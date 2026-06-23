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

    func testPunctuationOnlyTranslationFallsBackToSourceWithoutFailingWholeTranslation() async throws {
        let source = try writeSRT("punctuation.en.srt", [
            SubtitleCue(index: 1, start: "00:00:01,000", end: "00:00:02,000", text: "."),
            SubtitleCue(index: 2, start: "00:00:03,000", end: "00:00:04,000", text: "Ignition.")
        ])
        let translator = ConfiguredTranslator(
            settings: cloudSettings(),
            appleTranslationExecutor: DefaultAppleTranslationExecutor(),
            modelSender: { _, _, _, _, _ in
                ModelReply(text: "1|。\n2|点火", reachedOutputLimit: false)
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
        XCTAssertEqual(result.map(\.text), [".", "点火"])
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

    // MARK: - ASR 重分段

    private func asrCues() -> [SubtitleCue] {
        // 8 条逐字、无标点的碎句（典型 ASR 自动字幕）。
        let words = ["we know it", "what is the vision", "for what you see", "coming next",
                     "we asked ourselves", "how far can it go", "and what comes", "after that"]
        return words.enumerated().map { i, text in
            SubtitleCue(index: i + 1,
                        start: secondsToSRTTime(Double(i)),
                        end: secondsToSRTTime(Double(i + 1)),
                        text: text)
        }
    }

    private func multilineAsrCues() -> [SubtitleCue] {
        (0..<20).map { i in
            SubtitleCue(index: i + 1,
                        start: secondsToSRTTime(Double(i)),
                        end: secondsToSRTTime(Double(i + 1)),
                        text: "word\(i) line\nnext\(i) piece")
        }
    }
    func testResegmentForReadabilityRebuildsSentencesWithAlignedTime() async throws {
        // 模型把碎句断成 2 个完整句子；token 与原文一致 → 重分段成功，时间轴保留。
        let translator = ConfiguredTranslator(
            settings: cloudSettings(),
            appleTranslationExecutor: DefaultAppleTranslationExecutor(),
            modelSender: { _, _, _, _, _ in
                ModelReply(
                    text: "1|we know it what is the vision for what you see coming next.\n2|we asked ourselves how far can it go and what comes after that?",
                    reachedOutputLimit: false)
            }
        )
        let output = try await translator.resegmentForReadability(
            asrCues(), context: TranslationContext(sourceLanguage: "en", targetLanguage: "zh-Hans"))
        XCTAssertEqual(output.count, 2)
        XCTAssertEqual(output[0].start, "00:00:00,000")
        XCTAssertEqual(output[0].text, "we know it what is the vision for what you see coming next.")
        XCTAssertEqual(output.last?.end, "00:00:08,000")
    }

    func testResegmentReturnsOriginalWhenAlignmentFails() async throws {
        // 模型返回完全不同的词 → 对齐失败 → 原样返回输入，绝不产出错位时间轴。
        let input = asrCues()
        let translator = ConfiguredTranslator(
            settings: cloudSettings(),
            appleTranslationExecutor: DefaultAppleTranslationExecutor(),
            modelSender: { _, _, _, _, _ in
                ModelReply(text: "1|completely different words here.", reachedOutputLimit: false)
            }
        )
        let output = try await translator.resegmentForReadability(
            input, context: TranslationContext(sourceLanguage: "en", targetLanguage: "zh-Hans"))
        XCTAssertEqual(output.map(\.text), input.map(\.text))
    }

    func testLooksLikeAutoCaptionHeuristic() {
        XCTAssertTrue(ConfiguredTranslator.looksLikeAutoCaption(asrCues()))
        // 正常字幕：每条都有句末标点 → 不判定为 ASR。
        let normal = (1...8).map {
            SubtitleCue(index: $0, start: secondsToSRTTime(Double($0)),
                        end: secondsToSRTTime(Double($0) + 0.9), text: "This is line \($0).")
        }
        XCTAssertFalse(ConfiguredTranslator.looksLikeAutoCaption(normal))
        // 条数太少 → 不判定。
        XCTAssertFalse(ConfiguredTranslator.looksLikeAutoCaption(Array(asrCues().prefix(3))))
        // 无标点但每条很长（≥6s）→ 更像已成句字幕，不判定。
        let longCues = (0..<8).map {
            SubtitleCue(index: $0 + 1, start: secondsToSRTTime(Double($0) * 8),
                        end: secondsToSRTTime(Double($0) * 8 + 8), text: "some words without period here")
        }
        XCTAssertFalse(ConfiguredTranslator.looksLikeAutoCaption(longCues))
        // 无标点但大量多行排版 → 更像人工字幕，不判定。
        let multiline = (0..<8).map {
            SubtitleCue(index: $0 + 1, start: secondsToSRTTime(Double($0)),
                        end: secondsToSRTTime(Double($0) + 1), text: "first line\nsecond line")
        }
        XCTAssertFalse(ConfiguredTranslator.looksLikeAutoCaption(multiline))
        XCTAssertTrue(ConfiguredTranslator.looksLikeAutoCaption(multilineAsrCues()))
    }

    func testTranslateResegmentsAsrCaptionWhenSmartEnabled() async throws {
        let source = try writeSRT("asr.en.srt", asrCues())
        let didSegment = AttemptCounter()
        var settings = cloudSettings()
        settings.smartTranslationPromptsEnabled = true
        let translator = ConfiguredTranslator(
            settings: settings,
            appleTranslationExecutor: DefaultAppleTranslationExecutor(),
            modelSender: { _, system, userContent, _, _ in
                // 断句请求：返回 2 个完整句子。
                if (system ?? "").contains("待断句文本") {
                    _ = await didSegment.next()
                    return ModelReply(
                        text: "1|we know it what is the vision for what you see coming next.\n2|we asked ourselves how far can it go and what comes after that?",
                        reachedOutputLimit: false)
                }
                // 摘要分析请求（smart）：返回最简 JSON。
                if (system ?? "").contains("字幕内容分析器") {
                    return ModelReply(text: #"{"summary":"测试","preset":"general"}"#, reachedOutputLimit: false)
                }
                return ModelReply(text: translatedLines(from: userContent), reachedOutputLimit: false)
            }
        )
        let output = try await translator.translate(
            srtFile: source, style: .chineseOnly,
            context: TranslationContext(sourceLanguage: "en", targetLanguage: "zh-Hans"),
            control: nil, progress: { _ in })
        let result = parseSRT(try String(contentsOf: output, encoding: .utf8))
        let segmentCalls = await didSegment.value()
        XCTAssertGreaterThan(segmentCalls, 0, "smart 开 + ASR 应触发重分段")
        XCTAssertEqual(result.count, 2, "重分段后应是 2 条整句")
    }

    func testTranslateResegmentsMultilineAsrCaptionWhenSmartEnabled() async throws {
        let input = multilineAsrCues()
        let source = try writeSRT("multiline-asr.en.srt", input)
        let didSegment = AttemptCounter()
        var settings = cloudSettings()
        settings.smartTranslationPromptsEnabled = true
        let translator = ConfiguredTranslator(
            settings: settings,
            appleTranslationExecutor: DefaultAppleTranslationExecutor(),
            modelSender: { _, system, userContent, _, _ in
                if (system ?? "").contains("待断句文本") {
                    _ = await didSegment.next()
                    return ModelReply(text: "1|\(userContent).", reachedOutputLimit: false)
                }
                if (system ?? "").contains("字幕内容分析器") {
                    return ModelReply(text: #"{"summary":"测试","preset":"general"}"#, reachedOutputLimit: false)
                }
                return ModelReply(text: translatedLines(from: userContent), reachedOutputLimit: false)
            }
        )

        let output = try await translator.translate(
            srtFile: source, style: .chineseOnly,
            context: TranslationContext(sourceLanguage: "en", targetLanguage: "zh-Hans"),
            control: nil, progress: { _ in })

        let result = parseSRT(try String(contentsOf: output, encoding: .utf8))
        let segmentCalls = await didSegment.value()
        XCTAssertGreaterThan(segmentCalls, 0)
        XCTAssertLessThan(result.count, input.count)
    }
    func testTranslateSkipsResegmentWhenSmartDisabled() async throws {
        let source = try writeSRT("asr2.en.srt", asrCues())
        let didSegment = AttemptCounter()
        let translator = ConfiguredTranslator(
            settings: cloudSettings(), // smartTranslationPromptsEnabled = false
            appleTranslationExecutor: DefaultAppleTranslationExecutor(),
            modelSender: { _, system, userContent, _, _ in
                if (system ?? "").contains("待断句文本") { _ = await didSegment.next() }
                return ModelReply(text: translatedLines(from: userContent), reachedOutputLimit: false)
            }
        )
        let output = try await translator.translate(
            srtFile: source, style: .chineseOnly,
            context: TranslationContext(sourceLanguage: "en", targetLanguage: "zh-Hans"),
            control: nil, progress: { _ in })
        let result = parseSRT(try String(contentsOf: output, encoding: .utf8))
        let segmentCalls = await didSegment.value()
        XCTAssertEqual(segmentCalls, 0, "smart 关 → 不触发重分段")
        XCTAssertEqual(result.count, cleanCues(asrCues()).count, "smart 关 → 只走普通清洗，不走 LLM 重分段")
    }

    // MARK: - CJK（日文）逐字符重分段

    /// 8 条逐字、无标点的日文碎句（典型 Whisper 输出，含用户报的「顔 / 洗って」割裂例）。
    private func japaneseAsrCues() -> [SubtitleCue] {
        let words = ["おはよう", "起きられて", "えらい", "顔", "洗って", "えらい", "テレビ見るのも", "えらい"]
        return words.enumerated().map { i, text in
            SubtitleCue(index: i + 1,
                        start: secondsToSRTTime(Double(i)),
                        end: secondsToSRTTime(Double(i + 1)),
                        text: text)
        }
    }

    func testResegmentCJKAlignsByCharacterAndRebuildsSentences() async throws {
        // 日文无词间空格：按词对齐必然失败而回退（旧行为）。逐字符对齐后，模型把碎句
        // 断成完整句子且字符序列不变 → 对齐通过 → 合并出句子级字幕，时间轴按字符插值保留。
        let translator = ConfiguredTranslator(
            settings: cloudSettings(),
            appleTranslationExecutor: DefaultAppleTranslationExecutor(),
            modelSender: { _, _, _, _, _ in
                ModelReply(
                    text: "1|おはよう。\n2|起きられてえらい。\n3|顔洗ってえらい。\n4|テレビ見るのもえらい。",
                    reachedOutputLimit: false)
            }
        )
        let output = try await translator.resegmentForReadability(
            japaneseAsrCues(), context: TranslationContext(sourceLanguage: "ja", targetLanguage: "zh-Hans"))
        XCTAssertEqual(output.count, 4, "应合并成 4 条完整句")
        XCTAssertEqual(output[0].start, "00:00:00,000")
        XCTAssertEqual(output[2].text, "顔洗ってえらい。", "「顔」与「洗って」应并入同一句，不再割裂")
        XCTAssertEqual(output.last?.end, "00:00:08,000")
    }

    func testResegmentCJKFallsBackWhenCharactersChanged() async throws {
        // 模型擅自改字（多了「猫」/漏字）→ 字符序列对不上 → 原样返回，绝不产出错位时间轴。
        let input = japaneseAsrCues()
        let translator = ConfiguredTranslator(
            settings: cloudSettings(),
            appleTranslationExecutor: DefaultAppleTranslationExecutor(),
            modelSender: { _, _, _, _, _ in
                ModelReply(text: "1|おはよう猫。\n2|起きられてえらい。", reachedOutputLimit: false)
            }
        )
        let output = try await translator.resegmentForReadability(
            input, context: TranslationContext(sourceLanguage: "ja", targetLanguage: "zh-Hans"))
        XCTAssertEqual(output.map(\.text), input.map(\.text), "对齐失败应原样返回")
    }

    func testTranslateResegmentsLocalASRSourceWithoutSmartAndWritesBack() async throws {
        // 本地 Whisper 源字幕（.local-asr.ja.srt）即使 smart 关闭也应重分段，并把句子级结果写回源文件。
        let source = try writeSRT("clip.local-asr.ja.srt", japaneseAsrCues())
        let settings = cloudSettings()           // smartTranslationPromptsEnabled = false
        let translator = ConfiguredTranslator(
            settings: settings,
            appleTranslationExecutor: DefaultAppleTranslationExecutor(),
            modelSender: { _, system, userContent, _, _ in
                if (system ?? "").contains("待断句文本") {
                    return ModelReply(
                        text: "1|おはよう。\n2|起きられてえらい。\n3|顔洗ってえらい。\n4|テレビ見るのもえらい。",
                        reachedOutputLimit: false)
                }
                return ModelReply(text: translatedLines(from: userContent), reachedOutputLimit: false)
            }
        )
        let output = try await translator.translate(
            srtFile: source, style: .chineseOnly,
            context: TranslationContext(sourceLanguage: "ja", targetLanguage: "zh-Hans"),
            control: nil, progress: { _ in })

        let rewrittenSource = parseSRT(try String(contentsOf: source, encoding: .utf8))
        XCTAssertEqual(rewrittenSource.count, 4, "源 .local-asr.ja.srt 应被写回为 4 条整句")
        XCTAssertEqual(rewrittenSource[2].text, "顔洗ってえらい。")
        let result = parseSRT(try String(contentsOf: output, encoding: .utf8))
        XCTAssertEqual(result.count, 4, "译文应基于句子级源字幕，4 条")
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
