using System.Text.Json;
using Moongate.Core;

namespace MoongateCore.Tests;

public class OutputTemplateTests
{
    private const string Fallback = "%(title).180B [%(id)s].%(ext)s";

    [Fact]
    public void NullTitle_UsesDefaultTemplate() =>
        Assert.Equal(Fallback, YtDlpEngine.OutputTemplate(null));

    [Fact]
    public void PercentEscaped()
    {
        Assert.Equal("100%% Done [%(id)s].%(ext)s", YtDlpEngine.OutputTemplate("100% Done"));
    }

    [Fact]
    public void PathSeparatorsAndNewlinesBecomeSpaces()
    {
        Assert.Equal("a b c d [%(id)s].%(ext)s", YtDlpEngine.OutputTemplate("a/b\\c:d"));
        Assert.Equal("line1 line2 [%(id)s].%(ext)s", YtDlpEngine.OutputTemplate("line1\nline2"));
    }

    [Fact]
    public void LongTitle_TruncatedTo120Chars()
    {
        var title = new string('x', 150);
        var template = YtDlpEngine.OutputTemplate(title);
        Assert.Equal(new string('x', 120) + " [%(id)s].%(ext)s", template);
    }

    [Fact]
    public void TitleReducedToEmpty_FallsBack()
    {
        Assert.Equal(Fallback, YtDlpEngine.OutputTemplate("///"));
        Assert.Equal(Fallback, YtDlpEngine.OutputTemplate("   "));
    }
}

public class ProgressLineTests
{
    [Fact]
    public void MgpLine_ParsesPercentSpeedEta()
    {
        var progress = YtDlpEngine.ParseProgressLine("MGP|  12.5%|  1.2MiB/s|00:45");
        Assert.NotNull(progress);
        Assert.Equal(DownloadProgress.ProgressPhase.Downloading, progress.Phase);
        Assert.Equal(12.5, progress.Percent);
        Assert.Equal("1.2MiB/s", progress.SpeedText);
        Assert.Equal("00:45", progress.EtaText);
    }

    [Fact]
    public void MgpLine_UnknownFields_BecomeNull()
    {
        var progress = YtDlpEngine.ParseProgressLine("MGP| N/A | N/A |Unknown");
        Assert.NotNull(progress);
        Assert.Null(progress.Percent);
        Assert.Null(progress.SpeedText);
        Assert.Null(progress.EtaText);
    }

    [Fact]
    public void MgpLine_PercentClampedTo100()
    {
        var progress = YtDlpEngine.ParseProgressLine("MGP|105.0%|x|y");
        Assert.Equal(100, progress!.Percent);
    }

    [Theory]
    [InlineData("NaN")]
    [InlineData("Infinity")]
    [InlineData("-Infinity")]
    public void MgpLine_NonFinitePercent_BecomesNull(string token)
    {
        var progress = YtDlpEngine.ParseProgressLine($"MGP|{token}%|x|y");

        Assert.NotNull(progress);
        Assert.Null(progress.Percent);
    }

    [Fact]
    public void MgpLine_WithTrackerAggregatesSeparateMediaStreams()
    {
        var tracker = new YtDlpEngine.DownloadProgressTracker(expectedMediaDownloads: 2);
        var updates = new[]
        {
            "MGP| 0.0%| 1MiB/s|00:10",
            "MGP| 50.0%| 1MiB/s|00:05",
            "MGP|100.0%| 1MiB/s|00:00",
            "MGP| 0.0%| 500KiB/s|00:03",
            "MGP| 30.0%| 500KiB/s|00:02",
            "MGP|100.0%| 500KiB/s|00:00",
        }.Select(line => YtDlpEngine.ParseProgressLine(line, tracker)!).ToArray();

        Assert.Equal([0, 25, 50, 50, 65, 98], updates.Select(update => update.Percent).ToArray());
        Assert.All(updates, update => Assert.Null(update.EtaText));
    }

    [Fact]
    public void ExpectedMediaDownloadCount_ClassifiesKnownSelectors()
    {
        var exact4K = YtDlpEngine.VideoTierFormatSelector(2160);
        var hdr4K = YtDlpEngine.ApplyHdrPreference(exact4K, preferHdr: true);

        Assert.Equal(2, YtDlpEngine.ExpectedMediaDownloadCount(exact4K));
        Assert.Equal(2, YtDlpEngine.ExpectedMediaDownloadCount(hdr4K));
        Assert.Equal(1, YtDlpEngine.ExpectedMediaDownloadCount("ba[ext=m4a]/ba/best"));
        Assert.Equal(1, YtDlpEngine.ExpectedMediaDownloadCount("best"));
        Assert.Equal(1, YtDlpEngine.ExpectedMediaDownloadCount("b[dynamic_range=HDR10+]/best"));
    }

    [Fact]
    public void PostprocessPrefixes_MapToProcessing()
    {
        foreach (var line in new[]
        {
            "[Merger] Merging formats into \"a.mp4\"",
            "[ExtractAudio] Destination: a.m4a",
            "[SubtitleConvertor] Converting subtitles",
            "[FixupM4a] Correcting container",
        })
        {
            var progress = YtDlpEngine.ParseProgressLine(line);
            Assert.NotNull(progress);
            Assert.Equal(DownloadProgress.ProgressPhase.Processing, progress.Phase);
        }
    }

    [Fact]
    public void OtherLines_ReturnNull() =>
        Assert.Null(YtDlpEngine.ParseProgressLine("[download] Destination: a.mp4"));
}

public class HlsSubtitleParsingTests
{
    [Fact]
    public void SubtitleTrackIdsDistinguishSameLanguageSources()
    {
        var manual = SubtitleChoice.Create("ja", "Japanese", SubtitleSourceKind.Manual);
        var auto = SubtitleChoice.Create("ja", "Japanese auto", SubtitleSourceKind.PlatformAuto);
        var localAsr = SubtitleChoice.Create(
            "ja",
            "Japanese local ASR",
            SubtitleSourceKind.LocalAsr,
            provider: "whisper.cpp",
            variant: "ggml-small");

        Assert.Equal("ja", manual.LanguageCode);
        Assert.Equal("ja", auto.LanguageCode);
        Assert.Equal("ja", localAsr.LanguageCode);
        Assert.Equal(3, new HashSet<string> { manual.Id, auto.Id, localAsr.Id }.Count);
        Assert.False(manual.IsAuto);
        Assert.True(auto.IsAuto);
        Assert.False(localAsr.IsAuto);
        Assert.Equal(SubtitleSourceKind.Manual, SubtitleTrackId.Parse(manual.Id).SourceKind);
        Assert.Equal(SubtitleSourceKind.PlatformAuto, SubtitleTrackId.Parse(auto.Id).SourceKind);
        Assert.Equal("ja", SubtitleTrackId.Parse("ja").LanguageCode);
        Assert.Equal(SubtitleSourceKind.Manual, SubtitleTrackId.Parse("ja").SourceKind);
    }

