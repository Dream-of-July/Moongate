namespace Moongate.Core;

/// <summary>字幕处理方式（ready 页「字幕处理」分组的选项）。</summary>
public enum ChineseSubtitleMode
{
    Off,
    SrtOnly,
    BurnIn,
    /// <summary>不翻译，把所选源字幕原样烧录进视频（无论语言、无需配置翻译服务）。</summary>
    BurnOriginal,
}

/// <summary>
/// 阶段槽位池：限制同一阶段（下载 / 压制 / 翻译）的并发任务数。
/// 线程安全（锁 + 票据续延）；排队者被唤醒后重新竞争（队列规模小，开销可忽略）。
/// </summary>
public sealed class StageSlotPool
{
    private readonly object _lock = new();
    private readonly Func<int> _capacity;
    private int _inUse;
    private readonly List<(Guid Id, TaskCompletionSource Tcs)> _parked = [];

    public StageSlotPool(Func<int> capacity)
    {
        _capacity = capacity;
    }

    public bool HasFreeSlot
    {
        get { lock (_lock) return _inUse < Math.Max(1, _capacity()); }
    }

    /// <summary>
    /// 等待并占用一个槽位。control 取消时抛 Cancelled。
    /// respectPause=true 时，暂停中的任务不抢槽（等恢复后再竞争）；
    /// 恢复重排队的路径传 false（item 已恢复但 token 仍处暂停态，等槽到手才真正恢复进程）。
    /// </summary>
    public async Task AcquireAsync(
        Guid id, TaskControlToken control, bool respectPause = true, CancellationToken ct = default)
    {
        while (true)
        {
            if (ct.IsCancellationRequested || control.IsCancelled) throw MoongateException.Cancelled();
            if (respectPause && control.IsPaused)
            {
                await control.GateAsync(ct).ConfigureAwait(false);
                continue;
            }
            TaskCompletionSource tcs;
            lock (_lock)
            {
                if (_inUse < Math.Max(1, _capacity()))
                {
                    _inUse++;
                    return;
                }
                tcs = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
                _parked.Add((id, tcs));
            }
            await tcs.Task.ConfigureAwait(false);
        }
    }

    /// <summary>释放一个槽位并唤醒全部排队者重新竞争。</summary>
    public void Release()
    {
        List<(Guid, TaskCompletionSource)> waiting;
        lock (_lock)
        {
            _inUse = Math.Max(0, _inUse - 1);
            waiting = [.. _parked];
            _parked.Clear();
        }
        foreach (var (_, tcs) in waiting) tcs.TrySetResult();
    }

    /// <summary>容量调大（设置变更）后让排队者重新竞争。</summary>
    public void WakeAll()
    {
        List<(Guid, TaskCompletionSource)> waiting;
        lock (_lock)
        {
            waiting = [.. _parked];
            _parked.Clear();
        }
        foreach (var (_, tcs) in waiting) tcs.TrySetResult();
    }

    /// <summary>取消某项时把它从排队里唤出（AcquireAsync 循环会自行检查取消并抛出）。</summary>
    public void Wake(Guid id)
    {
        TaskCompletionSource? tcs = null;
        lock (_lock)
        {
            var index = _parked.FindIndex(p => p.Id == id);
            if (index >= 0)
            {
                tcs = _parked[index].Tcs;
                _parked.RemoveAt(index);
            }
        }
        tcs?.TrySetResult();
    }
}

/// <summary>队列项当前所处阶段。暂停态不单列，由 QueueItem.IsPaused 叠加表示。</summary>
public enum ItemStageKind
{
    Queued,
    Downloading,
    Translating,
    Burning,
    Done,
    Failed,
    Cancelled,
}

public sealed record ItemStage(ItemStageKind Kind, string? FailureReason = null)
{
    public static readonly ItemStage Queued = new(ItemStageKind.Queued);
    public static readonly ItemStage Downloading = new(ItemStageKind.Downloading);
    public static readonly ItemStage Translating = new(ItemStageKind.Translating);
    public static readonly ItemStage Burning = new(ItemStageKind.Burning);
    public static readonly ItemStage Done = new(ItemStageKind.Done);
    public static readonly ItemStage Cancelled = new(ItemStageKind.Cancelled);
    public static ItemStage Failed(string reason) => new(ItemStageKind.Failed, reason);
}

public enum PostDownloadProcessingKind
{
    None,
    Generic,
    Transcoding,
}

public sealed record QueueCompletionNotification
{
    public required int CompletedCount { get; init; }
    public required int PartialFailureCount { get; init; }
    public required int FailedCount { get; init; }
    public required int CancelledCount { get; init; }
    public required IReadOnlyList<string> Titles { get; init; }
}

public interface IQueueCompletionNotifier
{
    void QueueDidComplete(QueueCompletionNotification notification);
}

/// <summary>
/// 下载队列。每个 QueueItem 是一条「下载 →[翻译]→[烧录]」完整流水线，
/// 持有独立的 TaskControlToken，可随时独立暂停 / 恢复 / 取消，并发执行互不阻塞；
/// 三个阶段各有并发上限（下载/压制可在设置里调，翻译固定 2 防网关限流），
/// 暂停会让出占用的下载/压制槽位给其它任务，恢复时重新排队领取。
/// 本类无 UI 依赖、线程安全；对外通过 ItemsChanged/ItemUpdated 事件通知，UI 层自行封送到主线程。
/// 状态读取请经 Items / Item(id)（带锁建立内存屏障），不要长期缓存 QueueItem 引用跨线程读。
/// </summary>
public sealed class QueueManager
{
    public sealed class QueueItem
    {
        public required Guid Id { get; init; }
        public required string Title { get; init; }
        public string? ThumbnailUrl { get; init; }
        public required VideoInfo Info { get; init; }
        public DownloadRequest Request { get; internal set; } = null!;
        public required ChineseSubtitleMode ChineseMode { get; init; }
        /// <summary>本项使用的设置快照（字幕样式、烧录画质、翻译凭证）。</summary>
        public required AppSettings Settings { get; init; }
        public ItemStage Stage { get; internal set; } = ItemStage.Queued;
        /// <summary>0...1；null 表示不确定（处理 / 翻译启动等）。</summary>
        public double? Progress { get; internal set; }
        /// <summary>整条任务的 0...1 进度；跨下载 / 转码 / 翻译 / 烧录保持单调。</summary>
        public double? OverallProgress { get; internal set; }
        public string? SpeedText { get; internal set; }
        public double? RemainingSeconds { get; internal set; }
        public bool RemainingIsApproximate { get; internal set; }
        public bool IsEstimatingRemaining { get; internal set; }
        public QueueProgressPhase? ProgressPhase { get; internal set; }
        public QueueProgressPlan ProgressPlan { get; internal set; } = null!;
        public TaskWorkPlan WorkPlan { get; internal set; } = null!;
        /// <summary>暂停 / 部分成功 / 失败原因等附加说明。</summary>
        public string? StatusText { get; internal set; }
        /// <summary>已落盘的产物（下载文件、译文、烧录视频）。</summary>
        public IReadOnlyList<string> ResultFiles { get; internal set; } = [];
        public bool IsPaused { get; internal set; }
        /// <summary>
        /// 下载已 100%、正在合并/转码/字幕转换（Progress 为 null 但仍处于 Downloading）。
        /// UI 据此显示「处理中…」而非「下载中…」（避免像卡死）。
        /// </summary>
        public bool IsPostDownloadProcessing { get; internal set; }
        public PostDownloadProcessingKind PostDownloadProcessingKind { get; internal set; } =
            PostDownloadProcessingKind.None;
        /// <summary>部分成功：视频已下载但字幕处理失败（Done 态显示「重试字幕处理」按钮）。</summary>
        public bool PartialFailure { get; internal set; }
        /// <summary>本项流水线的控制令牌；Retry 时换新的（旧的已 Cancel）。</summary>
        public TaskControlToken Control { get; internal set; } = new();
        /// <summary>流水线代际：每次 enqueue/retry 递增；写回前校验，作废陈旧回调。</summary>
        public int Generation { get; internal set; }
        internal CancellationTokenSource Cts { get; set; } = new();
        internal Task? RunTask { get; set; }

        public bool CanRetryWithLocalAsr =>
            ChineseMode != ChineseSubtitleMode.Off
            && LocalAsrRetryRequest(Request) is not null
            && ResultFiles.Any(file => VideoExtensions.Contains(ExtensionOf(file)));

        internal void ClearProgress(bool resetOverall = false)
        {
            Progress = null;
            SpeedText = null;
            RemainingSeconds = null;
            RemainingIsApproximate = false;
            IsEstimatingRemaining = false;
            ProgressPhase = null;
            if (resetOverall) OverallProgress = null;
        }

