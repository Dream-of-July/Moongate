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
                    message: "Private Cloud Compute 暂未提供可用于本 App 的公开运行时接口。"
                )
            ])
        case .appleFoundationCloudPro:
            return TranslationReadiness(issues: [
                TranslationReadinessIssue(
                    kind: .pccUnavailable,
                    message: "Apple Intelligence Cloud Pro（云端 Pro）暂未提供可用于本 App 的公开运行时接口。"
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
                    message: "Apple Translation 执行需要 macOS 26 或 iOS 26 及以上。"
                )
            ])
        }
        if request.engine == .appleTranslationHighFidelity {
            guard #available(macOS 26.4, iOS 26.4, *) else {
                return TranslationReadiness(issues: [
                    TranslationReadinessIssue(
                        kind: .needsRuntimeVerification,
                        message: "Apple Translation 高保真模式需要 macOS 26.4 或 iOS 26.4 及以上。"
                    )
                ])
            }
        }
        guard let source = request.context.sourceLanguage.flatMap(language(from:)) else {
            return TranslationReadiness(issues: [
                TranslationReadinessIssue(
                    kind: .needsRuntimeVerification,
                    message: "Apple Translation 需要明确源语言后才能运行。"
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
                    message: "系统支持中文字幕翻译，但需要先下载对应语言。"
                )
            ])
        case .unsupported:
            return TranslationReadiness(issues: [
                TranslationReadinessIssue(kind: .unsupportedLanguagePair)
            ])
        @unknown default:
            return request.fallbackReadiness
        }
        #else
        return TranslationReadiness(issues: [
            TranslationReadinessIssue(
                kind: .needsRuntimeVerification,
                message: "当前构建不包含 Translation.framework。"
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
                    message: "当前系统版本不支持本地 Apple Intelligence。"
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
                    message: "这台 Mac 不支持 Apple Intelligence。"
                )
            ])
        case .unavailable(.appleIntelligenceNotEnabled):
            return TranslationReadiness(issues: [
                TranslationReadinessIssue(
                    kind: .appleIntelligenceUnavailable,
                    message: "需要先在系统设置中启用 Apple Intelligence。"
                )
            ])
        case .unavailable(.modelNotReady):
            return TranslationReadiness(issues: [
                TranslationReadinessIssue(
                    kind: .modelUnavailable,
                    message: "Apple Intelligence 本地模型尚未就绪，请在系统设置中完成下载。"
                )
            ])
        @unknown default:
            return request.fallbackReadiness
        }
        #else
        return TranslationReadiness(issues: [
            TranslationReadinessIssue(
                kind: .appleIntelligenceUnavailable,
                message: "当前构建不包含 FoundationModels.framework。"
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
