using System.Net;
using System.Text;
using System.Text.Json;
using Moongate.Core;

namespace MoongateCore.Tests;

/// <summary>记录请求形状并按脚本应答的 fake handler（不发真网络请求）。</summary>
internal sealed class FakeHttpHandler : HttpMessageHandler
{
    internal sealed record CapturedRequest(
        HttpMethod Method, Uri Uri, Dictionary<string, string> Headers, string Body);

    private readonly object _lock = new();
    public List<CapturedRequest> Requests { get; } = [];
    /// <summary>按捕获的请求生成响应；默认 200 空对象。</summary>
    public Func<CapturedRequest, HttpResponseMessage> Responder { get; set; } =
        _ => Json(200, "{}");

    public static HttpResponseMessage Json(int status, string body) => new((HttpStatusCode)status)
    {
        Content = new StringContent(body, Encoding.UTF8, "application/json"),
    };

    protected override async Task<HttpResponseMessage> SendAsync(
        HttpRequestMessage request, CancellationToken cancellationToken)
    {
        var body = request.Content is null
            ? ""
            : await request.Content.ReadAsStringAsync(cancellationToken);
        var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var header in request.Headers)
        {
            headers[header.Key] = string.Join(",", header.Value);
        }
        var captured = new CapturedRequest(request.Method, request.RequestUri!, headers, body);
        lock (_lock) Requests.Add(captured);
        return Responder(captured);
    }
}

public class TranslationApiTests
{
    private static AppSettings GatewaySettings(TranslationProvider provider = TranslationProvider.Anthropic) => new()
    {
        TranslationProvider = provider,
        TranslationBaseUrl = "https://gateway.example.com",
        TranslationModel = "test-model",
        TranslationAuthToken = "secret-token",
    };

    private static string AnthropicReply(string text, string stopReason = "end_turn") =>
        JsonSerializer.Serialize(new
        {
            content = new[] { new { type = "text", text } },
            stop_reason = stopReason,
        });

    private static string ChatCompletionReply(string text, string finishReason = "stop") =>
        JsonSerializer.Serialize(new
        {
            choices = new[]
            {
                new
                {
                    message = new { role = "assistant", content = text },
                    finish_reason = finishReason,
                },
            },
        });

    [Fact]
    public async Task Anthropic_Gateway_SendsBothAuthHeaders()
    {
        var handler = new FakeHttpHandler
        {
            Responder = _ => FakeHttpHandler.Json(200, AnthropicReply("ok")),
        };
        var reply = await TranslationApi.SendAnthropicMessageAsync(
            GatewaySettings(), "sys", "1|hello", 100, handler, CancellationToken.None);

        Assert.Equal("ok", reply.Text);
        Assert.False(reply.ReachedOutputLimit);
        var request = Assert.Single(handler.Requests);
        Assert.Equal("https://gateway.example.com/v1/messages", request.Uri.ToString());
        Assert.Equal("secret-token", request.Headers["x-api-key"]);
        Assert.Equal("Bearer secret-token", request.Headers["Authorization"]);
        Assert.Equal("2023-06-01", request.Headers["anthropic-version"]);
        // 请求体形状
        using var doc = JsonDocument.Parse(request.Body);
        Assert.Equal("test-model", doc.RootElement.GetProperty("model").GetString());
        Assert.Equal(100, doc.RootElement.GetProperty("max_tokens").GetInt32());
        Assert.Equal("sys", doc.RootElement.GetProperty("system").GetString());
        Assert.Equal("1|hello", doc.RootElement.GetProperty("messages")[0].GetProperty("content").GetString());
    }

    /// <summary>官方 api.anthropic.com 只发 x-api-key（双头会被拒）。</summary>
    [Fact]
    public async Task Anthropic_OfficialHost_OmitsAuthorizationHeader()
    {
        var handler = new FakeHttpHandler
        {
            Responder = _ => FakeHttpHandler.Json(200, AnthropicReply("ok")),
        };
        var settings = GatewaySettings() with { TranslationBaseUrl = "https://api.anthropic.com" };
        await TranslationApi.SendAnthropicMessageAsync(
            settings, null, "hi", 100, handler, CancellationToken.None);

        var request = Assert.Single(handler.Requests);
        Assert.Equal("secret-token", request.Headers["x-api-key"]);
        Assert.False(request.Headers.ContainsKey("Authorization"));
    }

    /// <summary>凭证里误带 "Bearer " 前缀时剥掉，避免双重 Bearer。</summary>
    [Fact]
    public async Task TokenNormalization_StripsBearerPrefix()
    {
        var handler = new FakeHttpHandler
        {
            Responder = _ => FakeHttpHandler.Json(200, AnthropicReply("ok")),
        };
        var settings = GatewaySettings() with { TranslationAuthToken = "  Bearer secret-token  " };
        await TranslationApi.SendAnthropicMessageAsync(
            settings, null, "hi", 100, handler, CancellationToken.None);

        var request = Assert.Single(handler.Requests);
        Assert.Equal("secret-token", request.Headers["x-api-key"]);
        Assert.Equal("Bearer secret-token", request.Headers["Authorization"]);
    }

    [Fact]
    public async Task OpenAi_PostsToResponsesEndpoint_AndJoinsOutputText()
    {
        var responseBody = JsonSerializer.Serialize(new
        {
            output = new object[]
            {
                new { type = "reasoning", content = Array.Empty<object>() },
                new
                {
                    type = "message",
                    content = new object[]
                    {
                        new { type = "output_text", text = "1|你" },
                        new { type = "text", text = "好" },
                    },
                },
            },
            status = "completed",
        });
        var handler = new FakeHttpHandler { Responder = _ => FakeHttpHandler.Json(200, responseBody) };
        var reply = await TranslationApi.SendOpenAiResponseAsync(
            GatewaySettings(TranslationProvider.Openai), "inst", "1|hi", 256, handler, CancellationToken.None);

        Assert.Equal("1|你好", reply.Text);
        Assert.False(reply.ReachedOutputLimit);
        var request = Assert.Single(handler.Requests);
        Assert.Equal("https://gateway.example.com/v1/responses", request.Uri.ToString());
        Assert.Equal("Bearer secret-token", request.Headers["Authorization"]);
        using var doc = JsonDocument.Parse(request.Body);
        Assert.Equal(256, doc.RootElement.GetProperty("max_output_tokens").GetInt32());
        Assert.False(doc.RootElement.GetProperty("store").GetBoolean());
        Assert.Equal("inst", doc.RootElement.GetProperty("instructions").GetString());
    }

    [Fact]
    public async Task OpenAi_IncompleteMaxOutputTokens_FlagsOutputLimit()
    {
        var responseBody = JsonSerializer.Serialize(new
        {
            output = new object[]
            {
                new
                {
                    type = "message",
                    content = new object[] { new { type = "output_text", text = "partial" } },
                },
            },
            status = "incomplete",
            incomplete_details = new { reason = "max_output_tokens" },
        });
        var handler = new FakeHttpHandler { Responder = _ => FakeHttpHandler.Json(200, responseBody) };
        var reply = await TranslationApi.SendOpenAiResponseAsync(
            GatewaySettings(TranslationProvider.Openai), null, "x", 16, handler, CancellationToken.None);
        Assert.True(reply.ReachedOutputLimit);
    }

    [Fact]
    public async Task SendConfigured_OpenAiOfficial_UsesResponsesEndpoint()
    {
        var responseBody = JsonSerializer.Serialize(new
        {
            output = new object[]
            {
                new
                {
                    type = "message",
                    content = new object[] { new { type = "output_text", text = "ok" } },
                },
            },
            status = "completed",
        });
        var handler = new FakeHttpHandler { Responder = _ => FakeHttpHandler.Json(200, responseBody) };
        var settings = GatewaySettings(TranslationProvider.Openai) with { TranslationBaseUrl = "https://api.openai.com" };

        var reply = await TranslationApi.SendConfiguredMessageAsync(
            settings, "inst", "hello", 64, handler, CancellationToken.None);

        Assert.Equal("ok", reply.Text);
        var request = Assert.Single(handler.Requests);
        Assert.Equal("https://api.openai.com/v1/responses", request.Uri.ToString());
        using var doc = JsonDocument.Parse(request.Body);
        Assert.Equal("hello", doc.RootElement.GetProperty("input").GetString());
        Assert.Equal(64, doc.RootElement.GetProperty("max_output_tokens").GetInt32());
    }

    [Fact]
    public async Task SendConfigured_OpenAiCompatibleGateway_UsesChatCompletionsEndpoint()
    {
        var handler = new FakeHttpHandler
        {
            Responder = _ => FakeHttpHandler.Json(200, ChatCompletionReply("正常")),
        };
        var settings = GatewaySettings(TranslationProvider.Openai) with { TranslationBaseUrl = "https://api.deepseek.com" };

        var reply = await TranslationApi.SendConfiguredMessageAsync(
            settings, "inst", "hello", 64, handler, CancellationToken.None);

        Assert.Equal("正常", reply.Text);
        var request = Assert.Single(handler.Requests);
        Assert.Equal("https://api.deepseek.com/v1/chat/completions", request.Uri.ToString());
        Assert.Equal("Bearer secret-token", request.Headers["Authorization"]);
        using var doc = JsonDocument.Parse(request.Body);
        Assert.Equal("test-model", doc.RootElement.GetProperty("model").GetString());
        Assert.Equal(64, doc.RootElement.GetProperty("max_tokens").GetInt32());
        Assert.False(doc.RootElement.GetProperty("stream").GetBoolean());
        var messages = doc.RootElement.GetProperty("messages");
        Assert.Equal("system", messages[0].GetProperty("role").GetString());
        Assert.Equal("inst", messages[0].GetProperty("content").GetString());
        Assert.Equal("user", messages[1].GetProperty("role").GetString());
        Assert.Equal("hello", messages[1].GetProperty("content").GetString());
    }

