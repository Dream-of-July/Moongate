import Foundation

public enum SubtitleSourceResolver {
    public static func resolve(_ request: SubtitleResolutionRequest) -> ResolvedSubtitleSource? {
        let requestedLanguage = normalizedLanguage(from: request.languageIntent)
        let candidates = filterByLanguage(request.candidates, requestedLanguage: requestedLanguage)
        guard !candidates.isEmpty else { return nil }

        let scored = candidates.map {
            SubtitleQualityScorer.score(
                candidate: $0,
                requestedLanguageCode: requestedLanguage,
                videoDurationSeconds: request.videoDurationSeconds
            )
        }
        guard let winner = scored.max(by: { lhs, rhs in
            let lhsRank = lhs.score + policyBoost(lhs.kind, request.sourcePolicy)
            let rhsRank = rhs.score + policyBoost(rhs.kind, request.sourcePolicy)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return sourceKindRank(lhs.kind) > sourceKindRank(rhs.kind)
        }),
              let selected = candidates.first(where: { $0.id == winner.candidateID }) else {
            return nil
        }

        return ResolvedSubtitleSource(
            languageCode: selected.languageCode,
            selectedFile: selected.fileURL ?? URL(fileURLWithPath: ""),
            selectedKind: selected.kind,
            qualityVerdict: PlatformSubtitleQualityGate.Verdict(
                usable: winner.verdict >= .usable,
                reasons: [],
                report: winner.report ?? .empty
            ),
            sourceQualityVerdict: winner.verdict,
            usedLocalASRFallback: selected.kind == .localASR
                && candidates.contains { $0.kind != .localASR },
            fallbackReasons: [],
            candidateReports: scored.map { score in
                SubtitleSourceCandidateReport(
                    sourceKind: score.kind,
                    languageCode: score.languageCode,
                    available: candidates.contains { $0.id == score.candidateID && $0.fileURL != nil },
                    selected: score.candidateID == winner.candidateID,
                    usable: score.verdict >= .usable,
                    qualityVerdict: score.verdict,
                    reasons: score.reasons
                )
            }
        )
    }

    private static func policyBoost(_ kind: SubtitleSourceKind, _ policy: SubtitleSourcePolicy) -> Double {
        switch policy {
        case .autoBest:
            return 0
        case .preferPlatform:
            return isPlatform(kind) ? 12 : 0
        case .forcePlatform:
            return isPlatform(kind) ? 10_000 : -10_000
        case .preferLocalASR:
            return kind == .localASR ? 12 : 0
        case .forceLocalASR:
            return kind == .localASR ? 10_000 : -10_000
        case .compareLocalASR:
            return 0
        case .cloudASR:
            return kind == .cloudASR ? 10_000 : -10_000
        case .importedFile:
            return kind == .importedFile ? 10_000 : -10_000
        }
    }

    private static func isPlatform(_ kind: SubtitleSourceKind) -> Bool {
        kind == .manual || kind == .platformAuto || kind == .hlsManifest
    }

    private static func sourceKindRank(_ kind: SubtitleSourceKind) -> Int {
        switch kind {
        case .manual: return 0
        case .importedFile: return 1
        case .hlsManifest: return 2
        case .platformAuto: return 3
        case .cloudASR: return 4
        case .localASR: return 5
        }
    }

    private static func normalizedLanguage(from intent: SourceLanguageIntent) -> String? {
        switch intent {
        case .automatic:
            return nil
        case .language(let code):
            let normalized = SubtitleLanguageChoice.normalizedLanguageCode(code)
            return normalized.isEmpty ? nil : normalized
        }
    }

    private static func filterByLanguage(
        _ candidates: [SubtitleSourceCandidate],
        requestedLanguage: String?
    ) -> [SubtitleSourceCandidate] {
        guard let requestedLanguage else { return candidates }
        let exact = candidates.filter {
            SubtitleLanguageChoice.normalizedLanguageCode($0.languageCode) == requestedLanguage
        }
        return exact.isEmpty ? candidates : exact
    }
}
