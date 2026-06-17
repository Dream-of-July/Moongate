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
        public var accelerationReport: PipelineAccelerationReport

        public init(
            ffmpegArgs: [String],
            outputExtension: String,
            isRemux: Bool,
            dropsHDR: Bool,
            accelerationReport: PipelineAccelerationReport = .none
        ) {
            self.ffmpegArgs = ffmpegArgs
            self.outputExtension = outputExtension
            self.isRemux = isRemux
            self.dropsHDR = dropsHDR
            self.accelerationReport = accelerationReport
        }
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
        x265Available: Bool,
        backend: EncodeBackend = .software,
        hevcVTAvailable: Bool = false,
        h264VTAvailable: Bool = false
    ) -> Plan {
        let codec = (sourceVCodec ?? "").lowercased()
        let wantHW = backend.prefersHardware
        let q = FFmpegBurner.videoToolboxQuality
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
            // 转 H.264：8-bit SDR，HDR 源会丢 HDR（tonemap）。硬件可用时用 h264_videotoolbox 恒定质量。
            let usesHardwareEncode = wantHW && h264VTAvailable
            let requiresCPUVideoFilter = sourceIsHDR
            let family: HardwareAccelerationFamily = usesHardwareEncode ? .videoToolbox : .none
            var args = ["-y"]
                + HardwareAccelerationPlanner.inputArgs(
                    family: family,
                    requiresCPUVideoFilter: requiresCPUVideoFilter
                )
                + ["-i", inputPath]
            if sourceIsHDR {
                args += ["-vf", "zscale=t=linear:npl=100,tonemap=hable,zscale=t=bt709:m=bt709:r=tv,format=yuv420p"]
            }
            if usesHardwareEncode {
                args += ["-c:v", "h264_videotoolbox", "-q:v", "\(q)", "-pix_fmt", "yuv420p"]
            } else {
                args += ["-c:v", "libx264", "-crf", "20", "-preset", "medium"]
            }
            args += ["-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", outputPath]
            return Plan(
                ffmpegArgs: args,
                outputExtension: "mp4",
                isRemux: false,
                dropsHDR: sourceIsHDR,
                accelerationReport: HardwareAccelerationPlanner.report(
                    family: family,
                    usesHardwareEncode: usesHardwareEncode,
                    requiresCPUVideoFilter: requiresCPUVideoFilter
                )
            )
        case .mp4H265:
            if codec == "h265" {
                return Plan(
                    ffmpegArgs: ["-y", "-i", inputPath, "-c", "copy", "-tag:v", "hvc1", "-movflags", "+faststart", outputPath],
                    outputExtension: "mp4", isRemux: true, dropsHDR: false
                )
            }
            // 转 H.265。硬件 HEVC 可用时优先（HDR 走 main10 + 色彩元数据透传，保 HDR）；
            // 否则软件 libx265（HDR 用 10-bit hdr-opt）。两者都不可用 HDR 时退回 libx265 8-bit（丢 HDR）。
            let usesHardwareEncode = wantHW && hevcVTAvailable
            let family: HardwareAccelerationFamily = usesHardwareEncode ? .videoToolbox : .none
            let requiresCPUVideoFilter = false
            var args = ["-y"]
                + HardwareAccelerationPlanner.inputArgs(
                    family: family,
                    requiresCPUVideoFilter: requiresCPUVideoFilter
                )
                + ["-i", inputPath]
            let keepsHDR: Bool
            if usesHardwareEncode {
                if sourceIsHDR {
                    args += ["-c:v", "hevc_videotoolbox", "-profile:v", "main10", "-q:v", "\(q)", "-pix_fmt", "p010le"]
                    args += FFmpegBurner.hdrColorArgs(colorPrimaries: nil, colorTransfer: nil, colorSpace: nil)
                    keepsHDR = true
                } else {
                    args += ["-c:v", "hevc_videotoolbox", "-q:v", "\(q)", "-pix_fmt", "yuv420p"]
                    keepsHDR = false
                }
            } else {
                args += ["-c:v", "libx265", "-crf", "20", "-preset", "medium"]
                if sourceIsHDR && x265Available {
                    args += ["-pix_fmt", "yuv420p10le",
                             "-x265-params", "hdr-opt=1:repeat-headers=1:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc"]
                    keepsHDR = true
                } else {
                    keepsHDR = false
                }
            }
            args += ["-tag:v", "hvc1", "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", outputPath]
            return Plan(
                ffmpegArgs: args,
                outputExtension: "mp4",
                isRemux: false,
                dropsHDR: sourceIsHDR && !keepsHDR,
                accelerationReport: HardwareAccelerationPlanner.report(
                    family: family,
                    usesHardwareEncode: usesHardwareEncode,
                    requiresCPUVideoFilter: requiresCPUVideoFilter
                )
            )
        }
    }

    /// 执行转码/remux：把 inputFile 转成目标格式，返回新文件 URL（原文件保留或替换由调用方决定）。
    /// 失败抛 MoongateError.burnFailed（复用错误类型）。可取消。
    public func transcode(
        inputFile: URL,
        format: OutputFormat,
        sourceVCodec: String?,
        sourceIsHDR: Bool,
        backend: EncodeBackend = .auto,
        control: TaskControlToken?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        guard let ffmpeg = FFmpegBurner.locateAnyFFmpeg() else {
            throw MoongateError.burnFailed(CoreL10n.text(
                en: "Cannot find ffmpeg, so transcoding cannot continue. Install it with: brew install ffmpeg-full",
                zhHans: "找不到 ffmpeg，无法转码。请安装：brew install ffmpeg-full",
                zhHant: "找不到 ffmpeg，無法轉碼。請安裝：brew install ffmpeg-full"
            ))
        }
        let x265 = FFmpegBurner.encoderAvailable("libx265", ffmpeg: ffmpeg)
        let hevcVT = FFmpegBurner.encoderAvailable("hevc_videotoolbox", ffmpeg: ffmpeg)
        let h264VT = FFmpegBurner.encoderAvailable("h264_videotoolbox", ffmpeg: ffmpeg)
        let stem = inputFile.deletingPathExtension().lastPathComponent
        let dir = inputFile.deletingLastPathComponent()
        // 调用方常传 nil；此时探测下载产物的真实编码，让「已是目标编码」时走 remux 而非整段重编码。
        let resolvedVCodec: String?
        if let sourceVCodec {
            resolvedVCodec = sourceVCodec
        } else {
            resolvedVCodec = await FFmpegBurner.probeVideoCodec(file: inputFile)
        }
        if format == .mp4H265,
           (resolvedVCodec ?? "").lowercased() != "h265",
           !hevcVT,
           !x265 {
            throw MoongateError.burnFailed(CoreL10n.text(
                en: "The current ffmpeg does not include an HEVC encoder (hevc_videotoolbox or libx265), so it cannot convert to H.265. Install the full ffmpeg build, or choose H.264/source format.",
                zhHans: "当前 ffmpeg 缺少 HEVC 编码器（hevc_videotoolbox 或 libx265），无法转为 H.265。请安装完整 ffmpeg，或改选 H.264/原格式。",
                zhHant: "目前 ffmpeg 缺少 HEVC 編碼器（hevc_videotoolbox 或 libx265），無法轉為 H.265。請安裝完整版 ffmpeg，或改選 H.264/來源格式。"
            ))
        }
        let resolvedIsHDR = await FFmpegBurner.probeVideoHDRStatus(file: inputFile) ?? sourceIsHDR
        // 先用一次 plan 求目标容器扩展名（ffmpeg 按输出扩展名推断 muxer，临时文件必须带正确扩展名）。
        let probePlan = Self.plan(
            format: format, inputPath: inputFile.path, outputPath: inputFile.path,
            sourceVCodec: resolvedVCodec, sourceIsHDR: resolvedIsHDR, x265Available: x265,
            backend: backend, hevcVTAvailable: hevcVT, h264VTAvailable: h264VT
        )
        let targetExt = probePlan.outputExtension
        // 始终先写到临时文件，避免「输入输出同名同容器」时 ffmpeg 无法同时读写同一文件而直接报错。
        let tmpOutput = dir.appendingPathComponent("\(stem).transcoding.\(UUID().uuidString.prefix(8)).\(targetExt)")
        let p = Self.plan(
            format: format,
            inputPath: inputFile.path,
            outputPath: tmpOutput.path,
            sourceVCodec: resolvedVCodec,
            sourceIsHDR: resolvedIsHDR,
            x265Available: x265,
            backend: backend,
            hevcVTAvailable: hevcVT,
            h264VTAvailable: h264VT
        )
        // 最终落地文件名：与输入同容器时允许就地替换（原文件随后删除），否则避让已存在文件。
        var output = dir.appendingPathComponent("\(stem).\(p.outputExtension)")
        var serial = 2
        while FileManager.default.fileExists(atPath: output.path), output != inputFile {
            output = dir.appendingPathComponent("\(stem) \(serial).\(p.outputExtension)")
            serial += 1
        }
        // ffmpeg 写临时文件；占位的最后一个参数已是 tmpOutput.path，无需再改。
        // 进度：plan() 的参数不含 -progress（保持其纯净、可被单测精确断言），
        // 这里在输出文件名前插入 `-progress pipe:1 -nostats`，让 ffmpeg 把 out_time_us=
        // 写到 stdout，runStreamingProcess 的行回调据此换算完成比例、驱动进度条。
        var args = p.ffmpegArgs
        if !p.isRemux, let outIndex = args.lastIndex(of: tmpOutput.path) {
            // 转码（重编码）才有意义；remux 是 -c copy 秒级完成，不插进度参数。
            args.insert(contentsOf: ["-progress", "pipe:1", "-nostats"], at: outIndex)
        }

        if control?.isCancelled == true { throw MoongateError.cancelled }
        let duration = await FFmpegBurner.probeDurationSeconds(file: inputFile)
        do {
            defer { control?.setActivePID(0) }
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
            if control?.isCancelled == true {
                try? FileManager.default.removeItem(at: tmpOutput)
                throw MoongateError.cancelled
            }
            guard status == 0 else {
                try? FileManager.default.removeItem(at: tmpOutput)
                let reason = tail.split(separator: "\n").last.map(String.init) ?? CoreL10n.text(
                    en: "Unknown error",
                    zhHans: "未知错误",
                    zhHant: "未知錯誤"
                )
                throw MoongateError.burnFailed("\(CoreL10n.text(en: "Transcoding failed", zhHans: "转码失败", zhHant: "轉碼失敗"))：\(reason)")
            }
        } catch is ProcessStalledError {
            try? FileManager.default.removeItem(at: tmpOutput)
            throw MoongateError.burnFailed(CoreL10n.text(
                en: "The transcoding process produced no output for too long and was stopped. You can retry.",
                zhHans: "转码进程长时间无输出，已中止（可重试）。",
                zhHant: "轉碼程序長時間沒有輸出，已中止（可重試）。"
            ))
        }
        // 落地：就地替换或覆盖已存在的目标文件，再把临时文件移到最终名。
        try? FileManager.default.removeItem(at: output)
        do {
            try FileManager.default.moveItem(at: tmpOutput, to: output)
        } catch {
            try? FileManager.default.removeItem(at: tmpOutput)
            throw MoongateError.burnFailed("\(CoreL10n.text(en: "Transcoding finished but the output file could not be saved", zhHans: "转码完成但无法保存输出文件", zhHant: "轉碼完成但無法儲存輸出檔"))：\(error.localizedDescription)")
        }
        progress(1)
        return output
    }
}