    [Fact]
    public async Task SendConfigured_DeepSeek_DisablesThinkingForDeterministicTextTasks()
    {
        var handler = new FakeHttpHandler
        {
            Responder = _ => FakeHttpHandler.Json(200, ChatCompletionReply("正常")),
        };
        var settings = GatewaySettings(TranslationProvider.Openai) with { TranslationBaseUrl = "https://api.deepseek.com" };

        await TranslationApi.SendConfiguredMessageAsync(
            settings, "inst", "hello", 64, handler, CancellationToken.None);

        var request = Assert.Single(handler.Requests);
        using var doc = JsonDocument.Parse(request.Body);
        var thinking = doc.RootElement.GetProperty("thinking");
        Assert.Equal("disabled", thinking.GetProperty("type").GetString());
    }

    [Fact]
    public async Task SendConfigured_NonDeepSeekCompatibleGateway_DoesNotSendDeepSeekThinkingParameter()
    {
        var handler = new FakeHttpHandler
        {
            Responder = _ => FakeHttpHandler.Json(200, ChatCompletionReply("正常")),
        };
        var settings = GatewaySettings(TranslationProvider.Openai);

        await TranslationApi.SendConfiguredMessageAsync(
            settings, "inst", "hello", 64, handler, CancellationToken.None);

        var request = Assert.Single(handler.Requests);
        using var doc = JsonDocument.Parse(request.Body);
        Assert.False(doc.RootElement.TryGetProperty("thinking", out _));
    }

    [Fact]
    public async Task OpenAiChatCompletion_LengthFinishReason_FlagsOutputLimit()
    {
        var handler = new FakeHttpHandler
        {
            Responder = _ => FakeHttpHandler.Json(200, ChatCompletionReply("partial", "length")),
        };

        var reply = await TranslationApi.SendOpenAiChatCompletionAsync(
            GatewaySettings(TranslationProvider.Openai), null, "hello", 16, handler, CancellationToken.None);

        Assert.Equal("partial", reply.Text);
        Assert.True(reply.ReachedOutputLimit);
    }

    [Fact]
    public async Task OpenAiChatCompletion_ReasoningOnlyResponse_GivesActionableMessage()
    {
        var responseBody = JsonSerializer.Serialize(new
        {
            choices = new[]
            {
                new
                {
                    message = new
                    {
                        role = "assistant",
                        content = "",
                        reasoning_content = "thinking without final text",
                    },
                    finish_reason = "stop",
                },
            },
        });
        var handler = new FakeHttpHandler
        {
            Responder = _ => FakeHttpHandler.Json(200, responseBody),
        };

        var ex = await Assert.ThrowsAsync<MoongateException>(() =>
            TranslationApi.SendOpenAiChatCompletionAsync(
                GatewaySettings(TranslationProvider.Openai), null, "hello", 16, handler, CancellationToken.None));

        Assert.Contains("只返回了思考内容", ex.Detail);
    }

    [Fact]
    public void EndpointUrl_HandlesTrailingSlashAndV1Suffix()
    {
        Assert.Equal("https://a.com/v1/messages",
            TranslationApi.EndpointUrl("https://a.com/", "/v1/messages").ToString());
        Assert.Equal("https://a.com/v1/messages",
            TranslationApi.EndpointUrl("https://a.com/v1", "/v1/messages").ToString());
        Assert.Equal("https://a.com/v1/messages",
            TranslationApi.EndpointUrl("https://a.com/v1/messages", "/v1/messages").ToString());
        Assert.Throws<MoongateException>(() => TranslationApi.EndpointUrl("not a url", "/v1/messages"));
    }

    [Fact]
    public async Task ListModels_AppendsLimitQuery_AndParsesIds()
    {
        var handler = new FakeHttpHandler
        {
            Responder = _ => FakeHttpHandler.Json(200,
                """{"data":[{"id":"m1"},{"id":"m2"},{"id":"m1"},{"id":""}]}"""),
        };
        var models = await TranslationApi.ListModelsAsync(GatewaySettings(), handler);

        Assert.Equal(["m1", "m2"], models);
        var request = Assert.Single(handler.Requests);
        Assert.Equal(HttpMethod.Get, request.Method);
        Assert.Equal("https://gateway.example.com/v1/models?limit=1000", request.Uri.ToString());
        Assert.Equal("secret-token", request.Headers["x-api-key"]);
        Assert.Equal("Bearer secret-token", request.Headers["Authorization"]);
    }

    [Fact]
    public async Task ListModels_RetriesGatewayWithoutLimitWhenRequestShapeRejected()
    {
        var handler = new FakeHttpHandler
        {
            Responder = request => request.Uri.Query.Contains("limit=1000", StringComparison.Ordinal)
                ? FakeHttpHandler.Json(400, """{"error":"unexpected query"}""")
                : FakeHttpHandler.Json(200, """{"data":[{"id":"claude-gateway"},{"id":"claude-gateway"}]}"""),
        };

        var models = await TranslationApi.ListModelsAsync(GatewaySettings(), handler);

        Assert.Equal(["claude-gateway"], models);
        Assert.Equal(2, handler.Requests.Count);
        Assert.Equal("https://gateway.example.com/v1/models?limit=1000", handler.Requests[0].Uri.ToString());
        Assert.Equal("https://gateway.example.com/v1/models", handler.Requests[1].Uri.ToString());
        Assert.Equal("secret-token", handler.Requests[0].Headers["x-api-key"]);
        Assert.Equal("Bearer secret-token", handler.Requests[0].Headers["Authorization"]);
    }

    [Fact]
    public async Task ListModels_OfficialAnthropic_DoesNotRetryWithoutLimit()
    {
        var handler = new FakeHttpHandler
        {
            Responder = _ => FakeHttpHandler.Json(400, """{"error":"bad request"}"""),
        };
        var settings = GatewaySettings() with { TranslationBaseUrl = "https://api.anthropic.com" };

        var ex = await Assert.ThrowsAsync<MoongateException>(() =>
            TranslationApi.ListModelsAsync(settings, handler));

        Assert.Equal(MoongateErrorKind.TranslateFailed, ex.Kind);
        var request = Assert.Single(handler.Requests);
        Assert.Equal("https://api.anthropic.com/v1/models?limit=1000", request.Uri.ToString());
    }

    [Fact]
    public async Task ListModels_OfficialAnthropic_OmitsAuthorization()
    {
        var handler = new FakeHttpHandler
        {
            Responder = _ => FakeHttpHandler.Json(200, """{"data":[{"id":"claude-x"}]}"""),
        };
        var settings = GatewaySettings() with { TranslationBaseUrl = "https://api.anthropic.com" };
        await TranslationApi.ListModelsAsync(settings, handler);
        var request = Assert.Single(handler.Requests);
        Assert.False(request.Headers.ContainsKey("Authorization"));
    }

    [Fact]
    public async Task ListModels_OpenAiCompatible_UsesBearerOnly()
    {
        var handler = new FakeHttpHandler
        {
            Responder = _ => FakeHttpHandler.Json(200, """{"data":[{"id":"gpt-x"}]}"""),
        };

        var models = await TranslationApi.ListModelsAsync(
            GatewaySettings(TranslationProvider.Openai), handler);

        Assert.Equal(["gpt-x"], models);
        var request = Assert.Single(handler.Requests);
        Assert.Equal("Bearer secret-token", request.Headers["Authorization"]);
        Assert.False(request.Headers.ContainsKey("x-api-key"));
        Assert.False(request.Headers.ContainsKey("anthropic-version"));
    }

    [Fact]
    public void ParseModelIds_ToleratesVariousShapes()
    {
        Assert.Equal(["a", "b"], TranslationApi.ParseModelIds("""{"data":["a","b"]}"""));
        Assert.Equal(["a"], TranslationApi.ParseModelIds("""{"models":[{"name":"a"}]}"""));
        Assert.Equal(["a"], TranslationApi.ParseModelIds("""[{"model":"a"}]"""));
        Assert.Empty(TranslationApi.ParseModelIds("not json"));
    }

    [Fact]
    public async Task TestConnection_SendsMiniMessageWith1024Tokens()
    {
        var handler = new FakeHttpHandler
        {
            Responder = _ => FakeHttpHandler.Json(200, AnthropicReply("  正常  ")),
        };
        var text = await TranslationApi.TestConnectionAsync(GatewaySettings(), handler);
        Assert.Equal("正常", text);
        var request = Assert.Single(handler.Requests);
        using var doc = JsonDocument.Parse(request.Body);
        Assert.Equal(1024, doc.RootElement.GetProperty("max_tokens").GetInt32());
        Assert.Equal("请只回复两个字：正常", doc.RootElement.GetProperty("messages")[0].GetProperty("content").GetString());
    }

    [Fact]
    public void RequestFailureMessage_503_GivesGatewayHint()
    {
        var message = TranslationApi.RequestFailureMessage(
            503, """{"error":{"message":"no available accounts"}}""", GatewaySettings());
        Assert.Contains("网关没有可用账号或模型映射未命中", message);
        Assert.Contains("test-model", message);

        var plain = TranslationApi.RequestFailureMessage(401, """{"error":{"message":"bad key"}}""", GatewaySettings());
        Assert.Equal("HTTP 401：bad key", plain);
    }

    [Fact]
    public async Task MissingModelOrToken_ThrowsActionableError()
    {
        var noModel = GatewaySettings() with { TranslationModel = " " };
        var ex1 = await Assert.ThrowsAsync<MoongateException>(() =>
            TranslationApi.SendAnthropicMessageAsync(noModel, null, "x", 16, new FakeHttpHandler(), CancellationToken.None));
        Assert.Contains("尚未配置模型", ex1.Detail);

        var noToken = GatewaySettings() with { TranslationAuthToken = "" };
        var ex2 = await Assert.ThrowsAsync<MoongateException>(() =>
            TranslationApi.SendAnthropicMessageAsync(noToken, null, "x", 16, new FakeHttpHandler(), CancellationToken.None));
        Assert.Contains("尚未配置 API 凭证", ex2.Detail);
    }
}

public class ConfiguredTranslatorTests : IDisposable
{
    private readonly string _tempDir;

    public ConfiguredTranslatorTests()
    {
        _tempDir = Path.Combine(Path.GetTempPath(), $"moongate-test-{Guid.NewGuid():N}");
        Directory.CreateDirectory(_tempDir);
    }