        internal void CompleteProgress()
        {
            ClearProgress();
            OverallProgress = 1;
        }
    }

    private readonly object _lock = new();
    private readonly List<QueueItem> _items = [];
    private readonly IDownloadEngine _engine;
    private readonly Func<AppSettings, ISubtitleTranslator> _translatorFactory;
    private readonly Func<ISubtitleBurner> _burnerFactory;
    private ILocalAsrSubtitleGenerator? _localAsrGenerator;
    private readonly IQueueCompletionNotifier? _completionNotifier;
    private readonly HashSet<Guid> _notifiedTerminalIds = [];

    /// <summary>列表增删时触发（任意线程）。</summary>
    public event Action? ItemsChanged;
    /// <summary>单项字段变化时触发（任意线程）。</summary>
    public event Action<Guid>? ItemUpdated;

    private int _maxConcurrentDownloads;
    private int _maxConcurrentBurns;
    /// <summary>
    /// 实际压制并发上限：硬件编码后端时编码不占 CPU（走专用编码器），可比原始值多放一路提高吞吐；
    /// 软件后端等于原始值。由 SyncConcurrency 从 settings.EffectiveMaxConcurrentBurns 同步。
    /// </summary>
    private int _effectiveBurnCapacity;

    /// <summary>同时下载数（设置变更时由 UI 层同步；调大即时生效）。</summary>
    public int MaxConcurrentDownloads
    {
        get { lock (_lock) return _maxConcurrentDownloads; }
        set
        {
            // 兜底夹取到 [1,5]：0 或负数会让 StageSlotPool 永远无空槽，导致下载全部挂起。
            var clamped = Math.Clamp(value, 1, 5);
            lock (_lock) _maxConcurrentDownloads = clamped;
            _downloadPool.WakeAll();
        }
    }

    /// <summary>同时压制数。</summary>
    public int MaxConcurrentBurns
    {
        get { lock (_lock) return _maxConcurrentBurns; }
        set
        {
            // 兜底夹取到 [1,3]：理由同上。
            var clamped = Math.Clamp(value, 1, 3);
            lock (_lock) _maxConcurrentBurns = clamped;
            _burnPool.WakeAll();
        }
    }

    private readonly StageSlotPool _downloadPool;
    private readonly StageSlotPool _burnPool;
    /// <summary>翻译并发固定 2（每项内部还有 3 路分块并行，再高容易撞网关限流）。</summary>
    private readonly StageSlotPool _translatePool;
    /// <summary>
    /// 正在占用槽位的项（暂停让位 / 阶段结束释放用）。带代际：重试后旧流水线的
    /// 延迟释放不得动新代际刚领到的槽位。
    /// </summary>
    private readonly Dictionary<Guid, (int Generation, StageSlotPool Pool)> _holdingPool = [];
    /// <summary>暂停时让出的槽位池：恢复时需先重新领到槽位再恢复进程。</summary>
    private readonly Dictionary<Guid, (int Generation, StageSlotPool Pool)> _resumePool = [];
    private readonly Dictionary<Guid, (int Generation, QueueProgressPhase Phase, DateTimeOffset StartedAt)> _progressPhaseStarts = [];
    private readonly Dictionary<QueueProgressPhase, List<double>> _phaseDurationSamples = [];

    /// <summary>视频文件后缀（用于在产物里识别可烧录的视频）。</summary>
    internal static readonly HashSet<string> VideoExtensions =
    [
        "mp4", "mov", "mkv", "webm", "m4v", "avi", "flv", "ts",
    ];

    public QueueManager(
        IDownloadEngine engine,
        Func<AppSettings, ISubtitleTranslator>? translatorFactory = null,
        Func<ISubtitleBurner>? burnerFactory = null,
        AppSettings? settings = null,
        ILocalAsrSubtitleGenerator? localAsrGenerator = null,
        IQueueCompletionNotifier? completionNotifier = null)
    {
        _engine = engine;
        _translatorFactory = translatorFactory ?? (s => new ConfiguredTranslator(s));
        _burnerFactory = burnerFactory ?? (() => new FFmpegBurner());
        _localAsrGenerator = localAsrGenerator;
        _completionNotifier = completionNotifier;
        var loaded = settings ?? AppSettings.Load();
        _maxConcurrentDownloads = loaded.MaxConcurrentDownloads;
        _maxConcurrentBurns = loaded.MaxConcurrentBurns;
        _effectiveBurnCapacity = loaded.EffectiveMaxConcurrentBurns;
        _downloadPool = new StageSlotPool(() => MaxConcurrentDownloads);
        _burnPool = new StageSlotPool(() => { lock (_lock) return _effectiveBurnCapacity; });
        _translatePool = new StageSlotPool(() => 2);
    }

    public bool HasLocalAsrGenerator => _localAsrGenerator is not null;

    public void SyncLocalAsrGenerator(ILocalAsrSubtitleGenerator? generator)
    {
        _localAsrGenerator = generator;
    }

    public bool CanRetryWithLocalAsr(Guid id)
    {
        if (_localAsrGenerator is null) return false;
        lock (_lock)
        {
            var item = _items.FirstOrDefault(i => i.Id == id);
            return item?.CanRetryWithLocalAsr ?? false;
        }
    }

    /// <summary>设置保存后同步并发上限（setter 会唤醒排队者）。</summary>
    public void SyncConcurrency(AppSettings settings)
    {
        if (MaxConcurrentDownloads != settings.MaxConcurrentDownloads)
        {
            MaxConcurrentDownloads = settings.MaxConcurrentDownloads;
        }
        if (MaxConcurrentBurns != settings.MaxConcurrentBurns)
        {
            MaxConcurrentBurns = settings.MaxConcurrentBurns;
        }
        // 后端切换（硬件/软件）会改变有效压制并发，即使原始压制数没变也要同步。
        bool changed;
        lock (_lock)
        {
            changed = _effectiveBurnCapacity != settings.EffectiveMaxConcurrentBurns;
            _effectiveBurnCapacity = settings.EffectiveMaxConcurrentBurns;
        }
        if (changed) _burnPool.WakeAll();
    }

    // MARK: - 状态读取

    public IReadOnlyList<QueueItem> Items
    {
        get { lock (_lock) return [.. _items]; }
    }

    public QueueItem? Item(Guid id)
    {
        lock (_lock) return _items.FirstOrDefault(i => i.Id == id);
    }

    private int GenerationOf(Guid id)
    {
        lock (_lock) return _items.FirstOrDefault(i => i.Id == id)?.Generation ?? -1;
    }

    // MARK: - 槽位辅助

    /// <summary>等槽位（满员时先把状态文案改成等待提示），拿到后按代际登记为持有。</summary>
    private async Task AcquireSlotAsync(
        StageSlotPool pool, Guid id, int generation,
        TaskControlToken control, string waitingText, CancellationToken ct)
    {
        if (!pool.HasFreeSlot)
        {
            Update(id, generation, item => item.StatusText = waitingText);
        }
        await pool.AcquireAsync(id, control, respectPause: true, ct).ConfigureAwait(false);
        // 等待期间可能已被 retry 换代：旧代际拿到的槽立即归还，避免错记到新代际名下。
        if (GenerationOf(id) != generation)
        {
            pool.Release();
            throw MoongateException.Cancelled();
        }
        lock (_lock) _holdingPool[id] = (generation, pool);
        Update(id, generation, item =>
        {
            if (item.StatusText == waitingText) item.StatusText = null;
        });
    }

    /// <summary>阶段结束（成功或失败）释放槽位；只释放本代际登记的，暂停已让位时自然空操作。</summary>
    private void ReleaseSlot(Guid id, int generation)
    {
        StageSlotPool? pool = null;
        lock (_lock)
        {
            if (_holdingPool.TryGetValue(id, out var holding) && holding.Generation == generation)
            {
                _holdingPool.Remove(id);
                pool = holding.Pool;
            }
        }
        pool?.Release();
    }

    private void WakeFromAllPools(Guid id)
    {
        _downloadPool.Wake(id);
        _burnPool.Wake(id);
        _translatePool.Wake(id);
    }

    // MARK: - 派生状态

    /// <summary>
    /// 未到终态的任务数（queued/downloading/translating/burning，含已暂停）。
    /// 关窗确认据此统计，避免「只剩暂停任务」时静默丢弃。
    /// </summary>
    public int OpenTaskCount
    {
        get { lock (_lock) return _items.Count(i => IsOpen(i.Stage.Kind)); }
    }

    /// <summary>其中处于暂停态的数量。</summary>
    public int PausedOpenTaskCount
    {
        get { lock (_lock) return _items.Count(i => i.IsPaused && IsOpen(i.Stage.Kind)); }
    }

