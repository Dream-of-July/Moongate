import Foundation

/// Deterministic, no-regex script detection over titles and short text samples. Shared by the
/// language recommender; the Unicode ranges mirror `looksJapanese` in ASR.swift on purpose so the
/// ready-page recommendation and the ASR profile detector agree on what "looks Japanese/Korean".
public enum ScriptDetector {
    public struct Profile: Equatable, Sendable {
        public let kanaRatio: Double      // hiragana + katakana
        public let hangulRatio: Double
        public let cjkRatio: Double        // CJK unified ideographs (Han)
        public let latinRatio: Double
        public let visibleCount: Int
    }

    /// Counts script ratios over visible (non-whitespace) scalars in `text`.
    public static func profile(of text: String) -> Profile {
        var kana = 0
        var hangul = 0
        var cjk = 0
        var latin = 0
        var visible = 0
        for scalar in text.unicodeScalars where !scalar.properties.isWhitespace {
            visible += 1
            let v = scalar.value
            if (0x3040...0x30FF).contains(v) {
                kana += 1
            } else if (0xAC00...0xD7A3).contains(v) || (0x1100...0x11FF).contains(v) {
                hangul += 1
            } else if (0x4E00...0x9FFF).contains(v) {
                cjk += 1
            } else if (0x0041...0x005A).contains(v) || (0x0061...0x007A).contains(v) {
                latin += 1
            }
        }
        guard visible > 0 else {
            return Profile(kanaRatio: 0, hangulRatio: 0, cjkRatio: 0, latinRatio: 0, visibleCount: 0)
        }
        let d = Double(visible)
        return Profile(
            kanaRatio: Double(kana) / d,
            hangulRatio: Double(hangul) / d,
            cjkRatio: Double(cjk) / d,
            latinRatio: Double(latin) / d,
            visibleCount: visible
        )
    }
}

/// Language-first recommendation for the ready page. Runs BEFORE download, so it only sees the
/// video title and the available subtitle tracks (language code + manual/auto markers). It never
/// reads cue text, never goes online, never calls an LLM, and never hardcodes a language: the
/// recommendation falls out of deterministic scoring so it follows the actual video content.
public enum SubtitleLanguageRecommender {
    public struct Result: Equatable, Sendable {
        /// The single language shown by default. nil when there are no usable tracks.
        public let recommended: SubtitleLanguageChoice?
        /// Remaining languages for the disclosure area, ordered by descending score then code.
        public let others: [SubtitleLanguageChoice]

        public init(recommended: SubtitleLanguageChoice?, others: [SubtitleLanguageChoice]) {
            self.recommended = recommended
            self.others = others
        }
    }

    // Scoring constants. Single source of truth lives in the cross-platform fixture
    // (`languageRecommender` section); the Swift and C# copies are each asserted equal to it.
    public static let manualTrackScore = 100
    public static let autoTrackScore = 40
    public static let localASROnlyScore = 10
    public static let japaneseScriptBonus = 80
    public static let koreanScriptBonus = 80
    public static let latinScriptBonus = 30
    /// Weak signal: CJK ideographs (kanji) present but no kana/hangul. Romanized Japanese/Korean
    /// titles (e.g. "YOASOBI - 群青 (Gunjou)") are Latin-dominant with only a few ideographs, so a
    /// full script bonus can't fire — this lifts East-Asian-script languages over Latin ones.
    public static let cjkPresenceBonus = 20
    /// Stronger Han-script signal when a CJK language has a platform auto track. Local-ASR choices
    /// are synthetic per-language candidates in the UI, so they are not source-language evidence.
    public static let platformAutoCJKPresenceBonus = 90
    public static let titleLanguageHintBonus = 15
    public static let titleScriptDominanceRatio = 0.18

    /// Aggregates flat choices into language groups (delegates to the model-layer grouping).
    public static func aggregate(_ choices: [SubtitleChoice]) -> [SubtitleLanguageChoice] {
        SubtitleLanguageChoice.aggregate(choices)
    }

