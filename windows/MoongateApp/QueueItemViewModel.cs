using System.Diagnostics;
using System.IO;
using Moongate.Core;

namespace Moongate.App;

/// <summary>
/// 队列中的一行。字段在 UI 线程上从 QueueManager.Item(id) 的最新快照复制
/// （不长期缓存 QueueItem 引用跨线程读）；SetProperty 等值短路抑制高频进度回调下的多余重绘。
/// </summary>
public sealed class QueueItemViewModel : ObservableObject
{
    private readonly QueueManager _queue;
    private IReadOnlyList<string> _resultFiles = [];

    public Guid Id { get; }
    public string Title { get; }

    public RelayCommand PauseCommand { get; }
    public RelayCommand ResumeCommand { get; }
    public RelayCommand CancelCommand { get; }
    public RelayCommand RetryCommand { get; }
    public RelayCommand RemoveCommand { get; }
    public RelayCommand RevealCommand { get; }

    public QueueItemViewModel(QueueManager queue, QueueManager.QueueItem item)
    {
        _queue = queue;
        Id = item.Id;
        Title = item.Title;
        PauseCommand = new RelayCommand(() => _queue.Pause(Id));
        ResumeCommand = new RelayCommand(() => _queue.Resume(Id));
        CancelCommand = new RelayCommand(() => _queue.Cancel(Id));
        RetryCommand = new RelayCommand(() => _queue.Retry(Id));
        RemoveCommand = new RelayCommand(() => _queue.Remove(Id));
        RevealCommand = new RelayCommand(OpenInExplorer);
        Refresh(item);
    }

    // MARK: - 展示状态

    private string _statusText = "";
    public string StatusText { get => _statusText; private set => SetProperty(ref _statusText, value); }

    private bool _isFailed;
    public bool IsFailed { get => _isFailed; private set => SetProperty(ref _isFailed, value); }

    private bool _isPaused;
    public bool IsPaused { get => _isPaused; private set => SetProperty(ref _isPaused, value); }

    private bool _showProgress;
    public bool ShowProgress { get => _showProgress; private set => SetProperty(ref _showProgress, value); }

    private double _progressValue;
    public double ProgressValue { get => _progressValue; private set => SetProperty(ref _progressValue, value); }

    private bool _progressIndeterminate;
    public bool ProgressIndeterminate { get => _progressIndeterminate; private set => SetProperty(ref _progressIndeterminate, value); }

    // MARK: - 按钮组（按阶段变化）

    private bool _showPause;
    public bool ShowPause { get => _showPause; private set => SetProperty(ref _showPause, value); }

    private bool _showResume;
    public bool ShowResume { get => _showResume; private set => SetProperty(ref _showResume, value); }

    private bool _showCancel;
    public bool ShowCancel { get => _showCancel; private set => SetProperty(ref _showCancel, value); }

    private bool _showRetry;
    public bool ShowRetry { get => _showRetry; private set => SetProperty(ref _showRetry, value); }

    private bool _showRetrySubtitle;
    public bool ShowRetrySubtitle { get => _showRetrySubtitle; private set => SetProperty(ref _showRetrySubtitle, value); }

    private bool _showReveal;
    public bool ShowReveal { get => _showReveal; private set => SetProperty(ref _showReveal, value); }

    private bool _showRemove;
    public bool ShowRemove { get => _showRemove; private set => SetProperty(ref _showRemove, value); }

    // MARK: - 刷新

    /// <summary>用最新队列项快照刷新本行（UI 线程调用；项已被移除时安全跳过）。</summary>
    public void Refresh(QueueManager.QueueItem? item)
    {
        if (item is null || item.Id != Id) return;
        var kind = item.Stage.Kind;
        var open = kind is ItemStageKind.Queued or ItemStageKind.Downloading
            or ItemStageKind.Translating or ItemStageKind.Burning;

        IsPaused = item.IsPaused;
        StatusText = ComputeStatusText(item, open);
        IsFailed = kind == ItemStageKind.Failed;
        ShowProgress = open;
        ProgressValue = CoerceProgressValue(item.OverallProgress);
        ProgressIndeterminate = open && item.OverallProgress is null;

        ShowPause = open && !item.IsPaused;
        ShowResume = open && item.IsPaused;
        ShowCancel = open;
        ShowRetry = kind is ItemStageKind.Failed or ItemStageKind.Cancelled;
        // 部分成功（视频已下载、字幕处理失败）：只重跑字幕处理，不重新下载
        ShowRetrySubtitle = kind == ItemStageKind.Done && item.PartialFailure;
        ShowReveal = kind is ItemStageKind.Done or ItemStageKind.Cancelled && item.ResultFiles.Count > 0;
        ShowRemove = !open;
        _resultFiles = item.ResultFiles;
    }

