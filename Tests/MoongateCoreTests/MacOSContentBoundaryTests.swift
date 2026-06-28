import XCTest

final class MacOSContentBoundaryTests: XCTestCase {
    func testFirstRunOnboardingLetsUsersChooseLanguagesWithOptionalApiSetup() throws {
        let content = try contentViewSource()
        let viewModel = try viewModelSource()

        XCTAssertTrue(content.contains("@EnvironmentObject private var localizer: Localizer"))
        XCTAssertTrue(content.contains(".sheet(isPresented: $model.showOnboarding)"))
        XCTAssertTrue(content.contains("OnboardingView(model: model)"))
        XCTAssertTrue(content.contains("Picker(localizer.t(L.Onboarding.appLanguage)"))
        XCTAssertTrue(content.contains("Picker(localizer.t(L.Onboarding.translationTarget)"))
        XCTAssertTrue(content.contains("Toggle(localizer.t(L.Onboarding.useLocalTranslation)"))
        XCTAssertTrue(content.contains("Picker(localizer.t(L.Onboarding.translationProvider)"))
        XCTAssertTrue(content.contains("ForEach(TranslationProvider.allCases"))
        XCTAssertTrue(content.contains("model.completeOnboarding("))
        // 任务 3：选了 AI 翻译（非本地）时，onboarding 直接给出 API 凭证输入（可选填）。
        XCTAssertTrue(content.contains("if !useLocalTranslation"))
        XCTAssertTrue(content.contains("$onboardingBaseURL"))
        XCTAssertTrue(content.contains("$onboardingModel"))
        XCTAssertTrue(content.contains("$onboardingAuthToken"))
        XCTAssertTrue(content.contains("APIConfigEditor("))
        XCTAssertTrue(content.contains("settingsForRequest: { onboardingSettingsForRequest() }"))
        XCTAssertTrue(content.contains("apiBaseURL:"))
        XCTAssertTrue(content.contains("apiModel:"))
        XCTAssertTrue(content.contains("apiAuthToken:"))

        XCTAssertTrue(viewModel.contains("@Published var showOnboarding = false"))
        XCTAssertTrue(viewModel.contains("showOnboardingIfNeeded()"))
        XCTAssertTrue(viewModel.contains("func completeOnboarding("))
        XCTAssertTrue(viewModel.contains("var draft = settings"))
        XCTAssertTrue(viewModel.contains("draft.appLanguage = appLanguage.rawValue"))
        XCTAssertTrue(viewModel.contains("draft.translationTargetLanguage = translationTargetLanguage"))
        XCTAssertTrue(viewModel.contains("draft.onboardingCompleted = true"))
        XCTAssertTrue(viewModel.contains("useLocalTranslation: Bool"))
        XCTAssertTrue(viewModel.contains("translationProvider: TranslationProvider"))
        XCTAssertTrue(viewModel.contains("if useLocalTranslation"))
        XCTAssertTrue(viewModel.contains("draft.translationEngine = .appleTranslationLowLatency"))
        XCTAssertTrue(viewModel.contains("let engine = TranslationEngine.compatible(with: translationProvider)"))
        XCTAssertTrue(viewModel.contains("draft.aiEngine = engine"))
        XCTAssertTrue(viewModel.contains("draft.translationEngine = engine"))
        XCTAssertTrue(viewModel.contains("draft.aiBaseURL = translationProvider.defaultBaseURL"))
        XCTAssertTrue(viewModel.contains("draft.translationBaseURL = translationProvider.defaultBaseURL"))
        XCTAssertTrue(viewModel.contains("draft.translationFollowsDefault = true"))
        // 凭证可选填：填了才覆盖默认 base URL / token。
        XCTAssertTrue(viewModel.contains("draft.aiAuthToken = apiAuthToken"))
        XCTAssertTrue(viewModel.contains("let normalizedModel = apiModel.trimmingCharacters"))
        XCTAssertTrue(viewModel.contains("draft.aiModel = normalizedModel"))
        XCTAssertTrue(viewModel.contains("draft.translationModel = normalizedModel"))
        XCTAssertTrue(viewModel.contains("try draft.save()"))
        XCTAssertTrue(viewModel.contains("settings = draft"))
        XCTAssertTrue(viewModel.contains("showDependencySetupIfNeededOnStartup()"))
    }

