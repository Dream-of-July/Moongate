namespace Moongate.Core;

// MARK: - 错误

/// <summary>错误种类。与 Swift 版 MoongateError 各 case 一一对应。</summary>
public enum MoongateErrorKind
{
    BinaryNotFound,
    SniffFailed,
    AnalyzeFailed,
    UpdateFailed,
    DownloadFailed,
    /// <summary>站点风控/会员限制，需要用户在 App 内登录该站点后重试。Detail 为站点 host（如 "youtube.com"）。</summary>
    LoginRequired,
    /// <summary>站点需要用户在网页完成登录、验证或风控确认后保存 Cookie 再重试。</summary>
    SiteCookieRequired,
    TranslateFailed,
    BurnFailed,
    Cancelled,
}

/// <summary>
/// 统一业务异常。中文消息与 Swift 版保持一致（BinaryNotFound 例外：Windows 没有 Homebrew，
/// 改为指引用户重新下载依赖组件，由 DependencyManager 负责落地）。
/// </summary>
public sealed class MoongateException : Exception
{
    public MoongateErrorKind Kind { get; }
    /// <summary>原因文本或站点 host（LoginRequired 时）。</summary>
    public string Detail { get; }
    public string? CookieRequestUrl { get; }
    public string? CookieRequestReason { get; }

    private MoongateException(
        MoongateErrorKind kind, string detail, string message,
        string? cookieRequestUrl = null, string? cookieRequestReason = null) : base(message)
    {
        Kind = kind;
        Detail = detail;
        CookieRequestUrl = cookieRequestUrl;
        CookieRequestReason = cookieRequestReason;
    }

    public static MoongateException BinaryNotFound(string name) => new(
        MoongateErrorKind.BinaryNotFound, name,
        L10n.T($"找不到 {name}。请在「设置」里重新下载依赖组件后重试。",
            $"找不到 {name}。請在「設定」裡重新下載依賴元件後重試。",
            $"Could not find {name}. Re-download the components in Settings and try again."));

    public static MoongateException SniffFailed(string reason) => new(
        MoongateErrorKind.SniffFailed, reason,
        L10n.T($"没有在这个页面里找到可下载的视频。{reason}",
            $"沒有在這個頁面裡找到可下載的影片。{reason}",
            $"No downloadable video was found on this page. {reason}"));

    public static MoongateException AnalyzeFailed(string reason) => new(
        MoongateErrorKind.AnalyzeFailed, reason,
        L10n.T($"解析视频信息失败：{reason}", $"解析影片資訊失敗：{reason}", $"Failed to analyze the video: {reason}"));

    public static MoongateException UpdateFailed(string reason) => new(
        MoongateErrorKind.UpdateFailed, reason,
        L10n.T($"检查更新失败：{reason}", $"檢查更新失敗：{reason}", $"Update check failed: {reason}"));

    public static MoongateException DownloadFailed(string reason) => new(
        MoongateErrorKind.DownloadFailed, reason,
        L10n.T($"下载失败：{reason}", $"下載失敗：{reason}", $"Download failed: {reason}"));

    public static MoongateException LoginRequired(string site) => new(
        MoongateErrorKind.LoginRequired, site,
        L10n.T($"{site} 需要登录后才能下载。点击「去登录」，在弹出的页面里登录账号后重试。",
            $"{site} 需要登入後才能下載。點擊「去登入」，在彈出的頁面裡登入帳號後重試。",
            $"{site} requires sign-in before downloading. Click \"Sign in\", log in on the page that opens, then retry."));

    public static MoongateException SiteCookieRequired(string site, string url, string reason) => new(
        MoongateErrorKind.SiteCookieRequired, site,
        L10n.T($"{site} 需要先完成网页登录或验证，月之门才能访问真实视频页面。请打开页面并保存站点验证信息，随后会自动重试。\n{reason}",
            $"{site} 需要先完成網頁登入或驗證，月之門才能存取真實影片頁面。請打開頁面並儲存站點驗證資訊，隨後會自動重試。\n{reason}",
            $"{site} needs browser verification or sign-in before Moongate can access the video. Open the page here, save the site cookies, then Moongate will retry.\n{reason}"),
        cookieRequestUrl: url,
        cookieRequestReason: reason);

