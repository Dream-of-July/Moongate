using System.IO.Compression;
using System.Security.Cryptography;

namespace Moongate.Core;

/// <summary>一项待下载的依赖。Kind=Zip 时按 ZipEntries 提取（entry 后缀 → 目标文件名）。</summary>
public sealed record DependencyDownload
{
    public enum DownloadKind { Executable, Zip }

    /// <summary>展示名（如 "yt-dlp"）。</summary>
    public required string Name { get; init; }
    public required string Url { get; init; }
    public required DownloadKind Kind { get; init; }
    /// <summary>提供的目标文件名（bin 目录下）。</summary>
    public required IReadOnlyList<string> ProvidesFiles { get; init; }
    /// <summary>Zip 内 entry 路径后缀 → 目标文件名；Executable 时为空。</summary>
    public IReadOnlyDictionary<string, string> ZipEntries { get; init; } =
        new Dictionary<string, string>();
    /// <summary>
    /// 期望的 SHA-256（小写十六进制）。非空时下载后必须匹配才安装（DEP-SUPPLY-001）。
    /// 当前为 null（未固定）：需在依赖 manifest 里填入对应固定版本的真实哈希后才生效——
    /// Content-Length 只能发现截断，SHA-256 才能发现被替换的完整恶意文件。
    /// </summary>
    public string? Sha256 { get; init; }
}

/// <summary>
/// 依赖管理：检查 %LOCALAPPDATA%\Moongate\bin 下的 yt-dlp.exe / ffmpeg.exe /
/// ffprobe.exe / deno.exe，缺哪个下哪个。下载到 .tmp 再原子改名，避免半截文件被当成可用。
/// deno 是 yt-dlp 解 YouTube n-challenge 所需的 JS 运行时。
/// </summary>
public sealed class DependencyManager
{
    private const string YtDlpUrl =
        "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe";
    private const string FfmpegZipUrl =
        "https://github.com/BtbN/FFmpeg-Builds/releases/latest/download/ffmpeg-master-latest-win64-gpl.zip";
    private const string DenoZipUrl =
        "https://github.com/denoland/deno/releases/latest/download/deno-x86_64-pc-windows-msvc.zip";

    private readonly string _binDirectory;
    private readonly HttpClient _client;

    public DependencyManager(string? binDirectory = null, HttpMessageHandler? handler = null)
    {
        _binDirectory = binDirectory ?? BinaryLocator.BinDirectory;
        _client = handler is null
            ? new HttpClient() { Timeout = TimeSpan.FromMinutes(10) }
            : new HttpClient(handler, disposeHandler: false) { Timeout = TimeSpan.FromMinutes(10) };
    }

    /// <summary>受管的全部依赖（Windows 文件名）。</summary>
    internal static readonly string[] RequiredFiles = ["yt-dlp.exe", "ffmpeg.exe", "ffprobe.exe", "deno.exe"];

    /// <summary>检查 bin 目录，返回缺失依赖的下载计划（缺什么下什么）。</summary>
    public IReadOnlyList<DependencyDownload> PlanMissing() => PlanMissing(_binDirectory);

    internal static List<DependencyDownload> PlanMissing(string binDirectory)
    {
        bool Missing(string file) => !File.Exists(Path.Combine(binDirectory, file));
        return AllPlans().Where(plan => plan.ProvidesFiles.Any(Missing)).ToList();
    }

    /// <summary>不论是否已存在，规划全部受管依赖的下载（「重新下载依赖」用）。</summary>
    public IReadOnlyList<DependencyDownload> PlanAll() => AllPlans();

    /// <summary>受管依赖的完整下载计划（顺序：yt-dlp → ffmpeg → deno）。</summary>
    internal static List<DependencyDownload> AllPlans() =>
    [
        new DependencyDownload
        {
            Name = "yt-dlp",
            Url = YtDlpUrl,
            Kind = DependencyDownload.DownloadKind.Executable,
            ProvidesFiles = ["yt-dlp.exe"],
        },
        new DependencyDownload
        {
            Name = "ffmpeg",
            Url = FfmpegZipUrl,
            Kind = DependencyDownload.DownloadKind.Zip,
            ProvidesFiles = ["ffmpeg.exe", "ffprobe.exe"],
            ZipEntries = new Dictionary<string, string>
            {
                ["bin/ffmpeg.exe"] = "ffmpeg.exe",
                ["bin/ffprobe.exe"] = "ffprobe.exe",
            },
        },
        new DependencyDownload
        {
            Name = "deno",
            Url = DenoZipUrl,
            Kind = DependencyDownload.DownloadKind.Zip,
            ProvidesFiles = ["deno.exe"],
            ZipEntries = new Dictionary<string, string> { ["deno.exe"] = "deno.exe" },
        },
    ];

