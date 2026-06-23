using Moongate.Core;

namespace MoongateCore.Tests;

public class AssGenerationTests
{
    private static SubtitleCue Cue(string text) =>
        new(1, "00:00:01,000", "00:00:02,500", text);

    [Fact]
    public void Header_DefaultAspect_UsesPlayRes512x288_AndChineseStyleSize15()
    {
        var ass = FFmpegBurner.MakeAss([Cue("你好")], fontName: FFmpegBurner.WindowsFontName);
        Assert.Contains("PlayResX: 512", ass);
        Assert.Contains("PlayResY: 288", ass);
        Assert.Contains($"Style: ZH,{FFmpegBurner.WindowsFontName},15,", ass);
        Assert.Contains(",2,20,20,20,1", ass);  // Alignment 2 + 自动布局最小边距 MarginL/R 20 + MarginV 20
    }

    /// <summary>竖屏 9:16：坐标系收窄、字号边距整体缩小，原文 80% 字号（6）+ 80% 不透明度。</summary>
    [Fact]
    public void Header_PortraitAspect_ShrinksLayoutAndSmallFont()
    {
        var ass = FFmpegBurner.MakeAss(
            [Cue("你好世界\nhello world")], aspect: 9.0 / 16.0, fontName: FFmpegBurner.WindowsFontName);
        Assert.Contains("PlayResX: 162", ass);
        Assert.Contains("PlayResY: 288", ass);
        Assert.Contains($"Style: ZH,{FFmpegBurner.WindowsFontName},8,", ass);
        Assert.Contains(@"你好世界\N{\fs6\alpha&H33&}hello world", ass);
    }

    /// <summary>竖屏下超长中文行在生成 ASS 时就预换行（部分 libass 只在空格断行）。</summary>
    [Fact]
    public void LongChineseLine_PreWrappedInPortraitDialogue()
    {
        var line = "那么，你想找一款能在Nintendo Switch 2上和朋友一起玩的派对游戏。让我";
        var ass = FFmpegBurner.MakeAss([Cue(line)], aspect: 9.0 / 16.0);
        // 自动布局容量 18：超出即换行（具体切点由均衡算法决定，这里只验证发生了预换行）。
        Assert.Contains("\\N", ass);
    }

    [Fact]
    public void WindowsFontName_IsMicrosoftYaHei() =>
        Assert.Equal("Microsoft YaHei", FFmpegBurner.WindowsFontName);

    /// <summary>双语条目：中文行正常字号在上，原文行 80% 字号（12）+ 80% 不透明度在下。</summary>
    [Fact]
    public void BilingualCue_ChineseAboveWithSmallerOriginal()
    {
        var ass = FFmpegBurner.MakeAss([Cue("你好世界\nhello world")]);
        Assert.Contains(@"你好世界\N{\fs12\alpha&H33&}hello world", ass);
    }

    /// <summary>源文件里原文在上也重排为中文在上。</summary>
    [Fact]
    public void ReversedOrder_CjkLineStillOnTop()
    {
        var ass = FFmpegBurner.MakeAss([Cue("hello world\n你好世界")]);
        Assert.Contains(@"你好世界\N{\fs12\alpha&H33&}hello world", ass);
    }

    /// <summary>纯单语（无译文）条目：按词重排合并，用原文字号显示、不加透明度（无译文可对比）。</summary>
    [Fact]
    public void MonolingualCue_UsesOriginalSizeNoAlpha()
    {
        var ass = FFmpegBurner.MakeAss([Cue("plain english\nsecond line")]);
        Assert.Contains("plain english second line", ass);
        // 纯原文用原文字号（12），但不带 alpha 透明（透明只用于双语里区分原文/译文）。
        Assert.DoesNotContain(@"\alpha&H33&", ass.Split("[Events]")[1]);
    }

    /// <summary>大括号与反斜杠转义为全角，避免被 libass 当样式块解析。</summary>
    [Fact]
    public void BracesAndBackslash_EscapedToFullWidth()
    {
        var ass = FFmpegBurner.MakeAss([Cue(@"{\an8}你好")]);
        Assert.Contains("｛＼an8｝你好", ass);
        Assert.DoesNotContain(@"{\an8}", ass);
    }