    public static MoongateException TranslateFailed(string reason) => new(
        MoongateErrorKind.TranslateFailed, reason,
        L10n.T($"字幕翻译失败：{reason}", $"字幕翻譯失敗：{reason}", $"Subtitle translation failed: {reason}"));

    public static MoongateException BurnFailed(string reason) => new(
        MoongateErrorKind.BurnFailed, reason,
        L10n.T($"字幕烧录失败：{reason}", $"字幕燒錄失敗：{reason}", $"Subtitle burn-in failed: {reason}"));

    public static MoongateException Cancelled() => new(
        MoongateErrorKind.Cancelled, "", L10n.T("已取消", "已取消", "Cancelled"));
}

// MARK: - 链接解析候选

/// <summary>
/// 一条用户粘贴的链接背后可能藏着多个视频（例如页面主视频 + 内嵌的 YouTube 轮播）。
/// ResolveCandidatesAsync 把它们全部找出来，交给用户选择。
/// </summary>
public sealed record VideoCandidate
{
    public enum CandidateKind
    {
        PageMain,    // 页面的主视频（直链文件等）
        DirectFile,  // 直链视频文件（mp4 / m3u8 / webm …）
        Youtube,     // 内嵌 YouTube 视频
        Vimeo,       // 内嵌 Vimeo 视频
        Supported,   // yt-dlp 原生支持的链接（无需嗅探）
    }

    /// <summary>交给 AnalyzeAsync 的 URL（同时作为稳定标识）。</summary>
    public required string Url { get; init; }
    public required CandidateKind Kind { get; init; }
    /// <summary>尽力获取的标题（YouTube 走 oEmbed；直链用文件名；主视频用页面标题）。</summary>
    public required string Title { get; init; }
    /// <summary>补充说明，例如 "assets.nintendo.com · mp4 直链" 或 "YouTube"。</summary>
    public string? Detail { get; init; }
}

// MARK: - 解析结果

/// <summary>下载后输出格式（用户在选分辨率页选择）。Original = 保持源，不转码。</summary>
public enum OutputFormat
{
    Original,
    Mp4H264,
    Mp4H265,
    Mkv,
}

/// <summary>动态范围。从 yt-dlp dynamic_range 字符串解析。</summary>
public enum DynamicRange
{
    Sdr,
    Hdr10,
    DolbyVision,
}

public static class DynamicRangeExtensions
{
    /// <summary>从 yt-dlp dynamic_range 字符串解析（SDR/HDR/HDR10/HDR10+/DV/Dolby Vision 等）。</summary>
    public static DynamicRange FromYtDlpValue(string? raw)
    {
        var v = (raw ?? "").ToUpperInvariant();
        if (v.Contains("DV") || v.Contains("DOLBY")) return DynamicRange.DolbyVision;
        if (v.Contains("HDR")) return DynamicRange.Hdr10;
        return DynamicRange.Sdr;
    }

    public static bool IsHdr(this DynamicRange r) => r != DynamicRange.Sdr;

    /// <summary>UI 短标签；SDR 无标签。</summary>
    public static string? Badge(this DynamicRange r) => r switch
    {
        DynamicRange.Hdr10 => "HDR",
        DynamicRange.DolbyVision => L10n.T("杜比视界", "杜比視界", "Dolby Vision"),
        _ => null,
    };
}

public sealed record FormatChoice
{
    /// <summary>
    /// yt-dlp 的 -f 格式选择串（例如 "bv*[height&lt;=720]+ba/b[height&lt;=720]"），
    /// 音频选项用特殊值 "audio"（引擎据此改用 -x 提取音频）。
    /// </summary>
    public required string Id { get; init; }
    /// <summary>例如 "1080p · mp4" / "原始文件 · mp4" / "仅音频 · m4a"。</summary>
    public required string Label { get; init; }
    /// <summary>例如 "≈ 42 MB"、编码信息；未知则为 null。</summary>
    public string? Detail { get; init; }
    public bool IsAudioOnly { get; init; }
    /// <summary>该档是否有 HDR 源可选（同分辨率下存在 HDR 流）。</summary>
    public bool HdrAvailable { get; init; }
    /// <summary>源视频编码简称（如 "vp9"/"av1"/"h264"），用于转码决策与标注；未知为 null。</summary>
    public string? SourceVCodec { get; init; }
    /// <summary>源容器扩展名（如 "webm"/"mp4"）；未知为 null。</summary>
    public string? SourceContainer { get; init; }
}

