import Foundation

/// 本地 Whisper 识别输出的置信度概要。Whisper 对中/粤/韩等语言的歌唱内容常**自信地听错**或产出
/// 低置信乱码（青花瓷→「了出情话被风弄转」），此时没有更好的源可换（whisper 本就是 fallback），
/// 诚实做法是给用户「识别质量较低、字幕仅供参考」提示，而非把乱码当成自信字幕呈现。
///
/// **已知局限（保守取舍）**：whisper 置信度是弱信号——部分乱码（如韩语、个别中文）置信度并不低。
/// 因此除整体低置信外，还捕捉「多个 CJK token 被异常拉长，且其中存在极低概率 token」这类
/// timing/probability 组合信号。阈值刻意保守，只对明显低质输出报警，避免因单个错词误伤干净内容。
/// 常量唯一真值在
/// `Tests/fixtures/whisper-timing-constants.json` 的 `localASRConfidence` 段，两端契约断言。
/// 跨端镜像：windows/MoongateCore/LocalAsrConfidence.cs。
public struct LocalASRConfidenceSummary: Codable, Equatable, Sendable {
    public let assessedWordCount: Int
    public let averageProbability: Double
    public let lowConfidenceWordRatio: Double
    public let isLowConfidence: Bool
    public let scriptMismatchRatio: Double
    public let latinTokenRatio: Double
    public let dominantPhraseRatio: Double
    public let repeatedPhraseSpanSeconds: Double
    public let qualityIssues: [String]
    public let isLowQuality: Bool

    public var hasSevereQualityBlocker: Bool {
        qualityIssues.contains("phraseLoop")
            || qualityIssues.contains("autoLanguageMismatch")
            || qualityIssues.contains("nearEmptyTranscript")
    }

    public init(
        assessedWordCount: Int,
        averageProbability: Double,
        lowConfidenceWordRatio: Double,
        isLowConfidence: Bool,
        scriptMismatchRatio: Double = 0,
        latinTokenRatio: Double = 0,
        dominantPhraseRatio: Double = 0,
        repeatedPhraseSpanSeconds: Double = 0,
        qualityIssues: [String] = [],
        isLowQuality: Bool? = nil
    ) {
        self.assessedWordCount = assessedWordCount
        self.averageProbability = averageProbability
        self.lowConfidenceWordRatio = lowConfidenceWordRatio
        self.isLowConfidence = isLowConfidence
        self.scriptMismatchRatio = scriptMismatchRatio
        self.latinTokenRatio = latinTokenRatio
        self.dominantPhraseRatio = dominantPhraseRatio
        self.repeatedPhraseSpanSeconds = repeatedPhraseSpanSeconds
        self.qualityIssues = qualityIssues
        self.isLowQuality = isLowQuality ?? (isLowConfidence || !qualityIssues.isEmpty)
    }

