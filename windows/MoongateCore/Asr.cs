using System.Diagnostics;
using System.Globalization;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace Moongate.Core;

/// <summary>
/// CJK word-boundary lookup for Windows. .NET ships no morphological tokenizer like macOS
/// NaturalLanguage, so this uses a deterministic same-script-run segmenter: a cut straddles a word
/// when both sides belong to the same word-forming script (Latin / digits / Katakana / Hiragana /
/// Han), plus the kanji→okurigana (Han→Hiragana) case. This covers the dominant mid-word-cut
/// artifacts (within カード / within a latin word / 動く okurigana). For the script-run cases it
/// agrees with macOS NLTokenizer, which a cross-platform parity test asserts on a curated input set.
/// </summary>
public static class CjkWordBoundary
{
    private enum ScriptClass { Other, Latin, Digit, Hiragana, Katakana, Han, Hangul }

    private static ScriptClass Classify(char c)
    {
        if (c is (>= 'a' and <= 'z') or (>= 'A' and <= 'Z')) return ScriptClass.Latin;
        if (c is >= '0' and <= '9') return ScriptClass.Digit;
        int v = c;
        if (v is >= 0x3040 and <= 0x309F) return ScriptClass.Hiragana;
        if (v is >= 0x30A0 and <= 0x30FF) return ScriptClass.Katakana;
        if (v is >= 0x4E00 and <= 0x9FFF) return ScriptClass.Han;
        if (v is >= 0xAC00 and <= 0xD7A3) return ScriptClass.Hangul;
        return ScriptClass.Other;
    }

    /// <summary>
    /// True when <paramref name="charOffset"/> falls strictly inside a word (breaking there would
    /// cut a word in half). False at real word boundaries / gaps. Mirrors Swift CJKWordBoundary.straddles.
    /// </summary>
    public static bool Straddles(string text, int charOffset)
    {
        if (charOffset <= 0 || charOffset >= text.Length) return false;
        var left = Classify(text[charOffset - 1]);
        var right = Classify(text[charOffset]);
        if (left == ScriptClass.Other || right == ScriptClass.Other) return false;
        if (left == right) return true;
        // Okurigana: a kanji stem followed by its hiragana inflection is one word (動く, 食べる).
        if (left == ScriptClass.Han && right == ScriptClass.Hiragana) return true;
        return false;
    }
}

public static class AsrJson
{
    public static JsonSerializerOptions Options { get; } = CreateOptions();

    private static JsonSerializerOptions CreateOptions()
    {
        var options = new JsonSerializerOptions(JsonSerializerDefaults.Web);
        options.Converters.Add(new JsonStringEnumConverter(JsonNamingPolicy.CamelCase));
        return options;
    }
}

public enum AsrRecognitionProfile
{
    Speech,
    LyricsHighQuality,
}

public enum AsrBackendKind
{
    Unknown,
    WhisperCpp,
    SenseVoiceFunASR,
}

public sealed record AsrRequest
{
    public required string AudioPath { get; init; }
    public string? LanguageCode { get; init; }
    public required string ModelId { get; init; }
    public string? Prompt { get; init; }
    public AsrRecognitionProfile RecognitionProfile { get; init; } = AsrRecognitionProfile.Speech;
    /// <summary>Optional whisper.cpp text-context cap (<c>-mc</c>). Music-like local-ASR requests
    /// use 0 to reduce previous-text repetition loops.</summary>
    public int? MaxTextContextTokens { get; init; }
    /// <summary>When true, whisper.cpp may use <c>--vad</c> if <see cref="VadModelPath"/> points to
    /// an existing app-managed VAD model. Missing VAD assets gracefully fall back to the standard path.</summary>
    public bool VadEnabled { get; init; } = true;
    /// <summary>Explicit app-managed VAD model path. The command planner never guesses this from the runtime folder.</summary>
    public string? VadModelPath { get; init; }
    public bool WordTimestamps { get; init; } = true;
    /// <summary>
    /// When true (with word timestamps), whisper.cpp is asked for DTW-aligned token timestamps
    /// (<c>-dtw &lt;preset&gt; -nfa</c>), which are markedly closer to human timing than the
    /// default frame-quantized offsets. Disabled as a fail-safe if a model build rejects DTW.
    /// </summary>
    public bool DtwTokenTimestamps { get; init; } = true;
    public string? CacheKey { get; init; }
}

public sealed record AsrWord
{
    public required string Text { get; init; }
    public required double StartSeconds { get; init; }
    public required double EndSeconds { get; init; }
    public double? Probability { get; init; }
}

public sealed record AsrSegment
{
    public required string Text { get; init; }
    public required double StartSeconds { get; init; }
    public required double EndSeconds { get; init; }
}

public sealed record AsrTranscript
{
    public required string Id { get; init; }
    public required string LanguageCode { get; init; }
    public double? LanguageConfidence { get; init; }
    public double? DurationSeconds { get; init; }
    public required IReadOnlyList<AsrWord> Words { get; init; }
    public required string SourceModelId { get; init; }
    public AsrBackendKind BackendKind { get; init; } = AsrBackendKind.WhisperCpp;
    public IReadOnlyList<AsrSegment> Segments { get; init; } = [];
    public string? RawText { get; init; }
    public Dictionary<string, string> BackendDiagnostics { get; init; } = [];
    public LocalAsrConfidenceSummary? QualitySummary { get; init; }
    public DateTimeOffset CreatedAt { get; init; } = DateTimeOffset.UtcNow;
}

public sealed record AsrAudioActivityRange(double StartSeconds, double EndSeconds);

public sealed class AsrAudioActivity
{
    public IReadOnlyList<AsrAudioActivityRange> SilenceRanges { get; }

    public AsrAudioActivity(IReadOnlyList<AsrAudioActivityRange> silenceRanges)
    {
        SilenceRanges = silenceRanges
            .Where(range => double.IsFinite(range.StartSeconds)
                && double.IsFinite(range.EndSeconds)
                && range.EndSeconds > range.StartSeconds
                && range.EndSeconds >= 0)
            .OrderBy(range => range.StartSeconds)
            .ThenBy(range => range.EndSeconds)
            .ToList();
    }

    public static AsrAudioActivity ParseSilencedetectOutput(string output)
    {
        var ranges = new List<AsrAudioActivityRange>();
        double? openStart = null;
        foreach (var line in output.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries))
        {
            if (FirstNumber(line, "silence_start:") is { } start)
            {
                openStart = start;
                continue;
            }
            if (FirstNumber(line, "silence_end:") is { } end && openStart is { } rangeStart)
            {
                ranges.Add(new AsrAudioActivityRange(rangeStart, end));
                openStart = null;
            }
        }
        return new AsrAudioActivity(ranges);
    }

    internal double ProtectedLyricStart(double start)
    {
        const double tolerance = 0.12;
        var range = SilenceRanges.FirstOrDefault(range =>
            start >= range.StartSeconds - tolerance && start < range.EndSeconds);
        return range is null ? start : Math.Max(start, range.EndSeconds);
    }

    private static double? FirstNumber(string line, string marker)
    {
        var markerIndex = line.IndexOf(marker, StringComparison.Ordinal);
        if (markerIndex < 0) return null;
        var tail = line[(markerIndex + marker.Length)..];
        var match = Regex.Match(tail, @"[-+]?[0-9]+(?:\.[0-9]+)?");
        return match.Success && double.TryParse(match.Value, CultureInfo.InvariantCulture, out var value)
            ? value
            : null;
    }
}

public enum AsrProgressPhase
{
    ModelDownload,
    AudioExtract,
    SpeechRecognition,
    SubtitleSegment,
}

public sealed record AsrProgress
{
    public required AsrProgressPhase Phase { get; init; }
    public double? CompletedUnits { get; init; }
    public double? TotalUnits { get; init; }
    public string? Detail { get; init; }

    public double? Fraction => CompletedUnits is { } completed
        && TotalUnits is { } total
        && total > 0
            ? Math.Clamp(completed / total, 0, 1)
            : null;
}

public enum AsrReadinessStatus
{
    Ready,
    MissingRuntime,
    MissingModel,
    BadModelHash,
    InsufficientDiskSpace,
    UnsupportedPlatform,
}

public sealed record AsrReadiness
{
    public required AsrReadinessStatus Status { get; init; }
    public string? ModelId { get; init; }
    public required string Message { get; init; }
    public bool IsReady => Status == AsrReadinessStatus.Ready;
}

public interface ISpeechRecognizer
{
    Task<AsrReadiness> ReadinessAsync(AsrRequest request, CancellationToken ct = default);
    Task<AsrTranscript> TranscribeAsync(
        AsrRequest request,
        Action<AsrProgress> progress,
        TaskControlToken? control = null,
        CancellationToken ct = default);
}

public enum FakeSpeechRecognizerError
{
    NoSpeech,
    LowLanguageConfidence,
    MissingModel,
    BadModelHash,
}

public sealed class FakeSpeechRecognizerException(FakeSpeechRecognizerError reason)
    : Exception(reason.ToString())
{
    public FakeSpeechRecognizerError Reason { get; } = reason;
}

public sealed class FakeSpeechRecognizer : ISpeechRecognizer
{
    public enum FakeMode
    {
        Success,
        Failure,
        Cancelled,
    }

    private readonly AsrReadiness _readiness;
    private readonly FakeMode _mode;
    private readonly AsrTranscript? _transcript;
    private readonly FakeSpeechRecognizerError? _failure;

    public FakeSpeechRecognizer(AsrReadiness readiness, AsrTranscript transcript)
    {
        _readiness = readiness;
        _mode = FakeMode.Success;
        _transcript = transcript;
    }

    public FakeSpeechRecognizer(AsrReadiness readiness, FakeSpeechRecognizerError failure)
    {
        _readiness = readiness;
        _mode = FakeMode.Failure;
        _failure = failure;
    }

    public static FakeSpeechRecognizer Cancelled(AsrReadiness readiness) => new(readiness, FakeMode.Cancelled);

    private FakeSpeechRecognizer(AsrReadiness readiness, FakeMode mode)
    {
        _readiness = readiness;
        _mode = mode;
    }

    public Task<AsrReadiness> ReadinessAsync(AsrRequest request, CancellationToken ct = default) =>
        Task.FromResult(_readiness);

    public Task<AsrTranscript> TranscribeAsync(
        AsrRequest request,
        Action<AsrProgress> progress,
        TaskControlToken? control = null,
        CancellationToken ct = default)
    {
        ct.ThrowIfCancellationRequested();
        return TranscribeCoreAsync(request, progress, control, ct);
    }

    private async Task<AsrTranscript> TranscribeCoreAsync(
        AsrRequest request,
        Action<AsrProgress> progress,
        TaskControlToken? control,
        CancellationToken ct)
    {
        if (control is not null) await control.GateAsync(ct).ConfigureAwait(false);
        progress(new AsrProgress
        {
            Phase = AsrProgressPhase.SpeechRecognition,
            CompletedUnits = 0,
            TotalUnits = 1,
        });

        return await (_mode switch
        {
            FakeMode.Success => CompleteSuccess(progress),
            FakeMode.Failure => Task.FromException<AsrTranscript>(
                new FakeSpeechRecognizerException(_failure ?? FakeSpeechRecognizerError.NoSpeech)),
            _ => Task.FromCanceled<AsrTranscript>(new CancellationToken(canceled: true)),
        }).ConfigureAwait(false);
    }

    private Task<AsrTranscript> CompleteSuccess(Action<AsrProgress> progress)
    {
        progress(new AsrProgress
        {
            Phase = AsrProgressPhase.SpeechRecognition,
            CompletedUnits = 1,
            TotalUnits = 1,
        });
        return Task.FromResult(_transcript!);
    }
}

public sealed record AsrModelManifest
{
    public required IReadOnlyList<AsrModelInfo> Models { get; init; }

    public static AsrModelManifest RecommendedWhisperCpp { get; } = new()
    {
        Models =
        [
            new AsrModelInfo
            {
                Id = "whisper.cpp:tiny-q5_1",
                DisplayName = "Whisper tiny q5_1",
                FileName = "ggml-tiny-q5_1.bin",
                DownloadUrl = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny-q5_1.bin",
                SizeBytes = 32_152_673,
                Sha256 = "818710568da3ca15689e31a743197b520007872ff9576237bda97bd1b469c3d7",
                MemoryRequiredMb = 256,
                License = "MIT",
                SourceDescription = "ggerganov/whisper.cpp on Hugging Face",
            },
            new AsrModelInfo
            {
                Id = "whisper.cpp:tiny-q8_0",
                DisplayName = "Whisper tiny q8_0",
                FileName = "ggml-tiny-q8_0.bin",
                DownloadUrl = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny-q8_0.bin",
                SizeBytes = 43_537_433,
                Sha256 = "c2085835d3f50733e2ff6e4b41ae8a2b8d8110461e18821b09a15c40c42d1cca",
                MemoryRequiredMb = 384,
                License = "MIT",
                SourceDescription = "ggerganov/whisper.cpp on Hugging Face",
            },
            new AsrModelInfo
            {
                Id = "whisper.cpp:base-q5_1",
                DisplayName = "Whisper base q5_1",
                FileName = "ggml-base-q5_1.bin",
                DownloadUrl = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base-q5_1.bin",
                SizeBytes = 59_707_625,
                Sha256 = "422f1ae452ade6f30a004d7e5c6a43195e4433bc370bf23fac9cc591f01a8898",
                MemoryRequiredMb = 512,
                License = "MIT",
                SourceDescription = "ggerganov/whisper.cpp on Hugging Face",
            },
            new AsrModelInfo
            {
                Id = "whisper.cpp:base-q8_0",
                DisplayName = "Whisper base q8_0",
                FileName = "ggml-base-q8_0.bin",
                DownloadUrl = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base-q8_0.bin",
                SizeBytes = 81_768_585,
                Sha256 = "c577b9a86e7e048a0b7eada054f4dd79a56bbfa911fbdacf900ac5b567cbb7d9",
                MemoryRequiredMb = 768,
                License = "MIT",
                SourceDescription = "ggerganov/whisper.cpp on Hugging Face",
            },
            new AsrModelInfo
            {
                Id = "whisper.cpp:small-q5_1",
                DisplayName = "Whisper small q5_1",
                FileName = "ggml-small-q5_1.bin",
                DownloadUrl = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small-q5_1.bin",
                SizeBytes = 190_085_487,
                Sha256 = "ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb",
                MemoryRequiredMb = 1_024,
                License = "MIT",
                SourceDescription = "ggerganov/whisper.cpp on Hugging Face",
            },
            new AsrModelInfo
            {
                Id = "whisper.cpp:small-q8_0",
                DisplayName = "Whisper small q8_0",
                FileName = "ggml-small-q8_0.bin",
                DownloadUrl = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small-q8_0.bin",
                SizeBytes = 264_464_607,
                Sha256 = "49c8fb02b65e6049d5fa6c04f81f53b867b5ec9540406812c643f177317f779f",
                MemoryRequiredMb = 1_280,
                License = "MIT",
                SourceDescription = "ggerganov/whisper.cpp on Hugging Face",
            },
            new AsrModelInfo
            {
                Id = "whisper.cpp:small.en-q5_1",
                DisplayName = "Whisper small.en q5_1",
                FileName = "ggml-small.en-q5_1.bin",
                DownloadUrl = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en-q5_1.bin",
                SizeBytes = 190_098_681,
                Sha256 = "bfdff4894dcb76bbf647d56263ea2a96645423f1669176f4844a1bf8e478ad30",
                MemoryRequiredMb = 1_024,
                License = "MIT",
                SourceDescription = "ggerganov/whisper.cpp on Hugging Face",
            },
            new AsrModelInfo
            {
                Id = "whisper.cpp:medium-q5_0",
                DisplayName = "Whisper medium q5_0",
                FileName = "ggml-medium-q5_0.bin",
                DownloadUrl = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium-q5_0.bin",
                SizeBytes = 539_212_467,
                Sha256 = "19fea4b380c3a618ec4723c3eef2eb785ffba0d0538cf43f8f235e7b3b34220f",
                MemoryRequiredMb = 2_048,
                License = "MIT",
                SourceDescription = "ggerganov/whisper.cpp on Hugging Face",
            },
            new AsrModelInfo
            {
                Id = "whisper.cpp:large-v3-turbo-q5_0",
                DisplayName = "Whisper large-v3-turbo q5_0",
                FileName = "ggml-large-v3-turbo-q5_0.bin",
                DownloadUrl = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin",
                SizeBytes = 574_041_195,
                Sha256 = "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2",
                MemoryRequiredMb = 3_072,
                License = "MIT",
                SourceDescription = "ggerganov/whisper.cpp on Hugging Face",
            },
        ],
    };
}

public sealed record AsrModelInfo
{
    public required string Id { get; init; }
    public required string DisplayName { get; init; }
    public required string FileName { get; init; }
    public required string DownloadUrl { get; init; }
    public required long SizeBytes { get; init; }
    public required string Sha256 { get; init; }
    public required int MemoryRequiredMb { get; init; }
    public required string License { get; init; }
    public required string SourceDescription { get; init; }
}

public enum AsrRuntimeBundleManifestError
{
    EmptyManifest,
    MissingRequiredField,
    InvalidExecutableRelativePath,
    InvalidSha256,
    MissingExecutable,
    Sha256Mismatch,
    DownloadUrlNotAllowed,
}

public sealed class AsrRuntimeBundleManifestException(
    AsrRuntimeBundleManifestError reason,
    string? detail = null)
    : Exception(detail is { Length: > 0 } ? $"{reason}: {detail}" : reason.ToString())
{
    public AsrRuntimeBundleManifestError Reason { get; } = reason;
    public string? Detail { get; } = detail;
}

public sealed record AsrRuntimeBundleManifest
{
    public required IReadOnlyList<AsrRuntimeBundleInfo> Runtimes { get; init; }

    public static AsrRuntimeBundleManifest FromJson(string json)
    {
        var manifest = JsonSerializer.Deserialize<AsrRuntimeBundleManifest>(json, AsrJson.Options)
            ?? throw new AsrRuntimeBundleManifestException(AsrRuntimeBundleManifestError.EmptyManifest);
        manifest.Validate();
        return manifest;
    }

    public void Validate()
    {
        if (Runtimes.Count == 0)
        {
            throw new AsrRuntimeBundleManifestException(AsrRuntimeBundleManifestError.EmptyManifest);
        }
        foreach (var runtime in Runtimes)
        {
            runtime.Validate();
        }
    }
}

public sealed record AsrRuntimeBundleInfo
{
    public required string Provider { get; init; }
    public required string Platform { get; init; }
    public required string Architecture { get; init; }
    public required string Version { get; init; }
    public required string ExecutableRelativePath { get; init; }
    public required string Sha256 { get; init; }
    public required string License { get; init; }
    public required string SourceDescription { get; init; }

    [JsonExtensionData]
    public IDictionary<string, JsonElement>? ExtraFields { get; init; }

    public string ExecutablePathUnder(string runtimeDirectory)
    {
        Validate();
        var normalizedRelative = ExecutableRelativePath.Replace('/', Path.DirectorySeparatorChar);
        return Path.GetFullPath(Path.Combine(runtimeDirectory, normalizedRelative));
    }

    public AsrRuntimeInfo VerifiedRuntimeInfoUnder(string runtimeDirectory)
    {
        var executable = ExecutablePathUnder(runtimeDirectory);
        if (!File.Exists(executable))
        {
            throw new AsrRuntimeBundleManifestException(
                AsrRuntimeBundleManifestError.MissingExecutable,
                ExecutableRelativePath);
        }
        var actualSha = AsrModelStore.Sha256Hex(executable);
        if (!string.Equals(actualSha, Sha256, StringComparison.OrdinalIgnoreCase))
        {
            throw new AsrRuntimeBundleManifestException(
                AsrRuntimeBundleManifestError.Sha256Mismatch,
                actualSha);
        }
        return new AsrRuntimeInfo { Provider = Provider, ExecutablePath = executable };
    }

    public void Validate()
    {
        if (ExtraFields?.ContainsKey("downloadUrl") == true)
        {
            throw new AsrRuntimeBundleManifestException(AsrRuntimeBundleManifestError.DownloadUrlNotAllowed);
        }
        Require(Provider, nameof(Provider));
        Require(Platform, nameof(Platform));
        Require(Architecture, nameof(Architecture));
        Require(Version, nameof(Version));
        Require(License, nameof(License));
        Require(SourceDescription, nameof(SourceDescription));
        ValidateRelativePath(ExecutableRelativePath);
        ValidateSha256(Sha256);
    }

    private static void Require(string value, string field)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            throw new AsrRuntimeBundleManifestException(AsrRuntimeBundleManifestError.MissingRequiredField, field);
        }
    }

    private static void ValidateRelativePath(string value)
    {
        var trimmed = value.Trim();
        if (trimmed.Length == 0
            || Path.IsPathRooted(trimmed)
            || trimmed.Contains('\\', StringComparison.Ordinal)
            || trimmed.Contains(':', StringComparison.Ordinal))
        {
            throw new AsrRuntimeBundleManifestException(AsrRuntimeBundleManifestError.InvalidExecutableRelativePath, value);
        }
        var parts = trimmed.Split('/', StringSplitOptions.None);
        if (parts.Any(part => part.Length == 0 || part == "." || part == ".."))
        {
            throw new AsrRuntimeBundleManifestException(AsrRuntimeBundleManifestError.InvalidExecutableRelativePath, value);
        }
    }

    private static void ValidateSha256(string value)
    {
        var trimmed = value.Trim();
        if (trimmed.Length != 64 || trimmed.Any(ch => !Uri.IsHexDigit(ch)))
        {
            throw new AsrRuntimeBundleManifestException(AsrRuntimeBundleManifestError.InvalidSha256, value);
        }
    }
}

public sealed record AsrTranscriptCacheEntry
{
    public required string CacheKey { get; init; }
    public required string AudioFingerprint { get; init; }
    public required string ModelId { get; init; }
    public AsrBackendKind BackendKind { get; init; } = AsrBackendKind.WhisperCpp;
    public string? LanguageCode { get; init; }
    public required string TranscriptPath { get; init; }
    public DateTimeOffset CreatedAt { get; init; } = DateTimeOffset.UtcNow;
}

public static class AsrTranscriptMapper
{
    private const double LeadingSilenceToleranceSeconds = 0.12;
    private const double LeadingSilenceMinimumSeconds = 0.8;
    private const double LeadingSilenceCarryMaxGapSeconds = 1.0;
    private const double LeadingSilenceNoiseProbability = 0.35;
    private const double LeadingSilenceCarryProbability = 0.50;
    private const double LeadingSilenceCarryMinimumSeconds = 0.08;

    public static IReadOnlyList<SubtitleCueSourceFragment> SourceFragments(AsrTranscript transcript) =>
        WordsToFragments(transcript.Words);

    private static IReadOnlyList<SubtitleCueSourceFragment> SourceFragments(
        AsrTranscript transcript,
        SubtitleTimingProfile profile,
        AsrAudioActivity? audioActivity)
    {
        if (audioActivity is null || profile is not (SubtitleTimingProfile.Lyrics or SubtitleTimingProfile.JapaneseLyrics))
        {
            return SourceFragments(transcript);
        }
        return WordsToFragments(AdjustedLeadingSilenceWords(transcript.Words, audioActivity));
    }

    private static IReadOnlyList<SubtitleCueSourceFragment> WordsToFragments(IEnumerable<AsrWord> words)
    {
        var fragments = new List<(SubtitleCueSourceFragment Fragment, bool LatinMergeEligible)>();
        foreach (var word in words)
        {
            var text = LocalAsrSubtitleTimingPlanner.CleanedSpeechText(word.Text);
            if (text.Length == 0
                || double.IsNaN(word.StartSeconds)
                || double.IsInfinity(word.StartSeconds)
                || double.IsNaN(word.EndSeconds)
                || double.IsInfinity(word.EndSeconds)
                || word.StartSeconds < 0
                || word.EndSeconds < word.StartSeconds)
            {
                continue;
            }

            var fragment = new SubtitleCueSourceFragment(word.StartSeconds, word.EndSeconds, text);
            var startsNewWhisperTokenWord = word.Text.Length > 0
                && char.IsWhiteSpace(word.Text[0])
                && !ContainsCjkOrHangul(text);
            if (fragments.Count > 0
                && ShouldMergeLatinAsrToken(fragments[^1].Fragment.Text, fragments[^1].LatinMergeEligible, text, word.Text))
            {
                var previous = fragments[^1].Fragment;
                fragments[^1] = (new SubtitleCueSourceFragment(
                    previous.StartSeconds,
                    Math.Max(previous.EndSeconds, fragment.EndSeconds),
                    previous.Text + text), true);
            }
            else
            {
                fragments.Add((fragment, startsNewWhisperTokenWord));
            }
        }
        return fragments.Select(item => item.Fragment).ToList();
    }

    private static bool ShouldMergeLatinAsrToken(
        string previousText,
        bool previousMergeEligible,
        string currentText,
        string rawCurrentText)
    {
        if (!previousMergeEligible) return false;
        if (rawCurrentText.Length > 0 && char.IsWhiteSpace(rawCurrentText[0])) return false;
        var previous = previousText.Trim();
        var current = currentText.Trim();
        if (previous.Length == 0 || current.Length == 0) return false;
        if (ContainsCjkOrHangul(previous) || ContainsCjkOrHangul(current)) return false;
        if (IsLatinJoinPunctuation(current)) return true;
        if (IsLatinApostrophePrefix(previous) && ContainsLetterOutsideCjk(current)) return true;
        return ContainsLetterOutsideCjk(previous) && ContainsLetterOutsideCjk(current);
    }

    private static bool IsLatinJoinPunctuation(string text) =>
        text.All(ch => ch is '\'' or '’' or '.' or ',' or '!' or '?' or ':' or ';')
        || text[0] is '\'' or '’';

    private static bool IsLatinApostrophePrefix(string text) =>
        text.All(ch => ch is '\'' or '’');

    private static bool ContainsLetterOutsideCjk(string text) =>
        text.EnumerateRunes().Any(rune => Rune.IsLetter(rune) && !IsCjkOrHangulScalar(rune.Value));

    private static bool ContainsCjkOrHangul(string text) =>
        text.EnumerateRunes().Any(rune => IsCjkOrHangulScalar(rune.Value));

    private static bool IsCjkOrHangulScalar(int value) =>
        value is >= 0x3040 and <= 0x30FF
            or >= 0x3400 and <= 0x4DBF
            or >= 0x4E00 and <= 0x9FFF
            or >= 0xAC00 and <= 0xD7A3;

    private static IReadOnlyList<AsrWord> AdjustedLeadingSilenceWords(
        IReadOnlyList<AsrWord> words,
        AsrAudioActivity audioActivity)
    {
        var leadingSilence = audioActivity.SilenceRanges.FirstOrDefault(range =>
            range.StartSeconds <= LeadingSilenceToleranceSeconds
            && range.EndSeconds - range.StartSeconds >= LeadingSilenceMinimumSeconds);
        if (leadingSilence is null) return words;

        var silenceEnd = leadingSilence.EndSeconds;
        var firstAudibleIndex = -1;
        for (var i = 0; i < words.Count; i++)
        {
            if (words[i].EndSeconds > silenceEnd + LeadingSilenceToleranceSeconds
                || words[i].StartSeconds >= silenceEnd)
            {
                firstAudibleIndex = i;
                break;
            }
        }
        if (firstAudibleIndex < 0)
        {
            return words.Where(word => !IsLowConfidenceLeadingLyricNoise(word)).ToList();
        }
        if (firstAudibleIndex == 0)
        {
            return words.Select(word =>
                word.StartSeconds < silenceEnd && word.EndSeconds > silenceEnd
                    ? word with { StartSeconds = silenceEnd }
                    : word).ToList();
        }

        var adjusted = new List<AsrWord>();
        var carryWord = words
            .Take(firstAudibleIndex)
            .LastOrDefault(word =>
                !IsLowConfidenceLeadingLyricNoise(word)
                && (word.Probability ?? 1.0) >= LeadingSilenceCarryProbability);
        if (carryWord is not null)
        {
            var nextStart = words[firstAudibleIndex].StartSeconds;
            if (nextStart >= silenceEnd && nextStart - silenceEnd <= LeadingSilenceCarryMaxGapSeconds)
            {
                adjusted.Add(carryWord with
                {
                    StartSeconds = silenceEnd,
                    EndSeconds = Math.Max(silenceEnd + LeadingSilenceCarryMinimumSeconds, nextStart),
                });
            }
        }

        for (var i = firstAudibleIndex; i < words.Count; i++)
        {
            var word = words[i];
            adjusted.Add(word.StartSeconds < silenceEnd && word.EndSeconds > silenceEnd
                ? word with { StartSeconds = silenceEnd }
                : word);
        }
        return adjusted;
    }

    private static bool IsLowConfidenceLeadingLyricNoise(AsrWord word)
    {
        var text = LocalAsrSubtitleTimingPlanner.CleanedSpeechText(word.Text);
        var visibleCount = text.Count(ch => !char.IsWhiteSpace(ch));
        return visibleCount <= 2 && (word.Probability ?? 1.0) < LeadingSilenceNoiseProbability;
    }

    public static IReadOnlyList<SubtitleCue> SourceCues(
        AsrTranscript transcript,
        SubtitleTimingProfile profile = SubtitleTimingProfile.Speech,
        AsrAudioActivity? audioActivity = null) =>
        WhisperCueRetimer.Retime(
            LocalAsrSubtitleTimingPlanner.PlanCues(SourceFragments(transcript, profile, audioActivity), transcript.DurationSeconds, profile),
            transcript.DurationSeconds,
            profile,
            audioActivity);

    /// <summary>
    /// Detect the content-type timing profile from the filename and a first-pass (Speech) cue
    /// shape, then re-plan with the matching profile. Mirrors Swift sourceCues(from:fileName:).
    /// </summary>
    public static IReadOnlyList<SubtitleCue> SourceCues(
        AsrTranscript transcript,
        string fileName,
        AsrAudioActivity? audioActivity = null)
    {
        var speechCues = SourceCues(transcript, SubtitleTimingProfile.Speech);
        var profile = SubtitleTimingProfileDetector.Detect(fileName, speechCues, transcript.LanguageCode);
        return profile == SubtitleTimingProfile.Speech ? speechCues : SourceCues(transcript, profile, audioActivity);
    }

    public static string LocalAsrSourceSrtPath(string videoFile, string languageCode)
    {
        var directory = Path.GetDirectoryName(videoFile) ?? ".";
        var stem = Path.GetFileNameWithoutExtension(videoFile);
        var language = NormalizeLanguageCode(languageCode);
        return Path.Combine(directory, $"{stem}.local-asr.{language}.srt");
    }