    func testFirstRunOnboardingIsStagedAndKeepsLocalASRConsentDownloadFree() throws {
        let content = try contentViewSource()
        let viewModel = try viewModelSource()

        XCTAssertTrue(content.contains("enum OnboardingStep: String, CaseIterable, Identifiable"))
        XCTAssertTrue(content.contains("case language"))
        XCTAssertTrue(content.contains("case subtitleSource"))
        XCTAssertTrue(content.contains("case translationMethod"))
        XCTAssertTrue(content.contains("case readiness"))
        XCTAssertTrue(content.contains("@State private var selectedStep: OnboardingStep = .language"))
        XCTAssertTrue(content.contains("onboardingStepContent"))
        XCTAssertTrue(content.contains("onboardingFooter"))
        XCTAssertTrue(content.contains("Button(localizer.t(L.Onboarding.next))"))
        XCTAssertTrue(content.contains("Button(localizer.t(L.Onboarding.back))"))
        XCTAssertTrue(content.contains("preferLocalSpeechRecognition"))
        XCTAssertTrue(content.contains("$preferLocalSpeechRecognition"))
        XCTAssertTrue(content.contains("LocalASROnboardingOptionView"))
        XCTAssertTrue(content.contains("onboardingComponentRow("))
        XCTAssertTrue(content.contains("icon: \"wrench.and.screwdriver\""))
        XCTAssertTrue(content.contains("icon: \"captions.bubble\""))
        XCTAssertTrue(content.contains("icon: \"waveform.path.ecg\""))
        XCTAssertTrue(content.contains("localizer.t(L.Onboarding.requiredComponentsTitle)"))
        XCTAssertTrue(content.contains("localizer.t(L.Onboarding.recommendedComponentsTitle)"))
        XCTAssertTrue(content.contains("localizer.t(L.Onboarding.optionalComponentsTitle)"))
        XCTAssertTrue(content.contains("localizer.t(L.Onboarding.localSpeechSetupLater)"))
        XCTAssertTrue(content.contains("localizer.t(L.Onboarding.configureLocalSpeechOptional)"))
        XCTAssertTrue(content.contains("localizer.t(L.Onboarding.localSpeechOptionalDependencyHint)"))
        XCTAssertTrue(content.contains("model.openSettings(paneID: \"components\")"))
        XCTAssertTrue(content.contains("onboardingSubtitleSourceSummary"))
        XCTAssertTrue(content.contains("localizer.t(L.Settings.localASROptionalNotConfigured)"))
        XCTAssertTrue(content.contains("selectedTranslationProvider"))
        XCTAssertTrue(content.contains("localizer.t(L.Onboarding.translationProvider)"))
        XCTAssertTrue(content.contains("translationProviderLabel(selectedTranslationProvider)"))
        XCTAssertTrue(content.contains("localizer.t(L.Onboarding.readinessSummary)"))
        XCTAssertTrue(content.contains("useLocalTranslation: useLocalTranslation"))
        XCTAssertTrue(content.contains("translationProvider: selectedTranslationProvider"))
        XCTAssertTrue(content.contains("preferLocalSpeechRecognition: preferLocalSpeechRecognition"))

        XCTAssertFalse(content.localizedCaseInsensitiveContains("downloadModel"))
        XCTAssertFalse(content.localizedCaseInsensitiveContains("modelDownload"))
        XCTAssertFalse(content.contains("localASRModelPath"))
        XCTAssertFalse(content.contains("localASRRuntimePath"))

        XCTAssertTrue(viewModel.contains("preferLocalSpeechRecognition: Bool"))
        XCTAssertTrue(viewModel.contains("draft.localASREnabled = preferLocalSpeechRecognition"))
    }

    func testPrimaryMainWindowFlowUsesLocalizer() throws {
        let source = try contentViewSource()

        XCTAssertTrue(source.contains("TextField(localizer.t(L.Main.urlPlaceholderMultiline)"))
        XCTAssertTrue(source.contains(".accessibilityLabel(localizer.t(L.Main.urlInputAccessibility))"))
        XCTAssertTrue(source.contains(".help(localizer.t(L.Main.pasteAndParseHelp))"))
        XCTAssertTrue(source.contains("Text(localizer.t(L.Main.parse))"))
        XCTAssertTrue(source.contains("Text(localizer.t(L.Main.idleTitle))"))
        XCTAssertTrue(source.contains("Text(localizer.t(L.Main.idleSubtitle))"))
        XCTAssertTrue(source.contains("model.batchStatusText ?? localizer.t(L.Main.loadingAccessibility)"))
        XCTAssertTrue(source.contains("Text(model.batchStatusText ?? localizer.t(L.Main.loading))"))
        XCTAssertTrue(source.contains("Text(localizer.t(L.Main.batchAutoQueueHint))"))
        XCTAssertTrue(source.contains("Button(localizer.t(L.Common.cancel))"))
        XCTAssertTrue(source.contains("Text(localizer.t(L.Main.videoCount, candidates.count))"))
        XCTAssertTrue(source.contains(".accessibilityHint(localizer.t(L.Main.chooseVideoHint))"))
        XCTAssertTrue(source.contains("Label(localizer.t(L.Main.backToList), systemImage: \"chevron.left\")"))
        XCTAssertTrue(source.contains("Text(localizer.t(L.Main.enqueue))"))
        XCTAssertTrue(source.contains("localizer.t(L.Main.saveToVideoFolder, folderName)"))
        XCTAssertTrue(source.contains("localizer.t(L.Main.saveToDownloads)"))

        XCTAssertFalse(source.contains("TextField(\"粘贴视频链接，可一次粘贴多条\""))
        XCTAssertFalse(source.contains("Text(\"粘贴链接，下载网页里的视频\")"))
        XCTAssertFalse(source.contains("Text(\"解析完成的视频会按最高画质自动加入队列\")"))
        XCTAssertFalse(source.contains("Button(\"取消\") {"))
        XCTAssertFalse(source.contains("Text(\"这个页面里有 \\(candidates.count) 个视频\")"))
        XCTAssertFalse(source.contains("Label(\"返回列表\", systemImage: \"chevron.left\")"))
        XCTAssertFalse(source.contains("Text(\"加入队列\")"))
    }

