using System.Text.Json;

namespace Moongate.Core;

public enum TranslationProvider
{
    Anthropic,
    Openai,
}

/// <summary>视频编码后端。决定烧录/转码时优先走硬件媒体引擎还是兼容编码路径。</summary>
public enum EncodeBackend
{
    /// <summary>自动：优先使用可用的硬件媒体引擎；遇到兼容性问题时走兼容路径。日常推荐。</summary>
    Auto,
    /// <summary>优先硬件媒体引擎（NVENC→QSV→AMF）。最快、最省电；特殊格式可能需要兼容处理。</summary>
    Hardware,
    /// <summary>兼容性更稳定的编码路径。同体积画质更稳，但 4K/HDR 通常更慢。</summary>
    Software,
}

public static class EncodeBackendExtensions
{
    /// <summary>JSON 持久化值（与 Swift 版 rawValue 一致）。</summary>
    public static string RawValue(this EncodeBackend backend) => backend switch
    {
        EncodeBackend.Hardware => "hardware",
        EncodeBackend.Software => "software",
        _ => "auto",
    };

    public static EncodeBackend FromRawValue(string? raw) => raw switch
    {
        "hardware" => EncodeBackend.Hardware,
        "software" => EncodeBackend.Software,
        _ => EncodeBackend.Auto,
    };

    /// <summary>是否倾向硬件路径（Auto/Hardware）；实际是否真用硬件还要看探测结果。</summary>
    public static bool PrefersHardware(this EncodeBackend backend) => backend != EncodeBackend.Software;
}

public static class TranslationProviderExtensions
{
    public static string DefaultBaseUrl(this TranslationProvider provider) => provider switch
    {
        TranslationProvider.Anthropic => "https://api.anthropic.com",
        TranslationProvider.Openai => "https://api.openai.com",
        _ => "https://api.anthropic.com",
    };

    /// <summary>JSON 持久化值（与 Swift 版 rawValue 一致）。</summary>
    public static string RawValue(this TranslationProvider provider) => provider switch
    {
        TranslationProvider.Openai => "openai",
        _ => "anthropic",
    };

    public static TranslationProvider? FromRawValue(string? raw) => raw switch
    {
        "anthropic" => TranslationProvider.Anthropic,
        "openai" => TranslationProvider.Openai,
        _ => null,
    };
}