    /// Picks a recommended language from the title + available language groups.
    public static func recommend(title: String, languages: [SubtitleLanguageChoice]) -> Result {
        guard !languages.isEmpty else { return Result(recommended: nil, others: []) }
        let titleProfile = ScriptDetector.profile(of: title)
        let lowerTitle = title.lowercased()

        // Score each language; keep original index for a stable, documented tie-break.
        let scored = languages.enumerated().map { index, language -> (language: SubtitleLanguageChoice, score: Int, index: Int) in
            (language, score(for: language, titleProfile: titleProfile, lowerTitle: lowerTitle), index)
        }
        // Highest score wins. Tie-break: manual track first, then language code ascending.
        let ranked = scored.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.language.hasManualTrack != rhs.language.hasManualTrack {
                return lhs.language.hasManualTrack
            }
            return lhs.language.languageCode < rhs.language.languageCode
        }
        let recommended = ranked.first?.language
        let others = ranked.dropFirst().map(\.language)
        return Result(recommended: recommended, others: Array(others))
    }

    static func score(for language: SubtitleLanguageChoice, titleProfile: ScriptDetector.Profile, lowerTitle: String) -> Int {
        var total = 0
        // 1) Track availability base score (manual preferred over auto over localASR-only).
        if language.hasManualTrack {
            total += manualTrackScore
        } else if language.hasAutoTrack {
            total += autoTrackScore
        } else {
            total += localASROnlyScore
        }

        // 2) Title script alignment.
        let code = language.languageCode
        let titleHasKana = titleProfile.kanaRatio >= titleScriptDominanceRatio
        let titleHasHangul = titleProfile.hangulRatio >= titleScriptDominanceRatio
        let titleIsLatinDominant = titleProfile.latinRatio >= titleScriptDominanceRatio
            && titleProfile.kanaRatio == 0 && titleProfile.hangulRatio == 0 && titleProfile.cjkRatio == 0
        if isJapaneseCode(code), titleHasKana {
            total += japaneseScriptBonus
        }
        if isKoreanCode(code), titleHasHangul {
            total += koreanScriptBonus
        }
        if isLatinScriptLanguage(code), titleIsLatinDominant {
            total += latinScriptBonus
        }
        // Weak East-Asian signal: any ideographs present, no kana/hangul. Helps romanized CJK titles.
        let titleHasIdeographsOnly = titleProfile.cjkRatio > 0
            && titleProfile.kanaRatio == 0 && titleProfile.hangulRatio == 0
        if titleHasIdeographsOnly, isJapaneseCode(code) || isKoreanCode(code) || code == "zh" || code == "yue" {
            total += language.hasAutoTrack
                ? platformAutoCJKPresenceBonus
                : cjkPresenceBonus
        }

        // 3) Explicit title language hints (substring, no regex).
        if isJapaneseCode(code),
           lowerTitle.contains("日本語") || lowerTitle.contains("日语") || lowerTitle.contains("日語") {
            total += titleLanguageHintBonus
        }
        if isKoreanCode(code), lowerTitle.contains("한국어") || lowerTitle.contains("韓国語") || lowerTitle.contains("韩语") {
            total += titleLanguageHintBonus
        }
        return total
    }

    static func isJapaneseCode(_ code: String) -> Bool {
        code == "ja" || code == "jpn"
    }

    static func isKoreanCode(_ code: String) -> Bool {
        code == "ko" || code == "kor"
    }

    /// Latin-script European languages we recommend on a Latin-dominant title.
    static func isLatinScriptLanguage(_ code: String) -> Bool {
        latinScriptLanguageCodes.contains(code)
    }

    static let latinScriptLanguageCodes: Set<String> = [
        "en", "es", "fr", "it", "de", "pt", "nl", "sv", "no", "da", "fi", "pl", "id", "vi", "tr", "ro", "cs"
    ]
}
