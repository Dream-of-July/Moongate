using System.Collections.ObjectModel;
using System.Windows;
using System.Windows.Threading;
using Moongate.Core;

namespace Moongate.App;

/// <summary>解析与选档的前半段状态机；下载之后的流水线全部交给 QueueManager。</summary>
public enum ParseStage
{
    Idle,
    Resolving,
    Choosing,
    Analyzing,
    Ready,
    Failed,
}

/// <summary>
/// 主窗口视图模型。移植自 macOS 版 ViewModel.swift：解析 → 选择 → 入队的状态机、
/// 批量粘贴多链接自动逐条解析入队、设置与站点登录的转场。
/// QueueManager 的事件在任意线程触发，这里统一经 Dispatcher 封送回 UI 线程后
/// 增量更新 ObservableCollection（不整表重建）。
/// </summary>
public sealed class MainViewModel : ObservableObject
{
    private readonly IDownloadEngine _engine;
    private readonly Dispatcher _dispatcher;

    public QueueManager Queue { get; }

    /// <summary>解析代际：取消 / 重置后旧任务的回调全部作废。</summary>
    private int _session;
    private CancellationTokenSource? _parseCts;
    private List<VideoCandidate> _candidates = [];
    private VideoCandidate? _chosenCandidate;
    private Action? _retryAction;
    private string? _pendingSettingsNotice;

    // 队列事件合批：同一帧内的多个 ItemUpdated 合并成一次 Dispatcher 调度。
    private readonly object _updateLock = new();
    private readonly HashSet<Guid> _pendingUpdates = [];
    private bool _updateScheduled;

    /// <summary>入队 / 重置后请求重新聚焦链接输入框（方便继续粘贴下一条）。</summary>
    public event Action? FocusUrlRequested;
    public event Action? OpenSettingsRequested;
    /// <summary>请求弹出站点登录窗（参数为站点 host，如 "youtube.com"）。</summary>
    public event Action<string>? OpenLoginRequested;

    public MainViewModel() : this(new YtDlpEngine(), null) { }

    public MainViewModel(IDownloadEngine engine, QueueManager? queue)
    {
        _engine = engine;
        _settings = AppSettings.Load();
        // 设置文件损坏被备份时（DATA-SETTINGS-002），给一次非阻断提示，而不是静默回默认。
        if (AppSettings.LastCorruptBackupPath is { } corruptBackup)
        {
            AppSettings.LastCorruptBackupPath = null;
            _enqueueNotice = Loc.F("L.Settings.CorruptResetFmt", corruptBackup);
        }
        Queue = queue ?? new QueueManager(engine, settings: _settings);
        _dispatcher = Dispatcher.CurrentDispatcher;
        Queue.ItemsChanged += () => _dispatcher.BeginInvoke(ReconcileQueueRows);
        Queue.ItemUpdated += OnQueueItemUpdated;

        ParseCommand = new RelayCommand(Parse, () => !IsParsing && UrlText.Trim().Length > 0);
        PasteCommand = new RelayCommand(PasteAndParse);
        CancelParseCommand = new RelayCommand(CancelParse);
        ChooseCandidateCommand = new RelayCommand<VideoCandidate>(Choose);
        BackToListCommand = new RelayCommand(BackToList);
        StartDownloadCommand = new RelayCommand(StartDownload);
        RetryCommand = new RelayCommand(Retry);
        ResetCommand = new RelayCommand(Reset);
        GoLoginCommand = new RelayCommand(OpenLoginForFailure);
        OpenSettingsCommand = new RelayCommand(() => RequestOpenSettings(null));
        ClearFinishedCommand = new RelayCommand(Queue.ClearFinished);
        ToggleQueueCommand = new RelayCommand(ToggleQueue);
        SummarizeCommand = new RelayCommand(SummarizeCurrentVideo);
        CancelSummaryCommand = new RelayCommand(CancelSummary);
        // 语言切换：XAML 的 DynamicResource 自动换装；代码侧派生文案在这里统一重算。
        LocalizationManager.LanguageChanged += OnLanguageChanged;
    }

    // MARK: - 命令

    public RelayCommand ParseCommand { get; }
    public RelayCommand PasteCommand { get; }
    public RelayCommand CancelParseCommand { get; }
    public RelayCommand<VideoCandidate> ChooseCandidateCommand { get; }
    public RelayCommand BackToListCommand { get; }
    public RelayCommand StartDownloadCommand { get; }
    public RelayCommand RetryCommand { get; }
    public RelayCommand ResetCommand { get; }
    public RelayCommand GoLoginCommand { get; }
    public RelayCommand OpenSettingsCommand { get; }
    public RelayCommand ClearFinishedCommand { get; }
    public RelayCommand ToggleQueueCommand { get; }
    public RelayCommand SummarizeCommand { get; }
    public RelayCommand CancelSummaryCommand { get; }

    // MARK: - 阶段与派生状态

    private ParseStage _stage = ParseStage.Idle;
    public ParseStage Stage => _stage;
    public bool IsIdle => _stage == ParseStage.Idle;
    public bool IsLoadingStage => _stage is ParseStage.Resolving or ParseStage.Analyzing;
    public bool IsChoosing => _stage == ParseStage.Choosing;
    public bool IsReady => _stage == ParseStage.Ready;
    public bool IsFailedStage => _stage == ParseStage.Failed;
    public bool IsParsing => IsLoadingStage;
    /// <summary>解析按钮仅在 idle / failed 阶段作为主按钮，其余阶段降级为次按钮。</summary>
    public bool IsParseProminent => _stage is ParseStage.Idle or ParseStage.Failed;
    public bool IsParseSecondary => !IsParseProminent;
    public bool CanReturnToList => _candidates.Count > 1;

    private void SetStage(ParseStage value)
    {
        if (_stage == value) return;
        _stage = value;
        RaisePropertyChanged(nameof(Stage));
        RaisePropertyChanged(nameof(IsIdle));
        RaisePropertyChanged(nameof(IsLoadingStage));
        RaisePropertyChanged(nameof(IsChoosing));
        RaisePropertyChanged(nameof(IsReady));
        RaisePropertyChanged(nameof(IsFailedStage));
        RaisePropertyChanged(nameof(IsParsing));
        RaisePropertyChanged(nameof(IsParseProminent));
        RaisePropertyChanged(nameof(IsParseSecondary));
        RaisePropertyChanged(nameof(CanReturnToList));
        ParseCommand.RaiseCanExecuteChanged();
    }

