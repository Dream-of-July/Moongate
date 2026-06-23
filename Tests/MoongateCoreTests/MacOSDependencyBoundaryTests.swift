import XCTest

final class MacOSDependencyBoundaryTests: XCTestCase {
    func testDependencySetupSideEffectButtonsExposeHelpAndAccessibilityHints() throws {
        let source = try dependencySetupSource()
        let sheetBody = try XCTUnwrap(functionBody(prefix: "var body", in: source))

        XCTAssertTrue(source.contains("@EnvironmentObject private var localizer: Localizer"))

        let openBrewButton = try XCTUnwrap(sourceSlice(
            from: "Button(localizer.t(L.Dependency.openBrew))",
            to: "if let errorText",
            in: sheetBody
        ))
        XCTAssertTrue(openBrewButton.contains("NSWorkspace.shared.open(URL(string: \"https://brew.sh/zh-cn/\")!)"))
        assertButtonCopy(
            openBrewButton,
            helpExpression: "localizer.t(L.Dependency.openBrewHelp)",
            hintExpression: "localizer.t(L.Dependency.openBrewHint)"
        )

        let refreshButton = try XCTUnwrap(sourceSlice(
            from: "Button(localizer.t(L.Dependency.refresh))",
            to: "Spacer()",
            in: sheetBody
        ))
        XCTAssertTrue(refreshButton.contains("installer.refresh()"))
        XCTAssertTrue(refreshButton.contains(".disabled(installer.isRunning"))
        assertButtonCopy(
            refreshButton,
            helpExpression: "localizer.t(L.Dependency.refreshHelp)",
            hintExpression: "localizer.t(L.Dependency.refreshHint)"
        )

        let installButton = try XCTUnwrap(sourceSlice(
            from: "installer.install()",
            to: ".padding(20)",
            in: sheetBody
        ))
        XCTAssertTrue(installButton.contains("installer.install()"))
        XCTAssertTrue(installButton.contains(".disabled(installer.isRunning)"))
        assertButtonCopy(
            installButton,
            helpExpression: "localizer.t(L.Dependency.installHelp)",
            hintExpression: "localizer.t(L.Dependency.installHint)"
        )

        XCTAssertTrue(sheetBody.contains("installer.installOptional(component)"))
        XCTAssertTrue(sheetBody.contains("model.openLocalASRSettings()"))
        XCTAssertTrue(sheetBody.contains("localizer.t(L.Dependency.installOptional)"))
        XCTAssertTrue(sheetBody.contains("localizer.t(L.Dependency.configureOptional)"))
    }

    func testDependencySetupCloseButtonExplainsInstallCancellationScope() throws {
        let source = try dependencySetupSource()
        let sheetBody = try XCTUnwrap(functionBody(prefix: "var body", in: source))

        let closeButton = try XCTUnwrap(sourceSlice(
            from: "installer.cancel()",
            to: "if installer.allInstalled",
            in: sheetBody
        ))
        XCTAssertTrue(closeButton.contains("Text(installer.isRunning ? localizer.t(L.Dependency.cancelInstallAndClose) : localizer.t(L.Common.close))"))
        XCTAssertTrue(closeButton.contains("installer.cancel()"))
        XCTAssertTrue(closeButton.contains("model.closeDependencySetup()"))
        XCTAssertTrue(closeButton.contains(".help(closeButtonHelpText)"))
        XCTAssertTrue(closeButton.contains(".accessibilityHint(closeButtonHelpText)"))
        XCTAssertFalse(closeButton.contains("installer.install()"))
        XCTAssertFalse(closeButton.contains("NSWorkspace.shared.open"))
        XCTAssertFalse(closeButton.localizedCaseInsensitiveContains("token"))
        XCTAssertFalse(closeButton.localizedCaseInsensitiveContains("cookie"))

        let helpBody = try XCTUnwrap(functionBody(prefix: "private var closeButtonHelpText", in: source))
        XCTAssertTrue(helpBody.contains("installer.isRunning"))
        XCTAssertTrue(helpBody.contains("localizer.t(L.Dependency.closeRunningHelp)"))
        XCTAssertTrue(helpBody.contains("localizer.t(L.Dependency.closeIdleHelp)"))
        XCTAssertFalse(helpBody.contains("installer.install()"))
    }

