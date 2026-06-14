using Moongate.Core;
using Xunit;

namespace Moongate.Core.Tests;

public class TranscoderPlanTests
{
    [Fact]
    public void RemuxSameCodecToMkv_UsesCopy_KeepsHdr()
    {
        var plan = Transcoder.BuildPlan(
            OutputFormat.Mkv, "in.webm", "out.mkv",
            sourceVCodec: "vp9", sourceIsHdr: true, x265Available: true);
        Assert.True(plan.IsRemux);
        Assert.False(plan.DropsHdr);
        Assert.Contains("copy", plan.FfmpegArgs);
        Assert.Equal("mkv", plan.OutputExtension);
    }

    [Fact]
    public void TranscodeToH264FromHdr_Tonemaps_DropsHdr()
    {
        var plan = Transcoder.BuildPlan(
            OutputFormat.Mp4H264, "in.webm", "out.mp4",
            sourceVCodec: "vp9", sourceIsHdr: true, x265Available: true);
        Assert.False(plan.IsRemux);
        Assert.True(plan.DropsHdr);
        var joined = string.Join(" ", plan.FfmpegArgs);
        Assert.Contains("libx264", joined);
        Assert.Contains("tonemap", joined);
    }

    [Fact]
    public void TranscodeToH265FromHdr_KeepsHdr_WhenX265Available()
    {
        var plan = Transcoder.BuildPlan(
            OutputFormat.Mp4H265, "in.webm", "out.mp4",
            sourceVCodec: "vp9", sourceIsHdr: true, x265Available: true);
        Assert.False(plan.DropsHdr);
        var joined = string.Join(" ", plan.FfmpegArgs);
        Assert.Contains("libx265", joined);
        Assert.Contains("yuv420p10le", joined);
        Assert.Contains("transfer=smpte2084", joined);
    }

    [Fact]
    public void TranscodeToH265FromHdr_DropsHdr_WhenX265Unavailable()
    {
        var plan = Transcoder.BuildPlan(
            OutputFormat.Mp4H265, "in.webm", "out.mp4",
            sourceVCodec: "vp9", sourceIsHdr: true, x265Available: false);
        Assert.True(plan.DropsHdr);
        // x265 不可用回退时，HDR 源必须 tonemap 降级成 SDR，否则画面发灰/偏色。
        var joined = string.Join(" ", plan.FfmpegArgs);
        Assert.Contains("tonemap", joined);
        Assert.DoesNotContain("yuv420p10le", joined);
    }

    [Fact]
    public void RemuxAlreadyH264ToMp4_IsCopy()
    {
        var plan = Transcoder.BuildPlan(
            OutputFormat.Mp4H264, "in.mp4", "out.mp4",
            sourceVCodec: "h264", sourceIsHdr: false, x265Available: true);
        Assert.True(plan.IsRemux);
        Assert.Contains("copy", plan.FfmpegArgs);
    }

    [Fact]
    public void RemuxAlreadyH265ToMp4_IsCopy_TagsHvc1()
    {
        var plan = Transcoder.BuildPlan(
            OutputFormat.Mp4H265, "in.mkv", "out.mp4",
            sourceVCodec: "h265", sourceIsHdr: true, x265Available: true);
        Assert.True(plan.IsRemux);
        Assert.Contains("copy", plan.FfmpegArgs);
        Assert.Contains("hvc1", plan.FfmpegArgs);
    }

    [Fact]
    public void OriginalFormat_NeedsNoProcessing()
    {
        Assert.False(Transcoder.NeedsProcessing(OutputFormat.Original));
        Assert.True(Transcoder.NeedsProcessing(OutputFormat.Mp4H265));
        Assert.True(Transcoder.NeedsProcessing(OutputFormat.Mp4H264));
        Assert.True(Transcoder.NeedsProcessing(OutputFormat.Mkv));
    }

    [Theory]
    [InlineData("HDR10", DynamicRange.Hdr10)]
    [InlineData("Dolby Vision", DynamicRange.DolbyVision)]
    [InlineData("DV", DynamicRange.DolbyVision)]
    [InlineData("SDR", DynamicRange.Sdr)]
    [InlineData(null, DynamicRange.Sdr)]
    public void DynamicRange_ParsesYtDlpValue(string? raw, DynamicRange expected) =>
        Assert.Equal(expected, DynamicRangeExtensions.FromYtDlpValue(raw));
}

public class HdrBurnArgsTests
{
    [Fact]
    public void HdrVideoArgs_CarryHdr10Metadata()
    {
        var args = FFmpegBurner.HdrVideoArgs("bt2020", "smpte2084", "bt2020nc", 12000);
        var joined = string.Join(" ", args);
        Assert.Contains("libx265", joined);
        Assert.Contains("yuv420p10le", joined);
        Assert.Contains("colorprim=bt2020", joined);
        Assert.Contains("transfer=smpte2084", joined);
        Assert.Contains("colormatrix=bt2020nc", joined);
        Assert.Contains("hdr-opt=1", joined);
        Assert.Contains("12000k", args);
    }

    [Fact]
    public void HdrVideoArgs_FallBackToBt2020_WhenColorMissing()
    {
        var args = FFmpegBurner.HdrVideoArgs(null, null, null, 8000);
        var joined = string.Join(" ", args);
        Assert.Contains("colorprim=bt2020", joined);
        Assert.Contains("transfer=smpte2084", joined);
    }

    [Theory]
    [InlineData("smpte2084", true)]
    [InlineData("arib-std-b67", true)]
    [InlineData("bt709", false)]
    [InlineData(null, false)]
    public void ProbeResult_IsHdr_FromColorTransfer(string? transfer, bool expected)
    {
        var probe = new FFmpegBurner.ProbeResult(null, null, 1920, 1080, "hevc", transfer);
        Assert.Equal(expected, probe.IsHdr);
    }
}
