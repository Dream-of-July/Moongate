import AppKit
import Combine
import Foundation
#if canImport(MoongateCore)
import MoongateCore
#endif

/// 阶段槽位池：限制同一阶段（下载 / 压制 / 翻译）的并发任务数。
/// 全部在 MainActor 上运转，无锁；排队者被唤醒后重新竞争（队列规模小，开销可忽略）。
@MainActor
final class StageSlotPool {
    private let capacity: () -> Int
    private var inUse = 0
    private var parked: [(id: UUID, continuation: CheckedContinuation<Void, Never>)] = []

    init(capacity: @escaping () -> Int) {
        self.capacity = capacity
    }

    var hasFreeSlot: Bool { inUse < max(1, capacity()) }

    /// 等待并占用一个槽位。control 取消时抛 cancelled。
    /// respectPause=true 时，暂停中的任务不抢槽（等恢复后再竞争）；
    /// 恢复重排队的路径传 false（item 已恢复但 token 仍处暂停态，等槽到手才 SIGCONT）。
    func acquire(id: UUID, control: TaskControlToken, respectPause: Bool = true) async throws {
        while true {
            if Task.isCancelled || control.isCancelled { throw MoongateError.cancelled }
            if respectPause, control.isPaused {
                try await control.gate()
                continue
            }
            if hasFreeSlot {
                inUse += 1
                return
            }
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                parked.append((id, c))
            }
        }
    }

    /// 释放一个槽位并唤醒全部排队者重新竞争。
    func release() {
        inUse = max(0, inUse - 1)
        wakeAll()
    }

    /// 容量调大（设置变更）后让排队者重新竞争。
    func wakeAll() {
        let waiting = parked
        parked.removeAll()
        for waiter in waiting { waiter.continuation.resume() }
    }

    /// 取消某项时把它从排队里唤出（acquire 循环会自行检查取消并抛出）。
    func wake(id: UUID) {
        guard let index = parked.firstIndex(where: { $0.id == id }) else { return }
        let continuation = parked[index].continuation
        parked.remove(at: index)
        continuation.resume()
    }
}

/// 下载队列。每个 QueueItem 是一条「下载 →[翻译]→[烧录]」完整流水线，
/// 持有独立的 TaskControlToken，可随时独立暂停 / 恢复 / 取消，并发执行互不阻塞；
/// 三个阶段各有并发上限（下载/压制可在设置里调，翻译固定 2 防网关限流），
/// 暂停会让出占用的下载/压制槽位给其它任务，恢复时重新排队领取。
@MainActor
final class QueueManager: ObservableObject {

    /// 队列项当前所处阶段。暂停态不单列，由 QueueItem.isPaused 叠加表示。
    enum ItemStage: Equatable {
        case queued
        case downloading
        case translating
        case burning
        case done
        case failed(String)
        case cancelled
    }

    enum PostDownloadProcessingKind: Equatable {
        case generic
        case transcoding
    }

    struct QueueItem: Identifiable {
        let id: UUID
        let title: String
        let thumbnailURL: URL?
        let info: VideoInfo
        let request: DownloadRequest
        let chineseMode: ChineseSubtitleMode
        /// 本项使用的设置快照（字幕样式、烧录画质、翻译凭证）
        let settings: AppSettings
        var stage: ItemStage
        /// 0...1；nil 表示不确定（处理 / 翻译启动等）
        var progress: Double?
        /// 整条任务的 0...1 进度；跨下载 / 转码 / 翻译 / 烧录保持单调。
        var overallProgress: Double?
        var speedText: String?
        var remainingSeconds: Double?
        var remainingIsApproximate: Bool = false
        var isEstimatingRemaining: Bool = false
        var progressPhase: QueueProgressPhase?
        let progressPlan: QueueProgressPlan
        /// 暂停 / 部分成功 / 失败原因等附加说明
        var statusText: String?
        /// 已落盘的产物（下载文件、译文、烧录视频）
        var resultFiles: [URL]
        var isPaused: Bool
        /// 下载已 100%、正在合并/转码/字幕转换（progress 为 nil 但仍处于 .downloading）。
        /// UI 据此显示「处理中…」而非「下载中…」（避免像卡死）。
        var isPostDownloadProcessing: Bool = false
        var postDownloadProcessingKind: PostDownloadProcessingKind?
        /// 部分成功：视频已下载但字幕处理失败（done 态显示「重试字幕处理」按钮）。
        var partialFailure: Bool = false
        /// 本项流水线的控制令牌；retry 时换新的（旧的已 cancel）。
        var control: TaskControlToken
        /// 流水线代际：每次 enqueue/retry 递增；@MainActor 写回前校验，作废陈旧回调。
        var generation: Int = 0
        var task: Task<Void, Never>?

        mutating func clearProgress(resetOverall: Bool = false) {
            progress = nil
            speedText = nil
            remainingSeconds = nil
            remainingIsApproximate = false
            isEstimatingRemaining = false
            progressPhase = nil
            if resetOverall { overallProgress = nil }
        }

        mutating func completeProgress() {
            clearProgress()
            overallProgress = 1
        }
    }

    @Published var items: [QueueItem] = []

    /// 同时下载数（设置变更时由 ViewModel 同步；调大即时生效）。
    var maxConcurrentDownloads: Int {
        didSet { downloadPool.wakeAll() }
    }
    /// 同时压制数（设置里的原始值）。
    var maxConcurrentBurns: Int {
        didSet { burnPool.wakeAll() }
    }
    /// 实际压制并发上限：硬件编码后端时比原始值多放一路（编码走媒体引擎、不占 CPU），
    /// 软件后端时等于原始值。由 syncConcurrency 从 settings.effectiveMaxConcurrentBurns 同步。
    private var effectiveBurnCapacity: Int {
        didSet { if effectiveBurnCapacity != oldValue { burnPool.wakeAll() } }
    }

