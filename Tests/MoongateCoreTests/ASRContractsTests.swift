import Foundation
import CryptoKit
import XCTest
@testable import MoongateCore

final class ASRContractsTests: XCTestCase {
    func testTranscriptAndManifestsRoundTripThroughJSON() throws {
        let createdAt = Date(timeIntervalSince1970: 1_785_000_000)
        let transcript = ASRTranscript(
            id: "clip-ja-small",
            languageCode: "ja",
            languageConfidence: 0.91,
            durationSeconds: 2.4,
            words: [
                ASRWord(text: "梅雨", startSeconds: 0.0, endSeconds: 0.6, probability: 0.82),
                ASRWord(text: "が", startSeconds: 0.6, endSeconds: 0.8, probability: 0.93),
                ASRWord(text: "明ける", startSeconds: 0.8, endSeconds: 1.5, probability: 0.76)
            ],
            sourceModelID: "whisper.cpp:small-q5_1",
            createdAt: createdAt
        )
        let model = ASRModelInfo(
            id: "whisper.cpp:small-q5_1",
            displayName: "Whisper small q5_1",
            fileName: "ggml-small-q5_1.bin",
            downloadURL: try XCTUnwrap(URL(string: "https://example.com/ggml-small-q5_1.bin")),
            sizeBytes: 181_000_000,
            sha256: String(repeating: "a", count: 64),
            memoryRequiredMB: 1024,
            license: "MIT",
            sourceDescription: "whisper.cpp model mirror"
        )
        let cache = ASRTranscriptCacheEntry(
            cacheKey: "clip-ja-small",
            audioFingerprint: "sha256:\(String(repeating: "b", count: 64))",
            modelID: model.id,
            languageCode: "ja",
            transcriptURL: URL(fileURLWithPath: "/tmp/transcript.json"),
            createdAt: createdAt
        )

        let encoder = ASRJSON.makeEncoder()
        let decoder = ASRJSON.makeDecoder()

        let transcriptData = try encoder.encode(transcript)
        let transcriptJSON = try XCTUnwrap(String(data: transcriptData, encoding: .utf8))
        XCTAssertTrue(transcriptJSON.contains("\"sourceModelId\""))
        XCTAssertFalse(transcriptJSON.contains("sourceModelID"))
        XCTAssertEqual(transcript, try decoder.decode(ASRTranscript.self, from: transcriptData))
        XCTAssertEqual(ASRModelManifest(models: [model]), try decoder.decode(
            ASRModelManifest.self,
            from: encoder.encode(ASRModelManifest(models: [model]))
        ))
        XCTAssertEqual(cache, try decoder.decode(ASRTranscriptCacheEntry.self, from: encoder.encode(cache)))

        let progressData = try encoder.encode(ASRProgress(
            phase: .speechRecognition,
            completedUnits: 1,
            totalUnits: 2
        ))
        let progressJSON = try XCTUnwrap(String(data: progressData, encoding: .utf8))
        XCTAssertTrue(progressJSON.contains("\"phase\":\"speechRecognition\""))
    }

    func testRecommendedWhisperCppManifestUsesVerifiedHuggingFaceMetadata() throws {
        let manifest = ASRModelManifest.recommendedWhisperCpp

        XCTAssertEqual(
            manifest.models.map(\.id),
            [
                "whisper.cpp:tiny-q5_1",
                "whisper.cpp:tiny-q8_0",
                "whisper.cpp:base-q5_1",
                "whisper.cpp:base-q8_0",
                "whisper.cpp:small-q5_1",
                "whisper.cpp:small-q8_0",
                "whisper.cpp:small.en-q5_1",
                "whisper.cpp:medium-q5_0",
                "whisper.cpp:large-v3-turbo-q5_0"
            ]
        )
        XCTAssertTrue(manifest.models.allSatisfy { $0.license == "MIT" })
        XCTAssertTrue(manifest.models.allSatisfy { $0.sourceDescription.contains("ggerganov/whisper.cpp") })

        let tiny = try XCTUnwrap(manifest.models.first { $0.id == "whisper.cpp:tiny-q5_1" })
        XCTAssertEqual(tiny.fileName, "ggml-tiny-q5_1.bin")
        XCTAssertEqual(tiny.sizeBytes, 32_152_673)
        XCTAssertEqual(tiny.sha256, "818710568da3ca15689e31a743197b520007872ff9576237bda97bd1b469c3d7")
        XCTAssertEqual(tiny.downloadURL.absoluteString, "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny-q5_1.bin")
        XCTAssertGreaterThanOrEqual(tiny.memoryRequiredMB, 256)

        let base = try XCTUnwrap(manifest.models.first { $0.id == "whisper.cpp:base-q5_1" })
        XCTAssertEqual(base.fileName, "ggml-base-q5_1.bin")
        XCTAssertEqual(base.sizeBytes, 59_707_625)
        XCTAssertEqual(base.sha256, "422f1ae452ade6f30a004d7e5c6a43195e4433bc370bf23fac9cc591f01a8898")
        XCTAssertEqual(base.downloadURL.absoluteString, "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base-q5_1.bin")
        XCTAssertGreaterThanOrEqual(base.memoryRequiredMB, 512)

        let small = try XCTUnwrap(manifest.models.first { $0.id == "whisper.cpp:small-q5_1" })
        XCTAssertEqual(small.fileName, "ggml-small-q5_1.bin")
        XCTAssertEqual(small.sizeBytes, 190_085_487)
        XCTAssertEqual(small.sha256, "ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb")
        XCTAssertEqual(small.downloadURL.absoluteString, "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small-q5_1.bin")
        XCTAssertGreaterThanOrEqual(small.memoryRequiredMB, 1_024)

        let smallEnglish = try XCTUnwrap(manifest.models.first { $0.id == "whisper.cpp:small.en-q5_1" })
        XCTAssertEqual(smallEnglish.fileName, "ggml-small.en-q5_1.bin")
        XCTAssertEqual(smallEnglish.sizeBytes, 190_098_681)
        XCTAssertEqual(smallEnglish.sha256, "bfdff4894dcb76bbf647d56263ea2a96645423f1669176f4844a1bf8e478ad30")
        XCTAssertEqual(smallEnglish.downloadURL.absoluteString, "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en-q5_1.bin")

        let medium = try XCTUnwrap(manifest.models.first { $0.id == "whisper.cpp:medium-q5_0" })
        XCTAssertEqual(medium.fileName, "ggml-medium-q5_0.bin")
        XCTAssertEqual(medium.sizeBytes, 539_212_467)
        XCTAssertEqual(medium.sha256, "19fea4b380c3a618ec4723c3eef2eb785ffba0d0538cf43f8f235e7b3b34220f")
        XCTAssertEqual(medium.downloadURL.absoluteString, "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium-q5_0.bin")
        XCTAssertGreaterThanOrEqual(medium.memoryRequiredMB, 2_048)

        let turbo = try XCTUnwrap(manifest.models.first { $0.id == "whisper.cpp:large-v3-turbo-q5_0" })
        XCTAssertEqual(turbo.fileName, "ggml-large-v3-turbo-q5_0.bin")
        XCTAssertEqual(turbo.sizeBytes, 574_041_195)
        XCTAssertEqual(turbo.sha256, "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2")
        XCTAssertEqual(turbo.downloadURL.absoluteString, "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin")
        XCTAssertGreaterThanOrEqual(turbo.memoryRequiredMB, 3_072)
    }

    func testRuntimeBundleManifestRejectsDownloadURLsAndPathEscapes() throws {
        let runtime = try ASRRuntimeBundleInfo(
            provider: "whisper.cpp",
            platform: "macos",
            architecture: "arm64",
            version: "1.7.5",
            executableRelativePath: "bin/whisper-cli",
            sha256: String(repeating: "c", count: 64),
            license: "MIT",
            sourceDescription: "local staged whisper.cpp runtime"
        )
        let manifest = try ASRRuntimeBundleManifest(runtimes: [runtime])
        let encoder = ASRJSON.makeEncoder()
        let decoder = ASRJSON.makeDecoder()
        let data = try encoder.encode(manifest)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(json.contains("\"executableRelativePath\""))
        XCTAssertFalse(json.contains("downloadUrl"))
        XCTAssertEqual(manifest, try decoder.decode(ASRRuntimeBundleManifest.self, from: data))
        XCTAssertEqual(
            runtime.executableURL(relativeTo: URL(fileURLWithPath: "/Applications/Moongate.app/Contents/Resources/asr/runtime")).path,
            "/Applications/Moongate.app/Contents/Resources/asr/runtime/bin/whisper-cli"
        )

        XCTAssertThrowsError(try ASRRuntimeBundleInfo(
            provider: "whisper.cpp",
            platform: "macos",
            architecture: "arm64",
            version: "1.7.5",
            executableRelativePath: "../whisper-cli",
            sha256: String(repeating: "c", count: 64),
            license: "MIT",
            sourceDescription: "bad"
        )) { error in
            XCTAssertEqual(error as? ASRRuntimeBundleManifestError, .invalidExecutableRelativePath("../whisper-cli"))
        }
        XCTAssertThrowsError(try ASRRuntimeBundleInfo(
            provider: "whisper.cpp",
            platform: "macos",
            architecture: "arm64",
            version: "1.7.5",
            executableRelativePath: "/tmp/whisper-cli",
            sha256: String(repeating: "c", count: 64),
            license: "MIT",
            sourceDescription: "bad"
        )) { error in
            XCTAssertEqual(error as? ASRRuntimeBundleManifestError, .invalidExecutableRelativePath("/tmp/whisper-cli"))
        }
        XCTAssertThrowsError(try ASRRuntimeBundleInfo(
            provider: "whisper.cpp",
            platform: "macos",
            architecture: "arm64",
            version: "1.7.5",
            executableRelativePath: "bin/whisper-cli",
            sha256: "not-a-sha",
            license: "MIT",
            sourceDescription: "bad"
        )) { error in
            XCTAssertEqual(error as? ASRRuntimeBundleManifestError, .invalidSHA256("not-a-sha"))
        }

        let downloadURLJSON = """
        {
          "runtimes": [
            {
              "provider": "whisper.cpp",
              "platform": "macos",
              "architecture": "arm64",
              "version": "1.7.5",
              "executableRelativePath": "bin/whisper-cli",
              "sha256": "\(String(repeating: "c", count: 64))",
              "license": "MIT",
              "sourceDescription": "local staged whisper.cpp runtime",
              "downloadUrl": "https://example.com/whisper-cli"
            }
          ]
        }
        """
        XCTAssertThrowsError(try decoder.decode(ASRRuntimeBundleManifest.self, from: Data(downloadURLJSON.utf8))) { error in
            XCTAssertEqual(error as? ASRRuntimeBundleManifestError, .downloadURLNotAllowed)
        }
    }

