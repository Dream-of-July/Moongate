@testable import MoongateCore
import XCTest

final class SubtitleTimingPlannerTests: XCTestCase {
    func testSpeechAlignedVisibleSecondsKeepsShortFeedbackBrief() {
        XCTAssertEqual(SubtitleTimingPlanner.speechAlignedVisibleSeconds("Copy.", endsSentence: true), 2.0)
        XCTAssertEqual(SubtitleTimingPlanner.speechAlignedVisibleSeconds("What heat?", endsSentence: true), 2.0)
    }

    func testSpeechAlignedVisibleSecondsExtendsShortEmphaticLines() {
        XCTAssertEqual(SubtitleTimingPlanner.speechAlignedVisibleSeconds("10,000 hours!", endsSentence: true), 2.45)
        XCTAssertEqual(SubtitleTimingPlanner.speechAlignedVisibleSeconds("No!!", endsSentence: true), 2.45)
        XCTAssertEqual(SubtitleTimingPlanner.speechAlignedVisibleSeconds("Ever again.", endsSentence: true), 2.45)
        XCTAssertEqual(SubtitleTimingPlanner.speechAlignedVisibleSeconds("like around week eight,", endsSentence: false), 1.92)
    }

    func testSpeechAlignedVisibleSecondsScalesLongSpeechWithoutDragging() {
        let duration = SubtitleTimingPlanner.speechAlignedVisibleSeconds(
            "This is a longer spoken sentence that should stay readable without lingering too long.",
            endsSentence: true
        )

        XCTAssertGreaterThan(duration, 4.0)
        XCTAssertLessThanOrEqual(duration, 9.0)
    }

    func testWeakSemanticBoundaryDetectsBadEnglishSplits() {
        XCTAssertTrue(SubtitleTimingPlanner.isWeakBoundary(leftToken: "the", rightToken: "ship"))
        XCTAssertTrue(SubtitleTimingPlanner.isWeakBoundary(leftToken: "moon", rightToken: "and"))
        XCTAssertFalse(SubtitleTimingPlanner.isWeakBoundary(leftToken: "moon.", rightToken: "Next"))
    }

    func testWeakSemanticBoundaryDetectsRomanceLanguageSplits() {
        XCTAssertTrue(SubtitleTimingPlanner.isWeakBoundary(leftToken: "tono", rightToken: "de"))
        XCTAssertTrue(SubtitleTimingPlanner.isWeakBoundary(leftToken: "de", rightToken: "ponerte"))
        XCTAssertTrue(SubtitleTimingPlanner.isWeakBoundary(leftToken: "des", rightToken: "chaussures"))
        XCTAssertTrue(SubtitleTimingPlanner.isWeakBoundary(leftToken: "di", rightToken: "fronte"))
        XCTAssertTrue(SubtitleTimingPlanner.isWeakBoundary(leftToken: "muchas", rightToken: "veces"))
        XCTAssertTrue(SubtitleTimingPlanner.isWeakBoundary(leftToken: "no", rightToken: "hacen"))
    }

    func testTokenizersHandleLatinAndCJKText() {
        XCTAssertEqual(SubtitleTimingPlanner.wordTokens("Hello, Starship!"), ["hello", "starship"])
        XCTAssertEqual(SubtitleTimingPlanner.speechTokens("Copy. 10 engines?"), ["copy", "10", "engines"])
        XCTAssertEqual(
            SubtitleTimingPlanner.speechTokens("Sì, può iniziare questa settimana?"),
            ["sì", "può", "iniziare", "questa", "settimana"]
        )
        XCTAssertEqual(SubtitleTimingPlanner.timingTokens("3 € 4,99€."), ["3", "€", "4", "99", "€"])
        XCTAssertEqual(SubtitleTimingPlanner.speechTokens("今天我们继续"), [])
        XCTAssertEqual(SubtitleTimingPlanner.speechTokens("내가 서 있는 곳"), [])
        XCTAssertEqual(SubtitleTimingPlanner.visibleCharacters("你 好 world"), 7)
    }
}
