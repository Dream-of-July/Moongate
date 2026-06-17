using Moongate.Core;

namespace MoongateCore.Tests;

[Collection(L10nLanguageCollection.Name)]
public class SettingsTests
{
    [Fact]
    public void Defaults()
    {
        var settings = new AppSettings();
        Assert.Equal(TranslationProvider.Anthropic, settings.TranslationProvider);
        Assert.Equal("https://api.anthropic.com", settings.TranslationBaseUrl);
        Assert.Equal(SubtitleStyle.Bilingual, settings.SubtitleStyle);
        Assert.Equal(1080, settings.MaxBurnHeight);
        Assert.Equal(3, settings.MaxConcurrentDownloads);
        Assert.Equal(2, settings.MaxConcurrentBurns);
    }

    /// <summary>缺字段容错：空 JSON 全部回默认（maxBurnHeight 缺失按 1080 而非「保持源」）。</summary>
    [Fact]
    public void FromJson_EmptyObject_AllDefaults()
    {
        var settings = AppSettings.FromJson("{}");
        Assert.Equal(new AppSettings(), settings);
        Assert.Equal(1080, settings.MaxBurnHeight);
    }

    /// <summary>显式 null 的 maxBurnHeight 表示「保持源分辨率」。</summary>
    [Fact]
    public void FromJson_ExplicitNullBurnHeight_MeansKeepSource()
    {
        var settings = AppSettings.FromJson("""{"maxBurnHeight": null}""");
        Assert.Null(settings.MaxBurnHeight);
    }

    /// <summary>0.5：编码后端 + 烧录编码 round-trip；缺键默认 Auto/false。</summary>
    [Fact]
    public void EncodeBackend_RoundTripsThroughJson()
    {
        var settings = new AppSettings { EncodeBackend = EncodeBackend.Software, BurnAlwaysH264 = true };
        var back = AppSettings.FromJson(settings.ToJson());
        Assert.Equal(EncodeBackend.Software, back.EncodeBackend);
        Assert.True(back.BurnAlwaysH264);
    }

    [Fact]
    public void EncodeBackend_MissingKey_DefaultsAutoAndFalse()
    {
        var settings = AppSettings.FromJson("""{"translationModel": "claude"}""");
        Assert.Equal(EncodeBackend.Auto, settings.EncodeBackend);
        Assert.False(settings.BurnAlwaysH264);
    }

    [Fact]
    public void SmartTranslationPrompts_RoundTripsAndDefaultsOff()
    {
        Assert.False(new AppSettings().SmartTranslationPromptsEnabled);
        var settings = AppSettings.FromJson("""{"smartTranslationPromptsEnabled": true}""");
        Assert.True(settings.SmartTranslationPromptsEnabled);
        Assert.True(AppSettings.FromJson(settings.ToJson()).SmartTranslationPromptsEnabled);
        Assert.Contains("\"smartTranslationPromptsEnabled\"", settings.ToJson());
    }

    [Fact]
    public void SingleLineFields_AreTrimmedWhenRoundTripping()
    {
        var settings = new AppSettings
        {
            TranslationBaseUrl = " https://translation.example.com\n",
            TranslationModel = "\ntranslation-model ",
            TranslationAuthToken = "token",
            AIBaseUrl = "https://ai.example.com\n\n",
            AIModel = " ai-model\n",
            AIAuthToken = "ai-token",
            SummaryBaseUrl = "\nhttps://summary.example.com ",
            SummaryModel = "summary-model\n",
            SummaryAuthToken = "summary-token",
        };

        var back = AppSettings.FromJson(settings.ToJson());

        Assert.Equal("https://translation.example.com", back.TranslationBaseUrl);
        Assert.Equal("translation-model", back.TranslationModel);
        Assert.Equal("https://ai.example.com", back.AIBaseUrl);
        Assert.Equal("ai-model", back.AIModel);
        Assert.Equal("https://summary.example.com", back.SummaryBaseUrl);
        Assert.Equal("summary-model", back.SummaryModel);
    }

    /// <summary>0.7：界面语言/翻译目标/引导完成 round-trip。</summary>
    [Fact]
    public void Language_RoundTripsThroughJson()
    {
        var settings = new AppSettings
        {
            AppLanguage = "zh-Hant",
            TranslationTargetLanguage = "en",
            OnboardingCompleted = true,
        };
        var back = AppSettings.FromJson(settings.ToJson());
        Assert.Equal("zh-Hant", back.AppLanguage);
        Assert.Equal("en", back.TranslationTargetLanguage);
        Assert.True(back.OnboardingCompleted);
    }

