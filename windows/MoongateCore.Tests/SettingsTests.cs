using Moongate.Core;

namespace MoongateCore.Tests;

[Collection(L10nLanguageCollection.Name)]
public class SettingsTests
{
    /// <summary>SEC-CRED-001：迁移失败时不丢 Token 的测试用——Set 永远抛错的存储。</summary>
    private sealed class ThrowingCredentialStore : ICredentialStore
    {
        public string? Get(string key) => null;
        public void Set(string key, string value) => throw new IOException("store unavailable");
        public void Delete(string key) { }
    }

    [Fact]
    public void Credentials_MigrateLegacyPlaintextIntoStoreAndStripFromDisk()
    {
        var prevStore = AppSettings.CredentialStore;
        var prevDir = AppSettings.OverrideSupportDirectory;
        var dir = Path.Combine(Path.GetTempPath(), $"moongate-cred-{Guid.NewGuid():N}");
        Directory.CreateDirectory(dir);
        try
        {
            AppSettings.OverrideSupportDirectory = dir;
            var store = new InMemoryCredentialStore();
            AppSettings.CredentialStore = store;
            // 旧版文件：明文 Token 直接写在 JSON 里（ToJson 仍含 token，用来构造 legacy 文件）。
            File.WriteAllText(AppSettings.SettingsFilePath,
                new AppSettings { TranslationAuthToken = "secret-t", AIAuthToken = "secret-ai" }.ToJson());

            var loaded = AppSettings.Load();

            // 迁移进安全存储。
            Assert.Equal("secret-t", store.Get("translationAuthToken"));
            Assert.Equal("secret-ai", store.Get("aiAuthToken"));
            // 内存配置仍可用（覆盖回内存）。
            Assert.Equal("secret-t", loaded.TranslationAuthToken);
            Assert.Equal("secret-ai", loaded.AIAuthToken);
            // 磁盘文件已抹去明文。
            var raw = File.ReadAllText(AppSettings.SettingsFilePath);
            Assert.DoesNotContain("secret-t", raw);
            Assert.DoesNotContain("secret-ai", raw);
        }
        finally
        {
            AppSettings.CredentialStore = prevStore;
            AppSettings.OverrideSupportDirectory = prevDir;
            try { Directory.Delete(dir, true); } catch { /* 忽略 */ }
        }
    }

    [Fact]
    public void Credentials_SaveWritesNoPlaintextToDiskButRoundTripsViaStore()
    {
        var prevStore = AppSettings.CredentialStore;
        var prevDir = AppSettings.OverrideSupportDirectory;
        var dir = Path.Combine(Path.GetTempPath(), $"moongate-cred-{Guid.NewGuid():N}");
        Directory.CreateDirectory(dir);
        try
        {
            AppSettings.OverrideSupportDirectory = dir;
            var store = new InMemoryCredentialStore();
            AppSettings.CredentialStore = store;

            new AppSettings { TranslationModel = "m", TranslationAuthToken = "plaintext-xyz" }.Save();

            var raw = File.ReadAllText(AppSettings.SettingsFilePath);
            Assert.DoesNotContain("plaintext-xyz", raw);     // 磁盘无明文
            Assert.Equal("plaintext-xyz", store.Get("translationAuthToken"));
            Assert.Equal("plaintext-xyz", AppSettings.Load().TranslationAuthToken); // 从安全存储取回
        }
        finally
        {
            AppSettings.CredentialStore = prevStore;
            AppSettings.OverrideSupportDirectory = prevDir;
            try { Directory.Delete(dir, true); } catch { /* 忽略 */ }
        }
    }