    // MARK: - 输入与提示

    private string _urlText = "";
    public string UrlText
    {
        get => _urlText;
        set
        {
            if (SetProperty(ref _urlText, value)) ParseCommand.RaiseCanExecuteChanged();
        }
    }

    private string? _enqueueNotice;
    /// <summary>入队成功后的一行轻提示（如「已加入队列」）。</summary>
    public string? EnqueueNotice { get => _enqueueNotice; private set => SetProperty(ref _enqueueNotice, value); }

    private string? _batchStatusText;
    /// <summary>批量粘贴多链接时的进度文案（如「批量解析中（2/5）」）。</summary>
    public string? BatchStatusText
    {
        get => _batchStatusText;
        private set
        {
            if (!SetProperty(ref _batchStatusText, value)) return;
            RaisePropertyChanged(nameof(LoadingText));
            RaisePropertyChanged(nameof(IsBatchLoading));
        }
    }

    public string LoadingText => _batchStatusText ?? Loc.S("L.Loading.Default");
    public bool IsBatchLoading => _batchStatusText is not null;

    // MARK: - 候选列表

    public ObservableCollection<VideoCandidate> Candidates { get; } = [];
    public string ChoosingTitle => Loc.F("L.Choosing.TitleFmt", Candidates.Count);

    private void RefillCandidates()
    {
        Candidates.Clear();
        foreach (var candidate in _candidates) Candidates.Add(candidate);
        RaisePropertyChanged(nameof(ChoosingTitle));
        RaisePropertyChanged(nameof(CanReturnToList));
    }

    // MARK: - ready 页状态

    private VideoInfo? _currentInfo;
    public VideoInfo? CurrentInfo
    {
        get => _currentInfo;
        private set
        {
            if (!SetProperty(ref _currentInfo, value)) return;
            RaisePropertyChanged(nameof(Formats));
            RaisePropertyChanged(nameof(ReadyTitle));
            RaisePropertyChanged(nameof(ReadyMeta));
            RaisePropertyChanged(nameof(ThumbnailUrl));
            RaisePropertyChanged(nameof(HasNoSubtitles));
        }
    }

    public IReadOnlyList<FormatChoice> Formats => _currentInfo?.Formats ?? [];
    public string ReadyTitle => _currentInfo?.Title ?? "";
    public string ReadyMeta => _currentInfo is { } info
        ? string.Join(" · ", new[] { info.DurationText, info.Uploader }.Where(s => !string.IsNullOrEmpty(s)))
        : "";
    public string? ThumbnailUrl => _currentInfo?.ThumbnailUrl;
    public bool HasNoSubtitles => _currentInfo is { } current && current.Subtitles.Count == 0;

    private FormatChoice? _selectedFormat;
    public FormatChoice? SelectedFormat
    {
        get => _selectedFormat;
        set
        {
            if (SetProperty(ref _selectedFormat, value)) RaiseOutputOptionsDerived();
        }
    }

    public ObservableCollection<SubtitleOptionViewModel> SubtitleOptions { get; } = [];

    // MARK: - 输出选项（HDR + 转码格式）

    private bool _preferHdr;
    /// <summary>是否下载 HDR 版本（仅当所选档位提供 HDR 源时可见）。</summary>
    public bool PreferHdr
    {
        get => _preferHdr;
        set
        {
            if (SetProperty(ref _preferHdr, value)) RaisePropertyChanged(nameof(OutputFormatHint));
        }
    }

    /// <summary>所选档位是否提供 HDR 源。</summary>
    public bool HdrAvailable => SelectedFormat?.HdrAvailable ?? false;

    /// <summary>输出格式下拉项（固定四项）。</summary>
    public IReadOnlyList<OutputFormatOption> OutputFormats { get; } =
    [
        new(OutputFormat.Original, "L.Output.Original"),
        new(OutputFormat.Mp4H264, "L.Output.Mp4H264"),
        new(OutputFormat.Mp4H265, "L.Output.Mp4H265"),
        new(OutputFormat.Mkv, "L.Output.Mkv"),
    ];

    private OutputFormatOption? _selectedOutputFormat;
    public OutputFormatOption? SelectedOutputFormat
    {
        get => _selectedOutputFormat ??= OutputFormats[0];
        set
        {
            if (SetProperty(ref _selectedOutputFormat, value)) RaisePropertyChanged(nameof(OutputFormatHint));
        }
    }

    /// <summary>转码提示：选了会丢 HDR 或较慢的组合时提示；否则空。</summary>
    public string OutputFormatHint => (SelectedOutputFormat?.Format ?? OutputFormat.Original) switch
    {
        OutputFormat.Mp4H264 => PreferHdr ? Loc.S("L.Output.HintH264Hdr") : Loc.S("L.Output.HintH264"),
        OutputFormat.Mp4H265 => Loc.S("L.Output.HintH265"),
        _ => "",
    };

    private void RaiseOutputOptionsDerived()
    {
        RaisePropertyChanged(nameof(HdrAvailable));
        RaisePropertyChanged(nameof(OutputFormatHint));
        // 切换档位后，新档位不支持 HDR 时自动关掉偏好。
        if (!HdrAvailable && _preferHdr)
        {
            _preferHdr = false;
            RaisePropertyChanged(nameof(PreferHdr));
        }
    }

    // MARK: - AI 视频总结

    private CancellationTokenSource? _summaryCts;
    private SummaryPhase _summaryState = SummaryPhase.Idle;
    public SummaryPhase SummaryState
    {
        get => _summaryState;
        private set
        {
            if (!SetProperty(ref _summaryState, value)) return;
            RaisePropertyChanged(nameof(SummaryIsIdle));
            RaisePropertyChanged(nameof(SummaryIsRunning));
            RaisePropertyChanged(nameof(SummaryIsDone));
            RaisePropertyChanged(nameof(SummaryIsFailed));
        }
    }

    public bool SummaryIsIdle => _summaryState == SummaryPhase.Idle;
    public bool SummaryIsRunning => _summaryState == SummaryPhase.Running;
    public bool SummaryIsDone => _summaryState == SummaryPhase.Done;
    public bool SummaryIsFailed => _summaryState == SummaryPhase.Failed;