    public void Dispose()
    {
        try { Directory.Delete(_tempDir, true); } catch { /* 忽略 */ }
    }

    private static AppSettings Settings => new()
    {
        TranslationProvider = TranslationProvider.Anthropic,
        TranslationBaseUrl = "https://gateway.example.com",
        TranslationModel = "test-model",
        TranslationAuthToken = "tok",
        AIProvider = TranslationProvider.Anthropic,
        AIBaseUrl = "https://gateway.example.com",
        AIModel = "test-model",
        AIAuthToken = "tok",
    };

    private string WriteSrt(string name, IEnumerable<SubtitleCue> cues)
    {
        var path = Path.Combine(_tempDir, name);
        File.WriteAllText(path, SrtTools.SerializeSrt(cues));
        return path;
    }

    /// <summary>从请求体里取出 user content（messages[0].content），按行回贴 "N|中N"。</summary>
    private static string TranslateAllLines(string requestBody)
    {
        using var doc = JsonDocument.Parse(requestBody);
        var content = doc.RootElement.GetProperty("messages")[0].GetProperty("content").GetString()!;
        var replyLines = content.Split('\n').Select(line =>
        {
            var number = line.Split('|')[0];
            return $"{number}|中{number}";
        });
        return string.Join("\n", replyLines);
    }

    private static string AnthropicReply(string text, string stopReason = "end_turn") =>
        JsonSerializer.Serialize(new
        {
            content = new[] { new { type = "text", text } },
            stop_reason = stopReason,
        });

    [Fact]
    public async Task Translate_Bilingual_ChineseAboveOriginal_WritesTargetLanguageSrt()
    {
        var srt = WriteSrt("video.en.srt",
        [
            new SubtitleCue(1, "00:00:01,000", "00:00:02,000", "Hello there."),
            new SubtitleCue(2, "00:00:03,000", "00:00:04,000", "Bye now."),
        ]);
        var handler = new FakeHttpHandler
        {
            Responder = captured => FakeHttpHandler.Json(200, AnthropicReply(TranslateAllLines(captured.Body))),
        };
        var translator = new ConfiguredTranslator(Settings, handler);
        var output = await translator.TranslateAsync(srt, SubtitleStyle.Bilingual, null, _ => { });

        Assert.Equal(Path.Combine(_tempDir, "video.en.zh-Hans.srt"), output);
        var cues = SrtTools.ParseSrt(File.ReadAllText(output));
        Assert.Equal(2, cues.Count);
        Assert.Equal("中1\nHello there.", cues[0].Text);  // 双语：中文在上、原文在下
        Assert.Equal("中2\nBye now.", cues[1].Text);
    }

    [Fact]
    public async Task Translate_ChineseOnly_ReplacesText()
    {
        var srt = WriteSrt("v.srt",
        [
            new SubtitleCue(1, "00:00:01,000", "00:00:02,000", "Hello."),
        ]);
        var handler = new FakeHttpHandler
        {
            Responder = captured => FakeHttpHandler.Json(200, AnthropicReply(TranslateAllLines(captured.Body))),
        };
        var translator = new ConfiguredTranslator(Settings, handler);
        var output = await translator.TranslateAsync(srt, SubtitleStyle.ChineseOnly, null, _ => { });

        var cues = SrtTools.ParseSrt(File.ReadAllText(output));
        Assert.Equal("中1", Assert.Single(cues).Text);
    }

    [Fact]
    public async Task Translate_PunctuationOnlyTranslation_FallsBackToSourceWithoutFailingWholeTranslation()
    {
        var srt = WriteSrt("punctuation.en.srt",
        [
            new SubtitleCue(1, "00:00:01,000", "00:00:02,000", "."),
            new SubtitleCue(2, "00:00:03,000", "00:00:04,000", "Ignition."),
        ]);
        var handler = new FakeHttpHandler
        {
            Responder = _ => FakeHttpHandler.Json(200, AnthropicReply("1|。\n2|点火")),
        };
        var translator = new ConfiguredTranslator(Settings, handler);

        var output = await translator.TranslateAsync(srt, SubtitleStyle.ChineseOnly, null, _ => { });

        var cues = SrtTools.ParseSrt(File.ReadAllText(output));
        Assert.Equal([".", "点火"], cues.Select(c => c.Text));
    }

    [Fact]
    public async Task Translate_JapaneseFilenamePassesSourceLanguageToChunkAndLineFallbackPrompts()
    {
        var srt = WriteSrt("video.ja.srt",
        [
            new SubtitleCue(1, "00:00:01,000", "00:00:02,000", "左隣、あなたの"),
        ]);
        var attempts = 0;
        var handler = new FakeHttpHandler
        {
            Responder = captured =>
            {
                attempts++;
                return attempts == 1
                    ? FakeHttpHandler.Json(200, AnthropicReply("1|partial", "max_tokens"))
                    : FakeHttpHandler.Json(200, AnthropicReply("1|你坐在我的左侧"));
            },
        };
        var translator = new ConfiguredTranslator(Settings, handler);

        var output = await translator.TranslateAsync(srt, SubtitleStyle.ChineseOnly, null, _ => { });

        Assert.Equal("你坐在我的左侧", Assert.Single(SrtTools.ParseSrt(File.ReadAllText(output))).Text);
        Assert.Equal(2, handler.Requests.Count);
        Assert.All(handler.Requests, request =>
        {
            var system = RequestSystem(request.Body);
            Assert.Contains("正在把日语字幕翻译成简体中文", system);
            Assert.Contains("日文→中文重排示例", system);
        });
    }

    [Fact]
    public async Task Translate_WithSmartPrompts_AnalyzesSubtitleThenUsesLyricsPreset()
    {
        var srt = WriteSrt("song.srt",
        [
            new SubtitleCue(1, "00:00:01,000", "00:00:02,000", "I still hear your song."),
            new SubtitleCue(2, "00:00:03,000", "00:00:04,000", "Under the city lights."),
        ]);
        var settings = Settings with { SmartTranslationPromptsEnabled = true };
        var handler = new FakeHttpHandler();
        handler.Responder = captured =>
        {
            if (captured.Body.Contains("preset", StringComparison.OrdinalIgnoreCase)
                || captured.Body.Contains("字幕流水线规划", StringComparison.Ordinal))
            {
                return FakeHttpHandler.Json(200, AnthropicReply(
                    """
                    {
                      "summary":"这是一首夜色里的告别歌曲。",
                      "context":"YOASOBI 在 THE FIRST TAKE 中演唱，开场提到 Ayase、乐队成员和 Plusonica 合唱团。",
                      "terms":["Ayase：YOASOBI 成员/制作人","Plusonica：合唱团体，字幕中写作ぷらそにか时不要误拼为 Plasonica"],
                      "preset":"songLyrics"
                    }
                    """));
            }
            return FakeHttpHandler.Json(200, AnthropicReply(TranslateAllLines(captured.Body)));
        };
        var translator = new ConfiguredTranslator(settings, handler);

        await translator.TranslateAsync(srt, SubtitleStyle.ChineseOnly, null, _ => { });

        Assert.Equal(2, handler.Requests.Count);
        Assert.Contains("字幕流水线规划", RequestSystem(handler.Requests[0].Body));
        var translateSystem = RequestSystem(handler.Requests[1].Body);
        Assert.Contains("这是一首夜色里的告别歌曲。", translateSystem);
        Assert.Contains("翻译前上下文", translateSystem);
        Assert.Contains("Ayase", translateSystem);
        Assert.Contains("Plusonica", translateSystem);
        Assert.Contains("不要把上下文里没有对应原文的信息添加到译文", translateSystem);
        Assert.Contains("允许在相邻同句的行之间", translateSystem);
        Assert.Contains("歌词", translateSystem);
        Assert.Contains("画面感", translateSystem);
        Assert.Contains("呼吸感", translateSystem);
        Assert.DoesNotContain("不要擅自扩写", translateSystem);
    }

    [Fact]
    public void SmartTranslationPromptAdvice_LegacySummaryOnlyJsonStaysCompatible()
    {
        var advice = ConfiguredTranslator.ParseTranslationPromptAdvice(
            """{"summary":"测试摘要","preset":"songLyrics"}""");
        Assert.NotNull(advice);

        Assert.Equal("测试摘要", advice.Summary);
        Assert.Equal("", advice.Context);
        Assert.Empty(advice.Terms);
    }

    [Fact]
    public void SmartTranslationPromptPresets_CoverCommonVideoTypes()
    {
        var presets = new (string RawPreset, string ExpectedHint)[]
        {
            ("interviewConversation", "访谈"),
            ("tutorialHowTo", "步骤"),
            ("lectureCourse", "课程"),
            ("newsExplainer", "客观"),
            ("reviewProduct", "体验"),
            ("vlogLifestyle", "口吻"),
            ("shortSocial", "节奏"),
            ("documentaryNarrative", "叙事"),
            ("gamingEntertainment", "游戏"),
        };

        foreach (var (rawPreset, expectedHint) in presets)
        {
            var advice = ConfiguredTranslator.ParseTranslationPromptAdvice(
                $$"""{"summary":"测试摘要","preset":"{{rawPreset}}"}""");
            Assert.NotNull(advice);
            var prompt = ConfiguredTranslator.SystemPrompt("简体中文", advice);

            Assert.Contains(expectedHint, prompt);
            Assert.Contains("测试摘要", prompt);
        }
    }

    [Fact]
    public void TranslationPromptPresetProfiles_CoverEveryPromptLayer()
    {
        var presets = Enum.GetValues<TranslationPromptPreset>();
        Assert.Equal(12, presets.Length);
        foreach (var preset in presets)
        {
            var profile = TranslationPromptPresetProfile.For(preset);
            Assert.False(string.IsNullOrWhiteSpace(profile.PlanningHint), $"{preset}.PlanningHint");
            Assert.False(string.IsNullOrWhiteSpace(profile.SegmentationGuidance), $"{preset}.SegmentationGuidance");
            Assert.False(string.IsNullOrWhiteSpace(profile.TranslationGuidance), $"{preset}.TranslationGuidance");
            Assert.NotEmpty(profile.QualityAnchors);
        }
    }

