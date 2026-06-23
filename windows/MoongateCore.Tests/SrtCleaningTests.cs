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

    [Fact]
    public void ParseVtt_KeepsInlineWordTimingFragments()
    {
        const string raw = """
            WEBVTT

            00:00:00.000 --> 00:00:02.000 align:start position:0%
            Hello<00:00:00.500><c> world</c><00:00:01.200><c> again</c>
            """;

        var cues = SrtTools.ParseVtt(raw);

        var cue = Assert.Single(cues);
        Assert.Equal("Hello world again", cue.Text);
        Assert.Equal(["Hello", "world", "again"], cue.SourceFragments.Select(fragment => fragment.Text).ToArray());
        Assert.Equal(0.0, cue.SourceFragments[0].StartSeconds, precision: 3);
        Assert.Equal(0.5, cue.SourceFragments[0].EndSeconds, precision: 3);
        Assert.Equal(0.5, cue.SourceFragments[1].StartSeconds, precision: 3);
        Assert.Equal(1.2, cue.SourceFragments[1].EndSeconds, precision: 3);
        Assert.Equal(1.2, cue.SourceFragments[2].StartSeconds, precision: 3);
        Assert.Equal(2.0, cue.SourceFragments[2].EndSeconds, precision: 3);
    }

    [Fact]
    public void ParseVtt_SkipsCueIdentifiersAndMetadataBlocks()
    {
        const string raw = """
            WEBVTT

            STYLE
            ::cue { color: red; }

            REGION
            id:fred
            width:40%

            NOTE this block is not a cue
            00:00:00.000 --> 00:00:01.000
            Should not appear

            cue-1
            00:00:01.000 --> 00:00:03.000 align:start position:0%
            Hello<00:00:02.000><c> world</c>

            cue-2
            00:00:03.500 --> 00:00:04.500
            Next line
            """;

        var cues = SrtTools.ParseVtt(raw);

        Assert.Equal(2, cues.Count);
        Assert.Equal(["Hello world", "Next line"], cues.Select(cue => cue.Text).ToArray());
        Assert.Equal(["Hello", "world"], cues[0].SourceFragments.Select(fragment => fragment.Text).ToArray());
        Assert.DoesNotContain("cue-", string.Join(' ', cues.Select(cue => cue.Text)), StringComparison.Ordinal);
        Assert.DoesNotContain("Should not appear", string.Join(' ', cues.Select(cue => cue.Text)), StringComparison.Ordinal);
    }

    [Fact]
    public void ParseVtt_CapsTrailingInlineDisplayHold()
    {
        const string raw = """
            WEBVTT

            00:00:00.000 --> 00:00:10.000 align:start position:0%
            avoir<00:00:01.000><c> deux</c><00:00:02.000><c> euros</c>
            """;

        var cues = SrtTools.ParseVtt(raw);

        var cue = Assert.Single(cues);
        Assert.Equal(["avoir", "deux", "euros"], cue.SourceFragments.Select(fragment => fragment.Text).ToArray());
        Assert.Equal(2.0, cue.SourceFragments[2].StartSeconds, precision: 3);
        Assert.Equal(3.3, cue.SourceFragments[2].EndSeconds, precision: 3);
    }

    [Fact]
    public void ParseVtt_CapsNoInlineRollingDisplayHold()
    {
        const string raw = """
            WEBVTT

            00:00:00.000 --> 00:00:03.000 align:start position:0%
            avoir<00:00:01.000><c> deux</c>

            00:00:03.000 --> 00:00:08.000 align:start position:0%
            avoir deux
            euros
            """;

        var cues = SrtTools.ParseVtt(raw);

        Assert.Equal(2, cues.Count);
        Assert.Equal(["euros"], cues[1].SourceFragments.Select(fragment => fragment.Text).ToArray());
        Assert.Equal(3.0, cues[1].SourceFragments[0].StartSeconds, precision: 3);
        Assert.Equal(4.3, cues[1].SourceFragments[0].EndSeconds, precision: 3);
    }

    [Fact]
    public void ParseVtt_KeepsShortNoInlineRollingCueWindow()
    {
        const string raw = """
            WEBVTT

            00:00:00.000 --> 00:00:03.000 align:start position:0%
            au<00:00:01.000><c> prix</c>

            00:00:03.000 --> 00:00:05.000 align:start position:0%
            au prix
            kilo.
            """;

        var cues = SrtTools.ParseVtt(raw);

        Assert.Equal(2, cues.Count);
        Assert.Equal(["kilo."], cues[1].SourceFragments.Select(fragment => fragment.Text).ToArray());
        Assert.Equal(3.0, cues[1].SourceFragments[0].StartSeconds, precision: 3);
        Assert.Equal(5.0, cues[1].SourceFragments[0].EndSeconds, precision: 3);
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
    public void CleanCues_UsesVttWordFragmentsForRollingCaptions()
    {
        const string raw = """
            WEBVTT

            00:00:00.000 --> 00:00:02.000 align:start position:0%
            Hello<00:00:00.500><c> world</c>

            00:00:02.000 --> 00:00:02.010 align:start position:0%
            Hello world

            00:00:02.010 --> 00:00:04.000 align:start position:0%
            Hello world
            again<00:00:02.400><c> today.</c>
            """;

        var cleaned = SrtTools.CleanCues(SrtTools.ParseVtt(raw));

        var cue = Assert.Single(cleaned);
        Assert.Equal("Hello world again today.", cue.Text);
        Assert.Equal("00:00:00,000", cue.Start);
        Assert.Equal("00:00:04,000", cue.End);
    }

    [Fact]
    public void CleanCues_TrimsVttDisplayHoldAfterRollingPunctuationIsland()
    {
        const string raw = """
            WEBVTT

            00:04:35.120 --> 00:04:40.629 align:start position:0%
            Ceux-là<00:04:35.960><c> viennent</c><00:04:36.800><c> du</c><00:04:37.320><c> Pérou</c><00:04:38.759><c> et</c><00:04:39.639><c> on</c><00:04:40.000><c> peut</c><00:04:40.320><c> en</c>

            00:04:40.639 --> 00:04:46.590 align:start position:0%
            Ceux-là viennent du Pérou et on peut en
            avoir<00:04:41.320><c> deux</c><00:04:41.960><c> pour</c><00:04:42.840><c> 3</c><00:04:43.199><c> €</c><00:04:44.680><c> 4,99</c>

            00:04:46.600 --> 00:04:50.350 align:start position:0%
            avoir deux pour 3 € 4,99
            €.

            00:04:50.360 --> 00:04:52.000 align:start position:0%
            Le<00:04:50.500><c> primeur</c>
            """;

        var cleaned = SrtTools.CleanCues(SrtTools.ParseVtt(raw));
        var priceCue = cleaned.FirstOrDefault(cue => cue.Text.Contains("4,99", StringComparison.Ordinal));

        Assert.NotNull(priceCue);
        Assert.True(
            SrtTools.SrtTimeToSeconds(priceCue.End) <= 288.0,
            string.Join("\n", cleaned.Select(cue => $"{cue.Start} --> {cue.End} {cue.Text}")));
    }

    [Fact]
    public void ParseVtt_NoInlineCueKeepsSourceFragment()
    {
        const string raw = """
            WEBVTT

            00:00:50.430 --> 00:00:55.610
            大家如果有來過台北的話，就知道台北的摩托車還蠻多的
            """;

        var cues = SrtTools.ParseVtt(raw);

        var cue = Assert.Single(cues);
        var fragment = Assert.Single(cue.SourceFragments);
        Assert.Equal("大家如果有來過台北的話，就知道台北的摩托車還蠻多的", fragment.Text);
        Assert.Equal(50.430, fragment.StartSeconds, precision: 3);
        Assert.Equal(55.610, fragment.EndSeconds, precision: 3);
    }

    [Fact]
    public void CleanCues_TrimsNoInlineVttCjkIdleTailWithoutSplitting()
    {
        const string raw = """
            WEBVTT

            00:02:05.100 --> 00:02:11.380
            大家應該有發現吧！如果你跟臺灣人一起出去玩，車上都有飲料

            00:02:11.660 --> 00:02:20.720
            剛剛我跟我姐去買飲料喝，這樣子開車的時候也比較有樂趣、比較好玩

            00:02:20.940 --> 00:02:32.470
            因為大概20分鐘的車程，所以喝一杯飲料剛剛好也不錯，現在在等紅綠燈
            """;

        var cleaned = SrtTools.CleanCues(SrtTools.ParseVtt(raw));
        var middle = Assert.Single(cleaned, cue => cue.Text.StartsWith("剛剛我跟我姐", StringComparison.Ordinal));

        Assert.Equal(3, cleaned.Count);
        Assert.Equal("剛剛我跟我姐去買飲料喝，這樣子開車的時候也比較有樂趣、比較好玩", middle.Text);
        Assert.True(SrtTools.SrtTimeToSeconds(middle.Start)!.Value >= 132.0);
        Assert.True(SrtTools.SrtTimeToSeconds(middle.End)!.Value <= 140.5);
    }

    [Fact]
    public void CleanCues_DoesNotClampVttWordAnchorsBeforeRollingTransition()
    {
        const string raw = """
            WEBVTT

            00:00:00.160 --> 00:00:01.350 align:start position:0%
            안녕하세요

            00:00:01.350 --> 00:00:01.360 align:start position:0%
            안녕하세요

            00:00:01.360 --> 00:00:06.150 align:start position:0%
            안녕하세요
            보세요<00:00:02.679><c> 드릴게</c><00:00:03.679><c> 진짜요</c><00:00:04.080><c> 와</c><00:00:04.359><c> 엄합니다</c>

            00:00:06.150 --> 00:00:06.160 align:start position:0%
            보세요 드릴게 진짜요 와 엄합니다

            00:00:06.160 --> 00:00:12.950 align:start position:0%
            보세요 드릴게 진짜요 와 엄합니다
            5점<00:00:07.160><c> 1점</c><00:00:08.400><c> 진짜</c><00:00:09.400><c> 점</c>
            """;

        var cleaned = SrtTools.CleanCues(SrtTools.ParseVtt(raw));

        var cue = Assert.Single(cleaned, c => c.Text.Contains("엄합니다", StringComparison.Ordinal));
        var end = SrtTools.SrtTimeToSeconds(cue.End)!.Value;
        var cleanedDescription = string.Join(
            " / ",
            cleaned.Select(c => $"{c.Start} --> {c.End} | {c.Text}"));
        Assert.True(
            end >= 4.35,
            $"VTT word-anchored rolling captions must not be clamped to a transition cue before the spoken word ends: {cleanedDescription}");
    }

    [Fact]
    public void CleanCues_DoesNotClampManualShortVlogCueBeforeSourceEnd()
    {
        const string raw = """
            1
            00:00:01,200 --> 00:00:03,360
            All right, so here we are, in front of the
            elephants

            2
            00:00:05,318 --> 00:00:07,974
            the cool thing about these guys is that they
            have really...

            3
            00:00:07,974 --> 00:00:12,616
            really really long trunks

            4
            00:00:12,616 --> 00:00:14,367
            and that's cool
            """;

        var cleaned = SrtTools.CleanCues(SrtTools.ParseSrt(raw));

        var cue = Assert.Single(cleaned, c => c.Text == "really really long trunks");
        var end = SrtTools.SrtTimeToSeconds(cue.End)!.Value;
        var cleanedDescription = string.Join(
            " / ",
            cleaned.Select(c => $"{c.Start} --> {c.End} | {c.Text}"));
        Assert.True(
            end >= 12.5,
            $"Manual short vlog cue should not be clamped to a 1.9s display window before the source cue ends: {cleanedDescription}");
    }

    [Fact]
    public void CleanCues_KeepsKoreanVttWordAnchorsAcrossRollingCarry()
    {
        const string raw = """
            WEBVTT

            00:00:04.270 --> 00:00:09.720 align:start position:0%
            [박수]
            아니야<00:00:04.840><c> 화면들이</c><00:00:05.290><c> 한번</c><00:00:05.590><c> 갈까요</c><00:00:05.920><c> 이제</c><00:00:06.550><c> 아</c><00:00:06.580><c> 여기서</c><00:00:07.359><c> 내용이다</c><00:00:07.750><c> 아예</c><00:00:08.400><c> 아무</c><00:00:09.400><c> 이상이</c>

            00:00:09.720 --> 00:00:09.730 align:start position:0%
            아니야 화면들이 한번 갈까요 이제 아 여기서 내용이다 아예 아무 이상이

            00:00:09.730 --> 00:00:12.600 align:start position:0%
            아니야 화면들이 한번 갈까요 이제 아 여기서 내용이다 아예 아무 이상이
            좋아요<00:00:10.420><c> 4면을</c><00:00:11.200><c> 있어</c><00:00:11.410><c> 좋다</c>
            """;

        var cleaned = SrtTools.CleanCues(SrtTools.ParseVtt(raw));

        var cue = Assert.Single(cleaned, c => c.Text.Contains("좋다", StringComparison.Ordinal));
        var end = SrtTools.SrtTimeToSeconds(cue.End)!.Value;
        var cleanedDescription = string.Join(
            " / ",
            cleaned.Select(c => $"{c.Start} --> {c.End} | {c.Text}"));
        Assert.True(
            end >= 12.5,
            $"Korean VTT rolling carry must keep the later word anchor instead of compressing the cue: {cleanedDescription}");
    }

    [Fact]
    public void CleanCues_KeepsFirstWordFragmentAtReadableSplitBoundary()
    {
        var firstWords = new[] { "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten" };
        var secondWords = new[] { "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty." };

        static IReadOnlyList<SubtitleCueSourceFragment> Fragments(IEnumerable<string> words, double start) =>
            words.Select((word, index) => new SubtitleCueSourceFragment(
                start + index * 0.5,
                start + (index + 1) * 0.5,
                word)).ToList();

        var cues = new List<SubtitleCue>
        {
            new(
                1,
                "00:00:00,000",
                "00:00:05,000",
                string.Join(' ', firstWords),
                Fragments(firstWords, 0)),
            new(
                2,
                "00:00:05,000",
                "00:00:10,000",
                string.Join(' ', firstWords) + "\n" + string.Join(' ', secondWords),
                Fragments(secondWords, 5)),
        };

        var cleaned = SrtTools.CleanCues(cues);

        var second = Assert.Single(cleaned, cue => cue.Text.Contains("eleven", StringComparison.Ordinal));
        Assert.Equal("00:00:05,000", second.Start);
        Assert.StartsWith("eleven", second.Text);
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
    public void CleanCues_StarshipVttKeepsFinalSourceWordsVisible()
    {
        var parsed = SrtTools.ParseVtt(
            "WEBVTT\n" +
            "\n" +
            "00:04:13.599 --> 00:04:15.670 align:start position:0%\n" +
            "[music]\n" +
            "&gt;&gt; And<00:04:13.760><c> so</c><00:04:14.000><c> those</c><00:04:14.239><c> pieces,</c><00:04:14.720><c> which</c><00:04:15.120><c> at</c><00:04:15.360><c> the</c><00:04:15.519><c> time</c>\n" +
            "\n" +
            "00:04:15.670 --> 00:04:15.680 align:start position:0%\n" +
            "&gt;&gt; And so those pieces, which at the time\n" +
            " \n" +
            "\n" +
            "00:04:15.680 --> 00:04:18.150 align:start position:0%\n" +
            "&gt;&gt; And so those pieces, which at the time\n" +
            "did<00:04:15.920><c> not</c><00:04:16.079><c> seem</c><00:04:16.400><c> small</c><00:04:16.639><c> at</c><00:04:16.880><c> all,</c><00:04:17.440><c> were</c><00:04:17.759><c> Falcon</c>\n" +
            "\n" +
            "00:04:18.150 --> 00:04:18.160 align:start position:0%\n" +
            "did not seem small at all, were Falcon\n" +
            " \n" +
            "\n" +
            "00:04:18.160 --> 00:04:20.949 align:start position:0%\n" +
            "did not seem small at all, were Falcon\n" +
            "1,\n" +
            "\n" +
            "00:04:31.199 --> 00:04:33.110 align:start position:0%\n" +
            "Falcon Heavy.\n" +
            "&gt;&gt; Falcon<00:04:31.600><c> Heavy</c><00:04:31.919><c> is</c><00:04:32.080><c> supersonic.</c>\n" +
            "\n" +
            "00:04:33.110 --> 00:04:33.120 align:start position:0%\n" +
            "&gt;&gt; Falcon Heavy is supersonic.\n" +
            " \n" +
            "\n" +
            "00:04:33.120 --> 00:04:34.950 align:start position:0%\n" +
            "&gt;&gt; Falcon Heavy is supersonic.\n" +
            "&gt;&gt; These<00:04:33.360><c> were</c><00:04:33.520><c> the</c><00:04:33.759><c> building</c><00:04:34.080><c> blocks</c><00:04:34.479><c> that</c><00:04:34.800><c> let</c>\n" +
            "\n" +
            "00:04:34.950 --> 00:04:34.960 align:start position:0%\n" +
            "&gt;&gt; These were the building blocks that let\n" +
            " \n" +
            "\n" +
            "00:04:34.960 --> 00:04:37.350 align:start position:0%\n" +
            "&gt;&gt; These were the building blocks that let\n" +
            "us<00:04:35.199><c> cut</c><00:04:35.360><c> our</c><00:04:35.600><c> teeth</c><00:04:36.160><c> on</c><00:04:36.479><c> learning</c><00:04:36.800><c> how</c><00:04:36.960><c> to</c><00:04:37.120><c> do</c>\n" +
            "\n" +
            "00:04:37.350 --> 00:04:37.360 align:start position:0%\n" +
            "us cut our teeth on learning how to do\n" +
            " \n" +
            "\n" +
            "00:04:37.360 --> 00:04:39.909 align:start position:0%\n" +
            "us cut our teeth on learning how to do\n" +
            "rockets.\n");

        var cleaned = SrtTools.CleanCues(parsed);
        var falconOne = Assert.Single(cleaned, cue => cue.Text.Contains("were Falcon 1,", StringComparison.Ordinal));
        var rockets = Assert.Single(cleaned, cue => cue.Text.Contains("learning how to do rockets.", StringComparison.Ordinal));

        Assert.True(
            SrtTools.SrtTimeToSeconds(falconOne.End)!.Value >= SrtTools.SrtTimeToSeconds("00:04:20,949")!.Value);
        Assert.True(
            SrtTools.SrtTimeToSeconds(rockets.End)!.Value >= SrtTools.SrtTimeToSeconds("00:04:39,909")!.Value);
        Assert.DoesNotContain(cleaned, cue => cue.Text.Contains("[music]", StringComparison.Ordinal) || cue.Text.Contains(">>", StringComparison.Ordinal));
        AssertReadableWindows(cleaned, cleaned.Select(cue => cue.Text).Aggregate((left, right) => left + " " + right), cleaned[0].Start, cleaned[^1].End);
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
    public void CleanCues_ShortCjkFeedbackIsCappedWithoutSingleCharacterSplitting()
    {
        var parsed = SrtTools.ParseSrt(
            "1\n" +
            "00:00:10,000 --> 00:00:30,000\n" +
            "没问题\n");

        var cleaned = SrtTools.CleanCues(parsed);

        Assert.Equal(["没问题"], cleaned.Select(cue => cue.Text).ToArray());
        Assert.Equal("00:00:10,000", cleaned[0].Start);
        Assert.Equal("00:00:11,500", cleaned[0].End);
    }

    [Fact]
    public void CleanCues_LongCjkCueDoesNotSplitIntoSingletonCharacters()
    {
        var parsed = SrtTools.ParseSrt(
            "1\n" +
            "00:00:00,000 --> 00:00:24,000\n" +
            "今天我们先看一下这个问题然后再继续往下讲\n");

        var cleaned = SrtTools.CleanCues(parsed);

        Assert.True(cleaned.Count > 1);
        Assert.Equal(
            "今天我们先看一下这个问题然后再继续往下讲",
            string.Concat(cleaned.Select(cue => cue.Text)));
        Assert.DoesNotContain(cleaned, cue => cue.Text.Count(ch => !char.IsWhiteSpace(ch)) == 1);
        Assert.Equal("00:00:00,000", cleaned[0].Start);
        Assert.All(cleaned, cue =>
        {
            var start = SrtTools.SrtTimeToSeconds(cue.Start)!.Value;
            var end = SrtTools.SrtTimeToSeconds(cue.End)!.Value;
            Assert.True(end >= start);
            Assert.True(end - start <= 12.2, $"Cue is too long: {cue.Start} --> {cue.End}");
        });
    }

    [Fact]
    public void CleanCues_KoreanPreservesWordSpaces()
    {
        var parsed = SrtTools.ParseSrt(
            "1\n" +
            "00:03:00,077 --> 00:03:04,181\n" +
            "내가 서 있는 곳에 \n" +
            "정확히 멈추는 버스의 제동 소리.\n" +
            "\n" +
            "2\n" +
            "00:03:05,015 --> 00:03:08,885\n" +
            "터벅터벅 집을 향해 걸어가는 \n" +
            "나의 발걸음과\n");

        var cleaned = SrtTools.CleanCues(parsed);

        var joined = string.Join(' ', cleaned.Select(cue => cue.Text));
        Assert.Contains("내가 서 있는 곳에", joined);
        Assert.Contains("정확히 멈추는 버스의 제동 소리.", joined);
        Assert.Contains("터벅터벅 집을 향해 걸어가는", joined);
        Assert.DoesNotContain("내가서있는곳에", joined);
        Assert.DoesNotContain("멈추는버스의제동소리", joined);
    }

    [Fact]
    public void CleanCues_KoreanSplitsOnWordBoundaries()
    {
        var parsed = SrtTools.ParseSrt(
            "1\n" +
            "00:03:09,019 --> 00:03:22,490\n" +
            "현관을 들어서면 나를 반겨주는 반려 동물의 울음 소리와 조용히 움직이는 가족의 목소리.\n");

        var cleaned = SrtTools.CleanCues(parsed);

        Assert.True(cleaned.Count > 1);
        Assert.Equal(
            "현관을 들어서면 나를 반겨주는 반려 동물의 울음 소리와 조용히 움직이는 가족의 목소리.",
            string.Join(' ', cleaned.Select(cue => cue.Text)));
        Assert.DoesNotContain(cleaned, cue => cue.Text.Trim().EndsWith("반겨주", StringComparison.Ordinal));
        Assert.DoesNotContain(cleaned, cue => cue.Text.Trim().StartsWith("는 ", StringComparison.Ordinal));
    }

    [Fact]
    public void CleanCues_ManualMultilineKoreanCueIsNotSplit()
    {
        var parsed = SrtTools.ParseSrt(
            "1\n" +
            "00:03:35,378 --> 00:03:40,817\n" +
            "그런데 ‘소리가 없다‘,\n" +
            "‘소리가 전혀 들리지 않는다’라는,\n");

        var cleaned = SrtTools.CleanCues(parsed);

        var cue = Assert.Single(cleaned);
        Assert.Equal("00:03:35,378", cue.Start);
        Assert.Equal("00:03:40,817", cue.End);
        Assert.Equal("그런데 ‘소리가 없다‘,\n‘소리가 전혀 들리지 않는다’라는,", cue.Text);
    }

    [Fact]
    public void CleanCues_ManualSingleLineKoreanCueKeepsEndTiming()
    {
        var parsed = SrtTools.ParseSrt(
            "1\n" +
            "00:03:27,537 --> 00:03:30,640\n" +
            "끊임없이 소리를 듣고,\n");

        var cleaned = SrtTools.CleanCues(parsed);

        var cue = Assert.Single(cleaned);
        Assert.Equal("00:03:27,537", cue.Start);
        Assert.Equal("00:03:30,640", cue.End);
        Assert.Equal("끊임없이 소리를 듣고,", cue.Text);
    }

    [Fact]
    public void CleanCues_ManualMultilineCjkCueIsNotSplit()
    {
        var parsed = SrtTools.ParseSrt(
            "1\n" +
            "00:02:01,044 --> 00:02:05,724\n" +
            "參與了很多心靈成長課程、\n" +
            "工作坊，飛到國外找大師，\n");

        var cleaned = SrtTools.CleanCues(parsed);

        var cue = Assert.Single(cleaned);
        Assert.Equal("00:02:01,044", cue.Start);
        Assert.Equal("00:02:05,724", cue.End);
        Assert.Equal("參與了很多心靈成長課程、\n工作坊，飛到國外找大師，", cue.Text);
    }

    [Fact]
    public void CleanCues_RollingCjkUsesReadableSourceAnchoredPieces()
    {
        var parsed = SrtTools.ParseSrt(
            "1\n" +
            "00:01:09,080 --> 00:01:12,000\n" +
            "あったわけで働きたいです\n" +
            "\n" +
            "2\n" +
            "00:01:12,000 --> 00:01:12,010\n" +
            "あったわけで働きたいです\n" +
            "\n" +
            "3\n" +
            "00:01:12,010 --> 00:01:15,890\n" +
            "あったわけで働きたいです\n" +
            "東京がわかるんですよそう東京で\n");

        var cleaned = SrtTools.CleanCues(parsed);

        Assert.True(cleaned.Count > 1);
        Assert.Equal(
            "あったわけで働きたいです東京がわかるんですよそう東京で",
            string.Concat(cleaned.Select(cue => cue.Text)));
        Assert.DoesNotContain(cleaned, cue => cue.Text.Count(ch => !char.IsWhiteSpace(ch)) == 1);
        Assert.All(cleaned, cue =>
        {
            var start = SrtTools.SrtTimeToSeconds(cue.Start)!.Value;
            var end = SrtTools.SrtTimeToSeconds(cue.End)!.Value;
            Assert.True(end >= start);
            Assert.True(end - start <= 12.2, $"Cue is too long: {cue.Start} --> {cue.End}");
        });
    }

    [Fact]
    public void CleanCues_JapaneseVttUsesReadableSourceBoundaries()
    {
        const string raw = """
            WEBVTT

            00:00:19.140 --> 00:00:20.510 align:start position:0%
            えーと今
            昨日<00:00:19.320><c>あの</c><00:00:19.740><c>弟</c><00:00:19.740><c>の</c>

            00:00:20.510 --> 00:00:20.520 align:start position:0%
            昨日あの弟の

            00:00:20.520 --> 00:00:24.890 align:start position:0%
            昨日あの弟の
            家に<00:00:20.820><c>泊まっ</c><00:00:20.939><c>て</c><00:00:21.380><c>そう</c><00:00:22.380><c>です</c><00:00:22.500><c>ね</c><00:00:22.640><c>ちょっと</c><00:00:23.640><c>今日</c><00:00:24.539><c>の</c>

            00:00:24.890 --> 00:00:24.900 align:start position:0%
            家に泊まってそうですねちょっと今日の

            00:00:24.900 --> 00:00:25.790 align:start position:0%
            家に泊まってそうですねちょっと今日の
            キャンプ<00:00:25.080><c>の</c>

            00:00:25.790 --> 00:00:25.800 align:start position:0%
            キャンプの

            00:00:25.800 --> 00:00:28.310 align:start position:0%
            キャンプの
            準備<00:00:25.920><c>を</c><00:00:26.039><c>し</c><00:00:26.160><c>て</c><00:00:26.160><c>い</c><00:00:26.279><c>ます</c>

            00:00:28.320 --> 00:00:32.450 align:start position:0%
            任天<00:00:28.500><c>堂</c><00:00:28.680><c>スイッチ</c><00:00:28.820><c>も</c><00:00:30.000><c>持っ</c><00:00:30.000><c>て</c><00:00:30.060><c>いき</c><00:00:30.180><c>ます</c><00:00:30.180><c>よ</c><00:00:30.500><c>一応</c><00:00:31.500><c>ね</c>
            """;

        var cleaned = SrtTools.CleanCues(SrtTools.ParseVtt(raw));
        var combined = string.Concat(cleaned.Select(cue => cue.Text));

        Assert.Equal(
            "えーと今昨日あの弟の家に泊まってそうですねちょっと今日のキャンプの準備をしています任天堂スイッチも持っていきますよ一応ね",
            combined);
        Assert.True(cleaned.Count > 1);
        Assert.DoesNotContain(cleaned, cue => cue.Text.EndsWith("泊", StringComparison.Ordinal) || cue.Text.StartsWith("まって", StringComparison.Ordinal));
        Assert.DoesNotContain(cleaned, cue => cue.Text.EndsWith("ちょ", StringComparison.Ordinal) || cue.Text.StartsWith("っと", StringComparison.Ordinal));
        Assert.DoesNotContain(cleaned, cue => cue.Text.EndsWith("スイ", StringComparison.Ordinal) || cue.Text.StartsWith("ッチ", StringComparison.Ordinal));
        Assert.DoesNotContain(cleaned, cue => cue.Text.Count(ch => !char.IsWhiteSpace(ch)) <= 3 && cleaned.Count > 1);
        Assert.All(cleaned, cue =>
        {
            var start = SrtTools.SrtTimeToSeconds(cue.Start)!.Value;
            var end = SrtTools.SrtTimeToSeconds(cue.End)!.Value;
            Assert.True(end >= start);
            Assert.True(end - start <= 12.2, $"Cue is too long: {cue.Start} --> {cue.End}");
        });
    }

    [Fact]
    public void CleanCues_JapaneseVttTrimsTerminalDisplayHold()
    {
        const string raw = """
            WEBVTT

            00:00:28.320 --> 00:00:32.450 align:start position:0%
            任天<00:00:28.500><c>堂</c><00:00:28.680><c>スイッチ</c><00:00:28.820><c>も</c><00:00:30.000><c>持っ</c><00:00:30.000><c>て</c><00:00:30.060><c>いき</c><00:00:30.180><c>ます</c><00:00:30.180><c>よ</c><00:00:30.500><c>一応</c><00:00:31.500><c>ね</c>

            00:00:32.450 --> 00:00:32.460 align:start position:0%
            任天堂スイッチも持っていきますよ一応ね

            00:00:32.460 --> 00:00:36.110 align:start position:0%
            任天堂スイッチも持っていきますよ一応ね
            はい<00:00:32.759><c>たくさん</c><00:00:33.899><c>荷物</c><00:00:34.020><c>が</c><00:00:34.200><c>あり</c><00:00:34.260><c>ます</c><00:00:34.260><c>ね</c>

            00:00:36.110 --> 00:00:36.120 align:start position:0%
            はいたくさん荷物がありますね

            00:00:36.120 --> 00:00:39.290 align:start position:0%
            はいたくさん荷物がありますね
            楽しみ<00:00:36.300><c>です</c><00:00:36.360><c>か</c>
            """;

        var parsed = SrtTools.ParseVtt(raw);
        var parsedCue = Assert.Single(parsed, cue => cue.Text.Contains("楽しみですか", StringComparison.Ordinal));
        Assert.Equal(["楽しみ", "です", "か"], parsedCue.SourceFragments.Select(fragment => fragment.Text));
        Assert.True(parsedCue.SourceFragments[^1].EndSeconds <= 37.9);

        var cleaned = SrtTools.CleanCues(parsed);
        var cue = Assert.Single(cleaned, cue => cue.Text.Contains("楽しみですか", StringComparison.Ordinal));

        Assert.True(SrtTools.SrtTimeToSeconds(cue.End)!.Value <= 37.9);
    }

    [Fact]
    public void CleanCues_JapaneseVttMergesShortKanaFragments()
    {
        const string raw = """
            WEBVTT

            00:02:58.040 --> 00:03:01.070 align:start position:0%
            マジで
            おなら<00:02:59.360><c>つまら</c><00:03:00.360><c>ない</c><00:03:00.420><c>おなら</c><00:03:00.840><c>」</c><00:03:00.900><c>って</c><00:03:00.959><c>書い</c><00:03:01.019><c>て</c><00:03:01.080><c>ある</c>

            00:03:01.070 --> 00:03:01.080 align:start position:0%
            おならつまらないおなら」って書いてある

            00:03:01.080 --> 00:03:08.030 align:start position:0%
            おならつまらないおなら」って書いてある
            や<00:03:01.200><c>ん</c>
            """;

        var cleaned = SrtTools.CleanCues(SrtTools.ParseVtt(raw));
        var joined = string.Concat(cleaned.Select(cue => cue.Text));

        Assert.Contains("やん", joined, StringComparison.Ordinal);
        Assert.DoesNotContain(cleaned, cue => cue.Text is "や" or "ん");
        Assert.DoesNotContain(cleaned, cue =>
            SrtTools.SrtTimeToSeconds(cue.End)!.Value - SrtTools.SrtTimeToSeconds(cue.Start)!.Value <= 0.08
            && cue.Text.Contains("おなら", StringComparison.Ordinal));
        var cue = Assert.Single(cleaned, cue => cue.Text == "やん");
        Assert.True(SrtTools.SrtTimeToSeconds(cue.End)!.Value <= 182.5);
    }

    [Fact]
    public void CleanCues_DenseShortCjkCueDoesNotSplitIntoBlinkPieces()
    {
        var parsed = SrtTools.ParseSrt(
            "1\n" +
            "00:01:25,510 --> 00:01:27,510\n" +
            "美味しい食べ物がはいっぱいありますああそうですか便利じゃないですか\n");

        var cleaned = SrtTools.CleanCues(parsed);

        var cue = Assert.Single(cleaned);
        Assert.Equal("00:01:25,510", cue.Start);
        Assert.Equal("00:01:27,510", cue.End);
    }

    [Fact]
    public void CleanCues_ReadableCjkCueWithoutSourceAnchorsIsNotBlindlySplit()
    {
        var parsed = SrtTools.ParseSrt(
            "1\n" +
            "00:00:50,430 --> 00:00:55,610\n" +
            "大家如果有來過台北的話，就知道台北的摩托車還蠻多的\n");

        var cleaned = SrtTools.CleanCues(parsed);

        var cue = Assert.Single(cleaned);
        Assert.Equal("00:00:50,430", cue.Start);
        Assert.Equal("00:00:55,610", cue.End);
        Assert.Equal("大家如果有來過台北的話，就知道台北的摩托車還蠻多的", cue.Text);
    }

    [Fact]
    public void CleanCues_SlightlyLongCjkCueWithoutSourceAnchorsKeepsSourceWindow()
    {
        var parsed = SrtTools.ParseSrt(
            "1\n" +
            "00:00:55,670 --> 00:01:04,770\n" +
            "今天路上感覺車還好，然後天氣沒有下雨，但是不是晴天，沒有太陽\n");

        var cleaned = SrtTools.CleanCues(parsed);

        var cue = Assert.Single(cleaned);
        Assert.Equal("00:00:55,670", cue.Start);
        Assert.Equal("00:01:04,770", cue.End);
        Assert.Equal("今天路上感覺車還好，然後天氣沒有下雨，但是不是晴天，沒有太陽", cue.Text);
    }

    [Fact]
    public void CleanCues_NoAnchorCjkCueUnderHardWindowKeepsSourceWindow()
    {
        var parsed = SrtTools.ParseSrt(
            "1\n" +
            "00:01:16,360 --> 00:01:29,220\n" +
            "那我們現在可以來學一些車上的字，後照鏡可以看到後面的車\n");

        var cleaned = SrtTools.CleanCues(parsed);

        var cue = Assert.Single(cleaned);
        Assert.Equal("00:01:16,360", cue.Start);
        Assert.Equal("00:01:29,220", cue.End);
        Assert.Equal("那我們現在可以來學一些車上的字，後照鏡可以看到後面的車", cue.Text);
    }

    [Fact]
    public void CleanCues_CjkCueWithDigitsIsNotCappedAsShortFeedback()
    {
        var parsed = SrtTools.ParseSrt(
            "1\n" +
            "00:02:20,940 --> 00:02:32,470\n" +
            "因為大概20分鐘的車程，所以喝一杯飲料剛剛好 也不錯，現在在等紅綠燈\n");

        var cleaned = SrtTools.CleanCues(parsed);

        var cue = Assert.Single(cleaned);
        Assert.Equal("00:02:20,940", cue.Start);
        Assert.Equal("00:02:32,470", cue.End);
        Assert.Equal("因為大概20分鐘的車程，所以喝一杯飲料剛剛好也不錯，現在在等紅綠燈", cue.Text);
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
        var mainCue = Assert.Single(cleanedQuestion, c => c.Text == "Our main objective today is a 10 engine static fire.");
        Assert.True(
            SrtTools.SrtTimeToSeconds(mainCue.Start)!.Value >= SrtTools.SrtTimeToSeconds("00:00:45,430")!.Value,
            "A new sentence should not appear immediately at the previous source boundary.");
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
    public void CleanCues_RollingRomanceFragmentBorrowDoesNotDelayMidSentenceStart()
    {
        var cleaned = SrtTools.CleanCues(SrtTools.ParseSrt(
            "1\n" +
            "00:01:15,479 --> 00:01:18,649\n" +
            "el tiempo descubrí que no\n" +
            "no tengo el poder de leer Mentes pero\n" +
            "\n" +
            "2\n" +
            "00:01:18,649 --> 00:01:18,659\n" +
            "no tengo el poder de leer Mentes pero\n" +
            "\n" +
            "3\n" +
            "00:01:18,659 --> 00:01:20,210\n" +
            "no tengo el poder de leer Mentes pero\n" +
            "poco a poco fui desarrollando la\n" +
            "\n" +
            "4\n" +
            "00:01:20,210 --> 00:01:20,220\n" +
            "poco a poco fui desarrollando la\n" +
            "\n" +
            "5\n" +
            "00:01:20,220 --> 00:01:22,670\n" +
            "poco a poco fui desarrollando la\n" +
            "habilidad de conectar y sobre todo\n" +
            "\n" +
            "6\n" +
            "00:01:22,670 --> 00:01:22,680\n" +
            "habilidad de conectar y sobre todo\n" +
            "\n" +
            "7\n" +
            "00:01:22,680 --> 00:01:26,149\n" +
            "habilidad de conectar y sobre todo\n" +
            "entender los corazones de ahí surgió mi\n" +
            "\n" +
            "8\n" +
            "00:01:26,149 --> 00:01:26,159\n" +
            "entender los corazones de ahí surgió mi\n" +
            "\n" +
            "9\n" +
            "00:01:26,159 --> 00:01:27,830\n" +
            "entender los corazones de ahí surgió mi\n" +
            "verdadera Pasión por todo el mundo del\n" +
            "\n" +
            "10\n" +
            "00:01:27,830 --> 00:01:27,840\n" +
            "verdadera Pasión por todo el mundo del\n" +
            "\n" +
            "11\n" +
            "00:01:27,840 --> 00:01:29,690\n" +
            "verdadera Pasión por todo el mundo del\n" +
            "lenguaje no verbal todo lo que me\n" +
            "\n" +
            "12\n" +
            "00:01:29,690 --> 00:01:29,700\n" +
            "lenguaje no verbal todo lo que me\n" +
            "\n" +
            "13\n" +
            "00:01:29,700 --> 00:01:31,609\n" +
            "lenguaje no verbal todo lo que me\n" +
            "pudiera empezar a platicar la historia\n" +
            "\n" +
            "14\n" +
            "00:01:31,609 --> 00:01:31,619\n" +
            "pudiera empezar a platicar la historia\n" +
            "\n" +
            "15\n" +
            "00:01:31,619 --> 00:01:33,710\n" +
            "pudiera empezar a platicar la historia\n" +
            "de las personas que tenía enfrente su\n" +
            "\n" +
            "16\n" +
            "00:01:33,710 --> 00:01:33,720\n" +
            "de las personas que tenía enfrente su\n" +
            "\n" +
            "17\n" +
            "00:01:33,720 --> 00:01:36,109\n" +
            "de las personas que tenía enfrente su\n" +
            "lenguaje corporal su lenguaje facial la\n" +
            "\n" +
            "18\n" +
            "00:01:36,109 --> 00:01:36,119\n" +
            "lenguaje corporal su lenguaje facial la\n" +
            "\n" +
            "19\n" +
            "00:01:36,119 --> 00:01:39,469\n" +
            "lenguaje corporal su lenguaje facial la\n" +
            "ropa los movimientos el tono de voz todo\n" +
            "\n" +
            "20\n" +
            "00:01:39,469 --> 00:01:39,479\n" +
            "ropa los movimientos el tono de voz todo\n" +
            "\n" +
            "21\n" +
            "00:01:39,479 --> 00:01:41,510\n" +
            "ropa los movimientos el tono de voz todo\n" +
            "lo que me dijera Quién era la persona\n" +
            "\n" +
            "22\n" +
            "00:01:41,510 --> 00:01:41,520\n" +
            "lo que me dijera Quién era la persona\n" +
            "\n" +
            "23\n" +
            "00:01:41,520 --> 00:01:44,510\n" +
            "lo que me dijera Quién era la persona\n" +
            "que estaba enfrente de mí eso con el\n"));

        var cue = Assert.Single(cleaned, c => c.Text.Contains("a platicar la historia", StringComparison.Ordinal));
        Assert.True(
            SrtTools.SrtTimeToSeconds(cue.Start)!.Value <= SrtTools.SrtTimeToSeconds("00:01:30,950")!.Value,
            "Mid-sentence fragments should borrow the earlier source token timing instead of waiting for the next rolling window.");
    }

    [Fact]
    public void CleanCues_MergesShortRomancePrefixWithContinuationAdverb()
    {
        var cleaned = SrtTools.CleanCues(SrtTools.ParseSrt(
            "1\n" +
            "00:01:28,000 --> 00:01:31,109\n" +
            "des oranges maltaises mais elles\n" +
            "viennent de Tunisie et elles sont\n" +
            "\n" +
            "2\n" +
            "00:01:31,109 --> 00:01:31,119\n" +
            "viennent de Tunisie et elles sont\n" +
            " \n" +
            "\n" +
            "3\n" +
            "00:01:31,119 --> 00:01:35,830\n" +
            "viennent de Tunisie et elles sont\n" +
            "également à 3,99 € le kilo. On trouve\n" +
            "\n" +
            "4\n" +
            "00:01:35,830 --> 00:01:35,840\n" +
            "également à 3,99 € le kilo. On trouve\n" +
            " \n" +
            "\n" +
            "5\n" +
            "00:01:35,840 --> 00:01:39,389\n" +
            "également à 3,99 € le kilo. On trouve\n" +
            "aussi en toute saison des pommes.\n" +
            "\n" +
            "6\n" +
            "00:01:39,389 --> 00:01:39,399\n" +
            "aussi en toute saison des pommes.\n" +
            " \n" +
            "\n" +
            "7\n" +
            "00:01:39,399 --> 00:01:42,830\n" +
            "aussi en toute saison des pommes.\n" +
            "Ici nous avons des pommes Golden\n" +
            "\n" +
            "8\n" +
            "00:01:42,830 --> 00:01:42,840\n" +
            "Ici nous avons des pommes Golden\n" +
            " \n" +
            "\n" +
            "9\n" +
            "00:01:42,840 --> 00:01:47,230\n" +
            "Ici nous avons des pommes Golden\n" +
            "qui coûtent 3,99 € le kilo.\n"));

        Assert.DoesNotContain(cleaned, c => c.Text == "On trouve");
        var cue = Assert.Single(cleaned, c => c.Text == "On trouve aussi en toute saison des pommes.");
        Assert.True(
            SrtTools.SrtTimeToSeconds(cue.End)!.Value >= SrtTools.SrtTimeToSeconds("00:01:39,000")!.Value,
            "The merged French continuation cue should remain visible through the spoken phrase.");
    }

    [Fact]
    public void CleanCues_KeepsDecimalPercentAndMergesEnglishOrphanTail()
    {
        var input = new List<SubtitleCue>
        {
            new(1, "00:00:00,000", "00:00:12,000",
                "The The Sun is uh 99.8% of all mass in the solar system."),
            new(2, "00:00:12,010", "00:00:15,000",
                "And Jupiter is about 0.1% and Earth is in the miscellaneous category."),
            new(3, "00:00:15,010", "00:00:19,500",
                "hopefully at the solar system, and send spaceships to other star"),
            new(4, "00:00:19,510", "00:00:20,800",
                "systems."),
            new(5, "00:00:20,900", "00:00:21,140",
                "The Starship"),
            new(6, "00:00:21,150", "00:00:25,400",
                "V4 will make uh Starship V3 look kind of short."),
        };

        var texts = SrtTools.CleanCues(input).Select(c => c.Text).ToList();

        Assert.Contains(texts, text => text.Contains("99.8%", StringComparison.Ordinal));
        Assert.DoesNotContain(texts, text => text.Trim().EndsWith("99.", StringComparison.Ordinal));
        Assert.DoesNotContain(texts, text => text.Trim().StartsWith("8%", StringComparison.Ordinal));
        Assert.Contains(texts, text => text.Contains("0.1%", StringComparison.Ordinal));
        Assert.Contains(texts, text => text.Contains("other star systems.", StringComparison.Ordinal));
        Assert.DoesNotContain("systems.", texts);
        Assert.Contains(texts, text => text.Contains("The Starship V4 will make", StringComparison.Ordinal));
        Assert.DoesNotContain("The Starship", texts);
    }

    [Fact]
    public void CleanCues_DelaysTightSentenceHandoffToAvoidEarlyCutoff()
    {
        var cleaned = SrtTools.CleanCues(SrtTools.ParseSrt(
            "1\n" +
            "00:01:39,399 --> 00:01:42,830\n" +
            "aussi en toute saison des pommes.\n" +
            "Ici nous avons des pommes Golden\n" +
            "\n" +
            "2\n" +
            "00:01:42,830 --> 00:01:42,840\n" +
            "Ici nous avons des pommes Golden\n" +
            " \n" +
            "\n" +
            "3\n" +
            "00:01:42,840 --> 00:01:47,230\n" +
            "Ici nous avons des pommes Golden\n" +
            "qui coûtent 3,99 € le kilo.\n" +
            "\n" +
            "4\n" +
            "00:01:47,240 --> 00:01:50,389\n" +
            "qui coûtent 3,99 € le kilo.\n" +
            "On trouve aussi d'autres pommes\n" +
            "\n" +
            "5\n" +
            "00:01:50,389 --> 00:01:50,399\n" +
            "On trouve aussi d'autres pommes\n" +
            " \n" +
            "\n" +
            "6\n" +
            "00:01:50,399 --> 00:01:53,069\n" +
            "On trouve aussi d'autres pommes\n" +
            "qui sont des pommes Royal Gala au même\n" +
            "\n" +
            "7\n" +
            "00:01:53,069 --> 00:01:53,079\n" +
            "qui sont des pommes Royal Gala au même\n" +
            " \n" +
            "\n" +
            "8\n" +
            "00:01:53,079 --> 00:01:56,310\n" +
            "qui sont des pommes Royal Gala au même\n" +
            "prix. Ici, il y a trois sortes de\n" +
            "\n" +
            "9\n" +
            "00:01:56,310 --> 00:01:56,320\n" +
            "prix. Ici, il y a trois sortes de\n" +
            " \n" +
            "\n" +
            "10\n" +
            "00:01:56,320 --> 00:01:59,190\n" +
            "prix. Ici, il y a trois sortes de\n" +
            "poivrons. Des poivrons jaunes, des\n"));

        var cue = Assert.Single(cleaned, c => c.Text == "On trouve aussi d'autres pommes qui sont des pommes Royal Gala au même prix.");
        Assert.True(
            SrtTools.SrtTimeToSeconds(cue.End)!.Value >= SrtTools.SrtTimeToSeconds("00:01:54,050")!.Value,
            "A complete sentence should not disappear immediately before a tightly attached new sentence starts.");
    }

    [Fact]
    public void CleanCues_TedxColonHandoffAndShortAsideAvoidLateHolds()
    {
        var cleaned = SrtTools.CleanCues(SrtTools.ParseSrt(
            "1\n" +
            "00:01:36,718 --> 00:01:40,247\n" +
            "when the sleep deprivation\n" +
            "really kicked in,\n" +
            "\n" +
            "2\n" +
            "00:01:40,247 --> 00:01:42,299\n" +
            "like around week eight,\n" +
            "\n" +
            "3\n" +
            "00:01:42,299 --> 00:01:45,732\n" +
            "I had this thought,\n" +
            "and it was the same thought\n" +
            "\n" +
            "4\n" +
            "00:01:45,732 --> 00:01:49,773\n" +
            "that parents across the ages,\n" +
            "internationally,\n" +
            "\n" +
            "5\n" +
            "00:01:49,773 --> 00:01:52,467\n" +
            "everybody has had this thought,\n" +
            "which is:\n" +
            "\n" +
            "6\n" +
            "00:01:52,467 --> 00:01:58,054\n" +
            "I am never going to have\n" +
            "free time ever again.\n"));

        var shortAside = Assert.Single(cleaned, c => c.Text == "like around week eight,");
        Assert.True(
            SrtTools.SrtTimeToSeconds(shortAside.End)!.Value <= SrtTools.SrtTimeToSeconds("00:01:42,180")!.Value,
            "A short non-sentence aside should not linger almost a second after speech has ended.");

        var punchline = Assert.Single(cleaned, c => c.Text == "I am never going to have\nfree time ever again.");
        Assert.True(
            SrtTools.SrtTimeToSeconds(punchline.Start)!.Value <= SrtTools.SrtTimeToSeconds("00:01:52,350")!.Value,
            "A colon handoff should let the following sentence appear slightly before the delayed source cue boundary without cutting the previous cue too early.");
        Assert.All(cleaned, cue =>
        {
            var start = SrtTools.SrtTimeToSeconds(cue.Start)!.Value;
            var end = SrtTools.SrtTimeToSeconds(cue.End)!.Value;
            Assert.True(end >= start);
            Assert.True(end - start <= 12.2, $"Cue is too long: {cue.Start} --> {cue.End}");
        });
    }

    [Fact]
    public void CleanCues_KeepsEmphaticShortSentenceVisibleAfterHandoff()
    {
        var cleaned = SrtTools.CleanCues(SrtTools.ParseSrt(
            "1\n" +
            "00:03:03,040 --> 00:03:05,117\n" +
            "You know what I found?\n" +
            "\n" +
            "2\n" +
            "00:03:05,117 --> 00:03:09,438\n" +
            "10,000 hours!\n" +
            "\n" +
            "3\n" +
            "00:03:09,438 --> 00:03:11,200\n" +
            "Anybody ever heard this?\n"));

        var emphatic = Assert.Single(cleaned, c => c.Text == "10,000 hours!");
        Assert.True(SrtTools.SrtTimeToSeconds(emphatic.Start)!.Value <= SrtTools.SrtTimeToSeconds("00:03:05,367")!.Value);
        Assert.True(
            SrtTools.SrtTimeToSeconds(emphatic.End)!.Value >= SrtTools.SrtTimeToSeconds("00:03:07,567")!.Value,
            "A short emphatic sentence should not disappear immediately after a sentence handoff shifts its start later.");
    }

    [Fact]
    public void CleanCues_DoesNotBorrowColonHandoffBeforePreviousSpeechEnds()
    {
        var cleaned = SrtTools.CleanCues(SrtTools.ParseVtt(
            "WEBVTT\n" +
            "\n" +
            "00:04:49.608 --> 00:04:52.095\n" +
            "We had the place crammed\n" +
            "full of agents in T-shirts:\n" +
            "\n" +
            "00:04:52.119 --> 00:04:53.533\n" +
            "\"James Robinson IS Joseph!\"\n"));

        var setup = Assert.Single(cleaned, c => c.Text.Contains("agents in T-shirts:", StringComparison.Ordinal));
        Assert.True(
            SrtTools.SrtTimeToSeconds(setup.End)!.Value >= SrtTools.SrtTimeToSeconds("00:04:51,945")!.Value,
            "Colon handoff should not cut the setup cue more than 150ms before its source speech window ends.");

        var punchline = Assert.Single(cleaned, c => c.Text.Contains("James Robinson", StringComparison.Ordinal));
        Assert.True(
            SrtTools.SrtTimeToSeconds(punchline.Start)!.Value <= SrtTools.SrtTimeToSeconds("00:04:51,960")!.Value,
            "Colon handoff should still let the response appear slightly before the source cue boundary.");
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
            Cue(5, "00:00:04,000", "00:00:05,000", "(Acclamations)"),
            Cue(6, "00:00:05,000", "00:00:06,000", "(Applaudissements)"),
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