    internal static bool IsOpen(ItemStageKind stage) => stage switch
    {
        ItemStageKind.Queued or ItemStageKind.Downloading
            or ItemStageKind.Translating or ItemStageKind.Burning => true,
        _ => false,
    };

    /// <summary>存在已到终态（done/failed/cancelled）的项，「清除已完成」入口据此显示。</summary>
    public bool HasFinishedItems
    {
        get { lock (_lock) return _items.Any(i => !IsOpen(i.Stage.Kind)); }
    }

    public QueueProgressSnapshot ProgressSnapshot
    {
        get
        {
            lock (_lock)
            {
                return QueueProgressEstimator.QueueSnapshot(_items.Select(item =>
                {
                    var terminal = !IsOpen(item.Stage.Kind);
                    return new TaskProgressSnapshot(
                        OverallProgress: terminal ? 1 : item.OverallProgress,
                        RemainingSeconds: item.RemainingSeconds,
                        IsEstimatingRemaining: item.IsEstimatingRemaining,
                        IsTerminal: terminal,
                        Plan: item.ProgressPlan,
                        CurrentPhase: item.ProgressPhase,
                        WorkPlan: item.WorkPlan);
                }).ToList(), PhaseMedianDurationsLocked(), new Dictionary<QueueProgressPhase, int>
                {
                    [QueueProgressPhase.Download] = Math.Max(1, _maxConcurrentDownloads),
                    [QueueProgressPhase.AudioExtract] = Math.Max(1, _maxConcurrentDownloads),
                    [QueueProgressPhase.SpeechRecognition] = 1,
                    [QueueProgressPhase.SubtitleSegment] = 2,
                    [QueueProgressPhase.Transcode] = Math.Max(1, _maxConcurrentDownloads),
                    [QueueProgressPhase.Translate] = 2,
                    [QueueProgressPhase.Burn] = Math.Max(1, _effectiveBurnCapacity),
                });
            }
        }
    }

    private Dictionary<QueueProgressPhase, double> PhaseMedianDurationsLocked()
    {
        var medians = new Dictionary<QueueProgressPhase, double>();
        foreach (var (phase, samples) in _phaseDurationSamples)
        {
            var valid = samples
                .Where(value => !double.IsNaN(value) && !double.IsInfinity(value) && value >= 0)
                .Order()
                .ToList();
            if (valid.Count > 0) medians[phase] = valid[valid.Count / 2];
        }
        return medians;
    }

    private static QueueProgressPlan ProgressPlanFor(DownloadRequest request, ChineseSubtitleMode mode) => new(
        shouldTranscode: Transcoder.NeedsProcessing(request.OutputFormat),
        shouldTranslate: mode is ChineseSubtitleMode.SrtOnly or ChineseSubtitleMode.BurnIn,
        shouldBurn: mode is ChineseSubtitleMode.BurnIn or ChineseSubtitleMode.BurnOriginal);

    private static TaskWorkPlan WorkPlanFor(DownloadRequest request, ChineseSubtitleMode mode)
    {
        var needsLocalAsr = request.RequestedSubtitleTracks.Any(track => track.SourceKind == SubtitleSourceKind.LocalAsr);
        // Weights approximate real wall-clock so the bar tracks time (download/transcription/
        // translation/burn are all multi-minute). Mirrors the Swift QueueManager.workPlan.
        return new TaskWorkPlan(
            shouldExtractAudio: needsLocalAsr,
            shouldRunASR: needsLocalAsr,
            shouldSegmentSubtitles: needsLocalAsr,
            shouldTranscode: Transcoder.NeedsProcessing(request.OutputFormat),
            shouldTranslate: mode is ChineseSubtitleMode.SrtOnly or ChineseSubtitleMode.BurnIn,
            shouldBurn: mode is ChineseSubtitleMode.BurnIn or ChineseSubtitleMode.BurnOriginal,
            downloadUnits: 2,
            audioExtractUnits: 1,
            speechRecognitionUnits: needsLocalAsr ? 6 : 1,
            subtitleSegmentUnits: 1,
            transcodeUnits: 2,
            translateUnits: 6,
            burnUnits: 4);
    }

    // MARK: - 入队

    /// <summary>去重键：优先 videoID，取不到用 sourceURL + formatID。</summary>
    internal static string DedupeKey(string videoId, string sourceUrl, string formatId)
    {
        var id = videoId.Trim();
        if (id.Length > 0 && id != "video") return "id:" + id;
        return "url:" + sourceUrl + "|" + formatId;
    }

    /// <summary>队列里是否已有同源且未到终态（非 done/failed/cancelled）的任务。</summary>
    public bool HasOpenDuplicate(string videoId, string sourceUrl, string formatId)
    {
        var key = DedupeKey(videoId, sourceUrl, formatId);
        lock (_lock)
        {
            return _items.Any(item =>
                IsOpen(item.Stage.Kind)
                && DedupeKey(item.Info.VideoId, item.Request.Url, item.Request.FormatId) == key);
        }
    }

    public Guid Enqueue(VideoInfo info, DownloadRequest request, ChineseSubtitleMode chineseMode, AppSettings settings)
    {
        var id = Guid.NewGuid();
        var item = new QueueItem
        {
            Id = id,
            Title = info.Title,
            ThumbnailUrl = info.ThumbnailUrl,
            Info = info,
            Request = request,
            ChineseMode = chineseMode,
            Settings = settings,
            ProgressPlan = ProgressPlanFor(request, chineseMode),
            WorkPlan = WorkPlanFor(request, chineseMode),
        };
        lock (_lock) _items.Add(item);
        ItemsChanged?.Invoke();
        var ct = item.Cts.Token;
        var task = Task.Run(() => RunPipelineAsync(id, skipDownload: false, ct), CancellationToken.None);
        lock (_lock) item.RunTask = task;
        return id;
    }

    // MARK: - 流水线