    private enum CodingKeys: String, CodingKey {
        case assessedWordCount
        case averageProbability
        case lowConfidenceWordRatio
        case isLowConfidence
        case scriptMismatchRatio
        case latinTokenRatio
        case dominantPhraseRatio
        case repeatedPhraseSpanSeconds
        case qualityIssues
        case isLowQuality
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let assessedWordCount = try container.decode(Int.self, forKey: .assessedWordCount)
        let averageProbability = try container.decode(Double.self, forKey: .averageProbability)
        let lowConfidenceWordRatio = try container.decode(Double.self, forKey: .lowConfidenceWordRatio)
        let isLowConfidence = try container.decode(Bool.self, forKey: .isLowConfidence)
        let scriptMismatchRatio = try container.decodeIfPresent(Double.self, forKey: .scriptMismatchRatio) ?? 0
        let latinTokenRatio = try container.decodeIfPresent(Double.self, forKey: .latinTokenRatio) ?? 0
        let dominantPhraseRatio = try container.decodeIfPresent(Double.self, forKey: .dominantPhraseRatio) ?? 0
        let repeatedPhraseSpanSeconds = try container.decodeIfPresent(Double.self, forKey: .repeatedPhraseSpanSeconds) ?? 0
        let qualityIssues = try container.decodeIfPresent([String].self, forKey: .qualityIssues) ?? []
        let isLowQuality = try container.decodeIfPresent(Bool.self, forKey: .isLowQuality)
        self.init(
            assessedWordCount: assessedWordCount,
            averageProbability: averageProbability,
            lowConfidenceWordRatio: lowConfidenceWordRatio,
            isLowConfidence: isLowConfidence,
            scriptMismatchRatio: scriptMismatchRatio,
            latinTokenRatio: latinTokenRatio,
            dominantPhraseRatio: dominantPhraseRatio,
            repeatedPhraseSpanSeconds: repeatedPhraseSpanSeconds,
            qualityIssues: qualityIssues,
            isLowQuality: isLowQuality)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(assessedWordCount, forKey: .assessedWordCount)
        try container.encode(averageProbability, forKey: .averageProbability)
        try container.encode(lowConfidenceWordRatio, forKey: .lowConfidenceWordRatio)
        try container.encode(isLowConfidence, forKey: .isLowConfidence)
        try container.encode(scriptMismatchRatio, forKey: .scriptMismatchRatio)
        try container.encode(latinTokenRatio, forKey: .latinTokenRatio)
        try container.encode(dominantPhraseRatio, forKey: .dominantPhraseRatio)
        try container.encode(repeatedPhraseSpanSeconds, forKey: .repeatedPhraseSpanSeconds)
        try container.encode(qualityIssues, forKey: .qualityIssues)
        try container.encode(isLowQuality, forKey: .isLowQuality)
    }
}

public enum LocalASRConfidence {
    /// 平均词概率低于此值视为整体低置信。
    static let averageProbabilityFloor = 0.8
    /// 单词概率低于此值算「低置信词」。
    static let lowConfidenceWordProbability = 0.5
    /// 低置信词占比超过此值视为整体低置信。
    static let lowConfidenceWordRatioCeiling = 0.2
    /// 样本不足时不评估（短片段噪声大），避免误报。
    static let minimumAssessableWordCount = 24
    /// CJK 单 token 被拉长到这个时长以上，才进入异常 timing 候选。
    static let stretchedCJKTokenSecondsFloor = 2.5
    /// 只有形成多个异常拉长 CJK token 的集群，才把低概率拉长 token 视为低质信号。
    static let stretchedCJKTokenClusterCount = 3
    /// 异常拉长 token 的概率低于此值，视为极低置信 timing collapse。
    static let stretchedCJKLowProbabilityCeiling = 0.15

