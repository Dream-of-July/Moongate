import XCTest
@testable import MoongateCore

final class CloudASRTests: XCTestCase {
    func testCloudASRModelCapabilitiesDistinguishDirectSubtitleAndAlignmentOnlyModels() {
        XCTAssertTrue(CloudASRModelCapabilities.supportsDirectSubtitleOutput(" whisper-1\n"))
        XCTAssertFalse(CloudASRModelCapabilities.requiresAlignment("whisper-1"))
        XCTAssertFalse(CloudASRModelCapabilities.supportsDirectSubtitleOutput("gpt-4o-transcribe"))
        XCTAssertTrue(CloudASRModelCapabilities.requiresAlignment("gpt-4o-transcribe"))
    }

    func testOpenAICloudASRBuildsMultipartSRTTranscriptionRequest() throws {
        let audioURL = try writeTempAudio(name: "clip.wav", data: Data("RIFF audio".utf8))
        let request = CloudASRTranscriptionRequest(
            audioURL: audioURL,
            languageCode: "ja",
            modelID: "whisper-1",
            prompt: "title=コウペンちゃん",
            responseFormat: .srt
        )

        let urlRequest = try OpenAICloudASRClient.makeTranscriptionURLRequest(
            request,
            baseURL: URL(string: "https://api.openai.com")!,
            authToken: "Bearer sk-test",
            boundary: "moongate-test-boundary"
        )
        let body = String(data: try XCTUnwrap(urlRequest.httpBody), encoding: .utf8) ?? ""

        XCTAssertEqual(urlRequest.httpMethod, "POST")
        XCTAssertEqual(urlRequest.url?.absoluteString, "https://api.openai.com/v1/audio/transcriptions")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Content-Type"), "multipart/form-data; boundary=moongate-test-boundary")
        XCTAssertTrue(body.contains("name=\"model\""))
        XCTAssertTrue(body.contains("whisper-1"))
        XCTAssertTrue(body.contains("name=\"response_format\""))
        XCTAssertTrue(body.contains("srt"))
        XCTAssertTrue(body.contains("name=\"language\""))
        XCTAssertTrue(body.contains("ja"))
        XCTAssertTrue(body.contains("name=\"prompt\""))
        XCTAssertTrue(body.contains("title=コウペンちゃん"))
        XCTAssertTrue(body.contains("name=\"file\"; filename=\"clip.wav\""))
        XCTAssertFalse(body.contains("Bearer Bearer"))
    }

    func testOpenAICloudASRRejectsGPT4OForSRTOutput() throws {
        let audioURL = try writeTempAudio(name: "clip.wav", data: Data("RIFF audio".utf8))
        let request = CloudASRTranscriptionRequest(
            audioURL: audioURL,
            modelID: "gpt-4o-transcribe",
            responseFormat: .srt
        )

        XCTAssertThrowsError(try OpenAICloudASRClient.makeTranscriptionURLRequest(
            request,
            baseURL: URL(string: "https://api.openai.com")!,
            authToken: "sk-test",
            boundary: "moongate-test-boundary"
        )) { error in
            XCTAssertEqual(error as? CloudASRError, .unsupportedSRTModel("gpt-4o-transcribe"))
        }
    }