    public static string WriteLocalAsrSourceSrt(
        AsrTranscript transcript,
        string videoFile,
        AsrAudioActivity? audioActivity = null)
    {
        var cues = SourceCues(transcript, Path.GetFileName(videoFile), audioActivity);
        if (cues.Count == 0)
        {
            throw new WhisperCppRecognizerException(WhisperCppRecognizerError.EmptyTranscript);
        }
        var output = LocalAsrSourceSrtPath(videoFile, transcript.LanguageCode);
        Directory.CreateDirectory(Path.GetDirectoryName(output) ?? ".");
        File.WriteAllText(output, SrtTools.SerializeSrt(cues), Encoding.UTF8);
        return output;
    }

    private static string NormalizeLanguageCode(string value)
    {
        var trimmed = value.Trim();
        return trimmed.Length == 0 ? "und" : trimmed;
    }

}

/// <summary>
/// Content-type timing profile. Local-ASR subtitles for a lecture, a song, and an anime need
/// different regroup ceilings, break gaps, and hold-to-next behaviour. The profile is detected once
/// (filename + cue shape, see Translator.DetectTimingProfile) and threaded through all three timing
/// layers. <c>Speech</c> reproduces the pre-profile behaviour exactly. Mirrors Swift SubtitleTimingProfile.
/// </summary>
public enum SubtitleTimingProfile
{
    Speech,
    Lyrics,
    JapaneseLyrics,
    Anime,
}

/// <summary>
/// Detects the content-type timing profile from a filename and first-pass cue shape. Pure and
/// deterministic so it is unit-testable and mirrored 1:1 in Swift SubtitleTimingProfileDetector.
/// </summary>
public static class SubtitleTimingProfileDetector
{
    private static readonly string[] LyricsFilenameKeywords =
    [
        "official music video", "music video", "official mv", " mv ",
        "lyrics", "lyric", "song", "cover", "歌ってみた", "歌詞", "字幕版", "mv)",
    ];
    private static readonly string[] JapaneseMusicFilenameKeywords =
    [
        " live", "ライブ", "official audio", "official visualizer", "performance video",
    ];
    private static readonly string[] AnimeFilenameKeywords =
    [
        "anime", "アニメ", "动画", "動畫", "ova",
    ];
    private static readonly HashSet<char> SentenceEnders = ['.', '!', '?', '。', '！', '？'];

    private static bool IsEpisodeDigit(char c) =>
        c is >= '0' and <= '9' || c is >= '０' and <= '９'; // 半角 + 全角数字

    private static bool IsAsciiLetter(char c) => c is >= 'a' and <= 'z'; // lower 已小写

    /// <summary>
    /// 仅在数字邻接时才把分集标记当动漫信号，避免裸「第/话/episode」把任意标题误判成动漫。
    /// 命中：第&lt;数字&gt;话 / 第&lt;数字&gt;話 / episode&lt;可选分隔&gt;&lt;数字&gt; / ep&lt;可选 .或空格&gt;&lt;数字&gt;（含全角数字）。
    /// 纯字符扫描、无正则，与 Swift containsEpisodeMarker 逐字符一致镜像。<paramref name="lower"/> 须为已小写的文件名。
    /// </summary>
    internal static bool ContainsEpisodeMarker(string lower)
    {
        var n = lower.Length;
        for (var i = 0; i < n; i++)
        {
            var c = lower[i];
            // 第<数字>(话|話)
            if (c == '第')
            {
                var j = i + 1;
                var sawDigit = false;
                while (j < n && IsEpisodeDigit(lower[j])) { sawDigit = true; j++; }
                if (sawDigit && j < n && (lower[j] == '话' || lower[j] == '話')) return true;
            }
            // 词边界处的 ep / episode，后跟可选 '.'/' ' 再接数字。
            if (c == 'e' && (i == 0 || !IsAsciiLetter(lower[i - 1])))
            {
                var markerLen = 0;
                if (Matches(lower, i, "episode")) markerLen = 7;
                else if (Matches(lower, i, "ep")) markerLen = 2;
                if (markerLen > 0)
                {
                    var k = i + markerLen;
                    while (k < n && (lower[k] == '.' || lower[k] == ' ')) k++;
                    if (k < n && IsEpisodeDigit(lower[k])) return true;
                }
            }
        }
        return false;
    }

    private static bool Matches(string s, int index, string word)
    {
        if (index + word.Length > s.Length) return false;
        for (var offset = 0; offset < word.Length; offset++)
        {
            if (s[index + offset] != word[offset]) return false;
        }
        return true;
    }

    public static SubtitleTimingProfile Detect(string fileName, IReadOnlyList<SubtitleCue> cues, string? languageCode = null)
    {
        var lower = fileName.ToLowerInvariant();
        if (LyricsFilenameKeywords.Any(lower.Contains))
        {
            return LooksJapanese(lower, languageCode, cues) ? SubtitleTimingProfile.JapaneseLyrics : SubtitleTimingProfile.Lyrics;
        }
        var earlyJapaneseContent = LooksJapanese(lower, languageCode, cues);
        if (earlyJapaneseContent
            && (JapaneseMusicFilenameKeywords.Any(lower.Contains)
                || HasJapaneseLyricBoilerplateHallucination(cues)
                || HasJapaneseLyricIntroMusicHallucination(cues)))
        {
            return SubtitleTimingProfile.JapaneseLyrics;
        }
        if (cues.Count < 20)
        {
            return AnimeFilenameKeywords.Any(lower.Contains) || ContainsEpisodeMarker(lower)
                ? SubtitleTimingProfile.Anime : SubtitleTimingProfile.Speech;
        }

        var durations = new List<double>();
        var largeGaps = 0;
        var shortCues = 0;
        var cjkChars = 0;
        var totalChars = 0;
        var punctuated = 0;
        double? previousEnd = null;
        foreach (var cue in cues)
        {
            var trimmed = cue.Text.Trim();
            if (trimmed.Length > 0 && SentenceEnders.Contains(trimmed[^1])) punctuated++;
            foreach (var ch in trimmed)
            {
                if (!char.IsWhiteSpace(ch)) totalChars++;
                int value = ch;
                if ((value >= 0x3040 && value <= 0x30FF)
                    || (value >= 0x4E00 && value <= 0x9FFF)
                    || (value >= 0xAC00 && value <= 0xD7A3))
                {
                    cjkChars++;
                }
            }
            var start = SrtTools.SrtTimeToSeconds(cue.Start);
            var end = SrtTools.SrtTimeToSeconds(cue.End);
            if (start is null || end is null || end.Value <= start.Value) continue;
            var duration = end.Value - start.Value;
            durations.Add(duration);
            if (duration <= 1.5) shortCues++;
            if (previousEnd is { } prev && start.Value - prev >= 1.2) largeGaps++;
            previousEnd = end.Value;
        }
        if (durations.Count == 0) return SubtitleTimingProfile.Speech;
        var punctuatedRatio = (double)punctuated / cues.Count;
        var average = durations.Sum() / durations.Count;
        var japaneseContent = earlyJapaneseContent;

        // Some official J-pop uploads have titles like "Ado - うっせぇわ" without "MV" or
        // "lyrics". If whisper has already fallen into a dense Japanese loop, route through the
        // lyric profile so the dedicated hallucination suppressor can clean it up.
        if (japaneseContent
            && punctuatedRatio < 0.2
            && (HasDenseJapaneseAsrLoop(cues) || HasJapaneseLyricBoilerplateHallucination(cues)))
        {
            return SubtitleTimingProfile.JapaneseLyrics;
        }

        // Lyrics: few sentence-final punctuation marks, medium-length lines, frequent silent gaps
        // between phrases (the shape of a sung verse) — matches Translator.LooksLikeLocalAsrLyrics.
        if (punctuatedRatio < 0.2 && average >= 3.0 && average <= 5.8 && largeGaps >= 2)
        {
            return japaneseContent ? SubtitleTimingProfile.JapaneseLyrics : SubtitleTimingProfile.Lyrics;
        }

        var cjkRatio = totalChars > 0 ? (double)cjkChars / totalChars : 0;
        var shortRatio = (double)shortCues / cues.Count;
        if (AnimeFilenameKeywords.Any(lower.Contains) || ContainsEpisodeMarker(lower)) return SubtitleTimingProfile.Anime;
        if (cjkRatio >= 0.5 && shortRatio >= 0.45 && punctuatedRatio < 0.35)
        {
            return SubtitleTimingProfile.Anime;
        }
        return SubtitleTimingProfile.Speech;
    }

    private static bool HasDenseJapaneseAsrLoop(IReadOnlyList<SubtitleCue> cues)
    {
        var normalized = NormalizeJapaneseCueText(string.Concat(cues.Select(cue => cue.Text)));
        if (normalized.Length < 80) return false;
        var uniqueRatio = (double)normalized.Distinct().Count() / normalized.Length;
        if (uniqueRatio > 0.24) return false;
        if (RepeatedBigramExcess(normalized) < 24) return false;
        return HasDominantRepeatedSubstring(normalized);
    }

    private static bool HasJapaneseLyricBoilerplateHallucination(IReadOnlyList<SubtitleCue> cues)
    {
        var normalized = NormalizeJapaneseCueText(string.Concat(cues.Select(cue => cue.Text)));
        var hasCreditCluster = normalized.Contains("作詞", StringComparison.Ordinal)
            && (normalized.Contains("作曲", StringComparison.Ordinal)
                || normalized.Contains("編曲", StringComparison.Ordinal)
                || normalized.Contains("初音ミク", StringComparison.Ordinal));
        var thankYouCount = normalized.Split("ご視聴ありがとうございました", StringSplitOptions.None).Length - 1;
        var thankYouIndex = normalized.IndexOf("ご視聴ありがとうございました", StringComparison.Ordinal);
        var hasTerminalThankYou = thankYouIndex >= 0
            && normalized.Length - (thankYouIndex + "ご視聴ありがとうございました".Length) <= 12;
        return hasCreditCluster || thankYouCount >= 2 || hasTerminalThankYou;
    }

    private static bool HasJapaneseLyricIntroMusicHallucination(IReadOnlyList<SubtitleCue> cues)
    {
        if (cues.Count == 0) return false;
        var start = SrtTools.SrtTimeToSeconds(cues[0].Start);
        if (start is null || start.Value > 2.0) return false;
        var head = string.Concat(cues.Take(3).Select(cue => NormalizedLatinCueText(cue.Text)));
        return head.StartsWith("BGM", StringComparison.Ordinal);
    }

    private static string NormalizeJapaneseCueText(string text)
    {
        var builder = new StringBuilder();
        foreach (var ch in text)
        {
            if (ch is >= '\u3040' and <= '\u309F'
                || ch is >= '\u30A0' and <= '\u30FF'
                || ch is >= '\u4E00' and <= '\u9FFF')
            {
                builder.Append(ch);
            }
        }
        return builder.ToString();
    }

    private static string NormalizedLatinCueText(string text)
    {
        var builder = new StringBuilder();
        foreach (var ch in text)
        {
            if (ch is >= 'A' and <= 'Z')
            {
                builder.Append(ch);
            }
            else if (ch is >= 'a' and <= 'z')
            {
                builder.Append(char.ToUpperInvariant(ch));
            }
        }
        return builder.ToString();
    }

    private static int RepeatedBigramExcess(string text)
    {
        if (text.Length < 2) return 0;
        var counts = new Dictionary<string, int>(StringComparer.Ordinal);
        for (var index = 0; index < text.Length - 1; index++)
        {
            var bigram = text.Substring(index, 2);
            counts[bigram] = counts.GetValueOrDefault(bigram) + 1;
        }
        return counts.Values.Sum(count => Math.Max(0, count - 1));
    }

    private static bool HasDominantRepeatedSubstring(string text)
    {
        var maxLength = Math.Min(28, text.Length / 2);
        if (maxLength < 8) return false;
        for (var length = maxLength; length >= 8; length--)
        {
            var counts = new Dictionary<string, int>(StringComparer.Ordinal);
            for (var index = 0; index <= text.Length - length; index++)
            {
                var substring = text.Substring(index, length);
                if (substring.Distinct().Count() < 3) continue;
                counts[substring] = counts.GetValueOrDefault(substring) + 1;
            }
            if (counts.Values.Any(count =>
                count >= 3 && (double)(length * count) / text.Length >= 0.35))
            {
                return true;
            }
        }
        return false;
    }

    private static bool LooksJapanese(string lowerFileName, string? languageCode, IReadOnlyList<SubtitleCue> cues)
    {
        if (IsJapaneseLanguage(languageCode)) return true;
        if (lowerFileName.Contains(".ja.") || lowerFileName.Contains(".ja-")
            || lowerFileName.Contains("_ja.") || lowerFileName.Contains("_ja-")
            || lowerFileName.Contains("[ja]")
            || lowerFileName.Contains("日本語") || lowerFileName.Contains("日语") || lowerFileName.Contains("日語"))
        {
            return true;
        }

        var kana = 0;
        var visible = 0;
        foreach (var cue in cues.Take(40))
        {
            foreach (var ch in cue.Text)
            {
                if (char.IsWhiteSpace(ch)) continue;
                visible++;
                if (ch is >= '\u3040' and <= '\u30FF') kana++;
            }
        }
        return visible > 0 && (double)kana / visible >= 0.18;
    }

    private static bool IsJapaneseLanguage(string? languageCode)
    {
        if (string.IsNullOrWhiteSpace(languageCode)) return false;
        var normalized = languageCode.Trim().ToLowerInvariant();
        return normalized == "ja" || normalized == "jpn" || normalized.StartsWith("ja-", StringComparison.Ordinal);
    }
}

/// <summary>
/// Per-profile regroup/timing thresholds. The single cross-platform source of truth for the
/// differentiated values is Tests/fixtures/whisper-timing-constants.json (profiles section); the
/// Swift and C# threshold tables are each asserted equal to it (ARCH-3 parity). Mirrors Swift
/// SubtitleTimingThresholds.
/// </summary>
public readonly record struct SubtitleTimingThresholds(
    double MaximumCjkCueSeconds,
    double HardMaximumCjkCueSeconds,
    double RelaxedCjkCueSeconds,
    double MaximumLatinCueSeconds,
    double LargeSpeechGapSeconds,
    double OnsetDelaySeconds,
    double HoldToNextSeconds,
    double ResidualMaxStandaloneSeconds,
    double BreathGapBreakSeconds);

public static partial class LocalAsrSubtitleTimingPlanner
{
    internal const double MinimumCueSeconds = 0.3;
    private const double SentenceTailSeconds = 0.45;
    private const double PhraseTailSeconds = 0.2;
    internal const double MaximumCjkCueSeconds = 4.5;
    internal const double HardMaximumCjkCueSeconds = 5.5;
    internal const double RelaxedCjkCueSeconds = 6.5;
    internal const double MaximumLatinCueSeconds = SubtitleTimingPlanner.NormalReadableCueSeconds;
    private const double ShortStandaloneCjkCueSeconds = 2.4;
    private const int MaximumCjkUnits = 18;
    private const int HardMaximumCjkUnits = 28;
    private const int RelaxedShortMergeMaxCjkUnits = 34;
    private const int MaximumLatinTokens = 14;
    // 0.65->0.50 (2026-06-24, segmentation eval direction B): mirror of Swift largeSpeechGapSeconds;
    // human captions treat 0.4-0.65s pauses as strong boundaries the old 0.65 missed. Keep in sync
    // with Sources/MoongateCore/ASR.swift and Tests/fixtures/whisper-timing-constants.json.
    private const double LargeSpeechGapSeconds = 0.50;

    // Per-profile thresholds. `Speech` reproduces the standalone constants above exactly (zero
    // behaviour change for the default path); `Lyrics` / `Anime` tighten ceilings and break gaps
    // for song lines and short anime reactions. Mirrors Swift LocalASRSubtitleTimingPlanner and
    // asserted against Tests/fixtures/whisper-timing-constants.json (profiles section).
    internal static SubtitleTimingThresholds Thresholds(SubtitleTimingProfile profile) => profile switch
    {
        SubtitleTimingProfile.Lyrics => new SubtitleTimingThresholds(
            MaximumCjkCueSeconds: 3.0,
            HardMaximumCjkCueSeconds: 4.0,
            RelaxedCjkCueSeconds: 4.5,
            MaximumLatinCueSeconds: 5.0,
            LargeSpeechGapSeconds: 0.45,
            OnsetDelaySeconds: 0.1,
            HoldToNextSeconds: 0.35,
            ResidualMaxStandaloneSeconds: 0.9,
            BreathGapBreakSeconds: 0.25),
        SubtitleTimingProfile.JapaneseLyrics => new SubtitleTimingThresholds(
            MaximumCjkCueSeconds: 4.2,
            HardMaximumCjkCueSeconds: 5.2,
            RelaxedCjkCueSeconds: 5.8,
            MaximumLatinCueSeconds: 5.4,
            LargeSpeechGapSeconds: 0.5,
            OnsetDelaySeconds: 0.0,
            HoldToNextSeconds: 0.28,
            ResidualMaxStandaloneSeconds: 0.9,
            BreathGapBreakSeconds: 0.3),
        SubtitleTimingProfile.Anime => new SubtitleTimingThresholds(
            MaximumCjkCueSeconds: 3.5,
            HardMaximumCjkCueSeconds: 5.0,
            RelaxedCjkCueSeconds: 5.5,
            MaximumLatinCueSeconds: 7.0,
            LargeSpeechGapSeconds: 0.55,
            OnsetDelaySeconds: 0.15,
            HoldToNextSeconds: 0.5,
            ResidualMaxStandaloneSeconds: 1.2,
            BreathGapBreakSeconds: 0.3),
        _ => new SubtitleTimingThresholds(
            MaximumCjkCueSeconds: MaximumCjkCueSeconds,
            HardMaximumCjkCueSeconds: HardMaximumCjkCueSeconds,
            RelaxedCjkCueSeconds: RelaxedCjkCueSeconds,
            MaximumLatinCueSeconds: MaximumLatinCueSeconds,
            LargeSpeechGapSeconds: LargeSpeechGapSeconds,
            OnsetDelaySeconds: WhisperCueRetimer.OnsetDelaySeconds,
            HoldToNextSeconds: WhisperCueRetimer.HoldToNextSeconds,
            ResidualMaxStandaloneSeconds: double.MaxValue,
            BreathGapBreakSeconds: 0.35),
    };
    private static readonly HashSet<string> LatinContinuationSuffixes =
    [
        "s", "es", "ed", "er", "ers", "or", "ors", "ing", "ly", "ally", "ually",
        "ist", "ists", "tion", "tions", "ment", "ness", "less", "able", "ible",
        "al", "ial", "ual", "cial", "ance", "ence", "ancia", "anca", "ança",
        "encia", "ência", "eiro", "eira", "eiros", "eiras", "iro", "iros", "ira", "iras",
        "ais", "ias", "ción", "ciones", "ção", "ções", "dad", "dade", "idades",
        "ada", "adas", "ado", "ados", "estra", "estre", "ês",
        "mente", "mento", "miento", "amiento", "zione", "zioni", "ient", "aient",
        "lich", "chen", "en", "ern", "ung", "ungen", "heit", "keit",
        "zial", "ier", "ieren", "uren", "feld", "sprach", "sprache", "ne", "wich",
        "ità", "tà", "né", "nné", "rsità", "é", "ée", "ior", "ano", "rice",
    ];
    private static readonly HashSet<string> ShortLatinContinuationSuffixes =
    [
        "ne", "ês", "né", "tà", "é", "ée",
    ];
    private static readonly HashSet<string> LatinBridgeFragments =
    [
        "la", "le", "li", "lo",
    ];
    private static readonly HashSet<string> LatinBridgeTailSuffixes =
    [
        "ient", "aient", "ée", "rice", "ano", "êt", "lio", "li", "na", "ette",
    ];
    private static readonly Dictionary<string, HashSet<string>> ObservedLatinBridgePrefixes = new()
    {
        ["ach"] = ["arr"],
        ["at"] = ["cré"],
        ["r"] = ["most"],
        ["n"] = ["lection", "sélection", "selection", "ion"],
        ["onn"] = ["h"],
        ["og"] = ["org"],
        ["g"] = ["inse"],
    };
    private static readonly Dictionary<string, HashSet<string>> ObservedLatinContinuationPrefixes = new()
    {
        ["ütlich"] = ["gem"],
        ["üt"] = ["gem"],
        ["elt"] = ["reg"],
        ["est"] = ["bef"],
        ["igt"] = ["befest"],
        ["ver"] = ["seiten"],
        ["kle"] = ["seitenver", "ver"],
        ["id"] = ["seitenverkle", "kle"],
        ["ung"] = ["seitenverkleid", "id"],
        ["äck"] = ["gep"],
        ["ä"] = ["gep", "ep", "f"],
        ["ck"] = ["gepä", "ä"],
        ["f"] = ["gepäck", "ck"],
        ["cher"] = ["gepäckfä", "fä", "ä"],
        ["fächer"] = ["gepäck"],
        ["ch"] = ["was"],
        ["rä"] = ["wasch", "ch"],
        ["ume"] = ["waschrä", "rä"],
        ["amento"] = ["levant"],
        ["cre"] = ["trans"],
        ["ve"] = ["transcre", "cre"],
        ["mos"] = ["transcreve", "ve"],
        ["ut"] = ["trad"],
        ["ores"] = ["tradut", "ut"],
        ["ários"] = ["volunt"],
        ["ng"] = ["lí"],
        ["u"] = ["líng"],
        ["as"] = ["língu"],
        ["il"] = ["ut"],
        ["ise"] = ["util"],
        ["è"] = ["r"],
        ["gl"] = ["rè"],
        ["és"] = ["règl"],
        ["li"] = ["app", "orgog", "neg"],
        ["quer"] = ["appli"],
        ["ien"] = ["quotid", "chem"],
        ["ion"] = ["mar", "op", "opin"],
        ["in"] = ["op"],
        ["ette"] = ["marionn", "n"],
        ["no"] = ["reg"],
        ["ito"] = ["un"],
        ["ra"] = ["lond"],
        ["a"] = ["core"],
        ["ia"] = ["svez"],
        ["ix"] = ["d"],
        ["lection"] = ["sé", "se"],
        ["n"] = ["sélection", "selection", "marion", "ion"],
        ["êt"] = ["honn", "onn"],
        ["ée"] = ["sélectionn", "selectionn"],
        ["eté"] = ["honnêt", "honnet"],
        ["lio"] = ["orgog"],
        ["ino"] = ["lat"],
        ["os"] = ["orgogli", "li"],
        ["amente"] = ["orgoglios", "os"],
        ["ati"] = ["st"],
        ["iti"] = ["un"],
        ["igi"] = ["par"],
    };
    private static readonly Dictionary<string, HashSet<string>> ObservedStandaloneLatinFunctionPrefixes = new()
    {
        ["al"] = ["ito", "unito", "posto"],
        ["en"] = ["influencer", "prendre", "encore", "mais"],
        ["ne"] = ["qui"],
    };
    private static readonly HashSet<string> StrongLatinContinuationSuffixes =
    [
        "s", "es", "ed", "er", "ers", "or", "ors", "ing", "ly", "ally", "ually",
        "ist", "ists", "tion", "tions", "ment", "ness", "less", "able", "ible",
    ];
    private static readonly HashSet<string> LatinContinuationFunctionWords =
    [
        "a", "an", "and", "as", "at", "but", "by", "for", "from", "if", "in", "is", "it",
        "of", "on", "or", "the", "to", "we", "you", "he", "she", "they", "i", "me", "my",
        "un", "una", "une", "le", "la", "les", "de", "des", "du", "et", "ou", "que",
        "je", "tu", "il", "elle", "nous", "vous", "ce", "ces", "mon", "ma", "mes",
        "el", "los", "las", "y", "o", "yo", "tú", "tu", "él", "ella", "por", "para", "con",
        "em", "no", "na", "os", "as", "eu", "nós", "nos", "não", "ao", "à",
        "io", "noi", "voi", "che", "per", "con",
        "ich", "du", "er", "sie", "wir", "ihr", "der", "die", "das", "ein", "eine",
        "mit", "zu", "auf", "im", "am",
    ];

    // Japanese kana / punctuation that must not START a subtitle line (particles, small kana,
    // long-vowel mark, closing punctuation). Mirrors the Swift cjkLeadingProhibited set.
    private static readonly HashSet<char> CjkLeadingProhibited =
    [
        'を', 'が', 'は', 'に', 'へ', 'と', 'で', 'も', 'の', 'ね', 'よ', 'さ', 'わ', 'ぞ', 'ぜ', 'ん',
        'っ', 'ゃ', 'ゅ', 'ょ', 'ぁ', 'ぃ', 'ぅ', 'ぇ', 'ぉ', 'ゎ', 'ー', '〜',
        '、', '。', '，', '．', '・', '！', '？', '」', '』', '）', '”', '’',
    ];

    // Standalone residual kana / long-vowel marks that whisper often hallucinates from breath,
    // music, or stretched audio. Keeping them as cues creates multi-second 「っ」/「ー」 flashes.
    private static readonly HashSet<string> DroppableJapaneseResiduals =
    [
        "っ", "ー", "〜", "ぁ", "ぃ", "ぅ", "ぇ", "ぉ", "ゎ",
    ];
    private static readonly string[] JapaneseLyricPhraseStartPrefixes =
    [
        "そんな", "こんな", "あんな", "どんな", "この", "その", "あの",
        "これ", "それ", "あれ", "でも", "だけど",
    ];
    private static readonly HashSet<string> JapaneseLyricBareTailFragments =
    [
        "な", "て", "で", "に", "の", "が", "は", "を", "も", "と", "よ", "ね", "さ", "ん",
    ];
    private static readonly HashSet<string> JapaneseLyricAdnominalHeads =
    [
        "よう", "そう", "みたい",
    ];
    private static readonly HashSet<char> JapaneseLyricObjectParticleStarts =
    [
        'を', 'が', 'は', 'に', 'へ', 'と', 'で', 'も', 'の',
    ];
    private static readonly HashSet<char> JapaneseLyricSingleKanjiSuffixes =
    [
        '生', '者', '性', '感', '心', '声', '音', '色', '先', '中', '目', '手',
    ];
    private static readonly HashSet<string> JapaneseLyricKanaVerbStemTails =
    [
        "もが", "こ", "続",
    ];

    private const int JapaneseLoopMinPhraseFragments = 4;
    private const int JapaneseLoopMaxPhraseFragments = 12;
    private const int JapaneseLoopMinRepeatCount = 4;
    private const int JapaneseLoopAllowedRepeats = 1;
    private const double JapaneseLoopMaxPhraseSpanSeconds = 3.0;
    private const double JapaneseLoopMaxOccurrenceGapSeconds = 0.8;
    private const double JapaneseLoopFuseSeconds = 90.0;
    private const int JapaneseLyricLoopCueMinCount = 5;
    private const int JapaneseLyricLoopCueMinNormalizedCharacters = 28;
    private const double JapaneseLyricLoopCueMaxSpanSeconds = 35.0;
    private const double JapaneseLyricLoopCueMaxGapSeconds = 4.0;
    private const double JapaneseLyricLoopCueMaxUniqueCharacterRatio = 0.38;
    private const int JapaneseLyricLoopCueMinRepeatedBigramExcess = 8;
    private const double JapaneseLyricLoopCueLongSparseSeconds = 8.0;
    private const int JapaneseLyricDenseLoopMinCharacters = 36;
    private const int JapaneseLyricDenseLoopMinSubstringCharacters = 8;
    private const int JapaneseLyricDenseLoopMaxSubstringCharacters = 28;
    private const int JapaneseLyricDenseLoopMinOccurrences = 3;
    private const double JapaneseLyricDenseLoopMinCoverage = 0.55;
    private static readonly HashSet<string> JapaneseLyricCreditHallucinationTokens = new(StringComparer.Ordinal)
    {
        "作", "詞", "词", "作詞", "作词", "曲", "作曲", "編", "编", "編曲", "编曲", "初", "音", "初音", "ミ", "ク", "ミク", "初音ミク",
    };
    private static readonly string[] JapaneseLyricCreditHallucinationMarkers =
    [
        "作詞", "作词", "作曲", "編曲", "编曲", "初音ミク",
    ];
    private const double JapaneseLyricCreditHallucinationMaxGapSeconds = 4.0;
    private static readonly string[] JapaneseLyricOutroHallucinationMarkers =
    [
        "ご視聴ありがとうございました",
    ];
    private static readonly HashSet<string> LyricFillerLoopTokens = new(StringComparer.Ordinal)
    {
        "yeah", "yea", "ya", "yah", "ey", "hey", "heyy",
        "oh", "ooh", "uh", "uhh", "ah", "mmm", "mm", "hmm", "hm",
    };
    private const double LyricFillerLoopMinDurationSeconds = 8.0;
    private const int LyricFillerLoopMinTokenCount = 12;
    private const int LyricFillerLoopHighTokenCount = 24;
    private const int LyricFillerCueMinTokenCount = 3;
    private const double LyricFillerCueMinRatio = 0.75;
    private const double LyricFillerLoopMaxGapSeconds = 1.5;
    private const double LyricIntroCreditNameMaxStartSeconds = 3.0;
    private const double LyricIntroCreditNameMaxEndSeconds = 5.0;
    private const double LyricIntroCreditNameMinNextStartSeconds = 8.0;
    private const double LyricIntroCreditNameMinGapSeconds = 6.0;
    private const int LyricIntroCreditNameMinVisibleChars = 2;
    private const int LyricIntroCreditNameMaxVisibleChars = 4;
    private const double LyricRepeatedIntroFillerMaxStartSeconds = 35.0;
    private const int LyricRepeatedIntroFillerMinCueCount = 5;
    private const double LyricRepeatedIntroFillerMinDurationSeconds = 8.0;
    private const double LyricRepeatedIntroFillerMaxGapSeconds = 2.5;
    private const int LyricRepeatedIntroFillerMinKeyCharacters = 3;
    private const int LyricRepeatedIntroFillerMaxKeyCharacters = 14;
    private const int LyricRepeatedIntroFillerMaxRawKeyCharacters = 42;
    private const int LyricRepeatedIntroFillerMaxVisibleChars = 16;
    private static readonly string[] LyricOutroBoilerplateKeys =
    [
        "thanksforwatching", "thankyouforwatching", "graciasporver", "graciasporverelvideo",
        "ご視聴ありがとうございました",
    ];

    // A cue with at most this many visible characters is too short to stand alone (lone 「顔」/「ね」)
    // and is merged into the temporally-closest neighbour, within this same-utterance gap.
    private const int LoneMergeMaxVisibleChars = 3;
    private const double LoneMergeMaxGapSeconds = 1.0;