    func testReadyPageFormatAndSubtitleControlsUseLocalizer() throws {
        let source = try contentViewSource()

	        XCTAssertTrue(source.contains("section(localizer.t(L.Ready.formatSection))"))
	        XCTAssertTrue(source.contains("section(localizer.t(L.Ready.subtitlesSection))"))
	        XCTAssertFalse(source.contains("section(localizer.t(L.Ready.subtitleSourceSection))"))
	        XCTAssertFalse(source.contains("section(localizer.t(L.Ready.subtitleOutputSection))"))
	        XCTAssertFalse(source.contains("section(localizer.t(L.Ready.sourceLanguageSection))"))
	        XCTAssertTrue(source.contains("section(localizer.t(L.Ready.outputOptionsSection))"))
	        XCTAssertTrue(source.contains("sourceLanguageRows(info)"))
        XCTAssertTrue(source.contains("SourceLanguagePickerSheet(model: model, info: info)"))
        XCTAssertTrue(source.contains("Text(localizer.t(L.Ready.hdrHint))"))
        XCTAssertTrue(source.contains("Text(localizer.t(L.Ready.outputFormat))"))
        XCTAssertTrue(source.contains("Picker(localizer.t(L.Ready.outputFormat), selection: $model.selectedOutputFormat)"))
        XCTAssertTrue(source.contains("localizer.t(L.Ready.keepSourceFormatWithSource, s)"))
        XCTAssertTrue(source.contains("localizer.t(L.Ready.keepSourceFormat)"))
        XCTAssertTrue(source.contains("localizer.t(L.Ready.h264HdrWarning)"))
        XCTAssertTrue(source.contains("localizer.t(L.Ready.h264ReencodeWarning)"))
        XCTAssertTrue(source.contains("localizer.t(L.Ready.h265ReencodeWarning)"))
        XCTAssertTrue(source.contains("Text(localizer.t(L.Ready.audioSection))"))
        XCTAssertTrue(source.contains("localizer.t(L.Ready.subtitleIntentNone)"))
        XCTAssertTrue(source.contains("localizer.t(L.Ready.noSubtitleProcessingHint)"))
        XCTAssertTrue(source.contains("localizer.t(L.Ready.subtitleSourceModeAuto)"))
        XCTAssertTrue(source.contains("localizer.t(L.Ready.subtitleSourceModeOriginal)"))
        XCTAssertTrue(source.contains("localizer.t(L.Ready.subtitleSourceModeEnhanced)"))
        XCTAssertTrue(source.contains("localizer.t(L.Ready.subtitleReasonManualVideoLanguage)"))
        XCTAssertTrue(source.contains("localizer.t(L.Ready.subtitleSourceMoreOptions)"))
        XCTAssertTrue(source.contains("localizer.t(L.Ready.sourceLanguageAuto)"))
        XCTAssertTrue(source.contains("localizer.t(L.Ready.sourceLanguageChange)"))
        XCTAssertTrue(source.contains("localizer.t(L.Ready.sourceLanguagePickerTitle)"))
        XCTAssertTrue(source.contains(".accessibilityHint(localizer.t(L.Ready.chooseFormatHint))"))
        XCTAssertTrue(source.contains("localizer.t(L.Ready.selected)"))
        XCTAssertTrue(source.contains("localizer.t(L.Ready.notSelected)"))
        XCTAssertTrue(source.contains(".accessibilityHint(localizer.t(L.Ready.subtitleSelectHint))"))
        XCTAssertTrue(source.contains("localizer.t(L.Ready.recommendedBadge)"))

        XCTAssertFalse(source.contains("section(\"格式\")"))
        XCTAssertFalse(source.contains("section(\"字幕\")"))
        XCTAssertFalse(source.contains("section(\"字幕处理\")"))
        XCTAssertFalse(source.contains("section(\"字幕来源\")"))
        XCTAssertFalse(source.contains("section(\"字幕输出\")"))
        XCTAssertFalse(source.contains("section(\"输出选项\")"))
        XCTAssertFalse(source.contains("Text(\"这个视频没有字幕\")"))
        XCTAssertFalse(source.contains("Text(\"自动生成\")"))
    }

    func testReadyPageShowsLocalASRSubtitleSourceAsSelectableTrack() throws {
        let source = try contentViewSource()
        let sourceLanguageRowsBody = try XCTUnwrap(functionBody(prefix: "private func sourceLanguageRows", in: source))
        let pickerBody = try XCTUnwrap(functionBody(prefix: "private struct SourceLanguagePickerSheet", in: source))

        // 原声语言是独立入口：主页面只说明判断和置信度，搜索/手动代码在 sheet 内完成。
        XCTAssertTrue(source.contains("sourceLanguageRows(info)"))
        XCTAssertTrue(sourceLanguageRowsBody.contains("model.sourceLanguageRecommendation(for: info)"))
        XCTAssertTrue(sourceLanguageRowsBody.contains("sourceLanguageSummaryTitle(recommendation)"))
        XCTAssertTrue(sourceLanguageRowsBody.contains("sourceLanguageEvidenceText(recommendation)"))
        XCTAssertTrue(sourceLanguageRowsBody.contains("model.showSourceLanguagePicker = true"))
        XCTAssertTrue(source.contains("LanguageCatalog.commonEntries()"))
        XCTAssertTrue(pickerBody.contains("LanguageCatalog.search(searchText)"))
        XCTAssertTrue(pickerBody.contains("LanguageCatalog.normalize(manualCode)"))
        XCTAssertTrue(pickerBody.contains("model.setReadySourceLanguagePreference(code, for: info)"))
        XCTAssertFalse(source.contains("sourceLanguagePreferencePicker(info)"))

        let keys = try String(contentsOf: packageRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("MoongateMobileCore")
            .appendingPathComponent("Localization")
            .appendingPathComponent("LocalizationKeys.swift"))
        XCTAssertTrue(keys.contains("localASR"))
        XCTAssertTrue(keys.contains("localASRConfigure"))
        XCTAssertTrue(keys.contains("recommendedBadge"))
        XCTAssertTrue(keys.contains("moreLanguages"))
    }

