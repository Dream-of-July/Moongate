import XCTest
@testable import MoongateCore

final class SubtitleSourceResolverTests: XCTestCase {
    func testSubtitleIntentSeparatesOutputIntentFromSourceNeed() {
        XCTAssertFalse(SubtitleIntent.none.needsSubtitleSource)
        XCTAssertFalse(SubtitleIntent.none.requiresTranslation)
        XCTAssertFalse(SubtitleIntent.none.requiresBurnIn)

        XCTAssertTrue(SubtitleIntent.sourceSRT.needsSubtitleSource)
        XCTAssertFalse(SubtitleIntent.sourceSRT.requiresTranslation)
        XCTAssertFalse(SubtitleIntent.sourceSRT.requiresBurnIn)

        XCTAssertTrue(SubtitleIntent.translatedSRT.needsSubtitleSource)
        XCTAssertTrue(SubtitleIntent.translatedSRT.requiresTranslation)
        XCTAssertFalse(SubtitleIntent.translatedSRT.requiresBurnIn)

        XCTAssertTrue(SubtitleIntent.burnTranslated.needsSubtitleSource)
        XCTAssertTrue(SubtitleIntent.burnTranslated.requiresTranslation)
        XCTAssertTrue(SubtitleIntent.burnTranslated.requiresBurnIn)

        XCTAssertTrue(SubtitleIntent.burnSource.needsSubtitleSource)
        XCTAssertFalse(SubtitleIntent.burnSource.requiresTranslation)
        XCTAssertTrue(SubtitleIntent.burnSource.requiresBurnIn)
    }

    func testQualityScorerPenalizesCJKShortCueFragmentationWithoutHardcodedPhrases() throws {
        let source = try writeSRT(
            name: "koopenchan.local-asr.ja.srt",
            texts: [
                "お招きありがとう",
                "世界の銀行が崩れた",
                "冥府より現れしいお酒",
                "偉いドクネストレード",
                "チョコナナナ",
                "くじ引き野郎",
                "いいお湯なんだよ",
                "ソスせんべい",
                "僕はパタパタするよ滅びの",
                "風をくらえ",
                "あいい行く"
            ]
        )
        let candidate = SubtitleSourceCandidate(
            id: "local-ja",
            kind: .localASR,
            languageCode: "ja",
            displayName: "Local Japanese",
            fileURL: source,
            isGenerated: true,
            provider: "whisper.cpp"
        )

        let score = SubtitleQualityScorer.score(
            candidate: candidate,
            requestedSourceLanguageCode: "ja",
            videoDurationSeconds: nil
        )

        XCTAssertLessThanOrEqual(score.verdict, .lowConfidence)
        XCTAssertTrue(score.reasons.contains("shortCueFragmentation"))
    }

    func testNilLocalASRCandidateIsNotUsable() {
        let score = SubtitleQualityScorer.score(
            candidate: SubtitleSourceCandidate(
                id: "pending-local",
                kind: .localASR,
                languageCode: "en",
                displayName: "Local recognition",
                fileURL: nil,
                isGenerated: false,
                provider: "whisper.cpp"
            ),
            requestedSourceLanguageCode: "en",
            videoDurationSeconds: nil
        )

        XCTAssertEqual(score.score, 0)
        XCTAssertEqual(score.verdict, .unusable)
        XCTAssertTrue(score.reasons.contains("pendingGeneration"))
        XCTAssertFalse(score.reasons.contains("notGeneratedYet"))
    }

    func testResolverNeverReturnsEmptySelectedFileForMissingCandidate() {
        let resolved = SubtitleSourceResolver.resolve(SubtitleResolutionRequest(
            languageIntent: .language("en"),
            sourcePolicy: .autoBest,
            candidates: [
                SubtitleSourceCandidate(
                    id: "pending-local",
                    kind: .localASR,
                    languageCode: "en",
                    displayName: "Local recognition",
                    fileURL: nil,
                    isGenerated: false,
                    provider: "whisper.cpp"
                )
            ],
            videoDurationSeconds: nil
        ))

        XCTAssertNil(resolved)
    }