public enum SubtitleSourceKind
{
    Manual,
    PlatformAuto,
    HlsManifest,
    LocalAsr,
    CloudAsr,
    ImportedFile,
}

public enum SubtitleSourcePolicy
{
    AutoBest,
    PreferPlatform,
    ForcePlatform,
    PreferLocalAsr,
    ForceLocalAsr,
    CompareLocalAsr,
    CloudAsr,
    ImportedFile,
}

public enum SubtitleIntent
{
    None,
    SourceSrt,
    TranslatedSrt,
    BurnTranslated,
    BurnSource,
}

public readonly record struct SourceLanguageIntent(string? LanguageCode)
{
    public static SourceLanguageIntent Automatic { get; } = new(null);

    public static SourceLanguageIntent Language(string code) => new(code);

    public bool IsAutomatic => string.IsNullOrWhiteSpace(LanguageCode)
        || string.Equals(LanguageCode, "auto", StringComparison.OrdinalIgnoreCase);
}

public sealed record SubtitleTrackId(
    string LanguageCode,
    SubtitleSourceKind SourceKind,
    string Provider,
    string? Variant = null)
{
    public string RawValue => string.Join("|",
    [
        Encode(SourceKindRaw(SourceKind)),
        Encode(Provider),
        Encode(LanguageCode),
        Encode(Variant ?? ""),
    ]);

    public static SubtitleTrackId Parse(string raw)
    {
        var parts = raw.Split('|');
        if (parts.Length == 4 && SourceKindFromRaw(Decode(parts[0])) is { } kind)
        {
            var variant = Decode(parts[3]);
            return new SubtitleTrackId(
                Decode(parts[2]),
                kind,
                Decode(parts[1]),
                variant.Length == 0 ? null : variant);
        }
        return new SubtitleTrackId(raw, SubtitleSourceKind.Manual, "legacy");
    }

    public static string StableId(
        string languageCode,
        SubtitleSourceKind sourceKind,
        string provider = "yt-dlp",
        string? variant = null) =>
        new SubtitleTrackId(languageCode, sourceKind, provider, variant).RawValue;

    private static string Encode(string value) =>
        value.Replace("%", "%25", StringComparison.Ordinal)
            .Replace("|", "%7C", StringComparison.Ordinal);

    private static string Decode(string value) =>
        value.Replace("%7C", "|", StringComparison.Ordinal)
            .Replace("%25", "%", StringComparison.Ordinal);

    private static string SourceKindRaw(SubtitleSourceKind kind) => kind switch
    {
        SubtitleSourceKind.PlatformAuto => "platformAuto",
        SubtitleSourceKind.HlsManifest => "hlsManifest",
        SubtitleSourceKind.LocalAsr => "localASR",
        SubtitleSourceKind.CloudAsr => "cloudASR",
        SubtitleSourceKind.ImportedFile => "importedFile",
        _ => "manual",
    };

    private static SubtitleSourceKind? SourceKindFromRaw(string raw) => raw switch
    {
        "manual" => SubtitleSourceKind.Manual,
        "platformAuto" => SubtitleSourceKind.PlatformAuto,
        "hlsManifest" => SubtitleSourceKind.HlsManifest,
        "localASR" => SubtitleSourceKind.LocalAsr,
        "cloudASR" => SubtitleSourceKind.CloudAsr,
        "importedFile" => SubtitleSourceKind.ImportedFile,
        _ => null,
    };
}

public sealed record SubtitleChoice
{
    /// <summary>稳定字幕源 ID，包含语言、来源类型、provider 与 variant。</summary>
    public required string Id { get; init; }
    /// <summary>语言代码，如 "en"、"zh-Hans"。</summary>
    public required string LanguageCode { get; init; }
    /// <summary>中文展示名，如 "英语 (en)"。</summary>
    public required string Label { get; init; }
    public required SubtitleSourceKind SourceKind { get; init; }
    public string Provider { get; init; } = "yt-dlp";
    public string? Variant { get; init; }
    public string? QualityHint { get; init; }
    public IReadOnlyDictionary<string, string> Metadata { get; init; } = new Dictionary<string, string>();
    /// <summary>是否为自动生成字幕（YouTube 自动字幕等）。</summary>
    public required bool IsAuto { get; init; }