    [Fact]
    public void SanitizedSourceCuesForTranslation_DropsCjkRomanizedGarbageCues()
    {
        var cues = new List<SubtitleCue>
        {
            new(1, "00:00:01,000", "00:00:02,000", "好きなことを続けること"),
            new(2, "00:00:02,000", "00:00:03,000", "ni"),
            new(3, "00:00:03,000", "00:00:04,000", "dare ni"),
            new(4, "00:00:04,000", "00:00:05,000", "それは楽しいだけじゃない"),
            new(5, "00:00:05,000", "00:00:06,000", "carano"),
            new(6, "00:00:06,000", "00:00:07,000", "本当にできる"),
        };

        var filtered = ConfiguredTranslator.SanitizedSourceCuesForTranslation(cues, "ja");

        Assert.Equal(
            new[] { "好きなことを続けること", "それは楽しいだけじゃない", "本当にできる" },
            filtered.Select(cue => cue.Text));
        Assert.Equal(new[] { 1, 2, 3 }, filtered.Select(cue => cue.Index));
        Assert.Equal(
            new[] { "00:00:01,000", "00:00:04,000", "00:00:06,000" },
            filtered.Select(cue => cue.Start));
    }

    [Fact]
    public void SanitizedSourceCuesForTranslation_StripsJapaneseRomajiGlosses()
    {
        var cues = new List<SubtitleCue>
        {
            new(1, "00:00:00,790", "00:00:05,620", "沈むように溶けていくように (Shizumu you ni tokete yuku you ni)"),
            new(2, "00:00:08,500", "00:00:14,900", "二人だけの空が広がる夜に (Futari dake no sora ga hirogaru you ni)"),
        };

        var sanitized = ConfiguredTranslator.SanitizedSourceCuesForTranslation(cues, "ja");

        Assert.Equal(
            new[] { "沈むように溶けていくように", "二人だけの空が広がる夜に" },
            sanitized.Select(cue => cue.Text));
        Assert.Equal(new[] { 1, 2 }, sanitized.Select(cue => cue.Index));
        Assert.Equal(new[] { "00:00:00,790", "00:00:08,500" }, sanitized.Select(cue => cue.Start));
    }

    [Fact]
    public void TranslationPromptPresetProfiles_ExpressDistinctStyleAnchors()
    {
        var anchors = new (TranslationPromptPreset Preset, string[] Required, string[] Forbidden)[]
        {
            (TranslationPromptPreset.SongLyrics, ["诗意", "意象", "副歌"], ["客观", "按钮名"]),
            (TranslationPromptPreset.Anime, ["角色", "称呼", "口癖"], ["严肃科普"]),
            (TranslationPromptPreset.LectureCourse, ["专业", "严肃", "逻辑"], ["诗意"]),
            (TranslationPromptPreset.NewsExplainer, ["客观", "数字", "时间"], ["副歌"]),
            (TranslationPromptPreset.ShortSocial, ["节奏", "梗", "语义完整"], ["课程"]),
            (TranslationPromptPreset.GamingEntertainment, ["现场感", "术语", "即时反应"], ["新闻"]),
        };

        foreach (var (preset, required, forbidden) in anchors)
        {
            var prompt = ConfiguredTranslator.SystemPrompt(
                "简体中文",
                new TranslationPromptAdvice("测试摘要", "", [], preset));
            foreach (var word in required)
            {
                Assert.Contains(word, prompt);
            }
            foreach (var word in forbidden)
            {
                Assert.DoesNotContain(word, prompt);
            }
        }
    }

    [Fact]
    public void SmartTranslationPromptPresets_UnknownPresetFallsBackToGeneral()
    {
        var advice = ConfiguredTranslator.ParseTranslationPromptAdvice(
            """{"summary":"测试摘要","preset":"unknownFuturePreset"}""");
        Assert.NotNull(advice);

        Assert.Equal(TranslationPromptPreset.General, advice.Preset);
    }

    [Fact]
    public void SmartTranslationPromptAdvice_ParsesPlanningFieldsAndInjectsThem()
    {
        var advice = ConfiguredTranslator.ParseTranslationPromptAdvice(
            """
            {
              "summary":"一群冒险者的战斗对白。",
              "context":"奇幻动画第二季，主角与对手交战。",
              "sourceLanguageCode":"ja",
              "preset":"anime",
              "terms":["魔法：保留原文"],
              "characters":["王城ハル：主角，使用敬语","レン：对手，说话粗鲁"],
              "translationNotes":["保持ハル的敬语口吻","战斗拟声词保留情绪"]
            }
            """);
        Assert.NotNull(advice);
        Assert.Equal(TranslationPromptPreset.Anime, advice.Preset);
        Assert.Equal("ja", advice.SourceLanguageCode);
        Assert.Equal(2, advice.Characters!.Count);
        Assert.Equal(2, advice.TranslationNotes!.Count);

        // 第二层 prompt：源语言（advice 兜底点名）、人物、翻译注意、anime 风格句都要注入。
        var prompt = ConfiguredTranslator.SystemPrompt("简体中文", sourceLanguageCode: null, advice);
        Assert.Contains("正在把日语字幕翻译成简体中文", prompt);
        Assert.Contains("日文→中文重排示例", prompt);
        Assert.Contains("人物/角色", prompt);
        Assert.Contains("王城ハル", prompt);
        Assert.Contains("翻译注意", prompt);
        Assert.Contains("战斗拟声词保留情绪", prompt);
        Assert.Contains("动漫或动画对白", prompt);
    }

    [Fact]
    public void SmartTranslationPromptAdvice_LegacyJsonDefaultsPlanningFields()
    {
        var advice = ConfiguredTranslator.ParseTranslationPromptAdvice(
            """{"summary":"测试摘要","preset":"songLyrics"}""");
        Assert.NotNull(advice);

        Assert.Equal("unknown", advice.SourceLanguageCode);
        Assert.Empty(advice.Characters!);
        Assert.Empty(advice.TranslationNotes!);
    }

    [Fact]
    public void SubtitlePipelineAdvice_ParsesSourceActionAndTimingProfile()
    {
        var advice = ConfiguredTranslator.ParseSubtitlePipelineAdvice(
            """
            {
              "summary":"YOASOBI 歌曲 MV，YouTube 自动字幕疑似罗马音循环。",
              "context":"日语歌词，源字幕混入大量 ni/dare/carano。",
              "sourceLanguageCode":"ja",
              "preset":"songLyrics",
              "terms":["群青：歌名，保留意象"],
              "translationNotes":["按整段歌词意象翻译"],
              "sourceAssessment":"bad",
              "recommendedSourceAction":"useLocalASR",
              "timingProfile":"japaneseLyrics",
              "asrHints":{
                "disablePromptContext":true,
                "preferVAD":true,
                "suppressIntroHallucination":true
              },
              "qualityRisks":["romajiLoop","lyricsContext"]
            }
            """);
        Assert.NotNull(advice);

        Assert.Equal("ja", advice.SourceLanguageCode);
        Assert.Equal(TranslationPromptPreset.SongLyrics, advice.Preset);
        Assert.Equal(SubtitleSourceAssessment.Bad, advice.SourceAssessment);
        Assert.Equal(RecommendedSubtitleSourceAction.UseLocalAsr, advice.RecommendedSourceAction);
        Assert.Equal(SubtitleTimingProfile.JapaneseLyrics, advice.TimingProfile);
        Assert.True(advice.AsrHints.DisablePromptContext);
        Assert.True(advice.AsrHints.PreferVad);
        Assert.True(advice.AsrHints.SuppressIntroHallucination);
        Assert.Equal(["romajiLoop", "lyricsContext"], advice.QualityRisks);

        var translationAdvice = advice.ToTranslationPromptAdvice();
        Assert.Equal(TranslationPromptPreset.SongLyrics, translationAdvice.Preset);
        Assert.Equal(["按整段歌词意象翻译"], translationAdvice.TranslationNotes);
    }

    [Fact]
    public void SubtitlePipelineAdvice_LegacyTranslationJsonDefaultsToSafeSourceDecision()
    {
        var advice = ConfiguredTranslator.ParseSubtitlePipelineAdvice(
            """{"summary":"测试摘要","preset":"anime","sourceLanguageCode":"ja"}""");
        Assert.NotNull(advice);

        Assert.Equal(TranslationPromptPreset.Anime, advice.Preset);
        Assert.Equal("ja", advice.SourceLanguageCode);
        Assert.Equal(SubtitleSourceAssessment.Unknown, advice.SourceAssessment);
        Assert.Equal(RecommendedSubtitleSourceAction.KeepPlatform, advice.RecommendedSourceAction);
        Assert.Equal(SubtitleTimingProfile.Speech, advice.TimingProfile);
        Assert.False(advice.AsrHints.DisablePromptContext);
        Assert.Equal(TranslationPromptPreset.Anime, advice.ToTranslationPromptAdvice().Preset);
    }

    [Fact]
    public void SubtitlePipelinePlanningPrompt_IncludesSourceAndAsrDecisionSchema()
    {
        var prompt = ConfiguredTranslator.SubtitlePipelinePlanningSystemPrompt;

        Assert.Contains("字幕流水线规划器", prompt);
        Assert.Contains("sourceAssessment", prompt);
        Assert.Contains("recommendedSourceAction", prompt);
        Assert.Contains("timingProfile", prompt);
        Assert.Contains("asrHints", prompt);
        Assert.Contains("useLocalASR", prompt);
        Assert.Contains("japaneseLyrics", prompt);
        Assert.Contains("不能直接写时间轴", prompt);
        Assert.Contains("不能覆盖 local-ASR 源字幕", prompt);
    }

    [Fact]
    public void SmartTranslationPromptAdvice_NormalizesSourceLanguageAndCapsLists()
    {
        var manyCharacters = string.Join(",", Enumerable.Range(0, 12).Select(i => $"\"角色{i}\""));
        var advice = ConfiguredTranslator.ParseTranslationPromptAdvice(
            $$"""{"summary":"测试摘要","sourceLanguageCode":"Japanese","characters":[{{manyCharacters}}]}""");
        Assert.NotNull(advice);

        Assert.Equal("unknown", advice.SourceLanguageCode);
        Assert.Equal(8, advice.Characters!.Count);
    }

