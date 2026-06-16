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
    public sealed record Plan
    {
        public IReadOnlyList<string> FfmpegArgs { get; }
        public string OutputExtension { get; }
        public bool IsRemux { get; }
        public bool DropsHdr { get; }
        public PipelineAccelerationReport AccelerationReport { get; }

        public Plan(
            IReadOnlyList<string> ffmpegArgs,
            string outputExtension,
            bool isRemux,
            bool dropsHdr,
            PipelineAccelerationReport? accelerationReport = null)
        {
            FfmpegArgs = ffmpegArgs;
            OutputExtension = outputExtension;
            IsRemux = isRemux;
            DropsHdr = dropsHdr;
            AccelerationReport = accelerationReport ?? PipelineAccelerationReport.None;
        }
    }

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
        bool x265Available,
        EncodeBackend backend = EncodeBackend.Software,
        Func<string, bool>? available = null)
    {
        var codec = (sourceVCodec ?? "").ToLowerInvariant();
        var wantHw = backend.PrefersHardware();
        var probe = available ?? (_ => false);
        var hwH264 = wantHw ? FFmpegBurner.HardwareH264Encoder(probe) : null;
        var hwHevc = wantHw ? FFmpegBurner.HardwareHevcEncoder(probe) : null;
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
                // 转 H.264：8-bit SDR，HDR 源会丢 HDR（tonemap）。硬件可用时用 *_nvenc/qsv/amf。
                var h264Family = HardwareAccelerationPlanner.FamilyForEncoder(hwH264);
                var h264RequiresCpuVideoFilter = sourceIsHdr;
                var h264Args = new List<string> { "-y" };
                h264Args.AddRange(HardwareAccelerationPlanner.InputArgs(h264Family, h264RequiresCpuVideoFilter));
                h264Args.AddRange(["-i", inputPath]);
                if (sourceIsHdr)
                {
                    h264Args.AddRange(["-vf",
                        "zscale=t=linear:npl=100,tonemap=hable,zscale=t=bt709:m=bt709:r=tv,format=yuv420p"]);
                }
                h264Args.AddRange(VideoCodecArgs(hwH264, software: ["-c:v", "libx264", "-crf", "20", "-preset", "medium"]));
                h264Args.AddRange(["-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", outputPath]);
                return new Plan(
                    h264Args, "mp4", false, sourceIsHdr,
                    HardwareAccelerationPlanner.Report(
                        h264Family,
                        usesHardwareEncode: hwH264 is not null,
                        requiresCpuVideoFilter: h264RequiresCpuVideoFilter));

            case OutputFormat.Mp4H265:
                if (codec == "h265")
                {
                    return new Plan(
                        ["-y", "-i", inputPath, "-c", "copy", "-tag:v", "hvc1", "-movflags", "+faststart", outputPath],
                        "mp4", true, false);
                }
                // 转 H.265。硬件 HEVC 可用时优先（HDR 走 main10 + 色彩元数据透传，保 HDR）；
                // 否则软件 libx265（HDR 用 10-bit hdr-opt）；两者都没有且 HDR 时 tonemap 降级。
                var h265Family = HardwareAccelerationPlanner.FamilyForEncoder(hwHevc);
                var h265RequiresCpuVideoFilter = false;
                var h265Args = new List<string> { "-y" };
                h265Args.AddRange(HardwareAccelerationPlanner.InputArgs(h265Family, h265RequiresCpuVideoFilter));
                h265Args.AddRange(["-i", inputPath]);
                bool keepsHdr;
                if (hwHevc is { } hevcEnc)
                {
                    if (sourceIsHdr)
                    {
                        h265Args.AddRange(HwHevcEncoder(hevcEnc, main10: true));
                        h265Args.AddRange(FFmpegBurner.HdrColorArgs(null, null, null));
                        keepsHdr = true;
                    }
                    else
                    {
                        h265Args.AddRange(HwHevcEncoder(hevcEnc, main10: false));
                        keepsHdr = false;
                    }
                }
                else if (sourceIsHdr && x265Available)
                {
                    h265Args.AddRange(["-c:v", "libx265", "-crf", "20", "-preset", "medium",
                        "-pix_fmt", "yuv420p10le",
                        "-x265-params",
                        "hdr-opt=1:repeat-headers=1:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc"]);
                    keepsHdr = true;
                }
                else
                {
                    // x265 不可用或源非 HDR：用 libx265 8-bit；HDR 源先 tonemap 降级成 SDR。
                    if (sourceIsHdr)
                    {
                        h265Args.AddRange(["-vf",
                            "zscale=t=linear:npl=100,tonemap=hable,zscale=t=bt709:m=bt709:r=tv,format=yuv420p"]);
                    }
                    h265Args.AddRange(["-c:v", "libx265", "-crf", "20", "-preset", "medium"]);
                    keepsHdr = false;
                }
                h265Args.AddRange(["-tag:v", "hvc1", "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart"]);
                h265Args.Add(outputPath);
                return new Plan(
                    h265Args, "mp4", false, sourceIsHdr && !keepsHdr,
                    HardwareAccelerationPlanner.Report(
                        h265Family,
                        usesHardwareEncode: hwHevc is not null,
                        requiresCpuVideoFilter: h265RequiresCpuVideoFilter));

            default:
                throw new ArgumentOutOfRangeException(nameof(format));
        }
    }

    /// <summary>硬件编码器优先、否则软件参数。</summary>
    private static IReadOnlyList<string> VideoCodecArgs(string? hwEncoder, string[] software) =>
        hwEncoder is { } enc ? HwH264Encoder(enc) : software;

    /// <summary>硬件 H.264 转码参数（恒定质量）。</summary>
    private static string[] HwH264Encoder(string encoder) => HwQualityArgs(encoder);

    /// <summary>硬件 HEVC 转码参数；main10=true 时 10-bit p010le（HDR）。</summary>
    private static string[] HwHevcEncoder(string encoder, bool main10) => main10
        ? [.. HwQualityArgs(encoder), "-profile:v", "main10", "-pix_fmt", "p010le"]
        : [.. HwQualityArgs(encoder), "-pix_fmt", "yuv420p"];

    /// <summary>各硬件编码器的恒定质量旋钮（与 Burner 一致）。</summary>
    private static string[] HwQualityArgs(string encoder)
    {
        if (encoder.Contains("nvenc")) return ["-c:v", encoder, "-rc", "vbr", "-cq", "22", "-b:v", "0"];
        if (encoder.Contains("qsv")) return ["-c:v", encoder, "-global_quality", "22"];
        return ["-c:v", encoder, "-rc", "cqp", "-qp_i", "22", "-qp_p", "22"];
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
        EncodeBackend backend = EncodeBackend.Auto,
        CancellationToken ct = default)
    {
        var ffmpeg = FFmpegBurner.LocateFfmpeg()
            ?? throw MoongateException.BurnFailed("找不到 ffmpeg，无法转码。");
        // 运行时探测 libx265 是否可用（与 macOS 一致）。BtbN ffmpeg-gpl 通常带 libx265，
        // 但第三方/精简构建可能没有；不可用时 HDR 转码会回退 tonemap 成 SDR 而非直接失败。
        var x265 = FFmpegBurner.EncoderAvailable("libx265", ffmpeg);
        bool Available(string enc) => FFmpegBurner.EncoderAvailable(enc, ffmpeg);
        var dir = Path.GetDirectoryName(inputFile) ?? ".";
        var stem = Path.GetFileNameWithoutExtension(inputFile);

        // 调用方常传 null；此时探测下载产物的真实编码，让「已是目标编码」时走 remux 而非整段重编码。
        var resolvedVCodec = sourceVCodec ?? await FFmpegBurner.ProbeVideoCodecAsync(inputFile, ct).ConfigureAwait(false);
        if (format == OutputFormat.Mp4H265
            && (resolvedVCodec ?? "").ToLowerInvariant() != "h265"
            && FFmpegBurner.HardwareHevcEncoder(Available) is null
            && !x265)
        {
            throw MoongateException.BurnFailed(
                "当前 ffmpeg 缺少 HEVC 编码器（硬件 HEVC 或 libx265），无法转为 H.265。请安装完整 ffmpeg，或改选 H.264/原格式。");
        }
        // 先求目标容器扩展名（ffmpeg 按输出扩展名推断 muxer，临时文件必须带正确扩展名）。
        var resolvedIsHdr = await FFmpegBurner.ProbeVideoIsHdrAsync(inputFile, ct).ConfigureAwait(false) ?? sourceIsHdr;
        var targetExt = BuildPlan(format, inputFile, inputFile, resolvedVCodec, resolvedIsHdr, x265, backend, Available).OutputExtension;
        var shortId = Guid.NewGuid().ToString("N")[..8];
        var tmpOutput = Path.Combine(dir, $"{stem}.transcoding.{shortId}.{targetExt}");

        var plan = BuildPlan(format, inputFile, tmpOutput, resolvedVCodec, resolvedIsHdr, x265, backend, Available);
        // 最终落地文件名：与输入同容器时允许就地替换（原文件随后删），否则避让已存在文件。
        var output = Path.Combine(dir, $"{stem}.{plan.OutputExtension}");
        var serial = 2;
        while (File.Exists(output) && !PathsEqual(output, inputFile))
        {
            output = Path.Combine(dir, $"{stem} {serial}.{plan.OutputExtension}");
            serial++;
        }

        // 进度：plan() 参数不含 -progress（保持纯净、可单测精确断言）；重编码（非 remux）时在输出名前
        // 插入 -progress pipe:1 -nostats，让 ffmpeg 把 out_time_us= 写到 stdout 驱动进度条。
        var args = plan.FfmpegArgs.ToList();
        if (!plan.IsRemux)
        {
            var outIndex = args.LastIndexOf(tmpOutput);
            if (outIndex >= 0) args.InsertRange(outIndex, ["-progress", "pipe:1", "-nostats"]);
        }

        if (control?.IsCancelled == true) throw MoongateException.Cancelled();
        var totalSeconds = await FFmpegBurner.ProbeDurationSecondsAsync(inputFile, ct).ConfigureAwait(false);
        try
        {
            var (status, tail) = await ProcessRunner.RunStreamingProcessAsync(
                ffmpeg, args,
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
        finally
        {
            control?.SetActivePid(0);
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
