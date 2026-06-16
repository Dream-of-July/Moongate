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
    /// 烧录时限制最大分辨率高度：源高于此值则缩放到此值（既快又小，避开 4K60 的 H.264 上限）。
    /// null = 保持源分辨率。默认 1080。
    /// </summary>
    public int? MaxBurnHeight { get; init; } = 1080;
    /// <summary>同时进行的下载任务数（1...5，默认 3）。</summary>
    public int MaxConcurrentDownloads { get; init; } = 3;
    /// <summary>同时进行的压制（烧录）任务数（1...3，默认 2）。兼容路径并行多了会互相拖慢。</summary>
    public int MaxConcurrentBurns { get; init; } = 2;
    /// <summary>烧录/转码的视频编码后端：Auto（硬件优先）/ Hardware / Software。默认 Auto。</summary>
    public EncodeBackend EncodeBackend { get; init; } = EncodeBackend.Auto;
    /// <summary>烧录字幕时是否始终输出 H.264（兼容优先）。false=跟随源编码（HEVC 源保 HEVC）。默认 false。</summary>
    public bool BurnAlwaysH264 { get; init; }
    /// <summary>界面语言："auto"（跟随系统）、"zh-Hans"、"en"。</summary>
    public string AppLanguage { get; init; } = "auto";

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

    /// <summary>站点登录后导出的 Netscape 格式 cookies 文件；存在时引擎自动以 --cookies 传给 yt-dlp。</summary>
    public static string CookieFilePath => Path.Combine(SupportDirectory, "cookies.txt");

    // MARK: 读写

    public static AppSettings Load()
    {
        try
        {
            return File.Exists(SettingsFilePath)
                ? FromJson(File.ReadAllText(SettingsFilePath))
                : new AppSettings();
        }
        catch
        {
            return new AppSettings();
        }
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

        var baseUrl = StringField(root, "translationBaseURL")
            ?? TranslationProvider.Anthropic.DefaultBaseUrl();
        var model = StringField(root, "translationModel") ?? "";
        // provider 键缺失（旧版配置）时按 baseURL/模型名推断
        var provider = TranslationProviderExtensions.FromRawValue(StringField(root, "translationProvider"))
            ?? InferProvider(baseUrl, model);
        var translationEngineProvider = ProviderFromEngine(StringField(root, "translationEngine")) ?? provider;
        provider = translationEngineProvider;
        var aiProvider = ProviderFromEngine(StringField(root, "aiEngine")) ?? provider;
        var aiBaseUrl = StringField(root, "aiBaseURL") ?? baseUrl;
        var aiModel = StringField(root, "aiModel") ?? model;
        var aiToken = StringField(root, "aiAuthToken")
            ?? StringField(root, "translationAuthToken")
            ?? "";
        var summaryProvider = ProviderFromEngine(StringField(root, "summaryEngine")) ?? aiProvider;
        var summaryBaseUrl = StringField(root, "summaryBaseURL") ?? aiBaseUrl;
        var summaryModel = StringField(root, "summaryModel") ?? aiModel;
        var summaryToken = StringField(root, "summaryAuthToken") ?? aiToken;
        var style = StringField(root, "subtitleStyle") switch
        {
            "chineseOnly" => SubtitleStyle.ChineseOnly,
            _ => SubtitleStyle.Bilingual,
        };
        // 旧版 settings.json 没有 maxBurnHeight 键：缺失时按默认 1080 处理，而非「保持源分辨率」；
        // 显式 null 才表示保持源分辨率。
        int? maxBurnHeight = 1080;
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
            "en" => "en",
            _ => "auto",
        };

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
        };
    }

    public string ToJson()
    {
        // 手写字段映射保证键名与 Swift 版一致（枚举存 rawValue 字符串、null 显式落盘）。
        var payload = new Dictionary<string, object?>
        {
            ["translationProvider"] = TranslationProvider.RawValue(),
            ["translationEngine"] = EngineRawValue(TranslationProvider),
            ["translationBaseURL"] = TranslationBaseUrl,
            ["translationModel"] = TranslationModel,
            ["translationAuthToken"] = TranslationAuthToken,
            ["aiEngine"] = EngineRawValue(AIProvider),
            ["aiBaseURL"] = AIBaseUrl,
            ["aiModel"] = AIModel,
            ["aiAuthToken"] = AIAuthToken,
            ["translationFollowsDefault"] = TranslationFollowsDefault,
            ["summaryFollowsDefault"] = SummaryFollowsDefault,
            ["summaryEngine"] = EngineRawValue(SummaryProvider),
            ["summaryBaseURL"] = SummaryBaseUrl,
            ["summaryModel"] = SummaryModel,
            ["summaryAuthToken"] = SummaryAuthToken,
            ["subtitleStyle"] = SubtitleStyle == SubtitleStyle.ChineseOnly ? "chineseOnly" : "bilingual",
            ["maxBurnHeight"] = MaxBurnHeight,
            ["maxConcurrentDownloads"] = MaxConcurrentDownloads,
            ["maxConcurrentBurns"] = MaxConcurrentBurns,
            ["encodeBackend"] = EncodeBackend.RawValue(),
            ["burnAlwaysH264"] = BurnAlwaysH264,
            ["appLanguage"] = AppLanguage,
        };
        return JsonSerializer.Serialize(payload, new JsonSerializerOptions { WriteIndented = true });
    }

    /// <summary>
    /// 原子写：先写临时文件再替换。写失败时旧配置（含凭证）原样保留，
    /// 不能删旧文件导致磁盘满/权限问题时配置全丢。
    /// </summary>
    public void Save()
    {
        var dir = SupportDirectory;
        Directory.CreateDirectory(dir);
        var temp = Path.Combine(dir, $"settings.json.tmp-{Guid.NewGuid():N}");
        try
        {
            File.WriteAllText(temp, ToJson());
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

    /// <summary>把翻译有效配置投影成 TranslationApi 可直接使用的设置对象。</summary>
    public AppSettings ForTranslation()
    {
        if (!TranslationFollowsDefault) return this;
        return this with
        {
            TranslationProvider = AIProvider,
            TranslationBaseUrl = AIBaseUrl,
            TranslationModel = AIModel,
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
            TranslationBaseUrl = baseUrl,
            TranslationModel = model,
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
}
