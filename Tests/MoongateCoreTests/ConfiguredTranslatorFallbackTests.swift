import XCTest
@testable import MoongateCore

final class ConfiguredTranslatorFallbackTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("moongate-translator-fallback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
    }

    func testMissingLineFallsBackWithoutFailingWholeTranslation() async throws {
        let source = try writeSRT("missing.en.srt", [
            SubtitleCue(index: 1, start: "00:00:01,000", end: "00:00:02,000", text: "First line."),
            SubtitleCue(index: 2, start: "00:00:03,000", end: "00:00:04,000", text: "Second line."),
            SubtitleCue(index: 3, start: "00:00:05,000", end: "00:00:06,000", text: "Third line.")
        ])
        let translator = ConfiguredTranslator(
            settings: cloudSettings(),
            appleTranslationExecutor: DefaultAppleTranslationExecutor(),
            modelSender: { _, _, userContent, _, _ in
                if userContent.contains("\n") {
                    return ModelReply(text: "1|中1\n3|中3", reachedOutputLimit: false)
                }
                if userContent == "2|Second line." {
                    return ModelReply(text: "", reachedOutputLimit: false)
                }
                return ModelReply(text: translatedLines(from: userContent), reachedOutputLimit: false)
            }
        )

        let output = try await translator.translate(
            srtFile: source,
            style: .chineseOnly,
            context: TranslationContext(sourceLanguage: "en", targetLanguage: "zh-Hans"),
            control: nil,
            progress: { _ in }
        )

        let result = parseSRT(try String(contentsOf: output, encoding: .utf8))
        XCTAssertEqual(result.map(\.text), ["中1", "Second line.", "中3"])
    }

    func testTransientChunkNetworkErrorRetriesInsideChunk() async throws {
        let source = try writeSRT("retry.en.srt", [
            SubtitleCue(index: 1, start: "00:00:01,000", end: "00:00:02,000", text: "Hello."),
            SubtitleCue(index: 2, start: "00:00:03,000", end: "00:00:04,000", text: "Bye.")
        ])
        let attempts = AttemptCounter()
        let translator = ConfiguredTranslator(
            settings: cloudSettings(),
            appleTranslationExecutor: DefaultAppleTranslationExecutor(),
            modelSender: { _, _, userContent, _, _ in
                if await attempts.next() == 1 {
                    throw URLError(.timedOut)
                }
                return ModelReply(text: translatedLines(from: userContent), reachedOutputLimit: false)
            }
        )

        let output = try await translator.translate(
            srtFile: source,
            style: .chineseOnly,
            context: TranslationContext(sourceLanguage: "en", targetLanguage: "zh-Hans"),
            control: nil,
            progress: { _ in }
        )

        let result = parseSRT(try String(contentsOf: output, encoding: .utf8))
        XCTAssertEqual(result.map(\.text), ["中1", "中2"])
        let attemptCount = await attempts.value()
        XCTAssertEqual(attemptCount, 2)
    }

    private func writeSRT(_ name: String, _ cues: [SubtitleCue]) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try serializeSRT(cues).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func cloudSettings() -> AppSettings {
        AppSettings(
            translationEngine: .anthropicCompatible,
            translationBaseURL: "https://example.invalid",
            translationModel: "test-model",
            translationAuthToken: "token",
            smartTranslationPromptsEnabled: false
        )
    }
}

private func translatedLines(from userContent: String) -> String {
    userContent.split(separator: "\n", omittingEmptySubsequences: false)
        .map { line -> String in
            let number = line.split(separator: "|", maxSplits: 1).first ?? ""
            return "\(number)|中\(number)"
        }
        .joined(separator: "\n")
}

private actor AttemptCounter {
    private var count = 0

    func next() -> Int {
        count += 1
        return count
    }

    func value() -> Int {
        count
    }
}