    public static SubtitleChoice Create(
        string languageCode,
        string label,
        SubtitleSourceKind sourceKind,
        string provider = "yt-dlp",
        string? variant = null,
        string? qualityHint = null,
        IReadOnlyDictionary<string, string>? metadata = null) => new()
        {
            Id = SubtitleTrackId.StableId(languageCode, sourceKind, provider, variant),
            LanguageCode = languageCode,
            Label = label,
            SourceKind = sourceKind,
            Provider = provider,
            Variant = variant,
            QualityHint = qualityHint,
            Metadata = metadata ?? new Dictionary<string, string>(),
            IsAuto = sourceKind == SubtitleSourceKind.PlatformAuto,
        };
}

/// <summary>
/// Upper-level language aggregation consumed by the ready page UI. A language groups all of its
/// technical tracks (manual / platform-auto / local ASR / cloud ASR) so users pick a language, not a source.
/// Pure derived view: never persisted, never sent to yt-dlp directly.
/// </summary>
public sealed record SubtitleLanguageChoice
{
    /// <summary>Normalized language code (lowercased, first '-' segment), e.g. "ja". Also the identity.</summary>
    public required string LanguageCode { get; init; }
    /// <summary>Display label, taken from the best (first non-localASR) track in the group.</summary>
    public required string DisplayLabel { get; init; }
    /// <summary>Tracks for this language, sorted manual → platformAuto → cloudASR → localASR.</summary>
    public required IReadOnlyList<SubtitleChoice> Tracks { get; init; }

    public bool HasManualTrack => Tracks.Any(t => t.SourceKind == SubtitleSourceKind.Manual);
    public bool HasAutoTrack => Tracks.Any(t => t.SourceKind == SubtitleSourceKind.PlatformAuto);
    /// <summary>Whether the group carries a local-ASR option (independent of runtime readiness).</summary>
    public bool SupportsLocalAsr => Tracks.Any(t => t.SourceKind == SubtitleSourceKind.LocalAsr);
    /// <summary>Preferred technical track: manual > auto > localASR (tracks are pre-sorted).</summary>
    public SubtitleChoice? PreferredTrack => Tracks.Count > 0 ? Tracks[0] : null;

    /// <summary>
    /// Normalizes a subtitle language code to a stable bucket key: lowercased, first '-' segment.
    /// So "ja", "ja-JP", "ja-orig" all collapse to "ja".
    /// </summary>
    public static string NormalizedLanguageCode(string code)
    {
        return LanguageCatalog.Normalize(code);
    }

    /// <summary>Sort rank for technical tracks within a language group.</summary>
    public static int TrackRank(SubtitleSourceKind kind) => kind switch
    {
        SubtitleSourceKind.Manual => 0,
        SubtitleSourceKind.PlatformAuto => 1,
        SubtitleSourceKind.HlsManifest => 2,
        SubtitleSourceKind.CloudAsr => 3,
        SubtitleSourceKind.LocalAsr => 4,
        SubtitleSourceKind.ImportedFile => 5,
        _ => 6,
    };

    /// <summary>
    /// Groups flat subtitle choices by normalized language code into ordered language choices.
    /// Group order follows first appearance of each language; tracks within a group are stably
    /// sorted by source rank. Deterministic, no regex.
    /// </summary>
    public static IReadOnlyList<SubtitleLanguageChoice> Aggregate(IReadOnlyList<SubtitleChoice> choices)
    {
        var order = new List<string>();
        var grouped = new Dictionary<string, List<SubtitleChoice>>(StringComparer.Ordinal);
        foreach (var choice in choices)
        {
            var key = NormalizedLanguageCode(choice.LanguageCode);
            if (key.Length == 0) continue;
            if (!grouped.TryGetValue(key, out var list))
            {
                list = [];
                grouped[key] = list;
                order.Add(key);
            }
            list.Add(choice);
        }
        return order.Select(key =>
        {
            var tracks = grouped[key]
                .Select((choice, index) => (choice, index))
                .OrderBy(pair => TrackRank(pair.choice.SourceKind))
                .ThenBy(pair => pair.index)
                .Select(pair => pair.choice)
                .ToList();
            var label = tracks.FirstOrDefault(t => t.SourceKind != SubtitleSourceKind.LocalAsr && t.SourceKind != SubtitleSourceKind.CloudAsr)?.Label
                ?? tracks.FirstOrDefault()?.Label
                ?? key;
            return new SubtitleLanguageChoice
            {
                LanguageCode = key,
                DisplayLabel = label,
                Tracks = tracks,
            };
        }).ToList();
    }
}