    [Fact]
    public void CloudAsrSettings_DefaultOffRequireConsentAndUseCredentialStore()
    {
        var fresh = new AppSettings();
        Assert.False(fresh.CloudAsrEnabled);
        Assert.False(fresh.CloudAsrConsentAccepted);
        Assert.Equal("https://api.openai.com", fresh.CloudAsrBaseUrl);
        Assert.Equal("whisper-1", fresh.CloudAsrModel);
        Assert.Equal("", fresh.CloudAsrAuthToken);
        Assert.False(fresh.IsCloudAsrConfigured);
        Assert.False(fresh.CloudAsrModelRequiresAlignment);

        var prevStore = AppSettings.CredentialStore;
        var prevDir = AppSettings.OverrideSupportDirectory;
        var dir = Path.Combine(Path.GetTempPath(), $"moongate-cloud-asr-{Guid.NewGuid():N}");
        Directory.CreateDirectory(dir);
        try
        {
            AppSettings.OverrideSupportDirectory = dir;
            var store = new InMemoryCredentialStore();
            AppSettings.CredentialStore = store;

            new AppSettings
            {
                CloudAsrEnabled = true,
                CloudAsrConsentAccepted = true,
                CloudAsrBaseUrl = " https://api.openai.com/v1\n",
                CloudAsrModel = "\nwhisper-1 ",
                CloudAsrAuthToken = "cloud-token",
            }.Save();

            var raw = File.ReadAllText(AppSettings.SettingsFilePath);
            Assert.DoesNotContain("cloud-token", raw);
            Assert.Equal("cloud-token", store.Get("cloudASRAuthToken"));

            var loaded = AppSettings.Load();
            Assert.True(loaded.CloudAsrEnabled);
            Assert.True(loaded.CloudAsrConsentAccepted);
            Assert.Equal("https://api.openai.com/v1", loaded.CloudAsrBaseUrl);
            Assert.Equal("whisper-1", loaded.CloudAsrModel);
            Assert.Equal("cloud-token", loaded.CloudAsrAuthToken);
            Assert.True(loaded.IsCloudAsrConfigured);
            Assert.False(loaded.CloudAsrModelRequiresAlignment);

            var alignmentOnly = loaded with { CloudAsrModel = "gpt-4o-transcribe" };
            Assert.False(alignmentOnly.IsCloudAsrConfigured);
            Assert.True(alignmentOnly.CloudAsrModelRequiresAlignment);
        }
        finally
        {
            AppSettings.CredentialStore = prevStore;
            AppSettings.OverrideSupportDirectory = prevDir;
            try { Directory.Delete(dir, true); } catch { /* ignored */ }
        }
    }

    [Fact]
    public void CloudAsrGeneratorFactoryRequiresExplicitConfiguration()
    {
        Assert.Null(CloudAsrGeneratorFactory.Create(new AppSettings()));

        var configured = new AppSettings
        {
            CloudAsrEnabled = true,
            CloudAsrConsentAccepted = true,
            CloudAsrBaseUrl = "https://api.openai.com",
            CloudAsrModel = "whisper-1",
            CloudAsrAuthToken = "sk-test",
        };

        Assert.NotNull(CloudAsrGeneratorFactory.Create(configured));
        Assert.Null(CloudAsrGeneratorFactory.Create(configured with { CloudAsrConsentAccepted = false }));
        Assert.Null(CloudAsrGeneratorFactory.Create(configured with { CloudAsrBaseUrl = "not a url" }));
        Assert.Null(CloudAsrGeneratorFactory.Create(configured with { CloudAsrModel = "gpt-4o-transcribe" }));
        Assert.NotNull(CloudAsrGeneratorFactory.Create(
            configured with { CloudAsrModel = "gpt-4o-transcribe" },
            new FakeLocalAsrGenerator()));
    }

    [Fact]
    public void Credentials_MigrationStoreFailure_KeepsLegacyTokenNotLost()
    {
        var prevStore = AppSettings.CredentialStore;
        var prevDir = AppSettings.OverrideSupportDirectory;
        var dir = Path.Combine(Path.GetTempPath(), $"moongate-cred-{Guid.NewGuid():N}");
        Directory.CreateDirectory(dir);
        try
        {
            AppSettings.OverrideSupportDirectory = dir;
            AppSettings.CredentialStore = new ThrowingCredentialStore();
            File.WriteAllText(AppSettings.SettingsFilePath,
                new AppSettings { TranslationAuthToken = "secret-t" }.ToJson());

            var loaded = AppSettings.Load();

            // 安全存储写入失败：Token 不丢——内存仍有，磁盘明文仍保留（下次启动再试迁移）。
            Assert.Equal("secret-t", loaded.TranslationAuthToken);
            Assert.Contains("secret-t", File.ReadAllText(AppSettings.SettingsFilePath));
        }
        finally
        {
            AppSettings.CredentialStore = prevStore;
            AppSettings.OverrideSupportDirectory = prevDir;
            try { Directory.Delete(dir, true); } catch { /* 忽略 */ }
        }
    }

