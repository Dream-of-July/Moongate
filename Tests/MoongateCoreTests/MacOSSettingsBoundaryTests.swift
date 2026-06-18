import XCTest

final class MacOSSettingsBoundaryTests: XCTestCase {
    func testSettingsExposeAppAndTargetLanguagePickersAndPersistThem() throws {
        let source = try String(contentsOf: packageRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("Moongate")
            .appendingPathComponent("SettingsView.swift"))

        XCTAssertTrue(source.contains("@EnvironmentObject private var localizer: Localizer"))
        XCTAssertTrue(source.contains("languageSection"))
        XCTAssertTrue(source.contains("Section(localizer.t(L.Settings.languageSection))"))
        XCTAssertTrue(source.contains("Picker(localizer.t(L.Settings.appLanguage)"))
        XCTAssertTrue(source.contains("Text(localizer.t(L.Settings.followSystem))"))
        XCTAssertTrue(source.contains("Picker(localizer.t(L.Settings.targetLanguage)"))
        XCTAssertTrue(source.contains("Text(localizer.t(L.Settings.languageHelp))"))
        XCTAssertTrue(source.contains("$draft.appLanguage"))
        XCTAssertTrue(source.contains("$draft.translationTargetLanguage"))
        XCTAssertTrue(source.contains("localizer.setLanguage("))
        XCTAssertTrue(source.contains("model.settings = draft"))
    }

    func testPrimaryAIConfigurationSectionsUseLocalizer() throws {
        let source = try String(contentsOf: packageRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("Moongate")
            .appendingPathComponent("SettingsView.swift"))

        let translationSectionBody = try XCTUnwrap(functionBody(named: "translationSection", in: source))
        XCTAssertTrue(translationSectionBody.contains("Section(localizer.t(L.Settings.aiSettingsSection))"))
        XCTAssertTrue(translationSectionBody.contains("Text(localizer.t(L.Settings.aiSettingsDescription))"))
        XCTAssertTrue(translationSectionBody.contains("Picker(localizer.t(L.Settings.aiEngine)"))

        let translationConfigBody = try XCTUnwrap(functionBody(named: "translationConfigSection", in: source))
        XCTAssertTrue(translationConfigBody.contains("Section(localizer.t(L.Settings.aiTranslationSection))"))
        XCTAssertTrue(translationConfigBody.contains("Toggle(localizer.t(L.Settings.smartTranslationPrompts)"))
        XCTAssertTrue(translationConfigBody.contains("Text(localizer.t(L.Settings.smartTranslationPromptsHelp))"))
        XCTAssertTrue(translationConfigBody.contains("Picker(localizer.t(L.Settings.configMode)"))
        XCTAssertTrue(translationConfigBody.contains("Text(localizer.t(L.Settings.followAISettings))"))
        XCTAssertTrue(translationConfigBody.contains("Text(localizer.t(L.Settings.configureSeparately))"))
        XCTAssertTrue(translationConfigBody.contains("Picker(localizer.t(L.Settings.translationEngine)"))

        let summaryBody = try XCTUnwrap(functionBody(named: "summarySection", in: source))
        XCTAssertTrue(summaryBody.contains("Section(localizer.t(L.Settings.aiSummarySection))"))
        XCTAssertTrue(summaryBody.contains("Picker(localizer.t(L.Settings.configMode)"))
        XCTAssertTrue(summaryBody.contains("Text(localizer.t(L.Settings.defaultEngineCannotSummarize))"))
    }

