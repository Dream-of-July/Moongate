using System.Text;
using System.Text.Json;
using Moongate.Core;

namespace MoongateCore.Tests;

public class AsrContractsTests
{
    [Fact]
    public void TranscriptModelManifestAndCacheRoundTripThroughJson()
    {
        var createdAt = DateTimeOffset.FromUnixTimeSeconds(1_785_000_000);
        var transcript = new AsrTranscript
        {
            Id = "clip-ja-small",
            LanguageCode = "ja",
            LanguageConfidence = 0.91,
            DurationSeconds = 2.4,
            Words =
            [
                new AsrWord { Text = "梅雨", StartSeconds = 0, EndSeconds = 0.6, Probability = 0.82 },
                new AsrWord { Text = "が", StartSeconds = 0.6, EndSeconds = 0.8, Probability = 0.93 },
                new AsrWord { Text = "明ける", StartSeconds = 0.8, EndSeconds = 1.5, Probability = 0.76 },
            ],
            SourceModelId = "whisper.cpp:small-q5_1",
            CreatedAt = createdAt,
        };
        var model = new AsrModelInfo
        {
            Id = "whisper.cpp:small-q5_1",
            DisplayName = "Whisper small q5_1",
            FileName = "ggml-small-q5_1.bin",
            DownloadUrl = "https://example.com/ggml-small-q5_1.bin",
            SizeBytes = 181_000_000,
            Sha256 = new string('a', 64),
            MemoryRequiredMb = 1024,
            License = "MIT",
            SourceDescription = "whisper.cpp model mirror",
        };
        var cache = new AsrTranscriptCacheEntry
        {
            CacheKey = "clip-ja-small",
            AudioFingerprint = "sha256:" + new string('b', 64),
            ModelId = model.Id,
            LanguageCode = "ja",
            TranscriptPath = @"C:\Temp\transcript.json",
            CreatedAt = createdAt,
        };
        var options = AsrJson.Options;

        var transcriptJson = JsonSerializer.Serialize(transcript, options);
        Assert.Contains("\"sourceModelId\"", transcriptJson, StringComparison.Ordinal);
        Assert.DoesNotContain("SourceModelId", transcriptJson, StringComparison.Ordinal);
        AssertTranscriptEqual(transcript, JsonSerializer.Deserialize<AsrTranscript>(transcriptJson, options));
        var manifest = new AsrModelManifest { Models = [model] };
        var decodedManifest = JsonSerializer.Deserialize<AsrModelManifest>(
            JsonSerializer.Serialize(manifest, options), options);
        Assert.NotNull(decodedManifest);
        Assert.Equal([model], decodedManifest.Models);
        Assert.Equal(cache, JsonSerializer.Deserialize<AsrTranscriptCacheEntry>(
            JsonSerializer.Serialize(cache, options), options));

        var progressJson = JsonSerializer.Serialize(new AsrProgress
        {
            Phase = AsrProgressPhase.SpeechRecognition,
            CompletedUnits = 1,
            TotalUnits = 2,
        }, options);
        Assert.Contains("\"phase\":\"speechRecognition\"", progressJson, StringComparison.Ordinal);
    }

    [Fact]
    public void RecommendedWhisperCppManifestUsesVerifiedHuggingFaceMetadata()
    {
        var manifest = AsrModelManifest.RecommendedWhisperCpp;

        Assert.Equal(
            [
                "whisper.cpp:tiny-q5_1",
                "whisper.cpp:tiny-q8_0",
                "whisper.cpp:base-q5_1",
                "whisper.cpp:base-q8_0",
                "whisper.cpp:small-q5_1",
                "whisper.cpp:small-q8_0",
                "whisper.cpp:small.en-q5_1",
                "whisper.cpp:medium-q5_0",
                "whisper.cpp:large-v3-turbo-q5_0",
            ],
            manifest.Models.Select(model => model.Id));
        Assert.All(manifest.Models, model => Assert.Equal("MIT", model.License));
        Assert.All(manifest.Models, model => Assert.Contains("ggerganov/whisper.cpp", model.SourceDescription));

        var tiny = Assert.Single(manifest.Models, model => model.Id == "whisper.cpp:tiny-q5_1");
        Assert.Equal("ggml-tiny-q5_1.bin", tiny.FileName);
        Assert.Equal(32_152_673, tiny.SizeBytes);
        Assert.Equal("818710568da3ca15689e31a743197b520007872ff9576237bda97bd1b469c3d7", tiny.Sha256);
        Assert.Equal("https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny-q5_1.bin", tiny.DownloadUrl);
        Assert.True(tiny.MemoryRequiredMb >= 256);

        var @base = Assert.Single(manifest.Models, model => model.Id == "whisper.cpp:base-q5_1");
        Assert.Equal("ggml-base-q5_1.bin", @base.FileName);
        Assert.Equal(59_707_625, @base.SizeBytes);
        Assert.Equal("422f1ae452ade6f30a004d7e5c6a43195e4433bc370bf23fac9cc591f01a8898", @base.Sha256);
        Assert.Equal("https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base-q5_1.bin", @base.DownloadUrl);
        Assert.True(@base.MemoryRequiredMb >= 512);

        var small = Assert.Single(manifest.Models, model => model.Id == "whisper.cpp:small-q5_1");
        Assert.Equal("ggml-small-q5_1.bin", small.FileName);
        Assert.Equal(190_085_487, small.SizeBytes);
        Assert.Equal("ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb", small.Sha256);
        Assert.Equal("https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small-q5_1.bin", small.DownloadUrl);
        Assert.True(small.MemoryRequiredMb >= 1_024);

        var turbo = Assert.Single(manifest.Models, model => model.Id == "whisper.cpp:large-v3-turbo-q5_0");
        Assert.Equal("ggml-large-v3-turbo-q5_0.bin", turbo.FileName);
        Assert.Equal(574_041_195, turbo.SizeBytes);
        Assert.Equal("394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2", turbo.Sha256);
        Assert.Equal("https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin", turbo.DownloadUrl);
        Assert.True(turbo.MemoryRequiredMb >= 3_072);
    }

    [Fact]
    public void RuntimeBundleManifestRejectsDownloadUrlsAndPathEscapes()
    {
        var runtime = new AsrRuntimeBundleInfo
        {
            Provider = "whisper.cpp",
            Platform = "windows",
            Architecture = "x64",
            Version = "1.7.5",
            ExecutableRelativePath = "bin/whisper-cli.exe",
            Sha256 = new string('c', 64),
            License = "MIT",
            SourceDescription = "local staged whisper.cpp runtime",
        };
        var manifest = new AsrRuntimeBundleManifest { Runtimes = [runtime] };
        manifest.Validate();
        var json = JsonSerializer.Serialize(manifest, AsrJson.Options);

        Assert.Contains("\"executableRelativePath\"", json, StringComparison.Ordinal);
        Assert.DoesNotContain("downloadUrl", json, StringComparison.Ordinal);
        var decoded = AsrRuntimeBundleManifest.FromJson(json);
        Assert.Equal(runtime, Assert.Single(decoded.Runtimes));
        Assert.EndsWith(
            Path.Combine("asr", "runtime", "bin", "whisper-cli.exe"),
            runtime.ExecutablePathUnder(Path.Combine("C:\\Program Files", "Moongate", "asr", "runtime")),
            StringComparison.OrdinalIgnoreCase);

        var traversal = new AsrRuntimeBundleManifest
        {
            Runtimes = [runtime with { ExecutableRelativePath = "../whisper-cli.exe" }],
        };
        var traversalError = Assert.Throws<AsrRuntimeBundleManifestException>(() => traversal.Validate());
        Assert.Equal(AsrRuntimeBundleManifestError.InvalidExecutableRelativePath, traversalError.Reason);

        var absolute = new AsrRuntimeBundleManifest
        {
            Runtimes = [runtime with { ExecutableRelativePath = "C:/Temp/whisper-cli.exe" }],
        };
        var absoluteError = Assert.Throws<AsrRuntimeBundleManifestException>(() => absolute.Validate());
        Assert.Equal(AsrRuntimeBundleManifestError.InvalidExecutableRelativePath, absoluteError.Reason);

        var badHash = new AsrRuntimeBundleManifest
        {
            Runtimes = [runtime with { Sha256 = "not-a-sha" }],
        };
        var hashError = Assert.Throws<AsrRuntimeBundleManifestException>(() => badHash.Validate());
        Assert.Equal(AsrRuntimeBundleManifestError.InvalidSha256, hashError.Reason);

        var downloadUrlJson = """
        {
          "runtimes": [
            {
              "provider": "whisper.cpp",
              "platform": "windows",
              "architecture": "x64",
              "version": "1.7.5",
              "executableRelativePath": "bin/whisper-cli.exe",
              "sha256": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
              "license": "MIT",
              "sourceDescription": "local staged whisper.cpp runtime",
              "downloadUrl": "https://example.com/whisper-cli.exe"
            }
          ]
        }
        """;
        var downloadUrlError = Assert.Throws<AsrRuntimeBundleManifestException>(
            () => AsrRuntimeBundleManifest.FromJson(downloadUrlJson));
        Assert.Equal(AsrRuntimeBundleManifestError.DownloadUrlNotAllowed, downloadUrlError.Reason);
    }

