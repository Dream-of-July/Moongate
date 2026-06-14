import XCTest

final class MacOSViewModelBoundaryTests: XCTestCase {
    func testStartDownloadSkipsTranslationReadinessGateForChineseSourceSubtitles() throws {
        let source = try viewModelSource()
        let startDownloadBody = try XCTUnwrap(functionBody(prefix: "func startDownload", in: source))

        XCTAssertTrue(source.contains("shouldRequireTranslationReadiness(for mode: ChineseSubtitleMode, info: VideoInfo) -> Bool"))
        XCTAssertTrue(source.contains("mode.requiresTranslation && !translationSourceIsChinese(in: info)"))
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
        XCTAssertTrue(startDownloadBody.contains("TranslationContext("))
        XCTAssertTrue(startDownloadBody.contains("sourceLanguage: translationSourceSubtitle(in: info)?.id"))
        XCTAssertTrue(startDownloadBody.contains("targetLanguage: \"zh-Hans\""))
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
        XCTAssertTrue(processBatchBody.contains("sourceLanguage: subtitleLangs.first ?? autoSubtitleLangs.first"))
        XCTAssertTrue(processBatchBody.contains("targetLanguage: \"zh-Hans\""))
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

    private func compactWhitespace(_ source: String) -> String {
        source.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