    private string _summaryText = "";
    /// <summary>完成时的总结正文；失败时的错误文案。</summary>
    public string SummaryText
    {
        get => _summaryText;
        private set => SetProperty(ref _summaryText, value);
    }

    /// <summary>总结是否可用：需要配置好可生成文本的云端服务，可跟随默认 AI 或单独覆盖。</summary>
    public bool SummaryAvailable => Settings.IsSummaryConfigured;

    /// <summary>不可用原因（用于 idle 态提示）；可用时空。</summary>
    public string SummaryUnavailableReason =>
        SummaryAvailable ? "" : Loc.S("L.Summary.Unconfigured");

    /// <summary>对当前 Ready 视频做 AI 总结：优先现拉字幕文本，拿不到回退视频简介。</summary>
    public async void SummarizeCurrentVideo()
    {
        if (_stage != ParseStage.Ready || _currentInfo is not { } info) return;
        if (!SummaryAvailable)
        {
            SummaryText = Loc.S("L.Summary.Unconfigured");
            SummaryState = SummaryPhase.Failed;
            return;
        }
        _summaryCts?.Cancel();
        var cts = new CancellationTokenSource();
        _summaryCts = cts;
        var session = _session;
        SummaryState = SummaryPhase.Running;
        var settings = Settings;
        var preferredLangs = info.Subtitles.Select(s => s.Id).ToList();
        try
        {
            // 优先字幕文本；最佳努力，失败/无字幕回退简介。
            string? subtitleText = null;
            try
            {
                subtitleText = await _engine.FetchSubtitleTextAsync(
                    info.SourceUrl, preferredLangs, control: null, cts.Token).ConfigureAwait(true);
            }
            catch (MoongateException) { /* 回退简介 */ }
            if (cts.IsCancellationRequested || session != _session) return;
            var source = !string.IsNullOrEmpty(subtitleText) ? subtitleText : info.Description;
            var summary = await TranslationApi.SummarizeVideoAsync(
                info.Title, info.Uploader, info.DurationText, source, settings.ForSummary(), handler: null, cts.Token)
                .ConfigureAwait(true);
            if (cts.IsCancellationRequested || session != _session) return;
            SummaryText = summary;
            SummaryState = SummaryPhase.Done;
        }
        catch (OperationCanceledException) { /* 取消：保持当前态 */ }
        catch (MoongateException e)
        {
            if (cts.IsCancellationRequested || session != _session) return;
            SummaryText = e.Message;
            SummaryState = SummaryPhase.Failed;
        }
        catch (Exception e)
        {
            if (cts.IsCancellationRequested || session != _session) return;
            SummaryText = e.Message;
            SummaryState = SummaryPhase.Failed;
        }
    }

    public void CancelSummary()
    {
        _summaryCts?.Cancel();
        _summaryCts = null;
        SummaryText = "";
        SummaryState = SummaryPhase.Idle;
    }

    private void ResetSummary()
    {
        _summaryCts?.Cancel();
        _summaryCts = null;
        SummaryText = "";
        _summaryState = SummaryPhase.Idle;
        RaisePropertyChanged(nameof(SummaryIsIdle));
        RaisePropertyChanged(nameof(SummaryIsRunning));
        RaisePropertyChanged(nameof(SummaryIsDone));
        RaisePropertyChanged(nameof(SummaryIsFailed));
        RaisePropertyChanged(nameof(SummaryAvailable));
        RaisePropertyChanged(nameof(SummaryUnavailableReason));
    }

    // MARK: - 字幕处理

    private ChineseSubtitleMode _chineseMode = ChineseSubtitleMode.Off;
    public ChineseSubtitleMode ChineseMode
    {
        get => _chineseMode;
        set
        {
            if (SetProperty(ref _chineseMode, value)) RaiseChineseDerived();
        }
    }

    public bool ChineseModeOff
    {
        get => _chineseMode == ChineseSubtitleMode.Off;
        set { if (value) ChineseMode = ChineseSubtitleMode.Off; }
    }

    public bool ChineseModeSrtOnly
    {
        get => _chineseMode == ChineseSubtitleMode.SrtOnly;
        set { if (value) ChineseMode = ChineseSubtitleMode.SrtOnly; }
    }

    public bool ChineseModeBurnIn
    {
        get => _chineseMode == ChineseSubtitleMode.BurnIn;
        set { if (value) ChineseMode = ChineseSubtitleMode.BurnIn; }
    }

    public bool ChineseModeBurnOriginal
    {
        get => _chineseMode == ChineseSubtitleMode.BurnOriginal;
        set { if (value) ChineseMode = ChineseSubtitleMode.BurnOriginal; }
    }

    /// <summary>需要翻译服务的模式（直压 BurnOriginal 与关闭不需要）。</summary>
    private static bool RequiresTranslation(ChineseSubtitleMode mode) =>
        mode is ChineseSubtitleMode.SrtOnly or ChineseSubtitleMode.BurnIn;

    public bool HasSubtitleSelected => SubtitleOptions.Any(option => option.IsSelected);
    public bool ChineseModeEnabled => HasSubtitleSelected;

    /// <summary>勾选多条字幕时实际作为翻译源的那条（真实字幕优先、按解析顺序取第一条）。</summary>
    private SubtitleChoice? TranslationSourceSubtitle()
    {
        if (_currentInfo is not { } info) return null;
        var selectedIds = SubtitleOptions.Where(option => option.IsSelected).Select(option => option.Id).ToHashSet();
        var chosen = info.Subtitles.Where(subtitle => selectedIds.Contains(subtitle.Id)).ToList();
        return chosen.FirstOrDefault(subtitle => !subtitle.IsAuto) ?? chosen.FirstOrDefault();
    }

    /// <summary>实际翻译源字幕是否已与翻译目标语言同一脚本（同则跳过翻译、直接使用/烧录）。</summary>
    private bool TranslationSourceMatchesTarget()
    {
        var source = TranslationSourceSubtitle();
        if (source is null) return false;
        return TranslationLanguage.Matches(source.Id, Settings.TranslationTargetLanguage);
    }

