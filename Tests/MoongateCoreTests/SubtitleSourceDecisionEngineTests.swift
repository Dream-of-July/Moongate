import XCTest
@testable import MoongateCore

final class SubtitleSourceDecisionEngineTests: XCTestCase {

    // MARK: - Helpers

    private func assessment(
        id: String = "c",
        kind: SubtitleSourceKind,
        score: Double,
        gateUsable: Bool,
        verdict: SubtitleQualityVerdict,
        hasFile: Bool = true
    ) -> SubtitleSourceDecisionEngine.Assessment {
        SubtitleSourceDecisionEngine.Assessment(
            candidateID: id,
            kind: kind,
            languageCode: "ja",
            score: score,
            verdict: verdict,
            gateUsable: gateUsable,
            gateReasons: gateUsable ? [] : [.tooFewCues],
            reasons: [],
            report: nil,
            hasFile: hasFile
        )
    }

    // MARK: - generationPlan: gate-only, no conflation

    func testAutoBestKeepsHealthyPlatformWithoutGenerating() {
        let platform = assessment(kind: .platformAuto, score: 75, gateUsable: true, verdict: .good)
        let plan = SubtitleSourceDecisionEngine.generationPlan(
            policy: .autoBest, platform: platform, localASRAvailable: true, cloudASRAvailable: true)
        XCTAssertEqual(plan, .none)
    }

    func testAutoBestRegeneratesWhenGateUnusableAndLocalAvailable() {
        let platform = assessment(kind: .platformAuto, score: 30, gateUsable: false, verdict: .unusable)
        let plan = SubtitleSourceDecisionEngine.generationPlan(
            policy: .autoBest, platform: platform, localASRAvailable: true, cloudASRAvailable: false)
        XCTAssertEqual(plan, .generateLocalASRThenChoose)
    }

    func testAutoBestKeepsPlatformWithReasonsWhenGateUnusableButNoGenerator() {
        let platform = assessment(kind: .platformAuto, score: 30, gateUsable: false, verdict: .unusable)
        let plan = SubtitleSourceDecisionEngine.generationPlan(
            policy: .autoBest, platform: platform, localASRAvailable: false, cloudASRAvailable: false)
        XCTAssertEqual(plan, .keepPlatformRecordReasons([.tooFewCues]))
    }

    /// 质量地板：门 usable 但 verdict 低于 usable(lowConfidence) 时仍重生成——行为与旧
    /// `|| score <= .lowConfidence` 一致，但现在是单类型、具名、可测，不再混 OR。
    func testAutoBestRegeneratesWhenGateUsableButVerdictBelowFloor() {
        let platform = assessment(kind: .platformAuto, score: 45, gateUsable: true, verdict: .lowConfidence)
        let plan = SubtitleSourceDecisionEngine.generationPlan(
            policy: .autoBest, platform: platform, localASRAvailable: true, cloudASRAvailable: false)
        XCTAssertEqual(plan, .generateLocalASRThenChoose)
    }

    /// 反例：门 usable 且 verdict 达 usable → 不生成（不会因 sub-fatal 噪声白跑 Whisper）。
    func testAutoBestDoesNotRegenerateWhenUsableVerdict() {
        let platform = assessment(kind: .platformAuto, score: 60, gateUsable: true, verdict: .usable)
        let plan = SubtitleSourceDecisionEngine.generationPlan(
            policy: .autoBest, platform: platform, localASRAvailable: true, cloudASRAvailable: false)
        XCTAssertEqual(plan, .none)
    }

    func testPlatformPoliciesNeverGenerate() {
        let platform = assessment(kind: .platformAuto, score: 30, gateUsable: false, verdict: .unusable)
        for policy in [SubtitleSourcePolicy.forcePlatform, .preferPlatform, .cloudASR, .importedFile] {
            let plan = SubtitleSourceDecisionEngine.generationPlan(
                policy: policy, platform: platform, localASRAvailable: true, cloudASRAvailable: true)
            XCTAssertEqual(plan, .none, "\(policy) should never generate local ASR")
        }
    }

    func testForceLocalASRAlwaysGenerates() {
        let platform = assessment(kind: .platformAuto, score: 90, gateUsable: true, verdict: .excellent)
        let plan = SubtitleSourceDecisionEngine.generationPlan(
            policy: .forceLocalASR, platform: platform, localASRAvailable: true, cloudASRAvailable: false)
        XCTAssertEqual(plan, .generateLocalASRThenChoose)
    }

