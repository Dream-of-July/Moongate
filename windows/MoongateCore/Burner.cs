using System.Globalization;
using System.Text.Json;

namespace Moongate.Core;

/// <summary>
/// ffmpeg subtitles 滤镜硬烧录中文字幕：libx264 + CRF 恒定质量（体积不超源），
/// 可选 scale 缩放到 maxHeight（避开 4K60 的 H.264 编码上限、又快又小）。
/// </summary>
public sealed class FFmpegBurner : ISubtitleBurner
{
    /// <summary>Windows 平台中文字体名（官方 ffmpeg full 构建自带 libass，按系统字体名渲染）。</summary>
    public const string WindowsFontName = "Microsoft YaHei";

    internal static string[] CopyAudioArgs => ["-c:a", "copy"];

    internal static string[] AacAudioArgs => ["-c:a", "aac", "-b:a", "192k"];

    /// <summary>
    /// MP4 面向 Windows 自带播放器时优先 AAC。Opus 虽可被 ffmpeg mux 进 MP4，
    /// 但 Windows 媒体播放器会提示不支持 Opus 音频。
    /// </summary>
    internal static IReadOnlyList<IReadOnlyList<string>> Mp4CompatibleAudioEncodingChain() =>
        [AacAudioArgs, CopyAudioArgs];

    /// <summary>平台中文字体：Windows 微软雅黑；非 Windows（开发机）退回苹方。</summary>
    internal static string ChineseFontName => OperatingSystem.IsWindows() ? WindowsFontName : "PingFang SC";

    private static string? Locate(string name)
    {
        if (name == "ffmpeg"
            && Environment.GetEnvironmentVariable("MOONGATE_BURN_FFMPEG_PATH") is { Length: > 0 } custom
            && File.Exists(custom))
        {
            return custom;
        }
        return BinaryLocator.Locate(name);
    }

    /// <summary>转码用：定位 ffmpeg 可执行文件，找不到返回 null。</summary>
    internal static string? LocateFfmpeg() => Locate("ffmpeg");

    /// <summary>探测某个编码器是否可用（`ffmpeg -encoders` 含该名）。结果按 ffmpeg 路径缓存。与 macOS encoderAvailable 同构。</summary>
    private static readonly object EncoderCacheLock = new();
    private static readonly Dictionary<string, HashSet<string>> EncoderCache = [];

    internal static bool EncoderAvailable(string encoder, string ffmpeg)
    {
        lock (EncoderCacheLock)
        {
            if (EncoderCache.TryGetValue(ffmpeg, out var cached)) return cached.Contains(encoder);
        }
        var found = ProbeEncoders(ffmpeg);
        lock (EncoderCacheLock) { EncoderCache[ffmpeg] = found; }
        return found.Contains(encoder);
    }

    /// <summary>解析 `ffmpeg -encoders` 输出，提取已知关注的编码器集合。失败返回空集（按「不可用」处理，触发回退）。</summary>
    internal static HashSet<string> ProbeEncoders(string ffmpeg)
    {
        var found = new HashSet<string>();
        try
        {
            using var process = new System.Diagnostics.Process
            {
                StartInfo = new System.Diagnostics.ProcessStartInfo
                {
                    FileName = ffmpeg,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    UseShellExecute = false,
                    CreateNoWindow = true,
                },
            };
            process.StartInfo.ArgumentList.Add("-hide_banner");
            process.StartInfo.ArgumentList.Add("-encoders");
            if (!process.Start()) return found;
            var text = process.StandardOutput.ReadToEnd() + process.StandardError.ReadToEnd();
            process.WaitForExit();
            foreach (var token in new[]
            {
                "libx265", "libx264", "libsvtav1",
                "hevc_nvenc", "h264_nvenc",   // NVIDIA
                "hevc_qsv", "h264_qsv",       // Intel Quick Sync
                "hevc_amf", "h264_amf",       // AMD
            })
            {
                if (text.Contains(token)) found.Add(token);
            }
        }
        catch
        {
            // 探测失败：返回空集，调用方按「x265 不可用」回退 tonemap。
        }
        return found;
    }

    /// <summary>转码用：探测时长（秒），用于进度换算。</summary>
    internal static async Task<double?> ProbeDurationSecondsAsync(string video, CancellationToken ct = default) =>
        (await ProbeAsync(video, ct).ConfigureAwait(false)).Duration;

    /// <summary>转码用：探测下载产物的实际动态范围。null 表示 ffprobe 无法判断。</summary>
    internal static async Task<bool?> ProbeVideoIsHdrAsync(string video, CancellationToken ct = default)
    {
        var probe = await ProbeAsync(video, ct).ConfigureAwait(false);
        if (probe.CodecName is null && probe.Width is null && probe.Height is null && probe.ColorTransfer is null)
        {
            return null;
        }
        return probe.IsHdr;
    }

    /// <summary>转码用：探测实际视频编码短名（h264/h265/vp9/av1…），让「已是目标编码」时走 remux。</summary>
    internal static async Task<string?> ProbeVideoCodecAsync(string video, CancellationToken ct = default)
    {
        var raw = ((await ProbeAsync(video, ct).ConfigureAwait(false)).CodecName ?? "").ToLowerInvariant();
        return raw switch
        {
            "hevc" or "h265" => "h265",
            "avc" or "avc1" or "h264" => "h264",
            "" => null,
            _ => raw,
        };
    }

    /// <summary>
    /// HDR 保真烧录的视频编码参数：libx265 10-bit + HDR10 色彩元数据透传。与 macOS hdrVideoArgs 同构。
    /// 字幕仍是 SDR 白字，叠在 BT.2020/PQ 画面上由 subtitles 滤镜处理。maxrateK 控制码率上限。
    /// </summary>
    internal static string[] HdrVideoArgs(string? colorPrimaries, string? colorTransfer, string? colorSpace, int? maxrateK)
    {
        var prim = string.IsNullOrEmpty(colorPrimaries) ? "bt2020" : colorPrimaries;
        var trc = string.IsNullOrEmpty(colorTransfer) ? "smpte2084" : colorTransfer;
        var mtx = string.IsNullOrEmpty(colorSpace) ? "bt2020nc" : colorSpace;
        var x265Params = string.Join(":",
            "hdr-opt=1", "repeat-headers=1", $"colorprim={prim}", $"transfer={trc}", $"colormatrix={mtx}");
        return
        [
            "-c:v", "libx265", "-crf", "20", "-preset", "medium",
            "-pix_fmt", "yuv420p10le",
            "-x265-params", x265Params,
            "-tag:v", "hvc1",
            .. MaxrateFlags(maxrateK),
        ];
    }