    [Fact]
    public void SystemPrompt_IncludesNaturalOrderAndParentheticalSoundRules()
    {
        var prompt = ConfiguredTranslator.SystemPrompt("简体中文");

        Assert.Contains("自然语序", prompt);
        Assert.Contains("相邻行", prompt);
        Assert.Contains("悬空成分", prompt);
        Assert.Contains("99.", prompt);
        Assert.Contains("8%", prompt);
        Assert.Contains("Sun's", prompt);
        Assert.Contains("太阳的", prompt);
        Assert.Contains("圆括号", prompt);
        Assert.Contains("音效", prompt);
    }

    [Fact]
    public void SystemPrompt_JapaneseSourceNamesLanguageAndAddsReorderExamples()
    {
        var prompt = ConfiguredTranslator.SystemPrompt("简体中文", sourceLanguageCode: "ja");

        Assert.Contains("正在把日语字幕翻译成简体中文", prompt);
        Assert.Contains("日文→中文重排示例", prompt);
        Assert.Contains("左隣、あなたの", prompt);
        Assert.Contains("確かにほら救われたんだよ", prompt);
    }

    [Fact]
    public void SystemPrompt_NonJapaneseSourceOmitsJapaneseFewShot()
    {
        var prompt = ConfiguredTranslator.SystemPrompt("简体中文", sourceLanguageCode: "en");

        Assert.Contains("正在把英语字幕翻译成简体中文", prompt);
        Assert.Contains("99.", prompt);
        Assert.Contains("Sun's", prompt);
        Assert.DoesNotContain("日文→中文重排示例", prompt);
        Assert.DoesNotContain("左隣、あなたの", prompt);
    }

    [Fact]
    public void SystemPrompt_LegacyAdviceOverloadStaysCompatible()
    {
        var advice = new TranslationPromptAdvice(
            "测试摘要",
            "",
            [],
            TranslationPromptPreset.General);

        var prompt = ConfiguredTranslator.SystemPrompt("简体中文", advice);

        Assert.Contains("把用户给出的字幕翻译成简体中文", prompt);
        Assert.Contains("测试摘要", prompt);
    }

    [Fact]
    public async Task Translate_WithSmartPromptsButNoSummaryModel_ThrowsActionableError()
    {
        var srt = WriteSrt("smart-missing.srt",
        [
            new SubtitleCue(1, "00:00:01,000", "00:00:02,000", "Hello."),
        ]);
        var settings = new AppSettings
        {
            TranslationProvider = TranslationProvider.Anthropic,
            TranslationBaseUrl = "https://gateway.example.com",
            TranslationModel = "test-model",
            TranslationAuthToken = "tok",
            AIProvider = TranslationProvider.Anthropic,
            AIBaseUrl = "https://gateway.example.com",
            AIModel = "",
            AIAuthToken = "tok",
            SmartTranslationPromptsEnabled = true,
        };
        var translator = new ConfiguredTranslator(settings, new FakeHttpHandler());

        var ex = await Assert.ThrowsAsync<MoongateException>(() =>
            translator.TranslateAsync(srt, SubtitleStyle.ChineseOnly, null, _ => { }));

        Assert.Equal(MoongateErrorKind.TranslateFailed, ex.Kind);
        Assert.Contains("AI 翻译规划", ex.Detail);
        Assert.Contains("模型", ex.Detail);
    }

    [Fact]
    public void SplitTranslatedCueBySentence_SplitsLongMultiSentenceBilingualCue()
    {
        var pieces = ConfiguredTranslator.SplitTranslatedCueBySentence(
            "这是第一句，长度足够触发拆分。这里是第二句，也应该保留。最后还有第三句。",
            "This is the first sentence. This is the second sentence. Finally the third sentence.",
            "00:00:00,000",
            "00:00:09,000");

        Assert.True(pieces.Count >= 2);
        Assert.Equal("00:00:00,000", pieces[0].Start);
        Assert.Equal("00:00:09,000", pieces[^1].End);
        Assert.Equal(
            "这是第一句，长度足够触发拆分。这里是第二句，也应该保留。最后还有第三句。",
            string.Concat(pieces.Select(p => p.Text.Split('\n')[0])));
        Assert.Equal(
            "Thisisthefirstsentence.Thisisthesecondsentence.Finallythethirdsentence.",
            string.Concat(pieces.Select(p => p.Text.Split('\n').ElementAtOrDefault(1) ?? ""))
                .Replace(" ", ""));
    }

    [Fact]
    public async Task ResegmentForReadability_AnimePresetUsesAnimeSegmentationInstruction()
    {
        var cues = new List<SubtitleCue>
        {
            new(1, "00:00:00,000", "00:00:01,000", "おはよう"),
            new(2, "00:00:01,000", "00:00:02,000", "今日もいい天気"),
        };
        string? capturedSegmentSystem = null;
        var handler = new FakeHttpHandler
        {
            Responder = captured =>
            {
                var system = RequestSystem(captured.Body);
                if (system.Contains("待断句文本", StringComparison.Ordinal))
                {
                    capturedSegmentSystem = system;
                }
                return FakeHttpHandler.Json(200, AnthropicReply("1|おはよう。\n2|今日もいい天気。"));
            },
        };
        var translator = new ConfiguredTranslator(Settings, handler);

        await translator.ResegmentForReadabilityAsync(cues, TranslationPromptPreset.Anime, CancellationToken.None);

        Assert.NotNull(capturedSegmentSystem);
        Assert.Contains("对白断句助手", capturedSegmentSystem!);
        Assert.Contains("台词", capturedSegmentSystem!);
        Assert.DoesNotContain("歌词行", capturedSegmentSystem!);
    }

    [Fact]
    public async Task ResegmentForReadability_UsesProfileGuidanceForLectureAndShortSocial()
    {
        var expectations = new (TranslationPromptPreset Preset, string[] RequiredWords)[]
        {
            (TranslationPromptPreset.LectureCourse, ["术语边界", "因果", "逻辑"]),
            (TranslationPromptPreset.ShortSocial, ["节奏", "语义完整", "梗"]),
        };

        foreach (var (preset, requiredWords) in expectations)
        {
            var handler = new FakeHttpHandler
            {
                Responder = captured =>
                {
                    var system = RequestSystem(captured.Body);
                    foreach (var word in requiredWords)
                    {
                        Assert.Contains(word, system);
                    }
                    Assert.DoesNotContain("歌词行", system);
                    return FakeHttpHandler.Json(200, AnthropicReply("1|this explains the core idea."));
                },
            };
            var translator = new ConfiguredTranslator(Settings, handler);

            await translator.ResegmentForReadabilityAsync(
                [new SubtitleCue(1, "00:00:00,000", "00:00:02,000", "this explains the core idea")],
                preset,
                CancellationToken.None);
        }
    }

    [Fact]
    public async Task ResegmentForReadability_UnpunctuatedAsr_UsesStrictAlignedSegments()
    {
        var cues = new List<SubtitleCue>
        {
            new(1, "00:00:00,000", "00:00:01,000", "we know it"),
            new(2, "00:00:01,000", "00:00:02,000", "what is the vision"),
            new(3, "00:00:02,000", "00:00:03,000", "for what you see"),
            new(4, "00:00:03,000", "00:00:04,000", "coming next"),
            new(5, "00:00:04,000", "00:00:05,000", "we asked ourselves"),
            new(6, "00:00:05,000", "00:00:06,000", "how far can it go"),
        };
        var handler = new FakeHttpHandler
        {
            Responder = _ => FakeHttpHandler.Json(200, AnthropicReply(
                "1|we know it what is the vision for what you see coming next.\n2|we asked ourselves how far can it go?")),
        };
        var translator = new ConfiguredTranslator(Settings, handler);

        var output = await translator.ResegmentForReadabilityAsync(cues, CancellationToken.None);

        Assert.Equal(2, output.Count);
        Assert.Equal("we know it what is the vision for what you see coming next.", output[0].Text);
        Assert.Equal("we asked ourselves how far can it go?", output[1].Text);
        Assert.Equal("00:00:00,000", output[0].Start);
        Assert.Equal("00:00:06,000", output[^1].End);
    }

    [Fact]
    public async Task ResegmentForReadability_UsesCueLocalTimeInterpolation()
    {
        var cues = new List<SubtitleCue>
        {
            new(1, "00:00:00,000", "00:00:10,000", "alpha beta"),
            new(2, "00:00:10,000", "00:00:11,000", "gamma delta epsilon zeta"),
            new(3, "00:00:11,000", "00:00:12,000", "eta theta iota kappa"),
            new(4, "00:00:12,000", "00:00:13,000", "lambda mu nu xi"),
            new(5, "00:00:13,000", "00:00:14,000", "omicron pi rho sigma tau upsilon phi chi psi omega"),
        };
        var handler = new FakeHttpHandler
        {
            Responder = _ => FakeHttpHandler.Json(200, AnthropicReply(
                "1|alpha beta.\n2|gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron pi rho sigma tau upsilon phi chi psi omega.")),
        };
        var translator = new ConfiguredTranslator(Settings, handler);

        var output = await translator.ResegmentForReadabilityAsync(cues, CancellationToken.None);

        Assert.Equal(2, output.Count);
        Assert.Equal("00:00:10,000", output[0].End);
        Assert.Equal("00:00:10,000", output[1].Start);
    }

    [Fact]
    public async Task ResegmentForReadability_LongInputChunksAtCueBoundaries()
    {
        var cues = NumberedWordCues(cueCount: 35, tokensPerCue: 35);
        var handler = new FakeHttpHandler
        {
            Responder = captured =>
            {
                var transcript = SegmentationTranscript(captured.Body);
                return FakeHttpHandler.Json(200, AnthropicReply($"1|{transcript}."));
            },
        };
        var translator = new ConfiguredTranslator(Settings, handler);

        var output = await translator.ResegmentForReadabilityAsync(cues, CancellationToken.None);

        Assert.True(handler.Requests.Count >= 2);
        Assert.True(output.Count >= 2);
        Assert.True(output.Count < cues.Count);
        Assert.Equal("00:00:00,000", output[0].Start);
        Assert.Equal(cues[^1].End, output[^1].End);
    }