    func testReadyPageSeparatesPrimarySubtitleSourceFromSubtitleOutput() throws {
        let source = try contentViewSource()
        let readyBody = try XCTUnwrap(functionBody(prefix: "private func readyState", in: source))
        let outputRowsBody = try XCTUnwrap(functionBody(prefix: "private func subtitleOutputRows", in: source))

	        // Ready 页只有一个字幕区；字幕结果在前，来源决策在同一区域内渐进披露。
	        XCTAssertTrue(readyBody.contains("let subtitleState = model.readySubtitleState(for: info)"))
	        XCTAssertTrue(readyBody.contains("section(localizer.t(L.Ready.subtitlesSection))"))
	        XCTAssertTrue(readyBody.contains("subtitleOutputRows(info, state: subtitleState)"))
	        XCTAssertTrue(readyBody.contains("if subtitleState.needsSubtitleSource"))
	        XCTAssertTrue(readyBody.contains("subtitleSourceRows(info, state: subtitleState)"))
	        XCTAssertFalse(readyBody.contains("section(localizer.t(L.Ready.sourceLanguageSection))"))
	        XCTAssertFalse(readyBody.contains("section(localizer.t(L.Ready.subtitleSourceSection))"))
	        XCTAssertFalse(readyBody.contains("section(localizer.t(L.Ready.subtitleProcessingSection))"))

        // 来源区：主流程只有 3 个用户语义；语言和导入字幕放入更多选项，技术策略不在 Ready 页外露。
        let sourceRowsBody = try XCTUnwrap(functionBody(prefix: "private func subtitleSourceRows", in: source))
        XCTAssertTrue(source.contains("localizer.t(L.Ready.recommendedBadge)"))
        XCTAssertTrue(sourceRowsBody.contains("state.sourceDecision"))
        XCTAssertTrue(sourceRowsBody.contains("ForEach(Array(userSubtitleSourcePolicies.enumerated())"))
        XCTAssertTrue(sourceRowsBody.contains("subtitleSourceModeBinding(for: info)"))
        XCTAssertTrue(sourceRowsBody.contains("subtitleSourceModeDetail(for: policy)"))
        XCTAssertTrue(source.contains("localizer.t(L.Ready.subtitleSourceModeAuto)"))
        XCTAssertTrue(source.contains("localizer.t(L.Ready.subtitleSourceModeOriginal)"))
        XCTAssertTrue(source.contains("localizer.t(L.Ready.subtitleSourceModeEnhanced)"))
        XCTAssertTrue(sourceRowsBody.contains("sourceLanguageRows(info)"))
        XCTAssertFalse(sourceRowsBody.contains("sourceLanguagePreferencePicker(info)"))
        XCTAssertFalse(sourceRowsBody.contains("subtitleLanguageRows(info)"))
        XCTAssertFalse(sourceRowsBody.contains("SubtitleSourcePolicy.allCases"))
        XCTAssertFalse(sourceRowsBody.contains("Picker(localizer.t(L.Ready.subtitleSourcePolicyAccessibility)"))
        XCTAssertFalse(sourceRowsBody.contains("localizer.t(L.Ready.subtitleSourceCandidates)"))
        XCTAssertTrue(sourceRowsBody.contains("importedSubtitleFileRow(info)"))
        XCTAssertTrue(source.contains("importSubtitleFile(for: info)"))
        XCTAssertTrue(source.contains("model.importedSubtitleFileURL"))
        XCTAssertTrue(source.contains("model.clearImportedSubtitleFile(for: info)"))

        XCTAssertTrue(outputRowsBody.contains("SubtitleIntent.allCases"))
        XCTAssertTrue(outputRowsBody.contains("subtitleIntentBinding(for: info)"))
        XCTAssertTrue(outputRowsBody.contains("!state.needsSubtitleSource"))
        XCTAssertTrue(outputRowsBody.contains("state.selectedTrack != nil"))
        XCTAssertFalse(outputRowsBody.contains("selectedSubtitleIDs.isEmpty"))
    }

