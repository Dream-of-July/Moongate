import XCTest
@testable import MoongateCore

final class SubtitleTimingHealthTests: XCTestCase {
    func testLooksUnreliableThreshold() {
        // >= 20% flash cues with enough cues -> unreliable.
        XCTAssertTrue(SubtitleTimingHealth.Assessment(cueCount: 10, flashCueCount: 3).looksUnreliable)
        // < 20% flash -> reliable.
        XCTAssertFalse(SubtitleTimingHealth.Assessment(cueCount: 10, flashCueCount: 1).looksUnreliable)
        // Too few cues to judge.
        XCTAssertFalse(SubtitleTimingHealth.Assessment(cueCount: 5, flashCueCount: 5).looksUnreliable)
    }

    func testWellTimedSubtitleLooksReliable() {
        // Normal 2s cues must never be flagged (no false positives on good subtitles).
        var srt = ""
        for i in 1...12 {
            let start = String(format: "00:00:%02d,000", i * 3)
            let end = String(format: "00:00:%02d,000", i * 3 + 2)
            srt += "\(i)\n\(start) --> \(end)\nThis is line number \(i).\n\n"
        }
        XCTAssertFalse(SubtitleTimingHealth.assess(rawSubtitle: srt, isVTT: false).looksUnreliable)
    }
}
