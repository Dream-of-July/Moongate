using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Reflection;
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

    private readonly UpdateChecker _checker = new();
    private CancellationTokenSource? _cts;

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
        private set { if (SetProperty(ref _downloadFraction, value)) RaisePropertyChanged(nameof(DownloadPercentText)); }
    }
    public string DownloadPercentText => $"{(int)(_downloadFraction * 100)}%";

    private string _failureReason = "";
    public string FailureReason { get => _failureReason; private set => SetProperty(ref _failureReason, value); }

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

    /// <summary>检查更新。silent=true 时失败不改状态（启动静默检查用）。</summary>
    public async void Check(bool silent = false)
    {
        if (_state is Phase.Downloading or Phase.Installing) return;
        _cts?.Cancel();
        var cts = new CancellationTokenSource();
        _cts = cts;
        if (!silent) State = Phase.Checking;
        try
        {
            var info = await _checker.CheckForUpdateAsync(CurrentVersion, httpHandler: null, cts.Token)
                .ConfigureAwait(true);
            if (cts.IsCancellationRequested) return;
            if (info is not null)
            {
                _available = info;
                RaisePropertyChanged(nameof(AvailableVersionText));
                RaisePropertyChanged(nameof(AvailableNotes));
                RaisePropertyChanged(nameof(HasNotes));
                State = Phase.Available;
            }
            else if (!silent)
            {
                State = Phase.UpToDate;
            }
        }
        catch (Exception e)
        {
            if (cts.IsCancellationRequested) return;
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
        _cts?.Cancel();
        var cts = new CancellationTokenSource();
        _cts = cts;
        DownloadFraction = 0;
        State = Phase.Downloading;
        try
        {
            var installerPath = await DownloadAsync(info.SetupUrl, info.AssetName,
                f => DownloadFraction = f, cts.Token).ConfigureAwait(true);
            if (cts.IsCancellationRequested) return;
            State = Phase.Installing;
            // 运行安装器（NSIS，每用户安装会就地覆盖并可重启），随后退出本应用让其完成替换。
            Process.Start(new ProcessStartInfo(installerPath) { UseShellExecute = true });
            Application.Current.Shutdown();
        }
        catch (Exception e)
        {
            if (cts.IsCancellationRequested) return;
            FailureReason = e.Message;
            State = Phase.Failed;
        }
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
                if (total is { } t && t > 0) progress(Math.Clamp((double)received / t, 0, 1));
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
}