    [Fact]
    public void DialogueLine_TimestampsConverted()
    {
        var ass = FFmpegBurner.MakeAss([Cue("你好")]);
        Assert.Contains("Dialogue: 0,0:00:01.00,0:00:02.50,ZH,,0,0,0,,你好", ass);
    }

    [Fact]
    public void AssTimestamp_Conversion()
    {
        Assert.Equal("0:01:02.50", FFmpegBurner.AssTimestamp("00:01:02,500"));
        Assert.Equal("1:02:03.04", FFmpegBurner.AssTimestamp("01:02:03,045"));
        Assert.Equal("0:00:01.50", FFmpegBurner.AssTimestamp("00:00:01,5"));  // 右补零
        Assert.Null(FFmpegBurner.AssTimestamp("oops"));
        Assert.Null(FFmpegBurner.AssTimestamp("00:99:01,000"));  // 非法分钟
    }

    [Fact]
    public void InvalidTimestampCue_Skipped()
    {
        var ass = FFmpegBurner.MakeAss([new SubtitleCue(1, "bad", "worse", "text")]);
        Assert.DoesNotContain("Dialogue:", ass);
    }

    [Fact]
    public void ContainsCjk_CoversHanKanaHangul()
    {
        Assert.True(FFmpegBurner.ContainsCjk("你好"));
        Assert.True(FFmpegBurner.ContainsCjk("こんにちは"));
        Assert.True(FFmpegBurner.ContainsCjk("안녕"));
        Assert.False(FFmpegBurner.ContainsCjk("hello 123"));
    }
}

public class AssLayoutTests
{
    /// <summary>竖屏 9:16：坐标系按比例收窄、字号按 sqrt 缩小、原文 80%、最小边距、按可用宽度算容量。</summary>
    [Fact]
    public void Portrait916_Layout()
    {
        var layout = new FFmpegBurner.AssLayout(9.0 / 16.0);
        Assert.Equal(162, layout.PlayResX);
        Assert.Equal(288, layout.PlayResY);
        Assert.Equal(8, layout.ChineseSize);
        Assert.Equal(6, layout.OriginalSize);   // round(8 × 0.8) = 6
        Assert.Equal(Math.Max(5, (int)Math.Round(162 * 0.04, MidpointRounding.AwayFromZero)), layout.MarginH);
        Assert.Equal(18, layout.CjkWrapCapacity);
        Assert.Equal(45, layout.LatinWrapCapacity);
    }

    [Fact]
    public void Landscape169_Layout()
    {
        var layout = new FFmpegBurner.AssLayout(16.0 / 9.0);
        Assert.Equal(512, layout.PlayResX);
        Assert.Equal(15, layout.ChineseSize);
        Assert.Equal(12, layout.OriginalSize);  // round(15 × 0.8) = 12
        Assert.Equal(20, layout.MarginH);        // 自动布局最小边距 512 × 0.04 ≈ 20
        Assert.Equal(31, layout.CjkWrapCapacity); // (512 - 40) / 15 ≈ 31，比旧 26 宽
    }

    [Fact]
    public void Landscape169_LongChineseLine_PreWrappedWhenOverflow()
    {
        // 容量 31 以内不换行；远超才折。
        var ass = FFmpegBurner.MakeAss([
            new SubtitleCue(1, "00:00:01,000", "00:00:02,500",
                "今天，我会介绍如何使用Xcode中的一些强大新工具，在早期探索应用设计时快速尝试不同的界面方向。")
        ]);
        Assert.Contains("\\N", ass);  // 超容量长行应换行
    }

