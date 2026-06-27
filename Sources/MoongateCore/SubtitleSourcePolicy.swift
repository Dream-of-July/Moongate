import Foundation

public enum SubtitleIntent: String, Codable, CaseIterable, Sendable {
    case none
    case sourceSRT
    case translatedSRT
    case burnTranslated
    case burnSource

    public var needsSubtitleSource: Bool { self != .none }
    public var requiresTranslation: Bool {
        self == .translatedSRT || self == .burnTranslated
    }
    public var requiresBurnIn: Bool {
        self == .burnTranslated || self == .burnSource
    }
}

public enum SourceLanguageIntent: Equatable, Codable, Sendable {
    case automatic
    case language(String)
}

public enum SubtitleSourcePolicy: String, Codable, CaseIterable, Sendable {
    case autoBest
    case preferPlatform
    case forcePlatform
    case preferLocalASR
    case forceLocalASR
    case compareLocalASR
    case cloudASR
    case importedFile
}

public enum SubtitleQualityVerdict: String, Codable, Sendable, Comparable {
    case unusable
    case lowConfidence
    case usable
    case good
    case excellent

    public static func < (lhs: Self, rhs: Self) -> Bool {
        rank(lhs) < rank(rhs)
    }

    private static func rank(_ verdict: Self) -> Int {
        switch verdict {
        case .unusable: return 0
        case .lowConfidence: return 1
        case .usable: return 2
        case .good: return 3
        case .excellent: return 4
        }
    }
}

public struct SubtitleSourceCandidate: Identifiable, Equatable, Sendable {
    public let id: String
    public let kind: SubtitleSourceKind
    public let languageCode: String
    public let displayName: String
    public let fileURL: URL?
    public let isGenerated: Bool
    public let provider: String?

    public init(
        id: String,
        kind: SubtitleSourceKind,
        languageCode: String,
        displayName: String,
        fileURL: URL?,
        isGenerated: Bool,
        provider: String?
    ) {
        self.id = id
        self.kind = kind
        self.languageCode = languageCode
        self.displayName = displayName
        self.fileURL = fileURL
        self.isGenerated = isGenerated
        self.provider = provider
    }
}

public struct SubtitleSourceScore: Equatable, Sendable {
    public let candidateID: String
    public let kind: SubtitleSourceKind
    public let languageCode: String
    public let score: Double
    public let verdict: SubtitleQualityVerdict
    public let reasons: [String]
    public let report: PlatformSubtitleQualityGate.SubtitleSourceQualityReport?

    public init(
        candidateID: String,
        kind: SubtitleSourceKind,
        languageCode: String,
        score: Double,
        verdict: SubtitleQualityVerdict,
        reasons: [String],
        report: PlatformSubtitleQualityGate.SubtitleSourceQualityReport?
    ) {
        self.candidateID = candidateID
        self.kind = kind
        self.languageCode = languageCode
        self.score = score
        self.verdict = verdict
        self.reasons = reasons
        self.report = report
    }
}

public struct SubtitleResolutionRequest: Sendable {
    public let languageIntent: SourceLanguageIntent
    public let sourcePolicy: SubtitleSourcePolicy
    public let candidates: [SubtitleSourceCandidate]
    public let videoDurationSeconds: Double?

    public init(
        languageIntent: SourceLanguageIntent,
        sourcePolicy: SubtitleSourcePolicy,
        candidates: [SubtitleSourceCandidate],
        videoDurationSeconds: Double?
    ) {
        self.languageIntent = languageIntent
        self.sourcePolicy = sourcePolicy
        self.candidates = candidates
        self.videoDurationSeconds = videoDurationSeconds
    }
}
