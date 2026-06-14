@testable import MoongateCore
import XCTest

final class AppleTranslationExecutorTests: XCTestCase {
    func testAppleTranslationPathUsesExecutorAndWritesBilingualSRT() async throws {
        let executor = RecordingAppleTranslationExecutor(responses: [
            2: "晚安",
            1: "你好世界"
        ])
        let translator = ConfiguredTranslator(
            settings: AppSettings(
                translationEngine: .appleTranslationLowLatency,
                translationBaseURL: "",
                translationModel: "",
                translationAuthToken: ""
            ),
            appleTranslationExecutor: executor
        )
        let source = try writeSRT("""
        1
        00:00:01,000 --> 00:00:02,000
        Hello world.

        2
        00:00:03,000 --> 00:00:04,000
        Good night.

        """)

        let output = try await translator.translate(
            srtFile: source,
            style: .bilingual,
            context: TranslationContext(sourceLanguage: "en", targetLanguage: "zh-Hans"),
            control: nil
        ) { _ in }

        let written = try String(contentsOf: output, encoding: .utf8)
        XCTAssertEqual(written, """
        1
        00:00:01,000 --> 00:00:02,000
        你好世界
        Hello world.

        2
        00:00:03,000 --> 00:00:04,000
        晚安
        Good night.

        """)

        let requests = await executor.recordedRequests()
        XCTAssertEqual(requests, [
            AppleTranslationBatchRequest(
                engine: .appleTranslationLowLatency,
                context: TranslationContext(sourceLanguage: "en", targetLanguage: "zh-Hans"),
                segments: [
                    AppleTranslationSegment(number: 1, text: "Hello world."),
                    AppleTranslationSegment(number: 2, text: "Good night.")
                ]
            )
        ])
    }

    func testAppleTranslationPathPreservesOriginalTextWhenFewResponsesAreMissing() async throws {
        let executor = RecordingAppleTranslationExecutor(responses: [
            1: "第一句",
            3: "第三句"
        ])
        let translator = ConfiguredTranslator(
            settings: AppSettings(
                translationEngine: .appleTranslationHighFidelity,
                translationBaseURL: "",
                translationModel: "",
                translationAuthToken: ""
            ),
            appleTranslationExecutor: executor
        )
        let source = try writeSRT("""
        1
        00:00:01,000 --> 00:00:02,000
        First.

        2
        00:00:03,000 --> 00:00:04,000
        Second.

        3
        00:00:05,000 --> 00:00:06,000
        Third.

        """)

        let output = try await translator.translate(
            srtFile: source,
            style: .bilingual,
            context: TranslationContext(sourceLanguage: "en", targetLanguage: "zh-Hans"),
            control: nil
        ) { _ in }

        let written = try String(contentsOf: output, encoding: .utf8)
        XCTAssertEqual(written, """
        1
        00:00:01,000 --> 00:00:02,000
        第一句
        First.

        2
        00:00:03,000 --> 00:00:04,000
        Second.

        3
        00:00:05,000 --> 00:00:06,000
        第三句
        Third.

        """)
    }

    func testAppleTranslationPathFailsWhenTooManyResponsesAreMissing() async throws {
        let executor = RecordingAppleTranslationExecutor(responses: [
            1: "第一句",
            2: "第二句"
        ])
        let translator = ConfiguredTranslator(
            settings: AppSettings(
                translationEngine: .appleTranslationLowLatency,
                translationBaseURL: "",
                translationModel: "",
                translationAuthToken: ""
            ),
            appleTranslationExecutor: executor
        )
        let source = try writeSRT("""
        1
        00:00:01,000 --> 00:00:02,000
        One.

        2
        00:00:03,000 --> 00:00:04,000
        Two.

        3
        00:00:05,000 --> 00:00:06,000
        Three.

        4
        00:00:07,000 --> 00:00:08,000
        Four.

        5
        00:00:09,000 --> 00:00:10,000
        Five.

        """)

        do {
            _ = try await translator.translate(
                srtFile: source,
                style: .chineseOnly,
                context: TranslationContext(sourceLanguage: "en", targetLanguage: "zh-Hans"),
                control: nil
            ) { _ in }
            XCTFail("Expected excessive missing Apple Translation responses to fail.")
        } catch MoongateError.translateFailed(let message) {
            XCTAssertTrue(message.contains("缺失过多译文行"))
        }
    }

