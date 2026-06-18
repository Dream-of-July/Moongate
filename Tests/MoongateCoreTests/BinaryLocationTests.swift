import XCTest
@testable import MoongateCore

#if !os(Windows)
/// Phase 3：支持自定义 Homebrew prefix / 非标准安装位置的二进制搜索目录（纯函数）。
final class BinaryLocationTests: XCTestCase {
    func testIncludesCustomHomebrewPrefixFirstThenStandardThenPath() {
        let dirs = YtDlpEngine.binarySearchDirectories(environment: [
            "HOMEBREW_PREFIX": "/Users/x/homebrew",
            "PATH": "/custom/bin:/opt/homebrew/bin",
        ])
        // 自定义前缀的 bin 最先搜。
        XCTAssertEqual(dirs.first, "/Users/x/homebrew/bin")
        // 标准前缀仍在。
        XCTAssertTrue(dirs.contains("/opt/homebrew/bin"))
        XCTAssertTrue(dirs.contains("/usr/local/bin"))
        XCTAssertTrue(dirs.contains("/usr/bin"))
        // PATH 里的目录也纳入搜索。
        XCTAssertTrue(dirs.contains("/custom/bin"))
        // 去重保序：/opt/homebrew/bin 只出现一次。
        XCTAssertEqual(dirs.filter { $0 == "/opt/homebrew/bin" }.count, 1)
    }

    func testDefaultsWhenNoCustomEnvironment() {
        let dirs = YtDlpEngine.binarySearchDirectories(environment: [:])
        XCTAssertEqual(dirs, ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"])
    }

    func testEmptyHomebrewPrefixIgnored() {
        let dirs = YtDlpEngine.binarySearchDirectories(environment: ["HOMEBREW_PREFIX": ""])
        XCTAssertFalse(dirs.contains("/bin"))
        XCTAssertEqual(dirs.first, "/opt/homebrew/bin")
    }
}
#endif
