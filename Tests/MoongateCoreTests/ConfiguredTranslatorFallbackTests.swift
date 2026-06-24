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

    private func japaneseLyricsCues() -> [SubtitleCue] {
        let parts = [
            "青い", "世界", "好きなものを", "好きだという", "怖く", "て",
            "仕方ないけど", "本当の自分", "出会えた", "気がしたんだ"
        ]
        return parts.enumerated().map { i, text in
            SubtitleCue(index: i + 1,
                        start: secondsToSRTTime(Double(i) * 2.0),
                        end: secondsToSRTTime(Double(i) * 2.0 + 1.7),
                        text: text)
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

    func testResegmentForReadabilityUsesLyricsPromptForSongPreset() async throws {
        let translator = ConfiguredTranslator(
            settings: cloudSettings(),
            appleTranslationExecutor: DefaultAppleTranslationExecutor(),
            modelSender: { _, system, _, _, _ in
                let system = system ?? ""
                XCTAssertTrue(system.contains("歌词行"))
                XCTAssertTrue(system.contains("乐句"))
                XCTAssertFalse(system.contains("按完整句子重新断行"))
                return ModelReply(
                    text: "1|青い世界\n2|好きなものを好きだという\n3|怖くて仕方ないけど\n4|本当の自分出会えた気がしたんだ",
                    reachedOutputLimit: false
                )
            }
        )

        let output = try await translator.resegmentForReadability(
            japaneseLyricsCues(),
            context: TranslationContext(sourceLanguage: "ja", targetLanguage: "zh-Hans"),
            preset: .songLyrics
        )

        XCTAssertEqual(output.map(\.text), [
            "青い世界",
            "好きなものを好きだという",
            "怖くて仕方ないけど",
            "本当の自分出会えた気がしたんだ"
        ])
    }

    func testResegmentForReadabilityUsesProfileGuidanceForLectureAndShortSocial() async throws {
        let expectations: [(TranslationPromptPreset, [String])] = [
            (.lectureCourse, ["术语边界", "因果", "逻辑"]),
            (.shortSocial, ["节奏", "语义完整", "梗"])
        ]

        for (preset, requiredWords) in expectations {
            let translator = ConfiguredTranslator(
                settings: cloudSettings(),
                appleTranslationExecutor: DefaultAppleTranslationExecutor(),
                modelSender: { _, system, userContent, _, _ in
                    let system = system ?? ""
                    for word in requiredWords {
                        XCTAssertTrue(system.contains(word), "\(preset) missing \(word)")
                    }
                    XCTAssertFalse(system.contains("歌词行"), "\(preset) should not use lyrics segmentation")
                    return ModelReply(text: "1|\(userContent).", reachedOutputLimit: false)
                }
            )

            _ = try await translator.resegmentForReadability(
                [SubtitleCue(index: 1, start: "00:00:00,000", end: "00:00:02,000", text: "this explains the core idea")],
                context: TranslationContext(sourceLanguage: "en", targetLanguage: "zh-Hans"),
                preset: preset
            )
        }
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
                if let system, system.contains("字幕内容规划器") {
                    XCTAssertTrue(system.contains("- songLyrics："))
                    XCTAssertTrue(system.contains("意象"))
                    XCTAssertTrue(system.contains("- lectureCourse："))
                    XCTAssertTrue(system.contains("严肃科普"))
                    XCTAssertTrue(system.contains("- shortSocial："))
                    XCTAssertTrue(system.contains("快节奏"))
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

    func testTranslateUsesSmartSongLyricsAdviceBeforeLocalASRResegment() async throws {
        let source = try writeSRT("clip.local-asr.ja.srt", japaneseLyricsCues())
        let promptFlags = PromptFlags()
        var settings = cloudSettings()
        settings.smartTranslationPromptsEnabled = true
        let translator = ConfiguredTranslator(
            settings: settings,
            appleTranslationExecutor: DefaultAppleTranslationExecutor(),
            modelSender: { _, system, userContent, _, _ in
                let system = system ?? ""
                if system.contains("字幕内容规划器") {
                    return ModelReply(
                        text: #"{"summary":"日语歌曲歌词","context":"MV 演唱内容","preset":"songLyrics"}"#,
                        reachedOutputLimit: false
                    )
                }
                if system.contains("待断句文本") {
                    await promptFlags.markLyricsSegmentPrompt(
                        system.contains("歌词行") && !system.contains("按完整句子重新断行")
                    )
                    return ModelReply(
                        text: "1|青い世界\n2|好きなものを好きだという\n3|怖くて仕方ないけど\n4|本当の自分出会えた気がしたんだ",
                        reachedOutputLimit: false
                    )
                }
                await promptFlags.markLyricsTranslationPrompt(system.contains("中文歌词译本"))
                return ModelReply(text: translatedLines(from: userContent), reachedOutputLimit: false)
            }
        )

        let output = try await translator.translate(
            srtFile: source,
            style: .chineseOnly,
            context: TranslationContext(sourceLanguage: "ja", targetLanguage: "zh-Hans"),
            control: nil,
            progress: { _ in }
        )

        let result = parseSRT(try String(contentsOf: output, encoding: .utf8))
        XCTAssertEqual(result.count, 4)
        let flags = await promptFlags.snapshot()
        XCTAssertTrue(flags.segment, "songLyrics advice 应先于 local-ASR 重分段生效")
        XCTAssertTrue(flags.translation, "同一个 songLyrics advice 应继续用于翻译提示词")
        let rewrittenSource = parseSRT(try String(contentsOf: source, encoding: .utf8))
        XCTAssertEqual(rewrittenSource.map(\.text).prefix(3), [
            "青い世界",
            "好きなものを好きだという",
            "怖くて仕方ないけど"
        ])
    }

    func testTranslateUsesLyricsFallbackForLocalASRMusicFilenameWhenSmartDisabled() async throws {
        let source = try writeSRT("YOASOBI Official Music Video.local-asr.ja.srt", japaneseLyricsCues())
        let promptFlags = PromptFlags()
        let translator = ConfiguredTranslator(
            settings: cloudSettings(),
            appleTranslationExecutor: DefaultAppleTranslationExecutor(),
            modelSender: { _, system, userContent, _, _ in
                let system = system ?? ""
                XCTAssertFalse(system.contains("字幕内容规划器"), "smart 关闭时兜底不应额外请求增强分析")
                if system.contains("待断句文本") {
                    await promptFlags.markLyricsSegmentPrompt(
                        system.contains("歌词行") && !system.contains("按完整句子重新断行")
                    )
                    return ModelReply(
                        text: "1|青い世界\n2|好きなものを好きだという\n3|怖くて仕方ないけど\n4|本当の自分出会えた気がしたんだ",
                        reachedOutputLimit: false
                    )
                }
                await promptFlags.markLyricsTranslationPrompt(system.contains("中文歌词译本"))
                return ModelReply(text: translatedLines(from: userContent), reachedOutputLimit: false)
            }
        )

        let output = try await translator.translate(
            srtFile: source,
            style: .chineseOnly,
            context: TranslationContext(sourceLanguage: "ja", targetLanguage: "zh-Hans"),
            control: nil,
            progress: { _ in }
        )

        let result = parseSRT(try String(contentsOf: output, encoding: .utf8))
        XCTAssertEqual(result.count, 4)
        let flags = await promptFlags.snapshot()
        XCTAssertTrue(flags.segment)
        XCTAssertTrue(flags.translation)
    }

    func testSmartInterviewAdviceOverridesMusicFilenameAndAvoidsLyricsSegmentation() async throws {
        // 文件名像 MV，但第一层规划判定为访谈：必须按访谈处理，不走歌词分段、不套歌词翻译风格。
        let source = try writeSRT("YOASOBI Official Music Video.local-asr.ja.srt", japaneseLyricsCues())
        let promptFlags = PromptFlags()
        var settings = cloudSettings()
        settings.smartTranslationPromptsEnabled = true
        let translator = ConfiguredTranslator(
            settings: settings,
            appleTranslationExecutor: DefaultAppleTranslationExecutor(),
            modelSender: { _, system, userContent, _, _ in
                let system = system ?? ""
                if system.contains("字幕内容规划器") {
                    return ModelReply(
                        text: #"{"summary":"两位音乐人的访谈对话","preset":"interviewConversation","sourceLanguageCode":"ja"}"#,
                        reachedOutputLimit: false
                    )
                }
                if system.contains("待断句文本") {
                    await promptFlags.markLyricsSegmentPrompt(
                        system.contains("歌词行") && !system.contains("按完整句子重新断行")
                    )
                    return ModelReply(
                        text: "1|青い世界\n2|好きなものを好きだという\n3|怖くて仕方ないけど\n4|本当の自分出会えた気がしたんだ",
                        reachedOutputLimit: false
                    )
                }
                await promptFlags.markLyricsTranslationPrompt(system.contains("中文歌词译本"))
                return ModelReply(text: translatedLines(from: userContent), reachedOutputLimit: false)
            }
        )

        _ = try await translator.translate(
            srtFile: source,
            style: .chineseOnly,
            context: TranslationContext(sourceLanguage: "ja", targetLanguage: "zh-Hans"),
            control: nil,
            progress: { _ in }
        )

        let flags = await promptFlags.snapshot()
        XCTAssertFalse(flags.segment, "interview advice 不应触发歌词分段，即便文件名像 MV")
        XCTAssertFalse(flags.translation, "interview advice 不应套用歌词翻译风格")
    }

    func testSmartAnimeAdviceUsesAnimeSegmentationInstruction() async throws {
        // anime advice 应让重分段使用动漫对白断句指令，而不是歌词断句或普通完整句子断句。
        let source = try writeSRT("clip.local-asr.ja.srt", japaneseLyricsCues())
        let promptFlags = PromptFlags()
        var settings = cloudSettings()
        settings.smartTranslationPromptsEnabled = true
        let translator = ConfiguredTranslator(
            settings: settings,
            appleTranslationExecutor: DefaultAppleTranslationExecutor(),
            modelSender: { _, system, userContent, _, _ in
                let system = system ?? ""
                if system.contains("字幕内容规划器") {
                    return ModelReply(
                        text: #"{"summary":"动画对白片段","preset":"anime","sourceLanguageCode":"ja"}"#,
                        reachedOutputLimit: false
                    )
                }
                if system.contains("待断句文本") {
                    await promptFlags.markAnimeSegmentPrompt(system.contains("对白断句助手") && system.contains("台词"))
                    await promptFlags.markLyricsSegmentPrompt(system.contains("歌词行"))
                    return ModelReply(
                        text: "1|青い世界\n2|好きなものを好きだという\n3|怖くて仕方ないけど\n4|本当の自分出会えた気がしたんだ",
                        reachedOutputLimit: false
                    )
                }
                return ModelReply(text: translatedLines(from: userContent), reachedOutputLimit: false)
            }
        )

        _ = try await translator.translate(
            srtFile: source,
            style: .chineseOnly,
            context: TranslationContext(sourceLanguage: "ja", targetLanguage: "zh-Hans"),
            control: nil,
            progress: { _ in }
        )

        let usedAnimeSegmentation = await promptFlags.animeSegmentSnapshot()
        XCTAssertTrue(usedAnimeSegmentation, "anime advice 应使用动漫对白断句指令")
        let flags = await promptFlags.snapshot()
        XCTAssertFalse(flags.segment, "anime 不应使用歌词断句")
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
                if (system ?? "").contains("字幕内容规划器") {
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

    func testResegmentCJKLongSegmentSplitsWithoutRepeatingWholeLine() async throws {
        let parts = ["青い世界", "を見て", "胸の奥", "怖くて", "仕方ない", "けど今日も", "前へ進む"]
        let cues = parts.enumerated().map { i, text in
            SubtitleCue(index: i + 1,
                        start: secondsToSRTTime(Double(i)),
                        end: secondsToSRTTime(Double(i + 1)),
                        text: text)
        }
        let joined = parts.joined()
        let translator = ConfiguredTranslator(
            settings: cloudSettings(),
            appleTranslationExecutor: DefaultAppleTranslationExecutor(),
            modelSender: { _, _, _, _, _ in
                ModelReply(text: "1|\(joined)。", reachedOutputLimit: false)
            }
        )

        let output = try await translator.resegmentForReadability(
            cues,
            context: TranslationContext(sourceLanguage: "ja", targetLanguage: "zh-Hans"),
            preset: .songLyrics
        )

        XCTAssertGreaterThan(output.count, 1, "长 CJK 歌词行应按时间安全拆分")
        XCTAssertEqual(
            output.map(\.text).joined().replacingOccurrences(of: "。", with: ""),
            joined,
            "拆分后的 CJK 文本应首尾相接，而不是每段重复整句"
        )
        XCTAssertEqual(Set(output.map(\.text)).count, output.count, "不能把同一整句重复到多个 cue")
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

private actor PromptFlags {
    private var sawLyricsSegmentPrompt = false
    private var sawLyricsTranslationPrompt = false
    private var sawAnimeSegmentPrompt = false

    func markLyricsSegmentPrompt(_ value: Bool) {
        sawLyricsSegmentPrompt = sawLyricsSegmentPrompt || value
    }

    func markLyricsTranslationPrompt(_ value: Bool) {
        sawLyricsTranslationPrompt = sawLyricsTranslationPrompt || value
    }

    func markAnimeSegmentPrompt(_ value: Bool) {
        sawAnimeSegmentPrompt = sawAnimeSegmentPrompt || value
    }

    func animeSegmentSnapshot() -> Bool {
        sawAnimeSegmentPrompt
    }

    func snapshot() -> (segment: Bool, translation: Bool) {
        (sawLyricsSegmentPrompt, sawLyricsTranslationPrompt)
    }
}
