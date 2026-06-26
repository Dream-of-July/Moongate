import XCTest
@testable import MoongateCore

/// M2 pure-logic tests for the language-first ready page: deterministic recommendation that follows
/// video content (never hardcoded), and the platform auto-caption usability gate that must never
/// judge whisper by timing.
final class SubtitleLanguageRecommenderTests: XCTestCase {

    private func manual(_ code: String, label: String? = nil) -> SubtitleChoice {
        SubtitleChoice(languageCode: code, label: label ?? code, sourceKind: .manual)
    }

    private func auto(_ code: String, label: String? = nil) -> SubtitleChoice {
        SubtitleChoice(languageCode: code, label: label ?? code, sourceKind: .platformAuto)
    }

    private func localASR(_ code: String, label: String? = nil) -> SubtitleChoice {
        SubtitleChoice(languageCode: code, label: label ?? code, sourceKind: .localASR, provider: "whisper.cpp", variant: "local")
    }

    // MARK: - Aggregation

    func testAggregateGroupsByNormalizedLanguage() throws {
        let choices = [auto("ja-JP"), localASR("ja"), manual("en"), auto("ja-orig")]
        let groups = SubtitleLanguageChoice.aggregate(choices)
        XCTAssertEqual(groups.map(\.languageCode), ["ja", "en"])
        let ja = try XCTUnwrap(groups.first { $0.languageCode == "ja" })
        // ja group merges ja-JP / ja / ja-orig; tracks sorted auto(s) before localASR.
        XCTAssertEqual(ja.tracks.count, 3)
        XCTAssertTrue(ja.hasAutoTrack)
        XCTAssertTrue(ja.supportsLocalASR)
        XCTAssertFalse(ja.hasManualTrack)
    }

    func testPreferredTrackPrefersManualOverAutoOverLocalASR() {
        let groups = SubtitleLanguageChoice.aggregate([localASR("en"), auto("en"), manual("en")])
        let en = groups.first { $0.languageCode == "en" }
        XCTAssertEqual(en?.preferredTrack?.sourceKind, .manual)
    }

    // MARK: - Recommendation follows content (not hardcoded)

    func testGunjouRecommendsJapanese() {
        // 群青 (YOASOBI) — Japanese title, ja auto-caption available.
        let groups = SubtitleLanguageChoice.aggregate([auto("ja"), auto("en")])
        let result = SubtitleLanguageRecommender.recommend(title: "YOASOBI - 群青 (Gunjou)", languages: groups)
        XCTAssertEqual(result.recommended?.languageCode, "ja")
    }

    func testGunjouRecommendsJapaneseWhenManualTranslationSubtitlesExist() {
        // Manual English/Chinese subtitles are likely translations. The recommendation is the
        // video's source language; source choice inside that language is handled later.
        let groups = SubtitleLanguageChoice.aggregate([
            auto("ja"), manual("en"), manual("zh-Hans"),
            localASR("ja"), localASR("en"), localASR("zh-Hans")
        ])
        let result = SubtitleLanguageRecommender.recommend(title: "YOASOBI - 群青 (Gunjou)", languages: groups)
        XCTAssertEqual(result.recommended?.languageCode, "ja")
    }

    func testKoreanMVRecommendsKoreanWhenManualEnglishTranslationExists() {
        let groups = SubtitleLanguageChoice.aggregate([auto("ko"), manual("en"), localASR("ko"), localASR("en")])
        let result = SubtitleLanguageRecommender.recommend(title: "아이유 (IU) - 좋은 날 MV", languages: groups)
        XCTAssertEqual(result.recommended?.languageCode, "ko")
    }

    func testEnglishInterviewRecommendsEnglish() {
        let groups = SubtitleLanguageChoice.aggregate([auto("en"), auto("ja")])
        let result = SubtitleLanguageRecommender.recommend(
            title: "The Future of AI — A Conversation with Researchers", languages: groups)
        XCTAssertEqual(result.recommended?.languageCode, "en")
    }

    func testKoreanMVRecommendsKorean() {
        let groups = SubtitleLanguageChoice.aggregate([auto("ko"), auto("en")])
        let result = SubtitleLanguageRecommender.recommend(title: "아이유 (IU) - 좋은 날 MV", languages: groups)
        XCTAssertEqual(result.recommended?.languageCode, "ko")
    }

    func testRecommendationNotHardcoded() {
        // Same track set [ja, en, ko]; recommendation must switch with the title's script.
        let groups = SubtitleLanguageChoice.aggregate([auto("ja"), auto("en"), auto("ko")])
        let ja = SubtitleLanguageRecommender.recommend(title: "夜に駆ける 歌ってみた", languages: groups)
        let en = SubtitleLanguageRecommender.recommend(title: "How transformers actually work", languages: groups)
        let ko = SubtitleLanguageRecommender.recommend(title: "방탄소년단 라이브 무대", languages: groups)
        XCTAssertEqual(ja.recommended?.languageCode, "ja")
        XCTAssertEqual(en.recommended?.languageCode, "en")
        XCTAssertEqual(ko.recommended?.languageCode, "ko")
    }

    func testManualTrackPreferredOverAutoWhenScriptNeutral() {
        // Neutral/empty title: manual base score (100) beats auto (40).
        let groups = SubtitleLanguageChoice.aggregate([auto("en"), manual("fr")])
        let result = SubtitleLanguageRecommender.recommend(title: "12345", languages: groups)
        XCTAssertEqual(result.recommended?.languageCode, "fr")
    }

    func testEmptyLanguagesReturnsNilRecommendation() {
        let result = SubtitleLanguageRecommender.recommend(title: "anything", languages: [])
        XCTAssertNil(result.recommended)
        XCTAssertTrue(result.others.isEmpty)
    }

    // MARK: - Fixture contract (ARCH-3): scoring constants equal the shared cross-platform fixture.

    func testLanguageRecommenderConstantsMatchFixture() throws {
        let fixture = try loadFixtureSection("languageRecommender")
        func intValue(_ key: String) throws -> Int {
            try XCTUnwrap((fixture[key] as? NSNumber)?.intValue, "fixture missing \(key)")
        }
        func doubleValue(_ key: String) throws -> Double {
            try XCTUnwrap((fixture[key] as? NSNumber)?.doubleValue, "fixture missing \(key)")
        }
        XCTAssertEqual(SubtitleLanguageRecommender.manualTrackScore, try intValue("manualTrackScore"))
        XCTAssertEqual(SubtitleLanguageRecommender.autoTrackScore, try intValue("autoTrackScore"))
        XCTAssertEqual(SubtitleLanguageRecommender.localASROnlyScore, try intValue("localASROnlyScore"))
        XCTAssertEqual(SubtitleLanguageRecommender.japaneseScriptBonus, try intValue("japaneseScriptBonus"))
        XCTAssertEqual(SubtitleLanguageRecommender.koreanScriptBonus, try intValue("koreanScriptBonus"))
        XCTAssertEqual(SubtitleLanguageRecommender.latinScriptBonus, try intValue("latinScriptBonus"))
        XCTAssertEqual(SubtitleLanguageRecommender.cjkPresenceBonus, try intValue("cjkPresenceBonus"))
        XCTAssertEqual(SubtitleLanguageRecommender.platformAutoCJKPresenceBonus, try intValue("platformAutoCJKPresenceBonus"))
        XCTAssertEqual(SubtitleLanguageRecommender.titleLanguageHintBonus, try intValue("titleLanguageHintBonus"))
        XCTAssertEqual(SubtitleLanguageRecommender.titleScriptDominanceRatio, try doubleValue("titleScriptDominanceRatio"))
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