    /// <summary>非法长宽比（0/NaN）回退 16:9；超宽封顶 4.0，自动布局只留最小边距。</summary>
    [Fact]
    public void InvalidAspect_FallsBackTo169_UltraWideCapped()
    {
        foreach (var aspect in new[] { 0.0, double.NaN })
        {
            var layout = new FFmpegBurner.AssLayout(aspect);
            Assert.Equal(512, layout.PlayResX);
            Assert.Equal(15, layout.ChineseSize);
            Assert.Equal(20, layout.MarginH);
            Assert.Equal(31, layout.CjkWrapCapacity);
        }
        var ultraWide = new FFmpegBurner.AssLayout(10.0);
        Assert.Equal(1152, ultraWide.PlayResX);   // 288 × 4.0（封顶）
        Assert.Equal(15, ultraWide.ChineseSize);  // 横屏不缩字号
        Assert.Equal(46, ultraWide.MarginH);       // 1152 × 0.04 ≈ 46
        Assert.Equal(70, ultraWide.CjkWrapCapacity); // (1152 - 92) / 15 ≈ 70
    }
}

public class WrapCjkLineTests
{
    /// <summary>均衡断行：42 字 ÷ 容量 19 → 3 行，且不切进 Nintendo/Switch 单词中间。</summary>
    [Fact]
    public void RealCaption_BalancedThreeLines_NoMidWordCut()
    {
        var wrapped = FFmpegBurner.WrapCjkLine(
            "那么，你想找一款能在Nintendo Switch 2上和朋友一起玩的派对游戏。让我", 19);
        Assert.Equal(
            new[] { "那么，你想找一款能在Nintendo", "Switch 2上和朋友一起", "玩的派对游戏。让我" },
            wrapped);
    }

    [Fact]
    public void ShortLine_NotWrapped() =>
        Assert.Equal(new[] { "你好世界" }, FFmpegBurner.WrapCjkLine("你好世界", 19));

    /// <summary>容量过小（&lt;6）不预换行，交还 libass。</summary>
    [Fact]
    public void TinyCapacity_NotWrapped()
    {
        var line = "这一行明显超过五个字的容量";
        Assert.Equal(new[] { line }, FFmpegBurner.WrapCjkLine(line, 5));
    }
}

public class WrapLatinLineTests
{
    /// <summary>合并源 SRT 碎行后按词重排：不超容量、不切词、首尾无空格。</summary>
    [Fact]
    public void MergesSourceBreaksAndRewrapsByWords()
    {
        var wrapped = FFmpegBurner.WrapLatinLine(
            "Today\nI will\nshow you how to use some powerful new tools in Xcode to quickly explore design directions.",
            40);
        Assert.True(wrapped.Count > 1);
        foreach (var l in wrapped)
        {
            Assert.True(l.Length <= 40, $"每行不得超过容量：{l}");
            Assert.False(l.StartsWith(' '));
            Assert.False(l.EndsWith(' '));
        }
        Assert.Equal(
            "Today I will show you how to use some powerful new tools in Xcode to quickly explore design directions.",
            string.Join(" ", wrapped));
    }

    [Fact]
    public void ShortLine_StaysSingleLine() =>
        Assert.Equal(new[] { "A short caption." }, FFmpegBurner.WrapLatinLine("A short caption.", 50));

    /// <summary>双语：竖屏长英文按词折行而非保留源碎行；任意单行不超过容量 50。</summary>
    [Fact]
    public void BilingualCue_RewrapsEnglishUnderChinese()
    {
        const string english = "This is a fairly long English subtitle line that would otherwise overflow or be chopped into many tiny fragments on a portrait video.";
        var ass = FFmpegBurner.MakeAss(
            [new SubtitleCue(1, "00:00:01,000", "00:00:02,500", $"这是一句中文字幕\n{english}")],
            aspect: 9.0 / 16.0);
        var dialogue = ass.Split('\n').First(l => l.StartsWith("Dialogue:"));
        var englishPart = dialogue.Split('}').Last();
        foreach (var piece in englishPart.Split("\\N"))
            Assert.True(piece.Length <= 50, $"英文行过长：{piece}");
    }
}

public class BurnerParameterTests
{
    /// <summary>竖屏限宽 scale=W:-2，横屏限高 scale=-2:H；无缩放目标返回 null。</summary>
    [Fact]
    public void ScaleFilter_PortraitLimitsWidth_LandscapeLimitsHeight()
    {
        Assert.Equal("scale=1080:-2", FFmpegBurner.ScaleFilter(isPortrait: true, 1080));
        Assert.Equal("scale=-2:1080", FFmpegBurner.ScaleFilter(isPortrait: false, 1080));
        Assert.Null(FFmpegBurner.ScaleFilter(isPortrait: true, null));
    }