    [Fact]
    public async Task ResegmentForReadability_OutputLimitHalvesChunkAndRetries()
    {
        var cues = NumberedWordCues(cueCount: 8, tokensPerCue: 4);
        var attempts = 0;
        var handler = new FakeHttpHandler
        {
            Responder = captured =>
            {
                attempts++;
                if (attempts == 1)
                {
                    return FakeHttpHandler.Json(200, AnthropicReply("1|partial", "max_tokens"));
                }
                var transcript = SegmentationTranscript(captured.Body);
                return FakeHttpHandler.Json(200, AnthropicReply($"1|{transcript}."));
            },
        };
        var translator = new ConfiguredTranslator(Settings, handler);

        var output = await translator.ResegmentForReadabilityAsync(cues, CancellationToken.None);

        Assert.Equal(3, attempts);
        Assert.Equal(2, output.Count);
        Assert.Equal("00:00:00,000", output[0].Start);
        Assert.Equal(cues[^1].End, output[^1].End);
    }

    [Fact]
    public async Task ResegmentForReadability_LongSegmentSafetySplitsAndClamps()
    {
        var cues = NumberedWordCues(cueCount: 10, tokensPerCue: 3);
        var transcript = string.Join(' ', cues.Select(c => ConfiguredTranslator.Flattened(c.Text)));
        var tokens = transcript.Split(' ');
        var segment = string.Join(' ', tokens.Take(15)) + ", " + string.Join(' ', tokens.Skip(15));
        var handler = new FakeHttpHandler
        {
            Responder = _ => FakeHttpHandler.Json(200, AnthropicReply($"1|{segment}.")),
        };
        var translator = new ConfiguredTranslator(Settings, handler);

        var output = await translator.ResegmentForReadabilityAsync(cues, CancellationToken.None);

        Assert.Equal(2, output.Count);
        Assert.Equal(1, output[0].Index);
        Assert.Equal(2, output[1].Index);
        Assert.True(SrtTools.SrtTimeToSeconds(output[0].End) <= SrtTools.SrtTimeToSeconds(output[1].Start));
        Assert.Equal("00:00:00,000", output[0].Start);
        Assert.Equal(cues[^1].End, output[^1].End);
    }

    [Fact]
    public async Task ResegmentForReadability_ShortSegmentsMerge()
    {
        var cues = new List<SubtitleCue>
        {
            new(1, "00:00:00,000", "00:00:01,000", "alpha"),
            new(2, "00:00:01,000", "00:00:02,000", "beta"),
            new(3, "00:00:02,000", "00:00:03,000", "gamma"),
            new(4, "00:00:03,000", "00:00:04,000", "delta"),
            new(5, "00:00:04,000", "00:00:05,000", "epsilon"),
        };
        var handler = new FakeHttpHandler
        {
            Responder = _ => FakeHttpHandler.Json(200, AnthropicReply(
                "1|alpha beta.\n2|gamma delta.\n3|epsilon.")),
        };
        var translator = new ConfiguredTranslator(Settings, handler);

        var output = await translator.ResegmentForReadabilityAsync(cues, CancellationToken.None);

        var single = Assert.Single(output);
        Assert.Equal("alpha beta. gamma delta. epsilon.", single.Text);
        Assert.Equal("00:00:00,000", single.Start);
        Assert.Equal("00:00:05,000", single.End);
    }

    [Fact]
    public async Task ResegmentForReadability_AlignmentFailure_ReturnsOriginalCues()
    {
        var cues = new List<SubtitleCue>
        {
            new(1, "00:00:00,000", "00:00:01,000", "we know it"),
            new(2, "00:00:01,000", "00:00:02,000", "what is the vision"),
            new(3, "00:00:02,000", "00:00:03,000", "for what you see"),
            new(4, "00:00:03,000", "00:00:04,000", "coming next"),
            new(5, "00:00:04,000", "00:00:05,000", "we asked ourselves"),
            new(6, "00:00:05,000", "00:00:06,000", "how far can it go"),
        };
        var handler = new FakeHttpHandler
        {
            Responder = _ => FakeHttpHandler.Json(200, AnthropicReply("1|we know completely different words.")),
        };
        var translator = new ConfiguredTranslator(Settings, handler);

        var output = await translator.ResegmentForReadabilityAsync(cues, CancellationToken.None);

        Assert.Equal(cues.Select(c => c.Text), output.Select(c => c.Text));
    }

    private static List<SubtitleCue> AsrCues()
    {
        // 8 条逐字、无标点的碎句（典型 ASR 自动字幕）。
        string[] words =
        [
            "we know it", "what is the vision", "for what you see", "coming next",
            "we asked ourselves", "how far can it go", "and what comes", "after that",
        ];
        return words.Select((t, i) => new SubtitleCue(
            i + 1, SrtTools.SecondsToSrtTime(i), SrtTools.SecondsToSrtTime(i + 1), t)).ToList();
    }

    // 8 条逐字、无标点的日文碎句（典型 Whisper 输出，含用户报的「顔 / 洗って」割裂例）。
    private static List<SubtitleCue> JapaneseAsrCues()
    {
        string[] words = ["おはよう", "起きられて", "えらい", "顔", "洗って", "えらい", "テレビ見るのも", "えらい"];
        return words.Select((t, i) => new SubtitleCue(
            i + 1, SrtTools.SecondsToSrtTime(i), SrtTools.SecondsToSrtTime(i + 1), t)).ToList();
    }

    private static List<SubtitleCue> JapaneseLyricsCues()
    {
        string[] parts =
        [
            "青い", "世界", "好きなものを", "好きだという", "怖く", "て",
            "仕方ないけど", "本当の自分", "出会えた", "気がしたんだ",
        ];
        return parts.Select((t, i) => new SubtitleCue(
            i + 1,
            SrtTools.SecondsToSrtTime(i * 2.0),
            SrtTools.SecondsToSrtTime(i * 2.0 + 1.7),
            t)).ToList();
    }

    [Fact]
    public async Task ResegmentForReadability_Cjk_AlignsByCharacterAndRebuildsSentences()
    {
        // 日文无词间空格：按词对齐必然失败而回退（旧行为）。逐字符对齐后，模型断成完整句且
        // 字符序列不变 → 对齐通过 → 合并出句子级字幕，时间按字符插值保留。
        var handler = new FakeHttpHandler
        {
            Responder = _ => FakeHttpHandler.Json(200, AnthropicReply(
                "1|おはよう。\n2|起きられてえらい。\n3|顔洗ってえらい。\n4|テレビ見るのもえらい。")),
        };
        var translator = new ConfiguredTranslator(Settings, handler);

        var output = await translator.ResegmentForReadabilityAsync(JapaneseAsrCues(), CancellationToken.None);

        Assert.Equal(4, output.Count);
        Assert.Equal("00:00:00,000", output[0].Start);
        Assert.Equal("顔洗ってえらい。", output[2].Text);   // 「顔」与「洗って」并入同一句，不再割裂
        Assert.Equal("00:00:08,000", output[^1].End);
    }

    [Fact]
    public async Task ResegmentForReadability_CjkLongSegment_SplitsWithoutRepeatingWholeLine()
    {
        string[] parts = ["青い世界", "を見て", "胸の奥", "怖くて", "仕方ない", "けど今日も", "前へ進む"];
        var cues = parts.Select((text, i) => new SubtitleCue(
            i + 1,
            SrtTools.SecondsToSrtTime(i),
            SrtTools.SecondsToSrtTime(i + 1),
            text)).ToList();
        var joined = string.Concat(parts);
        var handler = new FakeHttpHandler
        {
            Responder = _ => FakeHttpHandler.Json(200, AnthropicReply($"1|{joined}。")),
        };
        var translator = new ConfiguredTranslator(Settings, handler);

        var output = await translator.ResegmentForReadabilityAsync(
            cues,
            TranslationPromptPreset.SongLyrics,
            CancellationToken.None);

        Assert.True(output.Count > 1, "long CJK lyric line should be safely split by time");
        Assert.Equal(
            joined,
            string.Concat(output.Select(cue => cue.Text)).Replace("。", "", StringComparison.Ordinal));
        Assert.Equal(output.Count, output.Select(cue => cue.Text).Distinct(StringComparer.Ordinal).Count());
    }

    [Fact]
    public async Task ResegmentForReadability_SongLyricsPreset_UsesLyricsLinePrompt()
    {
        var handler = new FakeHttpHandler
        {
            Responder = captured =>
            {
                var system = RequestSystem(captured.Body);
                Assert.Contains("歌词行", system);
                Assert.Contains("乐句", system);
                Assert.DoesNotContain("按完整句子重新断行", system);
                return FakeHttpHandler.Json(200, AnthropicReply(
                    "1|青い世界\n2|好きなものを好きだという\n3|怖くて仕方ないけど\n4|本当の自分出会えた気がしたんだ"));
            },
        };
        var translator = new ConfiguredTranslator(Settings, handler);

        var output = await translator.ResegmentForReadabilityAsync(
            JapaneseLyricsCues(),
            TranslationPromptPreset.SongLyrics,
            CancellationToken.None);

        Assert.Equal(
            ["青い世界", "好きなものを好きだという", "怖くて仕方ないけど", "本当の自分出会えた気がしたんだ"],
            output.Select(c => c.Text).ToArray());
    }

    [Fact]
    public async Task ResegmentForReadability_Cjk_FallsBackWhenCharactersChanged()
    {
        // 模型擅自改字（多了「猫」）→ 字符序列对不上 → 原样返回。
        var input = JapaneseAsrCues();
        var handler = new FakeHttpHandler
        {
            Responder = _ => FakeHttpHandler.Json(200, AnthropicReply("1|おはよう猫。\n2|起きられてえらい。")),
        };
        var translator = new ConfiguredTranslator(Settings, handler);

        var output = await translator.ResegmentForReadabilityAsync(input, CancellationToken.None);

        Assert.Equal(input.Select(c => c.Text), output.Select(c => c.Text));
    }