    func testCloudEnginesDoNotUseAppleTranslationExecutor() async throws {
        let executor = RecordingAppleTranslationExecutor(responses: [
            1: "不应使用"
        ])
        let translator = ConfiguredTranslator(
            settings: AppSettings(
                translationEngine: .openAICompatible,
                translationBaseURL: "",
                translationModel: "",
                translationAuthToken: ""
            ),
            appleTranslationExecutor: executor
        )
        let source = try writeSRT("""
        1
        00:00:01,000 --> 00:00:02,000
        Hello.

        """)

        do {
            _ = try await translator.translate(
                srtFile: source,
                style: .bilingual,
                context: TranslationContext(sourceLanguage: "en", targetLanguage: "zh-Hans"),
                control: nil
            ) { _ in }
            XCTFail("Expected OpenAI-compatible path to keep using existing cloud validation.")
        } catch MoongateError.translateFailed(let message) {
            XCTAssertTrue(message.contains("尚未配置模型"))
        }

        let requests = await executor.recordedRequests()
        XCTAssertEqual(requests, [])
    }

    func testDefaultAppleTranslationExecutorRequiresExplicitSourceLanguage() async throws {
        let executor = DefaultAppleTranslationExecutor()
        let request = AppleTranslationBatchRequest(
            engine: .appleTranslationLowLatency,
            context: TranslationContext(sourceLanguage: nil, targetLanguage: "zh-Hans"),
            segments: [AppleTranslationSegment(number: 1, text: "Hello.")]
        )

        do {
            _ = try await executor.translate(request)
            XCTFail("Expected missing source language to fail before runtime execution.")
        } catch MoongateError.translateFailed(let message) {
            XCTAssertTrue(message.contains("源语言"))
        }
    }

    func testPrecancelledControlTokenCancelsBeforeAppleExecutorRequest() async throws {
        let executor = RecordingAppleTranslationExecutor(responses: [
            1: "不应调用"
        ])
        let translator = ConfiguredTranslator(
            settings: AppSettings(
                translationEngine: .appleTranslationLowLatency,
                translationBaseURL: "",
                translationModel: "",
                translationAuthToken: ""
            ),
            appleTranslationExecutor: executor
        )
        let source = try writeSRT("""
        1
        00:00:01,000 --> 00:00:02,000
        Hello.

        """)
        let control = TaskControlToken()
        control.cancel()

        do {
            _ = try await translator.translate(
                srtFile: source,
                style: .bilingual,
                context: TranslationContext(sourceLanguage: "en", targetLanguage: "zh-Hans"),
                control: control
            ) { _ in }
            XCTFail("Expected a precancelled control token to cancel before invoking Apple Translation.")
        } catch MoongateError.cancelled {
            let requests = await executor.recordedRequests()
            XCTAssertEqual(requests, [])
        }
    }

    func testPausedControlTokenDelaysAppleExecutorRequestUntilResume() async throws {
        let executor = RecordingAppleTranslationExecutor(responses: [
            1: "你好"
        ])
        let translator = ConfiguredTranslator(
            settings: AppSettings(
                translationEngine: .appleTranslationLowLatency,
                translationBaseURL: "",
                translationModel: "",
                translationAuthToken: ""
            ),
            appleTranslationExecutor: executor
        )
        let source = try writeSRT("""
        1
        00:00:01,000 --> 00:00:02,000
        Hello.

        """)
        let control = TaskControlToken()
        control.pause()

        let task = Task<URL, Error> {
            try await translator.translate(
                srtFile: source,
                style: .chineseOnly,
                context: TranslationContext(sourceLanguage: "en", targetLanguage: "zh-Hans"),
                control: control
            ) { _ in }
        }
        defer {
            control.resume()
            task.cancel()
        }

        try await Task.sleep(nanoseconds: 30_000_000)
        let pausedRequests = await executor.recordedRequests()
        XCTAssertEqual(pausedRequests, [])

        control.resume()
        let output = try await value(of: task)
        let written = try String(contentsOf: output, encoding: .utf8)
        XCTAssertTrue(written.contains("你好"))
        let resumedRequests = await executor.recordedRequests()
        XCTAssertEqual(resumedRequests.count, 1)
    }

    private func writeSRT(_ text: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("moongate-apple-translation-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("sample.en.srt")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func value<T>(
        of task: Task<T, Error>,
        timeoutNanoseconds: UInt64 = 1_000_000_000
    ) async throws -> T {
        do {
            return try await withThrowingTaskGroup(of: T.self) { group in
                group.addTask {
                    try await task.value
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    throw TestTimeoutError.timedOut
                }
                guard let value = try await group.next() else {
                    throw TestTimeoutError.timedOut
                }
                group.cancelAll()
                return value
            }
        } catch {
            task.cancel()
            throw error
        }
    }

    private enum TestTimeoutError: Error {
        case timedOut
    }
}

private actor RecordingAppleTranslationExecutor: AppleTranslationExecuting {
    private let responses: [Int: String]
    private var requests: [AppleTranslationBatchRequest] = []

    init(responses: [Int: String]) {
        self.responses = responses
    }

    func translate(_ request: AppleTranslationBatchRequest) async throws -> [Int: String] {
        requests.append(request)
        return responses
    }

    func recordedRequests() -> [AppleTranslationBatchRequest] {
        requests
    }
}
