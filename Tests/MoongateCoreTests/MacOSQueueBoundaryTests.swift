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
        XCTAssertTrue(
            source.contains("isLocalASRRetryReady ? L.Queue.retryWithLocalASRHint : L.Queue.retryWithLocalASRConfigureHint"),
            "Local ASR retry should explain whether it will rerun immediately or open configuration first."
        )
    }

    func testCompletedQueueItemCanRetryWithLocalASRWithoutRedownloading() throws {
        let queueManager = try queueManagerSource()
        let queueItem = try queueItemSource()
        let queueSection = try queueSectionSource()

        let retryBody = try XCTUnwrap(functionBody(named: "retryWithLocalASR", in: queueManager))
        let helperBody = try XCTUnwrap(functionBody(named: "localASRRetryRequest", in: queueManager))
        let buttonsBody = try XCTUnwrap(functionBody(named: "buttons", in: queueItem))

        XCTAssertTrue(retryBody.contains("localASRRetryRequest(for: old.request)"))
        XCTAssertTrue(retryBody.contains("localASRGenerator != nil"))
        XCTAssertFalse(retryBody.contains("old.chineseMode != .off"))
        XCTAssertTrue(retryBody.contains("let retryMode: ChineseSubtitleMode = .burnIn"))
        XCTAssertTrue(retryBody.contains("hasVideo"))
        XCTAssertTrue(retryBody.contains("$0.request = request"))
        XCTAssertTrue(retryBody.contains("$0.chineseMode = retryMode"))
        XCTAssertTrue(retryBody.contains("$0.progressPlan = Self.progressPlan(for: request, mode: retryMode)"))
        XCTAssertTrue(retryBody.contains("$0.workPlan = Self.workPlan(for: request, mode: retryMode)"))
        XCTAssertTrue(retryBody.contains("runPipeline(id: id, skipDownload: true)"))
        XCTAssertTrue(helperBody.contains("languageCode.isEmpty ? \"auto\" : languageCode"))
        XCTAssertTrue(helperBody.contains("source?.label ?? CoreL10n.t(L.Ready.localASRAutoDetectLabel)"))
        XCTAssertTrue(helperBody.contains("sourceKind: .localASR"))
        XCTAssertTrue(helperBody.contains("provider: \"whisper.cpp\""))
        XCTAssertTrue(helperBody.contains("variant: \"local\""))
        XCTAssertTrue(buttonsBody.contains("canRetryWithLocalASR"))
        XCTAssertTrue(buttonsBody.contains("isLocalASRRetryReady"))
        XCTAssertTrue(buttonsBody.contains("onRetryWithLocalASR"))
        XCTAssertTrue(queueManager.contains("CoreL10n.t(L.Queue.localASRGeneratedSubtitleReady)"))
        XCTAssertTrue(queueManager.contains("func canRetryWithLocalASR(_ id: UUID) -> Bool"))
        XCTAssertFalse(try XCTUnwrap(functionBody(named: "canRetryWithLocalASR", in: queueManager)).contains("localASRGenerator != nil"))
        XCTAssertTrue(queueManager.contains("var hasLocalASRGenerator: Bool"))
        XCTAssertTrue(queueItem.contains("let onRetryWithLocalASR: () -> Void"))
        XCTAssertTrue(queueItem.contains("let canRetryWithLocalASR: Bool"))
        XCTAssertTrue(queueItem.contains("let isLocalASRRetryReady: Bool"))
        XCTAssertTrue(queueSection.contains("canRetryWithLocalASR: queue.canRetryWithLocalASR(item.id)"))
        XCTAssertTrue(queueSection.contains("isLocalASRRetryReady: queue.hasLocalASRGenerator"))
        XCTAssertTrue(queueSection.contains("onConfigureLocalASR()"))
        XCTAssertTrue(queueSection.contains("queue.retryWithLocalASR(item.id)"))
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

    func testPauseResumeReportSuccessAndConfirmPauseBeforeReleasingSlot() throws {
        let source = try queueManagerSource()
        let pauseBody = try XCTUnwrap(functionBody(named: "pause", in: source))
        let resumeBody = try XCTUnwrap(functionBody(named: "resume", in: source))

        XCTAssertTrue(source.contains("@discardableResult\n    func pause(_ id: UUID) -> Bool"))
        XCTAssertTrue(source.contains("@discardableResult\n    func resume(_ id: UUID) -> Bool"))
        XCTAssertTrue(pauseBody.contains("guard target.control.pause() else { return false }"))
        XCTAssertLessThan(
            try XCTUnwrap(pauseBody.range(of: "target.control.pause()")).lowerBound,
            try XCTUnwrap(pauseBody.range(of: "holding.pool.release()")).lowerBound
        )
        XCTAssertTrue(pauseBody.contains("return true"))
        XCTAssertTrue(resumeBody.contains("guard target.control.resume() else { return false }"))
        XCTAssertTrue(resumeBody.contains("update(id) { $0.isPaused = false }"))
        XCTAssertTrue(resumeBody.contains("return true"))
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
        XCTAssertTrue(pickerBody.contains("\"vtt\""))
        XCTAssertFalse(pickerBody.contains("hasSuffix(\".zh.srt\")"))
    }

    func testLocalASRSourceSRTIsGeneratedBeforeSourceSubtitlePicking() throws {
        let source = try queueManagerSource()
        let pipelineBody = try XCTUnwrap(functionBody(named: "runPipeline", in: source))
        let pickerRankBody = try XCTUnwrap(functionBody(named: "subtitleSourceRank", in: source))

        XCTAssertTrue(source.contains("localASRGenerator"))
        XCTAssertTrue(source.contains("generateSourceSubtitle"))
        XCTAssertTrue(source.contains("applyASRProgress"))
        XCTAssertTrue(pipelineBody.contains("prepareLocalASRSourceSubtitleIfNeeded"))
        XCTAssertLessThan(
            try XCTUnwrap(pipelineBody.range(of: "prepareLocalASRSourceSubtitleIfNeeded")).lowerBound,
            try XCTUnwrap(pipelineBody.range(of: "pickSourceSubtitle")).lowerBound
        )
        XCTAssertTrue(pickerRankBody.contains("isLocalASRSubtitle"))
    }

    func testLocalASRSourceSRTCanBeSavedWithoutTranslationOrBurning() throws {
        let source = try queueManagerSource()
        let pipelineBody = try XCTUnwrap(functionBody(named: "runPipeline", in: source))

        XCTAssertLessThan(
            try XCTUnwrap(pipelineBody.range(of: "prepareLocalASRSourceSubtitleIfNeeded")).lowerBound,
            try XCTUnwrap(pipelineBody.range(of: "guard mode != .off else")).lowerBound
        )
    }

    func testQueueUsesPrimarySubtitleTrackForSourcePickingAndTranslationContext() throws {
        let source = try queueManagerSource()
        let pipelineBody = try XCTUnwrap(functionBody(named: "runPipeline", in: source))
        let pickerBody = try XCTUnwrap(functionBody(named: "pickSourceSubtitle", in: source))

        XCTAssertTrue(pipelineBody.contains("current.request.primarySubtitleTrack"))
        XCTAssertTrue(pipelineBody.contains("preferredTrack: primarySubtitleTrack"))
        XCTAssertTrue(pipelineBody.contains("sourceLanguage: primarySubtitleTrack?.languageCode"))
        XCTAssertFalse(pipelineBody.contains("sourceLanguage: preferredLang"))
        XCTAssertTrue(source.contains("preferredTrack: SubtitleChoice?"))
        XCTAssertTrue(pickerBody.contains("preferredTrack?.sourceKind == .localASR"))
        XCTAssertTrue(pickerBody.contains("preferredTrack.sourceKind != .localASR"))
    }

    func testLocalASRRetryReusesExistingGeneratedSourceSRTBeforeInvokingRecognizerAgain() throws {
        let source = try queueManagerSource()
        let helperBody = try XCTUnwrap(functionBody(named: "existingLocalASRSubtitle", in: source))
        let prepareBody = try XCTUnwrap(functionBody(named: "prepareLocalASRSourceSubtitleIfNeeded", in: source))

        XCTAssertTrue(helperBody.contains("isLocalASRSubtitle"))
        XCTAssertTrue(helperBody.contains("langCode(ofSubtitle:"))
        XCTAssertTrue(prepareBody.contains("if let existing = Self.existingLocalASRSubtitle"))
        XCTAssertLessThan(
            try XCTUnwrap(prepareBody.range(of: "if let existing = Self.existingLocalASRSubtitle")).lowerBound,
            try XCTUnwrap(prepareBody.range(of: "generateSourceSubtitle")).lowerBound
        )
    }

    func testNormalSubtitlePathDoesNotRunLocalASRWork() throws {
        let source = try queueManagerSource()
        let workPlanBody = try XCTUnwrap(functionBody(named: "workPlan", in: source))
        let languageBody = try XCTUnwrap(functionBody(named: "localASRLanguageCode", in: source))
        let prepareBody = try XCTUnwrap(functionBody(named: "prepareLocalASRSourceSubtitleIfNeeded", in: source))

        XCTAssertTrue(workPlanBody.contains("let needsLocalASR = request.requestedSubtitleTracks.contains { $0.sourceKind == .localASR }"))
        XCTAssertTrue(workPlanBody.contains("shouldExtractAudio: needsLocalASR"))
        XCTAssertTrue(workPlanBody.contains("shouldRunASR: needsLocalASR"))
        XCTAssertTrue(workPlanBody.contains("shouldSegmentSubtitles: needsLocalASR"))
        XCTAssertTrue(languageBody.contains("request.primarySubtitleTrack?.sourceKind == .localASR"))
        XCTAssertTrue(languageBody.contains("first(where: { $0.sourceKind == .localASR })?"))
        XCTAssertTrue(prepareBody.contains("guard let languageCode = Self.localASRLanguageCode(in: request) else"))
        XCTAssertTrue(prepareBody.contains("return files"))
        XCTAssertLessThan(
            try XCTUnwrap(prepareBody.range(of: "guard let languageCode = Self.localASRLanguageCode")).lowerBound,
            try XCTUnwrap(prepareBody.range(of: "generateSourceSubtitle")).lowerBound
        )
    }

    func testQueueCompletionNotificationsAreCoalescedAtAllDoneBoundary() throws {
        let source = try queueManagerSource()

        XCTAssertTrue(source.contains("QueueCompletionNotification"))
        XCTAssertTrue(source.contains("completionNotifier"))
        XCTAssertTrue(source.contains("notifiedTerminalIDs"))
        XCTAssertTrue(source.contains("notifyQueueCompletionIfNeeded()"))
        XCTAssertTrue(source.contains("guard openItems.isEmpty else { return }"))
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

    func testQueueItemShowsLocalASRProgressPhases() throws {
        let source = try queueItemSource()
        let statusBody = try XCTUnwrap(functionBody(named: "statusText", in: source))
        let helperBody = try XCTUnwrap(functionBody(named: "localASRProgressText", in: source))
        let accessibilityNameBody = try XCTUnwrap(functionBody(named: "progressStageAccessibilityName", in: source))
        let accessibilityValueBody = try XCTUnwrap(functionBody(named: "progressAccessibilityValue", in: source))
        let keys = try String(contentsOf: packageRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("MoongateMobileCore")
            .appendingPathComponent("Localization")
            .appendingPathComponent("LocalizationKeys.swift"))

        XCTAssertTrue(statusBody.contains("if let localASRText = localASRProgressText"))
        XCTAssertTrue(helperBody.contains("case .audioExtract"))
        XCTAssertTrue(helperBody.contains("case .speechRecognition"))
        XCTAssertTrue(helperBody.contains("case .subtitleSegment"))
        XCTAssertTrue(helperBody.contains("localizer.t(L.Queue.audioExtractingPercent, Int(p * 100))"))
        XCTAssertTrue(helperBody.contains("localizer.t(L.Queue.speechRecognizingPercent, Int(p * 100))"))
        XCTAssertTrue(helperBody.contains("localizer.t(L.Queue.subtitleSegmentingPercent, Int(p * 100))"))
        XCTAssertTrue(accessibilityNameBody.contains("localizer.t(L.Queue.audioExtractProgress)"))
        XCTAssertTrue(accessibilityNameBody.contains("localizer.t(L.Queue.speechRecognitionProgress)"))
        XCTAssertTrue(accessibilityNameBody.contains("localizer.t(L.Queue.subtitleSegmentProgress)"))
        XCTAssertTrue(accessibilityValueBody.contains("localizer.t(L.Queue.progressIndeterminateAudioExtract)"))
        XCTAssertTrue(accessibilityValueBody.contains("localizer.t(L.Queue.progressIndeterminateSpeechRecognition)"))
        XCTAssertTrue(accessibilityValueBody.contains("localizer.t(L.Queue.progressIndeterminateSubtitleSegment)"))
        XCTAssertTrue(keys.contains("audioExtractingPercent"))
        XCTAssertTrue(keys.contains("speechRecognizingPercent"))
        XCTAssertTrue(keys.contains("subtitleSegmentingPercent"))
    }

    func testQueueItemUsesOverallProgressAndAddsRemainingDetails() throws {
        let source = try queueItemSource()
        let progressBody = try XCTUnwrap(functionBody(named: "progressBar", in: source))
        let statusHelperBody = try XCTUnwrap(functionBody(named: "statusWithDetails", in: source))
        let remainingBody = try XCTUnwrap(functionBody(named: "remainingText", in: source))
        let overlaySource = try queueOverlaySource()
        let overlayProgressBody = try XCTUnwrap(functionBody(named: "overallProgress", in: overlaySource))
        let overlayLabelBody = try XCTUnwrap(functionBody(named: "handleLabel", in: overlaySource))
        let terminalLabelBody = try XCTUnwrap(functionBody(named: "terminalHandleLabel", in: overlaySource))

        XCTAssertTrue(progressBody.contains("item.overallProgress"))
        XCTAssertFalse(progressBody.contains("item.progress"))
        XCTAssertTrue(statusHelperBody.contains("item.speedText"))
        XCTAssertTrue(statusHelperBody.contains("remainingText"))
        XCTAssertTrue(remainingBody.contains("item.remainingSeconds"))
        XCTAssertTrue(remainingBody.contains("localizer.t(L.Queue.remainingApprox"))
        XCTAssertTrue(remainingBody.contains("localizer.t(L.Queue.remainingEstimating"))
        XCTAssertTrue(overlayProgressBody.contains("queue.progressSnapshot.overallProgress"))
        XCTAssertTrue(overlayLabelBody.contains("queueRemainingText"))
        XCTAssertTrue(overlayLabelBody.contains("terminalHandleLabel"))
        XCTAssertTrue(terminalLabelBody.contains("L.Queue.allDone"))
        XCTAssertTrue(terminalLabelBody.contains("L.Queue.allEnded"))
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

    private func queueOverlaySource() throws -> String {
        try String(contentsOf: packageRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("Moongate")
            .appendingPathComponent("QueueOverlayView.swift"))
    }

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func functionBody(named name: String, in source: String) -> String? {
        let declarations = [
            "private static func \(name)(",
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
