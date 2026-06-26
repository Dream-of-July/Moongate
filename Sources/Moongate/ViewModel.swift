import AppKit
import Combine
import Foundation
#if canImport(MoongateCore)
import MoongateCore
#endif

/// 字幕处理方式（ready 页「字幕处理」分组的选项）
enum ChineseSubtitleMode: String, CaseIterable, Codable {
    case off
    case srtOnly
    case burnIn
    case burnOriginal

    var localizationKey: String {
        switch self {
        case .off: return L.Ready.subtitleModeOff
        case .srtOnly: return L.Ready.subtitleModeSrtOnly
        case .burnIn: return L.Ready.subtitleModeBurnIn
        case .burnOriginal: return L.Ready.subtitleModeBurnOriginal
        }
    }

    var requiresTranslation: Bool {
        self == .srtOnly || self == .burnIn
    }

    var requiresBurner: Bool {
        self == .burnIn || self == .burnOriginal
    }
}

@MainActor
final class ViewModel: ObservableObject {

    /// 解析与选档的前半段；下载之后的流水线全部交给 QueueManager。
    enum Stage {
        case idle
        case resolving
        case choosing([VideoCandidate])
        case analyzing
        case ready(VideoInfo)
        case failed(String)
    }

    @Published var urlText: String = ""
    @Published var stage: Stage = .idle
    @Published var selectedFormatID: String?
    /// 用户是否选择下载 HDR（仅当所选档有 HDR 源时生效）。
    @Published var preferHDR: Bool = false {
        didSet { persistCurrentDownloadOptions() }
    }
    /// 下载后输出格式（转码/remux）；.original 不转码。
    @Published var selectedOutputFormat: OutputFormat = .original {
        didSet { persistCurrentDownloadOptions() }
    }
    @Published var primarySubtitleTrackID: String? {
        didSet {
            selectedSubtitleIDs = primarySubtitleTrackID.map { [$0] } ?? []
            if primarySubtitleTrackID == nil, chineseMode != .off {
                chineseMode = .off
            }
            refreshTranslationRuntimeReadiness()
            persistCurrentDownloadOptions()
        }
    }
    @Published var selectedSubtitleIDs: Set<String> = [] {
        didSet {
            // 字幕处理依赖至少勾选一条字幕；全部取消勾选时强制回「不需要」
            if selectedSubtitleIDs.isEmpty, chineseMode != .off {
                chineseMode = .off
            }
            refreshTranslationRuntimeReadiness()
            persistCurrentDownloadOptions()
        }
    }
    @Published var chineseMode: ChineseSubtitleMode = .off {
        didSet { persistCurrentDownloadOptions() }
    }
    /// Ready 页语言区是否展开（默认折叠：只显示推荐语言，展开后才显示其他语言与来源细节）。
    @Published var languageSectionExpanded: Bool = false
    /// 启动时（ViewModel 实例化前）读取持久化的界面语言，供 App 在 init 注入 Localizer。
    /// 仅一次性磁盘读取（非子进程），可安全用于 @StateObject 初始化。
    static var persistedAppLanguage: String { AppSettings.load(readCredentials: false).appLanguage }

    private static func localASRGeneratorSettingsChanged(_ old: AppSettings, _ new: AppSettings) -> Bool {
        old.localASREnabled != new.localASREnabled
            || old.localASRRuntimePath != new.localASRRuntimePath
            || old.localASRModelPath != new.localASRModelPath
            || old.localASRModelID != new.localASRModelID
    }

    /// 启动时不读 Keychain 凭证（避免首次启动弹授权）；首次真正需要凭证时由 hydrateCredentials() 补齐。
    /// 默认空设置仅作占位，init 会立刻用 load(readCredentials: false) 覆盖。
    @Published var settings = AppSettings() {
        didSet {
            CoreL10n.sync(from: settings)
            queue.syncConcurrency(from: settings)
            if Self.localASRGeneratorSettingsChanged(oldValue, settings) {
                queue.syncLocalASRGenerator(from: settings)
            }
            refreshTranslationRuntimeReadiness()
            refreshSummaryRuntimeReadiness()
        }
    }
    @Published var showSettings = false
    @Published var pendingSettingsPaneID: String?
    /// 首启引导：选择 App 语言与默认译文目标；不强制配置 API。
    @Published var showOnboarding = false
    /// 非 nil 时弹出站点登录窗（值为站点 host，如 "youtube.com"）
    @Published var loginSite: String?
    /// 失败原因是需要登录时记录站点，failed 页据此把主按钮换成「去登录」
    @Published var failedNeedsLogin: String?
    /// 失败原因是缺依赖（yt-dlp/ffmpeg 找不到）时，failed 页给「一键安装依赖」入口
    @Published var failedNeedsDependency = false
    /// 一键安装依赖的弹层
    @Published var showDependencySetup = false
    /// 设置窗里的提示（保存失败 / 请先配置翻译服务）
    @Published var settingsNotice: String?
    /// 入队成功后的一行轻提示（如「已加入队列」）
    @Published var enqueueNotice: String?
    /// 批量粘贴多链接时的进度文案（解析中显示，如「批量解析中（2/5）」）
    @Published var batchStatusText: String?
    /// 触发器：自增时 ContentView 重新聚焦链接输入框（入队后方便继续粘贴）。
    @Published var requestUrlFocus = 0
    /// 队列浮层形态：true=铺满内容区，false=缩成底部小把手。
    /// 开始解析新链接时自动收起（让位给下载设置），入队完成/回到空闲时自动铺满。
    @Published var queueExpanded = false
    @Published private(set) var runtimeTranslationReadiness: TranslationReadiness?
    private var runtimeTranslationReadinessContext: TranslationContext?
    @Published private(set) var runtimeSummaryReadiness: TranslationReadiness?
    private var runtimeSummaryReadinessContext: TranslationContext?

    /// AI 内容总结状态。按需触发；切换/重置视频时回到 idle。
    enum SummaryState: Equatable {
        case idle
        case running
        case done(String)
        case failed(String)
    }
    @Published private(set) var summaryState: SummaryState = .idle
    private var summaryTask: Task<Void, Never>?

