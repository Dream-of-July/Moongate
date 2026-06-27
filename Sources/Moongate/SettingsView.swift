import SwiftUI
import WebKit
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif
#if canImport(MoongateCore)
import MoongateCore
#endif

private enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case subtitles
    case localSpeech
    case aiServices
    case videoOutput
    case siteLogin
    case components
    case updates

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .subtitles: return "captions.bubble"
        case .localSpeech: return "waveform"
        case .aiServices: return "sparkles"
        case .videoOutput: return "film"
        case .siteLogin: return "person.crop.circle.badge.checkmark"
        case .components: return "externaldrive"
        case .updates: return "arrow.down.circle"
        }
    }

    @MainActor
    func title(_ localizer: Localizer) -> String {
        switch self {
        case .general: return localizer.t(L.Settings.paneGeneral)
        case .subtitles: return localizer.t(L.Settings.paneSubtitles)
        case .localSpeech: return localizer.t(L.Settings.paneLocalSpeech)
        case .aiServices: return localizer.t(L.Settings.paneAIServices)
        case .videoOutput: return localizer.t(L.Settings.paneVideoOutput)
        case .siteLogin: return localizer.t(L.Settings.paneSiteLogin)
        case .components: return localizer.t(L.Settings.paneComponents)
        case .updates: return localizer.t(L.Settings.paneUpdates)
        }
    }
}

/// 独立设置窗口：通用、字幕与翻译、本地语音识别、AI 服务、视频与输出、站点登录、组件与存储、更新与关于。
/// 实时同步：draft 仅作输入缓冲，onChange 即通过 persistDraftLive 落盘，无「完成 / 取消」按钮（红灯关闭即可）。
struct SettingsView: View {
    @ObservedObject var model: ViewModel
    @EnvironmentObject private var localizer: Localizer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
    @State private var draftRuntimeReadiness: TranslationReadiness?
    @State private var draftRuntimeReadinessTask: Task<Void, Never>?
    @State private var appleTranslationSourceLanguage = "en"
    @State private var selectedPane: SettingsPane? = .general
    @State private var localASRModelCatalogVersion = 0
    @State private var localASRInstallingModelID: String?
    @State private var localASRModelInstallProgress: Double?

    private let appleTranslationSourceLanguages = ["en", "ja", "ko", "zh-Hans", "zh-Hant"]