    /// <summary>跑完整条流水线。skipDownload=true 用于重试：已下载产物在 ResultFiles 里，跳过下载阶段。</summary>
    private async Task RunPipelineAsync(Guid id, bool skipDownload, CancellationToken ct)
    {
        var current = Item(id);
        if (current is null) return;
        var control = current.Control;
        var settings = current.Settings;
        var mode = current.ChineseMode;
        // 启动代际：每次写回前校验，作废重试后陈旧回调的写入。
        var generation = current.Generation;

        // 1. 下载
        List<string> downloadFiles;
        if (skipDownload)
        {
            downloadFiles = [.. current.ResultFiles];
            Update(id, generation, item =>
            {
                item.OverallProgress = QueueProgressEstimator.TaskOverallProgress(
                    item.WorkPlan,
                    QueueProgressPhase.Download,
                    1,
                    item.OverallProgress);
                item.ClearProgress();
            });
        }
        else
        {
            try
            {
                await AcquireSlotAsync(_downloadPool, id, generation, control,
                    L10n.T("排队中：等待下载空位", "排隊中：等待下載空位", "Queued: waiting for a download slot"), ct).ConfigureAwait(false);
                try
                {
                    Update(id, generation, item =>
                    {
                        item.Stage = ItemStage.Downloading;
                        item.ClearProgress(resetOverall: true);
                        item.StatusText = null;
                        item.IsPostDownloadProcessing = false;
                        item.PostDownloadProcessingKind = PostDownloadProcessingKind.None;
                        ApplyProgress(item, id, generation, QueueProgressPhase.Download, null);
                    });
                    var result = await _engine.DownloadAsync(
                        current.Request, control,
                        p => ApplyDownloadProgress(id, generation, p),
                        ct).ConfigureAwait(false);
                    if (GenerationOf(id) != generation) return;
                    downloadFiles = [.. result.Files];
                    CompleteProgressPhase(id, generation, QueueProgressPhase.Download);
                    Update(id, generation, item =>
                    {
                        item.ResultFiles = [.. result.Files];
                        item.ClearProgress();
                    });

                    // 下载后转码/remux（用户选了非「保持源格式」时）。在下载槽内顺序执行。
                    if (Transcoder.NeedsProcessing(current.Request.OutputFormat))
                    {
                        var videoFile = downloadFiles.FirstOrDefault(f =>
                            VideoExtensions.Contains(Path.GetExtension(f).TrimStart('.').ToLowerInvariant()));
                        if (videoFile is not null)
                        {
                            Update(id, generation, item =>
                            {
                                item.Stage = ItemStage.Downloading;
                                item.ClearProgress();
                                item.StatusText = null;
                                item.IsPostDownloadProcessing = true;
                                item.PostDownloadProcessingKind = PostDownloadProcessingKind.Transcoding;
                                ApplyProgress(item, id, generation, QueueProgressPhase.Transcode, null);
                            });
                            // Transcoder 会先探测实际下载产物；偏好 HDR 只作为 ffprobe 失败时的兜底。
                            var requestedHdrFallback = current.Request.PreferHdr;
                            var transcoded = await new Transcoder().TranscodeAsync(
                                videoFile, current.Request.OutputFormat,
                                sourceVCodec: null, sourceIsHdr: requestedHdrFallback,
                                control,
                                frac =>
                                {
                                    if (GenerationOf(id) != generation) return;
                                    Update(id, generation, item =>
                                        ApplyProgress(item, id, generation, QueueProgressPhase.Transcode, frac));
                                },
                                backend: current.Settings.EncodeBackend,
                                ct: ct).ConfigureAwait(false);
                            if (GenerationOf(id) != generation) return;
                            // 用转码产物替换原视频文件（删原文件，除非同一路径）。
                            if (!PathsEqual(transcoded, videoFile))
                            {
                                try { File.Delete(videoFile); } catch { /* best-effort */ }
                            }
                            downloadFiles = downloadFiles.Select(f => f == videoFile ? transcoded : f).ToList();
                            if (!downloadFiles.Contains(transcoded)) downloadFiles.Add(transcoded);
                            CompleteProgressPhase(id, generation, QueueProgressPhase.Transcode);
                            Update(id, generation, item =>
                            {
                                item.ResultFiles = [.. downloadFiles];
                                item.ClearProgress();
                                item.StatusText = null;
                                item.IsPostDownloadProcessing = false;
                                item.PostDownloadProcessingKind = PostDownloadProcessingKind.None;
                            });
                        }
                    }
                }
                finally
                {
                    ReleaseSlot(id, generation);
                }
            }
            catch (Exception error)
            {
                if (GenerationOf(id) != generation) return;
                if (IsCancellation(error))
                {
                    Update(id, generation, item =>
                    {
                        item.Stage = ItemStage.Cancelled;
                        item.IsPaused = false;
                        item.ClearProgress();
                        item.StatusText = L10n.T("已取消", "已取消", "Cancelled");
                        item.IsPostDownloadProcessing = false;
                        item.PostDownloadProcessingKind = PostDownloadProcessingKind.None;
                    });
                    ClearProgressTracking(id);
                }
                else
                {
                    var reason = ShortReason(error);
                    Update(id, generation, item =>
                    {
                        item.Stage = ItemStage.Failed(reason);
                        item.IsPaused = false;
                        item.ClearProgress();
                        item.StatusText = L10n.T($"失败：{reason}", $"失敗：{reason}", $"Failed: {reason}");
                        item.IsPostDownloadProcessing = false;
                        item.PostDownloadProcessingKind = PostDownloadProcessingKind.None;
                    });
                    ClearProgressTracking(id);
                }
                return;
            }
        }

        // 下载完成，无需字幕处理：直接完成
        if (mode == ChineseSubtitleMode.Off)
        {
            FinishDone(id, generation, downloadFiles, null);
            return;
        }

        try
        {
            downloadFiles = await PrepareLocalAsrSourceSubtitleIfNeededAsync(
                downloadFiles,
                current.Request,
                id,
                generation,
                control,
                ct).ConfigureAwait(false);
        }
        catch (Exception error)
        {
            if (GenerationOf(id) != generation) return;
            SettlePartial(id, generation, Item(id)?.ResultFiles?.ToList() ?? downloadFiles, error,
                L10n.T("语音识别", "語音識別", "speech recognition"));
            return;
        }

        // 找翻译源字幕；没有就完成并提示已跳过
        var primarySubtitleTrack = current.Request.PrimarySubtitleTrack;
        var preferredLang = primarySubtitleTrack?.LanguageCode
            ?? current.Request.SubtitleLangs.FirstOrDefault()
            ?? current.Request.AutoSubtitleLangs.FirstOrDefault();
        var sourceSubtitle = PickSourceSubtitle(downloadFiles, preferredLang, primarySubtitleTrack);
        if (sourceSubtitle is null)
        {
            FinishDone(id, generation, downloadFiles, mode == ChineseSubtitleMode.BurnOriginal
                ? L10n.T("没有字幕文件，已跳过烧录", "沒有字幕檔，已跳過燒錄", "No subtitle file; burn-in skipped")
                : L10n.T("没有字幕文件，已跳过翻译", "沒有字幕檔，已跳過翻譯", "No subtitle file; translation skipped"));
            return;
        }

        // 直接烧录模式：跳过翻译，把所选源字幕原样压进视频（无论语言、无需配置翻译服务）。
        if (mode == ChineseSubtitleMode.BurnOriginal)
        {
            var rawVideo = downloadFiles.FirstOrDefault(f => VideoExtensions.Contains(ExtensionOf(f)));
            if (rawVideo is null)
            {
                FinishDone(id, generation, downloadFiles,
                    L10n.T("没有找到视频文件，已跳过烧录", "沒有找到影片檔，已跳過燒錄", "No video file found; burn-in skipped"));
                return;
            }
            try
            {
                await AcquireSlotAsync(_burnPool, id, generation, control,
                    L10n.T("排队中：等待压制空位", "排隊中：等待壓製空位", "Queued: waiting for an encoding slot"), ct).ConfigureAwait(false);
                try
                {
                    Update(id, generation, item =>
                    {
                        item.Stage = ItemStage.Burning;
                        item.ClearProgress();
                        item.StatusText = L10n.T("直接烧录字幕（不翻译）", "直接燒錄字幕（不翻譯）", "Burning subtitle as-is (no translation)");
                        item.IsPostDownloadProcessing = false;
                        item.PostDownloadProcessingKind = PostDownloadProcessingKind.None;
                        ApplyProgress(item, id, generation, QueueProgressPhase.Burn, null);
                    });
                    var burnSubtitle = EnsureSrtSubtitle(sourceSubtitle);
                    var burner = _burnerFactory();
                    var burned = await burner.BurnAsync(
                        rawVideo, burnSubtitle, settings.MaxBurnHeight, control,
                        p => Update(id, generation, item =>
                        {
                            if (item.Stage.Kind != ItemStageKind.Burning) return;
                            ApplyProgress(item, id, generation, QueueProgressPhase.Burn, p);
                        }),
                        backend: settings.EncodeBackend,
                        alwaysH264: settings.BurnAlwaysH264,
                        outputTag: L10n.T("（字幕版）", "（字幕版）", " (subtitled)"),
                        ct: ct).ConfigureAwait(false);
                    if (GenerationOf(id) != generation) return;
                    CompleteProgressPhase(id, generation, QueueProgressPhase.Burn);
                    Update(id, generation, item =>
                    {
                        var files = item.ResultFiles.Where(f => f != burned).ToList();
                        files.Insert(0, burned);
                        item.ResultFiles = files;
                    });
                    FinishDone(id, generation, Item(id)?.ResultFiles?.ToList() ?? downloadFiles,
                        L10n.T("已烧录字幕（未翻译）", "已燒錄字幕（未翻譯）", "Subtitle burned in (no translation)"));
                }
                finally
                {
                    ReleaseSlot(id, generation);
                }
            }
            catch (Exception error)
            {
                if (GenerationOf(id) != generation) return;
                SettlePartial(id, generation, Item(id)?.ResultFiles?.ToList() ?? downloadFiles, error,
                    L10n.T("烧录", "燒錄", "burn-in"));
            }
            return;
        }

        // 成熟的同语言软字幕：源字幕已与翻译目标语言同一脚本时直接使用，跳过 LLM 翻译。
        // 判定优先用 request 里记录的 lang，回退按所选文件名 ".<lang>.srt/.vtt" 解析。
        var sourceLang = primarySubtitleTrack?.LanguageCode ?? LangCode(sourceSubtitle);
        var sourceMatchesTarget = TranslationLanguage.Matches(
            sourceLang, settings.TranslationTargetLanguage);
        if (sourceMatchesTarget)
        {
            // srtOnly：原目标语言字幕即结果；若源是 VTT，先转成 SRT，保持模式语义。
            if (mode != ChineseSubtitleMode.BurnIn)
            {
                try
                {
                    var normalized = EnsureSrtSubtitle(sourceSubtitle);
                    var files = downloadFiles.ToList();
                    if (!files.Contains(normalized)) files.Add(normalized);
                    FinishDone(id, generation, files,
                        L10n.T("使用视频自带目标语言字幕，已跳过翻译",
                            "使用影片內建目標語言字幕，已跳過翻譯",
                            "Using the video's target-language subtitle; translation skipped"));
                }
                catch (Exception error)
                {
                    SettlePartial(id, generation, downloadFiles, error,
                        L10n.T("翻译", "翻譯", "translation"));
                }
                return;
            }
            // burnIn：直接拿目标语言字幕去烧录；VTT 先转成 SRT。
            var chineseVideo = downloadFiles.FirstOrDefault(f => VideoExtensions.Contains(ExtensionOf(f)));
            if (chineseVideo is null)
            {
                FinishDone(id, generation, downloadFiles,
                    L10n.T("没有找到视频文件，已跳过烧录", "沒有找到影片檔，已跳過燒錄", "No video file found; burn-in skipped"));
                return;
            }
            try
            {
                await AcquireSlotAsync(_burnPool, id, generation, control,
                    L10n.T("排队中：等待压制空位", "排隊中：等待壓製空位", "Queued: waiting for an encoding slot"), ct).ConfigureAwait(false);
                try
                {
                    Update(id, generation, item =>
                    {
                        item.Stage = ItemStage.Burning;
                        item.ClearProgress();
                        item.StatusText = L10n.T("使用视频自带目标语言字幕，直接烧录（不翻译）",
                            "使用影片內建目標語言字幕，直接燒錄（不翻譯）",
                            "Using the video's target-language subtitle; burning directly (no translation)");
                        item.IsPostDownloadProcessing = false;
                        item.PostDownloadProcessingKind = PostDownloadProcessingKind.None;
                        ApplyProgress(item, id, generation, QueueProgressPhase.Burn, null);
                    });
                    var burnSubtitle = EnsureSrtSubtitle(sourceSubtitle);
                    var burner = _burnerFactory();
                    var burned = await burner.BurnAsync(
                        chineseVideo, burnSubtitle, settings.MaxBurnHeight, control,
                        p => Update(id, generation, item =>
                        {
                            if (item.Stage.Kind != ItemStageKind.Burning) return;
                            ApplyProgress(item, id, generation, QueueProgressPhase.Burn, p);
                        }),
                        backend: settings.EncodeBackend,
                        alwaysH264: settings.BurnAlwaysH264,
                        ct: ct).ConfigureAwait(false);
                    if (GenerationOf(id) != generation) return;
                    CompleteProgressPhase(id, generation, QueueProgressPhase.Burn);
                    Update(id, generation, item =>
                    {
                        var files = item.ResultFiles.Where(f => f != burned).ToList();
                        files.Insert(0, burned);
                        item.ResultFiles = files;
                    });
                    FinishDone(id, generation, Item(id)?.ResultFiles?.ToList() ?? downloadFiles,
                        L10n.T("已烧录视频自带目标语言字幕",
                            "已燒錄影片內建目標語言字幕",
                            "Burned the video's target-language subtitle"));
                }
                finally
                {
                    ReleaseSlot(id, generation);
                }
            }
            catch (Exception error)
            {
                if (GenerationOf(id) != generation) return;
                SettlePartial(id, generation, Item(id)?.ResultFiles?.ToList() ?? downloadFiles, error,
                    L10n.T("烧录", "燒錄", "burn-in"));
            }
            return;
        }

        // 2. 翻译
        string zhSrt;
        try
        {
            await AcquireSlotAsync(_translatePool, id, generation, control,
                L10n.T("排队中：等待翻译空位", "排隊中：等待翻譯空位", "Queued: waiting for a translation slot"), ct).ConfigureAwait(false);
            try
            {
                Update(id, generation, item =>
                {
                    item.Stage = ItemStage.Translating;
                    item.ClearProgress();
                    item.StatusText = null;
                    item.IsPostDownloadProcessing = false;
                    item.PostDownloadProcessingKind = PostDownloadProcessingKind.None;
                    ApplyProgress(item, id, generation, QueueProgressPhase.Translate, null);
                });
                var translationSettings = settings.ForTranslation();
                var translator = _translatorFactory(translationSettings);
                zhSrt = await translator.TranslateAsync(
                    sourceSubtitle, translationSettings.SubtitleStyle, control,
                    p => Update(id, generation, item =>
                    {
                        if (item.Stage.Kind != ItemStageKind.Translating) return;
                        ApplyProgress(item, id, generation, QueueProgressPhase.Translate, p);
                    }),
                    ct).ConfigureAwait(false);
                if (GenerationOf(id) != generation) return;
                CompleteProgressPhase(id, generation, QueueProgressPhase.Translate);
                Update(id, generation, item =>
                {
                    item.ClearProgress();
                    if (!item.ResultFiles.Contains(zhSrt))
                    {
                        item.ResultFiles = [.. item.ResultFiles, zhSrt];
                    }
                });
            }
            finally
            {
                ReleaseSlot(id, generation);
            }
        }
        catch (Exception error)
        {
            if (GenerationOf(id) != generation) return;
            SettlePartial(id, generation, downloadFiles, error, L10n.T("翻译", "翻譯", "translation"));
            return;
        }

        // 3. 烧录（仅 burnIn）
        if (mode != ChineseSubtitleMode.BurnIn)
        {
            FinishDone(id, generation, Item(id)?.ResultFiles?.ToList() ?? downloadFiles, null);
            return;
        }
        var video = downloadFiles.FirstOrDefault(f => VideoExtensions.Contains(ExtensionOf(f)));
        if (video is null)
        {
            FinishDone(id, generation, Item(id)?.ResultFiles?.ToList() ?? downloadFiles,
                L10n.T("没有找到视频文件，已跳过烧录", "沒有找到影片檔，已跳過燒錄", "No video file found; burn-in skipped"));
            return;
        }

        try
        {
            await AcquireSlotAsync(_burnPool, id, generation, control,
                L10n.T("排队中：等待压制空位", "排隊中：等待壓製空位", "Queued: waiting for an encoding slot"), ct).ConfigureAwait(false);
            try
            {
                Update(id, generation, item =>
                {
                    item.Stage = ItemStage.Burning;
                    item.ClearProgress();
                    item.StatusText = null;
                    item.IsPostDownloadProcessing = false;
                    item.PostDownloadProcessingKind = PostDownloadProcessingKind.None;
                    ApplyProgress(item, id, generation, QueueProgressPhase.Burn, null);
                });
                var burner = _burnerFactory();
                var burned = await burner.BurnAsync(
                    video, zhSrt, settings.MaxBurnHeight, control,
                    p => Update(id, generation, item =>
                    {
                        if (item.Stage.Kind != ItemStageKind.Burning) return;
                        ApplyProgress(item, id, generation, QueueProgressPhase.Burn, p);
                    }),
                    backend: settings.EncodeBackend,
                    alwaysH264: settings.BurnAlwaysH264,
                    ct: ct).ConfigureAwait(false);
                if (GenerationOf(id) != generation) return;
                CompleteProgressPhase(id, generation, QueueProgressPhase.Burn);
                Update(id, generation, item =>
                {
                    var files = item.ResultFiles.Where(f => f != burned).ToList();
                    files.Insert(0, burned);
                    item.ResultFiles = files;
                });
                FinishDone(id, generation, Item(id)?.ResultFiles?.ToList() ?? downloadFiles, null);
            }
            finally
            {
                ReleaseSlot(id, generation);
            }
        }
        catch (Exception error)
        {
            if (GenerationOf(id) != generation) return;
            SettlePartial(id, generation, Item(id)?.ResultFiles?.ToList() ?? downloadFiles, error,
                L10n.T("烧录", "燒錄", "burn-in"));
        }
    }

