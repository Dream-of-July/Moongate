import Foundation
import MoongateMobileCore

// MARK: - 错误

public enum MoongateError: LocalizedError, Sendable {
    case binaryNotFound(String)
    case sniffFailed(String)
    case analyzeFailed(String)
    case updateFailed(String)
    case downloadFailed(String)
    /// 站点风控/会员限制，需要用户在 App 内登录该站点后重试。关联值为站点 host（如 "youtube.com"）。
    case loginRequired(String)
    case translateFailed(String)
    case burnFailed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .binaryNotFound(let name):
            return CoreL10n.t(L.Core.errorBinaryNotFound, name, name)
        case .sniffFailed(let reason):
            return CoreL10n.t(L.Core.errorSniffFailed, reason)
        case .analyzeFailed(let reason):
            return CoreL10n.t(L.Core.errorAnalyzeFailed, reason)
        case .updateFailed(let reason):
            return CoreL10n.t(L.Core.errorUpdateFailed, reason)
        case .downloadFailed(let reason):
            return CoreL10n.t(L.Core.errorDownloadFailed, reason)
        case .loginRequired(let site):
            return CoreL10n.t(L.Core.errorLoginRequired, site)
        case .translateFailed(let reason):
            return CoreL10n.t(L.Core.errorTranslateFailed, reason)
        case .burnFailed(let reason):
            return CoreL10n.t(L.Core.errorBurnFailed, reason)
        case .cancelled:
            return CoreL10n.t(L.Core.errorCancelled)
        }
    }
}

// MARK: - 链接解析候选

/// 一条用户粘贴的链接背后可能藏着多个视频（例如页面主视频 + 内嵌的 YouTube 轮播）。
/// `resolveCandidates` 把它们全部找出来，交给用户选择。
public struct VideoCandidate: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable {
        case pageMain    // 页面的主视频（直链文件等）
        case directFile  // 直链视频文件（mp4 / m3u8 / webm …）
        case youtube     // 内嵌 YouTube 视频
        case vimeo       // 内嵌 Vimeo 视频
        case supported   // yt-dlp 原生支持的链接（无需嗅探）
    }

    /// 稳定标识：解析后的最终 URL 字符串
    public var id: String { url }
    /// 交给 `analyze(url:)` 的 URL
    public let url: String
    public let kind: Kind
    /// 尽力获取的标题（YouTube 走 oEmbed；直链用文件名；主视频用页面标题）
    public var title: String
    /// 补充说明，例如 "assets.nintendo.com · mp4 直链" 或 "YouTube"
    public var detail: String?

    public init(url: String, kind: Kind, title: String, detail: String? = nil) {
        self.url = url
        self.kind = kind
        self.title = title
        self.detail = detail
    }
}

// MARK: - 解析结果

/// 视频动态范围。来自 yt-dlp 的 dynamic_range 字段。
public enum DynamicRange: String, Codable, Sendable, Equatable, CaseIterable {
    case sdr
    case hdr10
    case dolbyVision

    /// 从 yt-dlp dynamic_range 字符串解析（SDR/HDR/HDR10/HDR10+/DV/Dolby Vision 等）。
    public init(ytDlpValue raw: String?) {
        let v = (raw ?? "").uppercased()
        if v.contains("DV") || v.contains("DOLBY") {
            self = .dolbyVision
        } else if v.contains("HDR") {
            self = .hdr10
        } else {
            self = .sdr
        }
    }

    public var isHDR: Bool { self != .sdr }

    /// UI 短标签。
    public var badge: String? {
        switch self {
        case .sdr: return nil
        case .hdr10: return "HDR"
        case .dolbyVision: return CoreL10n.t(L.Core.dolbyVisionBadge)
        }
    }
}

/// 下载后输出格式（用户在选分辨率页选择）。original = 保持源，不转码。
public enum OutputFormat: String, Codable, Sendable, Equatable, CaseIterable {
    case original
    case mp4H264
    case mp4H265
    case mkv

    public var displayName: String {
        switch self {
        case .original: return CoreL10n.t(L.Core.outputOriginal)
        case .mp4H264: return CoreL10n.t(L.Core.outputH264)
        case .mp4H265: return CoreL10n.t(L.Core.outputH265)
        case .mkv: return CoreL10n.t(L.Core.outputMKV)
        }
    }
}

