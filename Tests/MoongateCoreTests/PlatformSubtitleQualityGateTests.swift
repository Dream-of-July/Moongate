import XCTest
@testable import MoongateCore

/// M2 pure-logic tests for the platform auto-caption usability gate. The load-bearing test is
/// `testWhisperNeverComparedByTiming`: a structurally bad-timing but content-healthy auto-caption
/// must stay usable, so the gate never triggers a needless whisper fallback on timing grounds.
final class PlatformSubtitleQualityGateTests: XCTestCase {

    /// Builds `count` short, well-formed English cues at 2s intervals (1.5s each) → good density/coverage.
    private func healthyCues(count: Int, text: (Int) -> String = { "line \($0)" }) -> [SubtitleCue] {
        (0..<count).map { i in
            let startMs = i * 2000
            let endMs = startMs + 1500
            return SubtitleCue(index: i + 1, start: ms(startMs), end: ms(endMs), text: text(i))
        }
    }

    private func ms(_ totalMs: Int) -> String {
        let h = totalMs / 3_600_000
        let m = (totalMs % 3_600_000) / 60_000
        let s = (totalMs % 60_000) / 1000
        let milli = totalMs % 1000
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, milli)
    }

    func testHealthyAutoCaptionUsable() {
        let cues = healthyCues(count: 20)
        let verdict = PlatformSubtitleQualityGate.assess(
            cues: cues, requestedLanguageCode: "en", subtitleLanguageCode: "en", videoDurationSeconds: 60)
        XCTAssertTrue(verdict.usable)
        XCTAssertTrue(verdict.reasons.isEmpty)
    }

    func testLanguageMismatchUnusable() {
        let cues = healthyCues(count: 20)
        let verdict = PlatformSubtitleQualityGate.assess(
            cues: cues, requestedLanguageCode: "ja", subtitleLanguageCode: "en", videoDurationSeconds: 60)
        XCTAssertFalse(verdict.usable)
        XCTAssertTrue(verdict.reasons.contains(.languageMismatch))
    }

    func testTooFewCuesUnusable() {
        let cues = healthyCues(count: 3)
        let verdict = PlatformSubtitleQualityGate.assess(
            cues: cues, requestedLanguageCode: "en", subtitleLanguageCode: "en", videoDurationSeconds: 10)
        XCTAssertFalse(verdict.usable)
        XCTAssertTrue(verdict.reasons.contains(.tooFewCues))
    }

    func testLowCoverageUnusable() {
        // 20 cues × 1.5s = 30s covered, but the video is 600s → 5% coverage.
        let cues = healthyCues(count: 20)
        let verdict = PlatformSubtitleQualityGate.assess(
            cues: cues, requestedLanguageCode: "en", subtitleLanguageCode: "en", videoDurationSeconds: 600)
        XCTAssertFalse(verdict.usable)
        XCTAssertTrue(verdict.reasons.contains(.lowCoverage))
    }

    func testCoverageSkippedWhenDurationUnknown() {
        let cues = healthyCues(count: 20)
        let verdict = PlatformSubtitleQualityGate.assess(
            cues: cues, requestedLanguageCode: "en", subtitleLanguageCode: "en", videoDurationSeconds: nil)
        XCTAssertTrue(verdict.usable, "no duration → coverage must not be judged")
    }

    func testRepetitiveUnusable() {
        // Every cue identical → adjacent-identical ratio = 1.0 ≥ 0.5.
        let cues = healthyCues(count: 20, text: { _ in "［音楽］" })
        let verdict = PlatformSubtitleQualityGate.assess(
            cues: cues, requestedLanguageCode: "ja", subtitleLanguageCode: "ja", videoDurationSeconds: 60)
        XCTAssertFalse(verdict.usable)
        XCTAssertTrue(verdict.reasons.contains(.garbledOrRepetitive))
    }

    func testGarbledUnusable() {
        let cues = healthyCues(count: 20, text: { i in i % 2 == 0 ? "\u{FFFD}\u{FFFD}\u{FFFD}" : "ok line \(i)" })
        let verdict = PlatformSubtitleQualityGate.assess(
            cues: cues, requestedLanguageCode: "en", subtitleLanguageCode: "en", videoDurationSeconds: 60)
        XCTAssertFalse(verdict.usable)
        XCTAssertTrue(verdict.reasons.contains(.garbledOrRepetitive))
    }

    func testGunjouLikeJapaneseAutoCaptionWithRomanizedLoopIsUnusable() {
        let texts = [
            "ああいつものようにすぎる一里にあくびが出る",
            "さんざめくよる声今日渋谷街に字買うん",
            "どこか話した",
            "anas あのこれええええええええええ",
            "しらす各 carano",
            "ni nani",
            "ni",
            "ni",
            "dare",
            "dare",
            "ni",
            "ana ni",
            "me ni",
            "ani box",
            "car ni",
            "悔しい気持ちだけ",
            "なくて涙立てる",
            "好きなことを続けること",
            "それは楽しいだけじゃない",
            "本当にできる"
        ]
        let cues = healthyCues(count: texts.count, text: { texts[$0] })
        let verdict = PlatformSubtitleQualityGate.assess(
            cues: cues,
            requestedLanguageCode: "ja",
            subtitleLanguageCode: "ja",
            videoDurationSeconds: 50
        )
        XCTAssertFalse(verdict.usable)
        XCTAssertTrue(verdict.reasons.contains(.garbledOrRepetitive))
    }

    func testCJKTrackWithMostlyLatinRomanizedNoiseIsUnusable() {
        let texts = ["ni", "ni", "dare ni", "carano", "anas", "nani", "ana ni", "me ni"]
        let cues = healthyCues(count: texts.count, text: { texts[$0] })
        let verdict = PlatformSubtitleQualityGate.assess(
            cues: cues,
            requestedLanguageCode: "ja",
            subtitleLanguageCode: "ja",
            videoDurationSeconds: 18
        )

        XCTAssertFalse(verdict.usable)
        XCTAssertTrue(verdict.reasons.contains(.garbledOrRepetitive))
        XCTAssertGreaterThanOrEqual(verdict.report.latinScalarRatio, PlatformSubtitleQualityGate.cjkContentMismatchLatinRatioThreshold)
    }

    func testHealthyJapaneseAutoCaptionWithSomeLatinTermsStaysUsable() {
        let texts = [
            "今日はYOASOBIの曲について話します",
            "まず最初のメロディーを聴いてください",
            "この部分はとても静かに始まります",
            "サビでは声の重なりが強くなります",
            "歌詞のイメージも青い世界を描いています",
            "MVの映像もその雰囲気に合わせています",
            "ここでピアノの音が前に出ます",
            "次にベースのリズムを確認します",
            "英語のタイトルGunjouも紹介されています",
            "全体として青春の迷いを表しています",
            "最後は明るい余韻で終わります",
            "この表現はライブでも印象的です"
        ]
        let cues = healthyCues(count: texts.count, text: { texts[$0] })
        let verdict = PlatformSubtitleQualityGate.assess(
            cues: cues,
            requestedLanguageCode: "ja",
            subtitleLanguageCode: "ja",
            videoDurationSeconds: 28
        )
        XCTAssertTrue(verdict.usable)
        XCTAssertTrue(verdict.reasons.isEmpty)
    }

    func testJapaneseLyricsWithParentheticalRomajiGlossStaysUsable() {
        let texts = [
            "沈むように溶けていくように (Shizumu you ni tokete yuku you ni)",
            "二人だけの空が広がる夜に (Futari dake no sora ga hirogaru you ni)",
            "さよならだけだった (Sayonara dakedatta)",
            "その一言で全てが分かった (Sono hitokoto de subete ga wakatta)",
            "日が沈み出した空と君の姿 (Higa shizumi dashita sora to kimi no sugata)",
            "フェンス越しに重なっていた (Fensu-goshi ni kasanatte ita)",
            "初めて会った日から (Hajimete atta hi kara)",
            "僕の心の全てを奪った (Boku no kokoro no subete o ubatta)",
            "どこか儚い空気を纏う君は (Doko ka hakanai kuuki o matou kimi wa)",
            "寂しい目をしてたんだ (Sabishii me wo shitetanda)"
        ]
        let cues = healthyCues(count: texts.count, text: { texts[$0] })
        let verdict = PlatformSubtitleQualityGate.assess(
            cues: cues,
            requestedLanguageCode: "ja",
            subtitleLanguageCode: "ja",
            videoDurationSeconds: nil
        )
        XCTAssertTrue(verdict.usable)
        XCTAssertTrue(verdict.reasons.isEmpty)
        XCTAssertLessThan(verdict.report.latinScalarRatio, 0.10)
        XCTAssertEqual(verdict.report.romanizedLoopTokenCount, 0)
    }

    func testCJKAutoCaptionWithExcessiveLongRollingCuesIsUnusable() {
        let cues = [
            SubtitleCue(index: 1, start: "00:00:01,120", end: "00:00:15,750", text: "私さは愚かさとはそれが何か見せつけて"),
            SubtitleCue(index: 2, start: "00:00:15,760", end: "00:00:20,150", text: "やるちっちゃな頃から言うとせついたら"),
            SubtitleCue(index: 3, start: "00:00:20,160", end: "00:00:24,990", text: "大人になってたナフのような思考会"),
            SubtitleCue(index: 4, start: "00:00:25,000", end: "00:00:28,710", text: "持ち合わせる負けもなくでも遊び足りない"),
            SubtitleCue(index: 5, start: "00:00:28,720", end: "00:00:33,590", text: "何か足りない困っちまうこれは誰かのせも"),
            SubtitleCue(index: 6, start: "00:00:36,480", end: "00:00:42,630", text: "するましか最の流行は当然の白経のど"),
            SubtitleCue(index: 7, start: "00:00:42,640", end: "00:00:49,750", text: "も中な精神でしは社会人は然の"),
            SubtitleCue(index: 8, start: "00:01:08,960", end: "00:01:24,390", text: "メロディは頭の敵が違うので問題は"),
            SubtitleCue(index: 9, start: "00:01:24,400", end: "00:01:30,150", text: "なしずっても私も半人間ったりするのはせ"),
            SubtitleCue(index: 10, start: "00:01:30,160", end: "00:01:47,190", text: "ったら言葉の中をその仲にきつけては")
        ]
        let verdict = PlatformSubtitleQualityGate.assess(
            cues: cues,
            requestedLanguageCode: "ja",
            subtitleLanguageCode: "ja",
            videoDurationSeconds: nil
        )

        XCTAssertFalse(verdict.usable)
        XCTAssertTrue(verdict.reasons.contains(.garbledOrRepetitive))
        XCTAssertGreaterThanOrEqual(verdict.report.longCueCount, PlatformSubtitleQualityGate.cjkLongCueMinCount)
    }

    func testKoreanLyricsWithEnglishHookStaysUsable() {
        let texts = [
            "이 노래는 It's about you baby",
            "Only you",
            "내가 힘들 때 울 것 같을 때",
            "It's you I got done honey",
            "말 안 해도 돼 boy",
            "멀리든 언제든지 달려와",
            "dreams come true",
            "That's my life",
            "I'll be far away",
            "Be your writer",
            "내일 내게 열리는 건 big stage",
            "You and me"
        ]
        let cues = healthyCues(count: texts.count, text: { texts[$0] })
        let verdict = PlatformSubtitleQualityGate.assess(
            cues: cues,
            requestedLanguageCode: "ko",
            subtitleLanguageCode: "ko",
            videoDurationSeconds: nil
        )

        XCTAssertTrue(verdict.usable)
        XCTAssertTrue(verdict.reasons.isEmpty)
        XCTAssertEqual(verdict.report.romanizedLoopTokenCount, 0)
    }

    func testAutoCaptionWithManySoundEffectCuesIsUnusable() {
        let texts = [
            "ルルルル",
            "[拍手]",
            "ルルルルル",
            "[音楽]",
            "君の中にある赤とはせも",
            "[拍手]",
            "[音楽]",
            "それらが結ばれるのは真の像",
            "風の中でも負けないような声で",
            "[拍手]",
            "届ける言葉を今は育ててる",
            "[音楽]"
        ]
        let cues = healthyCues(count: texts.count, text: { texts[$0] })
        let verdict = PlatformSubtitleQualityGate.assess(
            cues: cues,
            requestedLanguageCode: "ja",
            subtitleLanguageCode: "ja",
            videoDurationSeconds: nil
        )

        XCTAssertFalse(verdict.usable)
        XCTAssertTrue(verdict.reasons.contains(.garbledOrRepetitive))
        XCTAssertGreaterThanOrEqual(verdict.report.soundEffectCueCount, PlatformSubtitleQualityGate.soundEffectCueMinCount)
    }

    func testAutoCaptionWithLongSoundEffectHoldsIsUnusable() {
        let cues = [
            SubtitleCue(index: 1, start: ms(1_000), end: ms(16_000), text: "[Musica]"),
            SubtitleCue(index: 2, start: ms(16_000), end: ms(18_000), text: "Marco se n'è andato e non"),
            SubtitleCue(index: 3, start: ms(18_000), end: ms(23_000), text: "ritorna il treno delle sette e trenta"),
            SubtitleCue(index: 4, start: ms(23_000), end: ms(27_000), text: "un cuore di metallo senza l'anima"),
            SubtitleCue(index: 5, start: ms(27_000), end: ms(31_000), text: "nel freddo del mattino grigio di città"),
            SubtitleCue(index: 6, start: ms(31_000), end: ms(35_000), text: "a scuola il banco è vuoto"),
            SubtitleCue(index: 7, start: ms(35_000), end: ms(39_000), text: "dolce il suo respiro"),
            SubtitleCue(index: 8, start: ms(39_000), end: ms(43_000), text: "ma il cuore batte forte"),
            SubtitleCue(index: 9, start: ms(75_000), end: ms(89_000), text: "[Musica]")
        ]
        let verdict = PlatformSubtitleQualityGate.assess(
            cues: cues,
            requestedLanguageCode: "it",
            subtitleLanguageCode: "it",
            videoDurationSeconds: nil
        )

        XCTAssertFalse(verdict.usable)
        XCTAssertTrue(verdict.reasons.contains(.garbledOrRepetitive))
        XCTAssertGreaterThanOrEqual(verdict.report.soundEffectDurationRatio, PlatformSubtitleQualityGate.soundEffectDurationRatioThreshold)
    }

    func testEnglishLyricsWithMusicNoteMarkersStaysUsable() {
        let texts = [
            "♪ I WANT YOU TO STAY ♪",
            "'TIL I'M IN THE GRAVE ♪",
            "IF YOU GO, I'M GOING TOO, UH ♪",
            "BIRDS OF A FEATHER, WE SHOULD STICK TOGETHER, I KNOW ♪",
            "I'LL LOVE YOU 'TIL THE DAY THAT I DIE ♪",
            "♪♪♪",
            "TIL THE LIGHT LEAVES MY EYES ♪",
            "CAN'T CHANGE THE WEATHER, MIGHT NOT BE FOREVER ♪"
        ]
        let cues = healthyCues(count: texts.count, text: { texts[$0] })
        let verdict = PlatformSubtitleQualityGate.assess(
            cues: cues,
            requestedLanguageCode: "en",
            subtitleLanguageCode: "en",
            videoDurationSeconds: nil
        )

        XCTAssertTrue(verdict.usable)
        XCTAssertTrue(verdict.reasons.isEmpty)
        XCTAssertEqual(verdict.report.soundEffectCueCount, 1)
    }

    /// Load-bearing regression: structurally bad timing (huge overlaps / zero gaps mimicking
    /// whisper-vs-Google differences) but content is fine. The gate must NOT mark it unusable,
    /// because timing is explicitly out of scope — otherwise whisper fallback would fire needlessly.
    func testWhisperNeverComparedByTiming() {
        // All cues span the entire video with identical-looking start/end (terrible timing),
        // yet distinct healthy text, matching language, good density and full coverage.
        let cues = (0..<20).map { i in
            SubtitleCue(index: i + 1, start: ms(0), end: ms(60_000), text: "distinct healthy sentence number \(i)")
        }
        let verdict = PlatformSubtitleQualityGate.assess(
            cues: cues, requestedLanguageCode: "en", subtitleLanguageCode: "en", videoDurationSeconds: 60)
        XCTAssertTrue(verdict.usable, "timing must never enter the usability verdict")
        XCTAssertTrue(verdict.reasons.isEmpty)
    }

    func testSongSourceArbiterPrefersManualBeforeAutoAndLocalASR() throws {
        let arbitration = SongSubtitleSourceArbiter.arbitrate(
            languageCode: "ja",
            tracks: [
                SubtitleChoice(languageCode: "ja", label: "Japanese auto", sourceKind: .platformAuto),
                SubtitleChoice(languageCode: "ja", label: "Japanese", sourceKind: .manual)
            ],
            platformAutoVerdict: PlatformSubtitleQualityGate.Verdict(usable: true, reasons: []),
            localASRAvailable: true
        )

        XCTAssertEqual(arbitration.selectedKind, .manual)
        let manual = try XCTUnwrap(arbitration.candidateReports.first { $0.sourceKind == .manual })
        let auto = try XCTUnwrap(arbitration.candidateReports.first { $0.sourceKind == .platformAuto })
        let localASR = try XCTUnwrap(arbitration.candidateReports.first { $0.sourceKind == .localASR })
        XCTAssertTrue(manual.selected)
        XCTAssertFalse(auto.selected)
        XCTAssertFalse(localASR.selected)
    }

    func testSongSourceArbiterFallsBackToLocalASRWhenAutoIsGarbled() throws {
        let arbitration = SongSubtitleSourceArbiter.arbitrate(
            languageCode: "ja",
            tracks: [
                SubtitleChoice(languageCode: "ja", label: "Japanese auto", sourceKind: .platformAuto)
            ],
            platformAutoVerdict: PlatformSubtitleQualityGate.Verdict(
                usable: false,
                reasons: [.garbledOrRepetitive]
            ),
            localASRAvailable: true
        )

        XCTAssertEqual(arbitration.selectedKind, .localASR)
        let auto = try XCTUnwrap(arbitration.candidateReports.first { $0.sourceKind == .platformAuto })
        let localASR = try XCTUnwrap(arbitration.candidateReports.first { $0.sourceKind == .localASR })
        XCTAssertFalse(auto.usable)
        XCTAssertFalse(auto.selected)
        XCTAssertEqual(auto.reasons, ["garbledOrRepetitive"])
        XCTAssertTrue(localASR.usable)
        XCTAssertTrue(localASR.selected)
    }

    // MARK: - Fixture contract (ARCH-3)

    func testQualityGateConstantsMatchFixture() throws {
        let fixture = try loadFixtureSection("platformSubtitleQualityGate")
        func intValue(_ key: String) throws -> Int {
            try XCTUnwrap((fixture[key] as? NSNumber)?.intValue, "fixture missing \(key)")
        }
        func doubleValue(_ key: String) throws -> Double {
            try XCTUnwrap((fixture[key] as? NSNumber)?.doubleValue, "fixture missing \(key)")
        }
        XCTAssertEqual(PlatformSubtitleQualityGate.minimumUsableCueCount, try intValue("minimumUsableCueCount"))
        XCTAssertEqual(PlatformSubtitleQualityGate.minimumCoverageRatio, try doubleValue("minimumCoverageRatio"))
        XCTAssertEqual(PlatformSubtitleQualityGate.repetitionRatioThreshold, try doubleValue("repetitionRatioThreshold"))
        XCTAssertEqual(PlatformSubtitleQualityGate.garbledRatioThreshold, try doubleValue("garbledRatioThreshold"))
        XCTAssertEqual(PlatformSubtitleQualityGate.cjkLatinNoiseRatioThreshold, try doubleValue("cjkLatinNoiseRatioThreshold"))
        XCTAssertEqual(PlatformSubtitleQualityGate.cjkContentMismatchLatinRatioThreshold, try doubleValue("cjkContentMismatchLatinRatioThreshold"))
        XCTAssertEqual(PlatformSubtitleQualityGate.cjkContentMismatchCJKRatioThreshold, try doubleValue("cjkContentMismatchCJKRatioThreshold"))
        XCTAssertEqual(PlatformSubtitleQualityGate.cjkLongCueDurationThreshold, try doubleValue("cjkLongCueDurationThreshold"))
        XCTAssertEqual(PlatformSubtitleQualityGate.cjkLongCueRatioThreshold, try doubleValue("cjkLongCueRatioThreshold"))
        XCTAssertEqual(PlatformSubtitleQualityGate.cjkLongCueMinCount, try intValue("cjkLongCueMinCount"))
        XCTAssertEqual(PlatformSubtitleQualityGate.romanizedLoopTokenRatioThreshold, try doubleValue("romanizedLoopTokenRatioThreshold"))
        XCTAssertEqual(PlatformSubtitleQualityGate.romanizedLoopMinTokenCount, try intValue("romanizedLoopMinTokenCount"))
        XCTAssertEqual(PlatformSubtitleQualityGate.romanizedLoopMinMaxRun, try intValue("romanizedLoopMinMaxRun"))
        XCTAssertEqual(PlatformSubtitleQualityGate.soundEffectCueRatioThreshold, try doubleValue("soundEffectCueRatioThreshold"))
        XCTAssertEqual(PlatformSubtitleQualityGate.soundEffectCueMinCount, try intValue("soundEffectCueMinCount"))
        XCTAssertEqual(PlatformSubtitleQualityGate.soundEffectDurationRatioThreshold, try doubleValue("soundEffectDurationRatioThreshold"))
        XCTAssertEqual(PlatformSubtitleQualityGate.soundEffectDurationMinCount, try intValue("soundEffectDurationMinCount"))
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