    [Fact]
    public void DownloadRequestPrimarySubtitleTrackUsesStableIdentityWithManualFirstFallback()
    {
        var manual = SubtitleChoice.Create("ja", "Japanese", SubtitleSourceKind.Manual);
        var auto = SubtitleChoice.Create("ja", "Japanese auto", SubtitleSourceKind.PlatformAuto);
        var localAsr = SubtitleChoice.Create(
            "ja",
            "Japanese local ASR",
            SubtitleSourceKind.LocalAsr,
            provider: "whisper.cpp",
            variant: "small");

        var explicitRequest = new DownloadRequest
        {
            Url = "https://example.com/video",
            VideoId = "video",
            FormatId = "137",
            SubtitleTracks = [manual, auto, localAsr],
            PrimarySubtitleTrackId = localAsr.Id,
            DestinationDirectory = "/tmp",
        };
        Assert.Equal(localAsr.Id, explicitRequest.PrimarySubtitleTrack?.Id);
        Assert.Equal("ja", explicitRequest.PrimarySubtitleLanguageCode);

        var fallbackRequest = explicitRequest with { PrimarySubtitleTrackId = null, SubtitleTracks = [localAsr, auto, manual] };
        Assert.Equal(manual.Id, fallbackRequest.PrimarySubtitleTrack?.Id);
        Assert.Equal("ja", fallbackRequest.PrimarySubtitleLanguageCode);
    }

    [Fact]
    public void ParsesSubtitleMediaLines_ResolvesRelativeUris()
    {
        const string master = """
            #EXTM3U
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="English",LANGUAGE="en",URI="audio/en.m3u8"
            #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",DEFAULT=YES,LANGUAGE="en",URI="subtitles/eng/prog_index.m3u8"
            #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="简体中文",LANGUAGE="zh-Hans",URI="https://cdn.example.com/subs/zh.m3u8"
            #EXT-X-STREAM-INF:BANDWIDTH=1000000,SUBTITLES="subs"
            video/1080p.m3u8
            """;
        var baseUrl = new Uri("https://events.example.com/wwdc/master.m3u8");
        var entries = YtDlpEngine.ParseHlsSubtitleEntries(master, baseUrl);

        Assert.Equal(2, entries.Count);
        Assert.Equal("en", entries[0].Lang);
        Assert.Equal("English", entries[0].Name);
        Assert.Equal("https://events.example.com/wwdc/subtitles/eng/prog_index.m3u8", entries[0].Url);
        Assert.Equal("zh-Hans", entries[1].Lang);
        Assert.Equal("https://cdn.example.com/subs/zh.m3u8", entries[1].Url);
    }

    [Fact]
    public void MissingLanguageOrUri_Skipped()
    {
        const string master = """
            #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="NoLang",URI="x.m3u8"
            #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="NoUri",LANGUAGE="ja"
            """;
        var entries = YtDlpEngine.ParseHlsSubtitleEntries(master, new Uri("https://a.com/m.m3u8"));
        Assert.Empty(entries);
    }

    [Fact]
    public void UnquotedAttribute_Parsed()
    {
        Assert.Equal("subs", YtDlpEngine.HlsAttribute("GROUP-ID", "#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=subs,LANGUAGE=\"en\""));
        Assert.Equal("en", YtDlpEngine.HlsAttribute("LANGUAGE", "#EXT-X-MEDIA:LANGUAGE=\"en\",URI=\"a\""));
    }
}

public class DetectLoginRequiredTests
{
    private const string YoutubeUrl = "https://www.youtube.com/watch?v=abc";

    [Fact]
    public void SignInToConfirm_NoCookies_LoginRequired()
    {
        var error = YtDlpEngine.DetectLoginRequired(
            "ERROR: Sign in to confirm you're not a bot", YoutubeUrl, hasCookies: false);
        Assert.NotNull(error);
        Assert.Equal(MoongateErrorKind.LoginRequired, error.Kind);
        Assert.Equal("youtube.com", error.Detail);
    }

    [Fact]
    public void SignInToConfirm_WithCookies_SuggestsRelogin()
    {
        var error = YtDlpEngine.DetectLoginRequired(
            "ERROR: Sign in to confirm you're not a bot", YoutubeUrl, hasCookies: true);
        Assert.NotNull(error);
        Assert.Equal(MoongateErrorKind.DownloadFailed, error.Kind);
        Assert.Contains("登录信息可能已过期", error.Detail);
    }

    [Fact]
    public void Youtube403InLastErrorLine_NoCookies_LoginRequired()
    {
        var error = YtDlpEngine.DetectLoginRequired(
            "WARNING: something\nERROR: unable to download video data: HTTP Error 403: Forbidden",
            YoutubeUrl, hasCookies: false);
        Assert.NotNull(error);
        Assert.Equal(MoongateErrorKind.LoginRequired, error.Kind);
    }

    [Fact]
    public void Youtube403_WithCookies_SuggestsRelogin()
    {
        var error = YtDlpEngine.DetectLoginRequired(
            "ERROR: HTTP Error 403: Forbidden", YoutubeUrl, hasCookies: true);
        Assert.NotNull(error);
        Assert.Equal(MoongateErrorKind.DownloadFailed, error.Kind);
        Assert.Contains("403", error.Detail);
    }

    /// <summary>只看最后一条 ERROR 行：中间分片的瞬时 403 不触发登录判定。</summary>
    [Fact]
    public void Youtube403OnlyInMiddleErrorLine_NotLogin()
    {
        var error = YtDlpEngine.DetectLoginRequired(
            "ERROR: fragment 3: HTTP Error 403: Forbidden\nERROR: unable to continue without fragment",
            YoutubeUrl, hasCookies: false);
        Assert.Null(error);
    }