    // MARK: - 编码器选择（硬件 NVENC/QSV/AMF ↔ 软件 libx265/libx264 × 源编码 × HDR）

    /// <summary>
    /// 一次编码所需的全部参数：编码器/像素格式（EncoderArgs）、字幕滤镜前后缀
    /// （FilterPrefix/Suffix，用于 HDR 10-bit 转换或 tonemap→SDR）、以及色彩元数据参数（ColorArgs，
    /// 硬件路径需显式带上才能写出正确 HDR10 元数据）。
    /// </summary>
    internal sealed record VideoEncoderSelection(
        IReadOnlyList<string> EncoderArgs, string FilterPrefix, string FilterSuffix, IReadOnlyList<string> ColorArgs);

    /// <summary>硬件编码质量参数（NVENC/QSV/AMF 各自的「恒定质量」近似）。选高画质档（视觉接近无损）。</summary>
    private const int HwCq = 22; // NVENC -cq / QSV -global_quality / AMF -qp_p（越小画质越好）

    /// <summary>HDR10 色彩元数据参数（硬件路径需显式带上，否则输出 trc/prim 为 unknown）。缺源信息回退 BT.2020/PQ/BT.2020nc。</summary>
    internal static string[] HdrColorArgs(string? colorPrimaries, string? colorTransfer, string? colorSpace)
    {
        var prim = string.IsNullOrEmpty(colorPrimaries) ? "bt2020" : colorPrimaries;
        var trc = string.IsNullOrEmpty(colorTransfer) ? "smpte2084" : colorTransfer;
        var mtx = string.IsNullOrEmpty(colorSpace) ? "bt2020nc" : colorSpace;
        return ["-color_primaries", prim, "-color_trc", trc, "-colorspace", mtx];
    }

    /// <summary>软件 SDR H.264：libx264 + CRF；maxrateK 非 null 时封顶。</summary>
    internal static string[] SdrH264VideoArgs(int? maxrateK) =>
        ["-c:v", "libx264", "-crf", "20", "-preset", "medium", "-pix_fmt", "yuv420p", .. MaxrateFlags(maxrateK)];

    /// <summary>软件 SDR HEVC（保 HEVC，8-bit）：libx265 + CRF；maxrateK 非 null 时封顶。</summary>
    internal static string[] SdrHevcVideoArgs(int? maxrateK) =>
        ["-c:v", "libx265", "-crf", "20", "-preset", "medium", "-pix_fmt", "yuv420p", "-tag:v", "hvc1", .. MaxrateFlags(maxrateK)];

    /// <summary>首选可用的硬件 H.264 编码器名（NVENC→QSV→AMF），都不可用返回 null。</summary>
    internal static string? HardwareH264Encoder(Func<string, bool> available)
    {
        foreach (var enc in new[] { "h264_nvenc", "h264_qsv", "h264_amf" })
            if (available(enc)) return enc;
        return null;
    }

    /// <summary>首选可用的硬件 HEVC 编码器名（NVENC→QSV→AMF），都不可用返回 null。</summary>
    internal static string? HardwareHevcEncoder(Func<string, bool> available)
    {
        foreach (var enc in new[] { "hevc_nvenc", "hevc_qsv", "hevc_amf" })
            if (available(enc)) return enc;
        return null;
    }

    /// <summary>硬件 H.264 编码参数（按编码器选合适的质量旋钮；有封顶时使用目标码率）。</summary>
    internal static string[] HwH264VideoArgs(string encoder, int? maxrateK = null) =>
        [.. HwEncoderArgs(encoder, maxrateK), "-pix_fmt", "yuv420p"];

    /// <summary>硬件 HEVC（SDR）编码参数。</summary>
    internal static string[] HwHevcVideoArgs(string encoder, int? maxrateK = null) =>
        [.. HwEncoderArgs(encoder, maxrateK), "-pix_fmt", "yuv420p", "-tag:v", "hvc1"];

    /// <summary>硬件 HEVC main10（HDR）编码参数：10-bit p010le，色彩元数据由 ColorArgs 单独透传。</summary>
    internal static string[] HwHdrVideoArgs(string encoder, int? maxrateK = null) =>
        [.. HwEncoderArgs(encoder, maxrateK), "-profile:v", "main10", "-pix_fmt", "p010le", "-tag:v", "hvc1"];

    /// <summary>各硬件编码器的「恒定质量」旋钮（参数名不同：NVENC -cq、QSV -global_quality、AMF -rc cqp -qp_*）。</summary>
    private static string[] HwEncoderArgs(string encoder, int? maxrateK)
    {
        if (maxrateK is { } cap)
        {
            string[] capArgs = ["-b:v", $"{cap}k", .. MaxrateFlags(cap)];
            if (encoder.Contains("nvenc"))
            {
                return ["-c:v", encoder, "-rc", "vbr", "-cq", $"{HwCq}", .. capArgs];
            }
            if (encoder.Contains("qsv"))
            {
                return ["-c:v", encoder, "-global_quality", $"{HwCq}", .. capArgs];
            }
            // AMF 的 cqp 模式不接受码率封顶；有封顶时改用目标码率。
            return ["-c:v", encoder, .. capArgs];
        }
        if (encoder.Contains("nvenc"))
            return ["-c:v", encoder, "-rc", "vbr", "-cq", $"{HwCq}", "-b:v", "0"];
        if (encoder.Contains("qsv"))
            return ["-c:v", encoder, "-global_quality", $"{HwCq}"];
        // amf
        return ["-c:v", encoder, "-rc", "cqp", "-qp_i", $"{HwCq}", "-qp_p", $"{HwCq}"];
    }