    private let engine: any DownloadEngine
    private lazy var downloadPool = StageSlotPool { [weak self] in self?.maxConcurrentDownloads ?? 3 }
    private lazy var burnPool = StageSlotPool { [weak self] in self?.effectiveBurnCapacity ?? 2 }
    /// 翻译并发固定 2（每项内部还有 3 路分块并行，再高容易撞网关限流）。
    private lazy var translatePool = StageSlotPool { 2 }
    /// 正在占用槽位的项（暂停让位 / 阶段结束释放用）。带代际：重试后旧流水线的
    /// 延迟释放不得动新代际刚领到的槽位。
    private var holdingPool: [UUID: (generation: Int, pool: StageSlotPool)] = [:]
    /// 暂停时让出的槽位池：恢复时需先重新领到槽位再 SIGCONT。
    private var resumePool: [UUID: (generation: Int, pool: StageSlotPool)] = [:]
    private var progressPhaseStarts: [UUID: (generation: Int, phase: QueueProgressPhase, startedAt: Date)] = [:]
    private var phaseDurationSamples: [QueueProgressPhase: [Double]] = [:]

    /// 视频文件后缀（用于在产物里识别可烧录的视频）
    private static let videoExtensions: Set<String> = [
        "mp4", "mov", "mkv", "webm", "m4v", "avi", "flv", "ts",
    ]

    init(engine: any DownloadEngine = makeDefaultEngine()) {
        self.engine = engine
        let settings = AppSettings.load()
        self.maxConcurrentDownloads = settings.maxConcurrentDownloads
        self.maxConcurrentBurns = settings.maxConcurrentBurns
        self.effectiveBurnCapacity = settings.effectiveMaxConcurrentBurns
    }

    /// 设置保存后同步并发上限（didSet 会唤醒排队者）。
    func syncConcurrency(from settings: AppSettings) {
        if maxConcurrentDownloads != settings.maxConcurrentDownloads {
            maxConcurrentDownloads = settings.maxConcurrentDownloads
        }
        if maxConcurrentBurns != settings.maxConcurrentBurns {
            maxConcurrentBurns = settings.maxConcurrentBurns
        }
        // 后端切换（硬件/软件）会改变有效压制并发，即使原始压制数没变也要同步。
        if effectiveBurnCapacity != settings.effectiveMaxConcurrentBurns {
            effectiveBurnCapacity = settings.effectiveMaxConcurrentBurns
        }
    }

    // MARK: - 槽位辅助

    /// 等槽位（满员时先把状态文案改成等待提示），拿到后按代际登记为持有。
    private func acquireSlot(
        _ pool: StageSlotPool, id: UUID, generation: Int,
        control: TaskControlToken, waitingText: String
    ) async throws {
        if !pool.hasFreeSlot {
            update(id, generation: generation) { $0.statusText = waitingText }
        }
        try await pool.acquire(id: id, control: control)
        // 等待期间可能已被 retry 换代：旧代际拿到的槽立即归还，避免错记到新代际名下。
        guard item(id)?.generation == generation else {
            pool.release()
            throw MoongateError.cancelled
        }
        holdingPool[id] = (generation, pool)
        update(id, generation: generation) { if $0.statusText == waitingText { $0.statusText = nil } }
    }

    /// 阶段结束（成功或失败）释放槽位；只释放本代际登记的，暂停已让位时自然空操作。
    private func releaseSlot(_ id: UUID, generation: Int) {
        guard let holding = holdingPool[id], holding.generation == generation else { return }
        holdingPool.removeValue(forKey: id)
        holding.pool.release()
    }

    private func wakeFromAllPools(_ id: UUID) {
        downloadPool.wake(id: id)
        burnPool.wake(id: id)
        translatePool.wake(id: id)
    }

    // MARK: - 派生状态

    /// 未到终态的任务数（queued/downloading/translating/burning，含已暂停）。
    /// 关窗确认据此统计，避免「只剩暂停任务」时静默丢弃。
    var openTaskCount: Int {
        items.filter { Self.isOpen($0.stage) }.count
    }

    /// 其中处于暂停态的数量。
    var pausedOpenTaskCount: Int {
        items.filter { $0.isPaused && Self.isOpen($0.stage) }.count
    }

    private static func isOpen(_ stage: ItemStage) -> Bool {
        switch stage {
        case .queued, .downloading, .translating, .burning:
            return true
        case .done, .failed, .cancelled:
            return false
        }
    }

    /// 存在已到终态（done/failed/cancelled）的项，「清除已完成」入口据此显示。
    var hasFinishedItems: Bool {
        items.contains { !Self.isOpen($0.stage) }
    }

    var progressSnapshot: QueueProgressSnapshot {
        QueueProgressEstimator.queueSnapshot(items: items.map { item in
            let terminal = !Self.isOpen(item.stage)
            return TaskProgressSnapshot(
                overallProgress: terminal ? 1 : item.overallProgress,
                remainingSeconds: item.remainingSeconds,
                isEstimatingRemaining: item.isEstimatingRemaining,
                isTerminal: terminal,
                plan: item.progressPlan,
                currentPhase: item.progressPhase
            )
        }, phaseMedianDurations: phaseMedianDurations, phaseCapacities: [
            .download: max(1, maxConcurrentDownloads),
            .transcode: max(1, maxConcurrentDownloads),
            .translate: 2,
            .burn: max(1, effectiveBurnCapacity),
        ])
    }

