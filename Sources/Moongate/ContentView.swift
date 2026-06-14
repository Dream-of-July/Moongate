import AppKit
import SwiftUI
#if canImport(MoongateCore)
import MoongateCore
#endif

struct ContentView: View {
    @ObservedObject var model: ViewModel
    @FocusState private var urlFieldFocused: Bool

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
            // 解析栏放大：输入框可多行（一次粘贴多条链接逐行可见），按钮顶部对齐
            HStack(alignment: .top, spacing: 8) {
                TextField("粘贴视频链接，可一次粘贴多条", text: $model.urlText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .lineLimit(1...4)
                    .focused($urlFieldFocused)
                    .onSubmit { model.parse() }
                    .accessibilityLabel("视频链接输入框")
                Button {
                    model.pasteAndParse()
                } label: {
                    Image(systemName: "doc.on.clipboard")
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .disabled(model.isParsing)
                .help("粘贴并解析剪贴板链接")
                .accessibilityLabel("粘贴并解析")
                .accessibilityHint("粘贴剪贴板里的链接并开始解析")
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
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .help("设置")
                .accessibilityLabel("打开设置")
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
                        .accessibilityLabel("正在解析")
                } else {
                    Text("解析链接")
                }
            }
            .frame(minWidth: 36)
        }
        .help("解析当前输入框中的视频链接")
        .accessibilityHint("解析当前输入框中的视频链接")
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
            Text("粘贴链接，下载网页里的视频")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("一次粘贴多条链接会自动逐个解析并加入队列")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var loadingState: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
                .accessibilityLabel(model.batchStatusText ?? "正在解析")
            Text(model.batchStatusText ?? "正在解析…")
                .foregroundStyle(.secondary)
            if model.batchStatusText != nil {
                Text("解析完成的视频会按最高画质自动加入队列")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Button("取消") {
                model.cancelParse()
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func choosingState(_ candidates: [VideoCandidate]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("这个页面里有 \(candidates.count) 个视频")
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
        .accessibilityHint("选择这个视频")
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
                            Label("返回列表", systemImage: "chevron.left")
                                .font(.callout)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                    infoCard(info)
                    summarySection(info)
                    section("格式") {
                        formatRows(info)
                    }
                    outputOptionsSection(info)
                    section("字幕") {
                        subtitleRows(info)
                    }
                    section("字幕处理") {
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
                    Text("加入队列")
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
            return "保存到 Downloads/\(folderName) 文件夹 · 加入后可继续粘贴下一条"
        }
        return "保存到 Downloads · 加入后可继续粘贴下一条"
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
        .accessibilityHint("选择这个下载格式")
        .accessibilityValue(model.selectedFormatID == format.id ? "已选择" : "未选择")
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
        section("输出选项") {
            VStack(alignment: .leading, spacing: 10) {
                if hdrAvailable {
                    Toggle(isOn: $model.preferHDR) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("HDR")
                            Text("该清晰度提供 HDR 片源。开启后下载 HDR 版本。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                HStack {
                    Text("输出格式")
                    Spacer(minLength: 8)
                    Picker("输出格式", selection: $model.selectedOutputFormat) {
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
        if let s = sourceLabel { return "保持源格式（\(s)）" }
        return "保持源格式"
    }

    /// 转码提示：选了会丢 HDR 或较慢的组合时提示。
    private func outputFormatHint(_ info: VideoInfo) -> String? {
        switch model.selectedOutputFormat {
        case .original, .mkv:
            return nil
        case .mp4H264:
            return model.preferHDR ? "转 H.264 会把 HDR 转成 SDR（丢失 HDR），且需重新编码、较慢。" : "跨编码转 H.264 需重新编码，较慢。"
        case .mp4H265:
            return "转 H.265 需重新编码，较慢；HDR 源会尽量保留 HDR。"
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
            Text("音频")
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
            Text("这个视频没有字幕")
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
                            Text("自动生成")
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
                .accessibilityHint("勾选后可下载字幕，或用于中文字幕处理")
                .accessibilityValue(model.selectedSubtitleIDs.contains(subtitle.id) ? "已选择" : "未选择")
                if index < info.subtitles.count - 1 {
                    Divider().padding(.leading, 12)
                }
            }
        }
    }

    private func subtitleAccessibilityLabel(_ subtitle: SubtitleChoice) -> String {
        if subtitle.isAuto {
            return "\(subtitle.label)，自动生成字幕"
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
            Picker("字幕处理", selection: $model.chineseMode) {
                ForEach(ChineseSubtitleMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .disabled(!hasSubtitleSelected)
            .accessibilityLabel("字幕处理方式")
            .accessibilityHint(hasSubtitleSelected ? "选择是否生成、翻译或烧录中文字幕" : "先在上面勾选一条字幕")
            .accessibilityValue(model.chineseMode.label)
            if !hasSubtitleSelected {
                Text("先在上面勾选一条字幕")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if model.chineseMode.requiresTranslation, model.translationSourceIsChinese(in: info) {
                Text(model.chineseMode == .burnIn
                     ? "该字幕已是中文，将直接烧录（不翻译）"
                     : "该字幕已是中文，将直接使用（不翻译）")
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
                     ? "将烧录：\(source.label)"
                     : "将翻译：\(source.label)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var shouldShowAppleTranslationSetupGuidance: Bool {
        switch model.settings.translationEngine {
        case .appleTranslationLowLatency, .appleTranslationHighFidelity, .appleFoundationOnDevice, .appleFoundationPCC, .appleFoundationCloudPro:
            return true
        case .anthropicCompatible, .openAICompatible:
            return false
        }
    }

    private func compactTranslationReadinessView() -> some View {
        HStack(spacing: 8) {
            Text(model.translationReadinessMessageForCurrentSettings())
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("去设置") {
                model.showSettings = true
            }
            .buttonStyle(.link)
            .font(.caption)
        }
    }

    private func appleTranslationSetupGuidanceView(_ readiness: TranslationReadiness) -> some View {
        let guidance = AppleTranslationSetupGuidance.make(
            engine: model.settings.translationEngine,
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
                .accessibilityHint("如果本机 Apple 能力暂不可用，可以先切换到 API 兼容引擎")
            Button("去设置") {
                model.showSettings = true
            }
            .buttonStyle(.link)
            .help("只打开 App 设置查看系统侧步骤；不会直接打开系统设置、下载语言包、保存配置或切换引擎。")
            .accessibilityHint("只打开 App 设置查看系统侧步骤；不会直接打开系统设置、下载语言包、保存配置或切换引擎。")
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func appleTranslationSetupReadinessSummary(_ readiness: TranslationReadiness) -> some View {
        let statusText = readiness.isReady ? "当前可运行" : "需要处理"
        let reasonText = appleTranslationSetupReadinessReason(readiness)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("当前引擎")
                    .foregroundStyle(.secondary)
                Text(model.settings.translationEngine.displayName)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("状态")
                    .foregroundStyle(.secondary)
                Text(statusText)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("首要原因")
                    .foregroundStyle(.secondary)
                Text(reasonText)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Apple 翻译引擎状态")
        .accessibilityValue("\(model.settings.translationEngine.displayName)，\(statusText)：\(reasonText)")
    }

    private func appleTranslationSetupReadinessReason(_ readiness: TranslationReadiness) -> String {
        readiness.isReady ? "已满足当前翻译条件" : model.translationReadinessMessageForCurrentSettings()
    }

    private var appleTranslationSetupFallbackText: String {
        "也可以先在设置里改用 Anthropic-compatible 或 OpenAI-compatible 翻译引擎继续处理。"
    }

    private func appleTranslationSetupActionSummary(_ guidance: AppleTranslationSetupGuidance) -> String? {
        let actionKinds = guidance.actions.map(\.kind)
        if actionKinds.contains(.openLanguageSettings) || actionKinds.contains(.openAppleIntelligenceSettings) {
            return "建议动作：打开 App 设置查看系统侧配置步骤。"
        }
        if actionKinds.contains(.refreshReadiness) {
            return "建议动作：去设置后重新检测。"
        }
        if actionKinds.contains(.chooseDifferentEngine) {
            return "建议动作：去设置选择其他翻译引擎。"
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
                    DisclosureGroup("显示技术详情") {
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
                        Button("查看/安装缺失组件") {
                            model.showDependencySetup = true
                        }
                        .buttonStyle(.borderedProminent)
                        Button("重试") {
                            model.retry()
                        }
                        .buttonStyle(.bordered)
                    } else if model.failedNeedsLogin != nil {
                        Button("去登录") {
                            model.openLoginForFailure()
                        }
                        .buttonStyle(.borderedProminent)
                        Button("重试") {
                            model.retry()
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Button("重试") {
                            model.retry()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Button("重新开始") {
                        model.reset()
                        urlFieldFocused = true
                    }
                    .buttonStyle(.bordered)
                    if model.canReturnToList {
                        Button("返回列表") {
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
        section("AI 总结") {
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