public sealed record VideoInfo
{
    public required string SourceUrl { get; init; }
    /// <summary>yt-dlp 信息里的视频 id（用于定位产出文件）。</summary>
    public required string VideoId { get; init; }
    public required string Title { get; init; }
    /// <summary>形如 "2:31"；未知为 null。</summary>
    public string? DurationText { get; init; }
    public string? ThumbnailUrl { get; init; }
    public string? Uploader { get; init; }
    /// <summary>yt-dlp language field, normalized by LanguageCatalog; null when unknown.</summary>
    public string? DetectedLanguageCode { get; init; }
    /// <summary>视频简介（yt-dlp description）；无简介为 null。用于 AI 总结的回退数据源。</summary>
    public string? Description { get; init; }
    /// <summary>按推荐顺序排列（第一个为推荐档），保证至少一个元素。</summary>
    public required IReadOnlyList<FormatChoice> Formats { get; init; }
    /// <summary>真实字幕在前、自动字幕在后；可能为空。</summary>
    public required IReadOnlyList<SubtitleChoice> Subtitles { get; init; }
}

// MARK: - 下载

public sealed record DownloadRequest
{
    public required string Url { get; init; }
    /// <summary>视频 id（来自 VideoInfo.VideoId），用于在目标目录中识别产出文件。</summary>
    public required string VideoId { get; init; }
    /// <summary>FormatChoice.Id。</summary>
    public required string FormatId { get; init; }
    /// <summary>选中的真实字幕语言代码。</summary>
    public IReadOnlyList<string> SubtitleLangs { get; init; } = [];
    /// <summary>选中的自动字幕语言代码。</summary>
    public IReadOnlyList<string> AutoSubtitleLangs { get; init; } = [];
    /// <summary>v0.8 stable subtitle source identity. Legacy language arrays remain for compatibility.</summary>
    public IReadOnlyList<SubtitleChoice> SubtitleTracks { get; init; } = [];
    /// <summary>The single primary subtitle source selected on the ready page.</summary>
    public string? PrimarySubtitleTrackId { get; init; }
    /// <summary>
    /// The language (normalized code) the user picked on the language-first ready page. The
    /// post-download source resolver uses this for language matching / quality fallback.
    /// null falls back to <see cref="PrimarySubtitleLanguageCode"/>.
    /// </summary>
    public string? PreferredSubtitleLanguageCode { get; init; }
    /// <summary>
    /// How the queue should resolve the final subtitle source after download. Default preserves the
    /// existing "pick best available, only run local ASR when needed" behavior.
    /// </summary>
    public SubtitleSourcePolicy SubtitleSourcePolicy { get; init; } = SubtitleSourcePolicy.AutoBest;
    public SubtitleIntent SubtitleIntent { get; init; } = SubtitleIntent.None;
    public SourceLanguageIntent SourceLanguageIntent { get; init; } = SourceLanguageIntent.Automatic;
    public required string DestinationDirectory { get; init; }
    /// <summary>
    /// 期望的文件名标题。直链/页面主视频的 yt-dlp 标题往往是 CDN 文件名
    /// （如 "homepage_trailer"），此时用嗅探得到的页面标题命名更友好；null 用 yt-dlp 默认标题。
    /// </summary>
    public string? PreferredTitle { get; init; }
    /// <summary>是否下载 HDR 版本（该档存在 HDR 源时）。</summary>
    public bool PreferHdr { get; init; }
    /// <summary>下载后转码目标格式；Original 表示不转码。</summary>
    public OutputFormat OutputFormat { get; init; } = OutputFormat.Original;