/// <summary>
/// App 设置。持久化在 %APPDATA%\Moongate\settings.json。
/// 注意：AuthToken 属于敏感凭证，只落在本地配置文件，绝不写入代码、日志或版本库。
/// 字段名与 Swift 版 settings.json 完全一致，便于排查问题时对照。
/// </summary>
public sealed record AppSettings
{
    /// <summary>翻译接口协议。</summary>
    public TranslationProvider TranslationProvider { get; init; } = TranslationProvider.Anthropic;
    /// <summary>翻译服务地址（官方 API 或企业网关），不含 /v1/messages 或 /v1/responses 路径。</summary>
    public string TranslationBaseUrl { get; init; } = TranslationProvider.Anthropic.DefaultBaseUrl();
    /// <summary>模型名，例如 "claude-haiku-4-5" 或网关侧的模型标识。</summary>
    public string TranslationModel { get; init; } = "";
    /// <summary>API 凭证（x-api-key / Bearer token）。</summary>
    public string TranslationAuthToken { get; init; } = "";
    /// <summary>默认 AI 接口协议。Windows 版仅支持 Anthropic/OpenAI 兼容云端协议。</summary>
    public TranslationProvider AIProvider { get; init; } = TranslationProvider.Anthropic;
    /// <summary>默认 AI 服务地址；翻译/总结跟随默认时使用。</summary>
    public string AIBaseUrl { get; init; } = TranslationProvider.Anthropic.DefaultBaseUrl();
    /// <summary>默认 AI 模型名。</summary>
    public string AIModel { get; init; } = "";
    /// <summary>默认 AI API 凭证。</summary>
    public string AIAuthToken { get; init; } = "";
    /// <summary>翻译是否跟随默认 AI 配置；Windows 当前设置窗保持跟随默认。</summary>
    public bool TranslationFollowsDefault { get; init; } = true;
    /// <summary>AI 总结是否跟随默认 AI 配置。</summary>
    public bool SummaryFollowsDefault { get; init; } = true;
    /// <summary>总结单独覆盖协议。</summary>
    public TranslationProvider SummaryProvider { get; init; } = TranslationProvider.Anthropic;
    /// <summary>总结单独覆盖服务地址。</summary>
    public string SummaryBaseUrl { get; init; } = TranslationProvider.Anthropic.DefaultBaseUrl();
    /// <summary>总结单独覆盖模型名。</summary>
    public string SummaryModel { get; init; } = "";
    /// <summary>总结单独覆盖 API 凭证。</summary>
    public string SummaryAuthToken { get; init; } = "";
    /// <summary>烧录字幕样式。</summary>
    public SubtitleStyle SubtitleStyle { get; init; } = SubtitleStyle.Bilingual;
    /// <summary>
    /// 烧录时限制最大分辨率高度：源高于此值则缩放到此值（既快又小）。
    /// null = 保持源分辨率。默认保持源分辨率，避免 4K 选择被静默压到 1080。
    /// </summary>
    public int? MaxBurnHeight { get; init; }
    /// <summary>同时进行的下载任务数（1...5，默认 3）。</summary>
    public int MaxConcurrentDownloads { get; init; } = 3;
    /// <summary>同时进行的压制（烧录）任务数（1...3，默认 2）。兼容路径并行多了会互相拖慢。</summary>
    public int MaxConcurrentBurns { get; init; } = 2;
    /// <summary>烧录/转码的视频编码后端：Auto（硬件优先）/ Hardware / Software。默认 Auto。</summary>
    public EncodeBackend EncodeBackend { get; init; } = EncodeBackend.Auto;
    /// <summary>烧录字幕时是否始终输出 H.264（兼容优先）。false=跟随源编码（HEVC 源保 HEVC）。默认 false。</summary>
    public bool BurnAlwaysH264 { get; init; }
    /// <summary>界面语言："auto"（跟随系统）、"zh-Hans"、"zh-Hant"、"en"。与翻译目标语言相互独立。</summary>
    public string AppLanguage { get; init; } = "auto";
    /// <summary>字幕翻译目标语言："zh-Hans" / "zh-Hant" / "en"。默认 zh-Hans 以保证老用户升级后行为不变。</summary>
    public string TranslationTargetLanguage { get; init; } = "zh-Hans";
    /// <summary>默认原声/源字幕语言："auto" / "ja" / "en" / "ko" / "zh-Hans" / "zh-Hant" / "yue"。</summary>
    public string PreferredSourceLanguage { get; init; } = "auto";
    /// <summary>首启引导是否已完成。</summary>
    public bool OnboardingCompleted { get; init; }
    /// <summary>开启后，字幕翻译前会先用总结模型分析内容类型，再选择更合适的翻译提示词预设。</summary>
    public bool SmartTranslationPromptsEnabled { get; init; }
    /// <summary>是否允许下载流水线调用本地 whisper.cpp。默认关闭；不静默下载模型。</summary>
    public bool LocalAsrEnabled { get; init; }
    /// <summary>whisper.cpp 可执行文件路径（例如 whisper-cli.exe）。</summary>
    public string LocalAsrRuntimePath { get; init; } = "";
    /// <summary>本地 ASR 模型文件路径（ggml*.bin）。</summary>
    public string LocalAsrModelPath { get; init; } = "";
    /// <summary>用户选择/安装的模型标识，用于缓存与 UI 展示。</summary>
    public string LocalAsrModelId { get; init; } = "";
    /// <summary>是否优先使用用户配置的本地精准识别 sidecar。默认关闭；不自动下载 Python/模型。</summary>
    public bool LocalAsrPreciseModeEnabled { get; init; }
    /// <summary>本地精准识别 sidecar 可执行文件路径。契约：接收 --input/--output/--language/--model/--format srt。</summary>
    public string LocalAsrSidecarRuntimePath { get; init; } = "";
    /// <summary>本地精准识别 sidecar 模型或模型目录路径。</summary>
    public string LocalAsrSidecarModelPath { get; init; } = "";
    /// <summary>是否允许上传音频到用户配置的云端转写服务。默认关闭，避免隐式上传。</summary>
    public bool CloudAsrEnabled { get; init; }
    /// <summary>用户是否已确认云端识别会上传音频且可能产生 API 费用。</summary>
    public bool CloudAsrConsentAccepted { get; init; }
    /// <summary>OpenAI-compatible 转写服务地址；默认 OpenAI 官方根地址。</summary>
    public string CloudAsrBaseUrl { get; init; } = "https://api.openai.com";
    /// <summary>可直接返回 SRT/VTT 的转写模型。默认 whisper-1；新模型需要 alignment 前不作为直接字幕源。</summary>
    public string CloudAsrModel { get; init; } = "whisper-1";
    /// <summary>云端转写 API 凭证，使用独立安全存储槽，不复用翻译凭证。</summary>
    public string CloudAsrAuthToken { get; init; } = "";
    /// <summary>队列完成时是否允许发完成提醒。默认开；前台 App 仍优先使用应用内状态。</summary>
    public bool CompletionNotificationsEnabled { get; init; } = true;
    /// <summary>队列完成时是否播放提示音。默认开，满足长任务完成后的可感知提醒。</summary>
    public bool CompletionSoundEnabled { get; init; } = true;
    /// <summary>
    /// 是否接收测试版（预发布）更新。当前项目发布全部标记为 prerelease，默认 true 以免老用户收不到更新；
    /// 待首个正式版发布后应把默认改为 false，让稳定通道只收正式版。详见 UpdateChecker 的通道过滤。
    /// </summary>
    public bool ReceiveBetaUpdates { get; init; } = true;
    /// <summary>
    /// 视频解析/下载专用代理。为空表示直连；支持 http/https/socks4/socks5，裸 host:port 会按 http:// 归一化。
    /// 只传给 yt-dlp，不影响 AI API 凭证或普通系统网络设置。
    /// </summary>
    public string VideoProxyUrl { get; init; } = "";
    /// <summary>视频解析/下载是否忽略 HTTPS 证书校验。默认关闭，仅用于代理/VPN 证书链异常的环境。</summary>
    public bool IgnoreVideoCertificateErrors { get; init; }