    public string? ChineseHintText
    {
        get
        {
            if (!HasSubtitleSelected) return Loc.S("L.Hint.SelectSubtitleFirst");
            if (ShowTranslationUnconfigured) return null;
            if (_chineseMode != ChineseSubtitleMode.Off
                && SubtitleOptions.Count(option => option.IsSelected) > 1
                && TranslationSourceSubtitle() is { } source)
            {
                // 直压模式不翻译，提示「将烧录」；翻译类模式提示「将翻译」
                return _chineseMode == ChineseSubtitleMode.BurnOriginal
                    ? Loc.F("L.Hint.WillBurnFmt", source.Label)
                    : Loc.F("L.Hint.WillTranslateFmt", source.Label);
            }
            return null;
        }
    }

    public bool ShowTranslationUnconfigured =>
        HasSubtitleSelected && !Settings.IsTranslationConfigured
        && _chineseMode != ChineseSubtitleMode.BurnOriginal;

    /// <summary>翻译类模式下源字幕已是中文的提示；直压模式本就不翻译，无需提示。</summary>
    public string? ChineseSourceNote =>
        _chineseMode is ChineseSubtitleMode.SrtOnly or ChineseSubtitleMode.BurnIn && TranslationSourceMatchesTarget()
            ? (_chineseMode == ChineseSubtitleMode.BurnIn
                ? Loc.S("L.Hint.ChineseSourceBurn")
                : Loc.S("L.Hint.ChineseSourceUse"))
            : null;

    private void RaiseChineseDerived()
    {
        RaisePropertyChanged(nameof(ChineseModeOff));
        RaisePropertyChanged(nameof(ChineseModeSrtOnly));
        RaisePropertyChanged(nameof(ChineseModeBurnIn));
        RaisePropertyChanged(nameof(ChineseModeBurnOriginal));
        RaisePropertyChanged(nameof(HasSubtitleSelected));
        RaisePropertyChanged(nameof(ChineseModeEnabled));
        RaisePropertyChanged(nameof(ChineseHintText));
        RaisePropertyChanged(nameof(ShowTranslationUnconfigured));
        RaisePropertyChanged(nameof(ChineseSourceNote));
    }

    internal void OnSubtitleSelectionChanged()
    {
        // 字幕处理依赖至少勾选一条字幕；全部取消勾选时强制回「不需要」
        if (!HasSubtitleSelected && _chineseMode != ChineseSubtitleMode.Off)
        {
            ChineseMode = ChineseSubtitleMode.Off;
            return;
        }
        RaiseChineseDerived();
    }

    // MARK: - 设置

    private AppSettings _settings;
    public AppSettings Settings
    {
        get => _settings;
        set
        {
            _settings = value;
            Queue.SyncConcurrency(value);
            RaisePropertyChanged();
            RaiseChineseDerived();
            RaisePropertyChanged(nameof(SummaryAvailable));
            RaisePropertyChanged(nameof(SummaryUnavailableReason));
        }
    }

    private void RequestOpenSettings(string? notice)
    {
        _pendingSettingsNotice = notice;
        OpenSettingsRequested?.Invoke();
    }

    /// <summary>设置窗打开时取走待显示的提示（如「请先配置翻译服务」）。</summary>
    public string? ConsumePendingSettingsNotice()
    {
        var notice = _pendingSettingsNotice;
        _pendingSettingsNotice = null;
        return notice;
    }

    // MARK: - failed 页状态

    private string _failedHeadline = "";
    public string FailedHeadline { get => _failedHeadline; private set => SetProperty(ref _failedHeadline, value); }

    private string _failedDetail = "";
    public string FailedDetail { get => _failedDetail; private set => SetProperty(ref _failedDetail, value); }

    private string? _failedNeedsLogin;
    /// <summary>失败原因是需要登录时记录站点，failed 页据此把主按钮换成「去登录」。</summary>
    public string? FailedNeedsLogin
    {
        get => _failedNeedsLogin;
        private set
        {
            if (!SetProperty(ref _failedNeedsLogin, value)) return;
            RaisePropertyChanged(nameof(ShowGoLogin));
            RaisePropertyChanged(nameof(ShowRetryPrimary));
            RaisePropertyChanged(nameof(ShowRetrySecondary));
        }
    }

    public bool ShowGoLogin => _failedNeedsLogin is not null;
    public bool ShowRetryPrimary => _failedNeedsLogin is null;
    public bool ShowRetrySecondary => _failedNeedsLogin is not null;

    /// <summary>两段式错误：第一行为中文主句，其余为原始错误详情，UI 分层展示。</summary>
    private void SetFailed(string message)
    {
        var index = message.IndexOf('\n');
        FailedHeadline = index < 0 ? message : message[..index];
        FailedDetail = index < 0 ? "" : message[(index + 1)..].Trim();
        SetStage(ParseStage.Failed);
    }

    private void Fail(Exception error, Action retry)
    {
        _retryAction = retry;
        FailedNeedsLogin = error is MoongateException { Kind: MoongateErrorKind.LoginRequired } mge ? mge.Detail : null;
        SetFailed(error.Message);
    }

    // MARK: - 行为：解析

    public void Parse()
    {
        var input = UrlText.Trim();
        if (input.Length == 0 || IsParsing) return;

        // 一次粘贴多条链接：逐个解析并按默认选项（最高画质）自动加入队列
        var urls = ExtractUrls(input);
        if (urls.Count > 1)
        {
            ProcessBatch(urls);
            return;
        }

        if (!IsValidHttpUrl(input))
        {
            _session++;
            _retryAction = null;
            FailedNeedsLogin = null;
            SetFailed(Loc.S("L.Error.NotAUrl"));
            return;
        }
        _session++;
        var token = _session;
        _retryAction = null;
        FailedNeedsLogin = null;
        EnqueueNotice = null;
        _chosenCandidate = null;
        SetStage(ParseStage.Resolving);
        var ct = RestartParseCts();
        _ = ResolveAsync(token, input, ct);
    }

    private async Task ResolveAsync(int token, string input, CancellationToken ct)
    {
        try
        {
            var found = await _engine.ResolveCandidatesAsync(input, ct);
            if (token != _session) return;
            if (found.Count == 0) throw MoongateException.SniffFailed("");
            _candidates = [.. found];
            if (found.Count == 1)
            {
                Choose(found[0]);
            }
            else
            {
                RefillCandidates();
                SetStage(ParseStage.Choosing);
            }
        }
        catch (Exception error)
        {
            if (token != _session) return;
            Fail(error, Parse);
        }
    }

