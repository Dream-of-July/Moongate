import Foundation
import MoongateMobileCore
#if canImport(FoundationModels)
import FoundationModels
#endif

private let srtTimeLineRegex: NSRegularExpression? = try? NSRegularExpression(
    pattern: #"(\d{1,2}:\d{2}:\d{2}[,\.]\d{1,3})\s*-->\s*(\d{1,2}:\d{2}:\d{2}[,\.]\d{1,3})"#
)

private let vttTimeLineRegex: NSRegularExpression? = try? NSRegularExpression(
    pattern: #"\s*((?:\d{1,2}:)?\d{2}:\d{2}[,\.]\d{1,3})\s*-->\s*((?:\d{1,2}:)?\d{2}:\d{2}[,\.]\d{1,3})"#
)

private let vttInlineTimeRegex: NSRegularExpression? = try? NSRegularExpression(
    pattern: #"<((?:\d{1,2}:)?\d{2}:\d{2}[,\.]\d{1,3})>"#
)

private let vttTagRegex: NSRegularExpression? = try? NSRegularExpression(
    pattern: #"<[^>]+>"#
)

// MARK: - 默认翻译器

public func makeTranslator(settings: AppSettings) -> any SubtitleTranslator {
    ConfiguredTranslator(settings: settings)
}

// MARK: - SRT 解析与序列化

/// 解析 SRT 文本为字幕条。按时间行锚定切条（而非按空行切块）：
/// YouTube 滚动字幕的文本里常夹空行/纯空白行，按空行切块会把后半句当成
/// 没有时间行的孤块整体丢掉。容忍 BOM、CRLF、多行文本、序号缺失（按顺序补号）；
/// 文本为空的条目直接丢弃。
func parseSRT(_ raw: String) -> [SubtitleCue] {
    var text = raw
    if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
    let lines = text
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
        .components(separatedBy: "\n")

    // 先找出所有时间行的位置；上一行若是纯数字则视为该条的显式序号。
    struct Anchor {
        let lineIndex: Int
        let start: String
        let end: String
        let explicitIndex: Int?
        let hasIndexLine: Bool
    }
    var anchors: [Anchor] = []
    for (i, line) in lines.enumerated() {
        guard let (start, end) = parseSRTTimeLine(line) else { continue }
        var explicit: Int?
        if i > 0 {
            explicit = Int(lines[i - 1].trimmingCharacters(in: .whitespaces))
        }
        anchors.append(Anchor(
            lineIndex: i, start: start, end: end,
            explicitIndex: explicit, hasIndexLine: explicit != nil
        ))
    }

    var cues: [SubtitleCue] = []
    var nextIndex = 1
    for (a, anchor) in anchors.enumerated() {
        // 文本范围：本条时间行之后 → 下一条的序号行（或时间行）之前
        var textEnd = lines.count
        if a + 1 < anchors.count {
            let next = anchors[a + 1]
            textEnd = next.hasIndexLine ? next.lineIndex - 1 : next.lineIndex
        }
        let textStart = anchor.lineIndex + 1
        guard textStart <= textEnd else { continue }
        let textLines = lines[textStart..<textEnd]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !textLines.isEmpty else { continue }
        let index = anchor.explicitIndex ?? nextIndex
        cues.append(SubtitleCue(
            index: index, start: anchor.start, end: anchor.end,
            text: textLines.joined(separator: "\n")
        ))
        nextIndex = index + 1
    }
    return cues
}

/// 解析 WebVTT 文本为字幕条。YouTube 自动字幕常在 VTT 中保留 `<00:00:00.000>`
/// 词级时间戳；这里把它们转成 `sourceFragments`，供清洗器做真实语音边界对齐。
func parseVTT(_ raw: String) -> [SubtitleCue] {
    var text = raw
    if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
    let lines = text
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
        .components(separatedBy: "\n")

    var blocks: [[String]] = []
    var currentBlock: [String] = []
    func flushBlock() {
        guard !currentBlock.isEmpty else { return }
        blocks.append(currentBlock)
        currentBlock = []
    }
    for line in lines {
        if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            flushBlock()
        } else {
            currentBlock.append(line)
        }
    }
    flushBlock()

    var cues: [SubtitleCue] = []
    var previousVisible = ""
    for block in blocks {
        guard !shouldSkipVTTBlock(block),
              let timingIndex = block.firstIndex(where: { parseVTTTimeLine($0) != nil }),
              let timing = parseVTTTimeLine(block[timingIndex]) else {
            continue
        }
        let bodyStart = timingIndex + 1
        guard bodyStart < block.endIndex else { continue }
        let bodyLines = Array(block[bodyStart..<block.endIndex])
        guard let parsed = parseVTTCueBody(
            bodyLines,
            cueStart: timing.start,
            cueEnd: max(timing.end, timing.start),
            previousVisible: previousVisible
        ) else { continue }

        cues.append(SubtitleCue(
            index: cues.count + 1,
            start: secondsToSRTTime(timing.start),
            end: secondsToSRTTime(max(timing.end, timing.start)),
            text: parsed.text,
            sourceFragments: parsed.fragments
        ))
        previousVisible = parsed.text
    }
    return cues
}

private func shouldSkipVTTBlock(_ block: [String]) -> Bool {
    guard let first = block.first?.trimmingCharacters(in: .whitespacesAndNewlines),
          !first.isEmpty else {
        return true
    }
    if first == "WEBVTT" || first.hasPrefix("WEBVTT ") { return true }
    if first == "STYLE" || first.hasPrefix("STYLE ") { return true }
    if first == "REGION" || first.hasPrefix("REGION ") { return true }
    if first == "NOTE" || first.hasPrefix("NOTE ") { return true }
    return false
}

private func parseVTTTimeLine(_ line: String) -> (start: Double, end: Double)? {
    guard let regex = vttTimeLineRegex,
          let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
          let startRange = Range(match.range(at: 1), in: line),
          let endRange = Range(match.range(at: 2), in: line),
          let start = vttTimeToSeconds(String(line[startRange])),
          let end = vttTimeToSeconds(String(line[endRange])) else { return nil }
    return (start, end)
}

private func vttTimeToSeconds(_ raw: String) -> Double? {
    let parts = raw.replacingOccurrences(of: ",", with: ".").split(separator: ":")
    if parts.count == 2 {
        guard let minutes = Double(parts[0]), let seconds = Double(parts[1]) else { return nil }
        return minutes * 60 + seconds
    }
    if parts.count == 3 {
        guard let hours = Double(parts[0]),
              let minutes = Double(parts[1]),
              let seconds = Double(parts[2]) else { return nil }
        return hours * 3600 + minutes * 60 + seconds
    }
    return nil
}

private func parseVTTCueBody(
    _ bodyLines: [String],
    cueStart: Double,
    cueEnd: Double,
    previousVisible: String
) -> (text: String, fragments: [SubtitleCueSourceFragment])? {
    let visibleLines = bodyLines
        .map(stripVTTMarkup)
        .filter { !$0.isEmpty }
    guard !visibleLines.isEmpty else { return nil }
    let visibleText = visibleLines.joined(separator: "\n")

    let body = bodyLines.joined(separator: "\n")
    guard let inlineRegex = vttInlineTimeRegex else {
        return (visibleText, [])
    }
    let matches = inlineRegex.matches(in: body, range: NSRange(body.startIndex..., in: body))
    guard !matches.isEmpty else {
        let timingText = removeVTTRollingPrefix(visibleText, previousVisible: previousVisible)
        guard !timingText.isEmpty else { return (visibleText, []) }
        let tokens = timingText.split(whereSeparator: { $0.isWhitespace })
        let shouldCapNoInlineHold = timingText != visibleText
            && cueEnd - cueStart > SubtitleTimingPlanner.vttUntimedLongCueSeconds
        let cappedEnd = shouldCapNoInlineHold ? min(
            cueEnd,
            cueStart + Double(max(1, tokens.count)) * SubtitleTimingPlanner.vttUntimedMaxSecondsPerToken
        ) : cueEnd
        return (
            visibleText,
            [SubtitleCueSourceFragment(startSeconds: cueStart, endSeconds: cappedEnd, text: timingText)]
        )
    }

    var fragments: [SubtitleCueSourceFragment] = []
    var cursor = body.startIndex
    var segmentStart = cueStart
    var isLeadingSegment = true

    func appendSegment(_ rawSegment: Substring, start: Double, end: Double, capTokenSpan: Bool = false) {
        var text = stripVTTMarkup(String(rawSegment))
        if isLeadingSegment {
            text = removeVTTRollingPrefix(text, previousVisible: previousVisible)
        }
        isLeadingSegment = false
        guard !text.isEmpty else { return }

        let clampedStart = max(cueStart, start)
        let tokens = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var clampedEnd = min(max(clampedStart, end), cueEnd)
        if capTokenSpan,
           clampedEnd - clampedStart > 2.0 {
            let capUnitCount = SubtitleTimingPlanner.containsCJKText(text)
                ? SubtitleTimingPlanner.timingTokens(text).count
                : tokens.count
            clampedEnd = min(
                clampedEnd,
                clampedStart + Double(max(1, capUnitCount)) * SubtitleTimingPlanner.vttUntimedMaxSecondsPerToken
            )
        }
        guard clampedEnd >= clampedStart else { return }
        guard tokens.count > 1 else {
            fragments.append(SubtitleCueSourceFragment(
                startSeconds: clampedStart,
                endSeconds: clampedEnd,
                text: text
            ))
            return
        }

        let duration = clampedEnd - clampedStart
        for (tokenIndex, token) in tokens.enumerated() {
            let tokenStart = clampedStart + duration * Double(tokenIndex) / Double(tokens.count)
            let tokenEnd = clampedStart + duration * Double(tokenIndex + 1) / Double(tokens.count)
            fragments.append(SubtitleCueSourceFragment(
                startSeconds: tokenStart,
                endSeconds: tokenEnd,
                text: token
            ))
        }
    }

    for match in matches {
        guard let markerRange = Range(match.range(at: 0), in: body),
              let timeRange = Range(match.range(at: 1), in: body),
              let markerTime = vttTimeToSeconds(String(body[timeRange])) else { continue }
        appendSegment(body[cursor..<markerRange.lowerBound], start: segmentStart, end: markerTime)
        cursor = markerRange.upperBound
        segmentStart = markerTime
    }
    appendSegment(body[cursor..<body.endIndex], start: segmentStart, end: cueEnd, capTokenSpan: true)

    return (visibleText, fragments)
}

private func stripVTTMarkup(_ text: String) -> String {
    var output = text
    if let tagRegex = vttTagRegex {
        output = tagRegex.stringByReplacingMatches(
            in: output,
            range: NSRange(output.startIndex..., in: output),
            withTemplate: " "
        )
    }
    output = decodeBasicHTMLEntities(output)
    return collapseSubtitleWhitespace(output)
}

private func decodeBasicHTMLEntities(_ text: String) -> String {
    text.replacingOccurrences(of: "&nbsp;", with: " ")
        .replacingOccurrences(of: "&#160;", with: " ")
        .replacingOccurrences(of: "&amp;", with: "&")
        .replacingOccurrences(of: "&lt;", with: "<")
        .replacingOccurrences(of: "&gt;", with: ">")
        .replacingOccurrences(of: "&quot;", with: "\"")
        .replacingOccurrences(of: "&#39;", with: "'")
        .replacingOccurrences(of: "&apos;", with: "'")
}