    func testOpenAICloudASRTranscribesJSONAndAlignsTextToGuideSRT() async throws {
        let audioURL = try writeTempAudio(name: "clip.wav", data: Data("RIFF audio".utf8))
        let guideURL = try writeTempSubtitle(name: "clip.local-asr.ja.srt", text: """
        1
        00:00:00,000 --> 00:00:01,000
        コウペンちゃん

        2
        00:00:01,000 --> 00:00:03,000
        チョコバナナ 食べよう

        """)
        let outputURL = guideURL.deletingPathExtension().appendingPathExtension("aligned.srt")
        let transport = RecordingCloudASRTransport(
            data: Data(#"{"text":"コウペンちゃん チョコバナナを食べよう"}"#.utf8),
            statusCode: 200
        )
        let client = OpenAICloudASRClient(
            baseURL: URL(string: "https://api.openai.com")!,
            authToken: "sk-test",
            transport: transport
        )

        let written = try await client.transcribeToAlignedSRT(
            CloudASRTranscriptionRequest(
                audioURL: audioURL,
                languageCode: "ja",
                modelID: "gpt-4o-transcribe"
            ),
            guideSubtitleURL: guideURL,
            outputURL: outputURL
        )

        XCTAssertEqual(written, outputURL)
        XCTAssertEqual(transport.requests.count, 1)
        let body = String(data: try XCTUnwrap(transport.requests.first?.httpBody), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("name=\"response_format\""))
        XCTAssertTrue(body.contains("json"))
        XCTAssertFalse(body.contains("srt"))
        let aligned = parseSRT(try String(contentsOf: outputURL, encoding: .utf8))
        XCTAssertEqual(aligned.map(\.start), ["00:00:00,000", "00:00:01,000"])
        XCTAssertEqual(aligned.map(\.end), ["00:00:01,000", "00:00:03,000"])
        XCTAssertEqual(aligned.map(\.text).joined(), "コウペンちゃんチョコバナナを食べよう")
    }

    func testCloudTranscriptAlignerUsesGuideTimelineForLatinTranscript() throws {
        let aligned = try CloudTranscriptAligner.align(
            transcript: "hello bright moon gate",
            guideCues: [
                SubtitleCue(index: 1, start: "00:00:00,000", end: "00:00:01,000", text: "hello"),
                SubtitleCue(index: 2, start: "00:00:01,000", end: "00:00:03,000", text: "bright moon")
            ]
        )

        XCTAssertEqual(aligned.map(\.start), ["00:00:00,000", "00:00:01,000"])
        XCTAssertEqual(aligned.map(\.end), ["00:00:01,000", "00:00:03,000"])
        XCTAssertEqual(aligned.map(\.text), ["hello", "bright moon gate"])
    }

    func testOpenAICloudASRWritesReturnedSRT() async throws {
        let audioURL = try writeTempAudio(name: "clip.wav", data: Data("RIFF audio".utf8))
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("moongate-cloud-asr-\(UUID().uuidString)")
            .appendingPathExtension("srt")
        let transport = RecordingCloudASRTransport(
            data: Data("""
            1
            00:00:00,000 --> 00:00:01,000
            こんにちは
            """.utf8),
            statusCode: 200
        )
        let client = OpenAICloudASRClient(
            baseURL: URL(string: "https://api.openai.com")!,
            authToken: "sk-test",
            transport: transport
        )

        let written = try await client.transcribeToSRT(
            CloudASRTranscriptionRequest(audioURL: audioURL, languageCode: "ja", modelID: "whisper-1"),
            outputURL: outputURL
        )

        XCTAssertEqual(written, outputURL)
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        let output = try String(contentsOf: outputURL, encoding: .utf8)
        XCTAssertTrue(output.contains("こんにちは"))
    }

    func testOpenAICloudASRSubtitleGeneratorWritesCloudSourceSRTWithPromptMetadata() async throws {
        let videoURL = try writeTempAudio(name: "koupen.mp4", data: Data("fake video".utf8))
        let transport = RecordingCloudASRTransport(
            data: Data("""
            1
            00:00:00,000 --> 00:00:01,000
            コウペンちゃん
            """.utf8),
            statusCode: 200
        )
        let generator = OpenAICloudASRSubtitleGenerator(
            client: OpenAICloudASRClient(
                baseURL: URL(string: "https://api.openai.com")!,
                authToken: "sk-test",
                transport: transport
            ),
            modelID: "whisper-1"
        )

        let generated = try await generator.generateSourceSubtitle(
            videoFile: videoURL,
            languageCode: "ja",
            promptMetadata: ASRPromptMetadata(
                title: "コウペンちゃん",
                glossaryTerms: ["チョコバナナ"]
            ),
            control: nil
        )

        XCTAssertTrue(generated.url.lastPathComponent.contains(".cloud-asr.ja"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: generated.url.path))
        let body = String(data: try XCTUnwrap(transport.requests.first?.httpBody), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("name=\"prompt\""))
        XCTAssertTrue(body.contains("title=コウペンちゃん"))
        XCTAssertTrue(body.contains("チョコバナナ"))
        let output = try String(contentsOf: generated.url, encoding: .utf8)
        XCTAssertTrue(output.contains("コウペンちゃん"))
    }

    func testCloudASRGeneratorFactoryRequiresExplicitConfiguration() {
        XCTAssertNil(CloudASRGeneratorFactory.make(settings: AppSettings()))
        XCTAssertNotNil(CloudASRGeneratorFactory.make(settings: AppSettings(
            cloudASREnabled: true,
            cloudASRConsentAccepted: true,
            cloudASRBaseURL: "https://api.openai.com",
            cloudASRModel: "whisper-1",
            cloudASRAuthToken: "sk-test"
        )))
        XCTAssertNil(CloudASRGeneratorFactory.make(settings: AppSettings(
            cloudASREnabled: true,
            cloudASRConsentAccepted: true,
            cloudASRBaseURL: "https://api.openai.com",
            cloudASRModel: "gpt-4o-transcribe",
            cloudASRAuthToken: "sk-test"
        )))
        XCTAssertNotNil(CloudASRGeneratorFactory.make(
            settings: AppSettings(
                cloudASREnabled: true,
                cloudASRConsentAccepted: true,
                cloudASRBaseURL: "https://api.openai.com",
                cloudASRModel: "gpt-4o-transcribe",
                cloudASRAuthToken: "sk-test"
            ),
            localASRGenerator: StaticGuideLocalASRGenerator()
        ))
    }

    private func writeTempAudio(name: String, data: Data) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("moongate-cloud-asr-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func writeTempSubtitle(name: String, text: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("moongate-cloud-asr-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

private struct StaticGuideLocalASRGenerator: LocalASRSubtitleGenerator {
    func generateSourceSubtitle(
        videoFile: URL,
        languageCode: String,
        promptMetadata: ASRPromptMetadata?,
        control: TaskControlToken?,
        progress: @escaping @Sendable (ASRProgress) -> Void
    ) async throws -> GeneratedLocalASRSource {
        let output = videoFile
            .deletingPathExtension()
            .appendingPathExtension("local-asr.\(languageCode).srt")
        try """
        1
        00:00:00,000 --> 00:00:01,000
        guide

        """.write(to: output, atomically: true, encoding: .utf8)
        progress(ASRProgress(phase: .speechRecognition, completedUnits: 1, totalUnits: 1))
        return GeneratedLocalASRSource(url: output, confidence: nil)
    }
}

private final class RecordingCloudASRTransport: CloudASRHTTPTransport, @unchecked Sendable {
    private let data: Data
    private let statusCode: Int
    private var lock = NSLock()
    private var storedRequests: [URLRequest] = []

    var requests: [URLRequest] {
        lock.withLock { storedRequests }
    }

    init(data: Data, statusCode: Int) {
        self.data = data
        self.statusCode = statusCode
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock {
            storedRequests.append(request)
        }
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://api.openai.com")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (data, response)
    }
}