    /// <summary>
    /// 合并短孤儿组的有效间隙上限。仅 speech 档收紧到该档"大停顿断句阈值"(真实停顿是合法人工句边界,
    /// 已断处不应被短组重并吞回,strong-recall 丢分);歌词/动漫档保持 1.0s(有专门跨演唱停顿重接逻辑,冻结)。
    /// 镜像 Swift effectiveLoneMergeMaxGap。
    /// </summary>
    private static double EffectiveLoneMergeMaxGap(SubtitleTimingThresholds thresholds, SubtitleTimingProfile profile) =>
        profile == SubtitleTimingProfile.Speech
            ? Math.Min(LoneMergeMaxGapSeconds, thresholds.LargeSpeechGapSeconds)
            : LoneMergeMaxGapSeconds;
    private const double JapaneseLyricParticleRejoinMaxGapSeconds = 1.35;
    private const double JapaneseLyricSemanticRejoinMaxGapSeconds = 0.75;
    private const double JapaneseLyricKanaVerbRejoinMaxGapSeconds = 0.9;
    private const double JapaneseLyricModifierRejoinMaxGapSeconds = 0.35;
    private const double FlashMinCueSeconds = 0.8;
    private const double FlashMergeMaxGapSeconds = 0.6;

    [GeneratedRegex(@"\[_[A-Z]+(?:_[0-9]+)?_?\]")]
    private static partial Regex WhisperMarkerRegex();