private func removeVTTRollingPrefix(_ text: String, previousVisible: String) -> String {
    let currentTokens = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    let previousTokens = previousVisible
        .replacingOccurrences(of: "\n", with: " ")
        .split(whereSeparator: { $0.isWhitespace })
        .map(String.init)
    guard !currentTokens.isEmpty, !previousTokens.isEmpty else { return text }

    var overlap = min(currentTokens.count, previousTokens.count)
    while overlap > 0 {
        if Array(previousTokens.suffix(overlap)) == Array(currentTokens.prefix(overlap)) {
            let remaining = currentTokens.dropFirst(overlap).joined(separator: " ")
            return remaining.isEmpty ? "" : remaining
        }
        overlap -= 1
    }

    let compactText = collapseSubtitleWhitespace(text)
    let compactPrevious = collapseSubtitleWhitespace(previousVisible.replacingOccurrences(of: "\n", with: " "))
    if !compactPrevious.isEmpty,
       compactText != compactPrevious,
       compactText.hasPrefix(compactPrevious) {
        let remainingStart = compactText.index(compactText.startIndex, offsetBy: compactPrevious.count)
        let remaining = String(compactText[remainingStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return remaining.isEmpty ? "" : remaining
    }
    return text
}

/// 解析时间行 "HH:MM:SS,mmm --> HH:MM:SS,mmm"（毫秒分隔符容忍 "," 与 "."）。
private func parseSRTTimeLine(_ line: String) -> (start: String, end: String)? {
    guard let regex = srtTimeLineRegex,
          let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
          let startRange = Range(match.range(at: 1), in: line),
          let endRange = Range(match.range(at: 2), in: line) else { return nil }
    return (String(line[startRange]), String(line[endRange]))
}

/// 序列化为标准 SRT 文本。
func serializeSRT(_ cues: [SubtitleCue]) -> String {
    cues.map { "\($0.index)\n\($0.start) --> \($0.end)\n\($0.text)" }
        .joined(separator: "\n\n") + "\n"
}

// MARK: - 字幕清洗（去重叠 + 按句合并）

// 圆括号类音效/旁注：(...) 与全角（...）。只在内容命中词表时删，保留对话括号（如"(important note)"）。
private let nonSpeechMarkerRegex: NSRegularExpression? = try? NSRegularExpression(
    pattern: #"[\(（]\s*([^\)）]{1,48})\s*[\)）]"#,
    options: [.caseInsensitive]
)

// 方括号 / 书名号类音效标注：[...] 与【...】。这类几乎只用于音效/旁注，内容一律删除，不依赖词表
//（支持 [음악]、[dramatic orchestral music]、【効果音】等任意语言）。
private let bracketMarkerRegex: NSRegularExpression? = try? NSRegularExpression(
    pattern: #"[\[【]\s*[^\]】]{1,48}\s*[\]】]"#,
    options: []
)

// 音符记号 ♪/♫：包裹歌词时只去掉符号本身，保留内部文字（"♪sing this line♪" → "sing this line"）。
private let musicNoteRegex: NSRegularExpression? = try? NSRegularExpression(
    pattern: #"[♪♫]"#,
    options: []
)

/// 归一字幕转义：ASS/SRT 的 \N 硬换行 → 真换行；\h、&nbsp;、不间断空格(NBSP) → 普通空格。
/// 在清洗与翻译前统一，避免这些转义原样进入译文或干扰断句。与 Windows NormalizeSubtitleEscapes 同构。
private func normalizeSubtitleEscapes(_ text: String) -> String {
    text.replacingOccurrences(of: "\\N", with: "\n")
        .replacingOccurrences(of: "\\n", with: "\n")
        .replacingOccurrences(of: "\\h", with: " ")
        .replacingOccurrences(of: "&nbsp;", with: " ")
        .replacingOccurrences(of: "\u{00A0}", with: " ")
}

private let nonSpeechMarkerTerms: Set<String> = [
    "music", "bgm", "backgroundmusic", "instrumentalmusic", "song", "singing", "sings", "lyrics",
    "musica", "música", "musique", "musik", "muziek", "музыка", "♪",
    "音乐", "音樂", "背景音乐", "背景音樂", "歌声", "歌聲",
    "applause", "applauding", "clapping", "claps", "applausecontinues", "clappingcontinues",
    "acclamation", "acclamations", "applaudissement", "applaudissements",
    "aplauso", "aplausos", "applauso", "applausi",
    "掌声", "掌聲", "掌声继续", "掌聲繼續", "鼓掌", "鼓掌声", "鼓掌聲", "拍手", "拍手声", "拍手聲",
    "laughter", "laugh", "laughs", "laughing", "chuckle", "chuckles", "chuckling", "giggle",
    "giggles", "giggling", "snicker", "snickers", "laughingcontinues",
    "笑", "笑声", "笑聲", "笑声继续", "笑聲繼續", "大笑", "轻笑", "輕笑", "哄笑", "偷笑", "笑い", "笑い声",
    "risa", "risas", "rire", "rires", "lachen", "gelächter", "웃음",
    "cry", "crying", "sobbing", "sob", "sobs", "weeping", "sniffles", "sniffling",
    "哭", "哭声", "哭聲", "哭泣", "啜泣", "抽泣", "llanto", "pleurs", "weinen",
    "cheer", "cheers", "cheering", "crowdcheering", "audiencecheering", "欢呼", "歡呼", "喝彩",
    "sigh", "sighs", "sighing", "叹气", "嘆氣", "叹息", "嘆息",
    "cough", "coughs", "coughing", "咳嗽",
    "sneeze", "sneezes", "sneezing", "喷嚏", "噴嚏", "打喷嚏", "打噴嚏",
    "gasp", "gasps", "gasping", "breathing", "heavybreathing", "panting", "喘息", "喘气", "喘氣", "呼吸声", "呼吸聲",
    "scream", "screams", "screaming", "yell", "yells", "groan", "groans", "groaning", "moan", "moans", "moaning",
    "尖叫", "喊叫", "呻吟", "低吟",
    "inaudible", "unintelligible", "silence", "silent", "noise", "noises", "static",
    "backgroundnoise", "ambientnoise", "murmur", "murmurs", "murmuring",
    "听不清", "聽不清", "无法听清", "無法聽清", "沉默", "静音", "靜音", "噪音", "杂音", "雜音", "背景音", "背景噪音",
    "dooropens", "doorcloses", "phonerings", "phoneringing", "ringing", "footsteps", "steps",
    "knocking", "knocks", "beep", "beeping", "bellrings", "alarm", "siren", "windblowing", "rainfalling",
    "门开", "門開", "开门", "開門", "关门", "關門", "门关", "門關", "脚步", "腳步", "脚步声", "腳步聲",
    "敲门", "敲門", "电话响", "電話響", "铃声", "鈴聲", "警报", "警報", "风声", "風聲", "雨声", "雨聲", "人群声", "人群聲"
]

private func normalizedNonSpeechMarker(_ raw: String) -> String {
    raw.lowercased().filter { char in
        !(char.isWhitespace || char == "-" || char == "_" || char == "." || char == "!" || char == "?" || char == "！" || char == "？")
    }
}

/// 广播/CART 字幕（CEA-608）的说话人切换标记：行首或空白后的 ">>"/">>>"（含全角 "＞"）。
/// 例如 ">> 从1949年开始…"。这类标记不是台词内容，应在清洗阶段去掉，
/// 否则会原样进入译文。仅匹配「行首」或「空白后」的连续 ≥2 个尖括号，避免误伤行内 "a>>b"。
private let speakerChangeMarkerRegex: NSRegularExpression? = try? NSRegularExpression(
    pattern: #"(?:^|\s)[>＞]{2,}\s*"#,
    options: []
)

private func stripSpeakerChangeMarkers(_ line: String) -> String {
    guard let regex = speakerChangeMarkerRegex else { return line }
    let range = NSRange(line.startIndex..., in: line)
    return regex.stringByReplacingMatches(in: line, range: range, withTemplate: " ")
}

private func stripNonSpeechMarkers(_ text: String) -> String {
    text.components(separatedBy: .newlines).compactMap { rawLine -> String? in
        var line = rawLine
        // 方括号 / 书名号标注：内容一律删（不查词表）。
        if let bracketRegex = bracketMarkerRegex {
            line = bracketRegex.stringByReplacingMatches(
                in: line, range: NSRange(line.startIndex..., in: line), withTemplate: " ")
        }
        // 圆括号标注：仅当内容命中非语音词表才删，保留对话用括号。
        if let regex = nonSpeechMarkerRegex {
            let matches = regex.matches(in: line, range: NSRange(line.startIndex..., in: line))
            for match in matches.reversed() {
                guard let contentRange = Range(match.range(at: 1), in: line),
                      let markerRange = Range(match.range(at: 0), in: line) else { continue }
                let marker = normalizedNonSpeechMarker(String(line[contentRange]))
                if nonSpeechMarkerTerms.contains(marker) {
                    line.replaceSubrange(markerRange, with: " ")
                }
            }
        }
        // 音符记号：只去符号、保留歌词文字。
        if let noteRegex = musicNoteRegex {
            line = noteRegex.stringByReplacingMatches(
                in: line, range: NSRange(line.startIndex..., in: line), withTemplate: " ")
        }
        line = stripSpeakerChangeMarkers(line)
        let cleaned = collapseSubtitleWhitespace(line)
        return cleaned.isEmpty ? nil : cleaned
    }
    .joined(separator: "\n")
}

private func collapseSubtitleWhitespace(_ s: String) -> String {
    let collapsed = s.components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    return removeSpacesBetweenCJKCharacters(collapsed)
}

private func removeSpacesBetweenCJKCharacters(_ text: String) -> String {
    let chars = Array(text)
    guard chars.count >= 3 else { return text }
    var result: [Character] = []
    result.reserveCapacity(chars.count)
    for index in chars.indices {
        let char = chars[index]
        if char == " ",
           index > chars.startIndex,
           index < chars.index(before: chars.endIndex),
           isCJKSubtitleCharacter(chars[chars.index(before: index)]),
           isCJKSubtitleCharacter(chars[chars.index(after: index)]) {
            continue
        }
        result.append(char)
    }
    return String(result)
}

private func isCJKSubtitleCharacter(_ char: Character) -> Bool {
    char.unicodeScalars.contains { scalar in
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0x3040...0x30FF:
            return true
        default:
            return false
        }
    }
}

/// 把 "HH:MM:SS,mmm"（或用 "." 作毫秒分隔）解析为秒。失败返回 nil。
func srtTimeToSeconds(_ s: String) -> Double? {
    let normalized = s.replacingOccurrences(of: ",", with: ".")
    let parts = normalized.split(separator: ":")
    guard parts.count == 3, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
    guard let sec = Double(parts[2]) else { return nil }
    return Double(h) * 3600 + Double(m) * 60 + sec
}

/// 秒转回 "HH:MM:SS,mmm"。
func secondsToSRTTime(_ seconds: Double) -> String {
    let clamped = max(0, seconds)
    let totalMS = Int((clamped * 1000).rounded())
    let ms = totalMS % 1000
    let totalSec = totalMS / 1000
    let s = totalSec % 60
    let m = (totalSec / 60) % 60
    let h = totalSec / 3600
    return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
}

/// 清洗字幕：
/// (a) 解析时间戳为秒，按 start 稳定升序；
/// (b) 去重叠：每条 end 截断到 min(自身 end, 下一条 start)，截断后 <0.3s 则设为 start+0.3s；
/// (c) 按句合并（仅对滚动字幕启用）：相邻碎条拼接，遇句末标点 / 累积≥6s / 累积≥84 字符断句；
/// (d) 防误伤：合并后条数 ≥ 原条数则放弃合并，只返回去重叠结果；
/// (e) 滚动判定（满足其一即按句合并）：时间戳重叠率 > 50%（样式 A），
///     或相邻条文本重复率 > 30%（样式 B：两行滚动窗口，先做文本去重再合并）。
func cleanCues(_ input: [SubtitleCue]) -> [SubtitleCue] {
    guard !input.isEmpty else { return input }

    // (a) 解析时间 + 稳定升序排序
    struct Fragment { var start: Double; var end: Double; var text: String }
    struct Timed {
        var start: Double
        var end: Double
        var text: String
        var order: Int
        var fragments: [Fragment]
        var hasSourceAnchors: Bool
    }
    func fragmentMatchTokens(_ text: String) -> [String] {
        SubtitleTimingPlanner.timingTokens(text)
    }
    func fallbackFragment(start: Double, end: Double, text: String) -> [Fragment] {
        [Fragment(start: start, end: end, text: text)]
    }
    func sourceFragments(for cue: SubtitleCue, start: Double, end: Double, text: String) -> [Fragment] {
        let fragments = cue.sourceFragments.compactMap { fragment -> Fragment? in
            let fragmentText = stripNonSpeechMarkers(normalizeSubtitleEscapes(fragment.text))
            guard !fragmentText.isEmpty else { return nil }
            let fragmentStart = max(start, fragment.startSeconds)
            let fragmentEnd = min(end, fragment.endSeconds)
            guard fragmentEnd >= fragmentStart else { return nil }
            return Fragment(start: fragmentStart, end: fragmentEnd, text: fragmentText)
        }
        return fragments.isEmpty ? fallbackFragment(start: start, end: end, text: text) : fragments
    }
    func clippedFragments(_ fragments: [Fragment], start: Double, end: Double, text: String) -> [Fragment] {
        let clipped = fragments.compactMap { fragment -> Fragment? in
            let fragmentStart = max(start, fragment.start)
            let fragmentEnd = min(end, fragment.end)
            guard fragmentEnd >= fragmentStart else { return nil }
            return Fragment(start: fragmentStart, end: fragmentEnd, text: fragment.text)
        }
        return clipped.isEmpty ? fallbackFragment(start: start, end: end, text: text) : clipped
    }
    func fragmentsMatching(text: String, from fragments: [Fragment], fallbackStart: Double, fallbackEnd: Double) -> [Fragment] {
        let targetTokens = fragmentMatchTokens(text)
        guard !targetTokens.isEmpty else {
            return fallbackFragment(start: fallbackStart, end: fallbackEnd, text: text)
        }
        var cursor = 0
        var matched: [Fragment] = []
        for fragment in fragments {
            let tokens = fragmentMatchTokens(fragment.text)
            guard !tokens.isEmpty, cursor + tokens.count <= targetTokens.count else { continue }
            let targetSlice = Array(targetTokens[cursor..<(cursor + tokens.count)])
            guard targetSlice == tokens else { continue }
            matched.append(fragment)
            cursor += tokens.count
            if cursor == targetTokens.count { break }
        }
        return cursor == targetTokens.count && !matched.isEmpty
            ? matched
            : fallbackFragment(start: fallbackStart, end: fallbackEnd, text: text)
    }

    var timed: [Timed] = []
    for (i, cue) in input.enumerated() {
        guard let start = srtTimeToSeconds(cue.start), let end = srtTimeToSeconds(cue.end) else {
            continue
        }
        let text = stripNonSpeechMarkers(normalizeSubtitleEscapes(cue.text))
        guard !text.isEmpty else { continue }
        let clampedEnd = max(end, start)
        timed.append(Timed(
            start: start,
            end: clampedEnd,
            text: text,
            order: i,
            fragments: sourceFragments(for: cue, start: start, end: clampedEnd, text: text),
            hasSourceAnchors: !cue.sourceFragments.isEmpty
        ))
    }
    guard !timed.isEmpty else { return [] }
    timed.sort { $0.start != $1.start ? $0.start < $1.start : $0.order < $1.order }

    // (e) 滚动判定一：时间戳重叠（样式 A）——相邻条 start < 上一条 end 的比例 > 50%
    var overlapCount = 0
    if timed.count >= 2 {
        for i in 1..<timed.count where timed[i].start < timed[i - 1].end {
            overlapCount += 1
        }
    }
    let overlapRatio = timed.count >= 2 ? Double(overlapCount) / Double(timed.count - 1) : 0

    // (e2) 滚动判定二：文本重复（样式 B）——每条开头重复上一条的尾行
    //（两行滚动窗口 + 10ms 过渡条，时间戳首尾相接不重叠，靠时间戳判不出来）。
    func overlapPrefixCount(prev: [String], cur: [String]) -> Int {
        var k = min(prev.count, cur.count)
        while k > 0 {
            if Array(prev.suffix(k)) == Array(cur.prefix(k)) { return k }
            k -= 1
        }
        return 0
    }
    var textRepeatPairs = 0
    if timed.count >= 2 {
        for i in 1..<timed.count {
            let prev = timed[i - 1].text.components(separatedBy: "\n")
            let cur = timed[i].text.components(separatedBy: "\n")
            if overlapPrefixCount(prev: prev, cur: cur) > 0 { textRepeatPairs += 1 }
        }
    }
    let textRepeatRatio = timed.count >= 2 ? Double(textRepeatPairs) / Double(timed.count - 1) : 0

    let isRolling = overlapRatio > 0.5 || textRepeatRatio > 0.3

    // (a2) 样式 B 先做文本去重：删掉每条开头与上一条结尾重复的行，只留新增内容；
    //      删空的条目（纯过渡条）整条丢弃。对照对象用上一条的「原始」行，因为
    //      滚动窗口重复的是原文而非去重后的残句。阈值 0.3 防止误伤歌词等合法重复。
    if textRepeatRatio > 0.3 {
        var deduped: [Timed] = []
        var prevOriginalLines: [String] = []
        for item in timed {
            let curLines = item.text.components(separatedBy: "\n")
            let k = overlapPrefixCount(prev: prevOriginalLines, cur: curLines)
            prevOriginalLines = curLines
            let newLines = Array(curLines.dropFirst(k))
            guard !newLines.isEmpty else { continue }
            var copy = item
            copy.text = newLines.joined(separator: "\n")
            copy.fragments = fragmentsMatching(
                text: copy.text,
                from: item.fragments,
                fallbackStart: copy.start,
                fallbackEnd: copy.end
            )
            deduped.append(copy)
        }
        if !deduped.isEmpty { timed = deduped }
    }

    // (b) 去重叠：end 截断到下一条 start，过短则补到 start+0.3s（但不越过下一条 start）
    let minDuration = 0.3
    for i in 0..<timed.count {
        let nextStart = i + 1 < timed.count ? timed[i + 1].start : nil
        let preserveSourceWindow = isRolling && timed[i].hasSourceAnchors
        if let nextStart, !preserveSourceWindow {
            timed[i].end = min(timed[i].end, nextStart)
        }
        if timed[i].end - timed[i].start < minDuration {
            var compensated = timed[i].start + minDuration
            if let nextStart { compensated = min(compensated, nextStart) }
            timed[i].end = compensated
        }
        if !preserveSourceWindow {
            timed[i].fragments = clippedFragments(
                timed[i].fragments,
                start: timed[i].start,
                end: timed[i].end,
                text: timed[i].text
            )
        }
    }

    func makeCues(_ items: [Timed]) -> [SubtitleCue] {
        items.enumerated().map { idx, t in
            SubtitleCue(index: idx + 1, start: secondsToSRTTime(t.start),
                        end: secondsToSRTTime(t.end), text: t.text)
        }
    }

    // (c) 按句合并：把碎条文本规整空白后用空格累积，满足任一断句条件即收一条
    let sentenceEnders: Set<Character> = [".", "!", "?", "。", "！", "？"]
    let trailingAllowed: Set<Character> = ["\"", "'", "”", "’", ")", "）", "」", "』", "]"]
    func endsSentence(_ text: String) -> Bool {
        var chars = Array(text)
        // 跳过尾部的引号 / 括号
        while let last = chars.last, trailingAllowed.contains(last) || last == " " {
            chars.removeLast()
        }
        guard let last = chars.last else { return false }
        return sentenceEnders.contains(last)
    }
    func wordTokens(_ text: String) -> [String] {
        SubtitleTimingPlanner.wordTokens(text)
    }
    func looksLikeContinuation(current: String, nextPiece: String?) -> Bool {
        guard let nextPiece, !endsSentence(current) else { return false }
        let currentWords = wordTokens(current)
        let nextWords = wordTokens(nextPiece)
        guard let last = currentWords.last, let first = nextWords.first else { return false }
        return SubtitleTimingPlanner.isWeakBoundary(leftToken: last, rightToken: first)
    }

    var merged: [Timed] = []
    var curText = ""
    var curStart = 0.0
    var curEnd = 0.0
    var curFragments: [Fragment] = []
    var curHasSourceAnchors = false
    var hasCurrent = false

    func flush() {
        guard hasCurrent else { return }
        merged.append(Timed(
            start: curStart,
            end: curEnd,
            text: curText,
            order: merged.count,
            fragments: curFragments,
            hasSourceAnchors: curHasSourceAnchors
        ))
        hasCurrent = false
        curText = ""
        curFragments = []
        curHasSourceAnchors = false
    }

    let softDuration = 6.0
    let softCharacterBudget = 84
    let hardDuration = 18.0
    let hardCharacterBudget = 220
    let normalReadableCueSeconds = SubtitleTimingPlanner.normalReadableCueSeconds
    let emergencyReadableCueSeconds = SubtitleTimingPlanner.emergencyReadableCueSeconds

    func textWeight(_ text: String) -> Int {
        let words = wordTokens(text)
        return words.isEmpty ? max(1, text.count) : words.count
    }

    func speechTokens(_ text: String) -> [String] {
        SubtitleTimingPlanner.speechTokens(text)
    }

    func timingUnits(_ text: String) -> [String] {
        SubtitleTimingPlanner.timingTokens(text)
    }

    func speechAlignedVisibleSeconds(_ text: String) -> Double {
        SubtitleTimingPlanner.speechAlignedVisibleSeconds(text, endsSentence: endsSentence(text))
    }

    struct TokenTiming {
        let token: String
        let start: Double
        let end: Double
        let fragmentIndex: Int
        let fragmentStart: Double
        let fragmentEnd: Double
    }

    func effectiveFragmentEnd(
        _ fragment: Fragment,
        speechAlignTimings: Bool,
        isTerminalSourceFragment: Bool,
        itemTokenCount: Int
    ) -> Double {
        let duration = fragment.end - fragment.start
        let tokenCount = timingUnits(fragment.text).count
        guard speechAlignTimings,
              tokenCount > 0,
              (tokenCount <= 3 || duration > normalReadableCueSeconds) else {
            return fragment.end
        }
        if isTerminalSourceFragment, itemTokenCount > tokenCount {
            return fragment.end
        }
        if tokenCount <= 3, duration <= SubtitleTimingPlanner.shortSourceFragmentWindowSeconds {
            return fragment.end
        }
        return min(fragment.end, fragment.start + speechAlignedVisibleSeconds(fragment.text))
    }

    func tokenTimings(for item: Timed, speechAlignTimings: Bool) -> [TokenTiming] {
        var output: [TokenTiming] = []
        let itemTokenCount = timingUnits(item.text).count
        for (fragmentIndex, fragment) in item.fragments.enumerated() {
            let tokens = timingUnits(fragment.text)
            guard !tokens.isEmpty else { continue }
            let fragmentEnd = max(fragment.start, effectiveFragmentEnd(
                fragment,
                speechAlignTimings: speechAlignTimings,
                isTerminalSourceFragment: fragmentIndex == item.fragments.count - 1,
                itemTokenCount: itemTokenCount
            ))
            let duration = fragmentEnd - fragment.start
            for tokenIndex in tokens.indices {
                let tokenStart = fragment.start + duration * Double(tokenIndex) / Double(tokens.count)
                let tokenEnd = fragment.start + duration * Double(tokenIndex + 1) / Double(tokens.count)
                output.append(TokenTiming(
                    token: tokens[tokenIndex],
                    start: tokenStart,
                    end: tokenEnd,
                    fragmentIndex: fragmentIndex,
                    fragmentStart: fragment.start,
                    fragmentEnd: fragmentEnd
                ))
            }
        }
        return output
    }

    func alignedTokenRange(pieceTokens: [String], timings: [TokenTiming], from cursor: Int) -> Range<Int>? {
        guard let firstToken = pieceTokens.first else { return nil }
        let lowerBound = max(0, cursor)
        guard lowerBound < timings.count else { return nil }

        for candidateStart in lowerBound..<timings.count where timings[candidateStart].token == firstToken {
            var searchIndex = candidateStart
            var matchedLast = candidateStart
            var didMatch = true
            for token in pieceTokens {
                while searchIndex < timings.count, timings[searchIndex].token != token {
                    searchIndex += 1
                }
                guard searchIndex < timings.count else {
                    didMatch = false
                    break
                }
                matchedLast = searchIndex
                searchIndex += 1
            }
            if didMatch {
                return candidateStart..<(matchedLast + 1)
            }
        }
        return nil
    }

    func splitSentencePieces(_ text: String) -> [String] {
        var pieces: [String] = []
        var current = ""
        let chars = Array(text)
        for index in chars.indices {
            let char = chars[index]
            current.append(char)
            guard sentenceEnders.contains(char) else { continue }
            if char == ".",
               index > chars.startIndex,
               index < chars.index(before: chars.endIndex),
               chars[chars.index(before: index)].isNumber,
               chars[chars.index(after: index)].isNumber {
                continue
            }
            let piece = collapseSubtitleWhitespace(current)
            if !piece.isEmpty { pieces.append(piece) }
            current = ""
        }
        let tail = collapseSubtitleWhitespace(current)
        if !tail.isEmpty { pieces.append(tail) }
        return pieces
    }

    func packPiecesByWeight(_ pieces: [String], targetParts: Int) -> [String] {
        guard targetParts > 1 else { return [collapseSubtitleWhitespace(pieces.joined(separator: " "))] }
        let totalWeight = max(1, pieces.map(textWeight).reduce(0, +))
        var output: [String] = []
        var start = 0
        var emittedWeight = 0
        for part in 0..<targetParts {
            let remainingParts = targetParts - part
            let remainingPieces = pieces.count - start
            var end = start
            var currentWeight = 0
            let targetWeight = Int(ceil(Double(totalWeight - emittedWeight) / Double(remainingParts)))
            while end < pieces.count, remainingPieces - (end - start) > remainingParts - 1 {
                currentWeight += textWeight(pieces[end])
                end += 1
                if currentWeight >= targetWeight { break }
            }
            if end == start { end += 1 }
            let piece = collapseSubtitleWhitespace(pieces[start..<end].joined(separator: " "))
            if !piece.isEmpty {
                output.append(piece)
                emittedWeight += textWeight(piece)
            }
            start = end
        }
        return output
    }

    func lastMeaningfulCharacter(_ text: String) -> Character? {
        text.trimmingCharacters(in: .whitespacesAndNewlines).reversed().first { char in
            !trailingAllowed.contains(char) && char != " "
        }
    }

    func semanticBoundaryBonus(leftToken: String) -> Double {
        guard let last = lastMeaningfulCharacter(leftToken) else { return 0 }
        if sentenceEnders.contains(last) { return 400 }
        if [",", "，"].contains(last) { return 140 }
        if [";", "；", ":", "：", "-", "–", "—"].contains(last) { return 220 }
        return 0
    }

    func isBadBoundary(leftToken: String, rightToken: String) -> Bool {
        SubtitleTimingPlanner.isWeakBoundary(leftToken: leftToken, rightToken: rightToken)
    }

    func startsLikeNewSentence(_ text: String) -> Bool {
        let skippableOpeners: Set<Character> = ["\"", "'", "“", "‘", "(", "（", "¿", "¡"]
        for char in text.trimmingCharacters(in: .whitespacesAndNewlines) {
            if skippableOpeners.contains(char) { continue }
            let scalars = String(char).unicodeScalars
            if scalars.contains(where: { CharacterSet.letters.contains($0) }) {
                return scalars.contains(where: { CharacterSet.uppercaseLetters.contains($0) })
            }
            if scalars.contains(where: { CharacterSet.decimalDigits.contains($0) }) {
                return true
            }
            return false
        }
        return false
    }

    func splitTextByCharacters(_ text: String, targetParts: Int) -> [String] {
        let chars = Array(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !chars.isEmpty else { return [] }
        let parts = min(SubtitleTimingPlanner.characterSplitPartCount(text: text, requestedParts: targetParts), chars.count)
        return (0..<parts).compactMap { part in
            let start = chars.count * part / parts
            let end = part == parts - 1 ? chars.count : chars.count * (part + 1) / parts
            let piece = String(chars[start..<end]).trimmingCharacters(in: .whitespaces)
            return piece.isEmpty ? nil : piece
        }
    }

    func chooseSemanticBoundary(
        words: [String],
        previous: Int,
        remainingParts: Int,
        desired: Double,
        allowBad: Bool
    ) -> Int? {
        let minWordsPerPiece = words.count - previous >= (remainingParts + 1) * 2 ? 2 : 1
        let minBoundary = previous + minWordsPerPiece
        let maxBoundary = words.count - remainingParts * minWordsPerPiece
        guard minBoundary <= maxBoundary else { return nil }

        var best: (index: Int, score: Double, bad: Bool)?
        for boundary in minBoundary...maxBoundary {
            let leftToken = words[boundary - 1]
            let rightToken = words[boundary]
            let bad = isBadBoundary(leftToken: leftToken, rightToken: rightToken)
            if bad && !allowBad { continue }

            let leftCount = boundary - previous
            let rightCount = words.count - boundary
            let shortEdgePenalty = Double(max(0, 3 - min(leftCount, rightCount))) * 45
            let score = abs(Double(boundary) - desired) * 10
                + shortEdgePenalty
                + (bad ? 75 : 0)
                - semanticBoundaryBonus(leftToken: leftToken)
            if best == nil || score < best!.score {
                best = (boundary, score, bad)
            }
        }
        return best?.index
    }

    func splitTextSemantically(_ text: String, targetParts: Int, mustSplit: Bool) -> [String] {
        let targetParts = max(1, targetParts)
        guard targetParts > 1 else { return [collapseSubtitleWhitespace(text)] }

        let words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard words.count >= targetParts else {
            if speechTokens(text).isEmpty, SubtitleTimingPlanner.containsCJKText(text) {
                return splitTextByCharacters(text, targetParts: targetParts)
            }
            return mustSplit ? splitTextByCharacters(text, targetParts: targetParts) : [collapseSubtitleWhitespace(text)]
        }

        var boundaries: [Int] = []
        var previous = 0
        for part in 1..<targetParts {
            let remainingParts = targetParts - part
            let desired = Double(words.count) * Double(part) / Double(targetParts)
            if let boundary = chooseSemanticBoundary(
                words: words,
                previous: previous,
                remainingParts: remainingParts,
                desired: desired,
                allowBad: mustSplit
            ) {
                boundaries.append(boundary)
                previous = boundary
                continue
            }

            guard mustSplit,
                  let fallback = chooseSemanticBoundary(
                    words: words,
                    previous: previous,
                    remainingParts: remainingParts,
                    desired: desired,
                    allowBad: true
                  ) else {
                return [collapseSubtitleWhitespace(text)]
            }
            boundaries.append(fallback)
            previous = fallback
        }

        var output: [String] = []
        var start = 0
        for boundary in boundaries + [words.count] {
            let piece = collapseSubtitleWhitespace(words[start..<boundary].joined(separator: " "))
            if !piece.isEmpty { output.append(piece) }
            start = boundary
        }
        return output.count > 1 ? output : [collapseSubtitleWhitespace(text)]
    }

    func splitReadableText(_ text: String, targetParts: Int, mustSplit: Bool) -> [String] {
        let targetParts = max(1, targetParts)
        let sentences = splitSentencePieces(text)
        if sentences.count >= targetParts {
            return packPiecesByWeight(sentences, targetParts: targetParts)
        }
        if sentences.count > 1 {
            return sentences
        }
        return splitTextSemantically(text, targetParts: targetParts, mustSplit: mustSplit)
    }

    func firstMeaningfulCharacter(_ text: String) -> Character? {
        text.trimmingCharacters(in: .whitespacesAndNewlines).first { char in
            !trailingAllowed.contains(char) && char != " "
        }
    }

    func isSmallKanaContinuation(_ char: Character) -> Bool {
        let smallKana: Set<Character> = [
            "ぁ", "ぃ", "ぅ", "ぇ", "ぉ", "っ", "ゃ", "ゅ", "ょ", "ゎ",
            "ァ", "ィ", "ゥ", "ェ", "ォ", "ッ", "ャ", "ュ", "ョ", "ヮ",
            "ー"
        ]
        return smallKana.contains(char)
    }

    func cjkSourceBoundaryPenalty(leftText: String, rightText: String) -> Double {
        guard SubtitleTimingPlanner.containsCJKText(leftText + rightText) else { return 0 }
        let leftWeight = timingUnits(leftText).count
        let rightWeight = timingUnits(rightText).count
        var penalty = 0.0

        if leftWeight <= 1 || rightWeight <= 1 {
            penalty += 320
        } else if leftWeight <= 2 || rightWeight <= 2 {
            penalty += 110
        }

        if let left = lastMeaningfulCharacter(leftText), isSmallKanaContinuation(left) {
            penalty += 900
        }
        if let right = firstMeaningfulCharacter(rightText), isSmallKanaContinuation(right) {
            penalty += 900
        }
        return penalty
    }

    func sourceAnchoredCJKReadablePieces(_ item: Timed, targetParts: Int) -> [String]? {
        let targetParts = max(2, targetParts)
        let units = item.fragments.map { collapseSubtitleWhitespace($0.text) }.filter { !$0.isEmpty }
        guard units.count >= targetParts,
              SubtitleTimingPlanner.containsCJKText(item.text),
              speechTokens(item.text).isEmpty else {
            return nil
        }

        let unitTokens = timingUnits(units.joined())
        let itemTokens = timingUnits(item.text)
        guard !unitTokens.isEmpty, unitTokens == itemTokens else { return nil }

        let weights = units.map { max(1, timingUnits($0).count) }
        let totalWeight = weights.reduce(0, +)
        guard totalWeight >= targetParts else { return nil }
        let prefixWeights = weights.reduce(into: [0]) { partial, weight in
            partial.append((partial.last ?? 0) + weight)
        }

        var boundaries: [Int] = []
        var previous = 0
        for part in 1..<targetParts {
            let remainingParts = targetParts - part
            let minBoundary = previous + 1
            let maxBoundary = units.count - remainingParts
            guard minBoundary <= maxBoundary else { return nil }

            let desired = Double(totalWeight) * Double(part) / Double(targetParts)
            var best: (boundary: Int, score: Double)?
            for boundary in minBoundary...maxBoundary {
                let currentWeight = prefixWeights[boundary] - prefixWeights[previous]
                let remainingWeight = totalWeight - prefixWeights[boundary]
                let shortPiecePenalty = Double(max(0, 4 - min(currentWeight, remainingWeight))) * 55
                let score = abs(Double(prefixWeights[boundary]) - desired) * 10
                    + shortPiecePenalty
                    + cjkSourceBoundaryPenalty(leftText: units[boundary - 1], rightText: units[boundary])
                if best == nil || score < best!.score {
                    best = (boundary, score)
                }
            }
            guard let chosen = best?.boundary else { return nil }
            boundaries.append(chosen)
            previous = chosen
        }

        var output: [String] = []
        var start = 0
        for boundary in boundaries + [units.count] {
            let piece = collapseSubtitleWhitespace(units[start..<boundary].joined(separator: " "))
            if !piece.isEmpty { output.append(piece) }
            start = boundary
        }
        return output.count > 1 ? output : nil
    }

    func isPunctuationIsland(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 4 else { return false }
        return trimmed.unicodeScalars.allSatisfy { scalar in
            CharacterSet.punctuationCharacters.contains(scalar)
                || CharacterSet.symbols.contains(scalar)
        }
    }

    func appendPunctuationIsland(_ punctuation: String, to text: String) -> String {
        let punctuation = punctuation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !punctuation.isEmpty else { return text }
        if punctuation.first == "-" || punctuation.first == "–" || punctuation.first == "—" {
            return collapseSubtitleWhitespace(text + " " + punctuation)
        }
        return collapseSubtitleWhitespace(text) + punctuation
    }

    func collapsePunctuationIslands(_ items: [Timed]) -> [Timed] {
        var output: [Timed] = []
        var pendingPrefix: Timed?
        for item in items {
            if isPunctuationIsland(item.text) {
                if var previous = output.popLast() {
                    previous.text = appendPunctuationIsland(item.text, to: previous.text)
                    previous.end = max(previous.end, item.end)
                    previous.order = output.count
                    output.append(previous)
                } else {
                    pendingPrefix = item
                }
                continue
            }

            var current = item
            if let prefix = pendingPrefix {
                current.start = min(prefix.start, current.start)
                current.text = collapseSubtitleWhitespace(prefix.text + " " + current.text)
                pendingPrefix = nil
            }
            current.order = output.count
            output.append(current)
        }
        return output
    }

    func rebalanceHandoffBoundaries(_ items: [Timed]) -> [Timed] {
        guard items.count >= 2 else { return items }
        var adjusted = items
        for index in 0..<(adjusted.count - 1) {
            let previous = adjusted[index]
            let next = adjusted[index + 1]
            if abs(next.start - previous.end) <= 0.05,
               SubtitleTimingPlanner.shouldBorrowBoundaryForHandoff(
                    previousText: previous.text,
                    nextText: next.text
               ) {
                let borrow = min(
                    SubtitleTimingPlanner.handoffBoundaryBorrowSeconds,
                    max(0, previous.end - previous.start - minDuration)
                )
                guard borrow > 0 else { continue }
                let boundary = previous.end - borrow
                adjusted[index].end = boundary
                adjusted[index].fragments = [Fragment(start: previous.start, end: boundary, text: previous.text)]
                adjusted[index + 1].start = boundary
                adjusted[index + 1].fragments = [Fragment(start: boundary, end: next.end, text: next.text)]
                continue
            }

            let handoffGap = next.start - previous.end
            guard handoffGap >= -0.001,
                  handoffGap <= SubtitleTimingPlanner.sentenceHandoffGapSeconds + 0.02,
                  endsSentence(previous.text),
                  startsLikeNewSentence(next.text) else {
                continue
            }
            let forward = min(
                SubtitleTimingPlanner.sentenceHandoffForwardSeconds,
                max(0, next.end - next.start - minDuration)
            )
            guard forward > 0 else { continue }
            let boundary = min(next.start + forward, next.end - minDuration)
            guard boundary > previous.end + 0.001 else { continue }
            adjusted[index].end = boundary
            adjusted[index].fragments = [Fragment(start: previous.start, end: boundary, text: previous.text)]
            adjusted[index + 1].start = boundary
            adjusted[index + 1].fragments = [Fragment(start: boundary, end: next.end, text: next.text)]
        }
        return adjusted
    }

    func mergeShortContinuationPrefixes(_ items: [Timed]) -> [Timed] {
        guard items.count >= 2 else { return items }
        var output: [Timed] = []
        var index = 0
        func containsDecimalDigit(_ text: String) -> Bool {
            text.unicodeScalars.contains { CharacterSet.decimalDigits.contains($0) }
        }
        func isDecimalDigit(_ character: Character?) -> Bool {
            guard let character else { return false }
            return String(character).unicodeScalars.contains { CharacterSet.decimalDigits.contains($0) }
        }
        func firstTokenLooksLikeContinuationTail(_ text: String, tokens: [String]) -> Bool {
            guard !tokens.isEmpty else { return false }
            if tokens.contains(where: containsDecimalDigit) { return true }
            guard let first = firstMeaningfulCharacter(text) else { return false }
            let scalars = String(first).unicodeScalars
            return scalars.contains { CharacterSet.lowercaseLetters.contains($0) }
        }
        func containsNumericToken(_ tokens: [String]) -> Bool {
            tokens.contains(where: containsDecimalDigit)
        }
        func endsWithNumericDecimalPrefix(_ text: String) -> Bool {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.last == ".", let beforeDot = trimmed.dropLast().last else { return false }
            return isDecimalDigit(beforeDot)
        }
        while index < items.count {
            if index + 1 < items.count {
                let current = items[index]
                let next = items[index + 1]
                let currentTokens = wordTokens(current.text)
                let nextTokens = wordTokens(next.text)
                let combinedDuration = next.end - current.start
                let handoffGap = next.start - current.end
                let weakPair: Bool
                if let last = currentTokens.last, let first = nextTokens.first {
                    weakPair = SubtitleTimingPlanner.isWeakBoundary(leftToken: last, rightToken: first)
                } else {
                    weakPair = false
                }
                let shortContinuationPrefix = currentTokens.count >= 2
                    && currentTokens.count <= 3
                    && !endsSentence(current.text)
                    && weakPair
                let orphanTail = !endsSentence(current.text)
                    && currentTokens.count >= 2
                    && nextTokens.count <= 2
                    && firstTokenLooksLikeContinuationTail(next.text, tokens: nextTokens)
                let modelContinuationPrefix = !endsSentence(current.text)
                    && currentTokens.count >= 1
                    && currentTokens.count <= 3
                    && containsNumericToken(nextTokens)
                let numericContinuation = endsWithNumericDecimalPrefix(current.text)
                    && isDecimalDigit(nextTokens.first?.first)
                if (shortContinuationPrefix || orphanTail || modelContinuationPrefix || numericContinuation),
                   handoffGap >= -0.001,
                   handoffGap <= 0.12,
                   combinedDuration <= normalReadableCueSeconds {
                    output.append(Timed(
                        start: current.start,
                        end: max(current.end, next.end),
                        text: collapseSubtitleWhitespace(current.text + " " + next.text),
                        order: output.count,
                        fragments: current.fragments + next.fragments,
                        hasSourceAnchors: current.hasSourceAnchors || next.hasSourceAnchors
                    ))
                    index += 2
                    continue
                }
            }
            var item = items[index]
            item.order = output.count
            output.append(item)
            index += 1
        }
        return output
    }

    func mergeShortCJKSingletons(_ items: [Timed]) -> [Timed] {
        guard items.count >= 2 else { return items }
        var output: [Timed] = []
        var index = 0
        while index < items.count {
            if index + 1 < items.count {
                let current = items[index]
                let next = items[index + 1]
                let currentUnits = timingUnits(current.text).count
                let nextUnits = timingUnits(next.text).count
                let handoffGap = next.start - current.end
                let combinedDuration = next.end - current.start
                if SubtitleTimingPlanner.containsCJKText(current.text + next.text),
                   (currentUnits <= 1 || nextUnits <= 1),
                   currentUnits + nextUnits <= 4,
                   handoffGap >= -0.001,
                   handoffGap <= 0.12,
                   combinedDuration <= SubtitleTimingPlanner.shortSourceFragmentWindowSeconds {
                    output.append(Timed(
                        start: current.start,
                        end: max(current.end, next.end),
                        text: collapseSubtitleWhitespace(current.text + next.text),
                        order: output.count,
                        fragments: current.fragments + next.fragments,
                        hasSourceAnchors: current.hasSourceAnchors || next.hasSourceAnchors
                    ))
                    index += 2
                    continue
                }
            }
            var item = items[index]
            item.order = output.count
            output.append(item)
            index += 1
        }
        return output
    }

    func compactDuplicateKey(_ text: String) -> String {
        text.filter { !$0.isWhitespace }
    }

    func dropUltraShortCJKDuplicateTransitions(_ items: [Timed]) -> [Timed] {
        guard items.count >= 2 else { return items }
        var output: [Timed] = []
        for index in items.indices {
            let item = items[index]
            let key = compactDuplicateKey(item.text)
            if item.end - item.start <= 0.08,
               !key.isEmpty,
               SubtitleTimingPlanner.containsCJKText(item.text) {
                let previousKey = output.last.map { compactDuplicateKey($0.text) } ?? ""
                let nextKey = index + 1 < items.count ? compactDuplicateKey(items[index + 1].text) : ""
                if (!previousKey.isEmpty && previousKey.contains(key))
                    || (!nextKey.isEmpty && nextKey.contains(key)) {
                    continue
                }
            }
            var copy = item
            copy.order = output.count
            output.append(copy)
        }
        return output
    }

    func sourceAnchoredPieces(_ pieces: [String], item: Timed, speechAlignTimings: Bool) -> [Timed]? {
        let timings = tokenTimings(for: item, speechAlignTimings: speechAlignTimings)
        guard !pieces.isEmpty, !timings.isEmpty else { return nil }

        var output: [Timed] = []
        var cursor = 0
        var previousEnd = item.start
        var previousEndedSentence = false
        for piece in pieces {
            let pieceTokens = timingUnits(piece)
            let pieceTokenCount = pieceTokens.count
            guard pieceTokenCount > 0, cursor < timings.count else { return nil }
            let endCursor: Int
            if let alignedRange = alignedTokenRange(pieceTokens: pieceTokens, timings: timings, from: cursor) {
                cursor = alignedRange.lowerBound
                endCursor = alignedRange.upperBound
            } else {
                endCursor = min(cursor + pieceTokenCount, timings.count)
            }
            guard endCursor > cursor else { return nil }
            let covered = Array(timings[cursor..<endCursor])
            guard let first = covered.first, let last = covered.last else { return nil }

            var start = first.start
            let firstFragmentIndex = first.fragmentIndex
            let firstFragmentCount = covered.prefix { $0.fragmentIndex == firstFragmentIndex }.count
            let firstFragmentTokenCount = timingUnits(item.fragments[firstFragmentIndex].text).count
            if cursor > 0,
               firstFragmentTokenCount > firstFragmentCount,
               (firstFragmentCount <= 2 || startsLikeNewSentence(piece)),
               firstFragmentCount * 2 < covered.count,
               let later = covered.first(where: { $0.fragmentIndex != firstFragmentIndex }) {
                start = later.fragmentStart
            }
            start = max(start, previousEnd)
            if previousEndedSentence {
                start = min(max(start, previousEnd + SubtitleTimingPlanner.sentenceHandoffGapSeconds), last.end)
            }

            var end = last.end
            if endsSentence(piece) {
                end = max(end, min(last.fragmentEnd, end + 0.35))
            } else if endCursor < timings.count {
                end = min(max(end, end + 0.12), timings[endCursor].start)
            }
            end = max(end, start)

            output.append(Timed(
                start: start,
                end: end,
                text: piece,
                order: output.count,
                fragments: [Fragment(start: start, end: end, text: piece)],
                hasSourceAnchors: true
            ))
            previousEnd = end
            previousEndedSentence = endsSentence(piece)
            cursor = endCursor
        }
        return output
    }

    func splitLongReadableCues(_ items: [Timed], collapsePunctuation: Bool, speechAlignTimings: Bool) -> [Timed] {
        var output: [Timed] = []
        for item in items {
            let originalDuration = item.end - item.start
            let visibleLines = item.text
                .split(separator: "\n", omittingEmptySubsequences: true)
            if !collapsePunctuation,
               !speechAlignTimings,
               originalDuration <= emergencyReadableCueSeconds,
               visibleLines.count > 1,
               SubtitleTimingPlanner.containsCJKText(item.text) {
                output.append(Timed(
                    start: item.start,
                    end: item.end,
                    text: item.text,
                    order: output.count,
                    fragments: item.fragments,
                    hasSourceAnchors: item.hasSourceAnchors
                ))
                continue
            }
            let wordCount = wordTokens(item.text).count
            let cjkUnitCount = speechTokens(item.text).isEmpty && SubtitleTimingPlanner.containsCJKText(item.text)
                ? timingUnits(item.text).count
                : 0
            let canUseSourceAnchors = speechAlignTimings
                && !item.fragments.isEmpty
                && (item.hasSourceAnchors || originalDuration <= hardDuration)
            let shouldAlignToSpeech = SubtitleTimingPlanner.shouldAlignToSpeechWindow(
                text: item.text,
                originalDuration: originalDuration,
                speechAlignTimings: speechAlignTimings,
                canUseSourceAnchors: canUseSourceAnchors,
                endsSentence: endsSentence(item.text)
            )
            let effectiveEnd = shouldAlignToSpeech
                ? min(item.end, item.start + speechAlignedVisibleSeconds(item.text))
                : item.end
            let effectiveItem = Timed(
                start: item.start,
                end: effectiveEnd,
                text: item.text,
                order: item.order,
                fragments: item.fragments,
                hasSourceAnchors: item.hasSourceAnchors
            )
            let sentenceDrivenTargetParts = canUseSourceAnchors ? splitSentencePieces(effectiveItem.text).count : 1
            let anchoredTimings = canUseSourceAnchors
                ? tokenTimings(for: effectiveItem, speechAlignTimings: speechAlignTimings)
                : []
            let duration = anchoredTimings.isEmpty
                ? effectiveItem.end - effectiveItem.start
                : max(0, (anchoredTimings.last?.end ?? effectiveItem.end) - (anchoredTimings.first?.start ?? effectiveItem.start))
            let hasCJKWhitespaceWordBoundaries = cjkUnitCount > 0
                && SubtitleTimingPlanner.containsHangulText(item.text)
                && item.text.split(whereSeparator: { $0.isWhitespace }).count > 1
            let noAnchorUnspacedCJK = cjkUnitCount > 0 && !canUseSourceAnchors && !hasCJKWhitespaceWordBoundaries
            let cjkReadableSplitThreshold = canUseSourceAnchors
                ? 4.0
                : (noAnchorUnspacedCJK ? hardDuration : emergencyReadableCueSeconds)
            let shouldSplitCJKByReadableWindow = cjkUnitCount > 18
                && duration > cjkReadableSplitThreshold
            let textDrivenTargetParts = wordCount > 18
                ? Int(ceil(Double(wordCount) / 14.0))
                : (shouldSplitCJKByReadableWindow ? Int(ceil(Double(cjkUnitCount) / 14.0)) : 1)
            let durationSplitThreshold = noAnchorUnspacedCJK
                ? hardDuration
                : normalReadableCueSeconds
            let durationDrivenTargetParts = duration > durationSplitThreshold
                ? Int(ceil(duration / durationSplitThreshold))
                : 1
            var targetParts = max(durationDrivenTargetParts, textDrivenTargetParts, sentenceDrivenTargetParts)
            guard targetParts > 1 else {
                if canUseSourceAnchors,
                   let anchored = sourceAnchoredPieces([effectiveItem.text], item: effectiveItem, speechAlignTimings: speechAlignTimings) {
                    output.append(contentsOf: anchored.map {
                        Timed(
                            start: $0.start,
                            end: $0.end,
                            text: $0.text,
                            order: output.count + $0.order,
                            fragments: $0.fragments,
                            hasSourceAnchors: $0.hasSourceAnchors
                        )
                    })
                } else {
                    output.append(Timed(
                        start: effectiveItem.start,
                        end: effectiveItem.end,
                        text: effectiveItem.text,
                        order: output.count,
                        fragments: effectiveItem.fragments,
                        hasSourceAnchors: effectiveItem.hasSourceAnchors
                    ))
                }
                continue
            }

            targetParts = max(2, targetParts)
            let balancedMaxParts = max(2, wordCount / 2)
            let maxTargetParts = max(targetParts, balancedMaxParts)
            func readablePieces(for partCount: Int, mustSplit: Bool) -> [String] {
                if canUseSourceAnchors,
                   cjkUnitCount > 0,
                   let anchoredCJKPieces = sourceAnchoredCJKReadablePieces(effectiveItem, targetParts: partCount) {
                    return anchoredCJKPieces
                }
                return splitReadableText(
                    effectiveItem.text,
                    targetParts: partCount,
                    mustSplit: mustSplit
                )
            }

            var pieces = readablePieces(
                for: targetParts,
                mustSplit: duration > emergencyReadableCueSeconds
            )
            while pieces.count > 1,
                  targetParts < maxTargetParts {
                let totalWeight = max(1, pieces.map(textWeight).reduce(0, +))
                let longestEstimatedDuration = pieces
                    .map { duration * Double(textWeight($0)) / Double(totalWeight) }
                    .max() ?? 0
                guard longestEstimatedDuration > emergencyReadableCueSeconds else { break }
                targetParts += 1
                pieces = readablePieces(for: targetParts, mustSplit: true)
            }
            guard pieces.count > 1 else {
                if canUseSourceAnchors,
                   let anchored = sourceAnchoredPieces([effectiveItem.text], item: effectiveItem, speechAlignTimings: speechAlignTimings) {
                    output.append(contentsOf: anchored.map {
                        Timed(
                            start: $0.start,
                            end: $0.end,
                            text: $0.text,
                            order: output.count + $0.order,
                            fragments: $0.fragments,
                            hasSourceAnchors: $0.hasSourceAnchors
                        )
                    })
                } else {
                    output.append(Timed(
                        start: effectiveItem.start,
                        end: effectiveItem.end,
                        text: effectiveItem.text,
                        order: output.count,
                        fragments: effectiveItem.fragments,
                        hasSourceAnchors: effectiveItem.hasSourceAnchors
                    ))
                }
                continue
            }

            if canUseSourceAnchors,
               let anchored = sourceAnchoredPieces(pieces, item: effectiveItem, speechAlignTimings: speechAlignTimings) {
                output.append(contentsOf: anchored.map {
                    Timed(
                        start: $0.start,
                        end: $0.end,
                        text: $0.text,
                        order: output.count + $0.order,
                        fragments: $0.fragments,
                        hasSourceAnchors: $0.hasSourceAnchors
                    )
                })
                continue
            }

            let totalWeight = max(1, pieces.map(textWeight).reduce(0, +))
            var emittedWeight = 0
            for (index, piece) in pieces.enumerated() {
                let pieceWeight = textWeight(piece)
                let start = index == 0
                    ? effectiveItem.start
                    : effectiveItem.start + duration * Double(emittedWeight) / Double(totalWeight)
                emittedWeight += pieceWeight
                var end = index == pieces.count - 1
                    ? effectiveItem.end
                    : effectiveItem.start + duration * Double(emittedWeight) / Double(totalWeight)
                if end < start { end = start }
                output.append(Timed(
                    start: start,
                    end: end,
                    text: piece,
                    order: output.count,
                    fragments: [Fragment(start: start, end: end, text: piece)],
                    hasSourceAnchors: false
                ))
            }
        }
        let mergedContinuations = mergeShortContinuationPrefixes(output)
        let mergedCJKSingletons = mergeShortCJKSingletons(mergedContinuations)
        let dedupedTransitions = dropUltraShortCJKDuplicateTransitions(mergedCJKSingletons)
        return collapsePunctuation ? collapsePunctuationIslands(dedupedTransitions) : dedupedTransitions
    }

    func isSingleFragmentVTTSource(_ item: Timed) -> Bool {
        guard item.hasSourceAnchors, item.fragments.count == 1, let fragment = item.fragments.first else {
            return false
        }
        return collapseSubtitleWhitespace(fragment.text) == collapseSubtitleWhitespace(item.text)
    }

    func trimNoInlineVTTCJKIdleTails(_ items: [Timed]) -> [Timed] {
        guard items.count >= 2 else { return items }
        var adjusted = items
        for index in adjusted.indices {
            var item = adjusted[index]
            let duration = item.end - item.start
            let cjkUnits = timingUnits(item.text).count
            guard isSingleFragmentVTTSource(item),
                  SubtitleTimingPlanner.containsCJKText(item.text),
                  cjkUnits >= 8,
                  duration > 3.5 else {
                continue
            }

            var changed = false
            if index + 1 < adjusted.count {
                let nextGap = adjusted[index + 1].start - item.end
                let characterDensity = Double(cjkUnits) / max(duration, 0.001)
                let tailTrim = min(1.6, max(0, (3.75 - characterDensity) * 0.95))
                if nextGap > 0.03, tailTrim >= 0.08 {
                    item.end = max(item.start + minDuration, item.end - tailTrim)
                    changed = true
                }
            }

            if index > 0 {
                let previousGap = item.start - adjusted[index - 1].end
                let characterDensity = Double(cjkUnits) / max(duration, 0.001)
                let delay = min(0.35, max(0, item.end - item.start - minDuration))
                if previousGap > 0.15, characterDensity >= 3.35, delay >= 0.08 {
                    item.start += delay
                    changed = true
                }
            }

            if changed {
                item.fragments = [Fragment(start: item.start, end: item.end, text: item.text)]
                adjusted[index] = item
            }
        }
        return adjusted
    }

    // 非滚动字幕：只做去重叠，不做滚动合并；但仍应用可读窗口兜底，避免原始长 cue 拖住画面。
    guard isRolling else {
        let timingAdjusted = trimNoInlineVTTCJKIdleTails(timed)
        let readable = splitLongReadableCues(timingAdjusted, collapsePunctuation: false, speechAlignTimings: false)
        return makeCues(rebalanceHandoffBoundaries(readable))
    }

    for i in timed.indices {
        let t = timed[i]
        let piece = collapseSubtitleWhitespace(t.text)
            if !hasCurrent {
                curText = piece
                curStart = t.start
                curEnd = t.end
                curFragments = t.fragments
                curHasSourceAnchors = t.hasSourceAnchors
                hasCurrent = true
            } else {
                curText = collapseSubtitleWhitespace(curText + " " + piece)
                curEnd = t.end
                curFragments.append(contentsOf: t.fragments)
                curHasSourceAnchors = curHasSourceAnchors || t.hasSourceAnchors
            }
        let nextPiece = i + 1 < timed.count ? collapseSubtitleWhitespace(timed[i + 1].text) : nil
        let nextGap = i + 1 < timed.count ? timed[i + 1].start - curEnd : nil
        let hardLimitReached = (curEnd - curStart) >= hardDuration || curText.count >= hardCharacterBudget
        let softLimitReached = (curEnd - curStart) >= softDuration || curText.count >= softCharacterBudget
        let shouldHoldForContinuation = looksLikeContinuation(current: curText, nextPiece: nextPiece)
        if endsSentence(curText)
            || (nextGap ?? 0) > 1.2
            || hardLimitReached
            || (softLimitReached && !shouldHoldForContinuation) {
            flush()
        }
    }
    flush()

    // (d) 防误伤：合并后条数没减少则放弃合并。
    // (f) 可读窗口兜底：滚动字幕常把一整句拖成 10s+ 长 cue；即使语义上仍是同一句，
    //     最终可见字幕也要拆到约 6s 以内，避免画面已经变化但字幕还停在上一大段。
    let readable = splitLongReadableCues(
        merged.count < timed.count ? merged : timed,
        collapsePunctuation: true,
        speechAlignTimings: textRepeatRatio > 0.3
    )
    return makeCues(rebalanceHandoffBoundaries(readable))
}

// MARK: - LLM API 请求

/// 一次模型调用的结果：文本 + 是否因为输出上限被截断。
struct ModelReply {
    let text: String
    let reachedOutputLimit: Bool
}

typealias ConfiguredModelSender = @Sendable (
    AppSettings,
    String?,
    String,
    Int,
    TranslationContext
) async throws -> ModelReply

func sendConfiguredMessage(
    settings: AppSettings,
    system: String?,
    userContent: String,
    maxTokens: Int,
    context: TranslationContext = TranslationContext()
) async throws -> ModelReply {
    switch settings.translationEngine {
    case .anthropicCompatible:
        return try await sendAnthropicMessage(
            settings: settings,
            system: system,
            userContent: userContent,
            maxTokens: maxTokens
        )
    case .openAICompatible:
        return try await sendOpenAIChatCompletion(
            settings: settings,
            instructions: system,
            input: userContent,
            maxOutputTokens: maxTokens
        )
    case .appleTranslationLowLatency,
         .appleTranslationHighFidelity,
         .appleFoundationPCC,
        .appleFoundationCloudPro:
        let readiness = settings.translationReadiness(context: context)
        let message = readiness.issues.map(\.message).joined(separator: " ")
        throw MoongateError.translateFailed(message.isEmpty ? TranslatorL10n.engineNotReady : message)
    case .appleFoundationOnDevice:
        return try await sendFoundationModelsMessage(
            system: system,
            userContent: userContent,
            maxTokens: maxTokens
        )
    }
}

private func sendFoundationModelsMessage(
    system: String?,
    userContent: String,
    maxTokens: Int
) async throws -> ModelReply {
    #if canImport(FoundationModels)
    guard #available(macOS 26.0, iOS 26.0, *) else {
        throw MoongateError.translateFailed(TranslatorL10n.unsupportedLocalAppleIntelligenceOS)
    }
    let model = SystemLanguageModel.default
    switch model.availability {
    case .available:
        break
    case .unavailable(.deviceNotEligible):
        throw MoongateError.translateFailed(TranslatorL10n.deviceNotEligibleForAppleIntelligence)
    case .unavailable(.appleIntelligenceNotEnabled):
        throw MoongateError.translateFailed(TranslatorL10n.enableAppleIntelligence)
    case .unavailable(.modelNotReady):
        throw MoongateError.translateFailed(TranslatorL10n.appleIntelligenceModelNotReady)
    @unknown default:
        throw MoongateError.translateFailed(TranslatorL10n.appleIntelligenceUnavailable)
    }

    guard model.supportsLocale(Locale(identifier: "zh-Hans")) else {
        throw MoongateError.translateFailed(TranslatorL10n.unsupportedSimplifiedChineseOutput)
    }

    do {
        let session = LanguageModelSession(model: model, instructions: system)
        let response = try await session.respond(
            to: userContent,
            options: GenerationOptions(temperature: 0.2, maximumResponseTokens: maxTokens)
        )
        let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw MoongateError.translateFailed(TranslatorL10n.appleIntelligenceEmptyReply)
        }
        return ModelReply(text: text, reachedOutputLimit: false)
    } catch let error as MoongateError {
        throw error
    } catch let error as LanguageModelSession.GenerationError {
        throw MoongateError.translateFailed(error.localizedDescription)
    } catch {
        throw MoongateError.translateFailed(error.localizedDescription)
    }
    #else
    throw MoongateError.translateFailed(TranslatorL10n.foundationModelsMissing)
    #endif
}