    [Fact]
    public async Task ResegmentForReadability_SongLyrics_FallsBackOnInternalDuplicateNoise()
    {
        List<SubtitleCue> input =
        [
            new SubtitleCue(1, "00:01:59,880", "00:02:02,000", "好きなことを続けること、"),
            new SubtitleCue(2, "00:02:02,000", "00:02:04,618", "好こときをな続ことける、そ"),
            new SubtitleCue(3, "00:02:04,618", "00:02:08,000", "れは楽しいだけじゃない"),
        ];
        var handler = new FakeHttpHandler
        {
            Responder = _ => FakeHttpHandler.Json(200, AnthropicReply(
                "1|好きなことを続けること、好こときをな続ことける、それは楽しいだけじゃない")),
        };
        var translator = new ConfiguredTranslator(Settings, handler);

        var output = await translator.ResegmentForReadabilityAsync(
            input,
            TranslationPromptPreset.SongLyrics,
            CancellationToken.None);

        Assert.Equal(input.Select(c => c.Text), output.Select(c => c.Text));
    }

    [Fact]
    public async Task Translate_LocalAsrSource_ResegmentsWithoutSmartButDoesNotOverwriteSource()
    {
        // 本地 Whisper 源字幕可以在翻译内存视图里重分段，但不能把 LLM 结果写回源 .local-asr.ja.srt。
        var srt = WriteSrt("clip.local-asr.ja.srt", JapaneseAsrCues());
        var handler = new FakeHttpHandler
        {
            Responder = captured =>
            {
                if (RequestSystem(captured.Body).Contains("待断句文本", StringComparison.Ordinal))
                {
                    return FakeHttpHandler.Json(200, AnthropicReply(
                        "1|おはよう。\n2|起きられてえらい。\n3|顔洗ってえらい。\n4|テレビ見るのもえらい。"));
                }
                return FakeHttpHandler.Json(200, AnthropicReply(TranslateAllLines(captured.Body)));
            },
        };
        var translator = new ConfiguredTranslator(Settings, handler); // SmartTranslationPromptsEnabled = false

        var output = await translator.TranslateAsync(srt, SubtitleStyle.ChineseOnly, null, _ => { });

        var unchangedSource = SrtTools.ParseSrt(File.ReadAllText(srt));
        Assert.Equal(JapaneseAsrCues().Select(c => c.Text), unchangedSource.Select(c => c.Text));
        var result = SrtTools.ParseSrt(File.ReadAllText(output));
        Assert.Equal(4, result.Count);
    }

    [Fact]
    public async Task Translate_LocalAsrSource_UsesSmartSongLyricsAdviceBeforeResegment()
    {
        var srt = WriteSrt("clip.local-asr.ja.srt", JapaneseLyricsCues());
        var sawLyricsSegmentPrompt = false;
        var sawLyricsTranslationPrompt = false;
        var settings = Settings with { SmartTranslationPromptsEnabled = true };
        var handler = new FakeHttpHandler
        {
            Responder = captured =>
            {
                var system = RequestSystem(captured.Body);
                if (system.Contains("字幕流水线规划器", StringComparison.Ordinal))
                {
                    Assert.Contains("- songLyrics：", system);
                    Assert.Contains("意象", system);
                    Assert.Contains("- lectureCourse：", system);
                    Assert.Contains("严肃科普", system);
                    Assert.Contains("- shortSocial：", system);
                    Assert.Contains("快节奏", system);
                    return FakeHttpHandler.Json(200, AnthropicReply(
                        "{\"summary\":\"日语歌曲歌词\",\"context\":\"MV 演唱内容\",\"preset\":\"songLyrics\"}"));
                }
                if (system.Contains("待断句文本", StringComparison.Ordinal))
                {
                    sawLyricsSegmentPrompt = system.Contains("歌词行", StringComparison.Ordinal)
                        && !system.Contains("按完整句子重新断行", StringComparison.Ordinal);
                    return FakeHttpHandler.Json(200, AnthropicReply(
                        "1|青い世界\n2|好きなものを好きだという\n3|怖くて仕方ないけど\n4|本当の自分出会えた気がしたんだ"));
                }
                sawLyricsTranslationPrompt = system.Contains("中文歌词译本", StringComparison.Ordinal);
                return FakeHttpHandler.Json(200, AnthropicReply(TranslateAllLines(captured.Body)));
            },
        };
        var translator = new ConfiguredTranslator(settings, handler);

        var output = await translator.TranslateAsync(srt, SubtitleStyle.ChineseOnly, null, _ => { });

        var result = SrtTools.ParseSrt(File.ReadAllText(output));
        Assert.Equal(4, result.Count);
        Assert.True(sawLyricsSegmentPrompt);
        Assert.True(sawLyricsTranslationPrompt);
        var unchangedSource = SrtTools.ParseSrt(File.ReadAllText(srt));
        Assert.Equal(
            JapaneseLyricsCues().Select(c => c.Text),
            unchangedSource.Select(c => c.Text));
    }

    [Fact]
    public async Task Translate_LocalAsrSource_UsesLyricsFallbackForMusicFilenameWhenSmartDisabled()
    {
        var srt = WriteSrt("YOASOBI Official Music Video.local-asr.ja.srt", JapaneseLyricsCues());
        var sawLyricsSegmentPrompt = false;
        var sawLyricsTranslationPrompt = false;
        var handler = new FakeHttpHandler
        {
            Responder = captured =>
            {
                var system = RequestSystem(captured.Body);
                Assert.DoesNotContain("字幕流水线规划器", system);
                if (system.Contains("待断句文本", StringComparison.Ordinal))
                {
                    sawLyricsSegmentPrompt = system.Contains("歌词行", StringComparison.Ordinal)
                        && !system.Contains("按完整句子重新断行", StringComparison.Ordinal);
                    return FakeHttpHandler.Json(200, AnthropicReply(
                        "1|青い世界\n2|好きなものを好きだという\n3|怖くて仕方ないけど\n4|本当の自分出会えた気がしたんだ"));
                }
                sawLyricsTranslationPrompt = system.Contains("中文歌词译本", StringComparison.Ordinal);
                return FakeHttpHandler.Json(200, AnthropicReply(TranslateAllLines(captured.Body)));
            },
        };
        var translator = new ConfiguredTranslator(Settings, handler);

        var output = await translator.TranslateAsync(srt, SubtitleStyle.ChineseOnly, null, _ => { });

        var result = SrtTools.ParseSrt(File.ReadAllText(output));
        Assert.Equal(4, result.Count);
        Assert.True(sawLyricsSegmentPrompt);
        Assert.True(sawLyricsTranslationPrompt);
    }

    private static List<SubtitleCue> MultilineAsrCues() =>
        Enumerable.Range(0, 20)
            .Select(i => new SubtitleCue(
                i + 1,
                SrtTools.SecondsToSrtTime(i),
                SrtTools.SecondsToSrtTime(i + 1),
                $"word{i} line\nnext{i} piece"))
            .ToList();

    [Fact]
    public void LooksLikeAutoCaption_DetectsUnpunctuatedShortCues()
    {
        Assert.True(ConfiguredTranslator.LooksLikeAutoCaption(AsrCues()));
        var normal = Enumerable.Range(1, 8).Select(i => new SubtitleCue(
            i, SrtTools.SecondsToSrtTime(i), SrtTools.SecondsToSrtTime(i + 1), $"This is line {i}.")).ToList();
        Assert.False(ConfiguredTranslator.LooksLikeAutoCaption(normal));
        Assert.False(ConfiguredTranslator.LooksLikeAutoCaption(AsrCues().Take(3).ToList()));
        // 无标点但每条很长（≥6s）→ 不判定。
        var longCues = Enumerable.Range(0, 8).Select(i => new SubtitleCue(
            i + 1, SrtTools.SecondsToSrtTime(i * 8), SrtTools.SecondsToSrtTime(i * 8 + 8),
            "some words without period here")).ToList();
        Assert.False(ConfiguredTranslator.LooksLikeAutoCaption(longCues));
        // 无标点但大量多行排版 → 不判定。
        var multiline = Enumerable.Range(0, 8).Select(i => new SubtitleCue(
            i + 1, SrtTools.SecondsToSrtTime(i), SrtTools.SecondsToSrtTime(i + 1),
            "first line\nsecond line")).ToList();
        Assert.False(ConfiguredTranslator.LooksLikeAutoCaption(multiline));
        Assert.True(ConfiguredTranslator.LooksLikeAutoCaption(MultilineAsrCues()));
    }

    [Fact]
    public async Task Translate_ResegmentsAsrCaption_WhenSmartEnabled()
    {
        var srt = WriteSrt("asr.en.srt", AsrCues());
        var segmentCalls = 0;
        var settings = Settings with { SmartTranslationPromptsEnabled = true };
        var handler = new FakeHttpHandler
        {
            Responder = captured =>
            {
                var system = RequestSystem(captured.Body);
                if (system.Contains("待断句文本", StringComparison.Ordinal))
                {
                    segmentCalls++;
                    return FakeHttpHandler.Json(200, AnthropicReply(
                        "1|we know it what is the vision for what you see coming next.\n2|we asked ourselves how far can it go and what comes after that?"));
                }
                if (system.Contains("字幕流水线规划器", StringComparison.Ordinal))
                {
                    return FakeHttpHandler.Json(200, AnthropicReply("{\"summary\":\"测试\",\"preset\":\"general\"}"));
                }
                return FakeHttpHandler.Json(200, AnthropicReply(TranslateAllLines(captured.Body)));
            },
        };
        var translator = new ConfiguredTranslator(settings, handler);

        var output = await translator.TranslateAsync(srt, SubtitleStyle.ChineseOnly, null, _ => { });

        var result = SrtTools.ParseSrt(File.ReadAllText(output));
        Assert.True(segmentCalls > 0, "smart 开 + ASR 应触发重分段");
        Assert.Equal(2, result.Count);
    }