    func testUpdateSectionExposesSparkleCheckAndReleaseFallback() throws {
        let source = try String(contentsOf: packageRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("Moongate")
            .appendingPathComponent("SettingsView.swift"))
        let body = try XCTUnwrap(functionBody(named: "updateSection", in: source))
        // 当前版本、Sparkle 原生检查入口、队列保护、GitHub 兜底。
        XCTAssertTrue(body.contains("updater.currentVersion"))
        XCTAssertTrue(body.contains("Section(localizer.t(L.Update.sectionTitle))"))
        XCTAssertTrue(body.contains("Text(localizer.t(L.Update.currentVersion))"))
        XCTAssertTrue(body.contains("Button(localizer.t(L.Update.check))"))
        XCTAssertTrue(body.contains("startUpdateCheckFromSettings()"))
        XCTAssertTrue(body.contains(".disabled(!updater.canCheckForUpdates)"))
        XCTAssertTrue(body.contains("Button(localizer.t(L.Update.openReleases))"))
        XCTAssertTrue(body.contains("updater.openReleasesPage()"))
        XCTAssertTrue(body.contains("Button(localizer.t(L.Common.retry))"))
        XCTAssertTrue(body.contains("Button(localizer.t(L.Update.openGitHubDownload))"))
        XCTAssertTrue(body.contains("case .idle"))
        XCTAssertTrue(body.contains("case .failed(let reason)"))
        XCTAssertFalse(body.contains("updater.downloadAndInstall(info)"))
        XCTAssertFalse(body.contains("case .available(let info)"))
        XCTAssertFalse(body.contains("case .downloading"))
        XCTAssertFalse(body.contains("case .installerOpened"))
        let helper = try XCTUnwrap(functionBody(named: "startUpdateCheckFromSettings", in: source))
        XCTAssertTrue(helper.contains("model.queue.openTaskCount"))
        XCTAssertTrue(helper.contains("updater.blockInstallDueToOpenTasks"))
        XCTAssertTrue(helper.contains("model.showSettings = false"))
        XCTAssertTrue(helper.contains("DispatchQueue.main.asyncAfter"))
        XCTAssertTrue(helper.contains("updater.checkForUpdates()"))
        // 更新区被挂进 Form（与其他 section 并列）。
        XCTAssertTrue(source.contains("performanceSection"))
        XCTAssertTrue(source.contains("loginSection\n                updateSection")
            || source.contains("updateSection"))
    }

    func testSettingsViewReusesSharedUpdaterFromViewModel() throws {
        let source = try String(contentsOf: packageRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("Moongate")
            .appendingPathComponent("SettingsView.swift"))

        XCTAssertTrue(source.contains("@ObservedObject private var updater: UpdateService"))
        XCTAssertFalse(source.contains("@StateObject private var updater = UpdateService()"))
        XCTAssertTrue(source.contains("init(model: ViewModel)"))
        XCTAssertTrue(source.contains("self._updater = ObservedObject(wrappedValue: model.updater)"))
        XCTAssertTrue(source.contains("model.checkForUpdatesIfNeeded()"))
    }

    func testUpdateServiceWrapsSparkleNativeUpdater() throws {
        let source = try String(contentsOf: packageRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("Moongate")
            .appendingPathComponent("UpdateService.swift"))

        XCTAssertTrue(source.contains("SPUStandardUpdaterController"))
        XCTAssertTrue(source.contains("SPUStandardUserDriverDelegate"))
        XCTAssertTrue(source.contains("userDriverDelegate: self"))
        XCTAssertTrue(source.contains("prepareForUpdateUI?()"))
        XCTAssertTrue(source.contains("@Published private(set) var canCheckForUpdates"))
        XCTAssertTrue(source.contains("updaterController.checkForUpdates(nil)"))
        XCTAssertTrue(source.contains("guard !silent else { return }"))
        XCTAssertTrue(source.contains("NSWorkspace.shared.open(releasesPageURL)"))
        XCTAssertFalse(source.contains("hasAvailableUpdate"))
    }