    [Fact]
    public void Credentials_SaveStoreFailure_ThrowsAndDoesNotWriteSettings()
    {
        var prevStore = AppSettings.CredentialStore;
        var prevDir = AppSettings.OverrideSupportDirectory;
        var dir = Path.Combine(Path.GetTempPath(), $"moongate-cred-{Guid.NewGuid():N}");
        Directory.CreateDirectory(dir);
        try
        {
            AppSettings.OverrideSupportDirectory = dir;
            AppSettings.CredentialStore = new ThrowingCredentialStore();

            Assert.ThrowsAny<Exception>(() =>
                new AppSettings { TranslationAuthToken = "x" }.Save());
            // 安全存储先写、失败即抛——settings.json 不应被写出。
            Assert.False(File.Exists(AppSettings.SettingsFilePath));
        }
        finally
        {
            AppSettings.CredentialStore = prevStore;
            AppSettings.OverrideSupportDirectory = prevDir;
            try { Directory.Delete(dir, true); } catch { /* 忽略 */ }
        }
    }

    [Fact]
    public void Load_CorruptFile_BacksUpAndReturnsDefaultsWithoutOverwriting()
    {
        var previous = AppSettings.OverrideSupportDirectory;
        var dir = Path.Combine(Path.GetTempPath(), $"moongate-corrupt-{Guid.NewGuid():N}");
        Directory.CreateDirectory(dir);
        try
        {
            AppSettings.OverrideSupportDirectory = dir;
            AppSettings.LastCorruptBackupPath = null;
            File.WriteAllText(AppSettings.SettingsFilePath, "{ this is not valid json ");

            var settings = AppSettings.Load();

            // 回默认而非崩溃。
            Assert.Equal(new AppSettings().TranslationBaseUrl, settings.TranslationBaseUrl);
            // 损坏文件被改名备份，不再原地等下次保存覆盖。
            Assert.False(File.Exists(AppSettings.SettingsFilePath));
            Assert.NotNull(AppSettings.LastCorruptBackupPath);
            Assert.True(File.Exists(AppSettings.LastCorruptBackupPath!));
            Assert.Contains("settings.corrupt-", AppSettings.LastCorruptBackupPath!);
            Assert.Single(Directory.GetFiles(dir, "settings.corrupt-*.json"));
        }
        finally
        {
            AppSettings.LastCorruptBackupPath = null;
            AppSettings.OverrideSupportDirectory = previous;
            try { Directory.Delete(dir, true); } catch { /* 忽略 */ }
        }
    }

    [Fact]
    public void Load_ValidFile_NoBackup()
    {
        var previous = AppSettings.OverrideSupportDirectory;
        var dir = Path.Combine(Path.GetTempPath(), $"moongate-valid-{Guid.NewGuid():N}");
        Directory.CreateDirectory(dir);
        try
        {
            AppSettings.OverrideSupportDirectory = dir;
            AppSettings.LastCorruptBackupPath = null;
            new AppSettings { TranslationModel = "claude" }.Save();

            var settings = AppSettings.Load();

            Assert.Equal("claude", settings.TranslationModel);
            Assert.Null(AppSettings.LastCorruptBackupPath);
            Assert.Empty(Directory.GetFiles(dir, "settings.corrupt-*.json"));
        }
        finally
        {
            AppSettings.LastCorruptBackupPath = null;
            AppSettings.OverrideSupportDirectory = previous;
            try { Directory.Delete(dir, true); } catch { /* 忽略 */ }
        }
    }

    [Fact]
    public void LastDownloadOptions_RoundTripAndDefault()
    {
        // PARITY-002：上次下载选项默认空，能往返。
        var fresh = new AppSettings();
        Assert.Null(fresh.LastSubtitleMode);
        Assert.Empty(fresh.LastSubtitleLangs);
        Assert.Null(fresh.LastOutputFormat);
        Assert.False(fresh.LastPreferHdr);

        var settings = new AppSettings
        {
            LastSubtitleMode = "burnIn",
            LastSubtitleLangs = ["ja", "en"],
            LastPrimarySubtitleTrackId = "localASR|whisper.cpp|ja|local",
            LastOutputFormat = "mp4H265",
            LastPreferHdr = true,
        };
        var back = AppSettings.FromJson(settings.ToJson());
        Assert.Equal("burnIn", back.LastSubtitleMode);
        Assert.Equal(new[] { "ja", "en" }, back.LastSubtitleLangs.ToArray());
        Assert.Equal("localASR|whisper.cpp|ja|local", back.LastPrimarySubtitleTrackId);
        Assert.Equal("mp4H265", back.LastOutputFormat);
        Assert.True(back.LastPreferHdr);
    }