public struct FormatChoice: Identifiable, Hashable, Sendable {
    /// yt-dlp 的 -f 格式选择串（例如 "bv*[height<=720]+ba/b[height<=720]"），
    /// 音频选项用特殊值 "audio"（引擎据此改用 -x 提取音频）。
    public let id: String
    /// 例如 "1080p · mp4" / "原始文件 · mp4" / "仅音频 · m4a"
    public let label: String
    /// 例如 "≈ 42 MB"、编码信息；未知则为 nil
    public let detail: String?
    public let isAudioOnly: Bool
    /// 该档是否有 HDR 源可选（同分辨率下存在 HDR 流）。
    public let hdrAvailable: Bool
    /// 源视频编码简称（如 "vp9"/"av1"/"h264"），用于转码决策与标注；未知为 nil。
    public let sourceVCodec: String?
    /// 源容器扩展名（如 "webm"/"mp4"）；未知为 nil。
    public let sourceContainer: String?

    public init(
        id: String,
        label: String,
        detail: String? = nil,
        isAudioOnly: Bool = false,
        hdrAvailable: Bool = false,
        sourceVCodec: String? = nil,
        sourceContainer: String? = nil
    ) {
        self.id = id
        self.label = label
        self.detail = detail
        self.isAudioOnly = isAudioOnly
        self.hdrAvailable = hdrAvailable
        self.sourceVCodec = sourceVCodec
        self.sourceContainer = sourceContainer
    }
}

public struct SubtitleChoice: Identifiable, Hashable, Sendable {
    /// 语言代码，如 "en"、"zh-Hans"
    public let id: String
    /// 中文展示名，如 "英文 (en)"
    public let label: String
    /// 是否为自动生成字幕（YouTube 自动字幕等）
    public let isAuto: Bool

    public init(id: String, label: String, isAuto: Bool) {
        self.id = id
        self.label = label
        self.isAuto = isAuto
    }
}

public struct VideoInfo: Sendable {
    public let sourceURL: String
    /// yt-dlp 信息里的视频 id（用于定位产出文件）
    public let videoID: String
    public let title: String
    /// 形如 "2:31"；未知为 nil
    public let durationText: String?
    public let thumbnailURL: URL?
    public let uploader: String?
    /// 视频简介（yt-dlp description）；无简介为 nil。用于 AI 总结的回退数据源。
    public let description: String?
    /// 按推荐顺序排列（第一个为推荐档），保证至少一个元素
    public let formats: [FormatChoice]
    /// 真实字幕在前、自动字幕在后；可能为空
    public let subtitles: [SubtitleChoice]

    public init(
        sourceURL: String, videoID: String, title: String,
        durationText: String?, thumbnailURL: URL?, uploader: String?,
        description: String? = nil,
        formats: [FormatChoice], subtitles: [SubtitleChoice]
    ) {
        self.sourceURL = sourceURL
        self.videoID = videoID
        self.title = title
        self.durationText = durationText
        self.thumbnailURL = thumbnailURL
        self.uploader = uploader
        self.description = description
        self.formats = formats
        self.subtitles = subtitles
    }
}

// MARK: - 下载

public struct DownloadRequest: Sendable {
    public let url: String
    /// 视频 id（来自 VideoInfo.videoID），用于在目标目录中识别产出文件
    public let videoID: String
    /// FormatChoice.id
    public let formatID: String
    /// 选中的真实字幕语言代码
    public let subtitleLangs: [String]
    /// 选中的自动字幕语言代码
    public let autoSubtitleLangs: [String]
    public let destinationDirectory: URL
    /// 期望的文件名标题。直链/页面主视频的 yt-dlp 标题往往是 CDN 文件名
    /// （如 "homepage_trailer"），此时用嗅探得到的页面标题命名更友好；nil 用 yt-dlp 默认标题。
    public let preferredTitle: String?
    /// 是否优先下载 HDR 流（仅当该档有 HDR 源时有意义）。
    public let preferHDR: Bool
    /// 下载后输出格式；.original 表示不转码（HDR 默认 mkv 封装，SDR 默认 mp4）。
    public let outputFormat: OutputFormat

    public init(
        url: String, videoID: String, formatID: String,
        subtitleLangs: [String], autoSubtitleLangs: [String],
        destinationDirectory: URL, preferredTitle: String? = nil,
        preferHDR: Bool = false, outputFormat: OutputFormat = .original
    ) {
        self.url = url
        self.videoID = videoID
        self.formatID = formatID
        self.subtitleLangs = subtitleLangs
        self.autoSubtitleLangs = autoSubtitleLangs
        self.destinationDirectory = destinationDirectory
        self.preferredTitle = preferredTitle
        self.preferHDR = preferHDR
        self.outputFormat = outputFormat
    }
}

