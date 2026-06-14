import XCTest

final class MacOSSettingsBoundaryTests: XCTestCase {
    func testUpdateSectionExposesVersionCheckAndInstallEntry() throws {
        let source = try String(contentsOf: packageRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("Moongate")
            .appendingPathComponent("SettingsView.swift"))
        let body = try XCTUnwrap(functionBody(named: "updateSection", in: source))
        // 当前版本、检查更新、各状态、下载安装、GitHub 兜底。
        XCTAssertTrue(body.contains("updater.currentVersion"))
        XCTAssertTrue(body.contains("updater.check()"))
        XCTAssertTrue(body.contains("updater.downloadAndInstall(info)"))
        XCTAssertTrue(body.contains("case .available(let info)"))
        XCTAssertTrue(body.contains("case .downloading"))
        XCTAssertTrue(body.contains("case .installing"))
        XCTAssertTrue(body.contains("releasesPageURL"))
        // 更新区被挂进 Form（与其他 section 并列）。
        XCTAssertTrue(source.contains("performanceSection"))
        XCTAssertTrue(source.contains("loginSection\n                updateSection")
            || source.contains("updateSection"))
    }

    func testAppleTranslationReadinessUsesUserVisibleSourceLanguageContext() throws {
        let source = try String(contentsOf: packageRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("Moongate")
            .appendingPathComponent("SettingsView.swift"))

        XCTAssertTrue(source.contains("@State private var appleTranslationSourceLanguage"))
        XCTAssertTrue(source.contains("Picker(\"源语言\""))
        XCTAssertTrue(source.contains("appleTranslationReadinessContext()"))
        XCTAssertTrue(source.contains(".onChange(of: appleTranslationSourceLanguage)"))

        let readinessContextBody = try XCTUnwrap(functionBody(named: "appleTranslationReadinessContext", in: source))
        XCTAssertTrue(readinessContextBody.contains("TranslationContext(sourceLanguage: nil, targetLanguage: \"zh-Hans\")"))
        XCTAssertTrue(readinessContextBody.contains("TranslationContext(sourceLanguage: appleTranslationSourceLanguage, targetLanguage: \"zh-Hans\")"))
        XCTAssertFalse(readinessContextBody.contains("TranslationContext(targetLanguage: \"zh-Hans\")"))
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
        for term in technicalTerms {
            XCTAssertTrue(detailBody.contains(term), "\(term) should remain available in advanced credential help")
        }
    }

    func testAPICredentialCopyNamesOnlyUserTriggeredNetworkActions() throws {
        let source = try String(contentsOf: packageRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("Moongate")
            .appendingPathComponent("SettingsView.swift"))

        let summaryBody = try XCTUnwrap(functionBody(named: "credentialSummaryText", in: source))
        XCTAssertTrue(summaryBody.contains("凭证只保存在本机设置中。"))
        XCTAssertTrue(summaryBody.contains("只有点击「拉取模型」或「测试连接」时，才会发送到你填写的服务地址。"))
        XCTAssertFalse(summaryBody.contains("测试连接前不会发送"))

        let apiFieldsBody = try XCTUnwrap(functionBody(named: "apiTranslationFields", in: source))
        XCTAssertTrue(apiFieldsBody.contains("Text(credentialSummaryText)"))
        XCTAssertLessThan(
            try XCTUnwrap(apiFieldsBody.range(of: "Text(credentialSummaryText)")).lowerBound,
            try XCTUnwrap(apiFieldsBody.range(of: "DisclosureGroup")).lowerBound,
            "Credential summary must remain visible before advanced protocol details."
        )
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
        XCTAssertTrue(modelProgressSnippet.contains(".accessibilityLabel(\"正在拉取模型\")"))

        let testProgressStart = try XCTUnwrap(apiFieldsBody.range(of: "case .testing:"))
        let testProgressEnd = try XCTUnwrap(apiFieldsBody.range(
            of: "case .success:",
            range: testProgressStart.upperBound..<apiFieldsBody.endIndex
        ))
        let testProgressSnippet = String(apiFieldsBody[testProgressStart.lowerBound..<testProgressEnd.lowerBound])
        XCTAssertTrue(testProgressSnippet.contains(".accessibilityLabel(\"正在测试连接\")"))
    }

