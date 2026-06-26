import Foundation

/// Outcome of post-download subtitle source resolution: which file/source the translation pipeline
/// will actually use, why, and whether we fell back to local ASR. Surfaced to the UI's disclosure
/// area so the user can see the real source behind their language pick.
public struct ResolvedSubtitleSource: Equatable, Sendable {
    public let languageCode: String
    public let selectedFile: URL
    public let selectedKind: SubtitleSourceKind
    public let qualityVerdict: PlatformSubtitleQualityGate.Verdict?
    public let usedLocalASRFallback: Bool
    public let fallbackReasons: [PlatformSubtitleQualityGate.Reason]
    public let candidateReports: [SubtitleSourceCandidateReport]

    public init(
        languageCode: String,
        selectedFile: URL,
        selectedKind: SubtitleSourceKind,
        qualityVerdict: PlatformSubtitleQualityGate.Verdict? = nil,
        usedLocalASRFallback: Bool = false,
        fallbackReasons: [PlatformSubtitleQualityGate.Reason] = [],
        candidateReports: [SubtitleSourceCandidateReport] = []
    ) {
        self.languageCode = languageCode
        self.selectedFile = selectedFile
        self.selectedKind = selectedKind
        self.qualityVerdict = qualityVerdict
        self.usedLocalASRFallback = usedLocalASRFallback
        self.fallbackReasons = fallbackReasons
        self.candidateReports = candidateReports
    }
}

public struct SubtitleSourceCandidateReport: Equatable, Sendable {
    public let sourceKind: SubtitleSourceKind
    public let languageCode: String
    public let available: Bool
    public let selected: Bool
    public let usable: Bool
    public let reasons: [String]

    public init(
        sourceKind: SubtitleSourceKind,
        languageCode: String,
        available: Bool,
        selected: Bool,
        usable: Bool,
        reasons: [String] = []
    ) {
        self.sourceKind = sourceKind
        self.languageCode = languageCode
        self.available = available
        self.selected = selected
        self.usable = usable
        self.reasons = reasons
    }
}

public struct SongSubtitleSourceArbitration: Equatable, Sendable {
    public let selectedKind: SubtitleSourceKind?
    public let candidateReports: [SubtitleSourceCandidateReport]
}

public enum SongSubtitleSourceArbiter {
    public static func arbitrate(
        languageCode: String,
        tracks: [SubtitleChoice],
        platformAutoVerdict: PlatformSubtitleQualityGate.Verdict?,
        localASRAvailable: Bool
    ) -> SongSubtitleSourceArbitration {
        let normalized = SubtitleLanguageChoice.normalizedLanguageCode(languageCode)
        let sameLanguageTracks = tracks.filter {
            SubtitleLanguageChoice.normalizedLanguageCode($0.languageCode) == normalized
        }
        let manualAvailable = sameLanguageTracks.contains { $0.sourceKind == .manual || $0.sourceKind == .hlsManifest || $0.sourceKind == .importedFile }
        let autoAvailable = sameLanguageTracks.contains { $0.sourceKind == .platformAuto }
        let autoUsable = platformAutoVerdict?.usable ?? autoAvailable

        let selected: SubtitleSourceKind?
        if manualAvailable {
            selected = .manual
        } else if autoAvailable, autoUsable {
            selected = .platformAuto
        } else if localASRAvailable {
            selected = .localASR
        } else if autoAvailable {
            selected = .platformAuto
        } else {
            selected = nil
        }

        let autoReasons = platformAutoVerdict?.reasons.map(\.rawValue) ?? []
        let reports = [
            SubtitleSourceCandidateReport(
                sourceKind: .manual,
                languageCode: normalized,
                available: manualAvailable,
                selected: selected == .manual,
                usable: manualAvailable,
                reasons: manualAvailable ? [] : ["missing"]
            ),
            SubtitleSourceCandidateReport(
                sourceKind: .platformAuto,
                languageCode: normalized,
                available: autoAvailable,
                selected: selected == .platformAuto,
                usable: autoAvailable && autoUsable,
                reasons: autoAvailable ? autoReasons : ["missing"]
            ),
            SubtitleSourceCandidateReport(
                sourceKind: .localASR,
                languageCode: normalized,
                available: localASRAvailable,
                selected: selected == .localASR,
                usable: localASRAvailable,
                reasons: localASRAvailable ? [] : ["unavailable"]
            )
        ]
        return SongSubtitleSourceArbitration(selectedKind: selected, candidateReports: reports)
    }
}