    [Fact]
    public void NonYoutube403_NotLogin()
    {
        var error = YtDlpEngine.DetectLoginRequired(
            "ERROR: HTTP Error 403: Forbidden", "https://example.com/v.mp4", hasCookies: false);
        Assert.Null(error);
    }

    [Fact]
    public void MembersOnlyPattern_LoginRequiredWithSite()
    {
        var error = YtDlpEngine.DetectLoginRequired(
            "ERROR: This video is members-only content", "https://www.example.com/v", hasCookies: false);
        Assert.NotNull(error);
        Assert.Equal(MoongateErrorKind.LoginRequired, error.Kind);
        Assert.Equal("example.com", error.Detail);  // www. 前缀剥掉
    }

    [Fact]
    public void ChinesePattern_Bilibili_LoginRequired()
    {
        var error = YtDlpEngine.DetectLoginRequired(
            "ERROR: 大会员专享，请登录后重试", "https://www.bilibili.com/video/BV1x", hasCookies: false);
        Assert.NotNull(error);
        Assert.Equal(MoongateErrorKind.LoginRequired, error.Kind);
        Assert.Equal("bilibili.com", error.Detail);
    }

    [Fact]
    public void Bilibili412WithoutSavedCookies_LoginRequired()
    {
        var error = YtDlpEngine.DetectLoginRequired(
            "ERROR: [BiliBili] BV1: Unable to download JSON metadata: HTTP Error 412: Precondition Failed",
            "https://www.bilibili.com/video/BV1x",
            hasCookies: false);

        Assert.NotNull(error);
        Assert.Equal(MoongateErrorKind.LoginRequired, error.Kind);
        Assert.Equal("bilibili.com", error.Detail);
    }

    [Fact]
    public void Bilibili412WithSavedCookies_NotLoginRequired()
    {
        var error = YtDlpEngine.DetectLoginRequired(
            "ERROR: [BiliBili] BV1: Unable to download JSON metadata: HTTP Error 412: Precondition Failed",
            "https://www.bilibili.com/video/BV1x",
            hasCookies: true);

        Assert.Null(error);
    }

    [Fact]
    public void InvalidUrl_EmptyHost_FallbackSiteName()
    {
        var error = YtDlpEngine.DetectLoginRequired("ERROR: login required", "not a url", hasCookies: false);
        Assert.NotNull(error);
        Assert.Equal("该站点", error.Detail);
    }
}

public class StderrSummaryTests
{
    [Fact]
    public void SummarizeStderr_PrefersLastErrorLine()
    {
        var summary = YtDlpEngine.SummarizeStderr(
            "WARNING: a\nERROR: first\nWARNING: b\nERROR: second problem\nINFO: tail");
        Assert.Equal("ERROR: second problem", summary);
    }

    [Fact]
    public void SummarizeStderr_FallsBackToLastLineOrUnknown()
    {
        Assert.Equal("plain tail", YtDlpEngine.SummarizeStderr("first\nplain tail\n"));
        Assert.Equal("未知错误", YtDlpEngine.SummarizeStderr("  \n  "));
    }

    [Fact]
    public void FriendlyDownloadReason_403GetsAntiLeechHint()
    {
        var reason = YtDlpEngine.FriendlyDownloadReason("ERROR: HTTP Error 403: Forbidden");
        Assert.StartsWith("资源拒绝访问（403）", reason);
        Assert.Contains("ERROR: HTTP Error 403: Forbidden", reason);
    }

    [Fact]
    public void FriendlyAnalyzeMessage_FormatNotAvailable_GetsRetryHint()
    {
        var message = YtDlpEngine.FriendlyAnalyzeMessage("ERROR: Requested format is not available");
        Assert.Contains("临时风控", message);
    }

    [Fact]
    public void RiskControlMessage_Bilibili412_GivesHonestHint()
    {
        var msg = YtDlpEngine.RiskControlMessage("ERROR: HTTP Error 412: Precondition Failed", "www.bilibili.com");
        Assert.NotNull(msg);
        Assert.Contains("哔哩哔哩", msg);
        Assert.Contains("412", msg);
    }

    [Fact]
    public void RiskControlMessage_NonRiskError_ReturnsNull()
    {
        Assert.Null(YtDlpEngine.RiskControlMessage("ERROR: something unrelated", "www.bilibili.com"));
    }

    [Fact]
    public void RiskControlMessage_412OnGenericHost_GivesGenericHint()
    {
        var msg = YtDlpEngine.RiskControlMessage("ERROR: 412 precondition failed", "example.com");
        Assert.NotNull(msg);
        Assert.DoesNotContain("哔哩哔哩", msg);
    }

    [Fact]
    public void FriendlyDownloadReason_NetworkError_GivesProxyHint()
    {
        var reason = YtDlpEngine.FriendlyDownloadReason("ERROR: Connection reset by peer");
        Assert.Contains("代理", reason);
    }

    [Fact]
    public void FriendlyDownloadReason_CertificateTrustError_GivesCertificateHint()
    {
        var reason = YtDlpEngine.FriendlyDownloadReason(
            "ERROR: [youtube] Unable to download API page: [SSL: CERTIFICATE_VERIFY_FAILED] certificate verify failed: unable to get local issuer certificate");

        Assert.Contains("证书", reason);
        Assert.Contains("系统时间", reason);
        Assert.Contains("根证书", reason);
    }

    [Fact]
    public void FriendlyAnalyzeMessage_CertificateTrustError_GivesCertificateHint()
    {
        var message = YtDlpEngine.FriendlyAnalyzeMessage(
            "ERROR: [youtube] Unable to download API page: [SSL: CERTIFICATE_VERIFY_FAILED] certificate verify failed: unable to get local issuer certificate");

        Assert.Contains("证书", message);
        Assert.Contains("系统时间", message);
        Assert.Contains("根证书", message);
    }

    [Fact]
    public void FriendlyAnalyzeMessage_YoutubeUnavailable_GivesProxyAndAccountHint()
    {
        var message = YtDlpEngine.FriendlyAnalyzeMessage("ERROR: [youtube] 7lUYtW6VpVE: Video unavailable");

        Assert.Contains("YouTube", message);
        Assert.Contains("同一个账号", message);
        Assert.Contains("代理", message);
    }

