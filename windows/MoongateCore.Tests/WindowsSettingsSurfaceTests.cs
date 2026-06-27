using System.Text.RegularExpressions;

namespace MoongateCore.Tests;

public class WindowsSettingsSurfaceTests
{
    private static string RepoRoot()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null)
        {
            if (File.Exists(Path.Combine(dir.FullName, "Package.swift"))
                && Directory.Exists(Path.Combine(dir.FullName, "windows")))
            {
                return dir.FullName;
            }
            dir = dir.Parent;
        }
        throw new DirectoryNotFoundException("Could not locate repository root.");
    }

    private static string Read(params string[] parts) => File.ReadAllText(Path.Combine([RepoRoot(), .. parts]));

    private static IReadOnlySet<string> ResourceKeys(string xaml) => xaml
        .Split('\n')
        .Select(line => line.Split("x:Key=\"", 2, StringSplitOptions.None))
        .Where(parts => parts.Length == 2)
        .Select(parts => parts[1].Split('"', 2)[0])
        .ToHashSet(StringComparer.Ordinal);

    [Fact]
    public void WindowsChineseTypographyUsesCjkUiFontsAndCulture()
    {
        var loc = Read("windows", "MoongateApp", "Loc.cs");

        Assert.Contains("CultureInfo.DefaultThreadCurrentUICulture = culture", loc);
        Assert.Contains("XmlLanguage.GetLanguage(CurrentCultureName)", loc);
        Assert.Contains("Microsoft YaHei UI, Microsoft JhengHei UI, Segoe UI", loc);
        Assert.Contains("Microsoft JhengHei UI, Microsoft YaHei UI, Segoe UI", loc);

        foreach (var path in new[]
        {
            Path.Combine("windows", "MoongateApp", "MainWindow.xaml.cs"),
            Path.Combine("windows", "MoongateApp", "SettingsWindow.xaml.cs"),
            Path.Combine("windows", "MoongateApp", "ConfirmWindow.xaml.cs"),
            Path.Combine("windows", "MoongateApp", "LoginWindow.xaml.cs"),
            Path.Combine("windows", "MoongateApp", "OnboardingWindow.xaml.cs"),
            Path.Combine("windows", "MoongateApp", "DependencyWindow.xaml.cs"),
        })
        {
            var source = Read(path.Split(Path.DirectorySeparatorChar));
            Assert.Contains("LocalizationManager.ApplyTypography(this);", source);
        }
    }

    [Fact]
    public void WindowsLoginCookieExportVerifiesJarMatchesStartUrlBeforeRetrying()
    {
        var source = Read("windows", "MoongateApp", "LoginWindow.xaml.cs");
        var zh = Read("windows", "MoongateApp", "Strings.zh.xaml");
        var zhHant = Read("windows", "MoongateApp", "Strings.zh-Hant.xaml");
        var en = Read("windows", "MoongateApp", "Strings.en.xaml");

        Assert.Contains("NetscapeCookieFile.CookieHeaderFor(new Uri(StartUrl(_site, _startUrl)), path)", source);
        Assert.Contains("L.Login.NoUsableCookiesForPage", source);
        Assert.Contains("throw new InvalidOperationException(Loc.S(\"L.Login.NoUsableCookiesForPage\"))", source);
        foreach (var resource in new[] { zh, zhHant, en })
        {
            Assert.Contains("x:Key=\"L.Login.NoUsableCookiesForPage\"", resource);
        }
    }

    [Fact]
    public void WindowsFirstRunOnboardingPersistsLanguagesAndOffersApiEditor()
    {
        var mainWindowCode = Read("windows", "MoongateApp", "MainWindow.xaml.cs");
        var onboardingXaml = Read("windows", "MoongateApp", "OnboardingWindow.xaml");
        var onboardingCode = Read("windows", "MoongateApp", "OnboardingWindow.xaml.cs");
        var zh = Read("windows", "MoongateApp", "Strings.zh.xaml");
        var en = Read("windows", "MoongateApp", "Strings.en.xaml");
        var zhHant = Read("windows", "MoongateApp", "Strings.zh-Hant.xaml");

        Assert.Contains("ShowOnboardingIfNeeded();", mainWindowCode);
        Assert.Contains("if (_vm.Settings.OnboardingCompleted) return;", mainWindowCode);
        Assert.Contains("new OnboardingWindow(_vm) { Owner = this }", mainWindowCode);

        Assert.Contains("L.Onboarding.AppLanguage", onboardingXaml);
        Assert.Contains("L.Onboarding.TargetLanguage", onboardingXaml);
        Assert.Contains("L.Onboarding.AIOptional", onboardingXaml);
        Assert.Contains("AppLanguageBox", onboardingXaml);
        Assert.Contains("TargetLanguageBox", onboardingXaml);
        Assert.Contains("Content=\"繁體中文\"", onboardingXaml);

        // v0.8：onboarding 选非本地翻译时内联展示与设置页一致的完整 API 编辑器
        // （URL / API key / 拉取模型 / 测试连接），复用 APIEndpointActions，不再只设默认值。
        Assert.Contains("OnboardingApiTokenBox", onboardingXaml);
        Assert.Contains("Endpoint.FetchModelsCommand", onboardingXaml);
        Assert.Contains("Endpoint.TestConnectionCommand", onboardingXaml);
        Assert.Contains("L.Settings.BaseUrl", onboardingXaml);
        Assert.Contains("L.Settings.TestConnection", onboardingXaml);

        Assert.Contains("APIEndpointActions", onboardingCode);
        Assert.Contains("OnboardingCompleted = true", onboardingCode);
        Assert.Contains("AppLanguage = SelectedAppLanguage", onboardingCode);
        Assert.Contains("TranslationTargetLanguage = SelectedTargetLanguage", onboardingCode);
        Assert.Contains("AIAuthToken = _apiEditor.AuthToken", onboardingCode);
        Assert.Contains("AIModel = _apiEditor.Model", onboardingCode);
        Assert.Contains("settings.Save()", onboardingCode);
        Assert.Contains("LocalizationManager.Apply(settings.AppLanguage)", onboardingCode);

        foreach (var resource in new[] { zh, en, zhHant })
        {
            Assert.Contains("x:Key=\"L.Onboarding.Title\"", resource);
            Assert.Contains("x:Key=\"L.Onboarding.AppLanguage\"", resource);
            Assert.Contains("x:Key=\"L.Onboarding.TargetLanguage\"", resource);
            Assert.Contains("x:Key=\"L.Onboarding.AIOptional\"", resource);
        }
    }

    [Fact]
    public void WindowsFirstRunOnboardingIsStagedAndKeepsLocalAsrConsentDownloadFree()
    {
        var onboardingXaml = Read("windows", "MoongateApp", "OnboardingWindow.xaml");
        var onboardingCode = Read("windows", "MoongateApp", "OnboardingWindow.xaml.cs");
        var settings = Read("windows", "MoongateCore", "Settings.cs");
        var zh = Read("windows", "MoongateApp", "Strings.zh.xaml");
        var en = Read("windows", "MoongateApp", "Strings.en.xaml");
        var zhHant = Read("windows", "MoongateApp", "Strings.zh-Hant.xaml");

        Assert.Contains("OnboardingStep", onboardingCode);
        Assert.Contains("Language", onboardingCode);
        Assert.Contains("SubtitleSource", onboardingCode);
        Assert.Contains("TranslationMethod", onboardingCode);
        Assert.Contains("Readiness", onboardingCode);
        Assert.Contains("ShowStep(", onboardingCode);
        Assert.Contains("OnBackClick", onboardingCode);
        Assert.Contains("OnNextClick", onboardingCode);

        Assert.Contains("L.Onboarding.LanguageStep", onboardingXaml);
        Assert.Contains("L.Onboarding.SubtitleSourceStep", onboardingXaml);
        Assert.Contains("L.Onboarding.TranslationMethodStep", onboardingXaml);
        Assert.Contains("L.Onboarding.ReadinessStep", onboardingXaml);
        Assert.Contains("L.Onboarding.PlatformSubtitlePreference", onboardingXaml);
        Assert.Contains("PreferLocalSpeechRecognitionBox", onboardingXaml);
        Assert.Contains("L.Onboarding.LocalSpeechSetupLater", onboardingXaml);
        Assert.Contains("L.Onboarding.TranslationProvider", onboardingXaml);
        Assert.Contains("TranslationProviderBox", onboardingXaml);
        Assert.Contains("L.Onboarding.ReadinessSummary", onboardingXaml);
        Assert.Contains("BackButton", onboardingXaml);
        Assert.Contains("NextButton", onboardingXaml);
        Assert.Contains("StartButton", onboardingXaml);

        Assert.Contains("LocalAsrEnabled = PreferLocalSpeechRecognitionBox.IsChecked == true", onboardingCode);
        Assert.Contains("var provider = SelectedTranslationProvider;", onboardingCode);
        Assert.Contains("SummaryTranslationMethod.Text = SelectedComboBoxText(TranslationProviderBox)", onboardingCode);
        Assert.Contains("AIProvider = provider", onboardingCode);
        Assert.Contains("TranslationProvider = provider", onboardingCode);
        Assert.Contains("TranslationFollowsDefault = true", onboardingCode);
        Assert.Contains("LocalAsrEnabled", settings);
        // 本地 ASR 仍只收集「是否偏向本地识别」同意，不在 onboarding 暴露模型/运行时路径或下载动作。
        Assert.DoesNotContain("localASRModelPath", onboardingXaml);
        Assert.DoesNotContain("localASRRuntimePath", onboardingXaml);
        Assert.DoesNotContain("downloadModel", onboardingXaml, StringComparison.OrdinalIgnoreCase);

        foreach (var resource in new[] { zh, en, zhHant })
        {
            Assert.Contains("x:Key=\"L.Onboarding.LanguageStep\"", resource);
            Assert.Contains("x:Key=\"L.Onboarding.SubtitleSourceStep\"", resource);
            Assert.Contains("x:Key=\"L.Onboarding.TranslationMethodStep\"", resource);
            Assert.Contains("x:Key=\"L.Onboarding.TranslationProvider\"", resource);
            Assert.Contains("x:Key=\"L.Onboarding.ReadinessStep\"", resource);
            Assert.Contains("x:Key=\"L.Onboarding.LocalSpeechSetupLater\"", resource);
            Assert.Contains("x:Key=\"L.Onboarding.ReadinessSummary\"", resource);
            Assert.Contains("x:Key=\"L.Onboarding.Next\"", resource);
            Assert.Contains("x:Key=\"L.Onboarding.Back\"", resource);
        }
    }

    [Fact]
    public void WindowsSettingsExposeAppAndTargetLanguageControls()
    {
        var xaml = Read("windows", "MoongateApp", "SettingsWindow.xaml");
        var viewModel = Read("windows", "MoongateApp", "SettingsViewModel.cs");
        var loc = Read("windows", "MoongateApp", "Loc.cs");

        Assert.Contains("L.Settings.TargetLanguage", xaml);
        Assert.Contains("TargetLanguageIndex", xaml);
        Assert.Contains("Content=\"繁體中文\"", xaml);
        Assert.Contains("_targetLanguageIndex = current.TranslationTargetLanguage", viewModel);
        Assert.Contains("public int TargetLanguageIndex", viewModel);
        Assert.Contains("TranslationTargetLanguage = TargetLanguageIndex switch", viewModel);
        Assert.Contains("OnboardingCompleted = _onboardingCompleted", viewModel);
        Assert.Contains("\"zh-Hant\" => \"Strings.zh-Hant.xaml\"", loc);
    }

    [Fact]
    public void WindowsDefaultQueueReceivesLocalAsrGeneratorThroughSettingsFactory()
    {
        var viewModel = Read("windows", "MoongateApp", "MainViewModel.cs");

        Assert.Contains("LocalAsrGeneratorFactory.Create(_settings)", viewModel);
        Assert.Contains("localAsrGenerator:", viewModel);
        Assert.DoesNotContain("new WhisperCppLocalAsrSubtitleGenerator(", viewModel);
    }

    [Fact]
    public void WindowsDefaultQueueReceivesCompletionNotifierThroughAppLayer()
    {
        var viewModel = Read("windows", "MoongateApp", "MainViewModel.cs");

        Assert.Contains("IQueueCompletionNotifier", viewModel);
        Assert.Contains("completionNotifier: this", viewModel);
        Assert.Contains("QueueDidComplete(QueueCompletionNotification notification)", viewModel);
        Assert.Contains("CompletionNoticeText(notification)", viewModel);
    }

    [Fact]
    public void WindowsSettingsExposeCompletionNotificationAndSoundControls()
    {
        var xaml = Read("windows", "MoongateApp", "SettingsWindow.xaml");
        var viewModel = Read("windows", "MoongateApp", "SettingsViewModel.cs");
        var zh = Read("windows", "MoongateApp", "Strings.zh.xaml");
        var en = Read("windows", "MoongateApp", "Strings.en.xaml");
        var zhHant = Read("windows", "MoongateApp", "Strings.zh-Hant.xaml");

        Assert.Contains("L.Settings.Notifications", xaml);
        Assert.Contains("IsChecked=\"{Binding CompletionNotificationsEnabled}\"", xaml);
        Assert.Contains("IsChecked=\"{Binding CompletionSoundEnabled}\"", xaml);
        Assert.Contains("L.Settings.NotificationsHelp", xaml);
        Assert.Contains("_completionNotificationsEnabled = current.CompletionNotificationsEnabled", viewModel);
        Assert.Contains("_completionSoundEnabled = current.CompletionSoundEnabled", viewModel);
        Assert.Contains("public bool CompletionNotificationsEnabled", viewModel);
        Assert.Contains("public bool CompletionSoundEnabled", viewModel);
        Assert.Contains("CompletionNotificationsEnabled = CompletionNotificationsEnabled", viewModel);
        Assert.Contains("CompletionSoundEnabled = CompletionSoundEnabled", viewModel);

        foreach (var resource in new[] { zh, en, zhHant })
        {
            Assert.Contains("x:Key=\"L.Settings.Notifications\"", resource);
            Assert.Contains("x:Key=\"L.Settings.CompletionNotifications\"", resource);
            Assert.Contains("x:Key=\"L.Settings.CompletionSound\"", resource);
            Assert.Contains("x:Key=\"L.Settings.NotificationsHelp\"", resource);
        }
    }

    [Fact]
    public void WindowsStartDownloadScopesPreferHdrToResolvedSelectedFormat()
    {
        var viewModel = Read("windows", "MoongateApp", "MainViewModel.cs");

        Assert.Contains("var selectedFormat = SelectedFormat ?? info.Formats.FirstOrDefault();", viewModel);
        Assert.Contains("var formatId = selectedFormat?.Id;", viewModel);
        Assert.Contains("PreferHdr = _preferHdr && (selectedFormat?.HdrAvailable ?? false)", viewModel);
        Assert.DoesNotContain("PreferHdr = _preferHdr && (SelectedFormat?.HdrAvailable ?? false)", viewModel);
    }

    [Fact]
    public void WindowsReadySelectionIncludesLocalAsrSubtitleSource()
    {
        var viewModel = Read("windows", "MoongateApp", "MainViewModel.cs");
        var mainWindow = Read("windows", "MoongateApp", "MainWindow.xaml");
        var zh = Read("windows", "MoongateApp", "Strings.zh.xaml");
        var en = Read("windows", "MoongateApp", "Strings.en.xaml");
        var zhHant = Read("windows", "MoongateApp", "Strings.zh-Hant.xaml");

        Assert.Contains("AvailableSubtitleChoices(info)", viewModel);
        Assert.Contains("Queue.HasLocalAsrGenerator", viewModel);
        Assert.Contains("var localAsrGenerator = LocalAsrGeneratorFactory.Create(value);", viewModel);
        Assert.Contains("Queue.SyncLocalAsrGenerator(localAsrGenerator)", viewModel);
        Assert.Contains("Queue.SyncCloudAsrGenerator(CloudAsrGeneratorFactory.Create(value, localAsrGenerator))", viewModel);
        Assert.Contains("SubtitleSourceKind.LocalAsr", viewModel);
        Assert.Contains("provider: \"whisper.cpp\"", viewModel);
        Assert.Contains("variant: \"local\"", viewModel);
        Assert.Contains("info.Subtitles.Count == 0", viewModel);
        Assert.Contains("SubtitleChoice.Create(", viewModel);
        Assert.Contains("\"auto\"", viewModel);
        Assert.Contains("Loc.S(\"L.Ready.LocalASRAutoDetect\")", viewModel);
        Assert.Contains("IsLocalAsr", viewModel);
        // 展开区里仍以本地识别徽标标示 local-ASR 来源。
        Assert.Contains("L.Ready.LocalASR", mainWindow);
        Assert.Contains("ShowLocalAsrBadge", mainWindow);

        foreach (var resource in new[] { zh, en, zhHant })
        {
            Assert.Contains("x:Key=\"L.Ready.LocalASR\"", resource);
            Assert.Contains("x:Key=\"L.Ready.LocalASRHint\"", resource);
            Assert.Contains("x:Key=\"L.Ready.LocalASRAutoDetect\"", resource);
        }
    }

    [Fact]
    public void WindowsSettingsExposeLocalAsrVADStatus()
    {
        var xaml = Read("windows", "MoongateApp", "SettingsWindow.xaml");
        var viewModel = Read("windows", "MoongateApp", "SettingsViewModel.cs");
        var zh = Read("windows", "MoongateApp", "Strings.zh.xaml");
        var en = Read("windows", "MoongateApp", "Strings.en.xaml");
        var zhHant = Read("windows", "MoongateApp", "Strings.zh-Hant.xaml");

        Assert.Contains("L.Settings.LocalASRVADStatus", xaml);
        Assert.Contains("LocalAsrVADStatusText", xaml);
        Assert.Contains("LocalAsrVADStatusText", viewModel);
        Assert.Contains("WhisperCppVADModelLocator.Locate", viewModel);
        Assert.Contains("L.Settings.LocalASRVADReady", viewModel);
        Assert.Contains("L.Settings.LocalASRVADMissing", viewModel);
        Assert.Contains("RaisePropertyChanged(nameof(LocalAsrVADStatusText))", viewModel);

        foreach (var resource in new[] { zh, en, zhHant })
        {
            Assert.Contains("x:Key=\"L.Settings.LocalASRVADStatus\"", resource);
            Assert.Contains("x:Key=\"L.Settings.LocalASRVADReady\"", resource);
            Assert.Contains("x:Key=\"L.Settings.LocalASRVADMissing\"", resource);
        }
    }

    [Fact]
    public void WindowsThemeResourcesSupportSystemDarkModeWithoutOneOffSurfaceColors()
    {
        var app = Read("windows", "MoongateApp", "App.xaml");
        var appCode = Read("windows", "MoongateApp", "App.xaml.cs");
        var themeManager = Read("windows", "MoongateApp", "ThemeManager.cs");
        var light = Read("windows", "MoongateApp", "Themes", "Theme.Light.xaml");
        var dark = Read("windows", "MoongateApp", "Themes", "Theme.Dark.xaml");
        var main = Read("windows", "MoongateApp", "MainWindow.xaml");
        var settings = Read("windows", "MoongateApp", "SettingsWindow.xaml");

        Assert.Equal(
            ResourceKeys(light).OrderBy(key => key),
            ResourceKeys(dark).OrderBy(key => key));
        Assert.Contains("Source=\"Themes/Theme.Light.xaml\"", app);
        Assert.DoesNotContain("SolidColorBrush x:Key=\"WindowBrush\"", app);
        Assert.Contains("Value=\"{DynamicResource ControlHoverBrush}\"", app);
        Assert.Contains("Value=\"{DynamicResource QueueBarHoverBrush}\"", app);
        Assert.Contains("ThemeManager.ApplySystemTheme();", appCode);
        Assert.Contains("AppsUseLightTheme", themeManager);
        Assert.Contains("DwmSetWindowAttribute", themeManager);

        var hardcodedColor = new Regex("(Background|Foreground|BorderBrush|Color)=\"#[0-9A-Fa-f]{6}\"");
        Assert.False(hardcodedColor.IsMatch(main), "MainWindow.xaml should use theme resources instead of one-off colors.");
        Assert.False(hardcodedColor.IsMatch(settings), "SettingsWindow.xaml should use theme resources instead of one-off colors.");
        Assert.Contains("{DynamicResource SummarySurfaceBrush}", main);
        Assert.Contains("{DynamicResource SubtleSurfaceBrush}", main);
    }

    [Fact]
    public void WindowsSettingsBuildSettingsPreservesHiddenSettings()
    {
        var viewModel = Read("windows", "MoongateApp", "SettingsViewModel.cs");

        Assert.Contains("private readonly AppSettings _original;", viewModel);
        Assert.Contains("_original = current;", viewModel);
        Assert.Contains("public AppSettings BuildSettings() => _original with", viewModel);
        Assert.DoesNotContain("public AppSettings BuildSettings() => new()", viewModel);
    }

    [Fact]
    public void WindowsSettingsUseNavigationGroupedShell()
    {
        var xaml = Read("windows", "MoongateApp", "SettingsWindow.xaml");
        var zh = Read("windows", "MoongateApp", "Strings.zh.xaml");
        var en = Read("windows", "MoongateApp", "Strings.en.xaml");
        var zhHant = Read("windows", "MoongateApp", "Strings.zh-Hant.xaml");
        string[] navKeys =
        [
            "L.SettingsNav.General",
            "L.SettingsNav.SubtitlesTranslation",
            "L.SettingsNav.LocalSpeech",
            "L.SettingsNav.AI",
            "L.SettingsNav.VideoOutput",
            "L.SettingsNav.SiteLogin",
            "L.SettingsNav.ComponentsStorage",
            "L.SettingsNav.UpdatesAbout",
        ];

        Assert.Contains("<TabControl", xaml);
        Assert.Contains("TabStripPlacement=\"Left\"", xaml);
        Assert.DoesNotContain("<ScrollViewer VerticalScrollBarVisibility=\"Auto\" Padding=\"16,12,16,0\">", xaml);
        Assert.DoesNotContain("Header=\"{DynamicResource L.SettingsNav.Output}\"", xaml);
        Assert.DoesNotContain("Header=\"{DynamicResource L.SettingsNav.Access}\"", xaml);
        Assert.DoesNotContain("Header=\"{DynamicResource L.SettingsNav.Network}\"", xaml);
        Assert.DoesNotContain("Header=\"{DynamicResource L.SettingsNav.Components}\"", xaml);
        Assert.DoesNotContain("Header=\"{DynamicResource L.SettingsNav.Updates}\"", xaml);
        Assert.Contains("<sys:String x:Key=\"L.SettingsNav.LocalSpeech\">Local Speech Recognition</sys:String>", en);
        Assert.Contains("<sys:String x:Key=\"L.SettingsNav.LocalSpeech\">本地语音识别</sys:String>", zh);
        Assert.Contains("<sys:String x:Key=\"L.SettingsNav.LocalSpeech\">本機語音識別</sys:String>", zhHant);
        foreach (var key in navKeys)
        {
            // UpdatesAbout 用复合 Header（带「有可用更新」红色数字 1 角标），其余仍是简单 Header 属性。
            // 两种形式都引用了对应的本地化 key，分组信息架构不变。
            if (key == "L.SettingsNav.UpdatesAbout")
            {
                Assert.Contains($"{{DynamicResource {key}}}", xaml);
            }
            else
            {
                Assert.Contains($"Header=\"{{DynamicResource {key}}}\"", xaml);
            }
            foreach (var resource in new[] { zh, en, zhHant })
            {
                Assert.Contains($"x:Key=\"{key}\"", resource);
                foreach (var retiredKey in new[]
                {
                    "L.SettingsNav.Output",
                    "L.SettingsNav.Access",
                    "L.SettingsNav.Network",
                    "L.SettingsNav.Components",
                    "L.SettingsNav.Updates",
                })
                {
                    Assert.DoesNotContain($"x:Key=\"{retiredKey}\"", resource);
                }
            }
        }
        Assert.True(xaml.IndexOf("L.SettingsNav.General", StringComparison.Ordinal) < xaml.IndexOf("L.SettingsNav.SubtitlesTranslation", StringComparison.Ordinal));
        Assert.True(xaml.IndexOf("L.SettingsNav.SubtitlesTranslation", StringComparison.Ordinal) < xaml.IndexOf("L.SettingsNav.LocalSpeech", StringComparison.Ordinal));
        Assert.True(xaml.IndexOf("L.SettingsNav.LocalSpeech", StringComparison.Ordinal) < xaml.IndexOf("L.SettingsNav.AI", StringComparison.Ordinal));
        Assert.True(xaml.IndexOf("L.SettingsNav.AI", StringComparison.Ordinal) < xaml.IndexOf("L.SettingsNav.VideoOutput", StringComparison.Ordinal));
        Assert.True(xaml.IndexOf("L.SettingsNav.VideoOutput", StringComparison.Ordinal) < xaml.IndexOf("L.SettingsNav.SiteLogin", StringComparison.Ordinal));
        Assert.True(xaml.IndexOf("L.SettingsNav.SiteLogin", StringComparison.Ordinal) < xaml.IndexOf("L.SettingsNav.ComponentsStorage", StringComparison.Ordinal));
        Assert.True(xaml.IndexOf("L.SettingsNav.ComponentsStorage", StringComparison.Ordinal) < xaml.IndexOf("L.SettingsNav.UpdatesAbout", StringComparison.Ordinal));

        var subtitlePageStart = xaml.IndexOf("L.SettingsNav.SubtitlesTranslation", StringComparison.Ordinal);
        var localSpeechPageStart = xaml.IndexOf("L.SettingsNav.LocalSpeech", StringComparison.Ordinal);
        var aiPageStart = xaml.IndexOf("L.SettingsNav.AI", StringComparison.Ordinal);
        var videoPageStart = xaml.IndexOf("L.SettingsNav.VideoOutput", StringComparison.Ordinal);
        var siteLoginPageStart = xaml.IndexOf("L.SettingsNav.SiteLogin", StringComparison.Ordinal);
        Assert.True(xaml.IndexOf("L.Settings.Translation", StringComparison.Ordinal) > subtitlePageStart);
        Assert.True(xaml.IndexOf("L.Settings.Translation", StringComparison.Ordinal) < localSpeechPageStart);
        Assert.True(xaml.IndexOf("L.Settings.SubtitleStyle", StringComparison.Ordinal) > subtitlePageStart);
        Assert.True(xaml.IndexOf("L.Settings.SubtitleStyle", StringComparison.Ordinal) < localSpeechPageStart);
        Assert.True(xaml.IndexOf("L.Settings.AIService", StringComparison.Ordinal) > aiPageStart);
        Assert.True(xaml.IndexOf("L.Settings.AIService", StringComparison.Ordinal) < videoPageStart);
        Assert.True(xaml.IndexOf("L.Settings.VideoNetwork", StringComparison.Ordinal) > videoPageStart);
        Assert.True(xaml.IndexOf("L.Settings.VideoNetwork", StringComparison.Ordinal) < siteLoginPageStart);
    }

    [Fact]
    public void WindowsSettingsComponentsStorageAndUpdatesAboutHaveRealSections()
    {
        var xaml = Read("windows", "MoongateApp", "SettingsWindow.xaml");
        var viewModel = Read("windows", "MoongateApp", "SettingsViewModel.cs");
        var zh = Read("windows", "MoongateApp", "Strings.zh.xaml");
        var en = Read("windows", "MoongateApp", "Strings.en.xaml");
        var zhHant = Read("windows", "MoongateApp", "Strings.zh-Hant.xaml");

        var componentsPageStart = xaml.IndexOf("L.SettingsNav.ComponentsStorage", StringComparison.Ordinal);
        var updatesPageStart = xaml.IndexOf("L.SettingsNav.UpdatesAbout", StringComparison.Ordinal);
        Assert.True(componentsPageStart >= 0);
        Assert.True(updatesPageStart > componentsPageStart);
        Assert.True(xaml.IndexOf("L.Settings.StorageSection", StringComparison.Ordinal) > componentsPageStart);
        Assert.True(xaml.IndexOf("L.Settings.StorageSection", StringComparison.Ordinal) < updatesPageStart);
        // v0.8：存储区从纯文字升级为带占用大小 + 删除/清理的管理界面
        Assert.Contains("StorageTotalSizeText", xaml);
        Assert.Contains("RefreshStorageCommand", xaml);
        Assert.Contains("L.Settings.StorageDelete", xaml);
        Assert.Contains("public string StorageStatusText", viewModel);
        Assert.Contains("CalculateStorageSizesAsync", viewModel);
        Assert.Contains("AppSettings.SupportDirectory", viewModel);
        Assert.Contains("LocalAsrModelStoreDirectory", viewModel);
        Assert.Contains("BinaryLocator.BinDirectory", viewModel);

        Assert.True(xaml.IndexOf("L.Settings.AboutSection", StringComparison.Ordinal) > updatesPageStart);
        Assert.Contains("L.Settings.AboutAppName", xaml);
        Assert.Contains("L.Settings.AboutSource", xaml);
        Assert.Contains("Updater.CurrentVersion", xaml);
        // 关于区不再重复版本号：版本号只在「更新」区出现一次（对齐 macOS，避免两个版本号）。
        Assert.Equal(1, xaml.Split("Updater.CurrentVersion").Length - 1);
        // 关于区提供「查看 GitHub 仓库」按钮（对齐 macOS openRepoPage）。
        Assert.Contains("L.Settings.AboutOpenRepo", xaml);
        Assert.Contains("OnOpenRepoClick", xaml);

        foreach (var resource in new[] { zh, en, zhHant })
        {
            Assert.Contains("x:Key=\"L.Settings.StorageSection\"", resource);
            Assert.Contains("x:Key=\"L.Settings.StorageStatusFmt\"", resource);
            Assert.Contains("x:Key=\"L.Settings.AboutSection\"", resource);
            Assert.Contains("x:Key=\"L.Settings.AboutAppName\"", resource);
            Assert.Contains("x:Key=\"L.Settings.AboutSource\"", resource);
            Assert.Contains("x:Key=\"L.Settings.AboutOpenRepo\"", resource);
        }
    }

    [Fact]
    public void WindowsSettingsExposeLocalSpeechModelCatalogWithExplicitDownloadAction()
    {
        var xaml = Read("windows", "MoongateApp", "SettingsWindow.xaml");
        var viewModel = Read("windows", "MoongateApp", "SettingsViewModel.cs");
        var zh = Read("windows", "MoongateApp", "Strings.zh.xaml");
        var en = Read("windows", "MoongateApp", "Strings.en.xaml");
        var zhHant = Read("windows", "MoongateApp", "Strings.zh-Hant.xaml");

        Assert.Contains("Header=\"{DynamicResource L.SettingsNav.LocalSpeech}\"", xaml);
        Assert.Contains("L.Settings.LocalASRSection", xaml);
        Assert.Contains("IsChecked=\"{Binding LocalAsrEnabled}\"", xaml);
        Assert.Contains("Text=\"{Binding LocalAsrRuntimePath", xaml);
        Assert.Contains("IsChecked=\"{Binding LocalAsrPreciseModeEnabled}\"", xaml);
        Assert.Contains("Text=\"{Binding LocalAsrSidecarRuntimePath", xaml);
        Assert.Contains("Text=\"{Binding LocalAsrSidecarModelPath", xaml);
        Assert.Contains("Text=\"{Binding LocalAsrSidecarReadinessText}\"", xaml);
        Assert.Contains("L.Settings.LocalASRFindRuntime", xaml);
        Assert.Contains("Command=\"{Binding AdoptLocalAsrRuntimeCommand}\"", xaml);
        Assert.Contains("Text=\"{Binding LocalAsrModelPath", xaml);
        Assert.Contains("Text=\"{Binding LocalAsrModelId", xaml);
        Assert.Contains("ItemsSource=\"{Binding LocalAsrModelCatalogEntries}\"", xaml);
        Assert.Contains("L.Settings.LocalASRRecommendedModels", xaml);
        Assert.Contains("L.Settings.LocalASRModelSizeMemory", xaml);
        Assert.Contains("L.Settings.LocalASRModelSourceLicense", xaml);
        Assert.Contains("L.Settings.LocalASRModelSHA256", xaml);
        Assert.Contains("L.Settings.LocalASRModelStatus", xaml);
        Assert.Contains("L.Settings.LocalASRDownloadModel", xaml);
        Assert.Contains("L.Settings.LocalASRInstallingModel", xaml);
        Assert.Contains("Value=\"{Binding DataContext.LocalAsrModelInstallProgress, RelativeSource={RelativeSource AncestorType=Window}, Mode=OneWay}\"", xaml);
        Assert.Contains("L.Settings.LocalASRDeleteModel", xaml);
        Assert.Contains("Command=\"{Binding DataContext.InstallLocalAsrModelCommand", xaml);
        Assert.Contains("Command=\"{Binding DataContext.DeleteLocalAsrModelCommand", xaml);

        Assert.Contains("AsrModelManifest.RecommendedWhisperCpp", viewModel);
        Assert.Contains("AsrModelCatalog", viewModel);
        Assert.Contains("AsrModelInstaller", viewModel);
        Assert.Contains("AsrRuntimeLocator", viewModel);
        Assert.Contains("AdoptLocalAsrRuntimeCommand", viewModel);
        Assert.Contains("AdoptLocalAsrRuntime(", viewModel);
        Assert.Contains("LocalAsrRuntimeSearchPaths", viewModel);
        Assert.Contains("AppContext.BaseDirectory", viewModel);
        Assert.Contains("Path.Combine(AppContext.BaseDirectory, \"asr\", \"runtime\")", viewModel);
        Assert.Contains("Path.Combine(AppContext.BaseDirectory, \"asr\", \"runtime\", \"bin\")", viewModel);
        Assert.Contains("public bool LocalAsrEnabled", viewModel);
        Assert.Contains("public string LocalAsrRuntimePath", viewModel);
        Assert.Contains("public string LocalAsrModelPath", viewModel);
        Assert.Contains("public string LocalAsrModelId", viewModel);
        Assert.Contains("public bool LocalAsrPreciseModeEnabled", viewModel);
        Assert.Contains("public string LocalAsrSidecarRuntimePath", viewModel);
        Assert.Contains("public string LocalAsrSidecarModelPath", viewModel);
        Assert.Contains("public string LocalAsrSidecarReadinessText", viewModel);
        Assert.Contains("public IReadOnlyList<AsrModelCatalogEntry> LocalAsrModelCatalogEntries", viewModel);
        Assert.Contains("public double? LocalAsrModelInstallProgress", viewModel);
        Assert.Contains("InstallLocalAsrModelCommand", viewModel);
        Assert.Contains("InstallLocalAsrModelAsync(", viewModel);
        Assert.Contains("DeleteLocalAsrModelCommand", viewModel);
        Assert.Contains("DeleteLocalAsrModel(", viewModel);
        Assert.Contains("LocalAsrEnabled = LocalAsrEnabled", viewModel);
        Assert.Contains("LocalAsrRuntimePath = LocalAsrRuntimePath", viewModel);
        Assert.Contains("LocalAsrModelPath = LocalAsrModelPath", viewModel);
        Assert.Contains("LocalAsrModelId = LocalAsrModelId", viewModel);
        Assert.Contains("LocalAsrPreciseModeEnabled = LocalAsrPreciseModeEnabled", viewModel);
        Assert.Contains("LocalAsrSidecarRuntimePath = LocalAsrSidecarRuntimePath", viewModel);
        Assert.Contains("LocalAsrSidecarModelPath = LocalAsrSidecarModelPath", viewModel);
        Assert.DoesNotContain("HttpClient", viewModel);

        foreach (var resource in new[] { zh, en, zhHant })
        {
            Assert.Contains("x:Key=\"L.SettingsNav.LocalSpeech\"", resource);
            Assert.Contains("x:Key=\"L.Settings.LocalASRRecommendedModels\"", resource);
            Assert.Contains("x:Key=\"L.Settings.LocalASRFindRuntime\"", resource);
            Assert.Contains("x:Key=\"L.Settings.LocalASRRuntimeFound\"", resource);
            Assert.Contains("x:Key=\"L.Settings.LocalASRRuntimeNotFound\"", resource);
            Assert.Contains("x:Key=\"L.Settings.LocalASRPreciseModeEnabled\"", resource);
            Assert.Contains("x:Key=\"L.Settings.LocalASRSidecarRuntimePath\"", resource);
            Assert.Contains("x:Key=\"L.Settings.LocalASRSidecarModelPath\"", resource);
            Assert.Contains("x:Key=\"L.Settings.LocalASRSidecarReady\"", resource);
            Assert.Contains("x:Key=\"L.Settings.LocalASRSidecarNeedsSetup\"", resource);
            Assert.Contains("x:Key=\"L.Settings.LocalASRDownloadModel\"", resource);
            Assert.Contains("x:Key=\"L.Settings.LocalASRInstallingModel\"", resource);
            Assert.Contains("x:Key=\"L.Settings.LocalASRModelInstallComplete\"", resource);
            Assert.Contains("x:Key=\"L.Settings.LocalASRDeleteModel\"", resource);
            Assert.Contains("x:Key=\"L.Settings.LocalASRModelSHA256\"", resource);
        }
    }

    [Fact]
    public void WindowsSettingsExposePrivacySafeCloudAsrConfiguration()
    {
        var xaml = Read("windows", "MoongateApp", "SettingsWindow.xaml");
        var viewModel = Read("windows", "MoongateApp", "SettingsViewModel.cs");
        var zh = Read("windows", "MoongateApp", "Strings.zh.xaml");
        var zhHant = Read("windows", "MoongateApp", "Strings.zh-Hant.xaml");
        var en = Read("windows", "MoongateApp", "Strings.en.xaml");

        Assert.Contains("L.Settings.CloudASRSection", xaml);
        Assert.Contains("CloudAsrEnabled", xaml);
        Assert.Contains("CloudAsrConsentAccepted", xaml);
        Assert.Contains("CloudAsrBaseUrl", xaml);
        Assert.Contains("CloudAsrModel", xaml);
        Assert.Contains("CloudAsrAuthToken", xaml);
        Assert.Contains("CloudAsrReadinessText", xaml);

        Assert.Contains("public bool CloudAsrEnabled", viewModel);
        Assert.Contains("public bool CloudAsrConsentAccepted", viewModel);
        Assert.Contains("public string CloudAsrBaseUrl", viewModel);
        Assert.Contains("public string CloudAsrModel", viewModel);
        Assert.Contains("public string CloudAsrAuthToken", viewModel);
        Assert.Contains("public string CloudAsrReadinessText", viewModel);
        Assert.Contains("CloudAsrModelRequiresAlignment", viewModel);
        Assert.Contains("L.Settings.CloudASRModelNeedsAlignment", viewModel);
        Assert.Contains("CloudAsrCanUseLocalTimingGuide", viewModel);
        Assert.Contains("L.Settings.CloudASRUsesLocalTimingGuide", viewModel);
        Assert.Contains("CloudAsrAuthToken = CloudAsrAuthToken", viewModel);

        foreach (var resource in new[] { zh, zhHant, en })
        {
            Assert.Contains("x:Key=\"L.Settings.CloudASRSection\"", resource);
            Assert.Contains("x:Key=\"L.Settings.CloudASREnabled\"", resource);
            Assert.Contains("x:Key=\"L.Settings.CloudASRPrivacyNotice\"", resource);
            Assert.Contains("x:Key=\"L.Settings.CloudASRCostNotice\"", resource);
            Assert.Contains("x:Key=\"L.Settings.CloudASRConsentAccepted\"", resource);
            Assert.Contains("x:Key=\"L.Settings.CloudASRReady\"", resource);
            Assert.Contains("x:Key=\"L.Settings.CloudASRNeedsSetup\"", resource);
            Assert.Contains("x:Key=\"L.Settings.CloudASRModelNeedsAlignment\"", resource);
            Assert.Contains("x:Key=\"L.Settings.CloudASRUsesLocalTimingGuide\"", resource);
        }
    }

    [Fact]
    public void WindowsMainBatchErrorsUseLocalizedResources()
    {
        var viewModel = Read("windows", "MoongateApp", "MainViewModel.cs");
        var zh = Read("windows", "MoongateApp", "Strings.zh.xaml");
        var en = Read("windows", "MoongateApp", "Strings.en.xaml");
        var zhHant = Read("windows", "MoongateApp", "Strings.zh-Hant.xaml");

        Assert.Contains("Loc.T(\"L.Error.NoAvailableFormat\")", viewModel);
        Assert.DoesNotContain("AnalyzeFailed(\"没有可用格式\")", viewModel);

        foreach (var resource in new[] { zh, en, zhHant })
        {
            Assert.Contains("x:Key=\"L.Error.NoAvailableFormat\"", resource);
        }
    }

    [Fact]
    public void WindowsSettingsExposeEncodingControls()
    {
        var xaml = Read("windows", "MoongateApp", "SettingsWindow.xaml");
        var zh = Read("windows", "MoongateApp", "Strings.zh.xaml");
        var en = Read("windows", "MoongateApp", "Strings.en.xaml");

        Assert.Contains("L.Settings.EncodeBackend", xaml);
        Assert.Contains("L.Settings.AIService", xaml);
        Assert.Contains("AIProviderIndex", xaml);
        Assert.Contains("AIBaseUrl", xaml);
        Assert.Contains("AIModel", xaml);
        Assert.Contains("AIEndpoint.FetchModelsCommand", xaml);
        Assert.Contains("AIEndpoint.TestConnectionCommand", xaml);
        Assert.Contains("TranslationFollowsDefault", xaml);
        Assert.Contains("ShowTranslationOverride", xaml);
        Assert.Contains("EncodeBackendIndex", xaml);
        Assert.Contains("L.Settings.EncodeAuto", xaml);
        Assert.Contains("L.Settings.EncodeHardware", xaml);
        Assert.Contains("L.Settings.EncodeSoftware", xaml);
        Assert.Contains("BurnAlwaysH264", xaml);
        Assert.Contains("L.Settings.SummaryConfig", xaml);
        Assert.Contains("SummaryFollowsDefault", xaml);
        Assert.Contains("SummaryProviderIndex", xaml);
        Assert.Contains("SummaryBaseUrl", xaml);
        Assert.Contains("SummaryModel", xaml);
        Assert.Contains("SummaryEndpoint.FetchModelsCommand", xaml);
        Assert.Contains("SummaryEndpoint.TestConnectionCommand", xaml);

        foreach (var resource in new[] { zh, en })
        {
            Assert.Contains("x:Key=\"L.Settings.EncodeBackend\"", resource);
            Assert.Contains("x:Key=\"L.Settings.AIService\"", resource);
            Assert.Contains("x:Key=\"L.Settings.TranslationFollowsDefault\"", resource);
            Assert.Contains("x:Key=\"L.Settings.EncodeAuto\"", resource);
            Assert.Contains("x:Key=\"L.Settings.EncodeHardware\"", resource);
            Assert.Contains("x:Key=\"L.Settings.EncodeSoftware\"", resource);
            Assert.Contains("x:Key=\"L.Settings.BurnAlwaysH264\"", resource);
            Assert.Contains("x:Key=\"L.Settings.SummaryConfig\"", resource);
            Assert.Contains("x:Key=\"L.Settings.SummaryFollowsDefault\"", resource);
        }
    }

    [Fact]
    public void WindowsSettingsUpdateSectionAvoidsRunTextBindings()
    {
        var xaml = Read("windows", "MoongateApp", "SettingsWindow.xaml");

        Assert.DoesNotContain("<Run Text=", xaml);
        Assert.Contains("Updater.AvailableVersionText", xaml);
        Assert.Contains("Updater.DownloadPercentText", xaml);
        Assert.Contains("L.Update.FoundPrefix", xaml);
        Assert.Contains("L.Update.Downloading", xaml);
        Assert.Contains("L.Update.OpenReleases", xaml);
    }

    [Fact]
    public void WindowsSettingsExposeVideoProxyControl()
    {
        var xaml = Read("windows", "MoongateApp", "SettingsWindow.xaml");
        var viewModel = Read("windows", "MoongateApp", "SettingsViewModel.cs");
        var settings = Read("windows", "MoongateCore", "Settings.cs");
        var zh = Read("windows", "MoongateApp", "Strings.zh.xaml");
        var en = Read("windows", "MoongateApp", "Strings.en.xaml");
        var zhHant = Read("windows", "MoongateApp", "Strings.zh-Hant.xaml");

        Assert.Contains("L.Settings.VideoNetwork", xaml);
        Assert.Contains("Text=\"{Binding VideoProxyUrl, UpdateSourceTrigger=PropertyChanged}\"", xaml);
        Assert.Contains("IsChecked=\"{Binding IgnoreVideoCertificateErrors}\"", xaml);
        Assert.Contains("_videoProxyUrl = current.VideoProxyUrl", viewModel);
        Assert.Contains("_ignoreVideoCertificateErrors = current.IgnoreVideoCertificateErrors", viewModel);
        Assert.Contains("VideoProxyUrl = AppSettings.NormalizeVideoProxyUrl(VideoProxyUrl)", viewModel);
        Assert.Contains("IgnoreVideoCertificateErrors = IgnoreVideoCertificateErrors", viewModel);
        Assert.Contains("[\"videoProxyURL\"]", settings);
        Assert.Contains("[\"ignoreVideoCertificateErrors\"]", settings);
        foreach (var resource in new[] { zh, en, zhHant })
        {
            Assert.Contains("x:Key=\"L.Settings.VideoProxy\"", resource);
            Assert.Contains("x:Key=\"L.Settings.VideoProxyHint\"", resource);
            Assert.Contains("x:Key=\"L.Settings.IgnoreVideoCertificateErrors\"", resource);
            Assert.Contains("x:Key=\"L.Settings.IgnoreVideoCertificateErrorsHint\"", resource);
        }
    }

    [Fact]
    public void WindowsSettingsUpdateProgressBindingIsReadOnlySafe()
    {
        var xaml = Read("windows", "MoongateApp", "SettingsWindow.xaml");
        var updateService = Read("windows", "MoongateApp", "UpdateService.cs");

        Assert.Contains("Value=\"{Binding Updater.DownloadFraction, ElementName=Root, Mode=OneWay}\"", xaml);
        Assert.DoesNotContain("Value=\"{Binding Updater.DownloadFraction, ElementName=Root}\"", xaml);
        var updaterBindingLines = xaml
            .Split(Environment.NewLine)
            .Where(line => line.Contains("{Binding Updater.", StringComparison.Ordinal));
        Assert.All(updaterBindingLines, line => Assert.Contains("Mode=OneWay", line));
        Assert.Contains("CoerceDownloadFraction(value)", updateService);
        Assert.Contains("double.IsNaN(value)", updateService);
        Assert.Contains("double.IsInfinity(value)", updateService);
    }

    [Fact]
    public void WindowsQueueSurfaceShowsTranscodingPercentAndCompatibilityCopy()
    {
        var viewModel = Read("windows", "MoongateApp", "QueueItemViewModel.cs");
        var queue = Read("windows", "MoongateCore", "Queue.cs");
        var zh = Read("windows", "MoongateApp", "Strings.zh.xaml");
        var en = Read("windows", "MoongateApp", "Strings.en.xaml");

        Assert.Contains("PostDownloadProcessingKind", queue);
        Assert.Contains("PostDownloadProcessingKind.Transcoding", queue);
        Assert.Contains("PostDownloadProcessingKind.Generic", queue);
        Assert.Contains("ItemStageKind.Downloading when item.PostDownloadProcessingKind == PostDownloadProcessingKind.Transcoding", viewModel);
        Assert.Contains("L.Status.TranscodingFmt", viewModel);
        Assert.Contains("L.Status.Transcoding", viewModel);
        Assert.Contains("x:Key=\"L.Status.TranscodingFmt\"", zh);
        Assert.Contains("x:Key=\"L.Status.TranscodingFmt\"", en);
        Assert.Contains("实际耗时可能比预计更长", zh);
        Assert.Contains("may take longer than expected", en);
        Assert.DoesNotContain("CPU fallback", zh, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("CPU fallback", en, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void WindowsQueueSurfaceShowsLocalAsrProgressPhases()
    {
        var viewModel = Read("windows", "MoongateApp", "QueueItemViewModel.cs");
        var zh = Read("windows", "MoongateApp", "Strings.zh.xaml");
        var zhHant = Read("windows", "MoongateApp", "Strings.zh-Hant.xaml");
        var en = Read("windows", "MoongateApp", "Strings.en.xaml");

        Assert.Contains("LocalAsrProgressText(item)", viewModel);
        Assert.Contains("QueueProgressPhase.AudioExtract", viewModel);
        Assert.Contains("QueueProgressPhase.SpeechRecognition", viewModel);
        Assert.Contains("QueueProgressPhase.SubtitleSegment", viewModel);
        Assert.Contains("L.Status.AudioExtractingFmt", viewModel);
        Assert.Contains("L.Status.SpeechRecognizingFmt", viewModel);
        Assert.Contains("L.Status.SubtitleSegmentingFmt", viewModel);
        foreach (var resource in new[] { zh, zhHant, en })
        {
            Assert.Contains("x:Key=\"L.Status.AudioExtractingFmt\"", resource);
            Assert.Contains("x:Key=\"L.Status.AudioExtracting\"", resource);
            Assert.Contains("x:Key=\"L.Status.SpeechRecognizingFmt\"", resource);
            Assert.Contains("x:Key=\"L.Status.SpeechRecognizing\"", resource);
            Assert.Contains("x:Key=\"L.Status.SubtitleSegmentingFmt\"", resource);
            Assert.Contains("x:Key=\"L.Status.SubtitleSegmenting\"", resource);
        }
    }

    [Fact]
    public void WindowsQueueSurfaceCanRetryCompletedTaskWithLocalAsr()
    {
        var xaml = Read("windows", "MoongateApp", "MainWindow.xaml");
        var viewModel = Read("windows", "MoongateApp", "QueueItemViewModel.cs");
        var zh = Read("windows", "MoongateApp", "Strings.zh.xaml");
        var zhHant = Read("windows", "MoongateApp", "Strings.zh-Hant.xaml");
        var en = Read("windows", "MoongateApp", "Strings.en.xaml");

        Assert.Contains("RetryWithLocalAsrCommand", viewModel);
        Assert.Contains("_queue.RetryWithLocalAsr(Id)", viewModel);
        Assert.Contains("ShowRetryWithLocalAsr", viewModel);
        Assert.Contains("_queue.CanRetryWithLocalAsr(item.Id)", viewModel);
        Assert.Contains("L.Row.RetryWithLocalASR", xaml);
        Assert.Contains("Visibility=\"{Binding ShowRetryWithLocalAsr", xaml);
        foreach (var resource in new[] { zh, zhHant, en })
        {
            Assert.Contains("x:Key=\"L.Row.RetryWithLocalASR\"", resource);
        }
    }

    [Fact]
    public void WindowsReadyPageSeparatesPrimarySubtitleSourceFromOutputMode()
    {
        var xaml = Read("windows", "MoongateApp", "MainWindow.xaml");
        var viewModel = Read("windows", "MoongateApp", "MainViewModel.cs");
        var zh = Read("windows", "MoongateApp", "Strings.zh.xaml");
        var zhHant = Read("windows", "MoongateApp", "Strings.zh-Hant.xaml");
        var en = Read("windows", "MoongateApp", "Strings.en.xaml");

        // 输出优先：字幕输出区与来源区分离的两个 section。
        Assert.Contains("L.Ready.SubtitleOutputSection", xaml);
        Assert.Contains("L.Ready.SubtitleSourceSection", xaml);
        // 主区域先呈现自动最佳来源，推荐语言只作为次级原声语言信息；展开区再显示其他语言。
        Assert.Contains("L.Ready.RecommendedBadge", xaml);
        Assert.Contains("Text=\"{DynamicResource L.Ready.SubtitleSourcePolicyAutoBest}\"", xaml);
        Assert.Contains("Text=\"{Binding DisplayLabel}\"", xaml);
        Assert.Contains("L.Ready.AutoSourceExplanation", xaml);
        Assert.Contains("L.Ready.MoreLanguages", xaml);
        Assert.Contains("SourceLanguageOptions", xaml);
        Assert.Contains("SelectedSourceLanguageOption", xaml);
        Assert.Contains("RecommendedLanguageOption", xaml);
        Assert.Contains("OtherLanguageOptions", xaml);
        Assert.Contains("LanguageSectionExpanded", xaml);
        // ViewModel 语言优先 API + 仍保留主源 trackId 兼容路径。
        Assert.Contains("public string? PrimarySubtitleTrackId", viewModel);
        Assert.Contains("SubtitleIntentFromChineseMode", viewModel);
        Assert.Contains("SourceLanguageIntentFromCode", viewModel);
        Assert.Contains("SubtitleIntent = SubtitleIntentFromChineseMode", viewModel);
        Assert.Contains("SourceLanguageIntent = SourceLanguageIntentFromCode", viewModel);
        Assert.Contains("SubtitleLanguageRecommender.Recommend(", viewModel);
        Assert.Contains("preferredSourceLanguage: EffectiveSourceLanguagePreference(info)", viewModel);
        Assert.Contains("AppendLocalAsrChoice", viewModel);
        Assert.Contains("public void SelectLanguage(SubtitleLanguageChoice language)", viewModel);
        Assert.Contains("PrimarySubtitleTrackId = primary?.Id", viewModel);
        Assert.Contains("AvailableSubtitleChoices(info)", viewModel);
        Assert.Contains("recommended.PreferredTrack", viewModel);
        Assert.DoesNotContain("info.Subtitles.FirstOrDefault(s => !s.IsAuto) ?? info.Subtitles.FirstOrDefault()", viewModel);
        foreach (var resource in new[] { zh, zhHant, en })
        {
            Assert.Contains("x:Key=\"L.Ready.SubtitleLanguageSection\"", resource);
            Assert.Contains("x:Key=\"L.Ready.SubtitleSourceSection\"", resource);
            Assert.Contains("x:Key=\"L.Ready.SubtitleOutputSection\"", resource);
            Assert.Contains("x:Key=\"L.Ready.NoSubtitleSource\"", resource);
            Assert.Contains("x:Key=\"L.Ready.RecommendedBadge\"", resource);
            Assert.Contains("x:Key=\"L.Ready.MoreLanguages\"", resource);
            Assert.Contains("x:Key=\"L.Ready.SourceLanguageAuto\"", resource);
            Assert.Contains("x:Key=\"L.Ready.SourceLanguagePickerAccessibility\"", resource);
        }
        Assert.Contains("识别原声语言", zh);
        Assert.Contains("只需确认视频说什么语言；Moongate 会自动选择最可靠的字幕来源。", zh);
        Assert.DoesNotContain("自动字幕不会优先于更可靠的源语言", zh);
        Assert.Contains("辨識原聲語言", zhHant);
        Assert.Contains("只需確認影片說什麼語言；Moongate 會自動選擇最可靠的字幕來源。", zhHant);
        Assert.DoesNotContain("自動字幕不會優先於更可靠的源語言", zhHant);
        Assert.Contains("Original audio language", en);
        Assert.Contains("Confirm what language the video uses; Moongate will choose the most reliable subtitle source.", en);
        Assert.DoesNotContain("auto captions do not outrank", en);
    }

    [Fact]
    public void WindowsReadyPagePutsSubtitleOutputBeforeSourceAndHidesSourceWhenOff()
    {
        var xaml = Read("windows", "MoongateApp", "MainWindow.xaml");
        var viewModel = Read("windows", "MoongateApp", "MainViewModel.cs");

        var outputIndex = xaml.IndexOf("L.Ready.SubtitleOutputSection", StringComparison.Ordinal);
        var sourceIndex = xaml.IndexOf("L.Ready.SubtitleSourceSection", StringComparison.Ordinal);
        Assert.True(outputIndex >= 0, "Ready page should render a subtitle output section.");
        Assert.True(sourceIndex >= 0, "Ready page should render a subtitle source section.");
        Assert.True(outputIndex < sourceIndex, "Subtitle output should come before subtitle source.");

        Assert.Contains("Visibility=\"{Binding SubtitleSourceControlsVisible", xaml);
        Assert.DoesNotContain("IsEnabled=\"{Binding ChineseModeEnabled}\"", xaml);
        Assert.DoesNotContain("IsChecked=\"{Binding PrimarySubtitleNone}\"", xaml);

        Assert.Contains("public bool SubtitleSourceControlsVisible => _chineseMode != ChineseSubtitleMode.Off;", viewModel);
        Assert.Contains("private void EnsureSubtitleSourceSelected()", viewModel);
        Assert.Contains("if (value != ChineseSubtitleMode.Off) EnsureSubtitleSourceSelected();", viewModel);
        Assert.Contains("RaisePropertyChanged(nameof(SubtitleSourceControlsVisible));", viewModel);
    }

    [Fact]
    public void WindowsReadyPageExposesAdvancedSubtitleSourcePolicy()
    {
        var xaml = Read("windows", "MoongateApp", "MainWindow.xaml");
        var viewModel = Read("windows", "MoongateApp", "MainViewModel.cs");
        var zh = Read("windows", "MoongateApp", "Strings.zh.xaml");
        var zhHant = Read("windows", "MoongateApp", "Strings.zh-Hant.xaml");
        var en = Read("windows", "MoongateApp", "Strings.en.xaml");

        Assert.Contains("L.Ready.SubtitleSourceAdvanced", xaml);
        Assert.Contains("SubtitleSourcePolicyOptions", xaml);
        Assert.Contains("SelectedSubtitleSourcePolicyOption", xaml);

        Assert.Contains("public IReadOnlyList<SubtitleSourcePolicyOptionViewModel> SubtitleSourcePolicyOptions", viewModel);
        Assert.Contains("public SubtitleSourcePolicyOptionViewModel? SelectedSubtitleSourcePolicyOption", viewModel);
        Assert.Contains("TrackMatchingPolicy(", viewModel);
        Assert.Contains("var subtitleSourcePolicy = SelectedSubtitleSourcePolicyOption?.Policy ?? SubtitleSourcePolicy.AutoBest", viewModel);
        Assert.Contains("SubtitleSourcePolicy = subtitleSourcePolicy", viewModel);
        Assert.Contains("SubtitleSourcePolicy.CompareLocalAsr", viewModel);
        Assert.Contains("SubtitleSourcePolicy.CloudAsr", viewModel);
        Assert.Contains("CloudAsrGeneratorFactory.Create(_settings, localAsrGenerator)", viewModel);
        Assert.Contains("Queue.SyncCloudAsrGenerator(CloudAsrGeneratorFactory.Create(value, localAsrGenerator))", viewModel);
        Assert.Contains("OpenCloudAsrSettings()", viewModel);
        Assert.Contains("L.Ready.CloudASRSetupRequired", viewModel);

        foreach (var resource in new[] { zh, zhHant, en })
        {
            Assert.Contains("x:Key=\"L.Ready.SubtitleSourceAdvanced\"", resource);
            Assert.Contains("x:Key=\"L.Ready.SubtitleSourcePolicyAutoBest\"", resource);
            Assert.Contains("x:Key=\"L.Ready.SubtitleSourcePolicyCompareLocalASR\"", resource);
            Assert.Contains("x:Key=\"L.Ready.SubtitleSourcePolicyForceLocalASR\"", resource);
            Assert.Contains("x:Key=\"L.Ready.SubtitleSourcePolicyCloudASR\"", resource);
            Assert.Contains("x:Key=\"L.Ready.CloudASRSetupRequired\"", resource);
        }
    }

    [Fact]
    public void WindowsReadyPageExposesImportedSubtitleFileFlow()
    {
        var xaml = Read("windows", "MoongateApp", "MainWindow.xaml");
        var viewModel = Read("windows", "MoongateApp", "MainViewModel.cs");
        var codeBehind = Read("windows", "MoongateApp", "MainWindow.xaml.cs");
        var zh = Read("windows", "MoongateApp", "Strings.zh.xaml");
        var zhHant = Read("windows", "MoongateApp", "Strings.zh-Hant.xaml");
        var en = Read("windows", "MoongateApp", "Strings.en.xaml");

        Assert.Contains("Click=\"OnImportSubtitleFileClick\"", xaml);
        Assert.Contains("ImportedSubtitleSummary", xaml);
        Assert.Contains("ClearImportedSubtitleFileCommand", xaml);

        Assert.Contains("public string? ImportedSubtitleFilePath", viewModel);
        Assert.Contains("public string? ImportedSubtitleSummary", viewModel);
        Assert.Contains("public RelayCommand ClearImportedSubtitleFileCommand", viewModel);
        Assert.Contains("public void ImportSubtitleFile(string path)", viewModel);
        Assert.Contains("private SubtitleChoice? ImportedSubtitleChoice(", viewModel);
        Assert.Contains("SubtitleSourcePolicy.ImportedFile", viewModel);
        Assert.Contains("\"path\"", viewModel);

        Assert.Contains("private void OnImportSubtitleFileClick", codeBehind);
        Assert.Contains("OpenFileDialog", codeBehind);
        Assert.Contains("*.srt;*.vtt", codeBehind);

        foreach (var resource in new[] { zh, zhHant, en })
        {
            Assert.Contains("x:Key=\"L.Ready.ImportSubtitleFile\"", resource);
            Assert.Contains("x:Key=\"L.Ready.ImportedSubtitleSelectedFmt\"", resource);
            Assert.Contains("x:Key=\"L.Ready.ClearImportedSubtitle\"", resource);
            Assert.Contains("x:Key=\"L.Ready.ImportedSubtitleUnsupported\"", resource);
        }
    }

    [Fact]
    public void WindowsQueueRowsExposeResolvedSubtitleSourceDetails()
    {
        var xaml = Read("windows", "MoongateApp", "MainWindow.xaml");
        var rowViewModel = Read("windows", "MoongateApp", "QueueItemViewModel.cs");
        var zh = Read("windows", "MoongateApp", "Strings.zh.xaml");
        var zhHant = Read("windows", "MoongateApp", "Strings.zh-Hant.xaml");
        var en = Read("windows", "MoongateApp", "Strings.en.xaml");

        Assert.Contains("SubtitleSourceDetailText", xaml);
        Assert.Contains("public string? SubtitleSourceDetailText", rowViewModel);
        Assert.Contains("item.ResolvedSubtitleSource", rowViewModel);
        Assert.Contains("CandidateReports", rowViewModel);
        Assert.Contains("SubtitleSourceCandidateReportText", rowViewModel);

        foreach (var resource in new[] { zh, zhHant, en })
        {
            Assert.Contains("x:Key=\"L.Queue.SubtitleSourceActualFmt\"", resource);
            Assert.Contains("x:Key=\"L.Queue.SubtitleSourceQualityFmt\"", resource);
            Assert.Contains("x:Key=\"L.Queue.SubtitleSourceQualityExcellent\"", resource);
            Assert.Contains("x:Key=\"L.Queue.SubtitleSourceQualityGood\"", resource);
            Assert.Contains("x:Key=\"L.Queue.SubtitleSourceQualityUnusable\"", resource);
            Assert.Contains("x:Key=\"L.Queue.SubtitleSourceCandidatesFmt\"", resource);
            Assert.Contains("x:Key=\"L.Queue.SubtitleSourceCandidateFmt\"", resource);
        }
    }

    [Fact]
    public void WindowsSettingsViewModelPersistsEncodingControls()
    {
        var source = Read("windows", "MoongateApp", "SettingsViewModel.cs");

        Assert.Contains("private EncodeBackend _encodeBackend;", source);
        Assert.Contains("private TranslationProvider _aiProvider;", source);
        Assert.Contains("public int AIProviderIndex", source);
        Assert.Contains("public bool TranslationFollowsDefault", source);
        Assert.Contains("_encodeBackend = current.EncodeBackend;", source);
        Assert.Contains("_aiProvider = current.AIProvider;", source);
        Assert.Contains("_translationFollowsDefault = current.TranslationFollowsDefault;", source);
        Assert.Contains("_burnAlwaysH264 = current.BurnAlwaysH264;", source);
        Assert.Contains("public int EncodeBackendIndex", source);
        Assert.Contains("public bool BurnAlwaysH264", source);
        Assert.Contains("EncodeBackend = _encodeBackend", source);
        Assert.Contains("BurnAlwaysH264 = BurnAlwaysH264", source);
        Assert.Contains("AIProvider = _aiProvider", source);
        Assert.Contains("AIBaseUrl = AIBaseUrl", source);
        Assert.Contains("AIModel = AIModel", source);
        Assert.Contains("AIAuthToken = AIAuthToken", source);
        Assert.Contains("public APIEndpointActions AIEndpoint", source);
        Assert.Contains("() => RequestSettings(_aiProvider, AIBaseUrl, AIModel, AIAuthToken)", source);
        Assert.Contains("TranslationFollowsDefault = TranslationFollowsDefault", source);
        Assert.Contains("public bool SummaryFollowsDefault", source);
        Assert.Contains("public int SummaryProviderIndex", source);
        Assert.Contains("SummaryProvider = _summaryProvider", source);
        Assert.Contains("SummaryBaseUrl = SummaryBaseUrl", source);
        Assert.Contains("SummaryModel = SummaryModel", source);
        Assert.Contains("SummaryAuthToken = SummaryAuthToken", source);
        Assert.Contains("public APIEndpointActions SummaryEndpoint", source);
        Assert.Contains("() => RequestSettings(_summaryProvider, SummaryBaseUrl, SummaryModel, SummaryAuthToken)", source);
        Assert.Contains("TranslationFollowsDefault = false", source);
    }

    [Fact]
    public void WindowsLocalSpeechTabImportsModelAndHidesAdvancedPathsByDefault()
    {
        var xaml = Read("windows", "MoongateApp", "SettingsWindow.xaml");
        var viewModel = Read("windows", "MoongateApp", "SettingsViewModel.cs");
        var codeBehind = Read("windows", "MoongateApp", "SettingsWindow.xaml.cs");
        var en = Read("windows", "MoongateApp", "Strings.en.xaml");
        var zh = Read("windows", "MoongateApp", "Strings.zh.xaml");
        var zhHant = Read("windows", "MoongateApp", "Strings.zh-Hant.xaml");

        // 导入本地模型：可见按钮 + 文件对话框处理器 + 拷贝到托管 imported 目录、启用并设自定义 ID。
        Assert.Contains("L.Settings.LocalASRImportModel", xaml);
        Assert.Contains("Click=\"OnImportLocalAsrModelClick\"", xaml);
        Assert.Contains("private void OnImportLocalAsrModelClick", codeBehind);
        Assert.Contains("OpenFileDialog", codeBehind);
        Assert.Contains("public void ImportLocalAsrModel(string sourcePath)", viewModel);
        Assert.Contains("\"imported\"", viewModel);
        Assert.Contains("\"custom:\"", viewModel);
        Assert.Contains("LocalAsrEnabled = true;", viewModel);

        // cpp runtime/模型路径默认收起（高级折叠，对齐 macOS），用 BoolToVis 切换、不引入未做深色模板的 Expander。
        Assert.Contains("public bool ShowAdvancedLocalAsr", viewModel);
        Assert.Contains("IsChecked=\"{Binding ShowAdvancedLocalAsr}\"", xaml);
        Assert.Contains("Visibility=\"{Binding ShowAdvancedLocalAsr, Converter={StaticResource BoolToVis}}\"", xaml);
        Assert.DoesNotContain("<Expander", xaml);

        foreach (var resource in new[] { en, zh, zhHant })
        {
            Assert.Contains("x:Key=\"L.Settings.AdvancedDetails\"", resource);
            Assert.Contains("x:Key=\"L.Settings.LocalASRImportModel\"", resource);
            Assert.Contains("x:Key=\"L.Settings.LocalASRModelImportComplete\"", resource);
            Assert.Contains("x:Key=\"L.Settings.LocalASRImportFailed\"", resource);
        }
    }
}
