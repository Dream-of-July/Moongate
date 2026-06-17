import XCTest

final class MacOSViewModelBoundaryTests: XCTestCase {
    func testViewModelOwnsUpdaterAndChecksSilentlyOnAppear() throws {
        let source = try viewModelSource()

        XCTAssertTrue(source.contains("let updater: UpdateService"))
        XCTAssertTrue(source.contains("updater: UpdateService? = nil"))
        XCTAssertTrue(source.contains("self.updater = updater ?? UpdateService()"))
        let onAppearBody = try XCTUnwrap(functionBody(prefix: "func onAppear", in: source))
        XCTAssertTrue(onAppearBody.contains("checkForUpdatesIfNeeded()"))

        let checkBody = try XCTUnwrap(functionBody(prefix: "func checkForUpdatesIfNeeded", in: source))
        XCTAssertTrue(checkBody.contains("if case .idle = updater.state"))
        XCTAssertTrue(checkBody.contains("updater.check(silent: true)"))
    }

    func testStartDownloadSkipsTranslationReadinessGateForChineseSourceSubtitles() throws {
        let source = try viewModelSource()
        let startDownloadBody = try XCTUnwrap(functionBody(prefix: "func startDownload", in: source))

        XCTAssertTrue(source.contains("shouldRequireTranslationReadiness(for mode: ChineseSubtitleMode, info: VideoInfo) -> Bool"))
        XCTAssertTrue(source.contains("mode.requiresTranslation && !translationSourceMatchesTarget(in: info)"))
        XCTAssertTrue(startDownloadBody.contains("shouldRequireTranslationReadiness(for: mode, info: info)"))
        XCTAssertFalse(startDownloadBody.contains("if chineseMode.requiresTranslation"))

        let readinessGate = try XCTUnwrap(
            startDownloadBody.range(of: "shouldRequireTranslationReadiness(for: mode, info: info)")
        )
        let contextConstruction = try XCTUnwrap(startDownloadBody.range(of: "TranslationContext("))
        let contextAwareBlock = try XCTUnwrap(
            startDownloadBody.range(of: "await blockIfTranslationNotReady(")
        )

        XCTAssertLessThan(readinessGate.upperBound, contextConstruction.lowerBound)
        XCTAssertLessThan(contextConstruction.upperBound, contextAwareBlock.lowerBound)
    }

    func testStartDownloadAwaitsRuntimeReadinessForNonChineseSourceSubtitles() throws {
        let source = try viewModelSource()
        let startDownloadBody = try XCTUnwrap(functionBody(prefix: "func startDownload", in: source))
        let compactStartDownloadBody = compactWhitespace(startDownloadBody)

        XCTAssertTrue(source.contains("func startDownload() async"))
        XCTAssertTrue(startDownloadBody.contains("let startSession = session"))
        XCTAssertTrue(startDownloadBody.contains("let mode = chineseMode"))
        XCTAssertTrue(startDownloadBody.contains("let selectedFormatIDSnapshot = selectedFormatID"))
        XCTAssertTrue(startDownloadBody.contains("let selectedSubtitleIDsSnapshot = selectedSubtitleIDs"))
        XCTAssertTrue(startDownloadBody.contains("let currentSettings = settings"))
        XCTAssertTrue(startDownloadBody.contains("shouldRequireTranslationReadiness(for: mode, info: info)"))
        XCTAssertTrue(startDownloadBody.contains("currentSettings.makeTranslationContext("))
        XCTAssertTrue(startDownloadBody.contains("sourceLanguage: translationSourceSubtitle(in: info)?.id"))
        XCTAssertTrue(startDownloadBody.contains("await blockIfTranslationNotReady("))
        XCTAssertTrue(startDownloadBody.contains("settings: currentSettings"))
        XCTAssertTrue(startDownloadBody.contains("guard startSession == session else { return }"))
        XCTAssertTrue(startDownloadBody.contains("guard case .ready(let currentInfo) = stage"))
        XCTAssertTrue(startDownloadBody.contains("currentInfo.sourceURL == info.sourceURL"))
        XCTAssertTrue(startDownloadBody.contains("currentInfo.videoID == info.videoID"))
        XCTAssertTrue(startDownloadBody.contains("guard let formatID = selectedFormatIDSnapshot ?? info.formats.first?.id else { return }"))
        XCTAssertTrue(startDownloadBody.contains("selectedSubtitleIDsSnapshot.contains($0.id)"))
        XCTAssertTrue(startDownloadBody.contains("queue.enqueue(info: info, request: request, chineseMode: mode, settings: currentSettings)"))
        XCTAssertFalse(compactStartDownloadBody.contains(
            "guard blockIfTranslationNotReady(for: chineseMode) else { return }"
        ))
        XCTAssertTrue(source.contains("translationRuntimeReadiness("))
        XCTAssertTrue(source.contains("context: translationContext"))
        XCTAssertTrue(source.contains("evaluator: runtimeReadinessEvaluator"))
    }