public struct DownloadProgress: Sendable {
    public enum Phase: Sendable, Equatable {
        case preparing      // 启动 yt-dlp、握手中
        case downloading    // 主体下载
        case processing     // 合并 / 转码 / 字幕转换
        case finished
    }

    public let phase: Phase
    /// 0...100；未知为 nil
    public let percent: Double?
    public let speedText: String?
    public let etaText: String?
    /// 处理阶段的具体说明（如「正在合并音视频」「正在转码」）；未知为 nil。
    public let detail: String?

    public init(phase: Phase, percent: Double? = nil, speedText: String? = nil, etaText: String? = nil, detail: String? = nil) {
        self.phase = phase
        self.percent = percent
        self.speedText = speedText
        self.etaText = etaText
        self.detail = detail
    }
}

public struct DownloadResult: Sendable {
    /// 实际写入磁盘的文件（视频 + 字幕）
    public let files: [URL]

    public init(files: [URL]) {
        self.files = files
    }
}

// MARK: - 字幕翻译与烧录

/// 烧录/输出字幕的样式
public enum SubtitleStyle: String, Codable, Sendable {
    /// 原文在上、中文在下
    case bilingual
    /// 仅中文
    case chineseOnly
}

/// 细粒度源字幕片段。YouTube VTT 自动字幕常带词级时间戳，清洗器用它来判断字幕真正应在何时出现/消失。
public struct SubtitleCueSourceFragment: Sendable {
    public let startSeconds: Double
    public let endSeconds: Double
    public let text: String

    public init(startSeconds: Double, endSeconds: Double, text: String) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.text = text
    }
}

/// 一条 SRT 字幕
public struct SubtitleCue: Sendable {
    public let index: Int
    /// SRT 原始时间戳，如 "00:01:02,500"
    public let start: String
    public let end: String
    public var text: String
    public var sourceFragments: [SubtitleCueSourceFragment]

    public init(
        index: Int,
        start: String,
        end: String,
        text: String,
        sourceFragments: [SubtitleCueSourceFragment] = []
    ) {
        self.index = index
        self.start = start
        self.end = end
        self.text = text
        self.sourceFragments = sourceFragments
    }
}

/// 字幕翻译器。默认实现 `ConfiguredTranslator`（Translator.swift）：
/// 按设置选择 Anthropic/DeepSeek Messages API 或 OpenAI Responses API 调用配置的模型。
/// 用 `makeTranslator(settings:)` 获取实例。
public protocol SubtitleTranslator: Sendable {
    /// 把 srt 文件翻译成中文，按 style 生成新 srt（双语：中文在上原文在下；仅中文：替换原文），
    /// 写到 srt 同目录、文件名加 ".zh" 后缀；progress 为 0...1。
    /// YouTube 自动字幕的重叠滚动碎句会先被清洗、按句合并再翻译。
    /// control 非空时支持暂停（分块间挂起）与取消；失败抛 MoongateError.translateFailed。
    func translate(
        srtFile: URL,
        style: SubtitleStyle,
        control: TaskControlToken?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL
}

public protocol ContextualSubtitleTranslator: SubtitleTranslator {
    func translate(
        srtFile: URL,
        style: SubtitleStyle,
        context: TranslationContext,
        control: TaskControlToken?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL
}

public extension SubtitleTranslator {
    func translate(
        srtFile: URL,
        style: SubtitleStyle,
        context: TranslationContext,
        control: TaskControlToken?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        if let translator = self as? any ContextualSubtitleTranslator {
            return try await translator.translate(
                srtFile: srtFile,
                style: style,
                context: context,
                control: control,
                progress: progress
            )
        }
        return try await translate(
            srtFile: srtFile,
            style: style,
            control: control,
            progress: progress
        )
    }

    func translate(
        srtFile: URL,
        style: SubtitleStyle,
        context: TranslationContext,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        try await translate(
            srtFile: srtFile,
            style: style,
            context: context,
            control: nil,
            progress: progress
        )
    }