    /// <summary>短边：竖屏 1080×1920 视作 1080p——码率档位 6000（1080p），不是 16000（4K）。</summary>
    [Fact]
    public void ShortSide_PortraitVideo_DrivesTierByShortSide()
    {
        Assert.Equal(1080, FFmpegBurner.ShortSide(1080, 1920));
        Assert.Equal(1080, FFmpegBurner.ShortSide(1920, 1080));
        Assert.Equal(1080, FFmpegBurner.ShortSide(null, 1080));
        Assert.Equal(1080, FFmpegBurner.ShortSide(1080, null));
        Assert.Null(FFmpegBurner.ShortSide(null, null));
    }

    /// <summary>缺探测信息时不封顶码率；有探测信息时用 maxrate/bufsize 抑制烧录后体积膨胀。</summary>
    [Fact]
    public void MaxrateFlags_Null_NoCap_NonNull_Caps()
    {
        Assert.Empty(FFmpegBurner.MaxrateFlags(null));
        Assert.Equal(new[] { "-maxrate", "6000k", "-bufsize", "12000k" }, FFmpegBurner.MaxrateFlags(6000));
    }

    [Fact]
    public void SoftwareNoScale_CanUseMaxrateCap()
    {
        var args = FFmpegBurner.SdrH264VideoArgs(6000);

        Assert.Contains("-crf", args);
        Assert.Contains("-maxrate", args);
        Assert.Contains("6000k", args);
    }

    [Fact]
    public void HardwareEncoders_UseBitrateCapWhenProvided()
    {
        var h264 = FFmpegBurner.HwH264VideoArgs("h264_nvenc", 6000);
        Assert.Contains("-b:v", h264);
        Assert.Contains("6000k", h264);
        Assert.DoesNotContain("0", h264);

        var hevc = FFmpegBurner.HwHevcVideoArgs("hevc_qsv", 8000);
        Assert.Contains("-b:v", hevc);
        Assert.Contains("8000k", hevc);

        var hdr = FFmpegBurner.HwHdrVideoArgs("hevc_amf", 10000);
        Assert.Contains("-b:v", hdr);
        Assert.Contains("10000k", hdr);
        Assert.DoesNotContain("-qp_p", hdr);
    }

    [Fact]
    public void BurnerComputesMaxrateForNoScaleWhenSourceSizeIsKnown()
    {
        var source = File.ReadAllText(Path.Combine(RepoRoot(), "windows", "MoongateCore", "Burner.cs"));

        Assert.Contains("var capShortSide = targetShortSide ?? sourceShortSide", source);
        Assert.Contains("capShortSide is { } cap", source);
    }

    [Fact]
    public void MaxrateK_Scaled_TierOfTargetHeight_MinWithSource()
    {
        // 4K 高码率源缩到 1080p：min(6000, 30000) = 6000
        Assert.Equal(6000, FFmpegBurner.MaxrateK(20_000_000, 2160, 1080));
        // 低码率 4K 源缩 1080p：min(6000, 1500) = 1500
        Assert.Equal(1500, FFmpegBurner.MaxrateK(1_000_000, 2160, 1080));
        // 缺源码率：目标档位
        Assert.Equal(6000, FFmpegBurner.MaxrateK(null, 2160, 1080));
    }

    [Fact]
    public void BitrateForHeight_Tiers()
    {
        Assert.Equal(16000, FFmpegBurner.BitrateForHeight(2160));
        Assert.Equal(10000, FFmpegBurner.BitrateForHeight(1440));
        Assert.Equal(6000, FFmpegBurner.BitrateForHeight(1080));
        Assert.Equal(3000, FFmpegBurner.BitrateForHeight(720));
        Assert.Equal(1500, FFmpegBurner.BitrateForHeight(480));
    }