    /// <summary>确保所有依赖就位：缺失的逐个下载安装。progress 上报人话进度文案。</summary>
    public async Task EnsureAsync(IProgress<string>? progress = null, CancellationToken ct = default)
    {
        var plans = PlanMissing(_binDirectory);
        if (plans.Count == 0) return;
        Directory.CreateDirectory(_binDirectory);
        foreach (var plan in plans)
        {
            ct.ThrowIfCancellationRequested();
            await DownloadAndInstallAsync(plan, progress, ct).ConfigureAwait(false);
        }
        progress?.Report(L10n.T("依赖组件已就绪", "依賴元件已就緒", "All components are ready"));
    }

    /// <summary>
    /// 重新下载全部依赖：每项都先下到 .tmp、校验/提取成功后才原子替换。
    /// 关键是「先下后换」——网络失败时旧的可用文件原样保留，不会像旧实现那样先删后下、一断网就破坏环境。
    /// </summary>
    public async Task RedownloadAllAsync(IProgress<string>? progress = null, CancellationToken ct = default)
    {
        Directory.CreateDirectory(_binDirectory);
        foreach (var plan in AllPlans())
        {
            ct.ThrowIfCancellationRequested();
            await DownloadAndInstallAsync(plan, progress, ct).ConfigureAwait(false);
        }
        progress?.Report(L10n.T("依赖组件已更新", "依賴元件已更新", "All components are up to date"));
    }

    /// <summary>单独更新 yt-dlp（站点规则频繁变化，提供手动更新入口）。</summary>
    public async Task UpdateYtDlpAsync(IProgress<string>? progress = null, CancellationToken ct = default)
    {
        Directory.CreateDirectory(_binDirectory);
        await DownloadAndInstallAsync(new DependencyDownload
        {
            Name = "yt-dlp",
            Url = YtDlpUrl,
            Kind = DependencyDownload.DownloadKind.Executable,
            ProvidesFiles = ["yt-dlp.exe"],
        }, progress, ct).ConfigureAwait(false);
        progress?.Report(L10n.T("yt-dlp 已更新", "yt-dlp 已更新", "yt-dlp updated"));
    }

    private async Task DownloadAndInstallAsync(
        DependencyDownload plan, IProgress<string>? progress, CancellationToken ct)
    {
        // 先全部下到 .tmp，校验/提取成功后原子改名，失败不留半截产物。
        var tempPath = Path.Combine(_binDirectory, $"{plan.Name}-{Guid.NewGuid():N}.tmp");
        try
        {
            using (var response = await _client.GetAsync(
                plan.Url, HttpCompletionOption.ResponseHeadersRead, ct).ConfigureAwait(false))
            {
                response.EnsureSuccessStatusCode();
                var expected = response.Content.Headers.ContentLength;
                await using (var src = await response.Content.ReadAsStreamAsync(ct).ConfigureAwait(false))
                await using (var fileStream = File.Create(tempPath))
                {
                    await CopyWithProgressAsync(src, fileStream, plan.Name, expected, progress, ct)
                        .ConfigureAwait(false);
                }
                // 完整性校验：先查长度（截断），再查 SHA-256（被替换的完整文件）。
                VerifyDownloadIntegrity(plan.Name, tempPath, expected, plan.Sha256);
            }

            if (plan.Kind == DependencyDownload.DownloadKind.Executable)
            {
                var target = Path.Combine(_binDirectory, plan.ProvidesFiles[0]);
                File.Move(tempPath, target, overwrite: true);
            }
            else
            {
                await using (var zipStream = File.OpenRead(tempPath))
                {
                    ExtractZipEntries(zipStream, plan.ZipEntries, _binDirectory);
                }
                File.Delete(tempPath);
            }
        }
        catch
        {
            try { File.Delete(tempPath); } catch { /* 忽略 */ }
            throw;
        }
    }

    /// <summary>
    /// 流式拷贝并按节流上报真实进度：组件名 + 已下载/总大小 + 速度。
    /// 总大小未知（无 Content-Length）时只报已下载大小与速度。节流到约每 200ms 一次，避免刷屏。
    /// </summary>
    private static async Task CopyWithProgressAsync(
        Stream src, Stream dst, string name, long? total,
        IProgress<string>? progress, CancellationToken ct)
    {
        var buffer = new byte[81920];
        long received = 0;
        var lastReportTicks = 0L;
        var startTicks = Environment.TickCount64;
        int read;
        while ((read = await src.ReadAsync(buffer, ct).ConfigureAwait(false)) > 0)
        {
            await dst.WriteAsync(buffer.AsMemory(0, read), ct).ConfigureAwait(false);
            received += read;
            var now = Environment.TickCount64;
            if (progress is null || now - lastReportTicks < 200) continue;
            lastReportTicks = now;
            var elapsed = Math.Max(1, now - startTicks) / 1000.0;
            var speed = FormatBytes((long)(received / elapsed)) + "/s";
            var sizeText = total is { } t
                ? $"{FormatBytes(received)} / {FormatBytes(t)} · {speed}"
                : $"{FormatBytes(received)} · {speed}";
            progress.Report(L10n.T(
                $"正在下载 {name}… {sizeText}", $"正在下載 {name}… {sizeText}", $"Downloading {name}… {sizeText}"));
        }
    }

