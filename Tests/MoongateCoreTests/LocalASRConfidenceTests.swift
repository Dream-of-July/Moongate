import XCTest
@testable import MoongateCore

final class LocalASRConfidenceTests: XCTestCase {
    private func word(_ probability: Double?) -> ASRWord {
        ASRWord(text: "あ", startSeconds: 0, endSeconds: 0.1, probability: probability)
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