    [Fact]
    public void ParseProgress_OutTimeMicroseconds()
    {
        Assert.Equal(0.5, FFmpegBurner.ParseProgress("out_time_ms=30000000", 60)!.Value, precision: 9);
        Assert.Equal(0.5, FFmpegBurner.ParseProgress("out_time_us=30000000", 60)!.Value, precision: 9);
        Assert.Equal(1.0, FFmpegBurner.ParseProgress("out_time_ms=999000000", 60)!.Value, precision: 9);  // 上限 1
        Assert.Null(FFmpegBurner.ParseProgress("frame=12", 60));
        Assert.Null(FFmpegBurner.ParseProgress("out_time_ms=1", null));  // 无总时长
    }

    [Fact]
    public void LastLine_TrimsAndTruncates()
    {
        Assert.Equal("real error", FFmpegBurner.LastLine("info\nreal error\n  \n"));
        Assert.Equal("未知错误", FFmpegBurner.LastLine(""));
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
}

/// <summary>0.5：原文分类（简体中文 vs 日韩/拉丁）、80% 字号+透明度。</summary>
public class OriginalClassificationTests
{
    [Fact]
    public void IsSimplifiedChinese_OnlyHanWithoutKanaHangul()
    {
        Assert.True(FFmpegBurner.IsSimplifiedChineseLine("我会一直在你身边"));
        Assert.False(FFmpegBurner.IsSimplifiedChineseLine("ずっとそばにいるよ"), "日文（假名）不是译文");
        Assert.False(FFmpegBurner.IsSimplifiedChineseLine("항상 네 곁에 있을게"), "韩文（谚文）不是译文");
        Assert.False(FFmpegBurner.IsSimplifiedChineseLine("Always by your side"), "英文不是译文");
    }

    [Fact]
    public void JapaneseOriginal_TreatedAsOriginal_SmallerAndTransparent()
    {
        var ass = FFmpegBurner.MakeAss([
            new SubtitleCue(1, "00:00:01,000", "00:00:02,500", "我会一直在你身边\nずっとそばにいるよ")
        ]);
        var dialogue = ass.Split('\n').First(l => l.StartsWith("Dialogue:"));
        Assert.Contains(@"\alpha&H33&", dialogue);  // 日文原文进原文层（缩小+透明）
        var zhIdx = dialogue.IndexOf("我会一直在你身边", StringComparison.Ordinal);
        var ovIdx = dialogue.IndexOf(@"\alpha&H33&", StringComparison.Ordinal);
        Assert.True(zhIdx >= 0 && ovIdx > zhIdx, "中文译文应在原文之上");
    }

    [Fact]
    public void KoreanOriginal_TreatedAsOriginal()
    {
        var ass = FFmpegBurner.MakeAss([
            new SubtitleCue(1, "00:00:01,000", "00:00:02,500", "我会一直在你身边\n항상 네 곁에 있을게")
        ]);
        Assert.Contains(@"\alpha&H33&", ass);
    }
}

/// <summary>0.5：硬件/软件编码选择 + 回退链（NVENC/QSV/AMF；硬件失败退软件同编码）。</summary>
public class EncoderSelectionTests
{
    // 注入：声明全部硬件编码器可用。
    private static bool AllHw(string enc) => true;
    private static bool NoHw(string enc) => false;
    private static Func<string, bool> Only(params string[] names) => enc => names.Contains(enc);

    [Fact]
    public void AutoSdrHevc_PrefersHardwareHevc_NvencFirst()
    {
        var s = FFmpegBurner.SelectVideoEncoder(EncodeBackend.Auto, alwaysH264: false,
            sourceIsHevc: true, isHdr: false, null, null, null, null, x265Available: true, AllHw);
        Assert.Contains("hevc_nvenc", s.EncoderArgs);
    }

    [Fact]
    public void Auto_NvencUnavailable_FallsToQsvThenAmf()
    {
        var qsv = FFmpegBurner.SelectVideoEncoder(EncodeBackend.Auto, false, true, false,
            null, null, null, null, true, Only("hevc_qsv", "h264_qsv"));
        Assert.Contains("hevc_qsv", qsv.EncoderArgs);
        var amf = FFmpegBurner.SelectVideoEncoder(EncodeBackend.Auto, false, true, false,
            null, null, null, null, true, Only("hevc_amf", "h264_amf"));
        Assert.Contains("hevc_amf", amf.EncoderArgs);
    }