    public static string CleanedSpeechText(string value)
    {
        var text = WhisperMarkerRegex().Replace(value, " ").ReplaceLineEndings(" ");
        return string.Join(
            " ",
            text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
    }

    public static IReadOnlyList<SubtitleCue> PlanCues(
        IReadOnlyList<SubtitleCueSourceFragment> fragments,
        double? transcriptDurationSeconds = null,
        SubtitleTimingProfile profile = SubtitleTimingProfile.Speech)
    {
        var thresholds = Thresholds(profile);
        var kept = fragments
            .Where(ShouldKeep)
            .ToList();
        var profileFiltered = profile is SubtitleTimingProfile.Lyrics or SubtitleTimingProfile.JapaneseLyrics
            ? SuppressJapaneseLyricBoilerplateHallucinationFragments(kept)
            : kept;
        var exactLoopSuppressed = SuppressRepeatedJapaneseLoopFragments(profileFiltered);
        var approximateLoopSuppressed = profile == SubtitleTimingProfile.JapaneseLyrics
            ? SuppressJapaneseLyricLoopFragments(exactLoopSuppressed)
            : exactLoopSuppressed;
        var loopSuppressed = SplitLeadingJapaneseTailFragments(approximateLoopSuppressed);
        var ordered = loopSuppressed
            .OrderBy(fragment => fragment.StartSeconds)
            .ThenBy(fragment => fragment.EndSeconds)
            .ToList();
        if (ordered.Count == 0) return [];

        var groups = new List<List<SubtitleCueSourceFragment>>();
        var current = new List<SubtitleCueSourceFragment>();

        void FlushCurrent()
        {
            if (current.Count == 0) return;
            groups.Add(current.ToList());
            current.Clear();
        }

        foreach (var fragment in ordered)
        {
            if (current.Count > 0)
            {
                var previous = current[^1];
                var candidate = current.Append(fragment).ToList();
                var gap = fragment.StartSeconds - previous.EndSeconds;
                if (ShouldBreak(fragment, current, candidate, gap, thresholds))
                {
                    FlushCurrent();
                }
            }

            current.Add(fragment);
            if (EndsSentence(fragment.Text))
            {
                FlushCurrent();
            }
        }
        FlushCurrent();
        groups = MergeShortGroups(groups, thresholds, profile);
        if (profile == SubtitleTimingProfile.JapaneseLyrics)
        {
            groups = RebalanceJapaneseLyricPhraseStarts(groups, thresholds);
            groups = RebalanceJapaneseLyricSingleFragmentBoundaries(groups, thresholds);
        }
        groups = MergeFlashDurationGroups(groups, thresholds);

        var cues = new List<SubtitleCue>();
        for (var groupIndex = 0; groupIndex < groups.Count; groupIndex++)
        {
            if (MakeCue(cues.Count + 1, groups[groupIndex], transcriptDurationSeconds, thresholds) is { } cue)
            {
                cues.Add(cue);
            }
        }
        if (profile == SubtitleTimingProfile.JapaneseLyrics)
        {
            cues = SuppressJapaneseLyricIntroHallucinationCues(cues);
            cues = MergeJapaneseLyricLeadingOrphanCues(cues, thresholds);
            cues = SuppressJapaneseLyricLoopCues(cues);
            cues = SuppressJapaneseLyricInternalDuplicateCueNoise(cues);
            cues = RebalanceJapaneseLyricCueTextBoundaries(cues);
        }
        if (profile is SubtitleTimingProfile.Lyrics or SubtitleTimingProfile.JapaneseLyrics)
        {
            cues = SuppressLyricIntroCreditNameCues(cues);
            cues = SuppressLyricRepeatedIntroFillerLoopCues(cues);
            cues = SuppressLyricFillerLoopCues(cues);
        }

        return cues
            .Select((cue, offset) => new SubtitleCue(
                offset + 1,
                cue.Start,
                cue.End,
                cue.Text,
                cue.SourceFragments))
            .ToList();
    }

    private readonly record struct JapaneseLoopMatch(string Signature, int PhraseLength, int RepeatCount);

    private sealed class JapaneseLoopFuse(int phraseLength, HashSet<char> characters, double suppressUntilSeconds)
    {
        public int PhraseLength { get; } = phraseLength;
        public HashSet<char> Characters { get; } = characters;
        public double SuppressUntilSeconds { get; set; } = suppressUntilSeconds;
    }

    private sealed class JapaneseLyricLoopCueFuse(HashSet<char> characters, double suppressUntilSeconds)
    {
        public HashSet<char> Characters { get; } = characters;
        public double SuppressUntilSeconds { get; set; } = suppressUntilSeconds;
    }

    private const double JapaneseLyricIntroHallucinationMaxEndSeconds = 5.0;
    private const double JapaneseLyricIntroHallucinationMinNextStartSeconds = 8.0;
    private const double JapaneseLyricIntroHallucinationMinGapSeconds = 6.0;
    private const int JapaneseLyricIntroHallucinationMaxVisibleChars = 5;
    private const double JapaneseLyricLeadingOrphanMaxDurationSeconds = 1.2;
    private const double JapaneseLyricLeadingOrphanMaxGapSeconds = 1.25;
    private const double JapaneseLyricLeadingOrphanMaxMergedSeconds = 6.8;
    private const int JapaneseLyricDuplicateMinCharacters = 6;
    private const double JapaneseLyricDuplicateMinOverlap = 0.72;

    private static List<SubtitleCue> SuppressJapaneseLyricIntroHallucinationCues(IReadOnlyList<SubtitleCue> cues)
    {
        if (cues.Count < 2) return cues.ToList();
        var first = cues[0];
        var second = cues[1];
        if (first.SourceFragments.Count == 0 || second.SourceFragments.Count == 0) return cues.ToList();

        var firstStart = first.SourceFragments[0].StartSeconds;
        var firstEnd = first.SourceFragments[^1].EndSeconds;
        var secondStart = second.SourceFragments[0].StartSeconds;
        var gap = secondStart - firstEnd;
        var visible = SubtitleTimingPlanner.VisibleCharacters(first.Text);

        if (firstStart <= 1.0
            && firstEnd <= JapaneseLyricIntroHallucinationMaxEndSeconds
            && secondStart >= JapaneseLyricIntroHallucinationMinNextStartSeconds
            && gap >= JapaneseLyricIntroHallucinationMinGapSeconds
            && visible <= JapaneseLyricIntroHallucinationMaxVisibleChars
            && !EndsSentence(first.Text))
        {
            return cues.Skip(1).ToList();
        }
        return cues.ToList();
    }

    private static List<SubtitleCue> MergeJapaneseLyricLeadingOrphanCues(
        IReadOnlyList<SubtitleCue> cues,
        SubtitleTimingThresholds thresholds)
    {
        if (cues.Count < 2) return cues.ToList();
        var result = new List<SubtitleCue>(cues.Count);
        var index = 0;

        while (index < cues.Count)
        {
            var cue = cues[index];
            if (index + 1 >= cues.Count
                || !IsJapaneseLyricLeadingOrphanCue(cue)
                || cue.SourceFragments.Count == 0
                || cues[index + 1].SourceFragments.Count == 0)
            {
                result.Add(cue);
                index += 1;
                continue;
            }

            var cueStart = cue.SourceFragments[0].StartSeconds;
            var cueEnd = cue.SourceFragments[^1].EndSeconds;
            var nextStart = cues[index + 1].SourceFragments[0].StartSeconds;
            var gap = nextStart - cueEnd;
            var duration = cueEnd - cueStart;
            var mergedFragments = cue.SourceFragments.Concat(cues[index + 1].SourceFragments).ToList();

            if (duration <= JapaneseLyricLeadingOrphanMaxDurationSeconds
                && gap <= JapaneseLyricLeadingOrphanMaxGapSeconds
                && FitsJapaneseLyricLeadingOrphanMerge(mergedFragments)
                && MakeCue(result.Count + 1, mergedFragments, null, thresholds) is { } merged)
            {
                result.Add(merged);
                index += 2;
                continue;
            }

            result.Add(cue);
            index += 1;
        }
        return result;
    }

    private static bool FitsJapaneseLyricLeadingOrphanMerge(IReadOnlyList<SubtitleCueSourceFragment> fragments)
    {
        if (fragments.Count == 0) return false;
        var text = JoinedText(fragments);
        var duration = fragments[^1].EndSeconds - fragments[0].StartSeconds;
        var units = SubtitleTimingPlanner.TimingTokens(text).Count;
        return duration <= JapaneseLyricLeadingOrphanMaxMergedSeconds
            && units <= RelaxedShortMergeMaxCjkUnits;
    }

    private static bool IsJapaneseLyricLeadingOrphanCue(SubtitleCue cue)
    {
        var text = cue.Text.Trim();
        return SubtitleTimingPlanner.VisibleCharacters(text) == 1
            && SubtitleTimingPlanner.ContainsCjkText(text)
            && !StartsWithLeadingProhibited(text)
            && !EndsSentence(text);
    }

    private static List<SubtitleCueSourceFragment> SuppressRepeatedJapaneseLoopFragments(
        IReadOnlyList<SubtitleCueSourceFragment> fragments)
    {
        if (fragments.Count < JapaneseLoopMinPhraseFragments * JapaneseLoopMinRepeatCount)
        {
            return fragments.ToList();
        }

        var output = new List<SubtitleCueSourceFragment>(fragments.Count);
        var fuses = new Dictionary<string, JapaneseLoopFuse>(StringComparer.Ordinal);
        var index = 0;

        while (index < fragments.Count)
        {
            if (FusedJapaneseLoopMatch(index, fragments, fuses) is { } fused)
            {
                var dropEnd = index + fused.RepeatCount * fused.PhraseLength;
                if (dropEnd > index && dropEnd <= fragments.Count && fuses.TryGetValue(fused.Signature, out var fuse))
                {
                    fuse.SuppressUntilSeconds = Math.Max(
                        fuse.SuppressUntilSeconds,
                        fragments[dropEnd - 1].EndSeconds + JapaneseLoopFuseSeconds);
                }
                index = dropEnd;
                continue;
            }

            if (RepeatedJapaneseLoopMatch(index, fragments) is { } match)
            {
                var keepEnd = index + JapaneseLoopAllowedRepeats * match.PhraseLength;
                output.AddRange(fragments.Skip(index).Take(keepEnd - index));

                var dropEnd = index + match.RepeatCount * match.PhraseLength;
                if (dropEnd > index && dropEnd <= fragments.Count)
                {
                    fuses[match.Signature] = new JapaneseLoopFuse(
                        match.PhraseLength,
                        new HashSet<char>(match.Signature),
                        fragments[dropEnd - 1].EndSeconds + JapaneseLoopFuseSeconds);
                }
                index = dropEnd;
                continue;
            }

            output.Add(fragments[index]);
            index += 1;
        }

        return output;
    }

    private static List<SubtitleCue> SuppressJapaneseLyricLoopCues(IReadOnlyList<SubtitleCue> cues)
    {
        if (cues.Count < JapaneseLyricLoopCueMinCount) return cues.ToList();
        var output = new List<SubtitleCue>(cues.Count);
        var index = 0;
        var removedAny = false;

        while (index < cues.Count)
        {
            if (JapaneseLyricLoopCueRunEnd(index, cues) is { } end)
            {
                var run = cues.Skip(index).Take(end - index).ToList();
                var preserveCount = JapaneseLyricDenseLoopPreservePrefixCount(run);
                if (preserveCount > 0)
                {
                    output.AddRange(run.Take(preserveCount));
                }
                index = end;
                removedAny = true;
                continue;
            }
            output.Add(cues[index]);
            index += 1;
        }

        return removedAny && output.Count > 0 ? output : cues.ToList();
    }

    private readonly record struct LyricFillerCueStats(
        int TokenCount,
        int FillerTokenCount,
        bool HasOutroBoilerplate)
    {
        public double FillerRatio => TokenCount == 0 ? 0 : (double)FillerTokenCount / TokenCount;
    }

    private static List<SubtitleCue> SuppressLyricIntroCreditNameCues(IReadOnlyList<SubtitleCue> cues)
    {
        if (cues.Count < 2) return cues.ToList();
        return IsLyricIntroCreditNameCue(cues[0], cues[1])
            ? cues.Skip(1).ToList()
            : cues.ToList();
    }

    private static bool IsLyricIntroCreditNameCue(SubtitleCue cue, SubtitleCue next)
    {
        var start = CueStartSeconds(cue);
        var end = CueEndSeconds(cue);
        var nextStart = CueStartSeconds(next);
        var visible = SubtitleTimingPlanner.VisibleCharacters(cue.Text);
        return start <= LyricIntroCreditNameMaxStartSeconds
            && end <= LyricIntroCreditNameMaxEndSeconds
            && nextStart >= LyricIntroCreditNameMinNextStartSeconds
            && nextStart - end >= LyricIntroCreditNameMinGapSeconds
            && visible >= LyricIntroCreditNameMinVisibleChars
            && visible <= LyricIntroCreditNameMaxVisibleChars
            && IsHanOnlyLyricCueText(cue.Text)
            && !EndsSentence(cue.Text);
    }

    private static List<SubtitleCue> SuppressLyricRepeatedIntroFillerLoopCues(IReadOnlyList<SubtitleCue> cues)
    {
        if (cues.Count < LyricRepeatedIntroFillerMinCueCount) return cues.ToList();
        var output = new List<SubtitleCue>(cues.Count);
        var index = 0;
        var removedAny = false;
        var suppressedKeys = new HashSet<string>(StringComparer.Ordinal);

        while (index < cues.Count)
        {
            if (TrimLyricRepeatedIntroFillerPrefix(cues[index], suppressedKeys) is { } trimmed)
            {
                output.Add(trimmed);
                index += 1;
                removedAny = true;
                continue;
            }
            var key = LyricRepeatedIntroFillerKey(cues[index].Text);
            if (CueStartSeconds(cues[index]) > LyricRepeatedIntroFillerMaxStartSeconds || key is null)
            {
                output.Add(cues[index]);
                index += 1;
                continue;
            }

            var end = index + 1;
            while (end < cues.Count)
            {
                var gap = CueStartSeconds(cues[end]) - CueEndSeconds(cues[end - 1]);
                if (CueStartSeconds(cues[end]) > LyricRepeatedIntroFillerMaxStartSeconds
                    || gap > LyricRepeatedIntroFillerMaxGapSeconds
                    || !string.Equals(LyricRepeatedIntroFillerKey(cues[end].Text), key, StringComparison.Ordinal))
                {
                    break;
                }
                end += 1;
            }

            var count = end - index;
            var duration = CueEndSeconds(cues[end - 1]) - CueStartSeconds(cues[index]);
            if (count >= LyricRepeatedIntroFillerMinCueCount
                && duration >= LyricRepeatedIntroFillerMinDurationSeconds)
            {
                suppressedKeys.Add(key);
                index = end;
                removedAny = true;
            }
            else
            {
                output.AddRange(cues.Skip(index).Take(end - index));
                index = end;
            }
        }

        return removedAny ? output : cues.ToList();
    }

    private static SubtitleCue? TrimLyricRepeatedIntroFillerPrefix(
        SubtitleCue cue,
        IReadOnlySet<string> keys)
    {
        if (keys.Count == 0) return null;
        foreach (var key in keys)
        {
            var trimmedText = TrimLyricRepeatedIntroFillerPrefix(key, cue.Text);
            if (trimmedText is null) continue;
            return new SubtitleCue(cue.Index, cue.Start, cue.End, trimmedText, cue.SourceFragments);
        }
        return null;
    }

    private static string? TrimLyricRepeatedIntroFillerPrefix(string key, string text)
    {
        var index = 0;
        var matched = 0;
        var consumeEnd = 0;

        while (index < text.Length && matched < key.Length)
        {
            var ch = text[index];
            var letter = LowercaseAsciiLetter(ch);
            if (letter is { } value)
            {
                if (value != key[matched]) return null;
                matched += 1;
                consumeEnd = index + 1;
            }
            else if (IsLyricPrefixSeparator(ch))
            {
                consumeEnd = index + 1;
            }
            else
            {
                return null;
            }
            index += 1;
        }

        if (matched != key.Length) return null;
        while (consumeEnd < text.Length && IsLyricPrefixSeparator(text[consumeEnd]))
        {
            consumeEnd += 1;
        }
        var remainder = text[consumeEnd..].Trim();
        return SubtitleTimingPlanner.VisibleCharacters(remainder) >= LyricRepeatedIntroFillerMinKeyCharacters
            ? remainder
            : null;
    }

    private static char? LowercaseAsciiLetter(char ch)
    {
        if (ch is >= 'A' and <= 'Z') return char.ToLowerInvariant(ch);
        if (ch is >= 'a' and <= 'z') return ch;
        return null;
    }

    private static bool IsLyricPrefixSeparator(char ch) =>
        char.IsWhiteSpace(ch) || char.IsPunctuation(ch) || char.IsSymbol(ch);

    private static string? LyricRepeatedIntroFillerKey(string text)
    {
        if (SubtitleTimingPlanner.VisibleCharacters(text) > LyricRepeatedIntroFillerMaxVisibleChars
            || SubtitleTimingPlanner.ContainsCjkText(text))
        {
            return null;
        }
        var key = new StringBuilder();
        foreach (var ch in text)
        {
            if (ch is >= 'A' and <= 'Z')
            {
                key.Append(char.ToLowerInvariant(ch));
            }
            else if (ch is >= 'a' and <= 'z')
            {
                key.Append(ch);
            }
        }
        if (key.Length < LyricRepeatedIntroFillerMinKeyCharacters
            || key.Length > LyricRepeatedIntroFillerMaxRawKeyCharacters)
        {
            return null;
        }
        var rawKey = key.ToString();
        var motif = RepeatedLatinMotif(rawKey);
        if (motif is not null && motif.Length <= LyricRepeatedIntroFillerMaxKeyCharacters)
        {
            return motif;
        }
        return rawKey.Length <= LyricRepeatedIntroFillerMaxKeyCharacters ? rawKey : null;
    }

    private static string? RepeatedLatinMotif(string key)
    {
        if (key.Length < LyricRepeatedIntroFillerMinKeyCharacters * 2) return null;
        for (var length = LyricRepeatedIntroFillerMinKeyCharacters; length <= key.Length / 2; length++)
        {
            if (key.Length % length != 0) continue;
            var motif = key[..length];
            if (string.Concat(Enumerable.Repeat(motif, key.Length / length)) == key)
            {
                return motif;
            }
        }
        return null;
    }

    private static bool IsHanOnlyLyricCueText(string text)
    {
        var count = 0;
        foreach (var ch in text)
        {
            if (char.IsWhiteSpace(ch)) continue;
            if (!IsHanChar(ch)) return false;
            count += 1;
        }
        return count is >= LyricIntroCreditNameMinVisibleChars and <= LyricIntroCreditNameMaxVisibleChars;
    }

    private static bool IsHanChar(char ch) =>
        ch is >= '\u3400' and <= '\u4DBF'
        || ch is >= '\u4E00' and <= '\u9FFF'
        || ch is >= '\uF900' and <= '\uFAFF';

    private static List<SubtitleCue> SuppressLyricFillerLoopCues(IReadOnlyList<SubtitleCue> cues)
    {
        if (cues.Count < 2) return cues.ToList();
        var output = new List<SubtitleCue>(cues.Count);
        var index = 0;
        var removedAny = false;

        while (index < cues.Count)
        {
            if (LyricFillerCueStatsFor(cues[index].Text).HasOutroBoilerplate)
            {
                index += 1;
                removedAny = true;
                continue;
            }
            if (!IsLyricFillerLoopCue(cues[index]))
            {
                output.Add(cues[index]);
                index += 1;
                continue;
            }

            var end = index + 1;
            var fillerTokenCount = LyricFillerCueStatsFor(cues[index].Text).FillerTokenCount;
            while (end < cues.Count)
            {
                var gap = CueStartSeconds(cues[end]) - CueEndSeconds(cues[end - 1]);
                if (gap > LyricFillerLoopMaxGapSeconds || !IsLyricFillerLoopCue(cues[end])) break;
                fillerTokenCount += LyricFillerCueStatsFor(cues[end].Text).FillerTokenCount;
                end += 1;
            }

            var duration = CueEndSeconds(cues[end - 1]) - CueStartSeconds(cues[index]);
            var shouldDrop = duration >= LyricFillerLoopMinDurationSeconds
                    && fillerTokenCount >= LyricFillerLoopMinTokenCount
                || fillerTokenCount >= LyricFillerLoopHighTokenCount;

            if (shouldDrop)
            {
                index = end;
                removedAny = true;
            }
            else
            {
                output.AddRange(cues.Skip(index).Take(end - index));
                index = end;
            }
        }

        return removedAny ? output : cues.ToList();
    }

    private static bool IsLyricFillerLoopCue(SubtitleCue cue)
    {
        var stats = LyricFillerCueStatsFor(cue.Text);
        if (stats.HasOutroBoilerplate) return true;
        if (stats.TokenCount > 0 && stats.FillerRatio >= 1.0) return true;
        return stats.TokenCount >= LyricFillerCueMinTokenCount
            && stats.FillerRatio >= LyricFillerCueMinRatio;
    }

    private static LyricFillerCueStats LyricFillerCueStatsFor(string text)
    {
        var tokens = LyricLatinTokens(text);
        var fillerCount = tokens.Count(token => LyricFillerLoopTokens.Contains(token));
        return new LyricFillerCueStats(
            tokens.Count,
            fillerCount,
            ContainsLyricOutroBoilerplate(text));
    }

    private static List<string> LyricLatinTokens(string text)
    {
        var tokens = new List<string>();
        var current = new StringBuilder();
        foreach (var ch in text)
        {
            if (ch is >= 'A' and <= 'Z')
            {
                current.Append(char.ToLowerInvariant(ch));
            }
            else if (ch is >= 'a' and <= 'z')
            {
                current.Append(ch);
            }
            else if (current.Length > 0)
            {
                tokens.Add(current.ToString());
                current.Clear();
            }
        }
        if (current.Length > 0) tokens.Add(current.ToString());
        return tokens;
    }

    private static bool ContainsLyricOutroBoilerplate(string text)
    {
        var latinKey = new StringBuilder();
        foreach (var ch in text)
        {
            if (ch is >= 'A' and <= 'Z')
            {
                latinKey.Append(char.ToLowerInvariant(ch));
            }
            else if (ch is >= 'a' and <= 'z')
            {
                latinKey.Append(ch);
            }
        }
        var cjkKey = NormalizedJapaneseLoopText(text);
        return LyricOutroBoilerplateKeys.Any(key =>
            latinKey.ToString().Contains(key, StringComparison.Ordinal)
            || cjkKey.Contains(key, StringComparison.Ordinal));
    }

    private static List<SubtitleCue> SuppressJapaneseLyricInternalDuplicateCueNoise(IReadOnlyList<SubtitleCue> cues) =>
        cues.Select(cue =>
        {
            var cleaned = SuppressJapaneseLyricInternalDuplicateNoise(cue.Text);
            return string.Equals(cleaned, cue.Text, StringComparison.Ordinal)
                ? cue
                : new SubtitleCue(cue.Index, cue.Start, cue.End, cleaned, cue.SourceFragments);
        }).ToList();

    private static string SuppressJapaneseLyricInternalDuplicateNoise(string text)
    {
        var normalizedSeparators = text.Replace('，', '、').Replace(',', '、');
        var parts = normalizedSeparators.Split('、');
        if (parts.Length < 2) return text;

        var kept = new List<string>();
        var keptNormalized = new List<string>();
        var removedAny = false;
        foreach (var part in parts)
        {
            var normalized = NormalizedJapaneseLoopText(part);
            if (IsApproximateJapaneseLyricDuplicateSegment(normalized, keptNormalized))
            {
                removedAny = true;
                continue;
            }
            kept.Add(part);
            if (normalized.Length > 0) keptNormalized.Add(normalized);
        }
        var cleaned = string.Join("、", kept).Trim();
        return removedAny && cleaned.Length > 0 ? cleaned : text;
    }

    private static bool IsApproximateJapaneseLyricDuplicateSegment(string candidate, IReadOnlyList<string> previous)
    {
        if (candidate.Length < JapaneseLyricDuplicateMinCharacters) return false;
        foreach (var original in previous.TakeLast(3))
        {
            if (original.Length < JapaneseLyricDuplicateMinCharacters
                || string.Equals(original, candidate, StringComparison.Ordinal))
            {
                continue;
            }
            var smaller = Math.Min(original.Length, candidate.Length);
            var larger = Math.Max(original.Length, candidate.Length);
            if ((double)smaller / larger < 0.55) continue;
            if (JapaneseCharacterOverlapRatio(original, candidate) >= JapaneseLyricDuplicateMinOverlap)
            {
                return true;
            }
        }
        return false;
    }

    private static double JapaneseCharacterOverlapRatio(string lhs, string rhs)
    {
        var denominator = Math.Min(lhs.Length, rhs.Length);
        if (denominator <= 0) return 0;
        var counts = new Dictionary<char, int>();
        foreach (var ch in lhs)
        {
            counts[ch] = counts.GetValueOrDefault(ch) + 1;
        }
        var overlap = 0;
        foreach (var ch in rhs)
        {
            var count = counts.GetValueOrDefault(ch);
            if (count <= 0) continue;
            overlap += 1;
            counts[ch] = count - 1;
        }
        return (double)overlap / denominator;
    }

    private static List<SubtitleCueSourceFragment> SuppressJapaneseLyricLoopFragments(
        IReadOnlyList<SubtitleCueSourceFragment> fragments)
    {
        if (fragments.Count < JapaneseLyricLoopCueMinCount) return fragments.ToList();
        var output = new List<SubtitleCueSourceFragment>(fragments.Count);
        var fuses = new List<JapaneseLyricLoopCueFuse>();
        var index = 0;
        var removedAny = false;

        while (index < fragments.Count)
        {
            var normalized = NormalizedJapaneseLoopText(fragments[index].Text);
            var fuseIndex = fuses.FindIndex(fuse =>
                fragments[index].StartSeconds <= fuse.SuppressUntilSeconds
                && IsJapaneseLyricLoopFuseCompatible(normalized, fuse.Characters));
            if (fuseIndex >= 0)
            {
                fuses[fuseIndex].SuppressUntilSeconds = Math.Max(
                    fuses[fuseIndex].SuppressUntilSeconds,
                    fragments[index].EndSeconds + JapaneseLoopFuseSeconds);
                index += 1;
                removedAny = true;
                continue;
            }
            if (JapaneseLyricLoopFragmentRunEnd(index, fragments) is { } end)
            {
                var normalizedRun = string.Concat(fragments
                    .Skip(index)
                    .Take(end - index)
                    .Select(fragment => NormalizedJapaneseLoopText(fragment.Text)));
                fuses.Add(new JapaneseLyricLoopCueFuse(
                    new HashSet<char>(normalizedRun),
                    fragments[end - 1].EndSeconds + JapaneseLoopFuseSeconds));
                index = end;
                removedAny = true;
                continue;
            }
            output.Add(fragments[index]);
            index += 1;
        }

        return removedAny && output.Count > 0 ? output : fragments.ToList();
    }

    private static List<SubtitleCueSourceFragment> SuppressJapaneseLyricBoilerplateHallucinationFragments(
        IReadOnlyList<SubtitleCueSourceFragment> fragments)
    {
        if (fragments.Count == 0) return fragments.ToList();
        var output = new List<SubtitleCueSourceFragment>(fragments.Count);
        var index = 0;
        var removedAny = false;

        while (index < fragments.Count)
        {
            if (JapaneseLyricIntroMusicHallucinationClusterEnd(index, fragments) is { } musicEnd)
            {
                index = musicEnd;
                removedAny = true;
                continue;
            }
            if (JapaneseLyricOutroHallucinationClusterEnd(index, fragments) is { } outroEnd)
            {
                index = outroEnd;
                removedAny = true;
                continue;
            }
            if (JapaneseLyricCreditHallucinationClusterEnd(index, fragments) is { } creditEnd)
            {
                index = creditEnd;
                removedAny = true;
                continue;
            }
            output.Add(fragments[index]);
            index += 1;
        }

        return removedAny ? output : fragments.ToList();
    }

    private static int? JapaneseLyricIntroMusicHallucinationClusterEnd(
        int start,
        IReadOnlyList<SubtitleCueSourceFragment> fragments)
    {
        if (start != 0) return null;
        var normalized = new StringBuilder();
        var end = start;
        while (end < fragments.Count)
        {
            var fragment = fragments[end];
            if (fragment.StartSeconds > 20.5) break;
            var token = NormalizedLatinCueText(fragment.Text);
            if (token is not ("B" or "G" or "M" or "BG" or "GM" or "BGM")) break;
            normalized.Append(token);
            end += 1;
            if (normalized.ToString() == "BGM") return end;
        }
        return null;
    }

    private static string NormalizedLatinCueText(string text)
    {
        var builder = new StringBuilder();
        foreach (var ch in text)
        {
            if (ch is >= 'A' and <= 'Z')
            {
                builder.Append(ch);
            }
            else if (ch is >= 'a' and <= 'z')
            {
                builder.Append(char.ToUpperInvariant(ch));
            }
        }
        return builder.ToString();
    }

    private static int? JapaneseLyricOutroHallucinationClusterEnd(
        int start,
        IReadOnlyList<SubtitleCueSourceFragment> fragments)
    {
        var normalized = new StringBuilder();
        var maxEnd = Math.Min(fragments.Count, start + 4);
        var end = start;
        while (end < maxEnd)
        {
            normalized.Append(NormalizedJapaneseLoopText(fragments[end].Text));
            var text = normalized.ToString();
            if (!JapaneseLyricOutroHallucinationMarkers.Any(marker =>
                marker.StartsWith(text, StringComparison.Ordinal) || text.StartsWith(marker, StringComparison.Ordinal)))
            {
                return null;
            }
            if (JapaneseLyricOutroHallucinationMarkers.Any(marker => text.Contains(marker, StringComparison.Ordinal)))
            {
                return end + 1;
            }
            end += 1;
        }
        return null;
    }

    private static int? JapaneseLyricCreditHallucinationClusterEnd(
        int start,
        IReadOnlyList<SubtitleCueSourceFragment> fragments)
    {
        var normalized = new StringBuilder();
        var end = start;
        var sawCreditMarker = false;
        var trailingNameCharacterCount = 0;
        while (end < fragments.Count)
        {
            var token = NormalizedJapaneseLoopText(fragments[end].Text);
            if (sawCreditMarker
                && end > start
                && fragments[end].StartSeconds - fragments[end - 1].EndSeconds > JapaneseLyricCreditHallucinationMaxGapSeconds)
            {
                break;
            }
            if (token.Length == 0 && sawCreditMarker)
            {
                end += 1;
                continue;
            }
            if (IsJapaneseLyricCreditHallucinationToken(token))
            {
                normalized.Append(token);
                sawCreditMarker = true;
                trailingNameCharacterCount = 0;
                end += 1;
                continue;
            }
            if (sawCreditMarker
                && token.Length <= 2
                && trailingNameCharacterCount + token.Length <= 4)
            {
                normalized.Append(token);
                trailingNameCharacterCount += token.Length;
                end += 1;
                continue;
            }
            else
            {
                break;
            }
        }
        if (end <= start) return null;
        var text = normalized.ToString();
        var markerCount = JapaneseLyricCreditHallucinationMarkers.Count(marker =>
            text.Contains(marker, StringComparison.Ordinal));
        return markerCount > 0 && text.Length >= 2 ? end : null;
    }

    private static bool IsJapaneseLyricCreditHallucinationToken(string token)
    {
        if (token.Length == 0) return false;
        if (JapaneseLyricCreditHallucinationTokens.Contains(token)) return true;
        return token.Length <= 8
            && JapaneseLyricCreditHallucinationMarkers.Any(marker =>
                token.Contains(marker, StringComparison.Ordinal));
    }

    private static bool IsJapaneseLyricLoopFuseCompatible(string normalized, HashSet<char> characters) =>
        normalized.Length > 0 && normalized.All(characters.Contains);

    private static int? JapaneseLyricLoopFragmentRunEnd(
        int start,
        IReadOnlyList<SubtitleCueSourceFragment> fragments)
    {
        int? latestSuspiciousEnd = null;
        var end = start;
        while (end < fragments.Count)
        {
            if (end > start)
            {
                var gap = fragments[end].StartSeconds - fragments[end - 1].EndSeconds;
                if (gap > JapaneseLyricLoopCueMaxGapSeconds) break;
            }
            var span = fragments[end].EndSeconds - fragments[start].StartSeconds;
            if (span > JapaneseLyricLoopCueMaxSpanSeconds) break;

            var count = end - start + 1;
            if (count >= JapaneseLyricLoopCueMinCount
                && IsSuspiciousJapaneseLyricLoopFragmentRun(fragments.Skip(start).Take(count).ToList()))
            {
                latestSuspiciousEnd = end + 1;
            }
            end += 1;
        }
        return latestSuspiciousEnd;
    }

    private static bool IsSuspiciousJapaneseLyricLoopFragmentRun(
        IReadOnlyList<SubtitleCueSourceFragment> fragments)
    {
        var normalizedParts = fragments.Select(fragment => NormalizedJapaneseLoopText(fragment.Text)).ToList();
        var normalized = string.Concat(normalizedParts);
        if (normalized.Length < JapaneseLyricLoopCueMinNormalizedCharacters) return false;

        var uniqueRatio = (double)normalized.Distinct().Count() / normalized.Length;
        if (uniqueRatio > JapaneseLyricLoopCueMaxUniqueCharacterRatio) return false;
        if (RepeatedBigramExcess(normalized) < JapaneseLyricLoopCueMinRepeatedBigramExcess) return false;

        var longSparseFragmentCount = fragments.Count(fragment =>
        {
            var duration = fragment.EndSeconds - fragment.StartSeconds;
            return duration >= JapaneseLyricLoopCueLongSparseSeconds
                && SubtitleTimingPlanner.VisibleCharacters(fragment.Text) <= HardMaximumCjkUnits;
        });

        // Fragment-level words from whisper.cpp naturally contain particles like を / に / が.
        // Treating those as malformed line starts deletes legitimate repeated choruses. Dense
        // whole-phrase loops are handled after cue formation, where we can preserve readable lyric
        // lead-in lines instead of dropping an entire chorus island too early.
        return longSparseFragmentCount > 0;
    }

    private static int? JapaneseLyricLoopCueRunEnd(int start, IReadOnlyList<SubtitleCue> cues)
    {
        int? latestSuspiciousEnd = null;
        var end = start;
        while (end < cues.Count)
        {
            if (end > start)
            {
                var gap = CueStartSeconds(cues[end]) - CueEndSeconds(cues[end - 1]);
                if (gap > JapaneseLyricLoopCueMaxGapSeconds) break;
            }
            var span = CueEndSeconds(cues[end]) - CueStartSeconds(cues[start]);
            if (span > JapaneseLyricLoopCueMaxSpanSeconds) break;

            var count = end - start + 1;
            if (count >= JapaneseLyricLoopCueMinCount
                && IsSuspiciousJapaneseLyricLoopCueRun(cues.Skip(start).Take(count).ToList()))
            {
                latestSuspiciousEnd = end + 1;
            }
            end += 1;
        }
        return latestSuspiciousEnd;
    }

    private static bool IsSuspiciousJapaneseLyricLoopCueRun(IReadOnlyList<SubtitleCue> cues)
    {
        var normalizedParts = cues.Select(cue => NormalizedJapaneseLoopText(cue.Text)).ToList();
        var normalized = string.Concat(normalizedParts);
        if (normalized.Length < JapaneseLyricLoopCueMinNormalizedCharacters) return false;

        var uniqueRatio = (double)normalized.Distinct().Count() / normalized.Length;
        if (uniqueRatio > JapaneseLyricLoopCueMaxUniqueCharacterRatio) return false;
        if (RepeatedBigramExcess(normalized) < JapaneseLyricLoopCueMinRepeatedBigramExcess) return false;

        var longSparseCueCount = cues.Count(cue =>
        {
            var duration = CueEndSeconds(cue) - CueStartSeconds(cue);
            return duration >= JapaneseLyricLoopCueLongSparseSeconds
                && SubtitleTimingPlanner.VisibleCharacters(cue.Text) <= HardMaximumCjkUnits;
        });

        // Legitimate choruses can repeat short, particle-heavy phrases many times. Treat approximate
        // repetition as hallucination only when a short text is stretched across an implausibly long
        // span or a longer phrase densely repeats far beyond normal chorus cadence.
        return longSparseCueCount > 0 || HasDominantRepeatedJapaneseLyricSubstring(normalized);
    }

    private static bool HasDominantRepeatedJapaneseLyricSubstring(string text)
        => DominantRepeatedJapaneseLyricSubstring(text) is not null;

    private static string? DominantRepeatedJapaneseLyricSubstring(string text)
    {
        if (text.Length < JapaneseLyricDenseLoopMinCharacters) return null;
        var maxLength = Math.Min(JapaneseLyricDenseLoopMaxSubstringCharacters, text.Length / 2);
        if (maxLength < JapaneseLyricDenseLoopMinSubstringCharacters) return null;

        for (var length = maxLength; length >= JapaneseLyricDenseLoopMinSubstringCharacters; length--)
        {
            var counts = new Dictionary<string, int>(StringComparer.Ordinal);
            for (var index = 0; index <= text.Length - length; index++)
            {
                var substring = text.Substring(index, length);
                if (substring.Distinct().Count() < 3) continue;
                counts[substring] = counts.GetValueOrDefault(substring) + 1;
            }
            if (counts.Count == 0) continue;
            var match = counts.MaxBy(pair => pair.Value);
            if (match.Value >= JapaneseLyricDenseLoopMinOccurrences
                && (double)(length * match.Value) / text.Length >= JapaneseLyricDenseLoopMinCoverage)
            {
                return match.Key;
            }
        }
        return null;
    }

    private static int JapaneseLyricDenseLoopPreservePrefixCount(IReadOnlyList<SubtitleCue> cues)
    {
        var normalized = string.Concat(cues.Select(cue => NormalizedJapaneseLoopText(cue.Text)));
        var motif = DominantRepeatedJapaneseLyricSubstring(normalized);
        if (motif is null) return 0;
        var motifPrefix = motif[..Math.Min(8, motif.Length)];
        if (motifPrefix.Length < JapaneseLyricDenseLoopMinSubstringCharacters) return 0;
        for (var offset = 0; offset < cues.Count; offset++)
        {
            if (NormalizedJapaneseLoopText(cues[offset].Text).Contains(motifPrefix, StringComparison.Ordinal))
            {
                return offset;
            }
        }
        return 0;
    }

    private static int RepeatedBigramExcess(string text)
    {
        if (text.Length < 2) return 0;
        var counts = new Dictionary<string, int>(StringComparer.Ordinal);
        for (var index = 0; index < text.Length - 1; index++)
        {
            var bigram = text.Substring(index, 2);
            counts[bigram] = counts.GetValueOrDefault(bigram) + 1;
        }
        return counts.Values.Sum(count => Math.Max(0, count - 1));
    }

    private static double CueStartSeconds(SubtitleCue cue) =>
        cue.SourceFragments.FirstOrDefault()?.StartSeconds ?? 0;

    private static double CueEndSeconds(SubtitleCue cue) =>
        cue.SourceFragments.LastOrDefault()?.EndSeconds ?? CueStartSeconds(cue);

    private static JapaneseLoopMatch? RepeatedJapaneseLoopMatch(
        int index,
        IReadOnlyList<SubtitleCueSourceFragment> fragments)
    {
        for (var phraseLength = Math.Min(JapaneseLoopMaxPhraseFragments, fragments.Count - index);
             phraseLength >= JapaneseLoopMinPhraseFragments;
             phraseLength--)
        {
            var signature = JapaneseLoopSignature(index, phraseLength, fragments);
            if (signature is null) continue;
            var repeatCount = ConsecutiveJapaneseLoopCount(signature, phraseLength, index, fragments);
            if (repeatCount >= JapaneseLoopMinRepeatCount)
            {
                return new JapaneseLoopMatch(signature, phraseLength, repeatCount);
            }
        }
        return null;
    }

    private static JapaneseLoopMatch? FusedJapaneseLoopMatch(
        int index,
        IReadOnlyList<SubtitleCueSourceFragment> fragments,
        IReadOnlyDictionary<string, JapaneseLoopFuse> fuses)
    {
        foreach (var (signature, fuse) in fuses)
        {
            if (fragments[index].StartSeconds > fuse.SuppressUntilSeconds) continue;
            if (IsJapaneseLoopCompatibleNoise(fragments[index].Text, fuse.Characters))
            {
                var compatibleCount = ConsecutiveJapaneseLoopCompatibleNoiseCount(fuse.Characters, index, fragments);
                return new JapaneseLoopMatch(signature, 1, compatibleCount);
            }
            if (!string.Equals(
                    JapaneseLoopSignature(index, fuse.PhraseLength, fragments),
                    signature,
                    StringComparison.Ordinal))
            {
                continue;
            }
            var exactRepeatCount = Math.Max(
                1,
                ConsecutiveJapaneseLoopCount(signature, fuse.PhraseLength, index, fragments));
            return new JapaneseLoopMatch(signature, fuse.PhraseLength, exactRepeatCount);
        }
        return null;
    }

    private static int ConsecutiveJapaneseLoopCompatibleNoiseCount(
        HashSet<char> characters,
        int index,
        IReadOnlyList<SubtitleCueSourceFragment> fragments)
    {
        var count = 0;
        while (index + count < fragments.Count
            && IsJapaneseLoopCompatibleNoise(fragments[index + count].Text, characters))
        {
            count += 1;
        }
        return Math.Max(1, count);
    }

    private static int ConsecutiveJapaneseLoopCount(
        string signature,
        int phraseLength,
        int index,
        IReadOnlyList<SubtitleCueSourceFragment> fragments)
    {
        var count = 0;
        double? previousStart = null;
        while (index + (count + 1) * phraseLength <= fragments.Count)
        {
            var phraseIndex = index + count * phraseLength;
            if (!string.Equals(
                    JapaneseLoopSignature(phraseIndex, phraseLength, fragments),
                    signature,
                    StringComparison.Ordinal))
            {
                break;
            }
            var start = fragments[phraseIndex].StartSeconds;
            if (previousStart is { } previous
                && start - previous > JapaneseLoopMaxOccurrenceGapSeconds)
            {
                break;
            }
            previousStart = start;
            count += 1;
        }
        return count;
    }

    private static string? JapaneseLoopSignature(
        int index,
        int length,
        IReadOnlyList<SubtitleCueSourceFragment> fragments)
    {
        if (length < JapaneseLoopMinPhraseFragments || index + length > fragments.Count)
        {
            return null;
        }
        var span = fragments[index + length - 1].EndSeconds - fragments[index].StartSeconds;
        if (span > JapaneseLoopMaxPhraseSpanSeconds) return null;

        var builder = new StringBuilder();
        for (var i = index; i < index + length; i++)
        {
            builder.Append(NormalizedJapaneseLoopText(fragments[i].Text));
        }
        var signature = builder.ToString();
        return signature.Length >= JapaneseLoopMinPhraseFragments
            && signature.Length <= 16
            && IsJapaneseLoopSignatureText(signature)
            && signature.Distinct().Count() > 1
            ? signature
            : null;
    }

    private static string NormalizedJapaneseLoopText(string text)
    {
        var builder = new StringBuilder();
        foreach (var ch in text)
        {
            if (IsJapaneseLoopSignatureChar(ch))
            {
                builder.Append(ch);
            }
        }
        return builder.ToString();
    }

    private static bool IsJapaneseLoopCompatibleNoise(string text, HashSet<char> characters)
    {
        var normalized = NormalizedJapaneseLoopText(text);
        return normalized.Length > 0
            && IsJapaneseLoopSignatureText(normalized)
            && normalized.All(characters.Contains);
    }

    private static bool IsJapaneseLoopSignatureText(string text) =>
        text.All(IsJapaneseLoopSignatureChar);

    private static bool IsJapaneseLoopSignatureChar(char ch) =>
        ch is >= '\u3040' and <= '\u309F'
        || ch is >= '\u30A0' and <= '\u30FF'
        || ch is >= '\u4E00' and <= '\u9FFF';

    // Merge lone, too-short groups into the temporally-closest neighbour (avoids jarring 1-char
    // cues like 「顔」 separated from 「洗って」). Mirrors the Swift MergeShortGroups.
    private static List<List<SubtitleCueSourceFragment>> MergeShortGroups(
        List<List<SubtitleCueSourceFragment>> groups,
        SubtitleTimingThresholds thresholds,
        SubtitleTimingProfile profile)
    {
        if (groups.Count <= 1) return groups;
        var result = new List<List<SubtitleCueSourceFragment>>();
        var index = 0;
        while (index < groups.Count)
        {
            var group = groups[index];
            if (group.Count > 1
                && result.Count > 0
                && StartsWithLeadingProhibited(group[0].Text))
            {
                var leading = new List<SubtitleCueSourceFragment> { group[0] };
                var gapPrev = leading[0].StartSeconds - result[^1][^1].EndSeconds;
                if (gapPrev <= EffectiveLoneMergeMaxGap(thresholds, profile)
                    && FitsMergedCue([.. result[^1], .. leading], thresholds, leading))
                {
                    result[^1] = [.. result[^1], .. leading];
                    group = group.Skip(1).ToList();
                }
            }

            var text = JoinedText(group);
            var isShort = IsShortJapaneseOrphanGroup(group);
            if (isShort)
            {
                var gapPrev = result.Count > 0
                    ? group[0].StartSeconds - result[^1][^1].EndSeconds
                    : double.MaxValue;
                var nextGroup = index + 1 < groups.Count ? groups[index + 1] : null;
                var gapNext = nextGroup is not null
                    ? nextGroup[0].StartSeconds - group[^1].EndSeconds
                    : double.MaxValue;
                var canMergePrevious = gapPrev <= EffectiveLoneMergeMaxGap(thresholds, profile)
                    && result.Count > 0
                    && FitsMergedCue([.. result[^1], .. group], thresholds, group);
                var canMergeNext = gapNext <= EffectiveLoneMergeMaxGap(thresholds, profile)
                    && nextGroup is not null
                    && FitsMergedCue([.. group, .. nextGroup], thresholds, group);

                if (ShouldPreferNextMerge(text) && canMergeNext && nextGroup is not null)
                {
                    result.Add([.. group, .. nextGroup]);
                    index += 2;
                    continue;
                }
                if (ShouldPreferPreviousMerge(text) && canMergePrevious && result.Count > 0)
                {
                    result[^1] = [.. result[^1], .. group];
                    index += 1;
                    continue;
                }

                if (canMergePrevious && (!canMergeNext || gapPrev <= gapNext) && result.Count > 0)
                {
                    result[^1] = [.. result[^1], .. group];
                    index += 1;
                    continue;
                }
                if (canMergeNext && nextGroup is not null)
                {
                    result.Add([.. group, .. nextGroup]);
                    index += 2; // consumed current + next
                    continue;
                }
            }
            result.Add(group);
            index += 1;
        }
        return result;
    }

    private static bool FitsMergedCue(
        IReadOnlyList<SubtitleCueSourceFragment> fragments,
        SubtitleTimingThresholds thresholds,
        IReadOnlyList<SubtitleCueSourceFragment>? absorbingShortGroup = null)
    {
        if (fragments.Count == 0) return false;
        var text = JoinedText(fragments);
        var duration = fragments[^1].EndSeconds - fragments[0].StartSeconds;
        if (SubtitleTimingPlanner.ContainsCjkText(text))
        {
            var units = SubtitleTimingPlanner.TimingTokens(text).Count;
            if (duration <= thresholds.HardMaximumCjkCueSeconds && units <= HardMaximumCjkUnits)
            {
                return true;
            }
            if (absorbingShortGroup is null || !IsShortJapaneseOrphanGroup(absorbingShortGroup))
            {
                return false;
            }
            return duration <= thresholds.RelaxedCjkCueSeconds
                && units <= RelaxedShortMergeMaxCjkUnits;
        }
        return duration <= thresholds.MaximumLatinCueSeconds;
    }

    private static List<List<SubtitleCueSourceFragment>> MergeFlashDurationGroups(
        List<List<SubtitleCueSourceFragment>> groups,
        SubtitleTimingThresholds thresholds)
    {
        groups = groups.Where(group => group.Count > 0).ToList();
        if (groups.Count <= 1) return groups;
        var result = new List<List<SubtitleCueSourceFragment>>();
        var index = 0;
        while (index < groups.Count)
        {
            var group = groups[index];
            var span = group[^1].EndSeconds - group[0].StartSeconds;
            if (span >= FlashMinCueSeconds)
            {
                result.Add(group);
                index += 1;
                continue;
            }

            var previous = result.Count > 0 ? result[^1] : null;
            var gapPrev = previous is not null
                ? group[0].StartSeconds - previous[^1].EndSeconds
                : double.MaxValue;
            var next = index + 1 < groups.Count ? groups[index + 1] : null;
            var gapNext = next is not null
                ? next[0].StartSeconds - group[^1].EndSeconds
                : double.MaxValue;

            var canPrevious = previous is not null
                && gapPrev <= FlashMergeMaxGapSeconds
                && FitsMergedCue([.. previous, .. group], thresholds, group);
            var canNext = next is not null
                && gapNext <= FlashMergeMaxGapSeconds
                && FitsMergedCue([.. group, .. next], thresholds, group);

            if (canPrevious && (!canNext || gapPrev <= gapNext) && previous is not null)
            {
                result[^1] = [.. previous, .. group];
                index += 1;
            }
            else if (canNext && next is not null)
            {
                result.Add([.. group, .. next]);
                index += 2;
            }
            else
            {
                result.Add(group);
                index += 1;
            }
        }
        return result;
    }

    private static List<List<SubtitleCueSourceFragment>> RebalanceJapaneseLyricPhraseStarts(
        List<List<SubtitleCueSourceFragment>> groups,
        SubtitleTimingThresholds thresholds)
    {
        if (groups.Count < 2) return groups;
        var result = new List<List<SubtitleCueSourceFragment>>(groups.Count);
        foreach (var group in groups)
        {
            if (result.Count == 0)
            {
                result.Add(group);
                continue;
            }

            var previousCandidate = result[^1];
            var prefixCount = JapaneseLyricContinuationPrefixCount(group, previousCandidate);
            if (prefixCount is null || group.Count <= prefixCount.Value)
            {
                result.Add(group);
                continue;
            }

            var prefix = group.Take(prefixCount.Value).ToList();
            var remainder = group.Skip(prefixCount.Value).ToList();
            var previous = result[^1];
            result.RemoveAt(result.Count - 1);
            var directMerge = previous.Concat(prefix).ToList();

            if (FitsJapaneseLyricRebalancedCue(directMerge, thresholds))
            {
                result.Add(directMerge);
                result.Add(remainder);
                continue;
            }

            var split = SplitPreviousForJapaneseLyricContinuation(previous, prefix, thresholds);
            if (split is not null)
            {
                result.Add(split.Value.Head);
                result.Add(split.Value.Tail.Concat(prefix).ToList());
                result.Add(remainder);
                continue;
            }

            result.Add(previous);
            result.Add(group);
        }
        return result;
    }

    private static int? JapaneseLyricContinuationPrefixCount(
        IReadOnlyList<SubtitleCueSourceFragment> group,
        IReadOnlyList<SubtitleCueSourceFragment> previous)
    {
        var texts = group.Select(fragment => fragment.Text.Trim()).ToList();
        if (texts.Count < 2) return null;
        if (JapaneseLyricDetachedSuffixPrefixCount(texts, previous) is { } detachedSuffixCount)
        {
            return detachedSuffixCount;
        }
        if (JapaneseLyricBareTailFragments.Contains(texts[0]) && StartsJapaneseLyricPhrase(texts[1]))
        {
            return 1;
        }
        if (texts.Count >= 3
            && JapaneseLyricAdnominalHeads.Contains(texts[0])
            && texts[1] == "な"
            && StartsJapaneseLyricPhrase(texts[2]))
        {
            return 2;
        }
        return null;
    }

    private static int? JapaneseLyricDetachedSuffixPrefixCount(
        IReadOnlyList<string> texts,
        IReadOnlyList<SubtitleCueSourceFragment> previous)
    {
        var previousText = JoinedText(previous).Trim();
        if (previousText.Length == 0) return null;
        var previousLast = previousText[^1].ToString();
        if (texts[0] == "ば" && (previousLast == "せ" || previousLast == "れ" || previousLast == "け"))
        {
            return 1;
        }
        if (texts[0] == "く" && ContainsKanji(previousLast))
        {
            return texts.Count >= 2 && texts[1] == "へ" ? 2 : 1;
        }
        return null;
    }

    private static bool StartsJapaneseLyricPhrase(string text)
    {
        var trimmed = text.Trim();
        return JapaneseLyricPhraseStartPrefixes.Any(prefix => trimmed.StartsWith(prefix, StringComparison.Ordinal));
    }

    private static bool FitsJapaneseLyricRebalancedCue(
        IReadOnlyList<SubtitleCueSourceFragment> fragments,
        SubtitleTimingThresholds thresholds)
    {
        if (fragments.Count == 0) return false;
        var text = JoinedText(fragments);
        var duration = fragments[^1].EndSeconds - fragments[0].StartSeconds;
        var units = SubtitleTimingPlanner.TimingTokens(text).Count;
        return duration <= thresholds.RelaxedCjkCueSeconds && units <= RelaxedShortMergeMaxCjkUnits;
    }

    private readonly record struct JapaneseLyricContinuationSplit(
        List<SubtitleCueSourceFragment> Head,
        List<SubtitleCueSourceFragment> Tail);

    private static JapaneseLyricContinuationSplit? SplitPreviousForJapaneseLyricContinuation(
        IReadOnlyList<SubtitleCueSourceFragment> previous,
        IReadOnlyList<SubtitleCueSourceFragment> prefix,
        SubtitleTimingThresholds thresholds)
    {
        if (previous.Count < 2) return null;
        var maxSuffixCount = Math.Min(previous.Count - 1, 8);
        JapaneseLyricContinuationSplit? fallback = null;
        for (var suffixCount = 1; suffixCount <= maxSuffixCount; suffixCount++)
        {
            var head = previous.Take(previous.Count - suffixCount).ToList();
            var tail = previous.Skip(previous.Count - suffixCount).ToList();
            var rebalanced = tail.Concat(prefix).ToList();
            var text = JoinedText(rebalanced);
            if (head.Count == 0
                || StartsWithLeadingProhibited(text)
                || !FitsJapaneseLyricRebalancedCue(rebalanced, thresholds))
            {
                continue;
            }
            fallback ??= new JapaneseLyricContinuationSplit(head, tail);
            if (ContainsKanji(JoinedText(tail)))
            {
                return new JapaneseLyricContinuationSplit(head, tail);
            }
        }
        return fallback;
    }

    private static List<List<SubtitleCueSourceFragment>> RebalanceJapaneseLyricSingleFragmentBoundaries(
        IReadOnlyList<List<SubtitleCueSourceFragment>> groups,
        SubtitleTimingThresholds thresholds)
    {
        var result = groups.Where(group => group.Count > 0).Select(group => group.ToList()).ToList();
        if (result.Count < 2) return result;

        for (var index = 1; index < result.Count; index++)
        {
            if (result[index - 1].Count == 0 || result[index].Count == 0) continue;
            var first = result[index][0];
            if (!IsJapaneseLyricSingleKanjiSuffixFragment(first)
                || StartsWithLeadingProhibited(first.Text)
                || first.StartSeconds - result[index - 1][^1].EndSeconds > LoneMergeMaxGapSeconds)
            {
                continue;
            }
            var candidatePrevious = result[index - 1].Append(first).ToList();
            if (!FitsJapaneseLyricSingleFragmentRebalancedCue(candidatePrevious, thresholds)) continue;
            result[index - 1] = candidatePrevious;
            result[index] = result[index].Skip(1).ToList();
        }

        result = result.Where(group => group.Count > 0).ToList();
        if (result.Count < 2) return result;

        for (var pass = 0; pass < 3; pass++)
        {
            var changed = false;
            for (var index = 1; index < result.Count; index++)
            {
                if (result[index - 1].Count == 0 || result[index].Count == 0) continue;
                var moveCount = JapaneseLyricSemanticTailMoveCount(result[index - 1], result[index]);
                if (moveCount is null) continue;

                var previousWithoutMoved = result[index - 1]
                    .Take(result[index - 1].Count - moveCount.Value)
                    .ToList();
                var moved = result[index - 1]
                    .Skip(result[index - 1].Count - moveCount.Value)
                    .ToList();
                var candidateCurrent = moved.Concat(result[index]).ToList();
                if (!FitsJapaneseLyricSemanticTailRebalancedCue(candidateCurrent, thresholds))
                {
                    continue;
                }
                result[index - 1] = previousWithoutMoved;
                result[index] = candidateCurrent;
                changed = true;
            }
            if (changed)
            {
                result = result.Where(group => group.Count > 0).ToList();
            }
            if (!changed) break;
        }

        return result.Where(group => group.Count > 0).ToList();
    }

    private static int? JapaneseLyricSemanticTailMoveCount(
        IReadOnlyList<SubtitleCueSourceFragment> previous,
        IReadOnlyList<SubtitleCueSourceFragment> current)
    {
        if (previous.Count == 0 || current.Count == 0) return null;

        var previousLast = previous[^1];
        var currentFirst = current[0];
        var gap = currentFirst.StartSeconds - previousLast.EndSeconds;
        var currentText = currentFirst.Text.Trim();
        if (currentText.Length == 0) return null;

        if (StartsWithKanji(currentText)
            && gap <= JapaneseLyricModifierRejoinMaxGapSeconds)
        {
            var modifierTailCount = JapaneseLyricAdjectiveModifierTailMoveCount(previous);
            if (modifierTailCount is not null) return modifierTailCount;
        }

        if (StartsWithJapaneseLyricObjectParticle(currentText)
            && gap <= JapaneseLyricParticleRejoinMaxGapSeconds
            && IsMovableSingleCjkFragment(previousLast))
        {
            return 1;
        }

        var previousLastText = previousLast.Text.Trim();
        if (previousLastText == "あ"
            && currentText.StartsWith("なた", StringComparison.Ordinal)
            && gap <= JapaneseLyricSemanticRejoinMaxGapSeconds)
        {
            return 1;
        }

        if (IsJapaneseLyricQuotedSpeechStart(currentText)
            && gap <= JapaneseLyricSemanticRejoinMaxGapSeconds)
        {
            var quotedTailCount = JapaneseLyricQuotedTailMoveCount(previous);
            if (quotedTailCount is not null) return quotedTailCount;
        }

        if (IsJapaneseLyricFixedPhraseContinuationStart(currentText)
            && gap <= JapaneseLyricSemanticRejoinMaxGapSeconds)
        {
            var fixedTailCount = JapaneseLyricFixedPhraseTailMoveCount(previous);
            if (fixedTailCount is not null) return fixedTailCount;
        }

        if (currentText.StartsWith("する", StringComparison.Ordinal)
            && gap <= JapaneseLyricKanaVerbRejoinMaxGapSeconds)
        {
            var suruTailCount = JapaneseLyricSuruCompoundTailMoveCount(previous);
            if (suruTailCount is not null) return suruTailCount;
        }

        if (IsJapaneseLyricKanaVerbContinuationStart(currentText)
            && gap <= JapaneseLyricKanaVerbRejoinMaxGapSeconds)
        {
            var kanaVerbTailCount = JapaneseLyricKanaVerbTailMoveCount(previous);
            if (kanaVerbTailCount is not null) return kanaVerbTailCount;
        }

        if (IsJapaneseLyricAdjectivePredicateContinuationStart(currentText)
            && gap <= JapaneseLyricSemanticRejoinMaxGapSeconds)
        {
            var adjectiveTailCount = JapaneseLyricAdjectivePredicateTailMoveCount(previous);
            if (adjectiveTailCount is not null) return adjectiveTailCount;
        }

        if (!IsJapaneseLyricPredicateContinuationStart(currentText)
            || gap > JapaneseLyricSemanticRejoinMaxGapSeconds)
        {
            return null;
        }

        var maxSuffixCount = Math.Min(previous.Count - 1, 4);
        for (var suffixCount = 1; suffixCount <= maxSuffixCount; suffixCount++)
        {
            var suffix = previous.Skip(previous.Count - suffixCount).ToList();
            var text = JoinedText(suffix);
            if (ContainsKanji(text)
                && !StartsWithLeadingProhibited(text)
                && !EndsSentence(text))
            {
                return suffixCount;
            }
        }
        return null;
    }

    private static int? JapaneseLyricAdjectiveModifierTailMoveCount(IReadOnlyList<SubtitleCueSourceFragment> previous)
    {
        var maxSuffixCount = Math.Min(previous.Count, 3);
        if (maxSuffixCount < 1) return null;
        for (var suffixCount = 1; suffixCount <= maxSuffixCount; suffixCount++)
        {
            var text = JoinedText(previous.Skip(previous.Count - suffixCount).ToList());
            if (ContainsKanji(text)
                && text.EndsWith("い", StringComparison.Ordinal)
                && SubtitleTimingPlanner.VisibleCharacters(text) <= 4
                && !StartsWithLeadingProhibited(text))
            {
                return suffixCount;
            }
        }
        return null;
    }

    private static int? JapaneseLyricAdjectivePredicateTailMoveCount(IReadOnlyList<SubtitleCueSourceFragment> previous)
    {
        var maxSuffixCount = Math.Min(previous.Count, 4);
        if (maxSuffixCount < 2) return null;
        for (var suffixCount = 2; suffixCount <= maxSuffixCount; suffixCount++)
        {
            var suffix = previous.Skip(previous.Count - suffixCount).ToList();
            var text = JoinedText(suffix);
            string[] suffixes = ["く", "しく", "なく"];
            if (ContainsKanji(text)
                && suffixes.Any(text.EndsWith)
                && !StartsWithLeadingProhibited(text)
                && !EndsSentence(text))
            {
                return suffixCount;
            }
        }
        return null;
    }


    private static bool StartsWithKanji(string text)
    {
        var trimmed = text.Trim();
        return trimmed.Length > 0 && ContainsKanji(trimmed[0].ToString());
    }

    private static int? JapaneseLyricFixedPhraseTailMoveCount(IReadOnlyList<SubtitleCueSourceFragment> previous)
    {
        return previous[^1].Text.Trim() == "だけ" ? 1 : null;
    }

    private static bool IsJapaneseLyricFixedPhraseContinuationStart(string text)
    {
        var trimmed = text.Trim();
        return trimmed.StartsWith("じゃ", StringComparison.Ordinal)
            || trimmed.StartsWith("では", StringComparison.Ordinal);
    }

    private static int? JapaneseLyricSuruCompoundTailMoveCount(IReadOnlyList<SubtitleCueSourceFragment> previous)
    {
        if (previous.Count < 2) return null;
        var text = JoinedText(previous.Skip(previous.Count - 2).ToList());
        return text.EndsWith("こ", StringComparison.Ordinal) && ContainsKanji(text) ? 2 : null;
    }

    private static int? JapaneseLyricKanaVerbTailMoveCount(IReadOnlyList<SubtitleCueSourceFragment> previous)
    {
        var maxSuffixCount = Math.Min(previous.Count, 4);
        if (maxSuffixCount < 1) return null;
        for (var suffixCount = 1; suffixCount <= maxSuffixCount; suffixCount++)
        {
            var text = JoinedText(previous.Skip(previous.Count - suffixCount).ToList());
            if (JapaneseLyricKanaVerbStemTails.Contains(text))
            {
                return suffixCount;
            }
        }
        return null;
    }

    private static bool IsJapaneseLyricKanaVerbContinuationStart(string text)
    {
        var trimmed = text.Trim();
        string[] starts = ["いて", "いた", "いる", "する", "ける"];
        return starts.Any(start => trimmed.StartsWith(start, StringComparison.Ordinal));
    }

    private static bool IsJapaneseLyricAdjectivePredicateContinuationStart(string text)
    {
        var trimmed = text.Trim();
        string[] starts = ["なる", "なった", "ない"];
        return starts.Any(start => trimmed.StartsWith(start, StringComparison.Ordinal));
    }

    private static int? JapaneseLyricQuotedTailMoveCount(IReadOnlyList<SubtitleCueSourceFragment> previous)
    {
        var maxSuffixCount = Math.Min(previous.Count, 6);
        if (maxSuffixCount < 2) return null;
        for (var suffixCount = 2; suffixCount <= maxSuffixCount; suffixCount++)
        {
            var suffix = previous.Skip(previous.Count - suffixCount).ToList();
            var text = JoinedText(suffix);
            if (ContainsKanji(text)
                && text.EndsWith("と", StringComparison.Ordinal)
                && !StartsWithLeadingProhibited(text)
                && !EndsSentence(text))
            {
                return suffixCount;
            }
        }
        return null;
    }

    private static bool IsJapaneseLyricQuotedSpeechStart(string text)
    {
        var trimmed = text.Trim();
        return trimmed.StartsWith("言", StringComparison.Ordinal)
            || trimmed.StartsWith("いう", StringComparison.Ordinal)
            || trimmed.StartsWith("言う", StringComparison.Ordinal);
    }

    private static bool IsJapaneseLyricPredicateContinuationStart(string text)
    {
        var trimmed = text.Trim();
        string[] starts = ["だ", "で", "と", "って", "ても", "て", "して", "した", "し"];
        return starts.Any(start => trimmed.StartsWith(start, StringComparison.Ordinal));
    }

    private static bool IsMovableSingleCjkFragment(SubtitleCueSourceFragment fragment)
    {
        var text = fragment.Text.Trim();
        return text.Length > 0
            && SubtitleTimingPlanner.VisibleCharacters(text) == 1
            && SubtitleTimingPlanner.ContainsCjkText(text)
            && !CjkLeadingProhibited.Contains(text[0]);
    }

    private static bool IsJapaneseLyricSingleKanjiSuffixFragment(SubtitleCueSourceFragment fragment)
    {
        var text = fragment.Text.Trim();
        return text.Length > 0
            && SubtitleTimingPlanner.VisibleCharacters(text) == 1
            && ContainsKanji(text)
            && JapaneseLyricSingleKanjiSuffixes.Contains(text[0]);
    }

    private static List<SubtitleCue> RebalanceJapaneseLyricCueTextBoundaries(IReadOnlyList<SubtitleCue> cues)
    {
        if (cues.Count < 2) return cues.ToList();
        var result = cues.ToList();
        for (var index = 1; index < result.Count; index++)
        {
            var previous = result[index - 1];
            var current = result[index];
            var previousEnd = SrtTools.SrtTimeToSeconds(previous.End);
            var currentStart = SrtTools.SrtTimeToSeconds(current.Start);
            if (previousEnd is null || currentStart is null || currentStart.Value - previousEnd.Value > LoneMergeMaxGapSeconds)
            {
                continue;
            }
            var previousText = previous.Text.Trim();
            var currentText = current.Text;
            if (previousText.Length == 0 || currentText.Length == 0 || !ContainsKanji(previousText[^1].ToString()))
            {
                continue;
            }
            var first = currentText[0];
            if (!IsJapaneseLyricSingleKanjiSuffixCharacter(first) || currentText[1..].Trim().Length == 0)
            {
                continue;
            }
            result[index - 1] = new SubtitleCue(
                previous.Index,
                previous.Start,
                previous.End,
                previous.Text + first,
                previous.SourceFragments);
            result[index] = new SubtitleCue(
                current.Index,
                current.Start,
                current.End,
                currentText[1..],
                current.SourceFragments);
        }
        return result;
    }

    private static bool IsMovableSingleCjkCharacter(char character) =>
        SubtitleTimingPlanner.ContainsCjkText(character.ToString()) && !CjkLeadingProhibited.Contains(character);

    private static bool IsJapaneseLyricSingleKanjiSuffixCharacter(char character) =>
        JapaneseLyricSingleKanjiSuffixes.Contains(character);

    private static bool StartsWithJapaneseLyricObjectParticle(string text)
    {
        var trimmed = text.Trim();
        return trimmed.Length > 0 && JapaneseLyricObjectParticleStarts.Contains(trimmed[0]);
    }

    private static bool FitsJapaneseLyricSingleFragmentRebalancedCue(
        IReadOnlyList<SubtitleCueSourceFragment> fragments,
        SubtitleTimingThresholds thresholds)
    {
        if (fragments.Count == 0) return false;
        var duration = fragments[^1].EndSeconds - fragments[0].StartSeconds;
        var units = SubtitleTimingPlanner.TimingTokens(JoinedText(fragments)).Count;
        return duration <= Math.Min(thresholds.RelaxedCjkCueSeconds + 1.0, 6.8)
            && units <= RelaxedShortMergeMaxCjkUnits;
    }

    private static bool FitsJapaneseLyricSemanticTailRebalancedCue(
        IReadOnlyList<SubtitleCueSourceFragment> fragments,
        SubtitleTimingThresholds thresholds)
    {
        if (fragments.Count == 0) return false;
        var duration = fragments[^1].EndSeconds - fragments[0].StartSeconds;
        var units = SubtitleTimingPlanner.TimingTokens(JoinedText(fragments)).Count;
        return duration <= Math.Min(thresholds.RelaxedCjkCueSeconds + 2.0, 7.8)
            && units <= RelaxedShortMergeMaxCjkUnits;
    }

    internal static double MaximumCueSecondsFor(string text) =>
        MaximumCueSecondsFor(text, Thresholds(SubtitleTimingProfile.Speech));

    internal static double MaximumCueSecondsFor(string text, SubtitleTimingThresholds thresholds)
    {
        if (IsShortStandaloneCjkCueText(text))
        {
            // Lyrics/anime profiles cap a lone residual char tighter so a stray 「っ」/「ー」/「顔」
            // cannot linger; Speech keeps the 2.4s standalone cap (residual cap is double.MaxValue).
            return Math.Min(ShortStandaloneCjkCueSeconds, thresholds.ResidualMaxStandaloneSeconds);
        }
        return SubtitleTimingPlanner.ContainsCjkText(text) ? thresholds.HardMaximumCjkCueSeconds : thresholds.MaximumLatinCueSeconds;
    }

    internal static double MaximumCueSecondsFor(string text, double start, double lastTokenEnd) =>
        MaximumCueSecondsFor(text, start, lastTokenEnd, Thresholds(SubtitleTimingProfile.Speech));

    internal static double MaximumCueSecondsFor(string text, double start, double lastTokenEnd, SubtitleTimingThresholds thresholds)
    {
        var cap = MaximumCueSecondsFor(text, thresholds);
        // A short standalone residual keeps its tightened cap when the profile constrains residuals
        // (Lyrics/Anime). Speech leaves residuals unconstrained, so its long-run bump below is
        // unchanged — zero behaviour change for the default path.
        if (IsShortStandaloneCjkCueText(text) && thresholds.ResidualMaxStandaloneSeconds < double.MaxValue)
        {
            return cap;
        }
        if (SubtitleTimingPlanner.ContainsCjkText(text) && lastTokenEnd > start + cap)
        {
            cap = Math.Max(cap, Math.Min(lastTokenEnd - start, thresholds.RelaxedCjkCueSeconds));
        }
        return cap;
    }

    private static bool IsShortJapaneseOrphanGroup(IReadOnlyList<SubtitleCueSourceFragment> group)
    {
        var text = JoinedText(group);
        return SubtitleTimingPlanner.ContainsCjkText(text)
            && SubtitleTimingPlanner.VisibleCharacters(text) <= LoneMergeMaxVisibleChars
            && !EndsSentence(text);
    }

    private static bool IsShortStandaloneCjkCueText(string text) =>
        SubtitleTimingPlanner.ContainsCjkText(text)
        && SubtitleTimingPlanner.VisibleCharacters(text) <= 2
        && !EndsSentence(text);

    private static bool ShouldPreferNextMerge(string text) => ContainsKanji(text);

    private static bool ShouldPreferPreviousMerge(string text)
    {
        var trimmed = text.Trim();
        return trimmed.Length > 0
            && (CjkLeadingProhibited.Contains(trimmed[0]) || !ContainsKanji(trimmed));
    }

    private static bool StartsWithLeadingProhibited(string text)
    {
        var trimmed = text.Trim();
        if (trimmed.Length == 0) return false;
        if (CjkLeadingProhibited.Contains(trimmed[0])) return true;
        // Korean: a bare josa/eomi (particle or verb ending) must never start a line — it belongs to
        // the preceding eojeol. Conservative: only when the whole leading fragment IS the particle.
        return KoreanLeadingProhibitedParticles.Contains(trimmed);
    }

    // Korean particles / verb endings (josa / eomi) that must not stand alone at the start of a
    // subtitle line. Mirrors Swift koreanLeadingProhibitedParticles.
    private static readonly HashSet<string> KoreanLeadingProhibitedParticles =
    [
        "은", "는", "이", "가", "을", "를", "에", "의", "도", "만", "와", "과", "로", "으로",
        "에서", "에게", "한테", "부터", "까지", "보다", "처럼", "마다", "조차", "밖에",
        "고", "서", "며", "지만", "는데", "니까", "어서", "아서",
    ];

    private static bool ContainsKanji(string text) =>
        text.Any(ch => ch is >= '\u4E00' and <= '\u9FFF');

    private static bool ShouldKeep(SubtitleCueSourceFragment fragment)
    {
        if (fragment.Text.Length == 0) return false;
        if (fragment.EndSeconds < fragment.StartSeconds) return false;
        // Drop no-speech fragments (a lone "?", "...", "♪" etc.) outright — they carry no readable
        // content and otherwise become standalone cues that linger to the cue cap.
        if (IsPurePunctuation(fragment.Text)) return false;
        if (IsDroppableJapaneseResidual(fragment.Text)) return false;
        return true;
    }

    private static List<SubtitleCueSourceFragment> SplitLeadingJapaneseTailFragments(
        IReadOnlyList<SubtitleCueSourceFragment> fragments)
    {
        var output = new List<SubtitleCueSourceFragment>(fragments.Count);
        foreach (var fragment in fragments)
        {
            var text = fragment.Text.Trim();
            if (!text.StartsWith("なそ", StringComparison.Ordinal) || text.Length < 3)
            {
                output.Add(fragment);
                continue;
            }
            var duration = fragment.EndSeconds - fragment.StartSeconds;
            if (duration < 0.2)
            {
                output.Add(fragment);
                continue;
            }
            var tailEnd = Math.Min(
                fragment.EndSeconds,
                fragment.StartSeconds + Math.Max(0.12, Math.Min(0.28, duration * 0.2)));
            var rest = text[1..];
            if (rest.Length == 0)
            {
                output.Add(fragment);
                continue;
            }
            output.Add(new SubtitleCueSourceFragment(fragment.StartSeconds, tailEnd, "な"));
            output.Add(new SubtitleCueSourceFragment(tailEnd, fragment.EndSeconds, rest));
        }
        return output;
    }

    private static bool ShouldBreak(
        SubtitleCueSourceFragment next,
        IReadOnlyList<SubtitleCueSourceFragment> current,
        IReadOnlyList<SubtitleCueSourceFragment> candidate,
        double gap,
        SubtitleTimingThresholds thresholds)
    {
        if (current.Count == 0) return false;
        var first = current[0];
        var last = current[^1];
        if (gap > thresholds.LargeSpeechGapSeconds) return true;

        var candidateText = JoinedText(candidate);
        var candidateDuration = next.EndSeconds - first.StartSeconds;
        if (SubtitleTimingPlanner.ContainsCjkText(candidateText))
        {
            var units = SubtitleTimingPlanner.TimingTokens(candidateText).Count;
            var latinContinuation = IsStrongLatinContinuationFragment(last.Text, next.Text);
            if (latinContinuation
                && candidateDuration <= thresholds.RelaxedCjkCueSeconds
                && units <= RelaxedShortMergeMaxCjkUnits)
            {
                return false;
            }
            // Hard ceilings always break.
            if (candidateDuration > thresholds.HardMaximumCjkCueSeconds) return true;
            if (units > HardMaximumCjkUnits) return true;
            // Soft ceilings break only at a natural boundary: never split mid-word (same-script run
            // / okurigana via CjkWordBoundary), and never right before a leading particle / small
            // kana / closing punctuation. Otherwise extend to the hard ceiling.
            if (candidateDuration > thresholds.MaximumCjkCueSeconds || units > MaximumCjkUnits)
            {
                // Breath-gap anchor (stable-ts): a real inter-word silence is the natural place to
                // break a long line, so break there rather than running to the hard ceiling. Never
                // break right before a leading particle / small kana / closing punctuation, even
                // after a pause. Only in this over-soft-ceiling zone.
                if (gap >= thresholds.BreathGapBreakSeconds && !StartsWithLeadingProhibited(next.Text))
                {
                    return true;
                }
                var junction = JoinedText(current).Length;
                var midWord = CjkWordBoundary.Straddles(candidateText, junction);
                return !(midWord || HasWeakBoundary(last.Text, next.Text));
            }
            return false;
        }

        if (candidateDuration > thresholds.MaximumLatinCueSeconds) return true;
        var latinBudgetText = string.Join(
            " ",
            candidate
                .Select(fragment => fragment.Text.Trim())
                .Where(text => text.Length > 0));
        if (SubtitleTimingPlanner.SpeechTokens(latinBudgetText).Count > MaximumLatinTokens)
        {
            // Over the token budget: a breath gap is a natural break even at a weak boundary;
            // otherwise keep the existing weak-boundary protection.
            if (gap >= thresholds.BreathGapBreakSeconds) return true;
            if (!HasWeakBoundary(last.Text, next.Text)) return true;
        }
        return false;
    }

    private static SubtitleCue? MakeCue(
        int index,
        IReadOnlyList<SubtitleCueSourceFragment> fragments,
        double? transcriptDurationSeconds,
        SubtitleTimingThresholds thresholds)
    {
        if (fragments.Count == 0) return null;
        var text = JoinedText(fragments);
        if (text.Length == 0) return null;

        var start = fragments[0].StartSeconds;
        var end = fragments[^1].EndSeconds + (EndsSentence(text) ? SentenceTailSeconds : PhraseTailSeconds);
        if (transcriptDurationSeconds is { } duration)
        {
            end = Math.Min(end, duration);
        }
        var maximumEnd = start + MaximumCueSecondsFor(text, start, fragments[^1].EndSeconds, thresholds);
        end = Math.Min(end, maximumEnd);
        end = Math.Max(end, start + MinimumCueSeconds);
        // Neighbor-aware timing (hold-to-next-onset, no-overlap) is applied by WhisperCueRetimer.
        // MakeCue intentionally does NOT clamp to the next group's start here: doing so before the
        // minimum-duration floor produced overlapping cues (BUG-1).
        return new SubtitleCue(
            index,
            SrtTools.SecondsToSrtTime(start),
            SrtTools.SecondsToSrtTime(end),
            text,
            fragments.ToList());
    }

    private static string JoinedText(IEnumerable<SubtitleCueSourceFragment> fragments)
    {
        var parts = fragments
            .Select(fragment => fragment.Text.Trim())
            .Where(part => part.Length > 0)
            .ToList();
        var builder = new StringBuilder();
        var previous = "";
        var allowBroadLatinContinuation = SubtitleTimingPlanner.ContainsCjkText(string.Concat(parts));
        for (var index = 0; index < parts.Count; index++)
        {
            var part = parts[index];
            var next = index + 1 < parts.Count ? parts[index + 1] : null;
            if (builder.Length > 0
                && !IsObservedLatinContinuation(builder.ToString(), part)
                && ShouldInsertSpace(previous, part, next, allowBroadLatinContinuation))
            {
                builder.Append(' ');
            }
            builder.Append(part);
            previous = part;
        }
        return builder.ToString().Trim();
    }

    private static bool ShouldInsertSpace(
        string left,
        string right,
        string? next,
        bool allowBroadLatinContinuation) =>
        right.Length > 0
        && !IsNoSpaceBefore(right[0])
        && (IsObservedStandaloneLatinFunction(left, right)
            || !IsLatinBridgeFragment(left, right, next)
            && !IsStrongLatinContinuationFragment(left, right)
            && !IsLatinContinuationFragment(left, right, allowBroadLatinContinuation)
            && (ContainsHangul(left) && ContainsHangul(right) && !KoreanLeadingProhibitedParticles.Contains(right.Trim())
                || ContainsSpacedScript(left) && ContainsSpacedScript(right)
                || ContainsAsciiAlphanumeric(left) || ContainsAsciiAlphanumeric(right)));

    private static bool IsObservedStandaloneLatinFunction(string left, string right)
    {
        var leftRun = TrailingLatinLetterRun(left).ToLowerInvariant();
        var rightRun = LeadingLatinLetterRun(right).ToLowerInvariant();
        return leftRun.Length > 0
            && rightRun.Length > 0
            && ObservedStandaloneLatinFunctionPrefixes.TryGetValue(rightRun, out var allowedPrefixes)
            && allowedPrefixes.Contains(leftRun);
    }

    private static bool ContainsHangul(string text) =>
        text.Any(ch => ch is >= '\uAC00' and <= '\uD7A3');

    // Space-separated non-CJK scripts (Devanagari/Bengali/Arabic/Cyrillic/\u2026) keep word spaces.
    private static bool ContainsSpacedScript(string text) =>
        text.Any(ch =>
            ch is >= '\u0900' and <= '\u097F'    // Devanagari
            || ch is >= '\u0980' and <= '\u09FF' // Bengali
            || ch is >= '\u0600' and <= '\u06FF' // Arabic
            || ch is >= '\u0750' and <= '\u077F' // Arabic Supplement
            || ch is >= '\u08A0' and <= '\u08FF' // Arabic Extended-A
            || ch is >= '\u0400' and <= '\u04FF' // Cyrillic
            || ch is >= '\u0500' and <= '\u052F'); // Cyrillic Supplement

    private static bool ContainsAsciiAlphanumeric(string text) =>
        text.Any(ch => ch <= 0x7F && char.IsLetterOrDigit(ch));

    private static bool IsNoSpaceBefore(char ch) =>
        ch is '\'' or '.' or ',' or '!' or '?' or ':' or ';'
            or '。' or '、' or '！' or '？' or '，' or '：' or '；'
            or '）' or ')' or '」' or '』' or '”' or '’';

    private static bool HasWeakBoundary(string left, string right)
    {
        // CJK: never break right before a leading particle / small kana / closing punctuation.
        var trimmedRight = right.Trim();
        if (trimmedRight.Length > 0 && CjkLeadingProhibited.Contains(trimmedRight[0]))
        {
            return true;
        }
        // Korean: never break right before a bare josa/eomi fragment.
        if (KoreanLeadingProhibitedParticles.Contains(trimmedRight))
        {
            return true;
        }
        if (IsStrongLatinContinuationFragment(left, right))
        {
            return true;
        }
        if (IsLatinContinuationFragment(left, right, allowBroadHeuristics: false))
        {
            return true;
        }
        var leftTokens = SubtitleTimingPlanner.WordTokens(left);
        var rightTokens = SubtitleTimingPlanner.WordTokens(right);
        return leftTokens.Count > 0
            && rightTokens.Count > 0
            && SubtitleTimingPlanner.IsWeakBoundary(leftTokens[^1], rightTokens[0]);
    }

    private static bool IsStrongLatinContinuationFragment(string left, string right)
    {
        if (HasApostropheInsideLatinRun(left)) return false;
        var leftRun = TrailingLatinLetterRun(left);
        var rightRun = LeadingLatinLetterRun(right);
        if (leftRun.Length == 0 || rightRun.Length == 0) return false;
        var leftLower = leftRun.ToLowerInvariant();
        var rightLower = rightRun.ToLowerInvariant();
        if (StrongLatinContinuationSuffixes.Contains(rightLower))
        {
            return !LatinContinuationFunctionWords.Contains(leftLower);
        }
        return leftRun.Length == 1
            && char.IsUpper(leftRun[0])
            && !LatinContinuationFunctionWords.Contains(leftLower)
            && StartsWithLowercaseLetter(rightRun);
    }

    private static bool IsLatinContinuationFragment(string left, string right, bool allowBroadHeuristics)
    {
        if (IsObservedLatinContinuation(left, right)) return true;
        if (HasApostropheInsideLatinRun(left)) return false;
        var leftRun = TrailingLatinLetterRun(left);
        var rightRun = LeadingLatinLetterRun(right);
        if (leftRun.Length == 0 || rightRun.Length == 0) return false;
        var leftLower = leftRun.ToLowerInvariant();
        var rightLower = rightRun.ToLowerInvariant();
        if (LatinBridgeFragments.Contains(leftLower) && LatinBridgeTailSuffixes.Contains(rightLower))
        {
            return true;
        }
        if (LatinContinuationFunctionWords.Contains(leftLower)) return false;
        if (LatinContinuationSuffixes.Contains(rightLower))
        {
            if (ShortLatinContinuationSuffixes.Contains(rightLower))
            {
                return leftRun.Length >= 2 && !LatinContinuationFunctionWords.Contains(leftLower);
            }
            return !LatinContinuationFunctionWords.Contains(leftLower);
        }
        if (rightLower == "i"
            && leftLower.EndsWith("ior", StringComparison.Ordinal)
            && !LatinContinuationFunctionWords.Contains(leftLower))
        {
            return true;
        }
        if (!allowBroadHeuristics) return false;
        if (leftRun.Length == 1
            && char.IsUpper(leftRun[0])
            && !LatinContinuationFunctionWords.Contains(leftLower)
            && StartsWithLowercaseLetter(rightRun))
        {
            return true;
        }
        if (leftRun.Length <= 3
            && StartsWithUppercaseLetter(leftRun)
            && rightRun.Length >= 3
            && !LatinContinuationFunctionWords.Contains(leftLower)
            && !LatinContinuationFunctionWords.Contains(rightLower)
            && StartsWithLowercaseLetter(rightRun))
        {
            return true;
        }
        if (leftRun.Length <= 2
            && rightRun.Length >= 3
            && !LatinContinuationFunctionWords.Contains(leftLower)
            && !LatinContinuationFunctionWords.Contains(rightLower)
            && StartsWithLowercaseLetter(rightRun))
        {
            return true;
        }
        return false;
    }

    private static bool IsObservedLatinContinuation(string left, string right)
    {
        var leftLower = left.Normalize(NormalizationForm.FormC).Trim().ToLowerInvariant();
        var rightLower = right.Normalize(NormalizationForm.FormC).Trim().ToLowerInvariant();
        if (rightLower == "rice")
        {
            return leftLower.EndsWith("créat", StringComparison.Ordinal)
                || leftLower.EndsWith("creat", StringComparison.Ordinal);
        }
        return ObservedLatinContinuationPrefixes.TryGetValue(rightLower, out var allowedPrefixes)
            && allowedPrefixes.Any(prefix => leftLower.EndsWith(prefix, StringComparison.Ordinal));
    }

    private static bool IsLatinBridgeFragment(string left, string right, string? next)
    {
        if (next is null) return false;
        if (HasApostropheInsideLatinRun(left)) return false;
        var leftRun = TrailingLatinLetterRun(left);
        var rightRun = LeadingLatinLetterRun(right);
        var nextRun = LeadingLatinLetterRun(next);
        if (leftRun.Length == 0 || rightRun.Length == 0 || nextRun.Length == 0) return false;
        var leftLower = leftRun.ToLowerInvariant();
        var rightLower = rightRun.ToLowerInvariant();
        var nextLower = nextRun.ToLowerInvariant();
        if (ObservedLatinBridgePrefixes.TryGetValue(rightLower, out var allowedPrefixes))
        {
            return allowedPrefixes.Any(prefix => leftLower.EndsWith(prefix, StringComparison.Ordinal))
                && LatinBridgeTailSuffixes.Contains(nextLower);
        }
        if (ObservedLatinBridgePrefixes.ContainsKey(rightLower))
        {
            return false;
        }
        return LatinBridgeFragments.Contains(rightLower)
            && !LatinContinuationFunctionWords.Contains(leftLower)
            && LatinContinuationSuffixes.Contains(nextLower);
    }

    private static bool HasApostropheInsideLatinRun(string text)
    {
        var trimmed = text.Trim();
        return trimmed.Contains('\'') || trimmed.Contains('’');
    }

    private static string TrailingLatinLetterRun(string text)
    {
        text = text.Normalize(NormalizationForm.FormC);
        var index = text.Length - 1;
        while (index >= 0 && IsLatinLetter(text[index])) index--;
        return text[(index + 1)..];
    }

    private static string LeadingLatinLetterRun(string text)
    {
        text = text.Normalize(NormalizationForm.FormC);
        var index = 0;
        while (index < text.Length && IsLatinLetter(text[index])) index++;
        return text[..index];
    }

    private static bool IsLatinLetter(char ch)
    {
        var category = char.GetUnicodeCategory(ch);
        if (category is not (
            System.Globalization.UnicodeCategory.UppercaseLetter
            or System.Globalization.UnicodeCategory.LowercaseLetter
            or System.Globalization.UnicodeCategory.TitlecaseLetter
            or System.Globalization.UnicodeCategory.ModifierLetter
            or System.Globalization.UnicodeCategory.OtherLetter))
        {
            return false;
        }

        return ch is >= '\u0041' and <= '\u005A'
            or >= '\u0061' and <= '\u007A'
            or >= '\u00C0' and <= '\u00FF'
            or >= '\u0100' and <= '\u024F'
            or >= '\u1E00' and <= '\u1EFF';
    }

    private static bool StartsWithLowercaseLetter(string text) =>
        text.Length > 0 && char.IsLower(text[0]);

    private static bool StartsWithUppercaseLetter(string text) =>
        text.Length > 0 && char.IsUpper(text[0]);

    private static bool EndsSentence(string value)
    {
        var trimmed = value.Trim();
        return trimmed.Length > 0 && ".!?。！？".Contains(trimmed[^1]);
    }

    private static bool IsPurePunctuation(string text)
    {
        var trimmed = text.Trim();
        return trimmed.Length == 0 || trimmed.All(ch => char.IsPunctuation(ch) || char.IsSymbol(ch));
    }

    private static bool IsDroppableJapaneseResidual(string text) =>
        DroppableJapaneseResiduals.Contains(text.Trim());
}

/// <summary>
/// Whisper-specific subtitle re-timer. Mirrors the Swift WhisperCueRetimer. Keeps the raw
/// whisper onset (leadIn 0 — earlier pulls regressed real samples against human references) and
/// extends each cue's end toward the next real onset (capped at HoldToNextSeconds past the last
/// token) to absorb whisper's habitually-early word ends, while guaranteeing no overlap.
/// Separate from the platform (YouTube auto-caption) timing path, which keeps human source anchors.
/// </summary>
public static class WhisperCueRetimer
{
    public const double OnsetDelaySeconds = 0.2;
    /// <summary>整段第一条字幕的 lead-in 阈值:首词在此秒数内(贴近视频开头)则首条从 0 起显,填掉开头空白。镜像 Swift。</summary>
    public const double FirstCueLeadInSeconds = 0.3;
    public const double InterCueGuardSeconds = 0.08;
    public const double HoldToNextSeconds = 0.7;
    public const double MixedCjkLatinHoldToNextSeconds = 0.45;
    private const double MinimumCueSeconds = LocalAsrSubtitleTimingPlanner.MinimumCueSeconds;
    private const double ProfiledMinimumCueSeconds = 0.9;
    private const double Epsilon = 0.001;

