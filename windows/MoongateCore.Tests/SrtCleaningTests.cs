using Moongate.Core;

namespace MoongateCore.Tests;

public class SrtParsingTests
{
    [Fact]
    public void ParseSrt_NormalFile_ParsesAllFields()
    {
        const string srt = """
            1
            00:00:01,000 --> 00:00:02,500
            First line.

            2
            00:00:03,000 --> 00:00:04,500
            Second line
            continued.
            """;
        var cues = SrtTools.ParseSrt(srt);
        Assert.Equal(2, cues.Count);
        Assert.Equal(1, cues[0].Index);
        Assert.Equal("00:00:01,000", cues[0].Start);
        Assert.Equal("00:00:02,500", cues[0].End);
        Assert.Equal("First line.", cues[0].Text);
        Assert.Equal("Second line\ncontinued.", cues[1].Text);
    }

    [Fact]
    public void ParseSrt_BomCrlfAndDotMilliseconds_Tolerated()
    {
        var srt = "﻿1\r\n00:00:01.000 --> 00:00:02.000\r\nhello\r\n";
        var cues = SrtTools.ParseSrt(srt);
        Assert.Single(cues);
        Assert.Equal("00:00:01.000", cues[0].Start);
        Assert.Equal("hello", cues[0].Text);
    }

    [Fact]
    public void ParseSrt_MissingIndexLines_AutoNumbers()
    {
        const string srt = """
            00:00:01,000 --> 00:00:02,000
            a

            00:00:03,000 --> 00:00:04,000
            b
            """;
        var cues = SrtTools.ParseSrt(srt);
        Assert.Equal(2, cues.Count);
        Assert.Equal(1, cues[0].Index);
        Assert.Equal(2, cues[1].Index);
    }

    [Fact]
    public void ParseSrt_EmptyTextEntry_Dropped()
    {
        const string srt = """
            1
            00:00:01,000 --> 00:00:02,000

            2
            00:00:03,000 --> 00:00:04,000
            real text
            """;
        var cues = SrtTools.ParseSrt(srt);
        Assert.Single(cues);
        Assert.Equal(2, cues[0].Index);
        Assert.Equal("real text", cues[0].Text);
    }

    /// <summary>样式 B 关键回归：时间行锚定切条，条目里夹空行不丢后续内容。</summary>
    [Fact]
    public void ParseSrt_RollingStyleB_BlankLinesInsideEntries_NoContentLost()
    {
        var cues = SrtTools.ParseSrt(StyleBSample);
        Assert.Equal(5, cues.Count);
        Assert.Equal("hey everyone welcome back to the channel", cues[1].Text);
        Assert.Equal("hey everyone welcome back to the channel\ntoday we are looking at the new device", cues[2].Text);
        Assert.Equal("today we are looking at the new device\nit is really impressive.", cues[4].Text);
    }

    /// <summary>
    /// 真实 YouTube 滚动字幕样式 B 形态：两行滚动窗口（每条首行重复上一条尾行）、
    /// 10ms 过渡条、条目文本中夹空白行、时间戳首尾相接（不重叠）。
    /// </summary>
    internal const string StyleBSample =
        "1\n" +
        "00:00:00,080 --> 00:00:02,389\n" +
        "hey everyone welcome back to the channel\n" +
        "\n" +
        "2\n" +
        "00:00:02,389 --> 00:00:02,399\n" +
        "hey everyone welcome back to the channel\n" +
        " \n" +
        "\n" +
        "3\n" +
        "00:00:02,399 --> 00:00:04,830\n" +
        "hey everyone welcome back to the channel\n" +
        "today we are looking at the new device\n" +
        "\n" +
        "4\n" +
        "00:00:04,830 --> 00:00:04,840\n" +
        "today we are looking at the new device\n" +
        " \n" +
        "\n" +
        "5\n" +
        "00:00:04,840 --> 00:00:07,160\n" +
        "today we are looking at the new device\n" +
        "it is really impressive.\n";
}

public class CleanCuesTests
{
    private static SubtitleCue Cue(int index, string start, string end, string text) =>
        new(index, start, end, text);

    private static readonly HashSet<string> WeakBoundaryEnds = new(StringComparer.OrdinalIgnoreCase)
    {
        "a", "an", "the", "to", "of", "and", "or", "but", "that", "which", "what", "is", "are", "in",
    };

