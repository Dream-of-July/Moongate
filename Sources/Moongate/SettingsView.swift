import SwiftUI
import WebKit
#if canImport(AppKit)
import AppKit
#endif
#if canImport(MoongateCore)
import MoongateCore
#endif

/// 设置面板（sheet）：翻译服务、字幕样式、站点登录。
/// 草稿模式：输入框绑定 draft，点「完成」才回写并保存；取消 / Esc 不落任何修改。
struct SettingsView: View {
    @ObservedObject var model: ViewModel

    typealias TestState = APIConnectionTestState
    typealias ModelFetchState = APIModelFetchState

    @State private var draft = AppSettings()
    @ObservedObject private var updater: UpdateService
    @State private var testState: TestState = .idle
    @State private var testTask: Task<Void, Never>?
    @State private var modelFetchState: ModelFetchState = .idle
    @State private var modelFetchTask: Task<Void, Never>?
    @State private var clearFeedback: String?
    @State private var showClearConfirm = false
    /// cookies.txt 的修改日期；nil 表示尚未登录任何站点
    @State private var cookieDate: Date?
    // 初值为空：依赖体检会 spawn ffmpeg 子进程并 waitUntilExit（重入 runloop），
    // 不能在 @State 默认值（视图构造阶段）同步跑，否则触发 AttributeGraph 重入崩溃。
    @State private var dependencyComponents: [DependencySetup.Component] = []
    @State private var dependencyChecked = false
    @State private var dependencyExpanded = false
    @State private var draftRuntimeReadiness: TranslationReadiness?
    @State private var draftRuntimeReadinessTask: Task<Void, Never>?
    @State private var appleTranslationSourceLanguage = "en"

    private let appleTranslationSourceLanguages = [
        ("en", "英语"),
        ("ja", "日语"),
        ("ko", "韩语"),
        ("zh-Hans", "简体中文"),
        ("zh-Hant", "繁体中文")
    ]