    public void Choose(VideoCandidate candidate)
    {
        _session++;
        var token = _session;
        _retryAction = null;
        FailedNeedsLogin = null;
        _chosenCandidate = candidate;
        SetStage(ParseStage.Analyzing);
        var ct = RestartParseCts();
        _ = AnalyzeAsync(token, candidate, ct);
    }

    private async Task AnalyzeAsync(int token, VideoCandidate candidate, CancellationToken ct)
    {
        try
        {
            var info = await _engine.AnalyzeAsync(candidate.Url, ct);
            info = PreferCandidateTitle(info, candidate);
            if (token != _session) return;
            ShowReady(info);
        }
        catch (Exception error)
        {
            if (token != _session) return;
            Fail(error, () => Choose(candidate));
        }
    }

    /// <summary>直链/页面主视频的 yt-dlp 标题往往是 CDN 文件名，换成嗅探到的页面标题。</summary>
    private static VideoInfo PreferCandidateTitle(VideoInfo info, VideoCandidate candidate)
    {
        var isPage = candidate.Kind is VideoCandidate.CandidateKind.PageMain or VideoCandidate.CandidateKind.DirectFile;
        if (isPage && candidate.Title.Length > 0 && candidate.Title != info.Title)
        {
            return info with { Title = candidate.Title };
        }
        return info;
    }

    private void ShowReady(VideoInfo info)
    {
        CurrentInfo = info;
        SelectedFormat = info.Formats.FirstOrDefault();
        SubtitleOptions.Clear();
        foreach (var subtitle in info.Subtitles)
        {
            SubtitleOptions.Add(new SubtitleOptionViewModel(this, subtitle));
        }
        RestoreLastDownloadOptions(info);
        ResetSummary();
        SetStage(ParseStage.Ready);
        RaiseChineseDerived();
    }

    /// <summary>
    /// 选档页恢复上次下载选项（PARITY-002，与 macOS 一致）：输出格式 / HDR 直接套用；
    /// 字幕按语言代码在本视频可用字幕里匹配（真实字幕优先）；字幕处理方式在字幕恢复之后再设，
    /// 避免勾选回调把它打回「不需要」。
    /// </summary>
    private void RestoreLastDownloadOptions(VideoInfo info)
    {
        _preferHdr = Settings.LastPreferHdr && (SelectedFormat?.HdrAvailable ?? false);
        RaisePropertyChanged(nameof(PreferHdr));
        SelectedOutputFormat = OutputFormats.FirstOrDefault(o => o.Format == OutputFormatFromRaw(Settings.LastOutputFormat))
            ?? OutputFormats[0];

        var wantedLangs = Settings.LastSubtitleLangs.Select(NormalizedLang).ToHashSet();
        var matchedAny = false;
        if (wantedLangs.Count > 0)
        {
            foreach (var lang in wantedLangs)
            {
                var group = SubtitleOptions.Where(o => NormalizedLang(o.Id) == lang).ToList();
                var best = group.FirstOrDefault(o => !o.IsAuto) ?? group.FirstOrDefault();
                if (best is not null)
                {
                    best.IsSelected = true;
                    matchedAny = true;
                }
            }
        }
        // 仅当字幕成功恢复、且记录的处理方式不是「不需要」时才恢复 mode（否则保持 Off）。
        var savedMode = ChineseModeFromRaw(Settings.LastSubtitleMode);
        _chineseMode = matchedAny && savedMode != ChineseSubtitleMode.Off ? savedMode : ChineseSubtitleMode.Off;
    }

    /// <summary>字幕 id 归一成语言代码：小写、取首个 '-' 前的部分（"ja-JP"/"ja-orig" → "ja"）。</summary>
    private static string NormalizedLang(string id)
    {
        var lower = id.ToLowerInvariant();
        var dash = lower.IndexOf('-');
        return dash >= 0 ? lower[..dash] : lower;
    }

    private static string ChineseModeRaw(ChineseSubtitleMode mode) => mode switch
    {
        ChineseSubtitleMode.SrtOnly => "srtOnly",
        ChineseSubtitleMode.BurnIn => "burnIn",
        ChineseSubtitleMode.BurnOriginal => "burnOriginal",
        _ => "off",
    };

    private static ChineseSubtitleMode ChineseModeFromRaw(string? raw) => raw switch
    {
        "srtOnly" => ChineseSubtitleMode.SrtOnly,
        "burnIn" => ChineseSubtitleMode.BurnIn,
        "burnOriginal" => ChineseSubtitleMode.BurnOriginal,
        _ => ChineseSubtitleMode.Off,
    };

    private static string OutputFormatRaw(OutputFormat format) => format switch
    {
        OutputFormat.Mp4H264 => "mp4H264",
        OutputFormat.Mp4H265 => "mp4H265",
        OutputFormat.Mkv => "mkv",
        _ => "original",
    };

    private static OutputFormat OutputFormatFromRaw(string? raw) => raw switch
    {
        "mp4H264" => OutputFormat.Mp4H264,
        "mp4H265" => OutputFormat.Mp4H265,
        "mkv" => OutputFormat.Mkv,
        _ => OutputFormat.Original,
    };

    /// <summary>把当前选档页的选择记住为「上次下载选项」（无变化不写盘）。</summary>
    private void PersistLastDownloadOptions()
    {
        var selectedIds = SubtitleOptions.Where(o => o.IsSelected).Select(o => o.Id).ToList();
        var mode = ChineseModeRaw(_chineseMode);
        var format = OutputFormatRaw(SelectedOutputFormat?.Format ?? OutputFormat.Original);
        if (mode == Settings.LastSubtitleMode
            && format == Settings.LastOutputFormat
            && _preferHdr == Settings.LastPreferHdr
            && selectedIds.SequenceEqual(Settings.LastSubtitleLangs))
        {
            return;
        }
        var updated = Settings with
        {
            LastSubtitleMode = mode,
            LastSubtitleLangs = selectedIds,
            LastOutputFormat = format,
            LastPreferHdr = _preferHdr,
        };
        try
        {
            updated.Save();
            Settings = updated;
        }
        catch
        {
            // 记忆上次选项失败不影响本次下载。
        }
    }