    [Fact]
    public void MakeProxyArguments_UsesNormalizedVideoProxy()
    {
        var args = YtDlpEngine.MakeProxyArguments(new AppSettings { VideoProxyUrl = "127.0.0.1:7890" });

        Assert.Equal(new[] { "--proxy", "http://127.0.0.1:7890" }, args);
    }

    [Fact]
    public void MakeProxyArguments_EmptyWhenNoVideoProxy()
    {
        Assert.Empty(YtDlpEngine.MakeProxyArguments(new AppSettings()));
    }

    [Fact]
    public void MakeNetworkArguments_IncludesProxyAndCertificateBypass()
    {
        var args = YtDlpEngine.MakeNetworkArguments(new AppSettings
        {
            VideoProxyUrl = "127.0.0.1:7890",
            IgnoreVideoCertificateErrors = true,
        });

        Assert.Equal(new[] { "--proxy", "http://127.0.0.1:7890", "--no-check-certificates" }, args);
    }

    [Fact]
    public void IsBilibiliHost_RecognizesVariants()
    {
        Assert.True(YtDlpEngine.IsBilibiliHost("bilibili.com"));
        Assert.True(YtDlpEngine.IsBilibiliHost("www.bilibili.com"));
        Assert.True(YtDlpEngine.IsBilibiliHost("b23.tv"));
        Assert.False(YtDlpEngine.IsBilibiliHost("youtube.com"));
    }

    [Theory]
    [InlineData("www.tiktok.com")]
    [InlineData("vt.tiktok.com")]
    [InlineData("v.douyin.com")]
    [InlineData("www.douyin.com")]
    [InlineData("www.xiaohongshu.com")]
    [InlineData("xhslink.com")]
    public void NativeExtractorHost_IncludesShortVideoSites(string host)
    {
        Assert.True(YtDlpEngine.IsNativeExtractorHost(host));
    }
}

public class YtDlpNetworkSettingsTests
{
    private sealed class CapturingJsonEngine : YtDlpEngine
    {
        public IReadOnlyList<string> LastArguments { get; private set; } = [];

        protected override Task<(int Status, string Stdout, string Stderr, bool TimedOut)> RunProcessHookAsync(
            string executable, IReadOnlyList<string> arguments, TimeSpan? timeout, CancellationToken ct)
        {
            LastArguments = arguments.ToArray();
            const string json = """{"id":"abc123","title":"Proxy Test","extractor_key":"Youtube"}""";
            return Task.FromResult((0, json, "", false));
        }
    }

    [Fact]
    public async Task ResolveCandidates_LoadsVideoNetworkSettingsForYtDlp()
    {
        var previousSupport = AppSettings.OverrideSupportDirectory;
        var previousYtDlp = Environment.GetEnvironmentVariable("MOONGATE_YTDLP_PATH");
        var previousFfmpeg = Environment.GetEnvironmentVariable("MOONGATE_FFMPEG_PATH");
        var dir = Path.Combine(Path.GetTempPath(), $"moongate-network-settings-{Guid.NewGuid():N}");
        Directory.CreateDirectory(dir);
        var probe = typeof(YtDlpNetworkSettingsTests).Assembly.Location;
        try
        {
            AppSettings.OverrideSupportDirectory = dir;
            Environment.SetEnvironmentVariable("MOONGATE_YTDLP_PATH", probe);
            Environment.SetEnvironmentVariable("MOONGATE_FFMPEG_PATH", probe);
            File.WriteAllText(AppSettings.SettingsFilePath, new AppSettings
            {
                VideoProxyUrl = "127.0.0.1:7890",
                IgnoreVideoCertificateErrors = true,
            }.ToJson());

            var engine = new CapturingJsonEngine();
            var candidates = await engine.ResolveCandidatesAsync("https://www.youtube.com/watch?v=abc123");

            Assert.Single(candidates);
            Assert.Equal("Proxy Test", candidates[0].Title);
            Assert.Contains("--proxy", engine.LastArguments);
            Assert.Contains("http://127.0.0.1:7890", engine.LastArguments);
            Assert.Contains("--no-check-certificates", engine.LastArguments);
        }
        finally
        {
            AppSettings.OverrideSupportDirectory = previousSupport;
            Environment.SetEnvironmentVariable("MOONGATE_YTDLP_PATH", previousYtDlp);
            Environment.SetEnvironmentVariable("MOONGATE_FFMPEG_PATH", previousFfmpeg);
            try { Directory.Delete(dir, recursive: true); } catch { /* ignore */ }
        }
    }
}

[Collection(L10nLanguageCollection.Name)]
public class EngineI18nTests
{
    [Fact]
    public void DetectLoginRequired_UsesTraditionalChineseMessages()
    {
        var previous = L10n.Language;
        L10n.Language = CoreLanguage.TraditionalChinese;
        try
        {
            var expired = YtDlpEngine.DetectLoginRequired(
                "ERROR: Sign in to confirm you're not a bot",
                "https://www.youtube.com/watch?v=abc",
                hasCookies: true);
            Assert.NotNull(expired);
            Assert.Equal(MoongateErrorKind.DownloadFailed, expired.Kind);
            Assert.Contains("登入資訊可能已過期", expired.Detail);
            Assert.DoesNotContain("登录信息可能已过期", expired.Detail);

            var fallbackSite = YtDlpEngine.DetectLoginRequired(
                "ERROR: login required",
                "not a url",
                hasCookies: false);
            Assert.NotNull(fallbackSite);
            Assert.Equal("該站點", fallbackSite.Detail);
        }
        finally
        {
            L10n.Language = previous;
        }
    }

    [Fact]
    public void FriendlyDownloadReason_UsesTraditionalChineseMessages()
    {
        var previous = L10n.Language;
        L10n.Language = CoreLanguage.TraditionalChinese;
        try
        {
            var forbidden = YtDlpEngine.FriendlyDownloadReason("ERROR: HTTP Error 403: Forbidden");
            Assert.StartsWith("資源拒絕存取（403）", forbidden);
            Assert.Contains("ERROR: HTTP Error 403: Forbidden", forbidden);

            var network = YtDlpEngine.FriendlyDownloadReason("ERROR: Connection reset by peer");
            Assert.Contains("網路連線不穩定", network);
            Assert.Contains("重試", network);
        }
        finally
        {
            L10n.Language = previous;
        }
    }

