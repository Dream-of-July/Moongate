import XCTest

final class MacOSDependencyBoundaryTests: XCTestCase {
    func testDependencySetupSideEffectButtonsExposeHelpAndAccessibilityHints() throws {
        let source = try dependencySetupSource()
        let sheetBody = try XCTUnwrap(functionBody(prefix: "var body", in: source))

        let openBrewButton = try XCTUnwrap(sourceSlice(
            from: "Button(\"打开 brew.sh\")",
            to: "if let errorText",
            in: sheetBody
        ))
        XCTAssertTrue(openBrewButton.contains("NSWorkspace.shared.open(URL(string: \"https://brew.sh/zh-cn/\")!)"))
        assertButtonCopy(
            openBrewButton,
            help: "用默认浏览器打开 Homebrew 网站。你需要手动安装 Homebrew，App 不会自动安装 Homebrew。",
            hint: "会用默认浏览器打开 Homebrew 网站；你需要手动安装 Homebrew，App 不会自动安装 Homebrew。"
        )

        let refreshButton = try XCTUnwrap(sourceSlice(
            from: "Button(\"重新检测\")",
            to: "Spacer()",
            in: sheetBody
        ))
        XCTAssertTrue(refreshButton.contains("installer.refresh()"))
        XCTAssertTrue(refreshButton.contains(".disabled(installer.isRunning"))
        assertButtonCopy(
            refreshButton,
            help: "重新检查本机依赖状态，不安装或下载任何组件。",
            hint: "只重新检查本机依赖状态，不安装或下载任何组件。"
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
            help: "运行 brew install 安装缺失组件，可能下载 Homebrew 公式及其依赖。",
            hint: "会运行 brew install 安装缺失组件，可能下载 Homebrew 公式及其依赖。"
        )
    }

    func testDependencySetupCloseButtonExplainsInstallCancellationScope() throws {
        let source = try dependencySetupSource()
        let sheetBody = try XCTUnwrap(functionBody(prefix: "var body", in: source))

        let closeButton = try XCTUnwrap(sourceSlice(
            from: "installer.cancel()",
            to: "if installer.allInstalled",
            in: sheetBody
        ))
        XCTAssertTrue(closeButton.contains("Text(installer.isRunning ? \"取消安装并关闭\" : \"关闭\")"))
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
        XCTAssertTrue(helpBody.contains("终止当前 Homebrew 安装进程"))
        XCTAssertTrue(helpBody.contains("不会自动回滚 Homebrew 已经完成的改动"))
        XCTAssertTrue(helpBody.contains("关闭这个窗口"))
        XCTAssertFalse(helpBody.contains("installer.install()"))
    }

    func testDependencyUninstallIsConfirmationGatedAndDestructive() throws {
        let source = try dependencySetupSource()
        let sheetBody = try XCTUnwrap(functionBody(prefix: "var body", in: source))

        // 删除按钮只在「已检测 + brew 可用 + 有已安装组件」时出现，且只置位确认 flag，
        // 绝不直接 installer.uninstall()。
        let deleteButton = try XCTUnwrap(sourceSlice(
            from: "Button(\"删除依赖\", role: .destructive)",
            to: "Spacer()",
            in: sheetBody
        ))
        XCTAssertTrue(deleteButton.contains("showUninstallConfirm = true"))
        XCTAssertFalse(deleteButton.contains("installer.uninstall()"))
        XCTAssertTrue(sheetBody.contains("installer.hasChecked && installer.brewAvailable && installer.hasInstalled"))

        // 真正的卸载只发生在确认 alert 的 destructive 按钮里。
        let alertBlock = try XCTUnwrap(sourceSlice(
            from: ".alert(\"删除依赖组件？\"",
            to: "} message:",
            in: sheetBody
        ))
        XCTAssertTrue(alertBlock.contains("Button(\"取消\", role: .cancel)"))
        XCTAssertTrue(alertBlock.contains("Button(\"删除\", role: .destructive)"))
        XCTAssertTrue(alertBlock.contains("installer.uninstall()"))
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

        let helperBody = try XCTUnwrap(
            functionBody(prefix: "private func componentAccessibilityLabel", in: source)
        )
        XCTAssertTrue(helperBody.contains("component.id"))
        XCTAssertTrue(helperBody.contains("component.purpose"))
        XCTAssertTrue(helperBody.contains("return \"\\(component.id)，\\(component.purpose)\""))

        XCTAssertTrue(sheetBody.contains(".accessibilityLabel(\"Homebrew 安装日志\")"))

        let progressStart = try XCTUnwrap(sheetBody.range(of: "ProgressView()"))
        let progressEnd = try XCTUnwrap(sheetBody[progressStart.lowerBound...].range(of: "Text(\"安装中…\")"))
        let progressBody = String(sheetBody[progressStart.lowerBound..<progressEnd.upperBound])
        XCTAssertTrue(progressBody.contains(".accessibilityLabel(\"正在安装缺失组件\")"))
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
        help: String,
        hint: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            source.contains(".help(\"\(help)\")"),
            "Expected button source to expose help: \(help)",
            file: file,
            line: line
        )
        XCTAssertTrue(
            source.contains(".accessibilityHint(\"\(hint)\")"),
            "Expected button source to expose accessibility hint: \(hint)",
            file: file,
            line: line
        )
    }
}