    func testChineseSubtitleRowsUsesAppleGuidanceOnlyForAppleEngines() throws {
        let source = try contentViewSource()
        let rowsBody = try XCTUnwrap(functionBody(prefix: "private func subtitleOutputRows", in: source))

        XCTAssertTrue(rowsBody.contains("appleTranslationSetupGuidanceView("))
        XCTAssertTrue(rowsBody.contains("compactTranslationReadinessView()"))
        XCTAssertFalse(rowsBody.contains("AppleTranslationSetupGuidance.make("))

        let guidanceBody = try XCTUnwrap(
            functionBody(prefix: "private func appleTranslationSetupGuidanceView", in: source)
        )
        XCTAssertTrue(guidanceBody.contains("AppleTranslationSetupGuidance.make("))
        XCTAssertTrue(guidanceBody.contains("engine: effectiveTranslationEngine"))
        XCTAssertTrue(guidanceBody.contains("readiness: readiness"))
        XCTAssertTrue(guidanceBody.contains("guidance.title"))
        XCTAssertTrue(guidanceBody.contains("guidance.steps"))
        XCTAssertTrue(guidanceBody.contains("Button(localizer.t(L.Ready.openSettings))"))
        XCTAssertTrue(guidanceBody.contains(".help(localizer.t(L.Ready.appleTranslationOpenSettingsHelp))"))
        XCTAssertTrue(guidanceBody.contains(".accessibilityHint(localizer.t(L.Ready.appleTranslationOpenSettingsHelp))"))
        XCTAssertFalse(guidanceBody.contains("NSWorkspace.shared.open"))
        XCTAssertFalse(guidanceBody.contains("saveSettings()"))
        XCTAssertFalse(guidanceBody.contains("model.settings ="))
        XCTAssertFalse(guidanceBody.contains("translationEngineBinding"))
        XCTAssertFalse(guidanceBody.contains("wrappedValue"))
        XCTAssertFalse(guidanceBody.localizedCaseInsensitiveContains("cookie"))
        XCTAssertFalse(guidanceBody.localizedCaseInsensitiveContains("translationAuthToken"))
        XCTAssertFalse(guidanceBody.localizedCaseInsensitiveContains("token"))

        let summaryBody = try XCTUnwrap(
            functionBody(prefix: "private func appleTranslationSetupActionSummary", in: source)
        )
        XCTAssertTrue(summaryBody.contains("localizer.t(L.Ready.appleTranslationActionOpenSettings)"))
        XCTAssertTrue(summaryBody.contains("localizer.t(L.Ready.appleTranslationActionRefresh)"))
        XCTAssertTrue(summaryBody.contains("localizer.t(L.Ready.appleTranslationActionChooseDifferentEngine)"))
        XCTAssertFalse(summaryBody.contains("去设置完成系统侧配置"))
        XCTAssertFalse(summaryBody.contains("NSWorkspace.shared.open"))
        XCTAssertFalse(summaryBody.contains("saveSettings()"))
        XCTAssertFalse(summaryBody.contains("model.settings ="))
        XCTAssertFalse(summaryBody.localizedCaseInsensitiveContains("translationAuthToken"))
        XCTAssertFalse(summaryBody.localizedCaseInsensitiveContains("token"))

        let gateBody = try XCTUnwrap(functionBody(prefix: "private var shouldShowAppleTranslationSetupGuidance", in: source))
        let compactGateBody = compactWhitespace(gateBody)
        XCTAssertTrue(compactGateBody.contains("case .appleTranslationLowLatency, .appleTranslationHighFidelity, .appleFoundationOnDevice, .appleFoundationPCC, .appleFoundationCloudPro: return true"))
        XCTAssertTrue(compactGateBody.contains("case .anthropicCompatible, .openAICompatible: return false"))

        let effectiveEngineBody = try XCTUnwrap(functionBody(prefix: "private var effectiveTranslationEngine", in: source))
        XCTAssertTrue(effectiveEngineBody.contains("model.settings.effectiveTranslationConfig.engine"))
    }

    func testAppleSetupGuidanceShowsAPICompatibleFallbackWithoutChangingSettings() throws {
        let source = try contentViewSource()
        let guidanceBody = try XCTUnwrap(
            functionBody(prefix: "private func appleTranslationSetupGuidanceView", in: source)
        )

        XCTAssertTrue(guidanceBody.contains("Text(appleTranslationSetupFallbackText)"))
        XCTAssertTrue(guidanceBody.contains(".accessibilityHint(localizer.t(L.Ready.appleTranslationFallbackHint))"))
        XCTAssertFalse(guidanceBody.contains("model.settings ="))
        XCTAssertFalse(guidanceBody.contains(".translationEngine ="))
        XCTAssertFalse(guidanceBody.contains("saveSettings()"))
        XCTAssertFalse(guidanceBody.contains("NSWorkspace"))
        XCTAssertFalse(guidanceBody.localizedCaseInsensitiveContains("translationAuthToken"))
        XCTAssertFalse(guidanceBody.localizedCaseInsensitiveContains("token"))
        XCTAssertFalse(guidanceBody.localizedCaseInsensitiveContains("cookie"))

        let fallbackBody = try XCTUnwrap(
            functionBody(prefix: "private var appleTranslationSetupFallbackText", in: source)
        )
        XCTAssertTrue(fallbackBody.contains("localizer.t(L.Ready.appleTranslationFallback)"))
        XCTAssertFalse(fallbackBody.contains("PCC"))
        XCTAssertFalse(fallbackBody.localizedCaseInsensitiveContains("Cloud Pro"))
        XCTAssertFalse(fallbackBody.contains("云端"))
    }

