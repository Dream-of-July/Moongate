import Foundation

// MARK: - 下载后转码 / remux

/// 把下载好的文件转成用户选择的输出格式。
/// - 同编码换容器（如 vp9 webm → mkv）：remux，`-c copy`，秒级无损。
/// - 跨编码（如 vp9 → H.264/H.265）：转码；HDR 源转 H.265 用 libx265 10-bit 保 HDR。
public struct Transcoder: Sendable {

    public init() {}

    /// 转码计划：决定用 remux 还是转码、目标容器、是否丢 HDR。
    public struct Plan: Sendable, Equatable {
        public var ffmpegArgs: [String]
        public var outputExtension: String
        public var isRemux: Bool
        public var dropsHDR: Bool
    }

    /// 是否需要处理：original 一律跳过；其余按目标格式决定。
    public static func needsProcessing(_ format: OutputFormat) -> Bool {
        format != .original
    }

    /// 生成 ffmpeg 参数（不含可执行名）。输入输出文件名由调用方拼。
    /// - sourceVCodec: 源视频编码简称（h264/h265/vp9/av1…）。
    /// - sourceIsHDR: 源是否 HDR。
    public static func plan(
        format: OutputFormat,
        inputPath: String,
        outputPath: String,
        sourceVCodec: String?,
        sourceIsHDR: Bool,
        x265Available: Bool
    ) -> Plan {
        let codec = (sourceVCodec ?? "").lowercased()
        switch format {
        case .original:
            // 不应走到这里；按 remux 处理。
            return Plan(
                ffmpegArgs: ["-y", "-i", inputPath, "-c", "copy", outputPath],
                outputExtension: URL(fileURLWithPath: outputPath).pathExtension,
                isRemux: true, dropsHDR: false
            )
        case .mkv:
            // 只换封装，编码不动 → 保 HDR。
            return Plan(
                ffmpegArgs: ["-y", "-i", inputPath, "-c", "copy", outputPath],
                outputExtension: "mkv",
                isRemux: true, dropsHDR: false
            )
        case .mp4H264:
            if codec == "h264" {
                // 已是 H.264 → 只换 mp4 容器。
                return Plan(
                    ffmpegArgs: ["-y", "-i", inputPath, "-c", "copy", "-movflags", "+faststart", outputPath],
                    outputExtension: "mp4", isRemux: true, dropsHDR: false
                )
            }
            // 转 H.264：8-bit SDR，HDR 源会丢 HDR（tonemap）。
            var args = ["-y", "-i", inputPath]
            if sourceIsHDR {
                args += ["-vf", "zscale=t=linear:npl=100,tonemap=hable,zscale=t=bt709:m=bt709:r=tv,format=yuv420p"]
            }
            args += ["-c:v", "libx264", "-crf", "20", "-preset", "medium",
                     "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", outputPath]
            return Plan(ffmpegArgs: args, outputExtension: "mp4", isRemux: false, dropsHDR: sourceIsHDR)
        case .mp4H265:
            if codec == "h265" {
                return Plan(
                    ffmpegArgs: ["-y", "-i", inputPath, "-c", "copy", "-tag:v", "hvc1", "-movflags", "+faststart", outputPath],
                    outputExtension: "mp4", isRemux: true, dropsHDR: false
                )
            }
            // 转 H.265：HDR 源用 libx265 10-bit 保 HDR（x265 可用时）；x265 不可用时回退 tonemap 成 SDR。
            var args = ["-y", "-i", inputPath]
            if sourceIsHDR && x265Available {
                args += ["-c:v", "libx265", "-crf", "20", "-preset", "medium",
                         "-pix_fmt", "yuv420p10le",
                         "-x265-params", "hdr-opt=1:repeat-headers=1:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc"]
            } else {
                // x265 不可用或源非 HDR：用 libx265 8-bit；HDR 源先 tonemap 降级成 SDR，避免画面发灰/偏色。
                if sourceIsHDR {
                    args += ["-vf", "zscale=t=linear:npl=100,tonemap=hable,zscale=t=bt709:m=bt709:r=tv,format=yuv420p"]
                }
                args += ["-c:v", "libx265", "-crf", "20", "-preset", "medium"]
            }
            args += ["-tag:v", "hvc1", "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", outputPath]
            return Plan(ffmpegArgs: args, outputExtension: "mp4", isRemux: false, dropsHDR: sourceIsHDR && !x265Available)
        }
    }

