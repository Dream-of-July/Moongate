import Foundation

// MARK: - 默认引擎

public func makeDefaultEngine() -> any DownloadEngine {
    YtDlpEngine()
}

// MARK: - 跨线程小工具

/// 进程输出缓冲（多队列并发写入时加锁）。
private final class DataBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ data: Data) {
        lock.lock()
        storage.append(data)
        lock.unlock()
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// 收集 yt-dlp --print 输出的产出文件路径（输出回调线程并发追加）。
private final class PathCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []

    func append(_ path: String) {
        lock.lock()
        if !paths.contains(path) { paths.append(path) }
        lock.unlock()
    }

    /// 重试下载前清空上一轮收集到的产出路径，避免失败轮的残留串入。
    func reset() {
        lock.lock()
        paths.removeAll()
        lock.unlock()
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return paths
    }
}

/// 持有子进程引用，支持跨任务取消与超时标记。
private final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var timedOutFlag = false

    /// 返回 true 表示注册前已请求取消，调用方需立即终止子进程。
    func register(_ p: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        process = p
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let p = process
        lock.unlock()
        guard let p, p.isRunning else { return }
        p.terminate()
        // SIGTERM 不进树也可能被无视：3 秒后整棵进程树 SIGKILL 兜底，
        // 防止孙进程占着管道写端让 EOF 永不到来。
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if p.isRunning {
                TaskControlToken.signalTree(p.processIdentifier, SIGKILL)
            }
        }
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func markTimedOut() {
        lock.lock()
        timedOutFlag = true
        lock.unlock()
    }

    var timedOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timedOutFlag
    }
}

/// 流式下载进程的共享状态：stdout 行缓冲（半行拼接）、stderr 尾部、单次 resume 保护。
/// 进程停滞（看门狗超时无任何输出被强杀）。调用方据此映射为各自的友好错误。
struct ProcessStalledError: Error {}

private final class StreamingState: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var resumed = false
    private var lineBuffer = Data()
    private var stderrData = Data()
    private let stderrLimit = 16 * 1024
    private var lastActivity = Date()
    private var stalledFlag = false
    private var stallTimer: DispatchSourceTimer?

    func register(_ p: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        process = p
        lastActivity = Date()
        return cancelled
    }

    /// 刷新活动时间（有任何输出 / 暂停期间由看门狗代为刷新）。
    func touch() {
        lock.lock()
        lastActivity = Date()
        lock.unlock()
    }

    var isStalled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stalledFlag
    }

    /// 看门狗：静默超过 timeout 则标记停滞并强杀进程树（含子进程）。
    func killIfSilent(longerThan timeout: TimeInterval) {
        lock.lock()
        let silent = Date().timeIntervalSince(lastActivity) > timeout
        if silent { stalledFlag = true }
        let p = process
        lock.unlock()
        guard silent, let p, p.isRunning else { return }
        let pid = p.processIdentifier
        for child in Self.childProcessIDs(of: pid) {
            kill(child, SIGKILL)
        }
        if p.isRunning { kill(pid, SIGKILL) }
    }

    func setStallTimer(_ timer: DispatchSourceTimer) {
        lock.lock()
        stallTimer = timer
        lock.unlock()
    }

    func cancelStallTimer() {
        lock.lock()
        let timer = stallTimer
        stallTimer = nil
        lock.unlock()
        timer?.cancel()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let p = process
        lock.unlock()
        guard let p, p.isRunning else { return }
        // 先发 SIGINT，让 yt-dlp 走自身的 KeyboardInterrupt 清理逻辑；
        // 3 秒后仍未退出则先杀 ffmpeg 等子进程，再强杀 yt-dlp 本身。
        p.interrupt()
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            guard p.isRunning else { return }
            let pid = p.processIdentifier
            for child in Self.childProcessIDs(of: pid) {
                kill(child, SIGKILL)
            }
            if p.isRunning { kill(pid, SIGKILL) }
        }
    }

    /// 用 pgrep 找直接子进程（ffmpeg 等）。
    private static func childProcessIDs(of pid: Int32) -> [Int32] {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-P", String(pid)]
        let pipe = Pipe()
        pgrep.standardOutput = pipe
        pgrep.standardError = FileHandle.nullDevice
        do { try pgrep.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        pgrep.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func appendStderr(_ data: Data) {
        lock.lock()
        stderrData.append(data)
        if stderrData.count > stderrLimit {
            stderrData.removeFirst(stderrData.count - stderrLimit)
        }
        lastActivity = Date()
        lock.unlock()
    }

    var stderrTail: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: stderrData, as: UTF8.self)
    }

    /// 追加 stdout 数据，返回新凑齐的完整行（不含换行符）。
    func consumeLines(appending data: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        lastActivity = Date()
        lineBuffer.append(data)
        var lines: [String] = []
        while let index = lineBuffer.firstIndex(of: 0x0A) {
            let lineData = lineBuffer.subdata(in: lineBuffer.startIndex..<index)
            lineBuffer.removeSubrange(lineBuffer.startIndex...index)
            var line = String(decoding: lineData, as: UTF8.self)
            if line.hasSuffix("\r") { line.removeLast() }
            if !line.isEmpty { lines.append(line) }
        }
        return lines
    }

    func flushRemainder() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        guard !lineBuffer.isEmpty else { return [] }
        let line = String(decoding: lineBuffer, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        lineBuffer.removeAll()
        return line.isEmpty ? [] : [line]
    }

    func resumeOnce(_ body: () -> Void) {
        lock.lock()
        let shouldRun = !resumed
        resumed = true
        lock.unlock()
        if shouldRun { body() }
    }
}

private struct ProcessOutput {
    let status: Int32
    let stdout: Data
    let stderr: Data
    let timedOut: Bool
}

// MARK: - YtDlpEngine

public final class YtDlpEngine: DownloadEngine, @unchecked Sendable {

    private let cacheLock = NSLock()
    private var infoCache: [String: [String: Any]] = [:]
    private var infoCacheOrder: [String] = []
    /// analyze 阶段从 HLS master m3u8 解析出的字幕表：sourceURL -> [langCode: 字幕 m3u8 绝对 URL]。
    /// download 阶段据此用 ffmpeg 取这些 yt-dlp 拿不到的 HLS 内嵌字幕。
    private var hlsSubtitleCache: [String: [String: String]] = [:]
    private var hlsCacheOrder: [String] = []

    final class DownloadProgressTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var highestPercent: Double = 0