    /// <summary>把字节数格式化成人类可读大小（KB/MB/GB），保留一位小数。</summary>
    internal static string FormatBytes(long bytes)
    {
        if (bytes < 1024) return $"{bytes} B";
        double value = bytes;
        string[] units = ["KB", "MB", "GB"];
        var unit = -1;
        do { value /= 1024; unit++; } while (value >= 1024 && unit < units.Length - 1);
        return $"{value:0.0} {units[unit]}";
    }

    /// <summary>
    /// 下载完整性校验（DEP-SUPPLY-001）：
    /// 1) Content-Length 已知时必须匹配——只能发现截断（弱网/CDN 抖动让读取提前正常返回）。
    /// 2) 期望 SHA-256 非空时必须匹配——能发现被替换的完整恶意文件，是 Content-Length 给不了的保证。
    /// 任一不符抛 IOException，调用方删临时文件、保留旧版本。
    /// </summary>
    internal static void VerifyDownloadIntegrity(string name, string path, long? expectedLength, string? expectedSha256)
    {
        if (expectedLength is { } total)
        {
            var actual = new FileInfo(path).Length;
            if (actual != total)
            {
                throw new IOException(L10n.T(
                    $"{name} 下载不完整（{actual}/{total} 字节），可能是网络中断或代理抖动，请重试。",
                    $"{name} 下載不完整（{actual}/{total} 位元組），可能是網路中斷或代理抖動，請重試。",
                    $"{name} download was incomplete ({actual}/{total} bytes); the network or proxy may have dropped. Please retry."));
            }
        }
        if (!string.IsNullOrEmpty(expectedSha256))
        {
            var actual = FileSha256Hex(path);
            if (!string.Equals(actual, expectedSha256, StringComparison.OrdinalIgnoreCase))
            {
                throw new IOException(L10n.T(
                    $"{name} 校验失败：SHA-256 与预期不符，已拒绝安装（可能被篡改或下载源被劫持）。",
                    $"{name} 校驗失敗：SHA-256 與預期不符，已拒絕安裝（可能被竄改或下載來源被劫持）。",
                    $"{name} verification failed: SHA-256 did not match the pinned value; installation refused (possible tampering)."));
            }
        }
    }

    /// <summary>计算文件 SHA-256（小写十六进制）。</summary>
    internal static string FileSha256Hex(string path)
    {
        using var stream = File.OpenRead(path);
        return Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant();
    }

    /// <summary>
    /// 从 zip 流中按 entry 路径后缀提取目标文件到 binDirectory（提取到 .tmp 后原子改名）。
    /// BtbN 的 ffmpeg zip 顶层有版本号目录，所以按后缀匹配 "bin/ffmpeg.exe" 而非全路径。
    /// </summary>
    internal static void ExtractZipEntries(
        Stream zipStream, IReadOnlyDictionary<string, string> entrySuffixToTarget, string binDirectory)
    {
        using var archive = new ZipArchive(zipStream, ZipArchiveMode.Read, leaveOpen: true);
        var remaining = new Dictionary<string, string>(entrySuffixToTarget);
        foreach (var entry in archive.Entries)
        {
            if (entry.FullName.EndsWith('/')) continue;
            var normalized = entry.FullName.Replace('\\', '/');
            var hit = remaining.FirstOrDefault(pair =>
                normalized.EndsWith(pair.Key, StringComparison.OrdinalIgnoreCase));
            if (hit.Key is null) continue;
            remaining.Remove(hit.Key);

            var target = Path.Combine(binDirectory, hit.Value);
            var temp = target + $".extract-{Guid.NewGuid():N}.tmp";
            try
            {
                using (var entryStream = entry.Open())
                using (var output = File.Create(temp))
                {
                    entryStream.CopyTo(output);
                }
                File.Move(temp, target, overwrite: true);
            }
            catch
            {
                try { File.Delete(temp); } catch { /* 忽略 */ }
                throw;
            }
            if (remaining.Count == 0) break;
        }
        if (remaining.Count > 0)
        {
            throw new InvalidDataException(L10n.T(
                $"压缩包里缺少预期文件：{string.Join(", ", remaining.Keys)}",
                $"壓縮包裡缺少預期檔案：{string.Join(", ", remaining.Keys)}",
                $"The archive is missing expected files: {string.Join(", ", remaining.Keys)}"));
        }
    }
}
