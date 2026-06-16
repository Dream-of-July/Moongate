namespace Moongate.Core;

/// <summary>ffmpeg 硬件加速家族。用于解释当前计划走的是哪类系统媒体/显卡能力。</summary>
public enum HardwareAccelerationFamily
{
    None,
    VideoToolbox,
    Nvidia,
    IntelQuickSync,
    AmdAmf,
}

/// <summary>一条转码/压制计划实际使用的加速路径摘要。</summary>
public sealed record PipelineAccelerationReport(
    HardwareAccelerationFamily Family = HardwareAccelerationFamily.None,
    bool UsesHardwareDecode = false,
    bool UsesHardwareFilter = false,
    bool UsesHardwareEncode = false,
    string? CompatibilityNotice = null)
{
    public const string CompatibilityModeNotice = "遇到兼容性问题，实际耗时可能比预计更长。";
    public static readonly PipelineAccelerationReport None = new();
}

internal static class HardwareAccelerationPlanner
{
    internal static IReadOnlyList<string> InputArgs(
        HardwareAccelerationFamily family,
        bool requiresCpuVideoFilter)
    {
        if (requiresCpuVideoFilter) return [];
        return family switch
        {
            HardwareAccelerationFamily.VideoToolbox => ["-hwaccel", "videotoolbox"],
            HardwareAccelerationFamily.Nvidia => ["-hwaccel", "cuda"],
            HardwareAccelerationFamily.IntelQuickSync => ["-hwaccel", "qsv"],
            HardwareAccelerationFamily.AmdAmf => ["-hwaccel", "d3d11va"],
            _ => [],
        };
    }

    internal static PipelineAccelerationReport Report(
        HardwareAccelerationFamily family,
        bool usesHardwareEncode,
        bool requiresCpuVideoFilter) =>
        new(
            family,
            UsesHardwareDecode: family != HardwareAccelerationFamily.None && !requiresCpuVideoFilter,
            UsesHardwareFilter: false,
            UsesHardwareEncode: usesHardwareEncode,
            CompatibilityNotice: family != HardwareAccelerationFamily.None && requiresCpuVideoFilter
                ? PipelineAccelerationReport.CompatibilityModeNotice
                : null);

    internal static HardwareAccelerationFamily FamilyForEncoder(string? encoder)
    {
        if (encoder is null) return HardwareAccelerationFamily.None;
        if (encoder.Contains("nvenc", StringComparison.OrdinalIgnoreCase)) return HardwareAccelerationFamily.Nvidia;
        if (encoder.Contains("qsv", StringComparison.OrdinalIgnoreCase)) return HardwareAccelerationFamily.IntelQuickSync;
        if (encoder.Contains("amf", StringComparison.OrdinalIgnoreCase)) return HardwareAccelerationFamily.AmdAmf;
        if (encoder.Contains("videotoolbox", StringComparison.OrdinalIgnoreCase)) return HardwareAccelerationFamily.VideoToolbox;
        return HardwareAccelerationFamily.None;
    }
}