    /// <summary>
    /// 选择视频编码参数。纯函数，便于单测覆盖整个矩阵。available 注入编码器可用性（便于测试与缓存）。
    /// 决策顺序：HDR → 强制 H.264（路线 A）→ 跟随源（HEVC 保 HEVC，否则 H.264）。
    /// 每一类再按 backend + 硬件可用性在 硬件编码器 / libx 间选择。
    /// </summary>
    internal static VideoEncoderSelection SelectVideoEncoder(
        EncodeBackend backend, bool alwaysH264, bool sourceIsHevc, bool isHdr,
        string? colorPrimaries, string? colorTransfer, string? colorSpace,
        int? maxrateK, bool x265Available, Func<string, bool> available)
    {
        var wantHardware = backend.PrefersHardware();
        var hwHevc = wantHardware ? HardwareHevcEncoder(available) : null;
        var hwH264 = wantHardware ? HardwareH264Encoder(available) : null;

        // 1) HDR：保 HDR 时输出 HEVC 10-bit；强制 H.264 时只能 tonemap→SDR。
        if (isHdr && !alwaysH264)
        {
            if (hwHevc is { } enc)
            {
                return new VideoEncoderSelection(HwHdrVideoArgs(enc, maxrateK), "", ",format=p010le",
                    HdrColorArgs(colorPrimaries, colorTransfer, colorSpace));
            }
            if (x265Available)
            {
                return new VideoEncoderSelection(
                    HdrVideoArgs(colorPrimaries, colorTransfer, colorSpace, maxrateK), "", ",format=yuv420p10le", []);
            }
            return TonemappedSdrSelection(hwH264, maxrateK);
        }

        // 2) HDR 源但强制 H.264：先 tonemap 成 SDR 再编码。
        if (isHdr && alwaysH264)
        {
            return TonemappedSdrSelection(hwH264, maxrateK);
        }

        // 3) SDR：跟随源（HEVC 保 HEVC）或强制 H.264。
        if (sourceIsHevc && !alwaysH264)
        {
            if (hwHevc is { } enc) return new VideoEncoderSelection(HwHevcVideoArgs(enc, maxrateK), "", "", []);
            if (x265Available) return new VideoEncoderSelection(SdrHevcVideoArgs(maxrateK), "", "", []);
            // 无任何 HEVC 编码器：退回 H.264。
        }
        if (hwH264 is { } h264) return new VideoEncoderSelection(HwH264VideoArgs(h264, maxrateK), "", "", []);
        return new VideoEncoderSelection(SdrH264VideoArgs(maxrateK), "", "", []);
    }

    private static VideoEncoderSelection TonemappedSdrSelection(string? hwH264, int? maxrateK)
    {
        const string prefix = "zscale=t=linear:npl=100,tonemap=hable,zscale=t=bt709:m=bt709:r=tv,format=yuv420p,";
        var encoder = hwH264 is { } enc ? HwH264VideoArgs(enc, maxrateK) : SdrH264VideoArgs(maxrateK);
        return new VideoEncoderSelection(encoder, prefix, "", []);
    }

    /// <summary>
    /// 选择编码候选链：主选 + 同编码的软件回退。保证「用户/源决定的编码」最终一定能产出——
    /// 硬件编码器对个别输入会失败，此时回退到软件 libx265/libx264（仍是同一种编码，只换后端，绝不降级）。
    /// 主选已是软件、或硬件与软件选择一致（硬件不可用时主选已落到软件）时只返回一个候选。
    /// </summary>
    internal static IReadOnlyList<VideoEncoderSelection> SelectVideoEncoderChain(
        EncodeBackend backend, bool alwaysH264, bool sourceIsHevc, bool isHdr,
        string? colorPrimaries, string? colorTransfer, string? colorSpace,
        int? maxrateK, bool x265Available, Func<string, bool> available)
    {
        var primary = SelectVideoEncoder(backend, alwaysH264, sourceIsHevc, isHdr,
            colorPrimaries, colorTransfer, colorSpace, maxrateK, x265Available, available);
        if (!backend.PrefersHardware()) return [primary];
        var softwareFallback = SelectVideoEncoder(EncodeBackend.Software, alwaysH264, sourceIsHevc, isHdr,
            colorPrimaries, colorTransfer, colorSpace, maxrateK, x265Available, available);
        return softwareFallback.EncoderArgs.SequenceEqual(primary.EncoderArgs)
            ? [primary]
            : [primary, softwareFallback];
    }

