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

    func testProgressLineParserOnlyMatchesWhisperProgressLinesNotTranscriptText() {
        // 真实 whisper.cpp 进度行应解析出进度（兼容 `=`/`:` 两种版本分隔符）。
        let p1 = ASRProgressLineParser.whisperCppProgress(from: "whisper_print_progress_callback: progress =  50%")
        XCTAssertEqual(p1?.completedUnits, 50)
        XCTAssertEqual(p1?.totalUnits, 100)
        let p2 = ASRProgressLineParser.whisperCppProgress(from: "whisper.cpp progress: 25%")
        XCTAssertEqual(p2?.completedUnits, 25)
        let p3 = ASRProgressLineParser.whisperCppProgress(from: "progress = 100%")
        XCTAssertEqual(p3?.completedUnits, 100)
        // 回归 BUG-B：含 % 但无 “progress” 关键字的转写台词文本不应被误判为进度（否则进度条会随台词来回乱跳）。
        XCTAssertNil(ASRProgressLineParser.whisperCppProgress(from: "[00:00:01.000 --> 00:00:03.000]  sales were up 50% this year"))
        XCTAssertNil(ASRProgressLineParser.whisperCppProgress(from: "彼は「100%確実だ」と言った"))
        XCTAssertNil(ASRProgressLineParser.whisperCppProgress(from: "no percent here"))
    }

    func testWhisperTimingConstantsMatchCrossPlatformFixture() throws {
        // ARCH-3：Swift 与 C# 的 whisper 时序常量是两份手写字面量。共享 fixture 作为唯一真值，
        // 两端各断言本端常量等于它；任一端改动都会让该端失败，强制同步另一端，把 parity 从巧合变结构。
        let url = packageRoot()
            .appendingPathComponent("Tests")
            .appendingPathComponent("fixtures")
            .appendingPathComponent("whisper-timing-constants.json")
        let data = try Data(contentsOf: url)
        let fixture = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        func value(_ key: String) throws -> Double {
            try XCTUnwrap((fixture[key] as? NSNumber)?.doubleValue, "fixture missing numeric key \(key)")
        }
        XCTAssertEqual(WhisperCueRetimer.onsetDelaySeconds, try value("onsetDelaySeconds"))
        XCTAssertEqual(WhisperCueRetimer.interCueGuardSeconds, try value("interCueGuardSeconds"))
        XCTAssertEqual(WhisperCueRetimer.holdToNextSeconds, try value("holdToNextSeconds"))
        XCTAssertEqual(WhisperCueRetimer.mixedCJKLatinHoldToNextSeconds, try value("mixedCjkLatinHoldToNextSeconds"))
        XCTAssertEqual(LocalASRSubtitleTimingPlanner.minimumCueSeconds, try value("minimumCueSeconds"))

        // 每个 timing profile 的阈值表也必须等于 fixture 的 profiles 段（ARCH-3，逐档逐字段）。
        let profiles = try XCTUnwrap(fixture["profiles"] as? [String: [String: Any]], "fixture missing profiles")
        func profileValue(_ profile: String, _ key: String) throws -> Double {
            let entry = try XCTUnwrap(profiles[profile], "fixture missing profile \(profile)")
            // residualMaxStandaloneSeconds 在 speech 档省略，表示无约束（greatestFiniteMagnitude）。
            guard let number = entry[key] as? NSNumber else {
                return .greatestFiniteMagnitude
            }
            return number.doubleValue
        }
        for (name, profile) in [
            ("speech", SubtitleTimingProfile.speech),
            ("lyrics", .lyrics),
            ("japaneseLyrics", .japaneseLyrics),
            ("anime", .anime)
        ] {
            let t = LocalASRSubtitleTimingPlanner.thresholds(for: profile)
            XCTAssertEqual(t.maximumCJKCueSeconds, try profileValue(name, "maximumCJKCueSeconds"), "\(name).maximumCJKCueSeconds")
            XCTAssertEqual(t.hardMaximumCJKCueSeconds, try profileValue(name, "hardMaximumCJKCueSeconds"), "\(name).hardMaximumCJKCueSeconds")
            XCTAssertEqual(t.relaxedCJKCueSeconds, try profileValue(name, "relaxedCJKCueSeconds"), "\(name).relaxedCJKCueSeconds")
            XCTAssertEqual(t.maximumLatinCueSeconds, try profileValue(name, "maximumLatinCueSeconds"), "\(name).maximumLatinCueSeconds")
            XCTAssertEqual(t.largeSpeechGapSeconds, try profileValue(name, "largeSpeechGapSeconds"), "\(name).largeSpeechGapSeconds")
            XCTAssertEqual(t.onsetDelaySeconds, try profileValue(name, "onsetDelaySeconds"), "\(name).onsetDelaySeconds")
            XCTAssertEqual(t.holdToNextSeconds, try profileValue(name, "holdToNextSeconds"), "\(name).holdToNextSeconds")
            XCTAssertEqual(t.residualMaxStandaloneSeconds, try profileValue(name, "residualMaxStandaloneSeconds"), "\(name).residualMaxStandaloneSeconds")
            XCTAssertEqual(t.breathGapBreakSeconds, try profileValue(name, "breathGapBreakSeconds"), "\(name).breathGapBreakSeconds")
        }
        // speech 档必须等于顶层标量常量（零行为退化的结构保证）。
        let speech = LocalASRSubtitleTimingPlanner.thresholds(for: .speech)
        XCTAssertEqual(speech.onsetDelaySeconds, WhisperCueRetimer.onsetDelaySeconds)
        XCTAssertEqual(speech.holdToNextSeconds, WhisperCueRetimer.holdToNextSeconds)
        XCTAssertEqual(speech.maximumCJKCueSeconds, LocalASRSubtitleTimingPlanner.maximumCJKCueSeconds)
        XCTAssertEqual(speech.hardMaximumCJKCueSeconds, LocalASRSubtitleTimingPlanner.hardMaximumCJKCueSeconds)
        XCTAssertEqual(speech.relaxedCJKCueSeconds, LocalASRSubtitleTimingPlanner.relaxedCJKCueSeconds)
        XCTAssertEqual(speech.maximumLatinCueSeconds, LocalASRSubtitleTimingPlanner.maximumLatinCueSeconds)
    }

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    // MARK: - M5 CJK word-boundary parity (macOS NaturalLanguage vs Windows script-run)

    /// Curated (text, cutOffset, expectedStraddle) cases where the macOS NLTokenizer and the Windows
    /// same-script-run segmenter must agree. The identical table is asserted in C# CjkWordBoundary
    /// parity test, so the two platforms can never silently diverge on these. Hiragana-internal
    /// particle boundaries (e.g. ...た|ね) are intentionally excluded: a dictionary-free segmenter
    /// cannot resolve them, and the planner handles them via the leading-prohibited heuristic, not
    /// this tokenizer — so a divergence there is harmless.
    static let cjkBoundaryParityCases: [(String, Int, Bool)] = [
        ("カード", 2, true),       // inside a katakana word
        ("hello", 2, true),       // inside a latin word
        ("1234", 2, true),        // inside a digit run
        ("動く", 1, true),         // kanji stem + hiragana okurigana = one word
        ("カードを", 3, false),     // katakana word | particle を (script change)
        ("ABC始", 3, false),       // latin run | kanji (script change, not okurigana)
        ("食べた今", 3, false)      // hiragana | kanji (script change)
    ]

    func testCJKWordBoundaryMatchesParityTable() {
        for (text, offset, expected) in Self.cjkBoundaryParityCases {
            XCTAssertEqual(CJKWordBoundary.straddles(text, at: offset), expected, "straddles(\(text), \(offset))")
        }
    }

    // MARK: - M2 timing profile detection + lyrics/anime regroup

    private func srtCue(_ index: Int, _ start: Double, _ end: Double, _ text: String) -> SubtitleCue {
        SubtitleCue(index: index, start: secondsToSRTTime(start), end: secondsToSRTTime(end), text: text, sourceFragments: [])
    }

    func testTimingProfileDetectorRoutesByFilenameAndShape() {
        // Filename keyword wins immediately (even with few cues).
        XCTAssertEqual(SubtitleTimingProfileDetector.detect(fileName: "Artist - Title (Official MV).mp4", cues: []), .lyrics)
        XCTAssertEqual(
            SubtitleTimingProfileDetector.detect(
                fileName: "YOASOBI Official Music Video.local-asr.ja.srt",
                cues: [],
                languageCode: "ja"
            ),
            .japaneseLyrics
        )
        XCTAssertEqual(SubtitleTimingProfileDetector.detect(fileName: "Some Anime EP.12.mkv", cues: []), .anime)

        // Sung-verse shape: sparse end punctuation, medium lines, frequent silent gaps.
        var lyricCues: [SubtitleCue] = []
        var t = 0.0
        for i in 0..<24 {
            lyricCues.append(srtCue(i + 1, t, t + 4.0, "歌詞のフレーズ \(i)"))
            t += 4.0 + 1.4 // 1.4s gap between phrases
        }
        XCTAssertEqual(SubtitleTimingProfileDetector.detect(fileName: "live.mp4", cues: lyricCues), .japaneseLyrics)
        XCTAssertEqual(
            SubtitleTimingProfileDetector.detect(fileName: "live.mp4", cues: lyricCues, languageCode: "en"),
            .japaneseLyrics,
            "kana-heavy lyrics should still route to Japanese lyrics even if metadata is wrong"
        )

        // Lecture shape: full sentences, longer continuous lines -> speech.
        var speechCues: [SubtitleCue] = []
        t = 0.0
        for i in 0..<24 {
            speechCues.append(srtCue(i + 1, t, t + 3.5, "This is a full explanatory sentence number \(i)."))
            t += 3.6
        }
        XCTAssertEqual(SubtitleTimingProfileDetector.detect(fileName: "lecture.mp4", cues: speechCues), .speech)
    }

    func testAnimeFilenameHeuristicRequiresDigitAdjacentEpisodeMarkers() {
        // Strong keywords still route to anime.
        XCTAssertEqual(SubtitleTimingProfileDetector.detect(fileName: "アニメ OP.mp4", cues: []), .anime)
        XCTAssertEqual(SubtitleTimingProfileDetector.detect(fileName: "新番动画 PV.mp4", cues: []), .anime)

        // Digit-adjacent episode markers (incl. fullwidth digits) route to anime.
        XCTAssertEqual(SubtitleTimingProfileDetector.detect(fileName: "Spy Family 第12話.mkv", cues: []), .anime)
        XCTAssertEqual(SubtitleTimingProfileDetector.detect(fileName: "番剧 第３话.mp4", cues: []), .anime)
        XCTAssertEqual(SubtitleTimingProfileDetector.detect(fileName: "Episode 5 Recap.mkv", cues: []), .anime)
        XCTAssertEqual(SubtitleTimingProfileDetector.detect(fileName: "show EP.12 highlights.mkv", cues: []), .anime)

        // Bare 第 / 话 / 話 without an adjacent number must NOT be treated as anime anymore.
        XCTAssertEqual(SubtitleTimingProfileDetector.detect(fileName: "第一财经 产品评测.mp4", cues: []), .speech)
        XCTAssertEqual(SubtitleTimingProfileDetector.detect(fileName: "今天的话题讨论.mp4", cues: []), .speech)
        // "ep" embedded mid-word must not false-positive on a trailing number.
        XCTAssertEqual(SubtitleTimingProfileDetector.detect(fileName: "deep dive 3.mp4", cues: []), .speech)
        XCTAssertEqual(SubtitleTimingProfileDetector.detect(fileName: "keep calm 2024.mp4", cues: []), .speech)
    }

    func testLyricsProfileSplitsTighterThanSpeech() throws {
        // A 5.2s continuous CJK run: speech keeps it whole (<5.5s hard cap), lyrics (4.0s hard cap)
        // must split it into shorter sung lines.
        let words = (0..<13).map { i in
            ASRWord(text: "うた", startSeconds: Double(i) * 0.4, endSeconds: Double(i) * 0.4 + 0.4)
        }
        let transcript = ASRTranscript(id: "l", languageCode: "ja", words: words, sourceModelID: "whisper.cpp:test")
        let speech = ASRTranscriptMapper.sourceCues(from: transcript, profile: .speech)
        let lyrics = ASRTranscriptMapper.sourceCues(from: transcript, profile: .lyrics)
        // Assert on the longest cue duration (tokenizer-independent) rather than raw cue count.
        func maxDuration(_ cues: [SubtitleCue]) -> Double {
            cues.map { (srtTimeToSeconds($0.end) ?? 0) - (srtTimeToSeconds($0.start) ?? 0) }.max() ?? 0
        }
        XCTAssertLessThan(maxDuration(lyrics), maxDuration(speech), "lyrics profile should cap cues shorter than speech")
    }

    func testJapaneseLyricsRetimerKeepsRawOnsetToAvoidLateSongCaptions() throws {
        let transcript = ASRTranscript(
            id: "song",
            languageCode: "ja",
            durationSeconds: 5.0,
            words: [
                ASRWord(text: "青い", startSeconds: 1.0, endSeconds: 1.55),
                ASRWord(text: "世界", startSeconds: 1.7, endSeconds: 2.2)
            ],
            sourceModelID: "whisper.cpp:test"
        )
        let speech = ASRTranscriptMapper.sourceCues(from: transcript, profile: .speech)
        let japaneseLyrics = ASRTranscriptMapper.sourceCues(from: transcript, profile: .japaneseLyrics)
        let speechStart = try XCTUnwrap(srtTimeToSeconds(speech[0].start))
        let lyricsStart = try XCTUnwrap(srtTimeToSeconds(japaneseLyrics[0].start))
        XCTAssertEqual(speechStart, 1.0 + WhisperCueRetimer.onsetDelaySeconds, accuracy: 0.0015)
        XCTAssertEqual(lyricsStart, 1.0, accuracy: 0.0015)
    }

    func testLyricsAcousticGuardClampsIntroOutOfLeadingSilence() throws {
        let transcript = ASRTranscript(
            id: "gunjou-intro",
            languageCode: "ja",
            durationSeconds: 8.0,
            words: [
                ASRWord(text: "あ", startSeconds: 0.0, endSeconds: 0.63, probability: 0.14),
                ASRWord(text: "いつ", startSeconds: 0.63, endSeconds: 1.89, probability: 0.67),
                ASRWord(text: "もの", startSeconds: 2.60, endSeconds: 3.15, probability: 0.99),
                ASRWord(text: "ように", startSeconds: 3.15, endSeconds: 5.04, probability: 0.96)
            ],
            sourceModelID: "whisper.cpp:test"
        )
        let activity = ASRAudioActivity(silenceRanges: [
            ASRAudioActivityRange(startSeconds: 0.0, endSeconds: 2.51)
        ])

        let guarded = ASRTranscriptMapper.sourceCues(
            from: transcript,
            profile: .japaneseLyrics,
            audioActivity: activity
        )
        let unguarded = ASRTranscriptMapper.sourceCues(from: transcript, profile: .japaneseLyrics)

        let guardedStart = try XCTUnwrap(srtTimeToSeconds(guarded[0].start))
        let unguardedStart = try XCTUnwrap(srtTimeToSeconds(unguarded[0].start))
        XCTAssertGreaterThanOrEqual(guardedStart, 2.51, "lyrics must not appear inside a leading silent prelude")
        XCTAssertEqual(unguardedStart, 0.0, accuracy: 0.0015, "missing audio activity must preserve current timing")
    }

    func testAudioActivityParsesFfmpegSilencedetectOutput() {
        let activity = ASRAudioActivity.parseSilencedetectOutput("""
        [Parsed_silencedetect_0 @ 0x843041140] silence_start: 0.001
        [Parsed_silencedetect_0 @ 0x843041140] silence_end: 2.513313 | silence_duration: 2.512312
        [Parsed_silencedetect_0 @ 0x843041140] silence_start: 42.7
        [Parsed_silencedetect_0 @ 0x843041140] silence_end: 44.01 | silence_duration: 1.31
        """)

        XCTAssertEqual(activity.silenceRanges.count, 2)
        XCTAssertEqual(activity.silenceRanges[0].startSeconds, 0.001, accuracy: 0.000_001)
        XCTAssertEqual(activity.silenceRanges[0].endSeconds, 2.513_313, accuracy: 0.000_001)
        XCTAssertEqual(activity.silenceRanges[1].startSeconds, 42.7, accuracy: 0.000_001)
        XCTAssertEqual(activity.silenceRanges[1].endSeconds, 44.01, accuracy: 0.000_001)
    }

    func testJapaneseLyricsDoesNotStartLineWithBareNaTail() {
        let words = [
            ASRWord(text: "降る", startSeconds: 0.0, endSeconds: 0.6),
            ASRWord(text: "どこか", startSeconds: 0.8, endSeconds: 1.4),
            ASRWord(text: "虚しい", startSeconds: 1.6, endSeconds: 2.4),
            ASRWord(text: "よう", startSeconds: 2.6, endSeconds: 3.4),
            ASRWord(text: "なそんな", startSeconds: 3.5, endSeconds: 4.9),
            ASRWord(text: "気持ち", startSeconds: 5.1, endSeconds: 5.9)
        ]
        let transcript = ASRTranscript(id: "song", languageCode: "ja", words: words, sourceModelID: "whisper.cpp:test")
        let cues = ASRTranscriptMapper.sourceCues(from: transcript, profile: .japaneseLyrics)
        let joined = cues.map(\.text).joined(separator: " / ")
        XCTAssertFalse(cues.contains { $0.text.hasPrefix("な") }, joined)
        XCTAssertTrue(cues.contains { $0.text.contains("ような") }, joined)
    }

    func testJapaneseLyricsRebalancesNaTailBeforeSonnaPhrase() {
        let words = [
            ASRWord(text: "谷", startSeconds: 13.29, endSeconds: 13.68),
            ASRWord(text: "の", startSeconds: 13.68, endSeconds: 14.07),
            ASRWord(text: "街", startSeconds: 14.07, endSeconds: 14.46),
            ASRWord(text: "に", startSeconds: 14.46, endSeconds: 14.85),
            ASRWord(text: "朝", startSeconds: 14.85, endSeconds: 15.24),
            ASRWord(text: "が", startSeconds: 15.24, endSeconds: 15.63),
            ASRWord(text: "降", startSeconds: 15.63, endSeconds: 16.02),
            ASRWord(text: "る", startSeconds: 16.02, endSeconds: 16.44),
            ASRWord(text: "ど", startSeconds: 16.44, endSeconds: 16.77),
            ASRWord(text: "こ", startSeconds: 16.77, endSeconds: 17.1),
            ASRWord(text: "か", startSeconds: 17.1, endSeconds: 17.43),
            ASRWord(text: "虚", startSeconds: 17.43, endSeconds: 17.76),
            ASRWord(text: "しい", startSeconds: 17.76, endSeconds: 18.43),
            ASRWord(text: "よう", startSeconds: 18.94, endSeconds: 19.1),
            ASRWord(text: "な", startSeconds: 19.1, endSeconds: 19.3),
            ASRWord(text: "そんな", startSeconds: 19.52, endSeconds: 20.43),
            ASRWord(text: "気", startSeconds: 20.43, endSeconds: 20.76),
            ASRWord(text: "持", startSeconds: 20.76, endSeconds: 21.09),
            ASRWord(text: "ち", startSeconds: 21.09, endSeconds: 21.48),
            ASRWord(text: "つ", startSeconds: 21.48, endSeconds: 21.72),
            ASRWord(text: "ま", startSeconds: 21.72, endSeconds: 21.92),
            ASRWord(text: "ら", startSeconds: 21.99, endSeconds: 22.2),
            ASRWord(text: "ない", startSeconds: 22.2, endSeconds: 22.69),
            ASRWord(text: "な", startSeconds: 22.69, endSeconds: 22.96),
            ASRWord(text: "でも", startSeconds: 22.96, endSeconds: 23.5)
        ]
        let transcript = ASRTranscript(id: "song-na-sonna", languageCode: "ja", words: words, sourceModelID: "whisper.cpp:test")
        let cues = ASRTranscriptMapper.sourceCues(from: transcript, profile: .japaneseLyrics)
        let joined = cues.map(\.text).joined(separator: " / ")

        XCTAssertFalse(cues.contains { $0.text.hasPrefix("なそんな") }, joined)
        XCTAssertTrue(cues.contains { $0.text.contains("虚しいような") }, joined)
        XCTAssertTrue(cues.contains { $0.text.hasPrefix("そんな気持ち") }, joined)
    }

    func testBreathGapBreaksLongRunAtSilence() throws {
        // Use the planner directly so we can place a breath gap exactly at a soft-ceiling junction.
        // Without the gap the junction would extend to the hard ceiling (kept whole); with a real
        // breath gap there, the planner breaks at the silence (stable-ts breath anchor).
        func firstCueText(gapAtJunction: Bool) -> String {
            var frags: [SubtitleCueSourceFragment] = []
            var t = 0.0
            // One continuous kana run: every internal junction is mid-word, so without a gap the
            // planner extends past the 4.5s soft ceiling to the 5.5s hard ceiling. 0.4s/frag means
            // the soft ceiling is first crossed adding the 12th fragment — place the gap right there.
            for i in 0..<20 {
                if gapAtJunction, i == 11 { t += 0.5 } // breath gap exactly as soft ceiling is crossed
                frags.append(SubtitleCueSourceFragment(startSeconds: t, endSeconds: t + 0.4, text: "あ"))
                t += 0.4
            }
            return LocalASRSubtitleTimingPlanner.planCues(from: frags, transcriptDurationSeconds: nil, profile: .speech)
                .first?.text ?? ""
        }
        let withGap = firstCueText(gapAtJunction: true)
        let noGap = firstCueText(gapAtJunction: false)
        XCTAssertFalse(withGap.isEmpty)
        XCTAssertFalse(noGap.isEmpty)
        XCTAssertLessThan(withGap.count, noGap.count, "breath gap should anchor the first break earlier than the hard-ceiling break")
    }

    func testLyricsProfileCapsResidualStandaloneCue() throws {
        // A lone short kana cue that whisper stretches, isolated by large gaps so it stays standalone
        // (not merged): speech may hold up to the 2.4s standalone cap; lyrics keeps it near
        // the profile readability floor (0.9s) so it cannot linger or flash too quickly.
        let words = [
            ASRWord(text: "うた。", startSeconds: 0.0, endSeconds: 1.0),
            ASRWord(text: "ね", startSeconds: 10.0, endSeconds: 15.0),
            ASRWord(text: "そら。", startSeconds: 30.0, endSeconds: 31.0)
        ]
        let transcript = ASRTranscript(id: "r", languageCode: "ja", words: words, sourceModelID: "whisper.cpp:test")
        let speech = ASRTranscriptMapper.sourceCues(from: transcript, profile: .speech)
        let lyrics = ASRTranscriptMapper.sourceCues(from: transcript, profile: .lyrics)
        func standaloneDuration(_ cues: [SubtitleCue]) throws -> Double? {
            for cue in cues where cue.text == "ね" {
                let start = try XCTUnwrap(srtTimeToSeconds(cue.start))
                let end = try XCTUnwrap(srtTimeToSeconds(cue.end))
                return end - start
            }
            return nil
        }
        let speechDur = try XCTUnwrap(try standaloneDuration(speech))
        let lyricsDur = try XCTUnwrap(try standaloneDuration(lyrics))
        XCTAssertLessThanOrEqual(lyricsDur, 0.9 + 0.001, "residual cue must be capped under lyrics profile")
        XCTAssertGreaterThan(speechDur, lyricsDur, "speech profile allows a longer standalone hold than lyrics")
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
            "今日は、いい天気ですね。はい、そうです。; title=Moon Gate Clip; language=ja"
        )
        XCTAssertEqual(
            ASRPromptBuilder.defaultPrompt(videoURL: video, languageCode: " ko "),
            "안녕하세요. 오늘은 날씨가 좋네요. 네, 맞습니다.; title=Moon Gate Clip; language=ko"
        )
        XCTAssertEqual(
            ASRPromptBuilder.defaultPrompt(videoURL: video, languageCode: " auto "),
            "title=Moon Gate Clip"
        )
        XCTAssertEqual(
            ASRPromptBuilder.defaultPrompt(videoURL: video, languageCode: " AUTO "),
            "title=Moon Gate Clip"
        )
        // Latin languages keep the metadata-only prompt (no CJK exemplar).
        XCTAssertEqual(
            ASRPromptBuilder.defaultPrompt(videoURL: video, languageCode: "en"),
            "title=Moon Gate Clip; language=en"
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

    func testLocalASRTimingPlannerSuppressesRepeatedJapaneseLoopHallucinations() throws {
        var words: [ASRWord] = [
            ASRWord(text: "おはよう", startSeconds: 160.0, endSeconds: 160.6)
        ]
        let loopTokens = ["き", "ょ", "う", "も", "、", "は", "な", "ま", "る"]
        for repeatIndex in 0..<12 {
            let base = 162.0 + Double(repeatIndex) * 0.02
            for (tokenIndex, token) in loopTokens.enumerated() {
                let start = base + Double(tokenIndex) * 0.01
                words.append(ASRWord(
                    text: token,
                    startSeconds: start,
                    endSeconds: start + (token == "、" ? 0.01 : 0.05)
                ))
            }
        }
        words.append(ASRWord(text: "またね", startSeconds: 180.0, endSeconds: 180.8))
        let transcript = ASRTranscript(
            id: "japanese-loop-hallucination",
            languageCode: "ja",
            words: words,
            sourceModelID: "whisper.cpp:test"
        )

        let cues = ASRTranscriptMapper.sourceCues(from: transcript)
        let joined = cues.map(\.text).joined(separator: " ")
        let loopCount = joined.components(separatedBy: "きょうもはなまる").count - 1

        XCTAssertTrue(joined.contains("おはよう"))
        XCTAssertTrue(joined.contains("またね"))
        XCTAssertFalse(joined.contains("きうも"), "small kana inside a real syllable must not be dropped")
        XCTAssertLessThanOrEqual(loopCount, 1, "runaway repeated Japanese loop should be fused after one readable repeat")
        for cue in cues {
            let start = try XCTUnwrap(srtTimeToSeconds(cue.start))
            let end = try XCTUnwrap(srtTimeToSeconds(cue.end))
            XCTAssertGreaterThan(end, start, "local ASR cues must never serialize as zero-duration SRT entries")
        }
    }

    func testLocalASRTimingPlannerSuppressesMixedScriptJapaneseLoopHallucinations() {
        var words: [ASRWord] = [
            ASRWord(text: "おはよう", startSeconds: 178.0, endSeconds: 178.6)
        ]
        let loopTokens = ["今日", "も", "花丸", "スタンプ"]
        for repeatIndex in 0..<10 {
            let base = 181.0 + Double(repeatIndex) * 0.04
            for (tokenIndex, token) in loopTokens.enumerated() {
                let start = base + Double(tokenIndex) * 0.01
                words.append(ASRWord(text: token, startSeconds: start, endSeconds: start + 0.05))
            }
        }
        words.append(ASRWord(text: "またね", startSeconds: 205.0, endSeconds: 205.7))
        let transcript = ASRTranscript(
            id: "mixed-script-japanese-loop",
            languageCode: "ja",
            words: words,
            sourceModelID: "whisper.cpp:test"
        )

        let joined = ASRTranscriptMapper.sourceCues(from: transcript).map(\.text).joined(separator: " ")
        let loopCount = joined.components(separatedBy: "今日も花丸スタンプ").count - 1

        XCTAssertTrue(joined.contains("おはよう"))
        XCTAssertTrue(joined.contains("またね"))
        XCTAssertLessThanOrEqual(loopCount, 1, "mixed kanji/kana/katakana hallucination loop should be fused")
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

    func testLocalASRTimingPlannerKeepsSpacesBetweenEnglishPronounPhrases() {
        let transcript = ASRTranscript(
            id: "english-pronoun-spacing",
            languageCode: "en",
            words: [
                ASRWord(text: "I", startSeconds: 0.0, endSeconds: 0.1),
                ASRWord(text: "have", startSeconds: 0.1, endSeconds: 0.35),
                ASRWord(text: "ideas.", startSeconds: 0.35, endSeconds: 0.6),
                ASRWord(text: "I", startSeconds: 0.7, endSeconds: 0.8),
                ASRWord(text: "find", startSeconds: 0.8, endSeconds: 1.05),
                ASRWord(text: "patterns.", startSeconds: 1.05, endSeconds: 1.35),
                ASRWord(text: "I", startSeconds: 1.45, endSeconds: 1.55),
                ASRWord(text: "think", startSeconds: 1.55, endSeconds: 1.8),
                ASRWord(text: "fast.", startSeconds: 1.8, endSeconds: 2.05),
                ASRWord(text: "Am", startSeconds: 2.15, endSeconds: 2.35),
                ASRWord(text: "I", startSeconds: 2.35, endSeconds: 2.45),
                ASRWord(text: "right?", startSeconds: 2.45, endSeconds: 2.8),
                ASRWord(text: "I", startSeconds: 2.9, endSeconds: 3.0),
                ASRWord(text: "'m", startSeconds: 3.0, endSeconds: 3.12),
                ASRWord(text: "ready.", startSeconds: 3.12, endSeconds: 3.4)
            ],
            sourceModelID: "whisper.cpp:test"
        )

        let text = ASRTranscriptMapper.sourceCues(from: transcript).map(\.text).joined(separator: " ")

        XCTAssertTrue(text.contains("I have"))
        XCTAssertTrue(text.contains("I find"))
        XCTAssertTrue(text.contains("I think"))
        XCTAssertTrue(text.contains("Am I right?"))
        XCTAssertTrue(text.contains("I'm ready."))
        XCTAssertFalse(text.contains("Ihave"))
        XCTAssertFalse(text.contains("Ifind"))
        XCTAssertFalse(text.contains("Ithink"))
        XCTAssertFalse(text.contains("Iright"))
        XCTAssertFalse(text.contains("I 'm"))
    }

    func testLocalASRTimingPlannerKeepsSpacesAroundLatinRunsInsideCJK() {
        let transcript = ASRTranscript(
            id: "cjk-latin",
            languageCode: "zh",
            words: [
                ASRWord(text: "說", startSeconds: 0.0, endSeconds: 0.2),
                ASRWord(text: "法", startSeconds: 0.2, endSeconds: 0.4),
                ASRWord(text: "I", startSeconds: 0.4, endSeconds: 0.55),
                ASRWord(text: "'m", startSeconds: 0.55, endSeconds: 0.7),
                ASRWord(text: "actually", startSeconds: 0.7, endSeconds: 1.0),
                ASRWord(text: "a", startSeconds: 1.0, endSeconds: 1.1),
                ASRWord(text: "lingu", startSeconds: 1.1, endSeconds: 1.35),
                ASRWord(text: "ist", startSeconds: 1.35, endSeconds: 1.5),
                ASRWord(text: "這是", startSeconds: 1.5, endSeconds: 1.9)
            ],
            sourceModelID: "whisper.cpp:test"
        )

        let text = ASRTranscriptMapper.sourceCues(from: transcript).map(\.text).joined(separator: " ")

        XCTAssertTrue(text.contains("說法 I'm actually a linguist"))
        XCTAssertFalse(text.contains("I 'm"))
        XCTAssertFalse(text.contains("I'mactually"))
        XCTAssertFalse(text.contains("lingu ist"))
    }

    func testLocalASRTimingPlannerRejoinsMainstreamLatinSubwordFragments() {
        let transcript = ASRTranscript(
            id: "latin-subwords",
            languageCode: "zh",
            words: [
                ASRWord(text: "混合", startSeconds: 0.0, endSeconds: 0.15),
                ASRWord(text: "de", startSeconds: 0.15, endSeconds: 0.30),
                ASRWord(text: "esper", startSeconds: 0.30, endSeconds: 0.50),
                ASRWord(text: "ança", startSeconds: 0.50, endSeconds: 0.70),
                ASRWord(text: "At", startSeconds: 0.70, endSeconds: 0.85),
                ASRWord(text: "ual", startSeconds: 0.85, endSeconds: 1.00),
                ASRWord(text: "mente", startSeconds: 1.00, endSeconds: 1.30),
                ASRWord(text: "yo", startSeconds: 1.30, endSeconds: 1.50),
                ASRWord(text: "siempre", startSeconds: 1.50, endSeconds: 1.90)
            ],
            sourceModelID: "whisper.cpp:test"
        )

        let text = ASRTranscriptMapper.sourceCues(from: transcript).map(\.text).joined(separator: " ")

        XCTAssertTrue(text.contains("de esperança"))
        XCTAssertTrue(text.contains("yo siempre"))
        XCTAssertFalse(text.contains("esper ança"))
        XCTAssertFalse(text.contains("yosiempre"))
    }

    func testLocalASRTimingPlannerRejoinsLatinFragmentsInSourceLanguages() {
        let transcript = ASRTranscript(
            id: "latin-source-subwords",
            languageCode: "pt",
            words: [
                ASRWord(text: "Quando", startSeconds: 0.0, endSeconds: 0.2),
                ASRWord(text: "a", startSeconds: 0.2, endSeconds: 0.3),
                ASRWord(text: "pal", startSeconds: 0.3, endSeconds: 0.45),
                ASRWord(text: "estra", startSeconds: 0.45, endSeconds: 0.7),
                ASRWord(text: "não", startSeconds: 0.7, endSeconds: 0.9),
                ASRWord(text: "é", startSeconds: 0.9, endSeconds: 1.0),
                ASRWord(text: "d", startSeconds: 1.0, endSeconds: 1.1),
                ASRWord(text: "ada", startSeconds: 1.1, endSeconds: 1.25),
                ASRWord(text: "em", startSeconds: 1.25, endSeconds: 1.35),
                ASRWord(text: "ingl", startSeconds: 1.35, endSeconds: 1.55),
                ASRWord(text: "ês", startSeconds: 1.55, endSeconds: 1.75),
                ASRWord(text: "Sand", startSeconds: 1.75, endSeconds: 1.95),
                ASRWord(text: "wich", startSeconds: 1.95, endSeconds: 2.10),
                ASRWord(text: "Ker", startSeconds: 2.10, endSeconds: 2.25),
                ASRWord(text: "ne", startSeconds: 2.25, endSeconds: 2.40),
                ASRWord(text: "vou", startSeconds: 2.40, endSeconds: 2.55),
                ASRWord(text: "la", startSeconds: 2.55, endSeconds: 2.70),
                ASRWord(text: "ient", startSeconds: 2.70, endSeconds: 2.90)
            ],
            sourceModelID: "whisper.cpp:test"
        )

        let text = ASRTranscriptMapper.sourceCues(from: transcript).map(\.text).joined(separator: " ")

        XCTAssertTrue(text.contains("palestra"))
        XCTAssertTrue(text.contains("dada"))
        XCTAssertTrue(text.contains("inglês"))
        XCTAssertTrue(text.contains("Sandwich"))
        XCTAssertTrue(text.contains("Kerne"))
        XCTAssertTrue(text.contains("voulaient"))
        XCTAssertTrue(text.contains("a palestra"))
        XCTAssertFalse(text.contains("pal estra"))
        XCTAssertFalse(text.contains("d ada"))
        XCTAssertFalse(text.contains("ingl ês"))
        XCTAssertFalse(text.contains("Sand wich"))
        XCTAssertFalse(text.contains("Ker ne"))
        XCTAssertFalse(text.contains("vou la"))
        XCTAssertFalse(text.contains("apalestra"))
    }

    func testLocalASRTimingPlannerRejoinsItalianGermanFrenchSubwords() {
        // M4: università (ità), abandonné (né), gemütlich (lich) — Whisper sub-word splits in
        // it/de/fr must rejoin, not leave 「univers ità」/「abandon né」/「gemüt lich」.
        let transcript = ASRTranscript(
            id: "itdefr-subwords",
            languageCode: "it",
            words: [
                ASRWord(text: "la", startSeconds: 0.0, endSeconds: 0.15),
                ASRWord(text: "univers", startSeconds: 0.15, endSeconds: 0.45),
                ASRWord(text: "ità", startSeconds: 0.45, endSeconds: 0.7),
                ASRWord(text: "è", startSeconds: 0.7, endSeconds: 0.8),
                ASRWord(text: "abandon", startSeconds: 0.8, endSeconds: 1.1),
                ASRWord(text: "né", startSeconds: 1.1, endSeconds: 1.3),
                ASRWord(text: "und", startSeconds: 1.3, endSeconds: 1.45),
                ASRWord(text: "gemüt", startSeconds: 1.45, endSeconds: 1.7),
                ASRWord(text: "lich", startSeconds: 1.7, endSeconds: 1.95)
            ],
            sourceModelID: "whisper.cpp:test"
        )
        let text = ASRTranscriptMapper.sourceCues(from: transcript).map(\.text).joined(separator: " ")
        XCTAssertTrue(text.contains("università"), text)
        XCTAssertTrue(text.contains("abandonné"), text)
        XCTAssertTrue(text.contains("gemütlich"), text)
        XCTAssertFalse(text.contains("univers ità"))
        XCTAssertFalse(text.contains("abandon né"))
        XCTAssertFalse(text.contains("gemüt lich"))
    }

    func testKoreanParticleNeverStartsLine() {
        // M4: a bare josa/eomi must never begin a line; it stays attached to the preceding eojeol.
        let transcript = ASRTranscript(
            id: "ko-particle",
            languageCode: "ko",
            words: [
                ASRWord(text: "학교", startSeconds: 0.0, endSeconds: 0.5),
                ASRWord(text: "에서", startSeconds: 0.52, endSeconds: 0.8),
                ASRWord(text: "공부", startSeconds: 0.82, endSeconds: 1.2),
                ASRWord(text: "를", startSeconds: 1.22, endSeconds: 1.4),
                ASRWord(text: "합니다", startSeconds: 1.42, endSeconds: 2.0)
            ],
            sourceModelID: "whisper.cpp:test"
        )
        let cues = ASRTranscriptMapper.sourceCues(from: transcript)
        for cue in cues {
            let trimmed = cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertFalse(trimmed.hasPrefix("에서"), "line must not start with a bare josa: \(trimmed)")
            XCTAssertFalse(trimmed.hasPrefix("를"), "line must not start with a bare josa: \(trimmed)")
        }
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

    func testLocalASRTimingPlannerAbsorbsJapaneseOrphanFragmentsAcrossSoftCaps() {
        let transcript = ASRTranscript(
            id: "japanese-orphans",
            languageCode: "ja",
            words: [
                ASRWord(text: "一緒にい", startSeconds: 0.0, endSeconds: 0.48),
                ASRWord(text: "こう", startSeconds: 0.76, endSeconds: 5.72),
                ASRWord(text: "見て朝の花丸スタンプカ", startSeconds: 8.0, endSeconds: 12.8),
                ASRWord(text: "ード", startSeconds: 13.08, endSeconds: 14.2),
                ASRWord(text: "僕が", startSeconds: 14.48, endSeconds: 15.0),
                ASRWord(text: "顔", startSeconds: 20.0, endSeconds: 24.1),
                ASRWord(text: "洗って偉い", startSeconds: 24.38, endSeconds: 26.1),
                ASRWord(text: "コウペンちゃ", startSeconds: 30.0, endSeconds: 31.46),
                ASRWord(text: "う", startSeconds: 31.74, endSeconds: 35.9)
            ],
            sourceModelID: "whisper.cpp:test"
        )

        let texts = ASRTranscriptMapper.sourceCues(from: transcript).map(\.text)

        XCTAssertFalse(texts.contains("こう"), "「こう」 must not stand alone after 「一緒にい」")
        XCTAssertTrue(texts.contains { $0.contains("一緒にいこう") })
        XCTAssertFalse(texts.contains { $0.hasPrefix("ード") }, "片仮名の後半だけで cue を始めない")
        XCTAssertTrue(texts.contains { $0.contains("スタンプカード") })
        XCTAssertFalse(texts.contains("顔"), "「顔」 must be attached to the following action phrase")
        XCTAssertTrue(texts.contains { $0.contains("顔洗って") })
        XCTAssertFalse(texts.contains("う"), "Koupen-chan tail fragment must not stand alone")
        XCTAssertTrue(texts.contains { $0.contains("コウペンちゃう") })
    }

    func testLocalASRTimingPlannerAvoidsLeadingJapaneseContinuationAfterHardCap() {
        let transcript = ASRTranscript(
            id: "japanese-continuation-hard-cap",
            languageCode: "ja",
            words: [
                ASRWord(text: "好きなものを", startSeconds: 0.0, endSeconds: 1.6),
                ASRWord(text: "好きだと", startSeconds: 1.6, endSeconds: 3.0),
                ASRWord(text: "言うのが怖く", startSeconds: 3.0, endSeconds: 5.4),
                ASRWord(text: "て", startSeconds: 5.4, endSeconds: 5.8),
                ASRWord(text: "仕方ない", startSeconds: 5.8, endSeconds: 6.2)
            ],
            sourceModelID: "whisper.cpp:test"
        )

        let texts = ASRTranscriptMapper.sourceCues(from: transcript).map(\.text)

        XCTAssertFalse(texts.contains { $0.hasPrefix("て") }, "接続助詞「て」は前の形容詞尾に貼り戻す")
        XCTAssertTrue(texts.contains { $0.contains("怖くて仕方ない") })
    }

    func testLocalASRTimingPlannerDropsOrShortensJapaneseResidualFragments() throws {
        let transcript = ASRTranscript(
            id: "japanese-residuals",
            languageCode: "ja",
            words: [
                ASRWord(text: "一緒にいようねさ", startSeconds: 0.0, endSeconds: 2.1),
                ASRWord(text: "っ", startSeconds: 2.38, endSeconds: 7.2),
                ASRWord(text: "ー", startSeconds: 8.0, endSeconds: 13.2),
                ASRWord(text: "ぁ", startSeconds: 13.5, endSeconds: 16.9),
                ASRWord(text: "おはよう", startSeconds: 20.0, endSeconds: 21.0)
            ],
            sourceModelID: "whisper.cpp:test"
        )

        let cues = ASRTranscriptMapper.sourceCues(from: transcript)

        XCTAssertFalse(cues.contains { ["っ", "ー", "ぁ"].contains($0.text) })
        for cue in cues where SubtitleTimingPlanner.visibleCharacters(cue.text) <= 2 {
            let start = try XCTUnwrap(srtTimeToSeconds(cue.start))
            let end = try XCTUnwrap(srtTimeToSeconds(cue.end))
            XCTAssertLessThan(end - start, 3.0, "short residual-like cue held too long: \(cue.text)")
        }
    }

    func testLocalASRTimingPlannerDoesNotCapBeforeLastCJKWordEnds() throws {
        let transcript = ASRTranscript(
            id: "cjk-last-word",
            languageCode: "zh",
            words: [
                ASRWord(text: "早上来这里菜市场", startSeconds: 0.0, endSeconds: 6.0)
            ],
            sourceModelID: "whisper.cpp:test"
        )

        let cue = try XCTUnwrap(ASRTranscriptMapper.sourceCues(from: transcript).first)
        let end = try XCTUnwrap(srtTimeToSeconds(cue.end))

        XCTAssertGreaterThanOrEqual(end, 6.0)
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

    func testWhisperCueRetimerShortensHoldForMixedCJKLatinRuns() throws {
        let mixed = WhisperCueRetimer.retime(
            [
                retimerCue(10.0, 11.2, "說法I'mactuallyalinguist", lastTokenEnd: 11.0),
                retimerCue(13.0, 13.6, "下一句", lastTokenEnd: 13.5)
            ],
            transcriptDurationSeconds: nil
        )
        let mixedEnd = try XCTUnwrap(srtTimeToSeconds(mixed[0].end))
        XCTAssertEqual(mixedEnd, 11.0 + WhisperCueRetimer.mixedCJKLatinHoldToNextSeconds, accuracy: 0.0015)

        let plainCJK = WhisperCueRetimer.retime(
            [
                retimerCue(20.0, 21.2, "真正身份是一位語言學家", lastTokenEnd: 21.0),
                retimerCue(23.0, 23.6, "下一句", lastTokenEnd: 23.5)
            ],
            transcriptDurationSeconds: nil
        )
        let plainEnd = try XCTUnwrap(srtTimeToSeconds(plainCJK[0].end))
        XCTAssertEqual(plainEnd, 21.0 + WhisperCueRetimer.holdToNextSeconds, accuracy: 0.0015)
    }

    func testLyricsAndAnimeRetimerAvoidsFlashDurationWhenGapAllows() throws {
        let raw = retimerCue(4.0, 4.1, "梅だ", lastTokenEnd: 4.1)
        let speech = WhisperCueRetimer.retime([raw], transcriptDurationSeconds: 10.0, profile: .speech)
        let anime = WhisperCueRetimer.retime([raw], transcriptDurationSeconds: 10.0, profile: .anime)
        let lyrics = WhisperCueRetimer.retime([raw], transcriptDurationSeconds: 10.0, profile: .japaneseLyrics)

        func duration(_ cue: SubtitleCue) throws -> Double {
            let start = try XCTUnwrap(srtTimeToSeconds(cue.start))
            let end = try XCTUnwrap(srtTimeToSeconds(cue.end))
            return end - start
        }

        XCTAssertGreaterThanOrEqual(try duration(speech[0]), LocalASRSubtitleTimingPlanner.minimumCueSeconds)
        XCTAssertGreaterThanOrEqual(try duration(anime[0]), 0.9 - 0.0015)
        XCTAssertGreaterThanOrEqual(try duration(lyrics[0]), 0.9 - 0.0015)
    }

    func testWhisperCueRetimerRespectsDurationCapAndTranscriptLength() throws {
        // A long CJK cue may exceed the hard cap to avoid cutting off the last real word,
        // but it must still stay within the relaxed CJK cap.
        let longCJK = WhisperCueRetimer.retime([retimerCue(10.0, 30.0, "字幕字幕字幕字幕")], transcriptDurationSeconds: nil)
        let start = try XCTUnwrap(srtTimeToSeconds(longCJK[0].start))
        let end = try XCTUnwrap(srtTimeToSeconds(longCJK[0].end))
        XCTAssertLessThanOrEqual(end - start, LocalASRSubtitleTimingPlanner.relaxedCJKCueSeconds + 0.0015)

        // Transcript duration is a hard end ceiling.
        let clamped = WhisperCueRetimer.retime([retimerCue(8.0, 20.0, "字幕")], transcriptDurationSeconds: 11.0)
        let clampedEnd = try XCTUnwrap(srtTimeToSeconds(clamped[0].end))
        XCTAssertLessThanOrEqual(clampedEnd, 11.0 + 0.0015)

        // BUG-4: a final cue whose onset sits within minimumCueSeconds of the audio end must not be
        // pushed past the transcript duration by the minimum-readable-duration floor.
        let nearEnd = WhisperCueRetimer.retime([retimerCue(10.8, 10.9, "字幕")], transcriptDurationSeconds: 11.0)
        let nearEndStop = try XCTUnwrap(srtTimeToSeconds(nearEnd[0].end))
        XCTAssertLessThanOrEqual(nearEndStop, 11.0 + 0.0015)
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
