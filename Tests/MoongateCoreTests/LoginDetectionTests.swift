import XCTest
@testable import MoongateCore

/// 验证「未登录导致失败」会被识别为 .loginRequired（failed 页据此显示「去登录」按钮）。
final class LoginDetectionTests: XCTestCase {

    private func isLoginRequired(_ error: MoongateError?) -> Bool {
        if case .loginRequired = error { return true }
        return false
    }

    func testYouTubeSignInPromptIsRecognizedAsLoginIssue() {
        // YouTube「Sign in to confirm」：未登录→loginRequired；已登录→重新登录提示。
        // 本机可能已有 cookies，两种都算「识别为登录相关」，不应是普通失败。
        let error = YtDlpEngine._testLoginRequired(
            stderr: "ERROR: [youtube] abc: Sign in to confirm you're not a bot.",
            url: "https://www.youtube.com/watch?v=abc"
        )
        switch error {
        case .loginRequired:
            break
        case .downloadFailed(let msg):
            XCTAssertTrue(msg.contains("登录"), "已登录场景也应提示重新登录，而非普通失败")
        default:
            XCTFail("YouTube Sign in 提示应被识别为登录相关，实际：\(String(describing: error))")
        }
    }

    func testBilibiliMemberOnlyVideoNeedsLogin() {
        let error = YtDlpEngine._testLoginRequired(
            stderr: "ERROR: [BiliBili] BV1: 该视频需要登录大会员账号才能观看",
            url: "https://www.bilibili.com/video/BV1"
        )
        XCTAssertTrue(isLoginRequired(error))
        if case .loginRequired(let site) = error {
            XCTAssertEqual(site, "bilibili.com")
        }
    }

    func testGenericNeedLoginEnglishMessageNeedsLogin() {
        let error = YtDlpEngine._testLoginRequired(
            stderr: "ERROR: This video requires login. Use --cookies to provide account cookies.",
            url: "https://example.com/v/1"
        )
        XCTAssertTrue(isLoginRequired(error))
    }

    func testBilibili412WithoutSavedCookiesPromptsLogin() {
        // B 站首次未登录直接贴链接时常以 412 表现，用户需要的是登录引导/WebView。
        let stderr = "ERROR: [BiliBili] BV1: Unable to download JSON metadata: HTTP Error 412: Precondition Failed"
        let loginError = YtDlpEngine._testLoginRequired(
            stderr: stderr,
            url: "https://www.bilibili.com/video/BV1",
            hasCookies: false
        )
        XCTAssertTrue(isLoginRequired(loginError))
        if case .loginRequired(let site) = loginError {
            XCTAssertEqual(site, "bilibili.com")
        }
    }

    func testBilibili412WithSavedCookiesKeepsRiskControlHint() {
        let stderr = "ERROR: [BiliBili] BV1: Unable to download JSON metadata: HTTP Error 412: Precondition Failed"
        let loginError = YtDlpEngine._testLoginRequired(
            stderr: stderr,
            url: "https://www.bilibili.com/video/BV1",
            hasCookies: true
        )
        XCTAssertFalse(isLoginRequired(loginError))

        let riskMessage = YtDlpEngine._testRiskControlMessage(stderr: stderr, host: "www.bilibili.com")
        XCTAssertNotNil(riskMessage)
        XCTAssertTrue(riskMessage?.contains("风控") == true)
    }

    func testPlainNetworkErrorIsNeitherLoginNorRisk() {
        let stderr = "ERROR: Unable to download webpage: <urlopen error timed out>"
        XCTAssertFalse(isLoginRequired(YtDlpEngine._testLoginRequired(stderr: stderr, url: "https://www.bilibili.com/video/BV1")))
        XCTAssertNil(YtDlpEngine._testRiskControlMessage(stderr: stderr, host: "www.bilibili.com"))
    }

    func testNativeExtractorHostsIncludeShortVideoSites() {
        for host in [
            "www.tiktok.com",
            "vt.tiktok.com",
            "v.douyin.com",
            "www.douyin.com",
            "www.xiaohongshu.com",
            "xhslink.com",
        ] {
            XCTAssertTrue(YtDlpEngine._testIsNativeExtractorHost(host), host)
        }
        XCTAssertFalse(YtDlpEngine._testIsNativeExtractorHost("example.com"))
    }
}