    [Fact]
    public void AnalyzeAndRiskControlMessages_UseTraditionalChineseMessages()
    {
        var previous = L10n.Language;
        L10n.Language = CoreLanguage.TraditionalChinese;
        try
        {
            var risk = YtDlpEngine.RiskControlMessage(
                "ERROR: HTTP Error 412: Precondition Failed",
                "www.bilibili.com");
            Assert.NotNull(risk);
            Assert.Contains("HTTP 412", risk);
            Assert.Contains("10–30 分鐘", risk);
            Assert.DoesNotContain("安全风控", risk);

            var genericRisk = YtDlpEngine.RiskControlMessage("ERROR: 412 precondition failed", "example.com");
            Assert.NotNull(genericRisk);
            Assert.Contains("訪問風控", genericRisk);

            var analyze = YtDlpEngine.FriendlyAnalyzeMessage("ERROR: Requested format is not available");
            Assert.Contains("暫時沒有返回可用的清晰度", analyze);
            Assert.DoesNotContain("临时风控", analyze);
        }
        finally
        {
            L10n.Language = previous;
        }
    }

    [Fact]
    public void SummarizeStderr_UnknownError_UsesTraditionalChinese()
    {
        var previous = L10n.Language;
        L10n.Language = CoreLanguage.TraditionalChinese;
        try
        {
            Assert.Equal("未知錯誤", YtDlpEngine.SummarizeStderr("  \n  "));
        }
        finally
        {
            L10n.Language = previous;
        }
    }
}

/// <summary>
/// 覆盖用户反馈的「首次点击下载失败、需点第二次」交互路径：
/// yt-dlp 首次返回 "Requested format is not available"（n-challenge 冷启动/临时风控），
/// 下载路径应自动重试一次而非把失败抛给用户。
/// </summary>
public class DownloadRetryTests
{
    /// <summary>脚本化下载进程钩子：第 1 次失败，第 2 次写出产物并成功。</summary>
    private sealed class ScriptedDownloadEngine : YtDlpEngine
    {
        public int Attempts { get; private set; }
        public IReadOnlyList<string> LastArguments { get; private set; } = [];
        private readonly string _destDir;
        private readonly string _videoId;
        private readonly string _firstStderr;
        public ScriptedDownloadEngine(string destDir, string videoId, string firstStderr = "ERROR: Requested format is not available")
        {
            _destDir = destDir;
            _videoId = videoId;
            _firstStderr = firstStderr;
        }

        protected override Task<(int Status, string StderrTail)> RunDownloadProcessHookAsync(
            string executable, IReadOnlyList<string> arguments,
            TimeSpan? stallTimeout, Func<bool>? isSuspended, Action<int>? onStart,
            Action<string>? onLine, CancellationToken ct)
        {
            Attempts++;
            LastArguments = arguments.ToList();
            if (Attempts == 1)
            {
                return Task.FromResult((1, _firstStderr));
            }
            // 第 2 次：产出真实文件并通过 onLine 汇报其路径（--print after_move:filepath 行为）。
            var outFile = Path.Combine(_destDir, $"video [{_videoId}].mp4");
            File.WriteAllText(outFile, "fake mp4 bytes");
            onLine?.Invoke(outFile);
            return Task.FromResult((0, ""));
        }
    }

    [Fact]
    public void VideoTierSelector_PrefersExactHeightBeforeLowerFallback()
    {
        var selector = YtDlpEngine.VideoTierFormatSelector(2160);

        Assert.Equal(
            "bv*[height=2160]+ba/b[height=2160]/bv*[height<=2160]+ba/b[height<=2160]",
            selector);
        Assert.True(
            selector.IndexOf("[height=2160]", StringComparison.Ordinal)
                < selector.IndexOf("[height<=2160]", StringComparison.Ordinal),
            "The 4K row must try exact 2160p before any <=2160 fallback, or yt-dlp may resolve it to 1080p.");
    }

    [Fact]
    public void HdrPreference_KeepsExactHeightBeforeLowerHdrFallback()
    {
        var selector = YtDlpEngine.ApplyHdrPreference(YtDlpEngine.VideoTierFormatSelector(2160), preferHdr: true);
        var branches = selector.Split('/');

        Assert.Equal(
            new[]
            {
                "bv*[dynamic_range!=SDR][height=2160]+ba",
                "bv*[height=2160]+ba",
                "b[height=2160]",
                "bv*[dynamic_range!=SDR][height<=2160]+ba",
                "bv*[height<=2160]+ba",
                "b[height<=2160]",
            },
            branches);
    }

    [Fact]
    public async Task DownloadWith4KSelector_PassesExactHeightFirstFormatToYtDlp()
    {
        var destDir = Path.Combine(Path.GetTempPath(), $"mg-dl-4k-selector-{Guid.NewGuid():N}");
        Directory.CreateDirectory(destDir);
        var probe = typeof(DownloadRetryTests).Assembly.Location;
        var prevYt = Environment.GetEnvironmentVariable("MOONGATE_YTDLP_PATH");
        var prevFf = Environment.GetEnvironmentVariable("MOONGATE_FFMPEG_PATH");
        Environment.SetEnvironmentVariable("MOONGATE_YTDLP_PATH", probe);
        Environment.SetEnvironmentVariable("MOONGATE_FFMPEG_PATH", probe);
        try
        {
            var engine = new ScriptedDownloadEngine(destDir, "uhd123");
            var request = new DownloadRequest
            {
                Url = "https://www.youtube.com/watch?v=uhd123",
                VideoId = "uhd123",
                FormatId = YtDlpEngine.VideoTierFormatSelector(2160),
                DestinationDirectory = destDir,
            };

            _ = await engine.DownloadAsync(request, control: null, progress: _ => { });

            var formatIndex = Assert.Single(
                Enumerable.Range(0, engine.LastArguments.Count),
                i => engine.LastArguments[i] == "-f");
            Assert.Equal(
                "bv*[height=2160]+ba/b[height=2160]/bv*[height<=2160]+ba/b[height<=2160]",
                engine.LastArguments[formatIndex + 1]);
        }
        finally
        {
            Environment.SetEnvironmentVariable("MOONGATE_YTDLP_PATH", prevYt);
            Environment.SetEnvironmentVariable("MOONGATE_FFMPEG_PATH", prevFf);
            try { Directory.Delete(destDir, recursive: true); } catch { /* 忽略 */ }
        }
    }