    [Fact]
    public void RuntimeBundleManifestVerifiesExecutableHashBeforeAdoption()
    {
        var directory = Path.Combine(Path.GetTempPath(), "moongate-asr-runtime-bundle-" + Guid.NewGuid().ToString("N"));
        var bin = Path.Combine(directory, "bin");
        Directory.CreateDirectory(bin);
        var executable = Path.Combine(bin, OperatingSystem.IsWindows() ? "whisper-cli.exe" : "whisper-cli");
        File.WriteAllText(executable, "fake whisper runtime");
        if (!OperatingSystem.IsWindows())
        {
            File.SetUnixFileMode(executable, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        }
        var sha = AsrModelStore.Sha256Hex(executable);
        var runtime = new AsrRuntimeBundleInfo
        {
            Provider = "whisper.cpp",
            Platform = OperatingSystem.IsWindows() ? "windows" : "macos",
            Architecture = "x64",
            Version = "1.7.5",
            ExecutableRelativePath = OperatingSystem.IsWindows() ? "bin/whisper-cli.exe" : "bin/whisper-cli",
            Sha256 = sha,
            License = "MIT",
            SourceDescription = "local staged whisper.cpp runtime",
        };

        var runtimeInfo = runtime.VerifiedRuntimeInfoUnder(directory);
        Assert.Equal("whisper.cpp", runtimeInfo.Provider);
        Assert.Equal(Path.GetFullPath(executable), runtimeInfo.ExecutablePath);

        var badRuntime = runtime with { Sha256 = new string('d', 64) };
        var hashError = Assert.Throws<AsrRuntimeBundleManifestException>(
            () => badRuntime.VerifiedRuntimeInfoUnder(directory));
        Assert.Equal(AsrRuntimeBundleManifestError.Sha256Mismatch, hashError.Reason);
        Assert.Contains(sha, hashError.Detail, StringComparison.Ordinal);

        var missingRuntime = runtime with { ExecutableRelativePath = "bin/missing-whisper-cli" };
        var missingError = Assert.Throws<AsrRuntimeBundleManifestException>(
            () => missingRuntime.VerifiedRuntimeInfoUnder(directory));
        Assert.Equal(AsrRuntimeBundleManifestError.MissingExecutable, missingError.Reason);
        Assert.Equal("bin/missing-whisper-cli", missingError.Detail);
    }

    [Fact]
    public void RuntimeLocatorUsesVerifiedBundleManifestBeforeBareExecutableFallback()
    {
        var directory = Path.Combine(Path.GetTempPath(), "moongate-asr-runtime-locator-" + Guid.NewGuid().ToString("N"));
        try
        {
            var bin = Path.Combine(directory, "bin");
            Directory.CreateDirectory(bin);
            var executableName = OperatingSystem.IsWindows() ? "whisper-cli.exe" : "whisper-cli";
            var executable = Path.Combine(bin, executableName);
            File.WriteAllText(executable, "fake manifest-selected whisper runtime");
            if (!OperatingSystem.IsWindows())
            {
                File.SetUnixFileMode(executable, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
            }
            var runtime = new AsrRuntimeBundleInfo
            {
                Provider = "whisper.cpp",
                Platform = AsrRuntimeLocator.CurrentPlatform,
                Architecture = AsrRuntimeLocator.CurrentArchitecture,
                Version = "1.7.5",
                ExecutableRelativePath = "bin/" + executableName,
                Sha256 = AsrModelStore.Sha256Hex(executable),
                License = "MIT",
                SourceDescription = "local staged whisper.cpp runtime",
            };
            var manifest = new AsrRuntimeBundleManifest { Runtimes = [runtime] };
            File.WriteAllText(
                Path.Combine(directory, AsrRuntimeLocator.RuntimeManifestFileName),
                JsonSerializer.Serialize(manifest, AsrJson.Options));

            var located = new AsrRuntimeLocator(extraSearchPaths: [directory, bin], environmentPath: "").Locate();
            Assert.Equal("whisper.cpp", located?.Provider);
            Assert.Equal(Path.GetFullPath(executable), located?.ExecutablePath);

            File.WriteAllText(executable, "tampered runtime");
            Assert.Null(new AsrRuntimeLocator(extraSearchPaths: [directory, bin], environmentPath: "").Locate());
        }
        finally
        {
            if (Directory.Exists(directory))
            {
                Directory.Delete(directory, recursive: true);
            }
        }
    }

    [Fact]
    public async Task FakeRecognizerReportsReadinessProgressAndSuccess()
    {
        var transcript = new AsrTranscript
        {
            Id = "ok",
            LanguageCode = "ja",
            Words = [new AsrWord { Text = "新聞紙", StartSeconds = 0, EndSeconds = 0.8 }],
            SourceModelId = "whisper.cpp:base",
        };
        var recognizer = new FakeSpeechRecognizer(
            new AsrReadiness { Status = AsrReadinessStatus.Ready, ModelId = "whisper.cpp:base", Message = "Ready" },
            transcript);
        var request = new AsrRequest
        {
            AudioPath = "/tmp/audio.wav",
            LanguageCode = "ja",
            ModelId = "whisper.cpp:base",
            Prompt = "title channel glossary",
            CacheKey = "ok",
        };
        var progress = new List<AsrProgress>();

        var readiness = await recognizer.ReadinessAsync(request);
        var result = await recognizer.TranscribeAsync(request, progress.Add);

        Assert.True(readiness.IsReady);
        Assert.Equal(transcript, result);
        Assert.Equal([AsrProgressPhase.SpeechRecognition, AsrProgressPhase.SpeechRecognition],
            progress.Select(item => item.Phase).ToArray());
        Assert.Equal(1, progress[^1].Fraction);
    }

    [Fact]
    public void AsrWireJsonUsesPathFieldNames()
    {
        var request = new AsrRequest
        {
            AudioPath = "/tmp/moongate/audio.wav",
            LanguageCode = "ja",
            ModelId = "whisper.cpp:base",
            CacheKey = "wire",
        };
        var requestJson = JsonSerializer.Serialize(request, AsrJson.Options);
        Assert.Contains("\"audioPath\":\"/tmp/moongate/audio.wav\"", requestJson, StringComparison.Ordinal);
        Assert.DoesNotContain("audioUrl", requestJson, StringComparison.Ordinal);

        var runtimeJson = JsonSerializer.Serialize(
            new AsrRuntimeInfo { ExecutablePath = "/opt/moongate/whisper-cli" },
            AsrJson.Options);
        Assert.Contains("\"executablePath\":\"/opt/moongate/whisper-cli\"", runtimeJson, StringComparison.Ordinal);
        Assert.DoesNotContain("executableUrl", runtimeJson, StringComparison.Ordinal);

        var cacheJson = JsonSerializer.Serialize(new AsrTranscriptCacheEntry
        {
            CacheKey = "wire",
            AudioFingerprint = "sha256:" + new string('a', 64),
            ModelId = "whisper.cpp:base",
            TranscriptPath = "/tmp/moongate/wire.transcript.json",
            CreatedAt = DateTimeOffset.UnixEpoch,
        }, AsrJson.Options);
        Assert.Contains("\"transcriptPath\":\"/tmp/moongate/wire.transcript.json\"", cacheJson, StringComparison.Ordinal);
        Assert.DoesNotContain("transcriptUrl", cacheJson, StringComparison.Ordinal);
    }

    [Fact]
    public async Task FakeRecognizerSupportsFailureAndCancellationModes()
    {
        var request = new AsrRequest { AudioPath = "/tmp/audio.wav", ModelId = "missing" };
        var missing = new FakeSpeechRecognizer(
            new AsrReadiness { Status = AsrReadinessStatus.MissingModel, ModelId = "missing", Message = "Model missing" },
            FakeSpeechRecognizerError.MissingModel);

        var error = await Assert.ThrowsAsync<FakeSpeechRecognizerException>(
            () => missing.TranscribeAsync(request, _ => { }));
        Assert.Equal(FakeSpeechRecognizerError.MissingModel, error.Reason);

        var cancelled = FakeSpeechRecognizer.Cancelled(
            new AsrReadiness { Status = AsrReadinessStatus.Ready, ModelId = "base", Message = "Ready" });
        await Assert.ThrowsAsync<TaskCanceledException>(() => cancelled.TranscribeAsync(request, _ => { }));
    }

    [Fact]
    public void ModelStoreReportsHashDiskAndDeleteState()
    {
        var directory = Path.Combine(Path.GetTempPath(), "moongate-asr-model-store-" + Guid.NewGuid().ToString("N"));
        try
        {
            Directory.CreateDirectory(directory);
            var hashSource = Path.Combine(directory, "hash-source.bin");
            File.WriteAllText(hashSource, "good model");
            var expectedSha = AsrModelStore.Sha256Hex(hashSource);
            File.Delete(hashSource);
            var model = new AsrModelInfo
            {
                Id = "whisper.cpp:test",
                DisplayName = "Whisper test",
                FileName = "ggml-test.bin",
                DownloadUrl = "https://example.com/ggml-test.bin",
                SizeBytes = 128,
                Sha256 = expectedSha,
                MemoryRequiredMb = 64,
                License = "MIT",
                SourceDescription = "fixture",
            };

            var store = new AsrModelStore(directory, _ => 1024);
            Assert.Equal(AsrModelInstallState.NotInstalled, store.Status(model).State);

            File.WriteAllText(store.InstalledPath(model), "bad model");
            var badStatus = store.Status(model);
            Assert.Equal(AsrModelInstallState.BadHash, badStatus.State);
            Assert.NotEqual(expectedSha, badStatus.ActualSha256);

            File.WriteAllText(store.InstalledPath(model), "good model");
            Assert.Equal(AsrModelInstallState.Installed, store.Status(model).State);

            File.WriteAllText(store.StagedPath(model), "partial");
            store.Delete(model);
            Assert.False(File.Exists(store.InstalledPath(model)));
            Assert.False(File.Exists(store.StagedPath(model)));

            var fullDiskStore = new AsrModelStore(directory, _ => 1);
            Assert.Equal(AsrModelInstallState.InsufficientDiskSpace, fullDiskStore.Status(model).State);
        }
        finally
        {
            if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public void ModelCatalogExposesConsentMetadataInstallStateAndDeleteById()
    {
        var directory = Path.Combine(Path.GetTempPath(), "moongate-asr-model-catalog-" + Guid.NewGuid().ToString("N"));
        try
        {
            Directory.CreateDirectory(directory);
            var hashSource = Path.Combine(directory, "hash-source.bin");
            File.WriteAllText(hashSource, "good model");
            var expectedSha = AsrModelStore.Sha256Hex(hashSource);
            File.Delete(hashSource);

            var installedModel = new AsrModelInfo
            {
                Id = "whisper.cpp:small-q5_1",
                DisplayName = "Whisper small q5_1",
                FileName = "ggml-small-q5_1.bin",
                DownloadUrl = "https://example.com/ggml-small-q5_1.bin",
                SizeBytes = 181_000_000,
                Sha256 = expectedSha,
                MemoryRequiredMb = 1024,
                License = "MIT",
                SourceDescription = "whisper.cpp model mirror",
            };
            var missingModel = new AsrModelInfo
            {
                Id = "whisper.cpp:base-q5_1",
                DisplayName = "Whisper base q5_1",
                FileName = "ggml-base-q5_1.bin",
                DownloadUrl = "https://example.com/ggml-base-q5_1.bin",
                SizeBytes = 64_000_000,
                Sha256 = new string('b', 64),
                MemoryRequiredMb = 512,
                License = "MIT",
                SourceDescription = "whisper.cpp model mirror",
            };

            var store = new AsrModelStore(directory, _ => 512_000_000);
            File.WriteAllText(store.InstalledPath(installedModel), "good model");
            File.WriteAllText(store.StagedPath(installedModel), "partial");

            var catalog = new AsrModelCatalog(
                new AsrModelManifest { Models = [installedModel, missingModel] },
                store);

            Assert.Equal([installedModel.Id, missingModel.Id], catalog.Entries.Select(entry => entry.Id));
            var installed = Assert.Single(catalog.Entries, entry => entry.Id == installedModel.Id);
            Assert.Equal("Whisper small q5_1", installed.DisplayName);
            Assert.Equal(181_000_000, installed.SizeBytes);
            Assert.Equal(1024, installed.MemoryRequiredMb);
            Assert.Equal(expectedSha, installed.Sha256);
            Assert.Equal("MIT", installed.License);
            Assert.Equal("whisper.cpp model mirror", installed.SourceDescription);
            Assert.Equal(installedModel.DownloadUrl, installed.DownloadUrl);
            Assert.Equal(AsrModelInstallState.Installed, installed.InstallState);
            Assert.True(installed.IsInstalled);
            Assert.False(installed.NeedsUserDownloadConsent);

            var missing = Assert.Single(catalog.Entries, entry => entry.Id == missingModel.Id);
            Assert.Equal(AsrModelInstallState.NotInstalled, missing.InstallState);
            Assert.False(missing.IsInstalled);
            Assert.True(missing.NeedsUserDownloadConsent);

            var deleted = catalog.DeleteModel(installedModel.Id);
            Assert.Equal(installedModel.Id, deleted.Id);
            Assert.False(File.Exists(store.InstalledPath(installedModel)));
            Assert.False(File.Exists(store.StagedPath(installedModel)));
            var error = Assert.Throws<AsrModelCatalogException>(() => catalog.DeleteModel("whisper.cpp:unknown"));
            Assert.Equal(AsrModelCatalogError.UnknownModelId, error.Reason);
            Assert.Equal("whisper.cpp:unknown", error.ModelId);
        }
        finally
        {
            if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public async Task ModelInstallerDownloadsStagesVerifiesAndInstallsById()
    {
        var directory = Path.Combine(Path.GetTempPath(), "moongate-asr-model-installer-" + Guid.NewGuid().ToString("N"));
        try
        {
            Directory.CreateDirectory(directory);
            var payload = Encoding.UTF8.GetBytes("verified model payload");
            var hashSource = Path.Combine(directory, "hash-source.bin");
            File.WriteAllBytes(hashSource, payload);
            var expectedSha = AsrModelStore.Sha256Hex(hashSource);
            File.Delete(hashSource);
            var model = new AsrModelInfo
            {
                Id = "whisper.cpp:test-installer",
                DisplayName = "Whisper installer test",
                FileName = "ggml-installer-test.bin",
                DownloadUrl = "https://example.com/ggml-installer-test.bin",
                SizeBytes = payload.Length,
                Sha256 = expectedSha,
                MemoryRequiredMb = 64,
                License = "MIT",
                SourceDescription = "fixture",
            };

            var store = new AsrModelStore(directory, _ => 1024 * 1024);
            var downloader = new FakeAsrModelDownloadClient(payload);
            var installer = new AsrModelInstaller(
                new AsrModelManifest { Models = [model] },
                store,
                downloader);
            var progress = new List<AsrProgress>();

            var status = await installer.InstallModelAsync(model.Id, progress.Add);

            Assert.Equal(AsrModelInstallState.Installed, status.State);
            Assert.Equal(payload, File.ReadAllBytes(store.InstalledPath(model)));
            Assert.False(File.Exists(store.StagedPath(model)));
            Assert.Equal([model.Id], downloader.Requests.Select(request => request.ModelId));
            Assert.Equal([store.StagedPath(model)], downloader.Requests.Select(request => request.DestinationPath));
            Assert.Equal(AsrProgressPhase.ModelDownload, progress.First().Phase);
            Assert.Equal(1, progress.Last().Fraction);
        }
        finally
        {
            if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public async Task ModelInstallerCleansStagingAndFailsOnHashMismatch()
    {
        var directory = Path.Combine(Path.GetTempPath(), "moongate-asr-model-installer-badhash-" + Guid.NewGuid().ToString("N"));
        try
        {
            Directory.CreateDirectory(directory);
            var model = new AsrModelInfo
            {
                Id = "whisper.cpp:test-badhash",
                DisplayName = "Whisper bad hash",
                FileName = "ggml-badhash-test.bin",
                DownloadUrl = "https://example.com/ggml-badhash-test.bin",
                SizeBytes = 9,
                Sha256 = new string('a', 64),
                MemoryRequiredMb = 64,
                License = "MIT",
                SourceDescription = "fixture",
            };
            var store = new AsrModelStore(directory, _ => 1024 * 1024);
            var downloader = new FakeAsrModelDownloadClient(Encoding.UTF8.GetBytes("bad bytes"));
            var installer = new AsrModelInstaller(
                new AsrModelManifest { Models = [model] },
                store,
                downloader);

            var error = await Assert.ThrowsAsync<AsrModelInstallerException>(() =>
                installer.InstallModelAsync(model.Id, _ => { }));
            Assert.Equal(AsrModelInstallerError.HashMismatch, error.Reason);
            Assert.Equal(model.Id, error.ModelId);
            Assert.Equal(64, error.ActualSha256?.Length);
            Assert.Contains("SHA-256", error.Message, StringComparison.Ordinal);
            Assert.Contains(model.Id, error.Message, StringComparison.Ordinal);
            Assert.False(File.Exists(store.InstalledPath(model)));
            Assert.False(File.Exists(store.StagedPath(model)));
        }
        finally
        {
            if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public void RuntimeLocatorFindsExecutableWhisperCliCandidate()
    {
        var directory = Path.Combine(Path.GetTempPath(), "moongate-asr-runtime-" + Guid.NewGuid().ToString("N"));
        try
        {
            Directory.CreateDirectory(directory);
            var nonExecutable = Path.Combine(directory, "main");
            File.WriteAllText(nonExecutable, "#!/bin/sh\n");
            if (!OperatingSystem.IsWindows())
            {
                File.SetUnixFileMode(nonExecutable, UnixFileMode.UserRead | UnixFileMode.UserWrite);
            }
            var missing = new AsrRuntimeLocator(
                candidateNames: ["main"],
                extraSearchPaths: [directory],
                environmentPath: "");
            Assert.Null(missing.Locate());

            var executableName = OperatingSystem.IsWindows() ? "whisper-cli.exe" : "whisper-cli";
            var executable = Path.Combine(directory, executableName);
            File.WriteAllText(executable, "#!/bin/sh\n");
            if (!OperatingSystem.IsWindows())
            {
                File.SetUnixFileMode(executable, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
            }

            var runtime = new AsrRuntimeLocator(
                candidateNames: [executableName],
                extraSearchPaths: [directory],
                environmentPath: "").Locate();

            Assert.NotNull(runtime);
            Assert.Equal("whisper.cpp", runtime.Provider);
            Assert.Equal(executable, runtime.ExecutablePath);
        }
        finally
        {
            if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public void RuntimeLocatorDefaultCandidatesDoNotAcceptGenericMainExecutable()
    {
        var directory = Path.Combine(Path.GetTempPath(), "moongate-asr-runtime-main-" + Guid.NewGuid().ToString("N"));
        try
        {
            Directory.CreateDirectory(directory);
            var genericMain = Path.Combine(directory, OperatingSystem.IsWindows() ? "main.exe" : "main");
            File.WriteAllText(genericMain, "#!/bin/sh\n");
            if (!OperatingSystem.IsWindows())
            {
                File.SetUnixFileMode(genericMain, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
            }

            Assert.Null(new AsrRuntimeLocator(extraSearchPaths: [directory], environmentPath: "").Locate());
        }
        finally
        {
            if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public void ModelStoreRejectsModelFilenamesOutsideStoreDirectory()
    {
        var directory = Path.Combine(Path.GetTempPath(), "moongate-asr-model-store-" + Guid.NewGuid().ToString("N"));
        var store = new AsrModelStore(directory, _ => 1024);
        var malicious = new AsrModelInfo
        {
            Id = "whisper.cpp:bad",
            DisplayName = "Bad",
            FileName = "../escape.bin",
            DownloadUrl = "https://example.com/escape.bin",
            SizeBytes = 8,
            Sha256 = new string('0', 64),
            MemoryRequiredMb = 64,
            License = "MIT",
            SourceDescription = "fixture",
        };

        var statusError = Assert.Throws<AsrModelStoreException>(() => store.Status(malicious));
        Assert.Equal(AsrModelStoreError.InvalidModelFileName, statusError.Reason);
        Assert.Equal("../escape.bin", statusError.ModelFileName);

        var deleteError = Assert.Throws<AsrModelStoreException>(() => store.Delete(malicious));
        Assert.Equal(AsrModelStoreError.InvalidModelFileName, deleteError.Reason);
        Assert.Equal("../escape.bin", deleteError.ModelFileName);
    }

    [Fact]
    public void AudioExtractionPlanBuilds16kMonoPcmWavCommand()
    {
        var ffmpeg = OperatingSystem.IsWindows()
            ? @"C:\Tools\ffmpeg.exe"
            : "/usr/local/bin/ffmpeg";
        var input = Path.Combine(Path.GetTempPath(), "moongate", "video.mp4");
        var output = Path.Combine(Path.GetTempPath(), "moongate", "audio.wav");

        var plan = AsrAudioExtractionPlan.Create(ffmpeg, input, output);

        Assert.Equal(ffmpeg, plan.FfmpegPath);
        Assert.Equal(
        [
            "-y",
            "-i", input,
            "-map", "0:a:0",
            "-vn",
            "-ac", "1",
            "-ar", "16000",
            "-c:a", "pcm_s16le",
            "-f", "wav",
            output,
        ], plan.Arguments);
    }

    [Fact]
    public void WhisperCppCommandPlanUsesJsonFullLanguagePromptAndProgress()
    {
        var runtime = new AsrRuntimeInfo { ExecutablePath = "/opt/moongate/whisper-cli" };
        var model = "/opt/moongate/models/ggml-small.bin";
        var audio = Path.Combine(Path.GetTempPath(), "moongate", "audio.wav");
        var request = new AsrRequest
        {
            AudioPath = audio,
            LanguageCode = " ja ",
            ModelId = "whisper.cpp:small",
            Prompt = "title channel glossary",
            WordTimestamps = true,
        };

        var plan = WhisperCppCommandPlan.Create(
            runtime,
            model,
            request,
            Path.Combine(Path.GetTempPath(), "moongate", "transcript.json"));

        Assert.Equal(runtime.ExecutablePath, plan.ExecutablePath);
        Assert.Equal(Path.Combine(Path.GetTempPath(), "moongate", "transcript"), plan.OutputBasePath);
        Assert.Equal(Path.Combine(Path.GetTempPath(), "moongate", "transcript.json"), plan.OutputJsonPath);
        Assert.Equal(
        [
            "-m", model,
            "-f", audio,
            "-ojf",
            "-of", Path.Combine(Path.GetTempPath(), "moongate", "transcript"),
            "-pp",
            "-dtw", "small", "-nfa",
            "-l", "ja",
            "--prompt", "title channel glossary",
        ], plan.Arguments);

        // No token JSON requested -> DTW is pointless and must be omitted.
        var segmentJsonPlan = WhisperCppCommandPlan.Create(
            runtime,
            model,
            new AsrRequest { AudioPath = audio, ModelId = "whisper.cpp:small", WordTimestamps = false },
            Path.Combine(Path.GetTempPath(), "moongate", "segments"));
        Assert.Contains("-oj", segmentJsonPlan.Arguments);
        Assert.DoesNotContain("-ojf", segmentJsonPlan.Arguments);
        Assert.DoesNotContain("-dtw", segmentJsonPlan.Arguments);
        Assert.DoesNotContain("-nfa", segmentJsonPlan.Arguments);

        // Unknown preset -> omit -dtw (fail-safe), never crash.
        var unknownModelPlan = WhisperCppCommandPlan.Create(
            runtime,
            model,
            new AsrRequest { AudioPath = audio, ModelId = "whisper.cpp:test" },
            Path.Combine(Path.GetTempPath(), "moongate", "unknown"));
        Assert.DoesNotContain("-dtw", unknownModelPlan.Arguments);
    }

    [Fact]
    public void WhisperCppCommandPlanOmitsLanguageFlagForAutoDetect()
    {
        var runtime = new AsrRuntimeInfo { ExecutablePath = "/opt/moongate/whisper-cli" };
        var model = "/opt/moongate/models/ggml-small.bin";
        var audio = Path.Combine(Path.GetTempPath(), "moongate", "audio.wav");

        var plan = WhisperCppCommandPlan.Create(
            runtime,
            model,
            new AsrRequest
            {
                AudioPath = audio,
                LanguageCode = " auto ",
                ModelId = "whisper.cpp:small",
                WordTimestamps = true,
            },
            Path.Combine(Path.GetTempPath(), "moongate", "transcript.json"));

        Assert.DoesNotContain("-l", plan.Arguments);
        Assert.DoesNotContain("auto", plan.Arguments);
    }

    [Fact]
    public void DefaultLocalAsrPromptOmitsLanguageHintForAutoDetect()
    {
        var video = Path.Combine(Path.GetTempPath(), "Moon Gate Clip.mp4");

        Assert.Equal(
            "title=Moon Gate Clip; language=ja",
            AsrPromptBuilder.DefaultPrompt(video, " ja "));
        Assert.Equal(
            "title=Moon Gate Clip",
            AsrPromptBuilder.DefaultPrompt(video, " auto "));
        Assert.Equal(
            "title=Moon Gate Clip",
            AsrPromptBuilder.DefaultPrompt(video, " AUTO "));
        Assert.Null(AsrPromptBuilder.DefaultPrompt(Path.Combine(Path.GetTempPath(), "   .mp4"), "auto"));
    }

    [Fact]
    public void TranscriptCacheStoreWritesReadsAndInvalidatesByInputIdentity()
    {
        var directory = Path.Combine(Path.GetTempPath(), "moongate-asr-transcript-cache-" + Guid.NewGuid().ToString("N"));
        try
        {
            var store = new AsrTranscriptCacheStore(directory);
            var createdAt = DateTimeOffset.FromUnixTimeSeconds(1_785_100_000);
            var transcript = new AsrTranscript
            {
                Id = "clip-auto-ja",
                LanguageCode = "ja",
                Words = [new AsrWord { Text = "梅雨が明ける", StartSeconds = 0.2, EndSeconds = 1.5 }],
                SourceModelId = "whisper.cpp:small",
                CreatedAt = createdAt,
            };

            var entry = store.Write(
                transcript,
                cacheKey: "clip-audio-small-auto",
                audioFingerprint: "sha256:audio-a",
                createdAt: createdAt);

            Assert.True(File.Exists(store.EntryPath("clip-audio-small-auto")));
            Assert.True(File.Exists(store.TranscriptPath("clip-audio-small-auto")));
            Assert.Equal(entry, store.ReadEntry("clip-audio-small-auto"));
            AssertTranscriptEqual(transcript, store.ReadTranscript(entry));
            AssertTranscriptEqual(transcript, store.CachedTranscript(
                "clip-audio-small-auto",
                audioFingerprint: "sha256:audio-a",
                modelId: "whisper.cpp:small",
                languageCode: null));
            Assert.Null(store.CachedTranscript(
                "clip-audio-small-auto",
                audioFingerprint: "sha256:audio-b",
                modelId: "whisper.cpp:small",
                languageCode: null));
            Assert.Null(store.CachedTranscript(
                "clip-audio-small-auto",
                audioFingerprint: "sha256:audio-a",
                modelId: "whisper.cpp:base",
                languageCode: null));
            Assert.Null(store.CachedTranscript(
                "clip-audio-small-auto",
                audioFingerprint: "sha256:audio-a",
                modelId: "whisper.cpp:small",
                languageCode: "en"));
        }
        finally
        {
            if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public void TranscriptCacheStoresDetectedLanguageForAutoRequestAndMatchesItExplicitly()
    {
        var directory = Path.Combine(Path.GetTempPath(), "moongate-asr-transcript-cache-auto-" + Guid.NewGuid().ToString("N"));
        try
        {
            var store = new AsrTranscriptCacheStore(directory);
            var createdAt = DateTimeOffset.FromUnixTimeSeconds(1_785_100_100);
            var transcript = new AsrTranscript
            {
                Id = "clip-auto-ja",
                LanguageCode = "ja",
                Words = [new AsrWord { Text = "梅雨が明ける", StartSeconds = 0.2, EndSeconds = 1.5 }],
                SourceModelId = "whisper.cpp:small",
                CreatedAt = createdAt,
            };

            var entry = store.Write(
                transcript,
                cacheKey: "clip-audio-small-auto-detected",
                audioFingerprint: "sha256:audio-auto",
                languageCode: " auto ",
                createdAt: createdAt);

            Assert.Equal("ja", entry.LanguageCode);
            AssertTranscriptEqual(transcript, store.CachedTranscript(
                "clip-audio-small-auto-detected",
                audioFingerprint: "sha256:audio-auto",
                modelId: "whisper.cpp:small",
                languageCode: "auto"));
            AssertTranscriptEqual(transcript, store.CachedTranscript(
                "clip-audio-small-auto-detected",
                audioFingerprint: "sha256:audio-auto",
                modelId: "whisper.cpp:small",
                languageCode: " ja "));
            Assert.Null(store.CachedTranscript(
                "clip-audio-small-auto-detected",
                audioFingerprint: "sha256:audio-auto",
                modelId: "whisper.cpp:small",
                languageCode: "en"));
        }
        finally
        {
            if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public void TranscriptMapperBuildsCleanSourceFragments()
    {
        var transcript = new AsrTranscript
        {
            Id = "mapper",
            LanguageCode = "ja",
            Words =
            [
                new AsrWord { Text = " 梅雨 ", StartSeconds = 0.0, EndSeconds = 0.4 },
                new AsrWord { Text = "", StartSeconds = 0.4, EndSeconds = 0.5 },
                new AsrWord { Text = "が", StartSeconds = -1, EndSeconds = 0.6 },
                new AsrWord { Text = "明ける", StartSeconds = 0.6, EndSeconds = 1.2 },
                new AsrWord { Text = "bad", StartSeconds = 2.0, EndSeconds = 1.0 },
            ],
            SourceModelId = "whisper.cpp:test",
        };

        var fragments = AsrTranscriptMapper.SourceFragments(transcript);

        Assert.Equal(["梅雨", "明ける"], fragments.Select(fragment => fragment.Text).ToArray());
        Assert.Equal(0.0, fragments[0].StartSeconds, precision: 3);
        Assert.Equal(1.2, fragments[1].EndSeconds, precision: 3);
    }

    [Fact]
    public void TranscriptMapperBuildsLocalAsrSourceSrtWithLanguageAsLastDotSegment()
    {
        var directory = Path.Combine(Path.GetTempPath(), "moongate-asr-source-srt-" + Guid.NewGuid().ToString("N"));
        try
        {
            Directory.CreateDirectory(directory);
            var video = Path.Combine(directory, "video.mp4");
            File.WriteAllText(video, "video");
            var transcript = new AsrTranscript
            {
                Id = "clip",
                LanguageCode = "ja",
                DurationSeconds = 1.5,
                Words =
                [
                    new AsrWord { Text = "梅雨", StartSeconds = 0.0, EndSeconds = 0.6 },
                    new AsrWord { Text = "が", StartSeconds = 0.6, EndSeconds = 0.8 },
                    new AsrWord { Text = "明ける。", StartSeconds = 0.8, EndSeconds = 1.5 },
                ],
                SourceModelId = "whisper.cpp:test",
                CreatedAt = DateTimeOffset.UnixEpoch,
            };

            var output = AsrTranscriptMapper.WriteLocalAsrSourceSrt(transcript, video);

            Assert.Equal("video.local-asr.ja.srt", Path.GetFileName(output));
            var parsed = SrtTools.ParseSrt(File.ReadAllText(output));
            Assert.Equal(["梅雨が明ける。"], parsed.Select(cue => cue.Text).ToArray());
            Assert.Equal("00:00:00,200", parsed[0].Start);
            Assert.Equal("00:00:01,500", parsed[0].End);
        }
        finally
        {
            if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public void LocalAsrTimingPlannerRemovesMarkersAndRejectsFlashCues()
    {
        var transcript = new AsrTranscript
        {
            Id = "koupen",
            LanguageCode = "ja",
            Words =
            [
                new AsrWord { Text = "[_BEG_]", StartSeconds = 0.0, EndSeconds = 0.0 },
                new AsrWord { Text = "コーペンちゃん", StartSeconds = 0.1, EndSeconds = 1.0 },
                new AsrWord { Text = "[_TT_100]", StartSeconds = 1.0, EndSeconds = 1.0 },
                new AsrWord { Text = "梅", StartSeconds = 1.1, EndSeconds = 1.4 },
                new AsrWord { Text = "だー！", StartSeconds = 1.4, EndSeconds = 1.8 },
                new AsrWord { Text = "?", StartSeconds = 101.990, EndSeconds = 102.000 },
                new AsrWord { Text = "[_TT_500]", StartSeconds = 112.0, EndSeconds = 112.0 },
            ],
            SourceModelId = "whisper.cpp:test",
        };

        var cues = AsrTranscriptMapper.SourceCues(transcript);

        Assert.Equal(["コーペンちゃん梅だー！"], cues.Select(cue => cue.Text).ToArray());
        // leadIn=0 keeps the raw onset; the last cue holds HoldToNextSeconds past the last token (1.8s -> 2.5s).
        Assert.Equal("00:00:00,300", cues[0].Start);
        Assert.Equal("00:00:02,500", cues[0].End);
        Assert.DoesNotContain(cues, cue => cue.Text.Contains("[_", StringComparison.Ordinal));
    }

    [Fact]
    public void LocalAsrTimingPlannerSplitsLongCjkLyricsWithoutLongIdleHold()
    {
        var transcript = new AsrTranscript
        {
            Id = "lyrics",
            LanguageCode = "ja",
            Words =
            [
                new AsrWord { Text = "きょうも", StartSeconds = 94.48, EndSeconds = 95.30 },
                new AsrWord { Text = "はなまる", StartSeconds = 95.30, EndSeconds = 96.20 },
                new AsrWord { Text = "ぽかぽかぽかぽか", StartSeconds = 96.20, EndSeconds = 98.50 },
                new AsrWord { Text = "ぽかぽかぽかぽか", StartSeconds = 98.50, EndSeconds = 101.65 },
            ],
            SourceModelId = "whisper.cpp:test",
        };

        var cues = AsrTranscriptMapper.SourceCues(transcript);

        Assert.True(cues.Count >= 2);
        foreach (var cue in cues)
        {
            var start = SrtTools.SrtTimeToSeconds(cue.Start);
            var end = SrtTools.SrtTimeToSeconds(cue.End);
            Assert.True(end - start >= 0.3);
            Assert.True(end - start <= 4.5);
        }
    }

    [Fact]
    public void LocalAsrTimingPlannerSuppressesRepeatedJapaneseLoopHallucinations()
    {
        var words = new List<AsrWord>
        {
            new() { Text = "おはよう", StartSeconds = 160.0, EndSeconds = 160.6 },
        };
        var loopTokens = new[] { "き", "ょ", "う", "も", "、", "は", "な", "ま", "る" };
        for (var repeatIndex = 0; repeatIndex < 12; repeatIndex++)
        {
            var baseTime = 162.0 + repeatIndex * 0.02;
            for (var tokenIndex = 0; tokenIndex < loopTokens.Length; tokenIndex++)
            {
                var token = loopTokens[tokenIndex];
                var start = baseTime + tokenIndex * 0.01;
                words.Add(new AsrWord
                {
                    Text = token,
                    StartSeconds = start,
                    EndSeconds = start + (token == "、" ? 0.01 : 0.05),
                });
            }
        }
        words.Add(new AsrWord { Text = "またね", StartSeconds = 180.0, EndSeconds = 180.8 });
        var transcript = new AsrTranscript
        {
            Id = "japanese-loop-hallucination",
            LanguageCode = "ja",
            Words = words,
            SourceModelId = "whisper.cpp:test",
        };

        var cues = AsrTranscriptMapper.SourceCues(transcript);
        var joined = string.Join(" ", cues.Select(cue => cue.Text));
        var loopCount = joined.Split("きょうもはなまる", StringSplitOptions.None).Length - 1;

        Assert.Contains("おはよう", joined, StringComparison.Ordinal);
        Assert.Contains("またね", joined, StringComparison.Ordinal);
        Assert.DoesNotContain("きうも", joined, StringComparison.Ordinal);
        Assert.True(loopCount <= 1, "runaway repeated Japanese loop should be fused after one readable repeat");
        foreach (var cue in cues)
        {
            var start = SrtTools.SrtTimeToSeconds(cue.Start)!.Value;
            var end = SrtTools.SrtTimeToSeconds(cue.End)!.Value;
            Assert.True(end > start, "local ASR cues must never serialize as zero-duration SRT entries");
        }
    }

    [Fact]
    public void LocalAsrTimingPlannerAvoidsWeakLatinBoundaries()
    {
        var transcript = new AsrTranscript
        {
            Id = "latin",
            LanguageCode = "en",
            Words =
            [
                new AsrWord { Text = "This", StartSeconds = 0.0, EndSeconds = 0.3 },
                new AsrWord { Text = "is", StartSeconds = 0.3, EndSeconds = 0.5 },
                new AsrWord { Text = "the", StartSeconds = 0.5, EndSeconds = 0.7 },
                new AsrWord { Text = "ship", StartSeconds = 0.7, EndSeconds = 1.0 },
                new AsrWord { Text = "we", StartSeconds = 1.0, EndSeconds = 1.2 },
                new AsrWord { Text = "need.", StartSeconds = 1.2, EndSeconds = 1.6 },
            ],
            SourceModelId = "whisper.cpp:test",
        };

        var cues = AsrTranscriptMapper.SourceCues(transcript);

        Assert.Equal(["This is the ship we need."], cues.Select(cue => cue.Text).ToArray());
        Assert.DoesNotContain(cues, cue => cue.Text.EndsWith(" the", StringComparison.Ordinal));
    }

    [Fact]
    public void LocalAsrTimingPlannerKeepsSpacesAroundLatinRunsInsideCjk()
    {
        var transcript = new AsrTranscript
        {
            Id = "cjk-latin",
            LanguageCode = "zh",
            Words =
            [
                new AsrWord { Text = "說", StartSeconds = 0.0, EndSeconds = 0.2 },
                new AsrWord { Text = "法", StartSeconds = 0.2, EndSeconds = 0.4 },
                new AsrWord { Text = "I", StartSeconds = 0.4, EndSeconds = 0.55 },
                new AsrWord { Text = "'m", StartSeconds = 0.55, EndSeconds = 0.7 },
                new AsrWord { Text = "actually", StartSeconds = 0.7, EndSeconds = 1.0 },
                new AsrWord { Text = "a", StartSeconds = 1.0, EndSeconds = 1.1 },
                new AsrWord { Text = "lingu", StartSeconds = 1.1, EndSeconds = 1.35 },
                new AsrWord { Text = "ist", StartSeconds = 1.35, EndSeconds = 1.5 },
                new AsrWord { Text = "這是", StartSeconds = 1.5, EndSeconds = 1.9 },
            ],
            SourceModelId = "whisper.cpp:test",
        };

        var text = string.Join(" ", AsrTranscriptMapper.SourceCues(transcript).Select(cue => cue.Text));

        Assert.Contains("說法 I'm actually a linguist", text, StringComparison.Ordinal);
        Assert.DoesNotContain("I 'm", text, StringComparison.Ordinal);
        Assert.DoesNotContain("I'mactually", text, StringComparison.Ordinal);
        Assert.DoesNotContain("lingu ist", text, StringComparison.Ordinal);
    }

    [Fact]
    public void LocalAsrTimingPlannerRejoinsMainstreamLatinSubwordFragments()
    {
        var transcript = new AsrTranscript
        {
            Id = "latin-subwords",
            LanguageCode = "zh",
            Words =
            [
                new AsrWord { Text = "混合", StartSeconds = 0.0, EndSeconds = 0.15 },
                new AsrWord { Text = "de", StartSeconds = 0.15, EndSeconds = 0.30 },
                new AsrWord { Text = "esper", StartSeconds = 0.30, EndSeconds = 0.50 },
                new AsrWord { Text = "ança", StartSeconds = 0.50, EndSeconds = 0.70 },
                new AsrWord { Text = "At", StartSeconds = 0.70, EndSeconds = 0.85 },
                new AsrWord { Text = "ual", StartSeconds = 0.85, EndSeconds = 1.00 },
                new AsrWord { Text = "mente", StartSeconds = 1.00, EndSeconds = 1.30 },
                new AsrWord { Text = "yo", StartSeconds = 1.30, EndSeconds = 1.50 },
                new AsrWord { Text = "siempre", StartSeconds = 1.50, EndSeconds = 1.90 },
            ],
            SourceModelId = "whisper.cpp:test",
        };

        var text = string.Join(" ", AsrTranscriptMapper.SourceCues(transcript).Select(cue => cue.Text));

        Assert.Contains("de esperança", text, StringComparison.Ordinal);
        Assert.Contains("yo siempre", text, StringComparison.Ordinal);
        Assert.DoesNotContain("esper ança", text, StringComparison.Ordinal);
        Assert.DoesNotContain("yosiempre", text, StringComparison.Ordinal);
    }

    [Fact]
    public void LocalAsrTimingPlannerRejoinsLatinFragmentsInSourceLanguages()
    {
        var transcript = new AsrTranscript
        {
            Id = "latin-source-subwords",
            LanguageCode = "pt",
            Words =
            [
                new AsrWord { Text = "Quando", StartSeconds = 0.0, EndSeconds = 0.2 },
                new AsrWord { Text = "a", StartSeconds = 0.2, EndSeconds = 0.3 },
                new AsrWord { Text = "pal", StartSeconds = 0.3, EndSeconds = 0.45 },
                new AsrWord { Text = "estra", StartSeconds = 0.45, EndSeconds = 0.7 },
                new AsrWord { Text = "não", StartSeconds = 0.7, EndSeconds = 0.9 },
                new AsrWord { Text = "é", StartSeconds = 0.9, EndSeconds = 1.0 },
                new AsrWord { Text = "d", StartSeconds = 1.0, EndSeconds = 1.1 },
                new AsrWord { Text = "ada", StartSeconds = 1.1, EndSeconds = 1.25 },
                new AsrWord { Text = "em", StartSeconds = 1.25, EndSeconds = 1.35 },
                new AsrWord { Text = "ingl", StartSeconds = 1.35, EndSeconds = 1.55 },
                new AsrWord { Text = "ês", StartSeconds = 1.55, EndSeconds = 1.75 },
                new AsrWord { Text = "Sand", StartSeconds = 1.75, EndSeconds = 1.95 },
                new AsrWord { Text = "wich", StartSeconds = 1.95, EndSeconds = 2.10 },
                new AsrWord { Text = "Ker", StartSeconds = 2.10, EndSeconds = 2.25 },
                new AsrWord { Text = "ne", StartSeconds = 2.25, EndSeconds = 2.40 },
                new AsrWord { Text = "vou", StartSeconds = 2.40, EndSeconds = 2.55 },
                new AsrWord { Text = "la", StartSeconds = 2.55, EndSeconds = 2.70 },
                new AsrWord { Text = "ient", StartSeconds = 2.70, EndSeconds = 2.90 },
            ],
            SourceModelId = "whisper.cpp:test",
        };

        var text = string.Join(" ", AsrTranscriptMapper.SourceCues(transcript).Select(cue => cue.Text));

        Assert.Contains("palestra", text, StringComparison.Ordinal);
        Assert.Contains("dada", text, StringComparison.Ordinal);
        Assert.Contains("inglês", text, StringComparison.Ordinal);
        Assert.Contains("Sandwich", text, StringComparison.Ordinal);
        Assert.Contains("Kerne", text, StringComparison.Ordinal);
        Assert.Contains("voulaient", text, StringComparison.Ordinal);
        Assert.Contains("a palestra", text, StringComparison.Ordinal);
        Assert.DoesNotContain("pal estra", text, StringComparison.Ordinal);
        Assert.DoesNotContain("d ada", text, StringComparison.Ordinal);
        Assert.DoesNotContain("ingl ês", text, StringComparison.Ordinal);
        Assert.DoesNotContain("Sand wich", text, StringComparison.Ordinal);
        Assert.DoesNotContain("Ker ne", text, StringComparison.Ordinal);
        Assert.DoesNotContain("vou la", text, StringComparison.Ordinal);
        Assert.DoesNotContain("apalestra", text, StringComparison.Ordinal);
    }

    [Fact]
    public void LocalAsrTimingPlannerAbsorbsJapaneseOrphanFragmentsAcrossSoftCaps()
    {
        var transcript = new AsrTranscript
        {
            Id = "japanese-orphans",
            LanguageCode = "ja",
            Words =
            [
                new AsrWord { Text = "一緒にい", StartSeconds = 0.0, EndSeconds = 0.48 },
                new AsrWord { Text = "こう", StartSeconds = 0.76, EndSeconds = 5.72 },
                new AsrWord { Text = "見て朝の花丸スタンプカ", StartSeconds = 8.0, EndSeconds = 12.8 },
                new AsrWord { Text = "ード", StartSeconds = 13.08, EndSeconds = 14.2 },
                new AsrWord { Text = "僕が", StartSeconds = 14.48, EndSeconds = 15.0 },
                new AsrWord { Text = "顔", StartSeconds = 20.0, EndSeconds = 24.1 },
                new AsrWord { Text = "洗って偉い", StartSeconds = 24.38, EndSeconds = 26.1 },
                new AsrWord { Text = "コウペンちゃ", StartSeconds = 30.0, EndSeconds = 31.46 },
                new AsrWord { Text = "う", StartSeconds = 31.74, EndSeconds = 35.9 },
            ],
            SourceModelId = "whisper.cpp:test",
        };

        var texts = AsrTranscriptMapper.SourceCues(transcript).Select(cue => cue.Text).ToArray();

        Assert.DoesNotContain("こう", texts);
        Assert.Contains(texts, text => text.Contains("一緒にいこう", StringComparison.Ordinal));
        Assert.DoesNotContain(texts, text => text.StartsWith("ード", StringComparison.Ordinal));
        Assert.Contains(texts, text => text.Contains("スタンプカード", StringComparison.Ordinal));
        Assert.DoesNotContain("顔", texts);
        Assert.Contains(texts, text => text.Contains("顔洗って", StringComparison.Ordinal));
        Assert.DoesNotContain("う", texts);
        Assert.Contains(texts, text => text.Contains("コウペンちゃう", StringComparison.Ordinal));
    }

    [Fact]
    public void LocalAsrTimingPlannerDropsOrShortensJapaneseResidualFragments()
    {
        var transcript = new AsrTranscript
        {
            Id = "japanese-residuals",
            LanguageCode = "ja",
            Words =
            [
                new AsrWord { Text = "一緒にいようねさ", StartSeconds = 0.0, EndSeconds = 2.1 },
                new AsrWord { Text = "っ", StartSeconds = 2.38, EndSeconds = 7.2 },
                new AsrWord { Text = "ー", StartSeconds = 8.0, EndSeconds = 13.2 },
                new AsrWord { Text = "ぁ", StartSeconds = 13.5, EndSeconds = 16.9 },
                new AsrWord { Text = "おはよう", StartSeconds = 20.0, EndSeconds = 21.0 },
            ],
            SourceModelId = "whisper.cpp:test",
        };

        var cues = AsrTranscriptMapper.SourceCues(transcript);

        Assert.DoesNotContain(cues, cue => cue.Text is "っ" or "ー" or "ぁ");
        foreach (var cue in cues.Where(cue => SubtitleTimingPlanner.VisibleCharacters(cue.Text) <= 2))
        {
            var start = SrtTools.SrtTimeToSeconds(cue.Start)!.Value;
            var end = SrtTools.SrtTimeToSeconds(cue.End)!.Value;
            Assert.True(end - start < 3.0, $"short residual-like cue held too long: {cue.Text}");
        }
    }

    [Fact]
    public void LocalAsrTimingPlannerDoesNotCapBeforeLastCjkWordEnds()
    {
        var transcript = new AsrTranscript
        {
            Id = "cjk-last-word",
            LanguageCode = "zh",
            Words =
            [
                new AsrWord { Text = "早上来这里菜市场", StartSeconds = 0.0, EndSeconds = 6.0 },
            ],
            SourceModelId = "whisper.cpp:test",
        };

        var cue = Assert.Single(AsrTranscriptMapper.SourceCues(transcript));
        var end = SrtTools.SrtTimeToSeconds(cue.End)!.Value;

        Assert.True(end >= 6.0, $"cue ended before the last CJK word: {cue.End}");
    }

    [Fact]
    public void LocalAsrTimingPlannerKeepsTrailingParticleAttachedAndDropsNoSpeech()
    {
        var transcript = new AsrTranscript
        {
            Id = "particle",
            LanguageCode = "ja",
            Words =
            [
                new AsrWord { Text = "おはよう", StartSeconds = 0.0, EndSeconds = 0.8 },
                new AsrWord { Text = "コーペンちゃんだ", StartSeconds = 0.8, EndSeconds = 3.8 },
                new AsrWord { Text = "よ", StartSeconds = 3.8, EndSeconds = 4.4 },
                new AsrWord { Text = "?", StartSeconds = 9.0, EndSeconds = 12.0 },
            ],
            SourceModelId = "whisper.cpp:test",
        };
        var cues = AsrTranscriptMapper.SourceCues(transcript);
        Assert.DoesNotContain(cues, cue => cue.Text.StartsWith("よ", StringComparison.Ordinal));
        Assert.DoesNotContain(cues, cue => cue.Text.Contains('?'));
        Assert.Contains(cues, cue => cue.Text.EndsWith("よ", StringComparison.Ordinal));
    }

    [Fact]
    public void WhisperDtwPresetMapsQuantizedModelIdsAndRejectsUnknown()
    {
        Assert.Equal("small", WhisperDtwPreset.Preset("whisper.cpp:small"));
        Assert.Equal("small", WhisperDtwPreset.Preset("whisper.cpp:small-q5_1"));
        Assert.Equal("base", WhisperDtwPreset.Preset("whisper.cpp:base-q8_0"));
        Assert.Equal("tiny", WhisperDtwPreset.Preset("whisper.cpp:tiny-q5_1"));
        Assert.Equal("small.en", WhisperDtwPreset.Preset("whisper.cpp:small.en-q5_1"));
        Assert.Equal("medium", WhisperDtwPreset.Preset("whisper.cpp:medium-q5_0"));
        Assert.Equal("large.v3.turbo", WhisperDtwPreset.Preset("whisper.cpp:large-v3-turbo-q5_0"));
        Assert.Null(WhisperDtwPreset.Preset("whisper.cpp:test"));
        Assert.Null(WhisperDtwPreset.Preset("whisper.cpp:gigantic-q5_0"));
    }

    [Fact]
    public void WhisperCppJsonParserPrefersDtwTokenTimestampsWhenPresent()
    {
        const string json = """
        {
          "result": { "language": "en" },
          "transcription": [
            {
              "text": " hello world",
              "offsets": { "from": 0, "to": 2000 },
              "tokens": [
                { "text": " hello", "offsets": { "from": 0, "to": 600 }, "t_dtw": 30 },
                { "text": " world", "offsets": { "from": 600, "to": 2000 }, "t_dtw": 90 }
              ]
            }
          ]
        }
        """;
        var transcript = new WhisperCppJsonTranscriptParser().Parse(
            Encoding.UTF8.GetBytes(json),
            new AsrRequest { AudioPath = "/tmp/a.wav", ModelId = "whisper.cpp:large-v3-turbo-q5_0" },
            "dtw");
        Assert.Equal(["hello", "world"], transcript.Words.Select(w => w.Text).ToArray());
        Assert.Equal(0.30, transcript.Words[0].StartSeconds, 4);
        Assert.Equal(0.90, transcript.Words[0].EndSeconds, 4);
        Assert.Equal(0.90, transcript.Words[1].StartSeconds, 4);
        Assert.Equal(2.30, transcript.Words[1].EndSeconds, 4);
    }

    [Fact]
    public void WhisperCppJsonParserUsesOffsetsWhenDtwAbsent()
    {
        const string json = """
        {
          "result": { "language": "en" },
          "transcription": [
            {
              "text": " hi",
              "offsets": { "from": 100, "to": 700 },
              "tokens": [ { "text": " hi", "offsets": { "from": 100, "to": 700 }, "t_dtw": -1 } ]
            }
          ]
        }
        """;
        var transcript = new WhisperCppJsonTranscriptParser().Parse(
            Encoding.UTF8.GetBytes(json),
            new AsrRequest { AudioPath = "/tmp/a.wav", ModelId = "whisper.cpp:test" },
            "nodtw");
        Assert.Equal(0.1, transcript.Words[0].StartSeconds, 4);
        Assert.Equal(0.7, transcript.Words[0].EndSeconds, 4);
    }

    private static SubtitleCue RetimerCue(double start, double end, string text, double? lastTokenEnd = null) =>
        new(
            0,
            SrtTools.SecondsToSrtTime(start),
            SrtTools.SecondsToSrtTime(end),
            text,
            [new SubtitleCueSourceFragment(start, lastTokenEnd ?? end, text)]);

    [Fact]
    public void WhisperCueRetimerDelaysOnsetAndHoldsTowardNextCue()
    {
        // Onset nudged later by onsetDelaySeconds (long cue, not bound-limited): 5.0 -> 5.2.
        var single = WhisperCueRetimer.Retime([RetimerCue(5.0, 9.0, "hello there", 8.8)], null);
        Assert.Equal(5.0 + WhisperCueRetimer.OnsetDelaySeconds, SrtTools.SrtTimeToSeconds(single[0].Start)!.Value, 3);

        // Short cue: delay bounded so the cue keeps a positive readable duration.
        var shortCue = WhisperCueRetimer.Retime([RetimerCue(5.0, 5.4, "hi", 5.4)], null);
        var ss = SrtTools.SrtTimeToSeconds(shortCue[0].Start)!.Value;
        var se = SrtTools.SrtTimeToSeconds(shortCue[0].End)!.Value;
        Assert.True(se - ss > 0.0);
        Assert.True(ss <= 5.4);

        var pair = WhisperCueRetimer.Retime(
            [RetimerCue(1.0, 1.3, "one", 1.2), RetimerCue(3.0, 3.6, "two", 3.5)], null);
        var firstEnd = SrtTools.SrtTimeToSeconds(pair[0].End)!.Value;
        var secondStart = SrtTools.SrtTimeToSeconds(pair[1].Start)!.Value;
        Assert.True(firstEnd <= secondStart, "cue must not overlap the next onset");
        Assert.True(firstEnd > 1.3, "cue should hold past its raw end toward the next onset");
    }

    [Fact]
    public void WhisperCueRetimerNeverOverlapsAdjacentCues()
    {
        // Tightly spaced, short cues: the kind that previously overlapped (BUG-1).
        var cues = WhisperCueRetimer.Retime(
            [
                RetimerCue(1.0, 1.3, "one", 1.05),
                RetimerCue(1.1, 1.6, "two", 1.5),
                RetimerCue(1.65, 5.0, "three", 4.9),
            ],
            null);
        Assert.Equal(3, cues.Count);
        var previousEnd = double.NegativeInfinity;
        foreach (var cue in cues)
        {
            var start = SrtTools.SrtTimeToSeconds(cue.Start)!.Value;
            var end = SrtTools.SrtTimeToSeconds(cue.End)!.Value;
            Assert.True(start + 0.0011 >= previousEnd, "cue overlaps previous cue");
            Assert.True(end > start, "cue must have positive duration");
            previousEnd = end;
        }
    }

    [Fact]
    public void WhisperCueRetimerShortensHoldForMixedCjkLatinRuns()
    {
        var mixed = WhisperCueRetimer.Retime(
            [
                RetimerCue(10.0, 11.2, "說法I'mactuallyalinguist", 11.0),
                RetimerCue(13.0, 13.6, "下一句", 13.5),
            ],
            null);
        var mixedEnd = SrtTools.SrtTimeToSeconds(mixed[0].End)!.Value;
        Assert.Equal(11.0 + WhisperCueRetimer.MixedCjkLatinHoldToNextSeconds, mixedEnd, 3);

        var plainCjk = WhisperCueRetimer.Retime(
            [
                RetimerCue(20.0, 21.2, "真正身份是一位語言學家", 21.0),
                RetimerCue(23.0, 23.6, "下一句", 23.5),
            ],
            null);
        var plainEnd = SrtTools.SrtTimeToSeconds(plainCjk[0].End)!.Value;
        Assert.Equal(21.0 + WhisperCueRetimer.HoldToNextSeconds, plainEnd, 3);
    }

    [Fact]
    public void WhisperCueRetimerRespectsDurationCapAndTranscriptLength()
    {
        var longCjk = WhisperCueRetimer.Retime([RetimerCue(10.0, 30.0, "字幕字幕字幕字幕")], null);
        var start = SrtTools.SrtTimeToSeconds(longCjk[0].Start)!.Value;
        var end = SrtTools.SrtTimeToSeconds(longCjk[0].End)!.Value;
        Assert.True(end - start <= LocalAsrSubtitleTimingPlanner.RelaxedCjkCueSeconds + 0.0015);

        var clamped = WhisperCueRetimer.Retime([RetimerCue(8.0, 20.0, "字幕")], 11.0);
        Assert.True(SrtTools.SrtTimeToSeconds(clamped[0].End)!.Value <= 11.0 + 0.0015);
    }

    [Fact]
    public void WhisperCppJsonParserBuildsTranscriptFromTokenOffsets()
    {
        var createdAt = DateTimeOffset.FromUnixTimeSeconds(1_785_200_000);
        const string json = """
        {
          "result": { "language": "ja", "language_probability": 0.88 },
          "transcription": [
            {
              "text": " 梅雨 が 明ける",
              "offsets": { "from": 0, "to": 1500 },
              "tokens": [
                { "text": " 梅雨", "offsets": { "from": 0, "to": 600 }, "p": 0.82 },
                { "text": " が", "offsets": { "from": 600, "to": 800 }, "p": 0.93 },
                { "text": " 明ける", "offsets": { "from": 800, "to": 1500 }, "p": 0.76 }
              ]
            }
          ]
        }
        """;
        var request = new AsrRequest
        {
            AudioPath = "/tmp/audio.wav",
            LanguageCode = "ja",
            ModelId = "whisper.cpp:small-q5_1",
        };

        var transcript = new WhisperCppJsonTranscriptParser().Parse(
            Encoding.UTF8.GetBytes(json),
            request,
            transcriptId: "clip-ja-small",
            createdAt: createdAt);

        Assert.Equal("clip-ja-small", transcript.Id);
        Assert.Equal("ja", transcript.LanguageCode);
        Assert.Equal(0.88, transcript.LanguageConfidence);
        Assert.NotNull(transcript.DurationSeconds);
        Assert.Equal(1.5, transcript.DurationSeconds.Value, precision: 3);
        Assert.Equal(["梅雨", "が", "明ける"], transcript.Words.Select(word => word.Text).ToArray());
        Assert.Equal(0.0, transcript.Words[0].StartSeconds, precision: 3);
        Assert.Equal(0.6, transcript.Words[0].EndSeconds, precision: 3);
        Assert.Equal(0.76, transcript.Words[2].Probability);
        Assert.Equal("whisper.cpp:small-q5_1", transcript.SourceModelId);
        Assert.Equal(createdAt, transcript.CreatedAt);
    }

    [Fact]
    public void WhisperCppJsonParserFallsBackToSegmentTextWhenNoTokenWords()
    {
        const string json = """
        {
          "params": { "language": "ja" },
          "transcription": [
            {
              "text": " 新聞紙",
              "offsets": { "from": 200, "to": 1100 },
              "tokens": []
            }
          ]
        }
        """;
        var request = new AsrRequest { AudioPath = "/tmp/audio.wav", ModelId = "whisper.cpp:base" };

        var transcript = new WhisperCppJsonTranscriptParser().Parse(
            Encoding.UTF8.GetBytes(json),
            request,
            transcriptId: "fallback",
            createdAt: DateTimeOffset.UnixEpoch);

        Assert.Equal("ja", transcript.LanguageCode);
        Assert.NotNull(transcript.DurationSeconds);
        Assert.Equal(1.1, transcript.DurationSeconds.Value, precision: 3);
        Assert.Equal(
        [
            new AsrWord { Text = "新聞紙", StartSeconds = 0.2, EndSeconds = 1.1 },
        ], transcript.Words);
    }

    [Fact]
    public async Task WhisperCppRecognizerRunsCommandWritesCacheAndReportsProgress()
    {
        var directory = Path.Combine(Path.GetTempPath(), "moongate-asr-runner-" + Guid.NewGuid().ToString("N"));
        try
        {
            Directory.CreateDirectory(directory);
            var outputDirectory = Path.Combine(directory, "out");
            var cacheDirectory = Path.Combine(directory, "cache");
            var audio = Path.Combine(directory, "audio.wav");
            var model = Path.Combine(directory, "ggml-test.bin");
            var runtime = Path.Combine(directory, OperatingSystem.IsWindows() ? "whisper-cli.exe" : "whisper-cli");
            File.WriteAllText(audio, "audio fixture");
            File.WriteAllText(model, "model fixture");
            File.WriteAllText(runtime, "#!/bin/sh\n");
            if (!OperatingSystem.IsWindows())
            {
                File.SetUnixFileMode(runtime, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
            }

            var runner = new RecordingAsrCommandRunner((plan, onLine, _) =>
            {
                Directory.CreateDirectory(Path.GetDirectoryName(plan.OutputJsonPath)!);
                onLine("whisper.cpp progress: 25%");
                onLine("whisper.cpp progress: 100%");
                File.WriteAllText(plan.OutputJsonPath, """
                {
                  "result": { "language": "ja" },
                  "transcription": [
                    {
                      "text": " 梅雨 が 明ける",
                      "offsets": { "from": 0, "to": 1500 },
                      "tokens": [
                        { "text": " 梅雨", "offsets": { "from": 0, "to": 600 } },
                        { "text": " が", "offsets": { "from": 600, "to": 800 } },
                        { "text": " 明ける", "offsets": { "from": 800, "to": 1500 } }
                      ]
                    }
                  ]
                }
                """);
                return Task.FromResult(new AsrCommandResult { Status = 0, StderrTail = "" });
            });
            var recognizer = new WhisperCppSpeechRecognizer(
                new AsrRuntimeInfo { ExecutablePath = runtime },
                model,
                outputDirectory,
                new AsrTranscriptCacheStore(cacheDirectory),
                runner,
                () => DateTimeOffset.FromUnixTimeSeconds(1_785_300_000));
            var request = new AsrRequest
            {
                AudioPath = audio,
                LanguageCode = "ja",
                ModelId = "whisper.cpp:test",
                CacheKey = "clip-ja-local-asr",
            };
            var progress = new List<AsrProgress>();

            var first = await recognizer.TranscribeAsync(request, progress.Add);
            var second = await recognizer.TranscribeAsync(request, _ => { });

            Assert.Equal(1, runner.CallCount);
            Assert.Equal(["梅雨", "が", "明ける"], first.Words.Select(word => word.Text).ToArray());
            AssertTranscriptEqual(first, second);
            Assert.Equal(new double?[] { 0, 0.25, 1, 1 }, progress.Select(item => item.Fraction).ToArray());
            Assert.NotNull(new AsrTranscriptCacheStore(cacheDirectory).ReadEntry("clip-ja-local-asr"));
        }
        finally
        {
            if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public async Task WhisperCppLocalAsrSubtitleGeneratorExtractsTranscribesAndWritesSourceSrt()
    {
        var directory = Path.Combine(Path.GetTempPath(), "moongate-asr-generator-" + Guid.NewGuid().ToString("N"));
        try
        {
            Directory.CreateDirectory(directory);
            var workDirectory = Path.Combine(directory, "work");
            var outputDirectory = Path.Combine(directory, "out");
            var cacheDirectory = Path.Combine(directory, "cache");
            var video = Path.Combine(directory, "clip.mp4");
            var ffmpeg = Path.Combine(directory, OperatingSystem.IsWindows() ? "ffmpeg.exe" : "ffmpeg");
            var model = Path.Combine(directory, "ggml-test.bin");
            var runtime = Path.Combine(directory, OperatingSystem.IsWindows() ? "whisper-cli.exe" : "whisper-cli");
            File.WriteAllText(video, "video fixture");
            File.WriteAllText(ffmpeg, "#!/bin/sh\n");
            File.WriteAllText(model, "model fixture");
            File.WriteAllText(runtime, "#!/bin/sh\n");
            if (!OperatingSystem.IsWindows())
            {
                File.SetUnixFileMode(ffmpeg, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
                File.SetUnixFileMode(runtime, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
            }

            var audioExtractor = new RecordingAsrAudioExtractor((plan, progress, _) =>
            {
                progress(new AsrProgress { Phase = AsrProgressPhase.AudioExtract, CompletedUnits = 0.5, TotalUnits = 1 });
                Directory.CreateDirectory(Path.GetDirectoryName(plan.OutputPath)!);
                File.WriteAllText(plan.OutputPath, "wav fixture");
                return Task.FromResult(plan.OutputPath);
            });
            var runner = new RecordingAsrCommandRunner((plan, onLine, _) =>
            {
                Directory.CreateDirectory(Path.GetDirectoryName(plan.OutputJsonPath)!);
                onLine("whisper.cpp progress: 50%");
                File.WriteAllText(plan.OutputJsonPath, """
                {
                  "result": { "language": "ja" },
                  "transcription": [
                    {
                      "text": " 梅雨 が 明ける",
                      "offsets": { "from": 0, "to": 1500 },
                      "tokens": [
                        { "text": " 梅雨", "offsets": { "from": 0, "to": 600 } },
                        { "text": " が", "offsets": { "from": 600, "to": 800 } },
                        { "text": " 明ける。", "offsets": { "from": 800, "to": 1500 } }
                      ]
                    }
                  ]
                }
                """);
                return Task.FromResult(new AsrCommandResult { Status = 0, StderrTail = "" });
            });
            var recognizer = new WhisperCppSpeechRecognizer(
                new AsrRuntimeInfo { ExecutablePath = runtime },
                model,
                outputDirectory,
                new AsrTranscriptCacheStore(cacheDirectory),
                runner,
                () => DateTimeOffset.FromUnixTimeSeconds(1_785_400_000));
            var generator = new WhisperCppLocalAsrSubtitleGenerator(
                ffmpeg,
                workDirectory,
                recognizer,
                modelId: "whisper.cpp:test",
                promptProvider: (videoPath, languageCode) =>
                    $"title={Path.GetFileNameWithoutExtension(videoPath)}; lang={languageCode}",
                audioExtractor: audioExtractor);
            var progress = new List<AsrProgress>();

            var output = await generator.GenerateSourceSubtitleAsync(video, "ja", null, progress.Add);

            Assert.Equal("clip.local-asr.ja.srt", Path.GetFileName(output));
            var parsed = SrtTools.ParseSrt(File.ReadAllText(output));
            Assert.Equal(["梅雨が明ける。"], parsed.Select(cue => cue.Text).ToArray());
            Assert.Equal([video], audioExtractor.Plans.Select(plan => plan.InputPath).ToArray());
            Assert.Equal(ffmpeg, audioExtractor.Plans[0].FfmpegPath);
            Assert.Equal(1, runner.CallCount);
            var request = Assert.Single(runner.Plans).Request;
            Assert.Equal(audioExtractor.Plans[0].OutputPath, request.AudioPath);
            Assert.Equal("ja", request.LanguageCode);
            Assert.Equal("whisper.cpp:test", request.ModelId);
            Assert.Equal("title=clip; lang=ja", request.Prompt);
            Assert.NotNull(request.CacheKey);
            Assert.Contains(progress, item => item.Phase == AsrProgressPhase.AudioExtract);
            Assert.Contains(progress, item => item.Phase == AsrProgressPhase.SpeechRecognition);
            Assert.Equal(new AsrProgress
            {
                Phase = AsrProgressPhase.SubtitleSegment,
                CompletedUnits = 1,
                TotalUnits = 1,
            }, progress[^1]);
        }
        finally
        {
            if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public async Task WhisperCppLocalAsrSubtitleGeneratorReusesAutoTranscriptCache()
    {
        var directory = Path.Combine(Path.GetTempPath(), "moongate-asr-generator-cache-" + Guid.NewGuid().ToString("N"));
        try
        {
            Directory.CreateDirectory(directory);
            var workDirectory = Path.Combine(directory, "work");
            var outputDirectory = Path.Combine(directory, "out");
            var cacheDirectory = Path.Combine(directory, "cache");
            var video = Path.Combine(directory, "clip.mp4");
            var ffmpeg = Path.Combine(directory, OperatingSystem.IsWindows() ? "ffmpeg.exe" : "ffmpeg");
            var model = Path.Combine(directory, "ggml-test.bin");
            var runtime = Path.Combine(directory, OperatingSystem.IsWindows() ? "whisper-cli.exe" : "whisper-cli");
            File.WriteAllText(video, "video fixture");
            File.WriteAllText(ffmpeg, "#!/bin/sh\n");
            File.WriteAllText(model, "model fixture");
            File.WriteAllText(runtime, "#!/bin/sh\n");
            if (!OperatingSystem.IsWindows())
            {
                File.SetUnixFileMode(ffmpeg, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
                File.SetUnixFileMode(runtime, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
            }

            var audioExtractor = new RecordingAsrAudioExtractor((plan, _, _) =>
            {
                Directory.CreateDirectory(Path.GetDirectoryName(plan.OutputPath)!);
                File.WriteAllText(plan.OutputPath, "wav fixture");
                return Task.FromResult(plan.OutputPath);
            });
            var runner = new RecordingAsrCommandRunner((plan, _, _) =>
            {
                Directory.CreateDirectory(Path.GetDirectoryName(plan.OutputJsonPath)!);
                File.WriteAllText(plan.OutputJsonPath, """
                {
                  "result": { "language": "ja" },
                  "transcription": [
                    {
                      "text": " 梅雨 が 明ける",
                      "offsets": { "from": 0, "to": 1500 },
                      "tokens": [
                        { "text": " 梅雨", "offsets": { "from": 0, "to": 600 } },
                        { "text": " が", "offsets": { "from": 600, "to": 800 } },
                        { "text": " 明ける。", "offsets": { "from": 800, "to": 1500 } }
                      ]
                    }
                  ]
                }
                """);
                return Task.FromResult(new AsrCommandResult { Status = 0, StderrTail = "" });
            });
            var recognizer = new WhisperCppSpeechRecognizer(
                new AsrRuntimeInfo { ExecutablePath = runtime },
                model,
                outputDirectory,
                new AsrTranscriptCacheStore(cacheDirectory),
                runner,
                () => DateTimeOffset.FromUnixTimeSeconds(1_785_400_100));
            var generator = new WhisperCppLocalAsrSubtitleGenerator(
                ffmpeg,
                workDirectory,
                recognizer,
                modelId: "whisper.cpp:test",
                promptProvider: AsrPromptBuilder.DefaultPrompt,
                audioExtractor: audioExtractor);

            var firstOutput = await generator.GenerateSourceSubtitleAsync(video, "auto", null, _ => { });
            var secondProgress = new List<AsrProgress>();
            var secondOutput = await generator.GenerateSourceSubtitleAsync(video, "auto", null, secondProgress.Add);

            Assert.Equal(firstOutput, secondOutput);
            Assert.Equal("clip.local-asr.ja.srt", Path.GetFileName(secondOutput));
            Assert.Single(audioExtractor.Plans);
            Assert.Equal(1, runner.CallCount);
            var request = Assert.Single(runner.Plans).Request;
            Assert.Equal("auto", request.LanguageCode);
            Assert.Equal("title=clip", request.Prompt);
            Assert.Contains(new AsrProgress
            {
                Phase = AsrProgressPhase.SpeechRecognition,
                CompletedUnits = 1,
                TotalUnits = 1,
            }, secondProgress);
        }
        finally
        {
            if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public void LocalAsrGeneratorFactoryRequiresExplicitReadySettings()
    {
        var directory = Path.Combine(Path.GetTempPath(), "moongate-asr-factory-" + Guid.NewGuid().ToString("N"));
        try
        {
            Directory.CreateDirectory(directory);
            var ffmpeg = Path.Combine(directory, OperatingSystem.IsWindows() ? "ffmpeg.exe" : "ffmpeg");
            var runtime = Path.Combine(directory, OperatingSystem.IsWindows() ? "whisper-cli.exe" : "whisper-cli");
            var model = Path.Combine(directory, "ggml-small-q5_1.bin");
            File.WriteAllText(ffmpeg, "#!/bin/sh\n");
            File.WriteAllText(runtime, "#!/bin/sh\n");
            File.WriteAllText(model, "model fixture");
            if (!OperatingSystem.IsWindows())
            {
                File.SetUnixFileMode(ffmpeg, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
                File.SetUnixFileMode(runtime, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
            }
            var enabled = new AppSettings
            {
                LocalAsrEnabled = true,
                LocalAsrRuntimePath = runtime,
                LocalAsrModelPath = model,
                LocalAsrModelId = "custom:test",
            };

            Assert.Null(LocalAsrGeneratorFactory.Create(new AppSettings(), ffmpeg, directory));
            Assert.Null(LocalAsrGeneratorFactory.Create(enabled, null, directory));
            Assert.Null(LocalAsrGeneratorFactory.Create(enabled, Path.Combine(directory, "missing-ffmpeg"), directory));
            Assert.NotNull(LocalAsrGeneratorFactory.Create(enabled, ffmpeg, directory));
        }
        finally
        {
            if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public void LocalAsrGeneratorFactoryRejectsBadHashForRecommendedModel()
    {
        var directory = Path.Combine(Path.GetTempPath(), "moongate-asr-factory-bad-hash-" + Guid.NewGuid().ToString("N"));
        try
        {
            Directory.CreateDirectory(directory);
            var ffmpeg = Path.Combine(directory, OperatingSystem.IsWindows() ? "ffmpeg.exe" : "ffmpeg");
            var runtime = Path.Combine(directory, OperatingSystem.IsWindows() ? "whisper-cli.exe" : "whisper-cli");
            File.WriteAllText(ffmpeg, "#!/bin/sh\n");
            File.WriteAllText(runtime, "#!/bin/sh\n");
            if (!OperatingSystem.IsWindows())
            {
                File.SetUnixFileMode(ffmpeg, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
                File.SetUnixFileMode(runtime, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
            }
            var supportDirectory = Path.Combine(directory, "support");
            var store = new AsrModelStore(Path.Combine(supportDirectory, "asr", "models"));
            var model = AsrModelManifest.RecommendedWhisperCpp.Models[0];
            var installedPath = store.InstalledPath(model);
            Directory.CreateDirectory(Path.GetDirectoryName(installedPath)!);
            File.WriteAllText(installedPath, "wrong model payload");
            var enabled = new AppSettings
            {
                LocalAsrEnabled = true,
                LocalAsrRuntimePath = runtime,
                LocalAsrModelPath = installedPath,
                LocalAsrModelId = model.Id,
            };

            Assert.Null(LocalAsrGeneratorFactory.Create(enabled, ffmpeg, supportDirectory));
        }
        finally
        {
            if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public async Task WhisperCppRecognizerPropagatesCancellationAndDoesNotCache()
    {
        var directory = Path.Combine(Path.GetTempPath(), "moongate-asr-cancel-" + Guid.NewGuid().ToString("N"));
        try
        {
            Directory.CreateDirectory(directory);
            var audio = Path.Combine(directory, "audio.wav");
            var model = Path.Combine(directory, "ggml-test.bin");
            var runtime = Path.Combine(directory, OperatingSystem.IsWindows() ? "whisper-cli.exe" : "whisper-cli");
            File.WriteAllText(audio, "audio fixture");
            File.WriteAllText(model, "model fixture");
            File.WriteAllText(runtime, "#!/bin/sh\n");
            if (!OperatingSystem.IsWindows())
            {
                File.SetUnixFileMode(runtime, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
            }
            var cache = new AsrTranscriptCacheStore(Path.Combine(directory, "cache"));
            var recognizer = new WhisperCppSpeechRecognizer(
                new AsrRuntimeInfo { ExecutablePath = runtime },
                model,
                Path.Combine(directory, "out"),
                cache,
                new RecordingAsrCommandRunner((_, _, ct) => Task.FromCanceled<AsrCommandResult>(ct.IsCancellationRequested
                    ? ct
                    : new CancellationToken(canceled: true))));
            var request = new AsrRequest
            {
                AudioPath = audio,
                LanguageCode = "ja",
                ModelId = "whisper.cpp:test",
                CacheKey = "cancelled",
            };

            await Assert.ThrowsAnyAsync<OperationCanceledException>(() => recognizer.TranscribeAsync(request, _ => { }));
            Assert.Null(cache.ReadEntry("cancelled"));
        }
        finally
        {
            if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public async Task WhisperCppRecognizerRejectsNonZeroExit()
    {
        var directory = Path.Combine(Path.GetTempPath(), "moongate-asr-exit-" + Guid.NewGuid().ToString("N"));
        try
        {
            Directory.CreateDirectory(directory);
            var audio = Path.Combine(directory, "audio.wav");
            var model = Path.Combine(directory, "ggml-test.bin");
            var runtime = Path.Combine(directory, OperatingSystem.IsWindows() ? "whisper-cli.exe" : "whisper-cli");
            File.WriteAllText(audio, "audio fixture");
            File.WriteAllText(model, "model fixture");
            File.WriteAllText(runtime, "#!/bin/sh\n");
            if (!OperatingSystem.IsWindows())
            {
                File.SetUnixFileMode(runtime, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
            }
            var recognizer = new WhisperCppSpeechRecognizer(
                new AsrRuntimeInfo { ExecutablePath = runtime },
                model,
                Path.Combine(directory, "out"),
                commandRunner: new RecordingAsrCommandRunner((_, _, _) =>
                    Task.FromResult(new AsrCommandResult { Status = 2, StderrTail = "bad model" })));

            var error = await Assert.ThrowsAsync<WhisperCppRecognizerException>(() =>
                recognizer.TranscribeAsync(new AsrRequest { AudioPath = audio, ModelId = "whisper.cpp:test" }, _ => { }));
            Assert.Equal(WhisperCppRecognizerError.ProcessFailed, error.Reason);
            Assert.Equal(2, error.Status);
            Assert.Equal("bad model", error.StderrTail);
        }
        finally
        {
            if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true);
        }
    }

    private static void AssertTranscriptEqual(AsrTranscript expected, AsrTranscript? actual)
    {
        Assert.NotNull(actual);
        Assert.Equal(expected.Id, actual.Id);
        Assert.Equal(expected.LanguageCode, actual.LanguageCode);
        Assert.Equal(expected.LanguageConfidence, actual.LanguageConfidence);
        Assert.Equal(expected.DurationSeconds, actual.DurationSeconds);
        Assert.Equal(expected.SourceModelId, actual.SourceModelId);
        Assert.Equal(expected.CreatedAt, actual.CreatedAt);
        Assert.Equal(expected.Words.Count, actual.Words.Count);
        for (var index = 0; index < expected.Words.Count; index += 1)
        {
            Assert.Equal(expected.Words[index], actual.Words[index]);
        }
    }

    private sealed class RecordingAsrCommandRunner(
        Func<WhisperCppCommandPlan, Action<string>, CancellationToken, Task<AsrCommandResult>> handler)
        : IAsrCommandRunner
    {
        private int _callCount;
        private readonly object _lock = new();
        private readonly List<WhisperCppCommandPlan> _plans = [];

        public int CallCount => Volatile.Read(ref _callCount);
        public IReadOnlyList<WhisperCppCommandPlan> Plans
        {
            get { lock (_lock) return [.. _plans]; }
        }

        public Task<AsrCommandResult> RunWhisperAsync(
            WhisperCppCommandPlan plan,
            TaskControlToken? control,
            Action<string> onLine,
            CancellationToken ct = default)
        {
            Interlocked.Increment(ref _callCount);
            lock (_lock) _plans.Add(plan);
            return handler(plan, onLine, ct);
        }
    }

    private sealed class FakeAsrModelDownloadClient(byte[] payload) : IAsrModelDownloadClient
    {
        public sealed record Request(string ModelId, string DestinationPath);

        private readonly object _lock = new();
        private readonly List<Request> _requests = [];

        public IReadOnlyList<Request> Requests
        {
            get { lock (_lock) return [.. _requests]; }
        }

        public Task DownloadModelAsync(
            AsrModelInfo model,
            string destinationPath,
            Action<AsrProgress> progress,
            CancellationToken ct = default)
        {
            ct.ThrowIfCancellationRequested();
            lock (_lock) _requests.Add(new Request(model.Id, destinationPath));
            progress(new AsrProgress
            {
                Phase = AsrProgressPhase.ModelDownload,
                CompletedUnits = 0,
                TotalUnits = model.SizeBytes,
            });
            Directory.CreateDirectory(Path.GetDirectoryName(destinationPath) ?? ".");
            File.WriteAllBytes(destinationPath, payload);
            progress(new AsrProgress
            {
                Phase = AsrProgressPhase.ModelDownload,
                CompletedUnits = payload.Length,
                TotalUnits = model.SizeBytes,
            });
            return Task.CompletedTask;
        }
    }

    private sealed class RecordingAsrAudioExtractor(
        Func<AsrAudioExtractionPlan, Action<AsrProgress>, CancellationToken, Task<string>> handler)
        : IAsrAudioExtractor
    {
        private readonly object _lock = new();
        private readonly List<AsrAudioExtractionPlan> _plans = [];

        public IReadOnlyList<AsrAudioExtractionPlan> Plans
        {
            get { lock (_lock) return [.. _plans]; }
        }

        public Task<string> ExtractAudioAsync(
            AsrAudioExtractionPlan plan,
            TaskControlToken? control,
            Action<AsrProgress> progress,
            CancellationToken ct = default)
        {
            lock (_lock) _plans.Add(plan);
            return handler(plan, progress, ct);
        }
    }
}
