@testable import MoongateMobileCore
import XCTest

final class MobileTranslationProviderTests: XCTestCase {
    func testOpenAICompatibleProviderBuildsResponsesRequestFromSecureCredentialAndParsesResponsesJSON() async throws {
        let credential = SecureCredentialReference(service: "translation.openai", account: "default")
        let store = ReadableCredentialStore(secrets: [credential: "TEST_SECRET_VALUE_DO_NOT_STORE"])
        let transport = RecordingMobileTranslationTransport(responseText: """
        {
          "output": [
            {
              "type": "message",
              "content": [
                { "type": "output_text", "text": "1=你好" }
              ]
            }
          ]
        }
        """)
        let provider = APICompatibleMobileTranslationProvider(
            configuration: MobileTranslationConfiguration(
                engine: .openAICompatible,
                baseURL: "https://api.openai.com",
                model: "gpt-5-mini",
                credential: credential
            ),
            credentialStore: store,
            transport: transport
        )

        let result = try await provider.translate(MobileTranslationRequest(
            segments: [
                MobileTranslationSegment(id: "1", startTime: "00:00:01,000", endTime: "00:00:02,000", text: "Hello")
            ],
            context: TranslationContext(sourceLanguage: "en", targetLanguage: "zh-Hans")
        ))
        let maybeRecorded = await transport.firstRecordedRequest()
        let recorded = try XCTUnwrap(maybeRecorded)
        let body = try XCTUnwrap(String(data: recorded.body, encoding: .utf8))

        XCTAssertEqual(result.segments.map(\.text), ["你好"])
        XCTAssertEqual(recorded.url.absoluteString, "https://api.openai.com/v1/responses")
        XCTAssertEqual(recorded.headers["Authorization"], "Bearer TEST_SECRET_VALUE_DO_NOT_STORE")
        XCTAssertNil(recorded.headers["x-api-key"])
        XCTAssertTrue(body.contains(#""model":"gpt-5-mini""#))
        XCTAssertTrue(body.contains(#""store":false"#))
        XCTAssertTrue(body.contains("Hello"))

        let encodedConfig = String(
            data: try JSONEncoder().encode(provider.configuration),
            encoding: .utf8
        )
        XCTAssertFalse(try XCTUnwrap(encodedConfig).contains("TEST_SECRET_VALUE_DO_NOT_STORE"))
    }

    func testAPICompatibleProviderBlocksWhenCredentialIsMissing() async throws {
        let provider = APICompatibleMobileTranslationProvider(
            configuration: MobileTranslationConfiguration(
                engine: .openAICompatible,
                baseURL: "https://api.openai.com",
                model: "gpt-5-mini",
                credential: SecureCredentialReference(service: "translation.openai", account: "default")
            ),
            credentialStore: ReadableCredentialStore(),
            transport: RecordingMobileTranslationTransport(responseText: "1=你好")
        )

        let readiness = await provider.readiness(for: TranslationContext(sourceLanguage: "en", targetLanguage: "zh-Hans"))

        XCTAssertFalse(readiness.isReady)
        XCTAssertEqual(readiness.issues.map(\.kind), [.needsConfiguration])

        do {
            _ = try await provider.translate(MobileTranslationRequest(
                segments: [
                    MobileTranslationSegment(id: "1", startTime: "00:00:01,000", endTime: "00:00:02,000", text: "Hello")
                ],
                context: TranslationContext(sourceLanguage: "en", targetLanguage: "zh-Hans")
            ))
            XCTFail("Translation should require a readable secure credential.")
        } catch let error as MobileTranslationProviderError {
            XCTAssertEqual(error, .missingCredential)
        }
    }

    func testAPICompatibleProviderReadinessRejectsInvalidBaseURL() async throws {
        let credential = SecureCredentialReference(service: "translation.openai", account: "default")
        let provider = APICompatibleMobileTranslationProvider(
            configuration: MobileTranslationConfiguration(
                engine: .openAICompatible,
                baseURL: "not a url",
                model: "gpt-5-mini",
                credential: credential
            ),
            credentialStore: ReadableCredentialStore(secrets: [credential: "TEST_SECRET_VALUE_DO_NOT_STORE"]),
            transport: RecordingMobileTranslationTransport(responseText: "")
        )

        let readiness = await provider.readiness(for: TranslationContext(sourceLanguage: "en", targetLanguage: "zh-Hans"))

        XCTAssertFalse(readiness.isReady)
        XCTAssertEqual(readiness.issues.map(\.kind), [.needsConfiguration])
    }

    func testAPICompatibleProviderRejectsPlainHTTPBeforeSendingCredential() async throws {
        let credential = SecureCredentialReference(service: "translation.openai", account: "default")
        let transport = RecordingMobileTranslationTransport(responseText: "1=你好")
        let provider = APICompatibleMobileTranslationProvider(
            configuration: MobileTranslationConfiguration(
                engine: .openAICompatible,
                baseURL: "http://api.example.com",
                model: "gpt-5-mini",
                credential: credential
            ),
            credentialStore: ReadableCredentialStore(secrets: [credential: "TEST_SECRET_VALUE_DO_NOT_STORE"]),
            transport: transport
        )

        let readiness = await provider.readiness(for: TranslationContext(sourceLanguage: "en", targetLanguage: "zh-Hans"))

        XCTAssertFalse(readiness.isReady)
        XCTAssertEqual(readiness.issues.map(\.kind), [.needsConfiguration])
        do {
            _ = try await provider.translate(MobileTranslationRequest(
                segments: [
                    MobileTranslationSegment(id: "1", startTime: "00:00:01,000", endTime: "00:00:02,000", text: "Hello")
                ],
                context: TranslationContext(sourceLanguage: "en", targetLanguage: "zh-Hans")
            ))
            XCTFail("Plain HTTP endpoints must be rejected before credentials are attached.")
        } catch let error as MobileTranslationProviderError {
            XCTAssertEqual(error, .invalidConfiguration)
        }
        let recordedRequest = await transport.firstRecordedRequest()
        XCTAssertNil(recordedRequest)
    }

    func testAnthropicCompatibleGatewayRequestCarriesCompatibleAuthHeadersAndParsesMessagesJSON() async throws {
        let credential = SecureCredentialReference(service: "translation.anthropic", account: "default")
        let store = ReadableCredentialStore(secrets: [credential: "TEST_SECRET_VALUE_DO_NOT_STORE"])
        let transport = RecordingMobileTranslationTransport(responseText: """
        {
          "content": [
            { "type": "text", "text": "1=你好" }
          ]
        }
        """)
        let provider = APICompatibleMobileTranslationProvider(
            configuration: MobileTranslationConfiguration(
                engine: .anthropicCompatible,
                baseURL: "https://gateway.example.com/v1",
                model: "deepseek-chat",
                credential: credential
            ),
            credentialStore: store,
            transport: transport
        )

        let result = try await provider.translate(MobileTranslationRequest(
            segments: [
                MobileTranslationSegment(id: "1", startTime: "00:00:01,000", endTime: "00:00:02,000", text: "Hello")
            ],
            context: TranslationContext(sourceLanguage: "en", targetLanguage: "zh-Hans")
        ))
        let maybeRecorded = await transport.firstRecordedRequest()
        let recorded = try XCTUnwrap(maybeRecorded)
        let body = try XCTUnwrap(String(data: recorded.body, encoding: .utf8))

        XCTAssertEqual(result.segments.map(\.text), ["你好"])
        XCTAssertEqual(recorded.url.absoluteString, "https://gateway.example.com/v1/messages")
        XCTAssertEqual(recorded.headers["x-api-key"], "TEST_SECRET_VALUE_DO_NOT_STORE")
        XCTAssertEqual(recorded.headers["Authorization"], "Bearer TEST_SECRET_VALUE_DO_NOT_STORE")
        XCTAssertEqual(recorded.headers["anthropic-version"], "2023-06-01")
        XCTAssertTrue(body.contains(#""model":"deepseek-chat""#))
        XCTAssertTrue(body.contains("Hello"))
    }

    func testOfficialAnthropicRequestDoesNotSendAuthorizationHeader() async throws {
        let credential = SecureCredentialReference(service: "translation.anthropic", account: "default")
        let store = ReadableCredentialStore(secrets: [credential: "TEST_SECRET_VALUE_DO_NOT_STORE"])
        let transport = RecordingMobileTranslationTransport(responseText: """
        {
          "content": [
            { "type": "text", "text": "1=你好" }
          ]
        }
        """)
        let provider = APICompatibleMobileTranslationProvider(
            configuration: MobileTranslationConfiguration(
                engine: .anthropicCompatible,
                baseURL: "https://api.anthropic.com",
                model: "claude-haiku-4-5",
                credential: credential
            ),
            credentialStore: store,
            transport: transport
        )

        _ = try await provider.translate(MobileTranslationRequest(
            segments: [
                MobileTranslationSegment(id: "1", startTime: "00:00:01,000", endTime: "00:00:02,000", text: "Hello")
            ],
            context: TranslationContext(sourceLanguage: "en", targetLanguage: "zh-Hans")
        ))
        let maybeRecorded = await transport.firstRecordedRequest()
        let recorded = try XCTUnwrap(maybeRecorded)

        XCTAssertEqual(recorded.url.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(recorded.headers["x-api-key"], "TEST_SECRET_VALUE_DO_NOT_STORE")
        XCTAssertNil(recorded.headers["Authorization"])
    }
}

private actor ReadableCredentialStore: SecureCredentialStore {
    private var secrets: [SecureCredentialReference: String]

    init(secrets: [SecureCredentialReference: String] = [:]) {
        self.secrets = secrets
    }

    func saveCredential(_ secret: String, for reference: SecureCredentialReference) async throws -> SecureCredentialReference {
        secrets[reference] = secret
        return reference
    }

    func deleteCredential(_ reference: SecureCredentialReference) async throws {
        secrets.removeValue(forKey: reference)
    }

    func hasCredential(_ reference: SecureCredentialReference) async throws -> Bool {
        secrets[reference] != nil
    }

    func credential(for reference: SecureCredentialReference) async throws -> String? {
        secrets[reference]
    }
}

private actor RecordingMobileTranslationTransport: MobileTranslationTransport {
    private var recordedRequests: [MobileTranslationTransportRequest] = []
    private let responseText: String

    init(responseText: String) {
        self.responseText = responseText
    }

    func send(_ request: MobileTranslationTransportRequest) async throws -> MobileTranslationTransportResponse {
        recordedRequests.append(request)
        return MobileTranslationTransportResponse(statusCode: 200, body: Data(responseText.utf8))
    }

    func firstRecordedRequest() -> MobileTranslationTransportRequest? {
        recordedRequests.first
    }
}