    internal static double CoerceProgressValue(double? progress)
    {
        if (progress is not { } value || double.IsNaN(value) || double.IsInfinity(value)) return 0;
        return Math.Clamp(value, 0, 1);
    }

    private static string ComputeStatusText(QueueManager.QueueItem item, bool open)
    {
        if (open && item.IsPaused) return Loc.S("L.Status.Paused");
        return item.Stage.Kind switch
        {
            // 等槽位/等待恢复等具体原因（QueueManager 写入），没有就显示通用文案
            ItemStageKind.Queued => item.StatusText ?? Loc.S("L.Status.Queued"),
            ItemStageKind.Downloading when item.PostDownloadProcessingKind == PostDownloadProcessingKind.Transcoding =>
                item.Progress is { } p
                    ? WithProgressDetails(Loc.F("L.Status.TranscodingFmt", (int)(p * 100)), item, includeSpeed: false)
                    : WithProgressDetails(Loc.S("L.Status.Transcoding"), item, includeSpeed: false),
            ItemStageKind.Downloading when item.PostDownloadProcessingKind == PostDownloadProcessingKind.Generic ||
                                           item.IsPostDownloadProcessing =>
                WithProgressDetails(Loc.S("L.Status.Processing"), item, includeSpeed: false),
            ItemStageKind.Downloading => item.Progress is { } p
                ? WithProgressDetails(Loc.F("L.Status.DownloadingFmt", (int)(p * 100)), item)
                : WithProgressDetails(Loc.S("L.Status.Downloading"), item),
            ItemStageKind.Translating => item.Progress is { } p
                ? WithProgressDetails(Loc.F("L.Status.TranslatingFmt", (int)(p * 100)), item, includeSpeed: false)
                : WithProgressDetails(Loc.S("L.Status.Translating"), item, includeSpeed: false),
            ItemStageKind.Burning => item.Progress is { } p
                ? WithProgressDetails(Loc.F("L.Status.BurningFmt", (int)(p * 100)), item, includeSpeed: false)
                : WithProgressDetails(Loc.S("L.Status.Burning"), item, includeSpeed: false),
            ItemStageKind.Done => item.StatusText ?? Loc.S("L.Status.Done"),
            ItemStageKind.Cancelled => item.StatusText ?? Loc.S("L.Status.Cancelled"),
            ItemStageKind.Failed => Loc.F("L.Status.FailedFmt", item.Stage.FailureReason ?? Loc.S("L.Status.Unknown")),
            _ => item.StatusText ?? "",
        };
    }

    private static string WithProgressDetails(string baseText, QueueManager.QueueItem item, bool includeSpeed = true)
    {
        var parts = new List<string> { baseText };
        if (includeSpeed && !string.IsNullOrWhiteSpace(item.SpeedText)) parts.Add(item.SpeedText);
        if (RemainingText(item) is { } remaining) parts.Add(remaining);
        return string.Join(Loc.S("L.Queue.SummarySep"), parts);
    }

    private static string? RemainingText(QueueManager.QueueItem item)
    {
        if (item.RemainingSeconds is { } seconds)
        {
            return item.RemainingIsApproximate
                ? Loc.F("L.Status.RemainingApprox", ApproximateDurationText(seconds))
                : Loc.F("L.Status.RemainingExact", ClockDurationText(seconds));
        }
        return item.IsEstimatingRemaining ? Loc.S("L.Status.RemainingEstimating") : null;
    }

    private static string ClockDurationText(double seconds)
    {
        var total = Math.Max(0, (int)Math.Ceiling(seconds));
        var hours = total / 3600;
        var minutes = total % 3600 / 60;
        var secs = total % 60;
        return hours > 0
            ? $"{hours}:{minutes:00}:{secs:00}"
            : $"{minutes:00}:{secs:00}";
    }

    private static string ApproximateDurationText(double seconds)
    {
        var total = Math.Max(0, (int)Math.Ceiling(seconds));
        if (total < 60) return Loc.S("L.Status.RemainingLessThanMinute");
        var minutes = (int)Math.Ceiling(total / 60.0);
        if (minutes < 60) return Loc.F("L.Status.RemainingMinutes", minutes);
        return Loc.F("L.Status.RemainingHoursMinutes", minutes / 60, minutes % 60);
    }

    /// <summary>在资源管理器中选中产物（烧录视频排第一）。</summary>
    private void OpenInExplorer()
    {
        try
        {
            var file = _resultFiles.FirstOrDefault(File.Exists) ?? _resultFiles.FirstOrDefault();
            if (file is null || !OperatingSystem.IsWindows()) return;
            Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{file}\"") { UseShellExecute = true });
        }
        catch
        {
            // 打不开资源管理器不影响任务状态
        }
    }
}
