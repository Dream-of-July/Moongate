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
    @EnvironmentObject private var localizer: Localizer

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

    private let appleTranslationSourceLanguages = ["en", "ja", "ko", "zh-Hans", "zh-Hant"]

    init(model: ViewModel) {
        self.model = model
        self._updater = ObservedObject(wrappedValue: model.updater)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                languageSection
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
            .onChange(of: draft.appLanguage) {
                localizer.setLanguage(AppLanguage(rawValue: draft.appLanguage) ?? .auto)
            }
            .onChange(of: draft.translationTargetLanguage) {
                refreshDraftRuntimeReadiness()
            }
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
            localizer.setLanguage(AppLanguage(rawValue: model.settings.appLanguage) ?? .auto)
        }
    }

    // MARK: - 语言

    private var languageSection: some View {
        Section(localizer.t(L.Settings.languageSection)) {
            Picker(localizer.t(L.Settings.appLanguage), selection: $draft.appLanguage) {
                Text(localizer.t(L.Settings.followSystem)).tag("auto")
                Text(localizer.t(L.Settings.langHans)).tag("zh-Hans")
                Text(localizer.t(L.Settings.langHant)).tag("zh-Hant")
                Text(localizer.t(L.Settings.langEn)).tag("en")
            }
            Picker(localizer.t(L.Settings.targetLanguage), selection: $draft.translationTargetLanguage) {
                Text(localizer.t(L.Settings.langHans)).tag("zh-Hans")
                Text(localizer.t(L.Settings.langHant)).tag("zh-Hant")
                Text(localizer.t(L.Settings.langEn)).tag("en")
            }
            Text(localizer.t(L.Settings.languageHelp))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 依赖组件

    private var dependencyAllReady: Bool {
        dependencyChecked && !DependencySetup.needsSetup(dependencyComponents)
    }

    private var dependencySummaryText: String {
        if !dependencyChecked { return localizer.t(L.Dependency.summaryChecking) }
        return DependencySetup.needsSetup(dependencyComponents)
            ? localizer.t(L.Dependency.summaryMissing)
            : localizer.t(L.Dependency.summaryReady)
    }

    private var dependencySection: some View {
        Section {
            DisclosureGroup(isExpanded: $dependencyExpanded) {
                if !dependencyChecked {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                            .accessibilityLabel(localizer.t(L.Dependency.checkingAccessibility))
                        Text(localizer.t(L.Dependency.summaryChecking))
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
                                Text(componentPurposeText(component))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(componentReadyText(component))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(componentAccessibilityLabel(component))
                        .accessibilityValue(componentReadyText(component))
                    }

                    HStack(spacing: 10) {
                        Button(localizer.t(L.Dependency.refresh)) {
                            Task { await refreshDependencies() }
                        }
                        .buttonStyle(.bordered)
                        Button(DependencySetup.needsSetup(dependencyComponents) ? localizer.t(L.Dependency.setupMissing) : localizer.t(L.Dependency.setupReady)) {
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
                    Text(localizer.t(L.Dependency.sectionTitle))
                    Spacer()
                    Text(dependencySummaryText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(localizer.t(L.Dependency.sectionTitle))
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
        localizer.t(L.Dependency.componentAccessibilityLabel, component.id, componentPurposeText(component))
    }

    private func componentPurposeText(_ component: DependencySetup.Component) -> String {
        switch component.id {
        case "yt-dlp": return localizer.t(L.Dependency.purposeYtDlp)
        case "ffmpeg": return localizer.t(L.Dependency.purposeFfmpeg)
        case "deno": return localizer.t(L.Dependency.purposeDeno)
        default: return component.purpose
        }
    }

    private func componentReadyText(_ component: DependencySetup.Component) -> String {
        component.isInstalled ? localizer.t(L.Dependency.statusReady) : localizer.t(L.Dependency.statusPending)
    }

    // MARK: - AI 设置（翻译/总结共享的默认配置 + 各自跟随/单独开关）

    private var translationSection: some View {
        Section(localizer.t(L.Settings.aiSettingsSection)) {
            Text(localizer.t(L.Settings.aiSettingsDescription))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker(localizer.t(L.Settings.aiEngine), selection: translationEngineBinding) {
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
        Section(localizer.t(L.Settings.aiTranslationSection)) {
            Toggle(localizer.t(L.Settings.smartTranslationPrompts), isOn: $draft.smartTranslationPromptsEnabled)
            Text(localizer.t(L.Settings.smartTranslationPromptsHelp))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker(localizer.t(L.Settings.configMode), selection: Binding(
                get: { draft.translationFollowsDefault },
                set: { draft.translationFollowsDefault = $0 }
            )) {
                Text(localizer.t(L.Settings.followAISettings)).tag(true)
                Text(localizer.t(L.Settings.configureSeparately)).tag(false)
            }
            .pickerStyle(.menu)
            if !draft.translationFollowsDefault {
                Picker(localizer.t(L.Settings.translationEngine), selection: $draft.translationEngine) {
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
                        modelPrompt: localizer.t(L.Settings.modelPromptEmpty)
                    )
                } else {
                    Text(localizer.t(L.Settings.localEngineNoCredentials))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - AI 总结（默认跟随，可单独配置）

    private var summarySection: some View {
        Section(localizer.t(L.Settings.aiSummarySection)) {
            Picker(localizer.t(L.Settings.configMode), selection: Binding(
                get: { draft.summaryFollowsDefault },
                set: { draft.summaryFollowsDefault = $0 }
            )) {
                Text(localizer.t(L.Settings.followAISettings)).tag(true)
                Text(localizer.t(L.Settings.configureSeparately)).tag(false)
            }
            .pickerStyle(.menu)
            if draft.summaryFollowsDefault {
                if !draft.aiEngine.canGenerateText {
                    Text(localizer.t(L.Settings.defaultEngineCannotSummarize))
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
        Picker(localizer.t(L.Settings.summaryEngine), selection: $draft.summaryEngine) {
            ForEach(TranslationEngine.allCases, id: \.rawValue) { engine in
                Text(engine.displayName).tag(engine)
            }
        }
        if !draft.summaryEngine.canGenerateText {
            Text(localizer.t(L.Settings.engineCannotSummarize))
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
                modelPrompt: localizer.t(L.Settings.modelPromptEmpty)
            )
        } else {
            Text(localizer.t(L.Settings.localEngineNoCredentials))
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
            localizer.t(L.Settings.serviceURL),
            text: $draft.aiBaseURL,
            prompt: Text(baseURLPrompt)
        )
        .autocorrectionDisabled()
        VStack(alignment: .leading, spacing: 4) {
            SecureField(localizer.t(L.Settings.apiCredential), text: $draft.aiAuthToken)
            Text(credentialSummaryText)
                .font(.caption)
                .foregroundStyle(.secondary)
            DisclosureGroup(localizer.t(L.Settings.advancedDetails)) {
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
            Button(localizer.t(L.Settings.fetchModels)) { fetchModels() }
                .buttonStyle(.bordered)
                .disabled(modelFetchState == .fetching
                    || draft.aiBaseURL.trimmingCharacters(in: .whitespaces).isEmpty
                    || draft.aiAuthToken.trimmingCharacters(in: .whitespaces).isEmpty)
            switch modelFetchState {
            case .idle:
                EmptyView()
            case .fetching:
                ProgressView().controlSize(.small)
                    .accessibilityLabel(localizer.t(L.Settings.fetchingModels))
            case .loaded(let models):
                Text(localizer.t(L.Settings.fetchedModels, models.count))
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
            Picker(localizer.t(L.Settings.selectModel), selection: $draft.aiModel) {
                Text(localizer.t(L.Settings.pleaseSelect)).tag("")
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.menu)
        }
        // 拉不到列表时仍允许手填
        TextField(
            localizer.t(L.Settings.modelName),
            text: $draft.aiModel,
            prompt: Text(modelPrompt)
        )
        .autocorrectionDisabled()
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button(localizer.t(L.Settings.testConnection)) {
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
                    .accessibilityLabel(localizer.t(L.Settings.testingConnection))
            case .success:
                Text(localizer.t(L.Settings.connectionOK))
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
        let statusText = readiness.isReady ? localizer.t(L.Settings.statusReady) : localizer.t(L.Settings.statusNeedsAction)
        return VStack(alignment: .leading, spacing: 6) {
            Text(draft.aiEngine.readinessGuidance)
                .font(.caption)
                .foregroundStyle(.secondary)
            if shouldShowAppleTranslationSourceLanguagePicker {
                Picker(localizer.t(L.Settings.sourceLanguage), selection: $appleTranslationSourceLanguage) {
                    ForEach(appleTranslationSourceLanguages, id: \.self) { code in
                        Text(appleTranslationSourceLanguageLabel(code)).tag(code)
                    }
                }
                .pickerStyle(.menu)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(localizer.t(L.Settings.currentEngine))
                        .foregroundStyle(.secondary)
                    Text(draft.aiEngine.displayName)
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(localizer.t(L.Settings.status))
                        .foregroundStyle(.secondary)
                    Text(statusText)
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(localizer.t(L.Settings.primaryReason))
                        .foregroundStyle(.secondary)
                    Text(readinessMessage(readiness))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
            // 只把只读状态合并成单个朗读元素；源语言 Picker 与恢复按钮必须保持可独立聚焦/激活。
            .accessibilityElement(children: .combine)
            .accessibilityLabel(localizer.t(L.Settings.appleTranslationStatus))
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
            return draft.makeTranslationContext(sourceLanguage: nil)
        }
        return draft.makeTranslationContext(sourceLanguage: appleTranslationSourceLanguage)
    }

    private var fallbackEngineText: String {
        localizer.t(L.Settings.fallbackEngine)
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
                .accessibilityHint(localizer.t(L.Settings.fallbackEngineHint))
            if !guidance.actions.isEmpty {
                HStack(spacing: 8) {
                    ForEach(guidance.actions) { action in
                        Button(appleSetupActionTitle(action.kind)) {
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
            return localizer.t(L.Settings.baseURLPromptAnthropic)
        case .openai:
            return "https://api.openai.com"
        }
    }

    private var modelPrompt: String {
        switch apiProvider {
        case .anthropic:
            return localizer.t(L.Settings.modelPromptEmpty)
        case .openai:
            return localizer.t(L.Settings.modelPromptEmpty)
        }
    }

    private var credentialSummaryText: String {
        localizer.t(L.Settings.credentialSummary)
    }

    private var credentialDetailText: String {
        switch apiProvider {
        case .anthropic:
            return localizer.t(L.Settings.credentialDetailAnthropic)
        case .openai:
            return localizer.t(L.Settings.credentialDetailOpenAI)
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
        case .anthropic: return localizer.t(L.Settings.baseURLPromptAnthropic)
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
        if readiness.isReady { return localizer.t(L.Settings.statusReady) }
        return readiness.issues
            .min { readinessIssuePriority($0.kind) < readinessIssuePriority($1.kind) }?
            .message
            ?? localizer.t(L.Settings.readinessUnavailable)
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
            return localizer.t(L.Settings.appleActionRefreshHelp)
        case .openLanguageSettings:
            return localizer.t(L.Settings.appleActionOpenLanguageSettingsHelp)
        case .openAppleIntelligenceSettings:
            return localizer.t(L.Settings.appleActionOpenAppleIntelligenceSettingsHelp)
        case .chooseDifferentEngine:
            return localizer.t(L.Settings.appleActionChooseDifferentEngineHelp)
        }
    }

    private func appleSetupActionTitle(_ kind: AppleTranslationSetupActionKind) -> String {
        switch kind {
        case .refreshReadiness:
            return localizer.t(L.Settings.appleActionRefresh)
        case .openLanguageSettings:
            return localizer.t(L.Settings.appleActionOpenLanguageSettings)
        case .openAppleIntelligenceSettings:
            return localizer.t(L.Settings.appleActionOpenAppleIntelligenceSettings)
        case .chooseDifferentEngine:
            return localizer.t(L.Settings.appleActionChooseDifferentEngine)
        }
    }

    private func appleTranslationSourceLanguageLabel(_ code: String) -> String {
        switch code {
        case "en":
            return localizer.t(L.Settings.sourceEnglish)
        case "ja":
            return localizer.t(L.Settings.sourceJapanese)
        case "ko":
            return localizer.t(L.Settings.sourceKorean)
        case "zh-Hans":
            return localizer.t(L.Settings.langHans)
        case "zh-Hant":
            return localizer.t(L.Settings.langHant)
        default:
            return code
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
        Section(localizer.t(L.Update.sectionTitle)) {
            HStack {
                Text(localizer.t(L.Update.currentVersion))
                Spacer()
                Text("v\(updater.currentVersion)")
                    .foregroundStyle(.secondary)
            }
            switch updater.state {
            case .idle:
                HStack {
                    Spacer()
                    Button(localizer.t(L.Update.check)) {
                        startUpdateCheckFromSettings()
                    }
                        .buttonStyle(.bordered)
                        .disabled(!updater.canCheckForUpdates)
                    Button(localizer.t(L.Update.openReleases)) {
                        updater.openReleasesPage()
                    }
                        .buttonStyle(.bordered)
                    Spacer()
                }
            case .failed(let reason):
                VStack(alignment: .leading, spacing: 8) {
                    Text(reason)
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button(localizer.t(L.Common.retry)) {
                            startUpdateCheckFromSettings()
                        }
                            .buttonStyle(.bordered)
                            .disabled(!updater.canCheckForUpdates)
                        Button(localizer.t(L.Update.openGitHubDownload)) {
                            updater.openReleasesPage()
                        }
                            .buttonStyle(.bordered)
                        Spacer()
                    }
                }
            }
        }
    }

    private func startUpdateCheckFromSettings() {
        if model.queue.openTaskCount > 0 {
            updater.blockInstallDueToOpenTasks(count: model.queue.openTaskCount)
            return
        }
        model.showSettings = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            updater.checkForUpdates()
        }
    }

    // MARK: - 性能

    private var performanceSection: some View {
        Section(localizer.t(L.Settings.performanceSection)) {
            Stepper(value: $draft.maxConcurrentDownloads, in: 1...5) {
                HStack {
                    Text(localizer.t(L.Settings.concurrentDownloads))
                    Spacer()
                    Text("\(draft.maxConcurrentDownloads)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Stepper(value: $draft.maxConcurrentBurns, in: 1...3) {
                HStack {
                    Text(localizer.t(L.Settings.concurrentBurns))
                    Spacer()
                    Text("\(draft.maxConcurrentBurns)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Text(localizer.t(L.Settings.performanceHelp))
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
                testState = .failure(localizer.t(L.Settings.connectionFailed, reason))
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
                modelFetchState = .failure(localizer.t(L.Settings.fetchFailed, reason))
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
        Section(localizer.t(L.Settings.styleSection)) {
            Picker(localizer.t(L.Settings.subtitleStyle), selection: $draft.subtitleStyle) {
                Text(localizer.t(L.Settings.subtitleStyleBilingual)).tag(SubtitleStyle.bilingual)
                Text(localizer.t(L.Settings.subtitleStyleChineseOnly)).tag(SubtitleStyle.chineseOnly)
            }
        }
    }

    // MARK: - 烧录画质

    private var burnQualitySection: some View {
        Section(localizer.t(L.Settings.burnSection)) {
            Picker(localizer.t(L.Settings.encodeBackend), selection: $draft.encodeBackend) {
                ForEach(EncodeBackend.allCases, id: \.rawValue) { backend in
                    Text(backend.displayName).tag(backend)
                }
            }
            Text(encodeBackendHint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker(localizer.t(L.Settings.burnEncoding), selection: Binding(
                get: { draft.burnAlwaysH264 },
                set: { draft.burnAlwaysH264 = $0 }
            )) {
                Text(localizer.t(L.Settings.followSourceHEVC)).tag(false)
                Text(localizer.t(L.Settings.alwaysH264)).tag(true)
            }
            Text(localizer.t(L.Settings.burnEncodingHelp))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                Toggle(
                    localizer.t(L.Settings.scaleHD1080),
                    isOn: Binding(
                        get: { draft.maxBurnHeight != nil },
                        set: { draft.maxBurnHeight = $0 ? 1080 : nil }
                    )
                )
                Text(localizer.t(L.Settings.scaleHD1080Help))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var encodeBackendHint: String {
        switch draft.encodeBackend {
        case .auto:
            return localizer.t(L.Settings.encodeAutoHint)
        case .hardware:
            return localizer.t(L.Settings.encodeHardwareHint)
        case .software:
            return localizer.t(L.Settings.encodeSoftwareHint)
        }
    }

    // MARK: - 站点登录

    private var loginSection: some View {
        Section(localizer.t(L.Settings.loginSection)) {
            Text(loginStatusText)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button(localizer.t(L.Settings.loginYouTube)) {
                    requestLogin(site: "youtube.com")
                }
                Button(localizer.t(L.Settings.loginBilibili)) {
                    requestLogin(site: "bilibili.com")
                }
            }
            HStack(spacing: 10) {
                Button(localizer.t(L.Settings.clearAppLogin), role: .destructive) {
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
                localizer.t(L.Settings.clearLoginDialogTitle),
                isPresented: $showClearConfirm
            ) {
                Button(localizer.t(L.Settings.clearLoginAction), role: .destructive) {
                    clearAllLogins()
                }
                Button(localizer.t(L.Common.cancel), role: .cancel) {}
            } message: {
                Text(clearLoginHelpText)
            }
        }
    }

    private var clearLoginHelpText: String {
        localizer.t(L.Settings.clearLoginHelp)
    }

    private var loginStatusText: String {
        guard let cookieDate else { return localizer.t(L.Settings.loginNone) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: settingsDateLocaleIdentifier)
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return localizer.t(L.Settings.loginSaved, formatter.string(from: cookieDate))
    }

    private var settingsDateLocaleIdentifier: String {
        switch localizer.resolved {
        case .en: return "en_US"
        case .zhHans: return "zh_CN"
        case .zhHant: return "zh_TW"
        }
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
            clearFeedback = localizer.t(L.Settings.cleared)
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
            Button(localizer.t(L.Common.cancel)) {
                model.showSettings = false
            }
            .buttonStyle(.bordered)
            .keyboardShortcut(.cancelAction)
            Button(localizer.t(L.Common.done)) {
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
    @EnvironmentObject private var localizer: Localizer

    var body: some View {
        TextField(localizer.t(L.Settings.serviceURL), text: $baseURL, prompt: Text(baseURLPrompt))
            .autocorrectionDisabled()
            .onChange(of: baseURL) { resetTestState(); resetModelFetch() }
        SecureField(localizer.t(L.Settings.apiCredential), text: $authToken)
            .onChange(of: authToken) { resetTestState(); resetModelFetch() }
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button(localizer.t(L.Settings.fetchModels)) { fetchModels() }
                .buttonStyle(.bordered)
                .disabled(modelFetchState == .fetching
                    || baseURL.trimmingCharacters(in: .whitespaces).isEmpty
                    || authToken.trimmingCharacters(in: .whitespaces).isEmpty)
            switch modelFetchState {
            case .idle:
                EmptyView()
            case .fetching:
                ProgressView().controlSize(.small)
                    .accessibilityLabel(localizer.t(L.Settings.fetchingModels))
            case .loaded(let models):
                Text(localizer.t(L.Settings.fetchedModels, models.count))
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
            Picker(localizer.t(L.Settings.selectModel), selection: $model) {
                Text(localizer.t(L.Settings.pleaseSelect)).tag("")
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.menu)
        }
        TextField(localizer.t(L.Settings.modelName), text: $model, prompt: Text(modelPrompt))
            .autocorrectionDisabled()
            .onChange(of: model) { resetTestState() }
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button(localizer.t(L.Settings.testConnection)) { runConnectionTest() }
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
                    .accessibilityLabel(localizer.t(L.Settings.testingConnection))
            case .success:
                Text(localizer.t(L.Settings.connectionOK)).font(.caption).foregroundStyle(.green)
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
                modelFetchState = .failure(localizer.t(L.Settings.fetchFailed, Self.reason(error)))
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
                testState = .failure(localizer.t(L.Settings.connectionFailed, Self.reason(error)))
            }
        }
    }

    private static func reason(_ error: Error) -> String {
        if case MoongateError.translateFailed(let detail) = error { return detail }
        return error.localizedDescription
    }
}
