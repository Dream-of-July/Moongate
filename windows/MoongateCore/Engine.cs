using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Moongate.Core;

// MARK: - 二进制定位

/// <summary>
/// 外部工具定位：先找受管目录 %LOCALAPPDATA%\Moongate\bin\&lt;name&gt;.exe
/// （DependencyManager 的下载目标），再沿 PATH 搜索。环境变量可逐个覆盖（调试用）。
/// </summary>
public static class BinaryLocator
{
    /// <summary>测试注入：非空时受管 bin 目录用它替代 %LOCALAPPDATA%\Moongate\bin。</summary>
    public static string? OverrideBinDirectory { get; set; }

    /// <summary>受管 bin 目录（DependencyManager 下载依赖的落点）。</summary>
    public static string BinDirectory
    {
        get
        {
            if (OverrideBinDirectory is { Length: > 0 } overridden) return overridden;
            var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            return Path.Combine(localAppData, "Moongate", "bin");
        }
    }

    /// <summary>带平台后缀的可执行文件名（Windows 加 .exe）。</summary>
    internal static string ExecutableFileName(string name)
    {
        if (!OperatingSystem.IsWindows()) return name;
        return name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) ? name : name + ".exe";
    }

    /// <summary>
    /// 定位某个外部工具。顺序：环境变量覆盖 → 受管 bin 目录 → PATH。找不到返回 null。
    /// </summary>
    public static string? Locate(string name, string? envVar = null)
    {
        if (envVar is not null
            && Environment.GetEnvironmentVariable(envVar) is { Length: > 0 } custom
            && File.Exists(custom))
        {
            return custom;
        }
        var exe = ExecutableFileName(name);
        var managed = Path.Combine(BinDirectory, exe);
        if (File.Exists(managed)) return managed;

        var pathValue = Environment.GetEnvironmentVariable("PATH") ?? "";
        foreach (var dir in pathValue.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
        {
            var candidate = Path.Combine(dir, exe);
            if (File.Exists(candidate)) return candidate;
        }
        return null;
    }

    /// <summary>
    /// 子进程的 PATH：把受管 bin 目录前置。yt-dlp 解 YouTube 的 n-challenge 必须能
    /// 找到 deno（JS 运行时），否则所有视频格式都会被跳过（"Requested format is not available"）。
    /// </summary>
    internal static string SubprocessPathValue()
    {
        var current = Environment.GetEnvironmentVariable("PATH") ?? "";
        var bin = BinDirectory;
        var parts = current.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries).ToList();
        if (!parts.Contains(bin)) parts.Insert(0, bin);
        return string.Join(Path.PathSeparator, parts);
    }
}

// MARK: - 进程执行

/// <summary>进程停滞（看门狗超时无任何输出被强杀）。调用方据此映射为各自的友好错误。</summary>
internal sealed class ProcessStalledException : Exception;

internal static class ProcessRunner
{
    internal sealed record ProcessOutput(int Status, string Stdout, string Stderr, bool TimedOut);

    /// <summary>一次性进程：整体收集 stdout/stderr，可选超时；支持取消（杀进程树）。</summary>
    internal static async Task<ProcessOutput> RunProcessAsync(
        string executable,
        IReadOnlyList<string> arguments,
        TimeSpan? timeout,
        CancellationToken ct = default)
    {
        using var process = new Process { StartInfo = MakeStartInfo(executable, arguments, null) };
        try
        {
            process.Start();
        }
        catch (Exception e)
        {
            throw MoongateException.AnalyzeFailed(L10n.T($"无法启动 {Path.GetFileName(executable)}：{e.Message}",
                $"無法啟動 {Path.GetFileName(executable)}：{e.Message}",
                $"Could not start {Path.GetFileName(executable)}: {e.Message}"));
        }
        process.StandardInput.Close();

        var timedOut = false;
        using var timeoutCts = new CancellationTokenSource();
        if (timeout is { } t)
        {
            timeoutCts.CancelAfter(t);
        }
        await using var timeoutReg = timeoutCts.Token.Register(() =>
        {
            timedOut = true;
            ProcessTree.KillTree(SafePid(process));
        }).ConfigureAwait(false);
        await using var cancelReg = ct.Register(() => ProcessTree.KillTree(SafePid(process))).ConfigureAwait(false);

        // 并发读两个管道，避免输出过大时互相阻塞。
        var stdoutTask = process.StandardOutput.ReadToEndAsync(CancellationToken.None);
        var stderrTask = process.StandardError.ReadToEndAsync(CancellationToken.None);
        await process.WaitForExitAsync(CancellationToken.None).ConfigureAwait(false);
        var stdout = await stdoutTask.ConfigureAwait(false);
        var stderr = await stderrTask.ConfigureAwait(false);

        if (ct.IsCancellationRequested) throw MoongateException.Cancelled();
        return new ProcessOutput(process.ExitCode, stdout, stderr, timedOut);
    }

    /// <summary>
    /// 流式进程：stdout 按行回调，stderr 保留尾部 16KB。Burner 复用它跑 ffmpeg/ffprobe。
    /// currentDirectory 非空时设置工作目录（Burner 的字幕路径转义技巧依赖它）。
    /// onStart 在子进程成功启动后回调其 pid（用于登记到 TaskControlToken 实现暂停）。
    /// stallTimeout 非空时启用停滞看门狗：进程连续这么多秒没有任何 stdout/stderr 输出
    /// 即视为挂死，强杀进程树并抛 ProcessStalledException（isSuspended 返回 true 期间不计时，
    /// 避免误杀被挂起暂停的进程）。
    /// </summary>
    internal static async Task<(int Status, string StderrTail)> RunStreamingProcessAsync(
        string executable,
        IReadOnlyList<string> arguments,
        string? currentDirectory = null,
        TimeSpan? stallTimeout = null,
        Func<bool>? isSuspended = null,
        Action<int>? onStart = null,
        Action<string>? onLine = null,
        CancellationToken ct = default)
    {
        using var process = new Process { StartInfo = MakeStartInfo(executable, arguments, currentDirectory) };
        try
        {
            process.Start();
        }
        catch (Exception e)
        {
            var tool = Path.GetFileName(executable);
            throw MoongateException.DownloadFailed(L10n.T($"无法启动 {tool}：{e.Message}",
                $"無法啟動 {tool}：{e.Message}",
                $"Could not start {tool}: {e.Message}"));
        }
        process.StandardInput.Close();
        var pid = SafePid(process);

        // 启动前已请求取消：立即终止。
        if (ct.IsCancellationRequested)
        {
            ProcessTree.KillTree(pid);
        }
        else
        {
            onStart?.Invoke(pid);
        }

        var lastActivity = Environment.TickCount64;
        var stalled = false;
        void Touch() => Interlocked.Exchange(ref lastActivity, Environment.TickCount64);

        var stderrTail = new StringBuilder();
        var stderrLock = new object();
        const int stderrLimit = 16 * 1024;

        var stdoutTask = Task.Run(async () =>
        {
            while (await process.StandardOutput.ReadLineAsync(CancellationToken.None).ConfigureAwait(false) is { } line)
            {
                Touch();
                if (line.Length > 0) onLine?.Invoke(line);
            }
        }, CancellationToken.None);
        var stderrTask = Task.Run(async () =>
        {
            while (await process.StandardError.ReadLineAsync(CancellationToken.None).ConfigureAwait(false) is { } line)
            {
                Touch();
                lock (stderrLock)
                {
                    stderrTail.AppendLine(line);
                    if (stderrTail.Length > stderrLimit)
                    {
                        stderrTail.Remove(0, stderrTail.Length - stderrLimit);
                    }
                }
            }
        }, CancellationToken.None);

        // 停滞看门狗
        using var watchdogCts = new CancellationTokenSource();
        Task? watchdogTask = null;
        if (stallTimeout is { } timeout)
        {
            var interval = TimeSpan.FromSeconds(Math.Max(5, Math.Min(15, timeout.TotalSeconds / 4)));
            watchdogTask = Task.Run(async () =>
            {
                while (!watchdogCts.Token.IsCancellationRequested)
                {
                    try { await Task.Delay(interval, watchdogCts.Token).ConfigureAwait(false); }
                    catch (OperationCanceledException) { return; }
                    // 暂停（进程树挂起）期间进程必然无输出：刷新计时而不是误杀。
                    if (isSuspended?.Invoke() == true)
                    {
                        Touch();
                        continue;
                    }
                    var silentMs = Environment.TickCount64 - Interlocked.Read(ref lastActivity);
                    if (silentMs > timeout.TotalMilliseconds)
                    {
                        stalled = true;
                        ProcessTree.KillTree(pid);
                        return;
                    }
                }
            }, CancellationToken.None);
        }

        await using var cancelReg = ct.Register(() => ProcessTree.KillTree(pid)).ConfigureAwait(false);

        await process.WaitForExitAsync(CancellationToken.None).ConfigureAwait(false);
        watchdogCts.Cancel();
        // 子进程若把管道 fd 传给仍存活的孙进程，EOF 可能迟到：最多再等 10 秒读尾巴。
        var drain = Task.WhenAll(stdoutTask, stderrTask);
        await Task.WhenAny(drain, Task.Delay(TimeSpan.FromSeconds(10), CancellationToken.None)).ConfigureAwait(false);
        if (watchdogTask is not null)
        {
            try { await watchdogTask.ConfigureAwait(false); } catch { /* 忽略 */ }
        }

        // 用户取消优先于停滞（取消也会让进程无输出退出）。
        if (ct.IsCancellationRequested) throw MoongateException.Cancelled();
        if (stalled) throw new ProcessStalledException();
        string tail;
        lock (stderrLock) tail = stderrTail.ToString();
        return (process.ExitCode, tail);
    }

    private static ProcessStartInfo MakeStartInfo(
        string executable, IReadOnlyList<string> arguments, string? currentDirectory)
    {
        var psi = new ProcessStartInfo(executable)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
        };
        foreach (var arg in arguments) psi.ArgumentList.Add(arg);
        if (currentDirectory is not null) psi.WorkingDirectory = currentDirectory;
        // 受管 bin 目录前置到 PATH（deno 解 YouTube n-challenge 需要）。
        psi.Environment["PATH"] = BinaryLocator.SubprocessPathValue();
        return psi;
    }

    private static int SafePid(Process process)
    {
        try { return process.Id; } catch { return 0; }
    }
}

