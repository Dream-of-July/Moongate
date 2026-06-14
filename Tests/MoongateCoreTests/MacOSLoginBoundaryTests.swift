import XCTest

final class MacOSLoginBoundaryTests: XCTestCase {
    func testLoginSheetProvidesCompactBrowserControlsThroughCommandBinding() throws {
        let source = try loginWebViewSource()
        let topBarBody = try XCTUnwrap(functionBody(prefix: "private var topBar", in: source))
        let webViewBody = try XCTUnwrap(structBody(named: "struct LoginWebView", in: source))
        let updateBody = try XCTUnwrap(functionBody(prefix: "func updateNSView", in: source))

        XCTAssertTrue(source.contains("@State private var webViewCommand: LoginWebViewCommand?"))
        XCTAssertTrue(source.contains("command: $webViewCommand"))
        XCTAssertTrue(webViewBody.contains("@Binding var command: LoginWebViewCommand?"))
        XCTAssertTrue(updateBody.contains("consumeCommand"))

        XCTAssertTrue(topBarBody.contains("webViewCommand = .back"))
        XCTAssertTrue(topBarBody.contains("webViewCommand = .reload"))
        XCTAssertTrue(topBarBody.contains("openCurrentPageInBrowser()"))
        XCTAssertTrue(topBarBody.contains("systemName: \"chevron.left\""))
        XCTAssertTrue(topBarBody.contains("systemName: \"arrow.clockwise\""))
        XCTAssertTrue(topBarBody.contains("systemName: \"safari\""))
        XCTAssertTrue(topBarBody.contains(".labelStyle(.iconOnly)"))
        XCTAssertTrue(topBarBody.contains(".controlSize(.small)"))
        XCTAssertTrue(topBarBody.contains(".help(\"返回\")"))
        XCTAssertTrue(topBarBody.contains(".help(\"重新载入\")"))
        XCTAssertTrue(topBarBody.contains(".help(\"在浏览器中打开\")"))
        XCTAssertTrue(topBarBody.contains(".accessibilityLabel(\"返回\")"))
        XCTAssertTrue(topBarBody.contains(".accessibilityLabel(\"重新载入\")"))
        XCTAssertTrue(topBarBody.contains(".accessibilityLabel(\"在浏览器中打开\")"))
    }

    func testOpenInBrowserOnlyUsesUserActionAndCurrentOrStartURL() throws {
        let source = try loginWebViewSource()
        let topBarBody = try XCTUnwrap(functionBody(prefix: "private var topBar", in: source))
        let openBrowserBody = try XCTUnwrap(
            functionBody(prefix: "private func openCurrentPageInBrowser", in: source)
        )
        let makeBody = try XCTUnwrap(functionBody(prefix: "func makeNSView", in: source))
        let updateBody = try XCTUnwrap(functionBody(prefix: "func updateNSView", in: source))

        XCTAssertTrue(topBarBody.contains("openCurrentPageInBrowser()"))
        XCTAssertTrue(openBrowserBody.contains("currentPageURL ?? Self.startURL(for: site)"))
        XCTAssertTrue(openBrowserBody.contains("NSWorkspace.shared.open"))
        XCTAssertFalse(makeBody.contains("NSWorkspace.shared.open"))
        XCTAssertFalse(updateBody.contains("NSWorkspace.shared.open"))
    }

    func testTargetCookieReadinessShowsOnlySiteCookiePresence() throws {
        let source = try loginWebViewSource()
        let topBarBody = try XCTUnwrap(functionBody(prefix: "private var topBar", in: source))
        let readinessBody = try XCTUnwrap(
            functionBody(prefix: "private var cookieReadinessText: String", in: source)
        )
        let refreshBody = try XCTUnwrap(
            functionBody(prefix: "private func refreshCookieReadiness", in: source)
        )

        XCTAssertTrue(source.contains("@State private var hasSiteLoginCookies = false"))
        XCTAssertTrue(topBarBody.contains("Text(cookieReadinessText)"))
        XCTAssertTrue(readinessBody.contains("已检测到当前站点 Cookie"))
        XCTAssertTrue(readinessBody.contains("仍未检测到当前站点 Cookie"))
        XCTAssertFalse(readinessBody.contains("Cookie 内容"))
        XCTAssertFalse(readinessBody.contains("Cookie 名称"))
        XCTAssertFalse(readinessBody.contains("Cookie 数量"))
        XCTAssertFalse(readinessBody.contains("域名列表"))
        XCTAssertFalse(readinessBody.contains("登录信息"))

        XCTAssertTrue(refreshBody.contains("WKWebsiteDataStore.default().httpCookieStore.getAllCookies"))
        XCTAssertTrue(refreshBody.contains("containsSiteCookie"))
        XCTAssertFalse(refreshBody.contains("NetscapeCookieFile.write"))
    }