    func testRuntimeBundleManifestVerifiesExecutableHashBeforeAdoption() throws {
        let fm = FileManager.default
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("moongate-asr-runtime-bundle-" + UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: directory) }
        let bin = directory.appendingPathComponent("bin", isDirectory: true)
        let executable = bin.appendingPathComponent("whisper-cli")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        let bytes = Data("fake whisper runtime".utf8)
        try bytes.write(to: executable)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let sha = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let runtime = try ASRRuntimeBundleInfo(
            provider: "whisper.cpp",
            platform: "macos",
            architecture: "arm64",
            version: "1.7.5",
            executableRelativePath: "bin/whisper-cli",
            sha256: sha,
            license: "MIT",
            sourceDescription: "local staged whisper.cpp runtime"
        )

        let runtimeInfo = try runtime.verifiedRuntimeInfo(relativeTo: directory)
        XCTAssertEqual(runtimeInfo.provider, "whisper.cpp")
        XCTAssertEqual(runtimeInfo.executableURL, executable)

        let badRuntime = try ASRRuntimeBundleInfo(
            provider: "whisper.cpp",
            platform: "macos",
            architecture: "arm64",
            version: "1.7.5",
            executableRelativePath: "bin/whisper-cli",
            sha256: String(repeating: "d", count: 64),
            license: "MIT",
            sourceDescription: "local staged whisper.cpp runtime"
        )
        XCTAssertThrowsError(try badRuntime.verifiedRuntimeInfo(relativeTo: directory)) { error in
            if case ASRRuntimeBundleManifestError.sha256Mismatch(
                expected: String(repeating: "d", count: 64),
                actual: sha
            ) = error {
                return
            }
            XCTFail("Unexpected error: \(error)")
        }