    /// 评估一段转写的整体置信度。只统计有概率、含可见字符的词。
    public static func assess(
        words: [ASRWord],
        segments: [ASRSegment] = [],
        languageCode: String? = nil,
        requestedLanguageCode: String? = nil,
        languageHintCode: String? = nil
    ) -> LocalASRConfidenceSummary {
        var probabilities: [Double] = []
        probabilities.reserveCapacity(words.count)
        for word in words {
            guard word.text.contains(where: { !$0.isWhitespace }) else { continue }
            guard let probability = word.probability else { continue }
            probabilities.append(probability)
        }
        let count = probabilities.count
        let scriptQuality = assessScriptQuality(words: words, languageCode: languageCode)
        let loopIssues = assessLoopQuality(words: words, languageCode: languageCode)
        let timingIssues = assessTimingQuality(words: words, languageCode: languageCode)
        let segmentQuality = assessSegmentQuality(
            segments: segments,
            languageCode: languageCode,
            requestedLanguageCode: requestedLanguageCode,
            languageHintCode: languageHintCode
        )
        let qualityIssues = Array(Set(scriptQuality.issues + loopIssues + timingIssues + segmentQuality.issues)).sorted()
        guard count > 0 else {
            return LocalASRConfidenceSummary(
                assessedWordCount: 0,
                averageProbability: 1,
                lowConfidenceWordRatio: 0,
                isLowConfidence: false,
                scriptMismatchRatio: scriptQuality.mismatchRatio,
                latinTokenRatio: scriptQuality.latinRatio,
                dominantPhraseRatio: segmentQuality.dominantPhraseRatio,
                repeatedPhraseSpanSeconds: segmentQuality.repeatedPhraseSpanSeconds,
                qualityIssues: qualityIssues)
        }
        let average = probabilities.reduce(0, +) / Double(count)
        let lowRatio = Double(probabilities.filter { $0 < lowConfidenceWordProbability }.count) / Double(count)
        let isLow = count >= minimumAssessableWordCount
            && (average < averageProbabilityFloor || lowRatio > lowConfidenceWordRatioCeiling)
        return LocalASRConfidenceSummary(
            assessedWordCount: count,
            averageProbability: average,
            lowConfidenceWordRatio: lowRatio,
            isLowConfidence: isLow,
            scriptMismatchRatio: scriptQuality.mismatchRatio,
            latinTokenRatio: scriptQuality.latinRatio,
            dominantPhraseRatio: segmentQuality.dominantPhraseRatio,
            repeatedPhraseSpanSeconds: segmentQuality.repeatedPhraseSpanSeconds,
            qualityIssues: qualityIssues)
    }

    public static func assessSubtitle(
        raw: String,
        fileName: String,
        languageCode: String? = nil,
        requestedLanguageCode: String? = nil,
        languageHintCode: String? = nil
    ) -> LocalASRConfidenceSummary {
        let cues = parseSubtitleCues(raw, fileName: fileName)
        let segments = cues.compactMap { cue -> ASRSegment? in
            guard let start = srtTimeToSeconds(cue.start),
                  let end = srtTimeToSeconds(cue.end) else {
                return nil
            }
            return ASRSegment(text: cue.text, startSeconds: start, endSeconds: max(end, start))
        }
        let words = segments.map {
            ASRWord(text: $0.text, startSeconds: $0.startSeconds, endSeconds: $0.endSeconds, probability: nil)
        }
        return assess(
            words: words,
            segments: segments,
            languageCode: languageCode,
            requestedLanguageCode: requestedLanguageCode,
            languageHintCode: languageHintCode
        )
    }

    private static func assessScriptQuality(
        words: [ASRWord],
        languageCode: String?
    ) -> (mismatchRatio: Double, latinRatio: Double, issues: [String]) {
        let language = normalizeLanguageCode(languageCode)
        guard ["ja", "ko", "zh", "yue"].contains(language) else {
            return (0, 0, [])
        }
        var visible = 0
        var expected = 0
        var latin = 0
        for scalar in words.flatMap({ $0.text.unicodeScalars }) {
            if CharacterSet.whitespacesAndNewlines.contains(scalar)
                || CharacterSet.punctuationCharacters.contains(scalar)
                || CharacterSet.symbols.contains(scalar) {
                continue
            }
            visible += 1
            if isExpectedScript(scalar, language: language) {
                expected += 1
            }
            if isLatinLetter(scalar) {
                latin += 1
            }
        }
        guard visible >= minimumAssessableWordCount else {
            return (0, 0, [])
        }
        let expectedRatio = Double(expected) / Double(visible)
        let latinRatio = Double(latin) / Double(visible)
        let mismatchRatio = 1 - expectedRatio
        let issues = expectedRatio < 0.25 && latinRatio > 0.5 ? ["scriptMismatch"] : []
        return (mismatchRatio, latinRatio, issues)
    }