    func testBatchChecksTranslationReadinessAfterAutoSelectingSubtitleSource() throws {
        let source = try viewModelSource()
        let processBatchBody = try XCTUnwrap(functionBody(prefix: "private func processBatch", in: source))
        let compactBatchBody = compactWhitespace(processBatchBody)

        XCTAssertTrue(compactBatchBody.contains("let mode = chineseMode guard dependenciesReady(for: mode) else { return }"))
        XCTAssertFalse(compactBatchBody.contains(
            "let mode = chineseMode guard blockIfTranslationNotReady(for: mode) else { return }"
        ))

        let subtitleSelection = try XCTUnwrap(processBatchBody.range(of: "autoSubtitleLangs = [sub.id]"))
        let readinessGate = try XCTUnwrap(processBatchBody.range(of: "shouldRequireTranslationReadiness"))
        let translationContext = try XCTUnwrap(processBatchBody.range(of: "TranslationContext("))
        let contextAwareBlock = try XCTUnwrap(processBatchBody.range(
            of: "blockIfTranslationNotReady("
        ))
        let requestConstruction = try XCTUnwrap(processBatchBody.range(of: "let request = DownloadRequest"))

        XCTAssertLessThan(subtitleSelection.upperBound, readinessGate.lowerBound)
        XCTAssertLessThan(readinessGate.upperBound, translationContext.lowerBound)
        XCTAssertLessThan(translationContext.upperBound, contextAwareBlock.lowerBound)
        XCTAssertLessThan(contextAwareBlock.upperBound, requestConstruction.lowerBound)
        XCTAssertTrue(compactBatchBody.contains("shouldRequireTranslationReadiness( for: mode, info: info,"))
        XCTAssertTrue(processBatchBody.contains("currentSettings.makeTranslationContext("))
        XCTAssertTrue(processBatchBody.contains("sourceLanguage: subtitleLangs.first ?? autoSubtitleLangs.first"))
        XCTAssertTrue(processBatchBody.contains("await blockIfTranslationNotReady("))
        XCTAssertTrue(processBatchBody.contains("settings: currentSettings"))
        XCTAssertTrue(source.contains(
            "private func blockIfTranslationNotReady("
        ))
        XCTAssertTrue(source.contains("settings: AppSettings"))
        XCTAssertTrue(source.contains("translationRuntimeReadiness("))
        XCTAssertTrue(source.contains("context: context"))
        XCTAssertTrue(source.contains("evaluator: runtimeReadinessEvaluator"))
    }

    func testSummaryAvailabilityUsesSummaryRuntimeReadiness() throws {
        let source = try viewModelSource()
        let refreshBody = try XCTUnwrap(functionBody(prefix: "func refreshSummaryRuntimeReadiness", in: source))
        let unavailableBody = try XCTUnwrap(functionBody(prefix: "var summaryUnavailableReason", in: source))

        XCTAssertTrue(source.contains("@Published private(set) var runtimeSummaryReadiness"))
        XCTAssertTrue(source.contains("private var runtimeSummaryReadinessContext"))
        XCTAssertTrue(source.contains("private var summaryReadinessTask"))
        XCTAssertTrue(refreshBody.contains("settings.applyingTranslationConfig(settings.effectiveSummaryConfig)"))
        XCTAssertTrue(refreshBody.contains("summaryReadinessContext()"))
        XCTAssertTrue(refreshBody.contains("translationRuntimeReadiness("))
        XCTAssertTrue(refreshBody.contains("runtimeSummaryReadiness = readiness"))

        XCTAssertTrue(unavailableBody.contains("let config = settings.effectiveSummaryConfig"))
        XCTAssertTrue(unavailableBody.contains("let summarySettings = settings.applyingTranslationConfig(config)"))
        XCTAssertTrue(unavailableBody.contains("runtimeSummaryReadinessContext == context"))
        XCTAssertTrue(unavailableBody.contains("runtimeSummaryReadiness ?? summarySettings.translationReadiness(context: context)"))
        XCTAssertFalse(unavailableBody.contains("settings.translationReadiness(context: context)"))
    }

    func testSummaryRuntimeReadinessRefreshesOnAppearAndSettingsChange() throws {
        let source = try viewModelSource()
        let onAppearBody = try XCTUnwrap(functionBody(prefix: "func onAppear", in: source))
        let settingsBody = try XCTUnwrap(publishedSettingsBody(in: source))

        XCTAssertTrue(onAppearBody.contains("refreshTranslationRuntimeReadiness()"))
        XCTAssertTrue(onAppearBody.contains("refreshSummaryRuntimeReadiness()"))
        XCTAssertTrue(settingsBody.contains("refreshTranslationRuntimeReadiness()"))
        XCTAssertTrue(settingsBody.contains("refreshSummaryRuntimeReadiness()"))
    }

    private func viewModelSource() throws -> String {
        try String(contentsOf: packageRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("Moongate")
            .appendingPathComponent("ViewModel.swift"))
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

    private func publishedSettingsBody(in source: String) -> String? {
        guard let declaration = source.range(of: "@Published var settings") else { return nil }
        guard let didSet = source.range(of: "didSet", range: declaration.lowerBound..<source.endIndex) else { return nil }
        guard let openingBrace = source[didSet.lowerBound...].firstIndex(of: "{") else { return nil }

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
