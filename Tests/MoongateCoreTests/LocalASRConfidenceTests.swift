import XCTest
@testable import MoongateCore

final class LocalASRConfidenceTests: XCTestCase {
    private func word(_ probability: Double?, text: String = "あ") -> ASRWord {
        ASRWord(text: text, startSeconds: 0, endSeconds: 0.1, probability: probability)
    }

    private func timedWord(_ text: String, start: Double, end: Double, probability: Double?) -> ASRWord {
        ASRWord(text: text, startSeconds: start, endSeconds: end, probability: probability)
    }

    func testCleanTranscriptIsNotLowConfidence() {
        let words = Array(repeating: word(0.95), count: 30)
        let summary = LocalASRConfidence.assess(words: words)
        XCTAssertFalse(summary.isLowConfidence)
        XCTAssertEqual(summary.assessedWordCount, 30)
        XCTAssertEqual(summary.averageProbability, 0.95, accuracy: 0.0001)
    }

    func testGarbledTranscriptIsLowConfidence() {
        // 8 低置信词 + 22 高置信词：avg≈0.74（<0.8）且低置信占比≈0.27（>0.2），两条都触发。
        let words = Array(repeating: word(0.3), count: 8) + Array(repeating: word(0.9), count: 22)
        let summary = LocalASRConfidence.assess(words: words)
        XCTAssertTrue(summary.isLowConfidence)
        XCTAssertLessThan(summary.averageProbability, 0.8)
        XCTAssertGreaterThan(summary.lowConfidenceWordRatio, 0.2)
    }

    func testBorderlineConfidenceIsNotFlagged() {
        // avg≈0.85（≥0.8），低置信占比 0.1（≤0.2）→ 保守不报警。
        let words = Array(repeating: word(0.4), count: 3) + Array(repeating: word(0.9), count: 27)
        let summary = LocalASRConfidence.assess(words: words)
        XCTAssertFalse(summary.isLowConfidence)
    }

    func testShortClipIsNotAssessed() {
        // 词数 < 24：样本不足，不评估（避免短片段误报）。
        let words = Array(repeating: word(0.2), count: 10)
        let summary = LocalASRConfidence.assess(words: words)
        XCTAssertFalse(summary.isLowConfidence)
    }

    func testWordsWithoutProbabilityAreNotFlagged() {
        let words = Array(repeating: word(nil), count: 40)
        let summary = LocalASRConfidence.assess(words: words)
        XCTAssertEqual(summary.assessedWordCount, 0)
        XCTAssertFalse(summary.isLowConfidence)
    }

    func testConfidentWrongScriptForKoreanIsLowQuality() {
        let words = Array(repeating: word(0.95, text: "baby"), count: 30)
        let summary = LocalASRConfidence.assess(words: words, languageCode: "ko")
        XCTAssertFalse(summary.isLowConfidence)
        XCTAssertTrue(summary.isLowQuality)
        XCTAssertTrue(summary.qualityIssues.contains("scriptMismatch"))
    }

    func testRepeatedTokenLoopIsLowQualityEvenWhenConfident() {
        let words = Array(repeating: word(0.96, text: "ね"), count: 36)

        let summary = LocalASRConfidence.assess(words: words, languageCode: "ja")

        XCTAssertFalse(summary.isLowConfidence)
        XCTAssertTrue(summary.isLowQuality)
        XCTAssertTrue(summary.qualityIssues.contains("repetitionLoop"))
        XCTAssertTrue(summary.qualityIssues.contains("lowDiversity"))
    }