    [Fact]
    public async Task AutoSubtitleDownload_PreservesRawVttTiming()
    {
        var destDir = Path.Combine(Path.GetTempPath(), $"mg-dl-auto-vtt-{Guid.NewGuid():N}");
        Directory.CreateDirectory(destDir);
        var probe = typeof(DownloadRetryTests).Assembly.Location;
        var prevYt = Environment.GetEnvironmentVariable("MOONGATE_YTDLP_PATH");
        var prevFf = Environment.GetEnvironmentVariable("MOONGATE_FFMPEG_PATH");
        Environment.SetEnvironmentVariable("MOONGATE_YTDLP_PATH", probe);
        Environment.SetEnvironmentVariable("MOONGATE_FFMPEG_PATH", probe);
        try
        {
            var engine = new ScriptedDownloadEngine(destDir, "abc123");
            var request = new DownloadRequest
            {
                Url = "https://www.youtube.com/watch?v=abc123",
                VideoId = "abc123",
                FormatId = "137",
                AutoSubtitleLangs = ["it-orig"],
                DestinationDirectory = destDir,
            };

            _ = await engine.DownloadAsync(request, control: null, progress: _ => { });

            Assert.Contains("--write-auto-subs", engine.LastArguments);
            Assert.Contains("--sub-format", engine.LastArguments);
            Assert.Contains("vtt/best", engine.LastArguments);
            Assert.DoesNotContain("--convert-subs", engine.LastArguments);
        }
        finally
        {
            Environment.SetEnvironmentVariable("MOONGATE_YTDLP_PATH", prevYt);
            Environment.SetEnvironmentVariable("MOONGATE_FFMPEG_PATH", prevFf);
            try { Directory.Delete(destDir, recursive: true); } catch { /* 忽略 */ }
        }
    }

    [Fact]
    public async Task ManualSubtitleDownload_KeepsSrtConversionCompatibility()
    {
        var destDir = Path.Combine(Path.GetTempPath(), $"mg-dl-manual-srt-{Guid.NewGuid():N}");
        Directory.CreateDirectory(destDir);
        var probe = typeof(DownloadRetryTests).Assembly.Location;
        var prevYt = Environment.GetEnvironmentVariable("MOONGATE_YTDLP_PATH");
        var prevFf = Environment.GetEnvironmentVariable("MOONGATE_FFMPEG_PATH");
        Environment.SetEnvironmentVariable("MOONGATE_YTDLP_PATH", probe);
        Environment.SetEnvironmentVariable("MOONGATE_FFMPEG_PATH", probe);
        try
        {
            var engine = new ScriptedDownloadEngine(destDir, "abc123");
            var request = new DownloadRequest
            {
                Url = "https://www.youtube.com/watch?v=abc123",
                VideoId = "abc123",
                FormatId = "137",
                SubtitleLangs = ["en"],
                DestinationDirectory = destDir,
            };

            _ = await engine.DownloadAsync(request, control: null, progress: _ => { });

            Assert.Contains("--write-subs", engine.LastArguments);
            Assert.Contains("--convert-subs", engine.LastArguments);
            Assert.Contains("srt", engine.LastArguments);
            Assert.DoesNotContain("--sub-format", engine.LastArguments);
        }
        finally
        {
            Environment.SetEnvironmentVariable("MOONGATE_YTDLP_PATH", prevYt);
            Environment.SetEnvironmentVariable("MOONGATE_FFMPEG_PATH", prevFf);
            try { Directory.Delete(destDir, recursive: true); } catch { /* 忽略 */ }
        }
    }

    [Fact]
    public async Task LocalAsrSubtitleTrack_DoesNotInvokeYtDlpSubtitleDownload()
    {
        var destDir = Path.Combine(Path.GetTempPath(), $"mg-dl-local-asr-{Guid.NewGuid():N}");
        Directory.CreateDirectory(destDir);
        var probe = typeof(DownloadRetryTests).Assembly.Location;
        var prevYt = Environment.GetEnvironmentVariable("MOONGATE_YTDLP_PATH");
        var prevFf = Environment.GetEnvironmentVariable("MOONGATE_FFMPEG_PATH");
        Environment.SetEnvironmentVariable("MOONGATE_YTDLP_PATH", probe);
        Environment.SetEnvironmentVariable("MOONGATE_FFMPEG_PATH", probe);
        try
        {
            var engine = new ScriptedDownloadEngine(destDir, "abc123");
            var request = new DownloadRequest
            {
                Url = "https://www.youtube.com/watch?v=abc123",
                VideoId = "abc123",
                FormatId = "137",
                SubtitleTracks =
                [
                    SubtitleChoice.Create(
                        "ja",
                        "Japanese local ASR",
                        SubtitleSourceKind.LocalAsr,
                        provider: "whisper.cpp",
                        variant: "small"),
                ],
                DestinationDirectory = destDir,
            };

            _ = await engine.DownloadAsync(request, control: null, progress: _ => { });

            Assert.DoesNotContain("--sub-langs", engine.LastArguments);
            Assert.DoesNotContain("--write-subs", engine.LastArguments);
            Assert.DoesNotContain("--write-auto-subs", engine.LastArguments);
        }
        finally
        {
            Environment.SetEnvironmentVariable("MOONGATE_YTDLP_PATH", prevYt);
            Environment.SetEnvironmentVariable("MOONGATE_FFMPEG_PATH", prevFf);
            try { Directory.Delete(destDir, recursive: true); } catch { /* 忽略 */ }
        }
    }

    [Fact]
    public async Task FirstAttemptFormatUnavailable_AutoRetriesAndSucceeds()
    {
        var destDir = Path.Combine(Path.GetTempPath(), $"mg-dl-retry-{Guid.NewGuid():N}");
        Directory.CreateDirectory(destDir);
        // YtDlpPath()/FfmpegDirectory() 在下载前解析二进制；指向任意存在文件即可（实际执行被钩子替换）。
        var probe = typeof(DownloadRetryTests).Assembly.Location;
        var prevYt = Environment.GetEnvironmentVariable("MOONGATE_YTDLP_PATH");
        var prevFf = Environment.GetEnvironmentVariable("MOONGATE_FFMPEG_PATH");
        Environment.SetEnvironmentVariable("MOONGATE_YTDLP_PATH", probe);
        Environment.SetEnvironmentVariable("MOONGATE_FFMPEG_PATH", probe);
        try
        {
            var engine = new ScriptedDownloadEngine(destDir, "abc123");
            var request = new DownloadRequest
            {
                Url = "https://www.youtube.com/watch?v=abc123",
                VideoId = "abc123",
                FormatId = "137",
                DestinationDirectory = destDir,
            };
            var result = await engine.DownloadAsync(request, control: null, progress: _ => { });

            Assert.Equal(2, engine.Attempts); // 首次失败后确实自动重试了一次
            Assert.NotEmpty(result.Files);
            Assert.Contains(result.Files, f => f.EndsWith(".mp4"));
        }
        finally
        {
            Environment.SetEnvironmentVariable("MOONGATE_YTDLP_PATH", prevYt);
            Environment.SetEnvironmentVariable("MOONGATE_FFMPEG_PATH", prevFf);
            try { Directory.Delete(destDir, recursive: true); } catch { /* 忽略 */ }
        }
    }