    public async Task<string> BurnAsync(
        string video,
        string subtitle,
        int? maxHeight,
        TaskControlToken? control,
        Action<double> progress,
        EncodeBackend backend = EncodeBackend.Auto,
        bool alwaysH264 = false,
        string? outputTag = null,
        CancellationToken ct = default)
    {
        var ffmpeg = Locate("ffmpeg") ?? throw MoongateException.BinaryNotFound("ffmpeg");
        if (control?.IsCancelled == true) throw MoongateException.Cancelled();

        // 1. ffprobe 取时长、整体码率与源尺寸（取不到不阻塞烧录，只影响进度与缩放/码率）
        var probe = await ProbeAsync(video, ct).ConfigureAwait(false);

        // 「最大 1080p」语义按短边算：横屏限高、竖屏限宽。
        // 旧规则只看高度，竖屏 1080×1920 会被压成 608×1080（短边掉到 608）。
        var isPortrait = probe is { Width: { } pw, Height: { } ph } && pw < ph;
        var sourceShortSide = ShortSide(probe.Width, probe.Height);
        // 缩放目标：maxHeight 非空且源短边更大时把短边缩到 maxHeight，否则保持源。
        int? targetShortSide = maxHeight is { } mh && mh > 0 && sourceShortSide is { } shortSide && shortSide > mh
            ? mh
            : null;
        // -maxrate 上限：缩放时按目标短边封顶；不缩放时按源短边封顶。
        // 保持源分辨率仍保留 CRF/硬件质量兜底，但避免低码率源被字幕烧录重编码撑大太多。
        var capShortSide = targetShortSide ?? sourceShortSide;
        int? maxrateK = capShortSide is { } cap ? MaxrateK(probe.BitRateBps, sourceShortSide, cap) : null;

        // 2. 临时目录：字幕转成 subs.ass 并把 ffmpeg 工作目录设到这里，
        //    规避 subtitles 滤镜对路径里冒号/引号/中文的转义问题。
        //    用 ASS 而非 SRT 是为了双语两种字号：中文（首行）正常字号，原文（次行）更小。
        var tempDir = Path.Combine(Path.GetTempPath(), $"moongate-burn-{Guid.NewGuid():N}");
        // 缩放滤镜：-2 让另一边自动按比例取偶数，避免 H.264 要求偶数边长报错。
        // 横屏限高（scale=-2:H）、竖屏限宽（scale=W:-2）。
        var scaleFilter = ScaleFilter(isPortrait, targetShortSide);
        string filter;
        try
        {
            Directory.CreateDirectory(tempDir);
            var srtText = await File.ReadAllTextAsync(subtitle, ct).ConfigureAwait(false);
            var cues = SrtTools.ParseSrt(srtText);
            string subtitleFilter;
            if (cues.Count == 0)
            {
                // 解析不出来就按原样走 SRT + force_style 的老路
                File.Copy(subtitle, Path.Combine(tempDir, "subs.srt"));
                subtitleFilter = "subtitles=subs.srt:force_style="
                    + $"'FontName={ChineseFontName},FontSize=15,Outline=1,Shadow=0,MarginV=20'";
            }
            else
            {
                // 字幕坐标系/字号按视频长宽比自适应（缩放不改变比例，用源尺寸即可）
                var aspect = probe is { Width: { } w, Height: { } h } && w > 0 && h > 0
                    ? (double)w / h
                    : 16.0 / 9.0;
                var ass = MakeAss(cues, aspect);
                await File.WriteAllTextAsync(Path.Combine(tempDir, "subs.ass"), ass, ct).ConfigureAwait(false);
                subtitleFilter = "subtitles=subs.ass";
            }
            // 先缩放再烧字幕：字幕按目标分辨率渲染，清晰度与位置都正确。
            // 同一条 -vf filterchain 用逗号连接。
            filter = scaleFilter is not null ? scaleFilter + "," + subtitleFilter : subtitleFilter;
        }
        catch (MoongateException)
        {
            TryRemoveDirectory(tempDir);
            throw;
        }
        catch (OperationCanceledException)
        {
            TryRemoveDirectory(tempDir);
            throw;
        }
        catch (Exception e)
        {
            TryRemoveDirectory(tempDir);
            throw MoongateException.BurnFailed(L10n.T($"无法准备字幕临时文件：{e.Message}",
                $"無法準備字幕暫存檔：{e.Message}",
                $"Could not prepare subtitle temp files: {e.Message}"));
        }

        try
        {
            // 3. 编码器选择：按 后端 / 源编码 / HDR / 是否强制 H.264 决定用硬件还是软件、何种编码。
            var x265Available = EncoderAvailable("libx265", ffmpeg);
            bool Available(string enc) => EncoderAvailable(enc, ffmpeg);
            var sourceIsHevc = (probe.CodecName ?? "").ToLowerInvariant() is "hevc" or "h265";
            // 候选链：主选（按后端）+ 同编码的软件回退。硬件失败时退到软件同一种编码，绝不降级。
            var candidates = SelectVideoEncoderChain(
                backend, alwaysH264, sourceIsHevc, probe.IsHdr,
                probe.ColorPrimaries, probe.ColorTransfer, probe.ColorSpace,
                maxrateK, x265Available, Available);

            // 4. 跑 ffmpeg，stdout 的 -progress 输出换算进度。
            //    onStart 登记 pid 到 control：暂停时挂起 ffmpeg 进程树。
            var totalSeconds = probe.Duration;
            async Task<(int Status, string StderrTail)> Run(List<string> arguments)
            {
                try
                {
                    return await ProcessRunner.RunStreamingProcessAsync(
                        ffmpeg, arguments,
                        currentDirectory: tempDir,
                        // ffmpeg 的 -progress 每约 0.5s 必有输出；2 分钟静默 = 真挂死。
                        stallTimeout: TimeSpan.FromSeconds(120),
                        isSuspended: () => control?.IsPaused ?? false,
                        onStart: pid =>
                        {
                            if (control?.IsCancelled == true)
                            {
                                // 启动瞬间已取消：立即终止进程树。
                                ProcessTree.KillTree(pid);
                            }
                            else
                            {
                                control?.SetActivePid(pid);
                            }
                        },
                        onLine: line =>
                        {
                            if (ParseProgress(line, totalSeconds) is { } fraction) progress(fraction);
                        },
                        ct: ct).ConfigureAwait(false);
                }
                catch (ProcessStalledException)
                {
                    throw MoongateException.BurnFailed(L10n.T(
                        "烧录进程超过 2 分钟没有任何输出，疑似挂死，已自动中止（可重试）。",
                        "燒錄程序超過 2 分鐘沒有任何輸出，疑似卡住，已自動中止（可重試）。",
                        "The encoder produced no output for 2 minutes and was stopped (you can retry)."));
                }
                finally
                {
                    control?.SetActivePid(0);
                }
            }

            // 字幕滤镜缺失（libass）这类错误换编码器也修不好：命中即终止，不浪费后续重编码。
            static bool IsUnfixable(string tail)
            {
                var lower = tail.ToLowerInvariant();
                return lower.Contains("error parsing filterchain")
                    || lower.Contains("no such filter")
                    || lower.Contains("no such file");
            }

            // 依次尝试候选编码；MP4 优先 AAC 音轨，避免 Opus 复制进 MP4 后 Windows 自带播放器无声。
            // AAC 编码失败时再 copy 兜底；硬件失败 → 进入下一个候选（软件同编码）。
            var status = -1;
            var stderrTail = "";
            foreach (var selection in candidates)
            {
                var videoFilter = selection.FilterPrefix + filter + selection.FilterSuffix;
                var head = new List<string> { "-y", "-i", video, "-vf", videoFilter };
                List<string> Tail(IReadOnlyList<string> audio) =>
                    [.. audio, .. selection.ColorArgs, "-movflags", "+faststart", "-nostats", "-progress", "pipe:1", "out.mp4"];

                var advanceToNextCandidate = false;
                foreach (var audio in Mp4CompatibleAudioEncodingChain())
                {
                    try { File.Delete(Path.Combine(tempDir, "out.mp4")); } catch { /* 忽略 */ }
                    (status, stderrTail) = await Run([.. head, .. selection.EncoderArgs, .. Tail(audio)]).ConfigureAwait(false);
                    if (status == 0) break;
                    if (control?.IsCancelled == true) throw MoongateException.Cancelled();
                    if (IsUnfixable(stderrTail)) { advanceToNextCandidate = false; break; }
                    // AAC 编码器不可用时再尝试 copy 兜底（同候选）。
                    advanceToNextCandidate = true;
                }
                if (status == 0 || IsUnfixable(stderrTail)) break;
                _ = advanceToNextCandidate; // 本候选 copy/aac 都失败：进入下一候选（软件回退）。
            }

            if (status != 0)
            {
                // 取消归一化：onStart 在取消时杀了进程树，ffmpeg 以非 0 退出，
                // 这里识别为取消（抛 Cancelled）而不是 BurnFailed，避免误报「烧录失败」。
                if (control?.IsCancelled == true) throw MoongateException.Cancelled();
                var lower = stderrTail.ToLowerInvariant();
                if (lower.Contains("error parsing filterchain") || lower.Contains("no such filter"))
                {
                    throw MoongateException.BurnFailed(L10n.T(
                        "当前 ffmpeg 不带字幕渲染组件（libass）。请在「设置」里重新下载完整版 ffmpeg 后重试。",
                        "目前 ffmpeg 不帶字幕渲染元件（libass）。請在「設定」裡重新下載完整版 ffmpeg 後重試。",
                        "This ffmpeg build lacks the subtitle renderer (libass). Re-download ffmpeg in Settings and retry."));
                }
                throw MoongateException.BurnFailed(LastLine(stderrTail));
            }
            var produced = Path.Combine(tempDir, "out.mp4");
            if (!File.Exists(produced))
            {
                throw MoongateException.BurnFailed(L10n.T("ffmpeg 已退出，但没有生成输出文件。",
                    "ffmpeg 已退出，但沒有產生輸出檔案。",
                    "ffmpeg exited without producing an output file."));
            }
            progress(1);

            // 6. 移到视频同目录："<原名>（字幕版）.mp4"（标签可由 outputTag 定制），重名时加 " 2"、" 3"…
            var stem = Path.GetFileNameWithoutExtension(video);
            var directory = Path.GetDirectoryName(video) ?? ".";
            var tag = outputTag ?? L10n.T("（字幕版）", "（字幕版）", " (subtitled)");
            var destination = Path.Combine(directory, $"{stem}{tag}.mp4");
            var serial = 2;
            while (File.Exists(destination))
            {
                destination = Path.Combine(directory, $"{stem}{tag} {serial}.mp4");
                serial++;
            }
            try
            {
                File.Move(produced, destination);
            }
            catch (Exception e)
            {
                throw MoongateException.BurnFailed(L10n.T($"无法移动输出文件：{e.Message}",
                    $"無法移動輸出檔案：{e.Message}",
                    $"Could not move the output file: {e.Message}"));
            }
            return destination;
        }
        finally
        {
            TryRemoveDirectory(tempDir);
        }
    }

