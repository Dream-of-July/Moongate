import Foundation

public enum TranslationOutputQualityGate {
    public enum Reason: String, Codable, Equatable, Sendable {
        case sourceLanguageLeakage
    }

    public struct Report: Equatable, Sendable {
        public let visibleScalarCount: Int
        public let sourceScriptScalarCount: Int
        public let sourceScriptScalarRatio: Double
        public let affectedLineCount: Int

        public init(
            visibleScalarCount: Int,
            sourceScriptScalarCount: Int,
            sourceScriptScalarRatio: Double,
            affectedLineCount: Int
        ) {
            self.visibleScalarCount = visibleScalarCount
            self.sourceScriptScalarCount = sourceScriptScalarCount
            self.sourceScriptScalarRatio = sourceScriptScalarRatio
            self.affectedLineCount = affectedLineCount
        }
    }

    public struct Verdict: Equatable, Sendable {
        public let usable: Bool
        public let reasons: [Reason]
        public let report: Report

        public init(usable: Bool, reasons: [Reason], report: Report) {
            self.usable = usable
            self.reasons = reasons
            self.report = report
        }
    }

    public static func assess(
        lines: [String],
        sourceLanguageCode: String?,
        targetLanguageCode: String
    ) -> Verdict {
        let target = TranslationLanguage.normalizedScript(targetLanguageCode)
        let source = TranslationLanguage.normalizedScript(sourceLanguageCode ?? "")
        guard target.hasPrefix("zh"), !source.isEmpty, source != target,
              let sourceScript = SourceScript(sourceLanguageCode: source) else {
            return Verdict(usable: true, reasons: [], report: emptyReport)
        }

        var visibleScalarCount = 0
        var sourceScriptScalarCount = 0
        var affectedLineCount = 0

        for line in lines {
            var lineVisible = 0
            var lineSource = 0
            for scalar in line.unicodeScalars where isVisibleScalar(scalar) {
                lineVisible += 1
                if sourceScript.contains(scalar) {
                    lineSource += 1
                }
            }
            guard lineVisible > 0 else { continue }
            visibleScalarCount += lineVisible
            sourceScriptScalarCount += lineSource
            if lineSource >= sourceScript.affectedLineMinimum
                && Double(lineSource) / Double(lineVisible) >= sourceScript.affectedLineRatio {
                affectedLineCount += 1
            }
        }

        let ratio = visibleScalarCount == 0
            ? 0
            : Double(sourceScriptScalarCount) / Double(visibleScalarCount)
        let report = Report(
            visibleScalarCount: visibleScalarCount,
            sourceScriptScalarCount: sourceScriptScalarCount,
            sourceScriptScalarRatio: ratio,
            affectedLineCount: affectedLineCount
        )
        let leaking = (sourceScriptScalarCount >= sourceScript.totalMinimum && ratio >= sourceScript.totalRatio)
            || (affectedLineCount >= 2 && sourceScriptScalarCount >= sourceScript.multiLineMinimum)
        let reasons: [Reason] = leaking ? [.sourceLanguageLeakage] : []
        return Verdict(usable: reasons.isEmpty, reasons: reasons, report: report)
    }

    private static let emptyReport = Report(
        visibleScalarCount: 0,
        sourceScriptScalarCount: 0,
        sourceScriptScalarRatio: 0,
        affectedLineCount: 0
    )

    private static func isVisibleScalar(_ scalar: Unicode.Scalar) -> Bool {
        !CharacterSet.whitespacesAndNewlines.contains(scalar)
            && !CharacterSet.punctuationCharacters.contains(scalar)
            && !CharacterSet.symbols.contains(scalar)
    }

    private enum SourceScript {
        case kana
        case hangul
        case latin

        init?(sourceLanguageCode: String) {
            switch sourceLanguageCode {
            case "ja":
                self = .kana
            case "ko":
                self = .hangul
            case "en", "fr", "de", "es", "it", "pt", "vi", "id":
                self = .latin
            default:
                return nil
            }
        }

        var totalMinimum: Int {
            switch self {
            case .kana, .hangul: return 12
            case .latin: return 24
            }
        }

        var multiLineMinimum: Int {
            switch self {
            case .kana, .hangul: return 6
            case .latin: return 16
            }
        }

        var totalRatio: Double {
            switch self {
            case .kana, .hangul: return 0.12
            case .latin: return 0.40
            }
        }

        var affectedLineMinimum: Int {
            switch self {
            case .kana, .hangul: return 2
            case .latin: return 8
            }
        }

        var affectedLineRatio: Double {
            switch self {
            case .kana, .hangul: return 0.18
            case .latin: return 0.40
            }
        }

        func contains(_ scalar: Unicode.Scalar) -> Bool {
            switch self {
            case .kana:
                return (0x3040...0x30FF).contains(scalar.value)
                    || (0x31F0...0x31FF).contains(scalar.value)
                    || (0xFF66...0xFF9F).contains(scalar.value)
            case .hangul:
                return (0x1100...0x11FF).contains(scalar.value)
                    || (0x3130...0x318F).contains(scalar.value)
                    || (0xAC00...0xD7A3).contains(scalar.value)
            case .latin:
                return (0x0041...0x005A).contains(scalar.value)
                    || (0x0061...0x007A).contains(scalar.value)
                    || (0x00C0...0x024F).contains(scalar.value)
            }
        }
    }
}