    /// 执行转码/remux：把 inputFile 转成目标格式，返回新文件 URL（原文件保留或替换由调用方决定）。
    /// 失败抛 MoongateError.burnFailed（复用错误类型）。可取消。
    public func transcode(
        inputFile: URL,
        format: OutputFormat,
        sourceVCodec: String?,
        sourceIsHDR: Bool,
        control: TaskControlToken?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        guard let ffmpeg = FFmpegBurner.locateAnyFFmpeg() else {
            throw MoongateError.burnFailed("找不到 ffmpeg，无法转码。请安装：brew install ffmpeg-full")
        }
        let x265 = FFmpegBurner.encoderAvailable("libx265", ffmpeg: ffmpeg)
        let stem = inputFile.deletingPathExtension().lastPathComponent
        let dir = inputFile.deletingLastPathComponent()
        // 调用方常传 nil；此时探测下载产物的真实编码，让「已是目标编码」时走 remux 而非整段重编码。
        let resolvedVCodec: String?
        if let sourceVCodec {
            resolvedVCodec = sourceVCodec
        } else {
            resolvedVCodec = await FFmpegBurner.probeVideoCodec(file: inputFile)
        }
        // 先用一次 plan 求目标容器扩展名（ffmpeg 按输出扩展名推断 muxer，临时文件必须带正确扩展名）。
        let probePlan = Self.plan(
            format: format, inputPath: inputFile.path, outputPath: inputFile.path,
            sourceVCodec: resolvedVCodec, sourceIsHDR: sourceIsHDR, x265Available: x265
        )
        let targetExt = probePlan.outputExtension
        // 始终先写到临时文件，避免「输入输出同名同容器」时 ffmpeg 无法同时读写同一文件而直接报错。
        let tmpOutput = dir.appendingPathComponent("\(stem).transcoding.\(UUID().uuidString.prefix(8)).\(targetExt)")
        let p = Self.plan(
            format: format,
            inputPath: inputFile.path,
            outputPath: tmpOutput.path,
            sourceVCodec: resolvedVCodec,
            sourceIsHDR: sourceIsHDR,
            x265Available: x265
        )
        // 最终落地文件名：与输入同容器时允许就地替换（原文件随后删除），否则避让已存在文件。
        var output = dir.appendingPathComponent("\(stem).\(p.outputExtension)")
        var serial = 2
        while FileManager.default.fileExists(atPath: output.path), output != inputFile {
            output = dir.appendingPathComponent("\(stem) \(serial).\(p.outputExtension)")
            serial += 1
        }
        // ffmpeg 写临时文件；占位的最后一个参数已是 tmpOutput.path，无需再改。
        let args = p.ffmpegArgs

        if control?.isCancelled == true { throw MoongateError.cancelled }
        let duration = await FFmpegBurner.probeDurationSeconds(file: inputFile)
        do {
            let (status, tail) = try await YtDlpEngine.runStreamingProcess(
                executable: ffmpeg,
                arguments: args,
                stallTimeout: 180,
                isSuspended: { control?.isPaused ?? false },
                onStart: { pid in
                    if control?.isCancelled == true {
                        TaskControlToken.signalTree(pid, SIGKILL)
                    } else {
                        control?.setActivePID(pid)
                    }
                }
            ) { line in
                if let frac = FFmpegBurner.parseProgressFraction(line: line, totalSeconds: duration) {
                    progress(frac)
                }
            }
            control?.setActivePID(0)
            if control?.isCancelled == true {
                try? FileManager.default.removeItem(at: tmpOutput)
                throw MoongateError.cancelled
            }
            guard status == 0 else {
                try? FileManager.default.removeItem(at: tmpOutput)
                throw MoongateError.burnFailed("转码失败：\(tail.split(separator: "\n").last.map(String.init) ?? "未知错误")")
            }
        } catch is ProcessStalledError {
            try? FileManager.default.removeItem(at: tmpOutput)
            throw MoongateError.burnFailed("转码进程长时间无输出，已中止（可重试）。")
        }
        // 落地：就地替换或覆盖已存在的目标文件，再把临时文件移到最终名。
        try? FileManager.default.removeItem(at: output)
        do {
            try FileManager.default.moveItem(at: tmpOutput, to: output)
        } catch {
            try? FileManager.default.removeItem(at: tmpOutput)
            throw MoongateError.burnFailed("转码完成但无法保存输出文件：\(error.localizedDescription)")
        }
        progress(1)
        return output
    }
}
