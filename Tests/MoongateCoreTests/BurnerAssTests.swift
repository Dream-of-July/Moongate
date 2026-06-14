@testable import MoongateCore
import XCTest

final class BurnerAssTests: XCTestCase {
    private func cue(_ text: String) -> SubtitleCue {
        SubtitleCue(index: 1, start: "00:00:01,000", end: "00:00:02,500", text: text)
    }

    func testLandscape169LayoutUsesReadableSubtitleWidth() {
        let layout = FFmpegBurner.ASSLayout(aspect: 16.0 / 9.0)

        XCTAssertEqual(layout.playResX, 512)
        XCTAssertEqual(layout.playResY, 288)
        XCTAssertEqual(layout.chineseSize, 15)
        XCTAssertEqual(layout.originalSize, 11)
        XCTAssertEqual(layout.marginH, 61)
        XCTAssertEqual(layout.marginV, 20)
        XCTAssertEqual(layout.cjkWrapCapacity, 26)
    }

    func testLandscape169LongChineseLinePreWrappedForReadableWidth() {
        let ass = FFmpegBurner.makeASS(cues: [
            cue("今天，我会介绍如何使用Xcode中的一些强大新工具，在早期探索应用设计时快速尝试不同的界面方向。")
        ])

        XCTAssertTrue(ass.contains(#"今天，我会介绍如何使用Xcode中的一些强大新工具，\N在早期探索应用设计时快速尝试不同的界面方向。"#))
    }

    func testPortrait916StillKeepsUsefulCapacity() {
        let layout = FFmpegBurner.ASSLayout(aspect: 9.0 / 16.0)

        XCTAssertEqual(layout.playResX, 162)
        XCTAssertEqual(layout.chineseSize, 8)
        XCTAssertEqual(layout.originalSize, 6)
        XCTAssertEqual(layout.marginH, 5)
        XCTAssertEqual(layout.cjkWrapCapacity, 19)
    }

    func testUltraWideCapsReadingLength() {
        let layout = FFmpegBurner.ASSLayout(aspect: 10.0)

        XCTAssertEqual(layout.playResX, 1152)
        XCTAssertEqual(layout.chineseSize, 15)
        XCTAssertEqual(layout.marginH, 351)
        XCTAssertEqual(layout.cjkWrapCapacity, 30)
    }

    // MARK: - 原文（拉丁）折行

    func testPortraitLatinCapacityComfortablyWiderThanCJK() {
        // 竖屏下英文按词折行的容量应远大于中文（拉丁字形更窄），否则英文会被切碎。
        let layout = FFmpegBurner.ASSLayout(aspect: 9.0 / 16.0)
        XCTAssertEqual(layout.latinWrapCapacity, 46)
    }

    func testLatinLineWrapMergesSourceBreaksAndRewrapsByWords() {
        // 源 SRT 把一句拆成很多碎行；折行后应合并再按词重排，且不切进单词中间。
        let wrapped = FFmpegBurner.wrapLatinLine(
            "Today\nI will\nshow you how to use some powerful new tools in Xcode to quickly explore design directions.",
            capacity: 40
        )
        XCTAssertGreaterThan(wrapped.count, 1)
        for line in wrapped {
            XCTAssertLessThanOrEqual(line.count, 40, "每行不得超过容量：\(line)")
            XCTAssertFalse(line.hasPrefix(" "))
            XCTAssertFalse(line.hasSuffix(" "))
        }
        // 不切词：重新拼接（空格连接）应还原原始单词序列。
        XCTAssertEqual(
            wrapped.joined(separator: " "),
            "Today I will show you how to use some powerful new tools in Xcode to quickly explore design directions."
        )
    }

    func testLatinShortLineStaysSingleLine() {
        let wrapped = FFmpegBurner.wrapLatinLine("A short caption.", capacity: 50)
        XCTAssertEqual(wrapped, ["A short caption."])
    }

    func testBilingualCueRewrapsEnglishUnderChinese() {
        // 双语：中文在上、英文在下；竖屏长英文行应被按词折行而非保留源碎行。
        let english = "This is a fairly long English subtitle line that would otherwise overflow or be chopped into many tiny fragments on a portrait video."
        let ass = FFmpegBurner.makeASS(
            cues: [SubtitleCue(index: 1, start: "00:00:01,000", end: "00:00:02,500",
                               text: "这是一句中文字幕\n\(english)")],
            aspect: 9.0 / 16.0
        )
        // 英文被折成多行（出现 \N 连接），但任意单行长度不超过容量 50。
        guard let dialogue = ass.split(separator: "\n").first(where: { $0.hasPrefix("Dialogue:") }) else {
            return XCTFail("应有 Dialogue 行")
        }
        let englishPart = String(dialogue).components(separatedBy: "}").last ?? ""
        for piece in englishPart.components(separatedBy: "\\N") {
            XCTAssertLessThanOrEqual(piece.count, 50, "英文行过长：\(piece)")
        }
    }
}