    private static func assessLoopQuality(
        words: [ASRWord],
        languageCode: String?
    ) -> [String] {
        let language = normalizeLanguageCode(languageCode)
        guard ["ja", "ko", "zh", "yue"].contains(language) else { return [] }
        let tokens = words
            .map { normalizeLoopToken($0.text) }
            .filter { !$0.isEmpty }
        guard tokens.count >= minimumAssessableWordCount else { return [] }

        var counts: [String: Int] = [:]
        var maxRun = 0
        var currentRun = 0
        var previous: String?
        for token in tokens {
            counts[token, default: 0] += 1
            if token == previous {
                currentRun += 1
            } else {
                currentRun = 1
                previous = token
            }
            maxRun = max(maxRun, currentRun)
        }
        let uniqueRatio = Double(counts.count) / Double(tokens.count)
        let dominantRatio = Double(counts.values.max() ?? 0) / Double(tokens.count)
        var issues: [String] = []
        if uniqueRatio <= 0.16 {
            issues.append("lowDiversity")
        }
        if maxRun >= 8 || (dominantRatio >= 0.5 && uniqueRatio <= 0.20) {
            issues.append("repetitionLoop")
        }
        return issues
    }

    private static func assessTimingQuality(
        words: [ASRWord],
        languageCode: String?
    ) -> [String] {
        let language = normalizeLanguageCode(languageCode)
        guard isCJKLanguage(language), words.count >= minimumAssessableWordCount else { return [] }

        let stretchedCJKWords = words.filter { word in
            word.endSeconds > word.startSeconds
                && word.endSeconds - word.startSeconds >= stretchedCJKTokenSecondsFloor
                && word.text.unicodeScalars.contains { isExpectedScript($0, language: language) }
        }
        guard stretchedCJKWords.count >= stretchedCJKTokenClusterCount else { return [] }
        let hasLowConfidenceStretchedToken = stretchedCJKWords.contains { word in
            guard let probability = word.probability else { return false }
            return probability <= stretchedCJKLowProbabilityCeiling
        }
        return hasLowConfidenceStretchedToken ? ["stretchedLowConfidenceCJKToken"] : []
    }

    private static func assessSegmentQuality(
        segments: [ASRSegment],
        languageCode: String?,
        requestedLanguageCode: String?,
        languageHintCode: String?
    ) -> (dominantPhraseRatio: Double, repeatedPhraseSpanSeconds: Double, issues: [String]) {
        let phrases = segments
            .map { segment in
                (
                    phrase: normalizeLoopToken(segment.text),
                    start: segment.startSeconds,
                    end: segment.endSeconds
                )
            }
            .filter { !$0.phrase.isEmpty }

        var issues: [String] = []
        if looksNearEmptyTranscript(segments) {
            issues.append("nearEmptyTranscript")
        }
        let detected = normalizeLanguageCode(languageCode)
        let hint = normalizeLanguageCode(languageHintCode)
        if isAutoLanguage(requestedLanguageCode)
            && isCJKLanguage(hint)
            && !detected.isEmpty
            && detected != hint {
            issues.append("autoLanguageMismatch")
        }

        guard phrases.count >= 3 else {
            return (0, 0, issues)
        }

        var groups: [String: [(start: Double, end: Double)]] = [:]
        for phrase in phrases {
            groups[phrase.phrase, default: []].append((start: phrase.start, end: phrase.end))
        }
        guard let dominant = groups.max(by: { lhs, rhs in
            lhs.value.count < rhs.value.count
        }) else {
            return (0, 0, issues)
        }
        let dominantCount = dominant.value.count
        let dominantRatio = Double(dominantCount) / Double(phrases.count)
        let earliest = dominant.value.map(\.start).min() ?? 0
        let latest = dominant.value.map(\.end).max() ?? earliest
        var repeatedSpan = max(0, latest - earliest)
        let overallStart = phrases.map(\.start).min() ?? earliest
        let overallEnd = phrases.map(\.end).max() ?? latest
        let overallSpan = max(0, overallEnd - overallStart)

        if groups.count == 1
            && dominantCount >= 3
            && phrases.count <= 4
            && repeatedSpan >= 20 {
            issues.append("lowSegmentDiversity")
        }
        if dominantCount >= 6
            && dominantRatio >= 0.6
            && repeatedSpan >= 25
            && dominant.key.count >= 4 {
            issues.append("phraseLoop")
        }
        if isFragmentedCJKLoop(
            phrases: phrases.map(\.phrase),
            languageCode: detected.isEmpty ? hint : detected,
            groupCount: groups.count,
            repeatedSpan: overallSpan
        ) {
            repeatedSpan = max(repeatedSpan, overallSpan)
            issues.append("lowSegmentDiversity")
            issues.append("phraseLoop")
        }

        return (dominantRatio, repeatedSpan, issues)
    }