private func normalizedToken(_ raw: String) -> String {
    var token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    // 用户误把 "Bearer xxx" 整段贴进凭证框时剥掉前缀，避免双重 Bearer。
    if token.lowercased().hasPrefix("bearer ") {
        token = String(token.dropFirst("bearer ".count)).trimmingCharacters(in: .whitespaces)
    }
    return token
}

private enum TranslatorL10n {
    static var engineNotReady: String {
        CoreL10n.text(en: "The current translation engine is not ready.", zhHans: "当前翻译引擎不可运行。", zhHant: "目前翻譯引擎不可執行。")
    }

    static var unsupportedLocalAppleIntelligenceOS: String {
        CoreL10n.text(en: "The current system version does not support local Apple Intelligence.", zhHans: "当前系统版本不支持本地 Apple Intelligence。", zhHant: "目前系統版本不支援本機 Apple Intelligence。")
    }

    static var deviceNotEligibleForAppleIntelligence: String {
        CoreL10n.text(en: "This device does not support Apple Intelligence.", zhHans: "当前设备不支持 Apple Intelligence。", zhHant: "目前裝置不支援 Apple Intelligence。")
    }

    static var enableAppleIntelligence: String {
        CoreL10n.text(en: "Enable Apple Intelligence in System Settings first.", zhHans: "需要先在系统设置中启用 Apple Intelligence。", zhHant: "需要先在系統設定中啟用 Apple Intelligence。")
    }