    func testSecondarySettingsSectionsUseLocalizer() throws {
        let source = try String(contentsOf: packageRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("Moongate")
            .appendingPathComponent("SettingsView.swift"))

        let performanceBody = try XCTUnwrap(functionBody(named: "performanceSection", in: source))
        XCTAssertTrue(performanceBody.contains("Section(localizer.t(L.Settings.performanceSection))"))
        XCTAssertTrue(performanceBody.contains("Text(localizer.t(L.Settings.concurrentDownloads))"))
        XCTAssertTrue(performanceBody.contains("Text(localizer.t(L.Settings.concurrentBurns))"))
        XCTAssertTrue(performanceBody.contains("Text(localizer.t(L.Settings.performanceHelp))"))

        let styleBody = try XCTUnwrap(functionBody(named: "styleSection", in: source))
        XCTAssertTrue(styleBody.contains("Section(localizer.t(L.Settings.styleSection))"))
        XCTAssertTrue(styleBody.contains("Picker(localizer.t(L.Settings.subtitleStyle),"))
        XCTAssertTrue(styleBody.contains("Text(localizer.t(L.Settings.subtitleStyleBilingual))"))
        XCTAssertTrue(styleBody.contains("Text(localizer.t(L.Settings.subtitleStyleChineseOnly))"))

        let burnBody = try XCTUnwrap(functionBody(named: "burnQualitySection", in: source))
        XCTAssertTrue(burnBody.contains("Section(localizer.t(L.Settings.burnSection))"))
        XCTAssertTrue(burnBody.contains("Picker(localizer.t(L.Settings.encodeBackend),"))
        XCTAssertTrue(burnBody.contains("Picker(localizer.t(L.Settings.burnEncoding),"))
        XCTAssertTrue(burnBody.contains("Text(localizer.t(L.Settings.followSourceHEVC))"))
        XCTAssertTrue(burnBody.contains("Text(localizer.t(L.Settings.alwaysH264))"))
        XCTAssertTrue(burnBody.contains("localizer.t(L.Settings.scaleHD1080)"))

        let loginBody = try XCTUnwrap(functionBody(named: "loginSection", in: source))
        XCTAssertTrue(loginBody.contains("Section(localizer.t(L.Settings.loginSection))"))
        XCTAssertTrue(loginBody.contains("Button(localizer.t(L.Settings.loginYouTube))"))
        XCTAssertTrue(loginBody.contains("Button(localizer.t(L.Settings.loginBilibili))"))
        XCTAssertTrue(loginBody.contains("Button(localizer.t(L.Settings.clearAppLogin), role: .destructive)"))
        XCTAssertTrue(loginBody.contains("localizer.t(L.Settings.clearLoginDialogTitle)"))
        XCTAssertTrue(loginBody.contains("Button(localizer.t(L.Settings.clearLoginAction), role: .destructive)"))

        let bottomBody = try XCTUnwrap(functionBody(named: "bottomBar", in: source))
        XCTAssertTrue(bottomBody.contains("Button(localizer.t(L.Common.cancel))"))
        XCTAssertTrue(bottomBody.contains("Button(localizer.t(L.Common.done))"))

        let loginStatusBody = try XCTUnwrap(functionBody(named: "loginStatusText", in: source))
        XCTAssertTrue(loginStatusBody.contains("localizer.t(L.Settings.loginNone)"))
        XCTAssertTrue(loginStatusBody.contains("localizer.t(L.Settings.loginSaved"))
    }

    func testAppleTranslationReadinessUsesUserVisibleSourceLanguageContext() throws {
        let source = try String(contentsOf: packageRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("Moongate")
            .appendingPathComponent("SettingsView.swift"))

        XCTAssertTrue(source.contains("@State private var appleTranslationSourceLanguage"))
        XCTAssertTrue(source.contains("Picker(localizer.t(L.Settings.sourceLanguage)"))
        XCTAssertTrue(source.contains("appleTranslationReadinessContext()"))
        XCTAssertTrue(source.contains(".onChange(of: appleTranslationSourceLanguage)"))

        let readinessContextBody = try XCTUnwrap(functionBody(named: "appleTranslationReadinessContext", in: source))
        // B：目标语言来自设置（单一漏斗），源语言仍来自用户可见的选择器。
        XCTAssertTrue(readinessContextBody.contains("draft.makeTranslationContext(sourceLanguage: nil)"))
        XCTAssertTrue(readinessContextBody.contains("draft.makeTranslationContext(sourceLanguage: appleTranslationSourceLanguage)"))
        XCTAssertFalse(readinessContextBody.contains("targetLanguage: \"zh-Hans\""))
    }