        func normalizedPercent(_ percent: Double?) -> Double? {
            guard let percent else { return nil }
            let clamped = min(max(percent, 0), 100)
            lock.lock()
            defer { lock.unlock() }
            highestPercent = max(highestPercent, clamped)
            return highestPercent
        }
    }

    public init() {}

    // MARK: 二进制定位

    #if os(Windows)
    /// Windows：沿 PATH（; 分隔，键大小写不敏感）找 <name>.exe。
    private static func locateBinary(named name: String, envVar: String) -> String? {
        let fm = FileManager.default
        let env = ProcessInfo.processInfo.environment
        if let custom = env[envVar], !custom.isEmpty, fm.isExecutableFile(atPath: custom) {
            return custom
        }
        let exe = name.lowercased().hasSuffix(".exe") ? name : name + ".exe"
        let pathValue = env.first { $0.key.lowercased() == "path" }?.value ?? ""
        for dir in pathValue.split(separator: ";") {
            let candidate = String(dir) + "\\" + exe
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
    #else
    private static let searchDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]

    private static func locateBinary(named name: String, envVar: String) -> String? {
        let fm = FileManager.default
        if let custom = ProcessInfo.processInfo.environment[envVar],
           !custom.isEmpty, fm.isExecutableFile(atPath: custom) {
            return custom
        }
        for dir in searchDirectories {
            let path = dir + "/" + name
            if fm.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }
    #endif

    private func ytDlpPath() throws -> String {
        guard let path = Self.locateBinary(named: "yt-dlp", envVar: "MOONGATE_YTDLP_PATH") else {
            throw MoongateError.binaryNotFound("yt-dlp")
        }
        return path
    }

    private func ffmpegDirectory() throws -> String {
        guard let path = Self.locateBinary(named: "ffmpeg", envVar: "MOONGATE_FFMPEG_PATH") else {
            throw MoongateError.binaryNotFound("ffmpeg")
        }
        return (path as NSString).deletingLastPathComponent
    }

    /// HLS 字幕转 srt 用的 ffmpeg：与 Burner 一致优先 ffmpeg-full，其次 Homebrew ffmpeg。
    /// （转 srt 不需要 libass，但统一定位逻辑、避免精简版边角问题。）
    private static func locateSubtitleFFmpeg() -> String? {
        let fm = FileManager.default
        let candidates = [
            "/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg",
            "/usr/local/opt/ffmpeg-full/bin/ffmpeg",
        ]
        for path in candidates where fm.isExecutableFile(atPath: path) { return path }
        return locateBinary(named: "ffmpeg", envVar: "MOONGATE_FFMPEG_PATH")
    }

    private func ffprobePath() -> String? {
        Self.locateBinary(named: "ffprobe", envVar: "MOONGATE_FFPROBE_PATH")
    }

    /// 子进程环境。GUI App 从 Finder 启动时 PATH 只有系统目录，而 yt-dlp 解
    /// YouTube 的 n-challenge 必须能找到 Homebrew 里的 deno/node（JS 运行时），
    /// 否则所有视频格式都会被跳过（"Requested format is not available"）。
    static func subprocessEnvironment() -> [String: String] {
        #if os(Windows)
        // Windows：PATH 原样透传（deno/node/yt-dlp/ffmpeg 需用户装在 PATH 里）。
        return ProcessInfo.processInfo.environment
        #else
        var env = ProcessInfo.processInfo.environment
        var parts = (env["PATH"] ?? "/usr/bin:/bin").components(separatedBy: ":")
        for dir in ["/usr/local/bin", "/opt/homebrew/bin"] where !parts.contains(dir) {
            parts.insert(dir, at: 0)
        }
        env["PATH"] = parts.joined(separator: ":")
        return env
        #endif
    }

    // MARK: 系统代理（中国大陆 VPN/代理跟随）

    /// 读取系统代理并构造 yt-dlp `--proxy` 参数；默认「跟随系统」，无需任何设置项。
    ///
    /// 背景：macOS App 从访达启动时不继承 shell 的 HTTP(S)_PROXY 环境变量，而 yt-dlp 是
    /// 独立子进程、不会自动感知 macOS 系统代理。结果是用户开了 Clash/Surge（系统代理或 TUN）
    /// 仍可能下不动 YouTube。这里显式把系统代理传给 yt-dlp。优先 SOCKS（Clash/Surge 常用），
    /// 其次 HTTPS、HTTP。读不到则返回空（保持原行为，不影响国内站点/直连）。
    static func systemProxyArguments() -> [String] {
        #if os(Windows)
        // Windows：yt-dlp 经 WinINET 已能感知系统代理，无需显式传。
        return []
        #else
        // 环境变量优先（用户/终端显式设置时尊重之）。
        let env = ProcessInfo.processInfo.environment
        for key in ["https_proxy", "HTTPS_PROXY", "http_proxy", "HTTP_PROXY", "all_proxy", "ALL_PROXY"] {
            if let v = env[key], !v.trimmingCharacters(in: .whitespaces).isEmpty {
                return ["--proxy", v]
            }
        }
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue()
            as? [String: Any] else { return [] }
        func str(_ key: CFString) -> String? { settings[key as String] as? String }
        func num(_ key: CFString) -> Int? { (settings[key as String] as? NSNumber)?.intValue }
        func enabled(_ key: CFString) -> Bool { (settings[key as String] as? NSNumber)?.intValue == 1 }
        // SOCKS 优先（Clash/Surge 常配 socks5）。
        if enabled(kCFNetworkProxiesSOCKSEnable), let host = str(kCFNetworkProxiesSOCKSProxy) {
            let port = num(kCFNetworkProxiesSOCKSPort) ?? 1080
            return ["--proxy", "socks5://\(host):\(port)"]
        }
        if enabled(kCFNetworkProxiesHTTPSEnable), let host = str(kCFNetworkProxiesHTTPSProxy) {
            let port = num(kCFNetworkProxiesHTTPSPort) ?? 443
            return ["--proxy", "http://\(host):\(port)"]
        }
        if enabled(kCFNetworkProxiesHTTPEnable), let host = str(kCFNetworkProxiesHTTPProxy) {
            let port = num(kCFNetworkProxiesHTTPPort) ?? 80
            return ["--proxy", "http://\(host):\(port)"]
        }
        return []
        #endif
    }

    // MARK: 站点登录 cookies

    /// 站点登录导出的 cookies 文件存在时，所有 yt-dlp 调用都带上 --cookies。
    /// yt-dlp 的 --cookies 是「读取并在退出时**写回**」语义：并发任务共用主 cookies.txt
    /// 会互相覆写甚至损坏，写回还会把 0600 权限放宽。因此每次启动子进程都发一份
    /// 任务私有临时副本（写回只落在副本上），用后由 cleanup 删除。
    private static func makeCookieArguments() -> (args: [String], cleanup: @Sendable () -> Void) {
        let master = AppSettings.cookieFileURL
        guard FileManager.default.fileExists(atPath: master.path) else { return ([], {}) }
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("moongate-cookies-\(UUID().uuidString).txt")
        do {
            try FileManager.default.copyItem(at: master, to: temp)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: temp.path
            )
        } catch {
            return ([], {})  // 副本失败就不带 cookies，不阻塞下载
        }
        return (["--cookies", temp.path], { try? FileManager.default.removeItem(at: temp) })
    }

    /// 识别"需要登录"类错误。命中返回 loginRequired（或已登录时的过期文案），否则返回 nil 走常规文案。
    private static func detectLoginRequired(stderr: String, url urlString: String) -> MoongateError? {
        let hasCookies = FileManager.default.fileExists(atPath: AppSettings.cookieFileURL.path)
        return detectLoginRequired(stderr: stderr, url: urlString, hasCookies: hasCookies)
    }

    private static func detectLoginRequired(stderr: String, url urlString: String, hasCookies: Bool) -> MoongateError? {
        if stderr.contains("Sign in to confirm") {
            // 已登录过仍被风控：再弹登录窗没有意义，提示重新登录或稍后重试。
            if hasCookies {
                return .downloadFailed(CoreL10n.text(
                    en: "YouTube requires login confirmation. Your saved login may have expired; log in again in Settings or retry later.",
                    zhHans: "YouTube 要求确认登录状态。登录信息可能已过期，可在设置里重新登录，或稍后重试。",
                    zhHant: "YouTube 要求確認登入狀態。已儲存的登入資訊可能已過期；可在設定裡重新登入，或稍後重試。"
                ))
            }
            return .loginRequired("youtube.com")
        }
        let host = (URL(string: urlString)?.host ?? "").lowercased()
        let lowerStderr = stderr.lowercased()
        if isBilibiliHost(host),
           !hasCookies,
           (lowerStderr.contains("412") || lowerStderr.contains("precondition failed")) {
            return .loginRequired("bilibili.com")
        }
        // YouTube 的 403 实质是 PO token / 未登录，登录 cookies 是正解；其他站点的 403 保持防盗链文案。
        // 只看最后一条 ERROR 行，避免中间分片的瞬时 403 被误判成需要登录。
        if isYouTubeHost(host), summarizeStderr(stderr).contains("HTTP Error 403") {
            if hasCookies {
                return .downloadFailed(CoreL10n.text(
                    en: "YouTube rejected the request (403). Your saved login may have expired; log in again in Settings or retry later.",
                    zhHans: "YouTube 拒绝了请求（403）。登录信息可能已过期，可在设置里重新登录，或稍后重试。",
                    zhHant: "YouTube 拒絕了請求（403）。已儲存的登入資訊可能已過期；可在設定裡重新登入，或稍後重試。"
                ))
            }
            return .loginRequired("youtube.com")
        }
        let pattern = "login required|need to log ?in|requires? (?:a )?login|account cookies|cookies.*(?:required|--cookies)|members?[- ]only|premium|sign ?in|authenticat|登录|登陆|大会员|会员|付费|请先登录|需要登录"
        if stderr.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
            var site = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            if site.isEmpty {
                site = CoreL10n.text(en: "This site", zhHans: "该站点", zhHant: "此站點")
            }
            return .loginRequired(site)
        }
        return nil
    }

    /// 测试用：暴露登录检测与风控检测，验证未登录失败会被识别为 .loginRequired。
    static func _testLoginRequired(stderr: String, url: String) -> MoongateError? {
        detectLoginRequired(stderr: stderr, url: url)
    }

    static func _testLoginRequired(stderr: String, url: String, hasCookies: Bool) -> MoongateError? {
        detectLoginRequired(stderr: stderr, url: url, hasCookies: hasCookies)
    }

    static func _testRiskControlMessage(stderr: String, host: String) -> String? {
        riskControlMessage(stderr: stderr, host: host)
    }

    static func _testIsNativeExtractorHost(_ host: String) -> Bool {
        isNativeExtractorHost(host)
    }

    // MARK: 信息缓存

    /// 缓存条数上限：单条 YouTube -J JSON 可达 1-2MB，引擎与 App 同寿命，
    /// 不设上限的话长会话内存只增不减。FIFO 淘汰最旧的。
    private static let cacheLimit = 32

    private func cachedInfo(for url: String) -> [String: Any]? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return infoCache[url]
    }

    private func setCachedInfo(_ info: [String: Any], for url: String) {
        cacheLock.lock()
        if infoCache[url] == nil {
            infoCacheOrder.append(url)
            if infoCacheOrder.count > Self.cacheLimit {
                let evicted = infoCacheOrder.removeFirst()
                infoCache.removeValue(forKey: evicted)
            }
        }
        infoCache[url] = info
        cacheLock.unlock()
    }

    private func cachedHLSSubtitles(for url: String) -> [String: String]? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return hlsSubtitleCache[url]
    }

    private func setCachedHLSSubtitles(_ table: [String: String], for url: String) {
        cacheLock.lock()
        if hlsSubtitleCache[url] == nil {
            hlsCacheOrder.append(url)
            if hlsCacheOrder.count > Self.cacheLimit {
                let evicted = hlsCacheOrder.removeFirst()
                hlsSubtitleCache.removeValue(forKey: evicted)
            }
        }
        hlsSubtitleCache[url] = table
        cacheLock.unlock()
    }

    // MARK: - 第一步：解析候选

    public func resolveCandidates(for input: String) async throws -> [VideoCandidate] {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else {
            throw MoongateError.sniffFailed(CoreL10n.text(
                en: "Check the link format.",
                zhHans: "请检查链接格式。",
                zhHant: "請檢查連結格式。"
            ))
        }

        switch try await runYtDlpJSON(for: trimmed) {
        case .success(let json):
            setCachedInfo(json, for: trimmed)
            let title = (json["title"] as? String) ?? trimmed
            let detail = json["extractor_key"] as? String
            return [VideoCandidate(url: trimmed, kind: .supported, title: title, detail: detail)]

        case .failure(let stderr):
            if let loginError = Self.detectLoginRequired(stderr: stderr, url: trimmed) {
                throw loginError
            }
            let host = url.host ?? ""
            // 风控（如 bilibili 412）：直接给诚实原因，不要回退嗅探显示「页面加载失败」。
            if let riskMessage = Self.riskControlMessage(stderr: stderr, host: host) {
                throw MoongateError.analyzeFailed(riskMessage)
            }
            // yt-dlp 原生支持的站点（YouTube/bilibili 等）解析失败，回退嗅探没有意义，直接给原因。
            if Self.isNativeExtractorHost(host) {
                throw MoongateError.analyzeFailed(Self.friendlyAnalyzeMessage(stderr))
            }
            let candidates: [VideoCandidate]
            do {
                candidates = try await PageSniffer().sniff(pageURL: url)
            } catch let error as MoongateError {
                throw error
            } catch {
                throw MoongateError.sniffFailed(CoreL10n.text(
                    en: "Page loading failed. Try again later.",
                    zhHans: "页面加载失败，请稍后重试。",
                    zhHant: "頁面載入失敗，請稍後重試。"
                ))
            }
            guard !candidates.isEmpty else {
                throw MoongateError.sniffFailed(CoreL10n.text(
                    en: "Try another page, or paste a direct video file URL.",
                    zhHans: "可以换个页面，或直接粘贴视频文件地址。",
                    zhHant: "可以換個頁面，或直接貼上影片檔案地址。"
                ))
            }
            return candidates
        }
    }

    // MARK: - 第二步：解析格式与字幕

    public func analyze(url: String) async throws -> VideoInfo {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let json: [String: Any]
        if let cached = cachedInfo(for: trimmed) {
            json = cached
        } else {
            switch try await runYtDlpJSON(for: trimmed) {
            case .success(let dict):
                setCachedInfo(dict, for: trimmed)
                json = dict
            case .failure(let stderr):
                if let loginError = Self.detectLoginRequired(stderr: stderr, url: trimmed) {
                    throw loginError
                }
                if let riskMessage = Self.riskControlMessage(stderr: stderr, host: URL(string: trimmed)?.host ?? "") {
                    throw MoongateError.analyzeFailed(riskMessage)
                }
                throw MoongateError.analyzeFailed(Self.friendlyAnalyzeMessage(stderr))
            }
        }
        return await buildVideoInfo(sourceURL: trimmed, json: json)
    }

    private enum YtDlpJSONResult {
        case success([String: Any])
        case failure(stderr: String)
    }

    private func runYtDlpJSON(for url: String) async throws -> YtDlpJSONResult {
        let ytdlp = try ytDlpPath()
        let ffmpegDir = try ffmpegDirectory()
        let cookie = Self.makeCookieArguments()
        defer { cookie.cleanup() }
        var lastStderr = ""
        for attempt in 0..<2 {
            let output = try await Self.runProcess(
                executable: ytdlp,
                arguments: ["-J", "--no-playlist", "--ffmpeg-location", ffmpegDir]
                    + Self.systemProxyArguments() + cookie.args + [url],
                // 90s 而非 60s：中国大陆经代理/VPN 访问时握手+TLS+deno 冷启动延迟更高。
                timeout: 90
            )
            if output.timedOut {
                throw MoongateError.analyzeFailed(CoreL10n.text(
                    en: "Parsing timed out. Check the network and retry.",
                    zhHans: "解析超时，请检查网络后重试",
                    zhHant: "解析逾時，請檢查網路後重試"
                ))
            }
            if output.status == 0,
               let object = try? JSONSerialization.jsonObject(with: output.stdout),
               var dict = object as? [String: Any] {
                // --no-playlist 之下仍可能拿到 playlist 包装，取第一个条目兜底。
                if dict["_type"] as? String == "playlist",
                   let entries = dict["entries"] as? [[String: Any]],
                   let first = entries.first {
                    dict = first
                }
                return .success(dict)
            }
            lastStderr = String(decoding: output.stderr, as: UTF8.self)
            // YouTube 偶发返回空格式列表（"Requested format is not available"），
            // 属临时风控，隔 2 秒自动重试一次。
            if attempt == 0, lastStderr.contains("Requested format is not available") {
                do { try await Task.sleep(nanoseconds: 2_000_000_000) }
                catch { throw MoongateError.cancelled }
                continue
            }
            break
        }
        return .failure(stderr: lastStderr)
    }

    /// 只取字幕文本（不下载视频），供 AI 内容总结使用。最佳努力：失败/无字幕返回 nil。
    /// yt-dlp --skip-download --write-subs --write-auto-subs --convert-subs srt 到临时目录，
    /// 再用 parseSRT + cleanCues 提纯成纯文本。
    public func fetchSubtitleText(
        url: String,
        preferredLanguages: [String],
        control: TaskControlToken?
    ) async throws -> String? {
        if Task.isCancelled { throw MoongateError.cancelled }
        guard let ytdlp = try? ytDlpPath(), let ffmpegDir = try? ffmpegDirectory() else {
            return nil
        }
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("moongate-subs-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // 语言优先级：调用方给的偏好（如字幕选择/源语言）在前，再兜底常见语言。
        let langs = (preferredLanguages + ["en", "en-US", "zh-Hans", "zh", "ja", "ko"])
            .filter { !$0.isEmpty }
        let langArg = langs.isEmpty ? "all" : (langs.joined(separator: ",") + ",all")

        let cookie = Self.makeCookieArguments()
        defer { cookie.cleanup() }
        var args = [
            "--skip-download", "--no-playlist", "--ffmpeg-location", ffmpegDir,
            "--write-subs", "--write-auto-subs", "--sub-langs", langArg,
            "--convert-subs", "srt",
            "-o", tempDir.appendingPathComponent("%(id)s.%(ext)s").path,
        ]
        args += Self.systemProxyArguments()
        args += cookie.args
        args.append(url)

        let output = try? await Self.runProcess(executable: ytdlp, arguments: args, timeout: 60)
        if Task.isCancelled { throw MoongateError.cancelled }
        guard output != nil else { return nil }

        // 收集临时目录里的 .srt，按语言偏好挑一个，转成纯文本。
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: tempDir, includingPropertiesForKeys: nil
        ) else { return nil }
        let srtFiles = files.filter { $0.pathExtension.lowercased() == "srt" }
        guard !srtFiles.isEmpty else { return nil }

        func score(_ file: URL) -> Int {
            guard let code = Self.langCode(ofSubtitle: file) else { return langs.count }
            for (i, lang) in langs.enumerated() where code.hasPrefix(lang.lowercased()) {
                return i
            }
            return langs.count
        }
        let chosen = srtFiles.min { score($0) < score($1) } ?? srtFiles[0]

        guard let raw = try? String(contentsOf: chosen, encoding: .utf8) else { return nil }
        let cues = cleanCues(parseSRT(raw))
        guard !cues.isEmpty else { return nil }
        let text = cues.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func buildVideoInfo(sourceURL: String, json: [String: Any]) async -> VideoInfo {
        let videoID = (json["id"] as? String) ?? (json["display_id"] as? String) ?? "video"
        let title = (json["title"] as? String) ?? sourceURL
        var durationText = Self.doubleValue(json["duration"]).map(Self.formatDuration)
        let thumbnailURL = (json["thumbnail"] as? String).flatMap(URL.init(string:))
        let uploader = (json["uploader"] as? String) ?? (json["channel"] as? String)

        let rawFormats = (json["formats"] as? [[String: Any]]) ?? []
        let videoFormats = rawFormats.filter { format in
            (format["vcodec"] as? String) != "none" && (Self.intValue(format["height"]) ?? 0) > 0
        }

        var formats: [FormatChoice] = []

        if !videoFormats.isEmpty {
            let heights = Array(Set(videoFormats.compactMap { Self.intValue($0["height"]) }))
                .sorted(by: >)
            let audioBytes = Self.bestAudioSizeBytes(in: rawFormats)

            func tierDetail(_ height: Int) -> String? {
                let tier = videoFormats.filter { Self.intValue($0["height"]) == height }
                let best = tier.max {
                    (Self.doubleValue($0["tbr"]) ?? 0) < (Self.doubleValue($1["tbr"]) ?? 0)
                }
                let videoBytes = best.flatMap {
                    Self.doubleValue($0["filesize"]) ?? Self.doubleValue($0["filesize_approx"])
                } ?? tier.compactMap {
                    Self.doubleValue($0["filesize"]) ?? Self.doubleValue($0["filesize_approx"])
                }.max()
                guard let videoBytes else { return nil }
                return Self.sizeText(bytes: videoBytes + (audioBytes ?? 0))
            }

            // 最高档直接排第一（formats[0] 为推荐项），用通配格式串拿最佳画质。
            for (index, height) in heights.prefix(6).enumerated() {
                let formatID = index == 0
                    ? "bv*+ba/b"
                    : "bv*[height<=\(height)]+ba/b[height<=\(height)]"
                let tier = videoFormats.filter { Self.intValue($0["height"]) == height }
                // 该档是否有 HDR 流。
                let hdrAvailable = tier.contains {
                    DynamicRange(ytDlpValue: $0["dynamic_range"] as? String).isHDR
                }
                // 源编码/容器：取该档码率最高那个流的信息用于标注与转码决策。
                let bestStream = tier.max {
                    (Self.doubleValue($0["tbr"]) ?? 0) < (Self.doubleValue($1["tbr"]) ?? 0)
                }
                let vcodec = (bestStream?["vcodec"] as? String).map(Self.shortVCodec)
                let container = bestStream?["ext"] as? String
                var label = "\(height)p"
                if hdrAvailable {
                    label += CoreL10n.text(en: " · HDR available", zhHans: " · 可选 HDR", zhHant: " · 可選 HDR")
                }
                formats.append(FormatChoice(
                    id: formatID,
                    label: label,
                    detail: tierDetail(height),
                    hdrAvailable: hdrAvailable,
                    sourceVCodec: vcodec,
                    sourceContainer: container
                ))
            }
        } else {
            // 直链文件：单一格式，无分档信息。
            let urlExt = URL(string: sourceURL)?.pathExtension ?? ""
            let ext = (json["ext"] as? String) ?? (urlExt.isEmpty ? "mp4" : urlExt)
            var label = "\(CoreL10n.text(en: "Original file", zhHans: "原始文件", zhHant: "原始檔")) · \(ext)"
            var sizeDetail: String?
            if let first = rawFormats.first,
               let bytes = Self.doubleValue(first["filesize"]) ?? Self.doubleValue(first["filesize_approx"]) {
                sizeDetail = Self.sizeText(bytes: bytes)
            }
            let mediaURL = (json["url"] as? String)
                ?? rawFormats.first.flatMap { $0["url"] as? String }
                ?? sourceURL
            if let probe = await runFFProbe(on: mediaURL) {
                if let height = probe.height { label += " · \(height)p" }
                if durationText == nil, let seconds = probe.duration {
                    durationText = Self.formatDuration(seconds)
                }
                if sizeDetail == nil, let bytes = probe.sizeBytes {
                    sizeDetail = Self.sizeText(bytes: bytes)
                }
            }
            if sizeDetail == nil, let bytes = await headContentLength(of: mediaURL) {
                sizeDetail = Self.sizeText(bytes: bytes)
            }
            formats.append(FormatChoice(id: "best", label: label, detail: sizeDetail))
        }

        formats.append(FormatChoice(
            id: "audio",
            label: "\(CoreL10n.text(en: "Audio only", zhHans: "仅音频", zhHant: "僅音訊")) · m4a",
            detail: nil,
            isAudioOnly: true
        ))

        var subtitles = Self.parseSubtitles(json: json)
        // yt-dlp 没给字幕时（如 Apple WWDC 等走 generic/HLS 提取器的页面，字幕只存在于
        // HLS master manifest 里且被 yt-dlp 主动忽略），从 manifest 兜底解析内嵌字幕。
        if subtitles.isEmpty {
            let (choices, table) = await discoverHLSSubtitles(in: rawFormats)
            if !choices.isEmpty {
                subtitles = choices
                setCachedHLSSubtitles(table, for: sourceURL)
            }
        }

        let description = (json["description"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return VideoInfo(
            sourceURL: sourceURL,
            videoID: videoID,
            title: title,
            durationText: durationText,
            thumbnailURL: thumbnailURL,
            uploader: uploader,
            description: (description?.isEmpty == false) ? description : nil,
            formats: formats,
            subtitles: subtitles
        )
    }

    // MARK: HLS manifest 内嵌字幕兜底

    /// 从 formats 的 manifest_url 抓取 HLS master m3u8，解析其中的 EXT-X-MEDIA:TYPE=SUBTITLES，
    /// 返回（SubtitleChoice 列表, [langCode: 字幕 m3u8 绝对 URL]）。失败返回空，绝不抛错（不能让 analyze 失败）。
    private func discoverHLSSubtitles(
        in formats: [[String: Any]]
    ) async -> (choices: [SubtitleChoice], table: [String: String]) {
        guard let manifest = formats.compactMap({ $0["manifest_url"] as? String })
            .first(where: { !$0.isEmpty }),
              let masterURL = URL(string: manifest),
              let text = await Self.fetchText(url: masterURL) else {
            return ([], [:])
        }
        let entries = Self.parseHLSSubtitleEntries(master: text, baseURL: masterURL)
        guard !entries.isEmpty else { return ([], [:]) }

        var table: [String: String] = [:]
        var seen = Set<String>()
        var choices: [SubtitleChoice] = []
        // 中文优先排序，最多保留 30 条。
        let sorted = entries.sorted { Self.subtitleSortKey($0.lang) < Self.subtitleSortKey($1.lang) }
        for entry in sorted.prefix(30) {
            guard !seen.contains(entry.lang) else { continue }
            seen.insert(entry.lang)
            table[entry.lang] = entry.url
            let label: String
            let localized = Self.subtitleLabel(for: entry.lang)
            // subtitleLabel 认得的语言用本地化名，否则退回 manifest 里的 NAME。
            if localized != entry.lang {
                label = localized
            } else if let name = entry.name, !name.isEmpty {
                label = "\(name) (\(entry.lang))"
            } else {
                label = entry.lang
            }
            choices.append(SubtitleChoice(id: entry.lang, label: label, isAuto: false))
        }
        return (choices, table)
    }

    private struct HLSSubtitleEntry {
        let lang: String
        let name: String?
        let url: String
    }

    /// 解析 master m3u8 文本里所有 TYPE=SUBTITLES 的媒体行；URI 相对 baseURL 解析为绝对地址。
    private static func parseHLSSubtitleEntries(master: String, baseURL: URL) -> [HLSSubtitleEntry] {
        var entries: [HLSSubtitleEntry] = []
        for line in master.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("#EXT-X-MEDIA:"), trimmed.contains("TYPE=SUBTITLES") else { continue }
            guard let lang = attribute("LANGUAGE", in: trimmed), !lang.isEmpty,
                  let uri = attribute("URI", in: trimmed), !uri.isEmpty else { continue }
            let resolved: String
            if let abs = URL(string: uri), abs.scheme != nil {
                resolved = abs.absoluteString
            } else if let rel = URL(string: uri, relativeTo: baseURL) {
                resolved = rel.absoluteString
            } else {
                continue
            }
            entries.append(HLSSubtitleEntry(lang: lang, name: attribute("NAME", in: trimmed), url: resolved))
        }
        return entries
    }

    /// 从 EXT-X-MEDIA 行里取属性值（支持带引号与不带引号）。
    private static func attribute(_ key: String, in line: String) -> String? {
        guard let range = line.range(of: key + "=") else { return nil }
        let rest = line[range.upperBound...]
        if rest.first == "\"" {
            let afterQuote = rest.dropFirst()
            guard let end = afterQuote.firstIndex(of: "\"") else { return nil }
            return String(afterQuote[..<end])
        }
        let end = rest.firstIndex(of: ",") ?? rest.endIndex
        return String(rest[..<end]).trimmingCharacters(in: .whitespaces)
    }

    /// 同步等待的文本抓取（Safari UA、15s 超时）。失败返回 nil。
    private static func fetchText(url: URL) async -> String? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(PageSniffer.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: ffprobe / HEAD 补充信息

    private struct ProbeInfo {
        var height: Int?
        var duration: Double?
        var sizeBytes: Double?
    }

    private func runFFProbe(on urlString: String) async -> ProbeInfo? {
        guard let ffprobe = ffprobePath() else { return nil }
        guard let output = try? await Self.runProcess(
            executable: ffprobe,
            arguments: ["-v", "quiet", "-print_format", "json", "-show_format", "-show_streams", urlString],
            timeout: 20
        ), output.status == 0,
        let object = try? JSONSerialization.jsonObject(with: output.stdout),
        let dict = object as? [String: Any] else { return nil }

        var info = ProbeInfo()
        if let streams = dict["streams"] as? [[String: Any]],
           let video = streams.first(where: { ($0["codec_type"] as? String) == "video" }) {
            info.height = Self.intValue(video["height"])
        }
        if let format = dict["format"] as? [String: Any] {
            info.duration = Self.doubleValue(format["duration"])
            info.sizeBytes = Self.doubleValue(format["size"])
        }
        return info
    }

    private func headContentLength(of urlString: String) async -> Double? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 15
        request.setValue(PageSniffer.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        let length = http.expectedContentLength
        return length > 0 ? Double(length) : nil
    }

    // MARK: 字幕

    private static let autoCaptionAllowList: Set<String> = ["zh-Hans", "zh-Hant", "zh", "en", "en-orig", "ja"]

    private static func parseSubtitles(json: [String: Any]) -> [SubtitleChoice] {
        let videoLangPrefix = (json["language"] as? String)?
            .split(separator: "-").first.map { String($0).lowercased() }

        let realDict = (json["subtitles"] as? [String: Any]) ?? [:]
        let realCodes = realDict.keys.filter { $0 != "live_chat" && $0 != "rechat" }
        var real = realCodes.map { SubtitleChoice(id: $0, label: subtitleLabel(for: $0), isAuto: false) }
        real.sort { subtitleSortKey($0.id) < subtitleSortKey($1.id) }

        let autoDict = (json["automatic_captions"] as? [String: Any]) ?? [:]
        let realSet = Set(realCodes)
        var autoCodes = autoDict.keys.filter { code in
            guard !realSet.contains(code) else { return false }
            if autoCaptionAllowList.contains(code) { return true }
            if let prefix = videoLangPrefix,
               code.split(separator: "-").first.map({ String($0).lowercased() }) == prefix {
                return true
            }
            return false
        }
        autoCodes.sort { subtitleSortKey($0) < subtitleSortKey($1) }
        let auto = autoCodes.prefix(8).map {
            SubtitleChoice(id: $0, label: subtitleLabel(for: $0), isAuto: true)
        }
        return real + auto
    }

    private static func subtitleLabel(for code: String) -> String {
        let locale = Locale(identifier: "zh_CN")
        if let name = locale.localizedString(forLanguageCode: code), !name.isEmpty {
            return "\(name) (\(code))"
        }
        return code
    }

    private static func subtitleSortKey(_ code: String) -> (Int, String) {
        let lower = code.lowercased()
        let rank: Int
        if lower.hasPrefix("zh") {
            rank = 0
        } else if lower == "en" || lower.hasPrefix("en-") {
            rank = 1
        } else if lower == "ja" || lower.hasPrefix("ja-") {
            rank = 2
        } else {
            rank = 3
        }
        return (rank, lower)
    }

    // MARK: - 第三步：下载

    /// preferredTitle 作为字面量进入 yt-dlp 输出模板：需转义 %、去掉路径分隔符并限长。
    private static func outputTemplate(preferredTitle: String?) -> String {
        guard let raw = preferredTitle else { return "%(title).180B [%(id)s].%(ext)s" }
        var clean = raw.replacingOccurrences(of: "%", with: "%%")
        // 换行/控制字符并入分隔集：含 \n 的页面标题会破坏 --print 行匹配
        clean = clean
            .components(separatedBy: CharacterSet(charactersIn: "/\\:\0").union(.newlines))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.count > 120 { clean = String(clean.prefix(120)) }
        guard !clean.isEmpty else { return "%(title).180B [%(id)s].%(ext)s" }
        return "\(clean) [%(id)s].%(ext)s"
    }

    public func download(
        _ request: DownloadRequest,
        control: TaskControlToken?,
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> DownloadResult {
        let ytdlp = try ytDlpPath()
        let ffmpegDir = try ffmpegDirectory()
        let destDir = request.destinationDirectory
        try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        var args: [String] = [
            "--no-playlist", "--newline", "--no-mtime",
            "--progress-template",
            "download:MGP|%(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s",
            "--ffmpeg-location", ffmpegDir,
            "-P", destDir.path,
            "-o", Self.outputTemplate(preferredTitle: request.preferredTitle),
            // 网络韧性：分片并发提速 + 读超时 + 重试，缓解通用站点的下载中途停滞。
            "-N", "4",
            "--socket-timeout", "30",
            "--retries", "10",
            "--fragment-retries", "10",
        ]
        let cookie = Self.makeCookieArguments()
        defer { cookie.cleanup() }
        args += Self.systemProxyArguments()
        args += cookie.args
        if request.formatID == "audio" {
            args += ["-f", "ba/b", "-x", "--audio-format", "m4a"]
        } else {
            // HDR：把 height 选择器加上 dynamic_range 偏好，并用 mkv 封装（mp4 装 VP9.2-HDR 不可靠）。
            let formatSelector = Self.applyHDRPreference(to: request.formatID, preferHDR: request.preferHDR)
            let mergeContainer = request.preferHDR ? "mkv" : "mp4"
            args += ["-f", formatSelector, "--merge-output-format", mergeContainer]
        }
        let allSubLangs = request.subtitleLangs + request.autoSubtitleLangs
        if !allSubLangs.isEmpty {
            args += ["--sub-langs", allSubLangs.joined(separator: ",")]
            if !request.subtitleLangs.isEmpty { args.append("--write-subs") }
            if !request.autoSubtitleLangs.isEmpty { args.append("--write-auto-subs") }
            args += ["--convert-subs", "srt"]
        }
        // --print 默认隐含 simulate/quiet，必须配 --no-simulate / --no-quiet 抵消。
        args += ["--print", "after_move:filepath", "--no-simulate", "--no-quiet"]
        args.append(request.url)

        progress(DownloadProgress(phase: .preparing))

        // control 已请求取消：不必启动子进程。
        if control?.isCancelled == true { throw MoongateError.cancelled }

        let destPrefix = destDir.path.hasSuffix("/") ? destDir.path : destDir.path + "/"
        let printedPaths = PathCollector()
        let progressTracker = DownloadProgressTracker()
        var status: Int32 = -1
        var stderrTail = ""
        // 首次下载偶发 "Requested format is not available"（YouTube n-challenge 冷启动 /
        // 临时风控），yt-dlp 第二次运行 player 缓存已热即成功——正是用户反馈的「要点两次才能下载」。
        // 这里自动重试一次，省掉用户手动再点。仅对该可恢复错误重试，其它错误立即上抛。
        for attempt in 0..<2 {
            printedPaths.reset()
            do {
                (status, stderrTail) = try await Self.runStreamingProcess(
                    executable: ytdlp,
                    arguments: args,
                    // 停滞看门狗：10 分钟完全无输出视为挂死（暂停中不计时）。
                    stallTimeout: 600,
                    isSuspended: { control?.isPaused ?? false },
                    onStart: { pid in
                        // 登记主下载进程 pid：暂停时 TaskControlToken 向其进程树
                        // （含派生的 ffmpeg）发 SIGSTOP/SIGCONT。
                        control?.setActivePID(pid)
                    }
                ) { line in
                    Self.handleOutputLine(line, state: progressTracker, progress: progress)
                    if line.hasPrefix(destPrefix) { printedPaths.append(line) }
                }
                control?.setActivePID(0)
            } catch is ProcessStalledError {
                control?.setActivePID(0)
                // 保留 .part 文件：yt-dlp 重试时可断点续传。
                throw MoongateError.downloadFailed(
                    CoreL10n.text(
                        en: "Download stalled: no progress output for more than 10 minutes, so it was stopped. The site may be rate-limiting or the network may have dropped; click Retry to resume.",
                        zhHans: "下载停滞：超过 10 分钟没有任何进度输出，已自动中止。可能是站点限速或网络中断，可点「重试」续传。",
                        zhHant: "下載停滯：超過 10 分鐘沒有任何進度輸出，已自動中止。可能是站點限速或網路中斷，可點「重試」續傳。"
                    )
                )
            } catch {
                control?.setActivePID(0)
                // 取消路径：进程已确认退出，先清掉残留的临时文件再上抛。
                if case MoongateError.cancelled = error {
                    Self.cleanupTemporaryFiles(in: destDir, videoID: request.videoID)
                }
                throw error
            }
            // 可恢复的格式缺失：未取消、还有重试机会时，自动再跑一次。
            if attempt == 0, status != 0, control?.isCancelled != true,
               stderrTail.contains("Requested format is not available") {
                continue
            }
            break
        }

        guard status == 0 else {
            if let loginError = Self.detectLoginRequired(stderr: stderrTail, url: request.url) {
                throw loginError
            }
            throw MoongateError.downloadFailed(Self.friendlyDownloadReason(stderrTail: stderrTail))
        }
        // 注意：HLS 字幕兜底还在后面，.finished 留到全部产物就绪后再报，
        // 避免 UI 显示完成后任务还在后台拉字幕（源停摆时像卡死在 100%）。
        progress(DownloadProgress(phase: .processing))

        // 优先用 --print after_move:filepath 的精确产出；目录扫描降级为兜底。
        let fm = FileManager.default
        var files = printedPaths.values
            .map { URL(fileURLWithPath: $0) }
            .filter { fm.fileExists(atPath: $0.path) }
        if files.isEmpty {
            files = Self.collectOutputFiles(in: destDir, videoID: request.videoID)
        } else if !allSubLangs.isEmpty {
            // --print 不会打印字幕文件，用目录扫描补齐字幕。
            let known = Set(files.map(\.path))
            files += Self.collectOutputFiles(in: destDir, videoID: request.videoID).filter {
                Self.subtitleExtensions.contains($0.pathExtension.lowercased()) && !known.contains($0.path)
            }
        }
        guard !files.isEmpty else {
            throw MoongateError.downloadFailed(CoreL10n.text(
                en: "The download process finished, but no output file was found in the destination folder.",
                zhHans: "下载进程已结束，但在目标目录里没有找到产出文件。",
                zhHant: "下載程序已結束，但在目標資料夾裡沒有找到輸出檔。"
            ))
        }

        // yt-dlp 取不到的字幕（如 Apple WWDC 等只存在于 HLS manifest 里的字幕）：
        // 检测请求的字幕里哪些没落地 .srt，对缺失的 lang 用 ffmpeg 从 HLS 字幕 m3u8 转出。
        if !allSubLangs.isEmpty {
            let videoFile = files.first {
                !Self.subtitleExtensions.contains($0.pathExtension.lowercased())
            }
            if let videoFile {
                let presentLangs = Set(files
                    .filter { $0.pathExtension.lowercased() == "srt" }
                    .compactMap { Self.langCode(ofSubtitle: $0) })
                let missing = allSubLangs.filter { !presentLangs.contains($0.lowercased()) }
                if !missing.isEmpty {
                    let table = await hlsSubtitleTable(for: request.url)
                    for lang in missing {
                        guard let m3u8 = table[lang] else { continue }
                        if control?.isCancelled == true { throw MoongateError.cancelled }
                        if let srt = await Self.fetchHLSSubtitle(
                            m3u8: m3u8, lang: lang, videoFile: videoFile, control: control
                        ), !files.contains(srt) {
                            files.append(srt)
                        }
                    }
                }
            }
        }
        progress(DownloadProgress(phase: .finished, percent: 100))
        return DownloadResult(files: files)
    }

    /// 取 sourceURL 的 HLS 字幕表：优先用 analyze 阶段缓存（GUI 同一引擎实例命中）；
    /// 缓存缺失（如 CLI download 独立进程）时按需重新拉 JSON + 解析 manifest。
    private func hlsSubtitleTable(for url: String) async -> [String: String] {
        if let cached = cachedHLSSubtitles(for: url) { return cached }
        let json: [String: Any]
        if let info = cachedInfo(for: url) {
            json = info
        } else if case .success(let dict) = (try? await runYtDlpJSON(for: url)) ?? .failure(stderr: "") {
            json = dict
        } else {
            return [:]
        }
        let rawFormats = (json["formats"] as? [[String: Any]]) ?? []
        let (_, table) = await discoverHLSSubtitles(in: rawFormats)
        if !table.isEmpty { setCachedHLSSubtitles(table, for: url) }
        return table
    }

    /// 从字幕文件名 "<名>.<lang>.srt" 解析出 lang code（小写）。
    private static func langCode(ofSubtitle file: URL) -> String? {
        let stem = file.deletingPathExtension().lastPathComponent
        guard let dotIndex = stem.lastIndex(of: ".") else { return nil }
        return String(stem[stem.index(after: dotIndex)...]).lowercased()
    }

    /// 用 ffmpeg 把单语 HLS 字幕 m3u8 转成 srt，输出 "<视频名去扩展>.<lang>.srt"。
    /// 失败返回 nil（记日志、跳过该 lang，不影响整体下载）。
    private static func fetchHLSSubtitle(
        m3u8: String, lang: String, videoFile: URL, control: TaskControlToken?
    ) async -> URL? {
        let ffmpeg = locateSubtitleFFmpeg()
        guard let ffmpeg else {
            FileHandle.standardError.write(Data("HLS 字幕转换跳过（找不到 ffmpeg）：\(lang)\n".utf8))
            return nil
        }
        let stem = videoFile.deletingPathExtension().lastPathComponent
        let output = videoFile.deletingLastPathComponent()
            .appendingPathComponent("\(stem).\(lang).srt")
        try? FileManager.default.removeItem(at: output)
        let result = try? await runStreamingProcess(
            executable: ffmpeg,
            arguments: ["-y", "-i", m3u8, output.path],
            // 远端 m3u8 可能死链/停滞：1 分钟无输出即放弃该语言（try? 吞掉停滞错误）。
            stallTimeout: 60,
            isSuspended: { control?.isPaused ?? false },
            // 登记 pid：暂停/取消也能管到这个收尾阶段的 ffmpeg。
            onStart: { pid in control?.setActivePID(pid) },
            onLine: { _ in }
        )
        control?.setActivePID(0)
        if let result, result.status == 0,
           FileManager.default.fileExists(atPath: output.path) {
            return output
        }
        FileHandle.standardError.write(Data("HLS 字幕转换失败，已跳过：\(lang)\n".utf8))
        return nil
    }

    /// 取消后清理 yt-dlp 留下的临时文件（.part / .ytdl / 分片 .part-Frag…）。
    private static func cleanupTemporaryFiles(in directory: URL, videoID: String) {
        let marker = "[\(videoID)]"
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return }
        for file in contents {
            let name = file.lastPathComponent
            guard name.contains(marker) else { continue }
            let ext = file.pathExtension.lowercased()
            if ext == "part" || ext == "ytdl" || name.contains(".part-Frag") {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    static func handleOutputLine(
        _ line: String,
        state: DownloadProgressTracker,
        progress: @Sendable (DownloadProgress) -> Void
    ) {
        if line.hasPrefix("MGP|") {
            let parts = line.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            var percent: Double?
            if parts.count > 1 {
                percent = Double(parts[1].replacingOccurrences(of: "%", with: ""))
            }
            let speed = parts.count > 2 ? normalizeField(parts[2]) : nil
            let eta = parts.count > 3 ? normalizeField(parts[3]) : nil
            progress(DownloadProgress(
                phase: .downloading,
                percent: state.normalizedPercent(percent),
                speedText: speed,
                etaText: eta
            ))
        } else if let step = processingStep(for: line) {
            progress(DownloadProgress(phase: .processing, detail: step))
        }
    }

    /// 把 yt-dlp 后处理行映射成中文步骤说明（合并 HDR 视频时 [Merger] 可能耗时）。
    private static func processingStep(for line: String) -> String? {
        if line.hasPrefix("[Merger]") {
            return CoreL10n.text(en: "Merging video and audio", zhHans: "正在合并音视频", zhHant: "正在合併影音")
        }
        if line.hasPrefix("[VideoConvertor]") {
            return CoreL10n.text(en: "Transcoding video", zhHans: "正在转码视频", zhHant: "正在轉碼影片")
        }
        if line.hasPrefix("[ExtractAudio]") {
            return CoreL10n.text(en: "Extracting audio", zhHans: "正在提取音频", zhHant: "正在提取音訊")
        }
        if line.hasPrefix("[SubtitleConvertor]") {
            return CoreL10n.text(en: "Converting subtitles", zhHans: "正在转换字幕", zhHant: "正在轉換字幕")
        }
        if line.hasPrefix("[Fixup") {
            return CoreL10n.text(en: "Fixing container", zhHans: "正在修复封装", zhHant: "正在修復封裝")
        }
        return nil
    }

    private static func normalizeField(_ value: String) -> String? {
        if value.isEmpty || value == "N/A" || value == "Unknown" { return nil }
        return value
    }

    /// 两段式文案：中文主句 + 换行 + 原始 ERROR 行（截断 200 字符），UI 分层展示。
    /// 需要登录的情况已在上游由 detectLoginRequired 拦截为 loginRequired。
    private static func friendlyDownloadReason(stderrTail: String) -> String {
        let rawLine = summarizeStderr(stderrTail)
        if stderrTail.contains("HTTP Error 403") || stderrTail.contains("403 Forbidden") {
            return CoreL10n.text(
                en: "Access was denied (403). The source may block hotlinking or restrict your region. Confirm the video plays in a browser, or choose another candidate source.",
                zhHans: "资源拒绝访问（403），可能存在防盗链或地区限制。可先在浏览器确认视频能正常播放，或换一个候选来源。",
                zhHant: "資源拒絕存取（403），可能存在防盜連或地區限制。可先在瀏覽器確認影片能正常播放，或換一個候選來源。"
            ) + "\n" + rawLine
        }
        if isLikelyNetworkError(stderrTail) {
            return CoreL10n.text(
                en: "The network connection was unstable or interrupted. If the site is blocked on your network, confirm your proxy/VPN is working, then click Retry.",
                zhHans: "网络连接不稳定或被中断。若在中国大陆访问 YouTube 等站点，请确认代理/VPN 已开启且工作正常，再点「重试」。",
                zhHant: "網路連線不穩或被中斷。若該站點在你的網路中受限，請確認代理/VPN 已開啟且正常，再點「重試」。"
            ) + "\n" + rawLine
        }
        return CoreL10n.text(
            en: "An error occurred during download.",
            zhHans: "下载过程中出现错误。",
            zhHant: "下載過程中發生錯誤。"
        ) + "\n" + rawLine
    }

    /// 识别与网络/代理相关的子进程错误（用于给中国大陆用户更有针对性的提示）。
    private static func isLikelyNetworkError(_ stderr: String) -> Bool {
        let lower = stderr.lowercased()
        let markers = [
            "timed out", "timeout", "connection reset", "connection refused",
            "connection aborted", "temporary failure in name resolution",
            "failed to establish a new connection", "network is unreachable",
            "unable to connect", "ssl", "tunnel connection failed",
            "getaddrinfo", "name or service not known", "no route to host",
        ]
        return markers.contains { lower.contains($0) }
    }

    private static let subtitleExtensions: Set<String> = ["srt", "vtt", "ass", "ssa", "lrc", "ttml"]

    private static func collectOutputFiles(in directory: URL, videoID: String) -> [URL] {
        let marker = "[\(videoID)]"
        let tempExts: Set<String> = ["part", "ytdl", "temp"]
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return [] }
        let matched = contents.filter {
            $0.lastPathComponent.contains(marker) && !tempExts.contains($0.pathExtension.lowercased())
        }
        let videos = matched.filter { !subtitleExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let subs = matched.filter { subtitleExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return videos + subs
    }

    // MARK: - 进程执行

    /// 一次性进程：整体收集 stdout/stderr，可选超时；支持任务取消。
    private static func runProcess(
        executable: String,
        arguments: [String],
        timeout: TimeInterval?
    ) async throws -> ProcessOutput {
        let box = ProcessBox()
        let output: ProcessOutput = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessOutput, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: executable)
                    process.arguments = arguments
                    process.environment = Self.subprocessEnvironment()
                    process.standardInput = FileHandle.nullDevice
                    let outPipe = Pipe()
                    let errPipe = Pipe()
                    process.standardOutput = outPipe
                    process.standardError = errPipe

                    do {
                        try process.run()
                    } catch {
                        let name = (executable as NSString).lastPathComponent
                        continuation.resume(throwing: MoongateError.analyzeFailed("\(CoreL10n.text(en: "Could not start", zhHans: "无法启动", zhHant: "無法啟動")) \(name)：\(error.localizedDescription)"))
                        return
                    }
                    if box.register(process) { process.terminate() }

                    var timeoutItem: DispatchWorkItem?
                    if let timeout {
                        let item = DispatchWorkItem {
                            if process.isRunning {
                                box.markTimedOut()
                                process.terminate()
                                // SIGTERM 被无视时 3 秒后强杀整棵进程树兜底。
                                DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                                    if process.isRunning {
                                        TaskControlToken.signalTree(process.processIdentifier, SIGKILL)
                                    }
                                }
                            }
                        }
                        timeoutItem = item
                        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: item)
                    }

                    // 并发读两个管道，避免输出过大时互相阻塞。
                    let outBuf = DataBuffer()
                    let errBuf = DataBuffer()
                    let group = DispatchGroup()
                    group.enter()
                    DispatchQueue.global().async {
                        outBuf.append(outPipe.fileHandleForReading.readDataToEndOfFile())
                        group.leave()
                    }
                    group.enter()
                    DispatchQueue.global().async {
                        errBuf.append(errPipe.fileHandleForReading.readDataToEndOfFile())
                        group.leave()
                    }
                    process.waitUntilExit()
                    // 子进程若把 stdout/stderr fd 传给了仍存活的孙进程，EOF 永不到来：
                    // 进程退出后最多再等 10 秒读尾巴，防止 group.wait 永久阻塞蚕食线程。
                    _ = group.wait(timeout: .now() + 10)
                    timeoutItem?.cancel()

                    continuation.resume(returning: ProcessOutput(
                        status: process.terminationStatus,
                        stdout: outBuf.data,
                        stderr: errBuf.data,
                        timedOut: box.timedOut
                    ))
                }
            }
        } onCancel: {
            box.cancel()
        }
        if box.isCancelled { throw MoongateError.cancelled }
        return output
    }

    /// 流式进程：stdout 按行回调（处理半行到达），stderr 保留尾部 16KB。
    /// internal：Burner 复用它跑 ffmpeg/ffprobe。currentDirectory 为 nil 时不改工作目录。
    /// onStart 非空时在子进程成功启动后回调其 pid（用于登记到 TaskControlToken 实现暂停）；
    /// 默认 nil 不改变现有调用行为。
    /// stallTimeout 非空时启用停滞看门狗：进程连续这么多秒没有任何 stdout/stderr 输出
    /// 即视为挂死，强杀进程树并抛 ProcessStalledError（isSuspended 返回 true 期间不计时，
    /// 避免误杀被 SIGSTOP 暂停的进程）。
    static func runStreamingProcess(
        executable: String,
        arguments: [String],
        currentDirectory: URL? = nil,
        stallTimeout: TimeInterval? = nil,
        isSuspended: (@Sendable () -> Bool)? = nil,
        onStart: (@Sendable (Int32) -> Void)? = nil,
        onLine: @escaping @Sendable (String) -> Void
    ) async throws -> (status: Int32, stderrTail: String) {
        let state = StreamingState()
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.environment = Self.subprocessEnvironment()
                if let currentDirectory { process.currentDirectoryURL = currentDirectory }
                process.standardInput = FileHandle.nullDevice
                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe

                // 两条管道各自读到 EOF 后 leave；收尾统一等待，
                // 消除 terminationHandler 与在途回调并发读同一管道的竞态。
                let ioGroup = DispatchGroup()
                ioGroup.enter()
                ioGroup.enter()

                outPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        ioGroup.leave()
                        return
                    }
                    for line in state.consumeLines(appending: data) { onLine(line) }
                }
                errPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        ioGroup.leave()
                        return
                    }
                    state.appendStderr(data)
                }
                process.terminationHandler = { finished in
                    let status = finished.terminationStatus
                    DispatchQueue.global().async {
                        state.cancelStallTimer()
                        // 等两条管道 EOF（带兜底超时，防极端情况下挂起）再收尾。
                        _ = ioGroup.wait(timeout: .now() + 5)
                        outPipe.fileHandleForReading.readabilityHandler = nil
                        errPipe.fileHandleForReading.readabilityHandler = nil
                        for line in state.flushRemainder() { onLine(line) }
                        state.resumeOnce {
                            // 用户取消优先于停滞（取消也会让进程无输出退出）
                            if state.isStalled, !state.isCancelled {
                                continuation.resume(throwing: ProcessStalledError())
                            } else {
                                continuation.resume(returning: status)
                            }
                        }
                    }
                }

                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    // 子进程未启动，管道不会有数据/EOF，手动配平 ioGroup。
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    ioGroup.leave()
                    ioGroup.leave()
                    state.resumeOnce {
                        continuation.resume(throwing: MoongateError.downloadFailed("\(CoreL10n.text(en: "Could not start yt-dlp", zhHans: "无法启动 yt-dlp", zhHant: "無法啟動 yt-dlp"))：\(error.localizedDescription)"))
                    }
                    return
                }
                if state.register(process) {
                    state.cancel()
                } else {
                    onStart?(process.processIdentifier)
                    if let stallTimeout {
                        let timer = DispatchSource.makeTimerSource(queue: .global())
                        let interval = max(5, min(15, stallTimeout / 4))
                        timer.schedule(deadline: .now() + interval, repeating: interval)
                        timer.setEventHandler {
                            // 暂停（SIGSTOP）期间进程必然无输出：刷新计时而不是误杀。
                            if isSuspended?() == true {
                                state.touch()
                                return
                            }
                            state.killIfSilent(longerThan: stallTimeout)
                        }
                        state.setStallTimer(timer)
                        timer.resume()
                    }
                }
            }
        } onCancel: {
            state.cancel()
        }
        if state.isCancelled { throw MoongateError.cancelled }
        return (status, state.stderrTail)
    }

    // MARK: - 杂项

    private static func isYouTubeHost(_ host: String) -> Bool {
        let h = host.lowercased()
        return h == "youtu.be"
            || h == "youtube.com" || h.hasSuffix(".youtube.com")
            || h == "youtube-nocookie.com" || h.hasSuffix(".youtube-nocookie.com")
    }

    private static func isBilibiliHost(_ host: String) -> Bool {
        let h = host.lowercased()
        return h == "bilibili.com" || h.hasSuffix(".bilibili.com") || h == "b23.tv"
    }

    private static func isTikTokHost(_ host: String) -> Bool {
        let h = host.lowercased()
        return h == "tiktok.com" || h.hasSuffix(".tiktok.com")
    }

    private static func isDouyinHost(_ host: String) -> Bool {
        let h = host.lowercased()
        return h == "douyin.com" || h.hasSuffix(".douyin.com")
            || h == "iesdouyin.com" || h.hasSuffix(".iesdouyin.com")
            || h == "amemv.com" || h.hasSuffix(".amemv.com")
    }

    private static func isXiaohongshuHost(_ host: String) -> Bool {
        let h = host.lowercased()
        return h == "xiaohongshu.com" || h.hasSuffix(".xiaohongshu.com")
            || h == "xhslink.com" || h.hasSuffix(".xhslink.com")
    }

    /// yt-dlp 是该站点的原生 extractor（而非靠网页嗅探）。这些站点解析失败应直接给原因，
    /// 不要回退到 PageSniffer 显示误导性的「页面加载失败」。
    private static func isNativeExtractorHost(_ host: String) -> Bool {
        isYouTubeHost(host)
            || isBilibiliHost(host)
            || isTikTokHost(host)
            || isDouyinHost(host)
            || isXiaohongshuHost(host)
    }

    /// 站点风控/限流（如 bilibili HTTP 412）：给出诚实可操作的提示，而不是当成普通失败。
    private static func riskControlMessage(stderr: String, host: String) -> String? {
        let summary = summarizeStderr(stderr)
        let lower = summary.lowercased()
        let is412 = lower.contains("412") || lower.contains("precondition failed")
        let isRisk = lower.contains("risk") || summary.contains("风控") || summary.contains("安全风控")
        guard is412 || isRisk else { return nil }
        if isBilibiliHost(host) {
            return CoreL10n.text(
                en: "Bilibili triggered risk control (HTTP 412) and temporarily rejected parsing. This is usually caused by too many requests or frequent login attempts, and is tied to your network egress IP. Wait 10-30 minutes, try another network, or open Bilibili in a browser to confirm the account is not restricted. Repeated login attempts can extend the lockout.",
                zhHans: "哔哩哔哩触发了安全风控（HTTP 412），暂时拒绝了解析请求。这通常是短时间请求过多或登录尝试频繁导致，和你的网络出口 IP 相关。建议：等待 10–30 分钟再试、换一个网络环境、或在浏览器里正常访问 B 站确认账号未受限。不要反复点登录，会延长风控时间。",
                zhHant: "Bilibili 觸發了安全風控（HTTP 412），暫時拒絕解析請求。這通常是短時間請求過多或登入嘗試頻繁導致，與你的網路出口 IP 相關。建議等待 10–30 分鐘再試、換一個網路環境，或在瀏覽器裡正常開啟 Bilibili 確認帳號未受限。不要反覆登入，會延長風控時間。"
            )
        }
        return CoreL10n.text(
            en: "The site triggered access risk control (HTTP 412) and temporarily rejected the request. Try again later or switch networks.",
            zhHans: "站点触发了访问风控（HTTP 412），暂时拒绝了请求。请稍后重试或更换网络环境。",
            zhHant: "站點觸發了存取風控（HTTP 412），暫時拒絕請求。請稍後重試或更換網路環境。"
        )
    }

    /// 解析阶段错误的中文化（自动重试一次后仍失败才会走到这里）。
    private static func friendlyAnalyzeMessage(_ stderr: String) -> String {
        if stderr.contains("Requested format is not available") {
            return CoreL10n.text(
                en: "The site did not return any available quality options, often due to temporary risk control. Try again later; if it keeps happening, log in again in Settings.",
                zhHans: "站点暂时没有返回可用的清晰度（多为临时风控），请稍后重试；若反复出现，可在设置里重新登录。",
                zhHant: "站點暫時沒有返回可用清晰度（多半是臨時風控），請稍後重試；若反覆出現，可在設定裡重新登入。"
            )
        }
        if isLikelyNetworkError(stderr) {
            return CoreL10n.text(
                en: "Parsing failed because the network connection was unstable or interrupted. If the site is blocked on your network, confirm your proxy/VPN is working, then retry.",
                zhHans: "解析失败：网络连接不稳定或被中断。若在中国大陆访问 YouTube 等站点，请确认代理/VPN 已开启且工作正常，再重试。",
                zhHant: "解析失敗：網路連線不穩或被中斷。若該站點在你的網路中受限，請確認代理/VPN 已開啟且正常，再重試。"
            )
        }
        return summarizeStderr(stderr)
    }

    private static func summarizeStderr(_ text: String) -> String {
        let lines = text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let fallback = CoreL10n.text(en: "Unknown error", zhHans: "未知错误", zhHant: "未知錯誤")
        let errorLine = lines.last(where: { $0.hasPrefix("ERROR") }) ?? lines.last ?? fallback
        return String(errorLine.prefix(200))
    }

    private static func intValue(_ any: Any?) -> Int? {
        (any as? NSNumber)?.intValue
    }

    /// yt-dlp vcodec（如 "vp9.2"/"av01.0.09M.10..."/"avc1.64002A"）→ 简称。
    static func shortVCodec(_ raw: String) -> String {
        let v = raw.lowercased()
        if v.hasPrefix("vp9") || v.hasPrefix("vp09") { return "vp9" }
        if v.hasPrefix("av01") || v.hasPrefix("av1") { return "av1" }
        if v.hasPrefix("avc") || v.hasPrefix("h264") { return "h264" }
        if v.hasPrefix("hev") || v.hasPrefix("hvc") || v.hasPrefix("h265") { return "h265" }
        if v.hasPrefix("vp8") { return "vp8" }
        return v.components(separatedBy: ".").first ?? v
    }

    /// 给基础 -f 选择器加上 HDR 偏好：把每个视频选择子项 `bv*[...]` 加上 `[dynamic_range!=SDR]`，
    /// 并在末尾补一个不带 HDR 约束的回退（HDR 流缺失时仍能下到该档）。
    /// preferHDR=false 时原样返回。
    static func applyHDRPreference(to selector: String, preferHDR: Bool) -> String {
        guard preferHDR else { return selector }
        // 在每个 "bv*" 后面紧跟的部分插入 dynamic_range 约束。
        // 基础串形如 "bv*+ba/b" 或 "bv*[height<=1080]+ba/b[height<=1080]"。
        // 策略：对整串做 HDR 版（bv* → bv*[dynamic_range!=SDR]），再以 "/" 回退到原始串。
        let hdrVariant = selector.replacingOccurrences(of: "bv*", with: "bv*[dynamic_range!=SDR]")
        return hdrVariant + "/" + selector
    }
    private static func doubleValue(_ any: Any?) -> Double? {
        if let number = any as? NSNumber { return number.doubleValue }
        if let string = any as? String { return Double(string) }
        return nil
    }

    private static func bestAudioSizeBytes(in formats: [[String: Any]]) -> Double? {
        let audioOnly = formats.filter { format in
            let acodec = format["acodec"] as? String
            let vcodec = format["vcodec"] as? String
            return acodec != nil && acodec != "none" && (vcodec == nil || vcodec == "none")
        }
        let best = audioOnly.max {
            (doubleValue($0["abr"]) ?? doubleValue($0["tbr"]) ?? 0)
                < (doubleValue($1["abr"]) ?? doubleValue($1["tbr"]) ?? 0)
        }
        guard let best else { return nil }
        return doubleValue(best["filesize"]) ?? doubleValue(best["filesize_approx"])
    }

    private static func sizeText(bytes: Double) -> String {
        let mb = bytes / 1_048_576
        return "≈ \(max(1, Int(mb.rounded()))) MB"
    }

    private static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}
