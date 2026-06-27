using System.Net.Http;
using System.Text;
using System.Text.Json;

namespace Moongate.Core;

public readonly record struct GeneratedCloudAsrSource(string Url);

public static class CloudAsrModelCapabilities
{
    public static bool SupportsDirectSubtitleOutput(string modelId) =>
        string.Equals(Normalize(modelId), "whisper-1", StringComparison.OrdinalIgnoreCase);

    public static bool RequiresAlignment(string modelId)
    {
        var normalized = Normalize(modelId);
        return normalized.Length > 0 && !SupportsDirectSubtitleOutput(normalized);
    }

    private static string Normalize(string modelId) => (modelId ?? "").Trim();
}

public interface ICloudAsrSubtitleGenerator
{
    Task<GeneratedCloudAsrSource> GenerateSourceSubtitleAsync(
        string videoFile,
        string languageCode,
        TaskControlToken? control,
        CancellationToken ct = default);
}

public sealed class OpenAICloudAsrSubtitleGenerator : ICloudAsrSubtitleGenerator
{
    private readonly HttpClient _httpClient;
    private readonly Uri _endpoint;
    private readonly string _authToken;
    private readonly string _modelId;

    public OpenAICloudAsrSubtitleGenerator(
        string baseUrl,
        string authToken,
        string modelId,
        HttpClient? httpClient = null)
    {
        _endpoint = AudioTranscriptionsEndpoint(baseUrl);
        _authToken = NormalizeAuthToken(authToken);
        _modelId = modelId.Trim();
        _httpClient = httpClient ?? new HttpClient();
    }

    public async Task<GeneratedCloudAsrSource> GenerateSourceSubtitleAsync(
        string videoFile,
        string languageCode,
        TaskControlToken? control,
        CancellationToken ct = default)
    {
        ct.ThrowIfCancellationRequested();
        if (control is not null) await control.GateAsync(ct).ConfigureAwait(false);
        if (!File.Exists(videoFile))
        {
            throw MoongateException.DownloadFailed(L10n.T(
                "找不到可用于云端识别的视频文件。",
                "找不到可用於雲端識別的影片檔。",
                "Could not find a video file for cloud recognition."));
        }

        var normalizedLanguage = string.IsNullOrWhiteSpace(languageCode) ? "auto" : languageCode.Trim();
        var recognitionProfile = AsrPromptBuilder.RecognitionProfile(videoFile, normalizedLanguage);
        var prompt = AsrPromptBuilder.DefaultPrompt(videoFile, normalizedLanguage, recognitionProfile);
        var srt = await TranscribeToSrtAsync(videoFile, normalizedLanguage, prompt, ct).ConfigureAwait(false);
        if (control is not null) await control.GateAsync(ct).ConfigureAwait(false);

        var output = UniqueOutputPath(videoFile, normalizedLanguage);
        Directory.CreateDirectory(Path.GetDirectoryName(output) ?? ".");
        await File.WriteAllTextAsync(output, srt, Encoding.UTF8, ct).ConfigureAwait(false);
        return new GeneratedCloudAsrSource(output);
    }