    func testAppleTranslationPickerVisibilityAndRuntimeReadinessUseExpectedContext() throws {
        let source = try String(contentsOf: packageRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("Moongate")
            .appendingPathComponent("SettingsView.swift"))

        let pickerVisibilityBody = try XCTUnwrap(functionBody(named: "shouldShowAppleTranslationSourceLanguagePicker", in: source))
        let compactPickerVisibilityBody = compactWhitespace(pickerVisibilityBody)
        XCTAssertTrue(compactPickerVisibilityBody.contains("case .appleTranslationLowLatency, .appleTranslationHighFidelity: return true"))
        XCTAssertTrue(compactPickerVisibilityBody.contains("case .anthropicCompatible, .openAICompatible, .appleFoundationOnDevice, .appleFoundationPCC, .appleFoundationCloudPro: return false"))

        let refreshReadinessBody = try XCTUnwrap(functionBody(named: "refreshDraftRuntimeReadiness", in: source))
        XCTAssertTrue(refreshReadinessBody.contains("let context = appleTranslationReadinessContext()"))
        XCTAssertTrue(refreshReadinessBody.contains("translationRuntimeReadiness("))
        XCTAssertTrue(refreshReadinessBody.contains("context: context"))
    }

    func testAPICredentialCopyKeepsProtocolDetailsBehindDisclosure() throws {
        let source = try String(contentsOf: packageRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("Moongate")
            .appendingPathComponent("SettingsView.swift"))

        let apiFieldsBody = try XCTUnwrap(functionBody(named: "apiTranslationFields", in: source))
        XCTAssertTrue(apiFieldsBody.contains("DisclosureGroup"))
        XCTAssertTrue(apiFieldsBody.contains("credentialSummaryText"))
        XCTAssertTrue(apiFieldsBody.contains("credentialDetailText"))
        XCTAssertLessThan(
            try XCTUnwrap(apiFieldsBody.range(of: "credentialSummaryText")).lowerBound,
            try XCTUnwrap(apiFieldsBody.range(of: "DisclosureGroup")).lowerBound,
            "Credential summary should stay always-visible, outside the advanced disclosure."
        )

        let summaryBody = try XCTUnwrap(functionBody(named: "credentialSummaryText", in: source))
        let technicalTerms = [
            "ANTHROPIC_BASE_URL",
            "ANTHROPIC_AUTH_TOKEN",
            "Responses API",
            "Bearer",
            "DeepSeek",
        ]
        for term in technicalTerms {
            XCTAssertFalse(summaryBody.contains(term), "\(term) should stay out of always-visible credential copy")
        }

        let detailBody = try XCTUnwrap(functionBody(named: "credentialDetailText", in: source))
        XCTAssertTrue(detailBody.contains("localizer.t(L.Settings.credentialDetailAnthropic)"))
        XCTAssertTrue(detailBody.contains("localizer.t(L.Settings.credentialDetailOpenAI)"))
        XCTAssertFalse(detailBody.contains("appleTranslation"))
        XCTAssertFalse(detailBody.contains("appleFoundation"))
        XCTAssertFalse(detailBody.contains("PCC"))
    }

    func testAPICredentialCopyNamesOnlyUserTriggeredNetworkActions() throws {
        let source = try String(contentsOf: packageRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("Moongate")
            .appendingPathComponent("SettingsView.swift"))

        let summaryBody = try XCTUnwrap(functionBody(named: "credentialSummaryText", in: source))
        XCTAssertTrue(summaryBody.contains("localizer.t(L.Settings.credentialSummary)"))
        XCTAssertFalse(summaryBody.contains("测试连接前不会发送"))

        let apiFieldsBody = try XCTUnwrap(functionBody(named: "apiTranslationFields", in: source))
        XCTAssertTrue(apiFieldsBody.contains("Text(credentialSummaryText)"))
        XCTAssertLessThan(
            try XCTUnwrap(apiFieldsBody.range(of: "Text(credentialSummaryText)")).lowerBound,
            try XCTUnwrap(apiFieldsBody.range(of: "DisclosureGroup")).lowerBound,
            "Credential summary must remain visible before advanced protocol details."
        )
    }