    public void CancelParse()
    {
        switch (_stage)
        {
            case ParseStage.Resolving:
                _session++;
                _parseCts?.Cancel();
                BatchStatusText = null;
                SetStage(ParseStage.Idle);
                break;
            case ParseStage.Analyzing:
                _session++;
                _parseCts?.Cancel();
                if (_candidates.Count > 1)
                {
                    RefillCandidates();
                    SetStage(ParseStage.Choosing);
                }
                else
                {
                    SetStage(ParseStage.Idle);
                }
                break;
        }
    }

    public void BackToList()
    {
        if (_candidates.Count <= 1) return;
        _session++;
        _parseCts?.Cancel();
        _retryAction = null;
        FailedNeedsLogin = null;
        RefillCandidates();
        SetStage(ParseStage.Choosing);
    }

    public void Retry()
    {
        if (_stage != ParseStage.Failed) return;
        if (_retryAction is { } action) action();
        else Reset();
    }

    public void Reset()
    {
        _session++;
        _parseCts?.Cancel();
        UrlText = "";
        CurrentInfo = null;
        SelectedFormat = null;
        _preferHdr = false;
        RaisePropertyChanged(nameof(PreferHdr));
        SelectedOutputFormat = OutputFormats[0];
        ResetSummary();
        SubtitleOptions.Clear();
        _chineseMode = ChineseSubtitleMode.Off;
        _candidates = [];
        Candidates.Clear();
        _chosenCandidate = null;
        _retryAction = null;
        FailedNeedsLogin = null;
        EnqueueNotice = null;
        SetStage(ParseStage.Idle);
        RaiseChineseDerived();
        FocusUrlRequested?.Invoke();
    }

    // MARK: - 行为：批量入队

    /// <summary>批量模式：逐个解析（多候选页取第一个，即页面主视频），按最高画质自动入队。
    /// 当前已选字幕处理模式会沿用，并自动挑一条字幕作翻译源（真实字幕优先）。</summary>
    private void ProcessBatch(List<string> urls)
    {
        var mode = _chineseMode;
        if (RequiresTranslation(mode) && !Settings.IsTranslationConfigured)
        {
            RequestOpenSettings(Loc.S("L.Notice.ConfigureTranslationFirst"));
            return;
        }
        _session++;
        var token = _session;
        _retryAction = null;
        FailedNeedsLogin = null;
        EnqueueNotice = null;
        _candidates = [];
        _chosenCandidate = null;
        SetStage(ParseStage.Resolving);
        var settings = Settings;
        var ct = RestartParseCts();
        _ = RunBatchAsync(token, urls, mode, settings, ct);
    }

    private async Task RunBatchAsync(
        int token, List<string> urls, ChineseSubtitleMode mode, AppSettings settings, CancellationToken ct)
    {
        var added = 0;
        var duplicated = 0;
        var failedHosts = new List<string>();
        for (var index = 0; index < urls.Count; index++)
        {
            if (token != _session) return;
            BatchStatusText = Loc.F("L.Loading.BatchFmt", index + 1, urls.Count);
            var urlString = urls[index];
            try
            {
                var found = await _engine.ResolveCandidatesAsync(urlString, ct);
                if (token != _session) return;
                var candidate = found.FirstOrDefault() ?? throw MoongateException.SniffFailed("");
                var info = await _engine.AnalyzeAsync(candidate.Url, ct);
                if (token != _session) return;
                info = PreferCandidateTitle(info, candidate);
                var formatId = info.Formats.FirstOrDefault()?.Id
                    ?? throw MoongateException.AnalyzeFailed(Loc.T("L.Error.NoAvailableFormat"));
                if (Queue.HasOpenDuplicate(info.VideoId, info.SourceUrl, formatId))
                {
                    duplicated++;
                    continue;
                }
                // 字幕处理开启时自动选一条字幕作翻译源（真实字幕优先）
                var subtitleLangs = new List<string>();
                var autoSubtitleLangs = new List<string>();
                if (mode != ChineseSubtitleMode.Off)
                {
                    var sub = info.Subtitles.FirstOrDefault(s => !s.IsAuto) ?? info.Subtitles.FirstOrDefault();
                    if (sub is not null)
                    {
                        if (sub.IsAuto) autoSubtitleLangs.Add(sub.Id);
                        else subtitleLangs.Add(sub.Id);
                    }
                }
                var multiFile = mode != ChineseSubtitleMode.Off
                    || subtitleLangs.Count > 0 || autoSubtitleLangs.Count > 0;
                var isPage = candidate.Kind is VideoCandidate.CandidateKind.PageMain
                    or VideoCandidate.CandidateKind.DirectFile;
                var request = new DownloadRequest
                {
                    Url = info.SourceUrl,
                    VideoId = info.VideoId,
                    FormatId = formatId,
                    SubtitleLangs = subtitleLangs,
                    AutoSubtitleLangs = autoSubtitleLangs,
                    DestinationDirectory = DownloadPaths.DestinationDirectory(info.Title, multiFile),
                    PreferredTitle = isPage ? info.Title : null,
                };
                Queue.Enqueue(info, request, mode, settings);
                added++;
            }
            catch (OperationCanceledException)
            {
                return;
            }
            catch (Exception error)
            {
                if (token != _session) return;
                if (error is MoongateException { Kind: MoongateErrorKind.Cancelled }) return;
                failedHosts.Add(Uri.TryCreate(urlString, UriKind.Absolute, out var url) ? url.Host : urlString);
            }
        }
        if (token != _session) return;
        BatchStatusText = null;
        UrlText = "";
        SelectedFormat = null;
        SubtitleOptions.Clear();
        _chineseMode = ChineseSubtitleMode.Off;
        SetStage(ParseStage.Idle);
        RaiseChineseDerived();
        var parts = new List<string> { Loc.F("L.Notice.BatchAddedFmt", added) };
        if (duplicated > 0) parts.Add(Loc.F("L.Notice.BatchDupFmt", duplicated));
        if (failedHosts.Count > 0)
        {
            var sample = string.Join(Loc.S("L.Notice.ListSep"), failedHosts.Take(2));
            parts.Add(Loc.F("L.Notice.BatchFailedFmt", failedHosts.Count,
                sample + (failedHosts.Count > 2 ? Loc.S("L.Notice.BatchFailedEtc") : "")));
        }
        EnqueueNotice = string.Join(Loc.S("L.Notice.JoinSep"), parts);
        if (added > 0) PeekQueue();
        FocusUrlRequested?.Invoke();
    }

    // MARK: - 行为：入队

