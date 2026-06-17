import XCTest
@testable import MoongateCore

/// 译文清洗：去掉模型自加的行首对话破折号、兜底折叠分隔符（修复烧录字幕出现 "– …" 和 " / " 的脏输出）。
final class TranslationSanitizeTests: XCTestCase {

    func testStripsLeadingDialogueDash() {
        XCTAssertEqual(ConfiguredTranslator.sanitizeTranslation("– 几乎从来不取决于硬件本身"), "几乎从来不取决于硬件本身")
        XCTAssertEqual(ConfiguredTranslator.sanitizeTranslation("- 你好"), "你好")
        XCTAssertEqual(ConfiguredTranslator.sanitizeTranslation("— 你好"), "你好")
    }

    func testCollapsesResidualSlashSeparator() {
        XCTAssertEqual(
            ConfiguredTranslator.sanitizeTranslation("可你要真想玩 / 《马力欧赛车 世界》"),
            "可你要真想玩，《马力欧赛车 世界》"
        )
    }

    func testHandlesDashAndSlashTogether() {
        XCTAssertEqual(
            ConfiguredTranslator.sanitizeTranslation("– 可你要真想玩 / 《马力欧赛车 世界》"),
            "可你要真想玩，《马力欧赛车 世界》"
        )
    }

    func testLeavesCleanTranslationUntouched() {
        // 句中连字符（如 well-known）不在行首，不应被动到
        XCTAssertEqual(ConfiguredTranslator.sanitizeTranslation("这是 well-known 的事"), "这是 well-known 的事")
    }

    func testRemovesChineseTerminalPeriodButKeepsExpressivePunctuation() {
        XCTAssertEqual(ConfiguredTranslator.sanitizeTranslation("这样你就能坐在沙发上，连电视玩。"), "这样你就能坐在沙发上，连电视玩")
        XCTAssertEqual(ConfiguredTranslator.sanitizeTranslation("真的吗？"), "真的吗？")
        XCTAssertEqual(ConfiguredTranslator.sanitizeTranslation("太好了！"), "太好了！")
        XCTAssertEqual(ConfiguredTranslator.sanitizeTranslation("等等……"), "等等……")
    }
}