    func testLoginTopBarShowsHostOnlyInsteadOfFullRedirectURL() throws {
        let source = try loginWebViewSource()
        let topBarBody = try XCTUnwrap(functionBody(prefix: "private var topBar", in: source))
        let displayBody = try XCTUnwrap(
            functionBody(prefix: "private static func displayHost", in: source)
        )

        XCTAssertTrue(topBarBody.contains("Text(displayedCurrentURL)"))
        XCTAssertFalse(topBarBody.contains("Text(currentURL)"))
        XCTAssertTrue(displayBody.contains("URLComponents(string: value)"))
        XCTAssertTrue(displayBody.contains("components.host"))
        XCTAssertFalse(displayBody.contains("components.query"))
        XCTAssertFalse(displayBody.contains("components.fragment"))
    }

    func testCookieExportStillWritesAllCookiesWithoutFilteringToReadinessSite() throws {
        let source = try loginWebViewSource()
        let exportBody = try XCTUnwrap(functionBody(prefix: "private func exportCookies", in: source))

        XCTAssertTrue(exportBody.contains("WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in"))
        XCTAssertTrue(exportBody.contains("NetscapeCookieFile.write(cookies: cookies, to: fileURL)"))
        XCTAssertFalse(exportBody.contains("containsSiteCookie"))
        XCTAssertFalse(exportBody.contains("filter"))
    }

    func testLoginWebViewExposesLoadingStateThroughBinding() throws {
        let source = try loginWebViewSource()
        let coordinatorBody = try XCTUnwrap(functionBody(prefix: "func makeCoordinator", in: source))

        XCTAssertTrue(source.contains("@State private var isLoading = false"))
        XCTAssertTrue(source.contains("@Binding var isLoading: Bool"))
        XCTAssertTrue(source.contains("isLoading: $isLoading"))
        XCTAssertTrue(coordinatorBody.contains("Coordinator("))
        XCTAssertTrue(coordinatorBody.contains("currentURL: $currentURL"))
        XCTAssertTrue(coordinatorBody.contains("loadError: $loadError"))
        XCTAssertTrue(coordinatorBody.contains("isLoading: $isLoading"))
        XCTAssertTrue(source.contains("context.coordinator.isLoading = $isLoading"))
    }

    func testNavigationDelegateMaintainsLoadingStateWithoutReportingCancelledLoads() throws {
        let source = try loginWebViewSource()

        let didStartBody = try XCTUnwrap(
            functionBody(prefix: "func webView(_ webView: WKWebView, didStartProvisionalNavigation", in: source)
        )
        XCTAssertTrue(didStartBody.contains("isLoading.wrappedValue = true"))
        XCTAssertTrue(didStartBody.contains("loadError.wrappedValue = nil"))

        let didCommitBody = try XCTUnwrap(
            functionBody(prefix: "func webView(_ webView: WKWebView, didCommit", in: source)
        )
        XCTAssertTrue(didCommitBody.contains("isLoading.wrappedValue = true"))

        let didFinishBody = try XCTUnwrap(
            functionBody(prefix: "func webView(_ webView: WKWebView, didFinish", in: source)
        )
        XCTAssertTrue(didFinishBody.contains("isLoading.wrappedValue = false"))

        let reportFailureBody = try XCTUnwrap(functionBody(prefix: "private func reportLoadFailure", in: source))
        XCTAssertTrue(reportFailureBody.contains("isLoading.wrappedValue = false"))
        XCTAssertTrue(reportFailureBody.contains("NSURLErrorCancelled"))
        let clearsLoading = try XCTUnwrap(reportFailureBody.range(of: "isLoading.wrappedValue = false"))
        let checksCancelled = try XCTUnwrap(reportFailureBody.range(of: "NSURLErrorCancelled"))
        XCTAssertLessThan(clearsLoading.lowerBound, checksCancelled.lowerBound)
    }

