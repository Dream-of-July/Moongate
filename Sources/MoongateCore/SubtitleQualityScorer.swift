import Foundation

public enum SubtitleQualityScorer {
    public static func score(
        candidate: SubtitleSourceCandidate,
        requestedLanguageCode: String?,
        videoDurationSeconds: Double?
    ) -> SubtitleSourceScore {
        guard let url = candidate.fileURL else {
            let localGenerated = candidate.kind == .localASR || candidate.kind == .cloudASR
            return SubtitleSourceScore(
                candidateID: candidate.id,
                kind: candidate.kind,
                languageCode: normalizedLanguage(candidate.languageCode),
                score: localGenerated ? 45 : 0,
                verdict: localGenerated ? .usable : .unusable,
                reasons: localGenerated ? ["notGeneratedYet"] : ["missingFile"],
                report: nil
            )
        }

        let cues = loadCues(from: url)
        let gate = PlatformSubtitleQualityGate.assess(
            cues: cues.cleaned,
            requestedLanguageCode: requestedLanguageCode,
            subtitleLanguageCode: candidate.languageCode,
            videoDurationSeconds: videoDurationSeconds
        )
        let rawReport = PlatformSubtitleQualityGate.qualityReport(
            cues: cues.raw,
            requestedLanguageCode: requestedLanguageCode,
            subtitleLanguageCode: candidate.languageCode
        )
        let report = diagnosticReport(cleaned: gate.report, raw: rawReport)
        let extraReasons = contentReasons(cues.raw)
        var value = baseScore(for: candidate.kind)
        let scoringReport = gate.report
        var reasons = gate.reasons.map(\.rawValue)

        value += min(0.80, coverageEstimate(report: scoringReport)) * 25
        value += min(1.0, Double(scoringReport.visibleScalarCount) / 1400.0) * 10
        value += scoringReport.uniqueCueTextRatio * 8

        if gate.reasons.contains(.languageMismatch) { value -= 80 }
        if gate.reasons.contains(.tooFewCues) { value -= 30 }
        if gate.reasons.contains(.lowCoverage) { value -= 25 }
        if gate.reasons.contains(.garbledOrRepetitive) { value -= 35 }
        if soundEffectDominated(rawReport),
           !reasons.contains(PlatformSubtitleQualityGate.Reason.garbledOrRepetitive.rawValue) {
            value -= 35
            reasons.append(PlatformSubtitleQualityGate.Reason.garbledOrRepetitive.rawValue)
        }

        value -= min(25, report.soundEffectCueRatio * 80)
        value -= min(20, report.longCueRatio * 90)
        value -= min(25, report.adjacentIdenticalRatio * 70)
        value -= min(20, report.badScalarRatio * 200)
        value -= min(18, report.romanizedLoopTokenRatio * 40)

        if extraReasons.contains("hallucinationLikePhrase") { value -= 45 }
        if extraReasons.contains("shortCueFragmentation") { value -= 16 }
        reasons.append(contentsOf: extraReasons)

        let clamped = min(100, max(0, value))
        let verdict = verdict(for: clamped)
        if verdict == .lowConfidence { reasons.append("lowConfidence") }
        if verdict == .unusable { reasons.append("unusable") }

        return SubtitleSourceScore(
            candidateID: candidate.id,
            kind: candidate.kind,
            languageCode: normalizedLanguage(candidate.languageCode),
            score: clamped,
            verdict: verdict,
            reasons: Array(Set(reasons)).sorted(),
            report: report
        )
    }

    private static func baseScore(for kind: SubtitleSourceKind) -> Double {
        switch kind {
        case .manual:
            return 85
        case .importedFile:
            return 82
        case .hlsManifest:
            return 76
        case .platformAuto:
            return 58
        case .cloudASR:
            return 70
        case .localASR:
            return 50
        }
    }

    private static func verdict(for score: Double) -> SubtitleQualityVerdict {
        if score >= 85 { return .excellent }
        if score >= 72 { return .good }
        if score >= 55 { return .usable }
        if score >= 35 { return .lowConfidence }
        return .unusable
    }

    private static func coverageEstimate(
        report: PlatformSubtitleQualityGate.SubtitleSourceQualityReport
    ) -> Double {
        guard report.cueCount > 0 else { return 0 }
        let cueScore = min(1.0, Double(report.cueCount) / 80.0)
        let textScore = min(1.0, Double(report.visibleScalarCount) / 1800.0)
        return (cueScore * 0.45) + (textScore * 0.55)
    }

