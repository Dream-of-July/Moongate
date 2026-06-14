import XCTest
@testable import MoongateCore

final class UpdateCheckerTests: XCTestCase {

    func testSemVerParsingAndComparison() {
        XCTAssertEqual(SemVer("v0.4.0"), SemVer(major: 0, minor: 4, patch: 0))
        XCTAssertEqual(SemVer("0.4"), SemVer(major: 0, minor: 4, patch: 0))
        XCTAssertEqual(SemVer("1.2.3-beta"), SemVer(major: 1, minor: 2, patch: 3))
        XCTAssertNil(SemVer("not-a-version"))
        XCTAssertTrue(SemVer("0.4.0")! > SemVer("0.3.9")!)
        XCTAssertTrue(SemVer("v1.0.0")! > SemVer("0.99.99")!)
        XCTAssertFalse(SemVer("0.4.0")! > SemVer("0.4.0")!)
    }

    private func releasesJSON(_ entries: [(tag: String, assets: [String])]) -> Data {
        let arr = entries.map { e -> [String: Any] in
            [
                "tag_name": e.tag,
                "body": "release notes for \(e.tag)",
                "draft": false,
                "prerelease": true,
                "assets": e.assets.map { name -> [String: Any] in
                    ["name": name,
                     "browser_download_url": "https://github.com/Dream-of-July/video-downloader-app/releases/download/\(e.tag)/\(name)"]
                },
            ]
        }
        return try! JSONSerialization.data(withJSONObject: arr)
    }

    func testPicksNewestMacUpdateAboveCurrent() {
        let data = releasesJSON([
            ("v0.3.0", ["Moongate-macOS-v0.3.0.dmg", "Moongate-Windows-Setup-v0.3.0.exe"]),
            ("v0.5.0", ["Moongate-macOS-v0.5.0.dmg"]),
            ("v0.4.0", ["Moongate-macOS-v0.4.0.dmg"]),
        ])
        let info = UpdateChecker.latestMacUpdate(fromReleasesJSON: data, currentVersion: SemVer("0.4.0")!)
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.tag, "v0.5.0")
        XCTAssertEqual(info?.assetName, "Moongate-macOS-v0.5.0.dmg")
        XCTAssertTrue(info?.dmgURL.absoluteString.hasPrefix("https://github.com/Dream-of-July/") == true)
        XCTAssertTrue(info?.notes.contains("v0.5.0") == true)
    }

    func testReturnsNilWhenAlreadyLatest() {
        let data = releasesJSON([("v0.4.0", ["Moongate-macOS-v0.4.0.dmg"])])
        XCTAssertNil(UpdateChecker.latestMacUpdate(fromReleasesJSON: data, currentVersion: SemVer("0.4.0")!))
    }

    func testIgnoresReleasesWithoutMacDMG() {
        // 只有 Windows 资产 → 不算可更新。
        let data = releasesJSON([("v0.9.0", ["Moongate-Windows-Setup-v0.9.0.exe"])])
        XCTAssertNil(UpdateChecker.latestMacUpdate(fromReleasesJSON: data, currentVersion: SemVer("0.4.0")!))
    }

    func testSkipsUnparseableTagsAndBadData() {
        let data = releasesJSON([
            ("nightly", ["Moongate-macOS-nightly.dmg"]),   // 无法解析版本 → 跳过
            ("v0.6.0", ["Moongate-macOS-v0.6.0.dmg"]),
        ])
        let info = UpdateChecker.latestMacUpdate(fromReleasesJSON: data, currentVersion: SemVer("0.4.0")!)
        XCTAssertEqual(info?.tag, "v0.6.0")

        XCTAssertNil(UpdateChecker.latestMacUpdate(fromReleasesJSON: Data("not json".utf8), currentVersion: SemVer("0.4.0")!))
    }

    func testInstallScriptWaitsForExitThenReplacesAndReopens() {
        let script = UpdateChecker.installScript(
            mountedAppPath: "/Volumes/月之门/月之门.app",
            targetAppPath: "/Applications/月之门.app",
            pid: 4242
        )
        XCTAssertTrue(script.contains("kill -0 4242"))
        XCTAssertTrue(script.contains("ditto '/Volumes/月之门/月之门.app' '/Applications/月之门.app'"))
        XCTAssertTrue(script.contains("xattr -dr com.apple.quarantine '/Applications/月之门.app'"))
        XCTAssertTrue(script.contains("open '/Applications/月之门.app'"))
        // 先等退出再删除，保证不替换正在运行的进程。
        let killIdx = script.range(of: "kill -0")!.lowerBound
        let rmIdx = script.range(of: "rm -rf")!.lowerBound
        XCTAssertLessThan(killIdx, rmIdx)
    }

    func testTrustedDMGURLWhitelist() {
        let owner = "Dream-of-July", repo = "video-downloader-app"
        XCTAssertTrue(UpdateChecker.isTrustedDMGURL(
            URL(string: "https://github.com/Dream-of-July/video-downloader-app/releases/download/v0.5.0/x.dmg")!,
            owner: owner, repo: repo))
        // 只信任规范的 github.com 仓库 releases 下载路径。
        // objects.githubusercontent.com 任意路径不再放行（之前无脑 return true 是漏洞，
        // 且 dmgURL 实际只会是 github.com 规范地址，CDN 重定向由 URLSession 内部跟随）。
        XCTAssertFalse(UpdateChecker.isTrustedDMGURL(
            URL(string: "https://objects.githubusercontent.com/abc/x.dmg")!, owner: owner, repo: repo))
        // 非 https / 非 GitHub / 非 dmg / 错仓库 → 拒绝。
        XCTAssertFalse(UpdateChecker.isTrustedDMGURL(
            URL(string: "http://github.com/Dream-of-July/video-downloader-app/releases/download/v1/x.dmg")!, owner: owner, repo: repo))
        XCTAssertFalse(UpdateChecker.isTrustedDMGURL(
            URL(string: "https://evil.com/x.dmg")!, owner: owner, repo: repo))
        XCTAssertFalse(UpdateChecker.isTrustedDMGURL(
            URL(string: "https://github.com/Dream-of-July/video-downloader-app/releases/download/v1/x.zip")!, owner: owner, repo: repo))
        XCTAssertFalse(UpdateChecker.isTrustedDMGURL(
            URL(string: "https://github.com/someone-else/evil/releases/download/v1/x.dmg")!, owner: owner, repo: repo))
    }
}