    public IReadOnlyList<SubtitleChoice> RequestedSubtitleTracks =>
        SubtitleTracks.Count > 0
            ? SubtitleTracks
            :
            [
                .. SubtitleLangs.Select(lang => SubtitleChoice.Create(lang, lang, SubtitleSourceKind.Manual)),
                .. AutoSubtitleLangs.Select(lang => SubtitleChoice.Create(lang, lang, SubtitleSourceKind.PlatformAuto)),
            ];

    public SubtitleChoice? PrimarySubtitleTrack
    {
        get
        {
            var requested = RequestedSubtitleTracks;
            if (!string.IsNullOrWhiteSpace(PrimarySubtitleTrackId))
            {
                var exact = requested.FirstOrDefault(track => track.Id == PrimarySubtitleTrackId);
                if (exact is not null) return exact;
            }
            return requested.FirstOrDefault(track => track.SourceKind == SubtitleSourceKind.Manual)
                ?? requested.FirstOrDefault(track => track.SourceKind == SubtitleSourceKind.PlatformAuto)
                ?? requested.FirstOrDefault();
        }
    }

    public string? PrimarySubtitleLanguageCode => PrimarySubtitleTrack?.LanguageCode;

    /// <summary>
    /// The language the post-download source resolver should match against: the user's
    /// language-first pick, falling back to the primary track's language.
    /// </summary>
    public string? EffectivePreferredLanguageCode => PreferredSubtitleLanguageCode ?? PrimarySubtitleTrack?.LanguageCode;

    public IReadOnlyList<string> YtDlpSubtitleLangs =>
        UniqueForYtDlpSubLangs(RequestedSubtitleTracks
            .Where(track => track.SourceKind == SubtitleSourceKind.Manual)
            .Select(track => track.LanguageCode));

    public IReadOnlyList<string> YtDlpAutoSubtitleLangs =>
        UniqueForYtDlpSubLangs(RequestedSubtitleTracks
            .Where(track => track.SourceKind == SubtitleSourceKind.PlatformAuto)
            .Select(track => track.LanguageCode));

    public static IReadOnlyList<string> UniqueForYtDlpSubLangs(IEnumerable<string> codes)
    {
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var result = new List<string>();
        foreach (var code in codes)
        {
            var normalized = code.Trim();
            if (normalized.Length == 0 || !seen.Add(normalized)) continue;
            result.Add(normalized);
        }
        return result;
    }
}

public sealed record DownloadProgress
{
    public enum ProgressPhase
    {
        Preparing,      // 启动 yt-dlp、握手中
        Downloading,    // 主体下载
        Processing,     // 合并 / 转码 / 字幕转换
        Finished,
    }

    public required ProgressPhase Phase { get; init; }
    /// <summary>0...100；未知为 null。</summary>
    public double? Percent { get; init; }
    public string? SpeedText { get; init; }
    public string? EtaText { get; init; }
}

public sealed record DownloadResult
{
    /// <summary>实际写入磁盘的文件（视频 + 字幕），绝对路径。</summary>
    public required IReadOnlyList<string> Files { get; init; }
}

// MARK: - 字幕翻译与烧录

/// <summary>烧录/输出字幕的样式。JSON 序列化值与 Swift 版一致（bilingual / chineseOnly）。</summary>
public enum SubtitleStyle
{
    /// <summary>中文在上、原文在下。</summary>
    Bilingual,
    /// <summary>仅中文。</summary>
    ChineseOnly,
}

/// <summary>
/// 细粒度源字幕片段。YouTube VTT 自动字幕常带词级时间戳，清洗器用它来判断字幕真正应在何时出现/消失。
/// </summary>
public sealed class SubtitleCueSourceFragment
{
    public double StartSeconds { get; }
    public double EndSeconds { get; }
    public string Text { get; }

    public SubtitleCueSourceFragment(double startSeconds, double endSeconds, string text)
    {
        StartSeconds = startSeconds;
        EndSeconds = endSeconds;
        Text = text;
    }
}

/// <summary>一条 SRT 字幕。</summary>
public sealed class SubtitleCue
{
    public int Index { get; }
    /// <summary>SRT 原始时间戳，如 "00:01:02,500"。</summary>
    public string Start { get; }
    public string End { get; }
    public string Text { get; set; }
    public IReadOnlyList<SubtitleCueSourceFragment> SourceFragments { get; }