    /// <summary>下载进度显示态：进度分数（null=不确定）+ 是否「处理中」（合并/收尾，显示不确定）。</summary>
    public readonly record struct DownloadProgressState(double? Progress, bool IsProcessing);

    /// <summary>
    /// 由当前显示态 + yt-dlp 上报的百分比（0..1，null 表示无百分比）推导下一显示态（纯函数，便于测试）。
    /// Engine 层会把 DASH 分流下载聚合成整体百分比；这里再做防御，避免任何迟到/回落的
    /// 子进程百分比让用户可见进度倒退。仅过滤 &lt; 0.5 个百分点的高频抖动，减少刷新 churn。
    /// 合并阶段由 yt-dlp 的 [Merger] 行单独触发「处理中」（见 Processing 分支）。
    /// </summary>
    internal static DownloadProgressState NextDownloadProgressState(DownloadProgressState current, double? incoming)
    {
        incoming = NormalizeProgressFraction(incoming);
        if (incoming is not { } next) return current;                                    // 无百分比 → 不变
        if (current.Progress is { } old && (next <= old || Math.Abs(next - old) < 0.005)) return current;
        return new DownloadProgressState(next, false);
    }

    /// <summary>
    /// 下载进度上报：转 0...1。某条流满后进入「处理中」（不确定），避免卡 100% 或进度倒退。
    /// </summary>
    internal static double? NormalizeProgressFraction(double? value)
    {
        if (value is not { } fraction || double.IsNaN(fraction) || double.IsInfinity(fraction)) return null;
        return Math.Clamp(fraction, 0, 1);
    }