    public static IReadOnlyList<SubtitleCue> Retime(
        IReadOnlyList<SubtitleCue> cues,
        double? transcriptDurationSeconds,
        SubtitleTimingProfile profile = SubtitleTimingProfile.Speech,
        AsrAudioActivity? audioActivity = null)
    {
        if (cues.Count == 0) return cues;

        var thresholds = LocalAsrSubtitleTimingPlanner.Thresholds(profile);
        var lyricAcousticGuardEnabled = profile is SubtitleTimingProfile.Lyrics or SubtitleTimingProfile.JapaneseLyrics;
        var starts = new double[cues.Count];
        var ends = new double[cues.Count];
        var lastTokenEnds = new double[cues.Count];
        var caps = new double[cues.Count];
        for (var i = 0; i < cues.Count; i++)
        {
            var start = SrtTools.SrtTimeToSeconds(cues[i].Start);
            var end = SrtTools.SrtTimeToSeconds(cues[i].End);
            if (start is null || end is null)
            {
                return cues; // unparseable input: leave untouched rather than corrupt timing
            }
            starts[i] = start.Value;
            ends[i] = end.Value;
            var fragments = cues[i].SourceFragments;
            lastTokenEnds[i] = fragments.Count > 0 ? fragments[^1].EndSeconds : end.Value;
            caps[i] = LocalAsrSubtitleTimingPlanner.MaximumCueSecondsFor(cues[i].Text, start.Value, lastTokenEnds[i], thresholds);
        }

        var output = new List<SubtitleCue>(cues.Count);
        var previousEnd = double.NegativeInfinity;
        for (var i = 0; i < cues.Count; i++)
        {
            var hasNext = i + 1 < cues.Count;
            var nextStart = hasNext ? starts[i + 1] : double.PositiveInfinity;

            // Appearance: nudge the onset slightly later (DTW has a small early bias; window ideal
            // is slightly-late) so cues don't appear before speech. Bounded to keep a readable
            // minimum duration, never before the previous cue's end, never negative.
            // 例外:整段第一条不加 onsetDelay(避免视频开头首句"话说完才出现");首词贴近开头则从 0 起显填空白,
            // 首词前有真实静音则用原始 onset(不提前进静音)。镜像 Swift。
            double start;
            if (i == 0)
            {
                start = starts[i] <= FirstCueLeadInSeconds ? 0 : starts[i];
            }
            else
            {
                start = starts[i] + thresholds.OnsetDelaySeconds;
            }
            start = Math.Min(start, Math.Max(starts[i], ends[i] - MinimumCueSeconds));
            if (i > 0) start = Math.Max(start, previousEnd);
            start = Math.Max(start, 0);
            if (lyricAcousticGuardEnabled && audioActivity is not null)
            {
                start = audioActivity.ProtectedLyricStart(start);
                if (hasNext)
                {
                    start = Math.Min(start, Math.Max(starts[i], nextStart - MinimumCueSeconds));
                }
            }

            // Disappearance: extend toward the next real onset to absorb whisper's early word ends,
            // capped at HoldToNextSeconds past the last token and at the next onset minus a guard.
            // 末句没有下一个 onset，但仍不能越过整段音频时长，否则末句字幕会拖到视频结尾之后（BUG-4）。
            var ceiling = hasNext
                ? nextStart - InterCueGuardSeconds
                : (transcriptDurationSeconds is { } durationCeiling ? durationCeiling : double.PositiveInfinity);
            var hold = HoldToNextSecondsFor(cues[i].Text, thresholds);
            var end = Math.Max(ends[i], Math.Min(ceiling, lastTokenEnds[i] + hold));
            if (transcriptDurationSeconds is { } duration) end = Math.Min(end, duration);
            end = Math.Min(end, start + caps[i]);
            end = Math.Max(end, start + MinimumCueSecondsFor(profile)); // minimum readable duration (before overlap clamp)
            end = Math.Min(end, ceiling);                   // never overlap the next onset window
            end = Math.Min(end, nextStart);                 // hard no-overlap authority
            end = Math.Max(end, start + Epsilon);           // always positive duration

            output.Add(new SubtitleCue(
                output.Count + 1,
                SrtTools.SecondsToSrtTime(start),
                SrtTools.SecondsToSrtTime(end),
                cues[i].Text,
                cues[i].SourceFragments));
            previousEnd = end;
        }
        return output;
    }