    // MARK: 上次下载选项（PARITY-002：与 macOS 一致，选档页恢复上次选择）

    /// <summary>上次字幕处理方式的 rawValue（off/srtOnly/burnIn/burnOriginal）；null 表示无记录。</summary>
    public string? LastSubtitleMode { get; init; }
    /// <summary>上次选择的字幕语言 id 列表。</summary>
    public IReadOnlyList<string> LastSubtitleLangs { get; init; } = [];
    /// <summary>上次选择的主字幕来源 stable id；旧设置缺省为 null。</summary>
    public string? LastPrimarySubtitleTrackId { get; init; }
    /// <summary>上次输出格式的 rawValue（original/mp4H264/mp4H265/mkv）；null 表示无记录。</summary>
    public string? LastOutputFormat { get; init; }
    /// <summary>上次是否偏好 HDR。</summary>
    public bool LastPreferHdr { get; init; }

    /// <summary>
    /// 实际压制并发上限：硬件后端可比兼容路径多放一路并行提高吞吐；
    /// 兼容路径维持设置值，避免互相拖慢。夹在 1...4。
    /// </summary>
    public int EffectiveMaxConcurrentBurns =>
        EncodeBackend.PrefersHardware() ? Math.Min(MaxConcurrentBurns + 1, 4) : MaxConcurrentBurns;

    // MARK: 存储位置

    /// <summary>测试注入：非空时所有路径都以它为根目录（替代 %APPDATA%\Moongate）。</summary>
    public static string? OverrideSupportDirectory { get; set; }

    public static string SupportDirectory
    {
        get
        {
            if (OverrideSupportDirectory is { Length: > 0 } overridden) return overridden;
            // Windows: %APPDATA%\Moongate；非 Windows（开发/测试）退到用户配置目录下同名文件夹。
            var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
            return Path.Combine(appData, "Moongate");
        }
    }

    public static string SettingsFilePath => Path.Combine(SupportDirectory, "settings.json");

    /// <summary>旧版全局 cookies 文件（仅用于一次性迁移到按站点隔离的 jar；新代码不再写入）。</summary>
    public static string CookieFilePath => Path.Combine(SupportDirectory, "cookies.txt");

    /// <summary>按站点隔离的 cookie 目录（cookies/youtube.txt、cookies/bilibili.txt）。</summary>
    public static string CookieDirectory => Path.Combine(SupportDirectory, "cookies");

    /// <summary>某站点的 cookie 文件路径（如 siteKey="youtube" → cookies/youtube.txt）。</summary>
    public static string SiteCookieFilePath(string siteKey) =>
        Path.Combine(CookieDirectory, siteKey + ".txt");

    // MARK: 读写

    /// <summary>
    /// 凭证安全存储（SEC-CRED-001）。App 启动时注入 DPAPI 实现；默认内存实现供 CLI/测试。
    /// 设为可注入便于单测验证迁移编排（迁移失败不丢旧 Token）。
    /// </summary>
    public static ICredentialStore CredentialStore { get; set; } = new InMemoryCredentialStore();

    private const string TranslationTokenKey = "translationAuthToken";
    private const string AITokenKey = "aiAuthToken";
    private const string SummaryTokenKey = "summaryAuthToken";
    private const string CloudAsrTokenKey = "cloudASRAuthToken";

    /// <summary>
    /// 上次 Load 把损坏的 settings.json 备份后的路径（供 UI 一次性提示）；正常加载为 null。
    /// 读取后调用方可置回 null（消费一次）。
    /// </summary>
    public static string? LastCorruptBackupPath { get; set; }

    public static AppSettings Load()
    {
        if (!File.Exists(SettingsFilePath)) return ApplyAndMigrateCredentials(new AppSettings());
        string text;
        try
        {
            text = File.ReadAllText(SettingsFilePath);
        }
        catch
        {
            // 读不到（权限/占用）：不动文件，按默认运行，不误备份。
            return ApplyAndMigrateCredentials(new AppSettings());
        }
        try
        {
            return ApplyAndMigrateCredentials(FromJson(text));
        }
        catch
        {
            // 解析失败：不静默回默认并在下次保存时覆盖原文件，而是先把损坏文件改名备份，
            // 置位一次性提示，再返回默认。这样用户的旧凭证/配置仍有机会人工恢复。
            BackupCorruptSettings();
            return ApplyAndMigrateCredentials(new AppSettings());
        }
    }

