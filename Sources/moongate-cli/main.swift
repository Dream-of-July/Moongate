#if canImport(MoongateCore)
import MoongateCore
#endif
import Foundation

#if canImport(Security)
AppSettings.credentialStore = KeychainCredentialStore()
#endif

// MARK: - 输出辅助

func printErr(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

let usageText = """
用法：
  moongate-cli resolve <url>
  moongate-cli analyze <url>
  moongate-cli download <url> --video-id <id> --format <formatID> \
[--subs en,zh] [--auto-subs en] [--dest 路径]
  moongate-cli translate <srt路径> [--style bilingual|zh] [--provider anthropic|openai] [--engine 引擎] [--base 服务地址] [--model 模型] [--token 凭证]
  moongate-cli clean-srt <srt路径>          （只清洗不翻译，输出 <名>.clean.srt，便于检查清洗效果）
  moongate-cli local-asr-srt --asr-words <json> --language <lang> --out <srt路径> [--file-name <原视频名>] [--timing-profile speech|lyrics|japaneseLyrics|anime] [--silencedetect-log <ffmpeg日志>]
  moongate-cli burn <视频> <srt> [--max-height N | --keep-resolution]
  moongate-cli ping-llm [--provider anthropic|openai] [--engine 引擎] [--base 服务地址] [--model 模型] [--token 凭证]

说明：
  --provider/--engine/--base/--model/--token 缺省读 App 设置；--token 仅供本机调试，输出时只显示前 6 位。
  --engine 支持 \(TranslationEngine.supportedCLIValues.joined(separator: " / "))。
  公司 Claude 网关通常用 --provider anthropic --base "$ANTHROPIC_BASE_URL" --token "$ANTHROPIC_AUTH_TOKEN"。
  burn 默认保持源分辨率；--max-height N 可显式限制高度，--keep-resolution 强制保持源分辨率。
  local-asr-srt 的 --asr-words 支持 Moongate words JSON，也支持 whisper.cpp 原始 JSON。
"""

func splitLangs(_ value: String) -> [String] {
    value.split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
}

struct ASRWordsJSON: Decodable {
    struct Word: Decodable {
        let start: Double
        let end: Double
        let text: String
        let probability: Double?

        private enum CodingKeys: String, CodingKey {
            case start
            case end
            case text
            case probability
        }
    }

    let language: String?
    let words: [Word]
}

func loadLocalASRTranscript(
    wordsJSON: URL,
    requestedLanguageCode: String,
    transcriptID: String
) throws -> ASRTranscript {
    let data = try Data(contentsOf: wordsJSON)
    let language = requestedLanguageCode.trimmingCharacters(in: .whitespacesAndNewlines)
    if let payload = try? JSONDecoder().decode(ASRWordsJSON.self, from: data) {
        return ASRTranscript(
            id: transcriptID,
            languageCode: language.isEmpty ? (payload.language ?? "und") : language,
            durationSeconds: nil,
            words: payload.words.map {
                ASRWord(
                    text: $0.text,
                    startSeconds: $0.start,
                    endSeconds: $0.end,
                    probability: $0.probability
                )
            },
            sourceModelID: "subtitle_timing_eval"
        )
    }

    let request = ASRRequest(
        audioURL: wordsJSON,
        languageCode: language.isEmpty ? nil : language,
        modelID: "whisper.cpp:raw-json"
    )
    return try WhisperCppJSONTranscriptParser().parse(
        data: data,
        request: request,
        transcriptID: transcriptID
    )
}

func writeLocalASRSRT(
    wordsJSON: URL,
    languageCode: String,
    outputURL: URL,
    fileName: String? = nil,
    audioActivity: ASRAudioActivity? = nil,
    timingProfile: SubtitleTimingProfile? = nil
) throws {
    let transcript = try loadLocalASRTranscript(
        wordsJSON: wordsJSON,
        requestedLanguageCode: languageCode,
        transcriptID: outputURL.deletingPathExtension().lastPathComponent
    )
    let cues: [SubtitleCue]
    if let timingProfile {
        cues = ASRTranscriptMapper.sourceCues(from: transcript, profile: timingProfile, audioActivity: audioActivity)
    } else if let fileName, !fileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        cues = ASRTranscriptMapper.sourceCues(from: transcript, fileName: fileName, audioActivity: audioActivity)
    } else {
        cues = ASRTranscriptMapper.sourceCues(from: transcript, audioActivity: audioActivity)
    }
    guard !cues.isEmpty else {
        throw MoongateError.translateFailed("Local ASR words did not contain any usable timed speech.")
    }
    try FileManager.default.createDirectory(
        at: outputURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let raw = cues.map { cue in
        """
        \(cue.index)
        \(cue.start) --> \(cue.end)
        \(cue.text)
        """
    }.joined(separator: "\n\n") + "\n"
    try raw.write(to: outputURL, atomically: true, encoding: .utf8)
}

/// 凭证脱敏：只显示前 6 位，绝不回显完整值。
func maskToken(_ token: String) -> String {
    guard token.count > 8 else { return "…" }  // 短 token 全打码，避免变相回显
    return String(token.prefix(6)) + "…"
}

/// 解析 translate / ping-llm 共用的 LLM 相关 flags，覆盖到 settings；返回 token 是否被命令行覆盖。
func applyLLMFlags(
    _ arguments: [String], startingAt start: Int,
    settings: inout AppSettings, style: inout SubtitleStyle, allowStyle: Bool
) -> Bool {
    var index = start
    var tokenOverridden = false
    var endpointOverridden = false
    while index < arguments.count {
        let flag = arguments[index]
        guard index + 1 < arguments.count else {
            printErr("选项 \(flag) 缺少取值。")
            exit(1)
        }
        let value = arguments[index + 1]
        switch flag {
        case "--style" where allowStyle:
            switch value {
            case "bilingual": style = .bilingual
            case "zh": style = .chineseOnly
            default:
                printErr("未知字幕样式：\(value)（支持 bilingual / zh）")
                exit(1)
            }
        case "--provider":
            switch value {
            case "anthropic", "claude":
                settings.setTranslationProvider(.anthropic)
                endpointOverridden = true
            case "openai":
                settings.setTranslationProvider(.openai)
                endpointOverridden = true
            default:
                printErr("未知接口协议：\(value)（支持 anthropic / openai）")
                exit(1)
            }
        case "--engine":
            guard let engine = TranslationEngine(cliValue: value) else {
                printErr("未知翻译引擎：\(value)（支持 \(TranslationEngine.supportedCLIValues.joined(separator: " / "))）")
                exit(1)
            }
            if let provider = engine.legacyProvider {
                settings.setTranslationProvider(provider)
            } else {
                settings.translationEngine = engine
            }
            endpointOverridden = true
        case "--base":
            settings.translationBaseURL = value
            endpointOverridden = true
        case "--model":
            settings.translationModel = value
            endpointOverridden = true
        case "--token":
            settings.translationAuthToken = value
            tokenOverridden = true
            endpointOverridden = true
        default:
            printErr("未知选项：\(flag)\n" + usageText)
            exit(1)
        }
        index += 2
    }
    if endpointOverridden {
        settings.translationFollowsDefault = false
    }
    return tokenOverridden
}

/// 0...1 进度打印：单行刷新。
final class PercentPrinter: @unchecked Sendable {
    private let lock = NSLock()
    private let label: String
    private var lineOpen = false

    init(label: String) {
        self.label = label
    }

    func update(_ fraction: Double) {
        lock.lock()
        defer { lock.unlock() }
        let percent = Int((min(max(fraction, 0), 1) * 100).rounded())
        print("\r\(label) \(percent)%   ", terminator: "")
        fflush(stdout)
        lineOpen = true
    }

    func finish() {
        lock.lock()
        defer { lock.unlock() }
        if lineOpen {
            print("")
            lineOpen = false
        }
    }
}

/// 下载进度打印：下载中单行刷新，阶段切换时换行。
final class ProgressPrinter: @unchecked Sendable {
    private let lock = NSLock()
    private var lastPhase: DownloadProgress.Phase?
    private var lineOpen = false

    func handle(_ p: DownloadProgress) {
        lock.lock()
        defer { lock.unlock() }
        switch p.phase {
        case .preparing:
            if lastPhase != .preparing { print("准备中…") }
        case .downloading:
            var parts: [String] = ["下载中"]
            if let percent = p.percent { parts.append(String(format: "%5.1f%%", percent)) }
            if let speed = p.speedText { parts.append(speed) }
            if let eta = p.etaText { parts.append("剩余 \(eta)") }
            let line = parts.joined(separator: "  ")
            let padding = String(repeating: " ", count: max(0, 50 - line.count))
            print("\r\(line)\(padding)", terminator: "")
            fflush(stdout)
            lineOpen = true
        case .processing:
            if lastPhase != .processing {
                if lineOpen { print(""); lineOpen = false }
                print("处理中（合并 / 转换）…")
            }
        case .finished:
            if lineOpen { print(""); lineOpen = false }
            print("下载完成")
        }
        lastPhase = p.phase
    }
}

// MARK: - 入口

let cliArguments = Array(CommandLine.arguments.dropFirst())
guard let command = cliArguments.first else {
    printErr(usageText)
    exit(1)
}

let engine = makeDefaultEngine()

do {
    switch command {
    case "resolve":
        guard cliArguments.count >= 2 else {
            printErr("缺少链接参数。\n" + usageText)
            exit(1)
        }
        let candidates = try await engine.resolveCandidates(for: cliArguments[1])
        print("共找到 \(candidates.count) 个视频：")
        for (index, candidate) in candidates.enumerated() {
            print("[\(index + 1)] (\(candidate.kind.rawValue)) \(candidate.title)")
            print("    \(candidate.url)")
            if let detail = candidate.detail { print("    \(detail)") }
        }

    case "analyze":
        guard cliArguments.count >= 2 else {
            printErr("缺少链接参数。\n" + usageText)
            exit(1)
        }
        let info = try await engine.analyze(url: cliArguments[1])
        print("标题：\(info.title)")
        print("视频 ID：\(info.videoID)")
        if let duration = info.durationText { print("时长：\(duration)") }
        if let uploader = info.uploader { print("上传者：\(uploader)") }
        if let thumbnail = info.thumbnailURL { print("封面：\(thumbnail.absoluteString)") }
        print("格式：")
        for (index, format) in info.formats.enumerated() {
            var line = "  [\(index + 1)] \(format.label)"
            if let detail = format.detail { line += "（\(detail)）" }
            line += "   --format \(format.id)"
            print(line)
        }
        if info.subtitles.isEmpty {
            print("字幕：无")
        } else {
            print("字幕：")
            for subtitle in info.subtitles {
                let flag = subtitle.isAuto ? "--auto-subs" : "--subs"
                let mark = subtitle.isAuto ? "（自动生成）" : ""
                print("  - \(subtitle.label)\(mark)   \(flag) \(subtitle.languageCode)")
            }
        }

    case "download":
        guard cliArguments.count >= 2 else {
            printErr("缺少链接参数。\n" + usageText)
            exit(1)
        }
        let url = cliArguments[1]
        var videoID: String?
        var formatID: String?
        var subs: [String] = []
        var autoSubs: [String] = []
        var destDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)

        var index = 2
        while index < cliArguments.count {
            let flag = cliArguments[index]
            guard index + 1 < cliArguments.count else {
                printErr("选项 \(flag) 缺少取值。")
                exit(1)
            }
            let value = cliArguments[index + 1]
            switch flag {
            case "--video-id":
                videoID = value
            case "--format":
                formatID = value
            case "--subs":
                subs = splitLangs(value)
            case "--auto-subs":
                autoSubs = splitLangs(value)
            case "--dest":
                destDir = URL(fileURLWithPath: (value as NSString).expandingTildeInPath, isDirectory: true)
            default:
                printErr("未知选项：\(flag)\n" + usageText)
                exit(1)
            }
            index += 2
        }
        guard let videoID, let formatID else {
            printErr("download 需要 --video-id 与 --format。\n" + usageText)
            exit(1)
        }

        let request = DownloadRequest(
            url: url,
            videoID: videoID,
            formatID: formatID,
            subtitleLangs: subs,
            autoSubtitleLangs: autoSubs,
            destinationDirectory: destDir
        )
        let printer = ProgressPrinter()
        let result = try await engine.download(request) { printer.handle($0) }
        print("产出文件：")
        for file in result.files {
            print("  \(file.path)")
        }

    case "translate":
        guard cliArguments.count >= 2 else {
            printErr("缺少 srt 文件路径。\n" + usageText)
            exit(1)
        }
        let srtURL = URL(fileURLWithPath: (cliArguments[1] as NSString).expandingTildeInPath)
        var settings = AppSettings.load()
        var style = settings.subtitleStyle
        let tokenOverridden = applyLLMFlags(
            cliArguments, startingAt: 2,
            settings: &settings, style: &style, allowStyle: true
        )
        if tokenOverridden {
            print("使用命令行凭证：\(maskToken(settings.translationAuthToken))")
        }
        let translator = makeTranslator(settings: settings)
        let printer = PercentPrinter(label: "翻译中")
        let outputURL = try await translator.translate(
            srtFile: srtURL,
            style: style,
            context: settings.makeTranslationContext(
                sourceLanguage: TranslationContext.sourceLanguageIdentifier(fromSubtitleFile: srtURL)
            )
        ) { printer.update($0) }
        printer.finish()
        print("译文文件：\(outputURL.path)")

    case "clean-srt":
        guard cliArguments.count >= 2 else {
            printErr("缺少 srt 文件路径。\n" + usageText)
            exit(1)
        }
        let srtURL = URL(fileURLWithPath: (cliArguments[1] as NSString).expandingTildeInPath)
        let result = try cleanSRTFile(at: srtURL)
        print("解析 \(result.parsed) 条 → 清洗后 \(result.cleaned) 条")
        print("输出：\(result.output.path)")

    case "local-asr-srt":
        var wordsURL: URL?
        var languageCode = ""
        var outputURL: URL?
        var fileName: String?
        var silencedetectLogURL: URL?
        var timingProfile: SubtitleTimingProfile?
        var index = 1
        while index < cliArguments.count {
            let flag = cliArguments[index]
            guard index + 1 < cliArguments.count else {
                printErr("选项 \(flag) 缺少取值。")
                exit(1)
            }
            let value = cliArguments[index + 1]
            switch flag {
            case "--asr-words":
                wordsURL = URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
            case "--language":
                languageCode = value
            case "--out":
                outputURL = URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
            case "--file-name":
                fileName = value
            case "--timing-profile":
                guard let parsed = SubtitleTimingProfile(rawValue: value) else {
                    printErr("未知 timing profile：\(value)（支持 speech / lyrics / japaneseLyrics / anime）")
                    exit(1)
                }
                timingProfile = parsed
            case "--silencedetect-log":
                silencedetectLogURL = URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
            default:
                printErr("未知选项：\(flag)\n" + usageText)
                exit(1)
            }
            index += 2
        }
        guard let wordsURL, let outputURL else {
            printErr("local-asr-srt 需要 --asr-words 与 --out。\n" + usageText)
            exit(1)
        }
        let audioActivity = try silencedetectLogURL.map {
            try ASRAudioActivity.parseSilencedetectOutput(String(contentsOf: $0, encoding: .utf8))
        }
        try writeLocalASRSRT(
            wordsJSON: wordsURL,
            languageCode: languageCode,
            outputURL: outputURL,
            fileName: fileName,
            audioActivity: audioActivity,
            timingProfile: timingProfile
        )
        print("输出：\(outputURL.path)")

    case "burn":
        guard cliArguments.count >= 3 else {
            printErr("burn 需要视频与 srt 两个路径。\n" + usageText)
            exit(1)
        }
        let videoURL = URL(fileURLWithPath: (cliArguments[1] as NSString).expandingTildeInPath)
        let subtitleURL = URL(fileURLWithPath: (cliArguments[2] as NSString).expandingTildeInPath)
        // 缺省读设置里的最大高度；命令行可覆盖。
        var maxHeight: Int? = AppSettings.load().maxBurnHeight
        var bIndex = 3
        while bIndex < cliArguments.count {
            let flag = cliArguments[bIndex]
            switch flag {
            case "--keep-resolution":
                maxHeight = nil
                bIndex += 1
            case "--max-height":
                guard bIndex + 1 < cliArguments.count, let value = Int(cliArguments[bIndex + 1]), value > 0 else {
                    printErr("--max-height 需要一个正整数。")
                    exit(1)
                }
                maxHeight = value
                bIndex += 2
            default:
                printErr("未知选项：\(flag)\n" + usageText)
                exit(1)
            }
        }
        let burner = makeBurner()
        let printer = PercentPrinter(label: "烧录中")
        let outputURL = try await burner.burn(
            video: videoURL, subtitle: subtitleURL,
            maxHeight: maxHeight, control: nil
        ) {
            printer.update($0)
        }
        printer.finish()
        print("输出文件：\(outputURL.path)")

    case "ping-llm":
        var settings = AppSettings.load()
        var style = settings.subtitleStyle
        let tokenOverridden = applyLLMFlags(
            cliArguments, startingAt: 1,
            settings: &settings, style: &style, allowStyle: false
        )
        guard settings.translationEngine.requiresCloudConfiguration else {
            throw MoongateError.translateFailed("ping-llm 只支持 Anthropic-compatible / OpenAI-compatible。\(settings.translationEngine.displayName) 请使用 translate --engine 或运行时能力检测。")
        }
        if tokenOverridden {
            print("使用命令行凭证：\(maskToken(settings.translationAuthToken))")
        }
        let reply = try await testTranslationConnection(settings: settings)
        print("服务回复：\(reply)")

    default:
        printErr("未知命令：\(command)\n" + usageText)
        exit(1)
    }
} catch {
    printErr(error.localizedDescription)
    exit(1)
}