    [Fact]
    public void Defaults()
    {
        var settings = new AppSettings();
        Assert.Equal(TranslationProvider.Anthropic, settings.TranslationProvider);
        Assert.Equal("https://api.anthropic.com", settings.TranslationBaseUrl);
        Assert.Equal(SubtitleStyle.Bilingual, settings.SubtitleStyle);
        Assert.Null(settings.MaxBurnHeight);
        Assert.Equal(3, settings.MaxConcurrentDownloads);
        Assert.Equal(2, settings.MaxConcurrentBurns);
    }

    /// <summary>缺字段容错：空 JSON 全部回默认（烧录默认保持源分辨率，避免 4K 选择被静默压到 1080）。</summary>
    [Fact]
    public void FromJson_EmptyObject_AllDefaults()
    {
        var settings = AppSettings.FromJson("{}");
        // 值等价比较用 JSON（记录里含集合字段 LastSubtitleLangs，record 默认相等是引用比较，不适用）。
        Assert.Equal(new AppSettings().ToJson(), settings.ToJson());
        Assert.Null(settings.MaxBurnHeight);
    }

    /// <summary>显式 null 的 maxBurnHeight 表示「保持源分辨率」。</summary>
    [Fact]
    public void FromJson_ExplicitNullBurnHeight_MeansKeepSource()
    {
        var settings = AppSettings.FromJson("""{"maxBurnHeight": null}""");
        Assert.Null(settings.MaxBurnHeight);
    }