    func testClearLoginActionExplainsAppScopedSideEffects() throws {
        let source = try String(contentsOf: packageRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("Moongate")
            .appendingPathComponent("SettingsView.swift"))

        let loginSectionBody = try XCTUnwrap(functionBody(named: "loginSection", in: source))
        let outerButtonRange = try XCTUnwrap(loginSectionBody.range(of: "Button(\"清除本 App 登录信息\", role: .destructive)"))
        let confirmationDialogRange = try XCTUnwrap(loginSectionBody.range(of: ".confirmationDialog"))
        let outerClearLoginButton = String(loginSectionBody[outerButtonRange.lowerBound..<confirmationDialogRange.lowerBound])

        XCTAssertTrue(outerClearLoginButton.contains("Button(\"清除本 App 登录信息\", role: .destructive)"))
        XCTAssertTrue(outerClearLoginButton.contains(".accessibilityHint(clearLoginHelpText)"))
        XCTAssertTrue(loginSectionBody.contains("Text(clearLoginHelpText)"))
        XCTAssertTrue(loginSectionBody.contains("\"清除本 App 保存的登录信息？\""))
        XCTAssertTrue(loginSectionBody.contains("Button(\"清除登录信息\", role: .destructive)"))
        XCTAssertTrue(loginSectionBody.contains("Button(\"取消\", role: .cancel)"))
        XCTAssertFalse(loginSectionBody.contains("\"确定要清除所有登录吗？\""))
        XCTAssertFalse(loginSectionBody.contains("Button(\"清除所有登录\", role: .destructive)"))

        XCTAssertTrue(source.contains("private var clearLoginHelpText"))
        let clearLoginHelpTextBody = try XCTUnwrap(functionBody(named: "clearLoginHelpText", in: source))
        XCTAssertTrue(clearLoginHelpTextBody.contains("只清除本 App 保存的站点登录信息"))
        XCTAssertTrue(clearLoginHelpTextBody.contains("不会退出浏览器或系统账号"))
        XCTAssertTrue(clearLoginHelpTextBody.contains("需要重新登录才能下载会员/受限视频"))
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
        XCTAssertTrue(readinessBody.contains(".accessibilityLabel(\"Apple 翻译引擎状态\")"))
        XCTAssertTrue(readinessBody.contains("let statusText = readiness.isReady ? \"当前可运行\" : \"需要处理\""))
        XCTAssertTrue(readinessBody.contains(".accessibilityValue(\"\\(draft.aiEngine.displayName)，\\(statusText)：\\(readinessMessage(readiness))\")"))

        let guidanceBody = try XCTUnwrap(functionBody(named: "appleSetupGuidance", in: source))
        XCTAssertTrue(guidanceBody.contains("fallbackEngineText"))
        XCTAssertTrue(guidanceBody.contains("Text(fallbackEngineText)"))
        XCTAssertTrue(guidanceBody.contains(".accessibilityHint(\"如果本机 Apple 能力暂不可用，可以先切换到 API 兼容引擎\")"))

        let fallbackBody = try XCTUnwrap(functionBody(named: "fallbackEngineText", in: source))
        XCTAssertTrue(fallbackBody.contains("可先改用 Anthropic-compatible 或 OpenAI-compatible"))
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
        XCTAssertTrue(readinessBody.contains("let statusText = readiness.isReady ? \"当前可运行\" : \"需要处理\""))
        XCTAssertTrue(readinessBody.contains("Text(\"当前引擎\")"))
        XCTAssertTrue(readinessBody.contains("Text(draft.aiEngine.displayName)"))
        XCTAssertTrue(readinessBody.contains("Text(\"状态\")"))
        XCTAssertTrue(readinessBody.contains("Text(statusText)"))
        XCTAssertTrue(readinessBody.contains("Text(\"首要原因\")"))
        XCTAssertTrue(readinessBody.contains("Text(readinessMessage(readiness))"))
        XCTAssertTrue(readinessBody.contains(".accessibilityValue(\"\\(draft.aiEngine.displayName)，\\(statusText)：\\(readinessMessage(readiness))\")"))
        XCTAssertFalse(readinessBody.contains("Text(\"中文字幕翻译状态\")"))
        XCTAssertTrue(readinessBody.contains("if !readiness.isReady"))
        XCTAssertTrue(readinessBody.contains("appleSetupGuidance(guidance)"))

        let guidanceBody = try XCTUnwrap(functionBody(named: "appleSetupGuidance", in: source))
        XCTAssertTrue(guidanceBody.contains("Text(fallbackEngineText)"))

        let fallbackBody = try XCTUnwrap(functionBody(named: "fallbackEngineText", in: source))
        XCTAssertTrue(fallbackBody.contains("Anthropic-compatible 或 OpenAI-compatible"))
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
        XCTAssertTrue(componentRowsBody.contains(".accessibilityValue(component.isInstalled ? \"已就绪\" : \"待安装\")"))
        XCTAssertFalse(componentRowsBody.contains(".accessibilityHint("))

        let helperBody = try XCTUnwrap(functionBody(named: "componentAccessibilityLabel", in: source))
        XCTAssertTrue(helperBody.contains("component.id"))
        XCTAssertTrue(helperBody.contains("component.purpose"))
    }