/// Assesses whether a platform (YouTube) auto-caption track is USABLE as a translation source.
///
/// Critical design rule (hard-won): this gate must NEVER compare a whisper transcript against the
/// auto-caption, and must NEVER score timing. YouTube auto-captions pass through Google's
/// human-aligned word timestamps, so their timing is structurally better than whisper's — judging
/// "quality" by timing would make whisper always lose and defeat the whole point of the fallback.
/// Instead we only look at the auto-caption's OWN intrinsic usability: language match, cue density,
/// coverage, and garbling/repetition. Whisper is only generated when this gate says "not usable".
public enum PlatformSubtitleQualityGate {
    public enum Reason: String, Codable, Sendable, CaseIterable {
        case languageMismatch
        case tooFewCues
        case lowCoverage
        case garbledOrRepetitive
    }

    public struct SubtitleSourceQualityReport: Equatable, Sendable {
        public let cueCount: Int
        public let visibleScalarCount: Int
        public let cjkLanguage: Bool
        public let cjkScalarRatio: Double
        public let latinScalarRatio: Double
        public let adjacentIdenticalRatio: Double
        public let badScalarRatio: Double
        public let uniqueCueTextRatio: Double
        public let romanizedLoopTokenCount: Int
        public let romanizedLoopMaxRun: Int
        public let romanizedLoopTokenRatio: Double
        public let soundEffectCueCount: Int
        public let soundEffectCueRatio: Double
        public let soundEffectDurationRatio: Double
        public let longCueCount: Int
        public let longCueRatio: Double
        public let maxCueDuration: Double

        public init(
            cueCount: Int,
            visibleScalarCount: Int,
            cjkLanguage: Bool,
            cjkScalarRatio: Double,
            latinScalarRatio: Double,
            adjacentIdenticalRatio: Double,
            badScalarRatio: Double,
            uniqueCueTextRatio: Double,
            romanizedLoopTokenCount: Int,
            romanizedLoopMaxRun: Int,
            romanizedLoopTokenRatio: Double,
            soundEffectCueCount: Int,
            soundEffectCueRatio: Double,
            soundEffectDurationRatio: Double,
            longCueCount: Int,
            longCueRatio: Double,
            maxCueDuration: Double
        ) {
            self.cueCount = cueCount
            self.visibleScalarCount = visibleScalarCount
            self.cjkLanguage = cjkLanguage
            self.cjkScalarRatio = cjkScalarRatio
            self.latinScalarRatio = latinScalarRatio
            self.adjacentIdenticalRatio = adjacentIdenticalRatio
            self.badScalarRatio = badScalarRatio
            self.uniqueCueTextRatio = uniqueCueTextRatio
            self.romanizedLoopTokenCount = romanizedLoopTokenCount
            self.romanizedLoopMaxRun = romanizedLoopMaxRun
            self.romanizedLoopTokenRatio = romanizedLoopTokenRatio
            self.soundEffectCueCount = soundEffectCueCount
            self.soundEffectCueRatio = soundEffectCueRatio
            self.soundEffectDurationRatio = soundEffectDurationRatio
            self.longCueCount = longCueCount
            self.longCueRatio = longCueRatio
            self.maxCueDuration = maxCueDuration
        }