    func testDefaultAIConnectionActionsDoNotUseTranslationOverrideEndpoint() throws {
        let source = try String(contentsOf: packageRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("Moongate")
            .appendingPathComponent("SettingsView.swift"))

        let testBody = try XCTUnwrap(functionBody(named: "runConnectionTest", in: source))
        XCTAssertTrue(testBody.contains("draft.applyingTranslationConfig(defaultAIConfig)"))
        XCTAssertFalse(testBody.contains("draft.effectiveTranslationConfig"))

        let fetchBody = try XCTUnwrap(functionBody(named: "fetchModels", in: source))
        XCTAssertTrue(fetchBody.contains("draft.applyingTranslationConfig(defaultAIConfig)"))
        XCTAssertFalse(fetchBody.contains("draft.effectiveTranslationConfig"))

        let apiFieldsBody = try XCTUnwrap(functionBody(named: "apiTranslationFields", in: source))
        XCTAssertTrue(apiFieldsBody.contains("!draft.applyingTranslationConfig(defaultAIConfig).isTranslationConfigured"))
        XCTAssertFalse(apiFieldsBody.contains("!draft.translationReadiness().isReady"))

        let configBody = try XCTUnwrap(functionBody(named: "defaultAIConfig", in: source))
        XCTAssertTrue(configBody.contains("engine: draft.aiEngine"))
        XCTAssertTrue(configBody.contains("baseURL: draft.aiBaseURL"))
        XCTAssertTrue(configBody.contains("model: draft.aiModel"))
        XCTAssertTrue(configBody.contains("authToken: draft.aiAuthToken"))
    }

    func testAPITranslationProgressIndicatorsExposeAccessibleLabels() throws {
        let source = try String(contentsOf: packageRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("Moongate")
            .appendingPathComponent("SettingsView.swift"))

        let apiFieldsBody = try XCTUnwrap(functionBody(named: "apiTranslationFields", in: source))

        let modelProgressStart = try XCTUnwrap(apiFieldsBody.range(of: "ProgressView().controlSize(.small)"))
        let modelProgressEnd = try XCTUnwrap(apiFieldsBody.range(
            of: "case .loaded",
            range: modelProgressStart.upperBound..<apiFieldsBody.endIndex
        ))
        let modelProgressSnippet = String(apiFieldsBody[modelProgressStart.lowerBound..<modelProgressEnd.lowerBound])
        XCTAssertTrue(modelProgressSnippet.contains(".accessibilityLabel(localizer.t(L.Settings.fetchingModels))"))

        let testProgressStart = try XCTUnwrap(apiFieldsBody.range(of: "case .testing:"))
        let testProgressEnd = try XCTUnwrap(apiFieldsBody.range(
            of: "case .success:",
            range: testProgressStart.upperBound..<apiFieldsBody.endIndex
        ))
        let testProgressSnippet = String(apiFieldsBody[testProgressStart.lowerBound..<testProgressEnd.lowerBound])
        XCTAssertTrue(testProgressSnippet.contains(".accessibilityLabel(localizer.t(L.Settings.testingConnection))"))
    }