    private async Task<string> TranscribeToSrtAsync(
        string videoFile,
        string languageCode,
        string? prompt,
        CancellationToken ct)
    {
        if (!CloudAsrModelCapabilities.SupportsDirectSubtitleOutput(_modelId))
        {
            throw MoongateException.DownloadFailed(L10n.T(
                "当前云端精准识别只启用可直接返回 SRT 的模型，请先使用 whisper-1。",
                "目前雲端精準識別只啟用可直接回傳 SRT 的模型，請先使用 whisper-1。",
                "Cloud precise recognition currently only enables models that can return SRT directly. Use whisper-1."));
        }
        if (string.IsNullOrWhiteSpace(_authToken))
        {
            throw MoongateException.DownloadFailed(L10n.T(
                "请先配置云端精准识别 API Key。",
                "請先設定雲端精準識別 API Key。",
                "Configure the cloud precise recognition API key first."));
        }

        using var request = new HttpRequestMessage(HttpMethod.Post, _endpoint);
        request.Headers.TryAddWithoutValidation("Authorization", "Bearer " + _authToken);
        using var form = new MultipartFormDataContent();
        form.Add(new StringContent(_modelId, Encoding.UTF8), "model");
        form.Add(new StringContent("srt", Encoding.UTF8), "response_format");
        if (!string.Equals(languageCode, "auto", StringComparison.OrdinalIgnoreCase))
        {
            form.Add(new StringContent(languageCode, Encoding.UTF8), "language");
        }
        if (!string.IsNullOrWhiteSpace(prompt))
        {
            form.Add(new StringContent(prompt, Encoding.UTF8), "prompt");
        }
        await using var stream = File.OpenRead(videoFile);
        form.Add(new StreamContent(stream), "file", Path.GetFileName(videoFile));
        request.Content = form;

        using var response = await _httpClient.SendAsync(request, ct).ConfigureAwait(false);
        var body = await response.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
        if (!response.IsSuccessStatusCode)
        {
            throw MoongateException.DownloadFailed(L10n.T(
                $"云端精准识别请求失败（HTTP {(int)response.StatusCode}）：{SafeErrorBody(body)}",
                $"雲端精準識別請求失敗（HTTP {(int)response.StatusCode}）：{SafeErrorBody(body)}",
                $"Cloud precise recognition failed (HTTP {(int)response.StatusCode}): {SafeErrorBody(body)}"));
        }
        if (string.IsNullOrWhiteSpace(body))
        {
            throw MoongateException.DownloadFailed(L10n.T(
                "云端精准识别没有返回字幕内容。",
                "雲端精準識別沒有回傳字幕內容。",
                "Cloud precise recognition returned no subtitle content."));
        }
        return body;
    }

    public async Task<string> TranscribeToAlignedSrtAsync(
        string videoFile,
        string languageCode,
        string guideSubtitleFile,
        string outputFile,
        string? prompt,
        CancellationToken ct = default)
    {
        var transcript = await TranscribeToJsonTextAsync(videoFile, languageCode, prompt, ct).ConfigureAwait(false);
        var guideRaw = await File.ReadAllTextAsync(guideSubtitleFile, ct).ConfigureAwait(false);
        var guide = SrtTools.CleanCues(
            Path.GetExtension(guideSubtitleFile).Equals(".vtt", StringComparison.OrdinalIgnoreCase)
                ? SrtTools.ParseVtt(guideRaw)
                : SrtTools.ParseSrt(guideRaw));
        var aligned = CloudTranscriptAligner.Align(transcript, guide);
        Directory.CreateDirectory(Path.GetDirectoryName(outputFile) ?? ".");
        await File.WriteAllTextAsync(outputFile, SrtTools.SerializeSrt(aligned), Encoding.UTF8, ct).ConfigureAwait(false);
        return outputFile;
    }

    private async Task<string> TranscribeToJsonTextAsync(
        string videoFile,
        string languageCode,
        string? prompt,
        CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(_authToken))
        {
            throw MoongateException.DownloadFailed(L10n.T(
                "请先配置云端精准识别 API Key。",
                "請先設定雲端精準識別 API Key。",
                "Configure the cloud precise recognition API key first."));
        }

        using var request = new HttpRequestMessage(HttpMethod.Post, _endpoint);
        request.Headers.TryAddWithoutValidation("Authorization", "Bearer " + _authToken);
        using var form = new MultipartFormDataContent();
        form.Add(new StringContent(_modelId, Encoding.UTF8), "model");
        form.Add(new StringContent("json", Encoding.UTF8), "response_format");
        if (!string.Equals(languageCode, "auto", StringComparison.OrdinalIgnoreCase))
        {
            form.Add(new StringContent(languageCode, Encoding.UTF8), "language");
        }
        if (!string.IsNullOrWhiteSpace(prompt))
        {
            form.Add(new StringContent(prompt, Encoding.UTF8), "prompt");
        }
        await using var stream = File.OpenRead(videoFile);
        form.Add(new StreamContent(stream), "file", Path.GetFileName(videoFile));
        request.Content = form;