        public static let empty = SubtitleSourceQualityReport(
            cueCount: 0,
            visibleScalarCount: 0,
            cjkLanguage: false,
            cjkScalarRatio: 0,
            latinScalarRatio: 0,
            adjacentIdenticalRatio: 0,
            badScalarRatio: 0,
            uniqueCueTextRatio: 0,
            romanizedLoopTokenCount: 0,
            romanizedLoopMaxRun: 0,
            romanizedLoopTokenRatio: 0,
            soundEffectCueCount: 0,
            soundEffectCueRatio: 0,
            soundEffectDurationRatio: 0,
            longCueCount: 0,
            longCueRatio: 0,
            maxCueDuration: 0
        )
    }

    public struct Verdict: Equatable, Sendable {
        public let usable: Bool
        public let reasons: [Reason]
        public let report: SubtitleSourceQualityReport

        public init(
            usable: Bool,
            reasons: [Reason],
            report: SubtitleSourceQualityReport = .empty
        ) {
            self.usable = usable
            self.reasons = reasons
            self.report = report
        }
    }

    // Thresholds. Single source of truth lives in the cross-platform fixture
    // (`platformSubtitleQualityGate` section); Swift and C# copies are each asserted equal to it.
    public static let minimumUsableCueCount = 8
    public static let minimumCoverageRatio = 0.35
    public static let repetitionRatioThreshold = 0.5
    public static let garbledRatioThreshold = 0.05
    public static let cjkLatinNoiseRatioThreshold = 0.20
    public static let cjkContentMismatchLatinRatioThreshold = 0.55
    public static let cjkContentMismatchCJKRatioThreshold = 0.15
    public static let cjkLongCueDurationThreshold = 12.0
    public static let cjkLongCueRatioThreshold = 0.08
    public static let cjkLongCueMinCount = 2
    public static let romanizedLoopTokenRatioThreshold = 0.35
    public static let romanizedLoopMinTokenCount = 6
    public static let romanizedLoopMinMaxRun = 3
    public static let soundEffectCueRatioThreshold = 0.10
    public static let soundEffectCueMinCount = 4
    public static let soundEffectDurationRatioThreshold = 0.12
    public static let soundEffectDurationMinCount = 2

    /// - Parameters:
    ///   - cues: parsed cues of the auto-caption candidate.
    ///   - requestedLanguageCode: language the user picked (normalized or raw; normalized here).
    ///   - subtitleLanguageCode: language code of the candidate track.
    ///   - videoDurationSeconds: total video duration if known. nil → coverage check is skipped.
    public static func assess(
        cues: [SubtitleCue],
        requestedLanguageCode: String?,
        subtitleLanguageCode: String?,
        videoDurationSeconds: Double?
    ) -> Verdict {
        var reasons: [Reason] = []
        let report = qualityReport(
            cues: cues,
            requestedLanguageCode: requestedLanguageCode,
            subtitleLanguageCode: subtitleLanguageCode
        )

        // 1) Language match (fatal). Normalize both sides to language buckets.
        if let requested = requestedLanguageCode, !requested.isEmpty,
           let actual = subtitleLanguageCode, !actual.isEmpty {
            let r = SubtitleLanguageChoice.normalizedLanguageCode(requested)
            let a = SubtitleLanguageChoice.normalizedLanguageCode(actual)
            if r != a {
                reasons.append(.languageMismatch)
            }
        }

        // 2) Cue density.
        if cues.count < minimumUsableCueCount {
            reasons.append(.tooFewCues)
        }

        // 3) Coverage (only when duration is known and positive).
        if let duration = videoDurationSeconds, duration > 0 {
            let covered = totalCoveredSeconds(cues)
            if covered / duration < minimumCoverageRatio {
                reasons.append(.lowCoverage)
            }
        }

        // 4) Garbling / repetition.
        if reportLooksGarbledOrRepetitive(report) {
            reasons.append(.garbledOrRepetitive)
        }

        return Verdict(usable: reasons.isEmpty, reasons: reasons, report: report)
    }