    func testTopBarShowsLoadingStateWithoutCookieDetails() throws {
        let source = try loginWebViewSource()
        let topBarBody = try XCTUnwrap(functionBody(prefix: "private var topBar", in: source))
        let loadingStateBody = try XCTUnwrap(ifBody(condition: "if isLoading", in: topBarBody))

        XCTAssertTrue(topBarBody.contains("if isLoading"))
        XCTAssertTrue(loadingStateBody.contains("ProgressView()"))
        XCTAssertTrue(loadingStateBody.contains(".accessibilityLabel(\"页面加载中\")"))
        XCTAssertFalse(loadingStateBody.localizedCaseInsensitiveContains("cookie"))
    }

    func testSaveLoginActionExplainsAppScopedCookieExportWithoutCookieDetails() throws {
        let source = try loginWebViewSource()
        let topBarBody = try XCTUnwrap(functionBody(prefix: "private var topBar", in: source))
        let helpTextBody = try XCTUnwrap(
            functionBody(prefix: "private var saveLoginHelpText: String", in: source)
        )

        XCTAssertTrue(topBarBody.contains("Text(isExporting ? \"保存中…\" : \"保存登录信息\")"))
        XCTAssertTrue(topBarBody.contains("exportCookies()"))
        XCTAssertTrue(topBarBody.contains(".help(saveLoginHelpText)"))
        XCTAssertTrue(topBarBody.contains(".accessibilityHint(saveLoginHelpText)"))
        XCTAssertTrue(topBarBody.contains(".accessibilityValue(cookieReadinessText)"))
        XCTAssertTrue(source.contains("private var saveLoginHelpText: String"))
        XCTAssertTrue(helpTextBody.contains("if hasSiteLoginCookies"))
        XCTAssertTrue(helpTextBody.contains("当前站点 Cookie 已就绪"))
        XCTAssertTrue(helpTextBody.contains("还没有检测到当前站点 Cookie"))
        XCTAssertTrue(helpTextBody.contains("保存到本 App"))
        XCTAssertTrue(helpTextBody.contains("供下载器使用"))
        XCTAssertTrue(helpTextBody.contains("不会在界面显示 Cookie 内容"))
        XCTAssertFalse(topBarBody.contains("getAllCookies"))
        XCTAssertFalse(topBarBody.contains("NetscapeCookieFile.write"))
    }

    private func loginWebViewSource() throws -> String {
        try String(contentsOf: packageRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("Moongate")
            .appendingPathComponent("LoginWebView.swift"))
    }

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func functionBody(prefix: String, in source: String) -> String? {
        guard let declaration = source.range(of: prefix) else { return nil }
        guard let openingBrace = source[declaration.lowerBound...].firstIndex(of: "{") else { return nil }

        var depth = 0
        var cursor = openingBrace
        while cursor < source.endIndex {
            switch source[cursor] {
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return String(source[openingBrace...cursor])
                }
            default:
                break
            }
            cursor = source.index(after: cursor)
        }
        return nil
    }

    private func ifBody(condition: String, in source: String) -> String? {
        guard let declaration = source.range(of: condition) else { return nil }
        guard let openingBrace = source[declaration.lowerBound...].firstIndex(of: "{") else { return nil }

        var depth = 0
        var cursor = openingBrace
        while cursor < source.endIndex {
            switch source[cursor] {
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return String(source[openingBrace...cursor])
                }
            default:
                break
            }
            cursor = source.index(after: cursor)
        }
        return nil
    }

    private func structBody(named name: String, in source: String) -> String? {
        functionBody(prefix: name, in: source)
    }
}