    private static func looksNearEmptyTranscript(_ segments: [ASRSegment]) -> Bool {
        let meaningfulScalars = segments.flatMap(\.text.unicodeScalars).filter { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar)
                && !CharacterSet.punctuationCharacters.contains(scalar)
                && !CharacterSet.symbols.contains(scalar)
                && !CharacterSet.controlCharacters.contains(scalar)
        }
        return segments.count == 1 && meaningfulScalars.count <= 2
    }

    private static func isFragmentedCJKLoop(
        phrases: [String],
        languageCode: String,
        groupCount: Int,
        repeatedSpan: Double
    ) -> Bool {
        guard isCJKLanguage(languageCode),
              phrases.count >= 5,
              groupCount >= 3,
              repeatedSpan >= 20 else {
            return false
        }
        let scalars = phrases.joined().unicodeScalars.filter { scalar in
            !CharacterSet.punctuationCharacters.contains(scalar)
                && !CharacterSet.symbols.contains(scalar)
                && !CharacterSet.whitespacesAndNewlines.contains(scalar)
        }
        guard scalars.count >= 18 else { return false }
        let uniqueRatio = Double(Set(scalars.map(\.value)).count) / Double(scalars.count)
        let averagePhraseLength = Double(scalars.count) / Double(phrases.count)
        return uniqueRatio <= 0.25 && averagePhraseLength <= 8
    }

    private static func normalizeLoopToken(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .unicodeScalars
            .filter { scalar in
                !CharacterSet.punctuationCharacters.contains(scalar)
                    && !CharacterSet.symbols.contains(scalar)
            }
            .map(String.init)
            .joined()
            .lowercased()
    }

    private static func normalizeLanguageCode(_ raw: String?) -> String {
        let lower = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.isEmpty || lower == "auto" || lower == "und" || lower == "unknown" { return "" }
        if lower == "yue" { return "yue" }
        if lower.hasPrefix("zh") { return "zh" }
        if lower.hasPrefix("ja") { return "ja" }
        if lower.hasPrefix("ko") { return "ko" }
        return lower
    }

    private static func isAutoLanguage(_ raw: String?) -> Bool {
        let lower = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lower.isEmpty || lower == "auto" || lower == "und" || lower == "unknown"
    }

    private static func isCJKLanguage(_ language: String) -> Bool {
        language == "ja" || language == "ko" || language == "zh" || language == "yue"
    }

    private static func isExpectedScript(_ scalar: UnicodeScalar, language: String) -> Bool {
        switch language {
        case "ko":
            return (0xAC00...0xD7AF).contains(Int(scalar.value))
        case "ja":
            return (0x3040...0x30FF).contains(Int(scalar.value))
                || (0x4E00...0x9FFF).contains(Int(scalar.value))
        case "zh", "yue":
            return (0x4E00...0x9FFF).contains(Int(scalar.value))
        default:
            return false
        }
    }

    private static func isLatinLetter(_ scalar: UnicodeScalar) -> Bool {
        (65...90).contains(Int(scalar.value)) || (97...122).contains(Int(scalar.value))
    }
}