    /// <summary>
    /// 凭证安全存储的读取/迁移（SEC-CRED-001）：
    /// 1) 若 settings.json 还带明文 Token（旧版），先写入安全存储——**成功后**才把明文从磁盘抹掉，
    ///    store 写失败则保留明文、绝不丢失；
    /// 2) 用安全存储里的值覆盖内存配置（安全存储是凭证的唯一真相）。
    /// </summary>
    private static AppSettings ApplyAndMigrateCredentials(AppSettings parsed)
    {
        var hasLegacyPlaintext = !string.IsNullOrEmpty(parsed.TranslationAuthToken)
            || !string.IsNullOrEmpty(parsed.AIAuthToken)
            || !string.IsNullOrEmpty(parsed.SummaryAuthToken)
            || !string.IsNullOrEmpty(parsed.CloudAsrAuthToken);
        if (hasLegacyPlaintext)
        {
            try
            {
                parsed.WriteTokensToStore();
                // 安全存储已确认写入，才把明文从磁盘移除（最佳努力；失败也无妨，store 已有副本）。
                try { WritePersistedJson(parsed); } catch { /* 下次保存会再清 */ }
            }
            catch
            {
                // 安全存储写入失败：保留明文（内存 + 磁盘），不丢 Token；下次启动再尝试迁移。
                return parsed;
            }
        }
        return parsed with
        {
            TranslationAuthToken = CredentialStore.Get(TranslationTokenKey) ?? parsed.TranslationAuthToken,
            AIAuthToken = CredentialStore.Get(AITokenKey) ?? parsed.AIAuthToken,
            SummaryAuthToken = CredentialStore.Get(SummaryTokenKey) ?? parsed.SummaryAuthToken,
            CloudAsrAuthToken = CredentialStore.Get(CloudAsrTokenKey) ?? parsed.CloudAsrAuthToken,
        };
    }

    /// <summary>把 Token 写入安全存储（空值则删除）。任一写入失败向上抛。</summary>
    private void WriteTokensToStore()
    {
        SetOrDeleteToken(TranslationTokenKey, TranslationAuthToken);
        SetOrDeleteToken(AITokenKey, AIAuthToken);
        SetOrDeleteToken(SummaryTokenKey, SummaryAuthToken);
        SetOrDeleteToken(CloudAsrTokenKey, CloudAsrAuthToken);
    }

    private static void SetOrDeleteToken(string key, string value)
    {
        if (string.IsNullOrEmpty(value)) CredentialStore.Delete(key);
        else CredentialStore.Set(key, value);
    }

    /// <summary>把损坏的 settings.json 原子改名为 settings.corrupt-&lt;timestamp&gt;.json。</summary>
    private static void BackupCorruptSettings()
    {
        try
        {
            var stamp = DateTime.UtcNow.ToString("yyyyMMdd-HHmmss", System.Globalization.CultureInfo.InvariantCulture);
            var backup = Path.Combine(SupportDirectory, $"settings.corrupt-{stamp}.json");
            File.Move(SettingsFilePath, backup, overwrite: true);
            LastCorruptBackupPath = backup;
        }
        catch
        {
            // 备份失败也不要阻断启动；最坏退回默认。
        }
    }

    private static string SingleLineField(string value) => value.Trim();

    public static string NormalizePreferredSourceLanguage(string value)
    {
        var trimmed = SingleLineField(value);
        if (trimmed.Length == 0 || string.Equals(trimmed, "auto", StringComparison.OrdinalIgnoreCase))
            return "auto";
        var normalized = TranslationLanguage.NormalizedScript(trimmed);
        return normalized is "ja" or "en" or "ko" or "zh-Hans" or "zh-Hant" or "yue"
            ? normalized
            : "auto";
    }