    [Fact]
    public async Task Translate_SkipsResegment_WhenSmartDisabled()
    {
        var srt = WriteSrt("asr2.en.srt", AsrCues());
        var segmentCalls = 0;
        var handler = new FakeHttpHandler
        {
            Responder = captured =>
            {
                if (RequestSystem(captured.Body).Contains("待断句文本", StringComparison.Ordinal)) segmentCalls++;
                return FakeHttpHandler.Json(200, AnthropicReply(TranslateAllLines(captured.Body)));
            },
        };
        var translator = new ConfiguredTranslator(Settings, handler); // SmartTranslationPromptsEnabled = false

        var output = await translator.TranslateAsync(srt, SubtitleStyle.ChineseOnly, null, _ => { });

        var result = SrtTools.ParseSrt(File.ReadAllText(output));
        Assert.Equal(0, segmentCalls);
        Assert.Equal(SrtTools.CleanCues(AsrCues()).Count, result.Count);
    }

    private static List<SubtitleCue> NumberedWordCues(int cueCount, int tokensPerCue)
    {
        var token = 1;
        var cues = new List<SubtitleCue>();
        for (var cueIndex = 0; cueIndex < cueCount; cueIndex++)
        {
            var words = new List<string>();
            for (var i = 0; i < tokensPerCue; i++)
            {
                words.Add($"word{token:D5}");
                token++;
            }
            cues.Add(new SubtitleCue(
                cueIndex + 1,
                SrtTools.SecondsToSrtTime(cueIndex),
                SrtTools.SecondsToSrtTime(cueIndex + 1),
                string.Join(' ', words)));
        }
        return cues;
    }

    private static string SegmentationTranscript(string requestBody)
    {
        using var doc = JsonDocument.Parse(requestBody);
        var content = doc.RootElement.GetProperty("messages")[0].GetProperty("content").GetString()!;
        var marker = "待断句文本：\n";
        var idx = content.LastIndexOf(marker, StringComparison.Ordinal);
        return idx < 0 ? content.Trim() : content[(idx + marker.Length)..].Trim();
    }

    private static string RequestSystem(string requestBody)
    {
        using var doc = JsonDocument.Parse(requestBody);
        return doc.RootElement.GetProperty("system").GetString() ?? "";
    }

    /// <summary>译文被输出上限截断 → 30 条块减半成 15+15 重试；最终全部翻完。</summary>
    [Fact]
    public async Task Translate_TruncatedChunk_RetriesWithHalvedChunks()
    {
        var cues = Enumerable.Range(1, 40).Select(i => new SubtitleCue(
            i, SrtTools.SecondsToSrtTime(i * 10), SrtTools.SecondsToSrtTime(i * 10 + 2), $"Sentence {i}."));
        var srt = WriteSrt("long.srt", cues);

        var handler = new FakeHttpHandler();
        handler.Responder = captured =>
        {
            using var doc = JsonDocument.Parse(captured.Body);
            var content = doc.RootElement.GetProperty("messages")[0].GetProperty("content").GetString()!;
            var lineCount = content.Split('\n').Length;
            // 30 条的大块：模拟输出截断（stop_reason=max_tokens）；其余正常回贴
            return lineCount == 30
                ? FakeHttpHandler.Json(200, AnthropicReply("1|不完整", "max_tokens"))
                : FakeHttpHandler.Json(200, AnthropicReply(TranslateAllLines(captured.Body)));
        };
        var translator = new ConfiguredTranslator(Settings, handler);
        var progressValues = new List<double>();
        var progressLock = new object();
        var output = await translator.TranslateAsync(srt, SubtitleStyle.ChineseOnly, null,
            p => { lock (progressLock) progressValues.Add(p); });

        // 请求：30 条块 ×1（截断）→ 15 条块 ×2 + 10 条块 ×1 = 4 次
        Assert.Equal(4, handler.Requests.Count);
        var result = SrtTools.ParseSrt(File.ReadAllText(output));
        Assert.Equal(40, result.Count);
        for (var i = 0; i < 40; i++)
        {
            Assert.Equal($"中{i + 1}", result[i].Text);
        }
        lock (progressLock)
        {
            Assert.Equal(1.0, progressValues[^1], precision: 9);
        }
    }

    [Fact]
    public async Task Translate_MissingLinesInLongChunk_RetriesWithHalvedChunks()
    {
        var cues = Enumerable.Range(1, 30).Select(i => new SubtitleCue(
            i, SrtTools.SecondsToSrtTime(i * 10), SrtTools.SecondsToSrtTime(i * 10 + 2), $"Sentence {i}."));
        var srt = WriteSrt("long-missing.srt", cues);

        var handler = new FakeHttpHandler();
        handler.Responder = captured =>
        {
            using var doc = JsonDocument.Parse(captured.Body);
            var content = doc.RootElement.GetProperty("messages")[0].GetProperty("content").GetString()!;
            var lineCount = content.Split('\n').Length;
            return lineCount == 30
                ? FakeHttpHandler.Json(200, AnthropicReply("1|中1"))
                : FakeHttpHandler.Json(200, AnthropicReply(TranslateAllLines(captured.Body)));
        };
        var translator = new ConfiguredTranslator(Settings, handler);

        var output = await translator.TranslateAsync(srt, SubtitleStyle.ChineseOnly, null, _ => { });

        Assert.Equal(3, handler.Requests.Count);
        var result = SrtTools.ParseSrt(File.ReadAllText(output));
        Assert.Equal(30, result.Count);
        for (var i = 0; i < 30; i++)
        {
            Assert.Equal($"中{i + 1}", result[i].Text);
        }
    }

    /// <summary>译文缺失任意行 → 对缺失行逐行补齐，仍失败则回退原文，整体不归零。</summary>
    [Fact]
    public async Task Translate_MissingLines_FallsBackWithoutFailingWholeTranslation()
    {
        var cues = Enumerable.Range(1, 3).Select(i => new SubtitleCue(
            i, SrtTools.SecondsToSrtTime(i * 10), SrtTools.SecondsToSrtTime(i * 10 + 2), $"Sentence {i}."));
        var srt = WriteSrt("missing.srt", cues);
        var handler = new FakeHttpHandler
        {
            Responder = captured =>
            {
                using var doc = JsonDocument.Parse(captured.Body);
                var content = doc.RootElement.GetProperty("messages")[0].GetProperty("content").GetString()!;
                return content == "2|Sentence 2."
                    ? FakeHttpHandler.Json(200, AnthropicReply(""))
                    : FakeHttpHandler.Json(200, AnthropicReply("1|一\n3|三"));
            },
        };
        var translator = new ConfiguredTranslator(Settings, handler);

        var output = await translator.TranslateAsync(srt, SubtitleStyle.ChineseOnly, null, _ => { });

        var result = SrtTools.ParseSrt(File.ReadAllText(output));
        Assert.Equal(["一", "Sentence 2.", "三"], result.Select(c => c.Text).ToArray());
    }

    [Fact]
    public async Task Translate_TransientNetworkError_RetriesInsideChunk()
    {
        var srt = WriteSrt("retry.srt",
        [
            new SubtitleCue(1, "00:00:01,000", "00:00:02,000", "Hello."),
            new SubtitleCue(2, "00:00:03,000", "00:00:04,000", "Bye."),
        ]);
        var attempts = 0;
        var handler = new FakeHttpHandler
        {
            Responder = captured =>
            {
                attempts++;
                if (attempts == 1) throw new HttpRequestException("timeout");
                return FakeHttpHandler.Json(200, AnthropicReply(TranslateAllLines(captured.Body)));
            },
        };
        var translator = new ConfiguredTranslator(Settings, handler);

        var output = await translator.TranslateAsync(srt, SubtitleStyle.ChineseOnly, null, _ => { });

        var result = SrtTools.ParseSrt(File.ReadAllText(output));
        Assert.Equal(["中1", "中2"], result.Select(c => c.Text).ToArray());
        Assert.Equal(2, attempts);
    }

    [Fact]
    public void ParseReply_IgnoresMalformedLines()
    {
        var map = ConfiguredTranslator.ParseReply("1|你好\nnoise\n2| 世界 \nx|bad\n3|");
        Assert.Equal("你好", map[1]);
        Assert.Equal("世界", map[2]);
        Assert.Equal("", map[3]);
        Assert.Equal(3, map.Count);
    }

    [Fact]
    public void Flattened_JoinsLinesWithSpace()
    {
        Assert.Equal("a b", ConfiguredTranslator.Flattened(" a \n\n b "));
    }

    [Fact]
    public void Flattened_NormalizesSubtitleEscapesBeforeTranslation()
    {
        Assert.Equal("NVIDIA CEO next line here",
            ConfiguredTranslator.Flattened("NVIDIA\\hCEO\\Nnext&nbsp;line\u00A0here"));
    }

    [Fact]
    public void SanitizeTranslation_StripsLeadingDialogueDash()
    {
        Assert.Equal("几乎从来不取决于硬件本身", ConfiguredTranslator.SanitizeTranslation("– 几乎从来不取决于硬件本身"));
        Assert.Equal("你好", ConfiguredTranslator.SanitizeTranslation("- 你好"));
        Assert.Equal("你好", ConfiguredTranslator.SanitizeTranslation("— 你好"));
    }

    [Fact]
    public void SanitizeTranslation_CollapsesResidualSlash()
    {
        Assert.Equal("可你要真想玩，《马力欧赛车 世界》",
            ConfiguredTranslator.SanitizeTranslation("– 可你要真想玩 / 《马力欧赛车 世界》"));
    }

    [Fact]
    public void SanitizeTranslation_LeavesCleanTextUntouched()
    {
        Assert.Equal("这是 well-known 的事", ConfiguredTranslator.SanitizeTranslation("这是 well-known 的事"));
    }

    [Fact]
    public void SanitizeTranslation_RemovesChineseTerminalPeriodButKeepsExpressivePunctuation()
    {
        Assert.Equal("这样你就能坐在沙发上，连电视玩",
            ConfiguredTranslator.SanitizeTranslation("这样你就能坐在沙发上，连电视玩。"));
        Assert.Equal("真的吗？", ConfiguredTranslator.SanitizeTranslation("真的吗？"));
        Assert.Equal("太好了！", ConfiguredTranslator.SanitizeTranslation("太好了！"));
        Assert.Equal("等等……", ConfiguredTranslator.SanitizeTranslation("等等……"));
    }
}