    private DateTimeOffset ProgressPhaseStart(Guid id, int generation, QueueProgressPhase phase, DateTimeOffset now)
    {
        if (_progressPhaseStarts.TryGetValue(id, out var existing)
            && existing.Generation == generation
            && existing.Phase == phase)
        {
            return existing.StartedAt;
        }
        _progressPhaseStarts[id] = (generation, phase, now);
        return now;
    }

    private void ClearProgressTracking(Guid id)
    {
        lock (_lock) _progressPhaseStarts.Remove(id);
    }

    private void CompleteProgressPhase(Guid id, int generation, QueueProgressPhase expectedPhase)
    {
        lock (_lock)
        {
            if (!_progressPhaseStarts.TryGetValue(id, out var existing)
                || existing.Generation != generation
                || existing.Phase != expectedPhase)
            {
                return;
            }
            var duration = Math.Max(0.1, (DateTimeOffset.UtcNow - existing.StartedAt).TotalSeconds);
            _progressPhaseStarts.Remove(id);
            if (!_phaseDurationSamples.TryGetValue(expectedPhase, out var samples))
            {
                samples = [];
                _phaseDurationSamples[expectedPhase] = samples;
            }
            samples.Add(duration);
            if (samples.Count > 9)
            {
                samples.RemoveRange(0, samples.Count - 9);
            }
        }
    }

    private void ApplyProgress(
        QueueItem item,
        Guid id,
        int generation,
        QueueProgressPhase phase,
        double? phaseProgress,
        string? speedText = null,
        string? etaText = null)
    {
        var now = DateTimeOffset.UtcNow;
        var normalized = QueueProgressEstimator.NormalizedFraction(phaseProgress);
        var startedAt = ProgressPhaseStart(id, generation, phase, now);
        item.Progress = normalized;
        item.ProgressPhase = phase;
        item.OverallProgress = QueueProgressEstimator.TaskOverallProgress(
            item.WorkPlan,
            phase,
            normalized,
            item.OverallProgress);
        item.SpeedText = speedText;
        var remaining = QueueProgressEstimator.EstimatedRemainingSeconds(
            elapsedSeconds: Math.Max(0, (now - startedAt).TotalSeconds),
            phaseProgress: normalized,
            sourceEtaSeconds: QueueProgressEstimator.ParseEtaSeconds(etaText));
        item.RemainingSeconds = remaining?.Seconds;
        item.RemainingIsApproximate = remaining?.IsApproximate ?? false;
        item.IsEstimatingRemaining = remaining is null && normalized != 1 && !item.IsPaused;
    }

    private void ApplyDownloadProgress(Guid id, int generation, DownloadProgress p)
    {
        Update(id, generation, item =>
        {
            // 进入烧录/翻译后不再被迟到的下载回调覆盖
            if (item.Stage.Kind != ItemStageKind.Downloading) return;
            switch (p.Phase)
            {
                case DownloadProgress.ProgressPhase.Downloading:
                    double? newValue = p.Percent is { } percent ? NormalizeProgressFraction(percent / 100) : null;
                    var cur = new DownloadProgressState(
                        item.Progress,
                        item.IsPostDownloadProcessing
                            && item.PostDownloadProcessingKind == PostDownloadProcessingKind.Generic);
                    var nextState = NextDownloadProgressState(cur, newValue);
                    ApplyProgress(
                        item,
                        id,
                        generation,
                        QueueProgressPhase.Download,
                        nextState.Progress,
                        speedText: p.SpeedText,
                        etaText: p.EtaText);
                    item.IsPostDownloadProcessing = nextState.IsProcessing;
                    item.PostDownloadProcessingKind = nextState.IsProcessing
                        ? PostDownloadProcessingKind.Generic
                        : PostDownloadProcessingKind.None;
                    break;
                case DownloadProgress.ProgressPhase.Preparing:
                    ApplyProgress(item, id, generation, QueueProgressPhase.Download, null);
                    item.IsPostDownloadProcessing = false;
                    item.PostDownloadProcessingKind = PostDownloadProcessingKind.None;
                    break;
                case DownloadProgress.ProgressPhase.Finished:
                    ApplyProgress(item, id, generation, QueueProgressPhase.Download, 1);
                    item.ClearProgress();
                    item.IsPostDownloadProcessing = false;
                    item.PostDownloadProcessingKind = PostDownloadProcessingKind.None;
                    break;
                case DownloadProgress.ProgressPhase.Processing:
                    // 下载 100% 后的合并/转码：进度不确定，标记为「处理中」避免像卡死。
                    ApplyProgress(item, id, generation, QueueProgressPhase.Download, null);
                    item.IsPostDownloadProcessing = true;
                    item.PostDownloadProcessingKind = PostDownloadProcessingKind.Generic;
                    break;
            }
        });
    }

    /// <summary>
    /// 部分成功：下载产物已落盘 → Done + 失败说明（可重试字幕处理）；否则视为 Failed。
    /// 取消 → Cancelled，保留已下产物。
    /// </summary>
    private void SettlePartial(Guid id, int generation, List<string> files, Exception error, string phase)
    {
        if (IsCancellation(error))
        {
            Update(id, generation, item =>
            {
                item.Stage = ItemStage.Cancelled;
                item.IsPaused = false;
                item.ClearProgress();
                item.StatusText = files.Count == 0
                    ? L10n.T("已取消", "已取消", "Cancelled")
                    : L10n.T("已取消，视频已保存", "已取消，影片已儲存", "Cancelled; downloaded video kept");
                item.IsPostDownloadProcessing = false;
                item.PostDownloadProcessingKind = PostDownloadProcessingKind.None;
            });
            ClearProgressTracking(id);
            return;
        }
        var reason = ShortReason(error);
        if (files.Count > 0)
        {
            Update(id, generation, item =>
            {
                item.Stage = ItemStage.Done;
                item.IsPaused = false;
                item.CompleteProgress();
                item.PartialFailure = true;
                item.StatusText = L10n.T($"视频已下载，字幕{phase}失败：{reason}",
                    $"影片已下載，字幕{phase}失敗：{reason}",
                    $"Video saved; subtitle {phase} failed: {reason}");
                item.IsPostDownloadProcessing = false;
                item.PostDownloadProcessingKind = PostDownloadProcessingKind.None;
            });
            ClearProgressTracking(id);
        }
        else
        {
            Update(id, generation, item =>
            {
                item.Stage = ItemStage.Failed(reason);
                item.IsPaused = false;
                item.ClearProgress();
                item.StatusText = L10n.T($"失败：{reason}", $"失敗：{reason}", $"Failed: {reason}");
                item.IsPostDownloadProcessing = false;
                item.PostDownloadProcessingKind = PostDownloadProcessingKind.None;
            });
            ClearProgressTracking(id);
        }
    }

    private void FinishDone(Guid id, int generation, List<string> files, string? statusText)
    {
        Update(id, generation, item =>
        {
            item.Stage = ItemStage.Done;
            item.IsPaused = false;
            item.CompleteProgress();
            item.PartialFailure = false;
            item.IsPostDownloadProcessing = false;
            item.PostDownloadProcessingKind = PostDownloadProcessingKind.None;
            item.ResultFiles = files.Count == 0 ? item.ResultFiles : files;
            item.StatusText = statusText;
        });
        ClearProgressTracking(id);
    }

    // MARK: - 单项控制

    public bool Pause(Guid id)
    {
        StageSlotPool? releasePool = null;
        lock (_lock)
        {
            var target = _items.FirstOrDefault(i => i.Id == id);
            if (target is null || !IsOpen(target.Stage.Kind) || target.IsPaused) return false;
            if (!target.Control.Pause()) return false;
            // 让出占用的下载/压制槽位给其它任务；恢复时重新排队领取。
            // 翻译请求不是本地可挂起进程，暂停后仍可能有分块请求在飞行中，不能释放翻译并发位。
            if (_holdingPool.TryGetValue(id, out var holding) && holding.Generation == target.Generation)
            {
                if (!ReferenceEquals(holding.Pool, _translatePool))
                {
                    _holdingPool.Remove(id);
                    _resumePool[id] = holding;
                    releasePool = holding.Pool;
                }
            }
            target.IsPaused = true;
        }
        releasePool?.Release();
        ItemUpdated?.Invoke(id);
        return true;
    }