    private var phaseMedianDurations: [QueueProgressPhase: Double] {
        phaseDurationSamples.compactMapValues { samples in
            let valid = samples.filter { $0.isFinite && $0 >= 0 }.sorted()
            guard !valid.isEmpty else { return nil }
            return valid[valid.count / 2]
        }
    }

    private static func progressPlan(for request: DownloadRequest, mode: ChineseSubtitleMode) -> QueueProgressPlan {
        QueueProgressPlan(
            shouldTranscode: Transcoder.needsProcessing(request.outputFormat),
            shouldTranslate: mode.requiresTranslation,
            shouldBurn: mode.requiresBurner
        )
    }

    // MARK: - 入队

    /// 去重键：优先 videoID，取不到用 sourceURL + formatID。
    private static func dedupeKey(videoID: String, sourceURL: String, formatID: String) -> String {
        let id = videoID.trimmingCharacters(in: .whitespaces)
        if !id.isEmpty, id != "video" { return "id:" + id }
        return "url:" + sourceURL + "|" + formatID
    }

    /// 队列里是否已有同源且未到终态（非 done/failed/cancelled）的任务。
    func hasOpenDuplicate(videoID: String, sourceURL: String, formatID: String) -> Bool {
        let key = Self.dedupeKey(videoID: videoID, sourceURL: sourceURL, formatID: formatID)
        return items.contains { item in
            guard Self.isOpen(item.stage) else { return false }
            return Self.dedupeKey(
                videoID: item.info.videoID,
                sourceURL: item.request.url,
                formatID: item.request.formatID
            ) == key
        }
    }