    static var appleIntelligenceModelNotReady: String {
        CoreL10n.text(en: "The local Apple Intelligence model is not ready yet. Finish downloading it in System Settings.", zhHans: "Apple Intelligence 本地模型尚未就绪，请在系统设置中完成下载。", zhHant: "Apple Intelligence 本機模型尚未就緒，請在系統設定中完成下載。")
    }

    static var appleIntelligenceUnavailable: String {
        CoreL10n.text(en: "Apple Intelligence is currently unavailable.", zhHans: "Apple Intelligence 当前不可用。", zhHant: "Apple Intelligence 目前不可用。")
    }

    static var unsupportedSimplifiedChineseOutput: String {
        CoreL10n.text(en: "Apple Intelligence currently does not support Simplified Chinese output.", zhHans: "Apple Intelligence 当前不支持简体中文输出。", zhHant: "Apple Intelligence 目前不支援簡體中文輸出。")
    }

    static var appleIntelligenceEmptyReply: String {
        CoreL10n.text(en: "Apple Intelligence did not return usable translated text.", zhHans: "Apple Intelligence 没有返回可用译文。", zhHant: "Apple Intelligence 沒有返回可用譯文。")
    }

    static var foundationModelsMissing: String {
        CoreL10n.text(en: "This build does not include FoundationModels.framework.", zhHans: "当前构建不包含 FoundationModels.framework。", zhHant: "目前建置不包含 FoundationModels.framework。")
    }