    /// <summary>关键回归：旧 settings.json 无 0.7 新键时保住 token，三字段取安全默认（翻译目标 zh-Hans）。</summary>
    [Fact]
    public void FromJson_MissingLanguageKeys_KeepTokenAndUseSafeDefaults()
    {
        var settings = AppSettings.FromJson("""
        {
          "translationProvider": "anthropic",
          "translationEngine": "anthropicCompatible",
          "translationBaseURL": "https://api.anthropic.com",
          "translationModel": "claude-haiku-4-5",
          "translationAuthToken": "TEST_SECRET_VALUE_DO_NOT_STORE"
        }
        """);
        Assert.Equal("TEST_SECRET_VALUE_DO_NOT_STORE", settings.TranslationAuthToken);
        Assert.Equal("auto", settings.AppLanguage);
        Assert.Equal("zh-Hans", settings.TranslationTargetLanguage);
        Assert.False(settings.OnboardingCompleted);
    }

    /// <summary>parity：未知 appLanguage/translationTargetLanguage 值容错回退（auto / zh-Hans）。</summary>
    [Fact]
    public void FromJson_UnknownLanguageValues_FallBackSafely()
    {
        var settings = AppSettings.FromJson("""{"appLanguage": "klingon", "translationTargetLanguage": "elvish"}""");
        Assert.Equal("auto", settings.AppLanguage);
        Assert.Equal("zh-Hans", settings.TranslationTargetLanguage);
    }

    /// <summary>parity：ToJson 必须用与 Swift 端完全一致的 JSON key 名。</summary>
    [Fact]
    public void ToJson_UsesAgreedCrossPlatformLanguageKeys()
    {
        var json = new AppSettings().ToJson();
        Assert.Contains("\"appLanguage\"", json);
        Assert.Contains("\"translationTargetLanguage\"", json);
        Assert.Contains("\"onboardingCompleted\"", json);
    }

    [Fact]
    public void SummaryConfig_RoundTripsAndCanOverrideDefaultAi()
    {
        var settings = new AppSettings
        {
            TranslationProvider = TranslationProvider.Anthropic,
            TranslationBaseUrl = "https://translation.example.com",
            TranslationModel = "claude-translate",
            TranslationAuthToken = "translation-token",
            AIProvider = TranslationProvider.Openai,
            AIBaseUrl = "https://ai.example.com",
            AIModel = "gpt-default",
            AIAuthToken = "ai-token",
            SummaryFollowsDefault = false,
            SummaryProvider = TranslationProvider.Anthropic,
            SummaryBaseUrl = "https://summary.example.com",
            SummaryModel = "claude-summary",
            SummaryAuthToken = "summary-token",
        };

        var back = AppSettings.FromJson(settings.ToJson());
        Assert.False(back.SummaryFollowsDefault);
        Assert.Equal(TranslationProvider.Anthropic, back.ForSummary().TranslationProvider);
        Assert.Equal("https://summary.example.com", back.ForSummary().TranslationBaseUrl);
        Assert.Equal("claude-summary", back.ForSummary().TranslationModel);
        Assert.Equal("summary-token", back.ForSummary().TranslationAuthToken);
        Assert.True(back.IsSummaryConfigured);
    }

    [Fact]
    public void SummaryConfig_MissingKeysFollowDefaultAiSeededFromTranslation()
    {
        var settings = AppSettings.FromJson("""
            {
              "translationProvider": "openai",
              "translationBaseURL": "https://gateway.example.com",
              "translationModel": "gpt-4o-mini",
              "translationAuthToken": "tok"
            }
            """);

        Assert.True(settings.SummaryFollowsDefault);
        Assert.Equal(TranslationProvider.Openai, settings.AIProvider);
        Assert.Equal("https://gateway.example.com", settings.AIBaseUrl);
        Assert.Equal("gpt-4o-mini", settings.AIModel);
        Assert.Equal("tok", settings.AIAuthToken);
        Assert.Equal("gpt-4o-mini", settings.ForSummary().TranslationModel);
        Assert.True(settings.IsSummaryConfigured);
    }