    /// 并发下载队列，贯穿整个 App 生命周期。
    let queue: QueueManager
    /// 远程更新器贯穿主界面与设置页；发现新版后用于设置按钮红点提示。
    let updater: UpdateService

    private let engine: any DownloadEngine
    private let runtimeReadinessEvaluator: any TranslationRuntimeReadinessEvaluating
    private var runtimeReadinessTask: Task<Void, Never>?
    private var summaryReadinessTask: Task<Void, Never>?
    private var parseTask: Task<Void, Never>?
    private var candidates: [VideoCandidate] = []
    private var chosenCandidate: VideoCandidate?
    private var retryAction: (@MainActor () -> Void)?
    /// 设置窗里点了「登录 ××」：先收起设置 sheet，再由其 onDismiss 弹出登录窗
    private var pendingLoginSite: String?
    /// 设置窗里点了「配置依赖」：先收起设置 sheet，再由其 onDismiss 弹出依赖配置窗
    private var pendingDependencySetup = false
    /// 首次进入主界面时只做一次依赖体检，避免 sheet 被反复弹起。
    private var didRunStartupDependencyCheck = false
    /// 代际令牌：reset / 取消后，旧解析任务的回调全部作废
    private var session = 0

    /// 凭证是否已从安全存储补齐（见 hydrateCredentials）。启动时为 false，首次需要时置 true。
    private var credentialsHydrated = false

    init(
        engine: any DownloadEngine = makeDefaultEngine(),
        queue: QueueManager? = nil,
        updater: UpdateService? = nil,
        runtimeReadinessEvaluator: any TranslationRuntimeReadinessEvaluating = AppleRuntimeReadinessEvaluator()
    ) {
        let initialSettings = AppSettings.load(readCredentials: false)
        self.settings = initialSettings
        self.primarySubtitleTrackID = nil
        self.engine = engine
        self.queue = queue ?? QueueManager(
            engine: engine,
            localASRGenerator: LocalASRGeneratorFactory.make(settings: initialSettings),
            completionNotifier: SystemQueueCompletionNotifier(settingsProvider: { AppSettings.load(readCredentials: false) })
        )
        self.updater = updater ?? UpdateService()
        self.runtimeReadinessEvaluator = runtimeReadinessEvaluator
        self.updater.prepareForUpdateUI = { [weak self] in
            self?.dismissSheetsForUpdateUI()
        }
        CoreL10n.sync(from: settings)
    }

    /// 首次真正需要 API 凭证（打开设置 / 开始下载翻译 / 总结）时，从 Keychain 补齐 Token。
    /// 启动时刻意不读，避免首次启动还没用到 API 就弹 Keychain 授权；幂等，仅读一次。
    /// 注意：必须在任何会写回设置（保存）之前调用，否则会把空 Token 写盖掉安全存储里的值。
    func hydrateCredentials() {
        guard !credentialsHydrated else { return }
        credentialsHydrated = true
        settings = AppSettings.load(readCredentials: true)
    }

    // MARK: - 派生状态

    var isParsing: Bool {
        switch stage {
        case .resolving, .analyzing: return true
        default: return false
        }
    }

    var canReturnToList: Bool { candidates.count > 1 }

    // MARK: - 行为

    func onAppear() {
        prefillFromClipboardIfAppropriate()
        showOnboardingIfNeeded()
        if settings.onboardingCompleted {
            showDependencySetupIfNeededOnStartup()
        }
        checkForUpdatesIfNeeded()
        refreshTranslationRuntimeReadiness()
        refreshSummaryRuntimeReadiness()
    }

    func checkForUpdatesIfNeeded() {
        // 后台更新检查由 Sparkle 的自动调度驱动（Info.plist 的 SUEnableAutomaticChecks +
        // SUScheduledCheckInterval=86400）。之前这里调用的 updater.check(silent:true) 实为 no-op，
        // 既不真正检查、注释又声称会检查，已删除——显式检查仍由更新区的「检查更新」按钮触发。
    }

    func dismissSheetsForUpdateUI() {
        showSettings = false
    }

    /// 视图出现或 App 激活时：处于可输入阶段且输入框为空，用剪贴板里的链接预填（不自动解析）。
    func prefillFromClipboardIfAppropriate() {
        switch stage {
        case .idle, .ready:
            break
        default:
            return
        }
        guard urlText.isEmpty else { return }
        guard let clip = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            clip.lowercased().hasPrefix("http") else { return }
        urlText = clip
    }

    /// 「一键粘贴」：直接读剪贴板（绕过输入框对多行粘贴的处理差异），填入后立即解析。
    func pasteAndParse() {
        guard !isParsing else { return }
        guard let clip = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !clip.isEmpty else {
            enqueueNotice = CoreL10n.t(L.Main.clipboardEmpty)
            return
        }
        urlText = clip
        parse()
    }

    func parse() {
        let input = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !isParsing else { return }
        // 用户开始处理任务即补齐凭证：ready 页的「翻译/总结是否已配置」判断需要 Token，
        // 且此时弹一次 Keychain 授权（仅当有旧凭证项）比首次启动就弹更合理。
        hydrateCredentials()

        // 一次粘贴多条链接：逐个解析并按默认选项（最高画质）自动加入队列
        let urls = Self.extractURLs(from: input)
        if urls.count > 1 {
            processBatch(urls)
            return
        }

        // 单链接也用提取结果（容忍尾随标点/前后杂字），提不出再退回原始输入
        let target = urls.first ?? input
        guard let url = URL(string: target),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else {
            session += 1
            retryAction = nil
            failedNeedsLogin = nil
            failedNeedsDependency = false
            queueExpanded = false
            stage = .failed(CoreL10n.t(L.Main.invalidURL))
            return
        }
        session += 1
        let token = session
        retryAction = nil
        failedNeedsLogin = nil
        failedNeedsDependency = false
        enqueueNotice = nil
        queueExpanded = false
        stage = .resolving
        chosenCandidate = nil
        parseTask?.cancel()
        parseTask = Task {
            do {
                let found = try await self.engine.resolveCandidates(for: target)
                guard token == self.session else { return }
                guard !found.isEmpty else { throw MoongateError.sniffFailed("") }
                self.candidates = found
                if found.count == 1 {
                    self.choose(found[0])
                } else {
                    self.stage = .choosing(found)
                }
            } catch {
                guard token == self.session else { return }
                self.fail(error) { [weak self] in self?.parse() }
            }
        }
    }