    /// <summary>容错解析：缺字段按默认，非法值回退默认，并发数读入时夹回合法区间。</summary>
    public static AppSettings FromJson(string json)
    {
        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;

        static string? StringField(JsonElement root, string name) =>
            root.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
        static int? IntField(JsonElement root, string name) =>
            root.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.Number && v.TryGetInt32(out var i) ? i : null;

        var baseUrl = SingleLineField(StringField(root, "translationBaseURL")
            ?? TranslationProvider.Anthropic.DefaultBaseUrl());
        var model = SingleLineField(StringField(root, "translationModel") ?? "");
        // provider 键缺失（旧版配置）时按 baseURL/模型名推断
        var provider = TranslationProviderExtensions.FromRawValue(StringField(root, "translationProvider"))
            ?? InferProvider(baseUrl, model);
        var translationEngineProvider = ProviderFromEngine(StringField(root, "translationEngine")) ?? provider;
        provider = translationEngineProvider;
        var aiProvider = ProviderFromEngine(StringField(root, "aiEngine")) ?? provider;
        var aiBaseUrl = SingleLineField(StringField(root, "aiBaseURL") ?? baseUrl);
        var aiModel = SingleLineField(StringField(root, "aiModel") ?? model);
        var aiToken = StringField(root, "aiAuthToken")
            ?? StringField(root, "translationAuthToken")
            ?? "";
        var summaryProvider = ProviderFromEngine(StringField(root, "summaryEngine")) ?? aiProvider;
        var summaryBaseUrl = SingleLineField(StringField(root, "summaryBaseURL") ?? aiBaseUrl);
        var summaryModel = SingleLineField(StringField(root, "summaryModel") ?? aiModel);
        var summaryToken = StringField(root, "summaryAuthToken") ?? aiToken;
        var style = StringField(root, "subtitleStyle") switch
        {
            "chineseOnly" => SubtitleStyle.ChineseOnly,
            _ => SubtitleStyle.Bilingual,
        };
        // 旧版 settings.json 没有 maxBurnHeight 键：缺失时保持源分辨率，避免 4K 选择被静默压到 1080。
        int? maxBurnHeight = null;
        if (root.TryGetProperty("maxBurnHeight", out var heightValue))
        {
            maxBurnHeight = heightValue.ValueKind == JsonValueKind.Number && heightValue.TryGetInt32(out var h)
                ? h
                : null;
        }

        // 语言：未知值按 auto 容错
        var appLanguage = StringField(root, "appLanguage") switch
        {
            "zh-Hans" => "zh-Hans",
            "zh-Hant" => "zh-Hant",
            "en" => "en",
            _ => "auto",
        };
        // 翻译目标语言：未知值回退 zh-Hans（保持老用户升级后行为不变）
        var translationTargetLanguage = StringField(root, "translationTargetLanguage") switch
        {
            "zh-Hant" => "zh-Hant",
            "en" => "en",
            _ => "zh-Hans",
        };
        var preferredSourceLanguage = NormalizePreferredSourceLanguage(
            StringField(root, "preferredSourceLanguage") ?? "auto");
        // 首启引导是否完成：缺键/非 true 一律 false
        var onboardingCompleted = root.TryGetProperty("onboardingCompleted", out var obc)
            && obc.ValueKind == JsonValueKind.True;
        var smartTranslationPromptsEnabled = root.TryGetProperty("smartTranslationPromptsEnabled", out var stp)
            && stp.ValueKind == JsonValueKind.True;
        var localAsrEnabled = root.TryGetProperty("localASREnabled", out var lasre)
            && lasre.ValueKind == JsonValueKind.True;
        var localAsrRuntimePath = SingleLineField(StringField(root, "localASRRuntimePath") ?? "");
        var localAsrModelPath = SingleLineField(StringField(root, "localASRModelPath") ?? "");
        var localAsrModelId = SingleLineField(StringField(root, "localASRModelID") ?? "");
        var localAsrPreciseModeEnabled = root.TryGetProperty("localASRPreciseModeEnabled", out var lapme)
            && lapme.ValueKind == JsonValueKind.True;
        var localAsrSidecarRuntimePath = SingleLineField(StringField(root, "localASRSidecarRuntimePath") ?? "");
        var localAsrSidecarModelPath = SingleLineField(StringField(root, "localASRSidecarModelPath") ?? "");
        var cloudAsrEnabled = root.TryGetProperty("cloudASREnabled", out var cloudAsrEnabledValue)
            && cloudAsrEnabledValue.ValueKind == JsonValueKind.True;
        var cloudAsrConsentAccepted = root.TryGetProperty("cloudASRConsentAccepted", out var casca)
            && casca.ValueKind == JsonValueKind.True;
        var cloudAsrBaseUrl = SingleLineField(StringField(root, "cloudASRBaseURL") ?? "https://api.openai.com");
        var cloudAsrModel = SingleLineField(StringField(root, "cloudASRModel") ?? "whisper-1");
        var cloudAsrAuthToken = StringField(root, "cloudASRAuthToken") ?? "";
        var completionNotificationsEnabled = !root.TryGetProperty("completionNotificationsEnabled", out var cne)
            || cne.ValueKind != JsonValueKind.False;
        var completionSoundEnabled = !root.TryGetProperty("completionSoundEnabled", out var cse)
            || cse.ValueKind != JsonValueKind.False;
        // 接收测试版更新：缺键默认 true（当前发布全是 prerelease）；仅显式 false 关闭。
        var receiveBetaUpdates = !root.TryGetProperty("receiveBetaUpdates", out var rbu)
            || rbu.ValueKind != JsonValueKind.False;
        var videoProxyUrl = NormalizeVideoProxyUrl(
            StringField(root, "videoProxyURL") ?? StringField(root, "videoProxyUrl") ?? "");
        var ignoreVideoCertificateErrors = root.TryGetProperty("ignoreVideoCertificateErrors", out var ivce)
            && ivce.ValueKind == JsonValueKind.True;

        // 上次下载选项（PARITY-002）。
        var lastSubtitleMode = StringField(root, "lastSubtitleMode");
        var lastPrimarySubtitleTrackId = SingleLineField(StringField(root, "lastPrimarySubtitleTrackID") ?? "");
        var lastOutputFormat = StringField(root, "lastOutputFormat");
        var lastPreferHdr = root.TryGetProperty("lastPreferHDR", out var lph)
            && lph.ValueKind == JsonValueKind.True;
        var lastSubtitleLangs = new List<string>();
        if (root.TryGetProperty("lastSubtitleLangs", out var lsl) && lsl.ValueKind == JsonValueKind.Array)
        {
            foreach (var item in lsl.EnumerateArray())
            {
                if (item.ValueKind == JsonValueKind.String && item.GetString() is { } s) lastSubtitleLangs.Add(s);
            }
        }

        // 编码后端：缺键默认 Auto；烧录始终 H.264 默认关（跟随源）。
        var encodeBackend = EncodeBackendExtensions.FromRawValue(StringField(root, "encodeBackend"));
        var burnAlwaysH264 = root.TryGetProperty("burnAlwaysH264", out var ah264)
            && ah264.ValueKind == JsonValueKind.True;

        return new AppSettings
        {
            TranslationProvider = provider,
            TranslationBaseUrl = baseUrl,
            TranslationModel = model,
            TranslationAuthToken = StringField(root, "translationAuthToken") ?? "",
            AIProvider = aiProvider,
            AIBaseUrl = aiBaseUrl,
            AIModel = aiModel,
            AIAuthToken = aiToken,
            TranslationFollowsDefault = !root.TryGetProperty("translationFollowsDefault", out var tfd)
                || tfd.ValueKind != JsonValueKind.False,
            SummaryFollowsDefault = !root.TryGetProperty("summaryFollowsDefault", out var sfd)
                || sfd.ValueKind != JsonValueKind.False,
            SummaryProvider = summaryProvider,
            SummaryBaseUrl = summaryBaseUrl,
            SummaryModel = summaryModel,
            SummaryAuthToken = summaryToken,
            SubtitleStyle = style,
            MaxBurnHeight = maxBurnHeight,
            MaxConcurrentDownloads = Math.Clamp(IntField(root, "maxConcurrentDownloads") ?? 3, 1, 5),
            MaxConcurrentBurns = Math.Clamp(IntField(root, "maxConcurrentBurns") ?? 2, 1, 3),
            EncodeBackend = encodeBackend,
            BurnAlwaysH264 = burnAlwaysH264,
            AppLanguage = appLanguage,
            TranslationTargetLanguage = translationTargetLanguage,
            PreferredSourceLanguage = preferredSourceLanguage,
            OnboardingCompleted = onboardingCompleted,
            SmartTranslationPromptsEnabled = smartTranslationPromptsEnabled,
            LocalAsrEnabled = localAsrEnabled,
            LocalAsrRuntimePath = localAsrRuntimePath,
            LocalAsrModelPath = localAsrModelPath,
            LocalAsrModelId = localAsrModelId,
            LocalAsrPreciseModeEnabled = localAsrPreciseModeEnabled,
            LocalAsrSidecarRuntimePath = localAsrSidecarRuntimePath,
            LocalAsrSidecarModelPath = localAsrSidecarModelPath,
            CloudAsrEnabled = cloudAsrEnabled,
            CloudAsrConsentAccepted = cloudAsrConsentAccepted,
            CloudAsrBaseUrl = cloudAsrBaseUrl,
            CloudAsrModel = cloudAsrModel,
            CloudAsrAuthToken = cloudAsrAuthToken,
            CompletionNotificationsEnabled = completionNotificationsEnabled,
            CompletionSoundEnabled = completionSoundEnabled,
            ReceiveBetaUpdates = receiveBetaUpdates,
            VideoProxyUrl = videoProxyUrl,
            IgnoreVideoCertificateErrors = ignoreVideoCertificateErrors,
            LastSubtitleMode = lastSubtitleMode,
            LastSubtitleLangs = lastSubtitleLangs,
            LastPrimarySubtitleTrackId = lastPrimarySubtitleTrackId.Length == 0 ? null : lastPrimarySubtitleTrackId,
            LastOutputFormat = lastOutputFormat,
            LastPreferHdr = lastPreferHdr,
        };
    }

