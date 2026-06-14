import XCTest

final class MacOSContentBoundaryTests: XCTestCase {
    func testChineseSubtitleRowsUsesAppleGuidanceOnlyForAppleEngines() throws {
        let source = try contentViewSource()
        let rowsBody = try XCTUnwrap(functionBody(prefix: "private func chineseSubtitleRows", in: source))

        XCTAssertTrue(rowsBody.contains("appleTranslationSetupGuidanceView("))
        XCTAssertTrue(rowsBody.contains("compactTranslationReadinessView()"))
        XCTAssertFalse(rowsBody.contains("AppleTranslationSetupGuidance.make("))

        let guidanceBody = try XCTUnwrap(
            functionBody(prefix: "private func appleTranslationSetupGuidanceView", in: source)
        )
        XCTAssertTrue(guidanceBody.contains("AppleTranslationSetupGuidance.make("))
        XCTAssertTrue(guidanceBody.contains("engine: model.settings.translationEngine"))
        XCTAssertTrue(guidanceBody.contains("readiness: readiness"))
        XCTAssertTrue(guidanceBody.contains("guidance.title"))
        XCTAssertTrue(guidanceBody.contains("guidance.steps"))
        XCTAssertTrue(guidanceBody.contains("Button(\"去设置\")"))
        XCTAssertTrue(guidanceBody.contains(".help(\"只打开 App 设置查看系统侧步骤；不会直接打开系统设置、下载语言包、保存配置或切换引擎。\")"))
        XCTAssertTrue(guidanceBody.contains(".accessibilityHint(\"只打开 App 设置查看系统侧步骤；不会直接打开系统设置、下载语言包、保存配置或切换引擎。\")"))
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
        XCTAssertTrue(summaryBody.contains("建议动作：打开 App 设置查看系统侧配置步骤。"))
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
    }

    func testAppleSetupGuidanceShowsAPICompatibleFallbackWithoutChangingSettings() throws {
        let source = try contentViewSource()
        let guidanceBody = try XCTUnwrap(
            functionBody(prefix: "private func appleTranslationSetupGuidanceView", in: source)
        )

        XCTAssertTrue(guidanceBody.contains("Text(appleTranslationSetupFallbackText)"))
        XCTAssertTrue(guidanceBody.contains(".accessibilityHint(\"如果本机 Apple 能力暂不可用，可以先切换到 API 兼容引擎\")"))
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
        XCTAssertTrue(fallbackBody.contains("Anthropic-compatible 或 OpenAI-compatible"))
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
        XCTAssertTrue(summaryBody.contains("Text(\"当前引擎\")"))
        XCTAssertTrue(summaryBody.contains("model.settings.translationEngine.displayName"))
        XCTAssertTrue(summaryBody.contains("Text(\"状态\")"))
        XCTAssertTrue(summaryBody.contains("readiness.isReady ? \"当前可运行\" : \"需要处理\""))
        XCTAssertTrue(summaryBody.contains("Text(\"首要原因\")"))
        XCTAssertTrue(summaryBody.contains("appleTranslationSetupReadinessReason(readiness)"))
        XCTAssertTrue(summaryBody.contains(".accessibilityLabel(\"Apple 翻译引擎状态\")"))
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
        XCTAssertTrue(settingsHeaderBody.contains(".accessibilityLabel(\"打开设置\")"))

        let candidateRowBody = try XCTUnwrap(functionBody(prefix: "private func candidateRow", in: source))
        XCTAssertTrue(candidateRowBody.contains(".accessibilityElement(children: .combine)"))
        XCTAssertTrue(candidateRowBody.contains(".accessibilityLabel(candidate.title)"))
        XCTAssertTrue(candidateRowBody.contains(".accessibilityHint(\"选择这个视频\")"))

        let formatRowBody = try XCTUnwrap(functionBody(prefix: "private func formatRow", in: source))
        XCTAssertTrue(formatRowBody.contains(".accessibilityElement(children: .combine)"))
        XCTAssertTrue(formatRowBody.contains(".accessibilityLabel(format.label)"))
        XCTAssertTrue(formatRowBody.contains(".accessibilityHint(\"选择这个下载格式\")"))
        XCTAssertTrue(formatRowBody.contains(".accessibilityValue("))
        XCTAssertTrue(formatRowBody.contains("model.selectedFormatID == format.id ? \"已选择\" : \"未选择\""))
    }

    func testChineseSubtitleProcessingPickerHasAccessibleState() throws {
        let source = try contentViewSource()
        let rowsBody = try XCTUnwrap(functionBody(prefix: "private func chineseSubtitleRows", in: source))

        XCTAssertTrue(rowsBody.contains("Picker(\"字幕处理\""))
        XCTAssertTrue(rowsBody.contains(".accessibilityLabel(\"字幕处理方式\")"))
        XCTAssertTrue(rowsBody.contains(".accessibilityHint("))
        XCTAssertTrue(rowsBody.contains("hasSubtitleSelected ? \"选择是否生成、翻译或烧录中文字幕\" : \"先在上面勾选一条字幕\""))
        XCTAssertTrue(rowsBody.contains(".accessibilityValue(model.chineseMode.label)"))
    }