    func testClearLoginActionExplainsAppScopedSideEffects() throws {
        let source = try String(contentsOf: packageRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("Moongate")
            .appendingPathComponent("SettingsView.swift"))

        let loginSectionBody = try XCTUnwrap(functionBody(named: "loginSection", in: source))
        let outerButtonRange = try XCTUnwrap(loginSectionBody.range(of: "Button(localizer.t(L.Settings.clearAppLogin), role: .destructive)"))
        let confirmationDialogRange = try XCTUnwrap(loginSectionBody.range(of: ".confirmationDialog"))
        let outerClearLoginButton = String(loginSectionBody[outerButtonRange.lowerBound..<confirmationDialogRange.lowerBound])

        XCTAssertTrue(outerClearLoginButton.contains("Button(localizer.t(L.Settings.clearAppLogin), role: .destructive)"))
        XCTAssertTrue(outerClearLoginButton.contains(".accessibilityHint(clearLoginHelpText)"))
        XCTAssertTrue(loginSectionBody.contains("Text(clearLoginHelpText)"))
        XCTAssertTrue(loginSectionBody.contains("localizer.t(L.Settings.clearLoginDialogTitle)"))
        XCTAssertTrue(loginSectionBody.contains("Button(localizer.t(L.Settings.clearLoginAction), role: .destructive)"))
        XCTAssertTrue(loginSectionBody.contains("Button(localizer.t(L.Common.cancel), role: .cancel)"))
        XCTAssertFalse(loginSectionBody.contains("\"确定要清除所有登录吗？\""))
        XCTAssertFalse(loginSectionBody.contains("Button(\"清除所有登录\", role: .destructive)"))

        XCTAssertTrue(source.contains("private var clearLoginHelpText"))
        let clearLoginHelpTextBody = try XCTUnwrap(functionBody(named: "clearLoginHelpText", in: source))
        XCTAssertTrue(clearLoginHelpTextBody.contains("localizer.t(L.Settings.clearLoginHelp)"))
    }

    func testCloudCredentialSurfaceStaysLimitedToAPICompatibleProviders() throws {
        let source = try String(contentsOf: packageRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("Moongate")
            .appendingPathComponent("SettingsView.swift"))

        let translationSectionBody = try XCTUnwrap(functionBody(named: "translationSection", in: source))
        XCTAssertTrue(translationSectionBody.contains("if draft.aiEngine.requiresCloudConfiguration"))
        XCTAssertTrue(translationSectionBody.contains("apiTranslationFields"))
        XCTAssertTrue(translationSectionBody.contains("appleTranslationReadiness"))

        let apiFieldsBody = try XCTUnwrap(functionBody(named: "apiTranslationFields", in: source))
        XCTAssertFalse(apiFieldsBody.contains("TranslationEngine.allCases"))
        XCTAssertFalse(apiFieldsBody.contains("appleTranslation"))
        XCTAssertFalse(apiFieldsBody.contains("appleFoundation"))
        XCTAssertFalse(apiFieldsBody.contains("PCC"))

        let apiProviderBody = try XCTUnwrap(functionBody(named: "apiProvider", in: source))
        XCTAssertTrue(apiProviderBody.contains("draft.aiEngine.legacyProvider ?? .anthropic"))

        let detailBody = try XCTUnwrap(functionBody(named: "credentialDetailText", in: source))
        XCTAssertTrue(detailBody.contains("switch apiProvider"))
        XCTAssertTrue(detailBody.contains("case .anthropic"))
        XCTAssertTrue(detailBody.contains("case .openai"))
        XCTAssertFalse(detailBody.contains("appleTranslation"))
        XCTAssertFalse(detailBody.contains("appleFoundation"))
        XCTAssertFalse(detailBody.contains("PCC"))
    }

    func testAppleReadinessPanelExposesStateAndFallbackSemantics() throws {
        let source = try String(contentsOf: packageRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("Moongate")
            .appendingPathComponent("SettingsView.swift"))

        let readinessBody = try XCTUnwrap(functionBody(named: "appleTranslationReadiness", in: source))
        XCTAssertTrue(readinessBody.contains(".accessibilityElement(children: .combine)"))
        XCTAssertTrue(readinessBody.contains(".accessibilityLabel(localizer.t(L.Settings.appleTranslationStatus))"))
        XCTAssertTrue(readinessBody.contains("let statusText = readiness.isReady ? localizer.t(L.Settings.statusReady) : localizer.t(L.Settings.statusNeedsAction)"))
        XCTAssertTrue(readinessBody.contains(".accessibilityValue(\"\\(draft.aiEngine.displayName)，\\(statusText)：\\(readinessMessage(readiness))\")"))

        let guidanceBody = try XCTUnwrap(functionBody(named: "appleSetupGuidance", in: source))
        XCTAssertTrue(guidanceBody.contains("fallbackEngineText"))
        XCTAssertTrue(guidanceBody.contains("Text(fallbackEngineText)"))
        XCTAssertTrue(guidanceBody.contains(".accessibilityHint(localizer.t(L.Settings.fallbackEngineHint))"))

        let fallbackBody = try XCTUnwrap(functionBody(named: "fallbackEngineText", in: source))
        XCTAssertTrue(fallbackBody.contains("localizer.t(L.Settings.fallbackEngine)"))
        XCTAssertFalse(fallbackBody.contains("Apple 本机引擎"))
        XCTAssertFalse(fallbackBody.contains("PCC"))
        XCTAssertFalse(fallbackBody.localizedCaseInsensitiveContains("Cloud Pro"))
        XCTAssertFalse(fallbackBody.contains("云端"))
        XCTAssertFalse(fallbackBody.contains("NSWorkspace"))
        XCTAssertFalse(fallbackBody.localizedCaseInsensitiveContains("token"))
        XCTAssertFalse(fallbackBody.localizedCaseInsensitiveContains("cookie"))
    }

