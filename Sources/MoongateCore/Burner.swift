import Foundation

// MARK: - 默认烧录器

public func makeBurner() -> any SubtitleBurner {
    FFmpegBurner()
}

// MARK: - FFmpegBurner

/// ffmpeg subtitles 滤镜硬烧录字幕：按源编码选择 H.264/HEVC，默认优先画质。
/// 可选 scale 缩放到 maxHeight（避开 4K60 的 H.264 编码上限、又快又小）。
public struct FFmpegBurner: SubtitleBurner {

    public init() {}

    #if os(Windows)
    /// Windows：沿 PATH 找 ffmpeg.exe（官方 full 构建自带 libass）。
    private static func locate(_ name: String) -> String? {
        let fm = FileManager.default
        let env = ProcessInfo.processInfo.environment
        if name == "ffmpeg", let custom = env["MOONGATE_BURN_FFMPEG_PATH"],
           !custom.isEmpty, fm.isExecutableFile(atPath: custom) {
            return custom
        }
        let exe = name.lowercased().hasSuffix(".exe") ? name : name + ".exe"
        let pathValue = env.first { $0.key.lowercased() == "path" }?.value ?? ""
        for dir in pathValue.split(separator: ";") {
            let candidate = String(dir) + "\\" + exe
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
    #else
    // 烧录需要带 libass 的 ffmpeg（subtitles 滤镜）。Homebrew 镜像的 ffmpeg 可能是
    // 无 libass 的精简版，因此优先找 keg-only 的 ffmpeg-full，并在选择时验证能力。
    private static let searchPaths = [
        "/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg",
        "/usr/local/opt/ffmpeg-full/bin/ffmpeg",
        "/opt/homebrew/bin/ffmpeg",
        "/usr/local/bin/ffmpeg",
    ]

    private static func locate(_ name: String) -> String? {
        if name == "ffmpeg" {
            return locateSubtitleRendererFFmpeg()
        }
        for dir in ["/opt/homebrew/bin", "/usr/local/bin"] {
            let path = dir + "/" + name
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    internal static func locateSubtitleRendererFFmpeg(
        candidates: [String] = searchPaths,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileIsExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        supportsSubtitleRendering: (String) -> Bool = ffmpegSupportsSubtitleRendering
    ) -> String? {
        if let custom = environment["MOONGATE_BURN_FFMPEG_PATH"],
           !custom.isEmpty, fileIsExecutable(custom), supportsSubtitleRendering(custom) {
            return custom
        }
        for path in candidates where fileIsExecutable(path) && supportsSubtitleRendering(path) {
            return path
        }
        return nil
    }

    /// 探测某个编码器是否可用（`ffmpeg -encoders` 含该名）。结果按 ffmpeg 路径缓存。
    private static let encoderCacheLock = NSLock()
    nonisolated(unsafe) private static var encoderCache: [String: Set<String>] = [:]

    static func encoderAvailable(_ encoder: String, ffmpeg: String) -> Bool {
        encoderCacheLock.lock()
        if let cached = encoderCache[ffmpeg] {
            encoderCacheLock.unlock()
            return cached.contains(encoder)
        }
        encoderCacheLock.unlock()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = ["-hide_banner", "-encoders"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        guard (try? process.run()) != nil else { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        var found: Set<String> = []
        for token in ["libx265", "libx264", "libsvtav1", "hevc_videotoolbox", "h264_videotoolbox"] where text.contains(token) {
            found.insert(token)
        }
        encoderCacheLock.lock()
        encoderCache[ffmpeg] = found
        encoderCacheLock.unlock()
        return found.contains(encoder)
    }

    internal static func filterListHasSubtitleRenderer(_ text: String) -> Bool {
        text.split(whereSeparator: \.isNewline).contains { line in
            line.range(
                of: #"^\s*[TSC\.]+\s+subtitles\s"#,
                options: .regularExpression
            ) != nil
        }
    }

    private static func ffmpegSupportsSubtitleRendering(_ path: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["-hide_banner", "-filters"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return false
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return false }
        return filterListHasSubtitleRenderer(String(decoding: data, as: UTF8.self))
    }
    #endif

    /// 平台中文字体：macOS 苹方，Windows 微软雅黑。
    static var chineseFontName: String {
        #if os(Windows)
        return "Microsoft YaHei"
        #else
        return "PingFang SC"
        #endif
    }

    public func burn(
        video: URL,
        subtitle: URL,
        maxHeight: Int?,
        backend: EncodeBackend = .auto,
        alwaysH264: Bool = false,
        control: TaskControlToken?,
        outputTag: String? = nil,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        guard let ffmpeg = Self.locate("ffmpeg") else {
            throw MoongateError.burnFailed(Self.libassMissingMessage)
        }
        if control?.isCancelled == true { throw MoongateError.cancelled }

        // 1. ffprobe 取时长、码率、源尺寸与编码（取不到不阻塞烧录，只影响进度与缩放/码率）
        let probe = await Self.probe(video: video)

        // 「最大 1080p」语义按短边算：横屏限高、竖屏限宽。
        // 旧规则只看高度，竖屏 1080×1920 会被压成 608×1080（短边掉到 608）。
        let isPortrait: Bool = {
            guard let w = probe.width, let h = probe.height else { return false }
            return w < h
        }()
        let sourceShortSide: Int? = {
            guard let h = probe.height else { return probe.width }
            guard let w = probe.width else { return h }
            return min(w, h)
        }()
        // 缩放目标：maxHeight 非空且源短边更大时把短边缩到 maxHeight，否则保持源。
        let targetShortSide: Int? = {
            guard let maxHeight, maxHeight > 0, let short = sourceShortSide,
                  short > maxHeight else { return nil }
            return maxHeight
        }()
        // 编码器选择需要在计算缩放码率上限前完成：AV1/VP9 这类高效源默认转 HEVC，
        // 强制 H.264 时使用更高质量参数，不能照搬源码率封顶。
        let x265Available = Self.encoderAvailable("libx265", ffmpeg: ffmpeg)
        let hevcVTAvailable = Self.encoderAvailable("hevc_videotoolbox", ffmpeg: ffmpeg)
        let h264VTAvailable = Self.encoderAvailable("h264_videotoolbox", ffmpeg: ffmpeg)
        let sourceCodec = Self.normalizedVideoCodec(probe.codecName)
        let outputCodec = Self.preferredBurnOutputCodec(
            sourceCodec: sourceCodec,
            isHDR: probe.isHDR,
            alwaysH264: alwaysH264,
            x265Available: x265Available,
            hevcVTAvailable: hevcVTAvailable
        )
        // -maxrate 上限只用于缩放场景。不缩放时走纯 CRF / VideoToolbox -q:v，避免低码率 AV1
        // 以近似码率转成 H.264 后严重糊掉。
        let maxrateK: Int? = targetShortSide.map {
            Self.maxrateK(
                sourceBitRateBPS: probe.bitRateBPS,
                sourceHeight: sourceShortSide,
                targetHeight: $0,
                sourceCodec: sourceCodec,
                outputCodec: outputCodec
            )
        }

        // 2. 临时目录：字幕转成 subs.ass 并把 ffmpeg 工作目录设到这里，
        //    规避 subtitles 滤镜对路径里冒号/引号/中文的转义问题。
        //    用 ASS 而非 SRT 是为了双语两种字号：中文（首行）正常字号，原文（次行）更小。
        let fm = FileManager.default
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("moongate-burn-\(UUID().uuidString)", isDirectory: true)
        // 缩放滤镜：-2 让另一边自动按比例取偶数，避免 H.264 要求偶数边长报错。
        // 横屏限高（scale=-2:H）、竖屏限宽（scale=W:-2）。
        let scaleFilter = targetShortSide.map { isPortrait ? "scale=\($0):-2" : "scale=-2:\($0)" }
        let filter: String
        do {
            try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let srtText = try String(contentsOf: subtitle, encoding: .utf8)
            let cues = parseSRT(srtText)
            let subtitleFilter: String
            if cues.isEmpty {
                // 解析不出来就按原样走 SRT + force_style 的老路
                try fm.copyItem(at: subtitle, to: tempDir.appendingPathComponent("subs.srt"))
                subtitleFilter = "subtitles=subs.srt:force_style="
                    + "'FontName=\(Self.chineseFontName),FontSize=15,Outline=1,Shadow=0,MarginV=20'"
            } else {
                // 字幕坐标系/字号按视频长宽比自适应（缩放不改变比例，用源尺寸即可）
                let aspect: Double = {
                    guard let w = probe.width, let h = probe.height, w > 0, h > 0 else {
                        return 16.0 / 9.0
                    }
                    return Double(w) / Double(h)
                }()
                let ass = Self.makeASS(cues: cues, aspect: aspect)
                try ass.write(
                    to: tempDir.appendingPathComponent("subs.ass"),
                    atomically: true, encoding: .utf8
                )
                subtitleFilter = "subtitles=subs.ass"
            }
            // 先缩放再烧字幕：字幕按目标分辨率渲染，清晰度与位置都正确。
            // 同一条 -vf filterchain 用逗号连接。
            if let scaleFilter {
                filter = scaleFilter + "," + subtitleFilter
            } else {
                filter = subtitleFilter
            }
        } catch let error as MoongateError {
            try? fm.removeItem(at: tempDir)
            throw error
        } catch {
            try? fm.removeItem(at: tempDir)
            throw MoongateError.burnFailed("\(CoreL10n.text(en: "Could not prepare the temporary subtitle file", zhHans: "无法准备字幕临时文件", zhHant: "無法準備字幕暫存檔"))：\(error.localizedDescription)")
        }
        defer { try? fm.removeItem(at: tempDir) }

        // 3. 滤镜与参数
        let copyAudio = ["-c:a", "copy"]
        let aacAudio = ["-c:a", "aac", "-b:a", "192k"]

        // 编码器选择：按 后端 / 源编码 / HDR / 是否强制 H.264 决定用硬件还是软件、何种编码。
        // 硬件（VideoToolbox）通常更快、更省电；兼容路径同体积画质更稳但更慢。
        // 候选链：主选（按后端）+ 同编码的软件回退。硬件编码失败时退到软件**同一种编码**，
        // 保证「选了 HEVC 就输出 HEVC」，绝不降级成 H.264。
        let candidates = Self.selectVideoEncoderChain(
            backend: backend,
            alwaysH264: alwaysH264,
            sourceCodec: sourceCodec,
            isHDR: probe.isHDR,
            colorPrimaries: probe.colorPrimaries,
            colorTransfer: probe.colorTransfer,
            colorSpace: probe.colorSpace,
            maxrateK: maxrateK,
            x265Available: x265Available,
            hevcVTAvailable: hevcVTAvailable,
            h264VTAvailable: h264VTAvailable
        )

        // 4. 跑 ffmpeg，stdout 的 -progress 输出换算进度。
        //    onStart 登记 pid 到 control：暂停时向 ffmpeg 进程树发 SIGSTOP/SIGCONT。
        let totalSeconds = probe.duration
        func run(_ arguments: [String]) async throws -> (status: Int32, stderrTail: String) {
            do {
                defer { control?.setActivePID(0) }
                return try await YtDlpEngine.runStreamingProcess(
                    executable: ffmpeg,
                    arguments: arguments,
                    currentDirectory: tempDir,
                    // ffmpeg 的 -progress 每约 0.5s 必有输出；2 分钟静默 = 真挂死。
                    stallTimeout: 120,
                    isSuspended: { control?.isPaused ?? false },
                    onStart: { pid in
                        if control?.isCancelled == true {
                            // 启动瞬间已取消：立即终止进程树。
                            TaskControlToken.signalTree(pid, SIGKILL)
                        } else {
                            control?.setActivePID(pid)
                        }
                    }
                ) { line in
                    if let fraction = Self.parseProgress(line: line, totalSeconds: totalSeconds) {
                        progress(fraction)
                    }
                }
            } catch is ProcessStalledError {
                throw MoongateError.burnFailed(CoreL10n.text(
                    en: "The burn-in process produced no output for more than 2 minutes and was stopped. You can retry.",
                    zhHans: "烧录进程超过 2 分钟没有任何输出，疑似挂死，已自动中止（可重试）。",
                    zhHant: "燒錄程序超過 2 分鐘沒有任何輸出，疑似卡住，已自動中止（可重試）。"
                ))
            }
        }

        // 字幕滤镜缺失（libass）这类错误换编码器也修不好：命中即终止，不浪费后续重编码。
        func isUnfixable(_ stderrTail: String) -> Bool {
            let lower = stderrTail.lowercased()
            return lower.contains("error parsing filterchain")
                || lower.contains("no such filter")
                || lower.contains("no such file")
        }

        // 依次尝试候选编码；每个候选先 copy 音轨，失败（且非取消/非不可修复）再用 aac 音轨。
        // 视频编码层失败（如硬件 VideoToolbox 对该输入报错）→ 进入下一个候选（软件同编码）。
        var status: Int32 = -1
        var stderrTail = ""
        outer: for selection in candidates {
            let videoFilter = selection.filterPrefix + filter + selection.filterSuffix
            let head = ["-y", "-i", video.path, "-vf", videoFilter]
            func tail(audio: [String]) -> [String] {
                audio + selection.colorArgs + ["-movflags", "+faststart", "-nostats", "-progress", "pipe:1", "out.mp4"]
            }

            for audio in [copyAudio, aacAudio] {
                try? fm.removeItem(at: tempDir.appendingPathComponent("out.mp4"))
                (status, stderrTail) = try await run(head + selection.encoderArgs + tail(audio: audio))
                control?.setActivePID(0)
                if status == 0 { break outer }
                if control?.isCancelled == true { throw MoongateError.cancelled }
                // 字幕滤镜不可修复：换音轨/换编码都没用，直接终止。
                if isUnfixable(stderrTail) { break outer }
                // copy 音轨失败常因音频编码不进 mp4 容器：用 aac 再试（同候选）。
            }
            // 本候选 copy/aac 都失败：若还有软件回退候选，进入下一轮用同编码软件重试。
        }

        guard status == 0 else {
            // 取消归一化：onStart 在取消时 SIGKILL 了进程树，ffmpeg 以非 0 退出，
            // 这里识别为取消（抛 cancelled）而不是 burnFailed，避免误报「烧录失败」。
            if control?.isCancelled == true { throw MoongateError.cancelled }
            let lower = stderrTail.lowercased()
            if lower.contains("error parsing filterchain") || lower.contains("no such filter") {
                throw MoongateError.burnFailed(Self.libassMissingMessage)
            }
            throw MoongateError.burnFailed(Self.lastLine(of: stderrTail))
        }
        let produced = tempDir.appendingPathComponent("out.mp4")
        guard fm.fileExists(atPath: produced.path) else {
            throw MoongateError.burnFailed(CoreL10n.text(
                en: "ffmpeg exited but did not produce an output file.",
                zhHans: "ffmpeg 已退出，但没有生成输出文件。",
                zhHant: "ffmpeg 已退出，但沒有產生輸出檔。"
            ))
        }
        progress(1)

        // 6. 移到视频同目录："<原名>（字幕版）.mp4"，重名时加 " 2"、" 3"…
        let stem = video.deletingPathExtension().lastPathComponent
        let directory = video.deletingLastPathComponent()
        let tag = outputTag ?? CoreL10n.t(L.Queue.subtitleVersionTag)
        var destination = directory.appendingPathComponent("\(stem)\(tag).mp4")
        var serial = 2
        while fm.fileExists(atPath: destination.path) {
            destination = directory.appendingPathComponent("\(stem)\(tag) \(serial).mp4")
            serial += 1
        }
        do {
            try fm.moveItem(at: produced, to: destination)
        } catch {
            throw MoongateError.burnFailed("\(CoreL10n.text(en: "Could not move the output file", zhHans: "无法移动输出文件", zhHant: "無法移動輸出檔"))：\(error.localizedDescription)")
        }
        return destination
    }

    // MARK: ffprobe

    private struct ProbeResult {
        var duration: Double?
        var bitRateBPS: Double?
        var width: Int?
        var height: Int?
        var colorTransfer: String?
        var colorPrimaries: String?
        var colorSpace: String?
        var codecName: String?

        /// 是否 HDR：传递函数为 PQ(smpte2084) 或 HLG(arib-std-b67)。
        var isHDR: Bool {
            let t = (colorTransfer ?? "").lowercased()
            return t.contains("smpte2084") || t.contains("arib-std-b67") || t.contains("pq") || t.contains("hlg")
        }
    }

    /// 收集 ffprobe 的多行 JSON 输出（onLine 回调线程并发追加）。
    private final class LineSink: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []

        func append(_ line: String) {
            lock.lock()
            lines.append(line)
            lock.unlock()
        }

        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return lines.joined(separator: "\n")
        }
    }

    private static func probe(video: URL) async -> ProbeResult {
        guard let ffprobe = locate("ffprobe") else { return ProbeResult() }
        let sink = LineSink()
        guard let (status, _) = try? await YtDlpEngine.runStreamingProcess(
            executable: ffprobe,
            arguments: ["-v", "quiet", "-print_format", "json", "-show_format", "-show_streams", video.path],
            onLine: { sink.append($0) }
        ), status == 0,
        let object = try? JSONSerialization.jsonObject(with: Data(sink.text.utf8)),
        let dict = object as? [String: Any] else { return ProbeResult() }

        var result = ProbeResult()
        if let format = dict["format"] as? [String: Any] {
            result.duration = double(format["duration"])
            result.bitRateBPS = double(format["bit_rate"])
        }
        if let streams = dict["streams"] as? [[String: Any]],
           let videoStream = streams.first(where: { ($0["codec_type"] as? String) == "video" }) {
            result.width = int(videoStream["width"])
            result.height = int(videoStream["height"])
            result.codecName = videoStream["codec_name"] as? String
            result.colorTransfer = videoStream["color_transfer"] as? String
            result.colorPrimaries = videoStream["color_primaries"] as? String
            result.colorSpace = videoStream["color_space"] as? String
            if result.bitRateBPS == nil {
                result.bitRateBPS = double(videoStream["bit_rate"])
            }
        }
        return result
    }

    /// HDR 保真烧录的视频编码参数：libx265 10-bit + HDR10 色彩元数据透传。
    /// 字幕仍是 SDR 白字，叠在 BT.2020/PQ 画面上由 subtitles 滤镜处理。
    /// maxrateK 非 nil 时封顶码率（仅缩放场景）；nil 时纯 CRF（保持源分辨率，画质一致）。
    static func hdrVideoArgs(
        colorPrimaries: String?,
        colorTransfer: String?,
        colorSpace: String?,
        maxrateK: Int?
    ) -> [String] {
        let prim = (colorPrimaries?.isEmpty == false) ? colorPrimaries! : "bt2020"
        let trc = (colorTransfer?.isEmpty == false) ? colorTransfer! : "smpte2084"
        let mtx = (colorSpace?.isEmpty == false) ? colorSpace! : "bt2020nc"
        let x265Params = [
            "hdr-opt=1",
            "repeat-headers=1",
            "colorprim=\(prim)",
            "transfer=\(trc)",
            "colormatrix=\(mtx)",
        ].joined(separator: ":")
        return [
            "-c:v", "libx265", "-crf", "20", "-preset", "medium",
            "-pix_fmt", "yuv420p10le",
            "-x265-params", x265Params,
            "-tag:v", "hvc1",
        ] + maxrateFlags(maxrateK)
    }

    /// SDR 的 HEVC 源烧字幕：libx265 8-bit，保住编码不降级到 H.264。
    /// maxrateK 非 nil 时封顶码率（仅缩放场景）；nil 时纯 CRF。不带任何 HDR 色彩元数据。
    static func sdrHEVCVideoArgs(maxrateK: Int?) -> [String] {
        [
            "-c:v", "libx265", "-crf", "20", "-preset", "medium",
            "-pix_fmt", "yuv420p",
            "-tag:v", "hvc1",
        ] + maxrateFlags(maxrateK)
    }

    /// -maxrate/-bufsize 参数：仅缩放场景（maxrateK 非 nil）才封顶；nil 时为空（纯 CRF）。
    private static func maxrateFlags(_ maxrateK: Int?) -> [String] {
        guard let maxrateK else { return [] }
        return ["-maxrate", "\(maxrateK)k", "-bufsize", "\(maxrateK * 2)k"]
    }

    // MARK: - 编码器选择（硬件 / 软件 × 源编码 × HDR）

    /// 一次编码所需的全部参数：编码器/像素格式（encoderArgs）、字幕滤镜前后缀
    /// （filterPrefix/Suffix，用于 HDR 10-bit 转换或 tonemap→SDR）、以及色彩元数据参数（colorArgs，
    /// 硬件路径需显式带上才能写出正确 HDR10 元数据）。
    struct VideoEncoderSelection: Equatable {
        var encoderArgs: [String]
        var filterPrefix: String
        var filterSuffix: String
        var colorArgs: [String]
    }

    /// VideoToolbox 恒定质量模式的 q 值（0...100，越高画质越好/文件越大）。
    /// 选高画质档（视觉接近无损）：实测同源下体积与 libx265 medium 相当或略大，4K 快数倍且不发热。
    static let videoToolboxQuality = 65
    static let videoToolboxHighQuality = 75

    static func normalizedVideoCodec(_ raw: String?) -> String? {
        let token = (raw ?? "")
            .lowercased()
            .split { $0 == "." || $0 == " " || $0 == "_" || $0 == "-" }
            .first
            .map(String.init) ?? ""
        switch token {
        case "hevc", "h265", "hev1", "hvc1":
            return "hevc"
        case "avc", "avc1", "h264":
            return "h264"
        case "av01", "av1":
            return "av1"
        case "vp09", "vp9":
            return "vp9"
        case "":
            return nil
        default:
            return token
        }
    }

    private static func codecPrefersHEVCBurn(_ codec: String?) -> Bool {
        switch normalizedVideoCodec(codec) {
        case "hevc", "av1", "vp9":
            return true
        default:
            return false
        }
    }

    private static func isEfficientSourceCodec(_ codec: String?) -> Bool {
        switch normalizedVideoCodec(codec) {
        case "hevc", "av1", "vp9":
            return true
        default:
            return false
        }
    }

    private static func preferredBurnOutputCodec(
        sourceCodec: String?,
        isHDR: Bool,
        alwaysH264: Bool,
        x265Available: Bool,
        hevcVTAvailable: Bool
    ) -> String {
        if alwaysH264 { return "h264" }
        if isHDR { return (hevcVTAvailable || x265Available) ? "hevc" : "h264" }
        if codecPrefersHEVCBurn(sourceCodec), hevcVTAvailable || x265Available {
            return "hevc"
        }
        return "h264"
    }

    /// 选择视频编码参数。纯函数，便于单测覆盖整个矩阵。
    /// 决策顺序：HDR → 强制 H.264（兼容）→ 自动质量（HEVC/AV1/VP9 走 HEVC，H.264 走 H.264）。
    /// 每一类再按 backend + 硬件可用性在 VideoToolbox / libx 间选择。
    static func selectVideoEncoder(
        backend: EncodeBackend,
        alwaysH264: Bool,
        sourceCodec: String?,
        isHDR: Bool,
        colorPrimaries: String?,
        colorTransfer: String?,
        colorSpace: String?,
        maxrateK: Int?,
        x265Available: Bool,
        hevcVTAvailable: Bool,
        h264VTAvailable: Bool
    ) -> VideoEncoderSelection {
        let wantHardware = backend.prefersHardware
        let normalizedSourceCodec = normalizedVideoCodec(sourceCodec)

        // 1) HDR：保 HDR 时输出 HEVC 10-bit；强制 H.264 时只能 tonemap→SDR。
        if isHDR && !alwaysH264 {
            if wantHardware && hevcVTAvailable {
                // 硬件 HEVC main10 + 显式色彩元数据透传（实测 mastering-display / max-cll 会被保留）。
                return VideoEncoderSelection(
                    encoderArgs: hwHDRVideoArgs(maxrateK: maxrateK),
                    filterPrefix: "",
                    filterSuffix: ",format=p010le",
                    colorArgs: hdrColorArgs(colorPrimaries: colorPrimaries, colorTransfer: colorTransfer, colorSpace: colorSpace)
                )
            }
            if x265Available {
                return VideoEncoderSelection(
                    encoderArgs: hdrVideoArgs(colorPrimaries: colorPrimaries, colorTransfer: colorTransfer, colorSpace: colorSpace, maxrateK: maxrateK),
                    filterPrefix: "",
                    filterSuffix: ",format=yuv420p10le",
                    colorArgs: []
                )
            }
            // 既无硬件 HEVC 也无 libx265：tonemap 成 SDR 再编码（画质降级，但仍能烧录）。
            return tonemappedSDRSelection(
                wantHardware: wantHardware, h264VTAvailable: h264VTAvailable, maxrateK: maxrateK
            )
        }

        // 2) HDR 源但用户强制 H.264：先 tonemap 成 SDR 再编码。
        if isHDR && alwaysH264 {
            return tonemappedSDRSelection(
                wantHardware: wantHardware, h264VTAvailable: h264VTAvailable, maxrateK: maxrateK
            )
        }

        // 3) SDR：自动质量优先。HEVC/AV1/VP9 统一输出 HEVC；兼容模式强制 H.264。
        let keepHEVC = codecPrefersHEVCBurn(normalizedSourceCodec) && !alwaysH264
        if keepHEVC {
            if wantHardware && hevcVTAvailable {
                return VideoEncoderSelection(encoderArgs: hwHEVCVideoArgs(maxrateK: maxrateK), filterPrefix: "", filterSuffix: "", colorArgs: [])
            }
            if x265Available {
                return VideoEncoderSelection(encoderArgs: sdrHEVCVideoArgs(maxrateK: maxrateK), filterPrefix: "", filterSuffix: "", colorArgs: [])
            }
            // 没有任何 HEVC 编码器：退回 H.264。
        }
        // H.264（强制、或源非 HEVC、或无 HEVC 编码器可用）。
        let highQualityH264 = isEfficientSourceCodec(normalizedSourceCodec)
        if wantHardware && h264VTAvailable {
            return VideoEncoderSelection(
                encoderArgs: hwH264VideoArgs(maxrateK: maxrateK, highQuality: highQualityH264),
                filterPrefix: "",
                filterSuffix: "",
                colorArgs: []
            )
        }
        return VideoEncoderSelection(
            encoderArgs: sdrH264VideoArgs(maxrateK: maxrateK, highQuality: highQualityH264),
            filterPrefix: "",
            filterSuffix: "",
            colorArgs: []
        )
    }

    /// 选择编码候选链：主选 + 同编码的软件回退。保证「用户/源决定的编码」最终一定能产出——
    /// 硬件 VideoToolbox 对个别输入会编码失败，此时回退到软件 libx265/libx264（**仍是同一种编码**，
    /// 只换后端，绝不把 HEVC 降成 H.264）。烧录循环依次尝试，命中即停。
    /// 主选已是软件、或硬件与软件选择一致（如硬件不可用时主选已落到软件）时只返回一个候选，不重复跑。
    static func selectVideoEncoderChain(
        backend: EncodeBackend,
        alwaysH264: Bool,
        sourceCodec: String?,
        isHDR: Bool,
        colorPrimaries: String?,
        colorTransfer: String?,
        colorSpace: String?,
        maxrateK: Int?,
        x265Available: Bool,
        hevcVTAvailable: Bool,
        h264VTAvailable: Bool
    ) -> [VideoEncoderSelection] {
        let primary = selectVideoEncoder(
            backend: backend, alwaysH264: alwaysH264, sourceCodec: sourceCodec, isHDR: isHDR,
            colorPrimaries: colorPrimaries, colorTransfer: colorTransfer, colorSpace: colorSpace,
            maxrateK: maxrateK, x265Available: x265Available,
            hevcVTAvailable: hevcVTAvailable, h264VTAvailable: h264VTAvailable
        )
        guard backend.prefersHardware else { return [primary] }
        // 软件回退：同样的输入但强制 software 后端——选出的编码与主选同种（HEVC↔libx265、H.264↔libx264），
        // 仅当它与主选真正不同（即主选确实走了硬件）时才追加，避免硬件不可用时的重复重编码。
        let softwareFallback = selectVideoEncoder(
            backend: .software, alwaysH264: alwaysH264, sourceCodec: sourceCodec, isHDR: isHDR,
            colorPrimaries: colorPrimaries, colorTransfer: colorTransfer, colorSpace: colorSpace,
            maxrateK: maxrateK, x265Available: x265Available,
            hevcVTAvailable: hevcVTAvailable, h264VTAvailable: h264VTAvailable
        )
        return softwareFallback.encoderArgs == primary.encoderArgs ? [primary] : [primary, softwareFallback]
    }

    /// HDR→SDR tonemap 后的编码选择（硬件 H.264 优先，否则软件 libx264）。
    private static func tonemappedSDRSelection(
        wantHardware: Bool, h264VTAvailable: Bool, maxrateK: Int?
    ) -> VideoEncoderSelection {
        let prefix = "zscale=t=linear:npl=100,tonemap=hable,zscale=t=bt709:m=bt709:r=tv,format=yuv420p,"
        let encoder = (wantHardware && h264VTAvailable) ? hwH264VideoArgs(maxrateK: maxrateK) : sdrH264VideoArgs(maxrateK: maxrateK)
        return VideoEncoderSelection(encoderArgs: encoder, filterPrefix: prefix, filterSuffix: "", colorArgs: [])
    }

    /// 软件 SDR H.264：libx264 + CRF 恒定质量 + maxrate 封顶（体积不超源）。
    static func sdrH264VideoArgs(maxrateK: Int?, highQuality: Bool = false) -> [String] {
        ["-c:v", "libx264", "-crf", highQuality ? "18" : "20", "-preset", "medium", "-pix_fmt", "yuv420p"]
            + maxrateFlags(maxrateK)
    }

    /// 硬件 H.264（VideoToolbox 恒定质量）。
    static func hwH264VideoArgs(maxrateK: Int?, highQuality: Bool = false) -> [String] {
        let quality = highQuality ? videoToolboxHighQuality : videoToolboxQuality
        return ["-c:v", "h264_videotoolbox"] + hardwareQualityOrBitrateArgs(maxrateK: maxrateK, quality: quality) + ["-pix_fmt", "yuv420p"]
    }

    /// 硬件 HEVC（VideoToolbox 恒定质量）SDR。
    static func hwHEVCVideoArgs(maxrateK: Int?) -> [String] {
        ["-c:v", "hevc_videotoolbox"] + hardwareQualityOrBitrateArgs(maxrateK: maxrateK) + ["-pix_fmt", "yuv420p", "-tag:v", "hvc1"]
    }

    /// 硬件 HEVC main10（VideoToolbox）HDR：10-bit p010le，色彩元数据由 colorArgs 单独透传。
    static func hwHDRVideoArgs(maxrateK: Int?) -> [String] {
        ["-c:v", "hevc_videotoolbox", "-profile:v", "main10"] + hardwareQualityOrBitrateArgs(maxrateK: maxrateK) + [
         "-pix_fmt", "p010le", "-tag:v", "hvc1"]
    }

    private static func hardwareQualityOrBitrateArgs(maxrateK: Int?, quality: Int = videoToolboxQuality) -> [String] {
        guard let maxrateK else { return ["-q:v", "\(quality)"] }
        return ["-b:v", "\(maxrateK)k"] + maxrateFlags(maxrateK)
    }

    /// HDR10 色彩元数据参数（硬件路径需显式带上，否则输出 trc/prim 为 unknown）。
    /// 缺源色彩信息时回退 BT.2020 / PQ / BT.2020nc。
    static func hdrColorArgs(colorPrimaries: String?, colorTransfer: String?, colorSpace: String?) -> [String] {
        let prim = (colorPrimaries?.isEmpty == false) ? colorPrimaries! : "bt2020"
        let trc = (colorTransfer?.isEmpty == false) ? colorTransfer! : "smpte2084"
        let mtx = (colorSpace?.isEmpty == false) ? colorSpace! : "bt2020nc"
        return ["-color_primaries", prim, "-color_trc", trc, "-colorspace", mtx]
    }

    private static func int(_ any: Any?) -> Int? {
        if let number = any as? NSNumber { return number.intValue }
        if let string = any as? String { return Int(string) }
        return nil
    }
    private static func double(_ any: Any?) -> Double? {
        if let number = any as? NSNumber { return number.doubleValue }
        if let string = any as? String { return Double(string) }
        return nil
    }

    // MARK: 进度与参数

    /// 计算缩放场景的 -maxrate k 值（CRF/质量编码下仅作封顶，防高复杂度片段码率失控、体积膨胀）。
    /// 仅在用户开启「缩放到 1080p」时使用：按目标分辨率档位封顶，并按源/目标编码效率给低码率源补地板。
    /// 不缩放场景不调用本函数（走纯 CRF / -q:v，无上限）。
    /// 档位上限：2160p≈16000，1440p≈10000，1080p≈6000，720p≈3000，480p≈1500。
    static func maxrateK(
        sourceBitRateBPS: Double?,
        sourceHeight _: Int?,
        targetHeight: Int,
        sourceCodec: String?,
        outputCodec: String
    ) -> Int {
        let sourceK: Int? = {
            guard let bps = sourceBitRateBPS, bps > 0 else { return nil }
            return Int(bps / 1000 * bitrateExpansionMultiplier(sourceCodec: sourceCodec, outputCodec: outputCodec))
        }()
        let tierK = bitrateForHeight(targetHeight)
        let floorK = bitrateFloorForHeight(targetHeight, outputCodec: outputCodec)
        return min(tierK, sourceK.map { max($0, floorK) } ?? tierK)
    }

    private static func bitrateExpansionMultiplier(sourceCodec: String?, outputCodec: String) -> Double {
        let source = normalizedVideoCodec(sourceCodec)
        let output = normalizedVideoCodec(outputCodec) ?? outputCodec.lowercased()
        switch (source, output) {
        case ("av1", "h264"), ("vp9", "h264"):
            return 4.0
        case ("hevc", "h264"):
            return 2.5
        case ("av1", "hevc"), ("vp9", "hevc"):
            return 2.5
        case ("h264", "h264"):
            return 1.5
        case ("h264", "hevc"):
            return 1.2
        default:
            return output == "h264" ? 2.0 : 1.5
        }
    }

    private static func bitrateForHeight(_ height: Int) -> Int {
        switch height {
        case 1801...:  return 16000   // 4K (2160p) 及以上
        case 1201...1800: return 10000 // 1440p
        case 901...1200:  return 6000  // 1080p
        case 601...900:   return 3000  // 720p
        default:          return 1500  // 480p 及以下
        }
    }

    private static func bitrateFloorForHeight(_ height: Int, outputCodec: String) -> Int {
        let output = normalizedVideoCodec(outputCodec) ?? outputCodec.lowercased()
        let hevc = output == "hevc"
        switch height {
        case 1801...:
            return hevc ? 8000 : 12000
        case 1201...1800:
            return hevc ? 5000 : 7000
        case 901...1200:
            return hevc ? 1800 : 3000
        case 601...900:
            return hevc ? 1000 : 1600
        default:
            return hevc ? 600 : 900
        }
    }

    /// 解析 -progress pipe:1 输出。out_time_ms 与 out_time_us 的值都是微秒。
    private static func parseProgress(line: String, totalSeconds: Double?) -> Double? {
        guard let total = totalSeconds, total > 0 else { return nil }
        for prefix in ["out_time_ms=", "out_time_us="] where line.hasPrefix(prefix) {
            let value = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            guard let microseconds = Double(value) else { return nil }
            return min(max((microseconds / 1_000_000) / total, 0), 1)
        }
        return nil
    }

    /// 转码用：定位任意可用的（带编码器的）ffmpeg。复用字幕渲染版定位（ffmpeg-full）。
    static func locateAnyFFmpeg() -> String? {
        locate("ffmpeg")
    }

    /// 转码用：解析 ffmpeg -progress 行的完成比例。
    static func parseProgressFraction(line: String, totalSeconds: Double?) -> Double? {
        parseProgress(line: line, totalSeconds: totalSeconds)
    }

    /// 转码用：探测时长（秒），用于进度换算。
    static func probeDurationSeconds(file: URL) async -> Double? {
        await probe(video: file).duration
    }

    /// 转码用：探测下载产物的实际动态范围。nil 表示 ffprobe 无法判断。
    static func probeVideoHDRStatus(file: URL) async -> Bool? {
        let result = await probe(video: file)
        if result.codecName == nil, result.width == nil, result.height == nil, result.colorTransfer == nil {
            return nil
        }
        return result.isHDR
    }

    /// 转码用：探测实际视频编码短名（h264/h265/vp9/av1…），让「已是目标编码」时走 remux 而非重编码。
    static func probeVideoCodec(file: URL) async -> String? {
        let raw = (await probe(video: file).codecName ?? "").lowercased()
        switch raw {
        case "hevc", "h265": return "h265"
        case "avc", "avc1", "h264": return "h264"
        case "": return nil
        default: return raw
        }
    }

    private static func lastLine(of stderr: String) -> String {
        let lines = stderr.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let fallback = CoreL10n.text(en: "Unknown error", zhHans: "未知错误", zhHant: "未知錯誤")
        return String((lines.last ?? fallback).prefix(200))
    }

    private static var libassMissingMessage: String {
        CoreL10n.text(
            en: "The current ffmpeg build does not include subtitle rendering (libass). Install the full build and retry: brew install ffmpeg-full",
            zhHans: "当前 ffmpeg 不带字幕渲染组件（libass）。请安装完整版后重试：brew install ffmpeg-full",
            zhHant: "目前 ffmpeg 不含字幕渲染元件（libass）。請安裝完整版後重試：brew install ffmpeg-full"
        )
    }

    // MARK: ASS 生成（双语两级字号，按视频长宽比自适应）

    private static let chineseFontSize = 13
    /// 原文字号相对译文字号的比例（不分语言，永远 80%）。
    private static let originalSizeRatio = 0.8
    /// 原文不透明度（80%）对应的 ASS alpha 十六进制（00=不透明，FF=全透明）。
    /// round((1-0.8)*255)=51=0x33。作用于 PrimaryColour 与描边/阴影（\alpha 整体变淡）。
    static let originalAlphaHex = "33"
    /// 中文译文不透明度（96%）对应的 ASS alpha 十六进制。round((1-0.96)*255)=10=0x0A。
    /// 只作用于译文字体填充（PrimaryColour）；黑色描边保持不透明以保可读性。
    static let chineseAlphaHex = "0A"

    /// 按视频长宽比推导的 ASS 布局参数。
    /// 字号按「高度的固定比例」调校（横屏 16:9 下译文 13/288≈4.5% 视频高，原文为其 80%）。
    /// 换行采用自动布局：左右只留最小边距（约画面 2.5%），只有真的放不下才换行。
    struct ASSLayout: Equatable {
        let playResX: Int
        let playResY = 288
        let chineseSize: Int
        let originalSize: Int
        let marginH: Int
        let marginV: Int
        /// 中文行预换行容量（字符数）；nil 表示不预换行（交给 libass）。
        let cjkWrapCapacity: Int?
        /// 原文若为 CJK 文字（日/韩）的按字预换行容量（按更小的 originalSize 算）；nil 表示不预换行。
        let originalCJKWrapCapacity: Int?
        /// 原文（英文等拉丁文字）行按词预换行容量（字符数）；nil 表示不预换行。
        let latinWrapCapacity: Int?

        init(aspect: Double) {
            let safeAspect = aspect.isFinite && aspect > 0.1 ? min(aspect, 4.0) : 16.0 / 9.0
            // 脚本坐标系与视频同比例（取偶数），横向边距/字号的单位才不会被拉伸
            playResX = max(120, Int((288.0 * safeAspect / 2).rounded()) * 2)
            if safeAspect >= 1 {
                chineseSize = Self.baseChinese
            } else {
                let scale = (safeAspect / (16.0 / 9.0)).squareRoot()
                chineseSize = max(8, Int((Double(Self.baseChinese) * scale).rounded()))
            }
            // 原文字号永远是译文的 80%（不分语言）。
            originalSize = max(6, Int((Double(chineseSize) * Self.originalSizeRatio).rounded()))
            // 自动布局：左右只留一个最小边距（约画面 2.5%），不再按「舒适阅读宽度」强行收窄。
            // 只有真的放不下时才换行（容量按可用宽度 / 字宽推算）。
            marginV = 20
            marginH = max(5, Int((Double(playResX) * 0.025).rounded()))
            let usableWidth = Double(playResX - marginH * 2)
            // 中文（含日韩等 CJK 文字）按字宽≈1em：容量 = 可用宽度 / 字号。
            let cjkCapacity = Int(usableWidth / Double(max(chineseSize, 1)))
            cjkWrapCapacity = cjkCapacity >= 6 ? cjkCapacity : nil
            // 原文若是 CJK 文字（日/韩），按 originalSize 的字宽算容量（字更小、容得更多）。
            let originalCJK = Int(usableWidth / Double(max(originalSize, 1)))
            originalCJKWrapCapacity = originalCJK >= 6 ? originalCJK : nil
            // 原文（拉丁）按词换行容量：拉丁字形平均宽约为字号的 0.55em（含大写/空格的保守上界）。
            // WrapStyle:2 下没有 libass 兜底换行，容量保守以防整行溢出画面。
            let latinCapacity = Int(usableWidth / (Double(originalSize) * 0.55))
            latinWrapCapacity = latinCapacity >= 12 ? latinCapacity : nil
        }

        private static let baseChinese = FFmpegBurner.chineseFontSize
        private static let originalSizeRatio = FFmpegBurner.originalSizeRatio
    }

    /// 把 SRT 字幕转成 ASS：双语条目（首行含中日韩文字、其余行不含）首行用正常字号，
    /// 其余行（原文）用更小字号；普通条目整条统一字号。aspect = 视频宽/高。
    static func makeASS(cues: [SubtitleCue], aspect: Double = 16.0 / 9.0) -> String {
        let layout = ASSLayout(aspect: aspect)
        var dialogues: [String] = []
        for cue in cues {
            guard let start = assTimestamp(cue.start), let end = assTimestamp(cue.end) else {
                continue
            }
            let lines = cue.text
                .components(separatedBy: "\n")
                .map(escapeASSText)
                .filter { !$0.isEmpty }
            guard !lines.isEmpty else { continue }

            // 双语条目：简体中文译文排上面（正常字号），原文排下面（80% 字号 + 80% 不透明度）。
            // 判据是「简体中文」而非「含 CJK」：日文（假名）、韩文（谚文）也含 CJK 区字符，
            // 若按含 CJK 归类会把日韩原文误判成译文、用满字号且不缩小。
            // 简体中文 = 含汉字且不含假名/谚文。
            let text: String
            let zhLines = lines.filter(Self.isSimplifiedChineseLine)
                .flatMap { line -> [String] in
                    guard let capacity = layout.cjkWrapCapacity else { return [line] }
                    return wrapCJKLine(line, capacity: capacity)
                }
            // 原文行（非简体中文）：可能是拉丁文字（按词折行）或 CJK 文字（日韩，按字折行）。
            // 源 SRT 常把一句拆成多碎行，先合并再按目标容量重排。
            let rawOtherLines = lines.filter { !Self.isSimplifiedChineseLine($0) }
            let otherLines = Self.wrapOriginalLines(rawOtherLines, layout: layout)
            if !zhLines.isEmpty, !otherLines.isEmpty {
                // 原文整体（字+描边）淡到 80% 不透明：\alpha 同时作用于 Primary/Outline/Back。
                text = zhLines.joined(separator: "\\N")
                    + "\\N{\\fs\(layout.originalSize)\\alpha&H\(Self.originalAlphaHex)&}"
                    + otherLines.joined(separator: "\\N")
            } else if !zhLines.isEmpty {
                text = zhLines.joined(separator: "\\N")
            } else {
                // 纯原文（无中文译文）条目：用原文字号显示（仍折行，避免溢出/乱断）。
                text = "{\\fs\(layout.originalSize)}" + otherLines.joined(separator: "\\N")
            }
            dialogues.append("Dialogue: 0,\(start),\(end),ZH,,0,0,0,,\(text)")
        }

        let header = """
        [Script Info]
        ScriptType: v4.00+
        PlayResX: \(layout.playResX)
        PlayResY: \(layout.playResY)
        WrapStyle: 2
        ScaledBorderAndShadow: yes

        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: ZH,\(chineseFontName),\(layout.chineseSize),&H\(chineseAlphaHex)FFFFFF,&H00FFFFFF,&H00000000,&H7F000000,0,0,0,0,100,100,0,0,1,1,0,2,\(layout.marginH),\(layout.marginH),\(layout.marginV),1

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        """
        return header + "\n" + dialogues.joined(separator: "\n") + "\n"
    }

    /// 超过容量的中文行均衡预换行：行数取最少、各行长度尽量接近；
    /// 切点优先标点之后 > 空格处 > 任意中日韩字界（绝不切进英文单词/数字中间）。
    static func wrapCJKLine(_ line: String, capacity: Int) -> [String] {
        let chars = Array(line)
        guard capacity >= 6, chars.count > capacity else { return [line] }
        let lineCount = Int((Double(chars.count) / Double(capacity)).rounded(.up))
        let target = Int((Double(chars.count) / Double(lineCount)).rounded(.up))
        var result: [String] = []
        var start = 0
        while chars.count - start > capacity {
            let idealEnd = min(start + target, chars.count - 1)
            // 在理想切点前后各 6 个字符内找切点（切点 = 新行的起点下标），
            // 上限不超过容量保证本行装得下；同级里取离理想点最近的。
            let low = max(start + 1, idealEnd - 6)
            let high = min(start + capacity, min(idealEnd + 6, chars.count - 1))
            var bestPunct: Int?
            var bestSpace: Int?
            var bestCJKBoundary: Int?
            func better(_ current: Int?, _ candidate: Int) -> Int {
                guard let current else { return candidate }
                return abs(candidate - idealEnd) < abs(current - idealEnd) ? candidate : current
            }
            for i in low...high {
                let prev = chars[i - 1]
                if Self.cjkBreakAfter.contains(prev) {
                    bestPunct = better(bestPunct, i)
                } else if prev == " " || chars[i] == " " {
                    bestSpace = better(bestSpace, i)
                } else if isCJKChar(prev) || isCJKChar(chars[i]) {
                    bestCJKBoundary = better(bestCJKBoundary, i)
                }
            }
            let cut = bestPunct ?? bestSpace ?? bestCJKBoundary ?? idealEnd
            let piece = String(chars[start..<cut]).trimmingCharacters(in: .whitespaces)
            if !piece.isEmpty { result.append(piece) }
            start = cut
            // 跳过切点处的空格，避免新行以空格开头
            while start < chars.count, chars[start] == " " { start += 1 }
        }
        let last = String(chars[start...]).trimmingCharacters(in: .whitespaces)
        if !last.isEmpty { result.append(last) }
        return result.isEmpty ? [line] : result
    }

    /// 切行时允许出现在行尾的标点（其后断行不破坏语感）。
    private static let cjkBreakAfter: Set<Character> = [
        "，", "。", "！", "？", "、", "；", "：", "…", ",", ".", "!", "?", ";", ":",
    ]

    /// 原文（拉丁文字）按词折行：超过容量才折，按空格断词（绝不切进单词中间），
    /// 行数取最少、并均衡各行长度，避免末行只剩一两个词的难看断行。
    static func wrapLatinLine(_ line: String, capacity: Int) -> [String] {
        let collapsed = line.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .map(String.init)
        guard capacity >= 12, !collapsed.isEmpty else { return [line] }
        let fullText = collapsed.joined(separator: " ")
        guard fullText.count > capacity else { return [fullText] }
        // 目标行数：按容量向上取整；均衡目标行宽，行宽上限仍是 capacity。
        let lineCount = max(1, Int((Double(fullText.count) / Double(capacity)).rounded(.up)))
        let target = min(capacity, Int((Double(fullText.count) / Double(lineCount)).rounded(.up)))
        var result: [String] = []
        var current = ""
        for word in collapsed {
            if current.isEmpty {
                current = word
                continue
            }
            let candidate = current + " " + word
            // 已达到均衡目标且仍有余下单词时换行；硬上限为 capacity（单词本身超长则独占一行）。
            if candidate.count > capacity || (candidate.count > target && result.count < lineCount - 1) {
                result.append(current)
                current = word
            } else {
                current = candidate
            }
        }
        if !current.isEmpty { result.append(current) }
        return result.isEmpty ? [fullText] : result
    }

    /// "00:01:02,500" → "0:01:02.50"（ASS 用厘秒）
    private static func assTimestamp(_ srt: String) -> String? {
        let normalized = srt.replacingOccurrences(of: ",", with: ".")
        let parts = normalized.split(separator: ":")
        guard parts.count == 3,
              let h = Int(parts[0]),
              let m = Int(parts[1]) else { return nil }
        let secParts = parts[2].split(separator: ".")
        guard let s = Int(secParts.first ?? ""), s < 60, m < 60 else { return nil }
        let msString = secParts.count > 1 ? String(secParts[1].prefix(3)) : "0"
        let ms = Int(msString.padding(toLength: 3, withPad: "0", startingAt: 0)) ?? 0
        return String(format: "%d:%02d:%02d.%02d", h, m, s, ms / 10)
    }

    private static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: isCJKScalar)
    }

    private static func isCJKChar(_ character: Character) -> Bool {
        character.unicodeScalars.contains(where: isCJKScalar)
    }

    private static func isCJKScalar(_ scalar: Unicode.Scalar) -> Bool {
        (0x4E00...0x9FFF).contains(scalar.value)        // CJK 统一表意
            || (0x3400...0x4DBF).contains(scalar.value) // 扩展 A
            || (0x3040...0x30FF).contains(scalar.value) // 日文假名
            || (0xAC00...0xD7AF).contains(scalar.value) // 谚文
    }

    /// 日文假名（平假名/片假名）。
    private static func hasKana(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) }
    }