    /// Convenience: parse + clean a subtitle file (the cues the viewer actually sees) and assess it.
    /// Mirrors `SubtitleTimingHealth.assess(subtitleFileURL:)` so callers in the app module don't
    /// need the module-internal `parseSRT`/`parseVTT`/`cleanCues`. An unreadable file is treated as
    /// usable (we can't fault content we couldn't read — avoids a needless fallback).
    public static func assess(
        subtitleFileURL url: URL,
        requestedLanguageCode: String?,
        subtitleLanguageCode: String?,
        videoDurationSeconds: Double?
    ) -> Verdict {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            return Verdict(usable: true, reasons: [])
        }
        let isVTT = url.pathExtension.lowercased() == "vtt"
        let cleaned = cleanCues(isVTT ? parseVTT(raw) : parseSRT(raw))
        return assess(
            cues: cleaned,
            requestedLanguageCode: requestedLanguageCode,
            subtitleLanguageCode: subtitleLanguageCode,
            videoDurationSeconds: videoDurationSeconds)
    }

    static func totalCoveredSeconds(_ cues: [SubtitleCue]) -> Double {
        var total = 0.0
        for cue in cues {
            guard let s = srtTimeToSeconds(cue.start), let e = srtTimeToSeconds(cue.end), e > s else { continue }
            total += (e - s)
        }
        return total
    }

    static func looksGarbledOrRepetitive(_ cues: [SubtitleCue]) -> Bool {
        reportLooksGarbledOrRepetitive(qualityReport(
            cues: cues,
            requestedLanguageCode: nil,
            subtitleLanguageCode: nil
        ))
    }

    public static func qualityReport(
        cues: [SubtitleCue],
        requestedLanguageCode: String?,
        subtitleLanguageCode: String?
    ) -> SubtitleSourceQualityReport {
        guard !cues.isEmpty else { return .empty }

        let cjkLanguage = isCJKLanguageCode(requestedLanguageCode) || isCJKLanguageCode(subtitleLanguageCode)
        let romanizedLoopSensitiveLanguage = isRomanizedLoopSensitiveLanguageCode(requestedLanguageCode)
            || isRomanizedLoopSensitiveLanguageCode(subtitleLanguageCode)
        var identical = 0
        var comparable = 0
        var previous: String?
        var visibleScalars = 0
        var badScalars = 0
        var cjkScalars = 0
        var latinScalars = 0
        var uniqueTexts: Set<String> = []
        var latinTokens: [String] = []
        var soundEffectCueCount = 0
        var soundEffectDuration = 0.0
        var subtitleDuration = 0.0
        var longCueCount = 0
        var maxCueDuration = 0.0

        for cue in cues {
            let trimmed = cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let duration: Double
            if let start = srtTimeToSeconds(cue.start), let end = srtTimeToSeconds(cue.end), end > start {
                duration = end - start
            } else {
                duration = 0
            }
            subtitleDuration += duration
            maxCueDuration = max(maxCueDuration, duration)
            if duration >= cjkLongCueDurationThreshold {
                longCueCount += 1
            }
            if let previous {
                comparable += 1
                if !trimmed.isEmpty && trimmed == previous {
                    identical += 1
                }
            }
            previous = trimmed
            if !trimmed.isEmpty {
                uniqueTexts.insert(trimmed)
            }
            if isSoundEffectCueText(trimmed) {
                soundEffectCueCount += 1
                soundEffectDuration += duration
            }
            let qualityText = cjkLanguage ? removingParentheticalLatinGlosses(from: cue.text) : cue.text
            latinTokens.append(contentsOf: latinWordTokens(in: qualityText))
            for scalar in qualityText.unicodeScalars where !scalar.properties.isWhitespace {
                visibleScalars += 1
                if scalar.value == 0xFFFD || isControlScalar(scalar) {
                    badScalars += 1
                }
                if isCJKScalar(scalar) {
                    cjkScalars += 1
                }
                if isLatinLetterScalar(scalar) {
                    latinScalars += 1
                }
            }
        }

        let suspiciousTokens = romanizedLoopSensitiveLanguage ? latinTokens.filter(isSuspiciousRomanizedLoopToken) : []
        var counts: [String: Int] = [:]
        for token in suspiciousTokens {
            counts[token, default: 0] += 1
        }
        let repeatedLoopTokenCount = counts.values.filter { $0 >= 2 }.reduce(0, +)
        let maxRun = counts.values.max() ?? 0
        let loopRatio = latinTokens.isEmpty ? 0 : Double(repeatedLoopTokenCount) / Double(latinTokens.count)

        return SubtitleSourceQualityReport(
            cueCount: cues.count,
            visibleScalarCount: visibleScalars,
            cjkLanguage: cjkLanguage,
            cjkScalarRatio: visibleScalars == 0 ? 0 : Double(cjkScalars) / Double(visibleScalars),
            latinScalarRatio: visibleScalars == 0 ? 0 : Double(latinScalars) / Double(visibleScalars),
            adjacentIdenticalRatio: comparable == 0 ? 0 : Double(identical) / Double(comparable),
            badScalarRatio: visibleScalars == 0 ? 0 : Double(badScalars) / Double(visibleScalars),
            uniqueCueTextRatio: cues.isEmpty ? 0 : Double(uniqueTexts.count) / Double(cues.count),
            romanizedLoopTokenCount: repeatedLoopTokenCount,
            romanizedLoopMaxRun: maxRun,
            romanizedLoopTokenRatio: loopRatio,
            soundEffectCueCount: soundEffectCueCount,
            soundEffectCueRatio: cues.isEmpty ? 0 : Double(soundEffectCueCount) / Double(cues.count),
            soundEffectDurationRatio: subtitleDuration > 0 ? soundEffectDuration / subtitleDuration : 0,
            longCueCount: longCueCount,
            longCueRatio: cues.isEmpty ? 0 : Double(longCueCount) / Double(cues.count),
            maxCueDuration: maxCueDuration
        )
    }

    private static func reportLooksGarbledOrRepetitive(_ report: SubtitleSourceQualityReport) -> Bool {
        if report.adjacentIdenticalRatio >= repetitionRatioThreshold {
            return true
        }
        if report.badScalarRatio >= garbledRatioThreshold {
            return true
        }
        if report.cjkLanguage,
           report.visibleScalarCount >= 6,
           report.latinScalarRatio >= cjkContentMismatchLatinRatioThreshold,
           report.cjkScalarRatio <= cjkContentMismatchCJKRatioThreshold {
            return true
        }
        let romanizedLoop = report.romanizedLoopTokenCount >= romanizedLoopMinTokenCount
            && report.romanizedLoopMaxRun >= romanizedLoopMinMaxRun
            && report.romanizedLoopTokenRatio >= romanizedLoopTokenRatioThreshold
        if report.cjkLanguage,
           report.visibleScalarCount >= 80,
           report.latinScalarRatio >= cjkLatinNoiseRatioThreshold,
           romanizedLoop {
            return true
        }
        if report.cjkLanguage,
           report.longCueCount >= cjkLongCueMinCount,
           report.longCueRatio >= cjkLongCueRatioThreshold {
            return true
        }
        if report.soundEffectCueCount >= soundEffectCueMinCount,
           report.soundEffectCueRatio >= soundEffectCueRatioThreshold {
            return true
        }
        if report.soundEffectCueCount >= soundEffectDurationMinCount,
           report.soundEffectDurationRatio >= soundEffectDurationRatioThreshold {
            return true
        }
        return false
    }

    private static func isSoundEffectCueText(_ text: String) -> Bool {
        let compact = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
        guard !compact.isEmpty else { return false }
        let markers = [
            "[音楽]", "［音楽］", "[拍手]", "［拍手］",
            "[music]", "[applause]", "(music)", "(applause)",
            "[musica]", "[música]", "[musique]", "[musik]",
            "(musica)", "(música)", "(musique)", "(musik)"
        ]
        if markers.contains(where: { compact.contains($0) }) {
            return true
        }
        if !compact.isEmpty, compact.allSatisfy({ $0 == "♪" || $0 == "♫" }) {
            return true
        }
        return compact == "音楽"
            || compact == "拍手"
            || compact == "music"
            || compact == "applause"
            || compact == "musica"
            || compact == "música"
            || compact == "musique"
            || compact == "musik"
    }

    private static func removingParentheticalLatinGlosses(from text: String) -> String {
        guard containsCJKScalar(in: text) else { return text }
        var result = ""
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            let close: Character?
            if character == "(" {
                close = ")"
            } else if character == "（" {
                close = "）"
            } else {
                close = nil
            }

            if let close,
               let closeIndex = text[index...].firstIndex(of: close) {
                let innerStart = text.index(after: index)
                let inner = String(text[innerStart..<closeIndex])
                if containsLatinLetter(in: inner), !containsCJKScalar(in: inner) {
                    index = text.index(after: closeIndex)
                    continue
                }
            }

            result.append(character)
            index = text.index(after: index)
        }

        return result
    }

    private static func containsCJKScalar(in text: String) -> Bool {
        text.unicodeScalars.contains(where: isCJKScalar)
    }

    private static func containsLatinLetter(in text: String) -> Bool {
        text.unicodeScalars.contains(where: isLatinLetterScalar)
    }

    private static func isCJKLanguageCode(_ code: String?) -> Bool {
        guard let code, !code.isEmpty else { return false }
        let normalized = SubtitleLanguageChoice.normalizedLanguageCode(code)
        return normalized == "ja"
            || normalized == "ko"
            || normalized == "zh"
            || normalized == "yue"
            || normalized == "cmn"
    }

    private static func isRomanizedLoopSensitiveLanguageCode(_ code: String?) -> Bool {
        guard let code, !code.isEmpty else { return false }
        let normalized = SubtitleLanguageChoice.normalizedLanguageCode(code)
        return normalized == "ja" || normalized == "zh" || normalized == "yue" || normalized == "cmn"
    }

    private static func isCJKScalar(_ scalar: UnicodeScalar) -> Bool {
        let v = scalar.value
        return (0x3040...0x30FF).contains(v)
            || (0x3400...0x4DBF).contains(v)
            || (0x4E00...0x9FFF).contains(v)
            || (0xAC00...0xD7A3).contains(v)
            || (0xF900...0xFAFF).contains(v)
            || (0x20000...0x2FA1F).contains(v)
    }

    private static func isLatinLetterScalar(_ scalar: UnicodeScalar) -> Bool {
        let v = scalar.value
        return (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v)
    }

    private static func latinWordTokens(in text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for scalar in text.unicodeScalars {
            if isLatinLetterScalar(scalar) {
                current.append(Character(scalar))
            } else if !current.isEmpty {
                tokens.append(current.lowercased())
                current = ""
            }
        }
        if !current.isEmpty {
            tokens.append(current.lowercased())
        }
        return tokens
    }

    private static func isSuspiciousRomanizedLoopToken(_ token: String) -> Bool {
        guard (2...6).contains(token.count) else { return false }
        guard token.unicodeScalars.allSatisfy(isLatinLetterScalar) else { return false }
        guard token.unicodeScalars.contains(where: { "aeiou".unicodeScalars.contains($0) }) else { return false }
        let commonSafeTokens: Set<String> = [
            "mv", "live", "music", "video", "cover", "official", "the", "and", "you", "yo"
        ]
        return !commonSafeTokens.contains(token)
    }

    static func isControlScalar(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        // C0 controls except tab/newline/carriage return, plus DEL and C1 controls.
        if v == 0x09 || v == 0x0A || v == 0x0D { return false }
        return v < 0x20 || (0x7F...0x9F).contains(v)
    }

    /// Parses a yt-dlp style duration string ("2:31", "1:02:03", "45") into seconds. nil when the
    /// string is missing or unparseable (callers then skip the coverage check).
    public static func parseDurationSeconds(_ text: String?) -> Double? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count <= 3 else { return nil }
        var total = 0.0
        for part in parts {
            guard let value = Double(part), value >= 0 else { return nil }
            total = total * 60 + value
        }
        return total
    }
}