    public SubtitleCue(
        int index,
        string start,
        string end,
        string text,
        IReadOnlyList<SubtitleCueSourceFragment>? sourceFragments = null)
    {
        Index = index;
        Start = start;
        End = end;
        Text = text;
        SourceFragments = sourceFragments ?? [];
    }
}

// MARK: - 接口

/// <summary>
/// 三步流水线：Resolve（一条链接里找出所有视频）→ Analyze（取格式与字幕）→ Download。
/// 默认实现 YtDlpEngine（Engine.cs）。
/// </summary>
public interface IDownloadEngine
{
    /// <summary>
    /// 第一步：解析用户粘贴的链接。
    /// yt-dlp 原生支持的 URL 直接返回单个 Supported 候选；不支持的页面抓取 HTML 嗅探内嵌视频；
    /// 一个都找不到时抛 SniffFailed。
    /// </summary>
    Task<IReadOnlyList<VideoCandidate>> ResolveCandidatesAsync(string input, CancellationToken ct = default);

    /// <summary>第二步：完整解析单个候选，返回格式与字幕选项。实现可缓存第一步信息避免重复请求。</summary>
    Task<VideoInfo> AnalyzeAsync(string url, CancellationToken ct = default);

    /// <summary>
    /// 第三步：按用户选择下载。进度经回调上报（任意线程）；
    /// control 非空时支持暂停（挂起进程树）与取消；引擎需负责终止子进程、不留僵尸进程。
    /// </summary>
    Task<DownloadResult> DownloadAsync(
        DownloadRequest request,
        TaskControlToken? control,
        Action<DownloadProgress> progress,
        CancellationToken ct = default);

    /// <summary>
    /// 拉取视频字幕纯文本（供 AI 总结优先使用）；取不到返回 null（调用方回退到简介）。
    /// </summary>
    Task<string?> FetchSubtitleTextAsync(
        string url,
        IReadOnlyList<string> preferredLanguages,
        TaskControlToken? control,
        CancellationToken ct = default);
}

/// <summary>
/// 字幕翻译器。默认实现 ConfiguredTranslator（Translator.cs）：
/// 按设置选择 Anthropic Messages API 或 OpenAI Responses API 调用配置的模型。
/// </summary>
public interface ISubtitleTranslator
{
    /// <summary>
    /// 把 srt 文件翻译成中文，按 style 生成新 srt（双语：中文在上原文在下；仅中文：替换原文），
    /// 写到 srt 同目录、文件名加 ".zh" 后缀；progress 为 0...1。
    /// YouTube 自动字幕的重叠滚动碎句会先被清洗、按句合并再翻译。
    /// control 非空时支持暂停（分块间挂起）与取消；失败抛 TranslateFailed。返回译文文件路径。
    /// </summary>
    Task<string> TranslateAsync(
        string srtFile,
        SubtitleStyle style,
        TaskControlToken? control,
        Action<double> progress,
        CancellationToken ct = default);
}

/// <summary>字幕烧录器。默认实现 FFmpegBurner（Burner.cs）：ffmpeg subtitles 滤镜硬烧录。</summary>
public interface ISubtitleBurner
{
    /// <summary>
    /// 把 subtitle 烧录进 video，输出 "&lt;原名&gt;（字幕版）.mp4" 风格的新文件（不覆盖原片）；
    /// outputTag 自定义文件名后缀标签（null 用默认「（字幕版）」）。
    /// maxHeight 非空且源更高时缩放到该高度；progress 为 0...1。
    /// backend 决定用硬件（NVENC/QSV/AMF）还是软件编码器；alwaysH264=true 时无视源编码强制 H.264（兼容优先）。
    /// control 非空时支持暂停/取消（挂起/终止 ffmpeg 进程树）。失败抛 BurnFailed。返回输出文件路径。
    /// </summary>
    Task<string> BurnAsync(
        string video,
        string subtitle,
        int? maxHeight,
        TaskControlToken? control,
        Action<double> progress,
        EncodeBackend backend = EncodeBackend.Auto,
        bool alwaysH264 = false,
        string? outputTag = null,
        CancellationToken ct = default);
}
