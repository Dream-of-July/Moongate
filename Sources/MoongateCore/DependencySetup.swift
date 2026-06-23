import Foundation

#if !os(Windows)
/// macOS 依赖体检与一键安装支持：缺 yt-dlp/ffmpeg/deno 时 GUI 弹引导，
/// 经 Homebrew 安装；Homebrew 不存在时引导用户先装（绝不静默 curl|bash）。
public enum DependencySetup {

    public struct Component: Identifiable, Equatable {
        /// 展示名 = 二进制名
        public let id: String
        /// brew 公式名
        public let formula: String
        /// 一句话用途
        public let purpose: String
        public let isInstalled: Bool
        /// 是否属于普通下载链路的必需组件；本地 whisper.cpp 是可选能力，不阻塞 onboarding。
        public let isRequired: Bool
    }

    /// 依赖体检。ffmpeg 与 Burner 同口径：必须带 subtitles/libass 渲染能力；
    /// JS 运行时 deno/node 任一即可（yt-dlp 解 YouTube n-challenge 需要）。
    /// whisper.cpp 为本地 ASR 可选组件，不阻塞普通下载。
    public static func check() -> [Component] {
        components(
            ytDlpInstalled: find("yt-dlp") != nil,
            subtitleRendererFfmpegInstalled: FFmpegBurner.locateSubtitleRendererFFmpeg() != nil,
            jsRuntimeInstalled: find("deno") != nil || find("node") != nil,
            localWhisperInstalled: ASRRuntimeLocator(
                extraSearchURLs: localASRRuntimeSearchURLs()
            ).locate() != nil || find("whisper-cli") != nil
        )
    }

    internal static func components(
        ytDlpInstalled: Bool,
        subtitleRendererFfmpegInstalled: Bool,
        jsRuntimeInstalled: Bool,
        localWhisperInstalled: Bool = false
    ) -> [Component] {
        [
            Component(
                id: "yt-dlp", formula: "yt-dlp",
                purpose: CoreL10n.t(L.Dependency.purposeYtDlp),
                isInstalled: ytDlpInstalled,
                isRequired: true
            ),
            Component(
                id: "ffmpeg", formula: "ffmpeg-full",
                purpose: CoreL10n.t(L.Dependency.purposeFfmpeg),
                isInstalled: subtitleRendererFfmpegInstalled,
                isRequired: true
            ),
            Component(
                id: "deno", formula: "deno",
                purpose: CoreL10n.t(L.Dependency.purposeDeno),
                isInstalled: jsRuntimeInstalled,
                isRequired: true
            ),
            Component(
                id: "whisper-cli", formula: "whisper-cpp",
                purpose: CoreL10n.t(L.Dependency.purposeWhisperCpp),
                isInstalled: localWhisperInstalled,
                isRequired: false
            ),
        ]
    }

    public static func missing(from components: [Component]) -> [Component] {
        components.filter { !$0.isInstalled }
    }

    public static func missingRequired(from components: [Component]) -> [Component] {
        components.filter { $0.isRequired && !$0.isInstalled }
    }

    public static func missingOptional(from components: [Component]) -> [Component] {
        components.filter { !$0.isRequired && !$0.isInstalled }
    }

    public static func needsSetup(_ components: [Component]) -> Bool {
        !missingRequired(from: components).isEmpty
    }

    public static var missing: [Component] { missingRequired(from: check()) }

    /// Homebrew 可执行路径（Apple Silicon / Intel 双位置）。
    public static func brewPath() -> String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func find(_ name: String) -> String? {
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] {
            let path = dir + "/" + name
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    private static func localASRRuntimeSearchURLs() -> [URL] {
        let runtimeURL = AppSettings.supportDirectory
            .appendingPathComponent("asr", isDirectory: true)
            .appendingPathComponent("runtime", isDirectory: true)
        var urls = [
            runtimeURL,
            runtimeURL.appendingPathComponent("bin", isDirectory: true),
        ]
        if let bundledRuntimeURL = Bundle.main.resourceURL?
            .appendingPathComponent("asr", isDirectory: true)
            .appendingPathComponent("runtime", isDirectory: true) {
            urls.append(bundledRuntimeURL)
            urls.append(bundledRuntimeURL.appendingPathComponent("bin", isDirectory: true))
        }
        return urls
    }
}
#endif