    func testAppleSetupGuidanceShowsScannableReadinessSummaryWithoutSideEffects() throws {
        let source = try contentViewSource()
        let guidanceBody = try XCTUnwrap(
            functionBody(prefix: "private func appleTranslationSetupGuidanceView", in: source)
        )

        XCTAssertTrue(guidanceBody.contains("appleTranslationSetupReadinessSummary(readiness)"))

        let summaryBody = try XCTUnwrap(
            functionBody(prefix: "private func appleTranslationSetupReadinessSummary", in: source)
        )
        XCTAssertTrue(summaryBody.contains("Text(localizer.t(L.Ready.currentEngine))"))
        XCTAssertTrue(summaryBody.contains("effectiveTranslationEngine.displayName"))
        XCTAssertTrue(summaryBody.contains("Text(localizer.t(L.Ready.status))"))
        XCTAssertTrue(summaryBody.contains("readiness.isReady ? localizer.t(L.Ready.statusReady) : localizer.t(L.Ready.statusNeedsAction)"))
        XCTAssertTrue(summaryBody.contains("Text(localizer.t(L.Ready.primaryReason))"))
        XCTAssertTrue(summaryBody.contains("appleTranslationSetupReadinessReason(readiness)"))
        XCTAssertTrue(summaryBody.contains(".accessibilityLabel(localizer.t(L.Ready.appleTranslationStatus))"))
        XCTAssertTrue(summaryBody.contains(".accessibilityValue("))
        XCTAssertFalse(summaryBody.contains("model.settings ="))
        XCTAssertFalse(summaryBody.contains(".translationEngine ="))
        XCTAssertFalse(summaryBody.contains("saveSettings()"))
        XCTAssertFalse(summaryBody.contains("NSWorkspace"))
        XCTAssertFalse(summaryBody.localizedCaseInsensitiveContains("translationAuthToken"))
        XCTAssertFalse(summaryBody.localizedCaseInsensitiveContains("token"))
        XCTAssertFalse(summaryBody.localizedCaseInsensitiveContains("cookie"))
        XCTAssertFalse(summaryBody.contains("PCC 可用"))
        XCTAssertFalse(summaryBody.localizedCaseInsensitiveContains("Cloud Pro 可用"))
        XCTAssertFalse(summaryBody.contains("云端 Pro 可用"))

        let reasonBody = try XCTUnwrap(
            functionBody(prefix: "private func appleTranslationSetupReadinessReason", in: source)
        )
        XCTAssertTrue(reasonBody.contains("model.translationReadinessMessageForCurrentSettings()"))
        XCTAssertFalse(reasonBody.contains("PCC 可用"))
        XCTAssertFalse(reasonBody.localizedCaseInsensitiveContains("Cloud Pro 可用"))
        XCTAssertFalse(reasonBody.contains("云端 Pro 可用"))
    }

    func testCustomSelectionRowsExposeAccessibilitySemantics() throws {
        let source = try contentViewSource()

        let settingsHeaderBody = try XCTUnwrap(functionBody(prefix: "private var header", in: source))
        XCTAssertTrue(settingsHeaderBody.contains("localizer.t(L.Main.settingsAccessibility)"))

        let candidateRowBody = try XCTUnwrap(functionBody(prefix: "private func candidateRow", in: source))
        XCTAssertTrue(candidateRowBody.contains(".accessibilityElement(children: .combine)"))
        XCTAssertTrue(candidateRowBody.contains(".accessibilityLabel(candidate.title)"))
        XCTAssertTrue(candidateRowBody.contains(".accessibilityHint(localizer.t(L.Main.chooseVideoHint))"))

        let formatRowBody = try XCTUnwrap(functionBody(prefix: "private func formatRow", in: source))
        XCTAssertTrue(formatRowBody.contains(".accessibilityElement(children: .combine)"))
        XCTAssertTrue(formatRowBody.contains(".accessibilityLabel(format.label)"))
        XCTAssertTrue(formatRowBody.contains(".accessibilityHint(localizer.t(L.Ready.chooseFormatHint))"))
        XCTAssertTrue(formatRowBody.contains(".accessibilityValue("))
        XCTAssertTrue(formatRowBody.contains("model.selectedFormatID == format.id ? localizer.t(L.Ready.selected) : localizer.t(L.Ready.notSelected)"))
    }

    func testHeaderSettingsButtonShowsUpdateBadgeWhenUpdateAvailable() throws {
        let source = try contentViewSource()
        let headerBody = try XCTUnwrap(functionBody(prefix: "private var header", in: source))

        XCTAssertTrue(source.contains("@ObservedObject private var updater: UpdateService"))
        XCTAssertTrue(source.contains("ObservedObject(wrappedValue: model.updater)"))
        XCTAssertTrue(headerBody.contains("HStack(alignment: .center, spacing: 8)"))
        XCTAssertFalse(headerBody.contains("HStack(alignment: .top, spacing: 8)"))
        XCTAssertTrue(headerBody.contains("localizer.t(L.Main.settingsAccessibility)"))
        XCTAssertGreaterThanOrEqual(headerBody.components(separatedBy: ".frame(height: 34)").count - 1, 2)
        // 11f：发现更新时设置齿轮显示红点 badge。
        XCTAssertTrue(headerBody.contains("if updater.updateAvailable"))
        XCTAssertTrue(headerBody.contains("Circle()"))
        XCTAssertTrue(headerBody.contains(".fill(.red)"))

        let parseButtonBody = try XCTUnwrap(functionBody(prefix: "private var parseButton", in: source))
        XCTAssertTrue(parseButtonBody.contains(".frame(height: 34)"))
    }

    func testChineseSubtitleProcessingPickerHasAccessibleState() throws {
        let source = try contentViewSource()
        let rowsBody = try XCTUnwrap(functionBody(prefix: "private func subtitleOutputRows", in: source))

        XCTAssertTrue(rowsBody.contains("Picker(localizer.t(L.Ready.subtitleOutputSection)"))
        XCTAssertTrue(rowsBody.contains(".accessibilityLabel(localizer.t(L.Ready.subtitleProcessingAccessibility))"))
        XCTAssertTrue(rowsBody.contains(".accessibilityHint("))
        XCTAssertTrue(rowsBody.contains("localizer.t(L.Ready.subtitleProcessingHint)"))
        XCTAssertTrue(rowsBody.contains("localizer.t(L.Ready.noSubtitleProcessingHint)"))
        XCTAssertTrue(rowsBody.contains(".accessibilityValue(subtitleIntentLabel(state.intent))"))
    }