    [Fact]
    public void TranslationConfig_FollowsDefaultAiWhenRequested()
    {
        var settings = new AppSettings
        {
            TranslationProvider = TranslationProvider.Anthropic,
            TranslationBaseUrl = "",
            TranslationModel = "",
            TranslationAuthToken = "",
            AIProvider = TranslationProvider.Openai,
            AIBaseUrl = "https://ai.example.com",
            AIModel = "gpt-default",
            AIAuthToken = "ai-token",
            TranslationFollowsDefault = true,
        };

        var effective = settings.ForTranslation();
        Assert.True(settings.IsTranslationConfigured);
        Assert.Equal(TranslationProvider.Openai, effective.TranslationProvider);
        Assert.Equal("https://ai.example.com", effective.TranslationBaseUrl);
        Assert.Equal("gpt-default", effective.TranslationModel);
        Assert.Equal("ai-token", effective.TranslationAuthToken);
    }

    [Fact]
    public void TranslationConfig_FollowsDefaultAiWithoutFallingBackToHiddenOverride()
    {
        var settings = new AppSettings
        {
            TranslationProvider = TranslationProvider.Anthropic,
            TranslationBaseUrl = "https://old-translation.example.com",
            TranslationModel = "claude-old",
            TranslationAuthToken = "old-translation-token",
            AIProvider = TranslationProvider.Openai,
            AIBaseUrl = "",
            AIModel = "",
            AIAuthToken = "",
            TranslationFollowsDefault = true,
        };

        var effective = settings.ForTranslation();
        Assert.False(settings.IsTranslationConfigured);
        Assert.Equal(TranslationProvider.Openai, effective.TranslationProvider);
        Assert.Equal("", effective.TranslationBaseUrl);
        Assert.Equal("", effective.TranslationModel);
        Assert.Equal("", effective.TranslationAuthToken);
    }

    [Fact]
    public void TranslationConfig_UsesOverrideWhenNotFollowingDefault()
    {
        var settings = new AppSettings
        {
            TranslationProvider = TranslationProvider.Anthropic,
            TranslationBaseUrl = "https://translation.example.com",
            TranslationModel = "claude-translate",
            TranslationAuthToken = "translation-token",
            AIProvider = TranslationProvider.Openai,
            AIBaseUrl = "https://ai.example.com",
            AIModel = "gpt-default",
            AIAuthToken = "ai-token",
            TranslationFollowsDefault = false,
        };

        var effective = settings.ForTranslation();
        Assert.True(settings.IsTranslationConfigured);
        Assert.Equal(TranslationProvider.Anthropic, effective.TranslationProvider);
        Assert.Equal("https://translation.example.com", effective.TranslationBaseUrl);
        Assert.Equal("claude-translate", effective.TranslationModel);
        Assert.Equal("translation-token", effective.TranslationAuthToken);
    }

    [Fact]
    public void EffectiveMaxConcurrentBurns_BumpsForHardware_ClampsAtFour()
    {
        Assert.Equal(3, new AppSettings { MaxConcurrentBurns = 2, EncodeBackend = EncodeBackend.Auto }.EffectiveMaxConcurrentBurns);
        Assert.Equal(3, new AppSettings { MaxConcurrentBurns = 2, EncodeBackend = EncodeBackend.Hardware }.EffectiveMaxConcurrentBurns);
        Assert.Equal(2, new AppSettings { MaxConcurrentBurns = 2, EncodeBackend = EncodeBackend.Software }.EffectiveMaxConcurrentBurns);
        Assert.Equal(4, new AppSettings { MaxConcurrentBurns = 3, EncodeBackend = EncodeBackend.Auto }.EffectiveMaxConcurrentBurns);
    }

    [Fact]
    public void FromJson_ConcurrencyClampedToValidRange()
    {
        var settings = AppSettings.FromJson("""{"maxConcurrentDownloads": 99, "maxConcurrentBurns": 0}""");
        Assert.Equal(5, settings.MaxConcurrentDownloads);
        Assert.Equal(1, settings.MaxConcurrentBurns);
    }

