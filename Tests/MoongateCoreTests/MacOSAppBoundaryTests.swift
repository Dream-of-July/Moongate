import XCTest

final class MacOSAppBoundaryTests: XCTestCase {
    func testAppSettingsCommandOpensExistingSettingsSheet() throws {
        let source = try appSource()
        let commandBody = try XCTUnwrap(functionBody(prefix: "CommandGroup(replacing: .appSettings)", in: source))

        XCTAssertTrue(source.contains(".commands {"))
        XCTAssertTrue(source.contains("CommandGroup(replacing: .appSettings)"))
        XCTAssertTrue(commandBody.contains("model.showSettings = true"))
        XCTAssertTrue(commandBody.contains(".keyboardShortcut(\",\", modifiers: .command)"))
        XCTAssertFalse(source.contains("Settings {"))
        XCTAssertFalse(commandBody.contains("SettingsView(model:"))
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