    public string ToJson()
    {
        // 手写字段映射保证键名与 Swift 版一致（枚举存 rawValue 字符串、null 显式落盘）。
        var payload = new Dictionary<string, object?>
        {
            ["translationProvider"] = TranslationProvider.RawValue(),
            ["translationEngine"] = EngineRawValue(TranslationProvider),
            ["translationBaseURL"] = SingleLineField(TranslationBaseUrl),
            ["translationModel"] = SingleLineField(TranslationModel),
            ["translationAuthToken"] = TranslationAuthToken,
            ["aiEngine"] = EngineRawValue(AIProvider),
            ["aiBaseURL"] = SingleLineField(AIBaseUrl),
            ["aiModel"] = SingleLineField(AIModel),
            ["aiAuthToken"] = AIAuthToken,
            ["translationFollowsDefault"] = TranslationFollowsDefault,
            ["summaryFollowsDefault"] = SummaryFollowsDefault,
            ["summaryEngine"] = EngineRawValue(SummaryProvider),
            ["summaryBaseURL"] = SingleLineField(SummaryBaseUrl),
            ["summaryModel"] = SingleLineField(SummaryModel),
            ["summaryAuthToken"] = SummaryAuthToken,
            ["subtitleStyle"] = SubtitleStyle == SubtitleStyle.ChineseOnly ? "chineseOnly" : "bilingual",
            ["maxBurnHeight"] = MaxBurnHeight,
            ["maxConcurrentDownloads"] = MaxConcurrentDownloads,
            ["maxConcurrentBurns"] = MaxConcurrentBurns,
            ["encodeBackend"] = EncodeBackend.RawValue(),
            ["burnAlwaysH264"] = BurnAlwaysH264,
            ["appLanguage"] = AppLanguage,
            ["translationTargetLanguage"] = TranslationTargetLanguage,
            ["preferredSourceLanguage"] = NormalizePreferredSourceLanguage(PreferredSourceLanguage),
            ["onboardingCompleted"] = OnboardingCompleted,
            ["smartTranslationPromptsEnabled"] = SmartTranslationPromptsEnabled,
            ["localASREnabled"] = LocalAsrEnabled,
            ["localASRRuntimePath"] = SingleLineField(LocalAsrRuntimePath),
            ["localASRModelPath"] = SingleLineField(LocalAsrModelPath),
            ["localASRModelID"] = SingleLineField(LocalAsrModelId),
            ["localASRPreciseModeEnabled"] = LocalAsrPreciseModeEnabled,
            ["localASRSidecarRuntimePath"] = SingleLineField(LocalAsrSidecarRuntimePath),
            ["localASRSidecarModelPath"] = SingleLineField(LocalAsrSidecarModelPath),
            ["cloudASREnabled"] = CloudAsrEnabled,
            ["cloudASRConsentAccepted"] = CloudAsrConsentAccepted,
            ["cloudASRBaseURL"] = SingleLineField(CloudAsrBaseUrl),
            ["cloudASRModel"] = SingleLineField(CloudAsrModel),
            ["cloudASRAuthToken"] = CloudAsrAuthToken,
            ["completionNotificationsEnabled"] = CompletionNotificationsEnabled,
            ["completionSoundEnabled"] = CompletionSoundEnabled,
            ["receiveBetaUpdates"] = ReceiveBetaUpdates,
            ["videoProxyURL"] = NormalizeVideoProxyUrl(VideoProxyUrl),
            ["ignoreVideoCertificateErrors"] = IgnoreVideoCertificateErrors,
            ["lastSubtitleMode"] = LastSubtitleMode,
            ["lastSubtitleLangs"] = LastSubtitleLangs,
            ["lastPrimarySubtitleTrackID"] = LastPrimarySubtitleTrackId is { Length: > 0 }
                ? SingleLineField(LastPrimarySubtitleTrackId)
                : null,
            ["lastOutputFormat"] = LastOutputFormat,
            ["lastPreferHDR"] = LastPreferHdr,
        };
        return JsonSerializer.Serialize(payload, new JsonSerializerOptions { WriteIndented = true });
    }