    /// <summary>ready 页「加入队列」：构造 DownloadRequest 入队，然后清空回可输入态以便继续添加下一条。</summary>
    public void StartDownload()
    {
        if (_stage != ParseStage.Ready || _currentInfo is not { } info) return;
        if (RequiresTranslation(_chineseMode) && !Settings.IsTranslationConfigured)
        {
            RequestOpenSettings(Loc.S("L.Notice.ConfigureTranslationFirst"));
            return;
        }
        var formatId = (SelectedFormat ?? info.Formats.FirstOrDefault())?.Id;
        if (formatId is null) return;
        // 去重：队列里已有同源未完成任务时不再起新任务，只给一行提示。
        if (Queue.HasOpenDuplicate(info.VideoId, info.SourceUrl, formatId))
        {
            EnqueueNotice = Loc.S("L.Notice.Duplicate");
            return;
        }
        var chosen = SubtitleOptions.Where(option => option.IsSelected).ToList();
        // 会产出多个文件（字幕 / 翻译 / 烧录件）时按视频建独立文件夹；单视频直接放 Downloads。
        var multiFile = chosen.Count > 0 || _chineseMode != ChineseSubtitleMode.Off;
        var isPage = _chosenCandidate?.Kind is VideoCandidate.CandidateKind.PageMain
            or VideoCandidate.CandidateKind.DirectFile;
        var request = new DownloadRequest
        {
            Url = info.SourceUrl,
            VideoId = info.VideoId,
            FormatId = formatId,
            SubtitleLangs = chosen.Where(option => !option.IsAuto).Select(option => option.Id).ToList(),
            AutoSubtitleLangs = chosen.Where(option => option.IsAuto).Select(option => option.Id).ToList(),
            DestinationDirectory = DownloadPaths.DestinationDirectory(info.Title, multiFile),
            PreferredTitle = isPage ? info.Title : null,
            PreferHdr = _preferHdr && (SelectedFormat?.HdrAvailable ?? false),
            OutputFormat = SelectedOutputFormat?.Format ?? OutputFormat.Original,
        };
        Queue.Enqueue(info, request, _chineseMode, Settings);
        PersistLastDownloadOptions();
        PeekQueue();

        // 回到可输入态，方便粘贴下一条
        _session++;
        _parseCts?.Cancel();
        UrlText = "";
        CurrentInfo = null;
        SelectedFormat = null;
        _preferHdr = false;
        RaisePropertyChanged(nameof(PreferHdr));
        SelectedOutputFormat = OutputFormats[0];
        ResetSummary();
        SubtitleOptions.Clear();
        _chineseMode = ChineseSubtitleMode.Off;
        _candidates = [];
        Candidates.Clear();
        _chosenCandidate = null;
        _retryAction = null;
        FailedNeedsLogin = null;
        EnqueueNotice = Loc.F("L.Notice.EnqueuedFmt", info.Title);
        SetStage(ParseStage.Idle);
        RaiseChineseDerived();
        FocusUrlRequested?.Invoke();
    }

    // MARK: - 行为：剪贴板

    /// <summary>窗口出现或激活时：处于可输入阶段且输入框为空，用剪贴板里的链接预填（不自动解析）。</summary>
    public void PrefillFromClipboardIfAppropriate()
    {
        if (_stage is not (ParseStage.Idle or ParseStage.Ready)) return;
        if (UrlText.Length > 0) return;
        var clip = TryReadClipboardText().Trim();
        if (!clip.StartsWith("http", StringComparison.OrdinalIgnoreCase)) return;
        UrlText = clip;
    }

    /// <summary>「粘贴」按钮：取剪贴板内容直接开始解析（多链接自动批量入队）。</summary>
    public void PasteAndParse()
    {
        var clip = TryReadClipboardText().Trim();
        if (clip.Length == 0) return;
        UrlText = clip;
        Parse();
    }

    private static string TryReadClipboardText()
    {
        // 剪贴板被其他进程占用时 GetText 可能抛 COMException，拿不到就当没有。
        try { return Clipboard.ContainsText() ? Clipboard.GetText() : ""; }
        catch { return ""; }
    }

    // MARK: - 行为：站点登录

    /// <summary>failed 页点「去登录」。</summary>
    public void OpenLoginForFailure()
    {
        if (_failedNeedsLogin is { } site) OpenLoginRequested?.Invoke(site);
    }

    /// <summary>登录窗导出 cookies 成功后调用：自动重试上次失败的操作。</summary>
    public void LoginCompleted()
    {
        if (_stage == ParseStage.Failed && _retryAction is { } action) action();
    }

    // MARK: - 关窗确认

    /// <summary>关窗确认文案：队列里有未到终态（含已暂停）的任务时给出提示，否则返回 null。</summary>
    public string? AbortConfirmationMessage()
    {
        var count = Queue.OpenTaskCount;
        if (count == 0) return null;
        var paused = Queue.PausedOpenTaskCount;
        return paused > 0
            ? Loc.F("L.Confirm.ClosePausedFmt", count, paused)
            : Loc.F("L.Confirm.CloseFmt", count);
    }

    /// <summary>中止队列所有进行中的任务。</summary>
    public void AbortAllTasks()
    {
        foreach (var item in Queue.Items) Queue.Cancel(item.Id);
    }

    // MARK: - 队列行（事件封送 + 增量更新）

    public ObservableCollection<QueueItemViewModel> QueueRows { get; } = [];

    // MARK: 队列折叠 / 摘要

    private bool _isQueueExpanded;
    /// <summary>队列面板展开态。默认收起为摘要栏；入队时短暂探出（peek）。</summary>
    public bool IsQueueExpanded { get => _isQueueExpanded; private set => SetProperty(ref _isQueueExpanded, value); }

    private string _queueSummary = "";
    /// <summary>摘要栏文案："2 个进行中 · 1 个已完成" / "全部完成"。</summary>
    public string QueueSummary { get => _queueSummary; private set => SetProperty(ref _queueSummary, value); }

    /// <summary>用户手动展开 → 钉住：入队探出不再自动收起，直到用户手动收起。</summary>
    private bool _queuePinnedOpen;
    private DispatcherTimer? _queuePeekTimer;

    public void ToggleQueue()
    {
        _queuePeekTimer?.Stop();
        if (IsQueueExpanded)
        {
            _queuePinnedOpen = false;
            IsQueueExpanded = false;
        }
        else
        {
            _queuePinnedOpen = true;
            IsQueueExpanded = true;
        }
    }