    init(model: ViewModel) {
        self.model = model
        self._updater = ObservedObject(wrappedValue: model.updater)
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $selectedPane) { pane in
                settingsPaneRow(pane)
                    .tag(pane)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 240)
        } detail: {
            settingsPaneDetail
                .safeAreaInset(edge: .bottom) {
                    if let notice = model.settingsNotice {
                        HStack(spacing: 8) {
                            Image(systemName: "info.circle")
                                .foregroundStyle(.orange)
                            Text(notice)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.bar)
                    }
                }
        }
        .frame(minWidth: 760, idealWidth: 820, maxWidth: 860, minHeight: 560, idealHeight: 640)
        // 实时同步：草稿任何字段变化即写回 model.settings 并保存（不再需要「完成」按钮）。
        .onChange(of: draft) { _, newValue in
            persistDraftLive(newValue)
        }
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
        .onAppear {
            // 打开设置即补齐凭证，使 SecureField 显示已存 Token、连接测试/拉模型可用。
            model.hydrateCredentials()
            draft = model.settings
            applyPendingSettingsPane()
            refreshLoginStatus()
            refreshDraftRuntimeReadiness()
        }
        .onChange(of: model.pendingSettingsPaneID) { applyPendingSettingsPane() }
        .task {
            await refreshDependencies()
        }
        .task {
            // 后台更新检查由 Sparkle 调度驱动（见 UpdateService / Info.plist）；打开设置不强制立即检查。
            model.checkForUpdatesIfNeeded()
        }
        .onDisappear {
            testTask?.cancel()
            modelFetchTask?.cancel()
            draftRuntimeReadinessTask?.cancel()
            // 实时保存模式：关闭即同步（兜底再保存一次，确保最后一次编辑落盘）。
            persistDraftLive(draft)
        }
    }

    /// 实时把草稿写回 model.settings 并持久化。语言变化已由 onChange(draft.appLanguage) 即时反映到 UI。
    private func persistDraftLive(_ newValue: AppSettings) {
        guard model.settings != newValue else { return }
        model.settings = newValue
        model.saveSettings()
    }

    private func applyPendingSettingsPane() {
        guard let paneID = model.pendingSettingsPaneID,
              let pane = SettingsPane(rawValue: paneID) else { return }
        selectedPane = pane
        model.pendingSettingsPaneID = nil
    }

    @ViewBuilder
    private var settingsPaneDetail: some View {
        Form {
            switch selectedPane ?? .general {
            case .general:
                languageSection
                notificationsSection
            case .subtitles:
                translationConfigSection
                styleSection
            case .localSpeech:
                localSpeechSection
            case .aiServices:
                translationSection
                summarySection
            case .videoOutput:
                burnQualitySection
                performanceSection
            case .siteLogin:
                loginSection
            case .components:
                dependencySection
                storageSection
            case .updates:
                updateSection
                aboutSection
            }
        }
        .formStyle(.grouped)
        .navigationTitle((selectedPane ?? .general).title(localizer))
    }

    private func settingsPaneRow(_ pane: SettingsPane) -> some View {
        HStack(spacing: 8) {
            Label(pane.title(localizer), systemImage: pane.systemImage)
            Spacer()
            if pane == .updates && updater.updateAvailable {
                settingsUpdateBadge
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(pane.title(localizer))
        .accessibilityValue(pane == .updates && updater.updateAvailable ? localizer.t(L.Update.updateAvailableStatus) : "")
    }

    // 有更新可用：App Store 式红色数字角标（七月明确要求“数字 1 / 类似通知”）。
    // 布尔“有更新”以 1 表示“一项待处理更新”，与 Windows 更新页角标保持一致。
    private var settingsUpdateBadge: some View {
        Text("1")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 16, height: 16)
            .background(Circle().fill(.red))
            .accessibilityHidden(true)
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
            Picker(localizer.t(L.Settings.defaultSourceLanguage), selection: $draft.preferredSourceLanguage) {
                ForEach(ViewModel.sourceLanguagePreferenceOptions) { option in
                    Text(preferredSourceLanguageLabel(option.code)).tag(option.code)
                }
            }
            Text(localizer.t(L.Settings.languageHelp))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func preferredSourceLanguageLabel(_ code: String) -> String {
        if code == "auto" {
            return localizer.t(L.Ready.sourceLanguageAuto)
        }
        return TranslationLanguage.sourceDisplayName(for: code) ?? code
    }

    // MARK: - 本地语音识别

    private enum LocalASRSetupState: Equatable {
        case disabled
        case ready(runtimePath: String)
        case missingRuntime
        case missingModel
        case badHash
        case downloading(modelName: String)
    }

    @ViewBuilder
    private var localSpeechSection: some View {
        Section {
            Toggle(localizer.t(L.Settings.localASREnabled), isOn: $draft.localASREnabled)
            Text(localizer.t(L.Settings.localASRHelp))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            LocalASRSetupStatusView(state: localASRSetupState)
            if draft.localASREnabled {
                LocalASRVADStatusView(vadModelURL: localASRVADModelURL)
                Toggle(localizer.t(L.Settings.localASRPreciseModeEnabled), isOn: $draft.localASRPreciseModeEnabled)
                Text(localizer.t(L.Settings.localASRPreciseModeHelp))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if draft.localASRPreciseModeEnabled {
                    TextField(localizer.t(L.Settings.localASRSidecarRuntimePath), text: $draft.localASRSidecarRuntimePath)
                        .textContentType(.none)
                        .help(localizer.t(L.Settings.localASRSidecarRuntimePathPrompt))
                    TextField(localizer.t(L.Settings.localASRSidecarModelPath), text: $draft.localASRSidecarModelPath)
                        .textContentType(.none)
                        .help(localizer.t(L.Settings.localASRSidecarModelPathPrompt))
                    Text(localASRSidecarReadinessText)
                        .font(.caption)
                        .foregroundStyle(draft.isLocalASRSidecarConfigured ? .green : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            Text(localizer.t(L.Settings.localASRSection))
        }

        cloudASRSection

        // Recommended models.
        Section {
            let recommended = recommendedModelForDevice()

            if importedLocalASRModelURL != nil {
                importedLocalASRModelRow()
                Divider()
            }

            ForEach(localASRModelCatalogEntries, id: \.id) { entry in
                localASRModelRow(entry, isRecommended: entry.id == recommended?.id)
            }
        } header: {
            LocalASRModelListHeader(
                title: localizer.t(L.Settings.localASRRecommendedModels),
                importTitle: localizer.t(L.Settings.localASRImportModel),
                importAction: importLocalASRModel
            )
        }
    }

    private var cloudASRSection: some View {
        Section {
            Toggle(localizer.t(L.Settings.cloudASREnabled), isOn: $draft.cloudASREnabled)
            Text(localizer.t(L.Settings.cloudASRPrivacyNotice))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(localizer.t(L.Settings.cloudASRCostNotice))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if draft.cloudASREnabled {
                TextField(localizer.t(L.Settings.cloudASRBaseURL), text: $draft.cloudASRBaseURL)
                    .textContentType(.URL)
                TextField(localizer.t(L.Settings.cloudASRModel), text: $draft.cloudASRModel)
                    .textContentType(.none)
                SecureField(localizer.t(L.Settings.cloudASRAuthToken), text: $draft.cloudASRAuthToken)
                Toggle(localizer.t(L.Settings.cloudASRConsentAccepted), isOn: $draft.cloudASRConsentAccepted)
                Text(cloudASRReadinessText)
                    .font(.caption)
                    .foregroundStyle(cloudASRReadinessStyle)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text(localizer.t(L.Settings.cloudASRSection))
        }
    }

    private var cloudASRReadinessText: String {
        if draft.isCloudASRConfigured {
            return localizer.t(L.Settings.cloudASRReady)
        }
        if cloudASRCanUseLocalTimingGuide {
            return localizer.t(L.Settings.cloudASRUsesLocalTimingGuide)
        }
        if draft.cloudASRModelRequiresAlignment {
            return localizer.t(L.Settings.cloudASRModelNeedsAlignment)
        }
        return localizer.t(L.Settings.cloudASRNeedsSetup)
    }

    private var cloudASRReadinessStyle: Color {
        if draft.isCloudASRConfigured { return .green }
        if cloudASRCanUseLocalTimingGuide { return .orange }
        if draft.cloudASRModelRequiresAlignment { return .orange }
        return .secondary
    }

    private var cloudASRCanUseLocalTimingGuide: Bool {
        guard draft.cloudASRModelRequiresAlignment else { return false }
        let localASRGenerator = LocalASRGeneratorFactory.make(settings: draft)
        return CloudASRGeneratorFactory.make(
            settings: draft,
            localASRGenerator: localASRGenerator
        ) != nil
    }

    private var localASRSidecarReadinessText: String {
        draft.isLocalASRSidecarConfigured
            ? localizer.t(L.Settings.localASRSidecarReady)
            : localizer.t(L.Settings.localASRSidecarNeedsSetup)
    }

    @ViewBuilder
    private func LocalASRSetupStatusView(state: LocalASRSetupState) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: localASRSetupIcon(for: state))
                .font(.body.weight(.semibold))
                .foregroundStyle(localASRSetupTint(for: state))
                .symbolEffect(.pulse, isActive: isInstalling(state) && !reduceMotion)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                Text(localASRSetupTitle(for: state))
                    .font(.callout.weight(.medium))
                Text(localASRSetupDetail(for: state))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            localASRSetupAction(for: state)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(localASRSetupTitle(for: state))
        .accessibilityValue(localASRSetupDetail(for: state))
    }

    @ViewBuilder
    private func LocalASRVADStatusView(vadModelURL: URL?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: vadModelURL == nil ? "waveform.path.ecg" : "checkmark.circle.fill")
                .foregroundStyle(vadModelURL == nil ? Color.secondary : .green)
                .frame(width: 20)
            Text(vadModelURL == nil
                 ? localizer.t(L.Settings.localASRVADMissing)
                 : localizer.t(L.Settings.localASRVADReady))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func LocalASRModelListHeader(
        title: String,
        importTitle: String,
        importAction: @escaping () -> Void
    ) -> some View {
        HStack {
            Text(title)
            Spacer()
            Button(action: importAction) {
                Image(systemName: "square.and.arrow.down")
                    .imageScale(.medium)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help(importTitle)
            .accessibilityLabel(importTitle)
        }
    }

    @ViewBuilder
    private func localASRModelRow(_ entry: ASRModelCatalogEntry, isRecommended: Bool = false) -> some View {
        LocalASRModelRow(entry, isRecommended: isRecommended)
    }

    @ViewBuilder
    private func LocalASRModelRow(_ entry: ASRModelCatalogEntry, isRecommended: Bool = false) -> some View {
        HStack(spacing: 14) {
            Image(systemName: modelIcon(entry))
                .font(.title3.weight(.semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(modelTint(entry))
                .symbolEffect(.pulse, isActive: localASRInstallingModelID == entry.id && !reduceMotion)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(entry.displayName)
                        .font(.callout.weight(.medium))
                    if isRecommended {
                        Text(localizer.t(L.Settings.localASRRecommendedBadge))
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .foregroundStyle(Color.accentColor)
                            .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                            .accessibilityHidden(true)
                    }
                }
                Text(modelCapabilityText(entry))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(localizer.t(L.Settings.localASRModelSizeMemory, localASRModelSizeText(entry.sizeBytes), entry.memoryRequiredMB))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            if entry.isInstalled {
                HStack(spacing: 8) {
                    if draft.localASRModelID == entry.id {
                        Label(localizer.t(L.Settings.localASRModelInUse), systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                            .labelStyle(.titleAndIcon)
                    } else {
                        Button(localizer.t(L.Settings.localASRUseModel)) {
                            useLocalASRModel(entry)
                        }
                        .buttonStyle(.borderless)
                    }

                    Button(role: .destructive) {
                        deleteLocalASRModel(entry)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help(localizer.t(L.Settings.localASRDeleteModel))
                }
            } else if entry.installState == .badHash {
                Button(localizer.t(L.Settings.localASRSetupRepair)) {
                    deleteLocalASRModel(entry)
                }
                .buttonStyle(.borderless)
                .help(localizer.t(L.Settings.localASRModelBadHash))
            } else if entry.installState == .insufficientDiskSpace {
                Label(localizer.t(L.Settings.localASRModelInsufficientDisk), systemImage: "externaldrive.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if entry.needsUserDownloadConsent {
                if localASRInstallingModelID == entry.id {
                    VStack(spacing: 2) {
                        ProgressView(value: localASRModelInstallProgress)
                            .controlSize(.small)
                            .frame(width: 60)
                        if let p = localASRModelInstallProgress {
                            Text("\(Int(p * 100))%")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Button {
                        installLocalASRModel(entry)
                    } label: {
                        Image(systemName: "arrow.down.circle")
                            .font(.title3)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.accentColor)
                    .help(localizer.t(L.Settings.localASRDownloadModel))
                    .accessibilityLabel(localizer.t(L.Settings.localASRDownloadModel))
                    .disabled(localASRInstallingModelID != nil)
                }
            }
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(localASRModelAccessibilityLabel(entry))
        .accessibilityValue(localASRModelStatusText(entry))
    }

    @ViewBuilder
    private func importedLocalASRModelRow() -> some View {
        if let url = importedLocalASRModelURL {
            HStack(spacing: 14) {
                Image(systemName: "tray.and.arrow.down")
                    .font(.title3.weight(.semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(importedLocalASRModelName(url))
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                        Text(localizer.t(L.Settings.localASRImportedModelBadge))
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .foregroundStyle(Color.accentColor)
                            .background(
                                Capsule()
                                    .fill(Color.accentColor.opacity(0.14))
                            )
                    }
                    Text(importedLocalASRModelDetail(url))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(url.path)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                HStack(spacing: 8) {
                    Label(localizer.t(L.Settings.localASRModelInUse), systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .labelStyle(.titleAndIcon)

                    Button(role: .destructive) {
                        deleteImportedLocalASRModel()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help(localizer.t(L.Settings.localASRDeleteImportedModel))
                }
            }
            .padding(.vertical, 7)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(localizer.t(L.Settings.localASRImportedModelAccessibility, importedLocalASRModelName(url), importedLocalASRModelDetail(url)))
            .accessibilityValue(localizer.t(L.Settings.localASRModelInUse))
        }
    }

    private func modelIcon(_ entry: ASRModelCatalogEntry) -> String {
        if entry.id.contains("large") || entry.id.contains("turbo") { return "gauge.with.dots.needle.67percent" }
        if entry.id.contains(".en") { return "text.bubble.fill" }
        if entry.id.contains("medium") { return "waveform.path.ecg" }
        if entry.id.contains("tiny") { return "bolt.fill" }
        if entry.id.contains("base") { return "circle.grid.2x2.fill" }
        return "waveform"
    }

    private func modelTint(_ entry: ASRModelCatalogEntry) -> Color {
        entry.isInstalled ? .green : .secondary
    }

    private func modelCapabilityText(_ entry: ASRModelCatalogEntry) -> String {
        modelCapabilityLabel(entry)
    }

    private func modelCapabilityLabel(_ entry: ASRModelCatalogEntry) -> String {
        if entry.id.contains("large") || entry.id.contains("turbo") { return localizer.t(L.Settings.localASRModelCapabilityTurbo) }
        if entry.id.contains("medium") { return localizer.t(L.Settings.localASRModelCapabilityLongVideo) }
        if entry.id.contains(".en") { return localizer.t(L.Settings.localASRModelCapabilityEnglish) }
        if entry.id.contains("small-q8") { return localizer.t(L.Settings.localASRModelCapabilityDetailed) }
        if entry.id.contains("small") { return localizer.t(L.Settings.localASRModelCapabilityRecommended) }
        if entry.id.contains("base") { return localizer.t(L.Settings.localASRModelCapabilityBalanced) }
        if entry.id.contains("tiny") { return localizer.t(L.Settings.localASRModelCapabilityFast) }
        return localizer.t(L.Settings.localASRModelCapabilityAccurate)
    }

    private var localASRSetupState: LocalASRSetupState {
        guard draft.localASREnabled else { return .disabled }
        if let installingID = localASRInstallingModelID {
            let modelName = unsortedLocalASRModelCatalogEntries
                .first(where: { $0.id == installingID })?
                .displayName ?? localizer.t(L.Settings.localASRInstallingModel)
            return .downloading(modelName: modelName)
        }
        guard let runtimePath = availableLocalASRRuntimePath else {
            return .missingRuntime
        }
        if let entry = selectedCatalogLocalASRModel {
            switch entry.installState {
            case .installed:
                return .ready(runtimePath: runtimePath)
            case .badHash:
                return .badHash
            case .notInstalled, .insufficientDiskSpace:
                return .missingModel
            }
        }
        if let imported = importedLocalASRModelURL {
            return FileManager.default.fileExists(atPath: imported.path) ? .ready(runtimePath: runtimePath) : .missingModel
        }
        return .missingModel
    }

    private var availableLocalASRRuntimePath: String? {
        let path = draft.localASRRuntimePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }

    private var localASRVADModelURL: URL? {
        guard let runtimePath = availableLocalASRRuntimePath else { return nil }
        return WhisperCppVADModelLocator.locate(
            runtime: ASRRuntimeInfo(executableURL: URL(fileURLWithPath: runtimePath)),
            extraSearchURLs: localASRRuntimeSearchURLs
        )
    }

    private var selectedCatalogLocalASRModel: ASRModelCatalogEntry? {
        let selectedID = draft.localASRModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selectedID.isEmpty else { return nil }
        return unsortedLocalASRModelCatalogEntries.first { $0.id == selectedID }
    }

    private func isInstalling(_ state: LocalASRSetupState) -> Bool {
        if case .downloading = state { return true }
        return false
    }

    private func localASRSetupIcon(for state: LocalASRSetupState) -> String {
        switch state {
        case .disabled:
            return "circle"
        case .ready:
            return "checkmark.circle.fill"
        case .missingRuntime, .missingModel:
            return "wrench.and.screwdriver"
        case .badHash:
            return "exclamationmark.triangle.fill"
        case .downloading:
            return "arrow.down.circle"
        }
    }

    private func localASRSetupTint(for state: LocalASRSetupState) -> Color {
        switch state {
        case .disabled:
            return .secondary
        case .ready:
            return .green
        case .missingRuntime, .missingModel, .downloading:
            return .accentColor
        case .badHash:
            return .orange
        }
    }

    private func localASRSetupTitle(for state: LocalASRSetupState) -> String {
        switch state {
        case .disabled:
            return localizer.t(L.Settings.localASROptionalNotConfigured)
        case .ready:
            return localizer.t(L.Settings.localASRSetupReady)
        case .missingRuntime:
            return localizer.t(L.Settings.localASRSetupMissingRuntime)
        case .missingModel:
            return localizer.t(L.Settings.localASRSetupMissingModel)
        case .badHash:
            return localizer.t(L.Settings.localASRModelBadHash)
        case .downloading:
            return localizer.t(L.Settings.localASRInstallingModel)
        }
    }

    private func localASRSetupDetail(for state: LocalASRSetupState) -> String {
        switch state {
        case .disabled:
            return localizer.t(L.Settings.localASRHelp)
        case .ready(let runtimePath):
            return localizer.t(L.Settings.localASRRuntimeFound, runtimePath)
        case .missingRuntime:
            return localizer.t(L.Settings.localASRRuntimeNotFound)
        case .missingModel:
            return localizer.t(L.Settings.localASRSetupChooseModel)
        case .badHash:
            return localizer.t(L.Settings.localASRSetupBadModel)
        case .downloading(let modelName):
            return modelName
        }
    }

    @ViewBuilder
    private func localASRSetupAction(for state: LocalASRSetupState) -> some View {
        switch state {
        case .disabled, .ready:
            EmptyView()
        case .missingRuntime:
            HStack(spacing: 8) {
                Button(localizer.t(L.Settings.localASRFindRuntime)) {
                    adoptLocalASRRuntime()
                }
                .buttonStyle(.borderless)
                .disabled(localASRRuntimeSearchURLs.isEmpty)

                Button(localizer.t(L.Settings.localASRSetupRepair)) {
                    requestDependencySetup()
                }
                .buttonStyle(.borderless)
            }
        case .missingModel:
            Button(localizer.t(L.Settings.localASRSetupDownloadRecommended)) {
                installRecommendedLocalASRModel()
            }
            .buttonStyle(.borderless)
            .disabled(recommendedModelForDevice() == nil || localASRInstallingModelID != nil)
        case .badHash:
            Button(localizer.t(L.Settings.localASRSetupRepair)) {
                repairSelectedLocalASRModel()
            }
            .buttonStyle(.borderless)
        case .downloading:
            ProgressView(value: localASRModelInstallProgress)
                .controlSize(.small)
                .frame(width: 64)
                .accessibilityLabel(localizer.t(L.Settings.localASRInstallingModel))
        }
    }

    private func recommendedModelForDevice() -> ASRModelCatalogEntry? {
        let entries = unsortedLocalASRModelCatalogEntries
        guard !entries.isEmpty else { return nil }
        let memoryGB = ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)
        let preferredID = if memoryGB >= 32 {
            "whisper.cpp:large-v3-turbo-q5_0"
        } else if memoryGB >= 8 {
            "whisper.cpp:small-q5_1"
        } else if memoryGB >= 4 {
            "whisper.cpp:base-q5_1"
        } else {
            "whisper.cpp:tiny-q5_1"
        }
        return entries.first(where: { $0.id == preferredID }) ?? entries.first
    }

    private func installRecommendedLocalASRModel() {
        guard let entry = recommendedModelForDevice() else { return }
        if entry.isInstalled {
            useLocalASRModel(entry)
        } else {
            installLocalASRModel(entry)
        }
    }

    private func repairSelectedLocalASRModel() {
        if let entry = selectedCatalogLocalASRModel {
            deleteLocalASRModel(entry)
        } else {
            deleteImportedLocalASRModel()
        }
    }

    private func installLocalASRModel(_ entry: ASRModelCatalogEntry) {
        guard localASRInstallingModelID == nil else { return }
        localASRInstallingModelID = entry.id
        localASRModelInstallProgress = 0
        Task {
            do {
                let store = ASRModelStore(directoryURL: localASRModelStoreURL)
                let installer = ASRModelInstaller(manifest: .recommendedWhisperCpp, store: store)
                let status = try await installer.installModel(id: entry.id) { progress in
                    guard let fraction = progress.fraction else { return }
                    Task { @MainActor in
                        if localASRInstallingModelID == entry.id {
                            localASRModelInstallProgress = fraction
                        }
                    }
                }
                await MainActor.run {
                    draft.localASRModelID = entry.id
                    draft.localASRModelPath = status.installedURL.path
                    localASRModelCatalogVersion += 1
                    storageSizes["asrModels"] = nil
                    localASRModelInstallProgress = nil
                    localASRInstallingModelID = nil
                    model.settingsNotice = localizer.t(L.Settings.localASRModelInstallComplete, entry.displayName)
                }
            } catch {
                await MainActor.run {
                    model.settingsNotice = error.localizedDescription
                    localASRModelInstallProgress = nil
                    localASRInstallingModelID = nil
                    localASRModelCatalogVersion += 1
                }
            }
        }
    }

    private var localASRModelCatalogEntries: [ASRModelCatalogEntry] {
        let entries = unsortedLocalASRModelCatalogEntries
        guard let recommended = recommendedModelForDevice(),
              let recommendedIndex = entries.firstIndex(where: { $0.id == recommended.id }) else {
            return entries
        }
        var sorted = entries
        let recommendedEntry = sorted.remove(at: recommendedIndex)
        sorted.insert(recommendedEntry, at: 0)
        return sorted
    }

    private var unsortedLocalASRModelCatalogEntries: [ASRModelCatalogEntry] {
        _ = localASRModelCatalogVersion
        let store = ASRModelStore(directoryURL: localASRModelStoreURL)
        return (try? ASRModelCatalog(manifest: .recommendedWhisperCpp, store: store).entries) ?? []
    }

    private var localASRModelStoreURL: URL {
        AppSettings.supportDirectory
            .appendingPathComponent("asr", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
    }

    private var localASRRuntimeSearchURLs: [URL] {
        let runtimeURL = AppSettings.supportDirectory
            .appendingPathComponent("asr", isDirectory: true)
            .appendingPathComponent("runtime", isDirectory: true)
        var urls = [
            runtimeURL,
            runtimeURL.appendingPathComponent("bin", isDirectory: true),
        ]
        if let bundledRuntimeURL = Bundle.main.resourceURL?
            .appendingPathComponent("asr", isDirectory: true)
            .appendingPathComponent("runtime", isDirectory: true) {
            urls.append(bundledRuntimeURL)
            urls.append(bundledRuntimeURL.appendingPathComponent("bin", isDirectory: true))
        }
        return urls
    }

    private func adoptLocalASRRuntime() {
        guard let runtime = ASRRuntimeLocator(extraSearchURLs: localASRRuntimeSearchURLs).locate() else {
            model.settingsNotice = localizer.t(L.Settings.localASRRuntimeNotFound)
            return
        }
        draft.localASRRuntimePath = runtime.executableURL.path
        model.settingsNotice = localizer.t(L.Settings.localASRRuntimeFound, runtime.executableURL.path)
    }

    private func deleteLocalASRModel(_ entry: ASRModelCatalogEntry) {
        do {
            let store = ASRModelStore(directoryURL: localASRModelStoreURL)
            let catalog = try ASRModelCatalog(manifest: .recommendedWhisperCpp, store: store)
            try catalog.deleteModel(id: entry.id)
            if draft.localASRModelID == entry.id {
                draft.localASRModelID = ""
                if draft.localASRModelPath == entry.installedURL.path {
                    draft.localASRModelPath = ""
                }
            }
            localASRModelCatalogVersion += 1
            storageSizes["asrModels"] = nil
        } catch {
            model.settingsNotice = error.localizedDescription
        }
    }

    private func useLocalASRModel(_ entry: ASRModelCatalogEntry) {
        draft.localASRModelID = entry.id
        draft.localASRModelPath = entry.installedURL.path
    }

    private func localASRModelSizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var importedLocalASRModelURL: URL? {
        _ = localASRModelCatalogVersion
        let path = draft.localASRModelPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        let isCatalogModel = ASRModelManifest.recommendedWhisperCpp.models.contains { $0.id == draft.localASRModelID }
        guard !isCatalogModel else { return nil }
        return URL(fileURLWithPath: path)
    }

    private func importedLocalASRModelName(_ url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        return name.isEmpty ? url.lastPathComponent : name
    }

    private func importedLocalASRModelDetail(_ url: URL) -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path),
              let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let fileSize = values.fileSize else {
            return localizer.t(L.Settings.localASRModelMissingFile)
        }
        return localizer.t(L.Settings.localASRImportedModelDetail, localASRModelSizeText(Int64(fileSize)))
    }

    private func importLocalASRModel() {
        #if canImport(AppKit)
        let panel = NSOpenPanel()
        panel.title = localizer.t(L.Settings.localASRImportModel)
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        #if canImport(UniformTypeIdentifiers)
        if let binType = UTType(filenameExtension: "bin") {
            panel.allowedContentTypes = [binType]
        }
        #endif
        guard panel.runModal() == .OK, let sourceURL = panel.url else { return }
        importLocalASRModel(from: sourceURL)
        #else
        model.settingsNotice = localizer.t(L.Settings.localASRImportUnavailable)
        #endif
    }

    private func importLocalASRModel(from sourceURL: URL) {
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let fm = FileManager.default
        var copiedURL: URL?
        do {
            let importedDirectoryURL = localASRModelStoreURL.appendingPathComponent("imported", isDirectory: true)
            try fm.createDirectory(at: importedDirectoryURL, withIntermediateDirectories: true)
            let destinationURL = uniqueImportedModelDestination(
                directoryURL: importedDirectoryURL,
                fileName: sanitizedImportedModelFileName(sourceURL.lastPathComponent)
            )
            copiedURL = destinationURL
            try fm.copyItem(at: sourceURL, to: destinationURL)
            draft.localASREnabled = true
            draft.localASRModelID = importedLocalASRModelID(for: destinationURL)
            draft.localASRModelPath = destinationURL.path
            localASRModelCatalogVersion += 1
            storageSizes["asrModels"] = nil
            model.settingsNotice = localizer.t(L.Settings.localASRModelImportComplete, importedLocalASRModelName(destinationURL))
        } catch {
            // 复制中途失败可能留下半截 .bin：清理掉，避免占用存储或被后续误当成坏模型。
            if let copiedURL {
                try? fm.removeItem(at: copiedURL)
            }
            model.settingsNotice = localizer.t(L.Settings.localASRModelImportFailed, error.localizedDescription)
        }
    }

    private func deleteImportedLocalASRModel() {
        guard let url = importedLocalASRModelURL else { return }
        do {
            let fm = FileManager.default
            if fm.fileExists(atPath: url.path), isManagedLocalASRModelURL(url) {
                try fm.removeItem(at: url)
            }
            draft.localASRModelID = ""
            draft.localASRModelPath = ""
            localASRModelCatalogVersion += 1
            storageSizes["asrModels"] = nil
        } catch {
            model.settingsNotice = error.localizedDescription
        }
    }

    private func sanitizedImportedModelFileName(_ fileName: String) -> String {
        let lastPathComponent = URL(fileURLWithPath: fileName).lastPathComponent
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let sanitized = String(lastPathComponent.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "-"
        })
        let fallback = sanitized.trimmingCharacters(in: CharacterSet(charactersIn: ".-")).isEmpty
            ? "imported-whisper-model.bin"
            : sanitized
        return fallback.lowercased().hasSuffix(".bin") ? fallback : "\(fallback).bin"
    }

    private func uniqueImportedModelDestination(directoryURL: URL, fileName: String) -> URL {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
        let ext = URL(fileURLWithPath: fileName).pathExtension
        var candidate = directoryURL.appendingPathComponent(fileName, isDirectory: false)
        var index = 2
        while fm.fileExists(atPath: candidate.path) {
            let nextName = ext.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(ext)"
            candidate = directoryURL.appendingPathComponent(nextName, isDirectory: false)
            index += 1
        }
        return candidate
    }

    private func importedLocalASRModelID(for url: URL) -> String {
        "custom:\(url.deletingPathExtension().lastPathComponent)"
    }

    private func isManagedLocalASRModelURL(_ url: URL) -> Bool {
        let modelsPath = localASRModelStoreURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path == modelsPath || path.hasPrefix(modelsPath + "/")
    }

    private func localASRModelStatusText(_ entry: ASRModelCatalogEntry) -> String {
        let status = switch entry.installState {
        case .installed:
            localizer.t(L.Settings.localASRModelInstalled)
        case .notInstalled:
            localizer.t(L.Settings.localASRModelNotInstalled)
        case .badHash:
            localizer.t(L.Settings.localASRModelBadHash)
        case .insufficientDiskSpace:
            localizer.t(L.Settings.localASRModelInsufficientDisk)
        }
        return localizer.t(L.Settings.localASRModelStatus, status)
    }

    private func localASRModelAccessibilityLabel(_ entry: ASRModelCatalogEntry) -> String {
        [
            entry.displayName,
            modelCapabilityText(entry),
            localASRModelStatusText(entry)
        ].joined(separator: ", ")
    }

    // MARK: - 完成提醒

    private var notificationsSection: some View {
        Section(localizer.t(L.Settings.notificationsSection)) {
            Toggle(localizer.t(L.Settings.completionNotifications), isOn: $draft.completionNotificationsEnabled)
            Toggle(localizer.t(L.Settings.completionSound), isOn: $draft.completionSoundEnabled)
            Text(localizer.t(L.Settings.notificationsHelp))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 依赖组件

    private var dependencySection: some View {
        Section(localizer.t(L.Dependency.sectionTitle)) {
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
                        if !component.isRequired {
                            Text(localizer.t(L.Dependency.optionalBadge))
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .foregroundStyle(Color.accentColor)
                                .background(
                                    Capsule()
                                        .fill(Color.accentColor.opacity(0.14))
                                )
                        }
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
        }
    }

    private func refreshDependencies() async {
        let checked = await Task.detached(priority: .userInitiated) {
            DependencySetup.check()
        }.value
        dependencyComponents = checked
        dependencyChecked = true
    }

    // MARK: - 存储

    @State private var storageSizes: [String: Int64] = [:]
    @State private var storageCalculating = false
    @State private var showDeleteModelsConfirm = false
    @State private var showDeleteDownloadsConfirm = false
    @State private var storageFeedback: String?

    private var supportDataURL: URL { AppSettings.supportDirectory }
    private var appDownloadsDirectoryURL: URL { ViewModel.appDownloadsDirectory }

    private func calculateStorageSizes() async {
        storageCalculating = true
        storageFeedback = nil
        let supportDir = supportDataURL
        let downloadsDir = appDownloadsDirectoryURL
        let modelsDir = localASRModelStoreURL
        let result: [String: Int64] = await Task.detached(priority: .userInitiated) {
            var sizes: [String: Int64] = [:]
            let modelsSize = Self.directorySize(modelsDir)
            sizes["support"] = max(Self.directorySize(supportDir) - modelsSize, 0)
            sizes["asrModels"] = modelsSize
            sizes["downloads"] = Self.directorySize(downloadsDir)
            return sizes
        }.value
        storageSizes = result
        storageCalculating = false
    }

    private static nonisolated func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            do {
                let values = try fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
                total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            } catch {
                // skip inaccessible files
            }
        }
        return total
    }

    private func formattedSize(_ bytes: Int64) -> String {
        if bytes == 0 { return "0 KB" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func deleteAllASRModels() {
        do {
            let modelsDir = localASRModelStoreURL
            if FileManager.default.fileExists(atPath: modelsDir.path) {
                try FileManager.default.removeItem(at: modelsDir)
            }
            storageFeedback = localizer.t(L.Settings.storageDeleted)
            localASRModelCatalogVersion += 1
            Task { await calculateStorageSizes() }
        } catch {
            storageFeedback = localizer.t(L.Settings.storageDeletionFailed, error.localizedDescription)
        }
    }

    private func deleteAllDownloads() {
        do {
            let downloadsDir = appDownloadsDirectoryURL
            guard FileManager.default.fileExists(atPath: downloadsDir.path) else {
                storageFeedback = localizer.t(L.Settings.storageDeleted)
                storageSizes["downloads"] = 0
                return
            }
            var trashedURL: NSURL?
            try FileManager.default.trashItem(at: downloadsDir, resultingItemURL: &trashedURL)
            storageFeedback = localizer.t(L.Settings.storageDeleted)
            Task { await calculateStorageSizes() }
        } catch {
            storageFeedback = localizer.t(L.Settings.storageDeletionFailed, error.localizedDescription)
        }
    }

    private var storageSection: some View {
        Section(localizer.t(L.Settings.storageSection)) {
            VStack(alignment: .leading, spacing: 14) {
                storageOverview
                Divider()

                storageRow(
                    icon: "folder.fill.badge.gearshape",
                    tint: .secondary,
                    label: localizer.t(L.Settings.storageSupportData),
                    path: supportDataURL.path,
                    size: storageSizes["support"]
                )
                Divider()
                storageRow(
                    icon: "waveform",
                    tint: .green,
                    label: localizer.t(L.Settings.storageASRModels),
                    path: localASRModelStoreURL.path,
                    size: storageSizes["asrModels"],
                    actionTitle: localizer.t(L.Settings.storageDeleteModels),
                    actionSystemImage: "trash",
                    actionRole: .destructive,
                    action: { showDeleteModelsConfirm = true }
                )
                Divider()
                storageRow(
                    icon: "film.stack",
                    tint: .orange,
                    label: localizer.t(L.Settings.storageDownloadedVideos),
                    path: appDownloadsDirectoryURL.path,
                    size: storageSizes["downloads"],
                    actionTitle: localizer.t(L.Settings.storageDeleteDownloads),
                    actionSystemImage: "trash",
                    actionRole: .destructive,
                    action: { showDeleteDownloadsConfirm = true }
                )

                Divider()

                HStack(spacing: 10) {
                    Button {
                        calculateSizeTask()
                    } label: {
                        Label(localizer.t(L.Dependency.refresh), systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.bordered)
                    .disabled(storageCalculating)

                    if storageCalculating {
                        ProgressView().controlSize(.small)
                    }

                    Spacer()
                }

                if let feedback = storageFeedback {
                    Text(feedback)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .confirmationDialog(
                localizer.t(L.Settings.storageDeleteModelsConfirm),
                isPresented: $showDeleteModelsConfirm
            ) {
                Button(localizer.t(L.Settings.storageDeleteModels), role: .destructive) {
                    deleteAllASRModels()
                }
                Button(localizer.t(L.Common.cancel), role: .cancel) {}
            }
            .confirmationDialog(
                localizer.t(L.Settings.storageDeleteDownloadsConfirm),
                isPresented: $showDeleteDownloadsConfirm
            ) {
                Button(localizer.t(L.Settings.storageDeleteDownloads), role: .destructive) {
                    deleteAllDownloads()
                }
                Button(localizer.t(L.Common.cancel), role: .cancel) {}
            }
        }
        .onAppear {
            if storageSizes.isEmpty { calculateSizeTask() }
        }
    }

    private func calculateSizeTask() {
        Task { await calculateStorageSizes() }
    }

    private var storageOverview: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(localizer.t(L.Settings.aboutAppName))
                    .font(.headline)
                Spacer()
                Text(localizer.t(L.Settings.storageUsed, formattedSize(storageTotalBytes)))
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            storageUsageBar
            HStack(spacing: 12) {
                storageLegendItem(color: .secondary, text: localizer.t(L.Settings.storageSupportData))
                storageLegendItem(color: .green, text: localizer.t(L.Settings.storageASRModels))
                storageLegendItem(color: .orange, text: localizer.t(L.Settings.storageDownloadedVideos))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var storageTotalBytes: Int64 {
        (storageSizes["support"] ?? 0)
            + (storageSizes["asrModels"] ?? 0)
            + (storageSizes["downloads"] ?? 0)
    }

    private var storageUsageBar: some View {
        GeometryReader { proxy in
            let total = max(storageTotalBytes, 1)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary)
                HStack(spacing: 2) {
                    storageBarSegment(key: "support", color: .secondary, total: total, width: proxy.size.width)
                    storageBarSegment(key: "asrModels", color: .green, total: total, width: proxy.size.width)
                    storageBarSegment(key: "downloads", color: .orange, total: total, width: proxy.size.width)
                    Spacer(minLength: 0)
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
        .frame(height: 16)
    }

    private func storageBarSegment(key: String, color: Color, total: Int64, width: CGFloat) -> some View {
        let size = storageSizes[key] ?? 0
        let segmentWidth = size > 0 ? max(3, width * CGFloat(size) / CGFloat(total)) : 0
        return Rectangle()
            .fill(color)
            .frame(width: segmentWidth)
    }

    private func storageLegendItem(color: Color, text: String) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(text)
        }
    }

    @ViewBuilder
    private func storageRow(
        icon: String,
        tint: Color,
        label: String,
        path: String,
        size: Int64?,
        actionTitle: String? = nil,
        actionSystemImage: String? = nil,
        actionRole: ButtonRole? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .frame(width: 28)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.callout)
                Text(path)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
            }
            Spacer()
            if let size = size {
                Text(formattedSize(size))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Text(localizer.t(L.Settings.storageCalculating))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.borderless)
            .help(localizer.t(L.Queue.revealInFinder))
            if let action, let actionTitle {
                Button(role: actionRole, action: action) {
                    if let actionSystemImage {
                        Label(actionTitle, systemImage: actionSystemImage)
                    } else {
                        Text(actionTitle)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    private func componentAccessibilityLabel(_ component: DependencySetup.Component) -> String {
        localizer.t(L.Dependency.componentAccessibilityLabel, component.id, componentPurposeText(component))
    }

    private func componentPurposeText(_ component: DependencySetup.Component) -> String {
        switch component.id {
        case "yt-dlp": return localizer.t(L.Dependency.purposeYtDlp)
        case "ffmpeg": return localizer.t(L.Dependency.purposeFfmpeg)
        case "deno": return localizer.t(L.Dependency.purposeDeno)
        case "whisper-cli": return localizer.t(L.Dependency.purposeWhisperCpp)
        default: return component.purpose
        }
    }

    private func componentReadyText(_ component: DependencySetup.Component) -> String {
        if component.isInstalled { return localizer.t(L.Dependency.statusReady) }
        return component.isRequired
            ? localizer.t(L.Dependency.statusPending)
            : localizer.t(L.Dependency.statusOptionalMissing)
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
                HStack(spacing: 10) {
                    Button(localizer.t(L.Update.check)) {
                        startUpdateCheckFromSettings()
                    }
                        .buttonStyle(.bordered)
                        .disabled(!updater.canCheckForUpdates)
                    Button(localizer.t(L.Update.openReleases)) {
                        updater.openReleasesPage()
                    }
                        .buttonStyle(.bordered)
                }
            case .failed(let reason):
                VStack(alignment: .leading, spacing: 8) {
                    Text(reason)
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Button(localizer.t(L.Common.retry)) {
                            startUpdateCheckFromSettings()
                        }
                            .buttonStyle(.bordered)
                            .disabled(!updater.canCheckForUpdates)
                        Button(localizer.t(L.Update.openGitHubDownload)) {
                            updater.openReleasesPage()
                        }
                            .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    private var aboutSection: some View {
        Section(localizer.t(L.Settings.aboutSection)) {
            Text(localizer.t(L.Settings.aboutAppName))
                .fontWeight(.semibold)
            Text(localizer.t(L.Settings.aboutSource))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(localizer.t(L.Settings.openGitHubRepo)) {
                updater.openRepoPage()
            }
                .buttonStyle(.bordered)
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

    /// 登录状态行的数据源：任一 cookie jar 存在即视为已有验证信息，时间取最新。
    private func refreshLoginStatus() {
        let dates = cookieJarFileURLs().compactMap { url -> Date? in
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            return attributes?[.modificationDate] as? Date
        }
        cookieDate = dates.max()
    }

    /// 点「登录 ××」：实时保存模式下草稿已即时回写，这里只需走登录流程。
    private func requestLogin(site: String) {
        clearFeedback = nil
        persistDraftLive(draft)
        model.requestLogin(site: site)
    }

    /// 点「配置依赖」：实时保存模式下草稿已即时回写，这里只需走依赖流程。
    private func requestDependencySetup() {
        persistDraftLive(draft)
        model.requestDependencySetup()
    }

    private func clearAllLogins() {
        clearFeedback = nil
        // 清掉所有按站点隔离的 cookie 文件，外加可能残留的旧版全局文件。
        for url in cookieJarFileURLs() {
            NetscapeCookieFile.clear(at: url)
        }
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

    private func cookieJarFileURLs() -> [URL] {
        let fm = FileManager.default
        let dynamic = (try? fm.contentsOfDirectory(
            at: AppSettings.cookieDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ))?.filter { $0.pathExtension == "txt" } ?? []
        let known = CookieSites.all.map { AppSettings.siteCookieFileURL($0.key) }
        return Array(Set(dynamic + known)).filter { fm.fileExists(atPath: $0.path) }
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
