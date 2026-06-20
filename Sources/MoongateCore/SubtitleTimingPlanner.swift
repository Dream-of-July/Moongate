import Foundation

/// Shared subtitle timing heuristics used by cleaning, evaluation fixtures, and parity tests.
enum SubtitleTimingPlanner {
    static let normalReadableCueSeconds = 9.0
    static let emergencyReadableCueSeconds = 12.0
    static let sentenceHandoffGapSeconds = 0.08
    static let handoffBoundaryBorrowSeconds = 0.14
    static let sentenceHandoffForwardSeconds = 0.25
    static let shortSourceFragmentWindowSeconds = 2.4
    static let vttUntimedLongCueSeconds = 3.5
    static let vttUntimedMaxSecondsPerToken = 1.3

    private static let continuationStarts: Set<String> = [
        "if", "that", "which", "who", "whom", "whose", "when", "where", "why", "how",
        "and", "or", "but", "because", "so", "then", "than", "to", "of", "for", "with",
        "as", "in", "on", "at", "by", "from", "do", "does", "did", "is", "are", "was",
        "were", "be", "been", "being", "have", "has", "had", "can", "could", "would",
        "will", "should", "may", "might", "must", "not",
        "a", "al", "del", "de", "el", "la", "los", "las", "un", "una", "unos", "unas",
        "y", "o", "que", "quien", "como", "con", "para", "por", "se", "me", "te", "lo", "le", "les", "no", "veces",
        "tambien", "también",
        "du", "des", "le", "une", "et", "ou", "qui", "dont", "pour", "avec", "dans", "sur", "en", "au", "aux",
        "aussi", "également",
        "di", "della", "dei", "degli", "delle", "il", "gli", "e", "che", "per", "su", "alla", "alle", "ai", "anche",
        "also", "too"
    ]

    private static let continuationEnds: Set<String> = [
        "the", "a", "an", "and", "or", "but", "if", "that", "which", "who", "what",
        "when", "where", "why", "how", "to", "of", "for", "with", "from", "as",
        "is", "are", "was", "were", "be", "been", "being", "do", "does", "did",
        "have", "has", "had", "can", "could", "would", "will", "should", "may",
        "might", "must", "we", "you", "i", "they", "he", "she", "it",
        "al", "del", "de", "el", "la", "los", "las", "un", "una", "unos", "unas",
        "y", "o", "que", "quien", "como", "con", "para", "por", "se", "me", "te", "lo", "le", "les", "no",
        "du", "des", "le", "une", "et", "ou", "qui", "dont", "pour", "avec", "dans", "sur", "en", "au", "aux",
        "di", "della", "dei", "degli", "delle", "il", "gli", "e", "che", "per", "su", "alla", "alle", "ai"
    ]