    private struct LoadedCues {
        let raw: [SubtitleCue]
        let cleaned: [SubtitleCue]
    }

    private static func loadCues(from url: URL) -> LoadedCues {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            return LoadedCues(raw: [], cleaned: [])
        }
        let isVTT = url.pathExtension.lowercased() == "vtt"
        let parsed = isVTT ? parseVTT(raw) : parseSRT(raw)
        return LoadedCues(raw: parsed, cleaned: cleanCues(parsed))
    }

    private static func diagnosticReport(
        cleaned: PlatformSubtitleQualityGate.SubtitleSourceQualityReport,
        raw: PlatformSubtitleQualityGate.SubtitleSourceQualityReport
    ) -> PlatformSubtitleQualityGate.SubtitleSourceQualityReport {
        PlatformSubtitleQualityGate.SubtitleSourceQualityReport(
            cueCount: max(cleaned.cueCount, raw.cueCount),
            visibleScalarCount: cleaned.visibleScalarCount,
            cjkLanguage: cleaned.cjkLanguage || raw.cjkLanguage,
            cjkScalarRatio: cleaned.cjkScalarRatio,
            latinScalarRatio: cleaned.latinScalarRatio,
            adjacentIdenticalRatio: cleaned.adjacentIdenticalRatio,
            badScalarRatio: cleaned.badScalarRatio,
            uniqueCueTextRatio: cleaned.uniqueCueTextRatio,
            romanizedLoopTokenCount: cleaned.romanizedLoopTokenCount,
            romanizedLoopMaxRun: cleaned.romanizedLoopMaxRun,
            romanizedLoopTokenRatio: cleaned.romanizedLoopTokenRatio,
            soundEffectCueCount: max(cleaned.soundEffectCueCount, raw.soundEffectCueCount),
            soundEffectCueRatio: max(cleaned.soundEffectCueRatio, raw.soundEffectCueRatio),
            soundEffectDurationRatio: max(cleaned.soundEffectDurationRatio, raw.soundEffectDurationRatio),
            longCueCount: max(cleaned.longCueCount, raw.longCueCount),
            longCueRatio: max(cleaned.longCueRatio, raw.longCueRatio),
            maxCueDuration: max(cleaned.maxCueDuration, raw.maxCueDuration)
        )
    }

    private static func soundEffectDominated(
        _ report: PlatformSubtitleQualityGate.SubtitleSourceQualityReport
    ) -> Bool {
        if report.soundEffectCueCount >= PlatformSubtitleQualityGate.soundEffectCueMinCount,
           report.soundEffectCueRatio >= PlatformSubtitleQualityGate.soundEffectCueRatioThreshold {
            return true
        }
        if report.soundEffectCueCount >= PlatformSubtitleQualityGate.soundEffectDurationMinCount,
           report.soundEffectDurationRatio >= PlatformSubtitleQualityGate.soundEffectDurationRatioThreshold {
            return true
        }
        return false
    }

    private static func contentReasons(_ cues: [SubtitleCue]) -> [String] {
        var reasons: [String] = []
        let texts = cues.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        let joined = texts.joined(separator: "\n")
        let hallucinationLikePhrases = [
            "世界の銀行が崩れた",
            "冥府より現れしいお酒",
            "偉いドクネストレード",
            "ドクネストレード"
        ]
        if hallucinationLikePhrases.contains(where: { joined.contains($0) }) {
            reasons.append("hallucinationLikePhrase")
        }

        let cjkShortCueCount = texts.filter { text in
            let visibleCount = text.unicodeScalars.filter { !$0.properties.isWhitespace }.count
            return visibleCount > 0
                && visibleCount <= 6
                && text.unicodeScalars.contains(where: isCJKScalar)
        }.count
        let knownFragmentLikePhrases = ["チョコナナナ", "くじ引き野郎", "ソスせんべい", "あいい行く"]
        let hasKnownFragments = knownFragmentLikePhrases.contains { joined.contains($0) }
        if !texts.isEmpty,
           Double(cjkShortCueCount) / Double(texts.count) >= 0.35 || hasKnownFragments {
            reasons.append("shortCueFragmentation")
        }
        return reasons
    }

    private static func normalizedLanguage(_ code: String) -> String {
        SubtitleLanguageChoice.normalizedLanguageCode(code)
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
}