        let missingRuntime = try ASRRuntimeBundleInfo(
            provider: "whisper.cpp",
            platform: "macos",
            architecture: "arm64",
            version: "1.7.5",
            executableRelativePath: "bin/missing-whisper-cli",
            sha256: sha,
            license: "MIT",
            sourceDescription: "local staged whisper.cpp runtime"
        )
        XCTAssertThrowsError(try missingRuntime.verifiedRuntimeInfo(relativeTo: directory)) { error in
            XCTAssertEqual(error as? ASRRuntimeBundleManifestError, .missingExecutable("bin/missing-whisper-cli"))
        }
    }

    func testRuntimeLocatorUsesVerifiedBundleManifestBeforeBareExecutableFallback() throws {
        let fm = FileManager.default
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("moongate-asr-runtime-locator-" + UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: directory) }
        let bin = directory.appendingPathComponent("bin", isDirectory: true)
        let executableName = "whisper-cli"
        let executable = bin.appendingPathComponent(executableName)
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        let bytes = Data("fake manifest-selected whisper runtime".utf8)
        try bytes.write(to: executable)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let sha = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let runtime = try ASRRuntimeBundleInfo(
            provider: "whisper.cpp",
            platform: ASRRuntimeLocator.currentPlatform,
            architecture: ASRRuntimeLocator.currentArchitecture,
            version: "1.7.5",
            executableRelativePath: "bin/\(executableName)",
            sha256: sha,
            license: "MIT",
            sourceDescription: "local staged whisper.cpp runtime"
        )
        let manifest = try ASRRuntimeBundleManifest(runtimes: [runtime])
        let manifestURL = directory.appendingPathComponent(ASRRuntimeLocator.runtimeManifestFileName)
        try ASRJSON.makeEncoder().encode(manifest).write(to: manifestURL)

        let located = ASRRuntimeLocator(extraSearchURLs: [directory, bin], environmentPath: "").locate()
        XCTAssertEqual(located?.provider, "whisper.cpp")
        XCTAssertEqual(located?.executableURL, executable)

        try Data("tampered runtime".utf8).write(to: executable)
        XCTAssertNil(ASRRuntimeLocator(extraSearchURLs: [directory, bin], environmentPath: "").locate())
    }

    func testFakeRecognizerSuccessReadinessAndProgress() async throws {
        let transcript = ASRTranscript(
            id: "ok",
            languageCode: "ja",
            words: [ASRWord(text: "新聞紙", startSeconds: 0, endSeconds: 0.8)],
            sourceModelID: "whisper.cpp:base"
        )
        let recognizer = FakeSpeechRecognizer(
            readiness: ASRReadiness(status: .ready, modelID: "whisper.cpp:base", message: "Ready"),
            mode: .success(transcript)
        )
        let request = ASRRequest(
            audioURL: URL(fileURLWithPath: "/tmp/audio.wav"),
            languageCode: "ja",
            modelID: "whisper.cpp:base",
            prompt: "title channel glossary",
            vadEnabled: true,
            wordTimestamps: true,
            cacheKey: "ok"
        )

        let readiness = await recognizer.readiness(for: request)
        let progressRecorder = ProgressRecorder()
        let result = try await recognizer.transcribe(request) { progressRecorder.append($0) }

        XCTAssertTrue(readiness.isReady)
        XCTAssertEqual(result, transcript)
        XCTAssertEqual(progressRecorder.events.map(\.phase), [.speechRecognition, .speechRecognition])
        XCTAssertEqual(progressRecorder.events.last?.fraction, 1)
    }

    func testASRWireJSONUsesPathFieldNamesAndReadsLegacyURLFields() throws {
        let encoder = ASRJSON.makeEncoder()
        let decoder = ASRJSON.makeDecoder()
        let request = ASRRequest(
            audioURL: URL(fileURLWithPath: "/tmp/moongate/audio.wav"),
            languageCode: "ja",
            modelID: "whisper.cpp:base",
            cacheKey: "wire"
        )
        let requestData = try encoder.encode(request)
        let requestJSON = try XCTUnwrap(String(data: requestData, encoding: .utf8))
        let requestObject = try XCTUnwrap(JSONSerialization.jsonObject(with: requestData) as? [String: Any])
        XCTAssertEqual(requestObject["audioPath"] as? String, "/tmp/moongate/audio.wav")
        XCTAssertFalse(requestJSON.contains("audioUrl"))
        XCTAssertEqual(request, try decoder.decode(ASRRequest.self, from: Data("""
        {
          "audioUrl": "file:///tmp/moongate/audio.wav",
          "languageCode": "ja",
          "modelId": "whisper.cpp:base",
          "vadEnabled": true,
          "wordTimestamps": true,
          "cacheKey": "wire"
        }
        """.utf8)))

        let runtime = ASRRuntimeInfo(executableURL: URL(fileURLWithPath: "/opt/moongate/whisper-cli"))
        let runtimeData = try encoder.encode(runtime)
        let runtimeJSON = try XCTUnwrap(String(data: runtimeData, encoding: .utf8))
        let runtimeObject = try XCTUnwrap(JSONSerialization.jsonObject(with: runtimeData) as? [String: Any])
        XCTAssertEqual(runtimeObject["executablePath"] as? String, "/opt/moongate/whisper-cli")
        XCTAssertFalse(runtimeJSON.contains("executableUrl"))
        XCTAssertEqual(runtime, try decoder.decode(ASRRuntimeInfo.self, from: Data("""
        { "provider": "whisper.cpp", "executableUrl": "file:///opt/moongate/whisper-cli" }
        """.utf8)))

        let entry = ASRTranscriptCacheEntry(
            cacheKey: "wire",
            audioFingerprint: "sha256:\(String(repeating: "a", count: 64))",
            modelID: "whisper.cpp:base",
            transcriptURL: URL(fileURLWithPath: "/tmp/moongate/wire.transcript.json"),
            createdAt: Date(timeIntervalSince1970: 0)
        )
        let entryData = try encoder.encode(entry)
        let entryJSON = try XCTUnwrap(String(data: entryData, encoding: .utf8))
        let entryObject = try XCTUnwrap(JSONSerialization.jsonObject(with: entryData) as? [String: Any])
        XCTAssertEqual(entryObject["transcriptPath"] as? String, "/tmp/moongate/wire.transcript.json")
        XCTAssertFalse(entryJSON.contains("transcriptUrl"))
        XCTAssertEqual(entry, try decoder.decode(ASRTranscriptCacheEntry.self, from: Data("""
        {
          "cacheKey": "wire",
          "audioFingerprint": "sha256:\(String(repeating: "a", count: 64))",
          "modelId": "whisper.cpp:base",
          "languageCode": null,
          "transcriptUrl": "file:///tmp/moongate/wire.transcript.json",
          "createdAt": "1970-01-01T00:00:00Z"
        }
        """.utf8)))
    }

    func testFakeRecognizerFailureAndCancellationModes() async {
        let request = ASRRequest(audioURL: URL(fileURLWithPath: "/tmp/audio.wav"), modelID: "missing")
        let missing = FakeSpeechRecognizer(
            readiness: ASRReadiness(status: .missingModel, modelID: "missing", message: "Model missing"),
            mode: .failure(.missingModel)
        )
        await XCTAssertThrowsErrorAsync(try await missing.transcribe(request) { _ in }) { error in
            XCTAssertEqual(error as? FakeSpeechRecognizerError, .missingModel)
        }

        let cancelled = FakeSpeechRecognizer(
            readiness: ASRReadiness(status: .ready, modelID: "base", message: "Ready"),
            mode: .cancelled
        )
        await XCTAssertThrowsErrorAsync(try await cancelled.transcribe(request) { _ in }) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testModelStoreReportsHashDiskAndDeleteState() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory
            .appendingPathComponent("moongate-asr-model-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: directory) }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let hashSource = directory.appendingPathComponent("hash-source.bin")
        try Data("good model".utf8).write(to: hashSource)
        let expectedSha = try ASRModelStore.sha256(of: hashSource)
        try fm.removeItem(at: hashSource)
        let model = try ASRModelInfo(
            id: "whisper.cpp:test",
            displayName: "Whisper test",
            fileName: "ggml-test.bin",
            downloadURL: XCTUnwrap(URL(string: "https://example.com/ggml-test.bin")),
            sizeBytes: 128,
            sha256: expectedSha,
            memoryRequiredMB: 64,
            license: "MIT",
            sourceDescription: "fixture"
        )

        let store = ASRModelStore(directoryURL: directory, availableCapacityProvider: { _ in 1024 })
        XCTAssertEqual(try store.status(for: model).state, .notInstalled)

        try Data("bad model".utf8).write(to: store.installedURL(for: model))
        let badStatus = try store.status(for: model)
        XCTAssertEqual(badStatus.state, .badHash)
        XCTAssertNotEqual(badStatus.actualSha256, expectedSha)

        try Data("good model".utf8).write(to: store.installedURL(for: model))
        XCTAssertEqual(try store.status(for: model).state, .installed)

        try Data("partial".utf8).write(to: store.stagedURL(for: model))
        try store.delete(model: model)
        XCTAssertFalse(fm.fileExists(atPath: store.installedURL(for: model).path))
        XCTAssertFalse(fm.fileExists(atPath: store.stagedURL(for: model).path))

        let fullDiskStore = ASRModelStore(directoryURL: directory, availableCapacityProvider: { _ in 1 })
        XCTAssertEqual(try fullDiskStore.status(for: model).state, .insufficientDiskSpace)
    }

    func testModelCatalogExposesConsentMetadataInstallStateAndDeleteByID() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory
            .appendingPathComponent("moongate-asr-model-catalog-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: directory) }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let hashSource = directory.appendingPathComponent("hash-source.bin")
        try Data("good model".utf8).write(to: hashSource)
        let expectedSha = try ASRModelStore.sha256(of: hashSource)
        try fm.removeItem(at: hashSource)

        let installedModel = try ASRModelInfo(
            id: "whisper.cpp:small-q5_1",
            displayName: "Whisper small q5_1",
            fileName: "ggml-small-q5_1.bin",
            downloadURL: XCTUnwrap(URL(string: "https://example.com/ggml-small-q5_1.bin")),
            sizeBytes: 181_000_000,
            sha256: expectedSha,
            memoryRequiredMB: 1024,
            license: "MIT",
            sourceDescription: "whisper.cpp model mirror"
        )
        let missingModel = try ASRModelInfo(
            id: "whisper.cpp:base-q5_1",
            displayName: "Whisper base q5_1",
            fileName: "ggml-base-q5_1.bin",
            downloadURL: XCTUnwrap(URL(string: "https://example.com/ggml-base-q5_1.bin")),
            sizeBytes: 64_000_000,
            sha256: String(repeating: "b", count: 64),
            memoryRequiredMB: 512,
            license: "MIT",
            sourceDescription: "whisper.cpp model mirror"
        )

        let store = ASRModelStore(directoryURL: directory, availableCapacityProvider: { _ in 512_000_000 })
        try Data("good model".utf8).write(to: store.installedURL(for: installedModel))
        try Data("partial".utf8).write(to: store.stagedURL(for: installedModel))

        let catalog = try ASRModelCatalog(
            manifest: ASRModelManifest(models: [installedModel, missingModel]),
            store: store
        )

        XCTAssertEqual(catalog.entries.map(\.id), [installedModel.id, missingModel.id])
        let installed = try XCTUnwrap(catalog.entry(id: installedModel.id))
        XCTAssertEqual(installed.displayName, "Whisper small q5_1")
        XCTAssertEqual(installed.sizeBytes, 181_000_000)
        XCTAssertEqual(installed.memoryRequiredMB, 1024)
        XCTAssertEqual(installed.sha256, expectedSha)
        XCTAssertEqual(installed.license, "MIT")
        XCTAssertEqual(installed.sourceDescription, "whisper.cpp model mirror")
        XCTAssertEqual(installed.downloadURL, installedModel.downloadURL)
        XCTAssertEqual(installed.installState, .installed)
        XCTAssertTrue(installed.isInstalled)
        XCTAssertFalse(installed.needsUserDownloadConsent)

        let missing = try XCTUnwrap(catalog.entry(id: missingModel.id))
        XCTAssertEqual(missing.installState, .notInstalled)
        XCTAssertFalse(missing.isInstalled)
        XCTAssertTrue(missing.needsUserDownloadConsent)

        let deleted = try catalog.deleteModel(id: installedModel.id)
        XCTAssertEqual(deleted.id, installedModel.id)
        XCTAssertFalse(fm.fileExists(atPath: store.installedURL(for: installedModel).path))
        XCTAssertFalse(fm.fileExists(atPath: store.stagedURL(for: installedModel).path))
        XCTAssertThrowsError(try catalog.deleteModel(id: "whisper.cpp:unknown")) { error in
            XCTAssertEqual(error as? ASRModelCatalogError, .unknownModelID("whisper.cpp:unknown"))
        }
    }

    func testModelInstallerDownloadsStagesVerifiesAndInstallsByID() async throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory
            .appendingPathComponent("moongate-asr-model-installer-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: directory) }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let payload = Data("verified model payload".utf8)
        let hashSource = directory.appendingPathComponent("hash-source.bin")
        try payload.write(to: hashSource)
        let expectedSha = try ASRModelStore.sha256(of: hashSource)
        try fm.removeItem(at: hashSource)
        let model = try ASRModelInfo(
            id: "whisper.cpp:test-installer",
            displayName: "Whisper installer test",
            fileName: "ggml-installer-test.bin",
            downloadURL: XCTUnwrap(URL(string: "https://example.com/ggml-installer-test.bin")),
            sizeBytes: Int64(payload.count),
            sha256: expectedSha,
            memoryRequiredMB: 64,
            license: "MIT",
            sourceDescription: "fixture"
        )

        let store = ASRModelStore(directoryURL: directory, availableCapacityProvider: { _ in 1024 * 1024 })
        let downloader = FakeASRModelDownloadClient(payload: payload)
        let installer = ASRModelInstaller(
            manifest: ASRModelManifest(models: [model]),
            store: store,
            downloader: downloader
        )
        let progressRecorder = ProgressRecorder()

        let status = try await installer.installModel(id: model.id) { progressRecorder.append($0) }

        XCTAssertEqual(status.state, .installed)
        XCTAssertEqual(try Data(contentsOf: store.installedURL(for: model)), payload)
        XCTAssertFalse(fm.fileExists(atPath: store.stagedURL(for: model).path))
        XCTAssertEqual(downloader.requests.map(\.modelID), [model.id])
        XCTAssertEqual(downloader.requests.map(\.destinationURL), [store.stagedURL(for: model)])
        let progressEvents = progressRecorder.events
        XCTAssertEqual(progressEvents.first?.phase, .modelDownload)
        XCTAssertEqual(progressEvents.last?.fraction, 1)
    }

    func testModelInstallerCleansStagingAndFailsOnHashMismatch() async throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory
            .appendingPathComponent("moongate-asr-model-installer-badhash-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: directory) }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let model = try ASRModelInfo(
            id: "whisper.cpp:test-badhash",
            displayName: "Whisper bad hash",
            fileName: "ggml-badhash-test.bin",
            downloadURL: XCTUnwrap(URL(string: "https://example.com/ggml-badhash-test.bin")),
            sizeBytes: 9,
            sha256: String(repeating: "a", count: 64),
            memoryRequiredMB: 64,
            license: "MIT",
            sourceDescription: "fixture"
        )
        let store = ASRModelStore(directoryURL: directory, availableCapacityProvider: { _ in 1024 * 1024 })
        let downloader = FakeASRModelDownloadClient(payload: Data("bad bytes".utf8))
        let installer = ASRModelInstaller(
            manifest: ASRModelManifest(models: [model]),
            store: store,
            downloader: downloader
        )

        await XCTAssertThrowsErrorAsync(try await installer.installModel(id: model.id) { _ in }) { error in
            guard let installerError = error as? ASRModelInstallerError,
                  case let .hashMismatch(modelID, _, actual) = installerError else {
                return XCTFail("Expected ASRModelInstallerError.hashMismatch, got \(error)")
            }
            XCTAssertEqual(modelID, model.id)
            XCTAssertEqual(actual.count, 64)
            XCTAssertTrue(error.localizedDescription.contains("SHA-256"))
            XCTAssertTrue(error.localizedDescription.contains(model.id))
        }
        XCTAssertFalse(fm.fileExists(atPath: store.installedURL(for: model).path))
        XCTAssertFalse(fm.fileExists(atPath: store.stagedURL(for: model).path))
    }

    func testRuntimeLocatorFindsExecutableWhisperCliCandidate() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory
            .appendingPathComponent("moongate-asr-runtime-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: directory) }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let nonExecutable = directory.appendingPathComponent("main")
        try Data("#!/bin/sh\n".utf8).write(to: nonExecutable)
        XCTAssertNil(ASRRuntimeLocator(
            candidateNames: ["main"],
            extraSearchURLs: [directory],
            environmentPath: nil
        ).locate())

        let executable = directory.appendingPathComponent("whisper-cli")
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let runtime = ASRRuntimeLocator(
            candidateNames: ["whisper-cli"],
            extraSearchURLs: [directory],
            environmentPath: nil
        ).locate()

        XCTAssertEqual(runtime?.provider, "whisper.cpp")
        XCTAssertEqual(runtime?.executableURL, executable)
    }

    func testRuntimeLocatorDefaultCandidatesDoNotAcceptGenericMainExecutable() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory
            .appendingPathComponent("moongate-asr-runtime-main-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: directory) }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let genericMain = directory.appendingPathComponent("main")
        try Data("#!/bin/sh\n".utf8).write(to: genericMain)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: genericMain.path)

        XCTAssertNil(ASRRuntimeLocator(extraSearchURLs: [directory], environmentPath: nil).locate())
    }

    func testModelStoreRejectsModelFilenamesOutsideStoreDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("moongate-asr-model-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ASRModelStore(directoryURL: directory, availableCapacityProvider: { _ in 1024 })
        let malicious = try ASRModelInfo(
            id: "whisper.cpp:bad",
            displayName: "Bad",
            fileName: "../escape.bin",
            downloadURL: XCTUnwrap(URL(string: "https://example.com/escape.bin")),
            sizeBytes: 8,
            sha256: String(repeating: "0", count: 64),
            memoryRequiredMB: 64,
            license: "MIT",
            sourceDescription: "fixture"
        )

        XCTAssertThrowsError(try store.status(for: malicious)) { error in
            XCTAssertEqual(error as? ASRModelStoreError, .invalidModelFileName("../escape.bin"))
        }
        XCTAssertThrowsError(try store.delete(model: malicious)) { error in
            XCTAssertEqual(error as? ASRModelStoreError, .invalidModelFileName("../escape.bin"))
        }
    }

    func testAudioExtractionPlanBuilds16kMonoPcmWavCommand() {
        let ffmpeg = URL(fileURLWithPath: "/usr/local/bin/ffmpeg")
        let input = URL(fileURLWithPath: "/tmp/moongate/video.mp4")
        let output = URL(fileURLWithPath: "/tmp/moongate/audio.wav")

        let plan = ASRAudioExtractionPlan(ffmpegURL: ffmpeg, inputURL: input, outputURL: output)

        XCTAssertEqual(plan.ffmpegURL, ffmpeg)
        XCTAssertEqual(plan.arguments, [
            "-y",
            "-i", input.path,
            "-map", "0:a:0",
            "-vn",
            "-ac", "1",
            "-ar", "16000",
            "-c:a", "pcm_s16le",
            "-f", "wav",
            output.path
        ])
    }

    func testWhisperCppCommandPlanUsesJsonFullLanguagePromptAndProgress() {
        let runtime = ASRRuntimeInfo(executableURL: URL(fileURLWithPath: "/opt/moongate/whisper-cli"))
        let model = URL(fileURLWithPath: "/opt/moongate/models/ggml-small.bin")
        let audio = URL(fileURLWithPath: "/tmp/moongate/audio.wav")
        let request = ASRRequest(
            audioURL: audio,
            languageCode: " ja ",
            modelID: "whisper.cpp:small",
            prompt: "title channel glossary",
            wordTimestamps: true
        )

        let plan = WhisperCppCommandPlan(
            runtime: runtime,
            modelURL: model,
            request: request,
            outputBaseURL: URL(fileURLWithPath: "/tmp/moongate/transcript.json")
        )

        XCTAssertEqual(plan.executableURL, runtime.executableURL)
        XCTAssertEqual(plan.outputBaseURL, URL(fileURLWithPath: "/tmp/moongate/transcript"))
        XCTAssertEqual(plan.outputJSONURL, URL(fileURLWithPath: "/tmp/moongate/transcript.json"))
        XCTAssertEqual(plan.arguments, [
            "-m", model.path,
            "-f", audio.path,
            "-ojf",
            "-of", "/tmp/moongate/transcript",
            "-pp",
            "-dtw", "small", "-nfa",
            "-l", "ja",
            "--prompt", "title channel glossary"
        ])

        // No token JSON requested -> DTW is pointless and must be omitted.
        let segmentJSONPlan = WhisperCppCommandPlan(
            runtime: runtime,
            modelURL: model,
            request: ASRRequest(audioURL: audio, modelID: "whisper.cpp:small", wordTimestamps: false),
            outputBaseURL: URL(fileURLWithPath: "/tmp/moongate/segments")
        )
        XCTAssertTrue(segmentJSONPlan.arguments.contains("-oj"))
        XCTAssertFalse(segmentJSONPlan.arguments.contains("-ojf"))
        XCTAssertFalse(segmentJSONPlan.arguments.contains("-dtw"))
        XCTAssertFalse(segmentJSONPlan.arguments.contains("-nfa"))

        // Unknown preset -> omit -dtw (fail-safe), never crash.
        let unknownModelPlan = WhisperCppCommandPlan(
            runtime: runtime,
            modelURL: model,
            request: ASRRequest(audioURL: audio, modelID: "whisper.cpp:test"),
            outputBaseURL: URL(fileURLWithPath: "/tmp/moongate/unknown")
        )
        XCTAssertFalse(unknownModelPlan.arguments.contains("-dtw"))
    }

    func testWhisperCppCommandPlanOmitsLanguageFlagForAutoDetect() {
        let runtime = ASRRuntimeInfo(executableURL: URL(fileURLWithPath: "/opt/moongate/whisper-cli"))
        let model = URL(fileURLWithPath: "/opt/moongate/models/ggml-small.bin")
        let audio = URL(fileURLWithPath: "/tmp/moongate/audio.wav")

        let plan = WhisperCppCommandPlan(
            runtime: runtime,
            modelURL: model,
            request: ASRRequest(
                audioURL: audio,
                languageCode: " auto ",
                modelID: "whisper.cpp:small",
                wordTimestamps: true
            ),
            outputBaseURL: URL(fileURLWithPath: "/tmp/moongate/transcript.json")
        )

        XCTAssertFalse(plan.arguments.contains("-l"))
        XCTAssertFalse(plan.arguments.contains("auto"))
    }

    func testDefaultLocalASRPromptOmitsLanguageHintForAutoDetect() {
        let video = URL(fileURLWithPath: "/tmp/Moon Gate Clip.mp4")

        XCTAssertEqual(
            ASRPromptBuilder.defaultPrompt(videoURL: video, languageCode: " ja "),
            "title=Moon Gate Clip; language=ja"
        )
        XCTAssertEqual(
            ASRPromptBuilder.defaultPrompt(videoURL: video, languageCode: " auto "),
            "title=Moon Gate Clip"
        )
        XCTAssertEqual(
            ASRPromptBuilder.defaultPrompt(videoURL: video, languageCode: " AUTO "),
            "title=Moon Gate Clip"
        )
        XCTAssertNil(ASRPromptBuilder.defaultPrompt(videoURL: URL(fileURLWithPath: "/tmp/   .mp4"), languageCode: "auto"))
    }

    func testTranscriptCacheStoreWritesReadsAndInvalidatesByInputIdentity() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory
            .appendingPathComponent("moongate-asr-transcript-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: directory) }
        let store = ASRTranscriptCacheStore(directoryURL: directory)
        let createdAt = Date(timeIntervalSince1970: 1_785_100_000)
        let transcript = ASRTranscript(
            id: "clip-auto-ja",
            languageCode: "ja",
            words: [ASRWord(text: "梅雨が明ける", startSeconds: 0.2, endSeconds: 1.5)],
            sourceModelID: "whisper.cpp:small",
            createdAt: createdAt
        )

        let entry = try store.write(
            transcript: transcript,
            cacheKey: "clip-audio-small-auto",
            audioFingerprint: "sha256:audio-a",
            createdAt: createdAt
        )

        XCTAssertTrue(fm.fileExists(atPath: store.entryURL(cacheKey: "clip-audio-small-auto").path))
        XCTAssertTrue(fm.fileExists(atPath: store.transcriptURL(cacheKey: "clip-audio-small-auto").path))
        XCTAssertEqual(try store.readEntry(cacheKey: "clip-audio-small-auto"), entry)
        XCTAssertEqual(try store.readTranscript(entry: entry), transcript)
        XCTAssertEqual(try store.cachedTranscript(
            cacheKey: "clip-audio-small-auto",
            audioFingerprint: "sha256:audio-a",
            modelID: "whisper.cpp:small",
            languageCode: nil
        ), transcript)
        XCTAssertNil(try store.cachedTranscript(
            cacheKey: "clip-audio-small-auto",
            audioFingerprint: "sha256:audio-b",
            modelID: "whisper.cpp:small",
            languageCode: nil
        ))
        XCTAssertNil(try store.cachedTranscript(
            cacheKey: "clip-audio-small-auto",
            audioFingerprint: "sha256:audio-a",
            modelID: "whisper.cpp:base",
            languageCode: nil
        ))
        XCTAssertNil(try store.cachedTranscript(
            cacheKey: "clip-audio-small-auto",
            audioFingerprint: "sha256:audio-a",
            modelID: "whisper.cpp:small",
            languageCode: "en"
        ))
    }

    func testTranscriptCacheStoresDetectedLanguageForAutoRequestAndMatchesItExplicitly() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory
            .appendingPathComponent("moongate-asr-transcript-cache-auto-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: directory) }
        let store = ASRTranscriptCacheStore(directoryURL: directory)
        let createdAt = Date(timeIntervalSince1970: 1_785_100_100)
        let transcript = ASRTranscript(
            id: "clip-auto-ja",
            languageCode: "ja",
            words: [ASRWord(text: "梅雨が明ける", startSeconds: 0.2, endSeconds: 1.5)],
            sourceModelID: "whisper.cpp:small",
            createdAt: createdAt
        )

        let entry = try store.write(
            transcript: transcript,
            cacheKey: "clip-audio-small-auto-detected",
            audioFingerprint: "sha256:audio-auto",
            languageCode: " auto ",
            createdAt: createdAt
        )

        XCTAssertEqual(entry.languageCode, "ja")
        XCTAssertEqual(try store.cachedTranscript(
            cacheKey: "clip-audio-small-auto-detected",
            audioFingerprint: "sha256:audio-auto",
            modelID: "whisper.cpp:small",
            languageCode: "auto"
        ), transcript)
        XCTAssertEqual(try store.cachedTranscript(
            cacheKey: "clip-audio-small-auto-detected",
            audioFingerprint: "sha256:audio-auto",
            modelID: "whisper.cpp:small",
            languageCode: " ja "
        ), transcript)
        XCTAssertNil(try store.cachedTranscript(
            cacheKey: "clip-audio-small-auto-detected",
            audioFingerprint: "sha256:audio-auto",
            modelID: "whisper.cpp:small",
            languageCode: "en"
        ))
    }

    func testTranscriptMapperBuildsCleanSourceFragments() {
        let transcript = ASRTranscript(
            id: "mapper",
            languageCode: "ja",
            words: [
                ASRWord(text: " 梅雨 ", startSeconds: 0.0, endSeconds: 0.4),
                ASRWord(text: "", startSeconds: 0.4, endSeconds: 0.5),
                ASRWord(text: "が", startSeconds: -1, endSeconds: 0.6),
                ASRWord(text: "明ける", startSeconds: 0.6, endSeconds: 1.2),
                ASRWord(text: "bad", startSeconds: 2.0, endSeconds: 1.0)
            ],
            sourceModelID: "whisper.cpp:test"
        )

        let fragments = ASRTranscriptMapper.sourceFragments(from: transcript)

        XCTAssertEqual(fragments.map(\.text), ["梅雨", "明ける"])
        XCTAssertEqual(fragments[0].startSeconds, 0.0, accuracy: 0.001)
        XCTAssertEqual(fragments[1].endSeconds, 1.2, accuracy: 0.001)
    }

    func testTranscriptMapperBuildsLocalASRSourceSRTWithLanguageAsLastDotSegment() throws {
        let transcript = ASRTranscript(
            id: "clip",
            languageCode: "ja",
            durationSeconds: 1.5,
            words: [
                ASRWord(text: "梅雨", startSeconds: 0.0, endSeconds: 0.6),
                ASRWord(text: "が", startSeconds: 0.6, endSeconds: 0.8),
                ASRWord(text: "明ける。", startSeconds: 0.8, endSeconds: 1.5)
            ],
            sourceModelID: "whisper.cpp:test",
            createdAt: Date(timeIntervalSince1970: 0)
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("moongate-asr-source-srt-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let videoURL = directory.appendingPathComponent("video.mp4")
        try Data("video".utf8).write(to: videoURL)

        let outputURL = try ASRTranscriptMapper.writeLocalASRSourceSRT(
            transcript: transcript,
            videoURL: videoURL
        )

        XCTAssertEqual(outputURL.lastPathComponent, "video.local-asr.ja.srt")
        let raw = try String(contentsOf: outputURL, encoding: .utf8)
        let parsed = parseSRT(raw)
        XCTAssertEqual(parsed.map(\.text), ["梅雨が明ける。"])
        XCTAssertEqual(parsed.first?.start, "00:00:00,200")
        XCTAssertEqual(parsed.first?.end, "00:00:01,500")
    }

    func testLocalASRTimingPlannerRemovesMarkersAndRejectsFlashCues() {
        let transcript = ASRTranscript(
            id: "koupen",
            languageCode: "ja",
            words: [
                ASRWord(text: "[_BEG_]", startSeconds: 0.0, endSeconds: 0.0),
                ASRWord(text: "コーペンちゃん", startSeconds: 0.1, endSeconds: 1.0),
                ASRWord(text: "[_TT_100]", startSeconds: 1.0, endSeconds: 1.0),
                ASRWord(text: "梅", startSeconds: 1.1, endSeconds: 1.4),
                ASRWord(text: "だー！", startSeconds: 1.4, endSeconds: 1.8),
                ASRWord(text: "?", startSeconds: 101.990, endSeconds: 102.000),
                ASRWord(text: "[_TT_500]", startSeconds: 112.0, endSeconds: 112.0)
            ],
            sourceModelID: "whisper.cpp:test"
        )

        let cues = ASRTranscriptMapper.sourceCues(from: transcript)

        XCTAssertEqual(cues.map(\.text), ["コーペンちゃん梅だー！"])
        // Onset nudged later by onsetDelaySeconds (raw 0.1s -> 0.3s); end holds to lastTokenEnd+hold.
        XCTAssertEqual(cues.first?.start, "00:00:00,300")
        XCTAssertEqual(cues.first?.end, "00:00:02,500")
        XCTAssertFalse(cues.contains { $0.text.contains("[_") })
    }

    func testLocalASRTimingPlannerSplitsLongCJKLyricsWithoutLongIdleHold() throws {
        let words = [
            ASRWord(text: "きょうも", startSeconds: 94.48, endSeconds: 95.30),
            ASRWord(text: "はなまる", startSeconds: 95.30, endSeconds: 96.20),
            ASRWord(text: "ぽかぽかぽかぽか", startSeconds: 96.20, endSeconds: 98.50),
            ASRWord(text: "ぽかぽかぽかぽか", startSeconds: 98.50, endSeconds: 101.65)
        ]
        let transcript = ASRTranscript(
            id: "lyrics",
            languageCode: "ja",
            words: words,
            sourceModelID: "whisper.cpp:test"
        )

        let cues = ASRTranscriptMapper.sourceCues(from: transcript)

        XCTAssertGreaterThanOrEqual(cues.count, 2)
        for cue in cues {
            let start = try XCTUnwrap(srtTimeToSeconds(cue.start))
            let end = try XCTUnwrap(srtTimeToSeconds(cue.end))
            XCTAssertGreaterThanOrEqual(end - start, 0.3)
            XCTAssertLessThanOrEqual(end - start, 4.5)
        }
    }

    func testLocalASRTimingPlannerAvoidsWeakLatinBoundaries() {
        let transcript = ASRTranscript(
            id: "latin",
            languageCode: "en",
            words: [
                ASRWord(text: "This", startSeconds: 0.0, endSeconds: 0.3),
                ASRWord(text: "is", startSeconds: 0.3, endSeconds: 0.5),
                ASRWord(text: "the", startSeconds: 0.5, endSeconds: 0.7),
                ASRWord(text: "ship", startSeconds: 0.7, endSeconds: 1.0),
                ASRWord(text: "we", startSeconds: 1.0, endSeconds: 1.2),
                ASRWord(text: "need.", startSeconds: 1.2, endSeconds: 1.6)
            ],
            sourceModelID: "whisper.cpp:test"
        )

        let cues = ASRTranscriptMapper.sourceCues(from: transcript)

        XCTAssertEqual(cues.map(\.text), ["This is the ship we need."])
        XCTAssertFalse(cues.contains { $0.text.hasSuffix(" the") })
    }

    func testLocalASRTimingPlannerMergesLoneShortCue() {
        // A long phrase pushes the soft cap so 「顔」 would break off as a lone 1-char cue; with a big
        // gap to the next word it would otherwise stand alone. It must be merged into a neighbour.
        let transcript = ASRTranscript(
            id: "lone",
            languageCode: "ja",
            words: [
                ASRWord(text: "これは", startSeconds: 0.0, endSeconds: 1.0),
                ASRWord(text: "とても", startSeconds: 1.0, endSeconds: 2.5),
                ASRWord(text: "長い文章", startSeconds: 2.5, endSeconds: 4.4),
                ASRWord(text: "顔", startSeconds: 4.45, endSeconds: 4.9),
                ASRWord(text: "洗って", startSeconds: 8.0, endSeconds: 9.0)
            ],
            sourceModelID: "whisper.cpp:test"
        )
        let cues = ASRTranscriptMapper.sourceCues(from: transcript)
        XCTAssertFalse(cues.contains { $0.text == "顔" }, "lone 1-char cue must be merged into a neighbour")
        XCTAssertTrue(cues.contains { $0.text.contains("顔") })
    }

    func testCJKWordBoundaryDetectsMidWordVsBoundary() {
        // スタンプ | カード : offset 5 is inside カード (mid-word), offset 4 is the word boundary.
        XCTAssertTrue(CJKWordBoundary.straddles("スタンプカード", at: 5))
        XCTAssertFalse(CJKWordBoundary.straddles("スタンプカード", at: 4))
        // いこう is one word: cutting at い|こう (offset 1) is mid-word.
        XCTAssertTrue(CJKWordBoundary.straddles("いこう", at: 1))
        // Ends/zero never straddle.
        XCTAssertFalse(CJKWordBoundary.straddles("いこう", at: 0))
        XCTAssertFalse(CJKWordBoundary.straddles("いこう", at: 3))
    }

    func testLocalASRTimingPlannerKeepsTrailingParticleAttachedAndDropsNoSpeech() {
        let transcript = ASRTranscript(
            id: "particle",
            languageCode: "ja",
            words: [
                ASRWord(text: "おはよう", startSeconds: 0.0, endSeconds: 0.8),
                ASRWord(text: "コーペンちゃんだ", startSeconds: 0.8, endSeconds: 3.8),
                ASRWord(text: "よ", startSeconds: 3.8, endSeconds: 4.4),   // would lead a line past the 4.5s soft cap
                ASRWord(text: "?", startSeconds: 9.0, endSeconds: 12.0)    // no-speech: must be dropped
            ],
            sourceModelID: "whisper.cpp:test"
        )
        let cues = ASRTranscriptMapper.sourceCues(from: transcript)
        // The sentence-final particle stays attached; no cue begins with it.
        XCTAssertFalse(cues.contains { $0.text.hasPrefix("よ") })
        // The lone "?" never becomes a cue.
        XCTAssertFalse(cues.contains { $0.text.contains("?") })
        XCTAssertTrue(cues.contains { $0.text.hasSuffix("よ") })
    }

    func testWhisperDTWPresetMapsQuantizedModelIDsAndRejectsUnknown() {
        XCTAssertEqual(WhisperDTWPreset.preset(forModelID: "whisper.cpp:small"), "small")
        XCTAssertEqual(WhisperDTWPreset.preset(forModelID: "whisper.cpp:small-q5_1"), "small")
        XCTAssertEqual(WhisperDTWPreset.preset(forModelID: "whisper.cpp:base-q8_0"), "base")
        XCTAssertEqual(WhisperDTWPreset.preset(forModelID: "whisper.cpp:tiny-q5_1"), "tiny")
        XCTAssertEqual(WhisperDTWPreset.preset(forModelID: "whisper.cpp:small.en-q5_1"), "small.en")
        XCTAssertEqual(WhisperDTWPreset.preset(forModelID: "whisper.cpp:medium-q5_0"), "medium")
        XCTAssertEqual(WhisperDTWPreset.preset(forModelID: "whisper.cpp:large-v3-turbo-q5_0"), "large.v3.turbo")
        XCTAssertNil(WhisperDTWPreset.preset(forModelID: "whisper.cpp:test"))
        XCTAssertNil(WhisperDTWPreset.preset(forModelID: "whisper.cpp:gigantic-q5_0"))
    }

    func testWhisperCppJSONParserPrefersDTWTokenTimestampsWhenPresent() throws {
        // t_dtw is in centiseconds; offsets in ms. When t_dtw>=0 the parser must use it: word start
        // = t_dtw/100, word end = next token's t_dtw/100 (offsets end for the last token).
        let json = """
        {
          "result": { "language": "en" },
          "transcription": [
            {
              "text": " hello world",
              "offsets": { "from": 0, "to": 2000 },
              "tokens": [
                { "text": " hello", "offsets": { "from": 0, "to": 600 }, "t_dtw": 30 },
                { "text": " world", "offsets": { "from": 600, "to": 2000 }, "t_dtw": 90 }
              ]
            }
          ]
        }
        """
        let transcript = try WhisperCppJSONTranscriptParser().parse(
            data: Data(json.utf8),
            request: ASRRequest(audioURL: URL(fileURLWithPath: "/tmp/a.wav"), modelID: "whisper.cpp:large-v3-turbo-q5_0"),
            transcriptID: "dtw"
        )
        XCTAssertEqual(transcript.words.map(\.text), ["hello", "world"])
        // hello: start 30/100=0.30, end = next t_dtw 90/100=0.90 (contiguous, within acoustic span).
        XCTAssertEqual(transcript.words[0].startSeconds, 0.30, accuracy: 0.0001)
        XCTAssertEqual(transcript.words[0].endSeconds, 0.90, accuracy: 0.0001)
        // world: start 0.90, end = DTW start + acoustic (offsets) duration 1.4 = 2.30 (last token).
        XCTAssertEqual(transcript.words[1].startSeconds, 0.90, accuracy: 0.0001)
        XCTAssertEqual(transcript.words[1].endSeconds, 2.30, accuracy: 0.0001)
    }

    func testWhisperCppJSONParserUsesOffsetsWhenDTWAbsent() throws {
        // t_dtw == -1 (not computed) -> fall back to offsets.
        let json = """
        {
          "result": { "language": "en" },
          "transcription": [
            {
              "text": " hi",
              "offsets": { "from": 100, "to": 700 },
              "tokens": [ { "text": " hi", "offsets": { "from": 100, "to": 700 }, "t_dtw": -1 } ]
            }
          ]
        }
        """
        let transcript = try WhisperCppJSONTranscriptParser().parse(
            data: Data(json.utf8),
            request: ASRRequest(audioURL: URL(fileURLWithPath: "/tmp/a.wav"), modelID: "whisper.cpp:test"),
            transcriptID: "nodtw"
        )
        XCTAssertEqual(transcript.words[0].startSeconds, 0.1, accuracy: 0.0001)
        XCTAssertEqual(transcript.words[0].endSeconds, 0.7, accuracy: 0.0001)
    }

    private func retimerCue(_ start: Double, _ end: Double, _ text: String, lastTokenEnd: Double? = nil) -> SubtitleCue {
        SubtitleCue(
            index: 0,
            start: secondsToSRTTime(start),
            end: secondsToSRTTime(end),
            text: text,
            sourceFragments: [SubtitleCueSourceFragment(startSeconds: start, endSeconds: lastTokenEnd ?? end, text: text)]
        )
    }

    func testWhisperCueRetimerDelaysOnsetAndHoldsTowardNextCue() throws {
        // Onset is nudged later by onsetDelaySeconds (long cue, not bound-limited): 5.0 -> 5.2.
        let single = WhisperCueRetimer.retime(
            [retimerCue(5.0, 9.0, "hello there", lastTokenEnd: 8.8)],
            transcriptDurationSeconds: nil
        )
        let start0 = try XCTUnwrap(srtTimeToSeconds(single[0].start))
        XCTAssertEqual(start0, 5.0 + WhisperCueRetimer.onsetDelaySeconds, accuracy: 0.0015)

        // Short cue: the delay is bounded so the cue keeps at least the minimum readable duration.
        let shortCue = WhisperCueRetimer.retime(
            [retimerCue(5.0, 5.4, "hi", lastTokenEnd: 5.4)],
            transcriptDurationSeconds: nil
        )
        let shortStart = try XCTUnwrap(srtTimeToSeconds(shortCue[0].start))
        let shortEnd = try XCTUnwrap(srtTimeToSeconds(shortCue[0].end))
        XCTAssertGreaterThan(shortEnd - shortStart, 0.0)
        XCTAssertLessThanOrEqual(shortStart, 5.4)

        // With a near next cue, the hold extends toward — but never reaches — the next onset.
        let pair = WhisperCueRetimer.retime(
            [retimerCue(1.0, 1.3, "one", lastTokenEnd: 1.2), retimerCue(3.0, 3.6, "two", lastTokenEnd: 3.5)],
            transcriptDurationSeconds: nil
        )
        let firstEnd = try XCTUnwrap(srtTimeToSeconds(pair[0].end))
        let secondStart = try XCTUnwrap(srtTimeToSeconds(pair[1].start))
        XCTAssertLessThanOrEqual(firstEnd, secondStart, "cue must not overlap the next onset")
        XCTAssertGreaterThan(firstEnd, 1.3, "cue should hold past its raw end toward the next onset")
    }

    func testWhisperCueRetimerNeverOverlapsAdjacentCues() throws {
        // Tightly spaced, short cues: the kind that previously overlapped (BUG-1).
        let cues = [
            retimerCue(1.0, 1.3, "one", lastTokenEnd: 1.05),
            retimerCue(1.1, 1.6, "two", lastTokenEnd: 1.5),
            retimerCue(1.65, 5.0, "three", lastTokenEnd: 4.9)
        ]
        let retimed = WhisperCueRetimer.retime(cues, transcriptDurationSeconds: nil)
        XCTAssertEqual(retimed.count, 3)
        var previousEnd = -Double.greatestFiniteMagnitude
        for cue in retimed {
            let start = try XCTUnwrap(srtTimeToSeconds(cue.start))
            let end = try XCTUnwrap(srtTimeToSeconds(cue.end))
            XCTAssertGreaterThanOrEqual(start + 0.0011, previousEnd, "cue overlaps previous cue")
            XCTAssertGreaterThan(end, start, "cue must have positive duration")
            previousEnd = end
        }
    }

    func testWhisperCueRetimerRespectsDurationCapAndTranscriptLength() throws {
        // A long CJK cue must stay within the hard CJK cap even after grouping holds particles.
        let longCJK = WhisperCueRetimer.retime([retimerCue(10.0, 30.0, "字幕字幕字幕字幕")], transcriptDurationSeconds: nil)
        let start = try XCTUnwrap(srtTimeToSeconds(longCJK[0].start))
        let end = try XCTUnwrap(srtTimeToSeconds(longCJK[0].end))
        XCTAssertLessThanOrEqual(end - start, LocalASRSubtitleTimingPlanner.hardMaximumCJKCueSeconds + 0.0015)

        // Transcript duration is a hard end ceiling.
        let clamped = WhisperCueRetimer.retime([retimerCue(8.0, 20.0, "字幕")], transcriptDurationSeconds: 11.0)
        let clampedEnd = try XCTUnwrap(srtTimeToSeconds(clamped[0].end))
        XCTAssertLessThanOrEqual(clampedEnd, 11.0 + 0.0015)
    }

    func testWhisperCppJSONParserBuildsTranscriptFromTokenOffsets() throws {
        let createdAt = Date(timeIntervalSince1970: 1_785_200_000)
        let json = Data("""
        {
          "result": { "language": "ja", "language_probability": 0.88 },
          "transcription": [
            {
              "text": " 梅雨 が 明ける",
              "offsets": { "from": 0, "to": 1500 },
              "tokens": [
                { "text": " 梅雨", "offsets": { "from": 0, "to": 600 }, "p": 0.82 },
                { "text": " が", "offsets": { "from": 600, "to": 800 }, "p": 0.93 },
                { "text": " 明ける", "offsets": { "from": 800, "to": 1500 }, "p": 0.76 }
              ]
            }
          ]
        }
        """.utf8)
        let request = ASRRequest(
            audioURL: URL(fileURLWithPath: "/tmp/audio.wav"),
            languageCode: "ja",
            modelID: "whisper.cpp:small-q5_1"
        )

        let transcript = try WhisperCppJSONTranscriptParser().parse(
            data: json,
            request: request,
            transcriptID: "clip-ja-small",
            createdAt: createdAt
        )

        XCTAssertEqual(transcript.id, "clip-ja-small")
        XCTAssertEqual(transcript.languageCode, "ja")
        XCTAssertEqual(transcript.languageConfidence, 0.88)
        XCTAssertEqual(try XCTUnwrap(transcript.durationSeconds), 1.5, accuracy: 0.001)
        XCTAssertEqual(transcript.words.map(\.text), ["梅雨", "が", "明ける"])
        XCTAssertEqual(transcript.words[0].startSeconds, 0.0, accuracy: 0.001)
        XCTAssertEqual(transcript.words[0].endSeconds, 0.6, accuracy: 0.001)
        XCTAssertEqual(transcript.words[2].probability, 0.76)
        XCTAssertEqual(transcript.sourceModelID, "whisper.cpp:small-q5_1")
        XCTAssertEqual(transcript.createdAt, createdAt)
    }

    func testWhisperCppJSONParserFallsBackToSegmentTextWhenNoTokenWords() throws {
        let json = Data("""
        {
          "params": { "language": "ja" },
          "transcription": [
            {
              "text": " 新聞紙",
              "offsets": { "from": 200, "to": 1100 },
              "tokens": []
            }
          ]
        }
        """.utf8)
        let request = ASRRequest(
            audioURL: URL(fileURLWithPath: "/tmp/audio.wav"),
            modelID: "whisper.cpp:base"
        )

        let transcript = try WhisperCppJSONTranscriptParser().parse(
            data: json,
            request: request,
            transcriptID: "fallback",
            createdAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(transcript.languageCode, "ja")
        XCTAssertEqual(try XCTUnwrap(transcript.durationSeconds), 1.1, accuracy: 0.001)
        XCTAssertEqual(transcript.words, [
            ASRWord(text: "新聞紙", startSeconds: 0.2, endSeconds: 1.1)
        ])
    }

    func testWhisperCppRecognizerRunsCommandWritesCacheAndReportsProgress() async throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory
            .appendingPathComponent("moongate-asr-runner-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: directory) }
        let outputDirectory = directory.appendingPathComponent("out", isDirectory: true)
        let cacheDirectory = directory.appendingPathComponent("cache", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let audio = directory.appendingPathComponent("audio.wav")
        let model = directory.appendingPathComponent("ggml-test.bin")
        let runtime = directory.appendingPathComponent("whisper-cli")
        try Data("audio fixture".utf8).write(to: audio)
        try Data("model fixture".utf8).write(to: model)
        try Data("#!/bin/sh\n".utf8).write(to: runtime)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runtime.path)

        let runner = RecordingASRCommandRunner { plan, onLine in
            try FileManager.default.createDirectory(
                at: plan.outputJSONURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            onLine("whisper.cpp progress: 25%")
            onLine("whisper.cpp progress: 100%")
            try Data("""
            {
              "result": { "language": "ja" },
              "transcription": [
                {
                  "text": " 梅雨 が 明ける",
                  "offsets": { "from": 0, "to": 1500 },
                  "tokens": [
                    { "text": " 梅雨", "offsets": { "from": 0, "to": 600 } },
                    { "text": " が", "offsets": { "from": 600, "to": 800 } },
                    { "text": " 明ける", "offsets": { "from": 800, "to": 1500 } }
                  ]
                }
              ]
            }
            """.utf8).write(to: plan.outputJSONURL)
            return ASRCommandResult(status: 0, stderrTail: "")
        }
        let recognizer = WhisperCppSpeechRecognizer(
            runtime: ASRRuntimeInfo(executableURL: runtime),
            modelURL: model,
            outputDirectoryURL: outputDirectory,
            cacheStore: ASRTranscriptCacheStore(directoryURL: cacheDirectory),
            commandRunner: runner,
            nowProvider: { Date(timeIntervalSince1970: 1_785_300_000) }
        )
        let request = ASRRequest(
            audioURL: audio,
            languageCode: "ja",
            modelID: "whisper.cpp:test",
            cacheKey: "clip-ja-local-asr"
        )
        let progressRecorder = ProgressRecorder()

        let first = try await recognizer.transcribe(request) { progressRecorder.append($0) }
        let second = try await recognizer.transcribe(request) { _ in }

        XCTAssertEqual(runner.callCount, 1)
        XCTAssertEqual(first.words.map(\.text), ["梅雨", "が", "明ける"])
        XCTAssertEqual(second, first)
        XCTAssertEqual(progressRecorder.events.map(\.fraction), [0, 0.25, 1, 1])
        XCTAssertNotNil(try ASRTranscriptCacheStore(directoryURL: cacheDirectory).readEntry(cacheKey: "clip-ja-local-asr"))
    }

    func testWhisperCppLocalASRSubtitleGeneratorExtractsTranscribesAndWritesSourceSRT() async throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory
            .appendingPathComponent("moongate-asr-generator-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: directory) }
        let workDirectory = directory.appendingPathComponent("work", isDirectory: true)
        let outputDirectory = directory.appendingPathComponent("out", isDirectory: true)
        let cacheDirectory = directory.appendingPathComponent("cache", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let video = directory.appendingPathComponent("clip.mp4")
        let ffmpeg = directory.appendingPathComponent("ffmpeg")
        let model = directory.appendingPathComponent("ggml-test.bin")
        let runtime = directory.appendingPathComponent("whisper-cli")
        try Data("video fixture".utf8).write(to: video)
        try Data("#!/bin/sh\n".utf8).write(to: ffmpeg)
        try Data("model fixture".utf8).write(to: model)
        try Data("#!/bin/sh\n".utf8).write(to: runtime)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ffmpeg.path)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runtime.path)

        let audioExtractor = RecordingASRAudioExtractor { plan, progress in
            progress(ASRProgress(phase: .audioExtract, completedUnits: 0.5, totalUnits: 1))
            try FileManager.default.createDirectory(
                at: plan.outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("wav fixture".utf8).write(to: plan.outputURL)
            return plan.outputURL
        }
        let runner = RecordingASRCommandRunner { plan, onLine in
            try FileManager.default.createDirectory(
                at: plan.outputJSONURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            onLine("whisper.cpp progress: 50%")
            try Data("""
            {
              "result": { "language": "ja" },
              "transcription": [
                {
                  "text": " 梅雨 が 明ける",
                  "offsets": { "from": 0, "to": 1500 },
                  "tokens": [
                    { "text": " 梅雨", "offsets": { "from": 0, "to": 600 } },
                    { "text": " が", "offsets": { "from": 600, "to": 800 } },
                    { "text": " 明ける。", "offsets": { "from": 800, "to": 1500 } }
                  ]
                }
              ]
            }
            """.utf8).write(to: plan.outputJSONURL)
            return ASRCommandResult(status: 0, stderrTail: "")
        }
        let recognizer = WhisperCppSpeechRecognizer(
            runtime: ASRRuntimeInfo(executableURL: runtime),
            modelURL: model,
            outputDirectoryURL: outputDirectory,
            cacheStore: ASRTranscriptCacheStore(directoryURL: cacheDirectory),
            commandRunner: runner,
            nowProvider: { Date(timeIntervalSince1970: 1_785_400_000) }
        )
        let generator = WhisperCppLocalASRSubtitleGenerator(
            ffmpegURL: ffmpeg,
            workDirectoryURL: workDirectory,
            recognizer: recognizer,
            modelID: "whisper.cpp:test",
            promptProvider: { videoURL, languageCode in
                "title=\(videoURL.deletingPathExtension().lastPathComponent); lang=\(languageCode)"
            },
            audioExtractor: audioExtractor
        )
        let progressRecorder = ProgressRecorder()

        let outputURL = try await generator.generateSourceSubtitle(
            videoFile: video,
            languageCode: "ja",
            control: nil
        ) { progressRecorder.append($0) }

        XCTAssertEqual(outputURL.lastPathComponent, "clip.local-asr.ja.srt")
        let parsed = parseSRT(try String(contentsOf: outputURL, encoding: .utf8))
        XCTAssertEqual(parsed.map(\.text), ["梅雨が明ける。"])
        XCTAssertEqual(audioExtractor.plans.map(\.inputURL), [video])
        XCTAssertEqual(audioExtractor.plans.first?.ffmpegURL, ffmpeg)
        XCTAssertEqual(runner.callCount, 1)
        let request = try XCTUnwrap(runner.plans.first?.request)
        XCTAssertEqual(request.audioURL, audioExtractor.plans.first?.outputURL)
        XCTAssertEqual(request.languageCode, "ja")
        XCTAssertEqual(request.modelID, "whisper.cpp:test")
        XCTAssertEqual(request.prompt, "title=clip; lang=ja")
        XCTAssertNotNil(request.cacheKey)
        XCTAssertTrue(progressRecorder.events.contains { $0.phase == .audioExtract })
        XCTAssertTrue(progressRecorder.events.contains { $0.phase == .speechRecognition })
        XCTAssertEqual(progressRecorder.events.last, ASRProgress(phase: .subtitleSegment, completedUnits: 1, totalUnits: 1))
    }

    func testWhisperCppLocalASRSubtitleGeneratorReusesAutoTranscriptCache() async throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory
            .appendingPathComponent("moongate-asr-generator-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: directory) }
        let workDirectory = directory.appendingPathComponent("work", isDirectory: true)
        let outputDirectory = directory.appendingPathComponent("out", isDirectory: true)
        let cacheDirectory = directory.appendingPathComponent("cache", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let video = directory.appendingPathComponent("clip.mp4")
        let ffmpeg = directory.appendingPathComponent("ffmpeg")
        let model = directory.appendingPathComponent("ggml-test.bin")
        let runtime = directory.appendingPathComponent("whisper-cli")
        try Data("video fixture".utf8).write(to: video)
        try Data("#!/bin/sh\n".utf8).write(to: ffmpeg)
        try Data("model fixture".utf8).write(to: model)
        try Data("#!/bin/sh\n".utf8).write(to: runtime)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ffmpeg.path)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runtime.path)

        let audioExtractor = RecordingASRAudioExtractor { plan, _ in
            try FileManager.default.createDirectory(
                at: plan.outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("wav fixture".utf8).write(to: plan.outputURL)
            return plan.outputURL
        }
        let runner = RecordingASRCommandRunner { plan, _ in
            try FileManager.default.createDirectory(
                at: plan.outputJSONURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("""
            {
              "result": { "language": "ja" },
              "transcription": [
                {
                  "text": " 梅雨 が 明ける",
                  "offsets": { "from": 0, "to": 1500 },
                  "tokens": [
                    { "text": " 梅雨", "offsets": { "from": 0, "to": 600 } },
                    { "text": " が", "offsets": { "from": 600, "to": 800 } },
                    { "text": " 明ける。", "offsets": { "from": 800, "to": 1500 } }
                  ]
                }
              ]
            }
            """.utf8).write(to: plan.outputJSONURL)
            return ASRCommandResult(status: 0, stderrTail: "")
        }
        let recognizer = WhisperCppSpeechRecognizer(
            runtime: ASRRuntimeInfo(executableURL: runtime),
            modelURL: model,
            outputDirectoryURL: outputDirectory,
            cacheStore: ASRTranscriptCacheStore(directoryURL: cacheDirectory),
            commandRunner: runner,
            nowProvider: { Date(timeIntervalSince1970: 1_785_400_100) }
        )
        let generator = WhisperCppLocalASRSubtitleGenerator(
            ffmpegURL: ffmpeg,
            workDirectoryURL: workDirectory,
            recognizer: recognizer,
            modelID: "whisper.cpp:test",
            promptProvider: { videoURL, languageCode in
                ASRPromptBuilder.defaultPrompt(videoURL: videoURL, languageCode: languageCode)
            },
            audioExtractor: audioExtractor
        )

        let firstOutput = try await generator.generateSourceSubtitle(
            videoFile: video,
            languageCode: "auto",
            control: nil
        ) { _ in }
        let secondProgress = ProgressRecorder()
        let secondOutput = try await generator.generateSourceSubtitle(
            videoFile: video,
            languageCode: "auto",
            control: nil,
            progress: { secondProgress.append($0) }
        )

        XCTAssertEqual(firstOutput, secondOutput)
        XCTAssertEqual(secondOutput.lastPathComponent, "clip.local-asr.ja.srt")
        XCTAssertEqual(audioExtractor.plans.count, 1)
        XCTAssertEqual(runner.callCount, 1)
        XCTAssertEqual(runner.plans.first?.request.languageCode, "auto")
        XCTAssertEqual(runner.plans.first?.request.prompt, "title=clip")
        XCTAssertTrue(secondProgress.events.contains(ASRProgress(phase: .speechRecognition, completedUnits: 1, totalUnits: 1)))
    }

    func testLocalASRGeneratorFactoryRequiresExplicitReadySettings() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory
            .appendingPathComponent("moongate-asr-factory-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: directory) }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let ffmpeg = directory.appendingPathComponent("ffmpeg")
        let runtime = directory.appendingPathComponent("whisper-cli")
        let model = directory.appendingPathComponent("ggml-small-q5_1.bin")
        for url in [ffmpeg, runtime] {
            try Data("#!/bin/sh\n".utf8).write(to: url)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        try Data("model fixture".utf8).write(to: model)
        let enabled = AppSettings(
            localASREnabled: true,
            localASRRuntimePath: runtime.path,
            localASRModelPath: model.path,
            localASRModelID: "custom:test"
        )

        XCTAssertNil(LocalASRGeneratorFactory.make(
            settings: AppSettings(),
            ffmpegURL: ffmpeg,
            supportDirectoryURL: directory
        ))
        XCTAssertNil(LocalASRGeneratorFactory.make(
            settings: enabled,
            ffmpegURL: nil,
            supportDirectoryURL: directory
        ))
        XCTAssertNil(LocalASRGeneratorFactory.make(
            settings: enabled,
            ffmpegURL: ffmpeg.deletingLastPathComponent().appendingPathComponent("missing-ffmpeg"),
            supportDirectoryURL: directory
        ))
        XCTAssertNotNil(LocalASRGeneratorFactory.make(
            settings: enabled,
            ffmpegURL: ffmpeg,
            supportDirectoryURL: directory
        ))
    }

    func testLocalASRGeneratorFactoryRejectsBadHashForRecommendedModel() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory
            .appendingPathComponent("moongate-asr-factory-bad-hash-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: directory) }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let ffmpeg = directory.appendingPathComponent("ffmpeg")
        let runtime = directory.appendingPathComponent("whisper-cli")
        for url in [ffmpeg, runtime] {
            try Data("#!/bin/sh\n".utf8).write(to: url)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        let supportDirectory = directory.appendingPathComponent("support", isDirectory: true)
        let store = ASRModelStore(directoryURL: supportDirectory
            .appendingPathComponent("asr", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true))
        let model = try XCTUnwrap(ASRModelManifest.recommendedWhisperCpp.models.first)
        let installedURL = store.installedURL(for: model)
        try fm.createDirectory(at: installedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("wrong model payload".utf8).write(to: installedURL)
        let enabled = AppSettings(
            localASREnabled: true,
            localASRRuntimePath: runtime.path,
            localASRModelPath: installedURL.path,
            localASRModelID: model.id
        )

        XCTAssertNil(LocalASRGeneratorFactory.make(
            settings: enabled,
            ffmpegURL: ffmpeg,
            supportDirectoryURL: supportDirectory
        ))
    }

    func testWhisperCppRecognizerPropagatesCancellationAndDoesNotCache() async throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory
            .appendingPathComponent("moongate-asr-cancel-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: directory) }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let audio = directory.appendingPathComponent("audio.wav")
        let model = directory.appendingPathComponent("ggml-test.bin")
        let runtime = directory.appendingPathComponent("whisper-cli")
        try Data("audio fixture".utf8).write(to: audio)
        try Data("model fixture".utf8).write(to: model)
        try Data("#!/bin/sh\n".utf8).write(to: runtime)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runtime.path)
        let cache = ASRTranscriptCacheStore(directoryURL: directory.appendingPathComponent("cache", isDirectory: true))
        let recognizer = WhisperCppSpeechRecognizer(
            runtime: ASRRuntimeInfo(executableURL: runtime),
            modelURL: model,
            outputDirectoryURL: directory.appendingPathComponent("out", isDirectory: true),
            cacheStore: cache,
            commandRunner: RecordingASRCommandRunner { _, _ in throw CancellationError() }
        )
        let request = ASRRequest(
            audioURL: audio,
            languageCode: "ja",
            modelID: "whisper.cpp:test",
            cacheKey: "cancelled"
        )

        await XCTAssertThrowsErrorAsync(try await recognizer.transcribe(request) { _ in }) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertNil(try cache.readEntry(cacheKey: "cancelled"))
    }

    func testWhisperCppRecognizerRejectsNonZeroExit() async throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory
            .appendingPathComponent("moongate-asr-exit-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: directory) }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let audio = directory.appendingPathComponent("audio.wav")
        let model = directory.appendingPathComponent("ggml-test.bin")
        let runtime = directory.appendingPathComponent("whisper-cli")
        try Data("audio fixture".utf8).write(to: audio)
        try Data("model fixture".utf8).write(to: model)
        try Data("#!/bin/sh\n".utf8).write(to: runtime)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runtime.path)
        let recognizer = WhisperCppSpeechRecognizer(
            runtime: ASRRuntimeInfo(executableURL: runtime),
            modelURL: model,
            outputDirectoryURL: directory.appendingPathComponent("out", isDirectory: true),
            commandRunner: RecordingASRCommandRunner { _, _ in
                ASRCommandResult(status: 2, stderrTail: "bad model")
            }
        )

        await XCTAssertThrowsErrorAsync(try await recognizer.transcribe(
            ASRRequest(audioURL: audio, modelID: "whisper.cpp:test")
        ) { _ in }) { error in
            XCTAssertEqual(error as? WhisperCppRecognizerError, .processFailed(status: 2, stderrTail: "bad model"))
        }
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ verify: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected async expression to throw", file: file, line: line)
    } catch {
        verify(error)
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ASRProgress] = []

    var events: [ASRProgress] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ progress: ASRProgress) {
        lock.lock()
        storage.append(progress)
        lock.unlock()
    }
}

private final class FakeASRModelDownloadClient: ASRModelDownloadClient, @unchecked Sendable {
    struct Request: Equatable {
        let modelID: String
        let destinationURL: URL
    }

    private let payload: Data
    private(set) var requests: [Request] = []

    init(payload: Data) {
        self.payload = payload
    }

    func downloadModel(
        _ model: ASRModelInfo,
        to destinationURL: URL,
        progress: @escaping @Sendable (ASRProgress) -> Void
    ) async throws {
        requests.append(Request(modelID: model.id, destinationURL: destinationURL))
        progress(ASRProgress(phase: .modelDownload, completedUnits: 0, totalUnits: Double(model.sizeBytes)))
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try payload.write(to: destinationURL)
        progress(ASRProgress(
            phase: .modelDownload,
            completedUnits: Double(payload.count),
            totalUnits: Double(model.sizeBytes)
        ))
    }
}

private final class RecordingASRCommandRunner: ASRCommandRunner, @unchecked Sendable {
    typealias Handler = @Sendable (
        WhisperCppCommandPlan,
        @escaping @Sendable (String) -> Void
    ) async throws -> ASRCommandResult

    private let lock = NSLock()
    private let handler: Handler
    private var calls = 0
    private var recordedPlans: [WhisperCppCommandPlan] = []

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    var plans: [WhisperCppCommandPlan] {
        lock.lock()
        defer { lock.unlock() }
        return recordedPlans
    }

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func runWhisper(
        plan: WhisperCppCommandPlan,
        control: TaskControlToken?,
        onLine: @escaping @Sendable (String) -> Void
    ) async throws -> ASRCommandResult {
        record(plan)
        return try await handler(plan, onLine)
    }

    private func record(_ plan: WhisperCppCommandPlan) {
        lock.lock()
        calls += 1
        recordedPlans.append(plan)
        lock.unlock()
    }
}

private final class RecordingASRAudioExtractor: ASRAudioExtractor, @unchecked Sendable {
    typealias Handler = @Sendable (
        ASRAudioExtractionPlan,
        @escaping @Sendable (ASRProgress) -> Void
    ) async throws -> URL

    private let lock = NSLock()
    private let handler: Handler
    private var recordedPlans: [ASRAudioExtractionPlan] = []

    var plans: [ASRAudioExtractionPlan] {
        lock.lock()
        defer { lock.unlock() }
        return recordedPlans
    }

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func extractAudio(
        plan: ASRAudioExtractionPlan,
        control: TaskControlToken?,
        progress: @escaping @Sendable (ASRProgress) -> Void
    ) async throws -> URL {
        record(plan)
        return try await handler(plan, progress)
    }

    private func record(_ plan: ASRAudioExtractionPlan) {
        lock.lock()
        recordedPlans.append(plan)
        lock.unlock()
    }
}
