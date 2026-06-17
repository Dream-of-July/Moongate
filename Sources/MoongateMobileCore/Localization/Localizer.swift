import Foundation

// MARK: - 界面语言

/// 界面语言。与翻译目标语言（`TranslationContext.targetLanguage`）相互独立——
/// 例如英文界面 + 翻译成繁中是合法组合。持久化值见 `AppSettings.appLanguage`。
public enum AppLanguage: String, Sendable, CaseIterable, Codable {
    case auto
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"
    case en

    /// 把 `.auto` 解析到具体界面语言（依据系统首选语言）。
    public func resolved(preferredLanguages: [String] = Locale.preferredLanguages) -> ResolvedLanguage {
        switch self {
        case .zhHans: return .zhHans
        case .zhHant: return .zhHant
        case .en: return .en
        case .auto:
            let first = (preferredLanguages.first ?? "en").lowercased()
            guard first.hasPrefix("zh") else { return .en }
            if first.contains("hant") || first.contains("tw") || first.contains("hk") || first.contains("mo") {
                return .zhHant
            }
            return .zhHans
        }
    }
}

/// 解析后的具体界面语言（无 `.auto`），对应一张字符串表。
public enum ResolvedLanguage: String, Sendable, CaseIterable {
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"
    case en
}

// MARK: - 纯查表（CLI / 测试 / 无 Combine 平台可用）

/// 运行时字符串表查询。缺 key 时返回 key 本身，让遗漏在 UI 上可见而不是崩溃（镜像 Windows `Loc.S`）。
public enum LocalizedStrings {
    public static func table(for language: ResolvedLanguage) -> [String: String] {
        switch language {
        case .zhHans: return LocalizationTables.zhHans
        case .zhHant: return LocalizationTables.zhHant
        case .en: return LocalizationTables.en
        }
    }

    public static func string(_ key: String, language: ResolvedLanguage) -> String {
        table(for: language)[key] ?? key
    }

    public static func format(_ key: String, language: ResolvedLanguage, _ args: [CVarArg]) -> String {
        String(format: table(for: language)[key] ?? key, arguments: args)
    }
}

/// 字符串表容器；各语言表在 `Strings.<lang>.swift` 里以 `extension` 填充，便于分文件维护与 diff。
public enum LocalizationTables {}

// MARK: - 运行时可观察的语言切换器（仅 Apple 平台 / SwiftUI）

#if canImport(Combine)
import Combine

/// App 内即时切换界面语言（无需重启）。`AppSettings.appLanguage` 是持久化权威，
/// `Localizer.language` 是运行时权威；二者在同一处一起写，避免漂移（镜像 Windows `LocalizationManager.Apply`）。
@MainActor
public final class Localizer: ObservableObject {
    @Published public private(set) var language: AppLanguage
    @Published public private(set) var resolved: ResolvedLanguage

    public init(language: AppLanguage = .auto) {
        self.language = language
        self.resolved = language.resolved()
    }

    public func setLanguage(_ language: AppLanguage) {
        self.language = language
        self.resolved = language.resolved()
    }

    /// 取文案；缺 key 返回 key 本身。
    public func t(_ key: String) -> String {
        LocalizedStrings.string(key, language: resolved)
    }

    /// 取带占位符的文案（用位置化 %1$@ / %lld，因中英语序不同）。
    public func t(_ key: String, _ args: CVarArg...) -> String {
        LocalizedStrings.format(key, language: resolved, args)
    }
}
#endif