// MARK: - YtDlpEngine

/// <summary>
/// 默认下载引擎：yt-dlp -J 解析、流式下载、HLS manifest 字幕兜底。
/// 网络与子进程方法标为 virtual，测试可子类替换。
/// </summary>
public class YtDlpEngine : IDownloadEngine
{
    internal sealed class DownloadProgressTracker
    {
        private readonly int _expectedMediaDownloads;
        private int _completedMediaDownloads;
        private double? _lastRawFraction;
        private double? _lastDisplayedFraction;

        public DownloadProgressTracker(int expectedMediaDownloads = 1)
        {
            _expectedMediaDownloads = Math.Max(1, expectedMediaDownloads);
        }

        public string? NormalizeEtaText(string? text) =>
            _expectedMediaDownloads > 1 ? null : text;

        public double? NormalizePercent(double? percent)
        {
            if (percent is not { } value || double.IsNaN(value) || double.IsInfinity(value)) return null;
            var rawFraction = Math.Clamp(value, 0, 100) / 100;
            if (_lastRawFraction is { } lastRaw
                && lastRaw > 0.5
                && rawFraction + 0.15 < lastRaw)
            {
                _completedMediaDownloads++;
            }
            _lastRawFraction = rawFraction;

            var mediaDownloads = Math.Max(_expectedMediaDownloads, _completedMediaDownloads + 1);
            var combined = (_completedMediaDownloads + rawFraction) / mediaDownloads;
            var liveFraction = Math.Min(combined, 0.98);
            var displayed = Math.Max(_lastDisplayedFraction ?? 0, liveFraction);
            _lastDisplayedFraction = displayed;
            return displayed * 100;
        }
    }

    private readonly object _cacheLock = new();
    private readonly Dictionary<string, JsonElement> _infoCache = [];
    private readonly List<string> _infoCacheOrder = [];
    /// <summary>
    /// analyze 阶段从 HLS master m3u8 解析出的字幕表：sourceURL → [langCode: 字幕 m3u8 绝对 URL]。
    /// download 阶段据此用 ffmpeg 取这些 yt-dlp 拿不到的 HLS 内嵌字幕。
    /// </summary>
    private readonly Dictionary<string, Dictionary<string, string>> _hlsSubtitleCache = [];
    private readonly List<string> _hlsCacheOrder = [];

    private static readonly HttpClient SharedHttp = new() { Timeout = TimeSpan.FromSeconds(15) };

    // MARK: 二进制定位

    private static string YtDlpPath() =>
        BinaryLocator.Locate("yt-dlp", "MOONGATE_YTDLP_PATH") ?? throw MoongateException.BinaryNotFound("yt-dlp");

    private static string FfmpegDirectory()
    {
        var path = BinaryLocator.Locate("ffmpeg", "MOONGATE_FFMPEG_PATH") ?? throw MoongateException.BinaryNotFound("ffmpeg");
        return Path.GetDirectoryName(path) ?? ".";
    }

    private static string? FfprobePath() => BinaryLocator.Locate("ffprobe", "MOONGATE_FFPROBE_PATH");

    // MARK: 站点登录 cookies

    /// <summary>
    /// 按下载 URL 的 host 选择对应站点的 cookie jar，存在时所有 yt-dlp 调用都带上 --cookies。
    /// 按站点隔离：YouTube 下载只用 youtube jar，绝不把 Bilibili 等其它站点的会话带进去。
    /// yt-dlp 的 --cookies 是「读取并在退出时**写回**」语义：并发任务共用同一文件
    /// 会互相覆写甚至损坏。因此每次启动子进程都发一份任务私有临时副本
    /// （写回只落在副本上），用后由 cleanup 删除。
    /// </summary>
    internal static (List<string> Args, Action Cleanup) MakeCookieArguments(string urlString)
    {
        var master = CookieFileForUrl(urlString);
        if (master is null || !File.Exists(master)) return ([], () => { });
        var temp = Path.Combine(Path.GetTempPath(), $"moongate-cookies-{Guid.NewGuid():N}.txt");
        try
        {
            File.Copy(master, temp);
        }
        catch
        {
            return ([], () => { });  // 副本失败就不带 cookies，不阻塞下载
        }
        return (["--cookies", temp], () => { try { File.Delete(temp); } catch { /* 忽略 */ } });
    }

    /// <summary>按 URL host 解析对应站点的 cookie 文件路径；非受支持站点返回 null。</summary>
    internal static string? CookieFileForUrl(string urlString)
    {
        var host = Uri.TryCreate(urlString, UriKind.Absolute, out var u) ? u.Host : "";
        var site = CookieSites.ForHost(host);
        return site is null ? null : AppSettings.SiteCookieFilePath(site.Key);
    }

    /// <summary>该 URL 对应站点是否已有导出的登录 cookie 文件。</summary>
    internal static bool HasCookiesForUrl(string urlString)
    {
        var path = CookieFileForUrl(urlString);
        return path is not null && File.Exists(path);
    }

    internal static List<string> MakeProxyArguments(AppSettings settings)
    {
        var proxy = AppSettings.NormalizeVideoProxyUrl(settings.VideoProxyUrl);
        return proxy.Length == 0 ? [] : ["--proxy", proxy];
    }

    internal static List<string> MakeNetworkArguments(AppSettings settings)
    {
        var args = MakeProxyArguments(settings);
        if (settings.IgnoreVideoCertificateErrors) args.Add("--no-check-certificates");
        return args;
    }

    private static List<string> MakeNetworkArguments() => MakeNetworkArguments(AppSettings.Load());

    /// <summary>登录检测正则：编译一次复用，避免每次错误处理都 new Regex。与 macOS detectLoginRequired 同构。</summary>
    private static readonly Regex LoginRequiredRegex = new(
        "login required|need to log ?in|requires? (?:a )?login|account cookies|cookies.*(?:required|--cookies)|members?[- ]only|premium|sign ?in|authenticat|登录|登陆|大会员|会员|付费|请先登录|需要登录",
        RegexOptions.IgnoreCase | RegexOptions.Compiled);

    /// <summary>
    /// 识别"需要登录"类错误。命中返回 LoginRequired（或已登录时的过期文案），否则返回 null 走常规文案。
    /// hasCookies 由调用方传入（测试可控）。
    /// </summary>
    internal static MoongateException? DetectLoginRequired(string stderr, string urlString, bool hasCookies)
    {
        if (stderr.Contains("Sign in to confirm"))
        {
            // 已登录过仍被风控：再弹登录窗没有意义，提示重新登录或稍后重试。
            if (hasCookies)
            {
                return MoongateException.DownloadFailed(L10n.T(
                    "YouTube 要求确认登录状态。登录信息可能已过期，可在设置里重新登录，或稍后重试。",
                    "YouTube 要求確認登入狀態。登入資訊可能已過期，可在設定裡重新登入，或稍後重試。",
                    "YouTube asked to confirm sign-in. Your login may have expired; sign in again in Settings or retry later."));
            }
            return MoongateException.LoginRequired("youtube.com");
        }
        var host = Uri.TryCreate(urlString, UriKind.Absolute, out var url) ? url.Host.ToLowerInvariant() : "";
        var lowerStderr = stderr.ToLowerInvariant();
        if (IsBilibiliHost(host)
            && !hasCookies
            && (lowerStderr.Contains("412") || lowerStderr.Contains("precondition failed")))
        {
            return MoongateException.LoginRequired("bilibili.com");
        }
        // YouTube 的 403 实质是 PO token / 未登录，登录 cookies 是正解；其他站点的 403 保持防盗链文案。
        // 只看最后一条 ERROR 行，避免中间分片的瞬时 403 被误判成需要登录。
        if (IsYouTubeHost(host) && SummarizeStderr(stderr).Contains("HTTP Error 403"))
        {
            if (hasCookies)
            {
                return MoongateException.DownloadFailed(L10n.T(
                    "YouTube 拒绝了请求（403）。登录信息可能已过期，可在设置里重新登录，或稍后重试。",
                    "YouTube 拒絕了請求（403）。登入資訊可能已過期，可在設定裡重新登入，或稍後重試。",
                    "YouTube rejected the request (403). Your login may have expired; sign in again in Settings or retry later."));
            }
            return MoongateException.LoginRequired("youtube.com");
        }
        if (LoginRequiredRegex.IsMatch(stderr))
        {
            var site = host.StartsWith("www.") ? host[4..] : host;
            if (site.Length == 0) site = L10n.T("该站点", "該站點", "this site");
            return MoongateException.LoginRequired(site);
        }
        return null;
    }

    private static MoongateException? DetectLoginRequired(string stderr, string urlString) =>
        DetectLoginRequired(stderr, urlString, HasCookiesForUrl(urlString));

    // MARK: 信息缓存

    /// <summary>缓存条数上限：单条 YouTube -J JSON 可达 1-2MB，引擎与 App 同寿命，FIFO 淘汰最旧的。</summary>
    private const int CacheLimit = 32;

    private JsonElement? CachedInfo(string url)
    {
        lock (_cacheLock)
        {
            return _infoCache.TryGetValue(url, out var json) ? json : null;
        }
    }

    private void SetCachedInfo(JsonElement info, string url)
    {
        lock (_cacheLock)
        {
            if (!_infoCache.ContainsKey(url))
            {
                _infoCacheOrder.Add(url);
                if (_infoCacheOrder.Count > CacheLimit)
                {
                    var evicted = _infoCacheOrder[0];
                    _infoCacheOrder.RemoveAt(0);
                    _infoCache.Remove(evicted);
                }
            }
            _infoCache[url] = info;
        }
    }

    private Dictionary<string, string>? CachedHlsSubtitles(string url)
    {
        lock (_cacheLock)
        {
            return _hlsSubtitleCache.TryGetValue(url, out var table) ? table : null;
        }
    }

    private void SetCachedHlsSubtitles(Dictionary<string, string> table, string url)
    {
        lock (_cacheLock)
        {
            if (!_hlsSubtitleCache.ContainsKey(url))
            {
                _hlsCacheOrder.Add(url);
                if (_hlsCacheOrder.Count > CacheLimit)
                {
                    var evicted = _hlsCacheOrder[0];
                    _hlsCacheOrder.RemoveAt(0);
                    _hlsSubtitleCache.Remove(evicted);
                }
            }
            _hlsSubtitleCache[url] = table;
        }
    }