    func testPreferLocalASRGeneratesOnlyWhenPlatformUnusable() {
        let healthy = assessment(kind: .platformAuto, score: 80, gateUsable: true, verdict: .good)
        XCTAssertEqual(
            SubtitleSourceDecisionEngine.generationPlan(
                policy: .preferLocalASR, platform: healthy, localASRAvailable: true, cloudASRAvailable: false),
            .none)
        let bad = assessment(kind: .platformAuto, score: 30, gateUsable: false, verdict: .unusable)
        XCTAssertEqual(
            SubtitleSourceDecisionEngine.generationPlan(
                policy: .preferLocalASR, platform: bad, localASRAvailable: true, cloudASRAvailable: false),
            .generateLocalASRThenChoose)
    }

    // MARK: - post-generation local ASR escalation

    func testAutoBestEscalatesGeneratedLocalASRWhenLocalAssessmentBelowUsable() {
        let local = assessment(kind: .localASR, score: 40, gateUsable: false, verdict: .lowConfidence)

        XCTAssertTrue(SubtitleSourceDecisionEngine.shouldEscalateGeneratedLocalASR(
            policy: .autoBest,
            localAssessment: local,
            localASRConfidenceIsLowQuality: false,
            cloudASRAvailable: true))
    }

    func testAutoBestEscalatesGeneratedLocalASRWhenConfidenceIsLowQuality() {
        let local = assessment(kind: .localASR, score: 80, gateUsable: true, verdict: .good)

        XCTAssertTrue(SubtitleSourceDecisionEngine.shouldEscalateGeneratedLocalASR(
            policy: .autoBest,
            localAssessment: local,
            localASRConfidenceIsLowQuality: true,
            cloudASRAvailable: true))
    }

    func testAutoBestEscalatesGeneratedLocalASRWhenScoredSubtitleContentFallsBelowUsable() throws {
        let url = try writeTimedSRT(
            name: "local-asr.ja.srt",
            cues: (0..<12).map { index in
                ("作詞・作曲・編曲 初音ミク \(index)", Double(index) * 14.0, Double(index) * 14.0 + 13.0)
            })
        let local = SubtitleSourceDecisionEngine.assess(
            candidate: SubtitleSourceCandidate(id: "l", kind: .localASR, languageCode: "ja", displayName: "L",
                                               fileURL: url, isGenerated: true, provider: "whisper.cpp"),
            requestedSourceLanguageCode: "ja", videoDurationSeconds: nil)

        XCTAssertLessThan(local.verdict, .usable)
        XCTAssertTrue(SubtitleSourceDecisionEngine.shouldEscalateGeneratedLocalASR(
            policy: .autoBest,
            localAssessment: local,
            localASRConfidenceIsLowQuality: false,
            cloudASRAvailable: true))
    }

    func testGeneratedLocalASREscalationRespectsPolicyAndCloudAvailability() {
        let lowQualityLocal = assessment(kind: .localASR, score: 40, gateUsable: false, verdict: .lowConfidence)

        XCTAssertFalse(SubtitleSourceDecisionEngine.shouldEscalateGeneratedLocalASR(
            policy: .preferLocalASR,
            localAssessment: lowQualityLocal,
            localASRConfidenceIsLowQuality: true,
            cloudASRAvailable: true))
        XCTAssertFalse(SubtitleSourceDecisionEngine.shouldEscalateGeneratedLocalASR(
            policy: .autoBest,
            localAssessment: lowQualityLocal,
            localASRConfidenceIsLowQuality: true,
            cloudASRAvailable: false))
    }

    func testGeneratedLocalASRDoesNotEscalateHealthyLocalResult() {
        let healthyLocal = assessment(kind: .localASR, score: 80, gateUsable: true, verdict: .good)

        XCTAssertFalse(SubtitleSourceDecisionEngine.shouldEscalateGeneratedLocalASR(
            policy: .autoBest,
            localAssessment: healthyLocal,
            localASRConfidenceIsLowQuality: false,
            cloudASRAvailable: true))
    }

    // MARK: - choose: tie-break prefers more-trusted source