    /// 朝鲜文谚文音节/字母。
    private static func hasHangul(_ text: String) -> Bool {
        text.unicodeScalars.contains {
            (0xAC00...0xD7AF).contains($0.value) || (0x1100...0x11FF).contains($0.value)
        }
    }

    /// 汉字（CJK 统一表意，含扩展 A）。
    private static func hasHan(_ text: String) -> Bool {
        text.unicodeScalars.contains {
            (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value)
        }
    }

    /// 是否「简体中文译文行」：含汉字且不含假名/谚文。
    /// 译文恒为简体中文（含汉字、无假名/谚文）；日文必含假名、韩文必含谚文，据此与原文区分，
    /// 避免日韩原文（也落在 CJK 区）被误判成译文而用满字号、不缩小。
    static func isSimplifiedChineseLine(_ text: String) -> Bool {
        hasHan(text) && !hasKana(text) && !hasHangul(text)
    }

    /// 折行原文（非简体中文）：CJK 文字（日/韩）按字折行，拉丁文字按词折行。
    /// 先把源 SRT 的碎行合并，再按对应容量重排；无可用容量时原样返回（交给 libass）。
    static func wrapOriginalLines(_ rawLines: [String], layout: ASSLayout) -> [String] {
        guard !rawLines.isEmpty else { return [] }
        let isCJKText = rawLines.contains { hasKana($0) || hasHangul($0) || hasHan($0) }
        if isCJKText {
            // 日韩等无空格 CJK 原文：合并后按字折行（容量按更小的原文字号算）。
            let joined = rawLines.joined()
            guard let capacity = layout.originalCJKWrapCapacity else { return [joined] }
            return wrapCJKLine(joined, capacity: capacity)
        }
        // 拉丁原文：合并后按词折行。
        let joined = rawLines.joined(separator: " ")
        guard let capacity = layout.latinWrapCapacity else { return [joined] }
        return wrapLatinLine(joined, capacity: capacity)
    }

    /// ASS 文本里 {} 是样式覆盖块定界符，替换为全角避免被解析
    private static func escapeASSText(_ line: String) -> String {
        line.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "{", with: "｛")
            .replacingOccurrences(of: "}", with: "｝")
            .replacingOccurrences(of: "\\", with: "＼")
    }
}
