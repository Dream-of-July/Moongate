namespace Moongate.Core;

// MARK: - 下载后转码 / remux

/// <summary>
/// 把下载好的文件转成用户选择的输出格式。与 macOS Transcoder 同构。
/// - 同编码换容器（如 vp9 webm → mkv）：remux，-c copy，秒级无损。
/// - 跨编码（如 vp9 → H.264/H.265）：转码；HDR 源转 H.265 用 libx265 10-bit 保 HDR。
/// </summary>
public sealed class Transcoder
{
    /// <summary>转码计划：决定用 remux 还是转码、目标容器、是否丢 HDR。</summary>
    public sealed record Plan(IReadOnlyList<string> FfmpegArgs, string OutputExtension, bool IsRemux, bool DropsHdr);

    /// <summary>是否需要处理：Original 一律跳过；其余按目标格式决定。</summary>
    public static bool NeedsProcessing(OutputFormat format) => format != OutputFormat.Original;

    /// <summary>
    /// 生成 ffmpeg 参数（不含可执行名）。输入输出文件名由调用方拼。
    /// sourceVCodec: 源视频编码简称（h264/h265/vp9/av1…）。sourceIsHdr: 源是否 HDR。
    /// </summary>
    public static Plan BuildPlan(
        OutputFormat format,
        string inputPath,
        string outputPath,
        string? sourceVCodec,
        bool sourceIsHdr,
        bool x265Available)
    {
        var codec = (sourceVCodec ?? "").ToLowerInvariant();
        switch (format)
        {
            case OutputFormat.Original:
                // 不应走到这里；按 remux 处理。
                return new Plan(
                    ["-y", "-i", inputPath, "-c", "copy", outputPath],
                    Path.GetExtension(outputPath).TrimStart('.'), true, false);

            case OutputFormat.Mkv:
                // 只换封装，编码不动 → 保 HDR。
                return new Plan(
                    ["-y", "-i", inputPath, "-c", "copy", outputPath],
                    "mkv", true, false);

            case OutputFormat.Mp4H264:
                if (codec == "h264")
                {
                    // 已是 H.264 → 只换 mp4 容器。
                    return new Plan(
                        ["-y", "-i", inputPath, "-c", "copy", "-movflags", "+faststart", outputPath],
                        "mp4", true, false);
                }
                // 转 H.264：8-bit SDR，HDR 源会丢 HDR（tonemap）。
                var h264Args = new List<string> { "-y", "-i", inputPath };
                if (sourceIsHdr)
                {
                    h264Args.AddRange(["-vf",
                        "zscale=t=linear:npl=100,tonemap=hable,zscale=t=bt709:m=bt709:r=tv,format=yuv420p"]);
                }
                h264Args.AddRange(["-c:v", "libx264", "-crf", "20", "-preset", "medium",
                    "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", outputPath]);
                return new Plan(h264Args, "mp4", false, sourceIsHdr);

            case OutputFormat.Mp4H265:
                if (codec == "h265")
                {
                    return new Plan(
                        ["-y", "-i", inputPath, "-c", "copy", "-tag:v", "hvc1", "-movflags", "+faststart", outputPath],
                        "mp4", true, false);
                }
                // 转 H.265：HDR 源用 libx265 10-bit 保 HDR（x265 可用时）；x265 不可用时回退 tonemap 成 SDR。
                var h265Args = new List<string> { "-y", "-i", inputPath };
                if (sourceIsHdr && x265Available)
                {
                    h265Args.AddRange(["-c:v", "libx265", "-crf", "20", "-preset", "medium",
                        "-pix_fmt", "yuv420p10le",
                        "-x265-params",
                        "hdr-opt=1:repeat-headers=1:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc"]);
                }
                else
                {
                    // x265 不可用或源非 HDR：用 libx265 8-bit；HDR 源先 tonemap 降级成 SDR，避免画面发灰/偏色。
                    if (sourceIsHdr)
                    {
                        h265Args.AddRange(["-vf",
                            "zscale=t=linear:npl=100,tonemap=hable,zscale=t=bt709:m=bt709:r=tv,format=yuv420p"]);
                    }
                    h265Args.AddRange(["-c:v", "libx265", "-crf", "20", "-preset", "medium"]);
                }
                h265Args.AddRange(["-tag:v", "hvc1", "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", outputPath]);
                return new Plan(h265Args, "mp4", false, sourceIsHdr && !x265Available);

            default:
                throw new ArgumentOutOfRangeException(nameof(format));
        }
    }