    public bool Resume(Guid id)
    {
        TaskControlToken control;
        int generation;
        CancellationToken ct;
        (int Generation, StageSlotPool Pool)? parked = null;
        lock (_lock)
        {
            var target = _items.FirstOrDefault(i => i.Id == id);
            if (target is null || !target.IsPaused) return false;
            control = target.Control;
            generation = target.Generation;
            ct = target.Cts.Token;
            if (_resumePool.Remove(id, out var entry) && entry.Generation == generation)
            {
                parked = entry;
            }
            if (parked is null)
            {
                if (!control.Resume()) return false;
                target.IsPaused = false;
            }
            else
            {
                if (!control.IsPaused) return false;
                target.IsPaused = false;
            }
        }
        if (parked is not { } parkedEntry)
        {
            // 没让过位（翻译阶段 / 排队中暂停）：直接恢复，acquire 循环或 gate 会接着走。
            ItemUpdated?.Invoke(id);
            return true;
        }
        // 让过位的：先重新领到槽位再恢复进程，避免恢复瞬间超出并发上限。
        var resumeWaitingText = L10n.T("等待空位恢复…", "等待空位恢復…", "Waiting for a free slot to resume…");
        Update(id, generation, item => item.StatusText = resumeWaitingText);
        _ = Task.Run(async () =>
        {
            try
            {
                await parkedEntry.Pool.AcquireAsync(id, control, respectPause: false, ct).ConfigureAwait(false);
                if (GenerationOf(id) != generation)
                {
                    parkedEntry.Pool.Release();
                    return;
                }
                lock (_lock) _holdingPool[id] = (generation, parkedEntry.Pool);
                Update(id, generation, item =>
                {
                    if (item.StatusText == resumeWaitingText) item.StatusText = null;
                });
                control.Resume();
            }
            catch
            {
                // 等槽期间被取消：流水线任务自会收敛，这里不动状态。
            }
        }, CancellationToken.None);
        return true;
    }

    public void Cancel(Guid id)
    {
        TaskControlToken control;
        CancellationTokenSource cts;
        lock (_lock)
        {
            var target = _items.FirstOrDefault(i => i.Id == id);
            if (target is null) return;
            _resumePool.Remove(id);
            _progressPhaseStarts.Remove(id);
            control = target.Control;
            cts = target.Cts;
        }
        control.Cancel();
        cts.Cancel();
        // 还在排队等槽位的，唤出来让 acquire 循环抛出取消。
        WakeFromAllPools(id);
    }

    public void Remove(Guid id)
    {
        TaskControlToken control;
        CancellationTokenSource cts;
        lock (_lock)
        {
            var target = _items.FirstOrDefault(i => i.Id == id);
            if (target is null) return;
            _resumePool.Remove(id);
            _progressPhaseStarts.Remove(id);
            control = target.Control;
            cts = target.Cts;
        }
        control.Cancel();
        cts.Cancel();
        WakeFromAllPools(id);
        lock (_lock) _items.RemoveAll(i => i.Id == id);
        ItemsChanged?.Invoke();
    }

    /// <summary>重试：保留已下载产物则跳过下载，仅重跑字幕处理；无产物则整条重跑。</summary>
    public void Retry(Guid id)
    {
        TaskControlToken oldControl;
        CancellationTokenSource oldCts;
        bool skipDownload;
        CancellationToken newCt;
        lock (_lock)
        {
            var old = _items.FirstOrDefault(i => i.Id == id);
            if (old is null) return;
            // 旧 control 若仍登记着进程，确保释放；清掉旧代际的槽位记账。
            _resumePool.Remove(id);
            _progressPhaseStarts.Remove(id);
            oldControl = old.Control;
            oldCts = old.Cts;
            var hasVideo = old.ResultFiles.Any(f => VideoExtensions.Contains(ExtensionOf(f)));
            skipDownload = hasVideo && old.ChineseMode != ChineseSubtitleMode.Off;
            old.Control = new TaskControlToken();
            old.Cts = new CancellationTokenSource();
            old.Generation += 1;
            old.Stage = ItemStage.Queued;
            old.IsPaused = false;
            old.ClearProgress(resetOverall: true);
            old.IsPostDownloadProcessing = false;
            old.PostDownloadProcessingKind = PostDownloadProcessingKind.None;
            old.PartialFailure = false;
            old.StatusText = skipDownload ? null : L10n.T("重新下载并处理", "重新下載並處理", "Re-downloading and processing");
            if (!skipDownload) old.ResultFiles = [];
            newCt = old.Cts.Token;
        }
        oldControl.Cancel();
        oldCts.Cancel();
        WakeFromAllPools(id);
        ItemUpdated?.Invoke(id);
        var task = Task.Run(() => RunPipelineAsync(id, skipDownload, newCt), CancellationToken.None);
        lock (_lock)
        {
            var item = _items.FirstOrDefault(i => i.Id == id);
            if (item is not null) item.RunTask = task;
        }
    }

    public void RetryWithLocalAsr(Guid id)
    {
        TaskControlToken oldControl;
        CancellationTokenSource oldCts;
        CancellationToken newCt;
        lock (_lock)
        {
            var old = _items.FirstOrDefault(i => i.Id == id);
            if (old is null) return;
            var request = LocalAsrRetryRequest(old.Request);
            var hasVideo = old.ResultFiles.Any(f => VideoExtensions.Contains(ExtensionOf(f)));
            if (_localAsrGenerator is null || request is null || old.ChineseMode == ChineseSubtitleMode.Off || !hasVideo) return;

            _resumePool.Remove(id);
            _progressPhaseStarts.Remove(id);
            oldControl = old.Control;
            oldCts = old.Cts;
            old.Request = request;
            old.ProgressPlan = ProgressPlanFor(request, old.ChineseMode);
            old.WorkPlan = WorkPlanFor(request, old.ChineseMode);
            old.Control = new TaskControlToken();
            old.Cts = new CancellationTokenSource();
            old.Generation += 1;
            old.Stage = ItemStage.Queued;
            old.IsPaused = false;
            old.ClearProgress(resetOverall: true);
            old.IsPostDownloadProcessing = false;
            old.PostDownloadProcessingKind = PostDownloadProcessingKind.None;
            old.PartialFailure = false;
            old.StatusText = null;
            newCt = old.Cts.Token;
        }
        oldControl.Cancel();
        oldCts.Cancel();
        WakeFromAllPools(id);
        ItemUpdated?.Invoke(id);
        var task = Task.Run(() => RunPipelineAsync(id, skipDownload: true, newCt), CancellationToken.None);
        lock (_lock)
        {
            var item = _items.FirstOrDefault(i => i.Id == id);
            if (item is not null) item.RunTask = task;
        }
    }

    private static DownloadRequest? LocalAsrRetryRequest(DownloadRequest request)
    {
        var source = request.RequestedSubtitleTracks.FirstOrDefault(track => track.SourceKind != SubtitleSourceKind.LocalAsr);
        if (source is null) return null;
        var languageCode = source.LanguageCode.Trim();
        if (languageCode.Length == 0) return null;
        var localAsrTrack = SubtitleChoice.Create(
            languageCode,
            source.Label,
            SubtitleSourceKind.LocalAsr,
            provider: "whisper.cpp",
            variant: "local");
        return new DownloadRequest
        {
            Url = request.Url,
            VideoId = request.VideoId,
            FormatId = request.FormatId,
            SubtitleLangs = [],
            AutoSubtitleLangs = [],
            SubtitleTracks = [localAsrTrack],
            PrimarySubtitleTrackId = localAsrTrack.Id,
            DestinationDirectory = request.DestinationDirectory,
            PreferredTitle = request.PreferredTitle,
            PreferHdr = request.PreferHdr,
            OutputFormat = request.OutputFormat,
        };
    }

    /// <summary>一次移除所有已到终态（done/failed/cancelled）的项。</summary>
    public void ClearFinished()
    {
        lock (_lock) _items.RemoveAll(i => !IsOpen(i.Stage.Kind));
        ItemsChanged?.Invoke();
    }

    // MARK: - 工具

    /// <summary>代际校验版写回：仅当当前 Generation 与捕获值一致时才写回，作废重试后的陈旧回调。</summary>
    private void Update(Guid id, int generation, Action<QueueItem> mutate)
    {
        var changed = false;
        lock (_lock)
        {
            var item = _items.FirstOrDefault(i => i.Id == id);
            if (item is not null && item.Generation == generation)
            {
                mutate(item);
                changed = true;
            }
        }
        if (changed)
        {
            ItemUpdated?.Invoke(id);
            NotifyQueueCompletionIfNeeded();
        }
    }