    /// <summary>
    /// 落盘用 JSON：与 ToJson 相同但 Token 字段强制为空——明文凭证只进安全存储，绝不写进 settings.json。
    /// </summary>
    private string ToPersistedJson() =>
        (this with { TranslationAuthToken = "", AIAuthToken = "", SummaryAuthToken = "", CloudAsrAuthToken = "" }).ToJson();

    /// <summary>
    /// 原子写：先写临时文件再替换。写失败时旧配置原样保留。
    /// 凭证（SEC-CRED-001）：先写入安全存储，**成功后**才写不含明文 Token 的 JSON——
    /// store 写失败直接抛出、不动 settings.json，旧值不丢。
    /// </summary>
    public void Save()
    {
        WriteTokensToStore();
        WritePersistedJson(this);
    }

    /// <summary>原子写不含明文 Token 的 settings.json。</summary>
    private static void WritePersistedJson(AppSettings settings)
    {
        var dir = SupportDirectory;
        Directory.CreateDirectory(dir);
        var temp = Path.Combine(dir, $"settings.json.tmp-{Guid.NewGuid():N}");
        try
        {
            File.WriteAllText(temp, settings.ToPersistedJson());
            // File.Move(overwrite: true) 在同一卷上是原子替换
            File.Move(temp, SettingsFilePath, overwrite: true);
        }
        catch
        {
            try { File.Delete(temp); } catch { /* 忽略 */ }
            throw;
        }
    }

    // MARK: 派生状态

    /// <summary>翻译功能是否已配置完整。</summary>
    public bool IsTranslationConfigured => HasCloudEndpoint(ForTranslation());

    /// <summary>AI 总结功能是否已配置完整。</summary>
    public bool IsSummaryConfigured => HasCloudEndpoint(ForSummary());