    static var invalidServiceURL: String {
        CoreL10n.text(en: "Invalid service URL", zhHans: "服务地址无效", zhHant: "服務地址無效")
    }

    static var requestFailed: String {
        CoreL10n.text(en: "Request failed", zhHans: "请求失败", zhHant: "請求失敗")
    }

    static var missingModel: String {
        CoreL10n.text(en: "No model is configured. Enter a model name in Settings.", zhHans: "尚未配置模型，请在设置里填写模型名称。", zhHant: "尚未設定模型，請在設定裡填寫模型名稱。")
    }

    static var missingCredential: String {
        CoreL10n.text(en: "No API credential is configured. Fill it in Settings.", zhHans: "尚未配置 API 凭证，请在设置里填写。", zhHant: "尚未設定 API 憑證，請在設定裡填寫。")
    }

    static var unrecognizedResponse: String {
        CoreL10n.text(en: "The service returned an unrecognized response.", zhHans: "服务返回了无法识别的响应。", zhHant: "服務回傳了無法識別的回應。")
    }

    static var connectionFailed: String {
        CoreL10n.text(en: "Could not connect to the translation service. Check the service URL and network.", zhHans: "无法连接到翻译服务，请检查服务地址和网络。", zhHant: "無法連線到翻譯服務，請檢查服務地址與網路。")
    }

    static var emptySummary: String {
        CoreL10n.text(en: "AI did not return usable summary content. Try again later or switch models.", zhHans: "AI 没有返回可用的总结内容，请稍后重试或更换模型。", zhHant: "AI 沒有返回可用的摘要內容，請稍後重試或更換模型。")
    }

    static var modelListInvalid: String {
        CoreL10n.text(en: "Failed to fetch model list: invalid response.", zhHans: "拉取模型列表失败：无效响应。", zhHant: "拉取模型列表失敗：無效回應。")
    }

    static var modelListEmpty: String {
        CoreL10n.text(en: "The service returned an empty model list. Enter the model name manually.", zhHans: "服务返回的模型列表为空，请手动填写模型名。", zhHant: "服務回傳的模型列表為空，請手動填寫模型名稱。")
    }

    static func cannotReadSubtitle(_ name: String) -> String {
        "\(CoreL10n.text(en: "Could not read subtitle file", zhHans: "无法读取字幕文件", zhHant: "無法讀取字幕檔"))：\(name)"
    }

    static var emptySubtitle: String {
        CoreL10n.text(en: "The subtitle file has no recognizable subtitle content.", zhHans: "字幕文件里没有可识别的字幕内容。", zhHant: "字幕檔裡沒有可識別的字幕內容。")
    }

    static var missingTranslatedLine: String {
        CoreL10n.text(en: "The model response format is invalid: missing translated lines", zhHans: "模型返回格式异常，缺失译文行", zhHant: "模型回傳格式異常，缺少譯文行")
    }

    static var outputLimitReached: String {
        CoreL10n.text(en: "The translation exceeded the model output limit. Reduce subtitle chunk size or check the model max_tokens limit.", zhHans: "译文超出模型输出上限，请减小每块字幕条数或检查模型 max_tokens 限制", zhHant: "譯文超出模型輸出上限，請減小每塊字幕條數或檢查模型 max_tokens 限制")
    }

    static var smartPromptNeedsSummaryModel: String {
        CoreL10n.text(en: "Enhanced mode requires a summary model that can generate text. Choose a cloud API or local Apple Intelligence in AI summary settings.", zhHans: "增强模式需要可生成文本的总结模型，请在 AI 总结设置里选择云端 API 或本地 Apple Intelligence。", zhHant: "增強模式需要可生成文字的摘要模型，請在 AI 摘要設定裡選擇雲端 API 或本機 Apple Intelligence。")
    }

    static var smartAnalysisInvalid: String {
        CoreL10n.text(en: "Enhanced mode analysis returned an invalid format. Retry or turn off enhanced mode.", zhHans: "增强模式分析返回格式异常，请重试或关闭增强模式。", zhHant: "增強模式分析回傳格式異常，請重試或關閉增強模式。")
    }

    static var truncatedMarker: String {
        CoreL10n.text(en: "...[truncated]", zhHans: "…（已截断）", zhHant: "…（已截斷）")
    }
}

private func endpointURL(baseURL: String, endpointPath: String) throws -> URL {
    var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    while base.hasSuffix("/") { base.removeLast() }

    let path = endpointPath.hasPrefix("/") ? endpointPath : "/" + endpointPath
    let lowerBase = base.lowercased()
    let lowerPath = path.lowercased()
    let urlString: String
    if lowerBase.hasSuffix(lowerPath) {
        urlString = base
    } else if lowerBase.hasSuffix("/v1"), lowerPath.hasPrefix("/v1/") {
        urlString = base + String(path.dropFirst("/v1".count))
    } else {
        urlString = base + path
    }

    guard !base.isEmpty,
          let url = URL(string: urlString),
          let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
          url.host != nil else {
        throw MoongateError.translateFailed(TranslatorL10n.invalidServiceURL)
    }
    return url
}

private func responseErrorMessage(from data: Data) -> String {
    struct ErrorBody: Decodable {
        struct Inner: Decodable {
            let type: String?
            let message: String?
        }
        let error: Inner?
    }
    let decoded = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error?.message
    let fallback = String(decoding: data.prefix(200), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return decoded ?? (fallback.isEmpty ? TranslatorL10n.requestFailed : fallback)
}

private func requestFailureMessage(statusCode: Int, data: Data, settings: AppSettings) -> String {
    let message = responseErrorMessage(from: data)
    let lowerMessage = message.lowercased()
    guard statusCode == 503 || lowerMessage.contains("no available accounts") else {
        return "HTTP \(statusCode)：\(message)"
    }

    let model = settings.translationModel.trimmingCharacters(in: .whitespacesAndNewlines)
    let modelStatus = model.isEmpty
        ? CoreL10n.text(en: "filled in", zhHans: "已填写", zhHant: "已填寫")
        : "「\(model)」"
    return CoreL10n.text(
        en: "HTTP \(statusCode): the gateway has no available account, or the model mapping was not found. Confirm model \(modelStatus) is registered in the company gateway. Click Fetch models and choose a model actually provided by the gateway. Original error: \(message)",
        zhHans: "HTTP \(statusCode)：网关没有可用账号或模型映射未命中。请确认模型名 \(modelStatus) 在公司网关里已登记——点「拉取模型」选一个网关实际提供的模型。原始错误：\(message)",
        zhHant: "HTTP \(statusCode)：閘道沒有可用帳號或模型映射未命中。請確認模型名 \(modelStatus) 已在公司閘道登記，點「拉取模型」選一個閘道實際提供的模型。原始錯誤：\(message)"
    )
}

/// 调一次 Anthropic Messages API，返回回复里所有 type=="text" 块拼接后的文本。
/// 429/5xx 指数退避重试最多 2 次（2s、8s）；其余错误映射为 MoongateError。
func sendAnthropicMessage(
    settings: AppSettings,
    system: String?,
    userContent: String,
    maxTokens: Int
) async throws -> ModelReply {
    let model = settings.translationModel.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !model.isEmpty else {
        throw MoongateError.translateFailed(TranslatorL10n.missingModel)
    }
    let token = normalizedToken(settings.translationAuthToken)
    guard !token.isEmpty else {
        throw MoongateError.translateFailed(TranslatorL10n.missingCredential)
    }

    let url = try endpointURL(baseURL: settings.translationBaseURL, endpointPath: "/v1/messages")
    let host = url.host ?? ""

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 120
    request.setValue("application/json", forHTTPHeaderField: "content-type")
    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    // 官方 API 只认 x-api-key（两个鉴权头同时发会被拒）；其他网关两个都发以求兼容。
    request.setValue(token, forHTTPHeaderField: "x-api-key")
    if host.lowercased() != "api.anthropic.com" {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    struct Message: Encodable {
        let role: String
        let content: String
    }
    struct Payload: Encodable {
        let model: String
        let max_tokens: Int
        let system: String?
        let messages: [Message]
    }
    do {
        request.httpBody = try JSONEncoder().encode(Payload(
            model: model,
            max_tokens: maxTokens,
            system: system,
            messages: [Message(role: "user", content: userContent)]
        ))
    } catch {
        throw MoongateError.translateFailed("\(CoreL10n.text(en: "Could not build request body", zhHans: "无法构造请求体", zhHant: "無法構造請求本文"))：\(error.localizedDescription)")
    }

    let backoffNanoseconds: [UInt64] = [2_000_000_000, 8_000_000_000]
    var attempt = 0
    while true {
        if Task.isCancelled { throw MoongateError.cancelled }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw MoongateError.translateFailed(TranslatorL10n.unrecognizedResponse)
            }
            if http.statusCode == 200 {
                struct Block: Decodable {
                    let type: String
                    let text: String?
                }
                struct Reply: Decodable {
                    let content: [Block]
                    let stop_reason: String?
                }
                guard let reply = try? JSONDecoder().decode(Reply.self, from: data),
                      reply.content.contains(where: { $0.type == "text" }) else {
                    throw MoongateError.translateFailed(CoreL10n.text(
                        en: "The service response does not match the Anthropic Messages protocol. Check the service URL.",
                        zhHans: "服务响应不符合 Anthropic Messages 协议，请检查服务地址。",
                        zhHant: "服務回應不符合 Anthropic Messages 協定，請檢查服務地址。"
                    ))
                }
                let text = reply.content.filter { $0.type == "text" }.compactMap(\.text).joined()
                return ModelReply(text: text, reachedOutputLimit: reply.stop_reason == "max_tokens")
            }
            let retryable = http.statusCode == 429 || (500...599).contains(http.statusCode)
            if retryable, attempt < backoffNanoseconds.count {
                try await Task.sleep(nanoseconds: backoffNanoseconds[attempt])
                attempt += 1
                continue
            }
            throw MoongateError.translateFailed(requestFailureMessage(
                statusCode: http.statusCode,
                data: data,
                settings: settings
            ))
        } catch let error as MoongateError {
            throw error
        } catch is CancellationError {
            throw MoongateError.cancelled
        } catch let error as URLError {
            if error.code == .cancelled { throw MoongateError.cancelled }
            throw MoongateError.translateFailed(TranslatorL10n.connectionFailed)
        } catch {
            throw MoongateError.translateFailed(error.localizedDescription)
        }
    }
}

/// 调一次 OpenAI Chat Completions API（POST {baseURL}/v1/chat/completions）。
/// 这是 OpenAI 协议里最通用的端点：官方、Azure、以及绝大多数"OpenAI 兼容"网关
/// （DeepSeek / OpenRouter / Ollama / vLLM / LM Studio 等）都实现它；
/// 而 /v1/responses 是 OpenAI 的私有新端点，多数兼容服务并不提供，
/// 之前测试连接走 responses 会在这些服务上报错。
/// 429/5xx 指数退避重试最多 2 次（2s、8s）；其余错误映射为 MoongateError。
func sendOpenAIChatCompletion(
    settings: AppSettings,
    instructions: String?,
    input: String,
    maxOutputTokens: Int
) async throws -> ModelReply {
    let model = settings.translationModel.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !model.isEmpty else {
        throw MoongateError.translateFailed(TranslatorL10n.missingModel)
    }
    let token = normalizedToken(settings.translationAuthToken)
    guard !token.isEmpty else {
        throw MoongateError.translateFailed(TranslatorL10n.missingCredential)
    }

    let url = try endpointURL(baseURL: settings.translationBaseURL, endpointPath: "/v1/chat/completions")

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 120
    request.setValue("application/json", forHTTPHeaderField: "content-type")
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

    struct Message: Encodable {
        let role: String
        let content: String
    }
    struct Payload: Encodable {
        let model: String
        let messages: [Message]
        let max_completion_tokens: Int
    }
    var messages: [Message] = []
    if let instructions, !instructions.isEmpty {
        messages.append(Message(role: "system", content: instructions))
    }
    messages.append(Message(role: "user", content: input))
    do {
        request.httpBody = try JSONEncoder().encode(Payload(
            model: model,
            messages: messages,
            max_completion_tokens: maxOutputTokens
        ))
    } catch {
        throw MoongateError.translateFailed("\(CoreL10n.text(en: "Could not build request body", zhHans: "无法构造请求体", zhHant: "無法構造請求本文"))：\(error.localizedDescription)")
    }

    let backoffNanoseconds: [UInt64] = [2_000_000_000, 8_000_000_000]
    var attempt = 0
    while true {
        if Task.isCancelled { throw MoongateError.cancelled }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw MoongateError.translateFailed(TranslatorL10n.unrecognizedResponse)
            }
            if http.statusCode == 200 {
                struct Choice: Decodable {
                    struct Msg: Decodable { let content: String? }
                    let message: Msg?
                    let finish_reason: String?
                }
                struct Reply: Decodable { let choices: [Choice] }
                guard let reply = try? JSONDecoder().decode(Reply.self, from: data),
                      let first = reply.choices.first else {
                    throw MoongateError.translateFailed(CoreL10n.text(
                        en: "The service response does not match the OpenAI Chat Completions protocol. Check the service URL.",
                        zhHans: "服务响应不符合 OpenAI Chat Completions 协议，请检查服务地址。",
                        zhHant: "服務回應不符合 OpenAI Chat Completions 協定，請檢查服務地址。"
                    ))
                }
                let text = (first.message?.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    throw MoongateError.translateFailed(CoreL10n.text(
                        en: "The OpenAI response did not contain text. Check the model or service URL.",
                        zhHans: "OpenAI 响应里没有文本内容，请检查模型或服务地址。",
                        zhHant: "OpenAI 回應裡沒有文字內容，請檢查模型或服務地址。"
                    ))
                }
                return ModelReply(text: text, reachedOutputLimit: first.finish_reason == "length")
            }
            let retryable = http.statusCode == 429 || (500...599).contains(http.statusCode)
            if retryable, attempt < backoffNanoseconds.count {
                try await Task.sleep(nanoseconds: backoffNanoseconds[attempt])
                attempt += 1
                continue
            }
            throw MoongateError.translateFailed(requestFailureMessage(
                statusCode: http.statusCode,
                data: data,
                settings: settings
            ))
        } catch let error as MoongateError {
            throw error
        } catch is CancellationError {
            throw MoongateError.cancelled
        } catch let error as URLError {
            if error.code == .cancelled { throw MoongateError.cancelled }
            throw MoongateError.translateFailed(TranslatorL10n.connectionFailed)
        } catch {
            throw MoongateError.translateFailed(error.localizedDescription)
        }
    }
}

