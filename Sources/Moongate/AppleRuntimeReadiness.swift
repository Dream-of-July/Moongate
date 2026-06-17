import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif
#if canImport(Translation)
import Translation
#endif
#if canImport(MoongateCore)
import MoongateCore
#endif

struct AppleRuntimeReadinessEvaluator: TranslationRuntimeReadinessEvaluating {
    func readiness(for request: TranslationRuntimeReadinessRequest) async -> TranslationReadiness {
        switch request.engine {
        case .anthropicCompatible, .openAICompatible:
            return request.fallbackReadiness
        case .appleTranslationLowLatency, .appleTranslationHighFidelity:
            return await appleTranslationReadiness(for: request)
        case .appleFoundationOnDevice:
            return foundationModelsReadiness(for: request)
        case .appleFoundationPCC:
            return TranslationReadiness(issues: [
                TranslationReadinessIssue(
                    kind: .pccUnavailable,
                    message: CoreL10n.t(L.Core.readinessPCCUnavailable)
                )
            ])
        case .appleFoundationCloudPro:
            return TranslationReadiness(issues: [
                TranslationReadinessIssue(
                    kind: .pccUnavailable,
                    message: CoreL10n.t(L.Core.readinessCloudProUnavailable)
                )
            ])
        }
    }

    private func appleTranslationReadiness(
        for request: TranslationRuntimeReadinessRequest
    ) async -> TranslationReadiness {
        #if canImport(Translation)
        guard #available(macOS 26.0, iOS 26.0, *) else {
            return TranslationReadiness(issues: [
                TranslationReadinessIssue(
                    kind: .needsRuntimeVerification,
                    message: CoreL10n.t(L.Core.appleTranslationUnsupportedOS)
                )
            ])
        }
        if request.engine == .appleTranslationHighFidelity {
            guard #available(macOS 26.4, iOS 26.4, *) else {
                return TranslationReadiness(issues: [
                    TranslationReadinessIssue(
                        kind: .needsRuntimeVerification,
                        message: CoreL10n.t(L.Core.appleTranslationHighFidelityUnsupportedOS)
                    )
                ])
            }
        }
        guard let source = request.context.sourceLanguage.flatMap(language(from:)) else {
            return TranslationReadiness(issues: [
                TranslationReadinessIssue(
                    kind: .needsRuntimeVerification,
                    message: CoreL10n.t(L.Core.appleTranslationNeedsSourceLanguage)
                )
            ])
        }
        guard let target = language(from: request.context.targetLanguage) else {
            return TranslationReadiness(issues: [
                TranslationReadinessIssue(kind: .unsupportedLanguagePair)
            ])
        }
        let availability = LanguageAvailability()
        let status = await availability.status(from: source, to: target)

        switch status {
        case .installed:
            return .ready
        case .supported:
            return TranslationReadiness(issues: [
                TranslationReadinessIssue(
                    kind: .needsLanguageDownload,
                    message: CoreL10n.t(L.Core.appleTranslationNeedsLanguageDownload)
                )
            ])
        case .unsupported:
            return TranslationReadiness(issues: [
                CoreL10n.issue(.unsupportedLanguagePair)
            ])
        @unknown default:
            return request.fallbackReadiness
        }
        #else
        return TranslationReadiness(issues: [
            TranslationReadinessIssue(
                kind: .needsRuntimeVerification,
                message: CoreL10n.t(L.Core.appleTranslationFrameworkMissing)
            )
        ])
        #endif
    }

    private func foundationModelsReadiness(
        for request: TranslationRuntimeReadinessRequest
    ) -> TranslationReadiness {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, iOS 26.0, *) else {
            return TranslationReadiness(issues: [
                TranslationReadinessIssue(
                    kind: .appleIntelligenceUnavailable,
                    message: CoreL10n.t(L.Core.readinessAppleIntelligenceUnavailable)
                )
            ])
        }
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            let locale = Locale(identifier: request.context.targetLanguage)
            guard model.supportsLocale(locale) else {
                return TranslationReadiness(issues: [
                    TranslationReadinessIssue(kind: .unsupportedLanguagePair)
                ])
            }
            return .ready
        case .unavailable(.deviceNotEligible):
            return TranslationReadiness(issues: [
                TranslationReadinessIssue(
                    kind: .appleIntelligenceUnavailable,
                    message: CoreL10n.t(L.Core.readinessAppleIntelligenceUnavailable)
                )
            ])
        case .unavailable(.appleIntelligenceNotEnabled):
            return TranslationReadiness(issues: [
                TranslationReadinessIssue(
                    kind: .appleIntelligenceUnavailable,
                    message: CoreL10n.t(L.Core.readinessAppleIntelligenceUnavailable)
                )
            ])
        case .unavailable(.modelNotReady):
            return TranslationReadiness(issues: [
                TranslationReadinessIssue(
                    kind: .modelUnavailable,
                    message: CoreL10n.t(L.Core.readinessModelUnavailable)
                )
            ])
        @unknown default:
            return request.fallbackReadiness
        }
        #else
        return TranslationReadiness(issues: [
            TranslationReadinessIssue(
                kind: .appleIntelligenceUnavailable,
                message: CoreL10n.t(L.Core.readinessAppleIntelligenceUnavailable)
            )
        ])
        #endif
    }

    private func language(from identifier: String) -> Locale.Language? {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Locale.Language(identifier: trimmed)
    }
}
