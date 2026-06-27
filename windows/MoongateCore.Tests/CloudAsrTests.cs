using System.Net.Http;
using Moongate.Core;

namespace MoongateCore.Tests;

public class CloudAsrTests
{
    [Fact]
    public void CloudTranscriptAlignerUsesGuideTimelineForLatinTranscript()
    {
        var aligned = CloudTranscriptAligner.Align(
            "hello bright moon gate",
            [
                new SubtitleCue(1, "00:00:00,000", "00:00:01,000", "hello"),
                new SubtitleCue(2, "00:00:01,000", "00:00:03,000", "bright moon"),
            ]);

        Assert.Equal(["00:00:00,000", "00:00:01,000"], aligned.Select(c => c.Start).ToArray());
        Assert.Equal(["00:00:01,000", "00:00:03,000"], aligned.Select(c => c.End).ToArray());
        Assert.Equal(["hello", "bright moon gate"], aligned.Select(c => c.Text).ToArray());
    }

    [Fact]
    public async Task OpenAICloudAsrTranscribesJsonAndAlignsTextToGuideSrt()
    {
        var dir = Path.Combine(Path.GetTempPath(), $"moongate-cloud-asr-{Guid.NewGuid():N}");
        Directory.CreateDirectory(dir);
        try
        {
            var video = Path.Combine(dir, "clip.wav");
            await File.WriteAllTextAsync(video, "RIFF audio");
            var guide = Path.Combine(dir, "clip.local-asr.ja.srt");
            await File.WriteAllTextAsync(guide, """
            1
            00:00:00,000 --> 00:00:01,000
            コウペンちゃん

            2
            00:00:01,000 --> 00:00:03,000
            チョコバナナ 食べよう

            """);
            var output = Path.Combine(dir, "clip.cloud-asr.aligned.ja.srt");
            var handler = new FakeHttpHandler
            {
                Responder = _ => FakeHttpHandler.Json(200, """{"text":"コウペンちゃん チョコバナナを食べよう"}""")
            };
            var generator = new OpenAICloudAsrSubtitleGenerator(
                "https://api.openai.com",
                "sk-test",
                "gpt-4o-transcribe",
                new HttpClient(handler));

            var written = await generator.TranscribeToAlignedSrtAsync(
                video,
                "ja",
                guide,
                output,
                "title=コウペンちゃん");

            Assert.Equal(output, written);
            var request = Assert.Single(handler.Requests);
            Assert.Contains("name=response_format", request.Body);
            Assert.Contains("json", request.Body);
            Assert.DoesNotContain("srt", request.Body);
            var aligned = SrtTools.ParseSrt(await File.ReadAllTextAsync(output));
            Assert.Equal(["00:00:00,000", "00:00:01,000"], aligned.Select(c => c.Start).ToArray());
            Assert.Equal(["00:00:01,000", "00:00:03,000"], aligned.Select(c => c.End).ToArray());
            Assert.Equal("コウペンちゃんチョコバナナを食べよう", string.Concat(aligned.Select(c => c.Text)));
        }
        finally
        {
            try { Directory.Delete(dir, true); } catch { /* ignored */ }
        }
    }

    [Fact]
    public async Task FactoryCreatesAlignedCloudAsrGeneratorWhenJsonModelHasLocalTimingGuide()
    {
        var dir = Path.Combine(Path.GetTempPath(), $"moongate-cloud-asr-{Guid.NewGuid():N}");
        Directory.CreateDirectory(dir);
        try
        {
            var video = Path.Combine(dir, "clip.wav");
            await File.WriteAllTextAsync(video, "RIFF audio");
            var local = new FakeLocalAsrGenerator
            {
                OutputSrt = """
                1
                00:00:00,000 --> 00:00:01,000
                コウペンちゃん

                2
                00:00:01,000 --> 00:00:03,000
                チョコバナナ 食べよう

                """
            };
            var handler = new FakeHttpHandler
            {
                Responder = _ => FakeHttpHandler.Json(200, """{"text":"コウペンちゃん チョコバナナを食べよう"}""")
            };
            var generator = CloudAsrGeneratorFactory.Create(
                new AppSettings
                {
                    CloudAsrEnabled = true,
                    CloudAsrConsentAccepted = true,
                    CloudAsrBaseUrl = "https://api.openai.com",
                    CloudAsrModel = "gpt-4o-transcribe",
                    CloudAsrAuthToken = "sk-test",
                },
                local,
                new HttpClient(handler));

            var source = await Assert.IsType<AlignedOpenAICloudAsrSubtitleGenerator>(generator)
                .GenerateSourceSubtitleAsync(video, "ja", null);

            Assert.Equal(1, local.CallCount);
            Assert.EndsWith(".cloud-asr.ja.srt", source.Url);
            var aligned = SrtTools.ParseSrt(await File.ReadAllTextAsync(source.Url));
            Assert.Equal(["00:00:00,000", "00:00:01,000"], aligned.Select(c => c.Start).ToArray());
            Assert.Equal("コウペンちゃんチョコバナナを食べよう", string.Concat(aligned.Select(c => c.Text)));
        }
        finally
        {
            try { Directory.Delete(dir, true); } catch { /* ignored */ }
        }
    }
}