    private static void TryRemoveDirectory(string path)
    {
        try { Directory.Delete(path, recursive: true); } catch { /* 忽略 */ }
    }

    // MARK: ffprobe

    internal sealed record ProbeResult(
        double? Duration, double? BitRateBps, int? Width, int? Height,
        string? CodecName = null,
        string? ColorTransfer = null, string? ColorPrimaries = null, string? ColorSpace = null)
    {
        /// <summary>是否 HDR：传递函数为 PQ(smpte2084) 或 HLG(arib-std-b67)。</summary>
        public bool IsHdr
        {
            get
            {
                var t = (ColorTransfer ?? "").ToLowerInvariant();
                return t.Contains("smpte2084") || t.Contains("arib-std-b67") || t.Contains("pq") || t.Contains("hlg");
            }
        }
    }

    private static async Task<ProbeResult> ProbeAsync(string video, CancellationToken ct)
    {
        var ffprobe = Locate("ffprobe");
        if (ffprobe is null) return new ProbeResult(null, null, null, null);
        var lines = new List<string>();
        var linesLock = new object();
        int status;
        try
        {
            (status, _) = await ProcessRunner.RunStreamingProcessAsync(
                ffprobe,
                ["-v", "quiet", "-print_format", "json", "-show_format", "-show_streams", video],
                onLine: line => { lock (linesLock) lines.Add(line); },
                ct: ct).ConfigureAwait(false);
        }
        catch (MoongateException)
        {
            return new ProbeResult(null, null, null, null);
        }
        if (status != 0) return new ProbeResult(null, null, null, null);
        string text;
        lock (linesLock) text = string.Join("\n", lines);
        try
        {
            using var doc = JsonDocument.Parse(text);
            var root = doc.RootElement;
            double? duration = null, bitRate = null;
            int? width = null, height = null;
            string? codecName = null, colorTransfer = null, colorPrimaries = null, colorSpace = null;
            if (root.TryGetProperty("format", out var format) && format.ValueKind == JsonValueKind.Object)
            {
                duration = YtDlpEngine.DoubleField(format, "duration");
                bitRate = YtDlpEngine.DoubleField(format, "bit_rate");
            }
            if (root.TryGetProperty("streams", out var streams) && streams.ValueKind == JsonValueKind.Array)
            {
                foreach (var stream in streams.EnumerateArray())
                {
                    if (YtDlpEngine.StringField(stream, "codec_type") != "video") continue;
                    width = YtDlpEngine.IntField(stream, "width");
                    height = YtDlpEngine.IntField(stream, "height");
                    codecName = YtDlpEngine.StringField(stream, "codec_name");
                    colorTransfer = YtDlpEngine.StringField(stream, "color_transfer");
                    colorPrimaries = YtDlpEngine.StringField(stream, "color_primaries");
                    colorSpace = YtDlpEngine.StringField(stream, "color_space");
                    bitRate ??= YtDlpEngine.DoubleField(stream, "bit_rate");
                    break;
                }
            }
            return new ProbeResult(duration, bitRate, width, height, codecName, colorTransfer, colorPrimaries, colorSpace);
        }
        catch (JsonException)
        {
            return new ProbeResult(null, null, null, null);
        }
    }

    // MARK: 进度与参数