    private static double HoldToNextSecondsFor(string text, SubtitleTimingThresholds thresholds) =>
        ContainsCjkLatinMix(text) ? Math.Min(MixedCjkLatinHoldToNextSeconds, thresholds.HoldToNextSeconds) : thresholds.HoldToNextSeconds;

    private static double MinimumCueSecondsFor(SubtitleTimingProfile profile) =>
        profile == SubtitleTimingProfile.Speech ? MinimumCueSeconds : ProfiledMinimumCueSeconds;

    private static bool ContainsCjkLatinMix(string text) =>
        SubtitleTimingPlanner.ContainsCjkText(text)
        && text.Any(ch => ch <= 0x7F && char.IsLetterOrDigit(ch));
}

public interface ILocalAsrSubtitleGenerator
{
    Task<GeneratedLocalAsrSource> GenerateSourceSubtitleAsync(
        string videoFile,
        string languageCode,
        TaskControlToken? control,
        Action<AsrProgress> progress,
        CancellationToken ct = default);
}

public sealed class SidecarLocalAsrSubtitleGenerator : ILocalAsrSubtitleGenerator
{
    private readonly string _executablePath;
    private readonly string _modelPath;
    private readonly string _workDirectory;

    public SidecarLocalAsrSubtitleGenerator(
        string executablePath,
        string modelPath,
        string workDirectory)
    {
        _executablePath = executablePath;
        _modelPath = modelPath;
        _workDirectory = workDirectory;
    }

    public async Task<GeneratedLocalAsrSource> GenerateSourceSubtitleAsync(
        string videoFile,
        string languageCode,
        TaskControlToken? control,
        Action<AsrProgress> progress,
        CancellationToken ct = default)
    {
        ct.ThrowIfCancellationRequested();
        if (control is not null) await control.GateAsync(ct).ConfigureAwait(false);
        Directory.CreateDirectory(_workDirectory);
        var output = AsrTranscriptMapper.LocalAsrSourceSrtPath(videoFile, languageCode);
        try { if (File.Exists(output)) File.Delete(output); } catch { /* best effort */ }

        progress(new AsrProgress { Phase = AsrProgressPhase.SpeechRecognition, CompletedUnits = 0, TotalUnits = 1 });
        var args = new[]
        {
            "--input", videoFile,
            "--output", output,
            "--language", NormalizeSidecarLanguage(languageCode),
            "--model", _modelPath,
            "--format", "srt",
        };
        try
        {
            var result = await ProcessRunner.RunStreamingProcessAsync(
                _executablePath,
                args,
                onStart: pid => control?.SetActivePid(pid),
                ct: ct).ConfigureAwait(false);
            if (result.Status != 0)
            {
                throw MoongateException.DownloadFailed(L10n.T(
                    $"本地精准识别 sidecar 失败（退出码 {result.Status}）：{result.StderrTail}",
                    $"本機精準識別 sidecar 失敗（結束碼 {result.Status}）：{result.StderrTail}",
                    $"Local precise recognition sidecar failed (exit {result.Status}): {result.StderrTail}"));
            }
        }
        finally
        {
            control?.SetActivePid(0);
        }

        if (!File.Exists(output))
        {
            throw MoongateException.DownloadFailed(L10n.T(
                "本地精准识别 sidecar 没有写出 SRT。",
                "本機精準識別 sidecar 沒有寫出 SRT。",
                "Local precise recognition sidecar did not write an SRT file."));
        }
        var raw = await File.ReadAllTextAsync(output, ct).ConfigureAwait(false);
        if (string.IsNullOrWhiteSpace(raw))
        {
            throw MoongateException.DownloadFailed(L10n.T(
                "本地精准识别 sidecar 写出了空字幕。",
                "本機精準識別 sidecar 寫出了空字幕。",
                "Local precise recognition sidecar wrote an empty subtitle file."));
        }
        progress(new AsrProgress { Phase = AsrProgressPhase.SpeechRecognition, CompletedUnits = 1, TotalUnits = 1 });
        var confidence = LocalAsrConfidence.AssessSubtitle(
            raw,
            Path.GetFileName(output),
            languageCode,
            languageCode);
        return new GeneratedLocalAsrSource(output, confidence);
    }

    private static string NormalizeSidecarLanguage(string value)
    {
        var trimmed = value.Trim();
        return trimmed.Length == 0 ? "auto" : trimmed;
    }
}

public sealed record AsrPromptMetadata(
    string? Title = null,
    string? Channel = null,
    IReadOnlyList<string>? Characters = null,
    IReadOnlyList<string>? GlossaryTerms = null);

public static class AsrPromptBuilder
{
    // CJK punctuation exemplar: whisper.cpp continues in the prompt's style. CJK output
    // otherwise carries almost no sentence punctuation (Japanese: 0, Korean: 6), starving
    // the segmenter of sentence boundaries. A punctuated example raises emitted punctuation
    // (0->24) and CJK aggregate strong-boundary recall 0.31->0.44 with no per-sample
    // regression in a fair same-run comparison (segmentation eval 2026-06-24, n=4).
    // CJK only; Latin already punctuates well. Mirror of Swift ASRPromptBuilder.
    public static string? PunctuationExemplar(string languageCode)
    {
        var lang = languageCode.Trim().ToLowerInvariant();
        if (lang.StartsWith("ja", StringComparison.Ordinal))
            return "今日は、いい天気ですね。はい、そうです。";
        if (lang.StartsWith("ko", StringComparison.Ordinal))
            return "안녕하세요. 오늘은 날씨가 좋네요. 네, 맞습니다.";
        if (lang.StartsWith("zh", StringComparison.Ordinal)
            || lang.StartsWith("yue", StringComparison.Ordinal)
            || lang.StartsWith("cmn", StringComparison.Ordinal))
            return "你好，今天天气不错。是的，没错。";
        return null;
    }

    public static string? DefaultPrompt(string videoPath, string languageCode) =>
        DefaultPrompt(videoPath, languageCode, AsrRecognitionProfile.Speech, null);

    public static string? DefaultPrompt(
        string videoPath,
        string languageCode,
        AsrRecognitionProfile recognitionProfile) =>
        DefaultPrompt(videoPath, languageCode, recognitionProfile, null);

    public static string? DefaultPrompt(
        string videoPath,
        string languageCode,
        AsrPromptMetadata? metadata) =>
        DefaultPrompt(videoPath, languageCode, AsrRecognitionProfile.Speech, metadata);

    public static string? DefaultPrompt(
        string videoPath,
        string languageCode,
        AsrRecognitionProfile recognitionProfile,
        AsrPromptMetadata? metadata)
    {
        var title = (metadata?.Title ?? Path.GetFileNameWithoutExtension(videoPath)).Trim();
        var language = languageCode.Trim();
        var parts = new List<string>();
        // CJK: lead with a punctuated exemplar so whisper.cpp emits sentence punctuation.
        if (recognitionProfile == AsrRecognitionProfile.Speech
            && !string.Equals(language, "auto", StringComparison.OrdinalIgnoreCase))
        {
            var exemplar = PunctuationExemplar(language);
            if (exemplar != null)
            {
                parts.Add(exemplar);
            }
        }
        if (title.Length > 0)
        {
            parts.Add($"title={title}");
        }
        if (!string.IsNullOrWhiteSpace(metadata?.Channel))
        {
            parts.Add($"channel={metadata.Channel.Trim()}");
        }
        if (language.Length > 0 && !string.Equals(language, "auto", StringComparison.OrdinalIgnoreCase))
        {
            parts.Add($"language={language}");
        }
        var hints = PromptHints(title, language, metadata);
        if (hints.Characters.Count > 0)
        {
            parts.Add("characters=" + string.Join(", ", hints.Characters));
        }
        if (hints.GlossaryTerms.Count > 0)
        {
            parts.Add("glossary=" + string.Join(", ", hints.GlossaryTerms));
        }
        return parts.Count == 0 ? null : string.Join("; ", parts);
    }

    private static (IReadOnlyList<string> Characters, IReadOnlyList<string> GlossaryTerms) PromptHints(
        string title,
        string languageCode,
        AsrPromptMetadata? metadata)
    {
        var inferred = InferredPromptHints(title, languageCode);
        return (
            Unique([.. metadata?.Characters ?? [], .. inferred.Characters]),
            Unique([.. metadata?.GlossaryTerms ?? [], .. inferred.GlossaryTerms]));
    }

    private static (IReadOnlyList<string> Characters, IReadOnlyList<string> GlossaryTerms) InferredPromptHints(
        string title,
        string languageCode)
    {
        var language = languageCode.Trim().ToLowerInvariant();
        if (language.Length > 0
            && !string.Equals(language, "auto", StringComparison.OrdinalIgnoreCase)
            && !language.StartsWith("ja", StringComparison.Ordinal))
        {
            return ([], []);
        }
        var lowerTitle = title.ToLowerInvariant();
        if (!title.Contains("コウペン", StringComparison.Ordinal) && !lowerTitle.Contains("koupen", StringComparison.Ordinal))
        {
            return ([], []);
        }
        return (
            ["コウペンちゃん", "邪エナガさん"],
            ["チョコバナナ", "ソースせんべい", "くじ引きやろう"]);
    }

    private static IReadOnlyList<string> Unique(IEnumerable<string> values)
    {
        var result = new List<string>();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var value in values)
        {
            var normalized = value.Trim();
            if (normalized.Length == 0 || !seen.Add(normalized)) continue;
            result.Add(normalized);
        }
        return result;
    }

    /// <summary>
    /// 是否对该识别档启用 whisper.cpp VAD。VAD 对演讲/对白安全（实测全程覆盖、转写几乎不变），但对歌唱/音乐
    /// 灾难性失效——silero 把演唱人声+伴奏判为非语音、丢掉大部分音频（实测 群青 130s→仅 1 段 47s 残片）。
    /// 故歌词高质量档关闭 VAD。
    /// </summary>
    public static bool VadEnabled(AsrRecognitionProfile recognitionProfile) =>
        recognitionProfile != AsrRecognitionProfile.LyricsHighQuality;

    public static int? MaxTextContextTokens(
        string videoPath,
        string languageCode,
        AsrRecognitionProfile recognitionProfile = AsrRecognitionProfile.Speech)
    {
        if (recognitionProfile == AsrRecognitionProfile.LyricsHighQuality) return 0;
        var language = languageCode.Trim().ToLowerInvariant();
        var cjkLanguage = language.StartsWith("ja", StringComparison.Ordinal)
            || language.StartsWith("ko", StringComparison.Ordinal)
            || language.StartsWith("zh", StringComparison.Ordinal)
            || language.StartsWith("yue", StringComparison.Ordinal)
            || language.StartsWith("cmn", StringComparison.Ordinal);
        return cjkLanguage ? 0 : null;
    }

    public static AsrRecognitionProfile RecognitionProfile(string videoPath, string languageCode)
    {
        var title = Path.GetFileNameWithoutExtension(videoPath).Trim().ToLowerInvariant();
        if (title.Length == 0) return AsrRecognitionProfile.Speech;
        var language = languageCode.Trim().ToLowerInvariant();
        var supported = language.StartsWith("ja", StringComparison.Ordinal)
            || language.StartsWith("ko", StringComparison.Ordinal)
            || language.StartsWith("zh", StringComparison.Ordinal)
            || language.StartsWith("yue", StringComparison.Ordinal)
            || language.StartsWith("cmn", StringComparison.Ordinal)
            || language.StartsWith("en", StringComparison.Ordinal)
            || language.StartsWith("fr", StringComparison.Ordinal)
            || language.StartsWith("es", StringComparison.Ordinal)
            || language.StartsWith("it", StringComparison.Ordinal)
            || string.Equals(language, "auto", StringComparison.Ordinal);
        if (!supported) return AsrRecognitionProfile.Speech;
        string[] markers =
        [
            "official music video", "music video", "official mv", " mv", "mv ",
            "official audio", "official visualizer", "performance video",
            "live", "lyrics", "lyric", "歌詞", "歌ってみた", "cover", "ライブ", "ライヴ",
        ];
        return markers.Any(marker => title.Contains(marker, StringComparison.Ordinal))
            || LooksLikeOfficialArtistTitleRelease(title)
            ? AsrRecognitionProfile.LyricsHighQuality
            : AsrRecognitionProfile.Speech;
    }

    private static bool LooksLikeOfficialArtistTitleRelease(string title)
    {
        string[] officialMarkers = ["(official)", "[official]", "【official】"];
        if (!officialMarkers.Any(marker => title.Contains(marker, StringComparison.Ordinal)))
        {
            return false;
        }
        string[] artistTitleSeparators = [" ⧸ ", " / ", " ／ ", " - ", " – ", " — ", " | ", "｜"];
        return artistTitleSeparators.Any(separator => title.Contains(separator, StringComparison.Ordinal));
    }
}

public sealed record AsrAudioExtractionPlan
{
    public required string FfmpegPath { get; init; }
    public required string InputPath { get; init; }
    public required string OutputPath { get; init; }
    public required IReadOnlyList<string> Arguments { get; init; }

    public static AsrAudioExtractionPlan Create(string ffmpegPath, string inputPath, string outputPath) => new()
    {
        FfmpegPath = ffmpegPath,
        InputPath = inputPath,
        OutputPath = outputPath,
        Arguments =
        [
            "-y",
            "-i", inputPath,
            "-map", "0:a:0",
            "-vn",
            "-ac", "1",
            "-ar", "16000",
            "-c:a", "pcm_s16le",
            "-f", "wav",
            outputPath,
        ],
    };
}

public enum AsrAudioExtractorError
{
    ProcessFailed,
    MissingOutput,
}

public sealed record AsrAudioActivityDetectionPlan
{
    public required string FfmpegPath { get; init; }
    public required string AudioPath { get; init; }
    public required IReadOnlyList<string> Arguments { get; init; }

    public static AsrAudioActivityDetectionPlan Create(string ffmpegPath, string audioPath) => new()
    {
        FfmpegPath = ffmpegPath,
        AudioPath = audioPath,
        Arguments =
        [
            "-hide_banner",
            "-nostats",
            "-i", audioPath,
            "-af", "silencedetect=noise=-35dB:d=0.2",
            "-f", "null",
            "-",
        ],
    };
}

public enum AsrAudioActivityDetectorError
{
    ProcessFailed,
}

public sealed class AsrAudioExtractorException(
    AsrAudioExtractorError reason,
    string? path = null,
    int? status = null,
    string? stderrTail = null)
    : Exception(reason.ToString())
{
    public AsrAudioExtractorError Reason { get; } = reason;
    public string? Path { get; } = path;
    public int? Status { get; } = status;
    public string? StderrTail { get; } = stderrTail;
}

public sealed class AsrAudioActivityDetectorException(
    AsrAudioActivityDetectorError reason,
    int? status = null,
    string? stderrTail = null)
    : Exception(reason.ToString())
{
    public AsrAudioActivityDetectorError Reason { get; } = reason;
    public int? Status { get; } = status;
    public string? StderrTail { get; } = stderrTail;
}

public interface IAsrAudioExtractor
{
    Task<string> ExtractAudioAsync(
        AsrAudioExtractionPlan plan,
        TaskControlToken? control,
        Action<AsrProgress> progress,
        CancellationToken ct = default);
}

public interface IAsrAudioActivityDetector
{
    Task<AsrAudioActivity> DetectActivityAsync(
        string audioPath,
        string ffmpegPath,
        TaskControlToken? control,
        CancellationToken ct = default);
}

public sealed class ProcessAsrAudioExtractor : IAsrAudioExtractor
{
    public async Task<string> ExtractAudioAsync(
        AsrAudioExtractionPlan plan,
        TaskControlToken? control,
        Action<AsrProgress> progress,
        CancellationToken ct = default)
    {
        ct.ThrowIfCancellationRequested();
        if (control is not null) await control.GateAsync(ct).ConfigureAwait(false);
        Directory.CreateDirectory(Path.GetDirectoryName(plan.OutputPath) ?? ".");
        progress(new AsrProgress { Phase = AsrProgressPhase.AudioExtract, CompletedUnits = 0, TotalUnits = 1 });
        try
        {
            var result = await ProcessRunner.RunStreamingProcessAsync(
                plan.FfmpegPath,
                plan.Arguments,
                onStart: pid => control?.SetActivePid(pid),
                ct: ct).ConfigureAwait(false);
            if (result.Status != 0)
            {
                throw new AsrAudioExtractorException(
                    AsrAudioExtractorError.ProcessFailed,
                    status: result.Status,
                    stderrTail: result.StderrTail);
            }
        }
        finally
        {
            control?.SetActivePid(0);
        }
        if (!File.Exists(plan.OutputPath))
        {
            throw new AsrAudioExtractorException(AsrAudioExtractorError.MissingOutput, path: plan.OutputPath);
        }
        progress(new AsrProgress { Phase = AsrProgressPhase.AudioExtract, CompletedUnits = 1, TotalUnits = 1 });
        return plan.OutputPath;
    }
}

public sealed class ProcessAsrAudioActivityDetector : IAsrAudioActivityDetector
{
    public async Task<AsrAudioActivity> DetectActivityAsync(
        string audioPath,
        string ffmpegPath,
        TaskControlToken? control,
        CancellationToken ct = default)
    {
        ct.ThrowIfCancellationRequested();
        if (control is not null) await control.GateAsync(ct).ConfigureAwait(false);
        var plan = AsrAudioActivityDetectionPlan.Create(ffmpegPath, audioPath);
        var result = await ProcessRunner.RunProcessAsync(
            plan.FfmpegPath,
            plan.Arguments,
            timeout: null,
            ct: ct).ConfigureAwait(false);
        if (result.Status != 0)
        {
            throw new AsrAudioActivityDetectorException(
                AsrAudioActivityDetectorError.ProcessFailed,
                status: result.Status,
                stderrTail: result.Stderr);
        }
        return AsrAudioActivity.ParseSilencedetectOutput(result.Stdout + "\n" + result.Stderr);
    }
}

public sealed class WhisperCppLocalAsrSubtitleGenerator : ILocalAsrSubtitleGenerator
{
    private readonly string _ffmpegPath;
    private readonly string _workDirectoryPath;
    private readonly ISpeechRecognizer _recognizer;
    private readonly string _modelId;
    private readonly string? _vadModelPath;
    private readonly Func<string, string, string?>? _promptProvider;
    private readonly IAsrAudioActivityDetector _audioActivityDetector;
    private readonly IAsrAudioExtractor _audioExtractor;

    public WhisperCppLocalAsrSubtitleGenerator(
        string ffmpegPath,
        string workDirectoryPath,
        ISpeechRecognizer recognizer,
        string modelId,
        string? vadModelPath = null,
        Func<string, string, string?>? promptProvider = null,
        IAsrAudioActivityDetector? audioActivityDetector = null,
        IAsrAudioExtractor? audioExtractor = null)
    {
        _ffmpegPath = ffmpegPath;
        _workDirectoryPath = workDirectoryPath;
        _recognizer = recognizer;
        _modelId = modelId;
        _vadModelPath = string.IsNullOrWhiteSpace(vadModelPath) ? null : vadModelPath.Trim();
        _promptProvider = promptProvider;
        _audioActivityDetector = audioActivityDetector ?? new ProcessAsrAudioActivityDetector();
        _audioExtractor = audioExtractor ?? new ProcessAsrAudioExtractor();
    }

    public async Task<GeneratedLocalAsrSource> GenerateSourceSubtitleAsync(
        string videoFile,
        string languageCode,
        TaskControlToken? control,
        Action<AsrProgress> progress,
        CancellationToken ct = default)
    {
        ct.ThrowIfCancellationRequested();
        if (control is not null) await control.GateAsync(ct).ConfigureAwait(false);
        Directory.CreateDirectory(_workDirectoryPath);

        var audioPath = AudioPath(videoFile, languageCode);
        if (File.Exists(audioPath))
        {
            progress(new AsrProgress { Phase = AsrProgressPhase.AudioExtract, CompletedUnits = 1, TotalUnits = 1 });
        }
        else
        {
            var plan = AsrAudioExtractionPlan.Create(_ffmpegPath, videoFile, audioPath);
            await _audioExtractor.ExtractAudioAsync(plan, control, progress, ct).ConfigureAwait(false);
        }

        var request = MakeRequest(videoFile, audioPath, languageCode);
        var transcript = await _recognizer.TranscribeAsync(request, progress, control, ct).ConfigureAwait(false);
        var languageHintCode = SubtitleLanguageRecommender.InferredLocalAsrLanguageCode(Path.GetFileNameWithoutExtension(videoFile));
        var qualitySummary = QualitySummary(transcript, request, languageHintCode);
        if (ShouldRetryAutoTranscript(qualitySummary, request, languageHintCode))
        {
            ct.ThrowIfCancellationRequested();
            if (control is not null) await control.GateAsync(ct).ConfigureAwait(false);
            request = MakeRequest(videoFile, audioPath, languageHintCode!);
            transcript = await _recognizer.TranscribeAsync(request, progress, control, ct).ConfigureAwait(false);
            qualitySummary = QualitySummary(transcript, request, languageHintCode);
        }
        // 严重质量问题（重复循环 / 自动语言误判）不再让整个任务失败——whisper 是 fallback，硬失败只会让
        // 用户一无所得（近期被感知为"识别变差"的回归）。改为照常产出字幕并透传 qualitySummary，由 Queue 给出
        // 诚实的"识别可能不可靠"提示。
        progress(new AsrProgress { Phase = AsrProgressPhase.SubtitleSegment, CompletedUnits = 0, TotalUnits = 1 });
        var activity = await AudioActivityIfNeededAsync(transcript, videoFile, audioPath, control, ct).ConfigureAwait(false);
        var output = AsrTranscriptMapper.WriteLocalAsrSourceSrt(transcript, videoFile, activity);
        progress(new AsrProgress { Phase = AsrProgressPhase.SubtitleSegment, CompletedUnits = 1, TotalUnits = 1 });
        return new GeneratedLocalAsrSource(output, qualitySummary);
    }

    private AsrRequest MakeRequest(string videoFile, string audioPath, string languageCode)
    {
        var recognitionProfile = AsrPromptBuilder.RecognitionProfile(videoFile, languageCode);
        var prompt = _promptProvider?.Invoke(videoFile, languageCode);
        var maxTextContextTokens = AsrPromptBuilder.MaxTextContextTokens(videoFile, languageCode, recognitionProfile);
        // VAD 对演讲/对白安全但对歌唱/音乐灾难性失效（silero 把演唱人声判为非语音、丢大部分音频）→ 歌词档关闭。
        var vadEnabled = AsrPromptBuilder.VadEnabled(recognitionProfile);
        return new AsrRequest
        {
            AudioPath = audioPath,
            LanguageCode = languageCode,
            ModelId = _modelId,
            Prompt = prompt,
            RecognitionProfile = recognitionProfile,
            MaxTextContextTokens = maxTextContextTokens,
            VadEnabled = vadEnabled,
            VadModelPath = _vadModelPath,
            WordTimestamps = true,
            CacheKey = CacheKey(
                videoFile,
                languageCode,
                prompt,
                recognitionProfile,
                maxTextContextTokens,
                AsrBackendKind.WhisperCpp,
                vadEnabled: vadEnabled,
                vadModelPath: _vadModelPath,
                wordTimestamps: true,
                dtwTokenTimestamps: true),
        };
    }

    private static LocalAsrConfidenceSummary QualitySummary(
        AsrTranscript transcript,
        AsrRequest request,
        string? languageHintCode) =>
        LocalAsrConfidence.Assess(
            transcript.Words,
            transcript.LanguageCode,
            transcript.Segments,
            request.LanguageCode,
            languageHintCode);

    private static bool ShouldRetryAutoTranscript(
        LocalAsrConfidenceSummary summary,
        AsrRequest request,
        string? languageHintCode)
    {
        var requested = (request.LanguageCode ?? "").Trim().ToLowerInvariant();
        if (requested is not ("" or "auto" or "und" or "unknown")) return false;
        if (string.IsNullOrWhiteSpace(languageHintCode)) return false;
        return summary.QualityIssues.Contains("autoLanguageMismatch")
            || summary.QualityIssues.Contains("phraseLoop")
            || summary.QualityIssues.Contains("lowSegmentDiversity");
    }

    private async Task<AsrAudioActivity?> AudioActivityIfNeededAsync(
        AsrTranscript transcript,
        string videoFile,
        string audioPath,
        TaskControlToken? control,
        CancellationToken ct)
    {
        var speechCues = AsrTranscriptMapper.SourceCues(transcript, SubtitleTimingProfile.Speech);
        var profile = SubtitleTimingProfileDetector.Detect(Path.GetFileName(videoFile), speechCues, transcript.LanguageCode);
        if (profile is not (SubtitleTimingProfile.Lyrics or SubtitleTimingProfile.JapaneseLyrics)) return null;
        try
        {
            return await _audioActivityDetector.DetectActivityAsync(audioPath, _ffmpegPath, control, ct).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch
        {
            return null;
        }
    }

    private string AudioPath(string videoFile, string languageCode) =>
        Path.Combine(_workDirectoryPath, "audio", StableFileStem(AudioSeed(videoFile, languageCode)) + ".wav");

    private string CacheKey(
        string videoFile,
        string languageCode,
        string? prompt,
        AsrRecognitionProfile recognitionProfile,
        int? maxTextContextTokens,
        AsrBackendKind backendKind,
        bool vadEnabled,
        string? vadModelPath,
        bool wordTimestamps,
        bool dtwTokenTimestamps) =>
        "local-asr:" + StableFileStem(
            AudioSeed(videoFile, languageCode)
            + "\nbackend=" + BackendKindCacheValue(backendKind)
            + "\n" + (prompt ?? "")
            + "\nrp=" + RecognitionProfileCacheValue(recognitionProfile)
            + "\nmc=" + (maxTextContextTokens?.ToString(CultureInfo.InvariantCulture) ?? "default")
            + "\nvad=" + BoolCacheValue(vadEnabled)
            + "\nvm=" + (string.IsNullOrWhiteSpace(vadModelPath) ? "none" : vadModelPath.Trim())
            + "\nwords=" + BoolCacheValue(wordTimestamps)
            + "\ndtw=" + BoolCacheValue(dtwTokenTimestamps)
            + "\nschema=v4");

    private static string BackendKindCacheValue(AsrBackendKind backendKind) =>
        backendKind switch
        {
            AsrBackendKind.WhisperCpp => "whisperCpp",
            AsrBackendKind.SenseVoiceFunASR => "senseVoiceFunASR",
            _ => "unknown",
        };

    private static string RecognitionProfileCacheValue(AsrRecognitionProfile profile) =>
        profile switch
        {
            AsrRecognitionProfile.LyricsHighQuality => "lyricsHighQuality",
            _ => "speech",
        };

    private static string BoolCacheValue(bool value) => value ? "true" : "false";

    private string AudioSeed(string videoFile, string languageCode)
    {
        var fullPath = Path.GetFullPath(videoFile);
        var info = new FileInfo(videoFile);
        var size = info.Exists ? info.Length.ToString(CultureInfo.InvariantCulture) : "unknown-size";
        var modifiedAt = info.Exists
            ? info.LastWriteTimeUtc.Ticks.ToString(CultureInfo.InvariantCulture)
            : "unknown-mtime";
        return string.Join('\n', [fullPath, languageCode, _modelId, size, modifiedAt]);
    }

    private static string StableFileStem(string value) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value))).ToLowerInvariant();
}