    func testChooseTieBreakPrefersLowerSourceKindRank() {
        let manual = assessment(id: "m", kind: .manual, score: 70, gateUsable: true, verdict: .good)
        let local = assessment(id: "l", kind: .localASR, score: 70, gateUsable: true, verdict: .good)
        let winner = SubtitleSourceDecisionEngine.choose(
            policy: .autoBest, assessments: [manual, local], selectableIDs: ["m", "l"])
        XCTAssertEqual(winner, "m")
        // 顺序无关
        let winner2 = SubtitleSourceDecisionEngine.choose(
            policy: .autoBest, assessments: [local, manual], selectableIDs: ["m", "l"])
        XCTAssertEqual(winner2, "m")
    }

    func testChooseAutoBestPicksHigherScore() {
        let manual = assessment(id: "m", kind: .manual, score: 60, gateUsable: true, verdict: .usable)
        let local = assessment(id: "l", kind: .localASR, score: 80, gateUsable: true, verdict: .good)
        let winner = SubtitleSourceDecisionEngine.choose(
            policy: .autoBest, assessments: [manual, local], selectableIDs: ["m", "l"])
        XCTAssertEqual(winner, "l")
    }

    func testChooseForcePlatformPicksPlatformEvenWhenLocalScoresHigher() {
        let platform = assessment(id: "p", kind: .platformAuto, score: 55, gateUsable: true, verdict: .usable)
        let local = assessment(id: "l", kind: .localASR, score: 95, gateUsable: true, verdict: .excellent)
        let winner = SubtitleSourceDecisionEngine.choose(
            policy: .forcePlatform, assessments: [platform, local], selectableIDs: ["p", "l"])
        XCTAssertEqual(winner, "p")
    }

    func testChooseSkipsNonSelectableCandidates() {
        let pending = assessment(id: "pending", kind: .localASR, score: 0, gateUsable: false, verdict: .unusable, hasFile: false)
        let platform = assessment(id: "p", kind: .platformAuto, score: 60, gateUsable: true, verdict: .usable)
        let winner = SubtitleSourceDecisionEngine.choose(
            policy: .autoBest, assessments: [pending, platform], selectableIDs: ["p"])
        XCTAssertEqual(winner, "p")
    }

    // MARK: - assess: one gate run, authoritative gateUsable

    func testAssessHealthyJapaneseIsGateUsable() throws {
        let url = try writeSRT(name: "local-asr.ja.srt", texts: [
            "今日は楽しいお祭りの日です", "みんなでチョコバナナを食べよう", "ソースせんべいも買ってきたよ",
            "お風呂はとても気持ちいいね", "ありがとうと言われるとうれしい", "風が涼しくて気持ちいい",
            "友だちと一緒に歩いている", "次はくじ引きをやってみよう", "小さな声でもちゃんと聞こえる", "また明日も遊びに来よう",
        ])
        let assessment = SubtitleSourceDecisionEngine.assess(
            candidate: SubtitleSourceCandidate(id: "l", kind: .localASR, languageCode: "ja", displayName: "L",
                                               fileURL: url, isGenerated: true, provider: "whisper.cpp"),
            requestedSourceLanguageCode: "ja", videoDurationSeconds: nil)
        XCTAssertTrue(assessment.gateUsable)
        XCTAssertTrue(assessment.gateReasons.isEmpty)
        XCTAssertGreaterThanOrEqual(assessment.verdict, .usable)
    }

    func testAssessTooFewCuesIsGateUnusable() throws {
        let url = try writeSRT(name: "auto.ja.srt", texts: ["短い", "字幕", "です"])
        let assessment = SubtitleSourceDecisionEngine.assess(
            candidate: SubtitleSourceCandidate(id: "p", kind: .platformAuto, languageCode: "ja", displayName: "P",
                                               fileURL: url, isGenerated: true, provider: "yt-dlp"),
            requestedSourceLanguageCode: "ja", videoDurationSeconds: nil)
        XCTAssertFalse(assessment.gateUsable)
        XCTAssertTrue(assessment.gateReasons.contains(.tooFewCues))
        // 不变式：gate 不可用 ⇒ verdict <= lowConfidence
        XCTAssertLessThanOrEqual(assessment.verdict, .lowConfidence)
    }

