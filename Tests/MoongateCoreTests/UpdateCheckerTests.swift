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

    func testUpdateErrorsUseUpdateSpecificCopy() throws {
        let error = MoongateError.updateFailed("更新检查过于频繁（GitHub 限流），请稍后再试。")
        XCTAssertEqual(error.errorDescription, "检查更新失败：更新检查过于频繁（GitHub 限流），请稍后再试。")
        XCTAssertFalse(error.errorDescription?.contains("解析视频信息失败") == true)

        let source = try read("Sources", "MoongateCore", "Models.swift")
        XCTAssertFalse(source.contains("MoongateError.analyzeFailed"))
        XCTAssertTrue(source.contains("case updateFailed"))
    }

    func testSwiftUpdateCheckerNoLongerOwnsMacInstallFlow() throws {
        let source = try read("Sources", "MoongateCore", "UpdateChecker.swift")

        XCTAssertTrue(source.contains("public struct SemVer"))
        XCTAssertTrue(source.contains("macOS App 内更新从 0.7 起交给 Sparkle"))
        XCTAssertFalse(source.contains("latestMacUpdate"))
        XCTAssertFalse(source.contains("isTrustedPackageURL"))
        XCTAssertFalse(source.contains("browser_download_url"))
        XCTAssertFalse(source.contains(".pkg"))
    }

    func testMacUpdaterUsesSparkleInsteadOfSelfManagedInstaller() throws {
        let source = try read("Sources", "Moongate", "UpdateService.swift")

        XCTAssertTrue(source.contains("import Sparkle"))
        XCTAssertTrue(source.contains("SPUStandardUpdaterController"))
        XCTAssertTrue(source.contains("SPUStandardUserDriverDelegate"))
        XCTAssertTrue(source.contains("userDriverDelegate: self"))
        XCTAssertTrue(source.contains("standardUserDriverWillShowModalAlert"))
        XCTAssertTrue(source.contains("prepareForUpdateUI?()"))
        XCTAssertTrue(source.contains("updaterController.checkForUpdates(nil)"))
        XCTAssertTrue(source.contains("blockInstallDueToOpenTasks"))
        XCTAssertFalse(source.contains("pkgutil"))
        XCTAssertFalse(source.contains("spctl"))
        XCTAssertFalse(source.contains("URLSession"))
        XCTAssertFalse(source.contains("NSWorkspace.shared.open(packageURL)"))
        XCTAssertFalse(source.contains("NSApp.terminate"))
        XCTAssertFalse(source.contains("attachDMG"))
    }

    func testSparkleDependencyAndBundleConfigurationArePresent() throws {
        let package = try read("Package.swift")
        let buildScript = try read("build.sh")
        let publicKey = try read("sparkle-public-ed-key.txt").trimmingCharacters(in: .whitespacesAndNewlines)

        XCTAssertTrue(package.contains("https://github.com/sparkle-project/Sparkle"))
        XCTAssertTrue(package.contains("from: \"2.6.0\""))
        XCTAssertTrue(package.contains(".product(name: \"Sparkle\", package: \"Sparkle\")"))
        XCTAssertTrue(buildScript.contains("Sparkle.framework"))
        XCTAssertTrue(buildScript.contains("SUFeedURL"))
        XCTAssertTrue(buildScript.contains("https://dream-of-july.github.io/moongate/appcast.xml"))
        XCTAssertTrue(buildScript.contains("SUPublicEDKey"))
        XCTAssertTrue(buildScript.contains("SUEnableAutomaticChecks"))
        XCTAssertTrue(buildScript.contains("SUAutomaticallyUpdate"))
        XCTAssertTrue(buildScript.contains("SUVerifyUpdateBeforeExtraction"))
        XCTAssertTrue(buildScript.contains("<string>$APP_BUILD_NUMBER</string>"))
        XCTAssertEqual(publicKey.count, 44)
    }

    func testSparkleReleaseScriptsUseZipAndAppcastSigning() throws {
        let zipScript = try read("make-sparkle-zip.sh")
        let appcastScript = try read("make-appcast.sh")
        let dmgScript = try read("make-dmg.sh")
        let pkgScript = try read("make-pkg.sh")

        XCTAssertTrue(zipScript.contains("ditto -c -k --sequesterRsrc --keepParent"))
        XCTAssertTrue(zipScript.contains("MOONGATE_BUILD_NUMBER"))
        XCTAssertTrue(zipScript.contains("Moongate-macOS-v$VERSION.zip"))
        XCTAssertTrue(appcastScript.contains("sign_update"))
        XCTAssertTrue(appcastScript.contains("sparkle:edSignature"))
        XCTAssertTrue(appcastScript.contains("sparkle:version"))
        XCTAssertTrue(appcastScript.contains("sparkle:shortVersionString"))
        XCTAssertTrue(appcastScript.contains("docs/appcast.xml"))
        XCTAssertTrue(dmgScript.contains("make-sparkle-zip.sh"))
        XCTAssertTrue(pkgScript.contains("当前免 Developer ID 更新请使用 Sparkle ZIP"))
    }

    private func read(_ parts: String...) throws -> String {
        try String(contentsOf: parts.reduce(packageRoot()) { $0.appendingPathComponent($1) })
    }

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