    func testDependencyUninstallFeatureRemoved() throws {
        // MAC-DEP-001：App 不应替用户管理全局 Homebrew 环境（检测到的 ffmpeg/JS 运行时
        // 可能是用户为别的项目装的）。在 App 内提供「卸载依赖」会误伤其它工具，已整体移除。
        let source = try dependencySetupSource()
        XCTAssertFalse(source.contains("func uninstall()"))
        XCTAssertFalse(source.contains("installer.uninstall()"))
        XCTAssertFalse(source.contains("showUninstallConfirm"))
        XCTAssertFalse(source.contains("brew uninstall"))
        XCTAssertFalse(source.contains("uninstallIncomplete"))
        XCTAssertFalse(source.contains("L.Dependency.deleteDependencies"))
        XCTAssertFalse(source.contains("L.Dependency.uninstallAlertTitle"))
        // 安装路径仍在。
        XCTAssertTrue(source.contains("func install()"))
        XCTAssertTrue(source.contains("subcommand: \"install\""))
    }

    func testDependencySetupSheetExposesAccessibleStatusSemantics() throws {
        let source = try dependencySetupSource()
        let sheetBody = try XCTUnwrap(functionBody(prefix: "var body", in: source))

        let rowStart = try XCTUnwrap(sheetBody.range(of: "HStack(spacing: 10)"))
        let rowEnd = try XCTUnwrap(sheetBody[rowStart.lowerBound...].range(
            of: "if component.id != installer.components.last?.id"
        ))
        let componentRowBody = String(sheetBody[rowStart.lowerBound..<rowEnd.lowerBound])

        XCTAssertTrue(componentRowBody.contains(".accessibilityElement(children: .combine)"))
        XCTAssertTrue(componentRowBody.contains(".accessibilityLabel(componentAccessibilityLabel(component))"))
        XCTAssertTrue(componentRowBody.contains(".accessibilityValue(componentStatusText(component))"))
        XCTAssertTrue(componentRowBody.contains("localizer.t(L.Dependency.optionalBadge)"))
        XCTAssertTrue(componentRowBody.contains("component.id == \"whisper-cli\""))

        let helperBody = try XCTUnwrap(
            functionBody(prefix: "private func componentAccessibilityLabel", in: source)
        )
        XCTAssertTrue(helperBody.contains("component.id"))
        XCTAssertTrue(helperBody.contains("componentPurposeText(component)"))
        XCTAssertTrue(helperBody.contains("localizer.t(L.Dependency.componentAccessibilityLabel"))

        let purposeBody = try XCTUnwrap(functionBody(prefix: "private func componentPurposeText", in: source))
        XCTAssertTrue(purposeBody.contains("case \"whisper-cli\": return localizer.t(L.Dependency.purposeWhisperCpp)"))

        XCTAssertTrue(sheetBody.contains(".accessibilityLabel(localizer.t(L.Dependency.logAccessibility))"))

        let progressStart = try XCTUnwrap(sheetBody.range(of: "ProgressView()"))
        let progressEnd = try XCTUnwrap(sheetBody[progressStart.lowerBound...].range(of: "Text(localizer.t(L.Dependency.installing))"))
        let progressBody = String(sheetBody[progressStart.lowerBound..<progressEnd.upperBound])
        XCTAssertTrue(progressBody.contains(".accessibilityLabel(localizer.t(L.Dependency.installingMissingAccessibility))"))
    }

    private func dependencySetupSource() throws -> String {
        try String(contentsOf: packageRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("Moongate")
            .appendingPathComponent("DependencySetupView.swift"))
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

    private func sourceSlice(from marker: String, to endMarker: String, in source: String) -> String? {
        guard let start = source.range(of: marker) else { return nil }
        guard let end = source[start.upperBound...].range(of: endMarker) else { return nil }
        return String(source[start.lowerBound..<end.lowerBound])
    }

    private func assertButtonCopy(
        _ source: String,
        helpExpression: String,
        hintExpression: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            source.contains(".help(\(helpExpression))"),
            "Expected button source to expose help expression: \(helpExpression)",
            file: file,
            line: line
        )
        XCTAssertTrue(
            source.contains(".accessibilityHint(\(hintExpression))"),
            "Expected button source to expose accessibility hint expression: \(hintExpression)",
            file: file,
            line: line
        )
    }
}