    [Fact]
    public async Task FirstAttemptYoutube403_AutoRetriesAndSucceeds()
    {
        var destDir = Path.Combine(Path.GetTempPath(), $"mg-dl-yt403-retry-{Guid.NewGuid():N}");
        Directory.CreateDirectory(destDir);
        var probe = typeof(DownloadRetryTests).Assembly.Location;
        var prevYt = Environment.GetEnvironmentVariable("MOONGATE_YTDLP_PATH");
        var prevFf = Environment.GetEnvironmentVariable("MOONGATE_FFMPEG_PATH");
        Environment.SetEnvironmentVariable("MOONGATE_YTDLP_PATH", probe);
        Environment.SetEnvironmentVariable("MOONGATE_FFMPEG_PATH", probe);
        try
        {
            var engine = new ScriptedDownloadEngine(
                destDir, "abc123", "ERROR: unable to download video data: HTTP Error 403: Forbidden");
            var request = new DownloadRequest
            {
                Url = "https://youtu.be/abc123",
                VideoId = "abc123",
                FormatId = "18",
                DestinationDirectory = destDir,
            };

            var result = await engine.DownloadAsync(request, control: null, progress: _ => { });

            Assert.Equal(2, engine.Attempts);
            Assert.Contains(result.Files, f => f.EndsWith(".mp4"));
        }
        finally
        {
            Environment.SetEnvironmentVariable("MOONGATE_YTDLP_PATH", prevYt);
            Environment.SetEnvironmentVariable("MOONGATE_FFMPEG_PATH", prevFf);
            try { Directory.Delete(destDir, recursive: true); } catch { /* 忽略 */ }
        }
    }

    [Fact]
    public async Task FirstAttemptOtherError_DoesNotRetry()
    {
        var destDir = Path.Combine(Path.GetTempPath(), $"mg-dl-noretry-{Guid.NewGuid():N}");
        Directory.CreateDirectory(destDir);
        var probe = typeof(DownloadRetryTests).Assembly.Location;
        var prevYt = Environment.GetEnvironmentVariable("MOONGATE_YTDLP_PATH");
        var prevFf = Environment.GetEnvironmentVariable("MOONGATE_FFMPEG_PATH");
        Environment.SetEnvironmentVariable("MOONGATE_YTDLP_PATH", probe);
        Environment.SetEnvironmentVariable("MOONGATE_FFMPEG_PATH", probe);
        try
        {
            var engine = new NonRetryableEngine();
            var request = new DownloadRequest
            {
                Url = "https://www.youtube.com/watch?v=abc123",
                VideoId = "abc123",
                FormatId = "137",
                DestinationDirectory = destDir,
            };
            await Assert.ThrowsAsync<MoongateException>(() =>
                engine.DownloadAsync(request, control: null, progress: _ => { }));
            Assert.Equal(1, engine.Attempts); // 非可恢复错误：不重试
        }
        finally
        {
            Environment.SetEnvironmentVariable("MOONGATE_YTDLP_PATH", prevYt);
            Environment.SetEnvironmentVariable("MOONGATE_FFMPEG_PATH", prevFf);
            try { Directory.Delete(destDir, recursive: true); } catch { /* 忽略 */ }
        }
    }

    [Fact]
    public void RecoverableDownloadRetry_DoesNotTreatNonYoutube403AsTransient()
    {
        Assert.False(YtDlpEngine.IsRecoverableDownloadRetry(
            "ERROR: unable to download video data: HTTP Error 403: Forbidden",
            "https://example.com/video.mp4"));
    }

    private sealed class NonRetryableEngine : YtDlpEngine
    {
        public int Attempts { get; private set; }
        protected override Task<(int Status, string StderrTail)> RunDownloadProcessHookAsync(
            string executable, IReadOnlyList<string> arguments,
            TimeSpan? stallTimeout, Func<bool>? isSuspended, Action<int>? onStart,
            Action<string>? onLine, CancellationToken ct)
        {
            Attempts++;
            return Task.FromResult((1, "ERROR: HTTP Error 404: Not Found"));
        }
    }
}

public class BuildVideoInfoTests
{
    private static JsonElement ParseJson(string json)
    {
        using var doc = JsonDocument.Parse(json);
        return doc.RootElement.Clone();
    }

    /// <summary>测试替身：屏蔽网络/子进程钩子。</summary>
    private sealed class OfflineEngine : YtDlpEngine
    {
        protected override Task<string?> FetchTextAsync(Uri url, CancellationToken ct) =>
            Task.FromResult<string?>(null);
        protected override Task<ProbeInfo?> RunFfProbeAsync(string urlString, CancellationToken ct) =>
            Task.FromResult<ProbeInfo?>(null);
        protected override Task<double?> HeadContentLengthAsync(string urlString, CancellationToken ct) =>
            Task.FromResult<double?>(null);
    }

