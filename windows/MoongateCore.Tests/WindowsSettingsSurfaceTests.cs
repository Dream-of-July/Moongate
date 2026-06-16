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
}