/// 调一次 OpenAI Responses API，返回 output_text 块拼接后的文本。
/// 429/5xx 指数退避重试最多 2 次（2s、8s）；其余错误映射为 MoongateError。
func sendOpenAIResponse(
    settings: AppSettings,
    instructions: String?,
    input: String,
    maxOutputTokens: Int
) async throws -> ModelReply {
    let model = settings.translationModel.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !model.isEmpty else {
        throw MoongateError.translateFailed(TranslatorL10n.missingModel)
    }
    let token = normalizedToken(settings.translationAuthToken)
    guard !token.isEmpty else {
        throw MoongateError.translateFailed(TranslatorL10n.missingCredential)
    }

    let url = try endpointURL(baseURL: settings.translationBaseURL, endpointPath: "/v1/responses")

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 120
    request.setValue("application/json", forHTTPHeaderField: "content-type")
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

    struct Payload: Encodable {
        let model: String
        let instructions: String?
        let input: String
        let max_output_tokens: Int
        let store: Bool
    }
    do {
        request.httpBody = try JSONEncoder().encode(Payload(
            model: model,
            instructions: instructions,
            input: input,
            max_output_tokens: maxOutputTokens,
            store: false
        ))
    } catch {
        throw MoongateError.translateFailed("\(CoreL10n.text(en: "Could not build request body", zhHans: "无法构造请求体", zhHant: "無法構造請求本文"))：\(error.localizedDescription)")
    }

    let backoffNanoseconds: [UInt64] = [2_000_000_000, 8_000_000_000]
    var attempt = 0
    while true {
        if Task.isCancelled { throw MoongateError.cancelled }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw MoongateError.translateFailed(TranslatorL10n.unrecognizedResponse)
            }
            if http.statusCode == 200 {
                struct Content: Decodable {
                    let type: String
                    let text: String?
                }
                struct OutputItem: Decodable {
                    let type: String
                    let content: [Content]?
                }
                struct IncompleteDetails: Decodable {
                    let reason: String?
                }
                struct Reply: Decodable {
                    let output: [OutputItem]
                    let status: String?
                    let incomplete_details: IncompleteDetails?
                }
                guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else {
                    throw MoongateError.translateFailed(CoreL10n.text(
                        en: "The service response does not match the OpenAI Responses protocol. Check the service URL.",
                        zhHans: "服务响应不符合 OpenAI Responses 协议，请检查服务地址。",
                        zhHant: "服務回應不符合 OpenAI Responses 協定，請檢查服務地址。"
                    ))
                }
                let messageItems: [OutputItem] = reply.output.filter { $0.type == "message" }
                var textParts: [String] = []
                for item in messageItems {
                    let blocks = item.content ?? []
                    for block in blocks where block.type == "output_text" || block.type == "text" {
                        if let t = block.text { textParts.append(t) }
                    }
                }
                let text = textParts.joined()
                guard !text.isEmpty else {
                    throw MoongateError.translateFailed(CoreL10n.text(
                        en: "The OpenAI response did not contain text. Check the model or service URL.",
                        zhHans: "OpenAI 响应里没有文本内容，请检查模型或服务地址。",
                        zhHant: "OpenAI 回應裡沒有文字內容，請檢查模型或服務地址。"
                    ))
                }
                return ModelReply(
                    text: text,
                    reachedOutputLimit: reply.status == "incomplete"
                        && reply.incomplete_details?.reason == "max_output_tokens"
                )
            }
            let retryable = http.statusCode == 429 || (500...599).contains(http.statusCode)
            if retryable, attempt < backoffNanoseconds.count {
                try await Task.sleep(nanoseconds: backoffNanoseconds[attempt])
                attempt += 1
                continue
            }
            throw MoongateError.translateFailed(requestFailureMessage(
                statusCode: http.statusCode,
                data: data,
                settings: settings
            ))
        } catch let error as MoongateError {
            throw error
        } catch is CancellationError {
            throw MoongateError.cancelled
        } catch let error as URLError {
            if error.code == .cancelled { throw MoongateError.cancelled }
            throw MoongateError.translateFailed(TranslatorL10n.connectionFailed)
        } catch {
            throw MoongateError.translateFailed(error.localizedDescription)
        }
    }
}

// MARK: - 连接测试

/// 设置面板「测试连接」：发一条迷你请求，返回模型回复文本。
public func testTranslationConnection(settings: AppSettings) async throws -> String {
    // 上限别给太小：推理型模型（gpt-5 / o 系列等）会先消耗思考 token，
    // 16 会导致可见输出为空、把"连接正常"误报成失败。
    let reply = try await sendConfiguredMessage(
        settings: settings,
        system: nil,
        userContent: "请只回复两个字：正常",
        maxTokens: 1024
    )
    return reply.text.trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - AI 视频内容总结

/// 把一段视频元信息（标题/作者/时长）与可选的字幕或简介文本，用配置好的 AI 引擎
/// 总结成简体中文要点，帮助用户在下载前判断是否是想要的视频。
/// - source: 字幕正文（优先）或视频简介；为空时只凭标题等元信息总结（会更弱）。
/// 引擎不能生成文本（Apple Translation 各档）时抛 MoongateError.translateFailed。
public func summarizeVideo(
    title: String,
    uploader: String?,
    durationText: String?,
    source: String?,
    config: LLMEndpointConfig,
    settings: AppSettings
) async throws -> String {
    guard config.engine.canGenerateText else {
        throw MoongateError.translateFailed(CoreL10n.text(
            en: "The current summary engine (\(config.engine.displayName)) can only translate and cannot generate summaries. Choose a text-generation engine for summaries in AI settings.",
            zhHans: "当前总结引擎（\(config.engine.displayName)）只能翻译、不能生成内容总结。请在 AI 设置里为总结单独选择支持文本生成的引擎（云端 API 或本地 Apple Intelligence）。",
            zhHant: "目前摘要引擎（\(config.engine.displayName)）只能翻譯、無法產生內容摘要。請在 AI 設定裡為摘要單獨選擇支援文字生成的引擎（雲端 API 或本機 Apple Intelligence）。"
        ))
    }

    let system = """
        你是中文视频内容助手。根据用户给出的视频信息，用简体中文输出 3-5 句话的内容概述，\
        帮助用户在下载前判断这是不是自己想要的视频。只依据给出的信息，不要编造未提及的细节；\
        信息不足时如实说明。不要寒暄，不要使用 Markdown 列表，直接给概述。
        """

    var lines: [String] = []
    lines.append("标题：\(title)")
    if let uploader, !uploader.trimmingCharacters(in: .whitespaces).isEmpty {
        lines.append("作者/频道：\(uploader)")
    }
    if let durationText, !durationText.trimmingCharacters(in: .whitespaces).isEmpty {
        lines.append("时长：\(durationText)")
    }
    let trimmedSource = source?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !trimmedSource.isEmpty {
        // 控制 prompt 体量：超长字幕/简介截断，保留开头足够判断内容主题。
        let capped = trimmedSource.count > 6000 ? String(trimmedSource.prefix(6000)) + TranslatorL10n.truncatedMarker : trimmedSource
        lines.append("以下是该视频的字幕或简介内容：\n\(capped)")
    } else {
        lines.append("（没有可用的字幕或简介，只能依据标题等元信息概述。）")
    }
    let userContent = lines.joined(separator: "\n")

    // 总结要走「总结配置」，用 applyingTranslationConfig 把它固化进 settings 后复用统一调用路径。
    let summarySettings = settings.applyingTranslationConfig(config)
    let reply = try await sendConfiguredMessage(
        settings: summarySettings,
        system: system,
        userContent: userContent,
        maxTokens: 1500
    )
    let text = reply.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
        throw MoongateError.translateFailed(TranslatorL10n.emptySummary)
    }
    return text
}

/// 拉取服务端可用模型列表（GET {baseURL}/v1/models）。
/// 官方 Anthropic 与 OpenAI、以及大多数企业网关都暴露这个端点；返回模型 id 数组。
/// 只需服务地址 + 凭证，不需要先填模型。
public func listTranslationModels(settings: AppSettings) async throws -> [String] {
    guard settings.translationEngine.requiresCloudConfiguration else {
        throw MoongateError.translateFailed(CoreL10n.text(
            en: "\(settings.translationEngine.displayName) does not support fetching cloud model lists. Use the runtime check to confirm system capability.",
            zhHans: "\(settings.translationEngine.displayName) 不支持拉取云端模型列表。请使用运行前检测确认系统能力。",
            zhHant: "\(settings.translationEngine.displayName) 不支援拉取雲端模型列表。請使用執行前檢測確認系統能力。"
        ))
    }

    let token = normalizedToken(settings.translationAuthToken)
    guard !token.isEmpty else {
        throw MoongateError.translateFailed(CoreL10n.text(
            en: "No API credential is configured. Fill the credential before fetching models.",
            zhHans: "尚未配置 API 凭证，请先填写凭证再拉取模型。",
            zhHant: "尚未設定 API 憑證，請先填寫憑證再拉取模型。"
        ))
    }
    let urls = try modelListCandidateURLs(baseURL: settings.translationBaseURL)
    do {
        for (index, url) in urls.enumerated() {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 20
            configureModelListHeaders(
                request: &request,
                token: token,
                engine: settings.translationEngine,
                host: (url.host ?? "").lowercased()
            )

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw MoongateError.translateFailed(TranslatorL10n.modelListInvalid)
            }
            guard http.statusCode == 200 else {
                if index + 1 < urls.count,
                   shouldRetryModelListWithoutLimit(statusCode: http.statusCode) {
                    continue
                }
                throw MoongateError.translateFailed(requestFailureMessage(
                    statusCode: http.statusCode, data: data, settings: settings
                ))
            }
            let ids = parseModelIDs(from: data)
            guard !ids.isEmpty else {
                throw MoongateError.translateFailed(TranslatorL10n.modelListEmpty)
            }
            return ids
        }
        throw MoongateError.translateFailed(TranslatorL10n.connectionFailed)
    } catch let error as MoongateError {
        throw error
    } catch let error as URLError {
        if error.code == .cancelled { throw MoongateError.cancelled }
        throw MoongateError.translateFailed(TranslatorL10n.connectionFailed)
    } catch {
        throw MoongateError.translateFailed(error.localizedDescription)
    }
}

private func modelListCandidateURLs(baseURL: String) throws -> [URL] {
    let bareURL = try endpointURL(baseURL: baseURL, endpointPath: "/v1/models")
    guard var components = URLComponents(url: bareURL, resolvingAgainstBaseURL: false),
          components.queryItems?.isEmpty != false else {
        return [bareURL]
    }
    components.queryItems = [URLQueryItem(name: "limit", value: "1000")]
    let limitedURL = components.url ?? bareURL
    let host = (limitedURL.host ?? "").lowercased()
    if host == "api.anthropic.com" {
        return [limitedURL]
    }
    return [limitedURL, bareURL]
}