    [Fact]
    public async Task FormatTiers_SortedDescending_TopUsesExplicitHeightBoundSelector()
    {
        var json = ParseJson("""
            {
              "id": "abc123",
              "title": "Test Video",
              "duration": 151,
              "uploader": "Someone",
              "language": "fr",
              "formats": [
                {"format_id":"137","vcodec":"avc1","acodec":"none","height":1080,"tbr":4000,"filesize":104857600},
                {"format_id":"136","vcodec":"avc1","acodec":"none","height":720,"tbr":2000,"filesize_approx":52428800},
                {"format_id":"140","vcodec":"none","acodec":"mp4a","abr":128,"filesize":10485760}
              ],
              "subtitles": {"en": [{}], "live_chat": [{}]},
              "automatic_captions": {"en": [{}], "ja": [{}], "fr": [{}], "xx": [{}]}
            }
            """);
        var info = await new OfflineEngine().BuildVideoInfoAsync("https://www.youtube.com/watch?v=abc123", json);

        Assert.Equal("abc123", info.VideoId);
        Assert.Equal("Test Video", info.Title);
        Assert.Equal("2:31", info.DurationText);
        Assert.Equal("Someone", info.Uploader);

        // 1080p 推荐档、720p 档都精确优先并带降级回退；末尾音频档。
        Assert.Equal(3, info.Formats.Count);
        Assert.Equal("bv*[height=1080]+ba/b[height=1080]/bv*[height<=1080]+ba/b[height<=1080]", info.Formats[0].Id);
        Assert.Equal("1080p · mp4", info.Formats[0].Label);
        Assert.Equal("≈ 110 MB", info.Formats[0].Detail);  // 100MB 视频 + 10MB 最佳音轨
        Assert.Equal("bv*[height=720]+ba/b[height=720]/bv*[height<=720]+ba/b[height<=720]", info.Formats[1].Id);
        Assert.Equal("≈ 60 MB", info.Formats[1].Detail);
        Assert.True(info.Formats[^1].IsAudioOnly);
        Assert.Equal("audio", info.Formats[^1].Id);

        // 字幕：真实 en（live_chat 剔除）在前；同语言自动字幕保留为独立稳定来源。
        Assert.Equal(4, info.Subtitles.Count);
        Assert.Equal("en", info.Subtitles[0].LanguageCode);
        Assert.False(info.Subtitles[0].IsAuto);
        Assert.Equal(SubtitleSourceKind.Manual, info.Subtitles[0].SourceKind);
        Assert.Equal("en", info.Subtitles[1].LanguageCode);
        Assert.True(info.Subtitles[1].IsAuto);
        Assert.Equal(SubtitleSourceKind.PlatformAuto, info.Subtitles[1].SourceKind);
        Assert.NotEqual(info.Subtitles[0].Id, info.Subtitles[1].Id);
        Assert.Equal("ja", info.Subtitles[2].LanguageCode);  // 白名单 ja
        Assert.True(info.Subtitles[2].IsAuto);
        Assert.Equal("fr", info.Subtitles[3].LanguageCode);  // 视频语言前缀命中
        Assert.True(info.Subtitles[3].IsAuto);
    }

    [Fact]
    public async Task FormatTiers_4KTopTierUsesExplicitHeightBoundSelector()
    {
        var json = ParseJson("""
            {
              "id": "uhd123",
              "title": "UHD Test",
              "formats": [
                {"format_id":"401","vcodec":"av01","acodec":"none","height":2160,"tbr":12000,"filesize":419430400},
                {"format_id":"248","vcodec":"vp9","acodec":"none","height":1080,"tbr":5000,"filesize":104857600},
                {"format_id":"140","vcodec":"none","acodec":"mp4a","abr":128,"filesize":10485760}
              ]
            }
            """);

        var info = await new OfflineEngine().BuildVideoInfoAsync("https://www.youtube.com/watch?v=uhd123", json);

        Assert.Equal("2160p · mp4", info.Formats[0].Label);
        Assert.Equal("bv*[height=2160]+ba/b[height=2160]/bv*[height<=2160]+ba/b[height<=2160]", info.Formats[0].Id);
    }

    [Fact]
    public async Task DirectFile_SingleBestFormat()
    {
        var json = ParseJson("""
            {
              "id": "trailer",
              "title": "homepage_trailer",
              "ext": "mp4",
              "url": "https://cdn.example.com/trailer.mp4",
              "formats": [{"format_id":"0","url":"https://cdn.example.com/trailer.mp4","filesize":31457280}]
            }
            """);
        var info = await new OfflineEngine().BuildVideoInfoAsync("https://cdn.example.com/trailer.mp4", json);

        Assert.Equal(2, info.Formats.Count);
        Assert.Equal("best", info.Formats[0].Id);
        Assert.Equal("原始文件 · mp4", info.Formats[0].Label);
        Assert.Equal("≈ 30 MB", info.Formats[0].Detail);
        Assert.True(info.Formats[1].IsAudioOnly);
        Assert.Empty(info.Subtitles);
    }

    [Fact]
    public void SubtitleSortKey_ChineseFirstThenEnglishJapanese()
    {
        var codes = new[] { "fr", "ja", "en", "zh-Hans", "en-orig", "zh" };
        var sorted = codes
            .OrderBy(c => YtDlpEngine.SubtitleSortKey(c).Rank)
            .ThenBy(c => YtDlpEngine.SubtitleSortKey(c).Lower, StringComparer.Ordinal)
            .ToArray();
        Assert.Equal(new[] { "zh", "zh-Hans", "en", "en-orig", "ja", "fr" }, sorted);
    }

    [Fact]
    public void FormatDurationAndSizeText()
    {
        Assert.Equal("2:31", YtDlpEngine.FormatDuration(151));
        Assert.Equal("1:00:05", YtDlpEngine.FormatDuration(3605));
        Assert.Equal("≈ 1 MB", YtDlpEngine.SizeText(100));  // 不足 1MB 取下限 1
        Assert.Equal("≈ 30 MB", YtDlpEngine.SizeText(31457280));
    }

    [Fact]
    public void IsYouTubeHost_Boundaries()
    {
        Assert.True(YtDlpEngine.IsYouTubeHost("youtu.be"));
        Assert.True(YtDlpEngine.IsYouTubeHost("www.youtube.com"));
        Assert.True(YtDlpEngine.IsYouTubeHost("youtube-nocookie.com"));
        Assert.False(YtDlpEngine.IsYouTubeHost("notyoutube.com"));
        Assert.False(YtDlpEngine.IsYouTubeHost("youtube.com.evil.com"));
    }

    [Fact]
    public void LangCodeOfSubtitle_ParsesFromFileName()
    {
        Assert.Equal("en", YtDlpEngine.LangCodeOfSubtitle("/tmp/Video [abc].en.srt"));
        Assert.Equal("zh-hans", YtDlpEngine.LangCodeOfSubtitle("/tmp/Video [abc].zh-Hans.srt"));
        Assert.Null(YtDlpEngine.LangCodeOfSubtitle("/tmp/video.srt"));
    }
}