    func testChineseSubtitleRowsPrioritizesChineseSourceMessageBeforeReadinessGuidance() throws {
        let source = try contentViewSource()
        let rowsBody = try XCTUnwrap(functionBody(prefix: "private func chineseSubtitleRows", in: source))

        let chineseSourceRange = try XCTUnwrap(rowsBody.range(of: "model.translationSourceIsChinese(in: info)"))
        let readinessGateRange = try XCTUnwrap(rowsBody.range(of: "!readiness.isReady"))
        let directUsePromptRange = try XCTUnwrap(rowsBody.range(of: "该字幕已是中文，将直接使用（不翻译）"))
        let burnInPromptRange = try XCTUnwrap(rowsBody.range(of: "该字幕已是中文，将直接烧录（不翻译）"))

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
        XCTAssertTrue(pasteButtonFragment.contains(".help(\"粘贴并解析剪贴板链接\")"))
        XCTAssertTrue(pasteButtonFragment.contains(".accessibilityLabel(\"粘贴并解析\")"))
        XCTAssertTrue(pasteButtonFragment.contains(".accessibilityHint(\"粘贴剪贴板里的链接并开始解析\")"))
        XCTAssertFalse(pasteButtonFragment.containsVisibleViewLine(prefix: "Label("))
        XCTAssertFalse(pasteButtonFragment.containsVisibleViewLine(prefix: "Text(\"粘贴"))

        let parseButtonBody = try XCTUnwrap(functionBody(prefix: "private var parseButton", in: source))
        XCTAssertTrue(parseButtonBody.contains("Text(\"解析链接\")"))
        XCTAssertTrue(parseButtonBody.contains(".help(\"解析当前输入框中的视频链接\")"))
        XCTAssertTrue(parseButtonBody.contains(".accessibilityHint(\"解析当前输入框中的视频链接\")"))

        let buttonProgressRange = try XCTUnwrap(parseButtonBody.range(of: "ProgressView()"))
        let buttonTextRange = try XCTUnwrap(
            parseButtonBody.range(
                of: "Text(\"解析链接\")",
                range: buttonProgressRange.upperBound..<parseButtonBody.endIndex
            )
        )
        let buttonProgressFragment = String(parseButtonBody[buttonProgressRange.lowerBound..<buttonTextRange.upperBound])
        XCTAssertTrue(buttonProgressFragment.contains(".accessibilityLabel(\"正在解析\")"))

        let loadingStateBody = try XCTUnwrap(functionBody(prefix: "private var loadingState", in: source))
        XCTAssertTrue(loadingStateBody.contains(".accessibilityLabel(model.batchStatusText ?? \"正在解析\")"))
    }

    func testSubtitleRowsExposeManualAndAutoGeneratedAccessibilitySemantics() throws {
        let source = try contentViewSource()
        let rowsBody = try XCTUnwrap(functionBody(prefix: "private func subtitleRows", in: source))

        XCTAssertTrue(rowsBody.contains("accessibilityLabel(subtitleAccessibilityLabel(subtitle))"))
        XCTAssertTrue(rowsBody.contains("accessibilityHint(\"勾选后可下载字幕，或用于中文字幕处理\")"))
        XCTAssertTrue(rowsBody.contains("accessibilityValue(model.selectedSubtitleIDs.contains(subtitle.id) ? \"已选择\" : \"未选择\")"))

        let helperBody = try XCTUnwrap(
            functionBody(prefix: "private func subtitleAccessibilityLabel", in: source)
        )
        XCTAssertTrue(helperBody.contains("subtitle.isAuto"))
        XCTAssertTrue(helperBody.contains("\"\\(subtitle.label)，自动生成字幕\""))
        XCTAssertTrue(helperBody.contains("return subtitle.label"))
    }

    func testReadyFooterCopyDistinguishesSingleAndMultiFileDestinations() throws {
        let source = try contentViewSource()
        let readyBody = try XCTUnwrap(functionBody(prefix: "private func readyState", in: source))

        XCTAssertFalse(readyBody.contains("Text(\"保存到 ~/Downloads · 加入后可继续粘贴下一条\")"))
        XCTAssertTrue(readyBody.contains("Text(readyFooterCopy(for: info))"))

        let helperBody = try XCTUnwrap(functionBody(prefix: "private func readyFooterCopy", in: source))
        XCTAssertTrue(helperBody.contains("readyFooterUsesVideoFolder"))
        XCTAssertTrue(helperBody.contains("ViewModel.sanitizedFolderName(info.title)"))
        XCTAssertTrue(helperBody.contains("保存到 Downloads"))
        XCTAssertTrue(helperBody.contains("文件夹"))
        XCTAssertTrue(helperBody.contains("return \"保存到 Downloads · 加入后可继续粘贴下一条\""))
        XCTAssertTrue(helperBody.contains("加入后可继续粘贴下一条"))
        XCTAssertTrue(helperBody.contains("readyFooterUsesVideoFolder(for: info)"))

        let destinationGateBody = try XCTUnwrap(
            functionBody(prefix: "private func readyFooterUsesVideoFolder", in: source)
        )
        let compactDestinationGate = compactWhitespace(destinationGateBody)
        XCTAssertTrue(compactDestinationGate.contains("let chosen = info.subtitles.filter { model.selectedSubtitleIDs.contains($0.id) }"))
        XCTAssertTrue(compactDestinationGate.contains("return !chosen.isEmpty || model.chineseMode != .off"))
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