    func testAppleSetupActionButtonsExposeSideEffectHelp() throws {
        let source = try String(contentsOf: packageRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("Moongate")
            .appendingPathComponent("SettingsView.swift"))

        let guidanceBody = try XCTUnwrap(functionBody(named: "appleSetupGuidance", in: source))
        XCTAssertTrue(guidanceBody.contains("ForEach(guidance.actions)"))
        XCTAssertTrue(guidanceBody.contains("Button(action.title)"))
        XCTAssertTrue(guidanceBody.contains("performAppleSetupAction(action)"))

        let buttonStart = try XCTUnwrap(guidanceBody.range(of: "Button(action.title)"))
        let buttonEnd = guidanceBody.range(
            of: ".buttonStyle(.bordered)",
            range: buttonStart.upperBound..<guidanceBody.endIndex
        )?.upperBound ?? guidanceBody.endIndex
        let actionButtonSnippet = String(guidanceBody[buttonStart.lowerBound..<buttonEnd])
        XCTAssertTrue(actionButtonSnippet.contains(".help(appleSetupActionHelpText(action.kind))"))
        XCTAssertTrue(actionButtonSnippet.contains(".accessibilityHint(appleSetupActionHelpText(action.kind))"))

        XCTAssertTrue(source.contains("private func appleSetupActionHelpText(_ kind: AppleTranslationSetupActionKind) -> String"))
        let helpTextBody = try XCTUnwrap(functionBody(named: "appleSetupActionHelpText", in: source))
        XCTAssertTrue(helpTextBody.contains("只重新检查当前 Apple 翻译运行状态，不会下载语言包或模型"))
        XCTAssertTrue(helpTextBody.contains("打开系统设置，由你在系统里下载语言包；App 不会自动下载"))
        XCTAssertTrue(helpTextBody.contains("把当前设置草稿切换到 Anthropic-compatible"))
        XCTAssertTrue(helpTextBody.contains("点击「完成」后才保存"))
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
        XCTAssertTrue(appleIntelligenceHelpSnippet.contains("系统设置 > Apple Intelligence 与 Siri"))
        XCTAssertTrue(appleIntelligenceHelpSnippet.contains("查看或启用 Apple Intelligence 和模型准备状态"))
        XCTAssertTrue(appleIntelligenceHelpSnippet.contains("App 不会自动下载、替换模型或更改系统设置"))
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