    func testAppleReadinessPanelShowsScannableEngineStatusSummary() throws {
        let source = try String(contentsOf: packageRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("Moongate")
            .appendingPathComponent("SettingsView.swift"))

        let readinessBody = try XCTUnwrap(functionBody(named: "appleTranslationReadiness", in: source))
        XCTAssertTrue(readinessBody.contains("let statusText = readiness.isReady ? localizer.t(L.Settings.statusReady) : localizer.t(L.Settings.statusNeedsAction)"))
        XCTAssertTrue(readinessBody.contains("Text(localizer.t(L.Settings.currentEngine))"))
        XCTAssertTrue(readinessBody.contains("Text(draft.aiEngine.displayName)"))
        XCTAssertTrue(readinessBody.contains("Text(localizer.t(L.Settings.status))"))
        XCTAssertTrue(readinessBody.contains("Text(statusText)"))
        XCTAssertTrue(readinessBody.contains("Text(localizer.t(L.Settings.primaryReason))"))
        XCTAssertTrue(readinessBody.contains("Text(readinessMessage(readiness))"))
        XCTAssertTrue(readinessBody.contains(".accessibilityValue(\"\\(draft.aiEngine.displayName)，\\(statusText)：\\(readinessMessage(readiness))\")"))
        XCTAssertFalse(readinessBody.contains("Text(\"中文字幕翻译状态\")"))
        XCTAssertTrue(readinessBody.contains("if !readiness.isReady"))
        XCTAssertTrue(readinessBody.contains("appleSetupGuidance(guidance)"))

        let guidanceBody = try XCTUnwrap(functionBody(named: "appleSetupGuidance", in: source))
        XCTAssertTrue(guidanceBody.contains("Text(fallbackEngineText)"))

        let fallbackBody = try XCTUnwrap(functionBody(named: "fallbackEngineText", in: source))
        XCTAssertTrue(fallbackBody.contains("localizer.t(L.Settings.fallbackEngine)"))
        XCTAssertFalse(fallbackBody.contains("Apple 本机引擎"))
        XCTAssertFalse(fallbackBody.contains("PCC"))
        XCTAssertFalse(fallbackBody.localizedCaseInsensitiveContains("Cloud Pro"))
        XCTAssertFalse(fallbackBody.contains("云端"))
    }