    // MARK: - 第一步：解析候选

    public async Task<IReadOnlyList<VideoCandidate>> ResolveCandidatesAsync(string input, CancellationToken ct = default)
    {
        var trimmed = input.Trim();
        if (!Uri.TryCreate(trimmed, UriKind.Absolute, out var url)
            || (url.Scheme != "http" && url.Scheme != "https")
            || string.IsNullOrEmpty(url.Host))
        {
            throw MoongateException.SniffFailed(L10n.T("请检查链接格式。", "請檢查連結格式。", "Please check the link format."));
        }

        var result = await RunYtDlpJsonAsync(trimmed, ct).ConfigureAwait(false);
        if (result.Json is { } json)
        {
            SetCachedInfo(json, trimmed);
            var title = StringField(json, "title") ?? trimmed;
            var detail = StringField(json, "extractor_key");
            return [new VideoCandidate { Url = trimmed, Kind = VideoCandidate.CandidateKind.Supported, Title = title, Detail = detail }];
        }

        var stderr = result.Stderr ?? "";
        if (DetectLoginRequired(stderr, trimmed) is { } loginError) throw loginError;
        var resolveHost = url.Host.ToLowerInvariant();
        // 风控（如 bilibili 412）：直接给诚实原因，不回退嗅探显示「页面加载失败」。
        if (RiskControlMessage(stderr, resolveHost) is { } riskMessage)
        {
            throw MoongateException.AnalyzeFailed(riskMessage);
        }
        // yt-dlp 原生支持的站点解析失败，回退嗅探没有意义，直接给原因。
        if (IsNativeExtractorHost(resolveHost))
        {
            throw MoongateException.AnalyzeFailed(FriendlyAnalyzeMessage(stderr));
        }
        IReadOnlyList<VideoCandidate> candidates;
        try
        {
            candidates = await SniffPageAsync(url, ct).ConfigureAwait(false);
        }
        catch (MoongateException)
        {
            throw;
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch
        {
            throw MoongateException.SniffFailed(L10n.T("页面加载失败，请稍后重试。", "頁面載入失敗，請稍後重試。", "The page failed to load. Try again later."));
        }
        if (candidates.Count == 0)
        {
            throw MoongateException.SniffFailed(L10n.T("可以换个页面，或直接粘贴视频文件地址。",
                "可以換個頁面，或直接貼上影片檔案地址。",
                "Try another page, or paste a direct video file URL."));
        }
        return candidates;
    }

    /// <summary>页面嗅探入口；virtual 供测试替换。</summary>
    protected virtual Task<IReadOnlyList<VideoCandidate>> SniffPageAsync(Uri pageUrl, CancellationToken ct) =>
        new PageSniffer().SniffAsync(pageUrl, ct);

    // MARK: - 第二步：解析格式与字幕

    public async Task<VideoInfo> AnalyzeAsync(string url, CancellationToken ct = default)
    {
        var trimmed = url.Trim();
        JsonElement json;
        if (CachedInfo(trimmed) is { } cached)
        {
            json = cached;
        }
        else
        {
            var result = await RunYtDlpJsonAsync(trimmed, ct).ConfigureAwait(false);
            if (result.Json is { } fetched)
            {
                SetCachedInfo(fetched, trimmed);
                json = fetched;
            }
            else
            {
                var stderr = result.Stderr ?? "";
                if (DetectLoginRequired(stderr, trimmed) is { } loginError) throw loginError;
                // 风控（如 bilibili 412）：给诚实原因而非通用「解析失败」。
                if (Uri.TryCreate(trimmed, UriKind.Absolute, out var analyzeUri)
                    && RiskControlMessage(stderr, analyzeUri.Host.ToLowerInvariant()) is { } riskMessage)
                {
                    throw MoongateException.AnalyzeFailed(riskMessage);
                }
                throw MoongateException.AnalyzeFailed(FriendlyAnalyzeMessage(stderr));
            }
        }
        return await BuildVideoInfoAsync(trimmed, json, ct).ConfigureAwait(false);
    }

    private sealed record YtDlpJsonResult(JsonElement? Json, string? Stderr);

    private async Task<YtDlpJsonResult> RunYtDlpJsonAsync(string url, CancellationToken ct)
    {
        var ytdlp = YtDlpPath();
        var ffmpegDir = FfmpegDirectory();
        var (cookieArgs, cleanup) = MakeCookieArguments(url);
        var networkArgs = MakeNetworkArguments();
        try
        {
            var lastStderr = "";
            for (var attempt = 0; attempt < 2; attempt++)
            {
                var args = new List<string> { "-J", "--no-playlist", "--ffmpeg-location", ffmpegDir };
                args.AddRange(cookieArgs);
                args.AddRange(networkArgs);
                args.Add(url);
                // 90s 而非 60s：中国大陆经代理/VPN 访问时握手+TLS+deno 冷启动延迟更高。
                var output = await RunProcessHookAsync(ytdlp, args, TimeSpan.FromSeconds(90), ct).ConfigureAwait(false);
                if (output.TimedOut)
                {
                    throw MoongateException.AnalyzeFailed(L10n.T("解析超时，请检查网络后重试",
                        "解析逾時，請檢查網路後重試",
                        "Analysis timed out. Check your network and retry"));
                }
                if (output.Status == 0)
                {
                    try
                    {
                        using var doc = JsonDocument.Parse(output.Stdout);
                        var root = doc.RootElement.Clone();
                        // --no-playlist 之下仍可能拿到 playlist 包装，取第一个条目兜底。
                        if (StringField(root, "_type") == "playlist"
                            && root.TryGetProperty("entries", out var entries)
                            && entries.ValueKind == JsonValueKind.Array
                            && entries.GetArrayLength() > 0)
                        {
                            root = entries[0].Clone();
                        }
                        return new YtDlpJsonResult(root, null);
                    }
                    catch (JsonException)
                    {
                        // 输出不是 JSON：按失败处理
                    }
                }
                lastStderr = output.Stderr;
                // YouTube 偶发返回空格式列表（"Requested format is not available"），
                // 属临时风控，隔 2 秒自动重试一次。
                if (attempt == 0 && lastStderr.Contains("Requested format is not available"))
                {
                    try { await Task.Delay(TimeSpan.FromSeconds(2), ct).ConfigureAwait(false); }
                    catch (OperationCanceledException) { throw MoongateException.Cancelled(); }
                    continue;
                }
                break;
            }
            return new YtDlpJsonResult(null, lastStderr);
        }
        finally
        {
            cleanup();
        }
    }

    /// <summary>一次性进程钩子；virtual 供测试替换。</summary>
    protected virtual async Task<(int Status, string Stdout, string Stderr, bool TimedOut)> RunProcessHookAsync(
        string executable, IReadOnlyList<string> arguments, TimeSpan? timeout, CancellationToken ct)
    {
        var output = await ProcessRunner.RunProcessAsync(executable, arguments, timeout, ct).ConfigureAwait(false);
        return (output.Status, output.Stdout, output.Stderr, output.TimedOut);
    }

    /// <summary>下载用的流式进程钩子；virtual 供测试替换（覆盖「首次格式缺失自动重试」交互路径）。</summary>
    protected virtual Task<(int Status, string StderrTail)> RunDownloadProcessHookAsync(
        string executable, IReadOnlyList<string> arguments,
        TimeSpan? stallTimeout, Func<bool>? isSuspended, Action<int>? onStart,
        Action<string>? onLine, CancellationToken ct) =>
        ProcessRunner.RunStreamingProcessAsync(
            executable, arguments, currentDirectory: null, stallTimeout: stallTimeout,
            isSuspended: isSuspended, onStart: onStart, onLine: onLine, ct: ct);

    internal async Task<VideoInfo> BuildVideoInfoAsync(string sourceUrl, JsonElement json, CancellationToken ct = default)
    {
        var videoId = StringField(json, "id") ?? StringField(json, "display_id") ?? "video";
        var title = StringField(json, "title") ?? sourceUrl;
        var durationText = DoubleField(json, "duration") is { } duration ? FormatDuration(duration) : null;
        var thumbnailUrl = StringField(json, "thumbnail");
        var uploader = StringField(json, "uploader") ?? StringField(json, "channel");
        var description = StringField(json, "description");

        var rawFormats = new List<JsonElement>();
        if (json.TryGetProperty("formats", out var formatsValue) && formatsValue.ValueKind == JsonValueKind.Array)
        {
            rawFormats.AddRange(formatsValue.EnumerateArray());
        }
        var videoFormats = rawFormats.Where(f =>
            StringField(f, "vcodec") != "none" && (IntField(f, "height") ?? 0) > 0).ToList();

        var formats = new List<FormatChoice>();

        if (videoFormats.Count > 0)
        {
            var heights = videoFormats
                .Select(f => IntField(f, "height"))
                .Where(h => h.HasValue)
                .Select(h => h!.Value)
                .Distinct()
                .OrderDescending()
                .ToList();
            var audioBytes = BestAudioSizeBytes(rawFormats);

            string? TierDetail(int height)
            {
                var tier = videoFormats.Where(f => IntField(f, "height") == height).ToList();
                var best = tier.Count == 0 ? default : tier.MaxBy(f => DoubleField(f, "tbr") ?? 0);
                double? videoBytes = null;
                if (best.ValueKind == JsonValueKind.Object)
                {
                    videoBytes = DoubleField(best, "filesize") ?? DoubleField(best, "filesize_approx");
                }
                if (videoBytes is null)
                {
                    var sizes = tier
                        .Select(f => DoubleField(f, "filesize") ?? DoubleField(f, "filesize_approx"))
                        .Where(s => s.HasValue)
                        .Select(s => s!.Value)
                        .ToList();
                    if (sizes.Count > 0) videoBytes = sizes.Max();
                }
                return videoBytes is { } bytes ? SizeText(bytes + (audioBytes ?? 0)) : null;
            }

            // 每个可见档位先精确绑定高度，再回退到不高于该档位的可用格式。
            // 避免 2160p/4K 行被 yt-dlp 的通配 best selector 解析成 1080p。
            for (var index = 0; index < Math.Min(heights.Count, 6); index++)
            {
                var height = heights[index];
                var formatId = VideoTierFormatSelector(height);
                var tier = videoFormats.Where(f => IntField(f, "height") == height).ToList();
                // 该档是否有 HDR 流。
                var hdrAvailable = tier.Any(f =>
                    DynamicRangeExtensions.FromYtDlpValue(StringField(f, "dynamic_range")).IsHdr());
                // 源编码/容器：取该档码率最高那个流的信息用于标注与转码决策。
                var bestStream = tier.Count == 0 ? default : tier.MaxBy(f => DoubleField(f, "tbr") ?? 0);
                string? vcodec = bestStream.ValueKind == JsonValueKind.Object && StringField(bestStream, "vcodec") is { } vc
                    ? ShortVCodec(vc) : null;
                var container = bestStream.ValueKind == JsonValueKind.Object ? StringField(bestStream, "ext") : null;
                var label = $"{height}p · mp4";
                if (hdrAvailable) label = $"{height}p · {L10n.T("可选 HDR", "可選 HDR", "HDR available")}";
                formats.Add(new FormatChoice
                {
                    Id = formatId,
                    Label = label,
                    Detail = TierDetail(height),
                    HdrAvailable = hdrAvailable,
                    SourceVCodec = vcodec,
                    SourceContainer = container,
                });
            }
        }
        else
        {
            // 直链文件：单一格式，无分档信息。
            var urlExt = Uri.TryCreate(sourceUrl, UriKind.Absolute, out var srcUri)
                ? Path.GetExtension(srcUri.AbsolutePath).TrimStart('.')
                : "";
            var ext = StringField(json, "ext") ?? (urlExt.Length == 0 ? "mp4" : urlExt);
            var label = $"{L10n.T("原始文件", "原始檔案", "Original file")} · {ext}";
            string? sizeDetail = null;
            if (rawFormats.Count > 0
                && (DoubleField(rawFormats[0], "filesize") ?? DoubleField(rawFormats[0], "filesize_approx")) is { } bytes)
            {
                sizeDetail = SizeText(bytes);
            }
            var mediaUrl = StringField(json, "url")
                ?? (rawFormats.Count > 0 ? StringField(rawFormats[0], "url") : null)
                ?? sourceUrl;
            if (await RunFfProbeAsync(mediaUrl, ct).ConfigureAwait(false) is { } probe)
            {
                if (probe.Height is { } height) label += $" · {height}p";
                if (durationText is null && probe.Duration is { } seconds)
                {
                    durationText = FormatDuration(seconds);
                }
                if (sizeDetail is null && probe.SizeBytes is { } probeBytes)
                {
                    sizeDetail = SizeText(probeBytes);
                }
            }
            if (sizeDetail is null && await HeadContentLengthAsync(mediaUrl, ct).ConfigureAwait(false) is { } headBytes)
            {
                sizeDetail = SizeText(headBytes);
            }
            formats.Add(new FormatChoice { Id = "best", Label = label, Detail = sizeDetail });
        }

        formats.Add(new FormatChoice { Id = "audio", Label = $"{L10n.T("仅音频", "僅音訊", "Audio only")} · m4a", Detail = null, IsAudioOnly = true });

        var subtitles = ParseSubtitles(json);
        // yt-dlp 没给字幕时（如 Apple WWDC 等走 generic/HLS 提取器的页面，字幕只存在于
        // HLS master manifest 里且被 yt-dlp 主动忽略），从 manifest 兜底解析内嵌字幕。
        if (subtitles.Count == 0)
        {
            var (choices, table) = await DiscoverHlsSubtitlesAsync(rawFormats, ct).ConfigureAwait(false);
            if (choices.Count > 0)
            {
                subtitles = choices;
                SetCachedHlsSubtitles(table, sourceUrl);
            }
        }

        return new VideoInfo
        {
            SourceUrl = sourceUrl,
            VideoId = videoId,
            Title = title,
            DurationText = durationText,
            ThumbnailUrl = thumbnailUrl,
            Uploader = uploader,
            Description = description,
            Formats = formats,
            Subtitles = subtitles,
        };
    }

    /// <summary>
    /// 拉取视频字幕纯文本（供 AI 总结优先使用）：yt-dlp --skip-download 抓字幕转 srt，按语言偏好挑一个清洗成整段文本。
    /// 取不到返回 null（调用方回退到简介）。与 macOS fetchSubtitleText 同构。
    /// </summary>
    public async Task<string?> FetchSubtitleTextAsync(
        string url,
        IReadOnlyList<string> preferredLanguages,
        TaskControlToken? control,
        CancellationToken ct = default)
    {
        if (ct.IsCancellationRequested) throw MoongateException.Cancelled();
        string ytdlp, ffmpegDir;
        try
        {
            ytdlp = YtDlpPath();
            ffmpegDir = FfmpegDirectory();
        }
        catch (MoongateException)
        {
            return null;
        }
        var tempDir = Path.Combine(Path.GetTempPath(), $"moongate-subs-{Guid.NewGuid():N}");
        Directory.CreateDirectory(tempDir);
        try
        {
            // 语言优先级：调用方给的偏好在前，再兜底常见语言。
            var langs = preferredLanguages
                .Concat(["en", "en-US", "zh-Hans", "zh", "ja", "ko"])
                .Where(l => !string.IsNullOrEmpty(l))
                .ToList();
            var langArg = langs.Count == 0 ? "all" : string.Join(",", langs) + ",all";

            var (cookieArgs, cleanup) = MakeCookieArguments(url);
            var networkArgs = MakeNetworkArguments();
            try
            {
                var args = new List<string>
                {
                    "--skip-download", "--no-playlist", "--ffmpeg-location", ffmpegDir,
                    "--write-subs", "--write-auto-subs", "--sub-langs", langArg,
                    "--sub-format", "vtt/best",
                    "-o", Path.Combine(tempDir, "%(id)s.%(ext)s"),
                };
                args.AddRange(cookieArgs);
                args.AddRange(networkArgs);
                args.Add(url);

                var (status, _, _, _) = await RunProcessHookAsync(
                    ytdlp, args, TimeSpan.FromSeconds(90), ct).ConfigureAwait(false);
                if (ct.IsCancellationRequested) throw MoongateException.Cancelled();
                _ = status; // 即便非零也尝试收字幕文件
            }
            finally
            {
                cleanup();
            }

            var subtitleFiles = Directory.Exists(tempDir)
                ? Directory.GetFiles(tempDir).Where(f => SubtitleExtensions.Contains(ExtensionOf(f))).ToList()
                : [];
            if (subtitleFiles.Count == 0) return null;

            int Score(string file)
            {
                var code = LangCodeOfSubtitle(file);
                if (code is null) return langs.Count;
                for (var i = 0; i < langs.Count; i++)
                    if (code.StartsWith(langs[i].ToLowerInvariant(), StringComparison.Ordinal)) return i;
                return langs.Count;
            }
            var chosen = subtitleFiles.OrderBy(Score).First();

            string raw;
            try { raw = await File.ReadAllTextAsync(chosen, ct).ConfigureAwait(false); }
            catch { return null; }
            var cues = SrtTools.CleanCues(SrtTools.ParseSubtitle(raw, chosen));
            if (cues.Count == 0) return null;
            var text = string.Join(" ", cues.Select(c => c.Text)).Trim();
            return text.Length == 0 ? null : text;
        }
        finally
        {
            try { Directory.Delete(tempDir, recursive: true); } catch { /* best-effort */ }
        }
    }

    internal sealed record HlsSubtitleEntry(string Lang, string? Name, string Url);

    /// <summary>
    /// 从 formats 的 manifest_url 抓取 HLS master m3u8，解析其中的 EXT-X-MEDIA:TYPE=SUBTITLES，
    /// 返回（SubtitleChoice 列表, [langCode: 字幕 m3u8 绝对 URL]）。失败返回空，绝不抛错（不能让 analyze 失败）。
    /// </summary>
    private async Task<(List<SubtitleChoice> Choices, Dictionary<string, string> Table)> DiscoverHlsSubtitlesAsync(
        List<JsonElement> formats, CancellationToken ct)
    {
        var manifest = formats
            .Select(f => StringField(f, "manifest_url"))
            .FirstOrDefault(m => !string.IsNullOrEmpty(m));
        if (manifest is null
            || !Uri.TryCreate(manifest, UriKind.Absolute, out var masterUrl)
            || await FetchTextAsync(masterUrl, ct).ConfigureAwait(false) is not { } text)
        {
            return ([], []);
        }
        var entries = ParseHlsSubtitleEntries(text, masterUrl);
        if (entries.Count == 0) return ([], []);

        var table = new Dictionary<string, string>();
        var seen = new HashSet<string>();
        var choices = new List<SubtitleChoice>();
        // 中文优先排序，最多保留 30 条。
        var sorted = entries.OrderBy(e => SubtitleSortKey(e.Lang).Rank)
            .ThenBy(e => SubtitleSortKey(e.Lang).Lower, StringComparer.Ordinal)
            .ToList();
        foreach (var entry in sorted.Take(30))
        {
            if (!seen.Add(entry.Lang)) continue;
            table[entry.Lang] = entry.Url;
            string label;
            var localized = SubtitleLabel(entry.Lang);
            // SubtitleLabel 认得的语言用本地化名，否则退回 manifest 里的 NAME。
            if (localized != entry.Lang)
            {
                label = localized;
            }
            else if (entry.Name is { Length: > 0 } name)
            {
                label = $"{name} ({entry.Lang})";
            }
            else
            {
                label = entry.Lang;
            }
            choices.Add(SubtitleChoice.Create(
                entry.Lang,
                label,
                SubtitleSourceKind.HlsManifest,
                provider: "hls",
                variant: entry.Url));
        }
        return (choices, table);
    }

    /// <summary>解析 master m3u8 文本里所有 TYPE=SUBTITLES 的媒体行；URI 相对 baseUrl 解析为绝对地址。</summary>
    internal static List<HlsSubtitleEntry> ParseHlsSubtitleEntries(string master, Uri baseUrl)
    {
        var entries = new List<HlsSubtitleEntry>();
        foreach (var rawLine in master.Split('\n', '\r'))
        {
            var trimmed = rawLine.Trim();
            if (!trimmed.StartsWith("#EXT-X-MEDIA:") || !trimmed.Contains("TYPE=SUBTITLES")) continue;
            var lang = HlsAttribute("LANGUAGE", trimmed);
            var uri = HlsAttribute("URI", trimmed);
            if (string.IsNullOrEmpty(lang) || string.IsNullOrEmpty(uri)) continue;
            string resolved;
            if (Uri.TryCreate(uri, UriKind.Absolute, out var abs))
            {
                resolved = abs.AbsoluteUri;
            }
            else if (Uri.TryCreate(baseUrl, uri, out var rel))
            {
                resolved = rel.AbsoluteUri;
            }
            else
            {
                continue;
            }
            entries.Add(new HlsSubtitleEntry(lang, HlsAttribute("NAME", trimmed), resolved));
        }
        return entries;
    }

    /// <summary>从 EXT-X-MEDIA 行里取属性值（支持带引号与不带引号）。</summary>
    internal static string? HlsAttribute(string key, string line)
    {
        var index = line.IndexOf(key + "=", StringComparison.Ordinal);
        if (index < 0) return null;
        var rest = line[(index + key.Length + 1)..];
        if (rest.StartsWith('"'))
        {
            var afterQuote = rest[1..];
            var end = afterQuote.IndexOf('"');
            return end < 0 ? null : afterQuote[..end];
        }
        var comma = rest.IndexOf(',');
        return (comma < 0 ? rest : rest[..comma]).Trim();
    }

    /// <summary>文本抓取（Safari UA、15s 超时）。失败返回 null。virtual 供测试替换。</summary>
    protected virtual async Task<string?> FetchTextAsync(Uri url, CancellationToken ct)
    {
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, url);
            request.Headers.TryAddWithoutValidation("User-Agent", PageSniffer.UserAgent);
            using var response = await SharedHttp.SendAsync(request, ct).ConfigureAwait(false);
            if ((int)response.StatusCode != 200) return null;
            return await response.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            throw;
        }
        catch
        {
            return null;
        }
    }

    // MARK: ffprobe / HEAD 补充信息

    protected internal sealed record ProbeInfo(int? Height, double? Duration, double? SizeBytes);

    /// <summary>ffprobe 直链补充信息；virtual 供测试替换（默认实现要起子进程）。</summary>
    protected virtual async Task<ProbeInfo?> RunFfProbeAsync(string urlString, CancellationToken ct)
    {
        var ffprobe = FfprobePath();
        if (ffprobe is null) return null;
        ProcessRunner.ProcessOutput output;
        try
        {
            output = await ProcessRunner.RunProcessAsync(
                ffprobe,
                ["-v", "quiet", "-print_format", "json", "-show_format", "-show_streams", urlString],
                TimeSpan.FromSeconds(20), ct).ConfigureAwait(false);
        }
        catch (MoongateException)
        {
            return null;
        }
        if (output.Status != 0) return null;
        try
        {
            using var doc = JsonDocument.Parse(output.Stdout);
            var root = doc.RootElement;
            int? height = null;
            if (root.TryGetProperty("streams", out var streams) && streams.ValueKind == JsonValueKind.Array)
            {
                foreach (var stream in streams.EnumerateArray())
                {
                    if (StringField(stream, "codec_type") == "video")
                    {
                        height = IntField(stream, "height");
                        break;
                    }
                }
            }
            double? duration = null, size = null;
            if (root.TryGetProperty("format", out var format) && format.ValueKind == JsonValueKind.Object)
            {
                duration = DoubleField(format, "duration");
                size = DoubleField(format, "size");
            }
            return new ProbeInfo(height, duration, size);
        }
        catch (JsonException)
        {
            return null;
        }
    }

    /// <summary>HEAD 请求取 Content-Length；virtual 供测试替换。</summary>
    protected virtual async Task<double?> HeadContentLengthAsync(string urlString, CancellationToken ct)
    {
        if (!Uri.TryCreate(urlString, UriKind.Absolute, out var url)) return null;
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Head, url);
            request.Headers.TryAddWithoutValidation("User-Agent", PageSniffer.UserAgent);
            using var response = await SharedHttp.SendAsync(request, ct).ConfigureAwait(false);
            if ((int)response.StatusCode != 200) return null;
            var length = response.Content.Headers.ContentLength ?? -1;
            return length > 0 ? length : null;
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            throw;
        }
        catch
        {
            return null;
        }
    }

    // MARK: 字幕

    private static readonly HashSet<string> AutoCaptionAllowList = ["zh-Hans", "zh-Hant", "zh", "en", "en-orig", "ja"];

    internal static List<SubtitleChoice> ParseSubtitles(JsonElement json)
    {
        var videoLangPrefix = StringField(json, "language") is { } lang
            ? lang.Split('-')[0].ToLowerInvariant()
            : null;

        var realCodes = new List<string>();
        if (json.TryGetProperty("subtitles", out var realDict) && realDict.ValueKind == JsonValueKind.Object)
        {
            realCodes.AddRange(realDict.EnumerateObject()
                .Select(p => p.Name)
                .Where(name => name != "live_chat" && name != "rechat"));
        }
        var real = realCodes
            .Select(code => SubtitleChoice.Create(code, SubtitleLabel(code), SubtitleSourceKind.Manual))
            .OrderBy(c => SubtitleSortKey(c.LanguageCode).Rank)
            .ThenBy(c => SubtitleSortKey(c.LanguageCode).Lower, StringComparer.Ordinal)
            .ToList();

        var autoCodes = new List<string>();
        if (json.TryGetProperty("automatic_captions", out var autoDict) && autoDict.ValueKind == JsonValueKind.Object)
        {
            foreach (var property in autoDict.EnumerateObject())
            {
                var code = property.Name;
                if (AutoCaptionAllowList.Contains(code))
                {
                    autoCodes.Add(code);
                    continue;
                }
                if (videoLangPrefix is not null
                    && code.Split('-')[0].ToLowerInvariant() == videoLangPrefix)
                {
                    autoCodes.Add(code);
                }
            }
        }
        var auto = autoCodes
            .OrderBy(c => SubtitleSortKey(c).Rank)
            .ThenBy(c => SubtitleSortKey(c).Lower, StringComparer.Ordinal)
            .Take(8)
            .Select(code => SubtitleChoice.Create(code, SubtitleLabel(code), SubtitleSourceKind.PlatformAuto));
        return [.. real, .. auto];
    }

    /// <summary>
    /// 常见语言的中文展示名（Swift 版用 Locale zh_CN 本地化；这里用固定表保证跨平台确定性）。
    /// 认不得的语言返回 code 本身（HLS 兜底路径据此回退 manifest 里的 NAME）。
    /// </summary>
    internal static string SubtitleLabel(string code)
    {
        var special = code switch
        {
            "zh-Hans" => L10n.T("简体中文", "簡體中文", "Simplified Chinese"),
            "zh-Hant" => L10n.T("繁体中文", "繁體中文", "Traditional Chinese"),
            _ => null,
        };
        if (special is not null) return $"{special} ({code})";
        var baseName = code.Split('-')[0].ToLowerInvariant() switch
        {
            "zh" => L10n.T("中文", "中文", "Chinese"),
            "en" => L10n.T("英语", "英語", "English"),
            "ja" => L10n.T("日语", "日語", "Japanese"),
            "ko" => L10n.T("韩语", "韓語", "Korean"),
            "fr" => L10n.T("法语", "法語", "French"),
            "de" => L10n.T("德语", "德語", "German"),
            "es" => L10n.T("西班牙语", "西班牙語", "Spanish"),
            "pt" => L10n.T("葡萄牙语", "葡萄牙語", "Portuguese"),
            "ru" => L10n.T("俄语", "俄語", "Russian"),
            "it" => L10n.T("意大利语", "義大利語", "Italian"),
            "ar" => L10n.T("阿拉伯语", "阿拉伯語", "Arabic"),
            "hi" => L10n.T("印地语", "印地語", "Hindi"),
            "th" => L10n.T("泰语", "泰語", "Thai"),
            "vi" => L10n.T("越南语", "越南語", "Vietnamese"),
            "id" => L10n.T("印度尼西亚语", "印尼語", "Indonesian"),
            "nl" => L10n.T("荷兰语", "荷蘭語", "Dutch"),
            "tr" => L10n.T("土耳其语", "土耳其語", "Turkish"),
            "pl" => L10n.T("波兰语", "波蘭語", "Polish"),
            "sv" => L10n.T("瑞典语", "瑞典語", "Swedish"),
            "uk" => L10n.T("乌克兰语", "烏克蘭語", "Ukrainian"),
            _ => null,
        };
        return baseName is null ? code : $"{baseName} ({code})";
    }

    internal static (int Rank, string Lower) SubtitleSortKey(string code)
    {
        var lower = code.ToLowerInvariant();
        var rank = lower switch
        {
            _ when lower.StartsWith("zh") => 0,
            _ when lower == "en" || lower.StartsWith("en-") => 1,
            _ when lower == "ja" || lower.StartsWith("ja-") => 2,
            _ => 3,
        };
        return (rank, lower);
    }

    // MARK: - 第三步：下载

    /// <summary>preferredTitle 作为字面量进入 yt-dlp 输出模板：需转义 %、去掉路径分隔符并限长。</summary>
    internal static string OutputTemplate(string? preferredTitle)
    {
        const string fallback = "%(title).180B [%(id)s].%(ext)s";
        if (preferredTitle is null) return fallback;
        var clean = preferredTitle.Replace("%", "%%");
        // 换行/控制字符并入分隔集：含 \n 的页面标题会破坏 --print 行匹配
        var separators = new HashSet<char> { '/', '\\', ':', '\0', '\n', '\r', '\v', '\f', '\u0085', '\u2028', '\u2029' };
        clean = new string(clean.Select(c => separators.Contains(c) ? ' ' : c).ToArray()).Trim();
        if (clean.Length > 120) clean = clean[..120];
        if (clean.Length == 0) return fallback;
        return $"{clean} [%(id)s].%(ext)s";
    }

    internal static int ExpectedMediaDownloadCount(string formatId) =>
        ContainsMergeOperator(formatId) ? 2 : 1;

    private static bool ContainsMergeOperator(string selector)
    {
        var bracketDepth = 0;
        foreach (var ch in selector)
        {
            if (ch == '[')
            {
                bracketDepth++;
            }
            else if (ch == ']')
            {
                bracketDepth = Math.Max(0, bracketDepth - 1);
            }
            else if (ch == '+' && bracketDepth == 0)
            {
                return true;
            }
        }
        return false;
    }

    public async Task<DownloadResult> DownloadAsync(
        DownloadRequest request,
        TaskControlToken? control,
        Action<DownloadProgress> progress,
        CancellationToken ct = default)
    {
        var ytdlp = YtDlpPath();
        var ffmpegDir = FfmpegDirectory();
        var destDir = request.DestinationDirectory;
        try { Directory.CreateDirectory(destDir); } catch { /* 与 Swift 一致：失败留给下载报错 */ }

        var args = new List<string>
        {
            "--no-playlist", "--newline", "--no-mtime",
            "--progress-template",
            "download:MGP|%(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s",
            "--ffmpeg-location", ffmpegDir,
            "-P", destDir,
            "-o", OutputTemplate(request.PreferredTitle),
            // 网络韧性：分片并发提速 + 读超时 + 重试，缓解通用站点的下载中途停滞。
            "-N", "4",
            "--socket-timeout", "30",
            "--retries", "10",
            "--fragment-retries", "10",
        };
        var (cookieArgs, cleanup) = MakeCookieArguments(request.Url);
        var networkArgs = MakeNetworkArguments();
        try
        {
            args.AddRange(cookieArgs);
            args.AddRange(networkArgs);
            if (request.FormatId == "audio")
            {
                args.AddRange(["-f", "ba/b", "-x", "--audio-format", "m4a"]);
            }
            else
            {
                // HDR：把 height 选择器加上 dynamic_range 偏好，并用 mkv 封装（mp4 装 VP9.2-HDR 不可靠）。
                var formatSelector = ApplyHdrPreference(request.FormatId, request.PreferHdr);
                var mergeContainer = request.PreferHdr ? "mkv" : "mp4";
                args.AddRange(["-f", formatSelector, "--merge-output-format", mergeContainer]);
            }
            var subtitleLangs = request.YtDlpSubtitleLangs;
            var autoSubtitleLangs = request.YtDlpAutoSubtitleLangs;
            var allSubLangs = DownloadRequest.UniqueForYtDlpSubLangs(subtitleLangs.Concat(autoSubtitleLangs));
            if (allSubLangs.Count > 0)
            {
                args.AddRange(["--sub-langs", string.Join(",", allSubLangs)]);
                if (subtitleLangs.Count > 0) args.Add("--write-subs");
                if (autoSubtitleLangs.Count > 0) args.Add("--write-auto-subs");
                if (autoSubtitleLangs.Count == 0)
                {
                    args.AddRange(["--convert-subs", "srt"]);
                }
                else
                {
                    args.AddRange(["--sub-format", "vtt/best"]);
                }
            }
            // --print 默认隐含 simulate/quiet，必须配 --no-simulate / --no-quiet 抵消。
            args.AddRange(["--print", "after_move:filepath", "--no-simulate", "--no-quiet"]);
            args.Add(request.Url);

            progress(new DownloadProgress { Phase = DownloadProgress.ProgressPhase.Preparing });

            // control 已请求取消：不必启动子进程。
            if (control?.IsCancelled == true) throw MoongateException.Cancelled();

            var sep = Path.DirectorySeparatorChar;
            var destPrefix = destDir.EndsWith(sep) ? destDir : destDir + sep;
            var printedPaths = new List<string>();
            var printedLock = new object();
            var progressTracker = new DownloadProgressTracker(ExpectedMediaDownloadCount(request.FormatId));
            int status = -1;
            string stderrTail = "";
            // 首次下载偶发 "Requested format is not available"（YouTube n-challenge 冷启动 /
            // 临时风控），yt-dlp 第二次运行 player 缓存已热即成功——正是用户反馈的「要点两次才能下载」。
            // 自动重试一次省掉用户手动再点；仅对该可恢复错误重试，其它错误立即上抛。
            for (var attempt = 0; attempt < 2; attempt++)
            {
                lock (printedLock) printedPaths.Clear();
                try
                {
                    (status, stderrTail) = await RunDownloadProcessHookAsync(
                        ytdlp, args,
                        stallTimeout: TimeSpan.FromSeconds(600),
                        isSuspended: () => control?.IsPaused ?? false,
                        onStart: pid => control?.SetActivePid(pid),
                        onLine: line =>
                        {
                            if (ParseProgressLine(line, progressTracker) is { } update) progress(update);
                            if (line.StartsWith(destPrefix, StringComparison.Ordinal))
                            {
                                lock (printedLock)
                                {
                                    if (!printedPaths.Contains(line)) printedPaths.Add(line);
                                }
                            }
                        },
                        ct: ct).ConfigureAwait(false);
                    control?.SetActivePid(0);
                }
                catch (ProcessStalledException)
                {
                    control?.SetActivePid(0);
                    // 保留 .part 文件：yt-dlp 重试时可断点续传。
                    throw MoongateException.DownloadFailed(L10n.T(
                        "下载停滞：超过 10 分钟没有任何进度输出，已自动中止。可能是站点限速或网络中断，可点「重试」续传。",
                        "下載停滯：超過 10 分鐘沒有任何進度輸出，已自動中止。可能是站點限速或網路中斷，可點「重試」續傳。",
                        "Download stalled: no progress for 10 minutes, stopped automatically. The site may be throttling or the network dropped; press Retry to resume."));
                }
                catch (Exception e)
                {
                    control?.SetActivePid(0);
                    // 取消路径：进程已确认退出，先清掉残留的临时文件再上抛。
                    if (e is MoongateException { Kind: MoongateErrorKind.Cancelled } or OperationCanceledException)
                    {
                        CleanupTemporaryFiles(destDir, request.VideoId);
                    }
                    throw;
                }
                // 可恢复的 yt-dlp 下载失败：未取消、还有重试机会时，自动再跑一次。
                if (attempt == 0 && status != 0 && control?.IsCancelled != true
                    && IsRecoverableDownloadRetry(stderrTail, request.Url))
                {
                    continue;
                }
                break;
            }

            // control 取消会直接杀进程树（不经由 ct）：归一化为取消而非「下载失败」。
            if (control?.IsCancelled == true)
            {
                CleanupTemporaryFiles(destDir, request.VideoId);
                throw MoongateException.Cancelled();
            }

            if (status != 0)
            {
                if (DetectLoginRequired(stderrTail, request.Url) is { } loginError) throw loginError;
                throw MoongateException.DownloadFailed(FriendlyDownloadReason(stderrTail));
            }
            // 注意：HLS 字幕兜底还在后面，Finished 留到全部产物就绪后再报，
            // 避免 UI 显示完成后任务还在后台拉字幕（源停摆时像卡死在 100%）。
            progress(new DownloadProgress { Phase = DownloadProgress.ProgressPhase.Processing });

            // 优先用 --print after_move:filepath 的精确产出；目录扫描降级为兜底。
            List<string> files;
            lock (printedLock)
            {
                files = printedPaths.Where(File.Exists).ToList();
            }
            if (files.Count == 0)
            {
                files = CollectOutputFiles(destDir, request.VideoId);
            }
            else if (allSubLangs.Count > 0)
            {
                // --print 不会打印字幕文件，用目录扫描补齐字幕。
                var known = new HashSet<string>(files);
                files.AddRange(CollectOutputFiles(destDir, request.VideoId).Where(f =>
                    SubtitleExtensions.Contains(ExtensionOf(f)) && !known.Contains(f)));
            }
            if (files.Count == 0)
            {
                throw MoongateException.DownloadFailed(L10n.T("下载进程已结束，但在目标目录里没有找到产出文件。",
                    "下載程序已結束，但在目標資料夾裡沒有找到產出檔案。",
                    "The download process finished, but no output file was found in the destination folder."));
            }

            // yt-dlp 取不到的字幕（如 Apple WWDC 等只存在于 HLS manifest 里的字幕）：
            // 检测请求的字幕里哪些没落地 .srt，对缺失的 lang 用 ffmpeg 从 HLS 字幕 m3u8 转出。
            if (allSubLangs.Count > 0)
            {
                var videoFile = files.FirstOrDefault(f => !SubtitleExtensions.Contains(ExtensionOf(f)));
                if (videoFile is not null)
                {
                    var presentLangs = new HashSet<string>(files
                        .Where(f => SubtitleExtensions.Contains(ExtensionOf(f)))
                        .Select(LangCodeOfSubtitle)
                        .Where(l => l is not null)
                        .Select(l => l!));
                    var missing = allSubLangs.Where(l => !presentLangs.Contains(l.ToLowerInvariant())).ToList();
                    if (missing.Count > 0)
                    {
                        var table = await HlsSubtitleTableAsync(request.Url, ct).ConfigureAwait(false);
                        foreach (var lang in missing)
                        {
                            if (!table.TryGetValue(lang, out var m3u8)) continue;
                            if (control?.IsCancelled == true) throw MoongateException.Cancelled();
                            var srt = await FetchHlsSubtitleAsync(m3u8, lang, videoFile, control, ct).ConfigureAwait(false);
                            if (srt is not null && !files.Contains(srt))
                            {
                                files.Add(srt);
                            }
                        }
                    }
                }
            }
            progress(new DownloadProgress { Phase = DownloadProgress.ProgressPhase.Finished, Percent = 100 });
            return new DownloadResult { Files = files };
        }
        finally
        {
            cleanup();
        }
    }

    /// <summary>
    /// 取 sourceURL 的 HLS 字幕表：优先用 analyze 阶段缓存（GUI 同一引擎实例命中）；
    /// 缓存缺失时按需重新拉 JSON + 解析 manifest。
    /// </summary>
    private async Task<Dictionary<string, string>> HlsSubtitleTableAsync(string url, CancellationToken ct)
    {
        if (CachedHlsSubtitles(url) is { } cached) return cached;
        JsonElement json;
        if (CachedInfo(url) is { } info)
        {
            json = info;
        }
        else
        {
            try
            {
                var result = await RunYtDlpJsonAsync(url, ct).ConfigureAwait(false);
                if (result.Json is not { } fetched) return [];
                json = fetched;
            }
            catch (MoongateException)
            {
                return [];
            }
        }
        var rawFormats = new List<JsonElement>();
        if (json.TryGetProperty("formats", out var formatsValue) && formatsValue.ValueKind == JsonValueKind.Array)
        {
            rawFormats.AddRange(formatsValue.EnumerateArray());
        }
        var (_, table) = await DiscoverHlsSubtitlesAsync(rawFormats, ct).ConfigureAwait(false);
        if (table.Count > 0) SetCachedHlsSubtitles(table, url);
        return table;
    }

    /// <summary>从字幕文件名 "&lt;名&gt;.&lt;lang&gt;.srt" 解析出 lang code（小写）。</summary>
    internal static string? LangCodeOfSubtitle(string file)
    {
        var stem = Path.GetFileNameWithoutExtension(file);
        var dotIndex = stem.LastIndexOf('.');
        if (dotIndex < 0) return null;
        return stem[(dotIndex + 1)..].ToLowerInvariant();
    }

    /// <summary>
    /// 用 ffmpeg 把单语 HLS 字幕 m3u8 转成 srt，输出 "&lt;视频名去扩展&gt;.&lt;lang&gt;.srt"。
    /// 失败返回 null（跳过该 lang，不影响整体下载）。
    /// </summary>
    private static async Task<string?> FetchHlsSubtitleAsync(
        string m3u8, string lang, string videoFile, TaskControlToken? control, CancellationToken ct)
    {
        var ffmpeg = BinaryLocator.Locate("ffmpeg", "MOONGATE_FFMPEG_PATH");
        if (ffmpeg is null) return null;
        var stem = Path.GetFileNameWithoutExtension(videoFile);
        var output = Path.Combine(Path.GetDirectoryName(videoFile) ?? ".", $"{stem}.{lang}.srt");
        try { File.Delete(output); } catch { /* 忽略 */ }
        try
        {
            var (status, _) = await ProcessRunner.RunStreamingProcessAsync(
                ffmpeg,
                ["-y", "-i", m3u8, output],
                // 远端 m3u8 可能死链/停滞：1 分钟无输出即放弃该语言。
                stallTimeout: TimeSpan.FromSeconds(60),
                isSuspended: () => control?.IsPaused ?? false,
                // 登记 pid：暂停/取消也能管到这个收尾阶段的 ffmpeg。
                onStart: pid => control?.SetActivePid(pid),
                onLine: _ => { },
                ct: ct).ConfigureAwait(false);
            control?.SetActivePid(0);
            if (status == 0 && File.Exists(output)) return output;
        }
        catch (ProcessStalledException)
        {
            control?.SetActivePid(0);
        }
        catch (MoongateException)
        {
            control?.SetActivePid(0);
        }
        return null;
    }

    /// <summary>取消后清理 yt-dlp 留下的临时文件（.part / .ytdl / 分片 .part-Frag…）。</summary>
    internal static void CleanupTemporaryFiles(string directory, string videoId)
    {
        var marker = $"[{videoId}]";
        string[] contents;
        try
        {
            contents = Directory.GetFiles(directory);
        }
        catch
        {
            return;
        }
        foreach (var file in contents)
        {
            var name = Path.GetFileName(file);
            if (!name.Contains(marker)) continue;
            var ext = ExtensionOf(file);
            if (ext == "part" || ext == "ytdl" || name.Contains(".part-Frag"))
            {
                try { File.Delete(file); } catch { /* 忽略 */ }
            }
        }
    }

    private static readonly string[] ProcessingPrefixes =
    [
        "[Merger]", "[ExtractAudio]", "[SubtitleConvertor]", "[VideoConvertor]", "[Fixup",
    ];

    /// <summary>解析 yt-dlp 输出行：MGP| 进度模板 → Downloading；后处理前缀 → Processing；其余 null。</summary>
    internal static DownloadProgress? ParseProgressLine(string line, DownloadProgressTracker? tracker = null)
    {
        if (line.StartsWith("MGP|", StringComparison.Ordinal))
        {
            var parts = line.Split('|').Select(p => p.Trim()).ToArray();
            double? percent = null;
            if (parts.Length > 1
                && double.TryParse(parts[1].Replace("%", ""), NumberStyles.Float, CultureInfo.InvariantCulture, out var value))
            {
                percent = value;
            }
            var speed = parts.Length > 2 ? NormalizeField(parts[2]) : null;
            var eta = parts.Length > 3 ? NormalizeField(parts[3]) : null;
            return new DownloadProgress
            {
                Phase = DownloadProgress.ProgressPhase.Downloading,
                Percent = tracker?.NormalizePercent(percent) ?? NormalizeProgressPercent(percent),
                SpeedText = speed,
                EtaText = tracker is null ? eta : tracker.NormalizeEtaText(eta),
            };
        }
        if (ProcessingPrefixes.Any(prefix => line.StartsWith(prefix, StringComparison.Ordinal)))
        {
            return new DownloadProgress { Phase = DownloadProgress.ProgressPhase.Processing };
        }
        return null;
    }

    private static double? NormalizeProgressPercent(double? value)
    {
        if (value is not { } percent || double.IsNaN(percent) || double.IsInfinity(percent)) return null;
        return Math.Clamp(percent, 0, 100);
    }

    private static string? NormalizeField(string value) =>
        value.Length == 0 || value == "N/A" || value == "Unknown" ? null : value;

    /// <summary>
    /// 两段式文案：中文主句 + 换行 + 原始 ERROR 行（截断 200 字符），UI 分层展示。
    /// 需要登录的情况已在上游由 DetectLoginRequired 拦截为 LoginRequired。
    /// </summary>
    internal static string FriendlyDownloadReason(string stderrTail)
    {
        var rawLine = SummarizeStderr(stderrTail);
        if (stderrTail.Contains("HTTP Error 403") || stderrTail.Contains("403 Forbidden"))
        {
            return L10n.T("资源拒绝访问（403），可能存在防盗链或地区限制。可先在浏览器确认视频能正常播放，或换一个候选来源。",
                "資源拒絕存取（403），可能有防盜連或地區限制。可先在瀏覽器確認影片能正常播放，或換一個候選來源。",
                "Access denied (403): possibly hotlink protection or a region lock. Confirm the video plays in a browser, or pick another source.") + "\n" + rawLine;
        }
        if (IsCertificateTrustError(stderrTail))
        {
            return L10n.T("HTTPS 证书校验失败。请先检查 Windows 系统时间、系统根证书，以及代理/VPN 是否安装了需要信任的根证书，然后重试。",
                "HTTPS 憑證校驗失敗。請先檢查 Windows 系統時間、系統根憑證，以及代理/VPN 是否安裝了需要信任的根憑證，然後重試。",
                "HTTPS certificate validation failed. Check the Windows system time, root certificates, and whether your proxy/VPN requires a trusted root certificate, then retry.") + "\n" + rawLine;
        }
        if (IsLikelyNetworkError(stderrTail))
        {
            return L10n.T("网络连接不稳定或被中断。若在中国大陆访问 YouTube 等站点，请确认代理/VPN 已开启且工作正常，再点「重试」。",
                "網路連線不穩定或被中斷。若在中國大陸訪問 YouTube 等站點，請確認代理/VPN 已開啟且正常運作，再點「重試」。",
                "The network connection is unstable or was interrupted. If you are behind the GFW, make sure your proxy/VPN is on and working, then press Retry.") + "\n" + rawLine;
        }
        return L10n.T("下载过程中出现错误。", "下載過程中發生錯誤。", "An error occurred while downloading.") + "\n" + rawLine;
    }

    /// <summary>识别与网络/代理相关的子进程错误（用于给中国大陆用户更有针对性的提示）。</summary>
    private static bool IsCertificateTrustError(string stderr)
    {
        var lower = stderr.ToLowerInvariant();
        string[] markers =
        [
            "certificate_verify_failed", "certificate verify failed",
            "unable to get local issuer certificate", "self-signed certificate",
            "sec_e_untrusted_root", "untrusted root",
        ];
        return markers.Any(lower.Contains);
    }

    internal static bool IsLikelyNetworkError(string stderr)
    {
        var lower = stderr.ToLowerInvariant();
        string[] markers =
        [
            "timed out", "timeout", "connection reset", "connection refused",
            "connection aborted", "temporary failure in name resolution",
            "failed to establish a new connection", "network is unreachable",
            "unable to connect", "ssl", "tunnel connection failed",
            "getaddrinfo", "name or service not known", "no route to host",
        ];
        return markers.Any(lower.Contains);
    }

    internal static bool IsRecoverableDownloadRetry(string stderr, string url)
    {
        if (stderr.Contains("Requested format is not available", StringComparison.Ordinal))
        {
            return true;
        }
        if ((stderr.Contains("HTTP Error 403", StringComparison.OrdinalIgnoreCase)
                || stderr.Contains("403 Forbidden", StringComparison.OrdinalIgnoreCase))
            && Uri.TryCreate(url, UriKind.Absolute, out var parsed)
            && IsYouTubeHost(parsed.Host))
        {
            return true;
        }
        return false;
    }

    internal static readonly HashSet<string> SubtitleExtensions = ["srt", "vtt", "ass", "ssa", "lrc", "ttml"];

    private static string ExtensionOf(string path) =>
        Path.GetExtension(path).TrimStart('.').ToLowerInvariant();

    internal static List<string> CollectOutputFiles(string directory, string videoId)
    {
        var marker = $"[{videoId}]";
        var tempExts = new HashSet<string> { "part", "ytdl", "temp" };
        string[] contents;
        try
        {
            contents = Directory.GetFiles(directory);
        }
        catch
        {
            return [];
        }
        var matched = contents
            .Where(f => Path.GetFileName(f).Contains(marker) && !tempExts.Contains(ExtensionOf(f)))
            .ToList();
        var videos = matched.Where(f => !SubtitleExtensions.Contains(ExtensionOf(f)))
            .OrderBy(Path.GetFileName, StringComparer.Ordinal);
        var subs = matched.Where(f => SubtitleExtensions.Contains(ExtensionOf(f)))
            .OrderBy(Path.GetFileName, StringComparer.Ordinal);
        return [.. videos, .. subs];
    }

    // MARK: - 杂项

    internal static bool IsYouTubeHost(string host)
    {
        var h = host.ToLowerInvariant();
        return h == "youtu.be"
            || h == "youtube.com" || h.EndsWith(".youtube.com")
            || h == "youtube-nocookie.com" || h.EndsWith(".youtube-nocookie.com");
    }

    internal static bool IsBilibiliHost(string host)
    {
        var h = host.ToLowerInvariant();
        return h == "bilibili.com" || h.EndsWith(".bilibili.com") || h == "b23.tv";
    }

    internal static bool IsTikTokHost(string host)
    {
        var h = host.ToLowerInvariant();
        return h == "tiktok.com" || h.EndsWith(".tiktok.com");
    }

    internal static bool IsDouyinHost(string host)
    {
        var h = host.ToLowerInvariant();
        return h == "douyin.com" || h.EndsWith(".douyin.com")
            || h == "iesdouyin.com" || h.EndsWith(".iesdouyin.com")
            || h == "amemv.com" || h.EndsWith(".amemv.com");
    }

    internal static bool IsXiaohongshuHost(string host)
    {
        var h = host.ToLowerInvariant();
        return h == "xiaohongshu.com" || h.EndsWith(".xiaohongshu.com")
            || h == "xhslink.com" || h.EndsWith(".xhslink.com");
    }

    /// <summary>yt-dlp 原生 extractor 的站点（非靠网页嗅探）。解析失败应直接给原因，不回退嗅探显示误导性的「页面加载失败」。</summary>
    internal static bool IsNativeExtractorHost(string host) =>
        IsYouTubeHost(host)
        || IsBilibiliHost(host)
        || IsTikTokHost(host)
        || IsDouyinHost(host)
        || IsXiaohongshuHost(host);

    /// <summary>站点风控/限流（如 bilibili HTTP 412）：给诚实可操作的提示。与 macOS riskControlMessage 同构。</summary>
    internal static string? RiskControlMessage(string stderr, string host)
    {
        var summary = SummarizeStderr(stderr);
        var lower = summary.ToLowerInvariant();
        var is412 = lower.Contains("412") || lower.Contains("precondition failed");
        var isRisk = lower.Contains("risk") || summary.Contains("风控") || summary.Contains("安全风控");
        if (!is412 && !isRisk) return null;
        if (IsBilibiliHost(host))
        {
            return L10n.T(
                "哔哩哔哩触发了安全风控（HTTP 412），暂时拒绝了解析请求。这通常是短时间请求过多或登录尝试频繁导致，和你的网络出口 IP 相关。建议：等待 10–30 分钟再试、换一个网络环境、或在浏览器里正常访问 B 站确认账号未受限。不要反复点登录，会延长风控时间。",
                "Bilibili 觸發了安全風控（HTTP 412），暫時拒絕了解析請求。這通常是短時間請求過多或登入嘗試頻繁導致，和你的網路出口 IP 相關。建議：等待 10–30 分鐘再試、換一個網路環境，或在瀏覽器裡正常訪問 B 站確認帳號未受限。不要反覆點登入，會延長風控時間。",
                "Bilibili triggered anti-bot protection (HTTP 412) and temporarily refused the request. This usually comes from too many requests or repeated logins from your IP. Wait 10–30 minutes, switch networks, or open Bilibili in a browser to confirm your account is fine. Don't keep retrying login—it prolongs the block.");
        }
        return L10n.T(
            "站点触发了访问风控（HTTP 412），暂时拒绝了请求。请稍后重试或更换网络环境。",
            "站點觸發了訪問風控（HTTP 412），暫時拒絕了請求。請稍後重試或更換網路環境。",
            "The site triggered access protection (HTTP 412) and refused the request. Retry later or switch networks.");
    }

    /// <summary>解析阶段错误的中文化（自动重试一次后仍失败才会走到这里）。</summary>
    internal static string FriendlyAnalyzeMessage(string stderr)
    {
        if (stderr.Contains("Requested format is not available"))
        {
            return L10n.T("站点暂时没有返回可用的清晰度（多为临时风控），请稍后重试；若反复出现，可在设置里重新登录。",
                "站點暫時沒有返回可用的清晰度（多為臨時風控），請稍後重試；若反覆出現，可在設定裡重新登入。",
                "The site returned no usable formats (usually temporary anti-bot). Retry later; if it persists, sign in again in Settings.");
        }
        if (IsCertificateTrustError(stderr))
        {
            return L10n.T("解析失败：HTTPS 证书校验失败。请先检查 Windows 系统时间、系统根证书，以及代理/VPN 是否安装了需要信任的根证书，然后重试。",
                "解析失敗：HTTPS 憑證校驗失敗。請先檢查 Windows 系統時間、系統根憑證，以及代理/VPN 是否安裝了需要信任的根憑證，然後重試。",
                "Analysis failed: HTTPS certificate validation failed. Check the Windows system time, root certificates, and whether your proxy/VPN requires a trusted root certificate, then retry.");
        }
        if (stderr.Contains("Video unavailable", StringComparison.OrdinalIgnoreCase)
            || stderr.Contains("This video is unavailable", StringComparison.OrdinalIgnoreCase))
        {
            return L10n.T("YouTube 返回视频不可用。若浏览器里能播放，请确认月之门使用的是同一个账号和同一个代理出口；可在设置里登录 YouTube，或填写视频代理地址后重试。",
                "YouTube 回傳影片不可用。若瀏覽器裡能播放，請確認月之門使用的是同一個帳號和同一個代理出口；可在設定裡登入 YouTube，或填寫影片代理位址後重試。",
                "YouTube says the video is unavailable. If it plays in your browser, make sure Moongate uses the same account and proxy route; sign in to YouTube in Settings or set a video proxy, then retry.");
        }
        if (IsLikelyNetworkError(stderr))
        {
            return L10n.T("解析失败：网络连接不稳定或被中断。若在中国大陆访问 YouTube 等站点，请确认代理/VPN 已开启且工作正常，再重试。",
                "解析失敗：網路連線不穩定或被中斷。若在中國大陸訪問 YouTube 等站點，請確認代理/VPN 已開啟且正常運作，再重試。",
                "Analysis failed: the network is unstable or was interrupted. If you are behind the GFW, make sure your proxy/VPN is on and working, then retry.");
        }
        return SummarizeStderr(stderr);
    }

    internal static string SummarizeStderr(string text)
    {
        var lines = text.Split('\n')
            .Select(l => l.Trim())
            .Where(l => l.Length > 0)
            .ToList();
        var errorLine = lines.LastOrDefault(l => l.StartsWith("ERROR", StringComparison.Ordinal))
            ?? lines.LastOrDefault()
            ?? L10n.T("未知错误", "未知錯誤", "Unknown error");
        return errorLine.Length > 200 ? errorLine[..200] : errorLine;
    }

    // MARK: JSON 取值小工具（容忍数值/字符串混用，等价 Swift 的 NSNumber 桥接）

    internal static string? StringField(JsonElement element, string name) =>
        element.ValueKind == JsonValueKind.Object
        && element.TryGetProperty(name, out var v)
        && v.ValueKind == JsonValueKind.String
            ? v.GetString()
            : null;

    internal static int? IntField(JsonElement element, string name)
    {
        if (element.ValueKind != JsonValueKind.Object || !element.TryGetProperty(name, out var v)) return null;
        if (v.ValueKind != JsonValueKind.Number) return null;
        if (v.TryGetInt32(out var i)) return i;
        return v.TryGetDouble(out var d) ? (int)d : null;
    }

    internal static double? DoubleField(JsonElement element, string name)
    {
        if (element.ValueKind != JsonValueKind.Object || !element.TryGetProperty(name, out var v)) return null;
        if (v.ValueKind == JsonValueKind.Number && v.TryGetDouble(out var d)) return d;
        if (v.ValueKind == JsonValueKind.String
            && double.TryParse(v.GetString(), NumberStyles.Float, CultureInfo.InvariantCulture, out var parsed))
        {
            return parsed;
        }
        return null;
    }

    internal static double? BestAudioSizeBytes(List<JsonElement> formats)
    {
        var audioOnly = formats.Where(f =>
        {
            var acodec = StringField(f, "acodec");
            var vcodec = StringField(f, "vcodec");
            return acodec is not null && acodec != "none" && (vcodec is null || vcodec == "none");
        }).ToList();
        if (audioOnly.Count == 0) return null;
        var best = audioOnly.MaxBy(f => DoubleField(f, "abr") ?? DoubleField(f, "tbr") ?? 0);
        return DoubleField(best, "filesize") ?? DoubleField(best, "filesize_approx");
    }

    /// <summary>把 yt-dlp 的 vcodec 串归一为短名（vp9/av1/h264/h265/vp8…）。与 macOS shortVCodec 同构。</summary>
    internal static string ShortVCodec(string raw)
    {
        var v = raw.ToLowerInvariant();
        if (v.StartsWith("vp9") || v.StartsWith("vp09")) return "vp9";
        if (v.StartsWith("av01") || v.StartsWith("av1")) return "av1";
        if (v.StartsWith("avc") || v.StartsWith("h264")) return "h264";
        if (v.StartsWith("hev") || v.StartsWith("hvc") || v.StartsWith("h265")) return "h265";
        if (v.StartsWith("vp8")) return "vp8";
        return v.Split('.').FirstOrDefault() ?? v;
    }

    /// <summary>
    /// Selector for one visible quality tier. The exact-height branch is first so a
    /// visible 2160p row cannot resolve to 1080p while that 2160p stream exists.
    /// </summary>
    internal static string VideoTierFormatSelector(int height) =>
        $"bv*[height={height}]+ba/b[height={height}]/bv*[height<={height}]+ba/b[height<={height}]";

    /// <summary>
    /// 给基础 -f 选择器加上 HDR 偏好：每个 fallback 分支先尝试 HDR，再尝试原分支。
    /// 这样 2160p 档会按「2160 HDR → 2160 普通 → <=2160 HDR → <=2160 普通」回退，
    /// 不会为了 HDR 静默跳到低一档。与 macOS applyHDRPreference 同构。
    /// </summary>
    internal static string ApplyHdrPreference(string selector, bool preferHdr)
    {
        if (!preferHdr) return selector;
        var branches = selector.Split('/');
        return string.Join("/", branches.SelectMany(branch =>
        {
            var hdrVariant = branch.Replace("bv*", "bv*[dynamic_range!=SDR]");
            if (hdrVariant == branch) return new[] { branch };
            return new[] { hdrVariant, branch };
        }));
    }

    internal static string SizeText(double bytes)
    {
        var mb = bytes / 1_048_576;
        return $"≈ {Math.Max(1, (int)Math.Round(mb, MidpointRounding.AwayFromZero))} MB";
    }

    internal static string FormatDuration(double seconds)
    {
        var total = (long)Math.Round(seconds, MidpointRounding.AwayFromZero);
        var h = total / 3600;
        var m = total % 3600 / 60;
        var s = total % 60;
        return h > 0 ? $"{h}:{m:00}:{s:00}" : $"{m}:{s:00}";
    }
}
