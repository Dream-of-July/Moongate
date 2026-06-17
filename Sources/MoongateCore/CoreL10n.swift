import Foundation
import MoongateMobileCore

/// Runtime localization bridge for non-UI core code.
///
/// SwiftUI views use `Localizer` directly, but download/translate/burn pipelines
/// run in the core layer and may emit user-facing status or error messages from
/// background tasks. This bridge keeps those messages aligned with the current
/// app language without pushing UI objects into core services.
public enum CoreL10n {
    private static let lock = NSLock()
    private static var _language: ResolvedLanguage = .zhHans

    public static var language: ResolvedLanguage {
        lock.lock()
        defer { lock.unlock() }
        return _language
    }

    public static func setLanguage(_ language: ResolvedLanguage) {
        lock.lock()
        _language = language
        lock.unlock()
    }

    public static func setAppLanguage(_ language: AppLanguage) {
        setLanguage(language.resolved())
    }

    public static func sync(from settings: AppSettings) {
        setAppLanguage(AppLanguage(rawValue: settings.appLanguage) ?? .auto)
    }

    public static func t(_ key: String) -> String {
        LocalizedStrings.string(key, language: language)
    }

    public static func t(_ key: String, _ args: CVarArg...) -> String {
        LocalizedStrings.format(key, language: language, args)
    }

    public static func text(en: String, zhHans: String, zhHant: String) -> String {
        switch language {
        case .en: return en
        case .zhHans: return zhHans
        case .zhHant: return zhHant
        }
    }

    public static func readinessMessage(for kind: TranslationReadinessIssue.Kind) -> String {
        switch kind {
        case .needsConfiguration:
            return t(L.Core.readinessNeedsConfiguration)
        case .needsRuntimeVerification:
            return t(L.Core.readinessNeedsRuntimeVerification)
        case .needsLanguageDownload:
            return t(L.Core.readinessNeedsLanguageDownload)
        case .unsupportedLanguagePair:
            return t(L.Core.readinessUnsupportedLanguagePair)
        case .appleIntelligenceUnavailable:
            return t(L.Core.readinessAppleIntelligenceUnavailable)
        case .modelUnavailable:
            return t(L.Core.readinessModelUnavailable)
        case .needsExecutionAdapter:
            return t(L.Core.readinessNeedsExecutionAdapter)
        case .pccUnavailable:
            return t(L.Core.readinessPCCUnavailable)
        }
    }

    public static func issue(_ kind: TranslationReadinessIssue.Kind) -> TranslationReadinessIssue {
        TranslationReadinessIssue(kind: kind, message: readinessMessage(for: kind))
    }
}