    /// <summary>旧版配置没有 provider 键：按 baseURL / 模型名推断。</summary>
    [Fact]
    public void FromJson_MissingProvider_InferredFromBaseUrlOrModel()
    {
        var byBase = AppSettings.FromJson("""{"translationBaseURL": "https://api.openai.com"}""");
        Assert.Equal(TranslationProvider.Openai, byBase.TranslationProvider);

        var byModel = AppSettings.FromJson("""{"translationBaseURL": "https://gw.corp.com", "translationModel": "gpt-4o"}""");
        Assert.Equal(TranslationProvider.Openai, byModel.TranslationProvider);

        var anthropic = AppSettings.FromJson("""{"translationBaseURL": "https://gw.corp.com", "translationModel": "claude-haiku"}""");
        Assert.Equal(TranslationProvider.Anthropic, anthropic.TranslationProvider);
    }

    [Fact]
    public void FromJson_SubtitleStyleParsed()
    {
        Assert.Equal(SubtitleStyle.ChineseOnly,
            AppSettings.FromJson("""{"subtitleStyle": "chineseOnly"}""").SubtitleStyle);
        Assert.Equal(SubtitleStyle.Bilingual,
            AppSettings.FromJson("""{"subtitleStyle": "bogus"}""").SubtitleStyle);
    }

    [Fact]
    public void SaveLoad_RoundTrip_AtomicWrite()
    {
        var dir = Path.Combine(Path.GetTempPath(), $"moongate-settings-{Guid.NewGuid():N}");
        AppSettings.OverrideSupportDirectory = dir;
        try
        {
            var settings = new AppSettings
            {
                TranslationProvider = TranslationProvider.Openai,
                TranslationBaseUrl = "https://gw.corp.com",
                TranslationModel = "gpt-4o-mini",
                TranslationAuthToken = "tok-123",
                SubtitleStyle = SubtitleStyle.ChineseOnly,
                MaxBurnHeight = null,
                MaxConcurrentDownloads = 5,
                MaxConcurrentBurns = 1,
            };
            settings.Save();
            Assert.True(File.Exists(AppSettings.SettingsFilePath));
            // 临时文件不残留
            Assert.Empty(Directory.GetFiles(dir, "*.tmp-*"));

            var loaded = AppSettings.Load();
            Assert.Equal(settings, loaded);
        }
        finally
        {
            AppSettings.OverrideSupportDirectory = null;
            try { Directory.Delete(dir, true); } catch { /* 忽略 */ }
        }
    }

    [Fact]
    public void Load_CorruptedFile_ReturnsDefaults()
    {
        var dir = Path.Combine(Path.GetTempPath(), $"moongate-settings-{Guid.NewGuid():N}");
        AppSettings.OverrideSupportDirectory = dir;
        try
        {
            Directory.CreateDirectory(dir);
            File.WriteAllText(AppSettings.SettingsFilePath, "not json at all");
            Assert.Equal(new AppSettings(), AppSettings.Load());
        }
        finally
        {
            AppSettings.OverrideSupportDirectory = null;
            try { Directory.Delete(dir, true); } catch { /* 忽略 */ }
        }
    }

    [Fact]
    public void IsTranslationConfigured_RequiresAllThreeFields()
    {
        var ready = new AppSettings
        {
            TranslationModel = "m",
            TranslationAuthToken = "t",
            TranslationFollowsDefault = false,
        };
        Assert.True(ready.IsTranslationConfigured);
        Assert.True(ready.IsTranslationEndpointConfigured);

        var noModel = ready with { TranslationModel = " " };
        Assert.False(noModel.IsTranslationConfigured);
        Assert.True(noModel.IsTranslationEndpointConfigured);
    }

    /// <summary>界面语言：默认 auto，未知值容错回 auto，合法值原样保留并随 JSON 往返。</summary>
    [Fact]
    public void AppLanguage_DefaultAuto_ToleratesUnknown_RoundTrips()
    {
        Assert.Equal("auto", new AppSettings().AppLanguage);
        Assert.Equal("auto", AppSettings.FromJson("{}").AppLanguage);
        Assert.Equal("auto", AppSettings.FromJson("""{"appLanguage": "klingon"}""").AppLanguage);
        Assert.Equal("en", AppSettings.FromJson("""{"appLanguage": "en"}""").AppLanguage);
        Assert.Equal("zh-Hans", AppSettings.FromJson("""{"appLanguage": "zh-Hans"}""").AppLanguage);

        var settings = new AppSettings { AppLanguage = "en" };
        Assert.Equal("en", AppSettings.FromJson(settings.ToJson()).AppLanguage);
    }

