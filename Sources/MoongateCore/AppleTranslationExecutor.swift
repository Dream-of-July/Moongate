import Foundation
import MoongateMobileCore
#if canImport(Translation)
import Translation
#endif

struct AppleTranslationSegment: Sendable, Equatable {
    var number: Int
    var text: String

    init(number: Int, text: String) {
        self.number = number
        self.text = text
    }
}

struct AppleTranslationBatchRequest: Sendable, Equatable {
    var engine: TranslationEngine
    var context: TranslationContext
    var segments: [AppleTranslationSegment]

    init(
        engine: TranslationEngine,
        context: TranslationContext,
        segments: [AppleTranslationSegment]
    ) {
        self.engine = engine
        self.context = context
        self.segments = segments
    }
}

protocol AppleTranslationExecuting: Sendable {
    func translate(_ request: AppleTranslationBatchRequest) async throws -> [Int: String]
}

struct DefaultAppleTranslationExecutor: AppleTranslationExecuting {
    init() {}

    func translate(_ request: AppleTranslationBatchRequest) async throws -> [Int: String] {
        let sourceIdentifier = try Self.requiredSourceLanguage(from: request.context)
        let targetIdentifier = try Self.requiredTargetLanguage(from: request.context)

        #if canImport(Translation)
        guard #available(macOS 26.0, iOS 26.0, *) else {
            throw MoongateError.translateFailed(CoreL10n.t(L.Core.appleTranslationUnsupportedOS))
        }

        if request.engine == .appleTranslationHighFidelity {
            guard #available(macOS 26.4, iOS 26.4, *) else {
                throw MoongateError.translateFailed(CoreL10n.t(L.Core.appleTranslationHighFidelityUnsupportedOS))
            }
        }

        let source = Locale.Language(identifier: sourceIdentifier)
        let target = Locale.Language(identifier: targetIdentifier)
        let availability = LanguageAvailability()
        let status = await availability.status(from: source, to: target)

        switch status {
        case .installed:
            return try await executeInstalledTranslation(
                request,
                source: source,
                target: target
            )
        case .supported:
            throw MoongateError.translateFailed(CoreL10n.t(L.Core.appleTranslationNeedsLanguageDownload))
        case .unsupported:
            throw MoongateError.translateFailed(CoreL10n.t(
                L.Core.appleTranslationUnsupportedPair,
                sourceIdentifier,
                targetIdentifier
            ))
        @unknown default:
            throw MoongateError.translateFailed(CoreL10n.t(L.Core.appleTranslationUnknownPair))
        }
        #else
        throw MoongateError.translateFailed(CoreL10n.t(L.Core.appleTranslationFrameworkMissing))
        #endif
    }

    private static func requiredSourceLanguage(from context: TranslationContext) throws -> String {
        let identifier = context.sourceLanguage?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !identifier.isEmpty else {
            throw MoongateError.translateFailed(CoreL10n.t(L.Core.appleTranslationNeedsSourceLanguage))
        }
        return identifier
    }

    private static func requiredTargetLanguage(from context: TranslationContext) throws -> String {
        let identifier = context.targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty else {
            throw MoongateError.translateFailed(CoreL10n.t(L.Core.appleTranslationEmptyTarget))
        }
        return identifier
    }
}

#if canImport(Translation)
@available(macOS 26.0, iOS 26.0, *)
private func executeInstalledTranslation(
    _ request: AppleTranslationBatchRequest,
    source: Locale.Language,
    target: Locale.Language
) async throws -> [Int: String] {
    guard !request.segments.isEmpty else { return [:] }

    let session: TranslationSession
    switch request.engine {
    case .appleTranslationHighFidelity:
        guard #available(macOS 26.4, iOS 26.4, *) else {
            throw MoongateError.translateFailed(CoreL10n.t(L.Core.appleTranslationHighFidelityUnsupportedOS))
        }
        session = TranslationSession(
            installedSource: source,
            target: target,
            preferredStrategy: .highFidelity
        )
    case .appleTranslationLowLatency:
        if #available(macOS 26.4, iOS 26.4, *) {
            session = TranslationSession(
                installedSource: source,
                target: target,
                preferredStrategy: .lowLatency
            )
        } else {
            session = TranslationSession(installedSource: source, target: target)
        }
    case .anthropicCompatible,
         .openAICompatible,
         .appleFoundationOnDevice,
         .appleFoundationPCC,
         .appleFoundationCloudPro:
        throw MoongateError.translateFailed(CoreL10n.t(L.Core.appleTranslationUnsupportedAdapter))
    }

    let translationRequests = request.segments.map { segment in
        TranslationSession.Request(
            sourceText: segment.text,
            clientIdentifier: String(segment.number)
        )
    }

    do {
        let responses = try await session.translations(from: translationRequests)
        var translations: [Int: String] = [:]
        for response in responses {
            guard let identifier = response.clientIdentifier,
                  let number = Int(identifier) else {
                continue
            }
            translations[number] = response.targetText
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return translations
    } catch let error as MoongateError {
        throw error
    } catch is CancellationError {
        throw MoongateError.cancelled
    } catch {
        throw MoongateError.translateFailed(CoreL10n.t(
            L.Core.appleTranslationExecutionFailed,
            error.localizedDescription
        ))
    }
}
#endif