        using var response = await _httpClient.SendAsync(request, ct).ConfigureAwait(false);
        var body = await response.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
        if (!response.IsSuccessStatusCode)
        {
            throw MoongateException.DownloadFailed(L10n.T(
                $"云端精准识别请求失败（HTTP {(int)response.StatusCode}）：{SafeErrorBody(body)}",
                $"雲端精準識別請求失敗（HTTP {(int)response.StatusCode}）：{SafeErrorBody(body)}",
                $"Cloud precise recognition failed (HTTP {(int)response.StatusCode}): {SafeErrorBody(body)}"));
        }

        using var document = JsonDocument.Parse(body);
        if (!document.RootElement.TryGetProperty("text", out var textElement))
        {
            throw MoongateException.DownloadFailed(L10n.T(
                "云端精准识别没有返回可对齐的文本。",
                "雲端精準識別沒有回傳可對齊的文字。",
                "Cloud precise recognition returned no alignable text."));
        }
        var text = textElement.GetString()?.Trim() ?? "";
        if (text.Length == 0)
        {
            throw MoongateException.DownloadFailed(L10n.T(
                "云端精准识别返回了空文本。",
                "雲端精準識別回傳了空文字。",
                "Cloud precise recognition returned empty text."));
        }
        return text;
    }

    private static Uri AudioTranscriptionsEndpoint(string baseUrl)
    {
        var trimmed = (baseUrl ?? "").Trim().TrimEnd('/');
        if (trimmed.Length == 0) throw new UriFormatException("Cloud ASR base URL is empty.");
        if (!trimmed.EndsWith("/v1", StringComparison.OrdinalIgnoreCase))
        {
            trimmed += "/v1";
        }
        return new Uri(trimmed + "/audio/transcriptions", UriKind.Absolute);
    }

    private static string NormalizeAuthToken(string token)
    {
        var trimmed = token.Trim();
        const string bearer = "Bearer ";
        return trimmed.StartsWith(bearer, StringComparison.OrdinalIgnoreCase)
            ? trimmed[bearer.Length..].Trim()
            : trimmed;
    }

    private static string UniqueOutputPath(string videoFile, string languageCode)
    {
        var directory = Path.GetDirectoryName(videoFile) ?? ".";
        var stem = Path.GetFileNameWithoutExtension(videoFile);
        var lang = SafeLanguageForFile(languageCode);
        var basePath = Path.Combine(directory, $"{stem}.cloud-asr.{lang}.srt");
        if (!File.Exists(basePath)) return basePath;
        for (var index = 2; ; index++)
        {
            var candidate = Path.Combine(directory, $"{stem}.cloud-asr.{lang}-{index}.srt");
            if (!File.Exists(candidate)) return candidate;
        }
    }

    private static string SafeLanguageForFile(string languageCode)
    {
        var chars = languageCode
            .Trim()
            .Select(ch => char.IsLetterOrDigit(ch) || ch is '-' or '_' ? ch : '-')
            .ToArray();
        var value = new string(chars).Trim('-');
        return value.Length == 0 ? "auto" : value;
    }

    private static string SafeErrorBody(string body)
    {
        var compact = body.Replace('\r', ' ').Replace('\n', ' ').Trim();
        return compact.Length <= 240 ? compact : compact[..240] + "...";
    }
}