    func testDependencyStatusRowsExposeCombinedAccessibilitySemantics() throws {
        let source = try String(contentsOf: packageRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("Moongate")
            .appendingPathComponent("SettingsView.swift"))

        let dependencySectionBody = try XCTUnwrap(functionBody(named: "dependencySection", in: source))
        let rowsStart = try XCTUnwrap(dependencySectionBody.range(of: "ForEach(dependencyComponents)"))
        let rowsEnd = try XCTUnwrap(dependencySectionBody.range(
            of: "HStack(spacing: 10)",
            range: rowsStart.upperBound..<dependencySectionBody.endIndex
        ))
        let componentRowsBody = String(dependencySectionBody[rowsStart.lowerBound..<rowsEnd.lowerBound])

        XCTAssertTrue(componentRowsBody.contains(".accessibilityElement(children: .combine)"))
        XCTAssertTrue(componentRowsBody.contains(".accessibilityLabel(componentAccessibilityLabel(component))"))
        XCTAssertTrue(componentRowsBody.contains(".accessibilityValue(componentReadyText(component))"))
        XCTAssertFalse(componentRowsBody.contains(".accessibilityHint("))

        let helperBody = try XCTUnwrap(functionBody(named: "componentAccessibilityLabel", in: source))
        XCTAssertTrue(helperBody.contains("component.id"))
        XCTAssertTrue(helperBody.contains("componentPurposeText(component)"))
        XCTAssertTrue(helperBody.contains("localizer.t(L.Dependency.componentAccessibilityLabel"))
    }

    func testAppleSetupActionButtonsExposeSideEffectHelp() throws {
        let source = try String(contentsOf: packageRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("Moongate")
            .appendingPathComponent("SettingsView.swift"))

        let guidanceBody = try XCTUnwrap(functionBody(named: "appleSetupGuidance", in: source))
        XCTAssertTrue(guidanceBody.contains("ForEach(guidance.actions)"))
        XCTAssertTrue(guidanceBody.contains("Button(appleSetupActionTitle(action.kind))"))
        XCTAssertTrue(guidanceBody.contains("performAppleSetupAction(action)"))

        let buttonStart = try XCTUnwrap(guidanceBody.range(of: "Button(appleSetupActionTitle(action.kind))"))
        let buttonEnd = guidanceBody.range(
            of: ".buttonStyle(.bordered)",
            range: buttonStart.upperBound..<guidanceBody.endIndex
        )?.upperBound ?? guidanceBody.endIndex
        let actionButtonSnippet = String(guidanceBody[buttonStart.lowerBound..<buttonEnd])
        XCTAssertTrue(actionButtonSnippet.contains(".help(appleSetupActionHelpText(action.kind))"))
        XCTAssertTrue(actionButtonSnippet.contains(".accessibilityHint(appleSetupActionHelpText(action.kind))"))

        XCTAssertTrue(source.contains("private func appleSetupActionHelpText(_ kind: AppleTranslationSetupActionKind) -> String"))
        let helpTextBody = try XCTUnwrap(functionBody(named: "appleSetupActionHelpText", in: source))
        XCTAssertTrue(helpTextBody.contains("localizer.t(L.Settings.appleActionRefreshHelp)"))
        XCTAssertTrue(helpTextBody.contains("localizer.t(L.Settings.appleActionOpenLanguageSettingsHelp)"))
        XCTAssertTrue(helpTextBody.contains("localizer.t(L.Settings.appleActionChooseDifferentEngineHelp)"))
        XCTAssertFalse(helpTextBody.contains("切回 Apple 引擎"))

        let appleIntelligenceCaseStart = try XCTUnwrap(
            helpTextBody.range(of: "case .openAppleIntelligenceSettings:")
        )
        let appleIntelligenceCaseEnd = try XCTUnwrap(
            helpTextBody.range(
                of: "case .chooseDifferentEngine:",
                range: appleIntelligenceCaseStart.upperBound..<helpTextBody.endIndex
            )
        )
        let appleIntelligenceHelpSnippet = String(
            helpTextBody[appleIntelligenceCaseStart.lowerBound..<appleIntelligenceCaseEnd.lowerBound]
        )
        XCTAssertTrue(appleIntelligenceHelpSnippet.contains("localizer.t(L.Settings.appleActionOpenAppleIntelligenceSettingsHelp)"))
        XCTAssertFalse(appleIntelligenceHelpSnippet.contains("Anthropic-compatible"))
    }

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func functionBody(named name: String, in source: String) -> String? {
        let declarations = [
            "private func \(name)(",
            "private var \(name):",
            "private var \(name) "
        ]
        guard let declaration = declarations.compactMap({ source.range(of: $0) }).first else { return nil }
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
