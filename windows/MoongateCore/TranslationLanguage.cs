namespace Moongate.Core;

/// <summary>
/// 翻译目标语言的归一与展示（与 Swift MoongateMobileCore 的 TranslationLanguage 同构）。
/// 区分 zh-Hans / zh-Hant，避免把"中文"当成单一目标。
/// </summary>
public static class TranslationLanguage
{
    public static IReadOnlySet<string> TranslatedSubtitleFileSuffixes { get; } =
        new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            ".zh-Hans.srt",
            ".zh-Hant.srt",
            ".en.srt",
        };

    /// <summary>目标语言代码 → LLM 提示词里的人类可读名。</summary>
    public static string DisplayName(string code) => NormalizedScript(code) switch
    {
        "zh-Hans" => "简体中文",
        "zh-Hant" => "繁體中文",
        "en" => "English",
        _ => code,
    };

    /// <summary>源语言代码 → LLM 中文提示词里的人类可读名；未知码回退原始码。</summary>
    public static string? SourceDisplayName(string? code)
    {
        if (string.IsNullOrWhiteSpace(code)) return null;
        return NormalizedScript(code) switch
        {
            "zh-Hans" => "简体中文",
            "zh-Hant" => "繁体中文",
            "ja" => "日语",
            "ko" => "韩语",
            "en" => "英语",
            "fr" => "法语",
            "de" => "德语",
            "es" => "西班牙语",
            "ru" => "俄语",
            "it" => "意大利语",
            "pt" => "葡萄牙语",
            "th" => "泰语",
            "vi" => "越南语",
            "id" => "印尼语",
            "ar" => "阿拉伯语",
            _ => code.Trim(),
        };
    }

    /// <summary>
    /// 把任意 BCP-47 风格代码归一到"脚本级"标识，区分简繁。
    /// zh / zh-CN / zh-Hans → "zh-Hans"；zh-Hant / zh-TW / zh-HK / zh-MO → "zh-Hant"；其余取主语言子标签。
    /// </summary>
    public static string NormalizedScript(string code)
    {
        var lower = code.ToLowerInvariant();
        if (lower.StartsWith("zh", StringComparison.Ordinal))
        {
            if (lower.Contains("hant") || lower.Contains("tw") || lower.Contains("hk") || lower.Contains("mo"))
                return "zh-Hant";
            return "zh-Hans";
        }
        var dash = lower.IndexOf('-');
        return dash >= 0 ? lower[..dash] : lower;
    }

    public static string TranslatedSubtitleFileSuffix(string code) => $".{NormalizedScript(code)}.srt";

    public static string? SourceLanguageIdentifierFromSubtitleFile(string path)
    {
        var stem = Path.GetFileNameWithoutExtension(path);
        if (string.IsNullOrWhiteSpace(stem)) return null;
        var dot = stem.LastIndexOf('.');
        if (dot < 0 || dot == stem.Length - 1) return null;
        var identifier = stem[(dot + 1)..].Trim().ToLowerInvariant();
        return identifier.Length == 0 ? null : identifier;
    }

    public static bool IsTranslatedSubtitleFileName(string name)
    {
        var lower = Path.GetFileName(name).ToLowerInvariant();
        if (!lower.EndsWith(".srt", StringComparison.Ordinal)) return false;
        var stem = lower[..^4];
        var parts = stem.Split('.', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length < 3) return false;
        var source = parts[^2];
        var target = parts[^1];
        return IsLikelyLanguageCode(source)
            && TranslatedSubtitleFileSuffixes.Contains($".{target}.srt");
    }

    /// <summary>源语言与目标语言是否同一脚本（同则跳过翻译，直接使用/烧录原字幕）。源为空按"不匹配"。</summary>
    public static bool Matches(string? source, string target)
    {
        if (string.IsNullOrEmpty(source)) return false;
        return NormalizedScript(source) == NormalizedScript(target);
    }

    private static bool IsLikelyLanguageCode(string value)
    {
        var primary = value.Split('-', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault();
        return primary is { Length: >= 2 and <= 3 } && primary.All(char.IsLetter);
    }
}