    func testShortRepeatedAutoEnglishPhraseWithJapaneseHintIsSevereLowQuality() {
        let segments = [
            ASRSegment(text: "*Korin*", startSeconds: 0, endSeconds: 2),
            ASRSegment(text: "*Korin*", startSeconds: 30, endSeconds: 32),
            ASRSegment(text: "*Korin*", startSeconds: 60, endSeconds: 62),
        ]
        let words = segments.map {
            ASRWord(text: $0.text, startSeconds: $0.startSeconds, endSeconds: $0.endSeconds, probability: 0.95)
        }

        let summary = LocalASRConfidence.assess(
            words: words,
            segments: segments,
            languageCode: "en",
            requestedLanguageCode: "auto",
            languageHintCode: "ja")

        XCTAssertTrue(summary.isLowQuality)
        XCTAssertTrue(summary.hasSevereQualityBlocker)
        XCTAssertTrue(summary.qualityIssues.contains("autoLanguageMismatch"))
        XCTAssertTrue(summary.qualityIssues.contains("lowSegmentDiversity"))
        XCTAssertEqual(summary.dominantPhraseRatio, 1, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(summary.repeatedPhraseSpanSeconds, 60)
    }

    func testLongRepeatedPhraseLoopIsSevereLowQuality() {
        let segments = (0..<7).map { index in
            ASRSegment(
                text: "気持ちいいですか?",
                startSeconds: 22 + Double(index * 5),
                endSeconds: 24 + Double(index * 5))
        }
        let words = segments.map {
            ASRWord(text: $0.text, startSeconds: $0.startSeconds, endSeconds: $0.endSeconds, probability: 0.96)
        }

        let summary = LocalASRConfidence.assess(
            words: words,
            segments: segments,
            languageCode: "ja",
            requestedLanguageCode: "ja",
            languageHintCode: "ja")

        XCTAssertTrue(summary.isLowQuality)
        XCTAssertTrue(summary.hasSevereQualityBlocker)
        XCTAssertTrue(summary.qualityIssues.contains("phraseLoop"))
        XCTAssertGreaterThan(summary.repeatedPhraseSpanSeconds, 25)
    }

    func testFragmentedJapanesePhraseLoopIsSevereLowQuality() {
        let segments = [
            ASRSegment(text: "お同じく", startSeconds: 136.54, endSeconds: 138.68),
            ASRSegment(text: "お同じく", startSeconds: 139.44, endSeconds: 140.30),
            ASRSegment(text: "おく同じお同じおく同", startSeconds: 140.58, endSeconds: 145.28),
            ASRSegment(text: "じくお同じ", startSeconds: 148.44, endSeconds: 150.76),
            ASRSegment(text: "くお", startSeconds: 152.46, endSeconds: 153.62),
            ASRSegment(text: "同じくお同じく", startSeconds: 155.92, endSeconds: 158.48),
        ]
        let words = segments.map {
            ASRWord(text: $0.text, startSeconds: $0.startSeconds, endSeconds: $0.endSeconds, probability: 0.96)
        }

        let summary = LocalASRConfidence.assess(
            words: words,
            segments: segments,
            languageCode: "ja",
            requestedLanguageCode: "ja",
            languageHintCode: "ja")

        XCTAssertTrue(summary.isLowQuality)
        XCTAssertTrue(summary.hasSevereQualityBlocker)
        XCTAssertTrue(summary.qualityIssues.contains("phraseLoop"))
        XCTAssertTrue(summary.qualityIssues.contains("lowSegmentDiversity"))
    }

    func testExistingLocalASRSRTFragmentLoopIsSevereLowQuality() {
        let raw = """
        25
        00:02:16,540 --> 00:02:18,680
        お同じく

        26
        00:02:19,440 --> 00:02:20,300
        お同じく

        27
        00:02:20,580 --> 00:02:25,280
        おく同じお同じおく同

        28
        00:02:28,440 --> 00:02:30,760
        じくお同じ

        29
        00:02:32,460 --> 00:02:33,620
        くお

        30
        00:02:35,920 --> 00:02:38,480
        同じくお同じく
        """

        let summary = LocalASRConfidence.assessSubtitle(
            raw: raw,
            fileName: "clip.local-asr.ja.srt",
            languageCode: "ja",
            requestedLanguageCode: "ja",
            languageHintCode: "ja")

        XCTAssertTrue(summary.hasSevereQualityBlocker)
        XCTAssertTrue(summary.qualityIssues.contains("phraseLoop"))
        XCTAssertTrue(summary.qualityIssues.contains("lowSegmentDiversity"))
    }

    func testNearEmptyLocalASRSRTIsSevereLowQuality() {
        let raw = """
        1
        00:00:00,400 --> 00:00:01,530
        あ
        """

        let summary = LocalASRConfidence.assessSubtitle(
            raw: raw,
            fileName: "clip.local-asr.ja.srt",
            languageCode: "ja",
            requestedLanguageCode: "ja",
            languageHintCode: "ja")

        XCTAssertTrue(summary.isLowQuality)
        XCTAssertTrue(summary.hasSevereQualityBlocker)
        XCTAssertTrue(summary.qualityIssues.contains("nearEmptyTranscript"))
    }

    /// Cross-platform parity: invisible Unicode Format marks (U+200F RLM etc., common in Arabic
    /// RTL output) must not count as meaningful characters. Otherwise mac and Windows disagree on
    /// nearEmptyTranscript for the same transcript. Swift ignores Cc+Cf via controlCharacters; C#
    /// ignores Control+Format in ShouldIgnoreForScriptQuality.
    func testNearEmptyDetectionIgnoresInvisibleFormatMarks() {
        let raw = """
        1
        00:00:00,400 --> 00:00:01,530
        \u{0645}\u{200F}\u{200F}\u{200F}
        """

        let summary = LocalASRConfidence.assessSubtitle(
            raw: raw,
            fileName: "clip.local-asr.ar.srt",
            languageCode: "ar",
            requestedLanguageCode: "ar",
            languageHintCode: "ar")

        XCTAssertTrue(summary.qualityIssues.contains("nearEmptyTranscript"))
    }

    func testHealthyRepeatedLyricsAreNotTreatedAsLoopCollapse() {
        let tokens = ["青", "い", "空", "を", "見", "る", "君", "と", "歩", "く", "道", "で"]
        let words = (0..<36).map { index in word(0.96, text: tokens[index % tokens.count]) }

        let summary = LocalASRConfidence.assess(words: words, languageCode: "ja")

        XCTAssertFalse(summary.isLowQuality)
        XCTAssertEqual(summary.qualityIssues, [])
    }

    func testStretchedLowConfidenceCJKTokenClusterIsLowQuality() {
        let opening = [
            timedWord("착", start: 1.91, end: 5.13, probability: 0.02),
            timedWord("한", start: 5.14, end: 10.24, probability: 0.99),
            timedWord("얼굴에", start: 10.24, end: 25.60, probability: 0.96),
        ]
        let normal = (0..<30).map { index in
            timedWord("노래\(index)", start: 26 + Double(index) * 0.4, end: 26.2 + Double(index) * 0.4, probability: 0.95)
        }

        let summary = LocalASRConfidence.assess(words: opening + normal, languageCode: "ko")

        XCTAssertFalse(summary.isLowConfidence)
        XCTAssertTrue(summary.isLowQuality)
        XCTAssertTrue(summary.qualityIssues.contains("stretchedLowConfidenceCJKToken"))
    }

    func testHealthyStretchedCJKLyricsWithoutLowProbabilityAreNotLowQuality() {
        let stretched = [
            timedWord("な", start: 2.0, end: 4.8, probability: 0.94),
            timedWord("い", start: 8.0, end: 11.2, probability: 0.96),
            timedWord("君", start: 20.0, end: 23.4, probability: 0.91),
        ]
        let normal = (0..<30).map { index in
            timedWord("歌\(index)", start: 30 + Double(index) * 0.4, end: 30.2 + Double(index) * 0.4, probability: 0.95)
        }

        let summary = LocalASRConfidence.assess(words: stretched + normal, languageCode: "ja")

        XCTAssertFalse(summary.isLowQuality)
        XCTAssertFalse(summary.qualityIssues.contains("stretchedLowConfidenceCJKToken"))
    }

    func testReadableRepeatedChorusSegmentsAreNotSevereLowQuality() {
        let segments = (0..<5).map { index in
            ASRSegment(
                text: "好きだよ",
                startSeconds: Double(index) * 4,
                endSeconds: Double(index) * 4 + 1.2)
        }
        let words = segments.map {
            ASRWord(text: $0.text, startSeconds: $0.startSeconds, endSeconds: $0.endSeconds, probability: 0.96)
        }

        let summary = LocalASRConfidence.assess(
            words: words,
            segments: segments,
            languageCode: "ja",
            requestedLanguageCode: "ja",
            languageHintCode: "ja")

        XCTAssertFalse(summary.hasSevereQualityBlocker)
        XCTAssertFalse(summary.qualityIssues.contains("phraseLoop"))
        XCTAssertFalse(summary.qualityIssues.contains("lowSegmentDiversity"))
    }

    func testSummaryDecodesLegacyPayloadWithQualityDefaults() throws {
        let data = Data("""
        {
          "assessedWordCount": 30,
          "averageProbability": 0.95,
          "lowConfidenceWordRatio": 0.02,
          "isLowConfidence": false
        }
        """.utf8)

        let summary = try JSONDecoder().decode(LocalASRConfidenceSummary.self, from: data)

        XCTAssertFalse(summary.isLowQuality)
        XCTAssertEqual(summary.qualityIssues, [])
        XCTAssertEqual(summary.scriptMismatchRatio, 0)
    }

    func testConstantsMatchCrossPlatformFixture() throws {
        let fixture = try loadFixtureSection("localASRConfidence")
        func doubleValue(_ key: String) throws -> Double {
            try XCTUnwrap((fixture[key] as? NSNumber)?.doubleValue, "fixture missing \(key)")
        }
        func intValue(_ key: String) throws -> Int {
            try XCTUnwrap((fixture[key] as? NSNumber)?.intValue, "fixture missing \(key)")
        }
        XCTAssertEqual(LocalASRConfidence.averageProbabilityFloor, try doubleValue("averageProbabilityFloor"))
        XCTAssertEqual(LocalASRConfidence.lowConfidenceWordProbability, try doubleValue("lowConfidenceWordProbability"))
        XCTAssertEqual(LocalASRConfidence.lowConfidenceWordRatioCeiling, try doubleValue("lowConfidenceWordRatioCeiling"))
        XCTAssertEqual(LocalASRConfidence.minimumAssessableWordCount, try intValue("minimumAssessableWordCount"))
        XCTAssertEqual(LocalASRConfidence.stretchedCJKTokenSecondsFloor, try doubleValue("stretchedCJKTokenSecondsFloor"))
        XCTAssertEqual(LocalASRConfidence.stretchedCJKTokenClusterCount, try intValue("stretchedCJKTokenClusterCount"))
        XCTAssertEqual(LocalASRConfidence.stretchedCJKLowProbabilityCeiling, try doubleValue("stretchedCJKLowProbabilityCeiling"))
    }

    private func loadFixtureSection(_ section: String) throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Tests/fixtures/whisper-timing-constants.json")
        let data = try Data(contentsOf: url)
        let fixture = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(fixture[section] as? [String: Any], "fixture missing section \(section)")
    }
}
