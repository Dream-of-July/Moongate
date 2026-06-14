@testable import MoongateMobileCore
import XCTest

final class MobileSubtitleDocumentTests: XCTestCase {
    func testParsesSRTByTimeAnchorsAndKeepsMultilineText() {
        let raw = "\u{FEFF}1\r\n00:00:01.000 --> 00:00:02,500\r\nHello\r\n\r\ncontinued\r\n\r\n2\r\n00:00:03,000 --> 00:00:04,000\r\nNext line\r\n"

        let document = MobileSubtitleDocument.parseSRT(raw)

        XCTAssertEqual(document.cues.count, 2)
        XCTAssertEqual(document.cues[0].index, 1)
        XCTAssertEqual(document.cues[0].startTime, "00:00:01.000")
        XCTAssertEqual(document.cues[0].endTime, "00:00:02,500")
        XCTAssertEqual(document.cues[0].text, "Hello\ncontinued")
        XCTAssertEqual(document.cues[1].text, "Next line")
    }

    func testCleansRollingSubtitleWindowsBeforeBuildingTranslationRequest() {
        let document = MobileSubtitleDocument(cues: [
            MobileSubtitleCue(index: 1, startTime: "00:00:00,000", endTime: "00:00:02,000", text: "Hello"),
            MobileSubtitleCue(index: 2, startTime: "00:00:01,500", endTime: "00:00:03,000", text: "Hello\nworld."),
            MobileSubtitleCue(index: 3, startTime: "00:00:03,000", endTime: "00:00:04,000", text: "Next"),
            MobileSubtitleCue(index: 4, startTime: "00:00:04,000", endTime: "00:00:05,000", text: "Next\nline.")
        ])

        let cleaned = document.cleanedForTranslation()
        let request = cleaned.translationRequest(context: TranslationContext(sourceLanguage: "en", targetLanguage: "zh-Hans"))

        XCTAssertEqual(cleaned.cues.map(\.text), ["Hello world.", "Next line."])
        XCTAssertEqual(cleaned.cues.map(\.startTime), ["00:00:00,000", "00:00:03,000"])
        XCTAssertEqual(cleaned.cues.map(\.endTime), ["00:00:03,000", "00:00:05,000"])
        XCTAssertEqual(request.segments.map(\.id), ["1", "2"])
        XCTAssertEqual(request.segments.map(\.text), ["Hello world.", "Next line."])
        XCTAssertEqual(request.context.targetLanguage, "zh-Hans")
    }

    func testAppliesTranslatedSegmentsWithoutChangingTimelineAndSerializesSRT() {
        let source = MobileSubtitleDocument(cues: [
            MobileSubtitleCue(index: 1, startTime: "00:00:00,000", endTime: "00:00:03,000", text: "Hello world."),
            MobileSubtitleCue(index: 2, startTime: "00:00:03,000", endTime: "00:00:05,000", text: "Next line.")
        ])
        let translated = MobileTranslationResult(segments: [
            MobileTranslationSegment(id: "1", startTime: "ignored", endTime: "ignored", text: "你好，世界。"),
            MobileTranslationSegment(id: "2", startTime: "ignored", endTime: "ignored", text: "下一句。")
        ])

        let translatedOnly = source.applying(translated, style: .translatedOnly)
        let bilingual = source.applying(translated, style: .bilingual)

        XCTAssertEqual(translatedOnly.cues.map(\.startTime), source.cues.map(\.startTime))
        XCTAssertEqual(translatedOnly.cues.map(\.endTime), source.cues.map(\.endTime))
        XCTAssertEqual(translatedOnly.serializedSRT(), """
        1
        00:00:00,000 --> 00:00:03,000
        你好，世界。

        2
        00:00:03,000 --> 00:00:05,000
        下一句。

        """)
        XCTAssertEqual(bilingual.cues[0].text, "你好，世界。\nHello world.")
    }

    func testDuplicateTranslationIDsUseLastSegmentWithoutCrashing() {
        let source = MobileSubtitleDocument(cues: [
            MobileSubtitleCue(index: 1, startTime: "00:00:00,000", endTime: "00:00:03,000", text: "Hello world.")
        ])
        let translated = MobileTranslationResult(segments: [
            MobileTranslationSegment(id: "1", startTime: "", endTime: "", text: "旧译文"),
            MobileTranslationSegment(id: "1", startTime: "", endTime: "", text: "新译文")
        ])

        let translatedOnly = source.applying(translated, style: .translatedOnly)

        XCTAssertEqual(translatedOnly.cues.map(\.text), ["新译文"])
    }
}