    /// <summary>云端精准识别必须显式开启、确认上传/费用，并填好服务地址、模型和独立凭证。</summary>
    public bool IsCloudAsrConfigured =>
        CloudAsrEnabled
        && CloudAsrConsentAccepted
        && !string.IsNullOrWhiteSpace(CloudAsrBaseUrl)
        && !string.IsNullOrWhiteSpace(CloudAsrModel)
        && CloudAsrModelCapabilities.SupportsDirectSubtitleOutput(CloudAsrModel)
        && !string.IsNullOrWhiteSpace(CloudAsrAuthToken);

    public bool CloudAsrModelRequiresAlignment =>
        CloudAsrModelCapabilities.RequiresAlignment(CloudAsrModel);

    /// <summary>本地精准 sidecar 仅在本地识别开启、精准模式开启且两个本地路径完整时可用。</summary>
    public bool IsLocalAsrSidecarConfigured =>
        LocalAsrEnabled
        && LocalAsrPreciseModeEnabled
        && !string.IsNullOrWhiteSpace(LocalAsrSidecarRuntimePath)
        && !string.IsNullOrWhiteSpace(LocalAsrSidecarModelPath);

    /// <summary>把翻译有效配置投影成 TranslationApi 可直接使用的设置对象。</summary>
    public AppSettings ForTranslation()
    {
        if (!TranslationFollowsDefault)
        {
            return this with
            {
                TranslationBaseUrl = SingleLineField(TranslationBaseUrl),
                TranslationModel = SingleLineField(TranslationModel),
            };
        }
        return this with
        {
            TranslationProvider = AIProvider,
            TranslationBaseUrl = SingleLineField(AIBaseUrl),
            TranslationModel = SingleLineField(AIModel),
            TranslationAuthToken = AIAuthToken,
        };
    }

    /// <summary>把总结有效配置投影成 TranslationApi 可直接使用的设置对象。</summary>
    public AppSettings ForSummary()
    {
        var provider = SummaryFollowsDefault ? AIProvider : SummaryProvider;
        var baseUrl = SummaryFollowsDefault ? AIBaseUrl : SummaryBaseUrl;
        var model = SummaryFollowsDefault ? AIModel : SummaryModel;
        var token = SummaryFollowsDefault ? AIAuthToken : SummaryAuthToken;
        return this with
        {
            TranslationProvider = provider,
            TranslationBaseUrl = SingleLineField(baseUrl),
            TranslationModel = SingleLineField(model),
            TranslationAuthToken = token,
        };
    }

    /// <summary>已填好服务地址和凭证，但模型可以稍后从候选菜单里选择。</summary>
    public bool IsTranslationEndpointConfigured =>
        !string.IsNullOrWhiteSpace(ForTranslation().TranslationBaseUrl)
        && !string.IsNullOrWhiteSpace(ForTranslation().TranslationAuthToken);

    internal static TranslationProvider InferProvider(string baseUrl, string model)
    {
        var normalizedBase = baseUrl.ToLowerInvariant();
        var normalizedModel = model.ToLowerInvariant();
        if (normalizedBase.Contains("api.openai.com")
            || normalizedModel.StartsWith("gpt-")
            || normalizedModel.StartsWith("o1")
            || normalizedModel.StartsWith("o3")
            || normalizedModel.StartsWith("o4")
            || normalizedModel.StartsWith("o5"))
        {
            return TranslationProvider.Openai;
        }
        return TranslationProvider.Anthropic;
    }

    private static string EngineRawValue(TranslationProvider provider) => provider switch
    {
        TranslationProvider.Openai => "openAICompatible",
        _ => "anthropicCompatible",
    };

    private static TranslationProvider? ProviderFromEngine(string? raw) => raw switch
    {
        "anthropicCompatible" => TranslationProvider.Anthropic,
        "openAICompatible" => TranslationProvider.Openai,
        _ => TranslationProviderExtensions.FromRawValue(raw),
    };

    private static bool HasCloudEndpoint(AppSettings settings) =>
        !string.IsNullOrWhiteSpace(settings.TranslationBaseUrl)
        && !string.IsNullOrWhiteSpace(settings.TranslationModel)
        && !string.IsNullOrWhiteSpace(settings.TranslationAuthToken);

    public static string NormalizeVideoProxyUrl(string? value)
    {
        var trimmed = (value ?? "").Trim();
        if (trimmed.Length == 0) return "";
        if (trimmed.Contains('\r') || trimmed.Contains('\n')) return "";

        var candidate = trimmed.Contains("://", StringComparison.Ordinal)
            ? trimmed
            : "http://" + trimmed;
        if (!Uri.TryCreate(candidate, UriKind.Absolute, out var uri)) return "";
        var scheme = uri.Scheme.ToLowerInvariant();
        string[] supported = ["http", "https", "socks4", "socks4a", "socks5", "socks5h"];
        if (!supported.Contains(scheme) || string.IsNullOrWhiteSpace(uri.Host)) return "";
        return uri.ToString().TrimEnd('/');
    }
}
