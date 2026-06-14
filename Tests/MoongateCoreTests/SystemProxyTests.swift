import XCTest
@testable import MoongateCore

/// 验证「系统代理跟随」：环境变量显式设置代理时，yt-dlp 应收到对应的 --proxy 参数。
/// （系统代理读取走 CFNetwork，依赖运行机环境，无法在单测里确定性断言；
/// 这里覆盖确定性的环境变量优先路径。）
final class SystemProxyTests: XCTestCase {

    func testHTTPSProxyEnvVarProducesProxyArg() {
        let key = "HTTPS_PROXY"
        let previous = ProcessInfo.processInfo.environment[key]
        setenv(key, "http://127.0.0.1:7890", 1)
        defer {
            if let previous { setenv(key, previous, 1) } else { unsetenv(key) }
        }
        let args = YtDlpEngine.systemProxyArguments()
        // 环境变量优先：应原样作为 --proxy 传给 yt-dlp。
        XCTAssertEqual(args.first, "--proxy")
        XCTAssertTrue(args.contains("http://127.0.0.1:7890"),
                      "应把环境变量里的代理地址传给 yt-dlp，实际：\(args)")
    }

    func testAllProxyEnvVarSocksProducesProxyArg() {
        // 清掉可能干扰的 https/http，单独验证 all_proxy（Clash 常导出 socks）。
        for k in ["HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy"] { unsetenv(k) }
        let key = "ALL_PROXY"
        let previous = ProcessInfo.processInfo.environment[key]
        setenv(key, "socks5://127.0.0.1:7891", 1)
        defer {
            if let previous { setenv(key, previous, 1) } else { unsetenv(key) }
        }
        let args = YtDlpEngine.systemProxyArguments()
        XCTAssertEqual(args.first, "--proxy")
        XCTAssertTrue(args.contains("socks5://127.0.0.1:7891"), "实际：\(args)")
    }
}
