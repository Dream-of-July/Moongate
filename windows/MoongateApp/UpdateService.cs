using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Reflection;
using System.Security.Cryptography;
using System.Text.RegularExpressions;
using System.Windows;
using Moongate.Core;

namespace Moongate.App;

/// <summary>
/// 远程更新服务（Windows）：检查 → 下载 .exe 安装器 → 运行安装器 → 退出本应用。
/// NSIS 安装器是每用户安装，会就地覆盖并重启，无需我们替换正在运行的文件。
/// 与 macOS UpdateService 对应（macOS 走 DMG+脚本替换，Windows 走安装器自替换）。
/// </summary>
public sealed class UpdateService : ObservableObject
{
    public enum Phase { Idle, Checking, UpToDate, Available, Downloading, Installing, Failed }

    private static readonly TimeSpan AutomaticCheckInterval = TimeSpan.FromHours(6);

    private readonly UpdateChecker _checker = new();
    private CancellationTokenSource? _cts;
    private DateTimeOffset? _lastCheckedAt;

    private Phase _state = Phase.Idle;
    public Phase State
    {
        get => _state;
        private set
        {
            if (!SetProperty(ref _state, value)) return;
            RaisePropertyChanged(nameof(IsIdleOrUpToDate));
            RaisePropertyChanged(nameof(IsChecking));
            RaisePropertyChanged(nameof(IsUpToDate));
            RaisePropertyChanged(nameof(IsAvailable));
            RaisePropertyChanged(nameof(IsDownloading));
            RaisePropertyChanged(nameof(IsInstalling));
            RaisePropertyChanged(nameof(IsFailed));
        }
    }

    public bool IsIdleOrUpToDate => _state is Phase.Idle or Phase.UpToDate;
    public bool IsChecking => _state == Phase.Checking;
    public bool IsUpToDate => _state == Phase.UpToDate;
    public bool IsAvailable => _state == Phase.Available;
    public bool IsDownloading => _state == Phase.Downloading;
    public bool IsInstalling => _state == Phase.Installing;
    public bool IsFailed => _state == Phase.Failed;

    private UpdateInfo? _available;
    public string AvailableVersionText => _available is { } i ? $"v{i.Version}" : "";
    public string AvailableNotes => _available?.Notes ?? "";
    public bool HasNotes => !string.IsNullOrWhiteSpace(_available?.Notes);

    private double _downloadFraction;
    public double DownloadFraction
    {
        get => _downloadFraction;
        private set
        {
            var coerced = CoerceDownloadFraction(value);
            if (SetProperty(ref _downloadFraction, coerced)) RaisePropertyChanged(nameof(DownloadPercentText));
        }
    }
    public string DownloadPercentText => $"{(int)(CoerceDownloadFraction(_downloadFraction) * 100)}%";

    internal static double CoerceDownloadFraction(double value)
    {
        if (double.IsNaN(value) || double.IsInfinity(value)) return 0;
        return Math.Clamp(value, 0, 1);
    }

    private string _failureReason = "";
    public string FailureReason { get => _failureReason; private set => SetProperty(ref _failureReason, value); }

    public DateTimeOffset? LastCheckedAt
    {
        get => _lastCheckedAt;
        private set
        {
            if (_lastCheckedAt == value) return;
            _lastCheckedAt = value;
            RaisePropertyChanged(nameof(LastCheckedAt));
            RaisePropertyChanged(nameof(LastCheckedText));
        }
    }

    public string LastCheckedText => LastCheckedAt is { } at
        ? Loc.F("L.Update.LastCheckedFmt", at.ToLocalTime().ToString("yyyy-MM-dd HH:mm"))
        : "";

    /// <summary>当前应用版本（来自程序集版本，由 publish 时 -p:Version 注入）。</summary>
    public string CurrentVersion
    {
        get
        {
            var v = Assembly.GetExecutingAssembly().GetName().Version;
            return v is null ? "0.0.0" : $"{v.Major}.{v.Minor}.{v.Build}";
        }
    }

    public string ReleasesPageUrl => _checker.ReleasesPageUrl;
    public string RepoPageUrl => _checker.RepoPageUrl;

    /// <summary>
    /// 安装前最后一道闸：返回 false 则中止安装（不退出、不启动安装器）。
    /// 由 SettingsWindow 注入，用于检查队列是否有未完成任务并向用户确认。
    /// </summary>
    public Func<bool>? ConfirmInstallReady { get; set; }