    func translate(
        srtFile: URL,
        style: SubtitleStyle,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        try await translate(srtFile: srtFile, style: style, control: nil, progress: progress)
    }
}

public extension ContextualSubtitleTranslator {
    func translate(
        srtFile: URL,
        style: SubtitleStyle,
        control: TaskControlToken?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        try await translate(
            srtFile: srtFile,
            style: style,
            context: TranslationContext(),
            control: control,
            progress: progress
        )
    }
}

/// 字幕烧录器。默认实现 `FFmpegBurner`（Burner.swift）：ffmpeg subtitles 滤镜硬烧录。
/// 用 `makeBurner()` 获取实例。
public protocol SubtitleBurner: Sendable {
    /// 把 subtitle 烧录进 video，输出 "<原名>（字幕版).mp4" 风格的新文件（不覆盖原片）；
    /// outputTag 非空时自定义文件名标签，例如直压原字幕模式用 "（字幕版）"。
    /// maxHeight 非空且源更高时缩放到该高度；progress 为 0...1。
    /// backend 决定用硬件（VideoToolbox）还是软件编码器；alwaysH264=true 时无视源编码强制 H.264（兼容优先）。
    /// control 非空时支持暂停/取消（向 ffmpeg 进程树发 SIGSTOP/SIGCONT、取消时终止）。
    /// 失败抛 MoongateError.burnFailed。
    func burn(
        video: URL,
        subtitle: URL,
        maxHeight: Int?,
        backend: EncodeBackend,
        alwaysH264: Bool,
        control: TaskControlToken?,
        outputTag: String?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL
}

public extension SubtitleBurner {
    func burn(
        video: URL,
        subtitle: URL,
        maxHeight: Int?,
        backend: EncodeBackend = .auto,
        alwaysH264: Bool = false,
        control: TaskControlToken?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        try await burn(
            video: video, subtitle: subtitle,
            maxHeight: maxHeight, backend: backend, alwaysH264: alwaysH264,
            control: control, outputTag: nil,
            progress: progress
        )
    }

    func burn(
        video: URL,
        subtitle: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        try await burn(
            video: video, subtitle: subtitle,
            maxHeight: nil, backend: .auto, alwaysH264: false,
            control: nil, outputTag: nil,
            progress: progress
        )
    }
}

// MARK: - 引擎协议

/// 三步流水线：resolve（一条链接里找出所有视频）→ analyze（取格式与字幕）→ download。
/// 实现位于 Engine.swift 的 `YtDlpEngine`；用 `makeDefaultEngine()` 获取默认实例。
public protocol DownloadEngine: Sendable {
    /// 第一步：解析用户粘贴的链接。
    /// - yt-dlp 原生支持的 URL：直接返回单个 `.supported` 候选（不发起网络请求也可以）。
    /// - 不支持的页面：抓取 HTML 嗅探内嵌视频（og:video、video/source 标签、
    ///   YouTube/Vimeo iframe、data-videoid、裸 mp4/m3u8 链接等），返回带标题的候选列表。
    /// - 一个都找不到时抛 `MoongateError.sniffFailed`。
    func resolveCandidates(for input: String) async throws -> [VideoCandidate]

    /// 第二步：完整解析单个候选，返回格式与字幕选项。
    /// 实现可以缓存第一步已经取得的信息避免重复请求。
    func analyze(url: String) async throws -> VideoInfo

    /// 第三步：按用户选择下载。进度经回调上报（任意线程）；
    /// control 非空时支持暂停（SIGSTOP/SIGCONT 进程树）与取消；
    /// 也可通过 Swift 任务取消中止，引擎需负责终止子进程、不留僵尸进程。
    func download(
        _ request: DownloadRequest,
        control: TaskControlToken?,
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> DownloadResult

    /// 可选：只取字幕文本（不下载视频），用于 AI 内容总结。
    /// 最佳努力：没有字幕或站点不支持时返回 nil，绝不抛错阻断总结流程。
    func fetchSubtitleText(
        url: String,
        preferredLanguages: [String],
        control: TaskControlToken?
    ) async throws -> String?
}

public extension DownloadEngine {
    func download(
        _ request: DownloadRequest,
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> DownloadResult {
        try await download(request, control: nil, progress: progress)
    }

    /// 默认不支持字幕文本抓取（mock/iOS 引擎）；返回 nil 让总结回退到简介。
    func fetchSubtitleText(
        url: String,
        preferredLanguages: [String],
        control: TaskControlToken?
    ) async throws -> String? {
        nil
    }
}