    /// <summary>显式 1080 保留「高分辨率烧录缩放到 1080p」选项。</summary>
    [Fact]
    public void FromJson_ExplicitBurnHeight1080_KeepsScaleDownSetting()
    {
        var settings = AppSettings.FromJson("""{"maxBurnHeight": 1080}""");
        Assert.Equal(1080, settings.MaxBurnHeight);
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
    public void VideoProxy_RoundTripsAndNormalizes()
    {
        var settings = AppSettings.FromJson("""{"videoProxyURL": "127.0.0.1:7890", "ignoreVideoCertificateErrors": true}""");
        Assert.Equal("http://127.0.0.1:7890", settings.VideoProxyUrl);
        Assert.True(settings.IgnoreVideoCertificateErrors);

        var back = AppSettings.FromJson(new AppSettings
        {
            VideoProxyUrl = "socks5://127.0.0.1:1080/",
            IgnoreVideoCertificateErrors = true,
        }.ToJson());
        Assert.Equal("socks5://127.0.0.1:1080", back.VideoProxyUrl);
        Assert.True(back.IgnoreVideoCertificateErrors);
    }

    [Theory]
    [InlineData("")]
    [InlineData("file:///tmp/proxy")]
    [InlineData("http://good:7890\nhttp://bad:7890")]
    public void VideoProxy_InvalidValuesBecomeEmpty(string raw)
    {
        Assert.Equal("", AppSettings.NormalizeVideoProxyUrl(raw));
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
    public void LocalAsrSettings_DefaultOffAndRoundTripThroughJson()
    {
        var fresh = new AppSettings();
        Assert.False(fresh.LocalAsrEnabled);
        Assert.Equal("", fresh.LocalAsrRuntimePath);
        Assert.Equal("", fresh.LocalAsrModelPath);
        Assert.Equal("", fresh.LocalAsrModelId);
        Assert.False(fresh.LocalAsrPreciseModeEnabled);
        Assert.Equal("", fresh.LocalAsrSidecarRuntimePath);
        Assert.Equal("", fresh.LocalAsrSidecarModelPath);
        Assert.False(fresh.IsLocalAsrSidecarConfigured);

        var settings = new AppSettings
        {
            LocalAsrEnabled = true,
            LocalAsrRuntimePath = " C:\\Tools\\whisper-cli.exe\n",
            LocalAsrModelPath = "\nC:\\Models\\ggml-small-q5_1.bin ",
            LocalAsrModelId = " whisper.cpp:small-q5_1\n",
            LocalAsrPreciseModeEnabled = true,
            LocalAsrSidecarRuntimePath = " C:\\Tools\\faster-whisper-sidecar.exe\n",
            LocalAsrSidecarModelPath = "\nC:\\Models\\faster-whisper-small ",
        };
        var back = AppSettings.FromJson(settings.ToJson());
        Assert.True(back.LocalAsrEnabled);
        Assert.Equal("C:\\Tools\\whisper-cli.exe", back.LocalAsrRuntimePath);
        Assert.Equal("C:\\Models\\ggml-small-q5_1.bin", back.LocalAsrModelPath);
        Assert.Equal("whisper.cpp:small-q5_1", back.LocalAsrModelId);
        Assert.True(back.LocalAsrPreciseModeEnabled);
        Assert.Equal("C:\\Tools\\faster-whisper-sidecar.exe", back.LocalAsrSidecarRuntimePath);
        Assert.Equal("C:\\Models\\faster-whisper-small", back.LocalAsrSidecarModelPath);
        Assert.True(back.IsLocalAsrSidecarConfigured);
        var json = settings.ToJson();
        Assert.Contains("\"localASREnabled\"", json, StringComparison.Ordinal);
        Assert.Contains("\"localASRRuntimePath\"", json, StringComparison.Ordinal);
        Assert.Contains("\"localASRModelPath\"", json, StringComparison.Ordinal);
        Assert.Contains("\"localASRModelID\"", json, StringComparison.Ordinal);
        Assert.Contains("\"localASRPreciseModeEnabled\"", json, StringComparison.Ordinal);
        Assert.Contains("\"localASRSidecarRuntimePath\"", json, StringComparison.Ordinal);
        Assert.Contains("\"localASRSidecarModelPath\"", json, StringComparison.Ordinal);
    }

    [Fact]
    public void CompletionNotificationSettings_DefaultOnAndRoundTrip()
    {
        var fresh = new AppSettings();
        Assert.True(fresh.CompletionNotificationsEnabled);
        Assert.True(fresh.CompletionSoundEnabled);

        var settings = new AppSettings
        {
            CompletionNotificationsEnabled = false,
            CompletionSoundEnabled = false,
        };
        var back = AppSettings.FromJson(settings.ToJson());
        Assert.False(back.CompletionNotificationsEnabled);
        Assert.False(back.CompletionSoundEnabled);
        var json = settings.ToJson();
        Assert.Contains("\"completionNotificationsEnabled\"", json, StringComparison.Ordinal);
        Assert.Contains("\"completionSoundEnabled\"", json, StringComparison.Ordinal);
    }

    [Fact]
    public void ReceiveBetaUpdates_DefaultsOnAndRoundTrips()
    {
        // 默认接收测试版（当前发布全是 prerelease，避免老用户收不到更新）。
        Assert.True(new AppSettings().ReceiveBetaUpdates);
        Assert.True(AppSettings.FromJson("{}").ReceiveBetaUpdates);
        // 仅显式 false 关闭，且能往返。
        var off = AppSettings.FromJson("""{"receiveBetaUpdates": false}""");
        Assert.False(off.ReceiveBetaUpdates);
        Assert.False(AppSettings.FromJson(off.ToJson()).ReceiveBetaUpdates);
        Assert.Contains("\"receiveBetaUpdates\"", off.ToJson());
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
        var settings = AppSettings.FromJson("""{"appLanguage": "klingon", "translationTargetLanguage": "elvish", "preferredSourceLanguage": "na'vi"}""");
        Assert.Equal("auto", settings.AppLanguage);
        Assert.Equal("zh-Hans", settings.TranslationTargetLanguage);
        Assert.Equal("auto", settings.PreferredSourceLanguage);
    }

    /// <summary>parity：ToJson 必须用与 Swift 端完全一致的 JSON key 名。</summary>
    [Fact]
    public void ToJson_UsesAgreedCrossPlatformLanguageKeys()
    {
        var json = new AppSettings().ToJson();
        Assert.Contains("\"appLanguage\"", json);
        Assert.Contains("\"translationTargetLanguage\"", json);
        Assert.Contains("\"preferredSourceLanguage\"", json);
        Assert.Contains("\"onboardingCompleted\"", json);
    }

    [Fact]
    public void PreferredSourceLanguage_DefaultsAndRoundTrips()
    {
        Assert.Equal("auto", new AppSettings().PreferredSourceLanguage);
        Assert.Equal("auto", AppSettings.FromJson("{}").PreferredSourceLanguage);

        var settings = new AppSettings { PreferredSourceLanguage = "ja" };
        var back = AppSettings.FromJson(settings.ToJson());
        Assert.Equal("ja", back.PreferredSourceLanguage);
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
            Assert.Equal(settings.ToJson(), loaded.ToJson());
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
