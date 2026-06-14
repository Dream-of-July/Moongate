import AppKit
import SwiftUI
import WebKit
#if canImport(MoongateCore)
import MoongateCore
#endif

/// 站点登录 sheet：内嵌 WKWebView 让用户登录，点「保存登录信息」后把
/// WKWebsiteDataStore.default() 的 cookies 导出为 Netscape 格式供 yt-dlp 使用。
/// 使用持久化的 default 数据存储，登录状态跨 App 重启保留。
struct LoginSheet: View {
    /// 站点 host，如 "youtube.com"
    let site: String
    /// cookies 写入成功后调用（由调用方关窗并触发重试）
    let onComplete: () -> Void
    let onCancel: () -> Void

    @State private var currentURL: String = ""
    @State private var errorText: String?
    @State private var loadErrorText: String?
    @State private var isLoading = false
    @State private var canGoBack = false
    @State private var isExporting = false
    @State private var webViewCommand: LoginWebViewCommand?
    @State private var hasSiteLoginCookies = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            LoginWebView(
                startURL: Self.startURL(for: site),
                currentURL: $currentURL,
                loadError: $loadErrorText,
                isLoading: $isLoading,
                canGoBack: $canGoBack,
                command: $webViewCommand
            )
        }
        .frame(width: 920, height: 640)
        .onAppear {
            refreshCookieReadiness()
        }
        .onChange(of: currentURL) { _, _ in
            refreshCookieReadiness()
        }
        .onChange(of: isLoading) { _, loading in
            guard !loading else { return }
            refreshCookieReadiness()
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("登录 \(siteDisplayName)")
                    .font(.headline)
                Text("在下方页面完成登录，然后点右上角「保存登录信息」")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !currentURL.isEmpty {
                    Text(displayedCurrentURL)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(cookieReadinessText)
                    .font(.caption)
                    .foregroundStyle(hasSiteLoginCookies ? .secondary : .tertiary)
            }
            Spacer(minLength: 12)
            HStack(spacing: 4) {
                Button {
                    webViewCommand = .back
                } label: {
                    Label {
                        Text("返回")
                    } icon: {
                        Image(systemName: "chevron.left")
                    }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(!canGoBack)
                .help("返回")
                .accessibilityLabel("返回")
                .accessibilityHint("返回上一页")

                Button {
                    webViewCommand = .reload
                } label: {
                    Label {
                        Text("重新载入")
                    } icon: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("重新载入")
                .accessibilityLabel("重新载入")
                .accessibilityHint("重新载入当前页面")

                Button {
                    openCurrentPageInBrowser()
                } label: {
                    Label {
                        Text("在浏览器中打开")
                    } icon: {
                        Image(systemName: "safari")
                    }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("在浏览器中打开")
                .accessibilityLabel("在浏览器中打开")
                .accessibilityHint("用系统默认浏览器打开当前页面")
            }
            .controlSize(.small)
            if isLoading {
                HStack(spacing: 6) {
                    ProgressView()
                        .accessibilityLabel("页面加载中")
                        .controlSize(.small)
                    Text("页面加载中")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let displayError = errorText ?? loadErrorText {
                Text(displayError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .frame(maxWidth: 260, alignment: .trailing)
            }
            Button("取消") {
                onCancel()
            }
            .buttonStyle(.bordered)
            Button {
                exportCookies()
            } label: {
                Text(isExporting ? "保存中…" : "保存登录信息")
            }
            .buttonStyle(.borderedProminent)
            .disabled(isExporting)
            .help(saveLoginHelpText)
            .accessibilityHint(saveLoginHelpText)
            .accessibilityValue(cookieReadinessText)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var saveLoginHelpText: String {
        if hasSiteLoginCookies {
            return "当前站点 Cookie 已就绪。保存到本 App，供下载器使用；不会在界面显示 Cookie 内容。"
        }
        return "还没有检测到当前站点 Cookie。可以继续登录，保存到本 App 后供下载器使用；不会在界面显示 Cookie 内容。"
    }

    private var cookieReadinessText: String {
        hasSiteLoginCookies ? "已检测到当前站点 Cookie" : "仍未检测到当前站点 Cookie"
    }

    private var currentPageURL: URL? {
        guard !currentURL.isEmpty else { return nil }
        return URL(string: currentURL)
    }

    private var displayedCurrentURL: String {
        Self.displayHost(from: currentURL)
    }

    private static func displayHost(from value: String) -> String {
        guard let components = URLComponents(string: value),
              let host = components.host,
              !host.isEmpty else {
            return value
        }
        let path = components.path
        guard !path.isEmpty, path != "/" else { return host }
        return host + path
    }

    private var siteDisplayName: String {
        let s = site.lowercased()
        if s.contains("youtube") { return "YouTube" }
        if s.contains("bilibili") { return "哔哩哔哩" }
        return site
    }

    /// 各站点的登录入口页。
    static func startURL(for site: String) -> URL {
        let s = site.lowercased()
        if s.contains("youtube.com") {
            return URL(string: "https://accounts.google.com/ServiceLogin?continue=https%3A%2F%2Fwww.youtube.com")!
        }
        if s.contains("bilibili.com") {
            return URL(string: "https://passport.bilibili.com/login")!
        }
        return URL(string: "https://\(site)") ?? URL(string: "https://www.bing.com")!
    }

    private func openCurrentPageInBrowser() {
        let url = currentPageURL ?? Self.startURL(for: site)
        NSWorkspace.shared.open(url)
    }

    private func refreshCookieReadiness() {
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            let readiness = Self.containsSiteCookie(in: cookies, matching: site)
            DispatchQueue.main.async {
                hasSiteLoginCookies = readiness
            }
        }
    }

    private static func containsSiteCookie(in cookies: [HTTPCookie], matching site: String) -> Bool {
        let targetHost = normalizedCookieHost(site)
        guard !targetHost.isEmpty else { return false }
        return cookies.contains { cookie in
            let domain = normalizedCookieHost(cookie.domain)
            return domain == targetHost || domain.hasSuffix(".\(targetHost)")
        }
    }

    private static func normalizedCookieHost(_ value: String) -> String {
        let rawValue = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parsedHost = URL(string: rawValue)?.host ?? rawValue
        return parsedHost.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    private func exportCookies() {
        isExporting = true
        errorText = nil
        let fileURL = AppSettings.cookieFileURL
        // httpCookieStore 要求主线程使用，回调也在主队列。
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            var failureText: String?
            do {
                try NetscapeCookieFile.write(cookies: cookies, to: fileURL)
            } catch {
                failureText = "保存登录信息失败：\(error.localizedDescription)"
            }
            finishExport(failureText)
        }
    }

    private func finishExport(_ failureText: String?) {
        isExporting = false
        if let failureText {
            errorText = failureText
        } else {
            onComplete()
        }
    }
}

enum LoginWebViewCommand: Equatable {
    case back
    case reload
}

/// WKWebView 的 SwiftUI 包装。用 WKWebsiteDataStore.default()（持久存储），
/// 登录产生的 cookies 跨重启保留。
struct LoginWebView: NSViewRepresentable {
    let startURL: URL
    @Binding var currentURL: String
    @Binding var loadError: String?
    @Binding var isLoading: Bool
    @Binding var canGoBack: Bool
    @Binding var command: LoginWebViewCommand?

    /// 桌面 Safari 的 UA：降低 Google 等站点对内嵌 WebView 的拦截概率。
    private static let safariUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

    func makeCoordinator() -> Coordinator {
        Coordinator(
            currentURL: $currentURL,
            loadError: $loadError,
            isLoading: $isLoading,
            canGoBack: $canGoBack,
            command: $command
        )
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = Self.safariUserAgent
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.load(URLRequest(url: startURL))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.currentURL = $currentURL
        context.coordinator.loadError = $loadError
        context.coordinator.isLoading = $isLoading
        context.coordinator.canGoBack = $canGoBack
        context.coordinator.command = $command
        context.coordinator.consumeCommand(in: nsView)
        context.coordinator.updateNavigationState(for: nsView)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var currentURL: Binding<String>
        var loadError: Binding<String?>
        var isLoading: Binding<Bool>
        var canGoBack: Binding<Bool>
        var command: Binding<LoginWebViewCommand?>

        init(
            currentURL: Binding<String>,
            loadError: Binding<String?>,
            isLoading: Binding<Bool>,
            canGoBack: Binding<Bool>,
            command: Binding<LoginWebViewCommand?>
        ) {
            self.currentURL = currentURL
            self.loadError = loadError
            self.isLoading = isLoading
            self.canGoBack = canGoBack
            self.command = command
        }

        func consumeCommand(in webView: WKWebView) {
            guard let pendingCommand = command.wrappedValue else { return }
            switch pendingCommand {
            case .back:
                if webView.canGoBack {
                    webView.goBack()
                }
            case .reload:
                webView.reload()
            }
            command.wrappedValue = nil
            updateNavigationState(for: webView)
        }

        func updateNavigationState(for webView: WKWebView) {
            canGoBack.wrappedValue = webView.canGoBack
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            isLoading.wrappedValue = true
            loadError.wrappedValue = nil
            updateNavigationState(for: webView)
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            isLoading.wrappedValue = true
            currentURL.wrappedValue = webView.url?.absoluteString ?? ""
            loadError.wrappedValue = nil
            updateNavigationState(for: webView)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoading.wrappedValue = false
            currentURL.wrappedValue = webView.url?.absoluteString ?? ""
            updateNavigationState(for: webView)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            reportLoadFailure(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            reportLoadFailure(error)
        }

        /// 登录流程的重定向会频繁打断在途请求（NSURLErrorCancelled），不算失败。
        private func reportLoadFailure(_ error: Error) {
            isLoading.wrappedValue = false
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            loadError.wrappedValue = "页面加载失败，请检查网络后重试"
        }

        /// 弹窗 / target=_blank：直接在当前 webView 里打开，不创建新窗口。
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let url = navigationAction.request.url {
                webView.load(URLRequest(url: url))
            }
            return nil
        }
    }
}
