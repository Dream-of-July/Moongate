import XCTest

final class MacOSAppBoundaryTests: XCTestCase {
    func testAppSettingsCommandOpensStandaloneSettingsWindow() throws {
        let source = try appSource()
        let commandBody = try XCTUnwrap(functionBody(prefix: "CommandGroup(replacing: .appSettings)", in: source))

        XCTAssertTrue(source.contains(".commands {"))
        XCTAssertTrue(source.contains("CommandGroup(replacing: .appSettings)"))
        XCTAssertTrue(commandBody.contains("model.showSettings = true"))
        XCTAssertTrue(commandBody.contains(".keyboardShortcut(\",\", modifiers: .command)"))
        // 不使用 SwiftUI 的 Settings 场景（那是 preferences 风格）；命令本身也不直接构造 SettingsView。
        XCTAssertFalse(source.contains("Settings {"))
        XCTAssertFalse(commandBody.contains("SettingsView(model:"))
        // 11c：设置改为独立 Window 场景，只保留红灯关闭；关闭时复位 showSettings 并消费挂起动作。
        XCTAssertTrue(source.contains("Window(localizer.t(L.App.settingsWindowTitle), id: \"settings\")"))
        XCTAssertTrue(source.contains("SettingsView(model: model)"))
        XCTAssertTrue(source.contains("SettingsWindowAccessor()"))
        XCTAssertTrue(source.contains("standardWindowButton(.miniaturizeButton)?.isHidden = true"))
        XCTAssertTrue(source.contains("standardWindowButton(.zoomButton)?.isHidden = true"))
        XCTAssertTrue(source.contains("window.styleMask.remove([.miniaturizable, .resizable])"))
        XCTAssertTrue(source.contains("model.consumePendingSettingsActions()"))
    }

    func testAbortConfirmationExplainsChoicesWithoutChangingButtonsOrReturnMapping() throws {
        let source = try appSource()
        let body = try XCTUnwrap(functionBody(prefix: "private func confirmAbortDownload", in: source))

        XCTAssertTrue(body.contains("alert.informativeText ="))
        XCTAssertTrue(body.contains("localizer.t(L.App.abortInformativeText)"))
        XCTAssertTrue(body.contains("localizer.t(L.App.keepTasks)"))
        XCTAssertTrue(body.contains("localizer.t(L.App.abortTasks)"))
        XCTAssertTrue(body.contains("return alert.runModal() == .alertSecondButtonReturn"))

        let keepButton = try XCTUnwrap(body.range(of: "alert.addButton(withTitle: localizer.t(L.App.keepTasks))"))
        let abortButton = try XCTUnwrap(body.range(of: "alert.addButton(withTitle: localizer.t(L.App.abortTasks))"))
        let abortReturn = try XCTUnwrap(body.range(of: ".alertSecondButtonReturn"))

        XCTAssertLessThan(keepButton.lowerBound, abortButton.lowerBound)
        XCTAssertLessThan(abortButton.lowerBound, abortReturn.lowerBound)

        let messageBody = try XCTUnwrap(functionBody(prefix: "private func abortConfirmationMessage", in: source))
        XCTAssertTrue(messageBody.contains("localizer.t(L.App.abortPausedTasks"))
        XCTAssertTrue(messageBody.contains("localizer.t(L.App.abortRunningTasks"))
    }

    private func appSource() throws -> String {
        try String(contentsOf: packageRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("Moongate")
            .appendingPathComponent("App.swift"))
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
}
