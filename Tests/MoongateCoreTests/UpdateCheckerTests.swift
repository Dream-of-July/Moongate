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
                     "browser_download_url": "https://github.com/Dream-of-July/moongate/releases/download/\(e.tag)/\(name)"]
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

    func testIgnoresMacAssetWhenNameDoesNotMatchReleaseVersion() {
        let data = releasesJSON([
            ("v0.6.0", ["Moongate-macOS-v0.5.0.dmg"]),
            ("v0.5.0", ["Moongate-macOS-v0.5.0.dmg"]),
        ])
        let info = UpdateChecker.latestMacUpdate(fromReleasesJSON: data, currentVersion: SemVer("0.4.0")!)
        XCTAssertEqual(info?.tag, "v0.5.0")
        XCTAssertEqual(info?.assetName, "Moongate-macOS-v0.5.0.dmg")
    }

    func testIgnoresMacAssetWhenVersionIsOnlyPrefixMatch() {
        let data = releasesJSON([
            ("v0.5.0", ["Moongate-macOS-v0.5.01.dmg"]),
        ])

        XCTAssertNil(UpdateChecker.latestMacUpdate(fromReleasesJSON: data, currentVersion: SemVer("0.4.0")!))
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

    func testUpdateErrorsUseUpdateSpecificCopy() throws {
        let error = MoongateError.updateFailed("更新检查过于频繁（GitHub 限流），请稍后再试。")
        XCTAssertEqual(error.errorDescription, "检查更新失败：更新检查过于频繁（GitHub 限流），请稍后再试。")
        XCTAssertFalse(error.errorDescription?.contains("解析视频信息失败") == true)

        let source = try String(contentsOf: packageRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("MoongateCore")
            .appendingPathComponent("UpdateChecker.swift"))
        XCTAssertFalse(source.contains("MoongateError.analyzeFailed"))
        XCTAssertTrue(source.contains("MoongateError.updateFailed"))
    }

    func testInstallScriptWaitsForExitThenReplacesAndReopens() {
        let script = UpdateChecker.installScript(
            mountPoint: "/Volumes/月之门",
            mountedAppPath: "/Volumes/月之门/月之门.app",
            targetAppPath: "/Applications/月之门.app",
            pid: 4242
        )
        XCTAssertTrue(script.contains("kill -0 4242"))
        XCTAssertTrue(script.contains("mktemp -d"))
        XCTAssertTrue(script.contains(".moongate-update."))
        XCTAssertTrue(script.contains("newApp=\"$tmp/$targetBase\""))
        XCTAssertTrue(script.contains("backup=\"$parent/.moongate-previous-$targetBase\""))
        XCTAssertTrue(script.contains("ditto '/Volumes/月之门/月之门.app' \"$newApp\""))
        XCTAssertTrue(script.contains("mv '/Applications/月之门.app' \"$backup\""))
        XCTAssertTrue(script.contains("mv \"$backup\" '/Applications/月之门.app'"))
        XCTAssertTrue(script.contains("xattr -dr com.apple.quarantine '/Applications/月之门.app'"))
        XCTAssertTrue(script.contains("open '/Applications/月之门.app'"))
        XCTAssertFalse(script.contains("rm -rf '/Applications/月之门.app'"))
        // DMG 卸载必须由脚本负责（复制完成后），而不是由正在退出的 App 卸载，否则 ditto 读不到源。
        XCTAssertTrue(script.contains("hdiutil detach '/Volumes/月之门' -force"))
        // 先等退出，再复制到临时目录，复制完才卸载 DMG，最后原子交换，避免失败后留下空安装。
        let killIdx = script.range(of: "kill -0")!.lowerBound
        let dittoIdx = script.range(of: "ditto")!.lowerBound
        let backupIdx = script.range(of: "mv '/Applications/月之门.app' \"$backup\"")!.lowerBound
        let installIdx = script.range(of: "mv \"$newApp\" '/Applications/月之门.app'")!.lowerBound
        // 复制成功后才卸载 DMG：该注释紧贴成功路径上的 detach 调用，应在 ditto 之后、备份交换之前。
        let postCopyDetachIdx = script.range(of: "# 新 App 已完整落到本地磁盘")!.lowerBound
        XCTAssertLessThan(killIdx, dittoIdx)
        XCTAssertLessThan(dittoIdx, postCopyDetachIdx)
        XCTAssertLessThan(postCopyDetachIdx, backupIdx)
        XCTAssertLessThan(backupIdx, installIdx)
    }

    func testMacUpdateInstallValidatesMountedAppVersionBeforeReplacement() throws {
        let source = try String(contentsOf: packageRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("Moongate")
            .appendingPathComponent("UpdateService.swift"))

        XCTAssertTrue(source.contains("CFBundleShortVersionString"))
        XCTAssertTrue(source.contains("SemVer(newVersionRaw) == expectedVersion"))
        let versionCheck = try XCTUnwrap(source.range(of: "SemVer(newVersionRaw) == expectedVersion"))
        let installScript = try XCTUnwrap(source.range(of: "UpdateChecker.installScript("))
        XCTAssertLessThan(versionCheck.lowerBound, installScript.lowerBound)
    }

    func testMacUpdateChecksInstallDirectoryWritableBeforeTerminating() throws {
        let source = try String(contentsOf: packageRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("Moongate")
            .appendingPathComponent("UpdateService.swift"))

        // 不可写时替换脚本会在退出后静默失败，所以必须在退出 App 之前就检查并报错。
        XCTAssertTrue(source.contains("isWritableFile"))
        let writeCheck = try XCTUnwrap(source.range(of: "isWritableFile"))
        let terminate = try XCTUnwrap(source.range(of: "NSApp.terminate"))
        XCTAssertLessThan(writeCheck.lowerBound, terminate.lowerBound)
    }

    func testMacUpdateServiceLocalizesInstallerFailures() throws {
        let source = try String(contentsOf: packageRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("Moongate")
            .appendingPathComponent("UpdateService.swift"))

        XCTAssertTrue(source.contains("private func t(_ key: String"))
        XCTAssertTrue(source.contains("LocalizedStrings.format(key, language: language"))
        XCTAssertTrue(source.contains("t(L.Update.untrustedPackageURL)"))
        XCTAssertTrue(source.contains("t(L.Update.downloadPackageFailed)"))
        XCTAssertTrue(source.contains("t(L.Update.installDirectoryNotWritable, installParent.path)"))
        XCTAssertTrue(source.contains("t(L.Update.packageMissingApp)"))
        XCTAssertTrue(source.contains("t(L.Update.packageMismatch)"))
        XCTAssertTrue(source.contains("t(L.Update.versionMismatch)"))
        XCTAssertTrue(source.contains("t(L.Update.mountFailed)"))
    }

    func testTrustedDMGURLWhitelist() {
        let owner = "Dream-of-July", repo = "moongate"
        XCTAssertTrue(UpdateChecker.isTrustedDMGURL(
            URL(string: "https://github.com/Dream-of-July/moongate/releases/download/v0.5.0/x.dmg")!,
            owner: owner, repo: repo))
        // 非 https / 非 GitHub release canonical URL / 非 dmg / 错仓库 → 拒绝。
        XCTAssertFalse(UpdateChecker.isTrustedDMGURL(
            URL(string: "http://github.com/Dream-of-July/moongate/releases/download/v1/x.dmg")!, owner: owner, repo: repo))
        XCTAssertFalse(UpdateChecker.isTrustedDMGURL(
            URL(string: "https://evil.com/x.dmg")!, owner: owner, repo: repo))
        XCTAssertFalse(UpdateChecker.isTrustedDMGURL(
            URL(string: "https://objects.githubusercontent.com/abc/x.dmg")!, owner: owner, repo: repo))
        XCTAssertFalse(UpdateChecker.isTrustedDMGURL(
            URL(string: "https://github.com/Dream-of-July/moongate/releases/download/v1/x.zip")!, owner: owner, repo: repo))
        XCTAssertFalse(UpdateChecker.isTrustedDMGURL(
            URL(string: "https://github.com/someone-else/evil/releases/download/v1/x.dmg")!, owner: owner, repo: repo))
    }

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