private func configureModelListHeaders(
    request: inout URLRequest,
    token: String,
    engine: TranslationEngine,
    host: String
) {
    // 鉴权头按协议区分，避免把 Anthropic 私有头泄漏给 OpenAI / 严格网关导致 4xx 拒绝：
    // - OpenAI 兼容：只发 Authorization: Bearer；
    // - 其它（Anthropic 官方 / 网关）：发 x-api-key + anthropic-version，并补 Bearer 以兼容网关。
    if engine == .openAICompatible {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    } else {
        request.setValue(token, forHTTPHeaderField: "x-api-key")
        if host != "api.anthropic.com" {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    }
}

private func shouldRetryModelListWithoutLimit(statusCode: Int) -> Bool {
    [400, 404, 405, 422].contains(statusCode)
}

/// 解析 /v1/models 响应。兼容 OpenAI 风格 {"data":[{"id":...}]} 与 Anthropic 风格
/// {"data":[{"id":...,"type":"model"}]}，以及个别网关的 {"models":[...]} / 纯数组。
private func parseModelIDs(from data: Data) -> [String] {
    guard let obj = try? JSONSerialization.jsonObject(with: data) else { return [] }
    func ids(from arr: [Any]) -> [String] {
        arr.compactMap { entry in
            if let s = entry as? String { return s }
            if let d = entry as? [String: Any] {
                return (d["id"] as? String) ?? (d["name"] as? String) ?? (d["model"] as? String)
            }
            return nil
        }
    }
    if let dict = obj as? [String: Any] {
        if let arr = dict["data"] as? [Any] { return dedupePreservingOrder(ids(from: arr)) }
        if let arr = dict["models"] as? [Any] { return dedupePreservingOrder(ids(from: arr)) }
    }
    if let arr = obj as? [Any] { return dedupePreservingOrder(ids(from: arr)) }
    return []
}

private func dedupePreservingOrder(_ items: [String]) -> [String] {
    var seen = Set<String>()
    var out: [String] = []
    for item in items where !item.isEmpty && seen.insert(item).inserted {
        out.append(item)
    }
    return out
}

/// 调试辅助：只清洗不翻译（解析 → cleanCues → 序列化），输出 "<名>.clean.srt"。
/// 供 moongate-cli clean-srt 在不调 LLM 的情况下验证字幕清洗效果。
public func cleanSRTFile(at url: URL) throws -> (parsed: Int, cleaned: Int, output: URL) {
    let raw: String
    do {
        raw = try String(contentsOf: url, encoding: .utf8)
    } catch {
        throw MoongateError.translateFailed(TranslatorL10n.cannotReadSubtitle(url.lastPathComponent))
    }
    let parsed = parseSubtitleCues(raw, fileName: url.lastPathComponent)
    guard !parsed.isEmpty else {
        throw MoongateError.translateFailed(TranslatorL10n.emptySubtitle)
    }
    let cleaned = cleanCues(parsed)
    let name = url.lastPathComponent
    let stem = subtitleOutputStem(name)
    let outputURL = url.deletingLastPathComponent().appendingPathComponent(stem + ".clean.srt")
    try serializeSRT(cleaned).write(to: outputURL, atomically: true, encoding: .utf8)
    return (parsed.count, cleaned.count, outputURL)
}

func parseSubtitleCues(_ raw: String, fileName: String) -> [SubtitleCue] {
    fileName.lowercased().hasSuffix(".vtt") ? parseVTT(raw) : parseSRT(raw)
}

private func subtitleOutputStem(_ fileName: String) -> String {
    let lowercased = fileName.lowercased()
    if lowercased.hasSuffix(".srt") || lowercased.hasSuffix(".vtt") {
        return String(fileName.dropLast(4))
    }
    return fileName
}

// MARK: - ConfiguredTranslator

public enum TranslationPromptPreset: String, Codable, Sendable, Equatable {
    case general
    case songLyrics
    case interviewConversation
    case tutorialHowTo
    case lectureCourse
    case newsExplainer
    case reviewProduct
    case vlogLifestyle
    case shortSocial
    case documentaryNarrative
    case gamingEntertainment
}

public struct TranslationPromptAdvice: Codable, Sendable, Equatable {
    public let summary: String
    public let context: String
    public let terms: [String]
    public let preset: TranslationPromptPreset

    public init(summary: String, context: String = "", terms: [String] = [], preset: TranslationPromptPreset) {
        self.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        self.context = context.trimmingCharacters(in: .whitespacesAndNewlines)
        self.terms = Self.normalizedTerms(terms)
        self.preset = preset
    }

    private enum CodingKeys: String, CodingKey {
        case summary, context, terms, preset
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        summary = try c.decode(String.self, forKey: .summary)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        context = try c.decodeIfPresent(String.self, forKey: .context)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        terms = Self.normalizedTerms(try c.decodeIfPresent([String].self, forKey: .terms) ?? [])
        let rawPreset = try c.decodeIfPresent(String.self, forKey: .preset) ?? TranslationPromptPreset.general.rawValue
        preset = TranslationPromptPreset(rawValue: rawPreset) ?? .general
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(summary, forKey: .summary)
        try c.encode(context, forKey: .context)
        try c.encode(terms, forKey: .terms)
        try c.encode(preset.rawValue, forKey: .preset)
    }

    private static func normalizedTerms(_ terms: [String]) -> [String] {
        Array(terms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(8))
    }
}

/// 通过设置里选择的协议翻译字幕。服务地址、模型、凭证全部来自 AppSettings。
public struct ConfiguredTranslator: ContextualSubtitleTranslator {
    private let settings: AppSettings
    private let appleTranslationExecutor: any AppleTranslationExecuting
    private let modelSender: ConfiguredModelSender

    /// 每次请求翻译的字幕条数
    private static let chunkSize = 30

    /// 翻译系统提示词。目标语言由 context 决定（简体中文 / 繁體中文 / English），不再写死。
    internal static func systemPrompt(
        targetLanguageDisplayName: String,
        sourceLanguageCode: String? = nil,
        advice: TranslationPromptAdvice? = nil
    ) -> String {
        // 点名源语言能让模型针对日语/韩语等谓语后置、修饰语前置的语言主动调整语序；未知源语言时退回不点名的措辞。
        let sourceLanguageDisplayName = TranslationLanguage.sourceDisplayName(for: sourceLanguageCode)
        let sourceClause = sourceLanguageDisplayName.map { "正在把\($0)字幕翻译成\(targetLanguageDisplayName)" }
            ?? "把用户给出的字幕翻译成\(targetLanguageDisplayName)"
        var prompt = """
        你是专业字幕翻译，\(sourceClause)。\
        输入每行格式为 编号|原文。请先通读整段，判断哪些相邻行其实属于同一句话。\
        输出必须严格逐行 编号|译文，行数与输入完全一致、编号不变，不要输出任何其他内容。
        要求：
        1) 按目标语言的自然语序表达，不要保留原文语序——尤其日语等谓语后置、修饰语/领属前置的语言，要把句尾谓语、被动施事、领属修饰语挪到目标语言的自然位置。
        2) 一句话被拆到多行时，先在心里组成完整自然的译句，再按原行数在目标语言的自然停顿处切回各行；不要让某行停在「你的」「被你」这类悬空成分，也不要让某行变成没有主语或中心词的残句。当一句的谓语/动词落在靠后的行时，前面的行只翻译修饰语或状语，不要提前把动词译出来、造成相邻行重复同一个动作。
        3) 数字、百分比、单位、版本号和型号要按完整表达理解。若相邻行把小数或单位拆开，如「99.」+「8%」、「0.」+「1%」、「Sun's」+「energy」，译文要合成自然中文，不要翻成「99点」/「8%」两段，也不要让某行停在「太阳的」。
        4) 口语自然、简洁，保留专有名词；只翻译原文已有的信息，不增不减。
        """
        // 日语源语言额外给重排范例：抽象规则对弱模型不够稳，用具体「日文→自然中文」示例压制"逐行硬贴原文语序"的倒退。
        if TranslationLanguage.normalizedScript(sourceLanguageCode ?? "") == "ja" {
            prompt += """

            日文→中文重排示例（务必按中文语序，不要留悬空成分）：
            - 「左隣、あなたの」「横顔を月が照らした」→「你坐在我的左侧」「月光映照着你的侧脸」（领属词上移，别让某行停在「你的」）
            - 「確かにほら救われたんだよ」「あなたに」→「你看，我确实被拯救了」「是被你拯救的」（把谓语补完整，别让某行只剩「被你」）
            """
        }
        guard let advice else { return prompt }
        prompt += "\n\n翻译前上下文：\n内容摘要：\(advice.summary)"
        if !advice.context.isEmpty {
            prompt += "\n人物/场景/发生的事：\(advice.context)"
        }
        if !advice.terms.isEmpty {
            prompt += "\n专名参考：\n" + advice.terms.map { "- \($0)" }.joined(separator: "\n")
        }
        prompt += "\n这些上下文只用于理解人物、专名、场景和主题；不要把上下文里没有对应原文的信息加进译文。仍按编号逐行输出、行数不变，但允许在相邻同句的行之间按上面的自然语序要求重新分配文字。"
        switch advice.preset {
        case .general:
            prompt += "\n根据摘要保持术语与语气一致，但仍以逐条字幕的准确翻译为准。"
        case .songLyrics:
            prompt += "\n这段字幕更接近歌曲、歌词或带旋律的演唱内容。请当作要发表的中文歌词译本来打磨，而不是逐句直译：优先意境、情绪与可吟唱的自然度，用词可更凝练、更有画面感和文学性，不必逐字贴着原句；相邻几行常属同一句，可在它们之间自由合并、重排，让整段读起来像通顺的中文歌词，并保留原文的重复、副歌和短句呼吸感。仅本段为歌曲，放宽前面第 4 条“不增不减”的限制：可在忠于每句情绪重心与意象的前提下做合理引申和润色；但不得编造原文完全没有的情节或事实（如具体人名、地点、动作）。"
        case .interviewConversation:
            prompt += "\n这段内容更像访谈或对话。翻译时优先保留说话人的口吻、犹豫、转折和真实交流感；句子可以自然顺一点，但不要把口语磨成书面报告。"
        case .tutorialHowTo:
            prompt += "\n这段内容更像教程或操作说明。翻译时优先让步骤、条件、按钮名和动作顺序清楚可跟做；语气保持简洁直接，技术词前后统一。"
        case .lectureCourse:
            prompt += "\n这段内容更像课程或讲座。翻译时优先保留概念层次、因果关系和术语一致性；表达可以更清楚，但不要把讲者的铺垫和重点压扁。"
        case .newsExplainer:
            prompt += "\n这段内容更像新闻、评论或解释型视频。翻译时保持客观、克制、信息密度清楚；专名、数字、时间和因果关系要稳，避免额外立场。"
        case .reviewProduct:
            prompt += "\n这段内容更像产品评测或体验分享。翻译时保留体验感、比较关系和优缺点的细微语气；规格、型号、功能名和结论要清楚一致。"
        case .vlogLifestyle:
            prompt += "\n这段内容更像 vlog 或生活记录。翻译时保留轻松自然的口吻、场景感和个人语气；不要过度正式，短句可以保持日常说话的节奏。"
        case .shortSocial:
            prompt += "\n这段内容更像短视频或社交平台内容。翻译时优先保留节奏、梗、反差和情绪推进；可以使用更贴近目标语言的自然说法，但不要生造原文没有的信息。"
        case .documentaryNarrative:
            prompt += "\n这段内容更像纪录片或叙事旁白。翻译时保留画面感、时间线和叙事张力；用词可以更凝练，但要让信息和气氛都稳稳落在字幕里。"
        case .gamingEntertainment:
            prompt += "\n这段内容更像游戏或娱乐解说。翻译时保留即时反应、玩笑、术语和场面节奏；游戏名、角色名、机制名要一致，语气可以更有现场感。"
        }
        return prompt
    }

    internal static func parseTranslationPromptAdvice(_ text: String) -> TranslationPromptAdvice? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let json: String
        if trimmed.hasPrefix("{"), trimmed.hasSuffix("}") {
            json = trimmed
        } else if let start = trimmed.firstIndex(of: "{"),
                  let end = trimmed.lastIndex(of: "}"),
                  start <= end {
            json = String(trimmed[start...end])
        } else {
            return nil
        }
        guard let data = json.data(using: .utf8),
              let advice = try? JSONDecoder().decode(TranslationPromptAdvice.self, from: data),
              !advice.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return advice
    }

    public init(settings: AppSettings) {
        self.init(settings: settings, appleTranslationExecutor: DefaultAppleTranslationExecutor())
    }

    init(
        settings: AppSettings,
        appleTranslationExecutor: any AppleTranslationExecuting,
        modelSender: @escaping ConfiguredModelSender = { settings, system, userContent, maxTokens, context in
            try await sendConfiguredMessage(
                settings: settings,
                system: system,
                userContent: userContent,
                maxTokens: maxTokens,
                context: context
            )
        }
    ) {
        // 翻译统一走 translation* 字段，这里把「有效翻译配置」（可能跟随默认 AI 配置）固化进去，
        // 下游 sendConfiguredMessage 无需再关心跟随逻辑。
        self.settings = settings.applyingTranslationConfig(settings.effectiveTranslationConfig)
        self.appleTranslationExecutor = appleTranslationExecutor
        self.modelSender = modelSender
    }

    public func translate(
        srtFile: URL,
        style: SubtitleStyle,
        context: TranslationContext,
        control: TaskControlToken?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let raw: String
        do {
            raw = try String(contentsOf: srtFile, encoding: .utf8)
        } catch {
            throw MoongateError.translateFailed(TranslatorL10n.cannotReadSubtitle(srtFile.lastPathComponent))
        }
        let parsed = parseSubtitleCues(raw, fileName: srtFile.lastPathComponent)
        guard !parsed.isEmpty else {
            throw MoongateError.translateFailed(TranslatorL10n.emptySubtitle)
        }
        // 翻译前清洗：消除 YouTube 自动字幕的重叠滚动碎句、按句合并，减少疯狂刷新。
        let sourceLooksLikeAutoCaption = Self.looksLikeAutoCaption(parsed)
        var cues = cleanCues(parsed)
        // 智能提示词开启且字幕像逐字无标点的 ASR 自动字幕时，先重分段成完整句子再翻译，
        // 显著改善翻译质量与可读性。重分段失败（对齐不上）会原样返回，不影响后续。
        // 本地 Whisper 源字幕（.local-asr.*）天然是逐字无标点碎句，分段全靠 LLM 重断句——
        // 无论 smart 开关都对它重分段，并把句子级结果写回源 .srt（让导出的源字幕也成句）；
        // 平台自动字幕（YouTube 等）维持原行为，仅在 smart 开启时才重分段，避免影响既有路径与成本。
        let isLocalASRSource = srtFile.lastPathComponent.lowercased().contains(".local-asr.")
        if (settings.smartTranslationPromptsEnabled || isLocalASRSource),
           sourceLooksLikeAutoCaption || Self.looksLikeAutoCaption(cues) {
            let reseg = try await resegmentForReadability(cues, context: context)
            if isLocalASRSource, reseg.count != cues.count {
                try? serializeSRT(reseg).write(to: srtFile, atomically: true, encoding: .utf8)
            }
            cues = reseg
        }
        let advice = try await makeTranslationPromptAdvice(cues: cues, context: context)

        // 分块并行请求（最多 3 个在途）：编号用全局序号（1 起），回贴与完成顺序无关。
        // 每调度一个新块前过一次 gate（暂停挂起 / 取消抛出）；在途块自然跑完。
        var output = cues
        var chunkRanges: [Range<Int>] = []
        var rangeStart = 0
        while rangeStart < cues.count {
            let upper = min(rangeStart + Self.chunkSize, cues.count)
            chunkRanges.append(rangeStart..<upper)
            rangeStart = upper
        }
        let maxInFlight = 3
        var merged: [Int: String] = [:]
        var completedCues = 0
        let allCues = cues
        try await withThrowingTaskGroup(of: (Range<Int>, [Int: String]).self) { group in
            var nextChunk = 0
            func scheduleNext() async throws {
                guard nextChunk < chunkRanges.count else { return }
                if Task.isCancelled { throw MoongateError.cancelled }
                try await control?.gate()
                let range = chunkRanges[nextChunk]
                nextChunk += 1
                group.addTask {
                    let mapping = try await self.translateChunk(
                        allCues[range],
                        startNumber: range.lowerBound + 1,
                        context: context,
                        advice: advice,
                        depth: 0
                    )
                    return (range, mapping)
                }
            }
            for _ in 0..<min(maxInFlight, chunkRanges.count) {
                try await scheduleNext()
            }
            while let (range, mapping) = try await group.next() {
                merged.merge(mapping) { _, new in new }
                completedCues += range.count
                progress(Double(completedCues) / Double(cues.count))
                try await scheduleNext()
            }
        }
        for cueIndex in 0..<cues.count {
            let sourceText = cues[cueIndex].text
            let rawChinese = merged[cueIndex + 1] ?? ""
            let sanitizedChinese = Self.sanitizeTranslation(rawChinese)
            let usedSourceFallback = sanitizedChinese.isEmpty
            let chinese = usedSourceFallback ? sourceText : sanitizedChinese
            guard !chinese.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MoongateError.translateFailed(TranslatorL10n.missingTranslatedLine)
            }
            switch style {
            case .bilingual:
                // 译文在上、原文在下（烧录时原文用更小字号）
                output[cueIndex].text = usedSourceFallback ? sourceText : chinese + "\n" + sourceText
            case .chineseOnly:
                output[cueIndex].text = chinese
            }
        }

        // 写 "<原文件名去字幕扩展>.<target>.srt"
        let name = srtFile.lastPathComponent
        let stem = subtitleOutputStem(name)
        let outputURL = srtFile.deletingLastPathComponent()
            .appendingPathComponent(stem + TranslationLanguage.translatedSubtitleFileSuffix(for: context.targetLanguage))
        do {
            try serializeSRT(output).write(to: outputURL, atomically: true, encoding: .utf8)
        } catch {
            throw MoongateError.translateFailed("\(CoreL10n.text(en: "Could not write translated subtitle file", zhHans: "无法写入译文文件", zhHant: "無法寫入譯文檔"))：\(error.localizedDescription)")
        }
        return outputURL
    }

    /// 翻译一块字幕，返回 [全局编号: 译文]。
    /// stop_reason 为 "max_tokens"（译文被截断）时按减半的条数自动重试：
    /// 最多再分两层、每块最小 8 条；仍截断则抛错。
    /// 只要译文缺失行即视为模型返回格式异常，抛错而不是静默保留原文。
    private func translateChunk(
        _ chunk: ArraySlice<SubtitleCue>,
        startNumber: Int,
        context: TranslationContext,
        advice: TranslationPromptAdvice?,
        depth: Int
    ) async throws -> [Int: String] {
        if Task.isCancelled { throw MoongateError.cancelled }
        switch settings.translationEngine {
        case .appleTranslationLowLatency, .appleTranslationHighFidelity:
            return try await translateAppleTranslationChunk(
                chunk,
                startNumber: startNumber,
                context: context
            )
        case .anthropicCompatible, .openAICompatible, .appleFoundationOnDevice, .appleFoundationPCC, .appleFoundationCloudPro:
            break
        }

        let userContent = chunk.enumerated().map { offset, cue in
            "\(startNumber + offset)|\(Self.flattened(cue.text))"
        }.joined(separator: "\n")

        let reply = try await sendModelMessage(
            settings: settings,
            system: Self.systemPrompt(
                targetLanguageDisplayName: context.targetLanguageDisplayName,
                sourceLanguageCode: context.sourceLanguage,
                advice: advice
            ),
            userContent: userContent,
            maxTokens: 8000,
            context: context
        )
        if reply.reachedOutputLimit {
            let half = chunk.count / 2
            guard depth < 2, half >= 8 else {
                throw MoongateError.translateFailed(TranslatorL10n.outputLimitReached)
            }
            let mid = chunk.startIndex + half
            var merged = try await translateChunk(
                chunk[chunk.startIndex..<mid],
                startNumber: startNumber,
                context: context,
                advice: advice,
                depth: depth + 1
            )
            let second = try await translateChunk(
                chunk[mid..<chunk.endIndex],
                startNumber: startNumber + half,
                context: context,
                advice: advice,
                depth: depth + 1
            )
            merged.merge(second) { _, new in new }
            return merged
        }

        let map = Self.parseReply(reply.text)
        let missing = (startNumber..<startNumber + chunk.count)
            .filter { (map[$0] ?? "").isEmpty }
            .count
        if missing > 0 {
            let half = chunk.count / 2
            if depth < 2, half >= 8 {
                let mid = chunk.startIndex + half
                var merged = try await translateChunk(
                    chunk[chunk.startIndex..<mid],
                    startNumber: startNumber,
                    context: context,
                    advice: advice,
                    depth: depth + 1
                )
                let second = try await translateChunk(
                    chunk[mid..<chunk.endIndex],
                    startNumber: startNumber + half,
                    context: context,
                    advice: advice,
                    depth: depth + 1
                )
                merged.merge(second) { _, new in new }
                return merged
            }
            return try await repairMissingTranslations(
                chunk: chunk,
                startNumber: startNumber,
                currentMap: map,
                context: context,
                advice: advice
            )
        }
        return map
    }

    private func repairMissingTranslations(
        chunk: ArraySlice<SubtitleCue>,
        startNumber: Int,
        currentMap: [Int: String],
        context: TranslationContext,
        advice: TranslationPromptAdvice?
    ) async throws -> [Int: String] {
        var repaired = currentMap
        for (offset, cue) in chunk.enumerated() {
            if Task.isCancelled { throw MoongateError.cancelled }
            let number = startNumber + offset
            guard (repaired[number] ?? "").isEmpty else { continue }
            let original = Self.flattened(cue.text)
            let userContent = "\(number)|\(original)"
            let reply: ModelReply
            do {
                reply = try await sendModelMessage(
                    settings: settings,
                    system: Self.systemPrompt(
                        targetLanguageDisplayName: context.targetLanguageDisplayName,
                        sourceLanguageCode: context.sourceLanguage,
                        advice: advice
                    ),
                    userContent: userContent,
                    maxTokens: 1200,
                    context: context
                )
            } catch {
                repaired[number] = original
                continue
            }
            let retryMap = Self.parseReply(reply.text)
            let retryText = retryMap[number]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            repaired[number] = retryText.isEmpty ? original : retryText
        }
        return repaired
    }

    private func makeTranslationPromptAdvice(
        cues: [SubtitleCue],
        context: TranslationContext
    ) async throws -> TranslationPromptAdvice? {
        guard settings.smartTranslationPromptsEnabled else { return nil }
        let config = settings.effectiveSummaryConfig
        guard config.engine.canGenerateText else {
            throw MoongateError.translateFailed(TranslatorL10n.smartPromptNeedsSummaryModel)
        }
        let sample = Self.subtitleAnalysisSample(cues)
        let summarySettings = settings.applyingTranslationConfig(config)
        let system = """
        你是字幕内容分析器。根据字幕判断视频内容类型，并只输出 JSON：\
        {"summary":"不超过80字的中文摘要","context":"不超过160字，写清人物、组织、场景、发生的事和主题","terms":["原文专名或术语：目标语言说明，最多8个"],"preset":"general|songLyrics|interviewConversation|tutorialHowTo|lectureCourse|newsExplainer|reviewProduct|vlogLifestyle|shortSocial|documentaryNarrative|gamingEntertainment"}。\
        summary 写整体内容；context 写会影响翻译的背景，不要编造字幕没有支持的信息；terms 只放字幕里出现或能高置信识别的专名、人物、组织、作品名、品牌、术语，不确定官方译名时保留原文写法并说明不确定。\
        preset 选择最贴近的一个：歌曲/歌词/MV 用 songLyrics；访谈播客对话用 interviewConversation；教程操作演示用 tutorialHowTo；课程讲座用 lectureCourse；新闻评论解释用 newsExplainer；产品评测体验用 reviewProduct；vlog 生活记录用 vlogLifestyle；短视频社交平台内容用 shortSocial；纪录片旁白叙事用 documentaryNarrative；游戏或娱乐解说用 gamingEntertainment；无法判断用 general。不要输出 Markdown。
        """
        let userContent = """
        目标译文语言：\(context.targetLanguageDisplayName)
        字幕内容分析样本：
        \(sample)
        """
        let reply = try await sendModelMessage(
            settings: summarySettings,
            system: system,
            userContent: userContent,
            maxTokens: 1200,
            context: context
        )
        guard let advice = Self.parseTranslationPromptAdvice(reply.text) else {
            throw MoongateError.translateFailed(TranslatorL10n.smartAnalysisInvalid)
        }
        return advice
    }

    private func sendModelMessage(
        settings: AppSettings,
        system: String?,
        userContent: String,
        maxTokens: Int,
        context: TranslationContext
    ) async throws -> ModelReply {
        do {
            return try await modelSender(settings, system, userContent, maxTokens, context)
        } catch {
            guard !Task.isCancelled, Self.isTransientModelSendError(error) else { throw error }
            return try await modelSender(settings, system, userContent, maxTokens, context)
        }
    }

    private static func isTransientModelSendError(_ error: Error) -> Bool {
        if error is URLError { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain
    }

    private static func subtitleAnalysisSample(_ cues: [SubtitleCue]) -> String {
        let text = cues.prefix(120)
            .map { flattened($0.text) }
            .joined(separator: "\n")
        if text.count > 6000 {
            return String(text.prefix(6000)) + TranslatorL10n.truncatedMarker
        }
        return text
    }

    private func translateAppleTranslationChunk(
        _ chunk: ArraySlice<SubtitleCue>,
        startNumber: Int,
        context: TranslationContext
    ) async throws -> [Int: String] {
        let segments = chunk.enumerated().map { offset, cue in
            AppleTranslationSegment(
                number: startNumber + offset,
                text: Self.flattened(cue.text)
            )
        }
        let map = try await appleTranslationExecutor.translate(AppleTranslationBatchRequest(
            engine: settings.translationEngine,
            context: context,
            segments: segments
        ))
        let missing = (startNumber..<startNumber + chunk.count)
            .filter { (map[$0] ?? "").isEmpty }
            .count
        if missing > 0 {
            throw MoongateError.translateFailed(TranslatorL10n.missingTranslatedLine)
        }
        return map
    }

    /// 字幕条内部换行折叠成一行发给模型。用空格连接（旧版用 " / " 会被模型原样抄进译文，
    /// 出现「可你要真想玩 / 《马力欧赛车 世界》」这种把分隔符当正文的脏输出）。
    static func flattened(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\N", with: "\n")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\h", with: " ")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// 清洗单行译文：去掉模型偶尔自加的行首对话破折号（原文并无），并兜底去掉残留的 " / " 分隔符。
    static func sanitizeTranslation(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespaces)
        // 行首对话破折号（"- " / "– " / "— "）：原文没有时模型有时会自加，去掉。
        while let first = t.first, first == "-" || first == "–" || first == "—" {
            t.removeFirst()
            t = t.trimmingCharacters(in: .whitespaces)
        }
        // 兜底：把残留的 " / " 折叠分隔符还原成自然停顿（正常译文不会出现）。
        t = t.replacingOccurrences(of: " / ", with: "，")
        t = Self.removingChineseTerminalPeriod(t)
        return t.trimmingCharacters(in: .whitespaces)
    }

    private static func removingChineseTerminalPeriod(_ text: String) -> String {
        var chars = Array(text.trimmingCharacters(in: .whitespaces))
        let trailingClosers: Set<Character> = ["\"", "'", "”", "’", ")", "）", "」", "』", "]", "】"]
        var closing: [Character] = []
        while let last = chars.last, trailingClosers.contains(last) {
            closing.insert(chars.removeLast(), at: 0)
        }
        if chars.last == "。" {
            chars.removeLast()
        }
        return String(chars + closing)
    }

    /// 把模型回复按行解析为 [编号: 译文]；不合规的行忽略。
    private static func parseReply(_ reply: String) -> [Int: String] {
        var map: [Int: String] = [:]
        for line in reply.split(whereSeparator: \.isNewline) {
            guard let separator = line.firstIndex(of: "|") else { continue }
            guard let number = Int(line[..<separator].trimmingCharacters(in: .whitespaces)) else { continue }
            let text = String(line[line.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
            map[number] = text
        }
        return map
    }

    // MARK: - ASR 字幕重分段（resegment for readability）
    // 逐字、无标点的自动字幕每条只是一个时间窗口里的碎词，读起来割裂。
    // 把整段转写发给模型断句，再把断好的句子「严格对齐」回原始 token 序列，
    // 用每个 token 所在原 cue 的本地时间线性插值，重建带正确时间轴的整句字幕。
    // 对齐失败（模型擅自改词/漏词）时原样返回输入，绝不产出错位时间轴。
    // 与 Windows SrtTools/ConfiguredTranslator 的 ResegmentForReadability 同构。

    private static let resegmentChunkCues = 25        // 单次请求最多原始 cue 数（在 cue 边界切块）
    private static let resegmentMaxSegmentSeconds = 6.0 // 单条安全时长上限：超过且 token 足够多才再切
    private static let resegmentMinSplitTokens = 6      // 只有 token 数达到此值的段才按时长再切
    private static let resegmentMinSegmentSeconds = 3.0 // 合并判据：时长 < 此秒数
    private static let resegmentMinMergeTokens = 3      // 且 token < 此值，才算碎句并入前段

    /// 归一化单个 token 用于对齐比较：小写 + 去掉首尾标点（保留内部，如 well-known）。
    private static func normalizeAlignToken(_ raw: String) -> String {
        let lower = raw.lowercased()
        let chars = Array(lower)
        var start = 0, end = chars.count
        while start < end, !chars[start].isLetter, !chars[start].isNumber { start += 1 }
        while end > start, !chars[end - 1].isLetter, !chars[end - 1].isNumber { end -= 1 }
        return String(chars[start..<end])
    }

    /// 把文本拆成「词 token」：按空白切分后丢弃归一化后为空的纯标点 token。
    private static func alignTokens(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !normalizeAlignToken($0).isEmpty }
    }

    /// 单个字符是否属于 CJK（汉字/假名/谚文）——这类语言词间无空格。
    static func isCJKScalar(_ ch: Character) -> Bool {
        ch.unicodeScalars.contains { s in
            (0x3040...0x30FF).contains(s.value) ||   // 平假名 + 片假名
            (0x3400...0x4DBF).contains(s.value) ||   // CJK 扩展 A
            (0x4E00...0x9FFF).contains(s.value) ||   // CJK 基本汉字
            (0xAC00...0xD7A3).contains(s.value) ||   // 谚文音节
            (0xF900...0xFAFF).contains(s.value) ||   // CJK 兼容汉字
            (0x20000...0x2FA1F).contains(s.value)    // CJK 扩展 B+
        }
    }

    /// 判定字幕是否以 CJK（中日韩，词间无空格）为主，决定重分段按「字符」还是按「词」对齐。
    /// 无空格语言里整条字幕只算一个 token，按词对齐必然失败而整体回退；改为逐字符对齐才生效。
    static func isCJKHeavy(_ cues: [SubtitleCue]) -> Bool {
        var cjk = 0, total = 0
        for cue in cues {
            for ch in flattened(cue.text) where !ch.isWhitespace {
                total += 1
                if isCJKScalar(ch) { cjk += 1 }
            }
        }
        guard total > 0 else { return false }
        return Double(cjk) / Double(total) >= 0.5
    }

    /// 对齐单元：CJK 逐字符（丢弃空白与纯标点），其它语言按空白切词。
    /// CJK 模式下「token」= 单个字符，下游 build/merge/split/插值机制全部按字符粒度复用。
    private static func alignmentUnits(_ text: String, cjk: Bool) -> [String] {
        guard cjk else { return alignTokens(text) }
        return text.compactMap { ch in
            ch.isWhitespace ? nil : (normalizeAlignToken(String(ch)).isEmpty ? nil : String(ch))
        }
    }

    /// ASR 判定：像逐字无标点的自动字幕才重分段，尽量避免误伤正常字幕/歌词。
    /// 需同时满足：(1) cue 数足够多；(2) 带句末标点的 cue 比例很低；
    /// (3) 平均时长偏短（碎句特征）；(4) 整体几乎没有换行（ASR 每条单行碎词）。
    static func looksLikeAutoCaption(_ cues: [SubtitleCue]) -> Bool {
        guard cues.count >= 8 else { return false }
        let enders: Set<Character> = [".", "!", "?", "。", "！", "？"]
        let closers: Set<Character> = ["\"", "'", "”", "’", ")", "）", "」", "』", "]", "】"]
        func endsWithPunct(_ text: String) -> Bool {
            var chars = Array(text)
            while let last = chars.last, closers.contains(last) || last == " " { chars.removeLast() }
            guard let last = chars.last else { return false }
            return enders.contains(last)
        }
        let punctuated = cues.filter { endsWithPunct($0.text) }.count
        guard Double(punctuated) / Double(cues.count) < 0.15 else { return false }

        // 平均时长：ASR 碎句通常每条很短；过长（≥6s/条）更像已成句的正常字幕。
        var totalDuration = 0.0
        var measured = 0
        for cue in cues {
            guard let s = srtTimeToSeconds(cue.start), let e = srtTimeToSeconds(cue.end), e > s else { continue }
            totalDuration += e - s
            measured += 1
        }
        let avgDuration = measured > 0 ? totalDuration / Double(measured) : 0
        guard measured == 0 || avgDuration < 6.0 else { return false }

        // 多行比例：ASR 自动字幕基本每条单行；若大量条目本身就是多行排版，更像人工字幕。
        let multiline = cues.filter { $0.text.contains("\n") }.count
        let multilineRatio = Double(multiline) / Double(cues.count)
        guard multilineRatio < 0.5 || (cues.count >= 20 && avgDuration < 2.5) else { return false }
        return true
    }
}

