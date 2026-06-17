import XCTest

final class MacOSQueueBoundaryTests: XCTestCase {
    func testQueueHeaderExposesReadableTaskSummaryWithoutChangingActions() throws {
        let source = try queueSectionSource()
        let body = try XCTUnwrap(functionBody(named: "body", in: source))

        XCTAssertTrue(source.contains("@EnvironmentObject private var localizer: Localizer"))
        XCTAssertTrue(body.contains(".accessibilityElement(children: .combine)"))
        XCTAssertTrue(body.contains(".accessibilityLabel(localizer.t(L.Queue.title))"))
        XCTAssertTrue(body.contains(".accessibilityValue(queueHeaderAccessibilityValue)"))
        XCTAssertTrue(body.contains("queue.clearFinished()"))
        XCTAssertTrue(body.contains("onCollapse()"))

        let summaryBody = try XCTUnwrap(functionBody(named: "queueHeaderAccessibilityValue", in: source))
        XCTAssertTrue(summaryBody.contains("localizer.t(L.Queue.taskCount, queue.items.count)"))
        XCTAssertTrue(summaryBody.contains("queue.openTaskCount"))
        XCTAssertTrue(summaryBody.contains("queue.pausedOpenTaskCount"))
        XCTAssertTrue(summaryBody.contains("localizer.t(L.Queue.headerAllFinished"))
        XCTAssertTrue(summaryBody.contains("localizer.t(L.Queue.headerAllPaused"))
        XCTAssertFalse(summaryBody.contains("queue.clearFinished()"))
        XCTAssertFalse(summaryBody.contains("onCollapse"))
        XCTAssertFalse(summaryBody.contains("removeItem"))
        XCTAssertFalse(summaryBody.contains("delete"))
        XCTAssertFalse(summaryBody.localizedCaseInsensitiveContains("cookie"))
        XCTAssertFalse(summaryBody.localizedCaseInsensitiveContains("token"))
    }

    func testClearFinishedQueueActionExplainsNonDestructiveScope() throws {
        let source = try queueSectionSource()
        let body = try XCTUnwrap(functionBody(named: "body", in: source))

        XCTAssertTrue(body.contains("if queue.hasFinishedItems"))
        XCTAssertTrue(body.contains("Button(localizer.t(L.Queue.clearFinished))"))
        XCTAssertTrue(body.contains("queue.clearFinished()"))
        XCTAssertTrue(body.contains(".help(clearFinishedHelpText)"))
        XCTAssertTrue(body.contains(".accessibilityHint(clearFinishedHelpText)"))

        let helpBody = try XCTUnwrap(functionBody(named: "clearFinishedHelpText", in: source))
        XCTAssertTrue(helpBody.contains("localizer.t(L.Queue.clearFinishedHint)"))
    }

    func testQueueItemActionsExposeSideEffectAccessibilityHints() throws {
        let source = try queueItemSource()
        let iconButtonBody = try XCTUnwrap(functionBody(named: "iconButton", in: source))

        XCTAssertTrue(source.contains("@EnvironmentObject private var localizer: Localizer"))
        XCTAssertTrue(
            source.contains("private func iconButton(_ systemName: String, help: String, hint: String, action: @escaping () -> Void)"),
            "iconButton should require an action-specific accessibility hint."
        )
        XCTAssertTrue(
            iconButtonBody.contains(".accessibilityHint(hint)"),
            "iconButton should expose the supplied hint to assistive technologies."
        )
        XCTAssertTrue(
            source.contains("help: localizer.t(L.Queue.remove), hint: localizer.t(L.Queue.removeHint)"),
            "Remove actions should explain that downloaded files are not deleted."
        )
        XCTAssertTrue(
            source.contains("help: localizer.t(L.Queue.revealInFinder), hint: localizer.t(L.Queue.revealInFinderHint)"),
            "Reveal actions should explain that Finder opens the containing location."
        )
        XCTAssertTrue(
            source.contains("help: localizer.t(L.Queue.cancelAction), hint: localizer.t(L.Queue.cancelHint)"),
            "Cancel should explain that later download or processing work stops."
        )
        XCTAssertTrue(
            source.contains("help: localizer.t(L.Queue.retrySubtitle), hint: localizer.t(L.Queue.retrySubtitleHint)"),
            "Subtitle retry should explain that video download is not repeated."
        )
    }