    init(model: ViewModel) {
        self.model = model
        self._updater = ObservedObject(wrappedValue: model.updater)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                dependencySection
                translationSection
                translationConfigSection
                summarySection
                styleSection
                burnQualitySection
                performanceSection
                loginSection
                updateSection
            }
            .formStyle(.grouped)
            // 任一字段被改动：上一次的测试结果不再可信，回到初始态。
            .onChange(of: draft.aiBaseURL) { resetTestState(); resetModelFetch() }
            .onChange(of: draft.aiModel) { resetTestState() }
            .onChange(of: draft.aiAuthToken) { resetTestState(); resetModelFetch() }
            .onChange(of: appleTranslationSourceLanguage) { refreshDraftRuntimeReadiness() }
            Divider()
            bottomBar
        }
        .frame(width: 480, height: 560)
        .onAppear {
            draft = model.settings
            refreshLoginStatus()
            refreshDraftRuntimeReadiness()
        }
        .task {
            await refreshDependencies()
        }
        .task {
            // 打开设置时静默检查一次（有新版才在更新区提示，不打扰）。
            model.checkForUpdatesIfNeeded()
        }
        .onDisappear {
            testTask?.cancel()
            modelFetchTask?.cancel()
            draftRuntimeReadinessTask?.cancel()
            // 未点「完成」时回滚为磁盘值；已保存时 reload 等价于当前值，无副作用。
            model.settings = AppSettings.load()
        }
    }

    // MARK: - 依赖组件

    private var dependencyAllReady: Bool {
        dependencyChecked && !DependencySetup.needsSetup(dependencyComponents)
    }

    private var dependencySummaryText: String {
        if !dependencyChecked { return "检测中…" }
        return DependencySetup.needsSetup(dependencyComponents) ? "有组件未就绪" : "全部就绪"
    }

    private var dependencySection: some View {
        Section {
            DisclosureGroup(isExpanded: $dependencyExpanded) {
                if !dependencyChecked {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                            .accessibilityLabel("正在检测依赖组件")
                        Text("正在检测…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                } else {
                    ForEach(dependencyComponents) { component in
                        HStack(spacing: 8) {
                            Image(systemName: component.isInstalled ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(component.isInstalled ? .green : .orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(component.id)
                                    .font(.body.monospaced())
                                Text(component.purpose)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(component.isInstalled ? "已就绪" : "待安装")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(componentAccessibilityLabel(component))
                        .accessibilityValue(component.isInstalled ? "已就绪" : "待安装")
                    }

                    HStack(spacing: 10) {
                        Button("重新检测") {
                            Task { await refreshDependencies() }
                        }
                        .buttonStyle(.bordered)
                        Button(DependencySetup.needsSetup(dependencyComponents) ? "查看/安装缺失组件" : "打开配置") {
                            requestDependencySetup()
                        }
                        .buttonStyle(.borderedProminent)
                        Spacer()
                    }
                    .padding(.top, 2)
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: dependencyAllReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(dependencyAllReady ? .green : (dependencyChecked ? .orange : .secondary))
                    Text("依赖组件")
                    Spacer()
                    Text(dependencySummaryText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("依赖组件")
                .accessibilityValue(dependencySummaryText)
            }
        }
    }

    private func refreshDependencies() async {
        let checked = await Task.detached(priority: .userInitiated) {
            DependencySetup.check()
        }.value
        dependencyComponents = checked
        dependencyChecked = true
        // 有缺失才自动展开；全就绪保持折叠，不占地方。
        if DependencySetup.needsSetup(checked) {
            dependencyExpanded = true
        }
    }

    private func componentAccessibilityLabel(_ component: DependencySetup.Component) -> String {
        return "\(component.id)，\(component.purpose)"
    }

    // MARK: - AI 设置（翻译/总结共享的默认配置 + 各自跟随/单独开关）

    private var translationSection: some View {
        Section("AI 设置") {
            Text("这里配置默认 AI 服务。翻译与总结默认都用它，也可在下方各自单独配置。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("AI 引擎", selection: translationEngineBinding) {
                ForEach(TranslationEngine.allCases, id: \.rawValue) { engine in
                    Text(engine.displayName).tag(engine)
                }
            }
            if draft.aiEngine.requiresCloudConfiguration {
                apiTranslationFields
            } else {
                appleTranslationReadiness
            }
        }
    }

    // MARK: - AI 翻译（默认跟随，可单独配置）

    private var translationConfigSection: some View {
        Section("AI 翻译") {
            Picker("配置方式", selection: Binding(
                get: { draft.translationFollowsDefault },
                set: { draft.translationFollowsDefault = $0 }
            )) {
                Text("跟随 AI 设置").tag(true)
                Text("单独配置").tag(false)
            }
            .pickerStyle(.menu)
            if !draft.translationFollowsDefault {
                Picker("翻译引擎", selection: $draft.translationEngine) {
                    ForEach(TranslationEngine.allCases, id: \.rawValue) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }
                if draft.translationEngine.requiresCloudConfiguration {
                    APIConfigEditor(
                        baseURL: $draft.translationBaseURL,
                        model: $draft.translationModel,
                        authToken: $draft.translationAuthToken,
                        settingsForRequest: { overrideSettingsForRequest(
                            engine: draft.translationEngine,
                            baseURL: draft.translationBaseURL,
                            model: draft.translationModel,
                            authToken: draft.translationAuthToken
                        ) },
                        baseURLPrompt: baseURLPrompt(for: draft.translationEngine),
                        modelPrompt: "可先留空，填完地址和凭证后选择"
                    )
                } else {
                    Text("本地引擎无需填写服务地址与凭证。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - AI 总结（默认跟随，可单独配置）

    private var summarySection: some View {
        Section("AI 总结") {
            Picker("配置方式", selection: Binding(
                get: { draft.summaryFollowsDefault },
                set: { draft.summaryFollowsDefault = $0 }
            )) {
                Text("跟随 AI 设置").tag(true)
                Text("单独配置").tag(false)
            }
            .pickerStyle(.menu)
            if draft.summaryFollowsDefault {
                if !draft.aiEngine.canGenerateText {
                    Text("默认引擎不能生成总结，请改用云端 API / 本地 Apple Intelligence，或改为单独配置。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                summaryOverrideEditor
            }
        }
    }

    @ViewBuilder
    private var summaryOverrideEditor: some View {
        Picker("总结引擎", selection: $draft.summaryEngine) {
            ForEach(TranslationEngine.allCases, id: \.rawValue) { engine in
                Text(engine.displayName).tag(engine)
            }
        }
        if !draft.summaryEngine.canGenerateText {
            Text("该引擎只能翻译、不能生成总结，请改选云端 API 或本地 Apple Intelligence。")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else if draft.summaryEngine.requiresCloudConfiguration {
            APIConfigEditor(
                baseURL: $draft.summaryBaseURL,
                model: $draft.summaryModel,
                authToken: $draft.summaryAuthToken,
                settingsForRequest: { overrideSettingsForRequest(
                    engine: draft.summaryEngine,
                    baseURL: draft.summaryBaseURL,
                    model: draft.summaryModel,
                    authToken: draft.summaryAuthToken
                ) },
                baseURLPrompt: baseURLPrompt(for: draft.summaryEngine),
                modelPrompt: "可先留空，填完地址和凭证后选择"
            )
        } else {
            Text("本地引擎无需填写服务地址与凭证。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var apiTranslationFields: some View {
        Text(draft.aiEngine.readinessGuidance)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        TextField(
            "服务地址",
            text: $draft.aiBaseURL,
            prompt: Text(baseURLPrompt)
        )
        .autocorrectionDisabled()
        VStack(alignment: .leading, spacing: 4) {
            SecureField("API 凭证", text: $draft.aiAuthToken)
            Text(credentialSummaryText)
                .font(.caption)
                .foregroundStyle(.secondary)
            DisclosureGroup("高级说明") {
                Text(credentialDetailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        // 模型：先填地址+凭证，点「拉取模型」从服务端取真实可用列表再选。
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button("拉取模型") { fetchModels() }
                .buttonStyle(.bordered)
                .disabled(modelFetchState == .fetching
                    || draft.aiBaseURL.trimmingCharacters(in: .whitespaces).isEmpty
                    || draft.aiAuthToken.trimmingCharacters(in: .whitespaces).isEmpty)
            switch modelFetchState {
            case .idle:
                EmptyView()
            case .fetching:
                ProgressView().controlSize(.small)
                    .accessibilityLabel("正在拉取模型")
            case .loaded(let models):
                Text("已拉取 \(models.count) 个模型")
                    .font(.caption).foregroundStyle(.secondary)
            case .failure(let message):
                Text(message)
                    .font(.caption).foregroundStyle(.red).lineLimit(3)
            }
            Spacer(minLength: 0)
        }
        if case .loaded(let models) = modelFetchState, !models.isEmpty {
            // 手填了列表外的模型名时，把它并入选项，避免 Picker 选中值无对应 tag
            let current = draft.aiModel
            let options = (current.isEmpty || models.contains(current)) ? models : models + [current]
            Picker("选择模型", selection: $draft.aiModel) {
                Text("请选择").tag("")
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.menu)
        }
        // 拉不到列表时仍允许手填
        TextField(
            "模型名（也可手动填写）",
            text: $draft.aiModel,
            prompt: Text(modelPrompt)
        )
        .autocorrectionDisabled()
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button("测试连接") {
                runConnectionTest()
            }
            .buttonStyle(.bordered)
            .disabled(testState == .testing || !draft.applyingTranslationConfig(defaultAIConfig).isTranslationConfigured)
            switch testState {
            case .idle:
                EmptyView()
            case .testing:
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("正在测试连接")
            case .success:
                Text("连接正常")
                    .font(.caption)
                    .foregroundStyle(.green)
            case .failure(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
            Spacer(minLength: 0)
        }
    }

    private var appleTranslationReadiness: some View {
        let readiness = draftRuntimeReadiness
            ?? draft.translationReadiness(context: appleTranslationReadinessContext())
        let guidance = AppleTranslationSetupGuidance.make(
            engine: draft.aiEngine,
            readiness: readiness
        )
        let statusText = readiness.isReady ? "当前可运行" : "需要处理"
        return VStack(alignment: .leading, spacing: 6) {
            Text(draft.aiEngine.readinessGuidance)
                .font(.caption)
                .foregroundStyle(.secondary)
            if shouldShowAppleTranslationSourceLanguagePicker {
                Picker("源语言", selection: $appleTranslationSourceLanguage) {
                    ForEach(appleTranslationSourceLanguages, id: \.0) { language in
                        Text(language.1).tag(language.0)
                    }
                }
                .pickerStyle(.menu)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("当前引擎")
                        .foregroundStyle(.secondary)
                    Text(draft.aiEngine.displayName)
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("状态")
                        .foregroundStyle(.secondary)
                    Text(statusText)
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("首要原因")
                        .foregroundStyle(.secondary)
                    Text(readinessMessage(readiness))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
            // 只把只读状态合并成单个朗读元素；源语言 Picker 与恢复按钮必须保持可独立聚焦/激活。
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Apple 翻译引擎状态")
            .accessibilityValue("\(draft.aiEngine.displayName)，\(statusText)：\(readinessMessage(readiness))")
            if !readiness.isReady {
                appleSetupGuidance(guidance)
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 2)
    }

    private var shouldShowAppleTranslationSourceLanguagePicker: Bool {
        switch draft.aiEngine {
        case .appleTranslationLowLatency, .appleTranslationHighFidelity:
            return true
        case .anthropicCompatible, .openAICompatible, .appleFoundationOnDevice, .appleFoundationPCC, .appleFoundationCloudPro:
            return false
        }
    }

    private func appleTranslationReadinessContext() -> TranslationContext {
        guard shouldShowAppleTranslationSourceLanguagePicker else {
            return TranslationContext(sourceLanguage: nil, targetLanguage: "zh-Hans")
        }
        return TranslationContext(sourceLanguage: appleTranslationSourceLanguage, targetLanguage: "zh-Hans")
    }

    private var fallbackEngineText: String {
        "可先改用 Anthropic-compatible 或 OpenAI-compatible 翻译引擎。"
    }

    private func appleSetupGuidance(_ guidance: AppleTranslationSetupGuidance) -> some View {
        VStack(alignment: .leading, spacing: 6) {
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
            Text(fallbackEngineText)
                .foregroundStyle(.secondary)
                .accessibilityHint("如果本机 Apple 能力暂不可用，可以先切换到 API 兼容引擎")
            if !guidance.actions.isEmpty {
                HStack(spacing: 8) {
                    ForEach(guidance.actions) { action in
                        Button(action.title) {
                            performAppleSetupAction(action)
                        }
                        .help(appleSetupActionHelpText(action.kind))
                        .accessibilityHint(appleSetupActionHelpText(action.kind))
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var baseURLPrompt: String {
        switch apiProvider {
        case .anthropic:
            return "Anthropic 兼容地址或企业网关地址"
        case .openai:
            return "https://api.openai.com"
        }
    }

    private var modelPrompt: String {
        switch apiProvider {
        case .anthropic:
            return "可先留空，填完地址和凭证后选择"
        case .openai:
            return "可先留空，填完地址和凭证后选择"
        }
    }

    private var credentialSummaryText: String {
        "凭证只保存在本机设置中。只有点击「拉取模型」或「测试连接」时，才会发送到你填写的服务地址。"
    }

    private var credentialDetailText: String {
        switch apiProvider {
        case .anthropic:
            return "公司网关按 ANTHROPIC_BASE_URL / ANTHROPIC_AUTH_TOKEN 填写；DeepSeek 映射也选这个协议。"
        case .openai:
            return "OpenAI 使用 Responses API。服务地址填 https://api.openai.com；凭证填 OpenAI API key，不要带 Bearer 前缀。"
        }
    }

    private var apiProvider: TranslationProvider {
        draft.aiEngine.legacyProvider ?? .anthropic
    }

    /// 把某个「单独配置」槽位（翻译 / 总结）的字段固化进 translation* 字段，
    /// 供 listTranslationModels / testTranslationConnection 直接使用（它们只读 translation* 字段）。
    private func overrideSettingsForRequest(
        engine: TranslationEngine,
        baseURL: String,
        model: String,
        authToken: String
    ) -> AppSettings {
        draft.applyingTranslationConfig(LLMEndpointConfig(
            engine: engine, baseURL: baseURL, model: model, authToken: authToken
        ))
    }

    /// 服务地址提示语：按引擎对应的协议给出。
    private func baseURLPrompt(for engine: TranslationEngine) -> String {
        switch engine.legacyProvider ?? .anthropic {
        case .anthropic: return "Anthropic 兼容地址或企业网关地址"
        case .openai: return "https://api.openai.com"
        }
    }

    private var translationEngineBinding: Binding<TranslationEngine> {
        Binding(
            get: { draft.aiEngine },
            set: { engine in
                let previous = draft.aiEngine
                guard previous != engine else { return }
                draft.aiEngine = engine
                // 切协议清空默认模型，避免拿旧协议模型名撞 503。
                if previous.legacyProvider != engine.legacyProvider, !draft.aiModel.isEmpty {
                    draft.aiModel = ""
                }
                // 默认引擎是云端 API 时，把默认地址补上（仅在空或仍是默认值时）。
                if let provider = engine.legacyProvider {
                    let trimmed = draft.aiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    let defaults = Set(TranslationProvider.allCases.map(\.defaultBaseURL))
                    if trimmed.isEmpty || defaults.contains(trimmed) {
                        draft.aiBaseURL = provider.defaultBaseURL
                    }
                }
                resetTestState()
                resetModelFetch()
                refreshDraftRuntimeReadiness()
            }
        )
    }

    private func refreshDraftRuntimeReadiness() {
        draftRuntimeReadinessTask?.cancel()
        let settings = draft
        let context = appleTranslationReadinessContext()
        draftRuntimeReadiness = settings.translationReadiness(context: context)
        draftRuntimeReadinessTask = Task {
            let readiness = await settings.translationRuntimeReadiness(
                context: context,
                evaluator: AppleRuntimeReadinessEvaluator()
            )
            guard !Task.isCancelled else { return }
            draftRuntimeReadiness = readiness
        }
    }

    private func readinessMessage(_ readiness: TranslationReadiness) -> String {
        if readiness.isReady { return "当前可运行" }
        return readiness.issues
            .min { readinessIssuePriority($0.kind) < readinessIssuePriority($1.kind) }?
            .message
            ?? "当前翻译引擎不可运行。"
    }

    private func readinessIssuePriority(_ kind: TranslationReadinessIssue.Kind) -> Int {
        switch kind {
        case .needsConfiguration:
            return 0
        case .pccUnavailable:
            return 1
        case .appleIntelligenceUnavailable:
            return 2
        case .unsupportedLanguagePair:
            return 3
        case .needsRuntimeVerification:
            return 4
        case .needsLanguageDownload:
            return 5
        case .modelUnavailable:
            return 6
        case .needsExecutionAdapter:
            return 7
        }
    }

    private func performAppleSetupAction(_ action: AppleTranslationSetupAction) {
        switch action.kind {
        case .refreshReadiness:
            refreshDraftRuntimeReadiness()
        case .chooseDifferentEngine:
            translationEngineBinding.wrappedValue = .anthropicCompatible
        case .openLanguageSettings, .openAppleIntelligenceSettings:
            openSystemSettings(systemSettingsURL(for: action.kind))
        }
    }

    private func appleSetupActionHelpText(_ kind: AppleTranslationSetupActionKind) -> String {
        switch kind {
        case .refreshReadiness:
            return "只重新检查当前 Apple 翻译运行状态，不会下载语言包或模型"
        case .openLanguageSettings:
            return "打开系统设置，由你在系统里下载语言包；App 不会自动下载"
        case .openAppleIntelligenceSettings:
            return "打开系统设置 > Apple Intelligence 与 Siri，由你查看或启用 Apple Intelligence 和模型准备状态；App 不会自动下载、替换模型或更改系统设置"
        case .chooseDifferentEngine:
            return "把当前设置草稿切换到 Anthropic-compatible；点击「完成」后才保存并生效"
        }
    }

    private func systemSettingsURL(for kind: AppleTranslationSetupActionKind) -> URL? {
        switch kind {
        case .openLanguageSettings, .openAppleIntelligenceSettings:
            return URL(string: "x-apple.systempreferences:")
        case .refreshReadiness, .chooseDifferentEngine:
            return nil
        }
    }

    private func openSystemSettings(_ url: URL?) {
        guard let url else { return }
        #if canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif
    }

    // MARK: - 更新

    @ViewBuilder
    private var updateSection: some View {
        Section("更新") {
            HStack {
                Text("当前版本")
                Spacer()
                Text("v\(updater.currentVersion)")
                    .foregroundStyle(.secondary)
            }
            switch updater.state {
            case .idle, .upToDate:
                HStack {
                    if case .upToDate = updater.state {
                        Label("已是最新版本", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.callout)
                    }
                    Spacer()
                    Button("检查更新") { updater.check() }
                        .buttonStyle(.bordered)
                }
            case .checking:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("正在检查更新")
                    Text("正在检查更新…")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                }
            case .available(let info):
                VStack(alignment: .leading, spacing: 8) {
                    Label("发现新版本 v\(info.version.description)", systemImage: "arrow.down.circle.fill")
                        .foregroundStyle(.blue)
                        .font(.callout.weight(.medium))
                    if !info.notes.isEmpty {
                        DisclosureGroup("更新说明") {
                            Text(info.notes)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .font(.caption)
                    }
                    HStack {
                        Button("下载并更新") { updater.downloadAndInstall(info) }
                            .buttonStyle(.borderedProminent)
                        Button("打开发布页") { NSWorkspace.shared.open(updater.releasesPageURL) }
                            .buttonStyle(.bordered)
                        Spacer()
                    }
                }
            case .downloading(let fraction):
                VStack(alignment: .leading, spacing: 6) {
                    Text("正在下载更新…\(Int(fraction * 100))%")
                        .font(.callout).foregroundStyle(.secondary)
                    ProgressView(value: fraction)
                        .accessibilityLabel("更新下载进度")
                    Button("取消") { updater.cancel() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            case .installing:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("正在安装更新")
                    Text("正在安装，应用稍后会自动重启…")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                }
            case .failed(let reason):
                VStack(alignment: .leading, spacing: 8) {
                    Text(reason)
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("重试") { updater.check() }
                            .buttonStyle(.bordered)
                        Button("去 GitHub 下载") { NSWorkspace.shared.open(updater.releasesPageURL) }
                            .buttonStyle(.bordered)
                        Spacer()
                    }
                }
            }
        }
    }

    // MARK: - 性能

    private var performanceSection: some View {
        Section("性能") {
            Stepper(value: $draft.maxConcurrentDownloads, in: 1...5) {
                HStack {
                    Text("同时下载数")
                    Spacer()
                    Text("\(draft.maxConcurrentDownloads)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Stepper(value: $draft.maxConcurrentBurns, in: 1...3) {
                HStack {
                    Text("同时压制数")
                    Spacer()
                    Text("\(draft.maxConcurrentBurns)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Text("超出上限的任务显示「排队中」自动等待；暂停一个任务会把空位让给下一个。遇到兼容性问题时，实际耗时可能比预计更长。保存后即对新开始的阶段生效。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// 切换协议后清空模型：不同协议/端点的模型列表不同，强制重新「拉取模型」选择，
    /// 避免拿着上一个协议的模型名去撞 503。
    private func clearModelIfNeeded() {
        guard !draft.aiModel.isEmpty else { return }
        draft.aiModel = ""
    }

    /// 任一字段被改动：上一次的测试结果不再可信，回到初始态。
    private func resetTestState() {
        guard testState != .idle else { return }
        testTask?.cancel()
        testState = .idle
    }

    private func runConnectionTest() {
        testTask?.cancel()
        testState = .testing
        // 默认配置编辑的是 ai*；测试连接必须只测默认 AI，而不是当前翻译 override。
        let settings = draft.applyingTranslationConfig(defaultAIConfig)
        testTask = Task {
            do {
                _ = try await testTranslationConnection(settings: settings)
                guard !Task.isCancelled else { return }
                testState = .success
            } catch {
                guard !Task.isCancelled else { return }
                let reason: String
                if case MoongateError.translateFailed(let detail) = error {
                    reason = detail
                } else {
                    reason = error.localizedDescription
                }
                testState = .failure("连接失败：\(reason)")
            }
        }
    }

    private func resetModelFetch() {
        guard modelFetchState != .idle else { return }
        modelFetchTask?.cancel()
        modelFetchState = .idle
    }

    private func fetchModels() {
        modelFetchTask?.cancel()
        modelFetchState = .fetching
        let settings = draft.applyingTranslationConfig(defaultAIConfig)
        modelFetchTask = Task {
            do {
                let models = try await listTranslationModels(settings: settings)
                guard !Task.isCancelled else { return }
                modelFetchState = .loaded(models)
                // 当前模型不在列表里就清空，促使用户从列表选一个网关真有的模型。
                if !draft.aiModel.isEmpty, !models.contains(draft.aiModel) {
                    draft.aiModel = ""
                }
            } catch {
                guard !Task.isCancelled else { return }
                let reason: String
                if case MoongateError.translateFailed(let detail) = error {
                    reason = detail
                } else {
                    reason = error.localizedDescription
                }
                modelFetchState = .failure("拉取失败：\(reason)")
            }
        }
    }

    private var defaultAIConfig: LLMEndpointConfig {
        LLMEndpointConfig(
            engine: draft.aiEngine,
            baseURL: draft.aiBaseURL,
            model: draft.aiModel,
            authToken: draft.aiAuthToken
        )
    }

    // MARK: - 字幕样式

    private var styleSection: some View {
        Section("字幕样式") {
            Picker("中文字幕样式", selection: $draft.subtitleStyle) {
                Text("双语（原文 + 中文）").tag(SubtitleStyle.bilingual)
                Text("仅中文").tag(SubtitleStyle.chineseOnly)
            }
        }
    }

    // MARK: - 烧录画质

    private var burnQualitySection: some View {
        Section("烧录与转码") {
            Picker("编码方式", selection: $draft.encodeBackend) {
                ForEach(EncodeBackend.allCases, id: \.rawValue) { backend in
                    Text(backend.displayName).tag(backend)
                }
            }
            Text(encodeBackendHint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("烧录编码", selection: Binding(
                get: { draft.burnAlwaysH264 },
                set: { draft.burnAlwaysH264 = $0 }
            )) {
                Text("跟随源（HEVC 源保 HEVC）").tag(false)
                Text("始终 H.264（兼容最好）").tag(true)
            }
            Text("「始终 H.264」体积略大但几乎所有设备/网页都能播；「跟随源」保留 HEVC/HDR 画质与更小体积。HDR 源在跟随源时保留 HDR。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                Toggle(
                    "高清视频烧录时缩放到 1080p（更快更省空间，推荐）",
                    isOn: Binding(
                        get: { draft.maxBurnHeight != nil },
                        set: { draft.maxBurnHeight = $0 ? 1080 : nil }
                    )
                )
                Text("关闭则按源分辨率烧录（4K 会明显更慢、文件更大）。此设置只影响烧录字幕，不影响普通下载。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var encodeBackendHint: String {
        switch draft.encodeBackend {
        case .auto:
            return "优先用 Mac 的硬件媒体引擎编码。遇到源文件或系统兼容性问题时，实际耗时可能比预计更长。"
        case .hardware:
            return "优先使用硬件媒体引擎（VideoToolbox）。个别老机型或特殊格式可能需要兼容处理，实际耗时可能更长。"
        case .software:
            return "使用兼容性更稳定的编码路径。同等体积画质更稳，但 4K 和 HDR 任务通常更慢。"
        }
    }

    // MARK: - 站点登录

    private var loginSection: some View {
        Section("站点登录") {
            Text(loginStatusText)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("登录 YouTube") {
                    requestLogin(site: "youtube.com")
                }
                Button("登录哔哩哔哩") {
                    requestLogin(site: "bilibili.com")
                }
            }
            HStack(spacing: 10) {
                Button("清除本 App 登录信息", role: .destructive) {
                    showClearConfirm = true
                }
                .accessibilityHint(clearLoginHelpText)
                .buttonStyle(.bordered)
                .disabled(cookieDate == nil)
                if let feedback = clearFeedback {
                    Text(feedback)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .confirmationDialog(
                "清除本 App 保存的登录信息？",
                isPresented: $showClearConfirm
            ) {
                Button("清除登录信息", role: .destructive) {
                    clearAllLogins()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text(clearLoginHelpText)
            }
        }
    }

    private var clearLoginHelpText: String {
        "只清除本 App 保存的站点登录信息，不会退出浏览器或系统账号；需要重新登录才能下载会员/受限视频。"
    }

    private var loginStatusText: String {
        guard let cookieDate else { return "尚未登录任何站点" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return "已保存登录信息（\(formatter.string(from: cookieDate))导出）"
    }

    /// 登录状态行的数据源：cookies.txt 的修改日期。
    private func refreshLoginStatus() {
        let path = AppSettings.cookieFileURL.path
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        cookieDate = attributes?[.modificationDate] as? Date
    }

    /// 点「登录 ××」：先把草稿保存下来再走登录流程（设置窗即将收起）。
    private func requestLogin(site: String) {
        clearFeedback = nil
        model.settings = draft
        model.requestLogin(site: site)
    }

    /// 点「配置依赖」：与登录一致，先回写草稿再走依赖流程。
    /// 否则设置窗 onDisappear 会用磁盘值覆盖 model.settings，丢掉未保存的编辑。
    private func requestDependencySetup() {
        model.settings = draft
        model.requestDependencySetup()
    }

    private func clearAllLogins() {
        clearFeedback = nil
        NetscapeCookieFile.clear(at: AppSettings.cookieFileURL)
        WKWebsiteDataStore.default().removeData(
            ofTypes: [WKWebsiteDataTypeCookies, WKWebsiteDataTypeLocalStorage,
                      WKWebsiteDataTypeIndexedDBDatabases, WKWebsiteDataTypeSessionStorage],
            modifiedSince: .distantPast
        ) {
            clearFeedback = "已清除"
            refreshLoginStatus()
        }
    }

    // MARK: - 底栏

    private var bottomBar: some View {
        HStack(spacing: 10) {
            if let notice = model.settingsNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
            Spacer()
            Button("取消") {
                model.showSettings = false
            }
            .buttonStyle(.bordered)
            .keyboardShortcut(.cancelAction)
            Button("完成") {
                model.settings = draft
                if model.saveSettings() {
                    model.showSettings = false
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - 可复用的 API 端点编辑器（拉取模型 + 测试连接）

enum APIConnectionTestState: Equatable {
    case idle
    case testing
    case success
    case failure(String)
}

enum APIModelFetchState: Equatable {
    case idle
    case fetching
    case loaded([String])
    case failure(String)
}

/// 一个云端 API 引擎（Anthropic/OpenAI 兼容）的服务地址 + 凭证 + 模型编辑块，
/// 自带「拉取模型」和「测试连接」。AI 翻译、AI 总结的「单独配置」复用它，行为与主
/// 「AI 设置」一致：先填地址+凭证，点「拉取模型」从服务端取真实列表再选，再「测试连接」。
struct APIConfigEditor: View {
    @Binding var baseURL: String
    @Binding var model: String
    @Binding var authToken: String
    /// 把编辑中的字段组装成一份可直接调用的 settings（用于拉取模型 / 测试连接）。
    let settingsForRequest: () -> AppSettings
    let baseURLPrompt: String
    let modelPrompt: String

    @State private var testState: APIConnectionTestState = .idle
    @State private var testTask: Task<Void, Never>?
    @State private var modelFetchState: APIModelFetchState = .idle
    @State private var modelFetchTask: Task<Void, Never>?

    var body: some View {
        TextField("服务地址", text: $baseURL, prompt: Text(baseURLPrompt))
            .autocorrectionDisabled()
            .onChange(of: baseURL) { resetTestState(); resetModelFetch() }
        SecureField("API 凭证", text: $authToken)
            .onChange(of: authToken) { resetTestState(); resetModelFetch() }
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button("拉取模型") { fetchModels() }
                .buttonStyle(.bordered)
                .disabled(modelFetchState == .fetching
                    || baseURL.trimmingCharacters(in: .whitespaces).isEmpty
                    || authToken.trimmingCharacters(in: .whitespaces).isEmpty)
            switch modelFetchState {
            case .idle:
                EmptyView()
            case .fetching:
                ProgressView().controlSize(.small)
                    .accessibilityLabel("正在拉取模型")
            case .loaded(let models):
                Text("已拉取 \(models.count) 个模型")
                    .font(.caption).foregroundStyle(.secondary)
            case .failure(let message):
                Text(message)
                    .font(.caption).foregroundStyle(.red).lineLimit(3)
            }
            Spacer(minLength: 0)
        }
        if case .loaded(let models) = modelFetchState, !models.isEmpty {
            let current = model
            let options = (current.isEmpty || models.contains(current)) ? models : models + [current]
            Picker("选择模型", selection: $model) {
                Text("请选择").tag("")
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.menu)
        }
        TextField("模型名（也可手动填写）", text: $model, prompt: Text(modelPrompt))
            .autocorrectionDisabled()
            .onChange(of: model) { resetTestState() }
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button("测试连接") { runConnectionTest() }
                .buttonStyle(.bordered)
                .disabled(testState == .testing
                    || baseURL.trimmingCharacters(in: .whitespaces).isEmpty
                    || authToken.trimmingCharacters(in: .whitespaces).isEmpty
                    || model.trimmingCharacters(in: .whitespaces).isEmpty)
            switch testState {
            case .idle:
                EmptyView()
            case .testing:
                ProgressView().controlSize(.small)
                    .accessibilityLabel("正在测试连接")
            case .success:
                Text("连接正常").font(.caption).foregroundStyle(.green)
            case .failure(let message):
                Text(message).font(.caption).foregroundStyle(.red).lineLimit(3)
            }
            Spacer(minLength: 0)
        }
        .onDisappear {
            testTask?.cancel()
            modelFetchTask?.cancel()
        }
    }

    private func resetTestState() {
        guard testState != .idle else { return }
        testTask?.cancel()
        testState = .idle
    }

    private func resetModelFetch() {
        guard modelFetchState != .idle else { return }
        modelFetchTask?.cancel()
        modelFetchState = .idle
    }

    private func fetchModels() {
        modelFetchTask?.cancel()
        modelFetchState = .fetching
        let settings = settingsForRequest()
        modelFetchTask = Task {
            do {
                let models = try await listTranslationModels(settings: settings)
                guard !Task.isCancelled else { return }
                modelFetchState = .loaded(models)
                if !model.isEmpty, !models.contains(model) { model = "" }
            } catch {
                guard !Task.isCancelled else { return }
                modelFetchState = .failure("拉取失败：\(Self.reason(error))")
            }
        }
    }

    private func runConnectionTest() {
        testTask?.cancel()
        testState = .testing
        let settings = settingsForRequest()
        testTask = Task {
            do {
                _ = try await testTranslationConnection(settings: settings)
                guard !Task.isCancelled else { return }
                testState = .success
            } catch {
                guard !Task.isCancelled else { return }
                testState = .failure("连接失败：\(Self.reason(error))")
            }
        }
    }

    private static func reason(_ error: Error) -> String {
        if case MoongateError.translateFailed(let detail) = error { return detail }
        return error.localizedDescription
    }
}