    func testAssessMissingFileIsGateUnusable() {
        let assessment = SubtitleSourceDecisionEngine.assess(
            candidate: SubtitleSourceCandidate(id: "pending", kind: .localASR, languageCode: "ja", displayName: "L",
                                               fileURL: nil, isGenerated: false, provider: "whisper.cpp"),
            requestedSourceLanguageCode: "ja", videoDurationSeconds: nil)
        XCTAssertFalse(assessment.gateUsable)
        XCTAssertFalse(assessment.hasFile)
    }

    func testEngineConstantsMatchCrossPlatformFixture() throws {
        let fixture = try loadFixtureSection("subtitleSourceDecision")
        func section(_ key: String) throws -> [String: Any] {
            try XCTUnwrap(fixture[key] as? [String: Any], "fixture missing \(key)")
        }
        // baseScore（来源先验，真值在 SubtitleQualityScorer）
        let base = try section("baseScore")
        let baseExpect: [(SubtitleSourceKind, String)] = [
            (.manual, "manual"), (.importedFile, "importedFile"), (.hlsManifest, "hlsManifest"),
            (.cloudASR, "cloudASR"), (.platformAuto, "platformAuto"), (.localASR, "localASR"),
        ]
        for (kind, key) in baseExpect {
            let want = try XCTUnwrap((base[key] as? NSNumber)?.doubleValue, "baseScore.\(key)")
            XCTAssertEqual(SubtitleQualityScorer.baseScore(for: kind), want, "baseScore.\(key)")
        }
        // sourceKindRank（tie-break 顺序，真值在引擎）
        let rank = try section("sourceKindRank")
        for (kind, key) in baseExpect {
            let want = try XCTUnwrap((rank[key] as? NSNumber)?.intValue, "sourceKindRank.\(key)")
            XCTAssertEqual(SubtitleSourceDecisionEngine.sourceKindRank(kind), want, "sourceKindRank.\(key)")
        }
        // policyBoost：prefer / force
        let boost = try section("policyBoost")
        let preferWant = try XCTUnwrap((boost["prefer"] as? NSNumber)?.doubleValue)
        let forceWant = try XCTUnwrap((boost["force"] as? NSNumber)?.doubleValue)
        XCTAssertEqual(SubtitleSourceDecisionEngine.policyBoost(.platformAuto, .preferPlatform), preferWant)
        XCTAssertEqual(SubtitleSourceDecisionEngine.policyBoost(.localASR, .preferLocalASR), preferWant)
        XCTAssertEqual(SubtitleSourceDecisionEngine.policyBoost(.localASR, .forceLocalASR), forceWant)
        // verdictThresholds
        let vt = try section("verdictThresholds")
        XCTAssertEqual(SubtitleQualityScorer.verdictThresholds.excellent, try XCTUnwrap((vt["excellent"] as? NSNumber)?.doubleValue))
        XCTAssertEqual(SubtitleQualityScorer.verdictThresholds.good, try XCTUnwrap((vt["good"] as? NSNumber)?.doubleValue))
        XCTAssertEqual(SubtitleQualityScorer.verdictThresholds.usable, try XCTUnwrap((vt["usable"] as? NSNumber)?.doubleValue))
        XCTAssertEqual(SubtitleQualityScorer.verdictThresholds.lowConfidence, try XCTUnwrap((vt["lowConfidence"] as? NSNumber)?.doubleValue))
        // autoBestRegenerateBelow
        XCTAssertEqual(fixture["autoBestRegenerateBelow"] as? String, SubtitleSourceDecisionEngine.autoBestRegenerateBelow.rawValue)
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

    // MARK: - SRT helper

    private func writeSRT(name: String, texts: [String]) throws -> URL {
        try writeTimedSRT(
            name: name,
            cues: texts.enumerated().map { index, text in
                (text, Double(index) * 2.0, Double(index) * 2.0 + 1.5)
            })
    }

    private func writeTimedSRT(name: String, cues: [(String, Double, Double)]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("moongate-engine-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        let body = cues.enumerated().map { index, cue in
            "\(index + 1)\n\(timestamp(cue.1)) --> \(timestamp(cue.2))\n\(cue.0)"
        }.joined(separator: "\n\n")
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func timestamp(_ seconds: Double) -> String {
        let totalMs = Int((seconds * 1000).rounded())
        return String(
            format: "%02d:%02d:%02d,%03d",
            totalMs / 3_600_000,
            (totalMs % 3_600_000) / 60_000,
            (totalMs % 60_000) / 1000,
            totalMs % 1000)
    }
}