    func testProductionScorerDoesNotHardcodeObservedBadSamplePhrases() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/MoongateCore/SubtitleQualityScorer.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        for phrase in ["世界の銀行が崩れた", "冥府より現れしいお酒", "偉いドクネストレード", "チョコナナナ", "ソスせんべい", "くじ引き野郎", "あいい行く"] {
            XCTAssertFalse(source.contains(phrase), "Production scorer must use generic metrics, not hardcode \(phrase)")
        }
    }

    func testLocalASRDetectsShortCueFragmentation() throws {
        let source = try writeSRT(
            name: "koopenchan.fragments.local-asr.ja.srt",
            texts: [
                "コーペンジャオ",
                "ん",
                "くんくんくんわ",
                "あいい行く",
                "チョコナナナ",
                "ソスせんべい",
                "くじ引き野郎",
                "あ",
                "え",
                "う"
            ]
        )
        let candidate = SubtitleSourceCandidate(
            id: "fragmented-local-ja",
            kind: .localASR,
            languageCode: "ja",
            displayName: "Fragmented local Japanese",
            fileURL: source,
            isGenerated: true,
            provider: "whisper.cpp"
        )

        let score = SubtitleQualityScorer.score(
            candidate: candidate,
            requestedSourceLanguageCode: "ja",
            videoDurationSeconds: 120
        )

        XCTAssertLessThanOrEqual(score.verdict, .lowConfidence)
        XCTAssertTrue(score.reasons.contains("shortCueFragmentation"))
    }

    func testLocalASRDetectsLongCJKShortCueHolds() throws {
        let source = try writeSRT(name: "blackpink.long-hold.local-asr.ko.srt", cues: [
            cue(start: 1.91, end: 5.06, text: "착"),
            cue(start: 5.34, end: 10.16, text: "한"),
            cue(start: 10.44, end: 12.10, text: "얼굴에"),
            cue(start: 12.50, end: 14.00, text: "그렇지 못한대도"),
            cue(start: 14.20, end: 15.70, text: "volume은 두 배로"),
            cue(start: 16.00, end: 17.50, text: "거침없이 직진"),
            cue(start: 17.80, end: 19.30, text: "나는 믿고 있어"),
            cue(start: 19.60, end: 21.10, text: "지금 이 순간")
        ])
        let candidate = SubtitleSourceCandidate(
            id: "local-ko",
            kind: .localASR,
            languageCode: "ko",
            displayName: "Local Korean",
            fileURL: source,
            isGenerated: true,
            provider: "whisper.cpp"
        )

        let score = SubtitleQualityScorer.score(
            candidate: candidate,
            requestedSourceLanguageCode: "ko",
            videoDurationSeconds: nil
        )

        XCTAssertLessThanOrEqual(score.verdict, .lowConfidence)
        XCTAssertTrue(score.reasons.contains("longShortCueHold"))
    }

    func testQualityScorerPenalizesSoundEffectDominatedAndLongCueSources() throws {
        let source = try writeSRT(name: "video.auto.ja.srt", cues: [
            cue(start: 0, end: 13, text: "今日はとても長い説明がそのまま一つの字幕に詰め込まれています"),
            cue(start: 14, end: 28, text: "次の字幕も長すぎて読み切れないまま画面に残り続けます"),
            cue(start: 30, end: 32, text: "[音楽]"),
            cue(start: 33, end: 35, text: "[音楽]"),
            cue(start: 36, end: 38, text: "[拍手]"),
            cue(start: 39, end: 41, text: "[音楽]"),
            cue(start: 42, end: 44, text: "チョコナナナ"),
            cue(start: 45, end: 47, text: "くじ引き野郎"),
            cue(start: 48, end: 50, text: "偉いドクネストレード"),
            cue(start: 51, end: 53, text: "冥府より現れしいお酒")
        ])
        let candidate = candidate(id: "auto-ja", kind: .platformAuto, fileURL: source, isGenerated: true)

        let score = SubtitleQualityScorer.score(
            candidate: candidate,
            requestedSourceLanguageCode: "ja",
            videoDurationSeconds: 180
        )

        XCTAssertLessThanOrEqual(score.verdict, .lowConfidence)
        XCTAssertTrue(score.reasons.contains("garbledOrRepetitive"))
        XCTAssertTrue(score.reasons.contains("lowCoverage"))
        let report = try XCTUnwrap(score.report)
        XCTAssertGreaterThanOrEqual(report.longCueCount, 2)
        XCTAssertGreaterThanOrEqual(report.soundEffectCueCount, 4)
    }

    func testQualityScorerTreatsMostlyBlankCueFilesAsUnusable() throws {
        let source = try writeSRT(name: "video.blank.ja.srt", cues: [
            cue(start: 0, end: 10, text: "　"),
            cue(start: 12, end: 22, text: ""),
            cue(start: 24, end: 34, text: "\n"),
            cue(start: 40, end: 42, text: "顔"),
            cue(start: 50, end: 52, text: "手")
        ])
        let candidate = candidate(id: "auto-ja", kind: .platformAuto, fileURL: source, isGenerated: true)

        let score = SubtitleQualityScorer.score(
            candidate: candidate,
            requestedSourceLanguageCode: "ja",
            videoDurationSeconds: 120
        )

        XCTAssertEqual(score.verdict, .unusable)
        XCTAssertTrue(score.reasons.contains("tooFewCues"))
        XCTAssertTrue(score.reasons.contains("lowCoverage"))
    }

    func testResolverAutoBestPrefersManualSubtitleOverAutoAndLocalASR() throws {
        let manualFile = try writeSRT(name: "video.ja.srt", texts: healthyJapaneseTexts())
        let autoFile = try writeSRT(name: "video.auto.ja.srt", texts: healthyJapaneseTexts())
        let localFile = try writeSRT(name: "video.local-asr.ja.srt", texts: healthyJapaneseTexts())

        let candidates = [
            candidate(id: "auto-ja", kind: .platformAuto, fileURL: autoFile, isGenerated: true),
            candidate(id: "local-ja", kind: .localASR, fileURL: localFile, isGenerated: true),
            candidate(id: "manual-ja", kind: .manual, fileURL: manualFile, isGenerated: false),
        ]
        let resolved = try XCTUnwrap(SubtitleSourceResolver.resolve(SubtitleResolutionRequest(
            languageIntent: .language("ja"),
            sourcePolicy: .autoBest,
            candidates: candidates,
            videoDurationSeconds: nil
        )))

        XCTAssertEqual(resolved.selectedKind, .manual)
        XCTAssertEqual(resolved.selectedFile, manualFile)
        XCTAssertNotNil(resolved.sourceQualityVerdict)
        XCTAssertTrue(resolved.candidateReports.contains {
            $0.sourceKind == .manual && $0.selected && $0.usable && $0.qualityVerdict != nil
        })
    }

    func testResolverPolicyCanForcePlatformEvenWhenLocalASRScoresHigher() throws {
        let badAutoFile = try writeSRT(name: "video.auto.ja.srt", texts: [
            "[音楽]",
            "[拍手]",
            "世界の銀行が崩れた",
            "[音楽]",
            "冥府より現れしいお酒",
            "[拍手]",
            "チョコナナナ",
            "[音楽]",
            "くじ引き野郎",
            "[拍手]"
        ])
        let localFile = try writeSRT(name: "video.local-asr.ja.srt", texts: healthyJapaneseTexts())
        let candidates = [
            candidate(id: "auto-ja", kind: .platformAuto, fileURL: badAutoFile, isGenerated: true),
            candidate(id: "local-ja", kind: .localASR, fileURL: localFile, isGenerated: true),
        ]

        let automatic = try XCTUnwrap(SubtitleSourceResolver.resolve(SubtitleResolutionRequest(
            languageIntent: .language("ja"),
            sourcePolicy: .autoBest,
            candidates: candidates,
            videoDurationSeconds: nil
        )))
        let forced = try XCTUnwrap(SubtitleSourceResolver.resolve(SubtitleResolutionRequest(
            languageIntent: .language("ja"),
            sourcePolicy: .forcePlatform,
            candidates: candidates,
            videoDurationSeconds: nil
        )))

        XCTAssertEqual(automatic.selectedKind, .localASR)
        XCTAssertEqual(forced.selectedKind, .platformAuto)
        XCTAssertLessThanOrEqual(try XCTUnwrap(forced.sourceQualityVerdict), .lowConfidence)
        XCTAssertTrue(forced.candidateReports.contains {
            $0.sourceKind == .platformAuto && $0.selected && !$0.usable
        })
    }

    func testPlatformAutoWithManySoundEffectCuesFallsBackToASR() throws {
        let badAutoFile = try writeSRT(name: "video.auto.ja.srt", cues: [
            cue(start: 0, end: 2, text: "[音楽]"),
            cue(start: 3, end: 5, text: "[拍手]"),
            cue(start: 6, end: 8, text: "[音楽]"),
            cue(start: 9, end: 11, text: "[笑い]"),
            cue(start: 12, end: 14, text: "チョコナナナ"),
            cue(start: 15, end: 17, text: "世界の銀行が崩れた"),
            cue(start: 18, end: 20, text: "[音楽]"),
            cue(start: 21, end: 23, text: "冥府より現れしいお酒")
        ])
        let localFile = try writeSRT(name: "video.local-asr.ja.srt", texts: healthyJapaneseTexts())

        let resolved = try XCTUnwrap(SubtitleSourceResolver.resolve(SubtitleResolutionRequest(
            languageIntent: .language("ja"),
            sourcePolicy: .autoBest,
            candidates: [
                candidate(id: "auto-ja", kind: .platformAuto, fileURL: badAutoFile, isGenerated: true),
                candidate(id: "local-ja", kind: .localASR, fileURL: localFile, isGenerated: true),
            ],
            videoDurationSeconds: 180
        )))

        XCTAssertEqual(resolved.selectedKind, .localASR)
        XCTAssertTrue(resolved.usedLocalASRFallback)
        XCTAssertTrue(resolved.candidateReports.contains {
            $0.sourceKind == .platformAuto
                && !$0.usable
                && $0.reasons.contains("garbledOrRepetitive")
        })
    }

    func testResolverCanScoreCloudASRCandidateWithoutExposingUIPolicy() throws {
        let localFile = try writeSRT(name: "video.local-asr.ja.srt", texts: healthyJapaneseTexts())
        let cloudFile = try writeSRT(name: "video.cloud-asr.ja.srt", texts: healthyJapaneseTexts())
        let candidates = [
            candidate(id: "local-ja", kind: .localASR, fileURL: localFile, isGenerated: true),
            candidate(id: "cloud-ja", kind: .cloudASR, fileURL: cloudFile, isGenerated: true),
        ]

        let resolved = try XCTUnwrap(SubtitleSourceResolver.resolve(SubtitleResolutionRequest(
            languageIntent: .language("ja"),
            sourcePolicy: .autoBest,
            candidates: candidates,
            videoDurationSeconds: nil
        )))

        XCTAssertEqual(resolved.selectedKind, .cloudASR)
        XCTAssertTrue(resolved.candidateReports.contains {
            $0.sourceKind == .cloudASR && $0.selected && $0.usable
        })
    }

    func testCloudASRPolicySelectsOnlyCloudCandidate() throws {
        let platformFile = try writeSRT(name: "video.auto.ja.srt", texts: healthyJapaneseTexts())
        let cloudFile = try writeSRT(name: "video.cloud-policy.ja.srt", texts: healthyJapaneseTexts())

        let resolved = try XCTUnwrap(SubtitleSourceResolver.resolve(SubtitleResolutionRequest(
            languageIntent: .language("ja"),
            sourcePolicy: .cloudASR,
            candidates: [
                candidate(id: "platform-ja", kind: .platformAuto, fileURL: platformFile, isGenerated: true),
                candidate(id: "cloud-ja", kind: .cloudASR, fileURL: cloudFile, isGenerated: true),
            ],
            videoDurationSeconds: nil
        )))

        XCTAssertEqual(resolved.selectedKind, .cloudASR)
        XCTAssertEqual(resolved.selectedFile, cloudFile)
    }

    func testResolverReportsLowConfidenceWhenAllCandidatesAreBad() throws {
        let autoFile = try writeSRT(name: "video.auto.ja.srt", texts: [
            "[音楽]",
            "世界の銀行が崩れた",
            "[拍手]",
            "冥府より現れしいお酒",
            "チョコナナナ",
            "くじ引き野郎",
            "偉いドクネストレード",
            "[音楽]",
            "あいい行く",
            "[拍手]"
        ])
        let localFile = try writeSRT(name: "video.local-asr.ja.srt", texts: [
            "コーペンジャオ",
            "ん",
            "くんくんくんわ",
            "あいい行く",
            "チョコナナナ",
            "ソスせんべい",
            "くじ引き野郎",
            "世界の銀行が崩れた",
            "冥府より現れしいお酒",
            "偉いドクネストレード"
        ])
        let resolved = try XCTUnwrap(SubtitleSourceResolver.resolve(SubtitleResolutionRequest(
            languageIntent: .language("ja"),
            sourcePolicy: .autoBest,
            candidates: [
                candidate(id: "auto-ja", kind: .platformAuto, fileURL: autoFile, isGenerated: true),
                candidate(id: "local-ja", kind: .localASR, fileURL: localFile, isGenerated: true),
            ],
            videoDurationSeconds: 180
        )))

        XCTAssertLessThanOrEqual(try XCTUnwrap(resolved.sourceQualityVerdict), .lowConfidence)
        XCTAssertFalse(try XCTUnwrap(resolved.qualityVerdict).usable)
        XCTAssertEqual(resolved.candidateReports.count, 2)
        XCTAssertTrue(resolved.candidateReports.allSatisfy { !$0.usable })
        XCTAssertTrue(resolved.candidateReports.contains { $0.sourceKind == resolved.selectedKind && $0.selected })
    }

    private func candidate(
        id: String,
        kind: SubtitleSourceKind,
        fileURL: URL,
        isGenerated: Bool
    ) -> SubtitleSourceCandidate {
        SubtitleSourceCandidate(
            id: id,
            kind: kind,
            languageCode: "ja",
            displayName: id,
            fileURL: fileURL,
            isGenerated: isGenerated,
            provider: "test"
        )
    }

    private func healthyJapaneseTexts() -> [String] {
        [
            "今日は楽しいお祭りの日です",
            "みんなでチョコバナナを食べよう",
            "ソースせんべいも買ってきたよ",
            "お風呂はとても気持ちいいね",
            "ありがとうと言われるとうれしい",
            "風が涼しくて気持ちいい",
            "友だちと一緒に歩いている",
            "次はくじ引きをやってみよう",
            "小さな声でもちゃんと聞こえる",
            "また明日も遊びに来よう"
        ]
    }

    private func writeSRT(name: String, texts: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("moongate-subtitle-source-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        let body = texts.enumerated().map { index, text in
            let start = index * 2_000
            let end = start + 1_500
            return """
            \(index + 1)
            \(timestamp(start)) --> \(timestamp(end))
            \(text)
            """
        }.joined(separator: "\n\n")
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func timestamp(_ totalMs: Int) -> String {
        let h = totalMs / 3_600_000
        let m = (totalMs % 3_600_000) / 60_000
        let s = (totalMs % 60_000) / 1000
        let milli = totalMs % 1000
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, milli)
    }

    private struct TimedCue {
        let start: Double
        let end: Double
        let text: String
    }

    private func cue(start: Double, end: Double, text: String) -> TimedCue {
        TimedCue(start: start, end: end, text: text)
    }

    private func writeSRT(name: String, cues: [TimedCue]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("moongate-subtitle-source-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        let body = cues.enumerated().map { index, cue in
            """
            \(index + 1)
            \(timestamp(seconds: cue.start)) --> \(timestamp(seconds: cue.end))
            \(cue.text)
            """
        }.joined(separator: "\n\n")
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func timestamp(seconds: Double) -> String {
        timestamp(Int((seconds * 1000).rounded()))
    }
}