    func testChineseSubtitleRowsPrioritizesChineseSourceMessageBeforeReadinessGuidance() throws {
        let source = try contentViewSource()
        let rowsBody = try XCTUnwrap(functionBody(prefix: "private func subtitleOutputRows", in: source))

        let chineseSourceRange = try XCTUnwrap(rowsBody.range(of: "model.translationSourceMatchesTarget(in: info)"))
        let readinessGateRange = try XCTUnwrap(rowsBody.range(of: "!readiness.isReady"))
        let directUsePromptRange = try XCTUnwrap(rowsBody.range(of: "localizer.t(L.Ready.sourceAlreadyTargetUse)"))
        let burnInPromptRange = try XCTUnwrap(rowsBody.range(of: "localizer.t(L.Ready.sourceAlreadyTargetBurn)"))

        XCTAssertLessThan(chineseSourceRange.lowerBound, readinessGateRange.lowerBound)
        XCTAssertLessThan(directUsePromptRange.lowerBound, readinessGateRange.lowerBound)
        XCTAssertLessThan(burnInPromptRange.lowerBound, readinessGateRange.lowerBound)
    }

    func testParseButtonExposesClearPrimaryActionAndAccessibleHelp() throws {
        let source = try contentViewSource()

        let headerBody = try XCTUnwrap(functionBody(prefix: "private var header", in: source))
        let pasteActionRange = try XCTUnwrap(headerBody.range(of: "model.pasteAndParse()"))
        let followingParseButtonRange = try XCTUnwrap(
            headerBody.range(
                of: "parseButton",
                range: pasteActionRange.upperBound..<headerBody.endIndex
            )
        )
        let pasteButtonFragment = String(headerBody[pasteActionRange.lowerBound..<followingParseButtonRange.lowerBound])
        XCTAssertTrue(pasteButtonFragment.contains("Image(systemName: \"doc.on.clipboard\")"))
        XCTAssertTrue(pasteButtonFragment.contains(".disabled(model.isParsing)"))
        XCTAssertTrue(pasteButtonFragment.contains(".help(localizer.t(L.Main.pasteAndParseHelp))"))
        XCTAssertTrue(pasteButtonFragment.contains(".accessibilityLabel(localizer.t(L.Main.pasteAndParseAccessibility))"))
        XCTAssertTrue(pasteButtonFragment.contains(".accessibilityHint(localizer.t(L.Main.pasteAndParseHint))"))
        XCTAssertFalse(pasteButtonFragment.containsVisibleViewLine(prefix: "Label("))
        XCTAssertFalse(pasteButtonFragment.containsVisibleViewLine(prefix: "Text(\"粘贴"))

        let parseButtonBody = try XCTUnwrap(functionBody(prefix: "private var parseButton", in: source))
        XCTAssertTrue(parseButtonBody.contains("Text(localizer.t(L.Main.parse))"))
        XCTAssertTrue(parseButtonBody.contains(".help(localizer.t(L.Main.parseCurrentHelp))"))
        XCTAssertTrue(parseButtonBody.contains(".accessibilityHint(localizer.t(L.Main.parseCurrentHint))"))

        let buttonProgressRange = try XCTUnwrap(parseButtonBody.range(of: "ProgressView()"))
        let buttonTextRange = try XCTUnwrap(
            parseButtonBody.range(
                of: "Text(localizer.t(L.Main.parse))",
                range: buttonProgressRange.upperBound..<parseButtonBody.endIndex
            )
        )
        let buttonProgressFragment = String(parseButtonBody[buttonProgressRange.lowerBound..<buttonTextRange.upperBound])
        XCTAssertTrue(buttonProgressFragment.contains(".accessibilityLabel(localizer.t(L.Main.parsingAccessibility))"))

        let loadingStateBody = try XCTUnwrap(functionBody(prefix: "private var loadingState", in: source))
        XCTAssertTrue(loadingStateBody.contains(".accessibilityLabel(model.batchStatusText ?? localizer.t(L.Main.loadingAccessibility))"))
    }

    func testPrimarySubtitleSourceRowsExposeUserFacingSourceSemantics() throws {
        let source = try contentViewSource()
        let badgeBody = try XCTUnwrap(functionBody(prefix: "private func subtitleLanguageSourceBadge(for kind", in: source))

        // 行级可访问性：选中/未选中值 + 选择提示仍由 primarySubtitleSourceRow 提供。
        XCTAssertTrue(source.contains("accessibilityHint(localizer.t(L.Ready.subtitleSelectHint))"))
        XCTAssertTrue(source.contains("accessibilityValue(isSelected ? localizer.t(L.Ready.selected) : localizer.t(L.Ready.notSelected))"))

        // 来源摘要：主界面用用户能理解的来源名称，不暴露 platformAuto / Whisper 这类实现词。
        XCTAssertTrue(badgeBody.contains("localizer.t(L.Ready.manualSubtitle)"))
        XCTAssertFalse(badgeBody.contains("localizer.t(L.Ready.autoGenerated)"))
        XCTAssertTrue(badgeBody.contains("localizer.t(L.Ready.localASR)"))
        XCTAssertTrue(badgeBody.contains("localizer.t(L.Ready.importedSubtitle)"))
    }

