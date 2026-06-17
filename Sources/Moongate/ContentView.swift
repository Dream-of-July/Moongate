import AppKit
import SwiftUI
#if canImport(MoongateCore)
import MoongateCore
#endif

struct ContentView: View {
    @ObservedObject var model: ViewModel
    @ObservedObject private var updater: UpdateService
    @EnvironmentObject private var localizer: Localizer
    @FocusState private var urlFieldFocused: Bool

    init(model: ViewModel) {
        self.model = model
        self._updater = ObservedObject(wrappedValue: model.updater)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)
            // 内容区与队列浮层同层叠放：队列有任务且展开时铺满盖住下载设置，
            // 收起时缩成右下角小把手（带整体进度环），点击以上移动画展开。
            ZStack(alignment: .bottom) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                QueueOverlayView(queue: model.queue, expanded: $model.queueExpanded)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .frame(minWidth: 540, minHeight: 720)
        .onAppear {
            model.onAppear()
            urlFieldFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.prefillFromClipboardIfAppropriate()
        }
        .onChange(of: model.requestUrlFocus) { urlFieldFocused = true }
        .sheet(isPresented: $model.showSettings, onDismiss: { model.consumePendingSettingsActions() }) {
            SettingsView(model: model)
        }
        .sheet(isPresented: $model.showOnboarding) {
            OnboardingView(model: model)
                .environmentObject(localizer)
        }
        .sheet(isPresented: $model.showDependencySetup) {
            DependencySetupSheet(model: model)
        }
        .sheet(isPresented: loginSheetBinding) {
            if let site = model.loginSite {
                LoginSheet(
                    site: site,
                    onComplete: { model.loginCompleted() },
                    onCancel: { model.cancelLogin() }
                )
            }
        }
    }

    private var loginSheetBinding: Binding<Bool> {
        Binding(
            get: { model.loginSite != nil },
            set: { if !$0 { model.loginSite = nil } }
        )
    }

    // MARK: - 顶部输入区

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 解析栏放大：输入框可多行（一次粘贴多条链接逐行可见），按钮与输入框中心对齐。
            HStack(alignment: .center, spacing: 8) {
                TextField(localizer.t(L.Main.urlPlaceholderMultiline), text: $model.urlText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .lineLimit(1...4)
                    .focused($urlFieldFocused)
                    .onSubmit { model.parse() }
                    .accessibilityLabel(localizer.t(L.Main.urlInputAccessibility))
                Button {
                    model.pasteAndParse()
                } label: {
                    Image(systemName: "doc.on.clipboard")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .frame(height: 34)
                .disabled(model.isParsing)
                .help(localizer.t(L.Main.pasteAndParseHelp))
                .accessibilityLabel(localizer.t(L.Main.pasteAndParseAccessibility))
                .accessibilityHint(localizer.t(L.Main.pasteAndParseHint))
                parseButton
                    .controlSize(.large)
                    .disabled(
                        model.isParsing
                        || model.urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                Button {
                    model.showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .frame(width: 18, height: 18)
                        .overlay(alignment: .topTrailing) {
                            if updater.hasAvailableUpdate {
                                updateBadge
                            }
                        }
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .frame(height: 34)
                .help(localizer.t(L.Main.settingsHelp))
                .accessibilityLabel(
                    updater.hasAvailableUpdate
                    ? localizer.t(L.Main.settingsWithUpdateAccessibility)
                    : localizer.t(L.Main.settingsAccessibility)
                )
            }
            // 轻提示固定在解析栏下方：队列铺满时也不会被盖住
            // （ready 页有自己的就地提示，避免双显）
            if let notice = model.enqueueNotice, !isReadyStage {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private var isReadyStage: Bool {
        if case .ready = model.stage { return true }
        return false
    }

    private var updateBadge: some View {
        Circle()
            .fill(.red)
            .frame(width: 8, height: 8)
            .overlay {
                Circle()
                    .stroke(.white, lineWidth: 1.5)
            }
            .offset(x: 4, y: -4)
            .accessibilityHidden(true)
    }

    /// 解析按钮：仅在 idle / failed 阶段作为主按钮，其余阶段降级为次按钮。
    @ViewBuilder
    private var parseButton: some View {
        let button = Button {
            model.parse()
        } label: {
            Group {
                if model.isParsing {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(localizer.t(L.Main.parsingAccessibility))
                } else {
                    Text(localizer.t(L.Main.parse))
                }
            }
            .frame(minWidth: 36)
        }
        .help(localizer.t(L.Main.parseCurrentHelp))
        .accessibilityHint(localizer.t(L.Main.parseCurrentHint))
        .frame(height: 34)
        if parseButtonIsProminent {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    private var parseButtonIsProminent: Bool {
        switch model.stage {
        case .idle, .failed:
            return true
        default:
            return false
        }
    }

    // MARK: - 各阶段内容

    @ViewBuilder
    private var content: some View {
        switch model.stage {
        case .idle:
            emptyState
        case .resolving, .analyzing:
            loadingState
        case .choosing(let candidates):
            choosingState(candidates)
        case .ready(let info):
            readyState(info)
        case .failed(let message):
            failedState(message)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.tertiary)
            Text(localizer.t(L.Main.idleTitle))
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(localizer.t(L.Main.idleSubtitle))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var loadingState: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
                .accessibilityLabel(model.batchStatusText ?? localizer.t(L.Main.loadingAccessibility))
            Text(model.batchStatusText ?? localizer.t(L.Main.loading))
                .foregroundStyle(.secondary)
            if model.batchStatusText != nil {
                Text(localizer.t(L.Main.batchAutoQueueHint))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Button(localizer.t(L.Common.cancel)) {
                model.cancelParse()
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func choosingState(_ candidates: [VideoCandidate]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(localizer.t(L.Main.videoCount, candidates.count))
                    .font(.headline)
                VStack(spacing: 0) {
                    ForEach(Array(candidates.enumerated()), id: \.element.id) { index, candidate in
                        Button {
                            model.choose(candidate)
                        } label: {
                            candidateRow(candidate)
                        }
                        .buttonStyle(.plain)
                        if index < candidates.count - 1 {
                            Divider().padding(.leading, 44)
                        }
                    }
                }
                .background(cardBackground)
            }
            .frame(maxWidth: 500)
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity)
        }
    }

    private func candidateRow(_ candidate: VideoCandidate) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon(for: candidate.kind))
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.title)
                    .lineLimit(2)
                    .help(candidate.title)
                if let detail = candidate.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(candidate.title)
        .accessibilityHint(localizer.t(L.Main.chooseVideoHint))
    }

    private func icon(for kind: VideoCandidate.Kind) -> String {
        switch kind {
        case .pageMain, .directFile:
            return "film"
        case .youtube, .vimeo, .supported:
            return "play.rectangle"
        }
    }

    private func readyState(_ info: VideoInfo) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if model.canReturnToList {
                        Button {
                            model.backToList()
                        } label: {
                            Label(localizer.t(L.Main.backToList), systemImage: "chevron.left")
                                .font(.callout)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                    infoCard(info)
                    summarySection(info)
                    section(localizer.t(L.Ready.formatSection)) {
                        formatRows(info)
                    }
                    outputOptionsSection(info)
                    section(localizer.t(L.Ready.subtitlesSection)) {
                        subtitleRows(info)
                    }
                    section(localizer.t(L.Ready.subtitleProcessingSection)) {
                        chineseSubtitleRows(info)
                    }
                }
                .frame(maxWidth: 500)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity)
            }
            VStack(spacing: 6) {
                Button {
                    Task {
                        await model.startDownload()
                    }
                } label: {
                    Text(localizer.t(L.Main.enqueue))
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                // 重复入队等提示就地显示，避免点了按钮毫无反馈
                if let notice = model.enqueueNotice {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                } else {
                    Text(readyFooterCopy(for: info))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 500)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
    }

    private func readyFooterCopy(for info: VideoInfo) -> String {
        if readyFooterUsesVideoFolder(for: info) {
            let folderName = ViewModel.sanitizedFolderName(info.title)
            return localizer.t(L.Main.saveToVideoFolder, folderName)
        }
        return localizer.t(L.Main.saveToDownloads)
    }

    private func readyFooterUsesVideoFolder(for info: VideoInfo) -> Bool {
        let chosen = info.subtitles.filter { model.selectedSubtitleIDs.contains($0.id) }
        return !chosen.isEmpty || model.chineseMode != .off
    }

    private func formatRow(_ format: FormatChoice) -> some View {
        Button {
            model.selectedFormatID = format.id
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(format.label)
                    if let detail = format.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if model.selectedFormatID == format.id {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(format.label)
        .accessibilityHint(localizer.t(L.Ready.chooseFormatHint))
        .accessibilityValue(model.selectedFormatID == format.id ? localizer.t(L.Ready.selected) : localizer.t(L.Ready.notSelected))
    }

    /// 输出选项：HDR 开关（仅所选档有 HDR 源时显示）+ 输出格式（转码/remux）。
    @ViewBuilder
    private func outputOptionsSection(_ info: VideoInfo) -> some View {
        let selected = info.formats.first { $0.id == model.selectedFormatID }
        let hdrAvailable = selected?.hdrAvailable ?? false
        let sourceLabel: String? = {
            guard let s = selected else { return nil }
            let codec = s.sourceVCodec.map { $0.uppercased() } ?? ""
            let container = s.sourceContainer ?? ""
            let parts = [codec, container].filter { !$0.isEmpty }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }()
        section(localizer.t(L.Ready.outputOptionsSection)) {
            VStack(alignment: .leading, spacing: 10) {
                if hdrAvailable {
                    Toggle(isOn: $model.preferHDR) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("HDR")
                            Text(localizer.t(L.Ready.hdrHint))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                HStack {
                    Text(localizer.t(L.Ready.outputFormat))
                    Spacer(minLength: 8)
                    Picker(localizer.t(L.Ready.outputFormat), selection: $model.selectedOutputFormat) {
                        ForEach(OutputFormat.allCases, id: \.rawValue) { fmt in
                            Text(fmt == .original ? originalFormatLabel(sourceLabel) : fmt.displayName).tag(fmt)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                if let hint = outputFormatHint(info) {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
        }
    }

    private func originalFormatLabel(_ sourceLabel: String?) -> String {
        if let s = sourceLabel { return localizer.t(L.Ready.keepSourceFormatWithSource, s) }
        return localizer.t(L.Ready.keepSourceFormat)
    }

    /// 转码提示：选了会丢 HDR 或较慢的组合时提示。
    private func outputFormatHint(_ info: VideoInfo) -> String? {
        switch model.selectedOutputFormat {
        case .original, .mkv:
            return nil
        case .mp4H264:
            return model.preferHDR ? localizer.t(L.Ready.h264HdrWarning) : localizer.t(L.Ready.h264ReencodeWarning)
        case .mp4H265:
            return localizer.t(L.Ready.h265ReencodeWarning)
        }
    }

    /// 视频档位在前；其后用分隔线 + “音频”小节标渲染仅音频选项。
    @ViewBuilder
    private func formatRows(_ info: VideoInfo) -> some View {
        let videoFormats = info.formats.filter { !$0.isAudioOnly }
        let audioFormats = info.formats.filter { $0.isAudioOnly }
        ForEach(Array(videoFormats.enumerated()), id: \.element.id) { index, format in
            formatRow(format)
            if index < videoFormats.count - 1 {
                Divider().padding(.leading, 12)
            }
        }
        if !videoFormats.isEmpty && !audioFormats.isEmpty {
            Divider()
            Text(localizer.t(L.Ready.audioSection))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        ForEach(Array(audioFormats.enumerated()), id: \.element.id) { index, format in
            formatRow(format)
            if index < audioFormats.count - 1 {
                Divider().padding(.leading, 12)
            }
        }
    }

    @ViewBuilder
    private func subtitleRows(_ info: VideoInfo) -> some View {
        if info.subtitles.isEmpty {
            Text(localizer.t(L.Ready.noSubtitles))
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ForEach(Array(info.subtitles.enumerated()), id: \.element.id) { index, subtitle in
                Toggle(isOn: subtitleBinding(subtitle.id)) {
                    HStack(spacing: 6) {
                        Text(subtitle.label)
                        if subtitle.isAuto {
                            Text(localizer.t(L.Ready.autoGenerated))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(.quaternary))
                        }
                    }
                }
                .toggleStyle(.checkbox)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(subtitleAccessibilityLabel(subtitle))
                .accessibilityHint(localizer.t(L.Ready.subtitleSelectHint))
                .accessibilityValue(model.selectedSubtitleIDs.contains(subtitle.id) ? localizer.t(L.Ready.selected) : localizer.t(L.Ready.notSelected))
                if index < info.subtitles.count - 1 {
                    Divider().padding(.leading, 12)
                }
            }
        }
    }

    private func subtitleAccessibilityLabel(_ subtitle: SubtitleChoice) -> String {
        if subtitle.isAuto {
            return localizer.t(L.Ready.autoGeneratedSubtitleLabel, subtitle.label)
        }
        return subtitle.label
    }

    private func subtitleBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { model.selectedSubtitleIDs.contains(id) },
            set: { isOn in
                if isOn {
                    model.selectedSubtitleIDs.insert(id)
                } else {
                    model.selectedSubtitleIDs.remove(id)
                }
            }
        )
    }

    /// 「字幕处理」分组：依赖上方至少勾选一条字幕；只有翻译类模式需要翻译服务。
    private func chineseSubtitleRows(_ info: VideoInfo) -> some View {
        let hasSubtitleSelected = !model.selectedSubtitleIDs.isEmpty
        let readiness = model.translationReadinessForCurrentSettings()
        return VStack(alignment: .leading, spacing: 8) {
            Picker(localizer.t(L.Ready.subtitleProcessingSection), selection: $model.chineseMode) {
                ForEach(ChineseSubtitleMode.allCases, id: \.self) { mode in
                    Text(localizer.t(mode.localizationKey)).tag(mode)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .disabled(!hasSubtitleSelected)
            .accessibilityLabel(localizer.t(L.Ready.subtitleProcessingAccessibility))
            .accessibilityHint(hasSubtitleSelected
                               ? localizer.t(L.Ready.subtitleProcessingHint)
                               : localizer.t(L.Ready.subtitleProcessingHintSelectFirst))
            .accessibilityValue(localizer.t(model.chineseMode.localizationKey))
            if !hasSubtitleSelected {
                Text(localizer.t(L.Ready.noSubtitleSelected))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if model.chineseMode.requiresTranslation, model.translationSourceMatchesTarget(in: info) {
                Text(model.chineseMode == .burnIn
                     ? localizer.t(L.Ready.sourceAlreadyTargetBurn)
                     : localizer.t(L.Ready.sourceAlreadyTargetUse))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if model.chineseMode.requiresTranslation, !readiness.isReady {
                if shouldShowAppleTranslationSetupGuidance {
                    appleTranslationSetupGuidanceView(readiness)
                } else {
                    compactTranslationReadinessView()
                }
            } else if model.chineseMode != .off, model.selectedSubtitleIDs.count > 1,
                      let source = model.translationSourceSubtitle(in: info) {
                Text(model.chineseMode == .burnOriginal
                     ? localizer.t(L.Ready.willBurnSubtitle, source.label)
                     : localizer.t(L.Ready.willTranslateSubtitle, source.label))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var shouldShowAppleTranslationSetupGuidance: Bool {
        switch effectiveTranslationEngine {
        case .appleTranslationLowLatency, .appleTranslationHighFidelity, .appleFoundationOnDevice, .appleFoundationPCC, .appleFoundationCloudPro:
            return true
        case .anthropicCompatible, .openAICompatible:
            return false
        }
    }

    private var effectiveTranslationEngine: TranslationEngine {
        model.settings.effectiveTranslationConfig.engine
    }

    private func compactTranslationReadinessView() -> some View {
        HStack(spacing: 8) {
            Text(model.translationReadinessMessageForCurrentSettings())
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(localizer.t(L.Ready.openSettings)) {
                model.showSettings = true
            }
            .buttonStyle(.link)
            .font(.caption)
        }
    }

    private func appleTranslationSetupGuidanceView(_ readiness: TranslationReadiness) -> some View {
        let guidance = AppleTranslationSetupGuidance.make(
            engine: effectiveTranslationEngine,
            readiness: readiness
        )
        return VStack(alignment: .leading, spacing: 6) {
            appleTranslationSetupReadinessSummary(readiness)
            Text(guidance.title)
                .font(.caption.weight(.semibold))
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(guidance.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 6) {
                        Text("\(index + 1).")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Text(step)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let actionSummary = appleTranslationSetupActionSummary(guidance) {
                Text(actionSummary)
                    .foregroundStyle(.secondary)
            }
            Text(appleTranslationSetupFallbackText)
                .foregroundStyle(.secondary)
                .accessibilityHint(localizer.t(L.Ready.appleTranslationFallbackHint))
            Button(localizer.t(L.Ready.openSettings)) {
                model.showSettings = true
            }
            .buttonStyle(.link)
            .help(localizer.t(L.Ready.appleTranslationOpenSettingsHelp))
            .accessibilityHint(localizer.t(L.Ready.appleTranslationOpenSettingsHelp))
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func appleTranslationSetupReadinessSummary(_ readiness: TranslationReadiness) -> some View {
        let statusText = readiness.isReady ? localizer.t(L.Ready.statusReady) : localizer.t(L.Ready.statusNeedsAction)
        let reasonText = appleTranslationSetupReadinessReason(readiness)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(localizer.t(L.Ready.currentEngine))
                    .foregroundStyle(.secondary)
                Text(effectiveTranslationEngine.displayName)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(localizer.t(L.Ready.status))
                    .foregroundStyle(.secondary)
                Text(statusText)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(localizer.t(L.Ready.primaryReason))
                    .foregroundStyle(.secondary)
                Text(reasonText)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(localizer.t(L.Ready.appleTranslationStatus))
        .accessibilityValue("\(effectiveTranslationEngine.displayName)，\(statusText)：\(reasonText)")
    }

    private func appleTranslationSetupReadinessReason(_ readiness: TranslationReadiness) -> String {
        readiness.isReady ? localizer.t(L.Ready.appleTranslationReadyReason) : model.translationReadinessMessageForCurrentSettings()
    }

    private var appleTranslationSetupFallbackText: String {
        localizer.t(L.Ready.appleTranslationFallback)
    }

    private func appleTranslationSetupActionSummary(_ guidance: AppleTranslationSetupGuidance) -> String? {
        let actionKinds = guidance.actions.map(\.kind)
        if actionKinds.contains(.openLanguageSettings) || actionKinds.contains(.openAppleIntelligenceSettings) {
            return localizer.t(L.Ready.appleTranslationActionOpenSettings)
        }
        if actionKinds.contains(.refreshReadiness) {
            return localizer.t(L.Ready.appleTranslationActionRefresh)
        }
        if actionKinds.contains(.chooseDifferentEngine) {
            return localizer.t(L.Ready.appleTranslationActionChooseDifferentEngine)
        }
        return nil
    }

    private func failedState(_ message: String) -> some View {
        // 两段式错误：第一行为中文主句，其余为原始错误详情。
        let parts = message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
        let headline = parts.first.map(String.init) ?? message
        let detail = parts.count > 1
            ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        return ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 40))
                    .foregroundStyle(.orange)
                    .padding(.top, 40)
                Text(headline)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420)
                if !detail.isEmpty {
                    DisclosureGroup(localizer.t(L.Failed.technicalDetails)) {
                        Text(detail)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                    }
                    .frame(maxWidth: 420)
                }
                HStack(spacing: 10) {
                    if model.failedNeedsDependency {
                        Button(localizer.t(L.Dependency.setupMissing)) {
                            model.showDependencySetup = true
                        }
                        .buttonStyle(.borderedProminent)
                        Button(localizer.t(L.Common.retry)) {
                            model.retry()
                        }
                        .buttonStyle(.bordered)
                    } else if model.failedNeedsLogin != nil {
                        Button(localizer.t(L.Failed.login)) {
                            model.openLoginForFailure()
                        }
                        .buttonStyle(.borderedProminent)
                        Button(localizer.t(L.Common.retry)) {
                            model.retry()
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Button(localizer.t(L.Common.retry)) {
                            model.retry()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Button(localizer.t(L.Failed.restart)) {
                        model.reset()
                        urlFieldFocused = true
                    }
                    .buttonStyle(.bordered)
                    if model.canReturnToList {
                        Button(localizer.t(L.Main.backToList)) {
                            model.backToList()
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .controlSize(.large)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - 通用

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            VStack(spacing: 0, content: content)
                .background(cardBackground)
        }
    }

    @ViewBuilder
    private func summarySection(_ info: VideoInfo) -> some View {
        section(localizer.t(L.Summary.title)) {
            SummaryCard(
                state: model.summaryState,
                unavailableReason: model.summaryUnavailableReason,
                isAvailable: model.isSummaryAvailable,
                onSummarize: { model.summarizeCurrentVideo() },
                onCancel: { model.resetSummary() }
            )
            .padding(12)
        }
    }

    private func infoCard(_ info: VideoInfo) -> some View {
        HStack(alignment: .top, spacing: 12) {
            AsyncImage(url: info.thumbnailURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    Rectangle()
                        .fill(.quaternary)
                        .overlay(
                            Image(systemName: "film")
                                .foregroundStyle(.tertiary)
                        )
                }
            }
            .frame(width: 160, height: 90)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                Text(info.title)
                    .font(.headline)
                    .lineLimit(2)
                    .help(info.title)
                let meta = [info.durationText, info.uploader]
                    .compactMap { $0 }
                    .joined(separator: " · ")
                if !meta.isEmpty {
                    Text(meta)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(.quaternary.opacity(0.55))
    }
}

private struct OnboardingView: View {
    @ObservedObject var model: ViewModel
    @EnvironmentObject private var localizer: Localizer
    @State private var appLanguage: AppLanguage
    @State private var translationTargetLanguage: String
    @State private var useLocalTranslation = true

    private let targetLanguages = ["zh-Hans", "zh-Hant", "en"]

    init(model: ViewModel) {
        self.model = model
        _appLanguage = State(initialValue: AppLanguage(rawValue: model.settings.appLanguage) ?? .auto)
        _translationTargetLanguage = State(initialValue: model.settings.translationTargetLanguage)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(localizer.t(L.Onboarding.title))
                    .font(.title2.weight(.semibold))
                Text(localizer.t(L.Onboarding.subtitle))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Form {
                Picker(localizer.t(L.Onboarding.appLanguage), selection: $appLanguage) {
                    Text(localizer.t(L.Settings.followSystem)).tag(AppLanguage.auto)
                    Text(localizer.t(L.Settings.langHans)).tag(AppLanguage.zhHans)
                    Text(localizer.t(L.Settings.langHant)).tag(AppLanguage.zhHant)
                    Text(localizer.t(L.Settings.langEn)).tag(AppLanguage.en)
                }
                .onChange(of: appLanguage) { _, next in
                    localizer.setLanguage(next)
                }

                Picker(localizer.t(L.Onboarding.translationTarget), selection: $translationTargetLanguage) {
                    ForEach(targetLanguages, id: \.self) { code in
                        Text(TranslationLanguage.displayName(for: code)).tag(code)
                    }
                }

                Toggle(localizer.t(L.Onboarding.useLocalTranslation), isOn: $useLocalTranslation)
                Text(localizer.t(L.Onboarding.localTranslationHint))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)

            Text(localizer.t(L.Onboarding.aiOptional))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let notice = model.settingsNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button(localizer.t(L.Onboarding.start)) {
                    if model.completeOnboarding(
                        appLanguage: appLanguage,
                        translationTargetLanguage: translationTargetLanguage,
                        useLocalTranslation: useLocalTranslation
                    ) {
                        localizer.setLanguage(appLanguage)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
        .onDisappear {
            localizer.setLanguage(AppLanguage(rawValue: model.settings.appLanguage) ?? .auto)
        }
    }
}