    /// <summary>设置页自动静默检查：复用 App 级服务状态，6 小时内不重复请求 GitHub。</summary>
    public void CheckAutomaticSilent()
    {
        if (!UpdateChecker.ShouldRunAutomaticCheck(LastCheckedAt, DateTimeOffset.Now, AutomaticCheckInterval)) return;
        Check(silent: true);
    }

    /// <summary>检查更新。silent=true 时失败不改状态（启动静默检查用）。</summary>
    public async void Check(bool silent = false)
    {
        if (_state is Phase.Checking or Phase.Downloading or Phase.Installing) return;
        _cts?.Cancel();
        var cts = new CancellationTokenSource();
        _cts = cts;
        if (!silent) State = Phase.Checking;
        // 稳定/测试通道：跟随设置，默认接收预发布（当前发布全是 prerelease）。
        var includePrerelease = AppSettings.Load().ReceiveBetaUpdates;
        try
        {
            var info = await _checker.CheckForUpdateAsync(CurrentVersion, httpHandler: null, cts.Token,
                    includePrerelease)
                .ConfigureAwait(true);
            if (cts.IsCancellationRequested) return;
            if (info is not null)
            {
                _available = info;
                LastCheckedAt = DateTimeOffset.Now;
                RaisePropertyChanged(nameof(AvailableVersionText));
                RaisePropertyChanged(nameof(AvailableNotes));
                RaisePropertyChanged(nameof(HasNotes));
                State = Phase.Available;
            }
            else if (!silent)
            {
                LastCheckedAt = DateTimeOffset.Now;
                State = Phase.UpToDate;
            }
            else
            {
                LastCheckedAt = DateTimeOffset.Now;
            }
        }
        catch (Exception e)
        {
            if (cts.IsCancellationRequested) return;
            LastCheckedAt = DateTimeOffset.Now;
            if (!silent)
            {
                FailureReason = e is MoongateException ? e.Message : e.Message;
                State = Phase.Failed;
            }
        }
    }

    /// <summary>下载并运行当前可用更新的安装器。</summary>
    public async void DownloadAndInstall()
    {
        if (_available is not { } info) return;
        if (!UpdateChecker.IsTrustedSetupUrl(info.SetupUrl, _checker.Owner, _checker.Repo))
        {
            FailureReason = Loc.S("L.Update.Untrusted");
            State = Phase.Failed;
            return;
        }
        if (!UpdateChecker.IsTrustedSetupChecksumUrl(info.Sha256Url, info.AssetName, _checker.Owner, _checker.Repo))
        {
            FailureReason = Loc.S("L.Update.Untrusted");
            State = Phase.Failed;
            return;
        }
        _cts?.Cancel();
        var cts = new CancellationTokenSource();
        _cts = cts;
        DownloadFraction = 0;
        State = Phase.Downloading;
        string? downloadDir = null;
        try
        {
            var installerPath = await DownloadAsync(info.SetupUrl, info.AssetName,
                f => DownloadFraction = f, cts.Token).ConfigureAwait(true);
            downloadDir = Path.GetDirectoryName(installerPath);
            if (cts.IsCancellationRequested) { CleanupDir(downloadDir); return; }
            if (!InstallerNameMatchesVersion(installerPath, info.Version))
                throw MoongateException.DownloadFailed(Loc.S("L.Update.DownloadFailed"));
            var expectedSha256 = await DownloadSha256Async(info.Sha256Url, cts.Token).ConfigureAwait(true);
            if (!FileSha256Matches(installerPath, expectedSha256))
                throw MoongateException.DownloadFailed(Loc.S("L.Update.DownloadFailed"));
            // 安装前闸：有未完成任务时由调用方向用户确认（继续任务 / 取消全部任务并更新）。
            // 返回 false：保留已下载的安装器目录由下次启动清理，回到「可安装」态，不退出。
            if (ConfirmInstallReady is { } gate && !gate())
            {
                State = Phase.Available;
                return;
            }
            State = Phase.Installing;
            // 运行安装器（NSIS，每用户安装就地覆盖）。`/S` 静默安装：用户无需再点一遍安装向导，
            // 满足「下载后自动覆盖并重启」。传入当前 PID，安装器先等本进程完全退出再覆盖目录，
            // 避免「安装器已启动但旧 App 仍占用文件」的竞态；安装成功后安装器在静默+更新场景下自动重启 App。
            // 标记为更新退出：主窗口关窗确认不再拦截这次退出（专用状态，避免互相打架）。
            App.MarkUpdateShutdown();
            Process.Start(new ProcessStartInfo(installerPath)
            {
                UseShellExecute = true,
                Arguments = $"/S /UPDATEPID={Environment.ProcessId}",
            });
            Application.Current.Shutdown();
        }
        catch (Exception e)
        {
            CleanupDir(downloadDir);
            if (cts.IsCancellationRequested) return;
            FailureReason = e.Message;
            State = Phase.Failed;
        }
    }