public static class CloudTranscriptAligner
{
    public static IReadOnlyList<SubtitleCue> Align(string transcript, IReadOnlyList<SubtitleCue> guideCues)
    {
        var normalizedTranscript = CollapseWhitespace(transcript);
        if (normalizedTranscript.Length == 0)
        {
            throw MoongateException.DownloadFailed(L10n.T(
                "云端精准识别返回了空文本。",
                "雲端精準識別回傳了空文字。",
                "Cloud precise recognition returned empty text."));
        }

        var guide = guideCues
            .Where(cue => !string.IsNullOrWhiteSpace(cue.Text))
            .ToList();
        if (guide.Count == 0)
        {
            throw MoongateException.DownloadFailed(L10n.T(
                "缺少可用于对齐云端文本的时间轴字幕。",
                "缺少可用於對齊雲端文字的時間軸字幕。",
                "Missing timed subtitle guide for cloud transcript alignment."));
        }

        var characterMode = PrefersCharacterUnits(normalizedTranscript);
        var units = TranscriptUnits(normalizedTranscript, characterMode).ToList();
        if (units.Count == 0)
        {
            throw MoongateException.DownloadFailed(L10n.T(
                "云端精准识别返回了空文本。",
                "雲端精準識別回傳了空文字。",
                "Cloud precise recognition returned empty text."));
        }

        var weights = guide.Select(cue => Math.Max(1, TimingUnitCount(cue.Text, characterMode))).ToList();
        var totalWeight = Math.Max(1, weights.Sum());
        var cursor = 0;
        var output = new List<SubtitleCue>(guide.Count);

        for (var index = 0; index < guide.Count; index++)
        {
            var remainingUnits = units.Count - cursor;
            if (remainingUnits <= 0) break;
            var remainingCues = guide.Count - index;
            int targetCount;
            if (index == guide.Count - 1)
            {
                targetCount = remainingUnits;
            }
            else
            {
                var proportional = (int)Math.Round(units.Count * weights[index] / (double)totalWeight);
                targetCount = Math.Min(Math.Max(1, proportional), Math.Max(1, remainingUnits - (remainingCues - 1)));
            }

            var take = Math.Min(targetCount, remainingUnits);
            var text = JoinUnits(units.Skip(cursor).Take(take), characterMode);
            var guideCue = guide[index];
            output.Add(new SubtitleCue(output.Count + 1, guideCue.Start, guideCue.End, text, guideCue.SourceFragments));
            cursor += take;
        }

        if (cursor < units.Count && output.Count > 0)
        {
            var last = output[^1];
            last.Text = JoinUnits([last.Text, JoinUnits(units.Skip(cursor), characterMode)], characterMode);
        }
        return output;
    }

    private static IEnumerable<string> TranscriptUnits(string text, bool characterMode)
    {
        if (characterMode)
        {
            foreach (var ch in text.Where(ch => !char.IsWhiteSpace(ch)))
            {
                yield return ch.ToString();
            }
            yield break;
        }

        foreach (var part in text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries))
        {
            yield return part;
        }
    }

    private static int TimingUnitCount(string text, bool characterMode) =>
        TranscriptUnits(CollapseWhitespace(text), characterMode).Count();

    private static string JoinUnits(IEnumerable<string> units, bool withoutSpaces) =>
        withoutSpaces ? string.Concat(units) : string.Join(" ", units);

    private static bool PrefersCharacterUnits(string text)
    {
        var scalars = text.Where(ch => !char.IsWhiteSpace(ch)).ToList();
        if (scalars.Count == 0) return false;
        var cjk = scalars.Count(ch =>
            ch is >= '\u3040' and <= '\u30FF'
                or >= '\u3400' and <= '\u9FFF'
                or >= '\uAC00' and <= '\uD7AF');
        return cjk / (double)scalars.Count >= 0.35;
    }

    private static string CollapseWhitespace(string value) =>
        string.Join(" ", (value ?? "").Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries)).Trim();
}

