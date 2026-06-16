import XCTest

final class MacOSQueueBoundaryTests: XCTestCase {
    func testQueueHeaderExposesReadableTaskSummaryWithoutChangingActions() throws {
        let source = try queueSectionSource()
        let body = try XCTUnwrap(functionBody(named: "body", in: source))

        XCTAssertTrue(body.contains(".accessibilityElement(children: .combine)"))
        XCTAssertTrue(body.contains(".accessibilityLabel(\"下载队列\")"))
        XCTAssertTrue(body.contains(".accessibilityValue(queueHeaderAccessibilityValue)"))
        XCTAssertTrue(body.contains("queue.clearFinished()"))
        XCTAssertTrue(body.contains("onCollapse()"))

        let summaryBody = try XCTUnwrap(functionBody(named: "queueHeaderAccessibilityValue", in: source))
        XCTAssertTrue(summaryBody.contains("\\(queue.items.count) 个任务"))
        XCTAssertTrue(summaryBody.contains("queue.openTaskCount"))
        XCTAssertTrue(summaryBody.contains("queue.pausedOpenTaskCount"))
        XCTAssertTrue(summaryBody.contains("全部已结束"))
        XCTAssertTrue(summaryBody.contains("全部暂停"))
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
        XCTAssertTrue(body.contains("Button(\"清除已结束任务\")"))
        XCTAssertTrue(body.contains("queue.clearFinished()"))
        XCTAssertTrue(body.contains(".help(clearFinishedHelpText)"))
        XCTAssertTrue(body.contains(".accessibilityHint(clearFinishedHelpText)"))

        let helpBody = try XCTUnwrap(functionBody(named: "clearFinishedHelpText", in: source))
        XCTAssertTrue(helpBody.contains("从队列移除已完成、失败或已取消的任务"))
        XCTAssertTrue(helpBody.contains("不会删除已下载文件"))
    }

    func testQueueItemActionsExposeSideEffectAccessibilityHints() throws {
        let source = try queueItemSource()
        let iconButtonBody = try XCTUnwrap(functionBody(named: "iconButton", in: source))

        XCTAssertTrue(
            source.contains("private func iconButton(_ systemName: String, help: String, hint: String, action: @escaping () -> Void)"),
            "iconButton should require an action-specific accessibility hint."
        )
        XCTAssertTrue(
            iconButtonBody.contains(".accessibilityHint(hint)"),
            "iconButton should expose the supplied hint to assistive technologies."
        )
        XCTAssertTrue(
            source.contains("help: \"移除\", hint: \"只从队列移除这个任务，不删除已下载文件\""),
            "Remove actions should explain that downloaded files are not deleted."
        )
        XCTAssertTrue(
            source.contains("help: \"在访达中显示\", hint: \"打开包含结果文件的位置\""),
            "Reveal actions should explain that Finder opens the containing location."
        )
        XCTAssertTrue(
            source.contains("help: \"取消\", hint: \"停止这个任务的后续下载或处理\""),
            "Cancel should explain that later download or processing work stops."
        )
        XCTAssertTrue(
            source.contains("help: \"重试字幕处理\", hint: \"只重新执行字幕翻译或烧录，不重新下载视频\""),
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

    func testQueueItemShowsTranscodingPercentInsteadOfGenericProcessing() throws {
        let source = try queueItemSource()
        let statusBody = try XCTUnwrap(functionBody(named: "statusText", in: source))
        let helperBody = try XCTUnwrap(functionBody(named: "postDownloadProcessingText", in: source))
        let accessibilityNameBody = try XCTUnwrap(functionBody(named: "progressStageAccessibilityName", in: source))
        let accessibilityValueBody = try XCTUnwrap(functionBody(named: "progressAccessibilityValue", in: source))

        XCTAssertTrue(statusBody.contains("postDownloadProcessingText"))
        XCTAssertTrue(helperBody.contains("case .transcoding"))
        XCTAssertTrue(helperBody.contains("转码中 \\(Int(p * 100))%"))
        XCTAssertTrue(helperBody.contains("转码中…"))
        XCTAssertTrue(accessibilityNameBody.contains("转码进度"))
        XCTAssertTrue(accessibilityValueBody.contains("转码中，进度不确定"))
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