    [Fact]
    public void SoftwareBackend_AlwaysLibx()
    {
        var s = FFmpegBurner.SelectVideoEncoder(EncodeBackend.Software, false, true, false,
            null, null, null, null, true, AllHw);
        Assert.Contains("libx265", s.EncoderArgs);
        Assert.DoesNotContain("hevc_nvenc", s.EncoderArgs);
    }

    [Fact]
    public void AlwaysH264_ForcesH264_EvenForHevcSource()
    {
        var hw = FFmpegBurner.SelectVideoEncoder(EncodeBackend.Auto, alwaysH264: true,
            sourceIsHevc: true, isHdr: false, null, null, null, null, true, AllHw);
        Assert.Contains("h264_nvenc", hw.EncoderArgs);
        var sw = FFmpegBurner.SelectVideoEncoder(EncodeBackend.Software, alwaysH264: true,
            sourceIsHevc: true, isHdr: false, null, null, null, null, true, AllHw);
        Assert.Contains("libx264", sw.EncoderArgs);
    }

    [Fact]
    public void HdrAuto_HardwareMain10_WithColorMetadata()
    {
        var s = FFmpegBurner.SelectVideoEncoder(EncodeBackend.Auto, false, false, isHdr: true,
            null, null, null, null, true, AllHw);
        Assert.Contains("hevc_nvenc", s.EncoderArgs);
        Assert.Contains("main10", s.EncoderArgs);
        Assert.Contains("p010le", s.EncoderArgs);
        Assert.Contains("smpte2084", s.ColorArgs);
        Assert.Contains("bt2020", s.ColorArgs);
        Assert.Contains("p010le", s.FilterSuffix);
    }

    [Fact]
    public void HdrSoftware_Libx265TenBit()
    {
        var s = FFmpegBurner.SelectVideoEncoder(EncodeBackend.Software, false, false, isHdr: true,
            null, null, null, null, true, AllHw);
        Assert.Contains("libx265", s.EncoderArgs);
        Assert.Contains("yuv420p10le", s.EncoderArgs);
    }

    [Fact]
    public void HdrPlusAlwaysH264_TonemapsToSdr()
    {
        var s = FFmpegBurner.SelectVideoEncoder(EncodeBackend.Auto, alwaysH264: true, false, isHdr: true,
            null, null, null, null, true, AllHw);
        Assert.Contains("tonemap", s.FilterPrefix);
        Assert.Contains("h264_nvenc", s.EncoderArgs);
    }

    [Fact]
    public void Chain_HardwareHevc_FallsBackToLibx265SameCodec()
    {
        var chain = FFmpegBurner.SelectVideoEncoderChain(EncodeBackend.Auto, false, sourceIsHevc: true,
            isHdr: false, null, null, null, null, x265Available: true, AllHw);
        Assert.Equal(2, chain.Count);
        Assert.Contains("hevc_nvenc", chain[0].EncoderArgs);
        Assert.Contains("libx265", chain[1].EncoderArgs);   // 回退仍是 HEVC
        Assert.DoesNotContain("libx264", chain[1].EncoderArgs);
    }

    [Fact]
    public void Chain_HardwareUnavailable_SingleSoftwareCandidate()
    {
        var chain = FFmpegBurner.SelectVideoEncoderChain(EncodeBackend.Auto, false, true,
            false, null, null, null, null, true, NoHw);
        Assert.Single(chain);
        Assert.Contains("libx265", chain[0].EncoderArgs);
    }

    [Fact]
    public void Chain_SoftwareBackend_NoFallback()
    {
        var chain = FFmpegBurner.SelectVideoEncoderChain(EncodeBackend.Software, false, true,
            false, null, null, null, null, true, AllHw);
        Assert.Single(chain);
    }

    [Fact]
    public void Mp4AudioChain_PrefersAacBeforeCopy_ForWindowsPlayerCompatibility()
    {
        var chain = FFmpegBurner.Mp4CompatibleAudioEncodingChain();

        Assert.Equal("aac", chain[0][1]);
        Assert.Equal("copy", chain[1][1]);
    }

}