@available(*, deprecated, renamed: "ConfiguredTranslator")
public typealias AnthropicTranslator = ConfiguredTranslator

// MARK: - ASR 字幕重分段实现（与 Windows 同构）
extension ConfiguredTranslator {
    /// 展平后的单个 token：归一化文本 + 所属原 cue 索引 + 在该 cue 内的位置（用于本地时间插值）。
    fileprivate struct FlatToken {
        let norm: String
        let cueIndex: Int
        let posInCue: Int
        let cueTokenCount: Int
    }

    /// 把一段（连续若干原 cue）展平为带定位信息的 token 序列。
    /// CJK 模式下 token = 单个字符，posInCue/cueTokenCount 据此变为字符粒度，时间插值更细。
    fileprivate static func flattenCueTokens(_ cues: [SubtitleCue], start: Int, count: Int, cjk: Bool) -> [FlatToken] {
        var flat: [FlatToken] = []
        for c in start..<(start + count) {
            let tokens = alignmentUnits(flattened(cues[c].text), cjk: cjk)
            for (i, tok) in tokens.enumerated() {
                flat.append(FlatToken(norm: normalizeAlignToken(tok), cueIndex: c,
                                      posInCue: i, cueTokenCount: tokens.count))
            }
        }
        return flat
    }

    /// 一个 token 的「时间点」：用它所在原 cue 的本地时间线性插值。
    /// edge=false 取 token 起点（pos/count），edge=true 取 token 终点（(pos+1)/count）。
    fileprivate static func tokenTime(_ cues: [SubtitleCue], _ token: FlatToken, edge: Bool) -> Double {
        let cue = cues[token.cueIndex]
        let s = srtTimeToSeconds(cue.start) ?? 0
        let e = srtTimeToSeconds(cue.end) ?? s
        if token.cueTokenCount <= 0 || e <= s { return edge ? e : s }
        let frac = Double(edge ? token.posInCue + 1 : token.posInCue) / Double(token.cueTokenCount)
        return s + (e - s) * frac
    }

    /// 把一块原 cue 的转写文本发给模型断句，返回模型给出的句子列表（按编号排序）。
    /// 命中输出上限时把这块的 cue 数减半递归重试；单条仍截断则用原文兜底。
    fileprivate func segmentChunk(_ cues: [SubtitleCue], start: Int, count: Int,
                                  context: TranslationContext) async throws -> [String] {
        if Task.isCancelled { throw MoongateError.cancelled }
        let transcript = (start..<(start + count))
            .map { Self.flattened(cues[$0].text) }
            .joined(separator: " ")
        let system = """
        你是字幕断句助手。下面是一段逐字、缺少标点的自动语音字幕转写。\
        请在不改动、不增减、不翻译任何词的前提下，仅添加标点并按完整句子重新断行，\
        每个完整句子输出为一行，格式严格为 编号|句子（编号从 1 递增）。只能输出这些行，不要解释。
        待断句文本：
        \(transcript)
        """
        let reply = try await sendModelMessage(
            settings: settings, system: system, userContent: transcript,
            maxTokens: 4000, context: context)
        if reply.reachedOutputLimit {
            if count <= 1 { return [Self.flattened(cues[start].text)] }
            let half = count / 2
            let first = try await segmentChunk(cues, start: start, count: half, context: context)
            let second = try await segmentChunk(cues, start: start + half, count: count - half, context: context)
            return first + second
        }
        let map = Self.parseReply(reply.text)
        let sentences = map.sorted { $0.key < $1.key }
            .map { $0.value.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return sentences.isEmpty ? [transcript] : sentences
    }
}

extension ConfiguredTranslator {
    /// 重分段中间结果：一段连续 token 的起止秒 + 文本。
    fileprivate final class Segment {
        var startSec: Double
        var endSec: Double
        var tokenStart: Int   // 在 flat 序列中的起始索引（含）
        var tokenEnd: Int     // 结束索引（不含）
        var text: String
        init(startSec: Double, endSec: Double, tokenStart: Int, tokenEnd: Int, text: String) {
            self.startSec = startSec; self.endSec = endSec
            self.tokenStart = tokenStart; self.tokenEnd = tokenEnd; self.text = text
        }
    }

    /// ASR 字幕重分段：把逐字无标点的自动字幕重新断成完整句子，保留原始时间轴。
    /// 对齐失败（模型改词/漏词）时原样返回输入，绝不产出错位时间轴。
    func resegmentForReadability(_ cues: [SubtitleCue], context: TranslationContext) async throws -> [SubtitleCue] {
        guard !cues.isEmpty else { return [] }

        // 1) 在 cue 边界分块请求断句，拼出全部句子。最多 3 块在途并行（此前为串行，是
        //    Whisper/ASR 字幕翻译慢的主因——整段额外断句 LLM 往返一个接一个），结果按块序回拼。
        var chunkRanges: [(index: Int, start: Int, count: Int)] = []
        do {
            var start = 0
            var index = 0
            while start < cues.count {
                let count = min(Self.resegmentChunkCues, cues.count - start)
                chunkRanges.append((index, start, count))
                start += count
                index += 1
            }
        }
        var chunkSentences: [Int: [String]] = [:]
        let maxInFlight = 3
        try await withThrowingTaskGroup(of: (Int, [String]).self) { group in
            var nextChunk = 0
            func scheduleNext() async throws {
                guard nextChunk < chunkRanges.count else { return }
                if Task.isCancelled { throw MoongateError.cancelled }
                let chunk = chunkRanges[nextChunk]
                nextChunk += 1
                group.addTask {
                    (chunk.index, try await self.segmentChunk(cues, start: chunk.start, count: chunk.count, context: context))
                }
            }
            for _ in 0..<min(maxInFlight, chunkRanges.count) {
                try await scheduleNext()
            }
            while let (index, parts) = try await group.next() {
                chunkSentences[index] = parts
                try await scheduleNext()
            }
        }
        var sentences: [String] = []
        for index in 0..<chunkRanges.count {
            sentences += chunkSentences[index] ?? []
        }

        // 2) 展平原始 token，并把所有句子的 token 顺序拼接，逐 token 严格对齐。
        //    CJK（中日韩，词间无空格）按字符对齐；其它语言按空白切词——否则无空格语言整条
        //    只算一个 token，模型重新断句后必然对不上而整体回退（这是此前日文重分段不生效的根因）。
        let cjk = Self.isCJKHeavy(cues)
        let flat = Self.flattenCueTokens(cues, start: 0, count: cues.count, cjk: cjk)
        var sentenceTokenCounts: [Int] = []
        var alignedNorms: [String] = []
        for sentence in sentences {
            let toks = Self.alignmentUnits(sentence, cjk: cjk)
            sentenceTokenCounts.append(toks.count)
            alignedNorms += toks.map(Self.normalizeAlignToken)
        }
        // 对齐校验：句子拼接后的 token 必须与原 token 序列逐一一致；不一致则放弃重分段。
        guard alignedNorms.count == flat.count,
              !zip(alignedNorms, flat).contains(where: { $0 != $1.norm }) else {
            Self.resegmentLog("对齐失败（原 \(flat.count) token vs 模型 \(alignedNorms.count) token），保留原 \(cues.count) 条字幕")
            return cues
        }

        // 3) 切段 → 4) 合并/拆分/重排。
        let segments = Self.buildSegments(cues, flat: flat, sentences: sentences, counts: sentenceTokenCounts)
        let result = Self.finalizeSegments(cues, flat: flat, segments: segments)
        Self.resegmentLog("生效：\(cues.count) 条 → \(result.count) 条整句")
        return result
    }

    /// 重分段诊断日志：写 stderr，便于排查「是否生效 / 为何回退」。与 Engine 的 stderr 诊断风格一致。
    fileprivate static func resegmentLog(_ message: String) {
        FileHandle.standardError.write(Data("[resegment] \(message)\n".utf8))
    }
}

extension ConfiguredTranslator {
    /// 按每句覆盖的 token 范围，用 token 所在原 cue 的本地时间插值，切出带时间的段。
    fileprivate static func buildSegments(_ cues: [SubtitleCue], flat: [FlatToken],
                                          sentences: [String], counts: [Int]) -> [Segment] {
        var segments: [Segment] = []
        var cursor = 0
        for (s, sentence) in sentences.enumerated() {
            let tokenCount = counts[s]
            if tokenCount == 0 { continue }
            let tokenStart = cursor
            let tokenEnd = cursor + tokenCount
            cursor = tokenEnd
            segments.append(Segment(
                startSec: tokenTime(cues, flat[tokenStart], edge: false),
                endSec: tokenTime(cues, flat[tokenEnd - 1], edge: true),
                tokenStart: tokenStart, tokenEnd: tokenEnd,
                text: sentence.trimmingCharacters(in: .whitespaces)))
        }
        return segments
    }

    /// 合并碎句 → 按时长安全拆分过长段 → 单调钳制时间 → 重排 index → 转 SubtitleCue。
    fileprivate static func finalizeSegments(_ cues: [SubtitleCue], flat: [FlatToken],
                                             segments: [Segment]) -> [SubtitleCue] {
        guard !segments.isEmpty else { return cues }

        // 合并：把「时长短且 token 少」的碎句并入前一段。
        var merged: [Segment] = [segments[0]]
        for i in 1..<segments.count {
            let seg = segments[i]
            let tokenCount = seg.tokenEnd - seg.tokenStart
            let durationShort = seg.endSec - seg.startSec < resegmentMinSegmentSeconds
            if durationShort && tokenCount < resegmentMinMergeTokens {
                let prev = merged[merged.count - 1]
                prev.tokenEnd = seg.tokenEnd
                prev.endSec = seg.endSec
                prev.text = (prev.text + " " + seg.text).trimmingCharacters(in: .whitespaces)
            } else {
                merged.append(seg)
            }
        }

        // 拆分过长段。
        var split: [Segment] = []
        for seg in merged { split += splitLongSegment(cues, flat: flat, seg: seg) }

        // 转 SubtitleCue：index 从 1 连续，时间单调（钳制 end<=下一段 start）。
        var result: [SubtitleCue] = []
        for (i, seg) in split.enumerated() {
            var endSec = seg.endSec
            if i + 1 < split.count { endSec = min(endSec, split[i + 1].startSec) }
            if endSec < seg.startSec { endSec = seg.startSec }
            result.append(SubtitleCue(index: i + 1,
                                      start: secondsToSRTTime(seg.startSec),
                                      end: secondsToSRTTime(endSec),
                                      text: seg.text))
        }
        return result
    }

    /// 把过长段（时长超限且 token 足够多）在 token 边界均分成若干份；否则原样返回单段。
    /// 各份时间用边界 token 的本地插值，文本按词数等比切分。
    fileprivate static func splitLongSegment(_ cues: [SubtitleCue], flat: [FlatToken], seg: Segment) -> [Segment] {
        let tokenCount = seg.tokenEnd - seg.tokenStart
        let duration = seg.endSec - seg.startSec
        if duration <= resegmentMaxSegmentSeconds || tokenCount < resegmentMinSplitTokens {
            return [seg]
        }
        var parts = Int((duration / resegmentMaxSegmentSeconds).rounded(.up))
        parts = max(2, min(parts, tokenCount)) // 至少 2 份，至多每份 1 token
        let words = seg.text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var output: [Segment] = []
        for p in 0..<parts {
            var tStart = seg.tokenStart + tokenCount * p / parts
            var tEnd = seg.tokenStart + tokenCount * (p + 1) / parts
            if tEnd <= tStart { tEnd = tStart + 1 }
            if p == parts - 1 { tEnd = seg.tokenEnd }
            tStart = min(tStart, flat.count - 1)

            let wStart = words.count * p / parts
            let wEnd = p == parts - 1 ? words.count : words.count * (p + 1) / parts
            let text = wEnd > wStart ? words[wStart..<wEnd].joined(separator: " ") : seg.text
            output.append(Segment(
                startSec: tokenTime(cues, flat[tStart], edge: false),
                endSec: tokenTime(cues, flat[tEnd - 1], edge: true),
                tokenStart: tStart, tokenEnd: tEnd,
                text: text.trimmingCharacters(in: .whitespaces)))
        }
        return output
    }
}