    /// <summary>
    /// 入队后短暂展开队列再自动收起（约 1.8s）：用户能看到任务确实落进了队列，
    /// 主界面又不被长队列挤占。用户钉住展开时保持展开不打扰。
    /// </summary>
    private void PeekQueue()
    {
        if (_queuePinnedOpen && IsQueueExpanded) return;
        IsQueueExpanded = true;
        _queuePeekTimer?.Stop();
        var timer = new DispatcherTimer(DispatcherPriority.Normal, _dispatcher)
        {
            Interval = TimeSpan.FromMilliseconds(1800),
        };
        _queuePeekTimer = timer;
        timer.Tick += (_, _) =>
        {
            timer.Stop();
            if (_queuePeekTimer == timer && !_queuePinnedOpen)
            {
                IsQueueExpanded = false;
            }
        };
        timer.Start();
    }

    private void RefreshQueueSummary()
    {
        var total = Queue.Items.Count;
        if (total == 0)
        {
            QueueSummary = "";
            return;
        }
        var open = Queue.OpenTaskCount;
        var finished = total - open;
        if (open == 0)
        {
            QueueSummary = Loc.S("L.Queue.AllDone");
            return;
        }
        var summary = Loc.F("L.Queue.ActiveFmt", open);
        if (finished > 0)
        {
            summary += Loc.S("L.Queue.SummarySep") + Loc.F("L.Queue.FinishedFmt", finished);
        }
        QueueSummary = summary;
    }

    /// <summary>语言切换：重算代码侧派生文案并刷新队列行（XAML 文案由 DynamicResource 自动换）。</summary>
    private void OnLanguageChanged()
    {
        RaisePropertyChanged(nameof(LoadingText));
        RaisePropertyChanged(nameof(ChoosingTitle));
        RaiseChineseDerived();
        RefreshQueueSummary();
        foreach (var row in QueueRows)
        {
            row.Refresh(Queue.Item(row.Id));
        }
    }

    private bool _hasQueueItems;
    public bool HasQueueItems { get => _hasQueueItems; private set => SetProperty(ref _hasQueueItems, value); }

    private bool _hasFinishedItems;
    public bool HasFinishedItems { get => _hasFinishedItems; private set => SetProperty(ref _hasFinishedItems, value); }

    private void OnQueueItemUpdated(Guid id)
    {
        lock (_updateLock)
        {
            _pendingUpdates.Add(id);
            if (_updateScheduled) return;
            _updateScheduled = true;
        }
        _dispatcher.BeginInvoke(DrainQueueUpdates);
    }

    private void DrainQueueUpdates()
    {
        Guid[] ids;
        lock (_updateLock)
        {
            ids = [.. _pendingUpdates];
            _pendingUpdates.Clear();
            _updateScheduled = false;
        }
        foreach (var id in ids)
        {
            var row = QueueRows.FirstOrDefault(r => r.Id == id);
            row?.Refresh(Queue.Item(id));
        }
        HasFinishedItems = Queue.HasFinishedItems;
        RefreshQueueSummary();
    }

    /// <summary>按队列快照增量对账：保留既有行（避免进度条/按钮状态闪烁），只增删移动。</summary>
    private void ReconcileQueueRows()
    {
        var items = Queue.Items;
        for (var i = QueueRows.Count - 1; i >= 0; i--)
        {
            var id = QueueRows[i].Id;
            if (!items.Any(item => item.Id == id)) QueueRows.RemoveAt(i);
        }
        for (var i = 0; i < items.Count; i++)
        {
            var item = items[i];
            var existing = -1;
            for (var j = 0; j < QueueRows.Count; j++)
            {
                if (QueueRows[j].Id == item.Id) { existing = j; break; }
            }
            if (existing < 0)
            {
                QueueRows.Insert(Math.Min(i, QueueRows.Count), new QueueItemViewModel(Queue, item));
            }
            else if (existing != i && i < QueueRows.Count)
            {
                QueueRows.Move(existing, i);
            }
        }
        HasQueueItems = QueueRows.Count > 0;
        HasFinishedItems = Queue.HasFinishedItems;
        RefreshQueueSummary();
    }

    // MARK: - 工具

    private CancellationToken RestartParseCts()
    {
        _parseCts?.Cancel();
        _parseCts = new CancellationTokenSource();
        return _parseCts.Token;
    }

    private static bool IsValidHttpUrl(string input) =>
        Uri.TryCreate(input, UriKind.Absolute, out var url)
        && (url.Scheme == "http" || url.Scheme == "https")
        && !string.IsNullOrEmpty(url.Host);

    private static readonly char[] TrailingPunctuation =
        [',', ';', '，', '；', '、', '。', '.', ')', '）', ']', '》', '〉', '>', '」', '』', '"', '\''];

    /// <summary>从粘贴文本里提取全部 http(s) 链接，保序去重（统一走 Core 的 UrlTokenizer，与 macOS 同构）。</summary>
    internal static List<string> ExtractUrls(string input) => UrlTokenizer.Extract(input);
}

/// <summary>字幕多选里的一行。勾选状态变化回调主视图模型以联动字幕处理分组。</summary>
public sealed class SubtitleOptionViewModel : ObservableObject
{
    private readonly MainViewModel _owner;
    public string Id { get; }
    public string Label { get; }
    public bool IsAuto { get; }

    private bool _isSelected;
    public bool IsSelected
    {
        get => _isSelected;
        set
        {
            if (SetProperty(ref _isSelected, value)) _owner.OnSubtitleSelectionChanged();
        }
    }

    public SubtitleOptionViewModel(MainViewModel owner, SubtitleChoice choice)
    {
        _owner = owner;
        Id = choice.Id;
        Label = choice.Label;
        IsAuto = choice.IsAuto;
    }
}

/// <summary>AI 总结状态机。</summary>
public enum SummaryPhase
{
    Idle,
    Running,
    Done,
    Failed,
}

/// <summary>输出格式下拉项：把 OutputFormat 包成带本地化显示名的可绑定项。</summary>
public sealed class OutputFormatOption(OutputFormat format, string labelKey)
{
    public OutputFormat Format { get; } = format;
    private readonly string _labelKey = labelKey;
    public string Label => Loc.S(_labelKey);
}