public static class CloudAsrGeneratorFactory
{
    public static ICloudAsrSubtitleGenerator? Create(
        AppSettings settings,
        ILocalAsrSubtitleGenerator? localAsrGenerator = null,
        HttpClient? httpClient = null)
    {
        if (!settings.CloudAsrEnabled || !settings.CloudAsrConsentAccepted) return null;
        var baseUrl = settings.CloudAsrBaseUrl.Trim();
        var token = settings.CloudAsrAuthToken.Trim();
        var model = settings.CloudAsrModel.Trim();
        if (!Uri.TryCreate(baseUrl, UriKind.Absolute, out _)) return null;
        if (token.Length == 0 || model.Length == 0) return null;
        if (CloudAsrModelCapabilities.RequiresAlignment(model))
        {
            return localAsrGenerator is null
                ? null
                : new AlignedOpenAICloudAsrSubtitleGenerator(baseUrl, token, model, localAsrGenerator, httpClient);
        }
        if (!CloudAsrModelCapabilities.SupportsDirectSubtitleOutput(model)) return null;
        return new OpenAICloudAsrSubtitleGenerator(baseUrl, token, model, httpClient);
    }
}

public sealed class AlignedOpenAICloudAsrSubtitleGenerator : ICloudAsrSubtitleGenerator
{
    private readonly OpenAICloudAsrSubtitleGenerator _cloud;
    private readonly ILocalAsrSubtitleGenerator _timingGuideGenerator;

    public AlignedOpenAICloudAsrSubtitleGenerator(
        string baseUrl,
        string authToken,
        string modelId,
        ILocalAsrSubtitleGenerator timingGuideGenerator,
        HttpClient? httpClient = null)
    {
        _cloud = new OpenAICloudAsrSubtitleGenerator(baseUrl, authToken, modelId, httpClient);
        _timingGuideGenerator = timingGuideGenerator;
    }

    public async Task<GeneratedCloudAsrSource> GenerateSourceSubtitleAsync(
        string videoFile,
        string languageCode,
        TaskControlToken? control,
        CancellationToken ct = default)
    {
        var normalizedLanguage = string.IsNullOrWhiteSpace(languageCode) ? "auto" : languageCode.Trim();
        var guide = await _timingGuideGenerator.GenerateSourceSubtitleAsync(
            videoFile,
            normalizedLanguage,
            control,
            _ => { },
            ct).ConfigureAwait(false);
        if (guide.Confidence?.HasSevereQualityBlocker == true)
        {
            throw MoongateException.DownloadFailed(L10n.T(
                "本地时间轴参考字幕质量过低，无法安全对齐云端转写文本。",
                "本機時間軸參考字幕品質過低，無法安全對齊雲端轉寫文字。",
                "The local timing guide is too low quality to align cloud transcript text safely."));
        }

        var output = CloudAlignedOutputPath(videoFile, normalizedLanguage);
        var written = await _cloud.TranscribeToAlignedSrtAsync(
            videoFile,
            normalizedLanguage,
            guide.Url,
            output,
            prompt: null,
            ct).ConfigureAwait(false);
        return new GeneratedCloudAsrSource(written);
    }

    private static string CloudAlignedOutputPath(string videoFile, string languageCode)
    {
        var directory = Path.GetDirectoryName(videoFile) ?? ".";
        var stem = Path.GetFileNameWithoutExtension(videoFile);
        var lang = SafeLanguageForFile(languageCode);
        var basePath = Path.Combine(directory, $"{stem}.cloud-asr.{lang}.srt");
        if (!File.Exists(basePath)) return basePath;
        for (var index = 2; ; index++)
        {
            var candidate = Path.Combine(directory, $"{stem}.cloud-asr.{lang}-{index}.srt");
            if (!File.Exists(candidate)) return candidate;
        }
    }

    private static string SafeLanguageForFile(string languageCode)
    {
        var chars = languageCode
            .Trim()
            .Select(ch => char.IsLetterOrDigit(ch) || ch is '-' or '_' ? ch : '-')
            .ToArray();
        var value = new string(chars).Trim('-');
        return value.Length == 0 ? "auto" : value;
    }
}