    func testReadyFooterCopyDistinguishesSingleAndMultiFileDestinations() throws {
        let source = try contentViewSource()
        let readyBody = try XCTUnwrap(functionBody(prefix: "private func readyState", in: source))

        XCTAssertFalse(readyBody.contains("Text(\"保存到 ~/Downloads · 加入后可继续粘贴下一条\")"))
        XCTAssertTrue(readyBody.contains("Text(readyFooterCopy(for: info))"))

        let helperBody = try XCTUnwrap(functionBody(prefix: "private func readyFooterCopy", in: source))
        XCTAssertTrue(helperBody.contains("readyFooterUsesVideoFolder"))
        XCTAssertTrue(helperBody.contains("ViewModel.sanitizedFolderName(info.title)"))
        XCTAssertTrue(helperBody.contains("localizer.t(L.Main.saveToVideoFolder, folderName)"))
        XCTAssertTrue(helperBody.contains("localizer.t(L.Main.saveToDownloads)"))
        XCTAssertTrue(helperBody.contains("readyFooterUsesVideoFolder(for: info)"))

        let destinationGateBody = try XCTUnwrap(
            functionBody(prefix: "private func readyFooterUsesVideoFolder", in: source)
        )
        let compactDestinationGate = compactWhitespace(destinationGateBody)
        XCTAssertTrue(compactDestinationGate.contains("return model.subtitleIntent.needsSubtitleSource"))
        XCTAssertFalse(compactDestinationGate.contains("return !model.selectedSubtitleIDs.isEmpty || model.chineseMode != .off"))
    }

    func testSummarySectionGatesOnAvailabilityAndExposesAllStates() throws {
        // ContentView 把总结区委托给 SummaryCard，并传入可用性与回调。
        let source = try contentViewSource()
        let body = try XCTUnwrap(functionBody(prefix: "private func summarySection", in: source))
        XCTAssertTrue(body.contains("SummaryCard("))
        XCTAssertTrue(body.contains("state: model.summaryState"))
        XCTAssertTrue(body.contains("isAvailable: model.isSummaryAvailable"))
        XCTAssertTrue(body.contains("unavailableReason: model.summaryUnavailableReason"))
        XCTAssertTrue(body.contains("model.summarizeCurrentVideo()"))
        XCTAssertTrue(body.contains("model.resetSummary()"))

        let readyBody = try XCTUnwrap(functionBody(prefix: "private func readyState", in: source))
        XCTAssertTrue(readyBody.contains("summarySection(info)"))

        // SummaryCard 覆盖四态、按可用性禁用、计算中可取消，且不外发凭证。
        let cardSource = try summaryViewSource()
        XCTAssertTrue(cardSource.contains("@EnvironmentObject private var localizer: Localizer"))
        XCTAssertTrue(cardSource.contains("Label(localizer.t(L.Summary.title)"))
        XCTAssertTrue(cardSource.contains("Text(localizer.t(L.Summary.idleDescription))"))
        XCTAssertTrue(cardSource.contains("ShimmerText(text: localizer.t(L.Summary.running))"))
        XCTAssertTrue(cardSource.contains(".accessibilityLabel(localizer.t(L.Summary.runningAccessibility))"))
        XCTAssertTrue(cardSource.contains("Label(localizer.t(L.Summary.retry)"))
        XCTAssertTrue(cardSource.contains("Button(localizer.t(L.Common.retry), action: onSummarize)"))
        XCTAssertTrue(cardSource.contains("case .idle:"))
        XCTAssertTrue(cardSource.contains("case .running:"))
        XCTAssertTrue(cardSource.contains("case .done(let summary):"))
        XCTAssertTrue(cardSource.contains("case .failed(let message):"))
        XCTAssertTrue(cardSource.contains(".disabled(!isAvailable)"))
        XCTAssertTrue(cardSource.contains("onCancel"))
        // 计算/完成动画 + 尊重 Reduce Motion。
        XCTAssertTrue(cardSource.contains("accessibilityReduceMotion"))
        // 跑马灯流光描边：边框固定、渐变 angle 动画流动（非整体旋转）。
        XCTAssertTrue(cardSource.contains("FlowingBorder"))
        XCTAssertTrue(cardSource.contains("AngularGradient"))
        XCTAssertTrue(cardSource.contains("angle: .degrees(angle)"))
        XCTAssertFalse(cardSource.contains(".rotationEffect"))
        XCTAssertTrue(cardSource.contains(".transition("))
        XCTAssertFalse(cardSource.localizedCaseInsensitiveContains("token"))
        XCTAssertFalse(cardSource.localizedCaseInsensitiveContains("cookie"))
    }

    private func summaryViewSource() throws -> String {
        try String(contentsOf: packageRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("Moongate")
            .appendingPathComponent("SummaryView.swift"))
    }

    private func contentViewSource() throws -> String {
        try String(contentsOf: packageRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("Moongate")
            .appendingPathComponent("ContentView.swift"))
    }

    private func viewModelSource() throws -> String {
        try String(contentsOf: packageRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("Moongate")
            .appendingPathComponent("ViewModel.swift"))
    }

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func functionBody(prefix: String, in source: String) -> String? {
        guard let declaration = source.range(of: prefix) else { return nil }
        guard let openingBrace = source[declaration.lowerBound...].firstIndex(of: "{") else { return nil }

        var depth = 0
        var cursor = openingBrace
        while cursor < source.endIndex {
            switch source[cursor] {
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return String(source[openingBrace...cursor])
                }
            default:
                break
            }
            cursor = source.index(after: cursor)
        }
        return nil
    }

    private func compactWhitespace(_ source: String) -> String {
        source.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

private extension String {
    func containsVisibleViewLine(prefix: String) -> Bool {
        split(separator: "\n").contains { line in
            line.trimmingCharacters(in: .whitespaces).hasPrefix(prefix)
        }
    }
}