    /// App 管理的下载根目录。设置页的存储清理只允许操作这个目录，不能扫描整个 Downloads。
    static var appDownloadsDirectory: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Moongate", isDirectory: true)
    }

    /// 下载目的地：所有 v0.8 产物都放在 Downloads/Moongate 下；多文件任务再按视频标题建子文件夹。
    static func destinationDirectory(forTitle title: String, multiFile: Bool) -> URL {
        let downloads = appDownloadsDirectory
        guard multiFile else { return downloads }
        return downloads.appendingPathComponent(sanitizedFolderName(title), isDirectory: true)
    }

    /// 标题转安全文件夹名：去路径分隔/控制字符、截长、去结尾点号（兼容 Windows）。
    static func sanitizedFolderName(_ title: String) -> String {
        var name = title
            .components(separatedBy: CharacterSet(charactersIn: "/\\:\0").union(.newlines))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.count > 80 {
            name = String(name.prefix(80)).trimmingCharacters(in: .whitespaces)
        }
        while name.hasSuffix(".") { name.removeLast() }
        return name.isEmpty ? CoreL10n.t(L.Main.defaultVideoFolderName) : name
    }

    /// 从粘贴文本里提取全部 http(s) 链接，保序去重。
    /// 按 `http(s)://` 锚点切分而非只按空白：单行输入框粘贴多行时换行可能被吞掉、
    /// 多条链接首尾相接，按空白分隔会整段当成一条导致「只解析出一个地址」。
    static func extractURLs(from input: String) -> [String] {
        var seen = Set<String>()
        var urls: [String] = []
        guard let regex = urlExtractionRegex else { return [] }
        let ns = input as NSString
        for match in regex.matches(in: input, range: NSRange(location: 0, length: ns.length)) {
            let raw = ns.substring(with: match.range)
            let token = raw.trimmingCharacters(in: CharacterSet(charactersIn: ",;，；、。.)）]》〉>」』\"'"))
            guard let url = URL(string: token),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  url.host != nil,
                  seen.insert(token).inserted else { continue }
            urls.append(token)
        }
        return urls
    }

    // 每个字符既非空白、也不是下一条链接的开头（负向前瞻保证相接的链接被切开）。
    private static let urlExtractionRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"(?i)https?://(?:(?!https?://)\S)+"#
    )

    /// 批量模式：逐个解析（多候选页取第一个，即页面主视频），按最高画质自动入队。
    /// 当前已选字幕处理模式会沿用，并自动挑一条字幕作翻译源（真实字幕优先）。
    private func processBatch(_ urls: [String]) {
        let mode = chineseMode
        guard dependenciesReady(for: mode) else { return }
        session += 1
        let token = session
        retryAction = nil
        failedNeedsLogin = nil
        failedNeedsDependency = false
        enqueueNotice = nil
        candidates = []
        chosenCandidate = nil
        queueExpanded = false
        stage = .resolving
        let currentSettings = settings
        parseTask?.cancel()
        parseTask = Task {
            var added = 0
            var duplicated = 0
            var failedHosts: [String] = []
            for (index, urlString) in urls.enumerated() {
                guard token == self.session else { return }
                self.batchStatusText = CoreL10n.t(L.Main.batchParsing, index + 1, urls.count)
                do {
                    let found = try await self.engine.resolveCandidates(for: urlString)
                    guard token == self.session else { return }
                    guard let candidate = found.first else { throw MoongateError.sniffFailed("") }
                    var info = try await self.engine.analyze(url: candidate.url)
                    guard token == self.session else { return }
                    if candidate.kind == .pageMain || candidate.kind == .directFile,
                       !candidate.title.isEmpty, candidate.title != info.title {
                        info = VideoInfo(
                            sourceURL: info.sourceURL, videoID: info.videoID, title: candidate.title,
                            durationText: info.durationText, thumbnailURL: info.thumbnailURL,
                            uploader: info.uploader, description: info.description,
                            formats: info.formats, subtitles: info.subtitles
                        )
                    }
                    guard let formatID = info.formats.first?.id else {
                        throw MoongateError.analyzeFailed(CoreL10n.t(L.Main.noAvailableFormat))
                    }
                    if self.queue.hasOpenDuplicate(
                        videoID: info.videoID, sourceURL: info.sourceURL, formatID: formatID
                    ) {
                        duplicated += 1
                        continue
                    }
                    // 字幕处理开启时自动选一条推荐语言；同语言内仍由 track 排序决定人工/自动/本地源。
                    var subtitleLangs: [String] = []
                    var autoSubtitleLangs: [String] = []
                    var subtitleTracks: [SubtitleChoice] = []
                    var primarySubtitleTrackID: String?
                    let recommendation = SubtitleLanguageRecommender.recommend(
                        title: info.title,
                        languages: SubtitleLanguageRecommender.aggregate(availableSubtitleChoices(for: info))
                    )
                    if mode != .off,
                       let recommended = recommendation.recommended,
                       let sub = recommended.preferredTrack,
                       sub.sourceKind != .localASR || localASRReadyForDownload {
                        subtitleTracks = [sub]
                        primarySubtitleTrackID = sub.id
                        if sub.sourceKind == .platformAuto {
                            autoSubtitleLangs = [sub.languageCode]
                        } else if sub.sourceKind == .manual {
                            subtitleLangs = [sub.languageCode]
                        }
                    }
                    if shouldRequireTranslationReadiness(
                        for: mode,
                        info: info,
                        subtitleLangs: subtitleLangs,
                        autoSubtitleLangs: autoSubtitleLangs
                    ) {
                        let translationContext = currentSettings.makeTranslationContext(
                            sourceLanguage: subtitleTracks.first?.languageCode
                        )
                        guard await blockIfTranslationNotReady(
                            for: mode,
                            settings: currentSettings,
                            context: translationContext
                        ) else {
                            failedHosts.append(URL(string: urlString)?.host ?? urlString)
                            continue
                        }
                    }
                    let multiFile = mode != .off
                        || !subtitleLangs.isEmpty || !autoSubtitleLangs.isEmpty
                    let request = DownloadRequest(
                        url: info.sourceURL,
                        videoID: info.videoID,
                        formatID: formatID,
                        subtitleLangs: subtitleLangs,
                        autoSubtitleLangs: autoSubtitleLangs,
                        subtitleTracks: subtitleTracks,
                        primarySubtitleTrackID: primarySubtitleTrackID,
                        preferredSubtitleLanguageCode: primarySubtitleTrackID.map(normalizedLang),
                        destinationDirectory: Self.destinationDirectory(
                            forTitle: info.title, multiFile: multiFile
                        ),
                        preferredTitle: (candidate.kind == .pageMain || candidate.kind == .directFile)
                            ? info.title : nil
                    )
                    self.queue.enqueue(
                        info: info, request: request, chineseMode: mode, settings: currentSettings
                    )
                    added += 1
                } catch is CancellationError {
                    return
                } catch {
                    guard token == self.session else { return }
                    if case MoongateError.cancelled = error { return }
                    failedHosts.append(URL(string: urlString)?.host ?? urlString)
                }
            }
            guard token == self.session else { return }
            self.batchStatusText = nil
            self.urlText = ""
            self.selectedFormatID = nil
            self.primarySubtitleTrackID = nil
            self.chineseMode = .off
            self.stage = .idle
            var parts: [String] = [CoreL10n.t(L.Main.batchAdded, added)]
            if duplicated > 0 { parts.append(CoreL10n.t(L.Main.batchDuplicateCount, duplicated)) }
            if !failedHosts.isEmpty {
                let sample = failedHosts.prefix(2).joined(separator: "、")
                let suffix = failedHosts.count > 2 ? CoreL10n.t(L.Main.batchFailedSuffix) : ""
                parts.append(CoreL10n.t(L.Main.batchFailedCount, failedHosts.count, sample, suffix))
            }
            self.enqueueNotice = parts.joined(separator: "；")
            self.queueExpanded = true
            self.requestUrlFocus += 1
        }
    }

    func cancelParse() {
        switch stage {
        case .resolving:
            session += 1
            parseTask?.cancel()
            parseTask = nil
            batchStatusText = nil
            stage = .idle
            queueExpanded = true
        case .analyzing:
            session += 1
            parseTask?.cancel()
            parseTask = nil
            stage = candidates.count > 1 ? .choosing(candidates) : .idle
        default:
            break
        }
    }

    func choose(_ candidate: VideoCandidate) {
        session += 1
        let token = session
        retryAction = nil
        failedNeedsLogin = nil
        failedNeedsDependency = false
        chosenCandidate = candidate
        stage = .analyzing
        parseTask?.cancel()
        parseTask = Task {
            do {
                var info = try await self.engine.analyze(url: candidate.url)
                // 直链/页面主视频的 yt-dlp 标题往往是 CDN 文件名，换成嗅探到的页面标题
                if candidate.kind == .pageMain || candidate.kind == .directFile,
                   !candidate.title.isEmpty, candidate.title != info.title {
                    info = VideoInfo(
                        sourceURL: info.sourceURL, videoID: info.videoID, title: candidate.title,
                        durationText: info.durationText, thumbnailURL: info.thumbnailURL,
                        uploader: info.uploader, description: info.description,
                        formats: info.formats, subtitles: info.subtitles
                    )
                }
                guard token == self.session else { return }
                self.selectedFormatID = info.formats.first?.id
                self.restoreDownloadOptions(for: info)
                self.resetSummary()
                self.stage = .ready(info)
            } catch {
                guard token == self.session else { return }
                self.fail(error) { [weak self] in self?.choose(candidate) }
            }
        }
    }

    /// ready 页「加入队列」：构造 DownloadRequest 入队，然后清空回可输入态以便继续添加下一条。
    func startDownload() async {
        guard case .ready(let info) = stage else { return }
        hydrateCredentials()
        let startSession = session
        let mode = chineseMode
        let selectedFormatIDSnapshot = selectedFormatID
        let selectedSubtitleIDsSnapshot = selectedSubtitleIDs
        let primarySubtitleTrackIDSnapshot = primarySubtitleTrackID
        let preferHDRSnapshot = preferHDR
        let outputFormatSnapshot = selectedOutputFormat
        let currentSettings = settings
        let selectedCandidate = chosenCandidate

        if let primaryTrack = primarySubtitleTrack(in: info),
           primaryTrack.sourceKind == .localASR,
           !localASRReadyForDownload {
            openLocalASRSettings()
            return
        }
        guard dependenciesReady(for: mode) else { return }
        if shouldRequireTranslationReadiness(for: mode, info: info) {
            let translationContext = currentSettings.makeTranslationContext(
                sourceLanguage: translationSourceSubtitle(in: info)?.languageCode
            )
            guard await blockIfTranslationNotReady(
                for: mode,
                settings: currentSettings,
                context: translationContext
            ) else { return }
            guard startSession == session else { return }
            guard case .ready(let currentInfo) = stage,
                  currentInfo.sourceURL == info.sourceURL,
                  currentInfo.videoID == info.videoID else { return }
        }
        guard let formatID = selectedFormatIDSnapshot ?? info.formats.first?.id else { return }
        let selectedFormat = info.formats.first { $0.id == formatID }
        let requestPreferHDR = preferHDRSnapshot && (selectedFormat?.hdrAvailable ?? false)
        // 去重：队列里已有同源未完成任务时不再起新任务，只给一行提示。
        if queue.hasOpenDuplicate(videoID: info.videoID, sourceURL: info.sourceURL, formatID: formatID) {
            enqueueNotice = CoreL10n.t(L.Main.videoAlreadyQueued)
            return
        }
        let chosen = availableSubtitleChoices(for: info).filter { selectedSubtitleIDsSnapshot.contains($0.id) }
        // 会产出多个文件（字幕 / 翻译 / 烧录件）时在 App 下载目录下按视频建独立文件夹。
        let multiFile = !chosen.isEmpty || mode != .off
        let request = DownloadRequest(
            url: info.sourceURL,
            videoID: info.videoID,
            formatID: formatID,
            subtitleLangs: chosen.filter { !$0.isAuto }.map(\.languageCode),
            autoSubtitleLangs: chosen.filter { $0.isAuto }.map(\.languageCode),
            subtitleTracks: chosen,
            primarySubtitleTrackID: primarySubtitleTrackIDSnapshot,
            preferredSubtitleLanguageCode: primarySubtitleTrackIDSnapshot.map(normalizedLang),
            destinationDirectory: Self.destinationDirectory(forTitle: info.title, multiFile: multiFile),
            preferredTitle: {
                guard let kind = selectedCandidate?.kind, kind == .pageMain || kind == .directFile else { return nil }
                return info.title
            }(),
            preferHDR: requestPreferHDR,
            outputFormat: outputFormatSnapshot
        )
        queue.enqueue(info: info, request: request, chineseMode: mode, settings: currentSettings)

        // 回到可输入态，方便粘贴下一条。先切到 idle 再清空选项，避免清空触发 didSet 把
        // 已记住的「上次选项」误清（持久化只在 stage == .ready 时发生）。
        stage = .idle
        session += 1
        parseTask?.cancel()
        parseTask = nil
        urlText = ""
        selectedFormatID = nil
        self.primarySubtitleTrackID = nil
        chineseMode = .off
        candidates = []
        chosenCandidate = nil
        retryAction = nil
        failedNeedsLogin = nil
        failedNeedsDependency = false
        enqueueNotice = CoreL10n.t(L.Main.enqueuedTitle, info.title)
        // 入队即铺满队列（新任务落位可见），重新聚焦输入框方便直接粘贴下一条。
        queueExpanded = true
        requestUrlFocus += 1
    }

    /// 把当前选档页的选择即时记住（持久化为「上次下载选项」），供下次选档页恢复。
    /// 仅在 ready（用户正在选档）时记：恢复发生在 analyzing 阶段、入队后的清空发生在 idle 阶段，
    /// 都不会触发记忆，避免「恢复值/清空值」污染记忆。无变化时不落盘，避免每次切换都写磁盘。
    private func persistCurrentDownloadOptions() {
        guard case .ready(let info) = stage else { return }
        let selectedSubtitleLangs = availableSubtitleChoices(for: info)
            .filter { selectedSubtitleIDs.contains($0.id) }
            .map(\.languageCode)
        if settings.lastSubtitleMode == chineseMode.rawValue,
           settings.lastOutputFormat == selectedOutputFormat,
           settings.lastPreferHDR == preferHDR,
           settings.lastPrimarySubtitleTrackID == primarySubtitleTrackID,
           Set(settings.lastSubtitleLangs) == Set(selectedSubtitleLangs) {
            return
        }
        var updated = settings
        updated.lastSubtitleMode = chineseMode.rawValue
        updated.lastSubtitleLangs = selectedSubtitleLangs
        updated.lastPrimarySubtitleTrackID = primarySubtitleTrackID
        updated.lastOutputFormat = selectedOutputFormat
        updated.lastPreferHDR = preferHDR
        settings = updated
        _ = saveSettings()
    }

    /// 字幕 id 归一成语言代码：小写、取首个 `-` 前的部分。
    /// 这样上次选「ja」能匹配下个视频的「ja」/「ja-JP」/「ja-orig」/自动生成的日语字幕。
    private func normalizedLang(_ id: String) -> String {
        SubtitleLanguageChoice.normalizedLanguageCode(SubtitleTrackID(rawValue: id).languageCode)
    }

    func availableSubtitleChoices(for info: VideoInfo) -> [SubtitleChoice] {
        var choices = info.subtitles

        var seenIDs = Set(choices.map(\.id))
        if info.subtitles.isEmpty {
            let localASR = SubtitleChoice(
                languageCode: "auto",
                label: CoreL10n.t(L.Ready.localASRAutoDetectLabel),
                sourceKind: .localASR,
                provider: "whisper.cpp",
                variant: "local"
            )
            if seenIDs.insert(localASR.id).inserted {
                choices.append(localASR)
            }
            return choices
        }

        var seenLanguages: Set<String> = []
        for subtitle in info.subtitles {
            let languageCode = normalizedLang(subtitle.languageCode)
            guard !languageCode.isEmpty, seenLanguages.insert(languageCode).inserted else { continue }

            let localASR = SubtitleChoice(
                languageCode: languageCode,
                label: subtitle.label,
                sourceKind: .localASR,
                provider: "whisper.cpp",
                variant: "local"
            )
            if seenIDs.insert(localASR.id).inserted {
                choices.append(localASR)
            }
        }
        return choices
    }

    var localASRReadyForDownload: Bool {
        queue.hasLocalASRGenerator
    }

    // MARK: - Language-first ready page

    /// Language groups for the ready page (manual / auto / localASR collapsed per language).
    func availableLanguageChoices(for info: VideoInfo) -> [SubtitleLanguageChoice] {
        SubtitleLanguageRecommender.aggregate(availableSubtitleChoices(for: info))
    }

    /// Deterministic recommendation (recommended language + the rest), driven by title + tracks.
    func languageRecommendation(for info: VideoInfo) -> SubtitleLanguageRecommender.Result {
        SubtitleLanguageRecommender.recommend(
            title: info.title, languages: availableLanguageChoices(for: info))
    }

    /// The single language shown by default in the ready page main area.
    func recommendedLanguage(for info: VideoInfo) -> SubtitleLanguageChoice? {
        languageRecommendation(for: info).recommended
    }

    /// Other languages for the disclosure area (everything except the recommended one).
    func otherLanguages(for info: VideoInfo) -> [SubtitleLanguageChoice] {
        languageRecommendation(for: info).others
    }

    /// True when this language group is the currently selected source (by its preferred track).
    func isLanguageSelected(_ language: SubtitleLanguageChoice) -> Bool {
        guard let primarySubtitleTrackID else { return false }
        return language.tracks.contains { $0.id == primarySubtitleTrackID }
    }

    /// Selects a language: picks its preferred track (manual > auto > localASR) as the primary source.
    /// localASR-only groups still select when the generator isn't ready — the row shows a configure
    /// entry point, but the user's language intent is recorded.
    func selectLanguage(_ language: SubtitleLanguageChoice) {
        guard let track = language.preferredTrack else { return }
        primarySubtitleTrackID = track.id
    }

    func openSettings(paneID: String? = nil) {
        pendingSettingsPaneID = paneID
        showSettings = true
    }

    func openLocalASRSettings() {
        settingsNotice = CoreL10n.t(L.Ready.localASRSetupRequired)
        openSettings(paneID: "localSpeech")
    }

    /// 选档页恢复上次的下载选项：输出格式 / HDR 直接套用；字幕按语言代码在本视频可用字幕里匹配
    /// （真实字幕优先于自动字幕）；字幕处理方式在字幕恢复之后再设，避免 selectedSubtitleIDs 的
    /// didSet 把它打回 .off。本方法在 analyzing 阶段调用，期间不会触发 persist（持久化只认 .ready）。
    private func restoreDownloadOptions(for info: VideoInfo) {
        preferHDR = settings.lastPreferHDR
        selectedOutputFormat = settings.lastOutputFormat ?? .original

        let available = availableSubtitleChoices(for: info)
        var matchedPrimaryID: String?
        if let lastPrimarySubtitleTrackID = settings.lastPrimarySubtitleTrackID,
           let exact = available.first(where: { $0.id == lastPrimarySubtitleTrackID }),
           exact.sourceKind != .localASR || localASRReadyForDownload {
            matchedPrimaryID = exact.id
        } else {
            let wantedLangs = Set(settings.lastSubtitleLangs.map { normalizedLang($0) })
            for lang in wantedLangs {
                let group = available.filter {
                    normalizedLang($0.languageCode) == lang && $0.sourceKind != .localASR
                }
                if let best = group.first(where: { !$0.isAuto }) ?? group.first,
                   best.sourceKind != .localASR {
                    matchedPrimaryID = best.id
                    break
                }
            }
        }
        // 没有命中上次手选/语言 → 用语言优先推荐器选一个推荐语言（确定性，随视频内容变化）。
        if matchedPrimaryID == nil {
            if let recommended = recommendedLanguage(for: info)?.preferredTrack,
               recommended.sourceKind != .localASR || localASRReadyForDownload {
                matchedPrimaryID = recommended.id
            }
        }
        languageSectionExpanded = false
        primarySubtitleTrackID = matchedPrimaryID

        // 仅当字幕成功恢复、且记录的处理方式不是「不需要」时才恢复 mode（否则保持 didSet 设好的 .off）。
        if matchedPrimaryID != nil,
           let raw = settings.lastSubtitleMode,
           let mode = ChineseSubtitleMode(rawValue: raw),
           mode != .off {
            chineseMode = mode
        }
    }

    func primarySubtitleTrack(in info: VideoInfo) -> SubtitleChoice? {
        guard let primarySubtitleTrackID else { return nil }
        return availableSubtitleChoices(for: info).first { $0.id == primarySubtitleTrackID }
    }

    /// ready 页提示用：勾选多条字幕时实际作为翻译源的那条（真实字幕优先、按解析顺序取第一条）。
    func translationSourceSubtitle(in info: VideoInfo) -> SubtitleChoice? {
        primarySubtitleTrack(in: info)
    }

    /// 实际翻译源字幕是否已与翻译目标语言同一脚本（同则跳过翻译、直接使用/烧录）。
    /// 例：目标=简中且源=zh-Hans → 跳过；目标=繁中且源=zh-Hans → 不跳过（仍要简转繁翻译）。
    func translationSourceMatchesTarget(in info: VideoInfo) -> Bool {
        guard let source = translationSourceSubtitle(in: info) else { return false }
        return TranslationLanguage.matches(source: source.languageCode, target: settings.translationTargetLanguage)
    }

    func shouldRequireTranslationReadiness(for mode: ChineseSubtitleMode, info: VideoInfo) -> Bool {
        mode.requiresTranslation && !translationSourceMatchesTarget(in: info)
    }

    private func shouldRequireTranslationReadiness(
        for mode: ChineseSubtitleMode,
        info: VideoInfo,
        subtitleLangs: [String],
        autoSubtitleLangs: [String]
    ) -> Bool {
        mode.requiresTranslation
            && !translationSourceMatchesTarget(
                in: info,
                subtitleLangs: subtitleLangs,
                autoSubtitleLangs: autoSubtitleLangs
            )
    }

    private func translationSourceMatchesTarget(
        in info: VideoInfo,
        subtitleLangs: [String],
        autoSubtitleLangs: [String]
    ) -> Bool {
        let sourceID = subtitleLangs.first ?? autoSubtitleLangs.first
        guard let sourceID else { return false }
        guard info.subtitles.contains(where: { $0.languageCode == sourceID }) else { return false }
        return TranslationLanguage.matches(source: sourceID, target: settings.translationTargetLanguage)
    }

    func backToList() {
        guard candidates.count > 1 else { return }
        session += 1
        parseTask?.cancel()
        parseTask = nil
        retryAction = nil
        failedNeedsLogin = nil
        failedNeedsDependency = false
        resetSummary()
        stage = .choosing(candidates)
    }

    func retry() {
        guard case .failed = stage else { return }
        if let action = retryAction {
            action()
        } else {
            reset()
        }
    }

    func reset() {
        session += 1
        parseTask?.cancel()
        parseTask = nil
        urlText = ""
        resetSummary()
        stage = .idle
        queueExpanded = true
        selectedFormatID = nil
        primarySubtitleTrackID = nil
        chineseMode = .off
        candidates = []
        chosenCandidate = nil
        retryAction = nil
        failedNeedsLogin = nil
        failedNeedsDependency = false
        enqueueNotice = nil
    }

    private func dependenciesReady(for mode: ChineseSubtitleMode) -> Bool {
        guard mode.requiresBurner else { return true }
        let missing = DependencySetup.missing
        guard missing.contains(where: { $0.id == "ffmpeg" }) else { return true }
        settingsNotice = CoreL10n.t(L.Settings.installFfmpegFullNotice)
        showDependencySetup = true
        return false
    }

    func translationReadinessForCurrentSettings() -> TranslationReadiness {
        translationReadinessForCurrentSettings(context: currentTranslationContext())
    }

    private func translationReadinessForCurrentSettings(context: TranslationContext) -> TranslationReadiness {
        if runtimeTranslationReadinessContext == context,
           let runtimeTranslationReadiness {
            return runtimeTranslationReadiness
        }
        return settings.translationReadiness(context: context)
    }

    func translationReadinessMessageForCurrentSettings() -> String {
        translationReadinessMessageForCurrentSettings(context: currentTranslationContext())
    }

    private func translationReadinessMessageForCurrentSettings(context: TranslationContext) -> String {
        let readiness = translationReadinessForCurrentSettings(context: context)
        return translationReadinessMessage(for: readiness)
    }

    private func translationReadinessMessage(for readiness: TranslationReadiness) -> String {
        guard !readiness.isReady else { return CoreL10n.t(L.Settings.statusReady) }
        let message = readiness.issues.map(\.message).joined(separator: " ")
        return message.isEmpty ? CoreL10n.t(L.Settings.readinessUnavailable) : message
    }

    private func blockIfTranslationNotReady(for mode: ChineseSubtitleMode) -> Bool {
        guard mode.requiresTranslation else { return true }
        let readiness = translationReadinessForCurrentSettings()
        guard readiness.isReady else {
            settingsNotice = translationReadinessMessageForCurrentSettings()
            openSettings(paneID: "aiServices")
            return false
        }
        return true
    }

    private func blockIfTranslationNotReady(
        for mode: ChineseSubtitleMode,
        settings: AppSettings,
        context: TranslationContext
    ) async -> Bool {
        guard mode.requiresTranslation else { return true }
        let readiness = await settings.translationRuntimeReadiness(
            context: context,
            evaluator: runtimeReadinessEvaluator
        )
        guard readiness.isReady else {
            settingsNotice = translationReadinessMessage(for: readiness)
            openSettings(paneID: "aiServices")
            return false
        }
        return true
    }

    func refreshTranslationRuntimeReadiness() {
        runtimeReadinessTask?.cancel()
        let settings = settings
        let context = currentTranslationContext()
        runtimeTranslationReadinessContext = context
        runtimeTranslationReadiness = settings.translationReadiness(context: context)
        runtimeReadinessTask = Task { [runtimeReadinessEvaluator] in
            let readiness = await settings.translationRuntimeReadiness(
                context: context,
                evaluator: runtimeReadinessEvaluator
            )
            guard !Task.isCancelled else { return }
            guard self.runtimeTranslationReadinessContext == context else { return }
            self.runtimeTranslationReadiness = readiness
        }
    }

    func refreshSummaryRuntimeReadiness() {
        summaryReadinessTask?.cancel()
        let settings = settings.applyingTranslationConfig(settings.effectiveSummaryConfig)
        let context = summaryReadinessContext()
        runtimeSummaryReadinessContext = context
        runtimeSummaryReadiness = settings.translationReadiness(context: context)
        summaryReadinessTask = Task { [runtimeReadinessEvaluator] in
            let readiness = await settings.translationRuntimeReadiness(
                context: context,
                evaluator: runtimeReadinessEvaluator
            )
            guard !Task.isCancelled else { return }
            guard self.runtimeSummaryReadinessContext == context else { return }
            self.runtimeSummaryReadiness = readiness
        }
    }

    private func currentTranslationContext() -> TranslationContext {
        let sourceLanguage: String?
        if case .ready(let info) = stage {
            sourceLanguage = translationSourceSubtitle(in: info)?.languageCode
        } else {
            sourceLanguage = nil
        }
        return settings.makeTranslationContext(sourceLanguage: sourceLanguage)
    }

    private func summaryReadinessContext() -> TranslationContext {
        settings.makeTranslationContext(sourceLanguage: nil)
    }

    // MARK: - AI 内容总结

    /// 总结当前不可用的原因；nil 表示可用。供 Ready 页禁用按钮并给提示。
    var summaryUnavailableReason: String? {
        let config = settings.effectiveSummaryConfig
        if !config.engine.canGenerateText {
            return CoreL10n.t(L.Summary.unavailableEngine)
        }
        let summarySettings = settings.applyingTranslationConfig(config)
        if !summarySettings.isTranslationConfigured {
            return CoreL10n.t(L.Summary.notConfigured)
        }
        let context = summaryReadinessContext()
        let readiness = runtimeSummaryReadinessContext == context
            ? (runtimeSummaryReadiness ?? summarySettings.translationReadiness(context: context))
            : summarySettings.translationReadiness(context: context)
        if !readiness.isReady {
            return translationReadinessMessage(for: readiness)
        }
        return nil
    }

    var isSummaryAvailable: Bool { summaryUnavailableReason == nil }

    func resetSummary() {
        summaryTask?.cancel()
        summaryTask = nil
        summaryState = .idle
    }

    /// 对当前 Ready 的视频做 AI 总结：优先现拉字幕文本，拿不到回退视频简介。
    func summarizeCurrentVideo() {
        guard case .ready(let info) = stage else { return }
        hydrateCredentials()
        if let reason = summaryUnavailableReason {
            summaryState = .failed(reason)
            return
        }
        summaryTask?.cancel()
        summaryState = .running
        let settings = settings
        let config = settings.effectiveSummaryConfig
        let preferredLangs = info.subtitles.map(\.languageCode)
        summaryTask = Task { [engine] in
            do {
                // 优先字幕文本；最佳努力，失败/无字幕回退简介。
                let subtitleText = try? await engine.fetchSubtitleText(
                    url: info.sourceURL,
                    preferredLanguages: preferredLangs,
                    control: nil
                )
                if Task.isCancelled { return }
                let source = (subtitleText?.isEmpty == false) ? subtitleText : info.description
                let summary = try await summarizeVideo(
                    title: info.title,
                    uploader: info.uploader,
                    durationText: info.durationText,
                    source: source,
                    config: config,
                    settings: settings
                )
                if Task.isCancelled { return }
                self.summaryState = .done(summary)
            } catch is CancellationError {
                return
            } catch let MoongateError.translateFailed(message) {
                if Task.isCancelled { return }
                self.summaryState = .failed(message)
            } catch MoongateError.cancelled {
                return
            } catch {
                if Task.isCancelled { return }
                self.summaryState = .failed(error.localizedDescription)
            }
        }
    }

    private func showDependencySetupIfNeededOnStartup() {
        guard !didRunStartupDependencyCheck else { return }
        didRunStartupDependencyCheck = true
        // check() 会 spawn ffmpeg 子进程并 waitUntilExit，绝不能在 onAppear 同步路径里跑。
        Task { [weak self] in
            let components = await Task.detached(priority: .utility) {
                DependencySetup.check()
            }.value
            guard let self, DependencySetup.needsSetup(components) else { return }
            self.settingsNotice = CoreL10n.t(L.Dependency.setupRequiredNotice)
            self.showDependencySetup = true
        }
    }

    private func showOnboardingIfNeeded() {
        guard !settings.onboardingCompleted else { return }
        showOnboarding = true
    }

    @discardableResult
    func completeOnboarding(
        appLanguage: AppLanguage,
        translationTargetLanguage: String,
        useLocalTranslation: Bool,
        translationProvider: TranslationProvider,
        preferLocalSpeechRecognition: Bool,
        apiBaseURL: String = "",
        apiModel: String = "",
        apiAuthToken: String = ""
    ) -> Bool {
        // 必须先 hydrate 再取 draft：启动期 settings 以 readCredentials:false 载入（三个 Token 为空），
        // 若直接以此为 draft 落盘，save() → writeTokensToStore() 会把空值当“删除”抹掉 Keychain 里
        // 既有 Token（重跑 onboarding / settings.json 被重置或损坏后重建时尤甚）。
        // hydrate 后 settings 带真实 Token，draft 继承后只覆盖 onboarding 字段，未重填的 Token 得以保留。
        hydrateCredentials()
        var draft = settings
        draft.appLanguage = appLanguage.rawValue
        draft.translationTargetLanguage = translationTargetLanguage
        draft.onboardingCompleted = true
        draft.localASREnabled = preferLocalSpeechRecognition
        let engine = TranslationEngine.compatible(with: translationProvider)
        draft.translationProvider = translationProvider
        draft.aiEngine = engine
        draft.aiBaseURL = translationProvider.defaultBaseURL
        draft.translationBaseURL = translationProvider.defaultBaseURL
        if useLocalTranslation {
            draft.translationEngine = .appleTranslationLowLatency
            draft.translationFollowsDefault = false
        } else {
            draft.translationEngine = engine
            draft.translationFollowsDefault = true
            let normalizedModel = apiModel.trimmingCharacters(in: .whitespacesAndNewlines)
            draft.aiModel = normalizedModel
            draft.translationModel = normalizedModel
            // Apply user-entered API credentials from onboarding
            if !apiBaseURL.isEmpty {
                draft.aiBaseURL = apiBaseURL
                draft.translationBaseURL = apiBaseURL
            }
            if !apiAuthToken.isEmpty {
                draft.aiAuthToken = apiAuthToken
                draft.translationAuthToken = apiAuthToken
            }
        }
        do {
            try draft.save()
            settings = draft
            settingsNotice = nil
            showOnboarding = false
            showDependencySetupIfNeededOnStartup()
            return true
        } catch {
            settingsNotice = CoreL10n.t(L.Settings.saveFailed, error.localizedDescription)
            return false
        }
    }

    // MARK: - 设置与站点登录

    /// 保存设置；失败时把原因写进 settingsNotice。
    @discardableResult
    func saveSettings() -> Bool {
        do {
            try settings.save()
            settingsNotice = nil
            return true
        } catch {
            settingsNotice = CoreL10n.t(L.Settings.saveFailed, error.localizedDescription)
            return false
        }
    }

    /// 设置窗里点「登录 ××」：先保存设置再收起设置窗。保存失败则保持设置窗打开、不进入登录
    /// （settingsNotice 已写明原因），避免静默丢掉用户刚改的草稿（SETTINGS-001）。
    func requestLogin(site: String) {
        guard saveSettings() else { return }
        pendingLoginSite = site
        showSettings = false
    }

    /// 设置窗里点「配置依赖」：先保存设置再收起设置窗。保存失败则保持设置窗打开、不进入依赖流程。
    /// 与 requestLogin 一致先 save：设置窗 onDisappear 会用磁盘值回滚 model.settings，
    /// 不先落盘就会丢掉用户在设置里改了但还没点「完成」的草稿。
    func requestDependencySetup() {
        guard saveSettings() else { return }
        pendingDependencySetup = true
        showSettings = false
    }

    /// 设置 sheet 的 onDismiss 调用：若有待弹出的二级流程则继续弹出。
    func consumePendingSettingsActions() {
        consumePendingLogin()
        consumePendingDependencySetup()
    }

    private func consumePendingLogin() {
        guard let site = pendingLoginSite else { return }
        pendingLoginSite = nil
        loginSite = site
    }

    private func consumePendingDependencySetup() {
        guard pendingDependencySetup else { return }
        pendingDependencySetup = false
        showDependencySetup = true
    }

    func closeDependencySetup() {
        showDependencySetup = false
    }

    func completeDependencySetup() {
        showDependencySetup = false
        settingsNotice = nil
        let shouldRetry = failedNeedsDependency
        failedNeedsDependency = false
        if shouldRetry {
            retry()
        }
    }

    /// failed 页点「去登录」。
    func openLoginForFailure() {
        guard let site = failedNeedsLogin else { return }
        loginSite = site
    }

    /// 登录窗导出 cookies 成功后调用：关窗并自动重试上次失败的操作。
    func loginCompleted() {
        loginSite = nil
        if case .failed = stage, let action = retryAction {
            action()
        }
    }

    func cancelLogin() {
        loginSite = nil
    }

    // MARK: - 私有

    private func fail(_ error: Error, retry: @escaping @MainActor () -> Void) {
        retryAction = retry
        if case MoongateError.loginRequired(let site) = error {
            failedNeedsLogin = site
        } else {
            failedNeedsLogin = nil
            failedNeedsDependency = false
        }
        if case MoongateError.binaryNotFound = error {
            failedNeedsDependency = true
        } else {
            failedNeedsDependency = false
        }
        stage = .failed(error.localizedDescription)
    }
}