    /// <summary>源短边：缩放上限与码率档位都按短边算（竖屏 1080×1920 视作 1080p）。</summary>
    internal static int? ShortSide(int? width, int? height) =>
        height is { } h ? (width is { } w ? Math.Min(w, h) : h) : width;

    /// <summary>缩放滤镜：横屏限高（scale=-2:H）、竖屏限宽（scale=W:-2）；目标为空不缩放。</summary>
    internal static string? ScaleFilter(bool isPortrait, int? targetShortSide) =>
        targetShortSide is { } th ? (isPortrait ? $"scale={th}:-2" : $"scale=-2:{th}") : null;

    /// <summary>
    /// 计算烧录场景的 -maxrate k 值（CRF/质量编码下仅作封顶）：
    /// 按目标分辨率档位封顶，并与源码率×1.5 取 min（源更小时不浪费）。
    /// 档位上限：2160p≈16000，1440p≈10000，1080p≈6000，720p≈3000，480p≈1500。
    /// </summary>
    internal static int MaxrateK(double? sourceBitRateBps, int? sourceHeight, int targetHeight)
    {
        int? sourceK = sourceBitRateBps is { } bps && bps > 0 ? (int)(bps / 1000 * 1.5) : null;
        var tier = BitrateForHeight(targetHeight);
        return Math.Min(tier, sourceK ?? tier);
    }

    /// <summary>-maxrate/-bufsize 参数：maxrateK 非 null 时封顶；null 时为空（纯 CRF/恒定质量）。</summary>
    internal static string[] MaxrateFlags(int? maxrateK) =>
        maxrateK is { } k ? ["-maxrate", $"{k}k", "-bufsize", $"{k * 2}k"] : [];

    internal static int BitrateForHeight(int height) => height switch
    {
        >= 1801 => 16000,          // 4K (2160p) 及以上
        >= 1201 and <= 1800 => 10000, // 1440p
        >= 901 and <= 1200 => 6000,   // 1080p
        >= 601 and <= 900 => 3000,    // 720p
        _ => 1500,                    // 480p 及以下
    };