public static class LocalAsrGeneratorFactory
{
    public static ILocalAsrSubtitleGenerator? Create(
        AppSettings settings,
        Func<DateTimeOffset>? nowProvider = null) =>
        Create(
            settings,
            BinaryLocator.Locate("ffmpeg", "MOONGATE_FFMPEG_PATH"),
            AppSettings.SupportDirectory,
            nowProvider);

    public static ILocalAsrSubtitleGenerator? Create(
        AppSettings settings,
        string? ffmpegPath,
        string? supportDirectoryPath,
        Func<DateTimeOffset>? nowProvider = null)
    {
        if (!settings.LocalAsrEnabled) return null;
        var sidecarRuntimePath = settings.LocalAsrSidecarRuntimePath.Trim();
        var sidecarModelPath = settings.LocalAsrSidecarModelPath.Trim();
        if (settings.LocalAsrPreciseModeEnabled)
        {
            if (sidecarRuntimePath.Length == 0 || sidecarModelPath.Length == 0) return null;
            if (!IsExecutable(sidecarRuntimePath) || !File.Exists(sidecarModelPath) && !Directory.Exists(sidecarModelPath))
            {
                return null;
            }
            var sidecarDirectory = Path.Combine(supportDirectoryPath ?? AppSettings.SupportDirectory, "asr", "sidecar-work");
            return new SidecarLocalAsrSubtitleGenerator(sidecarRuntimePath, sidecarModelPath, sidecarDirectory);
        }
        var runtimePath = settings.LocalAsrRuntimePath.Trim();
        var modelPath = settings.LocalAsrModelPath.Trim();
        var modelId = settings.LocalAsrModelId.Trim();
        if (runtimePath.Length == 0 || modelPath.Length == 0 || modelId.Length == 0) return null;

        if (!IsExecutable(ffmpegPath) || !IsExecutable(runtimePath) || !File.Exists(modelPath))
        {
            return null;
        }
        if (!IsReadyModel(modelId, modelPath, supportDirectoryPath))
        {
            return null;
        }
        var vadModelPath = settings.LocalAsrVadModelPath.Trim();
        var usableVadModelPath = vadModelPath.Length > 0 && File.Exists(vadModelPath)
            ? vadModelPath
            : null;

        var asrDirectory = Path.Combine(supportDirectoryPath ?? AppSettings.SupportDirectory, "asr");
        var recognizer = new WhisperCppSpeechRecognizer(
            new AsrRuntimeInfo { ExecutablePath = runtimePath },
            modelPath,
            Path.Combine(asrDirectory, "transcripts-work"),
            new AsrTranscriptCacheStore(Path.Combine(asrDirectory, "cache")),
            nowProvider: nowProvider);
        return new WhisperCppLocalAsrSubtitleGenerator(
            ffmpegPath!,
            Path.Combine(asrDirectory, "work"),
            recognizer,
            modelId,
            usableVadModelPath,
            (videoPath, languageCode) => AsrPromptBuilder.DefaultPrompt(
                videoPath,
                languageCode,
                AsrPromptBuilder.RecognitionProfile(videoPath, languageCode)));
    }

    private static bool IsExecutable(string? path)
    {
        if (string.IsNullOrWhiteSpace(path) || !File.Exists(path)) return false;
        if (OperatingSystem.IsWindows()) return true;
        try
        {
            var mode = File.GetUnixFileMode(path);
            const UnixFileMode executeBits =
                UnixFileMode.UserExecute | UnixFileMode.GroupExecute | UnixFileMode.OtherExecute;
            return (mode & executeBits) != 0;
        }
        catch
        {
            return false;
        }
    }

    private static bool IsReadyModel(string modelId, string modelPath, string? supportDirectoryPath)
    {
        var model = AsrModelManifest.RecommendedWhisperCpp.Models
            .FirstOrDefault(candidate => string.Equals(candidate.Id, modelId, StringComparison.Ordinal));
        if (model is null) return true;

        try
        {
            var store = new AsrModelStore(Path.Combine(
                supportDirectoryPath ?? AppSettings.SupportDirectory,
                "asr",
                "models"));
            var status = store.Status(model);
            return status.IsInstalled
                && string.Equals(
                    Path.GetFullPath(modelPath),
                    Path.GetFullPath(status.InstalledPath),
                    PathComparison);
        }
        catch
        {
            return false;
        }
    }

    private static StringComparison PathComparison =>
        OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
}

public sealed record WhisperCppCommandPlan
{
    public required AsrRuntimeInfo Runtime { get; init; }
    public required string ModelPath { get; init; }
    public required AsrRequest Request { get; init; }
    public required string OutputBasePath { get; init; }
    public bool DisableGpu { get; init; }
    public required IReadOnlyList<string> Arguments { get; init; }

    public string ExecutablePath => Runtime.ExecutablePath;

    public string OutputJsonPath => Path.ChangeExtension(OutputBasePath, ".json");

    public static WhisperCppCommandPlan Create(
        AsrRuntimeInfo runtime,
        string modelPath,
        AsrRequest request,
        string outputBasePath,
        bool disableGpu = false)
    {
        var normalizedOutputBase = WithoutExtension(outputBasePath);
        List<string> arguments =
        [
            "-m", modelPath,
            "-f", request.AudioPath,
            request.WordTimestamps ? "-ojf" : "-oj",
            "-of", normalizedOutputBase,
            "-pp",
        ];
        if (disableGpu)
        {
            arguments.Add("--no-gpu");
        }

        if (request.VadEnabled
            && !string.IsNullOrWhiteSpace(request.VadModelPath)
            && File.Exists(request.VadModelPath))
        {
            arguments.AddRange(["--vad", "-vm", request.VadModelPath]);
        }

        // DTW token timestamps need full JSON token output, a known preset, and flash attention
        // OFF (-nfa) — otherwise whisper.cpp silently disables DTW.
        if (request.WordTimestamps
            && request.DtwTokenTimestamps
            && WhisperDtwPreset.Preset(request.ModelId) is { } preset)
        {
            arguments.AddRange(["-dtw", preset, "-nfa"]);
        }

        var languageCode = request.LanguageCode?.Trim();
        if (!string.IsNullOrEmpty(languageCode)
            && !string.Equals(languageCode, "auto", StringComparison.OrdinalIgnoreCase))
        {
            arguments.AddRange(["-l", languageCode]);
        }

        var prompt = request.Prompt?.Trim();
        if (!string.IsNullOrEmpty(prompt))
        {
            arguments.AddRange(["--prompt", prompt]);
        }
        if (request.MaxTextContextTokens is { } maxTextContextTokens)
        {
            arguments.AddRange(["-mc", Math.Max(0, maxTextContextTokens).ToString(CultureInfo.InvariantCulture)]);
        }

        return new WhisperCppCommandPlan
        {
            Runtime = runtime,
            ModelPath = modelPath,
            Request = request,
            OutputBasePath = normalizedOutputBase,
            DisableGpu = disableGpu,
            Arguments = arguments,
        };
    }

    private static string WithoutExtension(string path)
    {
        var directory = Path.GetDirectoryName(path);
        var fileName = Path.GetFileNameWithoutExtension(path);
        return string.IsNullOrEmpty(directory) ? fileName : Path.Combine(directory, fileName);
    }
}

/// <summary>
/// Maps a Moongate whisper model id (e.g. <c>whisper.cpp:small-q5_1</c>) to the whisper.cpp
/// <c>-dtw &lt;preset&gt;</c> alignment-heads preset name (dot form, e.g. <c>large.v3.turbo</c>).
/// Returns null when no preset is known, in which case the caller must omit <c>-dtw</c>.
/// </summary>
public static class WhisperDtwPreset
{
    private static readonly HashSet<string> Known =
    [
        "tiny", "tiny.en", "base", "base.en", "small", "small.en",
        "medium", "medium.en", "large.v1", "large.v2", "large.v3", "large.v3.turbo",
    ];

    public static string? Preset(string modelId)
    {
        var name = modelId;
        var colon = name.LastIndexOf(':');
        if (colon >= 0) name = name[(colon + 1)..];
        name = name.Trim().ToLowerInvariant();
        // Strip quantization suffix like "-q5_1", ".q8_0", "_q5_0".
        var match = System.Text.RegularExpressions.Regex.Match(name, "[-_.]q[0-9].*$");
        if (match.Success) name = name[..match.Index];
        // Catalog ids use dashes for large variants (large-v3-turbo); presets use dots.
        if (name.StartsWith("large", StringComparison.Ordinal)) name = name.Replace('-', '.');
        return Known.Contains(name) ? name : null;
    }
}

public sealed record AsrCommandResult
{
    public required int Status { get; init; }
    public required string StderrTail { get; init; }
}

public interface IAsrCommandRunner
{
    Task<AsrCommandResult> RunWhisperAsync(
        WhisperCppCommandPlan plan,
        TaskControlToken? control,
        Action<string> onLine,
        CancellationToken ct = default);
}

public sealed class ProcessAsrCommandRunner : IAsrCommandRunner
{
    public async Task<AsrCommandResult> RunWhisperAsync(
        WhisperCppCommandPlan plan,
        TaskControlToken? control,
        Action<string> onLine,
        CancellationToken ct = default)
    {
        using var process = new Process { StartInfo = MakeStartInfo(plan.ExecutablePath, plan.Arguments) };
        try
        {
            process.Start();
        }
        catch (Exception e)
        {
            throw new InvalidOperationException($"Could not start whisper.cpp runtime: {e.Message}", e);
        }
        process.StandardInput.Close();
        var pid = SafePid(process);
        if (ct.IsCancellationRequested)
        {
            ProcessTree.KillTree(pid);
        }
        else
        {
            control?.SetActivePid(pid);
        }

        var stderrTail = new StringBuilder();
        var stderrLock = new object();
        const int stderrLimit = 16 * 1024;

        var stdoutTask = Task.Run(async () =>
        {
            while (await process.StandardOutput.ReadLineAsync(CancellationToken.None).ConfigureAwait(false) is { } line)
            {
                if (line.Length > 0) onLine(line);
            }
        }, CancellationToken.None);
        var stderrTask = Task.Run(async () =>
        {
            while (await process.StandardError.ReadLineAsync(CancellationToken.None).ConfigureAwait(false) is { } line)
            {
                lock (stderrLock)
                {
                    stderrTail.AppendLine(line);
                    if (stderrTail.Length > stderrLimit)
                    {
                        stderrTail.Remove(0, stderrTail.Length - stderrLimit);
                    }
                }
                if (line.Length > 0) onLine(line);
            }
        }, CancellationToken.None);

        await using var cancelReg = ct.Register(() => ProcessTree.KillTree(pid)).ConfigureAwait(false);
        await process.WaitForExitAsync(CancellationToken.None).ConfigureAwait(false);
        control?.SetActivePid(0);
        await Task.WhenAny(
            Task.WhenAll(stdoutTask, stderrTask),
            Task.Delay(TimeSpan.FromSeconds(10), CancellationToken.None)).ConfigureAwait(false);

        ct.ThrowIfCancellationRequested();
        if (control?.IsCancelled == true) throw MoongateException.Cancelled();
        string tail;
        lock (stderrLock) tail = stderrTail.ToString();
        return new AsrCommandResult { Status = process.ExitCode, StderrTail = tail };
    }

    private static ProcessStartInfo MakeStartInfo(string executable, IReadOnlyList<string> arguments)
    {
        var psi = new ProcessStartInfo(executable)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        foreach (var argument in arguments)
        {
            psi.ArgumentList.Add(argument);
        }
        return psi;
    }

    private static int SafePid(Process process)
    {
        try { return process.Id; } catch { return 0; }
    }
}

public enum WhisperCppRecognizerError
{
    MissingRuntime,
    MissingModel,
    ProcessFailed,
    MissingTranscriptJson,
    EmptyTranscript,
    InvalidTranscriptJson,
}

public sealed class WhisperCppRecognizerException : Exception
{
    public WhisperCppRecognizerException(
        WhisperCppRecognizerError reason,
        string? path = null,
        int? status = null,
        string? stderrTail = null,
        string? detail = null)
        : base(detail ?? reason.ToString())
    {
        Reason = reason;
        Path = path;
        Status = status;
        StderrTail = stderrTail;
    }

    public WhisperCppRecognizerError Reason { get; }
    public string? Path { get; }
    public int? Status { get; }
    public string? StderrTail { get; }
}

public static class WhisperCppProgressParser
{
    public static AsrProgress? Parse(string line)
    {
        // 只认 whisper.cpp 自己的进度行（`whisper_print_progress_callback: progress = 25%` /
        // `whisper.cpp progress: 25%`）。旧版用 `([0-9.]+)\s*%` 匹配任意含 % 的行，会把转写出来的台词
        // 文本（如 "…sales up 50%…"）误当成进度更新，导致进度条乱跳。用 “progress” 关键字 + 分隔符锚定，
        // 同时兼容 `=`/`:` 两种 whisper.cpp 版本格式。
        var match = Regex.Match(line, @"progress\s*[:=]\s*([0-9]+(?:\.[0-9]+)?)\s*%", RegexOptions.IgnoreCase);
        if (!match.Success) return null;
        if (!double.TryParse(match.Groups[1].Value, NumberStyles.Float, CultureInfo.InvariantCulture, out var value)
            || double.IsNaN(value)
            || double.IsInfinity(value))
        {
            return null;
        }
        return new AsrProgress
        {
            Phase = AsrProgressPhase.SpeechRecognition,
            CompletedUnits = Math.Clamp(value, 0, 100),
            TotalUnits = 100,
        };
    }
}

public sealed class WhisperCppJsonTranscriptParser
{
    public AsrTranscript Parse(
        byte[] data,
        AsrRequest request,
        string transcriptId,
        DateTimeOffset? createdAt = null)
    {
        using var document = ParseDocument(data);
        var root = document.RootElement;
        var languageCode = LanguageCode(root, request);
        var languageConfidence = LanguageConfidence(root);
        var words = new List<AsrWord>();
        var transcriptSegments = new List<AsrSegment>();
        var rawTexts = new List<string>();
        var dtwStarts = new List<double?>();
        double? maxEnd = null;
        var segmentCount = 0;

        if (TryGetArray(root, "transcription", out var segments)
            || TryGetArray(root, "segments", out segments))
        {
            segmentCount = segments.GetArrayLength();
            foreach (var segment in segments.EnumerateArray())
            {
                var segmentText = TryCleanText(segment, out var cleanSegmentText) ? cleanSegmentText : null;
                if (TryInterval(segment, offsetsAreMilliseconds: true, out var segmentStart, out var segmentEnd))
                {
                    maxEnd = Math.Max(maxEnd ?? segmentEnd, segmentEnd);
                    if (segmentText is not null)
                    {
                        transcriptSegments.Add(new AsrSegment
                        {
                            Text = segmentText,
                            StartSeconds = segmentStart,
                            EndSeconds = segmentEnd,
                        });
                        rawTexts.Add(segmentText);
                    }
                }

                var tokenEntries = ParseTokenEntries(segment, segmentText);
                if (tokenEntries.Count == 0)
                {
                    if (ParseSegmentWord(segment) is { } fallback)
                    {
                        words.Add(fallback);
                        dtwStarts.Add(null);
                        maxEnd = Math.Max(maxEnd ?? fallback.EndSeconds, fallback.EndSeconds);
                    }
                }
                else
                {
                    foreach (var (word, dtwStart) in tokenEntries)
                    {
                        words.Add(word);
                        dtwStarts.Add(dtwStart);
                    }
                }
            }
        }

        // Prefer DTW token timestamps when present (whisper.cpp -dtw): markedly closer to human
        // timing than the default frame-quantized offsets.
        if (dtwStarts.Any(value => value is not null))
        {
            words = ApplyDtwTiming(words, dtwStarts);
        }
        foreach (var word in words)
        {
            maxEnd = Math.Max(maxEnd ?? word.EndSeconds, word.EndSeconds);
        }

        if (words.Count == 0)
        {
            throw new WhisperCppRecognizerException(WhisperCppRecognizerError.EmptyTranscript);
        }
        return new AsrTranscript
        {
            Id = transcriptId,
            LanguageCode = languageCode,
            LanguageConfidence = languageConfidence,
            DurationSeconds = maxEnd,
            Words = words,
            SourceModelId = request.ModelId,
            BackendKind = AsrBackendKind.WhisperCpp,
            Segments = transcriptSegments,
            RawText = rawTexts.Count == 0 ? null : string.Join('\n', rawTexts),
            BackendDiagnostics = new Dictionary<string, string>
            {
                ["segmentCount"] = segmentCount.ToString(CultureInfo.InvariantCulture),
                ["wordTimestampMode"] = request.WordTimestamps ? "word" : "segment",
                ["dtwRequested"] = request.DtwTokenTimestamps && request.WordTimestamps ? "True" : "False",
                ["vadRequested"] = request.VadEnabled ? "True" : "False",
            },
            QualitySummary = LocalAsrConfidence.Assess(
                words,
                languageCode,
                transcriptSegments,
                request.LanguageCode),
            CreatedAt = createdAt ?? DateTimeOffset.UtcNow,
        };
    }

    private static JsonDocument ParseDocument(byte[] data)
    {
        try
        {
            return JsonDocument.Parse(data);
        }
        catch (JsonException e)
        {
            throw new WhisperCppRecognizerException(
                WhisperCppRecognizerError.InvalidTranscriptJson,
                detail: e.Message);
        }
    }

    private static string LanguageCode(JsonElement root, AsrRequest request)
    {
        foreach (var candidate in new[]
        {
            TryGetObject(root, "result", out var result) && TryGetString(result, "language", out var resultLanguage)
                ? resultLanguage
                : null,
            TryGetObject(root, "params", out var parameters) && TryGetString(parameters, "language", out var parameterLanguage)
                ? parameterLanguage
                : null,
            request.LanguageCode,
        })
        {
            var value = candidate?.Trim();
            if (!string.IsNullOrEmpty(value)) return value;
        }
        return "auto";
    }

    private static double? LanguageConfidence(JsonElement root)
    {
        if (!TryGetObject(root, "result", out var result)) return null;
        return Number(result, ["language_probability", "languageProbability", "language_confidence", "languageConfidence"]);
    }

    private static IReadOnlyList<(AsrWord Word, double? DtwStart)> ParseTokenEntries(JsonElement segment, string? segmentText = null)
    {
        if (!TryGetArray(segment, "tokens", out var tokens)
            && !TryGetArray(segment, "words", out tokens))
        {
            return [];
        }

        var entries = new List<(AsrWord Word, double? DtwStart)>();
        var mergeEligible = new List<bool>();
        foreach (var token in tokens.EnumerateArray())
        {
            var rawText = TryGetString(token, "text", out var raw) ? raw : "";
            if (IsWhisperControlToken(rawText)) continue;
            if (!TryCleanText(token, out var text)
                || !TryTokenInterval(token, offsetsAreMilliseconds: true, out var start, out var end))
            {
                continue;
            }
            var word = new AsrWord
            {
                Text = text,
                StartSeconds = start,
                EndSeconds = end,
                Probability = Number(token, ["p", "probability", "confidence"]),
            };
            // whisper.cpp t_dtw is in centiseconds; -1 means "not computed".
            double? dtwStart = Number(token, ["t_dtw"]) is { } dtwRaw && dtwRaw >= 0 ? dtwRaw / 100.0 : null;
            var startsNewWhisperTokenWord = rawText.Length > 0
                && char.IsWhiteSpace(rawText[0])
                && !ParserContainsCjkOrHangul(text);
            if (entries.Count > 0
                && ShouldMergeLatinParserToken(entries[^1].Word.Text, mergeEligible[^1], text, rawText))
            {
                var previous = entries[^1];
                var mergedWord = new AsrWord
                {
                    Text = previous.Word.Text + text,
                    StartSeconds = previous.Word.StartSeconds,
                    EndSeconds = Math.Max(previous.Word.EndSeconds, word.EndSeconds),
                    Probability = Math.Min(previous.Word.Probability ?? 1.0, word.Probability ?? 1.0),
                };
                entries[^1] = (mergedWord, previous.DtwStart ?? dtwStart);
                mergeEligible[^1] = true;
            }
            else
            {
                entries.Add((word, dtwStart));
                mergeEligible.Add(startsNewWhisperTokenWord);
            }
        }
        return SpacedScriptSegmentWordEntries(segmentText, entries) ?? entries;
    }

    // Rebuild word-level entries from segment text for scripts that whisper.cpp writes with real
    // word spacing but splits into sub-character token pieces (Hangul eojeol, Devanagari words).
    // CJK segment text has no spaces, so it yields <2 units and is left untouched.
    private static IReadOnlyList<(AsrWord Word, double? DtwStart)>? SpacedScriptSegmentWordEntries(
        string? segmentText,
        IReadOnlyList<(AsrWord Word, double? DtwStart)> entries)
    {
        if (string.IsNullOrWhiteSpace(segmentText)
            || (!ParserContainsHangul(segmentText) && !ParserContainsSpacedScript(segmentText))
            || entries.Count == 0)
        {
            return null;
        }
        var units = segmentText
            .Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries)
            .ToArray();
        if (units.Length < 2) return null;

        var output = new List<(AsrWord Word, double? DtwStart)>();
        var entryIndex = 0;
        foreach (var unit in units)
        {
            var target = ParserAlignmentText(unit);
            if (target.Length == 0) return null;
            var consumed = new List<(AsrWord Word, double? DtwStart)>();
            var accumulated = "";
            while (entryIndex < entries.Count && accumulated != target)
            {
                var entry = entries[entryIndex];
                var tokenText = ParserAlignmentText(entry.Word.Text);
                if (tokenText.Length == 0) return null;
                accumulated += tokenText;
                if (!target.StartsWith(accumulated, StringComparison.Ordinal)) return null;
                consumed.Add(entry);
                entryIndex++;
            }
            if (accumulated != target || consumed.Count == 0) return null;
            var first = consumed[0];
            var end = consumed.Max(entry => entry.Word.EndSeconds);
            output.Add((
                first.Word with
                {
                    Text = unit,
                    EndSeconds = end,
                    Probability = consumed.Min(entry => entry.Word.Probability ?? 1.0),
                },
                first.DtwStart));
        }
        return entryIndex == entries.Count ? output : null;
    }

    private static bool ShouldMergeLatinParserToken(
        string previousText,
        bool previousMergeEligible,
        string currentText,
        string rawCurrentText)
    {
        if (!previousMergeEligible) return false;
        if (rawCurrentText.Length > 0 && char.IsWhiteSpace(rawCurrentText[0])) return false;
        var previous = previousText.Trim();
        var current = currentText.Trim();
        if (previous.Length == 0 || current.Length == 0) return false;
        if (ParserContainsCjkOrHangul(previous) || ParserContainsCjkOrHangul(current)) return false;
        if (ParserIsLatinJoinPunctuation(current)) return true;
        if (ParserIsLatinApostrophePrefix(previous) && ParserContainsLetterOutsideCjk(current)) return true;
        return ParserContainsLetterOutsideCjk(previous) && ParserContainsLetterOutsideCjk(current);
    }

    private static bool ParserIsLatinJoinPunctuation(string text) =>
        text.All(ch => ch is '\'' or '’' or '.' or ',' or '!' or '?' or ':' or ';')
        || text[0] is '\'' or '’';

    private static bool ParserIsLatinApostrophePrefix(string text) =>
        text.All(ch => ch is '\'' or '’');

    private static bool ParserContainsLetterOutsideCjk(string text) =>
        text.EnumerateRunes().Any(rune => Rune.IsLetter(rune) && !ParserIsCjkOrHangulScalar(rune.Value));

    private static bool ParserContainsCjkOrHangul(string text) =>
        text.EnumerateRunes().Any(rune => ParserIsCjkOrHangulScalar(rune.Value));

    private static bool ParserContainsHangul(string text) =>
        text.EnumerateRunes().Any(rune => rune.Value is >= 0xAC00 and <= 0xD7A3);

    // Space-separated non-CJK scripts that whisper.cpp writes with real word spacing but splits
    // into base-letter + combining-mark token pieces (Devanagari, Bengali, Arabic, Cyrillic, …).
    // Word entries must be rebuilt from segment text to keep readable spacing (mirrors Hangul).
    // CJK (Han/Kana) is intentionally excluded: it has no word spaces.
    private static bool ParserContainsSpacedScript(string text) =>
        text.EnumerateRunes().Any(rune => IsSpacedScriptScalar(rune.Value));

    private static bool IsSpacedScriptScalar(int v) =>
        v is >= 0x0900 and <= 0x097F      // Devanagari
        || v is >= 0x0980 and <= 0x09FF   // Bengali
        || v is >= 0x0600 and <= 0x06FF   // Arabic
        || v is >= 0x0750 and <= 0x077F   // Arabic Supplement
        || v is >= 0x08A0 and <= 0x08FF   // Arabic Extended-A
        || v is >= 0x0400 and <= 0x04FF   // Cyrillic
        || v is >= 0x0500 and <= 0x052F;  // Cyrillic Supplement

    private static string ParserAlignmentText(string text)
    {
        var builder = new StringBuilder();
        foreach (var ch in text.Normalize(NormalizationForm.FormC))
        {
            if (!char.IsWhiteSpace(ch)) builder.Append(ch);
        }
        return builder.ToString();
    }

    private static bool IsWhisperControlToken(string text)
    {
        var trimmed = text.Trim();
        return trimmed.StartsWith("[_", StringComparison.Ordinal) && trimmed.EndsWith(']');
    }

    private static bool ParserIsCjkOrHangulScalar(int value) =>
        value is >= 0x3040 and <= 0x30FF
            or >= 0x3400 and <= 0x4DBF
            or >= 0x4E00 and <= 0x9FFF
            or >= 0xAC00 and <= 0xD7A3;

    /// <summary>
    /// Rewrites word start/end using DTW token points: word i starts at its DTW point and ends at
    /// the next DTW point — capped at the word's own acoustic (offsets) duration, so a word before a
    /// pause does NOT absorb the silent gap (which produced lone multi-second single-morpheme cues).
    /// Tokens without a DTW point keep their offsets timing.
    /// </summary>
    private static List<AsrWord> ApplyDtwTiming(List<AsrWord> words, List<double?> dtwStarts)
    {
        const double minWordSeconds = 0.12;
        var result = new List<AsrWord>(words);
        for (var i = 0; i < words.Count; i++)
        {
            if (dtwStarts[i] is not { } start) continue;
            var offsetsDuration = Math.Max(minWordSeconds, words[i].EndSeconds - words[i].StartSeconds);
            var acousticEnd = start + offsetsDuration;
            var end = acousticEnd;
            for (var j = i + 1; j < words.Count; j++)
            {
                if (dtwStarts[j] is { } nextStart)
                {
                    if (nextStart > start) end = Math.Min(nextStart, acousticEnd);
                    break;
                }
            }
            if (end < start) end = start;
            result[i] = words[i] with { StartSeconds = start, EndSeconds = end };
        }
        return result;
    }

    private static bool TryTokenInterval(
        JsonElement element,
        bool offsetsAreMilliseconds,
        out double start,
        out double end)
    {
        if (TryInterval(element, offsetsAreMilliseconds, out start, out end))
        {
            return true;
        }
        if (TryGetObject(element, "offsets", out var offsets)
            && TryRepairedReversedInterval(offsets, offsetsAreMilliseconds, out start, out end))
        {
            return true;
        }
        if (TryGetObject(element, "timestamps", out var timestamps)
            && TryRepairedReversedInterval(timestamps, valuesAreMilliseconds: false, out start, out end))
        {
            return true;
        }
        start = 0;
        end = 0;
        return false;
    }

    private static bool TryRepairedReversedInterval(
        JsonElement element,
        bool valuesAreMilliseconds,
        out double start,
        out double end)
    {
        if (TrySeconds(element, "from", valuesAreMilliseconds, out start)
            && TrySeconds(element, "to", valuesAreMilliseconds, out end)
            && end < start)
        {
            end = start + 0.01;
            return true;
        }
        start = 0;
        end = 0;
        return false;
    }

    private static AsrWord? ParseSegmentWord(JsonElement segment)
    {
        if (!TryCleanText(segment, out var text)
            || !TryInterval(segment, offsetsAreMilliseconds: true, out var start, out var end))
        {
            return null;
        }
        return new AsrWord
        {
            Text = text,
            StartSeconds = start,
            EndSeconds = end,
            Probability = Number(segment, ["p", "probability", "confidence"]),
        };
    }

    private static bool TryInterval(
        JsonElement element,
        bool offsetsAreMilliseconds,
        out double start,
        out double end)
    {
        if (TryGetObject(element, "offsets", out var offsets)
            && TrySeconds(offsets, "from", offsetsAreMilliseconds, out start)
            && TrySeconds(offsets, "to", offsetsAreMilliseconds, out end)
            && end >= start)
        {
            return true;
        }
        if (TryGetObject(element, "timestamps", out var timestamps)
            && TrySeconds(timestamps, "from", valuesAreMilliseconds: false, out start)
            && TrySeconds(timestamps, "to", valuesAreMilliseconds: false, out end)
            && end >= start)
        {
            return true;
        }
        if ((TrySeconds(element, "start", valuesAreMilliseconds: false, out start)
                || TrySeconds(element, "startSeconds", valuesAreMilliseconds: false, out start))
            && (TrySeconds(element, "end", valuesAreMilliseconds: false, out end)
                || TrySeconds(element, "endSeconds", valuesAreMilliseconds: false, out end))
            && end >= start)
        {
            return true;
        }
        start = 0;
        end = 0;
        return false;
    }

    private static bool TrySeconds(JsonElement element, string property, bool valuesAreMilliseconds, out double seconds)
    {
        seconds = 0;
        if (!element.TryGetProperty(property, out var value)) return false;
        if (value.ValueKind == JsonValueKind.Number && value.TryGetDouble(out var number))
        {
            seconds = valuesAreMilliseconds ? number / 1000 : number;
            return true;
        }
        if (value.ValueKind == JsonValueKind.String && value.GetString() is { } text)
        {
            text = text.Trim();
            if (double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out number))
            {
                seconds = valuesAreMilliseconds ? number / 1000 : number;
                return true;
            }
            var components = text.Replace(',', '.').Split(':');
            if (components.Length == 3
                && double.TryParse(components[0], NumberStyles.Float, CultureInfo.InvariantCulture, out var hours)
                && double.TryParse(components[1], NumberStyles.Float, CultureInfo.InvariantCulture, out var minutes)
                && double.TryParse(components[2], NumberStyles.Float, CultureInfo.InvariantCulture, out var secs))
            {
                seconds = hours * 3600 + minutes * 60 + secs;
                return true;
            }
        }
        return false;
    }

    private static bool TryCleanText(JsonElement element, out string text)
    {
        text = "";
        if (!TryGetString(element, "text", out var value)) return false;
        text = value.Trim();
        return text.Length > 0;
    }

    private static double? Number(JsonElement element, IReadOnlyList<string> keys)
    {
        foreach (var key in keys)
        {
            if (!element.TryGetProperty(key, out var value)) continue;
            if (value.ValueKind == JsonValueKind.Number && value.TryGetDouble(out var number)) return number;
            if (value.ValueKind == JsonValueKind.String
                && double.TryParse(value.GetString(), NumberStyles.Float, CultureInfo.InvariantCulture, out number))
            {
                return number;
            }
        }
        return null;
    }

    private static bool TryGetArray(JsonElement element, string property, out JsonElement value) =>
        element.TryGetProperty(property, out value) && value.ValueKind == JsonValueKind.Array;

    private static bool TryGetObject(JsonElement element, string property, out JsonElement value) =>
        element.TryGetProperty(property, out value) && value.ValueKind == JsonValueKind.Object;

    private static bool TryGetString(JsonElement element, string property, out string value)
    {
        value = "";
        if (!element.TryGetProperty(property, out var child) || child.ValueKind != JsonValueKind.String) return false;
        value = child.GetString() ?? "";
        return true;
    }
}