    private void NotifyQueueCompletionIfNeeded()
    {
        if (_completionNotifier is null) return;
        QueueCompletionNotification? notification = null;
        lock (_lock)
        {
            var openItems = _items.Where(item => IsOpen(item.Stage.Kind)).ToList();
            if (openItems.Count > 0) return;
            var terminalItems = _items
                .Where(item => !IsOpen(item.Stage.Kind) && !_notifiedTerminalIds.Contains(item.Id))
                .ToList();
            if (terminalItems.Count == 0) return;

            foreach (var item in terminalItems)
            {
                _notifiedTerminalIds.Add(item.Id);
            }
            var completedItems = terminalItems.Where(item => item.Stage.Kind == ItemStageKind.Done).ToList();
            if (completedItems.Count == 0) return;

            notification = new QueueCompletionNotification
            {
                CompletedCount = completedItems.Count,
                PartialFailureCount = completedItems.Count(item => item.PartialFailure),
                FailedCount = terminalItems.Count(item => item.Stage.Kind == ItemStageKind.Failed),
                CancelledCount = terminalItems.Count(item => item.Stage.Kind == ItemStageKind.Cancelled),
                Titles = completedItems.Select(item => item.Title).ToList(),
            };
        }
        if (notification is not null) _completionNotifier.QueueDidComplete(notification);
    }

    private static bool IsCancellation(Exception error) =>
        error is MoongateException { Kind: MoongateErrorKind.Cancelled } or OperationCanceledException;

    private async Task<List<string>> PrepareLocalAsrSourceSubtitleIfNeededAsync(
        List<string> files,
        DownloadRequest request,
        Guid id,
        int generation,
        TaskControlToken control,
        CancellationToken ct)
    {
        var languageCode = LocalAsrLanguageCode(request);
        if (languageCode is null) return files;
        if (ExistingLocalAsrSubtitle(files, languageCode) is { } existing)
        {
            var reusedFiles = files.ToList();
            if (!reusedFiles.Contains(existing)) reusedFiles.Add(existing);
            return reusedFiles;
        }
        if (_localAsrGenerator is null) return files;
        var videoFile = files.FirstOrDefault(file => VideoExtensions.Contains(ExtensionOf(file)));
        if (videoFile is null) return files;

        Update(id, generation, item =>
        {
            item.Stage = ItemStage.Downloading;
            item.ClearProgress();
            item.StatusText = null;
            item.IsPostDownloadProcessing = true;
            item.PostDownloadProcessingKind = PostDownloadProcessingKind.Generic;
            ApplyProgress(item, id, generation, QueueProgressPhase.AudioExtract, null);
        });
        var sourceSrt = await _localAsrGenerator.GenerateSourceSubtitleAsync(
            videoFile,
            languageCode,
            control,
            progress => ApplyAsrProgress(id, generation, progress),
            ct).ConfigureAwait(false);
        if (GenerationOf(id) != generation) return files;

        CompleteProgressPhase(id, generation, QueueProgressPhase.AudioExtract);
        CompleteProgressPhase(id, generation, QueueProgressPhase.SpeechRecognition);
        CompleteProgressPhase(id, generation, QueueProgressPhase.SubtitleSegment);
        var nextFiles = files.ToList();
        if (!nextFiles.Contains(sourceSrt)) nextFiles.Add(sourceSrt);
        Update(id, generation, item =>
        {
            item.ResultFiles = nextFiles;
            item.ClearProgress();
            item.StatusText = null;
            item.IsPostDownloadProcessing = false;
            item.PostDownloadProcessingKind = PostDownloadProcessingKind.None;
        });
        return nextFiles;
    }

    private void ApplyAsrProgress(Guid id, int generation, AsrProgress progress)
    {
        Update(id, generation, item =>
        {
            if (item.Stage.Kind != ItemStageKind.Downloading) return;
            ApplyProgress(item, id, generation, QueuePhase(progress.Phase), progress.Fraction);
        });
    }

    private static QueueProgressPhase QueuePhase(AsrProgressPhase phase) => phase switch
    {
        AsrProgressPhase.ModelDownload => QueueProgressPhase.ModelDownload,
        AsrProgressPhase.AudioExtract => QueueProgressPhase.AudioExtract,
        AsrProgressPhase.SpeechRecognition => QueueProgressPhase.SpeechRecognition,
        AsrProgressPhase.SubtitleSegment => QueueProgressPhase.SubtitleSegment,
        _ => QueueProgressPhase.SpeechRecognition,
    };

    private static string? LocalAsrLanguageCode(DownloadRequest request)
    {
        if (request.PrimarySubtitleTrack?.SourceKind == SubtitleSourceKind.LocalAsr)
        {
            return request.PrimarySubtitleTrack?.LanguageCode;
        }
        return request.RequestedSubtitleTracks
            .FirstOrDefault(track => track.SourceKind == SubtitleSourceKind.LocalAsr)?
            .LanguageCode;
    }

    private static string? ExistingLocalAsrSubtitle(IEnumerable<string> files, string languageCode)
    {
        var normalized = languageCode.Trim().ToLowerInvariant();
        if (normalized.Length == 0) return null;
        return files.FirstOrDefault(file =>
            IsLocalAsrSubtitle(file) && LangCodeOfSubtitle(file) == normalized);
    }

    private static string? LangCodeOfSubtitle(string file)
    {
        var stem = Path.GetFileNameWithoutExtension(file);
        var dotIndex = stem.LastIndexOf('.');
        if (dotIndex < 0 || dotIndex == stem.Length - 1) return null;
        return stem[(dotIndex + 1)..].ToLowerInvariant();
    }

    internal static string ShortReason(Exception error) => error switch
    {
        MoongateException
        {
            Kind: MoongateErrorKind.TranslateFailed or MoongateErrorKind.BurnFailed or MoongateErrorKind.DownloadFailed,
        } mge => mge.Detail,
        _ => error.Message,
    };

    private static string ExtensionOf(string path) =>
        Path.GetExtension(path).TrimStart('.').ToLowerInvariant();

    private static bool PathsEqual(string a, string b) =>
        string.Equals(Path.GetFullPath(a), Path.GetFullPath(b),
            OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal);

    /// <summary>lang code 以 zh 开头视为中文（zh / zh-Hans / zh-Hant / zh-CN / zh-TW 等）。</summary>
    internal static bool IsChineseLang(string? lang)
    {
        if (string.IsNullOrEmpty(lang)) return false;
        var lower = lang.ToLowerInvariant();
        var prefix = lower.Split('-')[0];
        return prefix == "zh";
    }

    /// <summary>从字幕文件名 "&lt;名&gt;.&lt;lang&gt;.srt/.vtt" 解析出 lang code（无法解析返回 null）。</summary>
    internal static string? LangCode(string file)
    {
        var stem = Path.GetFileNameWithoutExtension(file);
        var dotIndex = stem.LastIndexOf('.');
        if (dotIndex < 0) return null;
        return stem[(dotIndex + 1)..].ToLowerInvariant();
    }

    /// <summary>
    /// 按主字幕来源挑翻译源字幕：大小写不敏感、允许前缀匹配。
    /// preferredTrack 命中时先按来源类型筛选，同语言 local ASR 和平台字幕不再互相抢源；
    /// 没有主来源时回退第一个非译文字幕，避免把上次译文当源二次翻译。
    /// </summary>
    internal static string? PickSourceSubtitle(
        IReadOnlyList<string> files,
        string? preferredLang,
        SubtitleChoice? preferredTrack = null)
    {
        var subtitleFiles = files
            .Where(f => ExtensionOf(f) is "srt" or "vtt")
            .OrderBy(SubtitleSourceRank)
            .ToList();
        if (preferredLang is { Length: > 0 })
        {
            var lang = preferredLang.ToLowerInvariant();
            var matches = subtitleFiles.Where(file =>
                {
                    var code = LangCode(file);
                    if (code is null) return false;
                    return code == lang || code.StartsWith(lang + "-") || lang.StartsWith(code + "-");
                })
                .ToList();
            if (preferredTrack?.SourceKind == SubtitleSourceKind.LocalAsr)
            {
                var matched = matches.FirstOrDefault(IsLocalAsrSubtitle);
                if (matched is not null) return matched;
            }
            if (preferredTrack is not null && preferredTrack.SourceKind != SubtitleSourceKind.LocalAsr)
            {
                var matched = matches.FirstOrDefault(file => !IsLocalAsrSubtitle(file));
                if (matched is not null) return matched;
            }
            if (matches.FirstOrDefault() is { } fallback) return fallback;
        }
        var nonTranslated = subtitleFiles
            .Where(f => !TranslationLanguage.IsTranslatedSubtitleFileName(f))
            .ToList();
        return nonTranslated.FirstOrDefault() ?? subtitleFiles.FirstOrDefault();
    }

    private static int SubtitleSourceRank(string file) => ExtensionOf(file) switch
    {
        _ when IsLocalAsrSubtitle(file) => -1,
        "vtt" => 0,
        "srt" => 1,
        _ => 2,
    };

    private static bool IsLocalAsrSubtitle(string file) =>
        Path.GetFileName(file).Contains(".local-asr.", StringComparison.OrdinalIgnoreCase);

    private static string EnsureSrtSubtitle(string file)
    {
        if (ExtensionOf(file) == "srt") return file;
        return SrtTools.CleanSrtFile(file).OutputPath;
    }
}