    func enqueue(info: VideoInfo, request: DownloadRequest, chineseMode: ChineseSubtitleMode, settings: AppSettings) {
        let id = UUID()
        let control = TaskControlToken()
        let item = QueueItem(
            id: id,
            title: info.title,
            thumbnailURL: info.thumbnailURL,
            info: info,
            request: request,
            chineseMode: chineseMode,
            settings: settings,
            stage: .queued,
            progress: nil,
            overallProgress: nil,
            speedText: nil,
            remainingSeconds: nil,
            progressPhase: nil,
            progressPlan: Self.progressPlan(for: request, mode: chineseMode),
            statusText: nil,
            resultFiles: [],
            isPaused: false,
            control: control
        )
        items.append(item)
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runPipeline(id: id, skipDownload: false)
        }
        update(id) { $0.task = task }
    }

    // MARK: - 流水线

    /// 跑完整条流水线。skipDownload=true 用于重试：已下载产物在 resultFiles 里，跳过下载阶段。
    private func runPipeline(id: UUID, skipDownload: Bool) async {
        guard let current = item(id) else { return }
        let control = current.control
        let settings = current.settings
        let mode = current.chineseMode
        // 启动代际：每次 @MainActor 写回前校验，作废重试后陈旧回调的写入。
        let generation = current.generation

        // 1. 下载
        var downloadFiles: [URL]
        if skipDownload {
            downloadFiles = current.resultFiles
            update(id, generation: generation) {
                $0.overallProgress = QueueProgressEstimator.taskOverallProgress(
                    plan: $0.progressPlan,
                    currentPhase: .download,
                    phaseProgress: 1,
                    previousOverallProgress: $0.overallProgress
                )
                $0.clearProgress()
            }
        } else {
            do {
                try await acquireSlot(
                    downloadPool,
                    id: id,
                    generation: generation,
                    control: control,
                    waitingText: CoreL10n.t(L.Queue.waitingForDownloadSlot)
                )
                defer { releaseSlot(id, generation: generation) }
                update(id, generation: generation) {
                    $0.stage = .downloading
                    $0.clearProgress(resetOverall: true)
                    $0.statusText = nil
                    $0.isPostDownloadProcessing = false
                    $0.postDownloadProcessingKind = nil
                    self.applyProgress(&$0, id: id, generation: generation, phase: .download, phaseProgress: nil)
                }
                let result = try await engine.download(current.request, control: control) { [weak self] p in
                    Task { @MainActor in
                        self?.applyDownloadProgress(id: id, generation: generation, p)
                    }
                }
                guard item(id)?.generation == generation else { return }
                downloadFiles = result.files
                completeProgressPhase(id, generation: generation, phase: .download)
                update(id, generation: generation) { $0.resultFiles = result.files; $0.clearProgress() }

                // 下载后转码/remux（用户选了非「保持源格式」时）。在下载槽内顺序执行。
                if Transcoder.needsProcessing(current.request.outputFormat),
                   let videoFile = downloadFiles.first(where: {
                       Self.videoExtensions.contains($0.pathExtension.lowercased())
                   }) {
                    update(id, generation: generation) {
                        $0.stage = .downloading
                        $0.clearProgress()
                        $0.statusText = nil
                        $0.isPostDownloadProcessing = true
                        $0.postDownloadProcessingKind = .transcoding
                        self.applyProgress(&$0, id: id, generation: generation, phase: .transcode, phaseProgress: nil)
                    }
                    do {
                        // Transcoder 会先探测实际下载产物；偏好 HDR 只作为 ffprobe 失败时的兜底。
                        let requestedHDRFallback = current.request.preferHDR
                        let transcoded = try await Transcoder().transcode(
                            inputFile: videoFile,
                            format: current.request.outputFormat,
                            sourceVCodec: nil,
                            sourceIsHDR: requestedHDRFallback,
                            backend: settings.encodeBackend,
                            control: control
                        ) { [weak self] frac in
                            Task { @MainActor in
                                guard let self, self.item(id)?.generation == generation else { return }
                                self.update(id, generation: generation) {
                                    self.applyProgress(&$0, id: id, generation: generation, phase: .transcode, phaseProgress: frac)
                                }
                            }
                        }
                        guard item(id)?.generation == generation else { return }
                        // 用转码产物替换原视频文件（删原文件，除非同一路径）。
                        if transcoded != videoFile {
                            try? FileManager.default.removeItem(at: videoFile)
                        }
                        downloadFiles = downloadFiles.map { $0 == videoFile ? transcoded : $0 }
                        if !downloadFiles.contains(transcoded) { downloadFiles.append(transcoded) }
                        completeProgressPhase(id, generation: generation, phase: .transcode)
                        update(id, generation: generation) {
                            $0.resultFiles = downloadFiles
                            $0.clearProgress()
                            $0.statusText = nil
                            $0.isPostDownloadProcessing = false
                            $0.postDownloadProcessingKind = nil
                        }
                    } catch {
                        guard item(id)?.generation == generation else { return }
                        if isCancellation(error) {
                            update(id, generation: generation) {
                                $0.stage = .cancelled; $0.isPaused = false; $0.clearProgress(); $0.statusText = CoreL10n.t(L.Queue.cancelled)
                                $0.isPostDownloadProcessing = false; $0.postDownloadProcessingKind = nil
                            }
                            clearProgressTracking(id)
                        } else {
                            update(id, generation: generation) {
                                $0.stage = .failed(Self.shortReason(of: error))
                                $0.isPaused = false; $0.clearProgress()
                                $0.statusText = CoreL10n.t(L.Queue.failedWithReason, Self.shortReason(of: error))
                                $0.isPostDownloadProcessing = false; $0.postDownloadProcessingKind = nil
                            }
                            clearProgressTracking(id)
                        }
                        return
                    }
                }
            } catch {
                guard item(id)?.generation == generation else { return }
                if isCancellation(error) {
                    update(id, generation: generation) {
                        $0.stage = .cancelled
                        $0.isPaused = false
                        $0.clearProgress()
                        $0.statusText = CoreL10n.t(L.Queue.cancelled)
                        $0.isPostDownloadProcessing = false
                        $0.postDownloadProcessingKind = nil
                    }
                    clearProgressTracking(id)
                } else {
                    update(id, generation: generation) {
                        $0.stage = .failed(Self.shortReason(of: error))
                        $0.isPaused = false
                        $0.clearProgress()
                        $0.statusText = CoreL10n.t(L.Queue.failedWithReason, Self.shortReason(of: error))
                        $0.isPostDownloadProcessing = false
                        $0.postDownloadProcessingKind = nil
                    }
                    clearProgressTracking(id)
                }
                return
            }
        }

        // 下载完成，无需字幕处理：直接完成
        guard mode != .off else {
            finishDone(id, generation: generation, files: downloadFiles, statusText: nil)
            return
        }

        // 找翻译源字幕；没有就完成并提示已跳过
        let preferredLang = current.request.subtitleLangs.first ?? current.request.autoSubtitleLangs.first
        guard let sourceSubtitle = Self.pickSourceSubtitle(from: downloadFiles, preferredLang: preferredLang) else {
            finishDone(
                id, generation: generation, files: downloadFiles,
                statusText: mode == .burnOriginal
                    ? CoreL10n.t(L.Queue.noSubtitleFileSkippedBurn)
                    : CoreL10n.t(L.Queue.noSubtitleFileSkippedTranslation)
            )
            return
        }

        // 直接烧录模式：跳过翻译，把所选源字幕原样压进视频（无论语言、无需配置翻译服务）。
        if mode == .burnOriginal {
            guard let video = downloadFiles.first(where: {
                Self.videoExtensions.contains($0.pathExtension.lowercased())
            }) else {
                finishDone(id, generation: generation, files: downloadFiles, statusText: CoreL10n.t(L.Queue.noVideoFileSkippedBurn))
                return
            }
            do {
                try await acquireSlot(
                    burnPool,
                    id: id,
                    generation: generation,
                    control: control,
                    waitingText: CoreL10n.t(L.Queue.waitingForBurnSlot)
                )
                defer { releaseSlot(id, generation: generation) }
                update(id, generation: generation) {
                    $0.stage = .burning
                    $0.clearProgress()
                    $0.statusText = CoreL10n.t(L.Queue.burnOriginalSubtitle)
                    $0.isPostDownloadProcessing = false
                    $0.postDownloadProcessingKind = nil
                    self.applyProgress(&$0, id: id, generation: generation, phase: .burn, phaseProgress: nil)
                }
                let burnSubtitle = try Self.ensureSRTSubtitle(sourceSubtitle)
                let burner = makeBurner()
                let burned = try await burner.burn(
                    video: video,
                    subtitle: burnSubtitle,
                    maxHeight: settings.maxBurnHeight,
                    backend: settings.encodeBackend,
                    alwaysH264: settings.burnAlwaysH264,
                    control: control,
                    outputTag: CoreL10n.t(L.Queue.subtitleVersionTag)
                ) { [weak self] p in
                    Task { @MainActor in
                        self?.update(id, generation: generation) {
                            guard $0.stage == .burning else { return }
                            self?.applyProgress(&$0, id: id, generation: generation, phase: .burn, phaseProgress: p)
                        }
                    }
                }
                guard item(id)?.generation == generation else { return }
                completeProgressPhase(id, generation: generation, phase: .burn)
                update(id, generation: generation) {
                    $0.resultFiles.removeAll { $0 == burned }
                    $0.resultFiles.insert(burned, at: 0)
                }
                finishDone(id, generation: generation, files: item(id)?.resultFiles ?? downloadFiles, statusText: CoreL10n.t(L.Queue.burnedOriginalSubtitle))
            } catch {
                guard item(id)?.generation == generation else { return }
                settlePartial(id, generation: generation, files: item(id)?.resultFiles ?? downloadFiles, error: error, phase: CoreL10n.t(L.Queue.phaseBurn))
            }
            return
        }

        // 成熟的同语言软字幕：源字幕已与翻译目标语言同一脚本时直接使用，跳过 LLM 翻译。
        // 判定优先用 request 里记录的 lang，回退按所选文件名 ".<lang>.srt/.vtt" 解析。
        let sourceLang = preferredLang ?? Self.langCode(of: sourceSubtitle)
        let sourceMatchesTarget = TranslationLanguage.matches(
            source: sourceLang,
            target: settings.translationTargetLanguage
        )
        if sourceMatchesTarget {
            // srtOnly：原目标语言字幕即结果；若源是 VTT，先转成 SRT，保持模式语义。
            guard mode == .burnIn else {
                do {
                    let normalized = try Self.ensureSRTSubtitle(sourceSubtitle)
                    var files = downloadFiles
                    if !files.contains(normalized) { files.append(normalized) }
                    finishDone(id, generation: generation, files: files, statusText: CoreL10n.t(L.Queue.sourceTargetSubtitleSkippedTranslation))
                } catch {
                    settlePartial(id, generation: generation, files: downloadFiles, error: error, phase: CoreL10n.t(L.Queue.phaseTranslation))
                }
                return
            }
            // burnIn：直接拿目标语言字幕去烧录；VTT 先转成 SRT。
            guard let video = downloadFiles.first(where: {
                Self.videoExtensions.contains($0.pathExtension.lowercased())
            }) else {
                finishDone(id, generation: generation, files: downloadFiles, statusText: CoreL10n.t(L.Queue.noVideoFileSkippedBurn))
                return
            }
            do {
                try await acquireSlot(
                    burnPool,
                    id: id,
                    generation: generation,
                    control: control,
                    waitingText: CoreL10n.t(L.Queue.waitingForBurnSlot)
                )
                defer { releaseSlot(id, generation: generation) }
                update(id, generation: generation) {
                    $0.stage = .burning
                    $0.clearProgress()
                    $0.statusText = CoreL10n.t(L.Queue.sourceTargetSubtitleBurn)
                    $0.isPostDownloadProcessing = false
                    $0.postDownloadProcessingKind = nil
                    self.applyProgress(&$0, id: id, generation: generation, phase: .burn, phaseProgress: nil)
                }
                let burnSubtitle = try Self.ensureSRTSubtitle(sourceSubtitle)
                let burner = makeBurner()
                let burned = try await burner.burn(
                    video: video,
                    subtitle: burnSubtitle,
                    maxHeight: settings.maxBurnHeight,
                    backend: settings.encodeBackend,
                    alwaysH264: settings.burnAlwaysH264,
                    control: control
                ) { [weak self] p in
                    Task { @MainActor in
                        self?.update(id, generation: generation) {
                            guard $0.stage == .burning else { return }
                            self?.applyProgress(&$0, id: id, generation: generation, phase: .burn, phaseProgress: p)
                        }
                    }
                }
                guard item(id)?.generation == generation else { return }
                completeProgressPhase(id, generation: generation, phase: .burn)
                update(id, generation: generation) {
                    $0.resultFiles.removeAll { $0 == burned }
                    $0.resultFiles.insert(burned, at: 0)
                }
                finishDone(id, generation: generation, files: item(id)?.resultFiles ?? downloadFiles, statusText: CoreL10n.t(L.Queue.burnedSourceTargetSubtitle))
            } catch {
                guard item(id)?.generation == generation else { return }
                settlePartial(id, generation: generation, files: item(id)?.resultFiles ?? downloadFiles, error: error, phase: CoreL10n.t(L.Queue.phaseBurn))
            }
            return
        }

        // 2. 翻译
        let zhSrt: URL
        do {
            try await acquireSlot(
                translatePool,
                id: id,
                generation: generation,
                control: control,
                waitingText: CoreL10n.t(L.Queue.waitingForTranslationSlot)
            )
            defer { releaseSlot(id, generation: generation) }
            update(id, generation: generation) {
                $0.stage = .translating
                $0.clearProgress()
                $0.statusText = nil
                $0.isPostDownloadProcessing = false
                $0.postDownloadProcessingKind = nil
                self.applyProgress(&$0, id: id, generation: generation, phase: .translate, phaseProgress: nil)
            }
            let translator = makeTranslator(settings: settings)
            zhSrt = try await translator.translate(
                srtFile: sourceSubtitle,
                style: settings.subtitleStyle,
                context: settings.makeTranslationContext(sourceLanguage: preferredLang),
                control: control
            ) { [weak self] p in
                    Task { @MainActor in
                        self?.update(id, generation: generation) {
                            guard $0.stage == .translating else { return }
                            self?.applyProgress(&$0, id: id, generation: generation, phase: .translate, phaseProgress: p)
                        }
                    }
                }
            guard item(id)?.generation == generation else { return }
            completeProgressPhase(id, generation: generation, phase: .translate)
            update(id, generation: generation) {
                $0.clearProgress()
                if !$0.resultFiles.contains(zhSrt) { $0.resultFiles.append(zhSrt) }
            }
        } catch {
            guard item(id)?.generation == generation else { return }
            settlePartial(id, generation: generation, files: downloadFiles, error: error, phase: CoreL10n.t(L.Queue.phaseTranslation))
            return
        }

        // 3. 烧录（仅 burnIn）
        guard mode == .burnIn else {
            finishDone(id, generation: generation, files: item(id)?.resultFiles ?? downloadFiles, statusText: nil)
            return
        }
        guard let video = downloadFiles.first(where: {
            Self.videoExtensions.contains($0.pathExtension.lowercased())
        }) else {
            finishDone(id, generation: generation, files: item(id)?.resultFiles ?? downloadFiles, statusText: CoreL10n.t(L.Queue.noVideoFileSkippedBurn))
            return
        }

        do {
            try await acquireSlot(
                burnPool,
                id: id,
                generation: generation,
                control: control,
                waitingText: CoreL10n.t(L.Queue.waitingForBurnSlot)
            )
            defer { releaseSlot(id, generation: generation) }
            update(id, generation: generation) {
                $0.stage = .burning
                $0.clearProgress()
                $0.statusText = nil
                $0.isPostDownloadProcessing = false
                $0.postDownloadProcessingKind = nil
                self.applyProgress(&$0, id: id, generation: generation, phase: .burn, phaseProgress: nil)
            }
            let burner = makeBurner()
            let burned = try await burner.burn(
                video: video,
                subtitle: zhSrt,
                maxHeight: settings.maxBurnHeight,
                backend: settings.encodeBackend,
                alwaysH264: settings.burnAlwaysH264,
                control: control
            ) { [weak self] p in
                    Task { @MainActor in
                        self?.update(id, generation: generation) {
                            guard $0.stage == .burning else { return }
                            self?.applyProgress(&$0, id: id, generation: generation, phase: .burn, phaseProgress: p)
                        }
                    }
                }
            guard item(id)?.generation == generation else { return }
            completeProgressPhase(id, generation: generation, phase: .burn)
            update(id, generation: generation) {
                $0.resultFiles.removeAll { $0 == burned }
                $0.resultFiles.insert(burned, at: 0)
            }
            finishDone(id, generation: generation, files: item(id)?.resultFiles ?? downloadFiles, statusText: nil)
        } catch {
            guard item(id)?.generation == generation else { return }
            settlePartial(id, generation: generation, files: item(id)?.resultFiles ?? downloadFiles, error: error, phase: CoreL10n.t(L.Queue.phaseBurn))
        }
    }

    /// 下载进度显示态：进度分数（nil=不确定）+ 是否「处理中」（合并/收尾，显示不确定）。
    struct DownloadProgressState: Equatable {
        var progress: Double?
        var isProcessing: Bool
    }

    /// 由当前显示态 + yt-dlp 上报百分比推导下一显示态（纯函数）。
    /// 如实显示当前下载百分比：DASH 分流下载（视频 0→100% 后再下音频 0→100%），换流时百分比回落是真实情况，
    /// 照实显示让进度条始终在动，好过卡在 100% 或藏成转圈「处理中」；仅过滤 < 0.5 个百分点的高频抖动。
    /// 合并阶段由 [Merger] 行单独触发「处理中」。
    static func nextDownloadProgressState(_ current: DownloadProgressState, incoming: Double?) -> DownloadProgressState {
        guard let next = incoming else { return current }
        if let old = current.progress, abs(next - old) < 0.005 { return current }
        return DownloadProgressState(progress: next, isProcessing: false)
    }

    private func progressPhaseStart(id: UUID, generation: Int, phase: QueueProgressPhase, now: Date) -> Date {
        if let existing = progressPhaseStarts[id],
           existing.generation == generation,
           existing.phase == phase {
            return existing.startedAt
        }
        progressPhaseStarts[id] = (generation, phase, now)
        return now
    }

    private func clearProgressTracking(_ id: UUID) {
        progressPhaseStarts.removeValue(forKey: id)
    }

    private func completeProgressPhase(
        _ id: UUID,
        generation: Int,
        phase expectedPhase: QueueProgressPhase,
        now: Date = Date()
    ) {
        guard let existing = progressPhaseStarts[id],
              existing.generation == generation,
              existing.phase == expectedPhase else {
            return
        }
        let duration = max(0.1, now.timeIntervalSince(existing.startedAt))
        progressPhaseStarts.removeValue(forKey: id)
        var samples = phaseDurationSamples[expectedPhase] ?? []
        samples.append(duration)
        if samples.count > 9 {
            samples.removeFirst(samples.count - 9)
        }
        phaseDurationSamples[expectedPhase] = samples
    }

    private func applyProgress(
        _ item: inout QueueItem,
        id: UUID,
        generation: Int,
        phase: QueueProgressPhase,
        phaseProgress: Double?,
        speedText: String? = nil,
        etaText: String? = nil,
        now: Date = Date()
    ) {
        let normalized = QueueProgressEstimator.normalizedFraction(phaseProgress)
        let startedAt = progressPhaseStart(id: id, generation: generation, phase: phase, now: now)
        item.progress = normalized
        item.progressPhase = phase
        item.overallProgress = QueueProgressEstimator.taskOverallProgress(
            plan: item.progressPlan,
            currentPhase: phase,
            phaseProgress: normalized,
            previousOverallProgress: item.overallProgress
        )
        item.speedText = speedText
        let remaining = QueueProgressEstimator.estimatedRemainingSeconds(
            elapsedSeconds: max(0, now.timeIntervalSince(startedAt)),
            phaseProgress: normalized,
            sourceEtaSeconds: QueueProgressEstimator.parseEtaSeconds(etaText)
        )
        item.remainingSeconds = remaining?.seconds
        item.remainingIsApproximate = remaining?.isApproximate ?? false
        item.isEstimatingRemaining = remaining == nil && normalized != 1 && !item.isPaused
    }

    /// 下载进度上报：转 0...1（processing 阶段进度不确定，置 nil）。
    /// 节流：进度变化 < 1% 时不写 items，避免高频 objectWillChange 在长队列时拖累 UI。
    private func applyDownloadProgress(id: UUID, generation: Int, _ p: DownloadProgress) {
        update(id, generation: generation) {
            // 进入烧录/翻译后不再被迟到的下载回调覆盖
            guard $0.stage == .downloading else { return }
            switch p.phase {
            case .downloading:
                let newValue = p.percent.map { min(max($0 / 100, 0), 1) }
                let isProcessing = $0.isPostDownloadProcessing && $0.postDownloadProcessingKind == .generic
                let nextState = Self.nextDownloadProgressState(
                    DownloadProgressState(progress: $0.progress, isProcessing: isProcessing), incoming: newValue)
                self.applyProgress(
                    &$0,
                    id: id,
                    generation: generation,
                    phase: .download,
                    phaseProgress: nextState.progress,
                    speedText: p.speedText,
                    etaText: p.etaText
                )
                $0.isPostDownloadProcessing = nextState.isProcessing
                $0.postDownloadProcessingKind = nextState.isProcessing ? .generic : nil
            case .preparing:
                self.applyProgress(&$0, id: id, generation: generation, phase: .download, phaseProgress: nil)
                $0.isPostDownloadProcessing = false
                $0.postDownloadProcessingKind = nil
            case .finished:
                self.applyProgress(&$0, id: id, generation: generation, phase: .download, phaseProgress: 1)
                $0.clearProgress()
                $0.isPostDownloadProcessing = false
                $0.postDownloadProcessingKind = nil
            case .processing:
                // 下载 100% 后的合并/转码：进度不确定，标记为「处理中」避免像卡死。
                self.applyProgress(&$0, id: id, generation: generation, phase: .download, phaseProgress: nil)
                $0.isPostDownloadProcessing = true
                $0.postDownloadProcessingKind = .generic
                $0.statusText = p.detail
            }
        }
    }

    /// 部分成功：下载产物已落盘 → .done + 失败说明（可重试字幕处理）；否则视为 .failed。
    /// 取消（MoongateError.cancelled / Task 取消）→ .cancelled，保留已下产物。
    private func settlePartial(_ id: UUID, generation: Int, files: [URL], error: Error, phase: String) {
        if isCancellation(error) {
            update(id, generation: generation) {
                $0.stage = .cancelled
                $0.isPaused = false
                $0.clearProgress()
                $0.statusText = files.isEmpty ? CoreL10n.t(L.Queue.cancelled) : CoreL10n.t(L.Queue.cancelledSaved)
                $0.isPostDownloadProcessing = false
                $0.postDownloadProcessingKind = nil
            }
            clearProgressTracking(id)
            return
        }
        let reason = Self.shortReason(of: error)
        if !files.isEmpty {
            update(id, generation: generation) {
                $0.stage = .done
                $0.isPaused = false
                $0.completeProgress()
                $0.partialFailure = true
                $0.statusText = CoreL10n.t(L.Queue.partialSubtitleFailed, phase, reason)
                $0.isPostDownloadProcessing = false
                $0.postDownloadProcessingKind = nil
            }
            clearProgressTracking(id)
        } else {
            update(id, generation: generation) {
                $0.stage = .failed(reason)
                $0.isPaused = false
                $0.clearProgress()
                $0.statusText = CoreL10n.t(L.Queue.failedWithReason, reason)
                $0.isPostDownloadProcessing = false
                $0.postDownloadProcessingKind = nil
            }
            clearProgressTracking(id)
        }
    }

    private func finishDone(_ id: UUID, generation: Int, files: [URL], statusText: String?) {
        update(id, generation: generation) {
            $0.stage = .done
            $0.isPaused = false
            $0.completeProgress()
            $0.partialFailure = false
            $0.isPostDownloadProcessing = false
            $0.postDownloadProcessingKind = nil
            $0.resultFiles = files.isEmpty ? $0.resultFiles : files
            $0.statusText = statusText
        }
        clearProgressTracking(id)
    }

    // MARK: - 单项控制

    func pause(_ id: UUID) {
        guard let target = item(id), Self.isOpen(target.stage), !target.isPaused else { return }
        target.control.pause()
        // 让出占用的下载/压制槽位给其它任务；恢复时重新排队领取。
        // 翻译请求不是本地可挂起进程，暂停后仍可能有分块请求在飞行中，不能释放翻译并发位。
        if let holding = holdingPool[id], holding.generation == target.generation {
            if holding.pool !== translatePool {
                holdingPool.removeValue(forKey: id)
                holding.pool.release()
                resumePool[id] = holding
            }
        }
        update(id) { $0.isPaused = true }
    }

    func resume(_ id: UUID) {
        guard let target = item(id), target.isPaused else { return }
        update(id) { $0.isPaused = false }
        guard let parked = resumePool.removeValue(forKey: id),
              parked.generation == target.generation else {
            // 没让过位（翻译阶段 / 排队中暂停）：直接恢复，acquire 循环或 gate 会接着走。
            target.control.resume()
            return
        }
        // 让过位的：先重新领到槽位再 SIGCONT，避免恢复瞬间超出并发上限。
        let control = target.control
        let generation = target.generation
        update(id, generation: generation) { $0.statusText = CoreL10n.t(L.Queue.waitingSlotResume) }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await parked.pool.acquire(id: id, control: control, respectPause: false)
                guard self.item(id)?.generation == generation else {
                    parked.pool.release()
                    return
                }
                self.holdingPool[id] = (generation, parked.pool)
                self.update(id, generation: generation) {
                    if $0.statusText == CoreL10n.t(L.Queue.waitingSlotResume) { $0.statusText = nil }
                }
                control.resume()
            } catch {
                // 等槽期间被取消：流水线任务自会收敛，这里不动状态。
            }
        }
    }

    func cancel(_ id: UUID) {
        guard let target = item(id) else { return }
        resumePool.removeValue(forKey: id)
        clearProgressTracking(id)
        target.control.cancel()
        target.task?.cancel()
        // 还在排队等槽位的，唤出来让 acquire 循环抛出取消。
        wakeFromAllPools(id)
    }

    func remove(_ id: UUID) {
        guard let target = item(id) else { return }
        resumePool.removeValue(forKey: id)
        clearProgressTracking(id)
        target.control.cancel()
        target.task?.cancel()
        wakeFromAllPools(id)
        items.removeAll { $0.id == id }
    }

    /// 重试：保留已下载产物则跳过下载，仅重跑字幕处理；无产物则整条重跑。
    func retry(_ id: UUID) {
        guard let old = item(id) else { return }
        // 旧 control 若仍登记着进程，确保释放；清掉旧代际的槽位记账。
        resumePool.removeValue(forKey: id)
        clearProgressTracking(id)
        old.control.cancel()
        old.task?.cancel()
        wakeFromAllPools(id)

        let hasVideo = old.resultFiles.contains {
            Self.videoExtensions.contains($0.pathExtension.lowercased())
        }
        let skipDownload = hasVideo && old.chineseMode != .off
        let newControl = TaskControlToken()
        update(id) {
            $0.control = newControl
            $0.generation += 1
            $0.stage = .queued
            $0.isPaused = false
            $0.clearProgress(resetOverall: true)
            $0.isPostDownloadProcessing = false
            $0.postDownloadProcessingKind = nil
            $0.partialFailure = false
            $0.statusText = skipDownload ? nil : CoreL10n.t(L.Queue.retryDownloadAndProcess)
            if !skipDownload { $0.resultFiles = [] }
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runPipeline(id: id, skipDownload: skipDownload)
        }
        update(id) { $0.task = task }
    }

    /// 在访达中选中该项的产物（烧录视频排第一）。
    func revealInFinder(_ id: UUID) {
        guard let target = item(id), !target.resultFiles.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(target.resultFiles)
    }

    /// 一次移除所有已到终态（done/failed/cancelled）的项。
    func clearFinished() {
        items.removeAll { !Self.isOpen($0.stage) }
    }

    // MARK: - 工具

    private func index(of id: UUID) -> Int? {
        items.firstIndex { $0.id == id }
    }

    private func item(_ id: UUID) -> QueueItem? {
        guard let i = index(of: id) else { return nil }
        return items[i]
    }

    /// 按 id 定位并就地修改；项已被移除时安全跳过。
    private func update(_ id: UUID, _ mutate: (inout QueueItem) -> Void) {
        guard let i = index(of: id) else { return }
        mutate(&items[i])
    }

    /// 代际校验版：仅当当前 generation 与捕获值一致时才写回，作废重试后的陈旧回调。
    private func update(_ id: UUID, generation: Int, _ mutate: (inout QueueItem) -> Void) {
        guard let i = index(of: id), items[i].generation == generation else { return }
        mutate(&items[i])
    }

    private func isCancellation(_ error: Error) -> Bool {
        if case MoongateError.cancelled = error { return true }
        return error is CancellationError
    }

    private static func shortReason(of error: Error) -> String {
        switch error {
        case MoongateError.translateFailed(let r), MoongateError.burnFailed(let r), MoongateError.downloadFailed(let r):
            return r
        default:
            return error.localizedDescription
        }
    }

    /// 从字幕文件名 "<名>.<lang>.srt/.vtt" 解析出 lang code（无法解析返回 nil）。
    private static func langCode(of file: URL) -> String? {
        let stem = file.deletingPathExtension().lastPathComponent
        guard let dotIndex = stem.lastIndex(of: ".") else { return nil }
        return String(stem[stem.index(after: dotIndex)...]).lowercased()
    }

    /// 按勾选语言挑翻译源字幕（与 ViewModel 旧逻辑一致）：大小写不敏感、允许前缀匹配。
    /// preferredLang 命中时直接返回该文件（含目标语言后缀，以支持视频自带目标语言字幕作为源）；
    /// 没有 preferredLang 时回退第一个非译文字幕，避免把上次译文当源二次翻译。
    private static func pickSourceSubtitle(from files: [URL], preferredLang: String?) -> URL? {
        let subtitleFiles = files
            .filter { ["srt", "vtt"].contains($0.pathExtension.lowercased()) }
            .sorted { subtitleSourceRank($0) < subtitleSourceRank($1) }
        if let lang = preferredLang?.lowercased(), !lang.isEmpty,
           let matched = subtitleFiles.first(where: { file in
               guard let code = langCode(of: file) else { return false }
               return code == lang || code.hasPrefix(lang + "-") || lang.hasPrefix(code + "-")
           }) {
            return matched
        }
        let nonTranslated = subtitleFiles.filter { file in
            !TranslationLanguage.isTranslatedSubtitleFileName(file.lastPathComponent)
        }
        return nonTranslated.first ?? subtitleFiles.first
    }

    private static func subtitleSourceRank(_ file: URL) -> Int {
        switch file.pathExtension.lowercased() {
        case "vtt": return 0
        case "srt": return 1
        default: return 2
        }
    }

    private static func ensureSRTSubtitle(_ file: URL) throws -> URL {
        if file.pathExtension.lowercased() == "srt" { return file }
        return try cleanSRTFile(at: file).output
    }
}
