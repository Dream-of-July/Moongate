using System.Text;
using System.Text.Json;
using Moongate.Core;

namespace MoongateCore.Tests;

public class AsrContractsTests
{
    [Fact]
    public void VadDisabledForLyricsProfileButEnabledForSpeech()
    {
        // VAD 对歌唱/音乐灾难性失效（silero 丢大部分音频），故歌词档必须关闭、演讲档保留。实测见 M3。
        Assert.False(AsrPromptBuilder.VadEnabled(AsrRecognitionProfile.LyricsHighQuality));
        Assert.True(AsrPromptBuilder.VadEnabled(AsrRecognitionProfile.Speech));
    }

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
            BackendKind = AsrBackendKind.WhisperCpp,
            Segments =
            [
                new AsrSegment { Text = "梅雨が明ける", StartSeconds = 0, EndSeconds = 1.5 },
            ],
            RawText = "梅雨が明ける",
            BackendDiagnostics = new Dictionary<string, string> { ["dtw"] = "enabled" },
            QualitySummary = new LocalAsrConfidenceSummary(3, 0.84, 0, false),
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
        Assert.Contains("\"backendKind\":\"whisperCpp\"", transcriptJson, StringComparison.Ordinal);
        Assert.DoesNotContain("SourceModelId", transcriptJson, StringComparison.Ordinal);
        using (var transcriptDoc = JsonDocument.Parse(transcriptJson))
        {
            Assert.Equal("梅雨が明ける", transcriptDoc.RootElement.GetProperty("rawText").GetString());
        }
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
    public void TranscriptDecodesLegacyPayloadWithBackendDefaults()
    {
        var transcript = JsonSerializer.Deserialize<AsrTranscript>(
            """
            {
              "id": "legacy",
              "languageCode": "ja",
              "words": [
                { "text": "雨", "startSeconds": 0.0, "endSeconds": 0.3 }
              ],
              "sourceModelId": "whisper.cpp:small-q5_1",
              "createdAt": "2026-06-27T00:00:00Z"
            }
            """,
            AsrJson.Options);

        Assert.NotNull(transcript);
        Assert.Equal(AsrBackendKind.WhisperCpp, transcript!.BackendKind);
        Assert.Empty(transcript.Segments);
        Assert.Null(transcript.RawText);
        Assert.Empty(transcript.BackendDiagnostics);
        Assert.Null(transcript.QualitySummary);
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
    public void WhisperCppProgressParserOnlyMatchesProgressLinesNotTranscriptText()
    {
        // 真实 whisper.cpp 进度行应解析出进度（兼容 `=`/`:` 两种版本分隔符）。
        var p1 = WhisperCppProgressParser.Parse("whisper_print_progress_callback: progress =  50%");
        Assert.NotNull(p1);
        Assert.Equal(50, p1!.CompletedUnits);
        Assert.Equal(100, p1.TotalUnits);
        var p2 = WhisperCppProgressParser.Parse("whisper.cpp progress: 25%");
        Assert.NotNull(p2);
        Assert.Equal(25, p2!.CompletedUnits);
        var p3 = WhisperCppProgressParser.Parse("progress = 100%");
        Assert.NotNull(p3);
        Assert.Equal(100, p3!.CompletedUnits);
        // 回归 BUG-B：含 % 但无 “progress” 关键字的转写台词文本不应被误判为进度（否则进度条会随台词来回乱跳）。
        Assert.Null(WhisperCppProgressParser.Parse("[00:00:01.000 --> 00:00:03.000]  sales were up 50% this year"));
        Assert.Null(WhisperCppProgressParser.Parse("彼は「100%確実だ」と言った"));
        Assert.Null(WhisperCppProgressParser.Parse("no percent here"));
    }

    [Fact]
    public void WhisperTimingConstantsMatchCrossPlatformFixture()
    {
        // ARCH-3：与 Swift 端共享同一份 fixture 作为唯一真值。两端各断言本端常量等于它；
        // 任一端改动 whisper 时序常量都会让该端失败，强制同步另一端与 fixture，把 parity 从巧合变结构。
        var path = Path.Combine(RepoRoot(), "Tests", "fixtures", "whisper-timing-constants.json");
        using var doc = JsonDocument.Parse(File.ReadAllText(path));
        var root = doc.RootElement;
        Assert.Equal(WhisperCueRetimer.OnsetDelaySeconds, root.GetProperty("onsetDelaySeconds").GetDouble());
        Assert.Equal(WhisperCueRetimer.InterCueGuardSeconds, root.GetProperty("interCueGuardSeconds").GetDouble());
        Assert.Equal(WhisperCueRetimer.HoldToNextSeconds, root.GetProperty("holdToNextSeconds").GetDouble());
        Assert.Equal(WhisperCueRetimer.MixedCjkLatinHoldToNextSeconds, root.GetProperty("mixedCjkLatinHoldToNextSeconds").GetDouble());
        Assert.Equal(LocalAsrSubtitleTimingPlanner.MinimumCueSeconds, root.GetProperty("minimumCueSeconds").GetDouble());

        // 每个 timing profile 的阈值表也必须等于 fixture 的 profiles 段（ARCH-3，逐档逐字段）。
        var profiles = root.GetProperty("profiles");
        static double ProfileValue(JsonElement profiles, string profile, string key) =>
            // residualMaxStandaloneSeconds 在 speech 档省略，表示无约束（double.MaxValue）。
            profiles.GetProperty(profile).TryGetProperty(key, out var element)
                ? element.GetDouble()
                : double.MaxValue;
        foreach (var (name, profile) in new[]
        {
            ("speech", SubtitleTimingProfile.Speech),
            ("lyrics", SubtitleTimingProfile.Lyrics),
            ("japaneseLyrics", SubtitleTimingProfile.JapaneseLyrics),
            ("anime", SubtitleTimingProfile.Anime),
        })
        {
            var t = LocalAsrSubtitleTimingPlanner.Thresholds(profile);
            Assert.Equal(ProfileValue(profiles, name, "maximumCJKCueSeconds"), t.MaximumCjkCueSeconds);
            Assert.Equal(ProfileValue(profiles, name, "hardMaximumCJKCueSeconds"), t.HardMaximumCjkCueSeconds);
            Assert.Equal(ProfileValue(profiles, name, "relaxedCJKCueSeconds"), t.RelaxedCjkCueSeconds);
            Assert.Equal(ProfileValue(profiles, name, "maximumLatinCueSeconds"), t.MaximumLatinCueSeconds);
            Assert.Equal(ProfileValue(profiles, name, "largeSpeechGapSeconds"), t.LargeSpeechGapSeconds);
            Assert.Equal(ProfileValue(profiles, name, "onsetDelaySeconds"), t.OnsetDelaySeconds);
            Assert.Equal(ProfileValue(profiles, name, "holdToNextSeconds"), t.HoldToNextSeconds);
            Assert.Equal(ProfileValue(profiles, name, "residualMaxStandaloneSeconds"), t.ResidualMaxStandaloneSeconds);
            Assert.Equal(ProfileValue(profiles, name, "breathGapBreakSeconds"), t.BreathGapBreakSeconds);
        }
        // speech 档必须等于顶层标量常量（零行为退化的结构保证）。
        var speech = LocalAsrSubtitleTimingPlanner.Thresholds(SubtitleTimingProfile.Speech);
        Assert.Equal(WhisperCueRetimer.OnsetDelaySeconds, speech.OnsetDelaySeconds);
        Assert.Equal(WhisperCueRetimer.HoldToNextSeconds, speech.HoldToNextSeconds);
        Assert.Equal(LocalAsrSubtitleTimingPlanner.MaximumCjkCueSeconds, speech.MaximumCjkCueSeconds);
        Assert.Equal(LocalAsrSubtitleTimingPlanner.HardMaximumCjkCueSeconds, speech.HardMaximumCjkCueSeconds);
        Assert.Equal(LocalAsrSubtitleTimingPlanner.RelaxedCjkCueSeconds, speech.RelaxedCjkCueSeconds);
        Assert.Equal(LocalAsrSubtitleTimingPlanner.MaximumLatinCueSeconds, speech.MaximumLatinCueSeconds);
    }

    [Fact]
    public void SubtitleSourceDecisionConstantsMatchCrossPlatformFixture()
    {
        // ARCH-3：引擎排名/裁决常量两端共享 fixture subtitleSourceDecision 段为唯一真值。
        var path = Path.Combine(RepoRoot(), "Tests", "fixtures", "whisper-timing-constants.json");
        using var doc = JsonDocument.Parse(File.ReadAllText(path));
        var s = doc.RootElement.GetProperty("subtitleSourceDecision");

        var baseScore = s.GetProperty("baseScore");
        var rank = s.GetProperty("sourceKindRank");
        var kinds = new (SubtitleSourceKind Kind, string Key)[]
        {
            (SubtitleSourceKind.Manual, "manual"),
            (SubtitleSourceKind.ImportedFile, "importedFile"),
            (SubtitleSourceKind.HlsManifest, "hlsManifest"),
            (SubtitleSourceKind.CloudAsr, "cloudASR"),
            (SubtitleSourceKind.PlatformAuto, "platformAuto"),
            (SubtitleSourceKind.LocalAsr, "localASR"),
        };
        foreach (var (kind, key) in kinds)
        {
            Assert.Equal(baseScore.GetProperty(key).GetDouble(), SubtitleQualityScorer.BaseScore(kind));
            Assert.Equal(rank.GetProperty(key).GetInt32(), SubtitleSourceDecisionEngine.SourceKindRank(kind));
        }

        var boost = s.GetProperty("policyBoost");
        var prefer = boost.GetProperty("prefer").GetDouble();
        var force = boost.GetProperty("force").GetDouble();
        Assert.Equal(prefer, SubtitleSourceDecisionEngine.PolicyBoost(SubtitleSourceKind.PlatformAuto, SubtitleSourcePolicy.PreferPlatform));
        Assert.Equal(prefer, SubtitleSourceDecisionEngine.PolicyBoost(SubtitleSourceKind.LocalAsr, SubtitleSourcePolicy.PreferLocalAsr));
        Assert.Equal(force, SubtitleSourceDecisionEngine.PolicyBoost(SubtitleSourceKind.LocalAsr, SubtitleSourcePolicy.ForceLocalAsr));

        var vt = s.GetProperty("verdictThresholds");
        Assert.Equal(vt.GetProperty("excellent").GetDouble(), SubtitleQualityScorer.VerdictThresholds.Excellent);
        Assert.Equal(vt.GetProperty("good").GetDouble(), SubtitleQualityScorer.VerdictThresholds.Good);
        Assert.Equal(vt.GetProperty("usable").GetDouble(), SubtitleQualityScorer.VerdictThresholds.Usable);
        Assert.Equal(vt.GetProperty("lowConfidence").GetDouble(), SubtitleQualityScorer.VerdictThresholds.LowConfidence);

        // autoBestRegenerateBelow（具名质量地板，取代旧双裁决 OR）
        Assert.Equal("usable", s.GetProperty("autoBestRegenerateBelow").GetString());
        Assert.Equal(SubtitleQualityVerdict.Usable, SubtitleSourceDecisionEngine.AutoBestRegenerateBelow);
    }

    [Fact]
    public void LocalAsrConfidenceConstantsMatchFixtureAndAssess()
    {
        var path = Path.Combine(RepoRoot(), "Tests", "fixtures", "whisper-timing-constants.json");
        using var doc = JsonDocument.Parse(File.ReadAllText(path));
        var section = doc.RootElement.GetProperty("localASRConfidence");
        Assert.Equal(LocalAsrConfidence.AverageProbabilityFloor, section.GetProperty("averageProbabilityFloor").GetDouble());
        Assert.Equal(LocalAsrConfidence.LowConfidenceWordProbability, section.GetProperty("lowConfidenceWordProbability").GetDouble());
        Assert.Equal(LocalAsrConfidence.LowConfidenceWordRatioCeiling, section.GetProperty("lowConfidenceWordRatioCeiling").GetDouble());
        Assert.Equal(LocalAsrConfidence.MinimumAssessableWordCount, section.GetProperty("minimumAssessableWordCount").GetInt32());
        Assert.Equal(LocalAsrConfidence.StretchedCjkTokenSecondsFloor, section.GetProperty("stretchedCJKTokenSecondsFloor").GetDouble());
        Assert.Equal(LocalAsrConfidence.StretchedCjkTokenClusterCount, section.GetProperty("stretchedCJKTokenClusterCount").GetInt32());
        Assert.Equal(LocalAsrConfidence.StretchedCjkLowProbabilityCeiling, section.GetProperty("stretchedCJKLowProbabilityCeiling").GetDouble());

        static List<AsrWord> Words(double probability, int count) =>
            Enumerable.Range(0, count)
                .Select(_ => new AsrWord { Text = "あ", StartSeconds = 0, EndSeconds = 0.1, Probability = probability })
                .ToList();

        Assert.False(LocalAsrConfidence.Assess(Words(0.95, 30)).IsLowConfidence);          // clean
        var garbled = Words(0.3, 8).Concat(Words(0.9, 22)).ToList();                        // avg≈0.74, lowRatio≈0.27
        Assert.True(LocalAsrConfidence.Assess(garbled).IsLowConfidence);
        Assert.False(LocalAsrConfidence.Assess(Words(0.2, 10)).IsLowConfidence);            // too few words
        var borderline = Words(0.4, 3).Concat(Words(0.9, 27)).ToList();                     // avg≈0.85, lowRatio 0.1
        Assert.False(LocalAsrConfidence.Assess(borderline).IsLowConfidence);

        var confidentWrongScript = Enumerable.Range(0, 30)
            .Select(_ => new AsrWord { Text = "baby", StartSeconds = 0, EndSeconds = 0.1, Probability = 0.95 })
            .ToList();
        var summary = LocalAsrConfidence.Assess(confidentWrongScript, "ko");
        Assert.False(summary.IsLowConfidence);
        Assert.True(summary.IsLowQuality);
        Assert.Contains("scriptMismatch", summary.QualityIssues);

        var repeatedLoop = Enumerable.Range(0, 36)
            .Select(_ => new AsrWord { Text = "ね", StartSeconds = 0, EndSeconds = 0.1, Probability = 0.96 })
            .ToList();
        var loopSummary = LocalAsrConfidence.Assess(repeatedLoop, "ja");
        Assert.False(loopSummary.IsLowConfidence);
        Assert.True(loopSummary.IsLowQuality);
        Assert.Contains("repetitionLoop", loopSummary.QualityIssues);
        Assert.Contains("lowDiversity", loopSummary.QualityIssues);

        var autoEnglishLoopSegments = new[]
        {
            new AsrSegment { Text = "*Korin*", StartSeconds = 0, EndSeconds = 2 },
            new AsrSegment { Text = "*Korin*", StartSeconds = 30, EndSeconds = 32 },
            new AsrSegment { Text = "*Korin*", StartSeconds = 60, EndSeconds = 62 },
        };
        var autoEnglishLoopWords = autoEnglishLoopSegments
            .Select(segment => new AsrWord
            {
                Text = segment.Text,
                StartSeconds = segment.StartSeconds,
                EndSeconds = segment.EndSeconds,
                Probability = 0.95,
            })
            .ToList();
        var autoEnglishLoopSummary = LocalAsrConfidence.Assess(
            autoEnglishLoopWords,
            "en",
            autoEnglishLoopSegments,
            requestedLanguageCode: "auto",
            languageHintCode: "ja");
        Assert.True(autoEnglishLoopSummary.HasSevereQualityBlocker);
        Assert.Contains("autoLanguageMismatch", autoEnglishLoopSummary.QualityIssues);
        Assert.Contains("lowSegmentDiversity", autoEnglishLoopSummary.QualityIssues);
        Assert.Equal(1, autoEnglishLoopSummary.DominantPhraseRatio, precision: 4);

        var phraseLoopSegments = Enumerable.Range(0, 7)
            .Select(index => new AsrSegment
            {
                Text = "気持ちいいですか?",
                StartSeconds = 22 + index * 5,
                EndSeconds = 24 + index * 5,
            })
            .ToList();
        var phraseLoopWords = phraseLoopSegments
            .Select(segment => new AsrWord
            {
                Text = segment.Text,
                StartSeconds = segment.StartSeconds,
                EndSeconds = segment.EndSeconds,
                Probability = 0.96,
            })
            .ToList();
        var phraseLoopSummary = LocalAsrConfidence.Assess(
            phraseLoopWords,
            "ja",
            phraseLoopSegments,
            requestedLanguageCode: "ja",
            languageHintCode: "ja");
        Assert.True(phraseLoopSummary.HasSevereQualityBlocker);
        Assert.Contains("phraseLoop", phraseLoopSummary.QualityIssues);

        var fragmentedLoopSegments = new[]
        {
            new AsrSegment { Text = "お同じく", StartSeconds = 136.54, EndSeconds = 138.68 },
            new AsrSegment { Text = "お同じく", StartSeconds = 139.44, EndSeconds = 140.30 },
            new AsrSegment { Text = "おく同じお同じおく同", StartSeconds = 140.58, EndSeconds = 145.28 },
            new AsrSegment { Text = "じくお同じ", StartSeconds = 148.44, EndSeconds = 150.76 },
            new AsrSegment { Text = "くお", StartSeconds = 152.46, EndSeconds = 153.62 },
            new AsrSegment { Text = "同じくお同じく", StartSeconds = 155.92, EndSeconds = 158.48 },
        };
        var fragmentedLoopWords = fragmentedLoopSegments
            .Select(segment => new AsrWord
            {
                Text = segment.Text,
                StartSeconds = segment.StartSeconds,
                EndSeconds = segment.EndSeconds,
                Probability = 0.96,
            })
            .ToList();
        var fragmentedLoopSummary = LocalAsrConfidence.Assess(
            fragmentedLoopWords,
            "ja",
            fragmentedLoopSegments,
            requestedLanguageCode: "ja",
            languageHintCode: "ja");
        Assert.True(fragmentedLoopSummary.HasSevereQualityBlocker);
        Assert.Contains("phraseLoop", fragmentedLoopSummary.QualityIssues);
        Assert.Contains("lowSegmentDiversity", fragmentedLoopSummary.QualityIssues);

        var existingSrtSummary = LocalAsrConfidence.AssessSubtitle(
            """
            25
            00:02:16,540 --> 00:02:18,680
            お同じく

            26
            00:02:19,440 --> 00:02:20,300
            お同じく

            27
            00:02:20,580 --> 00:02:25,280
            おく同じお同じおく同

            28
            00:02:28,440 --> 00:02:30,760
            じくお同じ

            29
            00:02:32,460 --> 00:02:33,620
            くお

            30
            00:02:35,920 --> 00:02:38,480
            同じくお同じく
            """,
            "clip.local-asr.ja.srt",
            "ja",
            requestedLanguageCode: "ja",
            languageHintCode: "ja");
        Assert.True(existingSrtSummary.HasSevereQualityBlocker);
        Assert.Contains("phraseLoop", existingSrtSummary.QualityIssues);
        Assert.Contains("lowSegmentDiversity", existingSrtSummary.QualityIssues);

        var nearEmptySrtSummary = LocalAsrConfidence.AssessSubtitle(
            """
            1
            00:00:00,400 --> 00:00:01,530
            あ
            """,
            "clip.local-asr.ja.srt",
            "ja",
            requestedLanguageCode: "ja",
            languageHintCode: "ja");
        Assert.True(nearEmptySrtSummary.IsLowQuality);
        Assert.True(nearEmptySrtSummary.HasSevereQualityBlocker);
        Assert.Contains("nearEmptyTranscript", nearEmptySrtSummary.QualityIssues);

        // Cross-platform parity: invisible Unicode Format marks (U+200F RLM etc.) must not count as
        // meaningful characters, matching Swift controlCharacters (Cc+Cf).
        var arabicFormatMarkSummary = LocalAsrConfidence.AssessSubtitle(
            "1\n00:00:00,400 --> 00:00:01,530\nم\u200F\u200F\u200F",
            "clip.local-asr.ar.srt",
            "ar",
            requestedLanguageCode: "ar",
            languageHintCode: "ar");
        Assert.Contains("nearEmptyTranscript", arabicFormatMarkSummary.QualityIssues);

        string[] healthyTokens = ["青", "い", "空", "を", "見", "る", "君", "と", "歩", "く", "道", "で"];
        var healthyRepeated = Enumerable.Range(0, 36)
            .Select(index => new AsrWord
            {
                Text = healthyTokens[index % healthyTokens.Length],
                StartSeconds = 0,
                EndSeconds = 0.1,
                Probability = 0.96,
            })
            .ToList();
        var healthySummary = LocalAsrConfidence.Assess(healthyRepeated, "ja");
        Assert.False(healthySummary.IsLowQuality);
        Assert.Empty(healthySummary.QualityIssues);

        AsrWord TimedWord(string text, double start, double end, double probability) => new()
        {
            Text = text,
            StartSeconds = start,
            EndSeconds = end,
            Probability = probability,
        };

        var stretchedLowConfidence = new[]
        {
            TimedWord("착", 1.91, 5.13, 0.02),
            TimedWord("한", 5.14, 10.24, 0.99),
            TimedWord("얼굴에", 10.24, 25.60, 0.96),
        }.Concat(Enumerable.Range(0, 30)
            .Select(index => TimedWord($"노래{index}", 26 + index * 0.4, 26.2 + index * 0.4, 0.95)))
            .ToList();
        var stretchedSummary = LocalAsrConfidence.Assess(stretchedLowConfidence, "ko");
        Assert.False(stretchedSummary.IsLowConfidence);
        Assert.True(stretchedSummary.IsLowQuality);
        Assert.Contains("stretchedLowConfidenceCJKToken", stretchedSummary.QualityIssues);

        var healthyStretched = new[]
        {
            TimedWord("な", 2.0, 4.8, 0.94),
            TimedWord("い", 8.0, 11.2, 0.96),
            TimedWord("君", 20.0, 23.4, 0.91),
        }.Concat(Enumerable.Range(0, 30)
            .Select(index => TimedWord($"歌{index}", 30 + index * 0.4, 30.2 + index * 0.4, 0.95)))
            .ToList();
        var healthyStretchedSummary = LocalAsrConfidence.Assess(healthyStretched, "ja");
        Assert.False(healthyStretchedSummary.IsLowQuality);
        Assert.DoesNotContain("stretchedLowConfidenceCJKToken", healthyStretchedSummary.QualityIssues);
    }

    // Identical to Swift cjkBoundaryParityCases — the two platforms must agree on these so the
    // macOS NaturalLanguage tokenizer and the Windows script-run segmenter never silently diverge.
    public static readonly (string Text, int Offset, bool Expected)[] CjkBoundaryParityCases =
    [
        ("カード", 2, true),
        ("hello", 2, true),
        ("1234", 2, true),
        ("動く", 1, true),
        ("カードを", 3, false),
        ("ABC始", 3, false),
        ("食べた今", 3, false),
    ];

    [Fact]
    public void CjkWordBoundaryMatchesParityTable()
    {
        foreach (var (text, offset, expected) in CjkBoundaryParityCases)
        {
            Assert.Equal(expected, CjkWordBoundary.Straddles(text, offset));
        }
    }

    private static SubtitleCue SrtCue(int index, double start, double end, string text) =>
        new(index, SrtTools.SecondsToSrtTime(start), SrtTools.SecondsToSrtTime(end), text, []);

    [Fact]
    public void BreathGapBreaksLongRunAtSilence()
    {
        // One continuous kana run: every internal junction is mid-word, so without a gap the planner
        // extends past the soft ceiling to the hard ceiling. A breath gap placed right as the soft
        // ceiling is crossed anchors the first break there instead (stable-ts breath anchor).
        static string FirstCueText(bool gapAtJunction)
        {
            var frags = new List<SubtitleCueSourceFragment>();
            var t = 0.0;
            for (var i = 0; i < 20; i++)
            {
                if (gapAtJunction && i == 11) t += 0.5;
                frags.Add(new SubtitleCueSourceFragment(t, t + 0.4, "あ"));
                t += 0.4;
            }
            var cues = LocalAsrSubtitleTimingPlanner.PlanCues(frags, null, SubtitleTimingProfile.Speech);
            return cues.Count > 0 ? cues[0].Text : "";
        }
        var withGap = FirstCueText(true);
        var noGap = FirstCueText(false);
        Assert.NotEmpty(withGap);
        Assert.NotEmpty(noGap);
        // With the Windows CJK tokenizer (M5), mid-word junctions extend to the hard ceiling without
        // a gap; a breath gap anchors the first break earlier at the silence.
        Assert.True(withGap.Length < noGap.Length, "breath gap should anchor the first break earlier than the hard-ceiling break");
    }

    [Fact]
    public void TimingProfileDetectorRoutesByFilenameAndShape()
    {
        Assert.Equal(SubtitleTimingProfile.Lyrics, SubtitleTimingProfileDetector.Detect("Artist - Title (Official MV).mp4", []));
        Assert.Equal(
            SubtitleTimingProfile.JapaneseLyrics,
            SubtitleTimingProfileDetector.Detect("YOASOBI Official Music Video.local-asr.ja.srt", [], "ja"));
        Assert.Equal(SubtitleTimingProfile.Anime, SubtitleTimingProfileDetector.Detect("Some Anime EP.12.mkv", []));

        var lyricCues = new List<SubtitleCue>();
        var t = 0.0;
        for (var i = 0; i < 24; i++)
        {
            lyricCues.Add(SrtCue(i + 1, t, t + 4.0, $"歌詞のフレーズ {i}"));
            t += 4.0 + 1.4;
        }
        Assert.Equal(SubtitleTimingProfile.JapaneseLyrics, SubtitleTimingProfileDetector.Detect("live.mp4", lyricCues));
        Assert.Equal(SubtitleTimingProfile.JapaneseLyrics, SubtitleTimingProfileDetector.Detect("live.mp4", lyricCues, "en"));

        var speechCues = new List<SubtitleCue>();
        t = 0.0;
        for (var i = 0; i < 24; i++)
        {
            speechCues.Add(SrtCue(i + 1, t, t + 3.5, $"This is a full explanatory sentence number {i}."));
            t += 3.6;
        }
        Assert.Equal(SubtitleTimingProfile.Speech, SubtitleTimingProfileDetector.Detect("lecture.mp4", speechCues));
    }

    [Fact]
    public void AnimeFilenameHeuristicRequiresDigitAdjacentEpisodeMarkers()
    {
        // Strong keywords still route to anime.
        Assert.Equal(SubtitleTimingProfile.Anime, SubtitleTimingProfileDetector.Detect("アニメ OP.mp4", []));
        Assert.Equal(SubtitleTimingProfile.Anime, SubtitleTimingProfileDetector.Detect("新番动画 PV.mp4", []));

        // Digit-adjacent episode markers (incl. fullwidth digits) route to anime.
        Assert.Equal(SubtitleTimingProfile.Anime, SubtitleTimingProfileDetector.Detect("Spy Family 第12話.mkv", []));
        Assert.Equal(SubtitleTimingProfile.Anime, SubtitleTimingProfileDetector.Detect("番剧 第３话.mp4", []));
        Assert.Equal(SubtitleTimingProfile.Anime, SubtitleTimingProfileDetector.Detect("Episode 5 Recap.mkv", []));
        Assert.Equal(SubtitleTimingProfile.Anime, SubtitleTimingProfileDetector.Detect("show EP.12 highlights.mkv", []));

        // Bare 第 / 话 / 話 without an adjacent number must NOT be treated as anime anymore.
        Assert.Equal(SubtitleTimingProfile.Speech, SubtitleTimingProfileDetector.Detect("第一财经 产品评测.mp4", []));
        Assert.Equal(SubtitleTimingProfile.Speech, SubtitleTimingProfileDetector.Detect("今天的话题讨论.mp4", []));
        // "ep" embedded mid-word must not false-positive on a trailing number.
        Assert.Equal(SubtitleTimingProfile.Speech, SubtitleTimingProfileDetector.Detect("deep dive 3.mp4", []));
        Assert.Equal(SubtitleTimingProfile.Speech, SubtitleTimingProfileDetector.Detect("keep calm 2024.mp4", []));
    }

    [Fact]
    public void LyricsProfileSplitsTighterThanSpeech()
    {
        var words = Enumerable.Range(0, 13)
            .Select(i => new AsrWord { Text = "うた", StartSeconds = i * 0.4, EndSeconds = i * 0.4 + 0.4 })
            .ToList();
        var transcript = new AsrTranscript { Id = "l", LanguageCode = "ja", Words = words, SourceModelId = "whisper.cpp:test" };
        var speech = AsrTranscriptMapper.SourceCues(transcript, SubtitleTimingProfile.Speech);
        var lyrics = AsrTranscriptMapper.SourceCues(transcript, SubtitleTimingProfile.Lyrics);
        // Assert on the actual guarantee — the longest cue duration — which is independent of the
        // CJK tokenizer parity gap that makes raw cue counts diverge across platforms.
        static double MaxDuration(IReadOnlyList<SubtitleCue> cues) => cues
            .Select(c => (SrtTools.SrtTimeToSeconds(c.End) ?? 0) - (SrtTools.SrtTimeToSeconds(c.Start) ?? 0))
            .DefaultIfEmpty(0)
            .Max();
        Assert.True(MaxDuration(lyrics) < MaxDuration(speech), "lyrics profile should cap cues shorter than speech");
    }

    [Fact]
    public void JapaneseLyricsRetimerKeepsRawOnsetToAvoidLateSongCaptions()
    {
        var transcript = new AsrTranscript
        {
            Id = "song",
            LanguageCode = "ja",
            DurationSeconds = 5.0,
            Words =
            [
                new AsrWord { Text = "青い", StartSeconds = 1.0, EndSeconds = 1.55 },
                new AsrWord { Text = "世界", StartSeconds = 1.7, EndSeconds = 2.2 },
            ],
            SourceModelId = "whisper.cpp:test",
        };
        var speech = AsrTranscriptMapper.SourceCues(transcript, SubtitleTimingProfile.Speech);
        var japaneseLyrics = AsrTranscriptMapper.SourceCues(transcript, SubtitleTimingProfile.JapaneseLyrics);
        var speechStart = SrtTools.SrtTimeToSeconds(speech[0].Start)!.Value;
        var lyricsStart = SrtTools.SrtTimeToSeconds(japaneseLyrics[0].Start)!.Value;
        Assert.Equal(1.0, speechStart, precision: 3); // 整段第一条前有静音:用原始 onset,不加 onsetDelay(镜像 Swift)
        Assert.Equal(1.0, lyricsStart, precision: 3);
    }

    [Fact]
    public void LyricsAcousticGuardClampsIntroOutOfLeadingSilence()
    {
        var transcript = new AsrTranscript
        {
            Id = "gunjou-intro",
            LanguageCode = "ja",
            DurationSeconds = 8.0,
            Words =
            [
                new AsrWord { Text = "あ", StartSeconds = 0.0, EndSeconds = 0.63, Probability = 0.14 },
                new AsrWord { Text = "いつ", StartSeconds = 0.63, EndSeconds = 1.89, Probability = 0.67 },
                new AsrWord { Text = "もの", StartSeconds = 2.60, EndSeconds = 3.15, Probability = 0.99 },
                new AsrWord { Text = "ように", StartSeconds = 3.15, EndSeconds = 5.04, Probability = 0.96 },
            ],
            SourceModelId = "whisper.cpp:test",
        };
        var activity = new AsrAudioActivity([
            new AsrAudioActivityRange(0.0, 2.51),
        ]);

        var guarded = AsrTranscriptMapper.SourceCues(transcript, SubtitleTimingProfile.JapaneseLyrics, activity);
        var unguarded = AsrTranscriptMapper.SourceCues(transcript, SubtitleTimingProfile.JapaneseLyrics);

        var guardedStart = SrtTools.SrtTimeToSeconds(guarded[0].Start)!.Value;
        var unguardedStart = SrtTools.SrtTimeToSeconds(unguarded[0].Start)!.Value;
        Assert.True(guardedStart >= 2.51, "lyrics must not appear inside a leading silent prelude");
        Assert.False(guarded[0].Text.StartsWith("あ", StringComparison.Ordinal), "low-confidence leading lyric noise inside the silent prelude should be dropped");
        Assert.StartsWith("いつもの", guarded[0].Text, StringComparison.Ordinal);
        Assert.Equal(0.0, unguardedStart, precision: 3);
    }

    [Fact]
    public void JapaneseLyricsKeepsSingleKanjiWordSuffixAttached()
    {
        var transcript = new AsrTranscript
        {
            Id = "ado-word-boundary",
            LanguageCode = "ja",
            DurationSeconds = 24.0,
            Words =
            [
                new AsrWord { Text = "ちっちゃな", StartSeconds = 8.17, EndSeconds = 12.61, Probability = 0.95 },
                new AsrWord { Text = "頃", StartSeconds = 12.89, EndSeconds = 13.50, Probability = 0.95 },
                new AsrWord { Text = "から", StartSeconds = 13.50, EndSeconds = 14.20, Probability = 0.95 },
                new AsrWord { Text = "優等", StartSeconds = 14.20, EndSeconds = 17.87, Probability = 0.95 },
                new AsrWord { Text = "生", StartSeconds = 18.15, EndSeconds = 18.50, Probability = 0.95 },
                new AsrWord { Text = "気付いたら", StartSeconds = 18.50, EndSeconds = 21.00, Probability = 0.95 },
            ],
            SourceModelId = "whisper.cpp:test",
        };

        var texts = AsrTranscriptMapper.SourceCues(transcript, SubtitleTimingProfile.JapaneseLyrics)
            .Select(cue => cue.Text)
            .ToList();
        Assert.Contains(texts, text => text.Contains("優等生", StringComparison.Ordinal));
        Assert.DoesNotContain(texts, text => text.StartsWith("生", StringComparison.Ordinal));
    }

    [Fact]
    public void JapaneseLyricsDoesNotBorrowKanaWordHeadIntoPreviousLine()
    {
        var transcript = new AsrTranscript
        {
            Id = "ado-kana-head-boundary",
            LanguageCode = "ja",
            DurationSeconds = 24.0,
            Words =
            [
                new AsrWord { Text = "それ", StartSeconds = 3.93, EndSeconds = 4.05, Probability = 0.99 },
                new AsrWord { Text = "が", StartSeconds = 4.05, EndSeconds = 4.38, Probability = 0.99 },
                new AsrWord { Text = "何", StartSeconds = 4.38, EndSeconds = 4.68, Probability = 0.99 },
                new AsrWord { Text = "か", StartSeconds = 4.71, EndSeconds = 5.01, Probability = 0.99 },
                new AsrWord { Text = "見", StartSeconds = 5.06, EndSeconds = 5.37, Probability = 0.68 },
                new AsrWord { Text = "せ", StartSeconds = 5.37, EndSeconds = 5.70, Probability = 0.99 },
                new AsrWord { Text = "つ", StartSeconds = 5.70, EndSeconds = 6.03, Probability = 0.98 },
                new AsrWord { Text = "けて", StartSeconds = 6.03, EndSeconds = 6.70, Probability = 0.99 },
                new AsrWord { Text = "や", StartSeconds = 6.70, EndSeconds = 7.03, Probability = 0.99 },
                new AsrWord { Text = "る", StartSeconds = 7.03, EndSeconds = 7.42, Probability = 0.99 },
                new AsrWord { Text = "ち", StartSeconds = 7.97, EndSeconds = 8.47, Probability = 0.74 },
                new AsrWord { Text = "っちゃ", StartSeconds = 8.47, EndSeconds = 11.64, Probability = 0.99 },
                new AsrWord { Text = "な", StartSeconds = 11.64, EndSeconds = 12.69, Probability = 0.99 },
                new AsrWord { Text = "頃", StartSeconds = 12.69, EndSeconds = 13.74, Probability = 0.99 },
                new AsrWord { Text = "から", StartSeconds = 13.74, EndSeconds = 15.85, Probability = 0.99 },
                new AsrWord { Text = "優", StartSeconds = 15.85, EndSeconds = 16.90, Probability = 0.74 },
                new AsrWord { Text = "等", StartSeconds = 16.90, EndSeconds = 17.95, Probability = 0.99 },
                new AsrWord { Text = "生", StartSeconds = 17.95, EndSeconds = 19.06, Probability = 0.99 },
                new AsrWord { Text = "気", StartSeconds = 19.06, EndSeconds = 19.27, Probability = 0.97 },
                new AsrWord { Text = "付", StartSeconds = 19.48, EndSeconds = 19.48, Probability = 0.56 },
                new AsrWord { Text = "いた", StartSeconds = 19.61, EndSeconds = 19.90, Probability = 0.99 },
                new AsrWord { Text = "ら", StartSeconds = 19.90, EndSeconds = 20.11, Probability = 0.99 },
            ],
            SourceModelId = "whisper.cpp:test",
        };

        var texts = AsrTranscriptMapper.SourceCues(transcript, SubtitleTimingProfile.JapaneseLyrics)
            .Select(cue => cue.Text)
            .ToList();
        Assert.DoesNotContain(texts, text => text.EndsWith("やるち", StringComparison.Ordinal));
        Assert.Contains(texts, text => text.Contains("ちっちゃ", StringComparison.Ordinal));
        Assert.Contains(texts, text => text.Contains("優等生", StringComparison.Ordinal));
        Assert.DoesNotContain(texts, text => text.StartsWith("生", StringComparison.Ordinal));
    }

    [Fact]
    public void JapaneseLyricsRejoinsSemanticTailsAcrossSungGaps()
    {
        var transcript = new AsrTranscript
        {
            Id = "gunjou-semantic-tails",
            LanguageCode = "ja",
            DurationSeconds = 78.0,
            Words =
            [
                new AsrWord { Text = "そんな", StartSeconds = 25.46, EndSeconds = 25.66, Probability = 0.97 },
                new AsrWord { Text = "も", StartSeconds = 25.66, EndSeconds = 25.83, Probability = 1.00 },
                new AsrWord { Text = "ん", StartSeconds = 26.04, EndSeconds = 26.20, Probability = 1.00 },
                new AsrWord { Text = "さ", StartSeconds = 26.20, EndSeconds = 26.48, Probability = 1.00 },
                new AsrWord { Text = "これで", StartSeconds = 26.48, EndSeconds = 27.28, Probability = 0.97 },
                new AsrWord { Text = "いい", StartSeconds = 27.28, EndSeconds = 27.82, Probability = 1.00 },
                new AsrWord { Text = "知", StartSeconds = 27.82, EndSeconds = 28.08, Probability = 0.97 },
                new AsrWord { Text = "ら", StartSeconds = 28.08, EndSeconds = 28.34, Probability = 1.00 },
                new AsrWord { Text = "ず", StartSeconds = 28.34, EndSeconds = 28.60, Probability = 0.99 },
                new AsrWord { Text = "知", StartSeconds = 28.60, EndSeconds = 28.86, Probability = 0.97 },
                new AsrWord { Text = "ら", StartSeconds = 28.86, EndSeconds = 29.12, Probability = 1.00 },
                new AsrWord { Text = "ず", StartSeconds = 29.12, EndSeconds = 29.38, Probability = 1.00 },
                new AsrWord { Text = "隠", StartSeconds = 29.38, EndSeconds = 29.63, Probability = 0.99 },
                new AsrWord { Text = "して", StartSeconds = 30.15, EndSeconds = 30.15, Probability = 1.00 },
                new AsrWord { Text = "た", StartSeconds = 30.33, EndSeconds = 30.42, Probability = 0.99 },
                new AsrWord { Text = "本当", StartSeconds = 30.90, EndSeconds = 31.23, Probability = 0.41 },
                new AsrWord { Text = "の", StartSeconds = 31.23, EndSeconds = 31.63, Probability = 1.00 },
                new AsrWord { Text = "声", StartSeconds = 31.63, EndSeconds = 32.03, Probability = 1.00 },
                new AsrWord { Text = "を", StartSeconds = 32.03, EndSeconds = 32.46, Probability = 1.00 },
                new AsrWord { Text = "響", StartSeconds = 32.46, EndSeconds = 32.80, Probability = 0.73 },
                new AsrWord { Text = "か", StartSeconds = 32.80, EndSeconds = 33.14, Probability = 1.00 },
                new AsrWord { Text = "せて", StartSeconds = 33.14, EndSeconds = 33.83, Probability = 1.00 },
                new AsrWord { Text = "よ", StartSeconds = 33.83, EndSeconds = 34.20, Probability = 1.00 },
                new AsrWord { Text = "青", StartSeconds = 53.26, EndSeconds = 53.70, Probability = 1.00 },
                new AsrWord { Text = "い", StartSeconds = 53.70, EndSeconds = 54.14, Probability = 1.00 },
                new AsrWord { Text = "世界", StartSeconds = 54.14, EndSeconds = 55.14, Probability = 1.00 },
                new AsrWord { Text = "好", StartSeconds = 55.14, EndSeconds = 55.47, Probability = 1.00 },
                new AsrWord { Text = "き", StartSeconds = 55.47, EndSeconds = 55.80, Probability = 1.00 },
                new AsrWord { Text = "な", StartSeconds = 55.80, EndSeconds = 56.13, Probability = 1.00 },
                new AsrWord { Text = "もの", StartSeconds = 56.13, EndSeconds = 56.79, Probability = 0.97 },
                new AsrWord { Text = "を", StartSeconds = 56.79, EndSeconds = 57.12, Probability = 1.00 },
                new AsrWord { Text = "好", StartSeconds = 57.12, EndSeconds = 57.45, Probability = 0.98 },
                new AsrWord { Text = "き", StartSeconds = 57.65, EndSeconds = 57.78, Probability = 1.00 },
                new AsrWord { Text = "だ", StartSeconds = 57.78, EndSeconds = 58.01, Probability = 1.00 },
                new AsrWord { Text = "と", StartSeconds = 58.22, EndSeconds = 58.44, Probability = 0.25 },
                new AsrWord { Text = "言", StartSeconds = 58.44, EndSeconds = 58.77, Probability = 1.00 },
                new AsrWord { Text = "う", StartSeconds = 58.77, EndSeconds = 59.14, Probability = 1.00 },
                new AsrWord { Text = "怖", StartSeconds = 59.14, EndSeconds = 59.47, Probability = 0.99 },
                new AsrWord { Text = "く", StartSeconds = 59.47, EndSeconds = 59.80, Probability = 1.00 },
                new AsrWord { Text = "て", StartSeconds = 59.80, EndSeconds = 60.13, Probability = 0.86 },
                new AsrWord { Text = "仕", StartSeconds = 60.13, EndSeconds = 60.46, Probability = 1.00 },
                new AsrWord { Text = "方", StartSeconds = 60.46, EndSeconds = 60.79, Probability = 1.00 },
                new AsrWord { Text = "ない", StartSeconds = 60.79, EndSeconds = 61.45, Probability = 1.00 },
                new AsrWord { Text = "した", StartSeconds = 65.89, EndSeconds = 66.41, Probability = 1.00 },
                new AsrWord { Text = "んだ", StartSeconds = 66.41, EndSeconds = 67.00, Probability = 1.00 },
                new AsrWord { Text = "手", StartSeconds = 67.00, EndSeconds = 68.22, Probability = 0.53 },
                new AsrWord { Text = "を", StartSeconds = 69.44, EndSeconds = 69.44, Probability = 1.00 },
                new AsrWord { Text = "伸", StartSeconds = 70.08, EndSeconds = 70.64, Probability = 1.00 },
                new AsrWord { Text = "ば", StartSeconds = 70.65, EndSeconds = 71.87, Probability = 1.00 },
                new AsrWord { Text = "せ", StartSeconds = 71.87, EndSeconds = 73.09, Probability = 1.00 },
                new AsrWord { Text = "ば", StartSeconds = 73.09, EndSeconds = 74.25, Probability = 1.00 },
                new AsrWord { Text = "伸", StartSeconds = 74.31, EndSeconds = 75.52, Probability = 0.99 },
                new AsrWord { Text = "ば", StartSeconds = 75.52, EndSeconds = 76.72, Probability = 1.00 },
                new AsrWord { Text = "す", StartSeconds = 76.76, EndSeconds = 77.96, Probability = 1.00 },
                new AsrWord { Text = "ほど", StartSeconds = 77.96, EndSeconds = 80.41, Probability = 0.99 },
                new AsrWord { Text = "に", StartSeconds = 80.41, EndSeconds = 81.68, Probability = 1.00 },
                new AsrWord { Text = "遠", StartSeconds = 81.70, EndSeconds = 82.06, Probability = 1.00 },
                new AsrWord { Text = "く", StartSeconds = 82.06, EndSeconds = 82.42, Probability = 1.00 },
                new AsrWord { Text = "へ", StartSeconds = 82.42, EndSeconds = 82.78, Probability = 1.00 },
                new AsrWord { Text = "行", StartSeconds = 82.78, EndSeconds = 83.14, Probability = 0.89 },
                new AsrWord { Text = "く", StartSeconds = 83.14, EndSeconds = 83.52, Probability = 1.00 },
                new AsrWord { Text = "思", StartSeconds = 83.52, EndSeconds = 83.83, Probability = 0.99 },
                new AsrWord { Text = "う", StartSeconds = 83.83, EndSeconds = 84.14, Probability = 1.00 },
                new AsrWord { Text = "ように", StartSeconds = 84.14, EndSeconds = 85.08, Probability = 0.98 },
                new AsrWord { Text = "い", StartSeconds = 85.08, EndSeconds = 85.45, Probability = 0.40 },
                new AsrWord { Text = "か", StartSeconds = 85.45, EndSeconds = 85.82, Probability = 1.00 },
                new AsrWord { Text = "ない", StartSeconds = 85.82, EndSeconds = 86.56, Probability = 1.00 },
                new AsrWord { Text = "今日", StartSeconds = 86.56, EndSeconds = 87.56, Probability = 1.00 },
                new AsrWord { Text = "も", StartSeconds = 87.56, EndSeconds = 87.56, Probability = 1.00 },
                new AsrWord { Text = "また", StartSeconds = 87.56, EndSeconds = 88.14, Probability = 0.81 },
                new AsrWord { Text = "慌", StartSeconds = 88.14, EndSeconds = 88.42, Probability = 0.86 },
                new AsrWord { Text = "ただ", StartSeconds = 88.42, EndSeconds = 89.00, Probability = 0.99 },
                new AsrWord { Text = "しく", StartSeconds = 89.00, EndSeconds = 89.60, Probability = 0.99 },
                new AsrWord { Text = "も", StartSeconds = 89.89, EndSeconds = 89.89, Probability = 0.91 },
                new AsrWord { Text = "が", StartSeconds = 90.07, EndSeconds = 90.18, Probability = 0.99 },
                new AsrWord { Text = "いて", StartSeconds = 90.64, EndSeconds = 90.77, Probability = 0.68 },
                new AsrWord { Text = "る", StartSeconds = 90.77, EndSeconds = 91.08, Probability = 0.99 },
                new AsrWord { Text = "悔", StartSeconds = 91.08, EndSeconds = 91.48, Probability = 1.00 },
                new AsrWord { Text = "しい", StartSeconds = 91.48, EndSeconds = 92.32, Probability = 1.00 },
            ],
            SourceModelId = "whisper.cpp:test",
        };

        var cues = AsrTranscriptMapper.SourceCues(transcript, SubtitleTimingProfile.JapaneseLyrics);
        var joined = string.Join(" / ", cues.Select(cue => cue.Text));
        Assert.Contains(cues, cue => cue.Text.Contains("隠してた", StringComparison.Ordinal));
        Assert.DoesNotContain(cues, cue => cue.Text.EndsWith("隠", StringComparison.Ordinal));
        Assert.DoesNotContain(cues, cue => cue.Text.StartsWith("して", StringComparison.Ordinal));
        Assert.Contains(cues, cue => cue.Text.Contains("好きだと言う", StringComparison.Ordinal));
        Assert.DoesNotContain(cues, cue => cue.Text.EndsWith("好き", StringComparison.Ordinal));
        Assert.DoesNotContain(cues, cue => cue.Text.StartsWith("だ", StringComparison.Ordinal));
        Assert.Contains(cues, cue => cue.Text.Contains("手を伸ばせば", StringComparison.Ordinal));
        Assert.DoesNotContain(cues, cue => cue.Text.EndsWith("手", StringComparison.Ordinal));
        Assert.DoesNotContain(cues, cue => cue.Text.StartsWith("を", StringComparison.Ordinal));
        Assert.Contains(cues, cue => cue.Text.Contains("もがいてる", StringComparison.Ordinal));
        Assert.DoesNotContain(cues, cue => cue.Text.EndsWith("もが", StringComparison.Ordinal));
        Assert.DoesNotContain(cues, cue => cue.Text.StartsWith("いて", StringComparison.Ordinal));
        Assert.NotEmpty(joined);
    }

    [Fact]
    public void JapaneseLyricsMergesFlashInterjectionWhenNeighborsAreReadable()
    {
        var transcript = new AsrTranscript
        {
            Id = "gunjou-flash-hora",
            LanguageCode = "ja",
            DurationSeconds = 42.0,
            Words =
            [
                new AsrWord { Text = "隠", StartSeconds = 29.38, EndSeconds = 29.63, Probability = 0.99 },
                new AsrWord { Text = "して", StartSeconds = 30.15, EndSeconds = 30.15, Probability = 1.00 },
                new AsrWord { Text = "た", StartSeconds = 30.33, EndSeconds = 30.42, Probability = 0.99 },
                new AsrWord { Text = "本当", StartSeconds = 30.90, EndSeconds = 31.23, Probability = 0.41 },
                new AsrWord { Text = "の", StartSeconds = 31.23, EndSeconds = 31.63, Probability = 1.00 },
                new AsrWord { Text = "声", StartSeconds = 31.63, EndSeconds = 32.03, Probability = 1.00 },
                new AsrWord { Text = "を", StartSeconds = 32.03, EndSeconds = 32.46, Probability = 1.00 },
                new AsrWord { Text = "響", StartSeconds = 32.46, EndSeconds = 32.80, Probability = 0.73 },
                new AsrWord { Text = "か", StartSeconds = 32.80, EndSeconds = 33.14, Probability = 1.00 },
                new AsrWord { Text = "せて", StartSeconds = 33.14, EndSeconds = 33.83, Probability = 1.00 },
                new AsrWord { Text = "よ", StartSeconds = 33.83, EndSeconds = 34.20, Probability = 1.00 },
                new AsrWord { Text = "ほ", StartSeconds = 34.20, EndSeconds = 34.48, Probability = 1.00 },
                new AsrWord { Text = "ら", StartSeconds = 34.48, EndSeconds = 34.76, Probability = 1.00 },
                new AsrWord { Text = "見", StartSeconds = 34.76, EndSeconds = 35.04, Probability = 0.97 },
                new AsrWord { Text = "ない", StartSeconds = 35.04, EndSeconds = 35.60, Probability = 1.00 },
                new AsrWord { Text = "ふ", StartSeconds = 35.60, EndSeconds = 35.88, Probability = 0.80 },
                new AsrWord { Text = "り", StartSeconds = 35.88, EndSeconds = 36.16, Probability = 1.00 },
                new AsrWord { Text = "して", StartSeconds = 36.68, EndSeconds = 36.72, Probability = 1.00 },
                new AsrWord { Text = "いて", StartSeconds = 36.80, EndSeconds = 36.98, Probability = 1.00 },
                new AsrWord { Text = "も", StartSeconds = 37.28, EndSeconds = 37.56, Probability = 1.00 },
                new AsrWord { Text = "確", StartSeconds = 37.56, EndSeconds = 37.89, Probability = 0.95 },
                new AsrWord { Text = "か", StartSeconds = 37.90, EndSeconds = 38.24, Probability = 1.00 },
                new AsrWord { Text = "に", StartSeconds = 38.24, EndSeconds = 38.58, Probability = 1.00 },
                new AsrWord { Text = "そこ", StartSeconds = 38.58, EndSeconds = 39.10, Probability = 1.00 },
                new AsrWord { Text = "に", StartSeconds = 39.10, EndSeconds = 39.40, Probability = 1.00 },
                new AsrWord { Text = "ある", StartSeconds = 39.40, EndSeconds = 40.20, Probability = 1.00 },
            ],
            SourceModelId = "whisper.cpp:test",
        };

        var cues = AsrTranscriptMapper.SourceCues(transcript, SubtitleTimingProfile.JapaneseLyrics);
        var joined = string.Join(" / ", cues.Select(cue => cue.Text));
        Assert.DoesNotContain(cues, cue => cue.Text == "ほら");
        Assert.Contains(cues, cue => cue.Text.Contains("ほら", StringComparison.Ordinal));
        foreach (var cue in cues.Where(cue => cue.Text.Contains("ほら", StringComparison.Ordinal)))
        {
            var duration = SrtTools.SrtTimeToSeconds(cue.End)!.Value - SrtTools.SrtTimeToSeconds(cue.Start)!.Value;
            Assert.True(duration >= 0.8, joined);
        }
    }

    [Fact]
    public void JapaneseLyricsRejoinsAdjectivePredicateContinuation()
    {
        var transcript = new AsrTranscript
        {
            Id = "gunjou-adjective-naru",
            LanguageCode = "ja",
            DurationSeconds = 108.0,
            Words =
            [
                new AsrWord { Text = "ち", StartSeconds = 92.90, EndSeconds = 93.19, Probability = 0.99 },
                new AsrWord { Text = "も", StartSeconds = 93.50, EndSeconds = 93.50, Probability = 0.95 },
                new AsrWord { Text = "ただ", StartSeconds = 93.57, EndSeconds = 93.96, Probability = 0.53 },
                new AsrWord { Text = "情", StartSeconds = 93.98, EndSeconds = 94.36, Probability = 1.00 },
                new AsrWord { Text = "け", StartSeconds = 94.36, EndSeconds = 94.74, Probability = 0.99 },
                new AsrWord { Text = "なく", StartSeconds = 94.74, EndSeconds = 95.50, Probability = 1.00 },
                new AsrWord { Text = "て", StartSeconds = 95.50, EndSeconds = 95.88, Probability = 1.00 },
                new AsrWord { Text = "涙", StartSeconds = 95.88, EndSeconds = 96.33, Probability = 1.00 },
                new AsrWord { Text = "が", StartSeconds = 96.33, EndSeconds = 96.78, Probability = 1.00 },
                new AsrWord { Text = "出", StartSeconds = 96.78, EndSeconds = 97.23, Probability = 0.99 },
                new AsrWord { Text = "る", StartSeconds = 97.23, EndSeconds = 97.68, Probability = 1.00 },
                new AsrWord { Text = "踏", StartSeconds = 97.68, EndSeconds = 97.93, Probability = 1.00 },
                new AsrWord { Text = "み", StartSeconds = 97.93, EndSeconds = 98.19, Probability = 1.00 },
                new AsrWord { Text = "込", StartSeconds = 98.19, EndSeconds = 98.44, Probability = 1.00 },
                new AsrWord { Text = "む", StartSeconds = 98.44, EndSeconds = 98.70, Probability = 1.00 },
                new AsrWord { Text = "ほど", StartSeconds = 98.70, EndSeconds = 99.24, Probability = 0.97 },
                new AsrWord { Text = "苦", StartSeconds = 99.24, EndSeconds = 99.62, Probability = 1.00 },
                new AsrWord { Text = "しく", StartSeconds = 99.62, EndSeconds = 100.38, Probability = 1.00 },
                new AsrWord { Text = "なる", StartSeconds = 100.38, EndSeconds = 101.14, Probability = 0.98 },
                new AsrWord { Text = "痛", StartSeconds = 101.14, EndSeconds = 101.56, Probability = 1.00 },
                new AsrWord { Text = "く", StartSeconds = 101.56, EndSeconds = 101.98, Probability = 1.00 },
                new AsrWord { Text = "も", StartSeconds = 101.98, EndSeconds = 102.40, Probability = 1.00 },
                new AsrWord { Text = "なる", StartSeconds = 102.40, EndSeconds = 103.24, Probability = 1.00 },
                new AsrWord { Text = "感じ", StartSeconds = 103.24, EndSeconds = 104.82, Probability = 0.78 },
            ],
            SourceModelId = "whisper.cpp:test",
        };

        var cues = AsrTranscriptMapper.SourceCues(transcript, SubtitleTimingProfile.JapaneseLyrics);
        var joined = string.Join(" / ", cues.Select(cue => cue.Text));
        Assert.Contains(cues, cue => cue.Text.Contains("苦しくなる", StringComparison.Ordinal));
        Assert.DoesNotContain(cues, cue => cue.Text.EndsWith("苦しく", StringComparison.Ordinal));
        Assert.DoesNotContain(cues, cue => cue.Text.StartsWith("なる痛", StringComparison.Ordinal));
        Assert.NotEmpty(joined);
    }

    [Fact]
    public void JapaneseLyricsRejoinsFixedPhrasesAcrossSungGaps()
    {
        var transcript = new AsrTranscript
        {
            Id = "gunjou-fixed-phrases",
            LanguageCode = "ja",
            DurationSeconds = 132.0,
            Words =
            [
                new AsrWord { Text = "この", StartSeconds = 111.40, EndSeconds = 111.71, Probability = 0.94 },
                new AsrWord { Text = "道", StartSeconds = 111.98, EndSeconds = 112.08, Probability = 1.00 },
                new AsrWord { Text = "を", StartSeconds = 112.08, EndSeconds = 112.46, Probability = 1.00 },
                new AsrWord { Text = "重", StartSeconds = 112.46, EndSeconds = 112.88, Probability = 0.67 },
                new AsrWord { Text = "い", StartSeconds = 112.88, EndSeconds = 113.30, Probability = 1.00 },
                new AsrWord { Text = "瞼", StartSeconds = 113.30, EndSeconds = 113.72, Probability = 0.81 },
                new AsrWord { Text = "こ", StartSeconds = 113.72, EndSeconds = 114.14, Probability = 0.76 },
                new AsrWord { Text = "する", StartSeconds = 114.94, EndSeconds = 114.98, Probability = 0.99 },
                new AsrWord { Text = "夜", StartSeconds = 115.07, EndSeconds = 115.55, Probability = 0.92 },
                new AsrWord { Text = "に", StartSeconds = 115.55, EndSeconds = 116.12, Probability = 1.00 },
                new AsrWord { Text = "し", StartSeconds = 116.12, EndSeconds = 116.42, Probability = 0.99 },
                new AsrWord { Text = "が", StartSeconds = 116.42, EndSeconds = 116.72, Probability = 1.00 },
                new AsrWord { Text = "み", StartSeconds = 116.72, EndSeconds = 117.02, Probability = 1.00 },
                new AsrWord { Text = "つ", StartSeconds = 117.02, EndSeconds = 117.32, Probability = 1.00 },
                new AsrWord { Text = "いた", StartSeconds = 117.32, EndSeconds = 117.93, Probability = 1.00 },
                new AsrWord { Text = "好き", StartSeconds = 119.18, EndSeconds = 119.86, Probability = 1.00 },
                new AsrWord { Text = "な", StartSeconds = 119.86, EndSeconds = 120.20, Probability = 1.00 },
                new AsrWord { Text = "こと", StartSeconds = 120.20, EndSeconds = 120.89, Probability = 0.98 },
                new AsrWord { Text = "を", StartSeconds = 120.89, EndSeconds = 121.23, Probability = 1.00 },
                new AsrWord { Text = "続", StartSeconds = 121.57, EndSeconds = 121.57, Probability = 1.00 },
                new AsrWord { Text = "ける", StartSeconds = 121.78, EndSeconds = 121.97, Probability = 1.00 },
                new AsrWord { Text = "こと", StartSeconds = 122.26, EndSeconds = 122.98, Probability = 1.00 },
                new AsrWord { Text = "それは", StartSeconds = 122.98, EndSeconds = 123.74, Probability = 1.00 },
                new AsrWord { Text = "楽", StartSeconds = 123.74, EndSeconds = 123.99, Probability = 1.00 },
                new AsrWord { Text = "しい", StartSeconds = 123.99, EndSeconds = 124.50, Probability = 1.00 },
                new AsrWord { Text = "だけ", StartSeconds = 124.50, EndSeconds = 125.01, Probability = 1.00 },
                new AsrWord { Text = "じゃない", StartSeconds = 125.54, EndSeconds = 125.83, Probability = 1.00 },
                new AsrWord { Text = "本当", StartSeconds = 126.04, EndSeconds = 126.83, Probability = 1.00 },
                new AsrWord { Text = "に", StartSeconds = 126.83, EndSeconds = 127.22, Probability = 1.00 },
                new AsrWord { Text = "できる", StartSeconds = 127.22, EndSeconds = 128.42, Probability = 0.98 },
            ],
            SourceModelId = "whisper.cpp:test",
        };

        var cues = AsrTranscriptMapper.SourceCues(transcript, SubtitleTimingProfile.JapaneseLyrics);
        var joined = string.Join(" / ", cues.Select(cue => cue.Text));
        Assert.Contains(cues, cue => cue.Text.Contains("重い瞼こする夜", StringComparison.Ordinal));
        Assert.DoesNotContain(cues, cue => cue.Text.EndsWith("瞼こ", StringComparison.Ordinal) || cue.Text.EndsWith("こ", StringComparison.Ordinal));
        Assert.DoesNotContain(cues, cue => cue.Text.StartsWith("する", StringComparison.Ordinal));
        Assert.Contains(cues, cue => cue.Text.Contains("続けること", StringComparison.Ordinal));
        Assert.DoesNotContain(cues, cue => cue.Text.EndsWith("続", StringComparison.Ordinal));
        Assert.DoesNotContain(cues, cue => cue.Text.StartsWith("ける", StringComparison.Ordinal));
        Assert.Contains(cues, cue => cue.Text.Contains("だけじゃない", StringComparison.Ordinal));
        Assert.DoesNotContain(cues, cue => cue.Text.EndsWith("だけ", StringComparison.Ordinal));
        Assert.DoesNotContain(cues, cue => cue.Text.StartsWith("じゃ", StringComparison.Ordinal));
        Assert.NotEmpty(joined);
    }

    [Fact]
    public void AudioActivityParsesFfmpegSilencedetectOutput()
    {
        var activity = AsrAudioActivity.ParseSilencedetectOutput("""
        [Parsed_silencedetect_0 @ 0x843041140] silence_start: 0.001
        [Parsed_silencedetect_0 @ 0x843041140] silence_end: 2.513313 | silence_duration: 2.512312
        [Parsed_silencedetect_0 @ 0x843041140] silence_start: 42.7
        [Parsed_silencedetect_0 @ 0x843041140] silence_end: 44.01 | silence_duration: 1.31
        """);

        Assert.Equal(2, activity.SilenceRanges.Count);
        Assert.Equal(0.001, activity.SilenceRanges[0].StartSeconds, precision: 6);
        Assert.Equal(2.513313, activity.SilenceRanges[0].EndSeconds, precision: 6);
        Assert.Equal(42.7, activity.SilenceRanges[1].StartSeconds, precision: 6);
        Assert.Equal(44.01, activity.SilenceRanges[1].EndSeconds, precision: 6);
    }

    [Fact]
    public void JapaneseLyricsDoesNotStartLineWithBareNaTail()
    {
        var transcript = new AsrTranscript
        {
            Id = "song",
            LanguageCode = "ja",
            Words =
            [
                new AsrWord { Text = "降る", StartSeconds = 0.0, EndSeconds = 0.6 },
                new AsrWord { Text = "どこか", StartSeconds = 0.8, EndSeconds = 1.4 },
                new AsrWord { Text = "虚しい", StartSeconds = 1.6, EndSeconds = 2.4 },
                new AsrWord { Text = "よう", StartSeconds = 2.6, EndSeconds = 3.4 },
                new AsrWord { Text = "なそんな", StartSeconds = 3.5, EndSeconds = 4.9 },
                new AsrWord { Text = "気持ち", StartSeconds = 5.1, EndSeconds = 5.9 },
            ],
            SourceModelId = "whisper.cpp:test",
        };
        var cues = AsrTranscriptMapper.SourceCues(transcript, SubtitleTimingProfile.JapaneseLyrics);
        var joined = string.Join(" / ", cues.Select(cue => cue.Text));
        Assert.DoesNotContain(cues, cue => cue.Text.StartsWith("な", StringComparison.Ordinal));
        Assert.Contains(cues, cue => cue.Text.Contains("ような", StringComparison.Ordinal));
    }

    [Fact]
    public void JapaneseLyricsRebalancesNaTailBeforeSonnaPhrase()
    {
        var transcript = new AsrTranscript
        {
            Id = "song-na-sonna",
            LanguageCode = "ja",
            Words =
            [
                new AsrWord { Text = "谷", StartSeconds = 13.29, EndSeconds = 13.68 },
                new AsrWord { Text = "の", StartSeconds = 13.68, EndSeconds = 14.07 },
                new AsrWord { Text = "街", StartSeconds = 14.07, EndSeconds = 14.46 },
                new AsrWord { Text = "に", StartSeconds = 14.46, EndSeconds = 14.85 },
                new AsrWord { Text = "朝", StartSeconds = 14.85, EndSeconds = 15.24 },
                new AsrWord { Text = "が", StartSeconds = 15.24, EndSeconds = 15.63 },
                new AsrWord { Text = "降", StartSeconds = 15.63, EndSeconds = 16.02 },
                new AsrWord { Text = "る", StartSeconds = 16.02, EndSeconds = 16.44 },
                new AsrWord { Text = "ど", StartSeconds = 16.44, EndSeconds = 16.77 },
                new AsrWord { Text = "こ", StartSeconds = 16.77, EndSeconds = 17.1 },
                new AsrWord { Text = "か", StartSeconds = 17.1, EndSeconds = 17.43 },
                new AsrWord { Text = "虚", StartSeconds = 17.43, EndSeconds = 17.76 },
                new AsrWord { Text = "しい", StartSeconds = 17.76, EndSeconds = 18.43 },
                new AsrWord { Text = "よう", StartSeconds = 18.94, EndSeconds = 19.1 },
                new AsrWord { Text = "な", StartSeconds = 19.1, EndSeconds = 19.3 },
                new AsrWord { Text = "そんな", StartSeconds = 19.52, EndSeconds = 20.43 },
                new AsrWord { Text = "気", StartSeconds = 20.43, EndSeconds = 20.76 },
                new AsrWord { Text = "持", StartSeconds = 20.76, EndSeconds = 21.09 },
                new AsrWord { Text = "ち", StartSeconds = 21.09, EndSeconds = 21.48 },
                new AsrWord { Text = "つ", StartSeconds = 21.48, EndSeconds = 21.72 },
                new AsrWord { Text = "ま", StartSeconds = 21.72, EndSeconds = 21.92 },
                new AsrWord { Text = "ら", StartSeconds = 21.99, EndSeconds = 22.2 },
                new AsrWord { Text = "ない", StartSeconds = 22.2, EndSeconds = 22.69 },
                new AsrWord { Text = "な", StartSeconds = 22.69, EndSeconds = 22.96 },
                new AsrWord { Text = "でも", StartSeconds = 22.96, EndSeconds = 23.5 },
            ],
            SourceModelId = "whisper.cpp:test",
        };
        var cues = AsrTranscriptMapper.SourceCues(transcript, SubtitleTimingProfile.JapaneseLyrics);
        var joined = string.Join(" / ", cues.Select(cue => cue.Text));

        Assert.DoesNotContain(cues, cue => cue.Text.StartsWith("なそんな", StringComparison.Ordinal));
        Assert.Contains(cues, cue => cue.Text.Contains("虚しいような", StringComparison.Ordinal));
        Assert.Contains(cues, cue => cue.Text.StartsWith("そんな気持ち", StringComparison.Ordinal));
    }

    [Fact]
    public void LyricsProfileCapsResidualStandaloneCue()
    {
        var transcript = new AsrTranscript
        {
            Id = "r",
            LanguageCode = "ja",
            Words =
            [
                new AsrWord { Text = "うた。", StartSeconds = 0.0, EndSeconds = 1.0 },
                new AsrWord { Text = "ね", StartSeconds = 10.0, EndSeconds = 15.0 },
                new AsrWord { Text = "そら。", StartSeconds = 30.0, EndSeconds = 31.0 },
            ],
            SourceModelId = "whisper.cpp:test",
        };
        var speech = AsrTranscriptMapper.SourceCues(transcript, SubtitleTimingProfile.Speech);
        var lyrics = AsrTranscriptMapper.SourceCues(transcript, SubtitleTimingProfile.Lyrics);
        static double? StandaloneDuration(IReadOnlyList<SubtitleCue> cues)
        {
            foreach (var cue in cues.Where(c => c.Text == "ね"))
            {
                var start = SrtTools.SrtTimeToSeconds(cue.Start);
                var end = SrtTools.SrtTimeToSeconds(cue.End);
                if (start is not null && end is not null) return end.Value - start.Value;
            }
            return null;
        }
        var speechDur = StandaloneDuration(speech);
        var lyricsDur = StandaloneDuration(lyrics);
        Assert.NotNull(speechDur);
        Assert.NotNull(lyricsDur);
        Assert.True(lyricsDur!.Value <= 0.9 + 0.001, "residual cue must be capped under lyrics profile");
        Assert.True(speechDur!.Value > lyricsDur.Value, "speech profile allows a longer standalone hold than lyrics");
    }

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
            MaxTextContextTokens = 0,
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
            "-mc", "0",
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
        Assert.DoesNotContain("-mc", unknownModelPlan.Arguments);
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
    public void WhisperCppCommandPlanUsesVADOnlyWithExplicitExistingModelPath()
    {
        var directory = Path.Combine(Path.GetTempPath(), "moongate-asr-vad-" + Guid.NewGuid().ToString("N"));
        try
        {
            var runtimeDirectory = Path.Combine(directory, "runtime");
            Directory.CreateDirectory(runtimeDirectory);
            var runtime = new AsrRuntimeInfo { ExecutablePath = Path.Combine(runtimeDirectory, "whisper-cli") };
            var model = Path.Combine(directory, "ggml-small.bin");
            var audio = Path.Combine(directory, "audio.wav");
            File.WriteAllText(runtime.ExecutablePath, "#!/bin/sh\n");
            File.WriteAllText(model, "model");
            File.WriteAllText(audio, "audio");

            var request = new AsrRequest
            {
                AudioPath = audio,
                LanguageCode = "ja",
                ModelId = "whisper.cpp:small",
                VadEnabled = true,
            };
            var missingPlan = WhisperCppCommandPlan.Create(
                runtime,
                model,
                request,
                Path.Combine(directory, "missing"));
            Assert.DoesNotContain("--vad", missingPlan.Arguments);
            Assert.DoesNotContain("-vm", missingPlan.Arguments);

            var vadModel = Path.Combine(runtimeDirectory, "ggml-silero-v5.1.2.bin");
            File.WriteAllText(vadModel, "fake vad model");
            var implicitLocatorPlan = WhisperCppCommandPlan.Create(
                runtime,
                model,
                request,
                Path.Combine(directory, "implicit"));
            Assert.DoesNotContain("--vad", implicitLocatorPlan.Arguments);
            Assert.DoesNotContain("-vm", implicitLocatorPlan.Arguments);

            var readyPlan = WhisperCppCommandPlan.Create(
                runtime,
                model,
                request with { VadModelPath = vadModel },
                Path.Combine(directory, "ready"));
            Assert.Contains("--vad", readyPlan.Arguments);
            Assert.Equal(vadModel, ArgumentValueAfter("-vm", readyPlan.Arguments));
            Assert.DoesNotContain("--vad-model", readyPlan.Arguments);

            var missingExplicitPlan = WhisperCppCommandPlan.Create(
                runtime,
                model,
                request with { VadModelPath = Path.Combine(runtimeDirectory, "missing-vad.bin") },
                Path.Combine(directory, "missing-explicit"));
            Assert.DoesNotContain("--vad", missingExplicitPlan.Arguments);
            Assert.DoesNotContain("-vm", missingExplicitPlan.Arguments);

            var disabledPlan = WhisperCppCommandPlan.Create(
                runtime,
                model,
                request with { VadEnabled = false, VadModelPath = vadModel },
                Path.Combine(directory, "disabled"));
            Assert.DoesNotContain("--vad", disabledPlan.Arguments);
            Assert.DoesNotContain("-vm", disabledPlan.Arguments);
        }
        finally
        {
            if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public void DefaultLocalAsrPromptOmitsLanguageHintForAutoDetect()
    {
        var video = Path.Combine(Path.GetTempPath(), "Moon Gate Clip.mp4");

        Assert.Equal(
            "今日は、いい天気ですね。はい、そうです。; title=Moon Gate Clip; language=ja",
            AsrPromptBuilder.DefaultPrompt(video, " ja "));
        Assert.Equal(
            "안녕하세요. 오늘은 날씨가 좋네요. 네, 맞습니다.; title=Moon Gate Clip; language=ko",
            AsrPromptBuilder.DefaultPrompt(video, " ko "));
        Assert.Equal(
            "title=Moon Gate Clip",
            AsrPromptBuilder.DefaultPrompt(video, " auto "));
        Assert.Equal(
            "title=Moon Gate Clip",
            AsrPromptBuilder.DefaultPrompt(video, " AUTO "));
        Assert.Equal(
            "title=Moon Gate Clip; language=en",
            AsrPromptBuilder.DefaultPrompt(video, "en"));
        Assert.Null(AsrPromptBuilder.DefaultPrompt(Path.Combine(Path.GetTempPath(), "   .mp4"), "auto"));
    }

    [Fact]
    public void DefaultLocalAsrPromptInjectsMetadataGlossaryAndCharacters()
    {
        var video = Path.Combine(Path.GetTempPath(), "コウペンちゃん 夏祭り.mp4");
        var metadata = new AsrPromptMetadata(
            Title: "コウペンちゃん 夏祭り",
            Channel: "Koupen Channel",
            Characters: ["コウペンちゃん", "邪エナガさん"],
            GlossaryTerms: ["チョコバナナ", "ソースせんべい", "くじ引きやろう"]);

        var prompt = AsrPromptBuilder.DefaultPrompt(video, "ja", metadata);

        Assert.NotNull(prompt);
        Assert.Contains("title=コウペンちゃん 夏祭り", prompt);
        Assert.Contains("channel=Koupen Channel", prompt);
        Assert.Contains("characters=コウペンちゃん, 邪エナガさん", prompt);
        Assert.Contains("glossary=チョコバナナ, ソースせんべい, くじ引きやろう", prompt);

        var inferred = AsrPromptBuilder.DefaultPrompt(video, "ja");
        Assert.NotNull(inferred);
        Assert.Contains("characters=コウペンちゃん", inferred);
        Assert.Contains("glossary=チョコバナナ, ソースせんべい, くじ引きやろう", inferred);
    }

    [Fact]
    public void LyricsRecognitionProfileAvoidsPromptContextAndDialogueExemplar()
    {
        var video = Path.Combine(Path.GetTempPath(), "YOASOBI - 群青 Official Music Video.mp4");
        var profile = AsrPromptBuilder.RecognitionProfile(video, "ja");

        Assert.Equal(AsrRecognitionProfile.LyricsHighQuality, profile);
        Assert.Equal(
            "title=YOASOBI - 群青 Official Music Video; language=ja",
            AsrPromptBuilder.DefaultPrompt(video, "ja", profile));
        Assert.Equal(0, AsrPromptBuilder.MaxTextContextTokens(video, "ja", profile));
    }

    [Fact]
    public void LyricsRecognitionProfileDetectsOfficialArtistTitleRelease()
    {
        var video = Path.Combine(Path.GetTempPath(), "星をみる少女 ⧸ 星街すいせい (official).mp4");
        var profile = AsrPromptBuilder.RecognitionProfile(video, "ja");

        Assert.Equal(AsrRecognitionProfile.LyricsHighQuality, profile);
        Assert.False(AsrPromptBuilder.VadEnabled(profile));
        Assert.Equal(
            "title=星をみる少女 ⧸ 星街すいせい (official); language=ja",
            AsrPromptBuilder.DefaultPrompt(video, "ja", profile));
    }

    [Fact]
    public void CjkSpeechRecognitionDisablesPromptContextByDefault()
    {
        var video = Path.Combine(Path.GetTempPath(), "dialogue clip.mp4");

        Assert.Equal(0, AsrPromptBuilder.MaxTextContextTokens(video, "ja"));
        Assert.Equal(0, AsrPromptBuilder.MaxTextContextTokens(video, "ko"));
        Assert.Equal(0, AsrPromptBuilder.MaxTextContextTokens(video, "zh-Hans"));
        Assert.Equal(0, AsrPromptBuilder.MaxTextContextTokens(video, "yue"));
        Assert.Null(AsrPromptBuilder.MaxTextContextTokens(video, "en"));
        Assert.Null(AsrPromptBuilder.MaxTextContextTokens(video, "auto"));
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
                backendKind: AsrBackendKind.WhisperCpp,
                languageCode: null));
            Assert.Null(store.CachedTranscript(
                "clip-audio-small-auto",
                audioFingerprint: "sha256:audio-b",
                modelId: "whisper.cpp:small",
                backendKind: AsrBackendKind.WhisperCpp,
                languageCode: null));
            Assert.Null(store.CachedTranscript(
                "clip-audio-small-auto",
                audioFingerprint: "sha256:audio-a",
                modelId: "whisper.cpp:base",
                backendKind: AsrBackendKind.WhisperCpp,
                languageCode: null));
            Assert.Null(store.CachedTranscript(
                "clip-audio-small-auto",
                audioFingerprint: "sha256:audio-a",
                modelId: "whisper.cpp:small",
                backendKind: AsrBackendKind.SenseVoiceFunASR,
                languageCode: null));
            Assert.Null(store.CachedTranscript(
                "clip-audio-small-auto",
                audioFingerprint: "sha256:audio-a",
                modelId: "whisper.cpp:small",
                backendKind: AsrBackendKind.WhisperCpp,
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
                backendKind: AsrBackendKind.WhisperCpp,
                languageCode: "auto"));
            AssertTranscriptEqual(transcript, store.CachedTranscript(
                "clip-audio-small-auto-detected",
                audioFingerprint: "sha256:audio-auto",
                modelId: "whisper.cpp:small",
                backendKind: AsrBackendKind.WhisperCpp,
                languageCode: " ja "));
            Assert.Null(store.CachedTranscript(
                "clip-audio-small-auto-detected",
                audioFingerprint: "sha256:audio-auto",
                modelId: "whisper.cpp:small",
                backendKind: AsrBackendKind.WhisperCpp,
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
    public void TranscriptMapperMergesLatinWhisperTokenPieces()
    {
        var transcript = new AsrTranscript
        {
            Id = "latin-pieces",
            LanguageCode = "it",
            Words =
            [
                new AsrWord { Text = " Marco", StartSeconds = 1.39, EndSeconds = 2.00 },
                new AsrWord { Text = " se", StartSeconds = 2.00, EndSeconds = 4.55 },
                new AsrWord { Text = " n", StartSeconds = 4.56, EndSeconds = 5.84 },
                new AsrWord { Text = "'", StartSeconds = 5.84, EndSeconds = 7.11 },
                new AsrWord { Text = "è", StartSeconds = 7.11, EndSeconds = 9.66 },
                new AsrWord { Text = " and", StartSeconds = 9.66, EndSeconds = 13.49 },
                new AsrWord { Text = "ato", StartSeconds = 13.49, EndSeconds = 17.34 },
                new AsrWord { Text = " e", StartSeconds = 17.34, EndSeconds = 17.43 },
                new AsrWord { Text = " non", StartSeconds = 17.43, EndSeconds = 17.70 },
                new AsrWord { Text = " r", StartSeconds = 17.70, EndSeconds = 17.79 },
                new AsrWord { Text = "itor", StartSeconds = 17.79, EndSeconds = 18.15 },
                new AsrWord { Text = "na", StartSeconds = 18.15, EndSeconds = 18.33 },
                new AsrWord { Text = " più", StartSeconds = 18.33, EndSeconds = 18.72 },
            ],
            SourceModelId = "whisper.cpp:test",
        };

        var fragments = AsrTranscriptMapper.SourceFragments(transcript);

        Assert.Equal(["Marco", "se", "n'è", "andato", "e", "non", "ritorna", "più"], fragments.Select(fragment => fragment.Text).ToArray());
        Assert.Equal(4.56, fragments[2].StartSeconds, precision: 3);
        Assert.Equal(9.66, fragments[2].EndSeconds, precision: 3);
        Assert.Equal(17.70, fragments[6].StartSeconds, precision: 3);
        Assert.Equal(18.33, fragments[6].EndSeconds, precision: 3);
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
            Assert.Equal("00:00:00,000", parsed[0].Start); // 首词贴近开头:第一条从 0 起显
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
        Assert.Equal("00:00:00,000", cues[0].Start); // 首词贴近开头:第一条从 0 起显
        Assert.Equal("00:00:02,500", cues[0].End);
        Assert.DoesNotContain(cues, cue => cue.Text.Contains("[_", StringComparison.Ordinal));
    }

    [Fact]
    public void LocalAsrTimingPlannerMergesReadableFlashDurationGroups()
    {
        var transcript = new AsrTranscript
        {
            Id = "flash-readable",
            LanguageCode = "en",
            Words =
            [
                new AsrWord { Text = "Hello.", StartSeconds = 0.0, EndSeconds = 1.0 },
                new AsrWord { Text = "OK.", StartSeconds = 1.2, EndSeconds = 1.4 },
                new AsrWord { Text = "World.", StartSeconds = 1.6, EndSeconds = 2.7 },
            ],
            SourceModelId = "whisper.cpp:test",
        };

        var cues = AsrTranscriptMapper.SourceCues(transcript);
        var joined = string.Join(" / ", cues.Select(cue => cue.Text));

        Assert.DoesNotContain(cues, cue => cue.Text == "OK.");
        Assert.Contains(cues, cue => cue.Text.Contains("OK.", StringComparison.Ordinal));
        Assert.True(cues.Count < 3, joined);
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
    public void LocalAsrTimingPlannerSuppressesMixedScriptJapaneseLoopHallucinations()
    {
        var words = new List<AsrWord>
        {
            new() { Text = "おはよう", StartSeconds = 178.0, EndSeconds = 178.6 },
        };
        var loopTokens = new[] { "今日", "も", "花丸", "スタンプ" };
        for (var repeatIndex = 0; repeatIndex < 10; repeatIndex++)
        {
            var baseTime = 181.0 + repeatIndex * 0.04;
            for (var tokenIndex = 0; tokenIndex < loopTokens.Length; tokenIndex++)
            {
                var start = baseTime + tokenIndex * 0.01;
                words.Add(new AsrWord
                {
                    Text = loopTokens[tokenIndex],
                    StartSeconds = start,
                    EndSeconds = start + 0.05,
                });
            }
        }
        words.Add(new AsrWord { Text = "またね", StartSeconds = 205.0, EndSeconds = 205.7 });
        var transcript = new AsrTranscript
        {
            Id = "mixed-script-japanese-loop",
            LanguageCode = "ja",
            Words = words,
            SourceModelId = "whisper.cpp:test",
        };

        var joined = string.Join(' ', AsrTranscriptMapper.SourceCues(transcript).Select(cue => cue.Text));
        var loopCount = joined.Split("今日も花丸スタンプ", StringSplitOptions.None).Length - 1;

        Assert.Contains("おはよう", joined, StringComparison.Ordinal);
        Assert.Contains("またね", joined, StringComparison.Ordinal);
        Assert.True(loopCount <= 1, "mixed kanji/kana/katakana hallucination loop should be fused");
    }

    [Fact]
    public void JapaneseLyricsKeepsLegitimateRepeatedChorusWithParticles()
    {
        var transcript = new AsrTranscript
        {
            Id = "gunjou-legitimate-repeated-chorus",
            LanguageCode = "ja",
            DurationSeconds = 130.0,
            Words =
            [
                new AsrWord { Text = "本当", StartSeconds = 61.48, EndSeconds = 62.60 },
                new AsrWord { Text = "の", StartSeconds = 62.60, EndSeconds = 63.16 },
                new AsrWord { Text = "自", StartSeconds = 63.16, EndSeconds = 63.72 },
                new AsrWord { Text = "分", StartSeconds = 63.97, EndSeconds = 64.28 },
                new AsrWord { Text = "で", StartSeconds = 64.53, EndSeconds = 64.53 },
                new AsrWord { Text = "会", StartSeconds = 64.54, EndSeconds = 64.78 },
                new AsrWord { Text = "え", StartSeconds = 64.78, EndSeconds = 65.03 },
                new AsrWord { Text = "た", StartSeconds = 65.03, EndSeconds = 65.28 },
                new AsrWord { Text = "気", StartSeconds = 65.28, EndSeconds = 65.53 },
                new AsrWord { Text = "が", StartSeconds = 65.53, EndSeconds = 65.78 },
                new AsrWord { Text = "した", StartSeconds = 65.78, EndSeconds = 66.29 },
                new AsrWord { Text = "んだ", StartSeconds = 66.29, EndSeconds = 66.86 },
                new AsrWord { Text = "ああ", StartSeconds = 66.86, EndSeconds = 67.74 },
                new AsrWord { Text = "手", StartSeconds = 67.74, EndSeconds = 68.18 },
                new AsrWord { Text = "を", StartSeconds = 68.18, EndSeconds = 68.62 },
                new AsrWord { Text = "伸", StartSeconds = 68.62, EndSeconds = 69.05 },
                new AsrWord { Text = "ば", StartSeconds = 69.35, EndSeconds = 69.49 },
                new AsrWord { Text = "せ", StartSeconds = 69.51, EndSeconds = 69.93 },
                new AsrWord { Text = "ば", StartSeconds = 69.93, EndSeconds = 70.37 },
                new AsrWord { Text = "伸", StartSeconds = 70.37, EndSeconds = 70.80 },
                new AsrWord { Text = "ば", StartSeconds = 70.80, EndSeconds = 71.24 },
                new AsrWord { Text = "す", StartSeconds = 71.24, EndSeconds = 71.68 },
                new AsrWord { Text = "ほど", StartSeconds = 71.68, EndSeconds = 72.56 },
                new AsrWord { Text = "に", StartSeconds = 72.56, EndSeconds = 72.94 },
                new AsrWord { Text = "遠", StartSeconds = 73.05, EndSeconds = 73.44 },
                new AsrWord { Text = "く", StartSeconds = 73.44, EndSeconds = 73.88 },
                new AsrWord { Text = "へ", StartSeconds = 73.88, EndSeconds = 74.32 },
                new AsrWord { Text = "行", StartSeconds = 74.32, EndSeconds = 74.76 },
                new AsrWord { Text = "く", StartSeconds = 74.76, EndSeconds = 75.24 },
                new AsrWord { Text = "ああ", StartSeconds = 75.24, EndSeconds = 76.15 },
                new AsrWord { Text = "手", StartSeconds = 76.15, EndSeconds = 76.60 },
                new AsrWord { Text = "を", StartSeconds = 76.60, EndSeconds = 77.05 },
                new AsrWord { Text = "伸", StartSeconds = 77.05, EndSeconds = 77.50 },
                new AsrWord { Text = "ば", StartSeconds = 77.73, EndSeconds = 77.95 },
                new AsrWord { Text = "せ", StartSeconds = 78.30, EndSeconds = 78.40 },
                new AsrWord { Text = "ば", StartSeconds = 78.40, EndSeconds = 78.85 },
                new AsrWord { Text = "伸", StartSeconds = 78.85, EndSeconds = 79.30 },
                new AsrWord { Text = "ば", StartSeconds = 79.30, EndSeconds = 79.75 },
                new AsrWord { Text = "す", StartSeconds = 79.75, EndSeconds = 80.20 },
                new AsrWord { Text = "ほど", StartSeconds = 80.20, EndSeconds = 81.11 },
                new AsrWord { Text = "に", StartSeconds = 81.11, EndSeconds = 81.62 },
                new AsrWord { Text = "遠", StartSeconds = 81.62, EndSeconds = 82.89 },
                new AsrWord { Text = "く", StartSeconds = 84.08, EndSeconds = 84.16 },
                new AsrWord { Text = "へ", StartSeconds = 84.68, EndSeconds = 85.43 },
                new AsrWord { Text = "行", StartSeconds = 85.43, EndSeconds = 86.70 },
                new AsrWord { Text = "く", StartSeconds = 86.70, EndSeconds = 88.00 },
                new AsrWord { Text = "あ", StartSeconds = 88.00, EndSeconds = 88.19 },
                new AsrWord { Text = "なた", StartSeconds = 88.19, EndSeconds = 88.58 },
                new AsrWord { Text = "は", StartSeconds = 88.58, EndSeconds = 88.77 },
                new AsrWord { Text = "正", StartSeconds = 88.77, EndSeconds = 88.96 },
                new AsrWord { Text = "しく", StartSeconds = 88.96, EndSeconds = 89.35 },
                new AsrWord { Text = "も", StartSeconds = 89.35, EndSeconds = 89.54 },
                new AsrWord { Text = "が", StartSeconds = 89.54, EndSeconds = 89.73 },
                new AsrWord { Text = "いて", StartSeconds = 89.73, EndSeconds = 90.12 },
                new AsrWord { Text = "る", StartSeconds = 90.38, EndSeconds = 90.38 },
            ],
            SourceModelId = "whisper.cpp:test",
        };

        var cues = AsrTranscriptMapper.SourceCues(transcript, SubtitleTimingProfile.JapaneseLyrics);
        var joined = string.Join(" ", cues.Select(cue => cue.Text));

        Assert.True(joined.Split("手を伸ばせ", StringSplitOptions.None).Length - 1 >= 2);
        Assert.Contains("遠くへ", joined, StringComparison.Ordinal);
        Assert.Contains("行く", joined, StringComparison.Ordinal);
        Assert.Contains("正しく", joined, StringComparison.Ordinal);
        Assert.DoesNotContain(cues, cue => cue.Text.StartsWith("ば", StringComparison.Ordinal));
        Assert.DoesNotContain(cues, cue => cue.Text.StartsWith("く", StringComparison.Ordinal));
    }

    [Fact]
    public void LocalAsrDetectorRoutesDenseJapaneseMusicLoopToLyricsProfile()
    {
        var words = new List<AsrWord>
        {
            new() { Text = "うせうせうせは", StartSeconds = 51.78, EndSeconds = 54.24 },
            new() { Text = "あなたが思うより健康です", StartSeconds = 54.24, EndSeconds = 59.26 },
        };
        var loopTokens = new[] { "あなた", "が", "悪", "い", "頭", "の", "出来", "が", "違う", "ので" };
        for (var repeatIndex = 0; repeatIndex < 24; repeatIndex++)
        {
            var baseTime = 70.0 + repeatIndex;
            for (var tokenIndex = 0; tokenIndex < loopTokens.Length; tokenIndex++)
            {
                var start = baseTime + tokenIndex * 0.04;
                words.Add(new AsrWord
                {
                    Text = loopTokens[tokenIndex],
                    StartSeconds = start,
                    EndSeconds = start + 0.03,
                });
            }
        }
        words.Add(new AsrWord { Text = "また次の歌詞に戻る", StartSeconds = 96.0, EndSeconds = 99.0 });

        var transcript = new AsrTranscript
        {
            Id = "usseewa-dense-loop",
            LanguageCode = "ja",
            DurationSeconds = 105.0,
            Words = words,
            SourceModelId = "whisper.cpp:test",
        };

        var joined = string.Join(" ", AsrTranscriptMapper.SourceCues(
            transcript,
            "Ado - うっせぇわ").Select(cue => cue.Text));
        var loopCount = joined.Split("あなたが悪い頭の出来が違うので", StringSplitOptions.None).Length - 1;

        Assert.Contains("うせうせうせ", joined, StringComparison.Ordinal);
        Assert.Contains("健康", joined, StringComparison.Ordinal);
        Assert.True(loopCount <= 1, "dense whole-phrase whisper loops should be fused after at most one readable occurrence");
    }

    [Fact]
    public void JapaneseLyricsDropsCreditAndOutroHallucinationFragments()
    {
        var transcript = new AsrTranscript
        {
            Id = "japanese-lyrics-credit-hallucination",
            LanguageCode = "ja",
            DurationSeconds = 90.0,
            SourceModelId = "whisper.cpp:test",
            Words =
            [
                new() { Text = "作", StartSeconds = 0.20, EndSeconds = 2.49 },
                new() { Text = "詞", StartSeconds = 2.49, EndSeconds = 4.98 },
                new() { Text = "作", StartSeconds = 7.47, EndSeconds = 9.96 },
                new() { Text = "曲", StartSeconds = 9.96, EndSeconds = 12.45 },
                new() { Text = "編", StartSeconds = 14.94, EndSeconds = 17.43 },
                new() { Text = "曲", StartSeconds = 17.43, EndSeconds = 19.92 },
                new() { Text = "初", StartSeconds = 19.92, EndSeconds = 22.41 },
                new() { Text = "音", StartSeconds = 22.41, EndSeconds = 24.90 },
                new() { Text = "ミ", StartSeconds = 24.90, EndSeconds = 27.38 },
                new() { Text = "ク", StartSeconds = 27.39, EndSeconds = 29.98 },
                new() { Text = "鏡", StartSeconds = 37.62, EndSeconds = 38.30 },
                new() { Text = "よ", StartSeconds = 38.30, EndSeconds = 38.80 },
                new() { Text = "この世で一番", StartSeconds = 39.00, EndSeconds = 42.50 },
                new() { Text = "ご視聴ありがとうございました", StartSeconds = 70.0, EndSeconds = 73.0 },
            ],
        };

        var joined = string.Join(" ", AsrTranscriptMapper.SourceCues(
            transcript,
            SubtitleTimingProfile.JapaneseLyrics).Select(cue => cue.Text));

        Assert.DoesNotContain("作詞", joined, StringComparison.Ordinal);
        Assert.DoesNotContain("作曲", joined, StringComparison.Ordinal);
        Assert.DoesNotContain("編曲", joined, StringComparison.Ordinal);
        Assert.DoesNotContain("初音ミク", joined, StringComparison.Ordinal);
        Assert.DoesNotContain("ご視聴ありがとうございました", joined, StringComparison.Ordinal);
        Assert.Contains("鏡よ", joined, StringComparison.Ordinal);
        Assert.Contains("この世で一番", joined, StringComparison.Ordinal);
    }

    [Fact]
    public void LyricsDropsChineseCreditHallucinationLoop()
    {
        var transcript = new AsrTranscript
        {
            Id = "chinese-lyrics-credit-loop",
            LanguageCode = "zh",
            DurationSeconds = 60.0,
            SourceModelId = "whisper.cpp:test",
            Words =
            [
                new() { Text = "作", StartSeconds = 0.0, EndSeconds = 0.2 },
                new() { Text = "词", StartSeconds = 0.2, EndSeconds = 0.4 },
                new() { Text = ":", StartSeconds = 0.4, EndSeconds = 0.5 },
                new() { Text = "李", StartSeconds = 0.5, EndSeconds = 0.7 },
                new() { Text = "宗", StartSeconds = 0.7, EndSeconds = 0.9 },
                new() { Text = "盛", StartSeconds = 0.9, EndSeconds = 1.0 },
                new() { Text = "作", StartSeconds = 1.0, EndSeconds = 1.2 },
                new() { Text = "曲", StartSeconds = 1.2, EndSeconds = 1.4 },
                new() { Text = ":", StartSeconds = 1.4, EndSeconds = 1.5 },
                new() { Text = "李", StartSeconds = 1.5, EndSeconds = 1.7 },
                new() { Text = "宗", StartSeconds = 1.7, EndSeconds = 1.9 },
                new() { Text = "盛", StartSeconds = 1.9, EndSeconds = 2.0 },
                new() { Text = "作", StartSeconds = 2.0, EndSeconds = 2.2 },
                new() { Text = "曲", StartSeconds = 2.2, EndSeconds = 2.4 },
                new() { Text = ":", StartSeconds = 2.4, EndSeconds = 2.5 },
                new() { Text = "李", StartSeconds = 2.5, EndSeconds = 2.7 },
                new() { Text = "宗", StartSeconds = 2.7, EndSeconds = 2.9 },
                new() { Text = "盛", StartSeconds = 2.9, EndSeconds = 3.0 },
                new() { Text = "天青色等烟雨", StartSeconds = 23.0, EndSeconds = 26.0 },
                new() { Text = "而我在等你", StartSeconds = 26.2, EndSeconds = 29.0 },
            ],
        };

        var joined = string.Join(" ", AsrTranscriptMapper.SourceCues(
            transcript,
            SubtitleTimingProfile.Lyrics).Select(cue => cue.Text));

        Assert.DoesNotContain("作词", joined, StringComparison.Ordinal);
        Assert.DoesNotContain("作曲", joined, StringComparison.Ordinal);
        Assert.DoesNotContain("李宗盛", joined, StringComparison.Ordinal);
        Assert.Contains("天青色等烟雨", joined, StringComparison.Ordinal);
        Assert.Contains("而我在等你", joined, StringComparison.Ordinal);
    }

    [Fact]
    public void LyricsDropsEarlyCreditNameCueBeforeLongIntroGap()
    {
        var transcript = new AsrTranscript
        {
            Id = "chinese-lyrics-intro-credit-name",
            LanguageCode = "zh",
            DurationSeconds = 60.0,
            SourceModelId = "whisper.cpp:test",
            Words =
            [
                new() { Text = "李", StartSeconds = 1.02, EndSeconds = 1.38 },
                new() { Text = "宗", StartSeconds = 1.38, EndSeconds = 1.76 },
                new() { Text = "盛", StartSeconds = 1.76, EndSeconds = 2.35 },
                new() { Text = "天青色等烟雨", StartSeconds = 23.43, EndSeconds = 26.00 },
                new() { Text = "而我在等你", StartSeconds = 26.20, EndSeconds = 29.00 },
            ],
        };

        var joined = string.Join(" ", AsrTranscriptMapper.SourceCues(
            transcript,
            SubtitleTimingProfile.Lyrics).Select(cue => cue.Text));

        Assert.DoesNotContain("李宗盛", joined, StringComparison.Ordinal);
        Assert.Contains("天青色等烟雨", joined, StringComparison.Ordinal);
        Assert.Contains("而我在等你", joined, StringComparison.Ordinal);
    }

    [Fact]
    public void LyricsDropsRepeatedLatinIntroFillerLoop()
    {
        var words = new List<AsrWord>();
        for (var offset = 0; offset < 10; offset++)
        {
            var start = 0.32 + offset * 2.0;
            words.Add(new AsrWord
            {
                Text = "Best ime",
                StartSeconds = start,
                EndSeconds = start + 1.65,
            });
        }
        words.AddRange([
            new() { Text = "Best ime Cause", StartSeconds = 23.80, EndSeconds = 24.10 },
            new() { Text = "I'm", StartSeconds = 24.15, EndSeconds = 24.35 },
            new() { Text = "in", StartSeconds = 24.40, EndSeconds = 24.55 },
            new() { Text = "the", StartSeconds = 24.60, EndSeconds = 24.75 },
            new() { Text = "stars", StartSeconds = 24.80, EndSeconds = 25.20 },
            new() { Text = "tonight", StartSeconds = 25.25, EndSeconds = 25.80 },
        ]);

        var transcript = new AsrTranscript
        {
            Id = "latin-lyrics-intro-filler-loop",
            LanguageCode = "en",
            DurationSeconds = 120.0,
            SourceModelId = "whisper.cpp:test",
            Words = words,
        };

        var joined = string.Join(" ", AsrTranscriptMapper.SourceCues(
            transcript,
            SubtitleTimingProfile.Lyrics).Select(cue => cue.Text));

        Assert.DoesNotContain("Best ime", joined, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("stars tonight", joined, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void LyricsDropsLongLatinFillerOutroLoop()
    {
        var words = new List<AsrWord>
        {
            new() { Text = "Baby", StartSeconds = 7.9, EndSeconds = 8.4 },
            new() { Text = "no", StartSeconds = 8.5, EndSeconds = 8.8 },
            new() { Text = "me", StartSeconds = 8.9, EndSeconds = 9.1 },
            new() { Text = "llames", StartSeconds = 9.2, EndSeconds = 9.8 },
            new() { Text = "que", StartSeconds = 9.9, EndSeconds = 10.2 },
            new() { Text = "ya", StartSeconds = 10.3, EndSeconds = 10.6 },
            new() { Text = "estoy", StartSeconds = 10.7, EndSeconds = 11.1 },
            new() { Text = "ocupada", StartSeconds = 11.2, EndSeconds = 12.1 },
        };
        for (var offset = 0; offset < 36; offset++)
        {
            var start = 125.0 + offset * 0.72;
            words.Add(new AsrWord
            {
                Text = offset % 5 == 0 ? "mmm" : "yeah",
                StartSeconds = start,
                EndSeconds = start + 0.45,
            });
        }
        words.AddRange(
        [
            new() { Text = "Gracias", StartSeconds = 154.0, EndSeconds = 154.4 },
            new() { Text = "por", StartSeconds = 154.5, EndSeconds = 154.7 },
            new() { Text = "ver", StartSeconds = 154.8, EndSeconds = 155.0 },
            new() { Text = "el", StartSeconds = 155.1, EndSeconds = 155.2 },
            new() { Text = "video", StartSeconds = 155.3, EndSeconds = 155.8 },
        ]);

        var transcript = new AsrTranscript
        {
            Id = "latin-filler-outro-loop",
            LanguageCode = "es",
            DurationSeconds = 158.9,
            SourceModelId = "whisper.cpp:test",
            Words = words,
        };

        var joined = string.Join(" ", AsrTranscriptMapper.SourceCues(
            transcript,
            SubtitleTimingProfile.Lyrics).Select(cue => cue.Text));

        Assert.Contains("Baby", joined, StringComparison.Ordinal);
        Assert.Contains("ocupada", joined, StringComparison.Ordinal);
        Assert.DoesNotContain("yeah yeah yeah", joined, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("mmm mmm", joined, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("Gracias", joined, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void LocalAsrDetectorRoutesRepeatedJapaneseOutroBoilerplateToLyricsProfile()
    {
        var transcript = new AsrTranscript
        {
            Id = "radwimps-outro-boilerplate",
            LanguageCode = "ja",
            DurationSeconds = 130.0,
            SourceModelId = "whisper.cpp:test",
            Words =
            [
                new() { Text = "やっと目を覚ましたかい", StartSeconds = 21.14, EndSeconds = 25.74 },
                new() { Text = "ご視聴ありがとうございました", StartSeconds = 93.94, EndSeconds = 96.03 },
                new() { Text = "ご視聴ありがとうございました", StartSeconds = 96.31, EndSeconds = 100.43 },
                new() { Text = "何億何光年分の物語を", StartSeconds = 116.73, EndSeconds = 121.28 },
            ],
        };

        var joined = string.Join(" ", AsrTranscriptMapper.SourceCues(
            transcript,
            "RADWIMPS - 前前前世").Select(cue => cue.Text));

        Assert.Contains("やっと目を覚ました", joined, StringComparison.Ordinal);
        Assert.Contains("何億何光年分", joined, StringComparison.Ordinal);
        Assert.DoesNotContain("ご視聴ありがとうございました", joined, StringComparison.Ordinal);
    }

    [Fact]
    public void JapaneseLyricsDropsIntroHallucinationAndMergesLeadingOrphans()
    {
        var transcript = new AsrTranscript
        {
            Id = "radwimps-intro-leading-orphans",
            LanguageCode = "ja",
            DurationSeconds = 130.0,
            SourceModelId = "whisper.cpp:test",
            Words =
            [
                new() { Text = "彼女の", StartSeconds = 0.00, EndSeconds = 3.46 },
                new() { Text = "やっと目を覚ましたかい", StartSeconds = 20.94, EndSeconds = 25.32 },
                new() { Text = "ど", StartSeconds = 104.84, EndSeconds = 105.22 },
                new() { Text = "っ", StartSeconds = 105.22, EndSeconds = 105.60 },
                new() { Text = "から話すかな君が眠っていた", StartSeconds = 106.36, EndSeconds = 110.47 },
                new() { Text = "何", StartSeconds = 114.96, EndSeconds = 115.86 },
                new() { Text = "億何光年分の物語を", StartSeconds = 116.53, EndSeconds = 121.28 },
            ],
        };

        var cues = AsrTranscriptMapper.SourceCues(transcript, SubtitleTimingProfile.JapaneseLyrics);
        var joined = string.Join(" ", cues.Select(cue => cue.Text));

        Assert.DoesNotContain("彼女の", joined, StringComparison.Ordinal);
        Assert.DoesNotContain(cues, cue => cue.Text == "ど");
        Assert.DoesNotContain(cues, cue => cue.Text == "何");
        Assert.Contains("どから話すかな", joined, StringComparison.Ordinal);
        Assert.Contains("何億何光年分", joined, StringComparison.Ordinal);
    }

    [Fact]
    public void LocalAsrDetectorRoutesJapaneseLiveTitleAndDropsTerminalThanks()
    {
        var transcript = new AsrTranscript
        {
            Id = "japanese-live-terminal-thanks",
            LanguageCode = "ja",
            DurationSeconds = 130.0,
            SourceModelId = "whisper.cpp:test",
            Words =
            [
                new() { Text = "暗闇の中に切り締めた", StartSeconds = 108.20, EndSeconds = 113.49 },
                new() { Text = "ご", StartSeconds = 113.50, EndSeconds = 113.91 },
                new() { Text = "視", StartSeconds = 113.91, EndSeconds = 114.32 },
                new() { Text = "聴", StartSeconds = 114.32, EndSeconds = 114.72 },
                new() { Text = "ありがとうございました", StartSeconds = 114.72, EndSeconds = 119.30 },
            ],
        };

        var joined = string.Join(" ", AsrTranscriptMapper.SourceCues(
            transcript,
            "YOASOBI - 優しい彗星 live").Select(cue => cue.Text));

        Assert.Contains("暗闇の中", joined, StringComparison.Ordinal);
        Assert.DoesNotContain("ご視聴", joined, StringComparison.Ordinal);
        Assert.DoesNotContain("ありがとうございました", joined, StringComparison.Ordinal);
    }

    [Fact]
    public void LocalAsrDetectorRoutesIntroBgmHallucinationToLyricsProfile()
    {
        var transcript = new AsrTranscript
        {
            Id = "kanden-intro-bgm",
            LanguageCode = "ja",
            DurationSeconds = 130.0,
            SourceModelId = "whisper.cpp:test",
            Words =
            [
                new() { Text = "B", StartSeconds = 0.22, EndSeconds = 6.66 },
                new() { Text = "GM", StartSeconds = 6.66, EndSeconds = 20.00 },
                new() { Text = "逃げ出したい夜のオンライン", StartSeconds = 20.14, EndSeconds = 23.86 },
            ],
        };

        var joined = string.Join(" ", AsrTranscriptMapper.SourceCues(
            transcript,
            "Kenshi Yonezu - Kanden").Select(cue => cue.Text));

        Assert.DoesNotContain("B", joined, StringComparison.Ordinal);
        Assert.DoesNotContain("GM", joined, StringComparison.Ordinal);
        Assert.Contains("逃げ出したい", joined, StringComparison.Ordinal);
    }

    [Fact]
    public void JapaneseLyricsSuppressesApproximateLoopHallucinationIsland()
    {
        var transcript = new AsrTranscript
        {
            Id = "yasashii-suisei-loop-hallucination",
            LanguageCode = "ja",
            DurationSeconds = 222.0,
            SourceModelId = "whisper.cpp:test",
            Words =
            [
                new() { Text = "幸せだった確かにほら救わ", StartSeconds = 117.28, EndSeconds = 121.08 },
                new() { Text = "れたんだよ、あなたに", StartSeconds = 121.16, EndSeconds = 126.71 },
                new() { Text = "あも恵み合わせ、なたにばどうしよう、あなたにも", StartSeconds = 131.22, EndSeconds = 132.42 },
                new() { Text = "恵み合わせあなたに、恵もわみ合なたせあにも", StartSeconds = 132.50, EndSeconds = 133.40 },
                new() { Text = "恵み合わせあなたにも、恵み合わせあなたにも", StartSeconds = 133.48, EndSeconds = 135.10 },
                new() { Text = "恵み合せわ、あなたに", StartSeconds = 135.18, EndSeconds = 137.22 },
                new() { Text = "も恵み合わせあなた", StartSeconds = 137.30, EndSeconds = 138.048 },
                new() { Text = "にも、恵み合わせあ", StartSeconds = 138.048, EndSeconds = 138.795 },
                new() { Text = "なた恵にもわみ合せあ", StartSeconds = 138.795, EndSeconds = 151.48 },
                new() { Text = "なたにも恵み合わせ、あなた", StartSeconds = 156.82, EndSeconds = 157.72 },
                new() { Text = "にも恵み合わせ、あなた", StartSeconds = 158.34, EndSeconds = 159.24 },
                new() { Text = "ありがとうございました。", StartSeconds = 220.76, EndSeconds = 221.95 },
            ],
        };

        var cues = AsrTranscriptMapper.SourceCues(transcript, SubtitleTimingProfile.JapaneseLyrics);
        var joined = string.Join(' ', cues.Select(cue => cue.Text));

        Assert.Contains("れたんだよ、あなたに", joined, StringComparison.Ordinal);
        Assert.Contains("ありがとうございました", joined, StringComparison.Ordinal);
        Assert.DoesNotContain("恵み合わせ", joined, StringComparison.Ordinal);
        Assert.DoesNotContain("なたにも恵み", joined, StringComparison.Ordinal);
    }

    [Fact]
    public void JapaneseLyricsKeepsReadableRepeatedChorusLines()
    {
        var words = new List<AsrWord>();
        for (var repeatIndex = 0; repeatIndex < 5; repeatIndex++)
        {
            var start = repeatIndex * 4.0;
            words.Add(new AsrWord { Text = "好きだよ", StartSeconds = start, EndSeconds = start + 1.2 });
        }
        var transcript = new AsrTranscript
        {
            Id = "readable-repeated-chorus",
            LanguageCode = "ja",
            Words = words,
            SourceModelId = "whisper.cpp:test",
        };

        var joined = string.Join(' ', AsrTranscriptMapper.SourceCues(
            transcript,
            SubtitleTimingProfile.JapaneseLyrics).Select(cue => cue.Text));
        var repeatCount = joined.Split("好きだよ", StringSplitOptions.None).Length - 1;

        Assert.Equal(5, repeatCount);
    }

    [Fact]
    public void JapaneseLyricsSuppressesApproximateDuplicateInsideCue()
    {
        var transcript = new AsrTranscript
        {
            Id = "gunjou-internal-duplicate-noise",
            LanguageCode = "ja",
            DurationSeconds = 140.0,
            SourceModelId = "whisper.cpp:test",
            Words =
            [
                new AsrWord
                {
                    Text = "好きなことを続けること、好こときをな続ことける、そ",
                    StartSeconds = 119.88,
                    EndSeconds = 124.62,
                },
                new AsrWord
                {
                    Text = "れは楽しいだけじゃない、本当にできる不安になけどる。",
                    StartSeconds = 124.62,
                    EndSeconds = 130.46,
                },
                new AsrWord
                {
                    Text = "ああ、何枚でもほら、何枚でもでもら枚",
                    StartSeconds = 130.88,
                    EndSeconds = 133.85,
                },
            ],
        };

        var joined = string.Join(" ", AsrTranscriptMapper.SourceCues(
            transcript,
            SubtitleTimingProfile.JapaneseLyrics).Select(cue => cue.Text));

        Assert.Contains("好きなことを続けること", joined, StringComparison.Ordinal);
        Assert.Contains("何枚でもほら", joined, StringComparison.Ordinal);
        Assert.DoesNotContain("好こときをな続ことける", joined, StringComparison.Ordinal);
        Assert.DoesNotContain("何枚でもでもら枚", joined, StringComparison.Ordinal);
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
    public void LocalAsrTimingPlannerKeepsSpacesBetweenEnglishPronounPhrases()
    {
        var transcript = new AsrTranscript
        {
            Id = "english-pronoun-spacing",
            LanguageCode = "en",
            Words =
            [
                new AsrWord { Text = "I", StartSeconds = 0.0, EndSeconds = 0.1 },
                new AsrWord { Text = "have", StartSeconds = 0.1, EndSeconds = 0.35 },
                new AsrWord { Text = "ideas.", StartSeconds = 0.35, EndSeconds = 0.6 },
                new AsrWord { Text = "I", StartSeconds = 0.7, EndSeconds = 0.8 },
                new AsrWord { Text = "find", StartSeconds = 0.8, EndSeconds = 1.05 },
                new AsrWord { Text = "patterns.", StartSeconds = 1.05, EndSeconds = 1.35 },
                new AsrWord { Text = "I", StartSeconds = 1.45, EndSeconds = 1.55 },
                new AsrWord { Text = "think", StartSeconds = 1.55, EndSeconds = 1.8 },
                new AsrWord { Text = "fast.", StartSeconds = 1.8, EndSeconds = 2.05 },
                new AsrWord { Text = "Am", StartSeconds = 2.15, EndSeconds = 2.35 },
                new AsrWord { Text = "I", StartSeconds = 2.35, EndSeconds = 2.45 },
                new AsrWord { Text = "right?", StartSeconds = 2.45, EndSeconds = 2.8 },
                new AsrWord { Text = "I", StartSeconds = 2.9, EndSeconds = 3.0 },
                new AsrWord { Text = "'m", StartSeconds = 3.0, EndSeconds = 3.12 },
                new AsrWord { Text = "ready.", StartSeconds = 3.12, EndSeconds = 3.4 },
            ],
            SourceModelId = "whisper.cpp:test",
        };

        var text = string.Join(" ", AsrTranscriptMapper.SourceCues(transcript).Select(cue => cue.Text));

        Assert.Contains("I have", text, StringComparison.Ordinal);
        Assert.Contains("I find", text, StringComparison.Ordinal);
        Assert.Contains("I think", text, StringComparison.Ordinal);
        Assert.Contains("Am I right?", text, StringComparison.Ordinal);
        Assert.Contains("I'm ready.", text, StringComparison.Ordinal);
        Assert.DoesNotContain("Ihave", text, StringComparison.Ordinal);
        Assert.DoesNotContain("Ifind", text, StringComparison.Ordinal);
        Assert.DoesNotContain("Ithink", text, StringComparison.Ordinal);
        Assert.DoesNotContain("Iright", text, StringComparison.Ordinal);
        Assert.DoesNotContain("I 'm", text, StringComparison.Ordinal);
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
    public void LocalAsrTimingPlannerKeepsSpacesBetweenKoreanWords()
    {
        var transcript = new AsrTranscript
        {
            Id = "korean-spacing",
            LanguageCode = "ko",
            Words =
            [
                new AsrWord { Text = "수학을", StartSeconds = 0.0, EndSeconds = 0.4 },
                new AsrWord { Text = "포기하면", StartSeconds = 0.4, EndSeconds = 0.9 },
                new AsrWord { Text = "대학을", StartSeconds = 0.9, EndSeconds = 1.3 },
                new AsrWord { Text = "포기하는", StartSeconds = 1.3, EndSeconds = 1.8 },
                new AsrWord { Text = "것이고요", StartSeconds = 1.8, EndSeconds = 2.3 },
                new AsrWord { Text = "영어를", StartSeconds = 2.3, EndSeconds = 2.7 },
                new AsrWord { Text = "포기하면", StartSeconds = 2.7, EndSeconds = 3.2 },
                new AsrWord { Text = "인생을", StartSeconds = 3.2, EndSeconds = 3.6 },
                new AsrWord { Text = "포기하는이라", StartSeconds = 3.6, EndSeconds = 4.3 },
            ],
            SourceModelId = "whisper.cpp:test",
        };

        var text = string.Join(" ", AsrTranscriptMapper.SourceCues(transcript).Select(cue => cue.Text));

        Assert.Contains("수학을 포기하면 대학을", text, StringComparison.Ordinal);
        Assert.Contains("영어를 포기하면 인생을", text, StringComparison.Ordinal);
        Assert.DoesNotContain("수학을포기하면", text, StringComparison.Ordinal);
        Assert.DoesNotContain("영어를포기하면", text, StringComparison.Ordinal);
    }

    [Fact]
    public void LocalAsrTimingPlannerKeepsSpacesBetweenDevanagariWords()
    {
        var transcript = new AsrTranscript
        {
            Id = "devanagari-spacing",
            LanguageCode = "hi",
            Words =
            [
                new AsrWord { Text = "जिसकी", StartSeconds = 0.0, EndSeconds = 0.45 },
                new AsrWord { Text = "तुलना", StartSeconds = 0.45, EndSeconds = 0.9 },
                new AsrWord { Text = "फिर", StartSeconds = 0.9, EndSeconds = 1.2 },
                new AsrWord { Text = "नहीं", StartSeconds = 1.2, EndSeconds = 1.5 },
                new AsrWord { Text = "की", StartSeconds = 1.5, EndSeconds = 1.7 },
                new AsrWord { Text = "जाएगी", StartSeconds = 1.7, EndSeconds = 2.1 },
            ],
            SourceModelId = "whisper.cpp:test",
        };

        var text = string.Join(" ", AsrTranscriptMapper.SourceCues(transcript).Select(cue => cue.Text));

        Assert.Contains("जिसकी तुलना फिर", text, StringComparison.Ordinal);
        Assert.Contains("नहीं की जाएगी", text, StringComparison.Ordinal);
        Assert.DoesNotContain("जिसकीतुलना", text, StringComparison.Ordinal);
        Assert.DoesNotContain("कीजाएगी", text, StringComparison.Ordinal);
    }

    [Fact]
    public void LocalAsrTimingPlannerKeepsSpacesBetweenSpacedNonLatinScripts()
    {
        // Arabic (RTL), Cyrillic, and Bengali are all space-separated word scripts like Devanagari.
        static string Joined(string language, (string Text, double Start, double End)[] words)
        {
            var transcript = new AsrTranscript
            {
                Id = $"spaced-{language}",
                LanguageCode = language,
                Words = words.Select(w => new AsrWord { Text = w.Text, StartSeconds = w.Start, EndSeconds = w.End }).ToList(),
                SourceModelId = "whisper.cpp:test",
            };
            return string.Join(" ", AsrTranscriptMapper.SourceCues(transcript).Select(cue => cue.Text));
        }

        var ru = Joined("ru", [("Привет", 0.0, 0.4), ("мир", 0.4, 0.8), ("как", 0.8, 1.1), ("дела", 1.1, 1.5)]);
        Assert.Contains("Привет мир как дела", ru, StringComparison.Ordinal);
        Assert.DoesNotContain("Приветмир", ru, StringComparison.Ordinal);

        var ar = Joined("ar", [("مرحبا", 0.0, 0.4), ("بالعالم", 0.4, 0.9), ("كيف", 0.9, 1.2), ("حالك", 1.2, 1.6)]);
        Assert.Contains("مرحبا بالعالم كيف حالك", ar, StringComparison.Ordinal);
        Assert.DoesNotContain("مرحبابالعالم", ar, StringComparison.Ordinal);

        var bn = Joined("bn", [("নমস্কার", 0.0, 0.5), ("বিশ্ব", 0.5, 0.9), ("কেমন", 0.9, 1.3), ("আছেন", 1.3, 1.7)]);
        Assert.Contains("নমস্কার বিশ্ব কেমন আছেন", bn, StringComparison.Ordinal);
        Assert.DoesNotContain("নমস্কারবিশ্ব", bn, StringComparison.Ordinal);
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
    public void LocalAsrTimingPlannerRejoinsItalianGermanFrenchSubwords()
    {
        // M4: università (ità), abandonné (né), gemütlich (lich) sub-word splits must rejoin.
        var transcript = new AsrTranscript
        {
            Id = "itdefr-subwords",
            LanguageCode = "it",
            Words =
            [
                new AsrWord { Text = "la", StartSeconds = 0.0, EndSeconds = 0.15 },
                new AsrWord { Text = "univers", StartSeconds = 0.15, EndSeconds = 0.45 },
                new AsrWord { Text = "ità", StartSeconds = 0.45, EndSeconds = 0.7 },
                new AsrWord { Text = "è", StartSeconds = 0.7, EndSeconds = 0.8 },
                new AsrWord { Text = "abandon", StartSeconds = 0.8, EndSeconds = 1.1 },
                new AsrWord { Text = "né", StartSeconds = 1.1, EndSeconds = 1.3 },
                new AsrWord { Text = "und", StartSeconds = 1.3, EndSeconds = 1.45 },
                new AsrWord { Text = "gemüt", StartSeconds = 1.45, EndSeconds = 1.7 },
                new AsrWord { Text = "lich", StartSeconds = 1.7, EndSeconds = 1.95 },
            ],
            SourceModelId = "whisper.cpp:test",
        };
        var text = string.Join(" ", AsrTranscriptMapper.SourceCues(transcript).Select(c => c.Text));
        Assert.Contains("università", text, StringComparison.Ordinal);
        Assert.Contains("abandonné", text, StringComparison.Ordinal);
        Assert.Contains("gemütlich", text, StringComparison.Ordinal);
        Assert.DoesNotContain("univers ità", text, StringComparison.Ordinal);
        Assert.DoesNotContain("abandon né", text, StringComparison.Ordinal);
        Assert.DoesNotContain("gemüt lich", text, StringComparison.Ordinal);
    }

    [Fact]
    public void LocalAsrTimingPlannerRejoinsObservedFrenchItalianSubwords()
    {
        var transcript = new AsrTranscript
        {
            Id = "observed-it-fr-subwords",
            LanguageCode = "fr",
            Words =
            [
                new AsrWord { Text = "travaill", StartSeconds = 0.0, EndSeconds = 0.2 },
                new AsrWord { Text = "é", StartSeconds = 0.2, EndSeconds = 0.3 },
                new AsrWord { Text = "arr", StartSeconds = 0.4, EndSeconds = 0.55 },
                new AsrWord { Text = "ach", StartSeconds = 0.55, EndSeconds = 0.75 },
                new AsrWord { Text = "ée", StartSeconds = 0.75, EndSeconds = 0.9 },
                new AsrWord { Text = "cré", StartSeconds = 1.0, EndSeconds = 1.2 },
                new AsrWord { Text = "at", StartSeconds = 1.2, EndSeconds = 1.35 },
                new AsrWord { Text = "rice", StartSeconds = 1.35, EndSeconds = 1.6 },
                new AsrWord { Text = "magg", StartSeconds = 1.7, EndSeconds = 1.9 },
                new AsrWord { Text = "ior", StartSeconds = 1.9, EndSeconds = 2.05 },
                new AsrWord { Text = "i", StartSeconds = 2.05, EndSeconds = 2.15 },
                new AsrWord { Text = "most", StartSeconds = 2.25, EndSeconds = 2.45 },
                new AsrWord { Text = "r", StartSeconds = 2.45, EndSeconds = 2.55 },
                new AsrWord { Text = "ano", StartSeconds = 2.55, EndSeconds = 2.8 },
                new AsrWord { Text = " arrive", StartSeconds = 3.0, EndSeconds = 3.25 },
                new AsrWord { Text = " at", StartSeconds = 3.25, EndSeconds = 3.35 },
                new AsrWord { Text = " rice", StartSeconds = 3.35, EndSeconds = 3.6 },
            ],
            SourceModelId = "whisper.cpp:test",
        };

        var text = string.Join(" ", AsrTranscriptMapper.SourceCues(transcript).Select(c => c.Text));

        Assert.Contains("travaillé", text, StringComparison.Ordinal);
        Assert.Contains("arrachée", text, StringComparison.Ordinal);
        Assert.Contains("créatrice", text, StringComparison.Ordinal);
        Assert.Contains("maggiori", text, StringComparison.Ordinal);
        Assert.Contains("mostrano", text, StringComparison.Ordinal);
        Assert.Contains("arrive at rice", text, StringComparison.Ordinal);
        Assert.DoesNotContain("travaill é", text, StringComparison.Ordinal);
        Assert.DoesNotContain("arr ach ée", text, StringComparison.Ordinal);
        Assert.DoesNotContain("cré at rice", text, StringComparison.Ordinal);
        Assert.DoesNotContain("magg ior i", text, StringComparison.Ordinal);
        Assert.DoesNotContain("most r ano", text, StringComparison.Ordinal);
        Assert.DoesNotContain("arriveatrice", text, StringComparison.Ordinal);
    }

    [Fact]
    public void LocalAsrTimingPlannerRejoinsObservedFrenchItalianSubwordsSecondWave()
    {
        var transcript = new AsrTranscript
        {
            Id = "observed-it-fr-subwords-2",
            LanguageCode = "it",
            Words =
            [
                new AsrWord { Text = "d", StartSeconds = 0.0, EndSeconds = 0.1 },
                new AsrWord { Text = "ix", StartSeconds = 0.1, EndSeconds = 0.2 },
                new AsrWord { Text = "sé", StartSeconds = 0.3, EndSeconds = 0.45 },
                new AsrWord { Text = "lection", StartSeconds = 0.45, EndSeconds = 0.65 },
                new AsrWord { Text = "n", StartSeconds = 0.65, EndSeconds = 0.75 },
                new AsrWord { Text = "ée", StartSeconds = 0.75, EndSeconds = 0.9 },
                new AsrWord { Text = "h", StartSeconds = 1.0, EndSeconds = 1.1 },
                new AsrWord { Text = "onn", StartSeconds = 1.1, EndSeconds = 1.25 },
                new AsrWord { Text = "êt", StartSeconds = 1.25, EndSeconds = 1.4 },
                new AsrWord { Text = "eté", StartSeconds = 1.4, EndSeconds = 1.6 },
                new AsrWord { Text = "org", StartSeconds = 1.7, EndSeconds = 1.85 },
                new AsrWord { Text = "og", StartSeconds = 1.85, EndSeconds = 2.0 },
                new AsrWord { Text = "lio", StartSeconds = 2.0, EndSeconds = 2.2 },
                new AsrWord { Text = "lat", StartSeconds = 2.3, EndSeconds = 2.45 },
                new AsrWord { Text = "ino", StartSeconds = 2.45, EndSeconds = 2.65 },
                new AsrWord { Text = "St", StartSeconds = 2.75, EndSeconds = 2.85 },
                new AsrWord { Text = "ati", StartSeconds = 2.85, EndSeconds = 3.05 },
                new AsrWord { Text = "Un", StartSeconds = 3.15, EndSeconds = 3.25 },
                new AsrWord { Text = "iti", StartSeconds = 3.25, EndSeconds = 3.45 },
                new AsrWord { Text = "Par", StartSeconds = 3.55, EndSeconds = 3.7 },
                new AsrWord { Text = "igi", StartSeconds = 3.7, EndSeconds = 3.9 },
                new AsrWord { Text = "no", StartSeconds = 4.0, EndSeconds = 4.15 },
                new AsrWord { Text = " entiendo", StartSeconds = 4.15, EndSeconds = 4.45 },
            ],
            SourceModelId = "whisper.cpp:test",
        };

        var text = string.Join(" ", AsrTranscriptMapper.SourceCues(transcript).Select(c => c.Text));

        Assert.Contains("dix", text, StringComparison.Ordinal);
        Assert.Contains("sélectionnée", text, StringComparison.Ordinal);
        Assert.Contains("honnêteté", text, StringComparison.Ordinal);
        Assert.Contains("orgoglio", text, StringComparison.Ordinal);
        Assert.Contains("latino", text, StringComparison.Ordinal);
        Assert.Contains("Stati", text, StringComparison.Ordinal);
        Assert.Contains("Uniti", text, StringComparison.Ordinal);
        Assert.Contains("Parigi", text, StringComparison.Ordinal);
        Assert.Contains("no entiendo", text, StringComparison.Ordinal);
        Assert.DoesNotContain("d ix", text, StringComparison.Ordinal);
        Assert.DoesNotContain("sé lection n ée", text, StringComparison.Ordinal);
        Assert.DoesNotContain("h onn êt eté", text, StringComparison.Ordinal);
        Assert.DoesNotContain("org og lio", text, StringComparison.Ordinal);
        Assert.DoesNotContain("lat ino", text, StringComparison.Ordinal);
        Assert.DoesNotContain("St ati", text, StringComparison.Ordinal);
        Assert.DoesNotContain("Un iti", text, StringComparison.Ordinal);
        Assert.DoesNotContain("Par igi", text, StringComparison.Ordinal);
        Assert.DoesNotContain("noentiendo", text, StringComparison.Ordinal);
    }

    [Fact]
    public void LocalAsrTimingPlannerRejoinsObservedFrenchItalianSubwordsThirdWave()
    {
        var transcript = new AsrTranscript
        {
            Id = "observed-it-fr-subwords-3",
            LanguageCode = "fr",
            Words =
            [
                new AsrWord { Text = "Ut", StartSeconds = 0.0, EndSeconds = 0.1 },
                new AsrWord { Text = "il", StartSeconds = 0.1, EndSeconds = 0.2 },
                new AsrWord { Text = "ise", StartSeconds = 0.2, EndSeconds = 0.35 },
                new AsrWord { Text = "r", StartSeconds = 0.45, EndSeconds = 0.5 },
                new AsrWord { Text = "è", StartSeconds = 0.5, EndSeconds = 0.58 },
                new AsrWord { Text = "gl", StartSeconds = 0.58, EndSeconds = 0.68 },
                new AsrWord { Text = "és", StartSeconds = 0.68, EndSeconds = 0.82 },
                new AsrWord { Text = "app", StartSeconds = 0.92, EndSeconds = 1.05 },
                new AsrWord { Text = "li", StartSeconds = 1.05, EndSeconds = 1.15 },
                new AsrWord { Text = "quer", StartSeconds = 1.15, EndSeconds = 1.35 },
                new AsrWord { Text = "quotid", StartSeconds = 1.45, EndSeconds = 1.65 },
                new AsrWord { Text = "ien", StartSeconds = 1.65, EndSeconds = 1.8 },
                new AsrWord { Text = "mar", StartSeconds = 1.9, EndSeconds = 2.05 },
                new AsrWord { Text = "ion", StartSeconds = 2.05, EndSeconds = 2.2 },
                new AsrWord { Text = "n", StartSeconds = 2.2, EndSeconds = 2.3 },
                new AsrWord { Text = "ette", StartSeconds = 2.3, EndSeconds = 2.5 },
                new AsrWord { Text = "op", StartSeconds = 2.6, EndSeconds = 2.75 },
                new AsrWord { Text = "in", StartSeconds = 2.75, EndSeconds = 2.9 },
                new AsrWord { Text = "ion", StartSeconds = 2.9, EndSeconds = 3.1 },
                new AsrWord { Text = "Reg", StartSeconds = 3.2, EndSeconds = 3.35 },
                new AsrWord { Text = "no", StartSeconds = 3.35, EndSeconds = 3.5 },
                new AsrWord { Text = "Un", StartSeconds = 3.6, EndSeconds = 3.75 },
                new AsrWord { Text = "ito", StartSeconds = 3.75, EndSeconds = 3.95 },
                new AsrWord { Text = "Lond", StartSeconds = 4.05, EndSeconds = 4.25 },
                new AsrWord { Text = "ra", StartSeconds = 4.25, EndSeconds = 4.4 },
                new AsrWord { Text = "Core", StartSeconds = 4.5, EndSeconds = 4.7 },
                new AsrWord { Text = "a", StartSeconds = 4.7, EndSeconds = 4.85 },
                new AsrWord { Text = "Svez", StartSeconds = 4.95, EndSeconds = 5.15 },
                new AsrWord { Text = "ia", StartSeconds = 5.15, EndSeconds = 5.3 },
                new AsrWord { Text = "orgog", StartSeconds = 5.4, EndSeconds = 5.65 },
                new AsrWord { Text = "li", StartSeconds = 5.65, EndSeconds = 5.75 },
                new AsrWord { Text = "os", StartSeconds = 5.75, EndSeconds = 5.9 },
                new AsrWord { Text = "amente", StartSeconds = 5.9, EndSeconds = 6.2 },
                new AsrWord { Text = "par", StartSeconds = 6.3, EndSeconds = 6.45 },
                new AsrWord { Text = "la", StartSeconds = 6.45, EndSeconds = 6.6 },
                new AsrWord { Text = "route", StartSeconds = 6.6, EndSeconds = 6.85 },
            ],
            SourceModelId = "whisper.cpp:test",
        };

        var text = string.Join(" ", AsrTranscriptMapper.SourceCues(transcript).Select(cue => cue.Text));

        Assert.Contains("Utilise", text, StringComparison.Ordinal);
        Assert.Contains("règlés", text, StringComparison.Ordinal);
        Assert.Contains("appliquer", text, StringComparison.Ordinal);
        Assert.Contains("quotidien", text, StringComparison.Ordinal);
        Assert.Contains("marionnette", text, StringComparison.Ordinal);
        Assert.Contains("opinion", text, StringComparison.Ordinal);
        Assert.Contains("Regno", text, StringComparison.Ordinal);
        Assert.Contains("Unito", text, StringComparison.Ordinal);
        Assert.Contains("Londra", text, StringComparison.Ordinal);
        Assert.Contains("Svezia", text, StringComparison.Ordinal);
        Assert.Contains("orgogliosamente", text, StringComparison.Ordinal);
        Assert.Contains("par la route", text, StringComparison.Ordinal);
        Assert.DoesNotContain("Ut il ise", text, StringComparison.Ordinal);
        Assert.DoesNotContain("r è gl és", text, StringComparison.Ordinal);
        Assert.DoesNotContain("app li quer", text, StringComparison.Ordinal);
        Assert.DoesNotContain("quotid ien", text, StringComparison.Ordinal);
        Assert.DoesNotContain("mar ion n ette", text, StringComparison.Ordinal);
        Assert.DoesNotContain("op in ion", text, StringComparison.Ordinal);
        Assert.DoesNotContain("Reg no", text, StringComparison.Ordinal);
        Assert.DoesNotContain("Un ito", text, StringComparison.Ordinal);
        Assert.DoesNotContain("Lond ra", text, StringComparison.Ordinal);
        Assert.DoesNotContain("Svez ia", text, StringComparison.Ordinal);
        Assert.DoesNotContain("orgog li os amente", text, StringComparison.Ordinal);
        Assert.DoesNotContain("parlaroute", text, StringComparison.Ordinal);
    }

    // Regression for the observed-continuation over-join bug: the tables must not glue a complete
    // left word to a following function word just because the word's tail happens to end in a
    // listed fragment. "stop"+"in", "core"+"a", "develop"+"in" are separate words, not sub-words.
    [Fact]
    public void LocalAsrTimingPlannerDoesNotGlueCompleteWordsToFollowingFunctionWords()
    {
        var transcript = new AsrTranscript
        {
            Id = "observed-no-overjoin-en-fr",
            LanguageCode = "en",
            Words = new List<AsrWord>
            {
                new AsrWord { Text = "we", StartSeconds = 0.0, EndSeconds = 0.2 },
                new AsrWord { Text = " stop", StartSeconds = 0.2, EndSeconds = 0.5 },
                new AsrWord { Text = " in", StartSeconds = 0.5, EndSeconds = 0.7 },
                new AsrWord { Text = " Paris", StartSeconds = 0.7, EndSeconds = 1.1 },
                new AsrWord { Text = " at", StartSeconds = 1.2, EndSeconds = 1.5 },
                new AsrWord { Text = " its", StartSeconds = 1.5, EndSeconds = 1.8 },
                new AsrWord { Text = " core", StartSeconds = 1.8, EndSeconds = 2.1 },
                new AsrWord { Text = " a", StartSeconds = 2.1, EndSeconds = 2.3 },
                new AsrWord { Text = " simple", StartSeconds = 2.3, EndSeconds = 2.7 },
                new AsrWord { Text = " idea", StartSeconds = 2.7, EndSeconds = 3.0 },
                new AsrWord { Text = " we", StartSeconds = 3.1, EndSeconds = 3.3 },
                new AsrWord { Text = " develop", StartSeconds = 3.3, EndSeconds = 3.7 },
                new AsrWord { Text = " in", StartSeconds = 3.7, EndSeconds = 3.9 },
                new AsrWord { Text = " town", StartSeconds = 3.9, EndSeconds = 4.2 },
            },
            SourceModelId = "whisper.cpp:test",
        };

        var text = string.Join(" ", AsrTranscriptMapper.SourceCues(transcript).Select(c => c.Text));

        Assert.Contains("stop in", text, StringComparison.Ordinal);
        Assert.Contains("core a", text, StringComparison.Ordinal);
        Assert.Contains("develop in", text, StringComparison.Ordinal);
        Assert.DoesNotContain("stopin", text, StringComparison.Ordinal);
        Assert.DoesNotContain("corea", text, StringComparison.Ordinal);
        Assert.DoesNotContain("developin", text, StringComparison.Ordinal);
    }

    [Fact]
    public void LocalAsrTimingPlannerPreservesObservedFrenchItalianFunctionWords()
    {
        var transcript = new AsrTranscript
        {
            Id = "observed-it-fr-function-words",
            LanguageCode = "it",
            Words =
            [
                new AsrWord { Text = "Un", StartSeconds = 0.0, EndSeconds = 0.1 },
                new AsrWord { Text = "ito", StartSeconds = 0.1, EndSeconds = 0.25 },
                new AsrWord { Text = "al", StartSeconds = 0.25, EndSeconds = 0.35 },
                new AsrWord { Text = "King's", StartSeconds = 0.35, EndSeconds = 0.6 },
                new AsrWord { Text = "Unito", StartSeconds = 0.7, EndSeconds = 0.95 },
                new AsrWord { Text = "al", StartSeconds = 0.95, EndSeconds = 1.05 },
                new AsrWord { Text = "King's", StartSeconds = 1.05, EndSeconds = 1.3 },
                new AsrWord { Text = "posto", StartSeconds = 1.4, EndSeconds = 1.6 },
                new AsrWord { Text = "al", StartSeconds = 1.6, EndSeconds = 1.7 },
                new AsrWord { Text = "mondo", StartSeconds = 1.7, EndSeconds = 1.95 },
                new AsrWord { Text = "influencer", StartSeconds = 2.05, EndSeconds = 2.3 },
                new AsrWord { Text = "en", StartSeconds = 2.3, EndSeconds = 2.42 },
                new AsrWord { Text = "bien", StartSeconds = 2.42, EndSeconds = 2.6 },
                new AsrWord { Text = "prendre", StartSeconds = 2.7, EndSeconds = 2.9 },
                new AsrWord { Text = "en", StartSeconds = 2.9, EndSeconds = 3.02 },
                new AsrWord { Text = "compte", StartSeconds = 3.02, EndSeconds = 3.25 },
                new AsrWord { Text = "qui", StartSeconds = 3.35, EndSeconds = 3.48 },
                new AsrWord { Text = "ne", StartSeconds = 3.48, EndSeconds = 3.6 },
                new AsrWord { Text = "correspondait", StartSeconds = 3.6, EndSeconds = 3.9 },
                new AsrWord { Text = "Ker", StartSeconds = 4.0, EndSeconds = 4.15 },
                new AsrWord { Text = "ne", StartSeconds = 4.15, EndSeconds = 4.3 },
            ],
            SourceModelId = "whisper.cpp:test",
        };

        var text = string.Join(" ", AsrTranscriptMapper.SourceCues(transcript).Select(cue => cue.Text));

        Assert.Contains("Unito al King's", text, StringComparison.Ordinal);
        Assert.Contains("posto al mondo", text, StringComparison.Ordinal);
        Assert.Contains("influencer en bien", text, StringComparison.Ordinal);
        Assert.Contains("prendre en compte", text, StringComparison.Ordinal);
        Assert.Contains("qui ne correspondait", text, StringComparison.Ordinal);
        Assert.Contains("Kerne", text, StringComparison.Ordinal);
        Assert.DoesNotContain("Unitoal", text, StringComparison.Ordinal);
        Assert.DoesNotContain("postoal", text, StringComparison.Ordinal);
        Assert.DoesNotContain("influenceren", text, StringComparison.Ordinal);
        Assert.DoesNotContain("prendreen", text, StringComparison.Ordinal);
        Assert.DoesNotContain("quine", text, StringComparison.Ordinal);
        Assert.DoesNotContain("Ker ne", text, StringComparison.Ordinal);
    }

    [Fact]
    public void LocalAsrTimingPlannerRejoinsObservedGermanPortugueseSubwords()
    {
        var transcript = new AsrTranscript
        {
            Id = "observed-de-pt-subwords",
            LanguageCode = "pt",
            Words =
            [
                new AsrWord { Text = "gem", StartSeconds = 0.0, EndSeconds = 0.1 },
                new AsrWord { Text = "üt", StartSeconds = 0.1, EndSeconds = 0.18 },
                new AsrWord { Text = "lich", StartSeconds = 0.18, EndSeconds = 0.25 },
                new AsrWord { Text = "reg", StartSeconds = 0.3, EndSeconds = 0.45 },
                new AsrWord { Text = "elt", StartSeconds = 0.45, EndSeconds = 0.6 },
                new AsrWord { Text = "bef", StartSeconds = 0.7, EndSeconds = 0.85 },
                new AsrWord { Text = "est", StartSeconds = 0.85, EndSeconds = 1.0 },
                new AsrWord { Text = "igt", StartSeconds = 1.0, EndSeconds = 1.15 },
                new AsrWord { Text = "Seiten", StartSeconds = 1.25, EndSeconds = 1.45 },
                new AsrWord { Text = "ver", StartSeconds = 1.45, EndSeconds = 1.55 },
                new AsrWord { Text = "kle", StartSeconds = 1.55, EndSeconds = 1.65 },
                new AsrWord { Text = "id", StartSeconds = 1.65, EndSeconds = 1.75 },
                new AsrWord { Text = "ung", StartSeconds = 1.75, EndSeconds = 1.9 },
                new AsrWord { Text = "G", StartSeconds = 2.0, EndSeconds = 2.05 },
                new AsrWord { Text = "ep", StartSeconds = 2.05, EndSeconds = 2.15 },
                new AsrWord { Text = "ä", StartSeconds = 2.15, EndSeconds = 2.25 },
                new AsrWord { Text = "ck", StartSeconds = 2.25, EndSeconds = 2.35 },
                new AsrWord { Text = "f", StartSeconds = 2.35, EndSeconds = 2.45 },
                new AsrWord { Text = "ä", StartSeconds = 2.45, EndSeconds = 2.55 },
                new AsrWord { Text = "cher", StartSeconds = 2.55, EndSeconds = 2.75 },
                new AsrWord { Text = "Was", StartSeconds = 2.85, EndSeconds = 3.0 },
                new AsrWord { Text = "ch", StartSeconds = 3.0, EndSeconds = 3.1 },
                new AsrWord { Text = "rä", StartSeconds = 3.1, EndSeconds = 3.2 },
                new AsrWord { Text = "ume", StartSeconds = 3.2, EndSeconds = 3.35 },
                new AsrWord { Text = "levant", StartSeconds = 3.45, EndSeconds = 3.65 },
                new AsrWord { Text = "amento", StartSeconds = 3.65, EndSeconds = 3.9 },
                new AsrWord { Text = "influ", StartSeconds = 4.0, EndSeconds = 4.15 },
                new AsrWord { Text = "ência", StartSeconds = 4.15, EndSeconds = 4.35 },
                new AsrWord { Text = "trad", StartSeconds = 4.45, EndSeconds = 4.6 },
                new AsrWord { Text = "ut", StartSeconds = 4.6, EndSeconds = 4.7 },
                new AsrWord { Text = "ores", StartSeconds = 4.7, EndSeconds = 4.9 },
                new AsrWord { Text = "volunt", StartSeconds = 5.0, EndSeconds = 5.2 },
                new AsrWord { Text = "ários", StartSeconds = 5.2, EndSeconds = 5.4 },
                new AsrWord { Text = "you", StartSeconds = 5.5, EndSeconds = 5.65 },
                new AsrWord { Text = "are", StartSeconds = 5.65, EndSeconds = 5.85 },
            ],
            SourceModelId = "whisper.cpp:test",
        };

        var text = string.Join(" ", AsrTranscriptMapper.SourceCues(transcript).Select(c => c.Text));

        Assert.Contains("gemütlich", text, StringComparison.Ordinal);
        Assert.Contains("regelt", text, StringComparison.Ordinal);
        Assert.Contains("befestigt", text, StringComparison.Ordinal);
        Assert.Contains("Seitenverkleidung", text, StringComparison.Ordinal);
        Assert.Contains("Gepäckfächer", text, StringComparison.Ordinal);
        Assert.Contains("Waschräume", text, StringComparison.Ordinal);
        Assert.Contains("levantamento", text, StringComparison.Ordinal);
        Assert.Contains("influência", text, StringComparison.Ordinal);
        Assert.Contains("tradutores", text, StringComparison.Ordinal);
        Assert.Contains("voluntários", text, StringComparison.Ordinal);
        Assert.Contains("you are", text, StringComparison.Ordinal);
        Assert.DoesNotContain("gem üt lich", text, StringComparison.Ordinal);
        Assert.DoesNotContain("reg elt", text, StringComparison.Ordinal);
        Assert.DoesNotContain("bef est igt", text, StringComparison.Ordinal);
        Assert.DoesNotContain("Seiten ver kle id ung", text, StringComparison.Ordinal);
        Assert.DoesNotContain("G ep ä ck f ä cher", text, StringComparison.Ordinal);
        Assert.DoesNotContain("Was ch rä ume", text, StringComparison.Ordinal);
        Assert.DoesNotContain("levant amento", text, StringComparison.Ordinal);
        Assert.DoesNotContain("influ ência", text, StringComparison.Ordinal);
        Assert.DoesNotContain("trad ut ores", text, StringComparison.Ordinal);
        Assert.DoesNotContain("volunt ários", text, StringComparison.Ordinal);
        Assert.DoesNotContain("youare", text, StringComparison.Ordinal);
    }

    [Fact]
    public void KoreanParticleNeverStartsLine()
    {
        var transcript = new AsrTranscript
        {
            Id = "ko-particle",
            LanguageCode = "ko",
            Words =
            [
                new AsrWord { Text = "학교", StartSeconds = 0.0, EndSeconds = 0.5 },
                new AsrWord { Text = "에서", StartSeconds = 0.52, EndSeconds = 0.8 },
                new AsrWord { Text = "공부", StartSeconds = 0.82, EndSeconds = 1.2 },
                new AsrWord { Text = "를", StartSeconds = 1.22, EndSeconds = 1.4 },
                new AsrWord { Text = "합니다", StartSeconds = 1.42, EndSeconds = 2.0 },
            ],
            SourceModelId = "whisper.cpp:test",
        };
        foreach (var cue in AsrTranscriptMapper.SourceCues(transcript))
        {
            var trimmed = cue.Text.Trim();
            Assert.False(trimmed.StartsWith("에서", StringComparison.Ordinal), $"line must not start with a bare josa: {trimmed}");
            Assert.False(trimmed.StartsWith("를", StringComparison.Ordinal), $"line must not start with a bare josa: {trimmed}");
        }
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
    public void LocalAsrTimingPlannerAvoidsLeadingJapaneseContinuationAfterHardCap()
    {
        var transcript = new AsrTranscript
        {
            Id = "japanese-continuation-hard-cap",
            LanguageCode = "ja",
            Words =
            [
                new AsrWord { Text = "好きなものを", StartSeconds = 0.0, EndSeconds = 1.6 },
                new AsrWord { Text = "好きだと", StartSeconds = 1.6, EndSeconds = 3.0 },
                new AsrWord { Text = "言うのが怖く", StartSeconds = 3.0, EndSeconds = 5.4 },
                new AsrWord { Text = "て", StartSeconds = 5.4, EndSeconds = 5.8 },
                new AsrWord { Text = "仕方ない", StartSeconds = 5.8, EndSeconds = 6.2 },
            ],
            SourceModelId = "whisper.cpp:test",
        };

        var texts = AsrTranscriptMapper.SourceCues(transcript).Select(cue => cue.Text).ToArray();

        Assert.DoesNotContain(texts, text => text.StartsWith("て", StringComparison.Ordinal));
        Assert.Contains(texts, text => text.Contains("怖くて仕方ない", StringComparison.Ordinal));
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
        Assert.Equal(5.0, SrtTools.SrtTimeToSeconds(single[0].Start)!.Value, 3); // 整段第一条前有静音:原始 onset,不加 delay

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
    public void LyricsAndAnimeRetimerAvoidsFlashDurationWhenGapAllows()
    {
        var raw = RetimerCue(4.0, 4.1, "梅だ", 4.1);
        var speech = WhisperCueRetimer.Retime([raw], 10.0, SubtitleTimingProfile.Speech);
        var anime = WhisperCueRetimer.Retime([raw], 10.0, SubtitleTimingProfile.Anime);
        var lyrics = WhisperCueRetimer.Retime([raw], 10.0, SubtitleTimingProfile.JapaneseLyrics);

        static double Duration(SubtitleCue cue) =>
            SrtTools.SrtTimeToSeconds(cue.End)!.Value - SrtTools.SrtTimeToSeconds(cue.Start)!.Value;

        Assert.True(Duration(speech[0]) >= LocalAsrSubtitleTimingPlanner.MinimumCueSeconds);
        Assert.True(Duration(anime[0]) >= 0.9 - 0.0015);
        Assert.True(Duration(lyrics[0]) >= 0.9 - 0.0015);
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

        // BUG-4: a final cue whose onset sits within MinimumCueSeconds of the audio end must not be
        // pushed past the transcript duration by the minimum-readable-duration floor.
        var nearEnd = WhisperCueRetimer.Retime([RetimerCue(10.8, 10.9, "字幕")], 11.0);
        Assert.True(SrtTools.SrtTimeToSeconds(nearEnd[0].End)!.Value <= 11.0 + 0.0015);
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
    public void WhisperCppJsonParserMergesLatinTokenPieces()
    {
        const string json = """
        {
          "result": { "language": "it" },
          "transcription": [
            {
              "text": " Marco se n'è andato e non ritorna più",
              "offsets": { "from": 0, "to": 18720 },
              "tokens": [
                { "text": " Marco", "offsets": { "from": 1390, "to": 2000 }, "p": 0.92 },
                { "text": " se", "offsets": { "from": 2000, "to": 4550 }, "p": 0.37 },
                { "text": " n", "offsets": { "from": 4560, "to": 5840 }, "p": 0.40 },
                { "text": "'", "offsets": { "from": 5840, "to": 7110 }, "p": 0.99 },
                { "text": "è", "offsets": { "from": 7110, "to": 9660 }, "p": 0.99 },
                { "text": " and", "offsets": { "from": 9660, "to": 13490 }, "p": 0.98 },
                { "text": "ato", "offsets": { "from": 13490, "to": 17340 }, "p": 0.99 },
                { "text": " e", "offsets": { "from": 17340, "to": 17430 }, "p": 0.91 },
                { "text": " non", "offsets": { "from": 17430, "to": 17700 }, "p": 0.99 },
                { "text": " r", "offsets": { "from": 17700, "to": 17790 }, "p": 0.97 },
                { "text": "itor", "offsets": { "from": 17790, "to": 18150 }, "p": 0.99 },
                { "text": "na", "offsets": { "from": 18150, "to": 18330 }, "p": 0.99 },
                { "text": " più", "offsets": { "from": 18330, "to": 18720 }, "p": 0.98 }
              ]
            }
          ]
        }
        """;
        var request = new AsrRequest
        {
            AudioPath = "/tmp/audio.wav",
            LanguageCode = "it",
            ModelId = "whisper.cpp:large-v3-turbo-q5_0",
        };

        var transcript = new WhisperCppJsonTranscriptParser().Parse(
            Encoding.UTF8.GetBytes(json),
            request,
            transcriptId: "clip-it");

        Assert.Equal(["Marco", "se", "n'è", "andato", "e", "non", "ritorna", "più"], transcript.Words.Select(word => word.Text).ToArray());
        Assert.Equal(4.56, transcript.Words[2].StartSeconds, precision: 3);
        Assert.Equal(9.66, transcript.Words[2].EndSeconds, precision: 3);
        Assert.Equal(17.70, transcript.Words[6].StartSeconds, precision: 3);
        Assert.Equal(18.33, transcript.Words[6].EndSeconds, precision: 3);
    }

    [Fact]
    public void WhisperCppJsonParserRejoinsObservedGermanPortugueseTokenPieces()
    {
        const string germanJson = """
        {
          "result": { "language": "de" },
          "transcription": [
            {
              "text": " gemütlich regelt, so ist doch euer Sitz auf einer Platte",
              "offsets": { "from": 0, "to": 3600 },
              "tokens": [
                { "text": " gem", "offsets": { "from": 0, "to": 130 }, "p": 0.64 },
                { "text": "üt", "offsets": { "from": 190, "to": 290 }, "p": 0.99 },
                { "text": "lich", "offsets": { "from": 290, "to": 470 }, "p": 0.99 },
                { "text": " reg", "offsets": { "from": 480, "to": 630 }, "p": 0.49 },
                { "text": "elt", "offsets": { "from": 630, "to": 770 }, "p": 0.99 },
                { "text": ",", "offsets": { "from": 770, "to": 800 }, "p": 0.95 },
                { "text": " so", "offsets": { "from": 820, "to": 920 }, "p": 0.99 },
                { "text": " ist", "offsets": { "from": 930, "to": 1030 }, "p": 0.99 },
                { "text": " doch", "offsets": { "from": 1040, "to": 1220 }, "p": 0.99 },
                { "text": " eu", "offsets": { "from": 1240, "to": 1360 }, "p": 0.99 },
                { "text": "er", "offsets": { "from": 1360, "to": 1480 }, "p": 0.99 },
                { "text": " Sitz", "offsets": { "from": 1500, "to": 1700 }, "p": 0.99 },
                { "text": " auf", "offsets": { "from": 1720, "to": 1900 }, "p": 0.99 },
                { "text": " einer", "offsets": { "from": 1920, "to": 2200 }, "p": 0.99 },
                { "text": " Plat", "offsets": { "from": 2220, "to": 2400 }, "p": 0.99 },
                { "text": "te", "offsets": { "from": 2400, "to": 2600 }, "p": 0.99 }
              ]
            }
          ]
        }
        """;
        const string portugueseJson = """
        {
          "result": { "language": "pt" },
          "transcription": [
            {
              "text": " levantamento do British Council tem influência em inglês",
              "offsets": { "from": 0, "to": 3000 },
              "tokens": [
                { "text": " levant", "offsets": { "from": 0, "to": 180 }, "p": 0.99 },
                { "text": "amento", "offsets": { "from": 180, "to": 420 }, "p": 0.99 },
                { "text": " do", "offsets": { "from": 430, "to": 560 }, "p": 0.99 },
                { "text": " British", "offsets": { "from": 570, "to": 900 }, "p": 0.99 },
                { "text": " Council", "offsets": { "from": 910, "to": 1250 }, "p": 0.99 },
                { "text": " tem", "offsets": { "from": 1300, "to": 1450 }, "p": 0.99 },
                { "text": " influ", "offsets": { "from": 1460, "to": 1700 }, "p": 0.99 },
                { "text": "ência", "offsets": { "from": 1700, "to": 1950 }, "p": 0.99 },
                { "text": " em", "offsets": { "from": 1960, "to": 2100 }, "p": 0.99 },
                { "text": " inglês", "offsets": { "from": 2110, "to": 2500 }, "p": 0.99 }
              ]
            }
          ]
        }
        """;

        var german = new WhisperCppJsonTranscriptParser().Parse(
            Encoding.UTF8.GetBytes(germanJson),
            new AsrRequest { AudioPath = "/tmp/de.wav", LanguageCode = "de", ModelId = "whisper.cpp:large-v3-turbo-q5_0" },
            "de");
        var portuguese = new WhisperCppJsonTranscriptParser().Parse(
            Encoding.UTF8.GetBytes(portugueseJson),
            new AsrRequest { AudioPath = "/tmp/pt.wav", LanguageCode = "pt", ModelId = "whisper.cpp:large-v3-turbo-q5_0" },
            "pt");

        Assert.Equal(["gemütlich", "regelt,", "so", "ist", "doch", "euer", "Sitz", "auf", "einer", "Platte"], german.Words.Select(word => word.Text).ToArray());
        Assert.Equal(["levantamento", "do", "British", "Council", "tem", "influência", "em", "inglês"], portuguese.Words.Select(word => word.Text).ToArray());
    }

    [Fact]
    public void WhisperCppJsonParserUsesKoreanSegmentWordsOverTokenPieces()
    {
        const string json = """
        {
          "result": { "language": "ko" },
          "transcription": [
            {
              "text": " 착한 얼굴에 그렇지 못한대도 volume은 두 배로",
              "offsets": { "from": 0, "to": 2200 },
              "tokens": [
                { "text": "[_BEG_]", "offsets": { "from": 0, "to": 0 }, "p": 0.61 },
                { "text": " 착", "offsets": { "from": 0, "to": 120 }, "p": 0.91 },
                { "text": "한", "offsets": { "from": 120, "to": 240 }, "p": 0.92 },
                { "text": " 얼굴에", "offsets": { "from": 240, "to": 620 }, "p": 0.95 },
                { "text": " 그렇지", "offsets": { "from": 620, "to": 980 }, "p": 0.95 },
                { "text": " 못", "offsets": { "from": 980, "to": 1120 }, "p": 0.93 },
                { "text": "한대도", "offsets": { "from": 1120, "to": 1450 }, "p": 0.94 },
                { "text": " volume", "offsets": { "from": 1450, "to": 1700 }, "p": 0.97 },
                { "text": "은", "offsets": { "from": 1700, "to": 1800 }, "p": 0.97 },
                { "text": " 두", "offsets": { "from": 1800, "to": 1940 }, "p": 0.98 },
                { "text": " 배로", "offsets": { "from": 1940, "to": 2200 }, "p": 0.98 },
                { "text": "[_TT_1359]", "offsets": { "from": 2200, "to": 2200 }, "p": 0.10 }
              ]
            },
            {
              "text": " 근데 뭔가 즐겁게 배운 것들은",
              "offsets": { "from": 40680, "to": 42940 },
              "tokens": [
                { "text": " 근데", "offsets": { "from": 40680, "to": 40600 }, "p": 0.95 },
                { "text": " 뭔가", "offsets": { "from": 41010, "to": 41400 }, "p": 0.96 },
                { "text": " 즐", "offsets": { "from": 41400, "to": 41600 }, "p": 0.93 },
                { "text": "겁", "offsets": { "from": 41600, "to": 41800 }, "p": 0.93 },
                { "text": "게", "offsets": { "from": 41800, "to": 42000 }, "p": 0.93 },
                { "text": " 배", "offsets": { "from": 42000, "to": 42200 }, "p": 0.94 },
                { "text": "운", "offsets": { "from": 42200, "to": 42400 }, "p": 0.94 },
                { "text": " 것", "offsets": { "from": 42400, "to": 42600 }, "p": 0.94 },
                { "text": "들", "offsets": { "from": 42600, "to": 42800 }, "p": 0.94 },
                { "text": "은", "offsets": { "from": 42800, "to": 42940 }, "p": 0.94 },
                { "text": "[_TT_648]", "offsets": { "from": 42940, "to": 42940 }, "p": 0.10 }
              ]
            }
          ]
        }
        """;

        var transcript = new WhisperCppJsonTranscriptParser().Parse(
            Encoding.UTF8.GetBytes(json),
            new AsrRequest { AudioPath = "/tmp/ko.wav", LanguageCode = "ko", ModelId = "whisper.cpp:large-v3-turbo-q5_0" },
            "ko");

        Assert.Equal(
            ["착한", "얼굴에", "그렇지", "못한대도", "volume은", "두", "배로", "근데", "뭔가", "즐겁게", "배운", "것들은"],
            transcript.Words.Select(word => word.Text).ToArray());
        Assert.Equal(0.0, transcript.Words[0].StartSeconds, precision: 3);
        Assert.Equal(0.24, transcript.Words[0].EndSeconds, precision: 3);
        Assert.Equal(1.45, transcript.Words[4].StartSeconds, precision: 3);
        Assert.Equal(1.8, transcript.Words[4].EndSeconds, precision: 3);
        Assert.Equal(41.4, transcript.Words[9].StartSeconds, precision: 3);
        Assert.Equal(42.0, transcript.Words[9].EndSeconds, precision: 3);
    }

    [Fact]
    public void WhisperCppJsonParserUsesDevanagariSegmentWordsOverTokenPieces()
    {
        // Whisper writes Hindi with real word spacing in segment text but splits words into
        // base-letter + combining-mark token pieces. The parser must rebuild spaced word units
        // from segment text (mirrors Hangul), so Hindi is not a run-on string like जिसकीतुलना.
        const string json = """
        {
          "result": { "language": "hi" },
          "transcription": [
            {
              "text": " जिसकी तुलना फिर",
              "offsets": { "from": 0, "to": 1200 },
              "tokens": [
                { "text": "[_BEG_]", "offsets": { "from": 0, "to": 0 }, "p": 0.6 },
                { "text": " ज", "offsets": { "from": 0, "to": 120 }, "p": 0.9 },
                { "text": "ि", "offsets": { "from": 120, "to": 180 }, "p": 0.9 },
                { "text": "स", "offsets": { "from": 180, "to": 270 }, "p": 0.9 },
                { "text": "क", "offsets": { "from": 270, "to": 360 }, "p": 0.9 },
                { "text": "ी", "offsets": { "from": 360, "to": 450 }, "p": 0.9 },
                { "text": " त", "offsets": { "from": 450, "to": 540 }, "p": 0.9 },
                { "text": "ु", "offsets": { "from": 540, "to": 630 }, "p": 0.9 },
                { "text": "ल", "offsets": { "from": 630, "to": 720 }, "p": 0.9 },
                { "text": "न", "offsets": { "from": 720, "to": 810 }, "p": 0.9 },
                { "text": "ा", "offsets": { "from": 810, "to": 900 }, "p": 0.9 },
                { "text": " फ", "offsets": { "from": 900, "to": 1010 }, "p": 0.9 },
                { "text": "ि", "offsets": { "from": 1010, "to": 1080 }, "p": 0.9 },
                { "text": "र", "offsets": { "from": 1080, "to": 1200 }, "p": 0.9 },
                { "text": "[_TT_360]", "offsets": { "from": 1200, "to": 1200 }, "p": 0.1 }
              ]
            }
          ]
        }
        """;

        var transcript = new WhisperCppJsonTranscriptParser().Parse(
            Encoding.UTF8.GetBytes(json),
            new AsrRequest { AudioPath = "/tmp/hi.wav", LanguageCode = "hi", ModelId = "whisper.cpp:large-v3-turbo-q5_0" },
            "hi");

        Assert.Equal(
            ["जिसकी", "तुलना", "फिर"],
            transcript.Words.Select(word => word.Text).ToArray());
        Assert.Equal(0.0, transcript.Words[0].StartSeconds, precision: 3);
        Assert.Equal(0.45, transcript.Words[0].EndSeconds, precision: 3);
        Assert.Equal(0.45, transcript.Words[1].StartSeconds, precision: 3);
        Assert.Equal(0.9, transcript.Words[2].StartSeconds, precision: 3);
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

            var output = (await generator.GenerateSourceSubtitleAsync(video, "ja", null, progress.Add)).Url;

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

            var firstOutput = (await generator.GenerateSourceSubtitleAsync(video, "auto", null, _ => { })).Url;
            var secondProgress = new List<AsrProgress>();
            var secondOutput = (await generator.GenerateSourceSubtitleAsync(video, "auto", null, secondProgress.Add)).Url;

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
    public async Task LocalAsrGeneratorRetriesAutoEnglishLoopWithJapaneseLanguageLock()
    {
        var directory = Path.Combine(Path.GetTempPath(), "moongate-asr-generator-loop-retry-" + Guid.NewGuid().ToString("N"));
        try
        {
            Directory.CreateDirectory(directory);
            var workDirectory = Path.Combine(directory, "work");
            var video = Path.Combine(directory, "[Amatør] lille japaner sample.mp4");
            var ffmpeg = Path.Combine(directory, OperatingSystem.IsWindows() ? "ffmpeg.exe" : "ffmpeg");
            File.WriteAllText(video, "video fixture");
            File.WriteAllText(ffmpeg, "#!/bin/sh\n");
            if (!OperatingSystem.IsWindows())
            {
                File.SetUnixFileMode(ffmpeg, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
            }

            var audioExtractor = new RecordingAsrAudioExtractor((plan, _, _) =>
            {
                Directory.CreateDirectory(Path.GetDirectoryName(plan.OutputPath)!);
                File.WriteAllText(plan.OutputPath, "wav fixture");
                return Task.FromResult(plan.OutputPath);
            });
            var recognizer = new SequencedSpeechRecognizer(
            [
                new AsrTranscript
                {
                    Id = "auto-en-loop",
                    LanguageCode = "en",
                    DurationSeconds = 70,
                    Words =
                    [
                        new AsrWord { Text = "Korin", StartSeconds = 0, EndSeconds = 2, Probability = 0.95 },
                        new AsrWord { Text = "Korin", StartSeconds = 30, EndSeconds = 32, Probability = 0.95 },
                        new AsrWord { Text = "Korin", StartSeconds = 60, EndSeconds = 62, Probability = 0.95 },
                    ],
                    SourceModelId = "whisper.cpp:test",
                    Segments =
                    [
                        new AsrSegment { Text = "*Korin*", StartSeconds = 0, EndSeconds = 2 },
                        new AsrSegment { Text = "*Korin*", StartSeconds = 30, EndSeconds = 32 },
                        new AsrSegment { Text = "*Korin*", StartSeconds = 60, EndSeconds = 62 },
                    ],
                },
                new AsrTranscript
                {
                    Id = "retry-ja",
                    LanguageCode = "ja",
                    DurationSeconds = 2,
                    Words =
                    [
                        new AsrWord { Text = "お客様", StartSeconds = 0, EndSeconds = 0.8, Probability = 0.95 },
                    ],
                    SourceModelId = "whisper.cpp:test",
                    Segments =
                    [
                        new AsrSegment { Text = "お客様", StartSeconds = 0, EndSeconds = 0.8 },
                    ],
                },
            ]);
            var generator = new WhisperCppLocalAsrSubtitleGenerator(
                ffmpeg,
                workDirectory,
                recognizer,
                modelId: "whisper.cpp:test",
                promptProvider: AsrPromptBuilder.DefaultPrompt,
                audioExtractor: audioExtractor);

            var output = (await generator.GenerateSourceSubtitleAsync(video, "auto", null, _ => { })).Url;

            Assert.Equal("[Amatør] lille japaner sample.local-asr.ja.srt", Path.GetFileName(output));
            Assert.Equal(["auto", "ja"], recognizer.Requests.Select(request => request.LanguageCode ?? "").ToArray());
            Assert.Equal(0, recognizer.Requests.Last().MaxTextContextTokens);
            Assert.Single(audioExtractor.Plans);
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
    public async Task SidecarLocalAsrSubtitleGeneratorRunsLocalProcessAndWritesSourceSrt()
    {
        if (OperatingSystem.IsWindows()) return;
        var directory = Path.Combine(Path.GetTempPath(), "moongate-asr-sidecar-" + Guid.NewGuid().ToString("N"));
        try
        {
            Directory.CreateDirectory(directory);
            var sidecar = Path.Combine(directory, "sidecar");
            await File.WriteAllTextAsync(sidecar, """
                #!/bin/sh
                output=""
                while [ "$#" -gt 0 ]; do
                  case "$1" in
                    --output) output="$2"; shift 2 ;;
                    *) shift 2 ;;
                  esac
                done
                printf '1\n00:00:00,000 --> 00:00:01,200\nコウペンちゃん\n' > "$output"
                """);
            File.SetUnixFileMode(sidecar, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
            var model = Path.Combine(directory, "faster-whisper-small");
            Directory.CreateDirectory(model);
            var video = Path.Combine(directory, "koupen.mp4");
            await File.WriteAllTextAsync(video, "video");
            var generator = new SidecarLocalAsrSubtitleGenerator(
                sidecar,
                model,
                Path.Combine(directory, "work"));

            var result = await generator.GenerateSourceSubtitleAsync(
                video,
                "ja",
                null,
                _ => { });

            Assert.Equal("koupen.local-asr.ja.srt", Path.GetFileName(result.Url));
            var raw = await File.ReadAllTextAsync(result.Url);
            Assert.Contains("コウペンちゃん", raw);
            Assert.DoesNotContain("emptyTranscript", result.Confidence?.QualityIssues ?? []);
        }
        finally
        {
            if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public void LocalAsrGeneratorFactoryUsesPreciseSidecarWhenEnabled()
    {
        var directory = Path.Combine(Path.GetTempPath(), "moongate-asr-sidecar-factory-" + Guid.NewGuid().ToString("N"));
        try
        {
            Directory.CreateDirectory(directory);
            var sidecar = Path.Combine(directory, OperatingSystem.IsWindows() ? "sidecar.exe" : "sidecar");
            File.WriteAllText(sidecar, "#!/bin/sh\n");
            if (!OperatingSystem.IsWindows())
            {
                File.SetUnixFileMode(sidecar, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
            }
            var model = Path.Combine(directory, "model-dir");
            Directory.CreateDirectory(model);
            var settings = new AppSettings
            {
                LocalAsrEnabled = true,
                LocalAsrRuntimePath = Path.Combine(directory, "missing-whisper-cli"),
                LocalAsrModelPath = Path.Combine(directory, "missing-ggml.bin"),
                LocalAsrModelId = "custom:missing",
                LocalAsrPreciseModeEnabled = true,
                LocalAsrSidecarRuntimePath = sidecar,
                LocalAsrSidecarModelPath = model,
            };

            Assert.IsType<SidecarLocalAsrSubtitleGenerator>(
                LocalAsrGeneratorFactory.Create(settings, null, directory));
            Assert.Null(LocalAsrGeneratorFactory.Create(settings with
            {
                LocalAsrSidecarRuntimePath = "",
            }, null, directory));
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

    [Fact]
    public async Task WhisperCppRecognizerRetriesMetalAllocationFailureWithoutGpu()
    {
        var directory = Path.Combine(Path.GetTempPath(), "moongate-asr-metal-retry-" + Guid.NewGuid().ToString("N"));
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

            var runner = new RecordingAsrCommandRunner((plan, _, _) =>
            {
                if (!plan.Arguments.Contains("--no-gpu"))
                {
                    return Task.FromResult(new AsrCommandResult
                    {
                        Status = 1,
                        StderrTail = "ggml_metal_buffer_init: error: failed to allocate buffer",
                    });
                }
                Directory.CreateDirectory(Path.GetDirectoryName(plan.OutputJsonPath)!);
                File.WriteAllText(plan.OutputJsonPath, """
                {
                  "result": { "language": "ja" },
                  "transcription": [
                    {
                      "text": " 梅雨",
                      "offsets": { "from": 0, "to": 600 },
                      "tokens": [
                        { "text": " 梅雨", "offsets": { "from": 0, "to": 600 } }
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
                Path.Combine(directory, "out"),
                commandRunner: runner);

            var transcript = await recognizer.TranscribeAsync(new AsrRequest
            {
                AudioPath = audio,
                LanguageCode = "ja",
                ModelId = "whisper.cpp:test",
            }, _ => { });

            Assert.Equal(["梅雨"], transcript.Words.Select(word => word.Text).ToArray());
            Assert.Equal(2, runner.CallCount);
            Assert.DoesNotContain("--no-gpu", runner.Plans[0].Arguments);
            Assert.Contains("--no-gpu", runner.Plans[1].Arguments);
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
        Assert.Equal(expected.BackendKind, actual.BackendKind);
        Assert.Equal(expected.Segments, actual.Segments);
        Assert.Equal(expected.RawText, actual.RawText);
        Assert.Equal(expected.BackendDiagnostics, actual.BackendDiagnostics);
        AssertQualitySummaryEqual(expected.QualitySummary, actual.QualitySummary);
        Assert.Equal(expected.CreatedAt, actual.CreatedAt);
        Assert.Equal(expected.Words.Count, actual.Words.Count);
        for (var index = 0; index < expected.Words.Count; index += 1)
        {
            Assert.Equal(expected.Words[index], actual.Words[index]);
        }
    }

    private static string? ArgumentValueAfter(string flag, IReadOnlyList<string> arguments)
    {
        for (var index = 0; index < arguments.Count - 1; index += 1)
        {
            if (arguments[index] == flag) return arguments[index + 1];
        }
        return null;
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

    private sealed class SequencedSpeechRecognizer(IReadOnlyList<AsrTranscript> transcripts) : ISpeechRecognizer
    {
        private readonly object _lock = new();
        private readonly Queue<AsrTranscript> _transcripts = new(transcripts);
        private readonly List<AsrRequest> _requests = [];

        public IReadOnlyList<AsrRequest> Requests
        {
            get { lock (_lock) return [.. _requests]; }
        }

        public Task<AsrReadiness> ReadinessAsync(AsrRequest request, CancellationToken ct = default) =>
            Task.FromResult(new AsrReadiness
            {
                Status = AsrReadinessStatus.Ready,
                ModelId = request.ModelId,
                Message = "ready",
            });

        public Task<AsrTranscript> TranscribeAsync(
            AsrRequest request,
            Action<AsrProgress> progress,
            TaskControlToken? control = null,
            CancellationToken ct = default)
        {
            ct.ThrowIfCancellationRequested();
            AsrTranscript transcript;
            lock (_lock)
            {
                _requests.Add(request);
                transcript = _transcripts.Dequeue();
            }
            progress(new AsrProgress
            {
                Phase = AsrProgressPhase.SpeechRecognition,
                CompletedUnits = 1,
                TotalUnits = 1,
            });
            return Task.FromResult(transcript);
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

    private static void AssertQualitySummaryEqual(LocalAsrConfidenceSummary? expected, LocalAsrConfidenceSummary? actual)
    {
        Assert.Equal(expected.HasValue, actual.HasValue);
        if (!expected.HasValue || !actual.HasValue) return;
        Assert.Equal(expected.Value.AssessedWordCount, actual.Value.AssessedWordCount);
        Assert.Equal(expected.Value.AverageProbability, actual.Value.AverageProbability);
        Assert.Equal(expected.Value.LowConfidenceWordRatio, actual.Value.LowConfidenceWordRatio);
        Assert.Equal(expected.Value.IsLowConfidence, actual.Value.IsLowConfidence);
        Assert.Equal(expected.Value.ScriptMismatchRatio, actual.Value.ScriptMismatchRatio);
        Assert.Equal(expected.Value.LatinTokenRatio, actual.Value.LatinTokenRatio);
        Assert.Equal(expected.Value.DominantPhraseRatio, actual.Value.DominantPhraseRatio);
        Assert.Equal(expected.Value.RepeatedPhraseSpanSeconds, actual.Value.RepeatedPhraseSpanSeconds);
        Assert.Equal(expected.Value.QualityIssues, actual.Value.QualityIssues);
        Assert.Equal(expected.Value.IsLowQuality, actual.Value.IsLowQuality);
    }
}