    /// <summary>
    /// 执行转码/remux：把 inputFile 转成目标格式，返回新文件路径。失败抛 MoongateException.BurnFailed。
    /// 一律先写临时文件再 move 落地，避免「输入输出同名同容器」时 ffmpeg 无法同时读写同一文件而报错。
    /// </summary>
    public async Task<string> TranscodeAsync(
        string inputFile,
        OutputFormat format,
        string? sourceVCodec,
        bool sourceIsHdr,
        TaskControlToken? control,
        Action<double> progress,
        CancellationToken ct = default)
    {
        var ffmpeg = FFmpegBurner.LocateFfmpeg()
            ?? throw MoongateException.BurnFailed("找不到 ffmpeg，无法转码。");
        // 运行时探测 libx265 是否可用（与 macOS 一致）。BtbN ffmpeg-gpl 通常带 libx265，
        // 但第三方/精简构建可能没有；不可用时 HDR 转码会回退 tonemap 成 SDR 而非直接失败。
        var x265 = FFmpegBurner.EncoderAvailable("libx265", ffmpeg);
        var dir = Path.GetDirectoryName(inputFile) ?? ".";
        var stem = Path.GetFileNameWithoutExtension(inputFile);

        // 调用方常传 null；此时探测下载产物的真实编码，让「已是目标编码」时走 remux 而非整段重编码。
        var resolvedVCodec = sourceVCodec ?? await FFmpegBurner.ProbeVideoCodecAsync(inputFile, ct).ConfigureAwait(false);
        // 先求目标容器扩展名（ffmpeg 按输出扩展名推断 muxer，临时文件必须带正确扩展名）。
        var targetExt = BuildPlan(format, inputFile, inputFile, resolvedVCodec, sourceIsHdr, x265).OutputExtension;
        var shortId = Guid.NewGuid().ToString("N")[..8];
        var tmpOutput = Path.Combine(dir, $"{stem}.transcoding.{shortId}.{targetExt}");

        var plan = BuildPlan(format, inputFile, tmpOutput, resolvedVCodec, sourceIsHdr, x265);
        // 最终落地文件名：与输入同容器时允许就地替换（原文件随后删），否则避让已存在文件。
        var output = Path.Combine(dir, $"{stem}.{plan.OutputExtension}");
        var serial = 2;
        while (File.Exists(output) && !PathsEqual(output, inputFile))
        {
            output = Path.Combine(dir, $"{stem} {serial}.{plan.OutputExtension}");
            serial++;
        }

        if (control?.IsCancelled == true) throw MoongateException.Cancelled();
        var totalSeconds = await FFmpegBurner.ProbeDurationSecondsAsync(inputFile, ct).ConfigureAwait(false);
        try
        {
            var (status, tail) = await ProcessRunner.RunStreamingProcessAsync(
                ffmpeg, plan.FfmpegArgs,
                stallTimeout: TimeSpan.FromSeconds(180),
                isSuspended: () => control?.IsPaused ?? false,
                onStart: pid =>
                {
                    if (control?.IsCancelled == true) ProcessTree.KillTree(pid);
                    else control?.SetActivePid(pid);
                },
                onLine: line =>
                {
                    if (FFmpegBurner.ParseProgress(line, totalSeconds) is { } fraction) progress(fraction);
                },
                ct: ct).ConfigureAwait(false);
            control?.SetActivePid(0);
            if (control?.IsCancelled == true)
            {
                TryDelete(tmpOutput);
                throw MoongateException.Cancelled();
            }
            if (status != 0)
            {
                TryDelete(tmpOutput);
                var lastLine = tail.Split('\n', StringSplitOptions.RemoveEmptyEntries).LastOrDefault() ?? "未知错误";
                throw MoongateException.BurnFailed($"转码失败：{lastLine}");
            }
        }
        catch (ProcessStalledException)
        {
            TryDelete(tmpOutput);
            throw MoongateException.BurnFailed("转码进程长时间无输出，已中止（可重试）。");
        }
        // 落地：就地替换或覆盖已存在的目标文件，再把临时文件移到最终名。
        TryDelete(output);
        try
        {
            File.Move(tmpOutput, output);
        }
        catch (Exception e)
        {
            TryDelete(tmpOutput);
            throw MoongateException.BurnFailed($"转码完成但无法保存输出文件：{e.Message}");
        }
        progress(1);
        return output;
    }

    private static bool PathsEqual(string a, string b) =>
        string.Equals(Path.GetFullPath(a), Path.GetFullPath(b),
            OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal);

    private static void TryDelete(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); }
        catch { /* best-effort 清理 */ }
    }
}