    /// <summary>L10n：默认中文；Pick 按显式语言取文案（不动全局开关，避免并行用例互扰）。</summary>
    [Fact]
    public void L10n_DefaultsToChinese_PickIsExplicit()
    {
        Assert.Equal(CoreLanguage.Chinese, L10n.Language);
        Assert.Equal("你好", L10n.Pick(CoreLanguage.Chinese, "你好", "hello"));
        Assert.Equal("hello", L10n.Pick(CoreLanguage.English, "你好", "hello"));
    }

    [Fact]
    public void L10n_PickSupportsTraditionalChinese()
    {
        Assert.Equal("你好", L10n.Pick(CoreLanguage.Chinese, "你好", "您好", "hello"));
        Assert.Equal("您好", L10n.Pick(CoreLanguage.TraditionalChinese, "你好", "您好", "hello"));
        Assert.Equal("hello", L10n.Pick(CoreLanguage.English, "你好", "您好", "hello"));
    }

    [Fact]
    public void MoongateException_UsesTraditionalChineseErrorShells()
    {
        var previous = L10n.Language;
        L10n.Language = CoreLanguage.TraditionalChinese;
        try
        {
            Assert.Equal("下載失敗：網路中斷", MoongateException.DownloadFailed("網路中斷").Message);
            Assert.Equal("字幕翻譯失敗：逾時", MoongateException.TranslateFailed("逾時").Message);
            Assert.Equal("已取消", MoongateException.Cancelled().Message);
        }
        finally
        {
            L10n.Language = previous;
        }
    }

    [Fact]
    public void CookieFilePath_SameDirectoryAsSettings()
    {
        AppSettings.OverrideSupportDirectory = "/tmp/moongate-x";
        try
        {
            Assert.Equal(Path.Combine("/tmp/moongate-x", "cookies.txt"), AppSettings.CookieFilePath);
            Assert.Equal(Path.Combine("/tmp/moongate-x", "settings.json"), AppSettings.SettingsFilePath);
        }
        finally
        {
            AppSettings.OverrideSupportDirectory = null;
        }
    }
}

public class CookieFileTests
{
    [Fact]
    public void Write_NetscapeFormat()
    {
        var path = Path.Combine(Path.GetTempPath(), $"moongate-cookies-{Guid.NewGuid():N}", "cookies.txt");
        try
        {
            NetscapeCookieFile.Write(
            [
                new CookieRecord
                {
                    Domain = ".youtube.com", Path = "/", Name = "SID", Value = "abc123",
                    IsSecure = true, ExpiresEpochSeconds = 1893456000,
                },
                new CookieRecord
                {
                    Domain = "example.com", Path = "/x", Name = "session", Value = "s1",
                    IsSecure = false, ExpiresEpochSeconds = null,  // session cookie
                },
                new CookieRecord
                {
                    Domain = "bad.com", Path = "/", Name = "evil", Value = "a\tb",  // 含制表符 → 跳过
                    IsSecure = false, ExpiresEpochSeconds = 0,
                },
            ], path);

            var lines = File.ReadAllLines(path);
            Assert.Equal("# Netscape HTTP Cookie File", lines[0]);
            Assert.Equal(3, lines.Length);  // 头 + 两条（坏 cookie 跳过）
            Assert.Equal(".youtube.com\tTRUE\t/\tTRUE\t1893456000\tSID\tabc123", lines[1]);
            Assert.Equal("example.com\tFALSE\t/x\tFALSE\t0\tsession\ts1", lines[2]);
        }
        finally
        {
            try { Directory.Delete(Path.GetDirectoryName(path)!, true); } catch { /* 忽略 */ }
        }
    }

    [Fact]
    public void Write_NegativeExpiry_ClampedToZero()
    {
        var path = Path.Combine(Path.GetTempPath(), $"moongate-cookies-{Guid.NewGuid():N}.txt");
        try
        {
            NetscapeCookieFile.Write(
            [
                new CookieRecord
                {
                    Domain = "a.com", Path = "/", Name = "n", Value = "v",
                    ExpiresEpochSeconds = -5,
                },
            ], path);
            Assert.Contains("a.com\tFALSE\t/\tFALSE\t0\tn\tv", File.ReadAllText(path));
        }
        finally
        {
            try { File.Delete(path); } catch { /* 忽略 */ }
        }
    }

    [Fact]
    public void Clear_MissingFile_Silent()
    {
        NetscapeCookieFile.Clear("/tmp/definitely-not-there-" + Guid.NewGuid());
    }
}