    private static readonly HashSet<string> WeakBoundaryStarts = new(StringComparer.OrdinalIgnoreCase)
    {
        "and", "or", "but", "that", "which", "who", "whose", "when", "where", "why", "how",
        "to", "of", "for", "with", "in",
    };

    private static string? FirstWord(string text) =>
        text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries)
            .Select(word => new string(word.ToLowerInvariant().Where(char.IsLetterOrDigit).ToArray()))
            .FirstOrDefault(word => word.Length > 0);

    private static string? LastWord(string text) =>
        text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries)
            .Reverse()
            .Select(word => new string(word.ToLowerInvariant().Where(char.IsLetterOrDigit).ToArray()))
            .FirstOrDefault(word => word.Length > 0);

    private static void AssertNoBadSemanticBoundaries(IReadOnlyList<SubtitleCue> cleaned)
    {
        for (var i = 0; i < cleaned.Count; i++)
        {
            var first = FirstWord(cleaned[i].Text);
            var last = LastWord(cleaned[i].Text);
            if (i < cleaned.Count - 1 && last is not null)
            {
                Assert.False(WeakBoundaryEnds.Contains(last), $"Bad semantic tail: {cleaned[i].Text}");
            }
            if (i > 0 && first is not null)
            {
                Assert.False(WeakBoundaryStarts.Contains(first), $"Bad semantic head: {cleaned[i].Text}");
            }
        }
    }

    private static void AssertReadableWindows(
        IReadOnlyList<SubtitleCue> cleaned,
        string expectedText,
        string expectedStart,
        string expectedEnd)
    {
        Assert.NotEmpty(cleaned);
        Assert.Equal(expectedStart, cleaned[0].Start);
        Assert.Equal(expectedEnd, cleaned[^1].End);
        Assert.Equal(expectedText, string.Join(' ', cleaned.Select(c => c.Text)));
        Assert.All(cleaned, cue =>
        {
            var start = SrtTools.SrtTimeToSeconds(cue.Start)!.Value;
            var end = SrtTools.SrtTimeToSeconds(cue.End)!.Value;
            Assert.True(end >= start);
            Assert.True(end - start <= 12.2, $"Cue is too long: {cue.Start} --> {cue.End}");
        });
        for (var i = 1; i < cleaned.Count; i++)
        {
            Assert.True(
                SrtTools.SrtTimeToSeconds(cleaned[i].Start) >= SrtTools.SrtTimeToSeconds(cleaned[i - 1].End),
                "Readable splits must keep the timeline monotonic.");
        }
        AssertNoBadSemanticBoundaries(cleaned);
    }

    private const string LongStyleBSample =
        "1\n" +
        "00:00:00,080 --> 00:00:02,000\n" +
        "this is the\n" +
        "\n" +
        "2\n" +
        "00:00:02,000 --> 00:00:02,010\n" +
        "this is the\n" +
        " \n" +
        "\n" +
        "3\n" +
        "00:00:02,010 --> 00:00:05,000\n" +
        "this is the\n" +
        "story of the\n" +
        "\n" +
        "4\n" +
        "00:00:05,000 --> 00:00:05,010\n" +
        "story of the\n" +
        " \n" +
        "\n" +
        "5\n" +
        "00:00:05,010 --> 00:00:08,000\n" +
        "story of the\n" +
        "people who\n" +
        "\n" +
        "6\n" +
        "00:00:08,000 --> 00:00:08,010\n" +
        "people who\n" +
        " \n" +
        "\n" +
        "7\n" +
        "00:00:08,010 --> 00:00:12,000\n" +
        "people who\n" +
        "wanted to learn how to speak English.\n";

    private const string StarshipStyleBSample =
        "1\n" +
        "00:02:28,239 --> 00:02:32,849\n" +
        "We are in Starfactory and this is an\n" +
        "\n" +
        "2\n" +
        "00:02:32,849 --> 00:02:32,859\n" +
        "We are in Starfactory and this is an\n" +
        " \n" +
        "\n" +
        "3\n" +
        "00:02:32,859 --> 00:02:37,460\n" +
        "We are in Starfactory and this is an\n" +
        "almost 1 million square ft facility that we've built\n" +
        "\n" +
        "4\n" +
        "00:02:37,460 --> 00:02:37,470\n" +
        "almost 1 million square ft facility that we've built\n" +
        " \n" +
        "\n" +
        "5\n" +
        "00:02:37,470 --> 00:02:42,070\n" +
        "almost 1 million square ft facility that we've built\n" +
        "to enable that production of both ship and booster.\n";

    /// <summary>样式 A：时间戳大面积重叠的碎句 → 去重叠 + 按句合并。</summary>
    [Fact]
    public void CleanCues_StyleA_OverlappingFragments_MergedIntoSentence()
    {
        var input = new List<SubtitleCue>
        {
            Cue(1, "00:00:01,000", "00:00:04,000", "so this is"),
            Cue(2, "00:00:02,000", "00:00:06,000", "the first sentence"),
            Cue(3, "00:00:03,500", "00:00:08,000", "we ever wrote."),
        };
        var cleaned = SrtTools.CleanCues(input);
        AssertReadableWindows(
            cleaned,
            "so this is the first sentence we ever wrote.",
            "00:00:01,000",
            "00:00:08,000");
    }

    /// <summary>样式 B：文本重复 + 时间戳相接 → 行级去重、丢纯过渡条、按句合并。</summary>
    [Fact]
    public void CleanCues_StyleB_TextRepeats_DedupedAndMerged()
    {
        var parsed = SrtTools.ParseSrt(SrtParsingTests.StyleBSample);
        var cleaned = SrtTools.CleanCues(parsed);
        AssertReadableWindows(
            cleaned,
            "hey everyone welcome back to the channel today we are looking at the new device it is really impressive.",
            "00:00:00,080",
            "00:00:07,160");
    }

    [Fact]
    public void CleanCues_StyleBLongNativeSpeedCue_SplitsIntoReadableWindows()
    {
        var parsed = SrtTools.ParseSrt(LongStyleBSample);
        var cleaned = SrtTools.CleanCues(parsed);

        Assert.True(
            SrtTools.SrtTimeToSeconds(cleaned[^1].End)!.Value <= SrtTools.SrtTimeToSeconds("00:00:12,200")!.Value,
            "Long rolling captions should stay within the emergency readable window without ending early.");
        AssertReadableWindows(
            cleaned,
            "this is the story of the people who wanted to learn how to speak English.",
            "00:00:00,080",
            cleaned[^1].End);
    }

    [Fact]
    public void CleanCues_StarshipSnippetKeepsReadableSemanticBoundaries()
    {
        var parsed = SrtTools.ParseSrt(StarshipStyleBSample);
        var cleaned = SrtTools.CleanCues(parsed);

        Assert.True(cleaned.Count < 3, "A complete thought should not be hard-split into residual fragments.");
        Assert.True(
            SrtTools.SrtTimeToSeconds(cleaned[^1].End)!.Value - SrtTools.SrtTimeToSeconds(cleaned[0].Start)!.Value <= 14.0,
            "Starship rolling captions should keep source coverage without returning to a dragged long window.");
        AssertReadableWindows(
            cleaned,
            "We are in Starfactory and this is an almost 1 million square ft facility that we've built to enable that production of both ship and booster.",
            "00:02:28,239",
            cleaned[^1].End);
        Assert.DoesNotContain(cleaned, cue => cue.Text is "." or "。" or "-" or "—");
    }

    [Fact]
    public void CleanCues_ShortLongCueIsCappedWithoutCharacterSplitting()
    {
        var parsed = SrtTools.ParseSrt(
            "1\n" +
            "00:14:21,040 --> 00:14:46,215\n" +
            "Copy.\n" +
            "\n" +
            "2\n" +
            "00:15:06,800 --> 00:15:21,590\n" +
            "What heat?\n");

        var cleaned = SrtTools.CleanCues(parsed);

        Assert.Equal(["Copy.", "What heat?"], cleaned.Select(c => c.Text).ToArray());
        Assert.Equal("00:14:21,040", cleaned[0].Start);
        Assert.Equal("00:14:23,040", cleaned[0].End);
        Assert.Equal("00:15:06,800", cleaned[1].Start);
        Assert.Equal("00:15:08,800", cleaned[1].End);
        AssertReadableWindows(cleaned, "Copy. What heat?", "00:14:21,040", "00:15:08,800");
    }

    [Fact]
    public void CleanCues_RollingTailUsesSpeechAlignedWindowInsteadOfSourceDrag()
    {
        var parsed = SrtTools.ParseSrt(
            "1\n" +
            "00:05:36,240 --> 00:05:39,350\n" +
            "It's because we need that size to do the\n" +
            "\n" +
            "2\n" +
            "00:05:39,350 --> 00:05:39,360\n" +
            "It's because we need that size to do the\n" +
            "\n" +
            "3\n" +
            "00:05:39,360 --> 00:06:19,270\n" +
            "It's because we need that size to do the\n" +
            "things we dream of doing with it.\n");

        var cleaned = SrtTools.CleanCues(parsed);

        Assert.Equal("00:05:36,240", cleaned[0].Start);
        Assert.True(
            SrtTools.SrtTimeToSeconds(cleaned[^1].End)!.Value <= SrtTools.SrtTimeToSeconds("00:05:45,240")!.Value,
            "Rolling source drag should not keep a short sentence visible for tens of seconds.");
        Assert.Equal(
            "It's because we need that size to do the things we dream of doing with it.",
            string.Join(' ', cleaned.Select(c => c.Text)));
        Assert.DoesNotContain(cleaned, cue => cue.Text is "C" or "op" or "y.");
        AssertReadableWindows(
            cleaned,
            "It's because we need that size to do the things we dream of doing with it.",
            "00:05:36,240",
            cleaned[^1].End);
    }

    [Fact]
    public void CleanCues_RollingSplitsStayAnchoredToSourceTiming()
    {
        var cleanedQuestion = SrtTools.CleanCues(SrtTools.ParseSrt(
            "1\n" +
            "00:00:43,120 --> 00:00:44,630\n" +
            "All right, test all B19 operators. This\n" +
            "final go now go pull for today's\n" +
            "\n" +
            "2\n" +
            "00:00:44,630 --> 00:00:44,640\n" +
            "final go now go pull for today's\n" +
            "\n" +
            "3\n" +
            "00:00:44,640 --> 00:00:46,869\n" +
            "final go now go pull for today's\n" +
            "operations. Our main objective today is\n" +
            "\n" +
            "4\n" +
            "00:00:46,869 --> 00:00:46,879\n" +
            "operations. Our main objective today is\n" +
            "\n" +
            "5\n" +
            "00:00:46,879 --> 00:00:48,950\n" +
            "operations. Our main objective today is\n" +
            "a 10 engine static fire.\n" +
            "\n" +
            "6\n" +
            "00:00:48,950 --> 00:00:48,960\n" +
            "a 10 engine static fire.\n" +
            "\n" +
            "7\n" +
            "00:00:48,960 --> 00:00:51,590\n" +
            "a 10 engine static fire.\n" +
            ">> Why 10 engines instead of all 33? This\n" +
            "\n" +
            "8\n" +
            "00:00:51,590 --> 00:00:51,600\n" +
            ">> Why 10 engines instead of all 33? This\n" +
            "\n" +
            "9\n" +
            "00:00:51,600 --> 00:00:53,750\n" +
            ">> Why 10 engines instead of all 33? This\n" +
            "is the first V3 booster down at the pad\n"));

        var whyCue = Assert.Single(cleanedQuestion, c => c.Text == "Why 10 engines instead of all 33?");
        Assert.True(
            SrtTools.SrtTimeToSeconds(whyCue.End)!.Value - SrtTools.SrtTimeToSeconds(whyCue.Start)!.Value >= 2.2,
            "The question should not be compressed into a blink-length cue.");
        Assert.True(
            SrtTools.SrtTimeToSeconds(whyCue.End)!.Value >= SrtTools.SrtTimeToSeconds("00:00:51,000")!.Value,
            "The question should stay visible until its source window has mostly completed.");
        var firstV3Cue = cleanedQuestion.FirstOrDefault(c => c.Text.StartsWith("This is the first V3", StringComparison.Ordinal));
        if (firstV3Cue is not null)
        {
            Assert.True(
                SrtTools.SrtTimeToSeconds(firstV3Cue.Start)!.Value >= SrtTools.SrtTimeToSeconds(whyCue.End)!.Value,
                "The next sentence should not be pulled before the question finishes.");
        }

        var cleanedMoon = SrtTools.CleanCues(SrtTools.ParseSrt(
            "1\n" +
            "00:05:03,520 --> 00:05:05,430\n" +
            "foundational design of Starship booster\n" +
            "in the pad. That's going to give us the\n" +
            "\n" +
            "2\n" +
            "00:05:05,430 --> 00:05:05,440\n" +
            "in the pad. That's going to give us the\n" +
            "\n" +
            "3\n" +
            "00:05:05,440 --> 00:05:07,430\n" +
            "in the pad. That's going to give us the\n" +
            "new capabilities we need to do the\n" +
            "\n" +
            "4\n" +
            "00:05:07,430 --> 00:05:07,440\n" +
            "new capabilities we need to do the\n" +
            "\n" +
            "5\n" +
            "00:05:07,440 --> 00:05:09,510\n" +
            "new capabilities we need to do the\n" +
            "missions in front of us. It'll be the\n" +
            "\n" +
            "6\n" +
            "00:05:09,510 --> 00:05:09,520\n" +
            "missions in front of us. It'll be the\n" +
            "\n" +
            "7\n" +
            "00:05:09,520 --> 00:05:11,670\n" +
            "missions in front of us. It'll be the\n" +
            "one that puts humans back on the moon.\n"));

        var moonCue = Assert.Single(cleanedMoon, c => c.Text == "It'll be the one that puts humans back on the moon.");
        Assert.True(
            Math.Abs(SrtTools.SrtTimeToSeconds(moonCue.Start)!.Value - SrtTools.SrtTimeToSeconds("00:05:09,520")!.Value) <= 0.25,
            "The moon sentence should start near the source window where the full line appears.");
        Assert.True(
            SrtTools.SrtTimeToSeconds(moonCue.End)!.Value >= SrtTools.SrtTimeToSeconds("00:05:11,400")!.Value,
            "The moon sentence should remain visible through the source speech window.");
        Assert.DoesNotContain(cleanedMoon, c => c.Text == "It'll be the one that puts");
        Assert.DoesNotContain(cleanedMoon, c => c.Text == "humans back on the moon.");
    }

    [Fact]
    public void CleanCues_StripsSpeakerChangeMarkers()
    {
        // 广播/CART 字幕的 ">>"/">>>" 说话人切换标记应被去掉，不应进入译文。
        var input = new List<SubtitleCue>
        {
            Cue(1, "00:00:00,000", "00:00:03,000", ">> 从1949年开始"),
            Cue(2, "00:00:03,000", "00:00:06,000", ">>> Beginning in December"),
            Cue(3, "00:00:06,000", "00:00:09,000", "蒋介石努力"),
            Cue(4, "00:00:09,000", "00:00:12,000", "Hello >> world"),
        };

        var cleaned = SrtTools.CleanCues(input);

        Assert.Equal([
            "从1949年开始",
            "Beginning in December",
            "蒋介石努力",
            "Hello world",
        ], cleaned.Select(c => c.Text).ToArray());
        Assert.DoesNotContain(cleaned, c => c.Text.Contains(">>"));
    }

    [Fact]
    public void CleanCues_KeepsInlineComparisonOperators()
    {
        // 行内 "a>>b"（无前导空白）不是说话人标记，不应被去掉。
        var input = new List<SubtitleCue>
        {
            Cue(1, "00:00:00,000", "00:00:03,000", "a>>b shift right"),
        };

        var cleaned = SrtTools.CleanCues(input);

        Assert.Equal(["a>>b shift right"], cleaned.Select(c => c.Text).ToArray());
    }

    [Fact]
    public void CleanCues_DropsMultilingualNonSpeechMarkersBeforeTranslation()
    {
        var input = new List<SubtitleCue>
        {
            Cue(1, "00:00:00,000", "00:00:01,000", "[Music]"),
            Cue(2, "00:00:01,000", "00:00:02,000", "[音乐][笑]"),
            Cue(3, "00:00:02,000", "00:00:03,000", "Welcome [Music] back."),
            Cue(4, "00:00:03,000", "00:00:04,000", "(Applause)"),
        };

        var cleaned = SrtTools.CleanCues(input);

        Assert.Equal(["Welcome back."], cleaned.Select(c => c.Text).ToArray());
        Assert.DoesNotContain(cleaned, c =>
            c.Text.Contains('[') || c.Text.Contains("Music") || c.Text.Contains("音乐"));
    }

    [Fact]
    public void CleanCues_DropsBroaderNonSpeechMarkersWithoutRemovingDialogueParentheses()
    {
        var input = new List<SubtitleCue>
        {
            Cue(1, "00:00:00,000", "00:00:01,000", "[Sighs]"),
            Cue(2, "00:00:01,000", "00:00:02,000", "Start [door opens] now"),
            Cue(3, "00:00:02,000", "00:00:03,000", "Keep (important note) here"),
            Cue(4, "00:00:03,000", "00:00:04,000", "继续【掌声继续】讲"),
        };

        var cleaned = SrtTools.CleanCues(input);

        Assert.Equal([
            "Start now",
            "Keep (important note) here",
            "继续讲",
        ], cleaned.Select(c => c.Text).ToArray());
    }

    [Fact]
    public void CleanCues_DropsBracketMarkersWithoutDependingOnLanguageTerms()
    {
        var input = new List<SubtitleCue>
        {
            Cue(1, "00:00:00,000", "00:00:01,000", "[음악]"),
            Cue(2, "00:00:01,000", "00:00:02,000", "Open [dramatic orchestral music] now"),
            Cue(3, "00:00:02,000", "00:00:03,000", "続けて【効果音】話す"),
            Cue(4, "00:00:03,000", "00:00:04,000", "♪sing this line♪"),
            Cue(5, "00:00:04,000", "00:00:05,000", "Keep (important note) here"),
        };

        var cleaned = SrtTools.CleanCues(input);

        Assert.Equal([
            "Open now",
            "続けて話す",
            "sing this line",
            "Keep (important note) here",
        ], cleaned.Select(c => c.Text).ToArray());
    }

    [Fact]
    public void CleanCues_NormalizesSubtitleEscapesBeforeCleaning()
    {
        var input = new List<SubtitleCue>
        {
            Cue(1, "00:00:00,000", "00:00:01,000", "NVIDIA\\hCEO\\Nnext&nbsp;line\u00A0here"),
        };

        var cleaned = SrtTools.CleanCues(input);

        Assert.Equal("NVIDIA CEO\nnext line here", Assert.Single(cleaned).Text);
    }

    [Fact]
    public void CleanCues_ContinuationSentenceKeepsTextButSplitsReadableWindows()
    {
        var input = new List<SubtitleCue>
        {
            Cue(1, "00:00:00,000", "00:00:04,000", "we know it what is the vision for what"),
            Cue(2, "00:00:03,500", "00:00:08,000", "you see coming next we asked ourselves"),
            Cue(3, "00:00:07,500", "00:00:12,000", "if it can do this how far can it go how"),
            Cue(4, "00:00:11,500", "00:00:15,000", "do we get from the robots we have now?"),
        };

        var cleaned = SrtTools.CleanCues(input);

        Assert.True(cleaned.Count > 1);
        AssertReadableWindows(
            cleaned,
            "we know it what is the vision for what you see coming next we asked ourselves if it can do this how far can it go how do we get from the robots we have now?",
            "00:00:00,000",
            "00:00:15,000");
    }

    /// <summary>正常字幕 1:1 不变（不滚动 → 不合并、不改时间）。</summary>
    [Fact]
    public void CleanCues_NormalFile_Unchanged()
    {
        var input = new List<SubtitleCue>
        {
            Cue(1, "00:00:01,000", "00:00:02,500", "First line."),
            Cue(2, "00:00:03,000", "00:00:04,500", "Second line."),
            Cue(3, "00:00:05,000", "00:00:06,500", "第三句。"),
        };
        var cleaned = SrtTools.CleanCues(input);
        Assert.Equal(3, cleaned.Count);
        for (var i = 0; i < 3; i++)
        {
            Assert.Equal(input[i].Index, cleaned[i].Index);
            Assert.Equal(input[i].Start, cleaned[i].Start);
            Assert.Equal(input[i].End, cleaned[i].End);
            Assert.Equal(input[i].Text, cleaned[i].Text);
        }
    }

    /// <summary>句合并断点：累积 ≥6s 也会断句（即便没有句末标点）。</summary>
    [Fact]
    public void CleanCues_MergeBreaksAtSixSeconds()
    {
        var input = new List<SubtitleCue>
        {
            Cue(1, "00:00:00,000", "00:00:03,000", "alpha beta"),
            Cue(2, "00:00:02,000", "00:00:07,000", "gamma delta"),
            Cue(3, "00:00:06,500", "00:00:09,000", "epsilon zeta"),
        };
        var cleaned = SrtTools.CleanCues(input);
        AssertReadableWindows(
            cleaned,
            "alpha beta gamma delta epsilon zeta",
            "00:00:00,000",
            "00:00:08,500");
    }

    /// <summary>句合并断点：累积 ≥84 字符也会断句。</summary>
    [Fact]
    public void CleanCues_MergeBreaksAtCharacterBudget()
    {
        // 三条无标点碎句，前两条合计 84+ 字符 → 在第二条后断句
        var long1 = new string('a', 50);
        var long2 = new string('b', 40);
        var input = new List<SubtitleCue>
        {
            Cue(1, "00:00:00,000", "00:00:02,000", long1),
            Cue(2, "00:00:01,500", "00:00:03,500", long2),
            Cue(3, "00:00:03,000", "00:00:05,000", "tail"),
        };
        var cleaned = SrtTools.CleanCues(input);
        Assert.Equal(2, cleaned.Count);
        Assert.Equal(long1 + " " + long2, cleaned[0].Text);
        Assert.Equal("tail", cleaned[1].Text);
    }

    /// <summary>去重叠：end 截到下一条 start；截剩过短补到 0.3s 但不越下一条 start。</summary>
    [Fact]
    public void CleanCues_DeoverlapClampsEndToNextStart()
    {
        // 重叠率 1/2 = 50% 不算滚动（>50% 才算）→ 只去重叠
        var input = new List<SubtitleCue>
        {
            Cue(1, "00:00:01,000", "00:00:05,000", "one"),
            Cue(2, "00:00:02,000", "00:00:03,000", "two."),
            Cue(3, "00:00:10,000", "00:00:11,000", "three."),
        };
        var cleaned = SrtTools.CleanCues(input);
        Assert.Equal(3, cleaned.Count);
        Assert.Equal("00:00:02,000", cleaned[0].End);  // 截到下一条 start
        Assert.Equal("one", cleaned[0].Text);          // 没有按句合并
    }

    /// <summary>防误判守卫：歌词等少量重复不触发滚动清洗（重复率 ≤30%）。</summary>
    [Fact]
    public void CleanCues_LowRepeatRatio_NotTreatedAsRolling()
    {
        var input = new List<SubtitleCue>
        {
            Cue(1, "00:00:01,000", "00:00:02,000", "la la la"),
            Cue(2, "00:00:03,000", "00:00:04,000", "la la la"),  // 整条重复（1 对）
            Cue(3, "00:00:05,000", "00:00:06,000", "different"),
            Cue(4, "00:00:07,000", "00:00:08,000", "lines"),
        };
        // 重复对 1/3 = 33% > 30%？是 — 调整为 1/4 对：再加一条
        input.Add(Cue(5, "00:00:09,000", "00:00:10,000", "ending"));
        // 1/4 = 25% ≤ 30% → 不滚动，5 条原样保留
        var cleaned = SrtTools.CleanCues(input);
        Assert.Equal(5, cleaned.Count);
        Assert.Equal("la la la", cleaned[1].Text);
    }

    [Fact]
    public void SrtTimeRoundTrip()
    {
        Assert.Equal(3723.5, SrtTools.SrtTimeToSeconds("01:02:03,500"));
        Assert.Equal(3723.5, SrtTools.SrtTimeToSeconds("01:02:03.500"));
        Assert.Null(SrtTools.SrtTimeToSeconds("oops"));
        Assert.Equal("01:02:03,500", SrtTools.SecondsToSrtTime(3723.5));
        Assert.Equal("00:00:00,000", SrtTools.SecondsToSrtTime(-1));
    }

    [Fact]
    public void SerializeSrt_RoundTripsThroughParse()
    {
        var cues = new List<SubtitleCue>
        {
            Cue(1, "00:00:01,000", "00:00:02,000", "hello\nworld"),
            Cue(2, "00:00:03,000", "00:00:04,000", "again"),
        };
        var text = SrtTools.SerializeSrt(cues);
        var reparsed = SrtTools.ParseSrt(text);
        Assert.Equal(2, reparsed.Count);
        Assert.Equal("hello\nworld", reparsed[0].Text);
    }
}