    static func wordTokens(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    static func speechTokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar), !isCJKSpeechScalar(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    static func timingTokens(_ text: String) -> [String] {
        if containsCJKText(text) {
            return text.filter { !$0.isWhitespace }.map { String($0) }
        }

        var tokens: [String] = []
        var current = ""
        func flushCurrent() {
            if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }

        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar), !isCJKSpeechScalar(scalar) {
                current.unicodeScalars.append(scalar)
            } else {
                flushCurrent()
                if isTimingCurrencyScalar(scalar) {
                    tokens.append(String(scalar))
                }
            }
        }
        flushCurrent()
        return tokens
    }

    static func visibleCharacters(_ text: String) -> Int {
        text.filter { !$0.isWhitespace }.count
    }

    static func containsCJKText(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: isCJKSpeechScalar)
    }

    static func containsHangulText(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            scalar.value >= 0xAC00 && scalar.value <= 0xD7AF
        }
    }

    static func shouldAlignToSpeechWindow(
        text: String,
        originalDuration: Double,
        speechAlignTimings: Bool,
        canUseSourceAnchors: Bool,
        endsSentence: Bool
    ) -> Bool {
        guard !canUseSourceAnchors else { return false }
        let containsCJK = containsCJKText(text)
        let speechTokenCount = speechTokens(text).count
        if speechTokenCount > 0, !containsCJK {
            if speechTokenCount <= 3 { return true }
            if speechTokenCount == 4,
               !endsSentence,
               hasTrailingSoftPause(text),
               originalDuration > speechAlignedVisibleSeconds(text, endsSentence: endsSentence) + 0.1 {
                return true
            }
            return speechAlignTimings && originalDuration > normalReadableCueSeconds
        }

        let visibleCount = visibleCharacters(text)
        guard containsCJK, visibleCount > 0, visibleCount <= 12 else {
            return false
        }
        guard speechAlignTimings || originalDuration > normalReadableCueSeconds else {
            return false
        }
        return originalDuration > speechAlignedVisibleSeconds(text, endsSentence: endsSentence) + 0.5
    }

    static func characterSplitPartCount(text: String, requestedParts: Int) -> Int {
        let visibleCount = visibleCharacters(text)
        guard visibleCount > 0 else { return 1 }
        let minVisibleCharacters = containsCJKText(text) ? 4 : 1
        let maxReadableParts = max(1, visibleCount / minVisibleCharacters)
        return min(max(1, requestedParts), maxReadableParts)
    }

    static func speechAlignedVisibleSeconds(_ text: String, endsSentence: Bool) -> Double {
        let tokens = speechTokens(text)
        if tokens.isEmpty {
            return clamp(Double(visibleCharacters(text)) * 0.18 + 0.8, min: 1.5, max: 6.0)
        }

        if tokens.count >= 2, tokens.allSatisfy({ $0.allSatisfy(\.isNumber) }) {
            return clamp(Double(tokens.count) * 0.65 + 0.5, min: 2.0, max: 8.0)
        }

        if tokens.count <= 3 {
            if shouldExtendShortCue(text, tokenCount: tokens.count, endsSentence: endsSentence) {
                return 2.45
            }
            return 2.0
        }
        if tokens.count == 4, !endsSentence {
            return 1.92
        }

        let sentencePause = endsSentence ? 0.8 : 0.45
        return clamp(Double(tokens.count) * 0.42 + sentencePause, min: 2.2, max: normalReadableCueSeconds)
    }

    static func isWeakBoundary(leftToken: String, rightToken: String) -> Bool {
        let left = normalizedBoundaryWord(leftToken)
        let right = normalizedBoundaryWord(rightToken)
        guard !left.isEmpty, !right.isEmpty else { return false }
        return continuationEnds.contains(left) || continuationStarts.contains(right)
    }

    static func shouldBorrowBoundaryForHandoff(previousText: String, nextText: String) -> Bool {
        guard !nextText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard let last = lastMeaningfulCharacter(previousText) else { return false }
        return last == ":" || last == "：" || last == ";" || last == "；"
    }

    private static func clamp(_ value: Double, min minValue: Double, max maxValue: Double) -> Double {
        Swift.min(Swift.max(value, minValue), maxValue)
    }

    private static func isCJKSpeechScalar(_ scalar: UnicodeScalar) -> Bool {
        (scalar.value >= 0x3400 && scalar.value <= 0x4DBF)
            || (scalar.value >= 0x4E00 && scalar.value <= 0x9FFF)
            || (scalar.value >= 0x3040 && scalar.value <= 0x30FF)
            || (scalar.value >= 0xAC00 && scalar.value <= 0xD7AF)
    }

    private static func isTimingCurrencyScalar(_ scalar: UnicodeScalar) -> Bool {
        scalar == "€" || scalar == "$" || scalar == "£" || scalar == "¥" || scalar == "₩"
    }

    private static func shouldExtendShortCue(_ text: String, tokenCount: Int, endsSentence: Bool) -> Bool {
        guard endsSentence else { return false }
        if hasEmphaticTerminalPunctuation(text) { return true }
        return tokenCount >= 2 && visibleCharacters(text) >= 10
    }

    private static func hasEmphaticTerminalPunctuation(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains("!!")
            || trimmed.contains("??")
            || trimmed.contains("!?")
            || trimmed.contains("?!")
    }

    private static func lastMeaningfulCharacter(_ text: String) -> Character? {
        let trailingAllowed: Set<Character> = ["\"", "'", "”", "’", ")", "）", "」", "』", "]"]
        return text.trimmingCharacters(in: .whitespacesAndNewlines).reversed().first { char in
            !trailingAllowed.contains(char) && char != " "
        }
    }

    private static func hasTrailingSoftPause(_ text: String) -> Bool {
        guard let last = lastMeaningfulCharacter(text) else { return false }
        return last == "," || last == "，" || last == ";" || last == "；" || last == ":" || last == "："
    }

    private static func normalizedBoundaryWord(_ raw: String) -> String {
        String(raw.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
}