    /// <summary>删除一次更新下载的临时目录（尽力而为）。</summary>
    private static void CleanupDir(string? dir)
    {
        if (string.IsNullOrEmpty(dir)) return;
        try { if (Directory.Exists(dir)) Directory.Delete(dir, recursive: true); }
        catch { /* 占用/权限问题忽略，留给启动期清理 */ }
    }

    /// <summary>
    /// 启动时清理遗留的更新临时目录（moongate-update-*）。成功安装后安装器无法删除自身所在目录，
    /// 由下次启动统一清掉；取消/失败路径已即时清理，这里兜底历史残留。
    /// </summary>
    public static void CleanStaleUpdateDirs()
    {
        try
        {
            var temp = Path.GetTempPath();
            foreach (var dir in Directory.EnumerateDirectories(temp, "moongate-update-*"))
            {
                try { Directory.Delete(dir, recursive: true); } catch { /* 仍被占用则下次再清 */ }
            }
        }
        catch { /* 临时目录不可枚举时忽略 */ }
    }

    public void Cancel()
    {
        _cts?.Cancel();
        _cts = null;
        State = Phase.Idle;
    }

    private static async Task<string> DownloadAsync(
        string url, string assetName, Action<double> progress, CancellationToken ct)
    {
        var dir = Path.Combine(Path.GetTempPath(), $"moongate-update-{Guid.NewGuid():N}");
        Directory.CreateDirectory(dir);
        // 安装器文件名保留 .exe 扩展名（用资产名，回退固定名）。
        var safeName = string.IsNullOrWhiteSpace(assetName) || !assetName.ToLowerInvariant().EndsWith(".exe")
            ? "MoongateSetup.exe"
            : Path.GetFileName(assetName);
        var target = Path.Combine(dir, safeName);

        using var client = new HttpClient { Timeout = TimeSpan.FromMinutes(10) };
        using var response = await client.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, ct)
            .ConfigureAwait(false);
        if (!response.IsSuccessStatusCode)
            throw MoongateException.DownloadFailed(Loc.S("L.Update.DownloadFailed"));

        var total = response.Content.Headers.ContentLength;
        await using (var src = await response.Content.ReadAsStreamAsync(ct).ConfigureAwait(false))
        await using (var dst = File.Create(target))
        {
            var buffer = new byte[81920];
            long received = 0;
            int read;
            while ((read = await src.ReadAsync(buffer, ct).ConfigureAwait(false)) > 0)
            {
                await dst.WriteAsync(buffer.AsMemory(0, read), ct).ConfigureAwait(false);
                received += read;
                if (total is { } t && t > 0) progress(CoerceDownloadFraction((double)received / t));
            }
            // 完整性校验：连接中途断开会让循环正常结束却只写了一半，
            // 若不校验就会把截断的安装器当成功直接运行。Content-Length 已知时必须匹配。
            if (total is { } expected && received != expected)
            {
                throw MoongateException.DownloadFailed(Loc.S("L.Update.DownloadFailed"));
            }
        }
        progress(1);
        return target;
    }

    private static bool InstallerNameMatchesVersion(string installerPath, SemVer expectedVersion)
    {
        return UpdateChecker.AssetNameMatchesVersion(Path.GetFileName(installerPath), expectedVersion);
    }

    private static async Task<string> DownloadSha256Async(string url, CancellationToken ct)
    {
        using var client = new HttpClient { Timeout = TimeSpan.FromMinutes(2) };
        var text = await client.GetStringAsync(url, ct).ConfigureAwait(false);
        var match = Regex.Match(text, @"\b[a-fA-F0-9]{64}\b");
        if (!match.Success) throw MoongateException.DownloadFailed(Loc.S("L.Update.DownloadFailed"));
        return match.Value.ToLowerInvariant();
    }

    private static bool FileSha256Matches(string path, string expectedSha256)
    {
        using var stream = File.OpenRead(path);
        var hash = SHA256.HashData(stream);
        var actual = Convert.ToHexString(hash).ToLowerInvariant();
        return string.Equals(actual, expectedSha256, StringComparison.OrdinalIgnoreCase);
    }
}
