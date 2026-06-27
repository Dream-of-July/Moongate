using System.Collections.ObjectModel;
using System.IO;
using System.Media;
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
public sealed class MainViewModel : ObservableObject, IQueueCompletionNotifier
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
    /// <summary>请求弹出站点验证窗（参数为站点 host 与可选起始 URL）。</summary>
    public event Action<string, string?>? OpenLoginRequested;

    public MainViewModel() : this(new YtDlpEngine(), null) { }

    public MainViewModel(IDownloadEngine engine, QueueManager? queue)
    {
        _engine = engine;
        _settings = AppSettings.Load();
        _dispatcher = Dispatcher.CurrentDispatcher;
        // 设置文件损坏被备份时（DATA-SETTINGS-002），给一次非阻断提示，而不是静默回默认。
        if (AppSettings.LastCorruptBackupPath is { } corruptBackup)
        {
            AppSettings.LastCorruptBackupPath = null;
            _enqueueNotice = Loc.F("L.Settings.CorruptResetFmt", corruptBackup);
        }
        var localAsrGenerator = LocalAsrGeneratorFactory.Create(_settings);
        Queue = queue ?? new QueueManager(
            engine,
            settings: _settings,
            localAsrGenerator: localAsrGenerator,
            cloudAsrGenerator: CloudAsrGeneratorFactory.Create(_settings, localAsrGenerator),
            completionNotifier: this);
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
        ClearImportedSubtitleFileCommand = new RelayCommand(ClearImportedSubtitleFile);
        // 语言切换：XAML 的 DynamicResource 自动换装；代码侧派生文案在这里统一重算。
        LocalizationManager.LanguageChanged += OnLanguageChanged;
    }

    public void QueueDidComplete(QueueCompletionNotification notification)
    {
        _dispatcher.BeginInvoke(() =>
        {
            if (Settings.CompletionNotificationsEnabled)
            {
                EnqueueNotice = CompletionNoticeText(notification);
            }
            if (Settings.CompletionSoundEnabled)
            {
                SystemSounds.Asterisk.Play();
            }
        });
    }

    private static string CompletionNoticeText(QueueCompletionNotification notification)
    {
        var text = notification.CompletedCount == 1 && notification.Titles.Count > 0
            ? Loc.F("L.Notice.DownloadCompletedTitleFmt", notification.Titles[0])
            : Loc.F("L.Notice.DownloadCompletedCountFmt", notification.CompletedCount);
        if (notification.PartialFailureCount > 0)
        {
            text += Loc.S("L.Notice.JoinSep") + Loc.F("L.Notice.DownloadPartialFmt", notification.PartialFailureCount);
        }
        return text;
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
    public RelayCommand ClearImportedSubtitleFileCommand { get; }

    /// <summary>App 级共享更新服务，供主窗设置入口的「有可用更新」红点绑定（只读观察，不触发检查）。</summary>
    public UpdateService Updater => App.WindowsUpdater;

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
    public bool HasNoSubtitles => SubtitleOptions.Count == 0;

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

    // MARK: - 语言优先 Ready 页（推荐语言 + 展开区其他语言）

    public ObservableCollection<SourceLanguageOptionViewModel> SourceLanguageOptions { get; } =
    [
        new("auto"),
        new("ja"),
        new("en"),
        new("ko"),
        new("zh-Hans"),
        new("yue"),
    ];

    public IReadOnlyList<SubtitleSourcePolicyOptionViewModel> SubtitleSourcePolicyOptions { get; } =
    [
        new(SubtitleSourcePolicy.AutoBest, "L.Ready.SubtitleSourcePolicyAutoBest"),
        new(SubtitleSourcePolicy.PreferPlatform, "L.Ready.SubtitleSourcePolicyPreferPlatform"),
        new(SubtitleSourcePolicy.ForcePlatform, "L.Ready.SubtitleSourcePolicyForcePlatform"),
        new(SubtitleSourcePolicy.PreferLocalAsr, "L.Ready.SubtitleSourcePolicyPreferLocalASR"),
        new(SubtitleSourcePolicy.ForceLocalAsr, "L.Ready.SubtitleSourcePolicyForceLocalASR"),
        new(SubtitleSourcePolicy.CompareLocalAsr, "L.Ready.SubtitleSourcePolicyCompareLocalASR"),
        new(SubtitleSourcePolicy.CloudAsr, "L.Ready.SubtitleSourcePolicyCloudASR"),
        new(SubtitleSourcePolicy.ImportedFile, "L.Ready.SubtitleSourcePolicyImportedFile"),
    ];

    private SubtitleSourcePolicyOptionViewModel? _selectedSubtitleSourcePolicyOption;
    public SubtitleSourcePolicyOptionViewModel? SelectedSubtitleSourcePolicyOption
    {
        get => _selectedSubtitleSourcePolicyOption ??= SubtitleSourcePolicyOptions[0];
        set
        {
            if (!SetProperty(ref _selectedSubtitleSourcePolicyOption, value)) return;
            if (_currentInfo is { } info && SubtitleSourceControlsVisible)
            {
                ApplySubtitleSourcePolicy(info);
            }
        }
    }

    private SourceLanguageOptionViewModel? _selectedSourceLanguageOption;
    public SourceLanguageOptionViewModel? SelectedSourceLanguageOption
    {
        get => _selectedSourceLanguageOption ??= SourceLanguageOptions[0];
        set
        {
            if (!SetProperty(ref _selectedSourceLanguageOption, value)) return;
            if (_currentInfo is not { } info) return;
            RebuildSubtitleOptions(info);
            RefreshLanguageOptions(info);
            if (RecommendedLanguageOption?.Language is { } recommended)
            {
                SelectLanguage(recommended);
            }
        }
    }

    /// <summary>展开区里的其他语言（推荐语言之外）。</summary>
    public ObservableCollection<SubtitleLanguageOptionViewModel> OtherLanguageOptions { get; } = [];

    private SubtitleLanguageOptionViewModel? _recommendedLanguageOption;
    /// <summary>主区域默认展示的推荐语言；null 表示该视频无可用字幕。</summary>
    public SubtitleLanguageOptionViewModel? RecommendedLanguageOption
    {
        get => _recommendedLanguageOption;
        private set => SetProperty(ref _recommendedLanguageOption, value);
    }

    public bool HasRecommendedLanguage => RecommendedLanguageOption is not null;
    public bool HasOtherLanguages => OtherLanguageOptions.Count > 0;

    private bool _languageSectionExpanded;
    /// <summary>Ready 页语言区是否展开（默认折叠：只显示推荐语言）。</summary>
    public bool LanguageSectionExpanded
    {
        get => _languageSectionExpanded;
        set => SetProperty(ref _languageSectionExpanded, value);
    }

    /// <summary>选定一个语言：用它的首选轨道（manual &gt; auto &gt; localASR）作为主源。</summary>
    public void SelectLanguage(SubtitleLanguageChoice language)
    {
        var policy = SelectedSubtitleSourcePolicyOption?.Policy ?? SubtitleSourcePolicy.AutoBest;
        var track = TrackMatchingPolicy(policy, language) ?? language.PreferredTrack;
        if (track is not null) PrimarySubtitleTrackId = track.Id;
    }

    private string? _importedSubtitleFilePath;
    public string? ImportedSubtitleFilePath
    {
        get => _importedSubtitleFilePath;
        private set
        {
            if (!SetProperty(ref _importedSubtitleFilePath, value)) return;
            RaisePropertyChanged(nameof(ImportedSubtitleSummary));
        }
    }

    public string? ImportedSubtitleSummary => ImportedSubtitleFilePath is { Length: > 0 } path
        ? Loc.F("L.Ready.ImportedSubtitleSelectedFmt", Path.GetFileName(path))
        : null;

    /// <summary>从可用字幕轨道聚合 + 推荐，刷新推荐语言与其他语言两个集合。</summary>
    private void RefreshLanguageOptions(VideoInfo info)
    {
        var result = SubtitleLanguageRecommender.Recommend(
            info.Title,
            SubtitleLanguageRecommender.Aggregate([.. SubtitleOptions.Select(o => o.Choice)]),
            Settings.TranslationTargetLanguage,
            preferredSourceLanguage: EffectiveSourceLanguagePreference(info));
        RecommendedLanguageOption = result.Recommended is { } recommended
            ? new SubtitleLanguageOptionViewModel(this, recommended, isRecommended: true)
            : null;
        OtherLanguageOptions.Clear();
        foreach (var language in result.Others)
        {
            OtherLanguageOptions.Add(new SubtitleLanguageOptionViewModel(this, language, isRecommended: false));
        }
        RaisePropertyChanged(nameof(HasRecommendedLanguage));
        RaisePropertyChanged(nameof(HasOtherLanguages));
    }

    private string? _primarySubtitleTrackId;
    public string? PrimarySubtitleTrackId
    {
        get => _primarySubtitleTrackId;
        set
        {
            if (!SetProperty(ref _primarySubtitleTrackId, value)) return;
            foreach (var option in SubtitleOptions)
            {
                option.RefreshPrimarySource();
            }
            RecommendedLanguageOption?.RefreshSelected();
            foreach (var language in OtherLanguageOptions)
            {
                language.RefreshSelected();
            }
            RaisePropertyChanged(nameof(PrimarySubtitleNone));
            RaisePropertyChanged(nameof(SelectedPrimarySubtitleOption));
            if (_primarySubtitleTrackId is null && _chineseMode != ChineseSubtitleMode.Off)
            {
                ChineseMode = ChineseSubtitleMode.Off;
                return;
            }
            RaiseChineseDerived();
        }
    }

    public bool PrimarySubtitleNone
    {
        get => PrimarySubtitleTrackId is null;
        set { if (value) SelectPrimarySubtitle(null); }
    }

    public SubtitleOptionViewModel? SelectedPrimarySubtitleOption =>
        SubtitleOptions.FirstOrDefault(option => option.Id == PrimarySubtitleTrackId);

    public void SelectPrimarySubtitle(SubtitleChoice? primary)
    {
        PrimarySubtitleTrackId = primary?.Id;
    }

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
        var preferredLangs = info.Subtitles.Select(s => s.LanguageCode).ToList();
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
            if (value != ChineseSubtitleMode.Off) EnsureSubtitleSourceSelected();
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

    public bool HasSubtitleSelected => SelectedPrimarySubtitleOption is not null;
    public bool ChineseModeEnabled => HasSubtitleSelected;
    public bool SubtitleSourceControlsVisible => _chineseMode != ChineseSubtitleMode.Off;

    /// <summary>实际作为翻译源的主字幕来源。</summary>
    private SubtitleChoice? TranslationSourceSubtitle()
    {
        return SelectedPrimarySubtitleOption?.Choice;
    }

    /// <summary>实际翻译源字幕是否已与翻译目标语言同一脚本（同则跳过翻译、直接使用/烧录）。</summary>
    private bool TranslationSourceMatchesTarget()
    {
        var source = TranslationSourceSubtitle();
        if (source is null) return false;
        return TranslationLanguage.Matches(source.LanguageCode, Settings.TranslationTargetLanguage);
    }

    public string? ChineseHintText
    {
        get
        {
            if (!HasSubtitleSelected) return Loc.S("L.Hint.SelectSubtitleFirst");
            if (ShowTranslationUnconfigured) return null;
            if (_chineseMode != ChineseSubtitleMode.Off
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
        && RequiresTranslation(_chineseMode);

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
        RaisePropertyChanged(nameof(SubtitleSourceControlsVisible));
        RaisePropertyChanged(nameof(ChineseHintText));
        RaisePropertyChanged(nameof(ShowTranslationUnconfigured));
        RaisePropertyChanged(nameof(ChineseSourceNote));
    }

    private void EnsureSubtitleSourceSelected()
    {
        if (HasSubtitleSelected) return;
        if (RecommendedLanguageOption?.Language is { } recommended)
        {
            SelectLanguage(recommended);
            if (HasSubtitleSelected) return;
        }
        if (OtherLanguageOptions.FirstOrDefault()?.Language is { } fallback)
        {
            SelectLanguage(fallback);
        }
    }

    private void ApplySubtitleSourcePolicy(VideoInfo info)
    {
        var policy = SelectedSubtitleSourcePolicyOption?.Policy ?? SubtitleSourcePolicy.AutoBest;
        if (TrackMatchingPolicy(policy, info) is { } track)
        {
            PrimarySubtitleTrackId = track.Id;
        }
    }

    private SubtitleChoice? TrackMatchingPolicy(SubtitleSourcePolicy policy, VideoInfo info)
    {
        var languages = SubtitleLanguageRecommender.Aggregate(AvailableSubtitleChoices(info));
        var selectedLanguage = SelectedPrimarySubtitleOption is { } selected
            ? SubtitleLanguageChoice.NormalizedLanguageCode(selected.LanguageCode)
            : null;
        var currentGroup = selectedLanguage is null
            ? RecommendedLanguageOption?.Language ?? languages.FirstOrDefault()
            : languages.FirstOrDefault(language => language.LanguageCode == selectedLanguage)
                ?? RecommendedLanguageOption?.Language
                ?? languages.FirstOrDefault();
        return currentGroup is null ? null : TrackMatchingPolicy(policy, currentGroup);
    }

    private static SubtitleChoice? TrackMatchingPolicy(SubtitleSourcePolicy policy, SubtitleLanguageChoice language)
    {
        static bool IsPlatformTrack(SubtitleChoice track) =>
            track.SourceKind is SubtitleSourceKind.Manual or SubtitleSourceKind.PlatformAuto or SubtitleSourceKind.HlsManifest;

        return policy switch
        {
            SubtitleSourcePolicy.AutoBest => language.PreferredTrack,
            SubtitleSourcePolicy.PreferPlatform => language.Tracks.FirstOrDefault(IsPlatformTrack) ?? language.PreferredTrack,
            SubtitleSourcePolicy.ForcePlatform => language.Tracks.FirstOrDefault(IsPlatformTrack),
            SubtitleSourcePolicy.PreferLocalAsr =>
                language.Tracks.FirstOrDefault(track => track.SourceKind == SubtitleSourceKind.LocalAsr) ?? language.PreferredTrack,
            SubtitleSourcePolicy.ForceLocalAsr =>
                language.Tracks.FirstOrDefault(track => track.SourceKind == SubtitleSourceKind.LocalAsr),
            SubtitleSourcePolicy.CompareLocalAsr =>
                language.Tracks.FirstOrDefault(track => track.SourceKind == SubtitleSourceKind.PlatformAuto)
                    ?? language.Tracks.FirstOrDefault(track => track.SourceKind == SubtitleSourceKind.LocalAsr),
            SubtitleSourcePolicy.CloudAsr => null,
            SubtitleSourcePolicy.ImportedFile =>
                language.Tracks.FirstOrDefault(track => track.SourceKind == SubtitleSourceKind.ImportedFile),
            _ => language.PreferredTrack,
        };
    }

    internal void OnSubtitleSelectionChanged()
    {
        // 字幕输出依赖一个主字幕来源；全部取消时强制回「不需要」。
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
            var localAsrGenerator = LocalAsrGeneratorFactory.Create(value);
            Queue.SyncLocalAsrGenerator(localAsrGenerator);
            Queue.SyncCloudAsrGenerator(CloudAsrGeneratorFactory.Create(value, localAsrGenerator));
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

    /// <summary>打开设置以配置本地语音识别（语言行未就绪时的配置入口）。</summary>
    internal void OpenLocalAsrSettings()
    {
        RequestOpenSettings(Loc.S("L.Ready.LocalASRSetupRequired"));
    }

    /// <summary>打开设置以配置云端精准识别（显式策略未就绪时的配置入口）。</summary>
    internal void OpenCloudAsrSettings()
    {
        RequestOpenSettings(Loc.S("L.Ready.CloudASRSetupRequired"));
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
    private string? _failedLoginUrl;
    /// <summary>失败原因是需要登录/验证时记录站点，failed 页据此把主按钮换成站点验证入口。</summary>
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
        if (error is MoongateException { Kind: MoongateErrorKind.LoginRequired } login)
        {
            FailedNeedsLogin = login.Detail;
            _failedLoginUrl = null;
        }
        else if (error is MoongateException { Kind: MoongateErrorKind.SiteCookieRequired } cookie)
        {
            FailedNeedsLogin = cookie.Detail;
            _failedLoginUrl = cookie.CookieRequestUrl;
        }
        else
        {
            FailedNeedsLogin = null;
            _failedLoginUrl = null;
        }
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
        PrimarySubtitleTrackId = null;
        ImportedSubtitleFilePath = null;
        SelectedSubtitleSourcePolicyOption = SubtitleSourcePolicyOptions[0];
        SelectedSourceLanguageOption = SourceLanguageOptions.FirstOrDefault(
            option => option.Code == AppSettings.NormalizePreferredSourceLanguage(Settings.PreferredSourceLanguage))
            ?? SourceLanguageOptions[0];
        RebuildSubtitleOptions(info);
        RefreshLanguageOptions(info);
        LanguageSectionExpanded = false;
        RestoreLastDownloadOptions(info);
        ResetSummary();
        SetStage(ParseStage.Ready);
        RaiseChineseDerived();
    }

    private void RebuildSubtitleOptions(VideoInfo info)
    {
        SubtitleOptions.Clear();
        foreach (var subtitle in AvailableSubtitleChoices(info))
        {
            SubtitleOptions.Add(new SubtitleOptionViewModel(this, subtitle));
        }
        RaisePropertyChanged(nameof(HasNoSubtitles));
    }

    /// <summary>
    /// 选档页恢复上次下载选项（PARITY-002，与 macOS 一致）：输出格式 / HDR 直接套用；
    /// 字幕按语言代码在本视频可用字幕里匹配（真实字幕优先）；字幕处理方式在字幕恢复之后再设，
    /// 避免勾选回调把它打回「不需要」。
    /// </summary>
    private void RestoreLastDownloadOptions(VideoInfo info)
    {
        SelectedSourceLanguageOption = SourceLanguageOptions.FirstOrDefault(
            option => option.Code == AppSettings.NormalizePreferredSourceLanguage(Settings.PreferredSourceLanguage))
            ?? SourceLanguageOptions[0];
        _preferHdr = Settings.LastPreferHdr && (SelectedFormat?.HdrAvailable ?? false);
        RaisePropertyChanged(nameof(PreferHdr));
        SelectedOutputFormat = OutputFormats.FirstOrDefault(o => o.Format == OutputFormatFromRaw(Settings.LastOutputFormat))
            ?? OutputFormats[0];

        var matchedAny = false;
        if (Settings.LastPrimarySubtitleTrackId is { Length: > 0 } lastPrimarySubtitleTrackId
            && SubtitleOptions.FirstOrDefault(option => option.Id == lastPrimarySubtitleTrackId) is { } exact)
        {
            SelectPrimarySubtitle(exact.Choice);
            matchedAny = true;
        }
        else
        {
            var wantedLangs = Settings.LastSubtitleLangs.Select(NormalizedLang).ToHashSet();
            foreach (var lang in wantedLangs)
            {
                var group = SubtitleOptions
                    .Where(o => NormalizedLang(o.LanguageCode) == lang && !o.IsLocalAsr)
                    .ToList();
                var best = group.FirstOrDefault(o => !o.IsAuto) ?? group.FirstOrDefault();
                if (best is not null)
                {
                    SelectPrimarySubtitle(best.Choice);
                    matchedAny = true;
                    break;
                }
            }
        }
        // 没有命中上次手选/语言 → 用语言优先推荐器选一个推荐语言（确定性，随视频内容变化）。
        if (!matchedAny && RecommendedLanguageOption?.Language.PreferredTrack is { } recommendedTrack)
        {
            SelectPrimarySubtitle(recommendedTrack);
            matchedAny = true;
        }
        // 仅当字幕成功恢复、且记录的处理方式不是「不需要」时才恢复 mode（否则保持 Off）。
        var savedMode = ChineseModeFromRaw(Settings.LastSubtitleMode);
        _chineseMode = matchedAny && savedMode != ChineseSubtitleMode.Off ? savedMode : ChineseSubtitleMode.Off;
    }

    /// <summary>字幕 id 归一成语言代码：小写、取首个 '-' 前的部分（"ja-JP"/"ja-orig" → "ja"）。</summary>
    private static string NormalizedLang(string id)
    {
        var lower = SubtitleTrackId.Parse(id).LanguageCode.ToLowerInvariant();
        var dash = lower.IndexOf('-');
        return dash >= 0 ? lower[..dash] : lower;
    }

    private IReadOnlyList<SubtitleChoice> AvailableSubtitleChoices(VideoInfo info)
    {
        var choices = info.Subtitles.ToList();
        var seenIds = choices.Select(choice => choice.Id).ToHashSet(StringComparer.Ordinal);
        AppendImportedSubtitleChoice(info, choices, seenIds);
        var preferredSourceLanguage = EffectiveSourceLanguagePreference(info);
        if (info.Subtitles.Count == 0)
        {
            AppendLocalAsrChoice(
                preferredSourceLanguage,
                preferredSourceLanguage == "auto" ? Loc.S("L.Ready.LocalASRAutoDetect") : null,
                choices,
                seenIds);
            return choices;
        }

        var seenLanguages = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var subtitle in info.Subtitles)
        {
            var languageCode = NormalizedLang(subtitle.LanguageCode);
            if (languageCode.Length == 0 || !seenLanguages.Add(languageCode)) continue;

            AppendLocalAsrChoice(
                languageCode,
                subtitle.Label,
                choices,
                seenIds);
        }
        if (preferredSourceLanguage != "auto")
        {
            AppendLocalAsrChoice(
                preferredSourceLanguage,
                TranslationLanguage.SourceDisplayName(preferredSourceLanguage),
                choices,
                seenIds);
        }
        return choices;
    }

    private void AppendImportedSubtitleChoice(
        VideoInfo info,
        List<SubtitleChoice> choices,
        HashSet<string> seenIds)
    {
        if (ImportedSubtitleChoice(info) is not { } imported) return;
        if (seenIds.Add(imported.Id)) choices.Add(imported);
    }

    private SubtitleChoice? ImportedSubtitleChoice(VideoInfo info)
    {
        if (ImportedSubtitleFilePath is not { Length: > 0 } path) return null;
        var languageCode = ImportedSubtitleLanguageCode(info);
        return SubtitleChoice.Create(
            languageCode,
            Path.GetFileName(path),
            SubtitleSourceKind.ImportedFile,
            provider: "file",
            variant: "imported",
            metadata: new Dictionary<string, string> { ["path"] = path });
    }

    private string ImportedSubtitleLanguageCode(VideoInfo info)
    {
        var preferred = EffectiveSourceLanguagePreference(info);
        if (preferred != "auto") return preferred;
        return SubtitleLanguageRecommender.InferredLocalAsrLanguageCode(info.Title) ?? "auto";
    }

    public void ImportSubtitleFile(string path)
    {
        var ext = Path.GetExtension(path).TrimStart('.').ToLowerInvariant();
        if (ext is not ("srt" or "vtt") || !File.Exists(path))
        {
            EnqueueNotice = Loc.S("L.Ready.ImportedSubtitleUnsupported");
            return;
        }
        ImportedSubtitleFilePath = path;
        SelectedSubtitleSourcePolicyOption = SubtitleSourcePolicyOptions
            .FirstOrDefault(option => option.Policy == SubtitleSourcePolicy.ImportedFile)
            ?? SelectedSubtitleSourcePolicyOption;
        if (_currentInfo is not { } info) return;
        RebuildSubtitleOptions(info);
        RefreshLanguageOptions(info);
        if (ImportedSubtitleChoice(info) is { } imported)
        {
            PrimarySubtitleTrackId = imported.Id;
        }
    }

    public void ClearImportedSubtitleFile()
    {
        ImportedSubtitleFilePath = null;
        if (SelectedSubtitleSourcePolicyOption?.Policy == SubtitleSourcePolicy.ImportedFile)
        {
            SelectedSubtitleSourcePolicyOption = SubtitleSourcePolicyOptions[0];
        }
        if (_currentInfo is not { } info) return;
        RebuildSubtitleOptions(info);
        RefreshLanguageOptions(info);
        EnsureSubtitleSourceSelected();
    }

    private static void AppendLocalAsrChoice(
        string languageCode,
        string? label,
        List<SubtitleChoice> choices,
        HashSet<string> seenIds)
    {
        var localAsr = SubtitleChoice.Create(
            languageCode,
            TranslationLanguage.SourceDisplayName(languageCode)
                ?? label
                ?? Loc.S("L.Ready.LocalASRAutoDetect"),
            SubtitleSourceKind.LocalAsr,
            provider: "whisper.cpp",
            variant: "local");
        if (seenIds.Add(localAsr.Id)) choices.Add(localAsr);
    }

    private string EffectiveSourceLanguagePreference(VideoInfo info)
    {
        var selected = AppSettings.NormalizePreferredSourceLanguage(SelectedSourceLanguageOption?.Code ?? "auto");
        if (selected != "auto") return selected;
        return SubtitleLanguageRecommender.InferredLocalAsrLanguageCode(info.Title) ?? "auto";
    }

    private static string BatchSourceLanguagePreference(VideoInfo info, AppSettings settings)
    {
        var selected = AppSettings.NormalizePreferredSourceLanguage(settings.PreferredSourceLanguage);
        return selected != "auto"
            ? selected
            : SubtitleLanguageRecommender.InferredLocalAsrLanguageCode(info.Title) ?? "auto";
    }

    private static SourceLanguageIntent SourceLanguageIntentFromCode(string code)
    {
        var normalized = AppSettings.NormalizePreferredSourceLanguage(code);
        return normalized == "auto"
            ? SourceLanguageIntent.Automatic
            : SourceLanguageIntent.Language(normalized);
    }

    private static SubtitleIntent SubtitleIntentFromChineseMode(ChineseSubtitleMode mode) => mode switch
    {
        ChineseSubtitleMode.SrtOnly => SubtitleIntent.TranslatedSrt,
        ChineseSubtitleMode.BurnIn => SubtitleIntent.BurnTranslated,
        ChineseSubtitleMode.BurnOriginal => SubtitleIntent.BurnSource,
        _ => SubtitleIntent.None,
    };

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
        var primary = SelectedPrimarySubtitleOption;
        List<string> selectedLangs = primary is null ? [] : [primary.LanguageCode];
        var mode = ChineseModeRaw(_chineseMode);
        var format = OutputFormatRaw(SelectedOutputFormat?.Format ?? OutputFormat.Original);
        if (mode == Settings.LastSubtitleMode
            && format == Settings.LastOutputFormat
            && _preferHdr == Settings.LastPreferHdr
            && PrimarySubtitleTrackId == Settings.LastPrimarySubtitleTrackId
            && selectedLangs.SequenceEqual(Settings.LastSubtitleLangs))
        {
            return;
        }
        var updated = Settings with
        {
            LastSubtitleMode = mode,
            LastSubtitleLangs = selectedLangs,
            LastPrimarySubtitleTrackId = PrimarySubtitleTrackId,
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
        PrimarySubtitleTrackId = null;
        ImportedSubtitleFilePath = null;
        SelectedSubtitleSourcePolicyOption = SubtitleSourcePolicyOptions[0];
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
                // 字幕处理开启时自动选一条推荐语言；同语言内仍由 track 排序决定人工/自动/本地源。
                var subtitleLangs = new List<string>();
                var autoSubtitleLangs = new List<string>();
                var subtitleTracks = new List<SubtitleChoice>();
                string? primarySubtitleTrackId = null;
                string? preferredSubtitleLanguageCode = null;
                var recommendation = SubtitleLanguageRecommender.Recommend(
                    info.Title,
                    SubtitleLanguageRecommender.Aggregate(AvailableSubtitleChoices(info)),
                    settings.TranslationTargetLanguage);
                if (mode != ChineseSubtitleMode.Off)
                {
                    if (recommendation.Recommended is { } recommended
                        && recommended.PreferredTrack is { } sub
                        && (sub.SourceKind != SubtitleSourceKind.LocalAsr || Queue.HasLocalAsrGenerator))
                    {
                        subtitleTracks.Add(sub);
                        primarySubtitleTrackId = sub.Id;
                        preferredSubtitleLanguageCode = SubtitleLanguageChoice.NormalizedLanguageCode(sub.LanguageCode);
                        if (sub.SourceKind == SubtitleSourceKind.PlatformAuto) autoSubtitleLangs.Add(sub.LanguageCode);
                        else if (sub.SourceKind == SubtitleSourceKind.Manual) subtitleLangs.Add(sub.LanguageCode);
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
                    SubtitleTracks = subtitleTracks,
                    PrimarySubtitleTrackId = primarySubtitleTrackId,
                    PreferredSubtitleLanguageCode = preferredSubtitleLanguageCode,
                    SubtitleIntent = SubtitleIntentFromChineseMode(mode),
                    SourceLanguageIntent = SourceLanguageIntentFromCode(BatchSourceLanguagePreference(info, settings)),
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
        PrimarySubtitleTrackId = null;
        ImportedSubtitleFilePath = null;
        SelectedSubtitleSourcePolicyOption = SubtitleSourcePolicyOptions[0];
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
        var selectedFormat = SelectedFormat ?? info.Formats.FirstOrDefault();
        var formatId = selectedFormat?.Id;
        if (formatId is null) return;
        // 去重：队列里已有同源未完成任务时不再起新任务，只给一行提示。
        if (Queue.HasOpenDuplicate(info.VideoId, info.SourceUrl, formatId))
        {
            EnqueueNotice = Loc.S("L.Notice.Duplicate");
            return;
        }
        var primary = SelectedPrimarySubtitleOption;
        if (primary?.Choice.SourceKind == SubtitleSourceKind.LocalAsr && !Queue.HasLocalAsrGenerator)
        {
            OpenLocalAsrSettings();
            return;
        }
        var subtitleSourcePolicy = SelectedSubtitleSourcePolicyOption?.Policy ?? SubtitleSourcePolicy.AutoBest;
        if (subtitleSourcePolicy == SubtitleSourcePolicy.CloudAsr && !Queue.HasCloudAsrGenerator)
        {
            OpenCloudAsrSettings();
            return;
        }
        List<SubtitleOptionViewModel> chosen = primary is null ? [] : [primary];
        // 会产出多个文件（字幕 / 翻译 / 烧录件）时按视频建独立文件夹；单视频直接放 Downloads。
        var multiFile = chosen.Count > 0 || _chineseMode != ChineseSubtitleMode.Off;
        var isPage = _chosenCandidate?.Kind is VideoCandidate.CandidateKind.PageMain
            or VideoCandidate.CandidateKind.DirectFile;
        var request = new DownloadRequest
        {
            Url = info.SourceUrl,
            VideoId = info.VideoId,
            FormatId = formatId,
            SubtitleLangs = primary?.Choice.SourceKind == SubtitleSourceKind.Manual ? [primary.LanguageCode] : [],
            AutoSubtitleLangs = primary?.Choice.SourceKind == SubtitleSourceKind.PlatformAuto ? [primary.LanguageCode] : [],
            SubtitleTracks = chosen.Select(option => option.Choice).ToList(),
            PrimarySubtitleTrackId = primary?.Id,
            PreferredSubtitleLanguageCode = primary is null
                ? null
                : SubtitleLanguageChoice.NormalizedLanguageCode(primary.LanguageCode),
            DestinationDirectory = DownloadPaths.DestinationDirectory(info.Title, multiFile),
            PreferredTitle = isPage ? info.Title : null,
            PreferHdr = _preferHdr && (selectedFormat?.HdrAvailable ?? false),
            OutputFormat = SelectedOutputFormat?.Format ?? OutputFormat.Original,
            SubtitleSourcePolicy = subtitleSourcePolicy,
            SubtitleIntent = SubtitleIntentFromChineseMode(_chineseMode),
            SourceLanguageIntent = SourceLanguageIntentFromCode(EffectiveSourceLanguagePreference(info)),
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
        PrimarySubtitleTrackId = null;
        ImportedSubtitleFilePath = null;
        SelectedSubtitleSourcePolicyOption = SubtitleSourcePolicyOptions[0];
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

    /// <summary>failed 页点「打开网页并保存验证信息」。</summary>
    public void OpenLoginForFailure()
    {
        if (_failedNeedsLogin is { } site) OpenLoginRequested?.Invoke(site, _failedLoginUrl);
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
            QueueSummary = Queue.Items.All(item => item.Stage.Kind == ItemStageKind.Done)
                ? Loc.S("L.Queue.AllDone")
                : Loc.S("L.Queue.AllEnded");
            return;
        }
        var summary = Loc.F("L.Queue.ActiveFmt", open);
        if (finished > 0)
        {
            summary += Loc.S("L.Queue.SummarySep") + Loc.F("L.Queue.FinishedFmt", finished);
        }
        if (QueueRemainingSummary() is { } remaining)
        {
            summary += Loc.S("L.Queue.SummarySep") + remaining;
        }
        QueueSummary = summary;
    }

    private string? QueueRemainingSummary()
    {
        var snapshot = Queue.ProgressSnapshot;
        if (snapshot.RemainingSeconds is { } seconds)
        {
            return Loc.F("L.Status.RemainingApprox", ApproximateDurationText(seconds));
        }
        return snapshot.IsEstimatingRemaining ? Loc.S("L.Status.RemainingEstimating") : null;
    }

    private static string ApproximateDurationText(double seconds)
    {
        var total = Math.Max(0, (int)Math.Ceiling(seconds));
        if (total < 60) return Loc.S("L.Status.RemainingLessThanMinute");
        var minutes = (int)Math.Ceiling(total / 60.0);
        if (minutes < 60) return Loc.F("L.Status.RemainingMinutes", minutes);
        return Loc.F("L.Status.RemainingHoursMinutes", minutes / 60, minutes % 60);
    }

    /// <summary>语言切换：重算代码侧派生文案并刷新队列行（XAML 文案由 DynamicResource 自动换）。</summary>
    private void OnLanguageChanged()
    {
        RaisePropertyChanged(nameof(LoadingText));
        RaisePropertyChanged(nameof(ChoosingTitle));
        RaisePropertyChanged(nameof(ImportedSubtitleSummary));
        RaiseChineseDerived();
        RefreshQueueSummary();
        foreach (var option in SourceLanguageOptions)
        {
            option.RefreshLabel();
        }
        foreach (var option in SubtitleSourcePolicyOptions)
        {
            option.RefreshLabel();
        }
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

/// <summary>字幕来源单选里的一行。选择状态变化回调主视图模型以联动字幕输出分组。</summary>
public sealed class SubtitleOptionViewModel : ObservableObject
{
    private readonly MainViewModel _owner;
    public SubtitleChoice Choice { get; }
    public string Id { get; }
    public string LanguageCode { get; }
    public string Label { get; }
    public bool IsAuto { get; }
    public bool IsLocalAsr { get; }

    public bool IsPrimarySource
    {
        get => _owner.PrimarySubtitleTrackId == Id;
        set { if (value) _owner.SelectPrimarySubtitle(Choice); }
    }

    public bool IsSelected
    {
        get => IsPrimarySource;
        set
        {
            if (value)
            {
                IsPrimarySource = true;
            }
            else if (IsPrimarySource)
            {
                _owner.SelectPrimarySubtitle(null);
            }
        }
    }

    internal void RefreshPrimarySource()
    {
        RaisePropertyChanged(nameof(IsPrimarySource));
        RaisePropertyChanged(nameof(IsSelected));
    }

    public SubtitleOptionViewModel(MainViewModel owner, SubtitleChoice choice)
    {
        _owner = owner;
        Choice = choice;
        Id = choice.Id;
        LanguageCode = choice.LanguageCode;
        Label = choice.Label;
        IsAuto = choice.IsAuto;
        IsLocalAsr = choice.SourceKind == SubtitleSourceKind.LocalAsr;
    }
}

public sealed class SourceLanguageOptionViewModel(string code) : ObservableObject
{
    public string Code { get; } = code;

    public string Label => Code == "auto"
        ? Loc.S("L.Ready.SourceLanguageAuto")
        : TranslationLanguage.SourceDisplayName(Code) ?? Code;

    internal void RefreshLabel() => RaisePropertyChanged(nameof(Label));
}

public sealed class SubtitleSourcePolicyOptionViewModel(SubtitleSourcePolicy policy, string labelKey) : ObservableObject
{
    public SubtitleSourcePolicy Policy { get; } = policy;
    public string LabelKey { get; } = labelKey;
    public string Label => Loc.S(LabelKey);

    internal void RefreshLabel() => RaisePropertyChanged(nameof(Label));
}

/// <summary>
/// 语言优先 Ready 页里的一行语言（聚合了该语言的所有技术轨道）。选语言而不是选技术源。
/// 推荐行显示「推荐」徽标；展开区里非推荐行按来源显示 auto / 本地识别徽标。
/// </summary>
public sealed class SubtitleLanguageOptionViewModel : ObservableObject
{
    private readonly MainViewModel _owner;
    public SubtitleLanguageChoice Language { get; }
    public string LanguageCode { get; }
    public string DisplayLabel { get; }
    public bool IsRecommended { get; }

    /// <summary>来源徽标：人工字幕不显示徽标；自动显示 auto；仅本地识别显示本地识别。</summary>
    public bool ShowAutoBadge => !Language.HasManualTrack && Language.HasAutoTrack;
    public bool ShowLocalAsrBadge => !Language.HasManualTrack && !Language.HasAutoTrack && Language.SupportsLocalAsr;

    /// <summary>local-ASR-only 语言且本地识别未就绪：显示配置入口而非直接选中。</summary>
    public bool NeedsLocalAsrConfig =>
        !Language.HasManualTrack && !Language.HasAutoTrack && Language.SupportsLocalAsr && !_owner.Queue.HasLocalAsrGenerator;

    public bool IsSelected
    {
        get => Language.Tracks.Any(t => t.Id == _owner.PrimarySubtitleTrackId);
        set
        {
            if (!value) return;
            if (NeedsLocalAsrConfig) _owner.OpenLocalAsrSettings();
            else _owner.SelectLanguage(Language);
        }
    }

    internal void RefreshSelected() => RaisePropertyChanged(nameof(IsSelected));

    public SubtitleLanguageOptionViewModel(MainViewModel owner, SubtitleLanguageChoice language, bool isRecommended)
    {
        _owner = owner;
        Language = language;
        LanguageCode = language.LanguageCode;
        DisplayLabel = language.DisplayLabel;
        IsRecommended = isRecommended;
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