    func testPauseDoesNotReleaseTranslationSlot() throws {
        let source = try queueManagerSource()
        let pauseBody = try XCTUnwrap(functionBody(named: "pause", in: source))

        XCTAssertTrue(pauseBody.contains("holding.pool !== translatePool"))
        XCTAssertLessThan(
            try XCTUnwrap(pauseBody.range(of: "holding.pool !== translatePool")).lowerBound,
            try XCTUnwrap(pauseBody.range(of: "holding.pool.release()")).lowerBound
        )
        XCTAssertTrue(pauseBody.contains("翻译请求不是本地可挂起进程"))
    }

    func testPostDownloadTranscodingUsesTypedProgressState() throws {
        let source = try queueManagerSource()

        XCTAssertTrue(source.contains("enum PostDownloadProcessingKind"))
        XCTAssertTrue(source.contains("postDownloadProcessingKind"))
        XCTAssertTrue(source.contains("postDownloadProcessingKind = .generic"))
        XCTAssertTrue(source.contains("postDownloadProcessingKind = .transcoding"))
        XCTAssertTrue(source.contains("postDownloadProcessingKind = nil"))
    }

    func testTranslatedSubtitleSourceFilterUsesAllTargetLanguageSuffixes() throws {
        let source = try queueManagerSource()
        let pickerBody = try XCTUnwrap(functionBody(named: "pickSourceSubtitle", in: source))

        XCTAssertTrue(pickerBody.contains("TranslationLanguage.isTranslatedSubtitleFileName"))
        XCTAssertFalse(pickerBody.contains("hasSuffix(\".zh.srt\")"))
    }

    func testQueueItemShowsTranscodingPercentInsteadOfGenericProcessing() throws {
        let source = try queueItemSource()
        let statusBody = try XCTUnwrap(functionBody(named: "statusText", in: source))
        let helperBody = try XCTUnwrap(functionBody(named: "postDownloadProcessingText", in: source))
        let accessibilityNameBody = try XCTUnwrap(functionBody(named: "progressStageAccessibilityName", in: source))
        let accessibilityValueBody = try XCTUnwrap(functionBody(named: "progressAccessibilityValue", in: source))

        XCTAssertTrue(statusBody.contains("postDownloadProcessingText"))
        XCTAssertTrue(helperBody.contains("case .transcoding"))
        XCTAssertTrue(helperBody.contains("localizer.t(L.Queue.transcodingPercent, Int(p * 100))"))
        XCTAssertTrue(helperBody.contains("localizer.t(L.Queue.transcoding)"))
        XCTAssertTrue(accessibilityNameBody.contains("localizer.t(L.Queue.transcodeProgress)"))
        XCTAssertTrue(accessibilityValueBody.contains("localizer.t(L.Queue.progressIndeterminateTranscoding)"))
    }

    private func queueManagerSource() throws -> String {
        try String(contentsOf: packageRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("Moongate")
            .appendingPathComponent("QueueManager.swift"))
    }

    private func queueSectionSource() throws -> String {
        try String(contentsOf: packageRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("Moongate")
            .appendingPathComponent("QueueSectionView.swift"))
    }

    private func queueItemSource() throws -> String {
        try String(contentsOf: packageRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("Moongate")
            .appendingPathComponent("QueueItemView.swift"))
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
            "func \(name)(",
            "private var \(name):",
            "private var \(name) ",
            "var \(name):",
            "var \(name) "
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
}