    /// <summary>解析 -progress pipe:1 输出。out_time_ms 与 out_time_us 的值都是微秒。</summary>
    internal static double? ParseProgress(string line, double? totalSeconds)
    {
        if (totalSeconds is not { } total || total <= 0) return null;
        foreach (var prefix in new[] { "out_time_ms=", "out_time_us=" })
        {
            if (!line.StartsWith(prefix, StringComparison.Ordinal)) continue;
            var value = line[prefix.Length..].Trim();
            if (!double.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out var microseconds))
            {
                return null;
            }
            return Math.Min(Math.Max(microseconds / 1_000_000 / total, 0), 1);
        }
        return null;
    }

    internal static string LastLine(string stderr)
    {
        var lines = stderr.Split('\n', '\r')
            .Select(l => l.Trim())
            .Where(l => l.Length > 0)
            .ToList();
        var last = lines.Count > 0 ? lines[^1] : L10n.T("未知错误", "未知錯誤", "Unknown error");
        return last.Length > 200 ? last[..200] : last;
    }

    // MARK: ASS 生成（双语两级字号，按视频长宽比自适应）

    private const int ChineseFontSize = 15;
    /// <summary>原文字号相对译文字号的比例（不分语言，永远 80%）。</summary>
    private const double OriginalSizeRatio = 0.8;
    /// <summary>原文不透明度（80%）对应的 ASS alpha 十六进制（00=不透明，FF=全透明）。round((1-0.8)*255)=51=0x33。</summary>
    internal const string OriginalAlphaHex = "33";

    /// <summary>
    /// 按视频长宽比推导的 ASS 布局参数。
    /// 字号按「高度的固定比例」调校（横屏 16:9 下译文 15/288≈5.2% 视频高，原文为其 80%）。
    /// 换行采用自动布局：左右只留最小边距（约画面 4%），只有真的放不下才换行。
    /// </summary>
    internal readonly struct AssLayout
    {
        public int PlayResX { get; }
        public int PlayResY => 288;
        public int ChineseSize { get; }
        public int OriginalSize { get; }
        public int MarginH { get; }
        public int MarginV => 20;
        /// <summary>中文行预换行容量（字符数）；null 表示不预换行（交给 libass）。</summary>
        public int? CjkWrapCapacity { get; }
        /// <summary>原文若为 CJK 文字（日/韩）的按字预换行容量（按更小的 OriginalSize 算）；null 表示不预换行。</summary>
        public int? OriginalCjkWrapCapacity { get; }
        /// <summary>原文（拉丁文字）行按词预换行容量（字符数）；null 表示不预换行。</summary>
        public int? LatinWrapCapacity { get; }

        public AssLayout(double aspect)
        {
            var safeAspect = double.IsFinite(aspect) && aspect > 0.1 ? Math.Min(aspect, 4.0) : 16.0 / 9.0;
            // 脚本坐标系与视频同比例（取偶数），横向边距/字号的单位才不会被拉伸
            PlayResX = Math.Max(120, (int)Math.Round(288.0 * safeAspect / 2, MidpointRounding.AwayFromZero) * 2);
            ChineseSize = safeAspect >= 1
                ? ChineseFontSize
                : Math.Max(8, (int)Math.Round(ChineseFontSize * Math.Sqrt(safeAspect / (16.0 / 9.0)), MidpointRounding.AwayFromZero));
            // 原文字号永远是译文的 80%（不分语言）。
            OriginalSize = Math.Max(6, (int)Math.Round(ChineseSize * OriginalSizeRatio, MidpointRounding.AwayFromZero));
            // 自动布局：左右只留一个最小边距（约画面 4%），只有真放不下才换行。
            MarginH = Math.Max(5, (int)Math.Round(PlayResX * 0.04, MidpointRounding.AwayFromZero));
            var usableWidth = (double)(PlayResX - MarginH * 2);
            var cjkCapacity = (int)(usableWidth / Math.Max(ChineseSize, 1));
            CjkWrapCapacity = cjkCapacity >= 6 ? cjkCapacity : null;
            var originalCjk = (int)(usableWidth / Math.Max(OriginalSize, 1));
            OriginalCjkWrapCapacity = originalCjk >= 6 ? originalCjk : null;
            // 原文（拉丁）按词换行容量：拉丁字形平均宽约为字号的 0.55em（含大写/空格的保守上界）。
            var latinCapacity = (int)(usableWidth / (OriginalSize * 0.55));
            LatinWrapCapacity = latinCapacity >= 12 ? latinCapacity : null;
        }
    }

    /// <summary>
    /// 把 SRT 字幕转成 ASS：双语条目（含中日韩文字的行 + 不含的行）中日韩行用正常字号排上面，
    /// 其余行（原文）用更小字号排下面；普通条目整条统一字号。
    /// aspect = 视频宽/高；fontName 供测试注入，null 用平台默认。
    /// </summary>
    internal static string MakeAss(IReadOnlyList<SubtitleCue> cues, double aspect = 16.0 / 9.0, string? fontName = null)
    {
        var font = fontName ?? ChineseFontName;
        var layout = new AssLayout(aspect);
        var dialogues = new List<string>();
        foreach (var cue in cues)
        {
            var start = AssTimestamp(cue.Start);
            var end = AssTimestamp(cue.End);
            if (start is null || end is null) continue;
            var lines = cue.Text.Split('\n')
                .Select(EscapeAssText)
                .Where(l => l.Length > 0)
                .ToList();
            if (lines.Count == 0) continue;

            // 双语条目：简体中文译文排上面（正常字号），原文排下面（80% 字号 + 80% 不透明度）。
            // 判据是「简体中文」而非「含 CJK」：日文（假名）、韩文（谚文）也含 CJK 区字符，
            // 若按含 CJK 归类会把日韩原文误判成译文、用满字号且不缩小。简体中文 = 含汉字且不含假名/谚文。
            string text;
            var zhLines = new List<string>();
            foreach (var zh in lines.Where(IsSimplifiedChineseLine))
            {
                if (layout.CjkWrapCapacity is { } capacity) zhLines.AddRange(WrapCjkLine(zh, capacity));
                else zhLines.Add(zh);
            }
            // 原文行（非简体中文）：可能是拉丁文字（按词折行）或 CJK 文字（日韩，按字折行）。
            var rawOtherLines = lines.Where(l => !IsSimplifiedChineseLine(l)).ToList();
            var otherLines = WrapOriginalLines(rawOtherLines, layout);
            if (zhLines.Count > 0 && otherLines.Count > 0)
            {
                // 原文整体（字+描边）淡到 80% 不透明：\alpha 同时作用于 Primary/Outline/Back。
                text = string.Join("\\N", zhLines)
                    + $"\\N{{\\fs{layout.OriginalSize}\\alpha&H{OriginalAlphaHex}&}}"
                    + string.Join("\\N", otherLines);
            }
            else if (zhLines.Count > 0)
            {
                text = string.Join("\\N", zhLines);
            }
            else
            {
                // 纯原文（无中文译文）条目：用原文字号显示（仍折行，避免溢出/乱断）。
                text = $"{{\\fs{layout.OriginalSize}}}" + string.Join("\\N", otherLines);
            }
            dialogues.Add($"Dialogue: 0,{start},{end},ZH,,0,0,0,,{text}");
        }

        var header = $"""
            [Script Info]
            ScriptType: v4.00+
            PlayResX: {layout.PlayResX}
            PlayResY: {layout.PlayResY}
            WrapStyle: 2
            ScaledBorderAndShadow: yes

            [V4+ Styles]
            Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
            Style: ZH,{font},{layout.ChineseSize},&H00FFFFFF,&H00FFFFFF,&H00000000,&H7F000000,0,0,0,0,100,100,0,0,1,1,0,2,{layout.MarginH},{layout.MarginH},{layout.MarginV},1

            [Events]
            Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
            """;
        return header + "\n" + string.Join("\n", dialogues) + "\n";
    }

    /// <summary>
    /// 原文（拉丁文字）按词折行：超过容量才折，按空格断词（绝不切进单词中间），
    /// 行数取最少、并均衡各行长度，避免末行只剩一两个词的难看断行。
    /// </summary>
    internal static List<string> WrapLatinLine(string line, int capacity)
    {
        var words = line.Split(new[] { ' ', '\n', '\t' }, StringSplitOptions.RemoveEmptyEntries);
        if (capacity < 12 || words.Length == 0) return [line];
        var fullText = string.Join(" ", words);
        if (fullText.Length <= capacity) return [fullText];
        // 目标行数：按容量向上取整；均衡目标行宽，行宽上限仍是 capacity。
        var lineCount = Math.Max(1, (int)Math.Ceiling((double)fullText.Length / capacity));
        var target = Math.Min(capacity, (int)Math.Ceiling((double)fullText.Length / lineCount));
        var result = new List<string>();
        var current = "";
        foreach (var word in words)
        {
            if (current.Length == 0)
            {
                current = word;
                continue;
            }
            var candidate = current + " " + word;
            // 已达到均衡目标且仍有余下单词时换行；硬上限为 capacity（单词本身超长则独占一行）。
            if (candidate.Length > capacity || (candidate.Length > target && result.Count < lineCount - 1))
            {
                result.Add(current);
                current = word;
            }
            else
            {
                current = candidate;
            }
        }
        if (current.Length > 0) result.Add(current);
        return result.Count == 0 ? [fullText] : result;
    }

    /// <summary>
    /// 超过容量的中文行均衡预换行：行数取最少、各行长度尽量接近；
    /// 切点优先标点之后 &gt; 空格处 &gt; 任意中日韩字界（绝不切进英文单词/数字中间）。
    /// </summary>
    internal static List<string> WrapCjkLine(string line, int capacity)
    {
        var chars = line.ToCharArray();
        if (capacity < 6 || chars.Length <= capacity) return [line];
        var lineCount = (int)Math.Ceiling((double)chars.Length / capacity);
        var target = (int)Math.Ceiling((double)chars.Length / lineCount);
        var result = new List<string>();
        var start = 0;
        while (chars.Length - start > capacity)
        {
            var idealEnd = Math.Min(start + target, chars.Length - 1);
            // 在理想切点前后各 6 个字符内找切点（切点 = 新行的起点下标），
            // 上限不超过容量保证本行装得下；同级里取离理想点最近的。
            var low = Math.Max(start + 1, idealEnd - 6);
            var high = Math.Min(start + capacity, Math.Min(idealEnd + 6, chars.Length - 1));
            int? bestPunct = null, bestSpace = null, bestCjkBoundary = null;
            int Better(int? current, int candidate) =>
                current is { } cur && Math.Abs(candidate - idealEnd) >= Math.Abs(cur - idealEnd)
                    ? cur
                    : candidate;
            for (var i = low; i <= high; i++)
            {
                var prev = chars[i - 1];
                if (CjkBreakAfter.Contains(prev)) bestPunct = Better(bestPunct, i);
                else if (prev == ' ' || chars[i] == ' ') bestSpace = Better(bestSpace, i);
                else if (IsCjkChar(prev) || IsCjkChar(chars[i])) bestCjkBoundary = Better(bestCjkBoundary, i);
            }
            var cut = bestPunct ?? bestSpace ?? bestCjkBoundary ?? idealEnd;
            var piece = new string(chars, start, cut - start).Trim();
            if (piece.Length > 0) result.Add(piece);
            start = cut;
            // 跳过切点处的空格，避免新行以空格开头
            while (start < chars.Length && chars[start] == ' ') start++;
        }
        var last = new string(chars, start, chars.Length - start).Trim();
        if (last.Length > 0) result.Add(last);
        return result.Count == 0 ? [line] : result;
    }

    /// <summary>切行时允许出现在行尾的标点（其后断行不破坏语感）。</summary>
    private static readonly HashSet<char> CjkBreakAfter =
        ['，', '。', '！', '？', '、', '；', '：', '…', ',', '.', '!', '?', ';', ':'];

    /// <summary>"00:01:02,500" → "0:01:02.50"（ASS 用厘秒）。</summary>
    internal static string? AssTimestamp(string srt)
    {
        var normalized = srt.Replace(',', '.');
        var parts = normalized.Split(':');
        if (parts.Length != 3) return null;
        if (!int.TryParse(parts[0], NumberStyles.Integer, CultureInfo.InvariantCulture, out var h)) return null;
        if (!int.TryParse(parts[1], NumberStyles.Integer, CultureInfo.InvariantCulture, out var m)) return null;
        var secParts = parts[2].Split('.');
        if (!int.TryParse(secParts[0], NumberStyles.Integer, CultureInfo.InvariantCulture, out var s)) return null;
        if (s >= 60 || m >= 60) return null;
        var msString = secParts.Length > 1 ? secParts[1] : "0";
        msString = msString.Length > 3 ? msString[..3] : msString.PadRight(3, '0');
        var ms = int.TryParse(msString, NumberStyles.Integer, CultureInfo.InvariantCulture, out var parsedMs) ? parsedMs : 0;
        return $"{h}:{m:00}:{s:00}.{ms / 10:00}";
    }

    internal static bool ContainsCjk(string text) =>
        text.EnumerateRunes().Any(rune =>
            rune.Value is >= 0x4E00 and <= 0x9FFF        // CJK 统一表意
                or >= 0x3400 and <= 0x4DBF               // 扩展 A
                or >= 0x3040 and <= 0x30FF               // 日文假名
                or >= 0xAC00 and <= 0xD7AF);             // 谚文

    /// <summary>日文假名（平假名/片假名）。</summary>
    private static bool HasKana(string text) =>
        text.EnumerateRunes().Any(r => r.Value is >= 0x3040 and <= 0x30FF);

    /// <summary>朝鲜文谚文音节/字母。</summary>
    private static bool HasHangul(string text) =>
        text.EnumerateRunes().Any(r => r.Value is (>= 0xAC00 and <= 0xD7AF) or (>= 0x1100 and <= 0x11FF));

    /// <summary>汉字（CJK 统一表意，含扩展 A）。</summary>
    private static bool HasHan(string text) =>
        text.EnumerateRunes().Any(r => r.Value is (>= 0x4E00 and <= 0x9FFF) or (>= 0x3400 and <= 0x4DBF));

    /// <summary>
    /// 是否「简体中文译文行」：含汉字且不含假名/谚文。译文恒为简体中文（含汉字、无假名/谚文）；
    /// 日文必含假名、韩文必含谚文，据此与原文区分，避免日韩原文（也落在 CJK 区）被误判成译文。
    /// </summary>
    internal static bool IsSimplifiedChineseLine(string text) =>
        HasHan(text) && !HasKana(text) && !HasHangul(text);

    /// <summary>
    /// 折行原文（非简体中文）：CJK 文字（日/韩）按字折行，拉丁文字按词折行。
    /// 先把源 SRT 的碎行合并，再按对应容量重排；无可用容量时原样返回（交给 libass）。
    /// </summary>
    internal static List<string> WrapOriginalLines(IReadOnlyList<string> rawLines, AssLayout layout)
    {
        if (rawLines.Count == 0) return [];
        var isCjkText = rawLines.Any(l => HasKana(l) || HasHangul(l) || HasHan(l));
        if (isCjkText)
        {
            // 日韩等无空格 CJK 原文：合并后按字折行（容量按更小的原文字号算）。
            var joined = string.Concat(rawLines);
            return layout.OriginalCjkWrapCapacity is { } capacity
                ? WrapCjkLine(joined, capacity)
                : [joined];
        }
        // 拉丁原文：合并后按词折行。
        var joinedLatin = string.Join(" ", rawLines);
        return layout.LatinWrapCapacity is { } latinCapacity
            ? WrapLatinLine(joinedLatin, latinCapacity)
            : [joinedLatin];
    }

    /// <summary>切行用的单字符判定；四个区段都在 BMP，按 char 比较即可（与 ContainsCjk 同区段）。</summary>
    private static bool IsCjkChar(char c) =>
        (int)c is >= 0x4E00 and <= 0x9FFF        // CJK 统一表意
            or >= 0x3400 and <= 0x4DBF           // 扩展 A
            or >= 0x3040 and <= 0x30FF           // 日文假名
            or >= 0xAC00 and <= 0xD7AF;          // 谚文

    /// <summary>ASS 文本里 {} 是样式覆盖块定界符，替换为全角避免被解析。</summary>
    internal static string EscapeAssText(string line) =>
        line.Trim()
            .Replace("{", "｛")
            .Replace("}", "｝")
            .Replace("\\", "＼");
}
