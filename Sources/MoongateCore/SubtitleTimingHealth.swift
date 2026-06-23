import Foundation

/// Post-hoc quality signal for a produced subtitle's timing. Used to gently suggest re-running
/// with local Whisper when a platform (e.g. YouTube rolling auto-caption) source yields many
/// near-zero-duration "flash" cues — lines that appear for ~10ms and read as "not recognized".
///
/// This is deliberately a soft, after-the-fact hint (never a forced upfront choice): the queue
/// surfaces it next to the existing "re-run with local ASR" action on a completed item.
public enum SubtitleTimingHealth {
    /// Cues shorter than this are treated as unreadable flashes. Set below the whisper planner's
    /// 0.30s minimum cue so genuine local-ASR output never counts as a flash.
    public static let flashThresholdSeconds = 0.25
    /// Fraction of flash cues above which the subtitle timing is considered unreliable.
    public static let flashRatioThreshold = 0.20
    /// Don't judge tiny clips (too few cues to be meaningful).
    public static let minimumCueCount = 8

    public struct Assessment: Equatable, Sendable {
        public let cueCount: Int
        public let flashCueCount: Int

        public init(cueCount: Int, flashCueCount: Int) {
            self.cueCount = cueCount
            self.flashCueCount = flashCueCount
        }

        public var flashRatio: Double {
            cueCount > 0 ? Double(flashCueCount) / Double(cueCount) : 0
        }

        /// True when the timing looks unreliable enough to suggest a local-Whisper re-run.
        public var looksUnreliable: Bool {
            cueCount >= SubtitleTimingHealth.minimumCueCount && flashRatio >= SubtitleTimingHealth.flashRatioThreshold
        }
    }

    /// Assess the cleaned cues that a subtitle file would actually produce (parse → clean), so the
    /// signal reflects what the viewer sees rather than the raw rolling-caption blocks.
    public static func assess(subtitleFileURL url: URL) -> Assessment {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            return Assessment(cueCount: 0, flashCueCount: 0)
        }
        return assess(rawSubtitle: raw, isVTT: url.pathExtension.lowercased() == "vtt")
    }

    public static func assess(rawSubtitle raw: String, isVTT: Bool) -> Assessment {
        let parsed = isVTT ? parseVTT(raw) : parseSRT(raw)
        let cleaned = cleanCues(parsed)
        var flash = 0
        for cue in cleaned {
            guard let start = srtTimeToSeconds(cue.start), let end = srtTimeToSeconds(cue.end) else { continue }
            if end - start < flashThresholdSeconds { flash += 1 }
        }
        return Assessment(cueCount: cleaned.count, flashCueCount: flash)
    }
}