public sealed class WhisperCppSpeechRecognizer : ISpeechRecognizer
{
    private readonly AsrRuntimeInfo _runtime;
    private readonly string _modelPath;
    private readonly string _outputDirectoryPath;
    private readonly AsrTranscriptCacheStore? _cacheStore;
    private readonly IAsrCommandRunner _commandRunner;
    private readonly Func<DateTimeOffset> _nowProvider;
    private readonly WhisperCppJsonTranscriptParser _parser;

    public WhisperCppSpeechRecognizer(
        AsrRuntimeInfo runtime,
        string modelPath,
        string outputDirectoryPath,
        AsrTranscriptCacheStore? cacheStore = null,
        IAsrCommandRunner? commandRunner = null,
        Func<DateTimeOffset>? nowProvider = null,
        WhisperCppJsonTranscriptParser? parser = null)
    {
        _runtime = runtime;
        _modelPath = modelPath;
        _outputDirectoryPath = outputDirectoryPath;
        _cacheStore = cacheStore;
        _commandRunner = commandRunner ?? new ProcessAsrCommandRunner();
        _nowProvider = nowProvider ?? (() => DateTimeOffset.UtcNow);
        _parser = parser ?? new WhisperCppJsonTranscriptParser();
    }

    public Task<AsrReadiness> ReadinessAsync(AsrRequest request, CancellationToken ct = default)
    {
        if (!IsExecutable(_runtime.ExecutablePath))
        {
            return Task.FromResult(new AsrReadiness
            {
                Status = AsrReadinessStatus.MissingRuntime,
                ModelId = request.ModelId,
                Message = "whisper.cpp runtime is missing.",
            });
        }
        if (!File.Exists(_modelPath))
        {
            return Task.FromResult(new AsrReadiness
            {
                Status = AsrReadinessStatus.MissingModel,
                ModelId = request.ModelId,
                Message = "Whisper model is not installed.",
            });
        }
        return Task.FromResult(new AsrReadiness
        {
            Status = AsrReadinessStatus.Ready,
            ModelId = request.ModelId,
            Message = "Local speech recognition is ready.",
        });
    }

    public async Task<AsrTranscript> TranscribeAsync(
        AsrRequest request,
        Action<AsrProgress> progress,
        TaskControlToken? control = null,
        CancellationToken ct = default)
    {
        ct.ThrowIfCancellationRequested();
        if (control is not null) await control.GateAsync(ct).ConfigureAwait(false);
        if (!IsExecutable(_runtime.ExecutablePath))
        {
            throw new WhisperCppRecognizerException(WhisperCppRecognizerError.MissingRuntime, path: _runtime.ExecutablePath);
        }
        if (!File.Exists(_modelPath))
        {
            throw new WhisperCppRecognizerException(WhisperCppRecognizerError.MissingModel, path: _modelPath);
        }

        progress(new AsrProgress { Phase = AsrProgressPhase.SpeechRecognition, CompletedUnits = 0, TotalUnits = 1 });
        var audioFingerprint = "sha256:" + AsrModelStore.Sha256Hex(request.AudioPath);
        if (request.CacheKey is { } cacheKey
            && _cacheStore?.CachedTranscript(
                cacheKey,
                audioFingerprint,
                request.ModelId,
                AsrBackendKind.WhisperCpp,
                request.LanguageCode) is { } cached)
        {
            progress(new AsrProgress { Phase = AsrProgressPhase.SpeechRecognition, CompletedUnits = 1, TotalUnits = 1 });
            return cached;
        }

        Directory.CreateDirectory(_outputDirectoryPath);
        var transcriptId = request.CacheKey ?? Guid.NewGuid().ToString("N");
        var outputBasePath = Path.Combine(_outputDirectoryPath, StableFileStem(transcriptId));

        async Task<(WhisperCppCommandPlan Plan, AsrCommandResult Result)> RunAsync(
            AsrRequest planRequest,
            bool disableGpu = false)
        {
            var plan = WhisperCppCommandPlan.Create(_runtime, _modelPath, planRequest, outputBasePath, disableGpu);
            var result = await _commandRunner.RunWhisperAsync(plan, control, line =>
            {
                if (WhisperCppProgressParser.Parse(line) is { } parsed)
                {
                    progress(parsed);
                }
            }, ct).ConfigureAwait(false);
            ct.ThrowIfCancellationRequested();
            return (plan, result);
        }

        var disableGpu = false;
        var (plan, result) = await RunAsync(request, disableGpu).ConfigureAwait(false);
        if (ShouldRetryWithoutGpu(result))
        {
            disableGpu = true;
            (plan, result) = await RunAsync(request, disableGpu).ConfigureAwait(false);
        }
        var usedDtw = request.WordTimestamps
            && request.DtwTokenTimestamps
            && WhisperDtwPreset.Preset(request.ModelId) is not null;
        if (usedDtw && (result.Status != 0 || !File.Exists(plan.OutputJsonPath)))
        {
            // Fail-safe: if a model build rejects -dtw/-nfa, retry once without it so a DTW
            // incompatibility degrades to plain offsets instead of failing the whole run.
            (plan, result) = await RunAsync(request with { DtwTokenTimestamps = false }, disableGpu).ConfigureAwait(false);
        }

        if (control?.IsCancelled == true) throw MoongateException.Cancelled();
        if (result.Status != 0)
        {
            throw new WhisperCppRecognizerException(
                WhisperCppRecognizerError.ProcessFailed,
                status: result.Status,
                stderrTail: result.StderrTail);
        }
        if (!File.Exists(plan.OutputJsonPath))
        {
            throw new WhisperCppRecognizerException(
                WhisperCppRecognizerError.MissingTranscriptJson,
                path: plan.OutputJsonPath);
        }

        var transcript = _parser.Parse(File.ReadAllBytes(plan.OutputJsonPath), request, transcriptId, _nowProvider());
        if (request.CacheKey is { } writeCacheKey)
        {
            _cacheStore?.Write(transcript, writeCacheKey, audioFingerprint, request.LanguageCode);
        }
        progress(new AsrProgress { Phase = AsrProgressPhase.SpeechRecognition, CompletedUnits = 1, TotalUnits = 1 });
        return transcript;
    }

    private static bool ShouldRetryWithoutGpu(AsrCommandResult result)
    {
        if (result.Status == 0) return false;
        var stderr = result.StderrTail.ToLowerInvariant();
        return stderr.Contains("ggml_metal", StringComparison.Ordinal)
            || stderr.Contains("metal buffer", StringComparison.Ordinal)
            || stderr.Contains("failed to allocate buffer", StringComparison.Ordinal);
    }

    private static bool IsExecutable(string path)
    {
        if (!File.Exists(path)) return false;
        if (OperatingSystem.IsWindows()) return true;
        try
        {
            var mode = File.GetUnixFileMode(path);
            return (mode & (UnixFileMode.UserExecute | UnixFileMode.GroupExecute | UnixFileMode.OtherExecute)) != 0;
        }
        catch
        {
            return false;
        }
    }

    private static string StableFileStem(string value) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value))).ToLowerInvariant();
}

public sealed class AsrTranscriptCacheStore
{
    public string DirectoryPath { get; }

    public AsrTranscriptCacheStore(string directoryPath)
    {
        DirectoryPath = directoryPath;
    }

    public string EntryPath(string cacheKey) =>
        Path.Combine(DirectoryPath, StableFileStem(cacheKey) + ".entry.json");

    public string TranscriptPath(string cacheKey) =>
        Path.Combine(DirectoryPath, StableFileStem(cacheKey) + ".transcript.json");

    public AsrTranscriptCacheEntry Write(
        AsrTranscript transcript,
        string cacheKey,
        string audioFingerprint,
        string? languageCode = null,
        DateTimeOffset? createdAt = null)
    {
        Directory.CreateDirectory(DirectoryPath);
        var transcriptPath = TranscriptPath(cacheKey);
        var entryPath = EntryPath(cacheKey);
        WriteAtomically(JsonSerializer.SerializeToUtf8Bytes(transcript, AsrJson.Options), transcriptPath);
        var entry = new AsrTranscriptCacheEntry
        {
            CacheKey = cacheKey,
            AudioFingerprint = audioFingerprint,
            ModelId = transcript.SourceModelId,
            BackendKind = transcript.BackendKind,
            LanguageCode = NormalizeCacheLanguage(languageCode) ?? NormalizeCacheLanguage(transcript.LanguageCode),
            TranscriptPath = transcriptPath,
            CreatedAt = createdAt ?? DateTimeOffset.UtcNow,
        };
        WriteAtomically(JsonSerializer.SerializeToUtf8Bytes(entry, AsrJson.Options), entryPath);
        return entry;
    }

    public AsrTranscriptCacheEntry? ReadEntry(string cacheKey)
    {
        var path = EntryPath(cacheKey);
        return File.Exists(path)
            ? JsonSerializer.Deserialize<AsrTranscriptCacheEntry>(File.ReadAllBytes(path), AsrJson.Options)
            : null;
    }

    public AsrTranscript ReadTranscript(AsrTranscriptCacheEntry entry) =>
        JsonSerializer.Deserialize<AsrTranscript>(File.ReadAllBytes(entry.TranscriptPath), AsrJson.Options)
            ?? throw new InvalidDataException("ASR transcript cache entry could not be decoded.");

    public AsrTranscript? CachedTranscript(
        string cacheKey,
        string audioFingerprint,
        string modelId,
        AsrBackendKind backendKind,
        string? languageCode)
    {
        var entry = ReadEntry(cacheKey);
        var requestedLanguageCode = NormalizeCacheLanguage(languageCode);
        if (entry is null
            || entry.AudioFingerprint != audioFingerprint
            || entry.ModelId != modelId
            || entry.BackendKind != backendKind
            || (requestedLanguageCode is not null && NormalizeCacheLanguage(entry.LanguageCode) != requestedLanguageCode)
            || !File.Exists(entry.TranscriptPath))
        {
            return null;
        }

        return ReadTranscript(entry);
    }

    private static void WriteAtomically(byte[] data, string path)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path) ?? ".");
        var temp = Path.Combine(
            Path.GetDirectoryName(path) ?? ".",
            "." + Path.GetFileName(path) + "." + Guid.NewGuid().ToString("N") + ".tmp");
        try
        {
            File.WriteAllBytes(temp, data);
            File.Move(temp, path, overwrite: true);
        }
        finally
        {
            if (File.Exists(temp)) File.Delete(temp);
        }
    }

    private static string StableFileStem(string value) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value))).ToLowerInvariant();

    private static string? NormalizeCacheLanguage(string? languageCode)
    {
        var trimmed = languageCode?.Trim().ToLowerInvariant();
        return string.IsNullOrEmpty(trimmed) || trimmed == "auto" ? null : trimmed;
    }
}

public sealed record AsrRuntimeInfo
{
    public string Provider { get; init; } = "whisper.cpp";
    public required string ExecutablePath { get; init; }
}

public sealed class AsrRuntimeLocator
{
    public const string RuntimeManifestFileName = "asr-runtime-manifest.json";

    public static string CurrentPlatform
    {
        get
        {
            if (OperatingSystem.IsWindows()) return "windows";
            if (OperatingSystem.IsMacOS()) return "macos";
            if (OperatingSystem.IsLinux()) return "linux";
            return "unknown";
        }
    }

    public static string CurrentArchitecture =>
        RuntimeInformation.ProcessArchitecture switch
        {
            Architecture.X64 => "x64",
            Architecture.Arm64 => "arm64",
            Architecture.X86 => "x86",
            Architecture.Arm => "arm",
            var architecture => architecture.ToString().ToLowerInvariant(),
        };

    private readonly IReadOnlyList<string> _candidateNames;
    private readonly IReadOnlyList<string> _extraSearchPaths;
    private readonly string? _environmentPath;
    private readonly string _runtimeManifestFileName;

    public AsrRuntimeLocator(
        IReadOnlyList<string>? candidateNames = null,
        IReadOnlyList<string>? extraSearchPaths = null,
        string? environmentPath = null,
        string runtimeManifestFileName = RuntimeManifestFileName)
    {
        _candidateNames = candidateNames ?? ["whisper-cli.exe", "whisper-cli"];
        _extraSearchPaths = extraSearchPaths ?? [];
        _environmentPath = environmentPath ?? Environment.GetEnvironmentVariable("PATH");
        _runtimeManifestFileName = runtimeManifestFileName;
    }

    public AsrRuntimeInfo? Locate()
    {
        var manifestRoots = ManifestRootsWithFile().ToArray();
        foreach (var root in manifestRoots)
        {
            var runtime = RuntimeFromManifest(root);
            if (runtime is not null) return runtime;
        }
        foreach (var path in SearchCandidates())
        {
            if (IsInsideAny(path, manifestRoots)) continue;
            if (IsExecutable(path)) return new AsrRuntimeInfo { ExecutablePath = path };
        }
        return null;
    }

    private IEnumerable<string> ManifestRootsWithFile()
    {
        var seen = new HashSet<string>(PathComparer);
        foreach (var path in _extraSearchPaths)
        {
            if (!Directory.Exists(path)) continue;
            var root = NormalizeDirectoryPath(path);
            if (!File.Exists(Path.Combine(root, _runtimeManifestFileName))) continue;
            if (seen.Add(root)) yield return root;
        }
    }

    private AsrRuntimeInfo? RuntimeFromManifest(string directory)
    {
        try
        {
            var manifest = AsrRuntimeBundleManifest.FromJson(
                File.ReadAllText(Path.Combine(directory, _runtimeManifestFileName)));
            foreach (var runtime in manifest.Runtimes.Where(MatchesCurrentRuntime))
            {
                try
                {
                    return runtime.VerifiedRuntimeInfoUnder(directory);
                }
                catch (AsrRuntimeBundleManifestException)
                {
                    // Keep searching matching entries, but do not fall back to bare files from this bundle root.
                }
            }
        }
        catch (Exception error) when (
            error is IOException
                or UnauthorizedAccessException
                or JsonException
                or AsrRuntimeBundleManifestException)
        {
            return null;
        }
        return null;
    }

    private IEnumerable<string> SearchCandidates()
    {
        foreach (var path in _extraSearchPaths)
        {
            if (Directory.Exists(path))
            {
                foreach (var name in _candidateNames) yield return Path.Combine(path, name);
            }
            else
            {
                yield return path;
            }
        }

        foreach (var dir in (_environmentPath ?? "").Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
        {
            foreach (var name in _candidateNames) yield return Path.Combine(dir, name);
        }
    }

    private static bool IsExecutable(string path)
    {
        if (!IsWhisperCliCandidate(path)) return false;
        if (!File.Exists(path)) return false;
        if (OperatingSystem.IsWindows()) return true;
        try
        {
            var mode = File.GetUnixFileMode(path);
            return (mode & (UnixFileMode.UserExecute | UnixFileMode.GroupExecute | UnixFileMode.OtherExecute)) != 0;
        }
        catch
        {
            return false;
        }
    }

    private static bool IsWhisperCliCandidate(string path)
    {
        var fileName = Path.GetFileName(path);
        return string.Equals(fileName, "whisper-cli", StringComparison.OrdinalIgnoreCase)
            || string.Equals(fileName, "whisper-cli.exe", StringComparison.OrdinalIgnoreCase);
    }

    private static bool MatchesCurrentRuntime(AsrRuntimeBundleInfo runtime) =>
        string.Equals(runtime.Platform, CurrentPlatform, StringComparison.OrdinalIgnoreCase)
            && string.Equals(runtime.Architecture, CurrentArchitecture, StringComparison.OrdinalIgnoreCase);

    private static bool IsInsideAny(string path, IReadOnlyList<string> roots) =>
        roots.Any(root => IsInside(path, root));

    private static bool IsInside(string path, string root)
    {
        var normalizedPath = Path.GetFullPath(path);
        var normalizedRoot = NormalizeDirectoryPath(root);
        if (string.Equals(normalizedPath, normalizedRoot, PathComparison)) return true;
        return normalizedPath.StartsWith(
            normalizedRoot + Path.DirectorySeparatorChar,
            PathComparison);
    }

    private static string NormalizeDirectoryPath(string path)
    {
        var fullPath = Path.GetFullPath(path);
        var root = Path.GetPathRoot(fullPath);
        if (string.Equals(fullPath, root, PathComparison)) return fullPath;
        return fullPath.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
    }

    private static StringComparison PathComparison =>
        OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;

    private static StringComparer PathComparer =>
        OperatingSystem.IsWindows() ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal;
}

public enum AsrModelInstallState
{
    NotInstalled,
    Installed,
    BadHash,
    InsufficientDiskSpace,
}

public enum AsrModelStoreError
{
    InvalidModelFileName,
}

public sealed class AsrModelStoreException(AsrModelStoreError reason, string modelFileName)
    : Exception(reason.ToString())
{
    public AsrModelStoreError Reason { get; } = reason;
    public string ModelFileName { get; } = modelFileName;
}

public sealed record AsrModelStatus
{
    public required string ModelId { get; init; }
    public required AsrModelInstallState State { get; init; }
    public required string InstalledPath { get; init; }
    public required string ExpectedSha256 { get; init; }
    public string? ActualSha256 { get; init; }
    public required long SizeBytes { get; init; }
    public long? AvailableBytes { get; init; }
    public bool IsInstalled => State == AsrModelInstallState.Installed;
}

public sealed class AsrModelStore
{
    private readonly Func<string, long?> _availableBytesProvider;

    public string DirectoryPath { get; }

    public AsrModelStore(string directoryPath, Func<string, long?>? availableBytesProvider = null)
    {
        DirectoryPath = directoryPath;
        _availableBytesProvider = availableBytesProvider ?? DefaultAvailableBytes;
    }

    public string InstalledPath(AsrModelInfo model) => Path.Combine(DirectoryPath, model.FileName);

    public string StagedPath(AsrModelInfo model) => Path.Combine(DirectoryPath, "." + model.FileName + ".download");

    public AsrModelStatus Status(AsrModelInfo model)
    {
        Directory.CreateDirectory(DirectoryPath);
        ValidateFileName(model.FileName);
        var path = InstalledPath(model);
        var availableBytes = _availableBytesProvider(DirectoryPath);
        if (!File.Exists(path))
        {
            var state = availableBytes is { } available && available < model.SizeBytes
                ? AsrModelInstallState.InsufficientDiskSpace
                : AsrModelInstallState.NotInstalled;
            return new AsrModelStatus
            {
                ModelId = model.Id,
                State = state,
                InstalledPath = path,
                ExpectedSha256 = model.Sha256,
                SizeBytes = model.SizeBytes,
                AvailableBytes = availableBytes,
            };
        }

        var actual = Sha256Hex(path);
        return new AsrModelStatus
        {
            ModelId = model.Id,
            State = string.Equals(actual, model.Sha256, StringComparison.OrdinalIgnoreCase)
                ? AsrModelInstallState.Installed
                : AsrModelInstallState.BadHash,
            InstalledPath = path,
            ExpectedSha256 = model.Sha256,
            ActualSha256 = actual,
            SizeBytes = model.SizeBytes,
            AvailableBytes = availableBytes,
        };
    }

    public void Delete(AsrModelInfo model)
    {
        ValidateFileName(model.FileName);
        foreach (var path in new[] { InstalledPath(model), StagedPath(model) })
        {
            if (File.Exists(path)) File.Delete(path);
        }
    }

    public static string Sha256Hex(string path)
    {
        using var stream = File.OpenRead(path);
        return Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant();
    }

    private static long? DefaultAvailableBytes(string directoryPath)
    {
        var root = Path.GetPathRoot(Path.GetFullPath(directoryPath));
        if (string.IsNullOrWhiteSpace(root)) return null;
        try
        {
            return new DriveInfo(root).AvailableFreeSpace;
        }
        catch
        {
            return null;
        }
    }

    private static void ValidateFileName(string fileName)
    {
        if (string.IsNullOrEmpty(fileName)
            || fileName is "." or ".."
            || fileName != Path.GetFileName(fileName)
            || fileName.Contains('/')
            || fileName.Contains('\\'))
        {
            throw new AsrModelStoreException(AsrModelStoreError.InvalidModelFileName, fileName);
        }
    }
}

public enum AsrModelCatalogError
{
    UnknownModelId,
}

public enum AsrModelInstallerError
{
    UnknownModelId,
    InsufficientDiskSpace,
    MissingDownloadedFile,
    HashMismatch,
}

public sealed class AsrModelCatalogException(AsrModelCatalogError reason, string modelId)
    : Exception(reason.ToString())
{
    public AsrModelCatalogError Reason { get; } = reason;
    public string ModelId { get; } = modelId;
}

public sealed class AsrModelInstallerException(
    AsrModelInstallerError reason,
    string modelId,
    string? path = null,
    string? expectedSha256 = null,
    string? actualSha256 = null,
    long? availableBytes = null,
    long? requiredBytes = null)
    : Exception(MessageFor(reason, modelId, path, expectedSha256, actualSha256, availableBytes, requiredBytes))
{
    public AsrModelInstallerError Reason { get; } = reason;
    public string ModelId { get; } = modelId;
    public string? Path { get; } = path;
    public string? ExpectedSha256 { get; } = expectedSha256;
    public string? ActualSha256 { get; } = actualSha256;
    public long? AvailableBytes { get; } = availableBytes;
    public long? RequiredBytes { get; } = requiredBytes;

    private static string MessageFor(
        AsrModelInstallerError reason,
        string modelId,
        string? path,
        string? expectedSha256,
        string? actualSha256,
        long? availableBytes,
        long? requiredBytes) =>
        reason switch
        {
            AsrModelInstallerError.UnknownModelId =>
                $"Unknown local ASR model ID: {modelId}.",
            AsrModelInstallerError.InsufficientDiskSpace =>
                $"Not enough disk space to install local ASR model {modelId}. Required: {FormatBytes(requiredBytes)}; available: {FormatBytes(availableBytes)}.",
            AsrModelInstallerError.MissingDownloadedFile =>
                $"Local ASR model download finished, but no file was found at {path ?? "(unknown path)"}.",
            AsrModelInstallerError.HashMismatch =>
                $"Local ASR model {modelId} failed SHA-256 verification. Expected {expectedSha256 ?? "(unknown)"}, got {actualSha256 ?? "(unknown)"}.",
            _ => reason.ToString(),
        };

    private static string FormatBytes(long? bytes) =>
        bytes is { } value ? $"{value:N0} bytes" : "unknown";
}

public interface IAsrModelDownloadClient
{
    Task DownloadModelAsync(
        AsrModelInfo model,
        string destinationPath,
        Action<AsrProgress> progress,
        CancellationToken ct = default);
}

public sealed class HttpAsrModelDownloadClient : IAsrModelDownloadClient, IDisposable
{
    private readonly HttpClient _client;
    private readonly bool _ownsClient;

    public HttpAsrModelDownloadClient(HttpClient? client = null)
    {
        _client = client ?? new HttpClient();
        _ownsClient = client is null;
    }

    public async Task DownloadModelAsync(
        AsrModelInfo model,
        string destinationPath,
        Action<AsrProgress> progress,
        CancellationToken ct = default)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(destinationPath) ?? ".");
        if (File.Exists(destinationPath)) File.Delete(destinationPath);

        using var response = await _client.GetAsync(
            model.DownloadUrl,
            HttpCompletionOption.ResponseHeadersRead,
            ct).ConfigureAwait(false);
        response.EnsureSuccessStatusCode();

        var totalBytes = response.Content.Headers.ContentLength ?? model.SizeBytes;
        progress(new AsrProgress
        {
            Phase = AsrProgressPhase.ModelDownload,
            CompletedUnits = 0,
            TotalUnits = totalBytes,
        });

        await using var input = await response.Content.ReadAsStreamAsync(ct).ConfigureAwait(false);
        await using var output = File.Create(destinationPath);
        var buffer = new byte[64 * 1024];
        long receivedBytes = 0;
        while (true)
        {
            var read = await input.ReadAsync(buffer.AsMemory(0, buffer.Length), ct).ConfigureAwait(false);
            if (read <= 0) break;
            await output.WriteAsync(buffer.AsMemory(0, read), ct).ConfigureAwait(false);
            receivedBytes += read;
            progress(new AsrProgress
            {
                Phase = AsrProgressPhase.ModelDownload,
                CompletedUnits = receivedBytes,
                TotalUnits = totalBytes,
            });
        }
    }

    public void Dispose()
    {
        if (_ownsClient) _client.Dispose();
    }
}

public sealed record AsrModelCatalogEntry
{
    public required AsrModelInfo Model { get; init; }
    public required AsrModelStatus Status { get; init; }

    public string Id => Model.Id;
    public string DisplayName => Model.DisplayName;
    public string FileName => Model.FileName;
    public string DownloadUrl => Model.DownloadUrl;
    public long SizeBytes => Model.SizeBytes;
    public string Sha256 => Model.Sha256;
    public int MemoryRequiredMb => Model.MemoryRequiredMb;
    public string License => Model.License;
    public string SourceDescription => Model.SourceDescription;
    public AsrModelInstallState InstallState => Status.State;
    public string InstalledPath => Status.InstalledPath;
    public bool IsInstalled => Status.IsInstalled;
    public bool NeedsUserDownloadConsent => !Status.IsInstalled;
}

public sealed class AsrModelCatalog
{
    private readonly IReadOnlyDictionary<string, AsrModelInfo> _modelsById;
    private readonly AsrModelStore _store;

    public AsrModelCatalog(AsrModelManifest manifest, AsrModelStore store)
    {
        _store = store;
        Entries = manifest.Models
            .Select(model => new AsrModelCatalogEntry
            {
                Model = model,
                Status = store.Status(model),
            })
            .ToList();
        _modelsById = manifest.Models.ToDictionary(model => model.Id, StringComparer.Ordinal);
    }

    public IReadOnlyList<AsrModelCatalogEntry> Entries { get; }

    public AsrModelCatalogEntry? Entry(string id) =>
        Entries.FirstOrDefault(entry => string.Equals(entry.Id, id, StringComparison.Ordinal));

    public AsrModelInfo DeleteModel(string id)
    {
        if (!_modelsById.TryGetValue(id, out var model))
        {
            throw new AsrModelCatalogException(AsrModelCatalogError.UnknownModelId, id);
        }
        _store.Delete(model);
        return model;
    }
}

public sealed class AsrModelInstaller
{
    private readonly IReadOnlyDictionary<string, AsrModelInfo> _modelsById;
    private readonly AsrModelStore _store;
    private readonly IAsrModelDownloadClient _downloader;

    public AsrModelInstaller(
        AsrModelManifest manifest,
        AsrModelStore store,
        IAsrModelDownloadClient? downloader = null)
    {
        _modelsById = manifest.Models.ToDictionary(model => model.Id, StringComparer.Ordinal);
        _store = store;
        _downloader = downloader ?? new HttpAsrModelDownloadClient();
    }

    public async Task<AsrModelStatus> InstallModelAsync(
        string id,
        Action<AsrProgress> progress,
        CancellationToken ct = default)
    {
        if (!_modelsById.TryGetValue(id, out var model))
        {
            throw new AsrModelInstallerException(AsrModelInstallerError.UnknownModelId, id);
        }

        var currentStatus = _store.Status(model);
        if (currentStatus.State == AsrModelInstallState.Installed)
        {
            progress(new AsrProgress
            {
                Phase = AsrProgressPhase.ModelDownload,
                CompletedUnits = model.SizeBytes,
                TotalUnits = model.SizeBytes,
            });
            return currentStatus;
        }
        if (currentStatus.State == AsrModelInstallState.InsufficientDiskSpace)
        {
            throw new AsrModelInstallerException(
                AsrModelInstallerError.InsufficientDiskSpace,
                model.Id,
                availableBytes: currentStatus.AvailableBytes,
                requiredBytes: model.SizeBytes);
        }

        var stagedPath = _store.StagedPath(model);
        var installedPath = _store.InstalledPath(model);
        if (File.Exists(stagedPath)) File.Delete(stagedPath);

        try
        {
            await _downloader.DownloadModelAsync(model, stagedPath, progress, ct).ConfigureAwait(false);
            if (!File.Exists(stagedPath))
            {
                throw new AsrModelInstallerException(
                    AsrModelInstallerError.MissingDownloadedFile,
                    model.Id,
                    path: stagedPath);
            }

            var actualSha256 = AsrModelStore.Sha256Hex(stagedPath);
            if (!string.Equals(actualSha256, model.Sha256, StringComparison.OrdinalIgnoreCase))
            {
                if (File.Exists(stagedPath)) File.Delete(stagedPath);
                throw new AsrModelInstallerException(
                    AsrModelInstallerError.HashMismatch,
                    model.Id,
                    path: stagedPath,
                    expectedSha256: model.Sha256,
                    actualSha256: actualSha256);
            }

            if (File.Exists(installedPath)) File.Delete(installedPath);
            File.Move(stagedPath, installedPath, overwrite: true);
            progress(new AsrProgress
            {
                Phase = AsrProgressPhase.ModelDownload,
                CompletedUnits = model.SizeBytes,
                TotalUnits = model.SizeBytes,
            });
            return _store.Status(model);
        }
        catch
        {
            if (File.Exists(stagedPath)) File.Delete(stagedPath);
            throw;
        }
    }
}
