import Foundation

/// 视频编码后端。决定烧录 / 转码时用硬件媒体引擎还是软件编码器。
public enum EncodeBackend: String, Codable, Sendable, Equatable, CaseIterable {
    /// 自动：优先使用可用的硬件媒体引擎；遇到兼容性问题时走兼容路径。日常推荐。
    case auto
    /// 优先硬件媒体引擎（VideoToolbox）。最快、最省电；特殊格式可能需要兼容处理。
    case hardware
    /// 兼容性更稳定的编码路径。同体积画质更稳，但 4K/HDR 通常更慢。
    case software

    public var displayName: String {
        switch self {
        case .auto: return "自动（硬件优先，推荐）"
        case .hardware: return "硬件加速（最快省电）"
        case .software: return "软件（画质最高，较慢）"
        }
    }

    /// 是否倾向使用硬件路径（auto / hardware）。software 返回 false。
    /// 实际是否真用硬件还要看 VideoToolbox 编码器可用性，由 Burner/Transcoder 决定。
    public var prefersHardware: Bool {
        self != .software
    }
}

public enum TranslationProvider: String, Codable, Sendable, Equatable, CaseIterable {
    case anthropic
    case openai

    public var defaultBaseURL: String {
        switch self {
        case .anthropic:
            return "https://api.anthropic.com"
        case .openai:
            return "https://api.openai.com"
        }
    }
}

public enum TranslationEngine: String, Codable, Sendable, Equatable, CaseIterable {
    case anthropicCompatible
    case openAICompatible
    case appleTranslationLowLatency
    case appleTranslationHighFidelity
    case appleFoundationOnDevice
    case appleFoundationPCC
    case appleFoundationCloudPro

    public var legacyProvider: TranslationProvider? {
        switch self {
        case .anthropicCompatible:
            return .anthropic
        case .openAICompatible:
            return .openai
        case .appleTranslationLowLatency,
             .appleTranslationHighFidelity,
             .appleFoundationOnDevice,
             .appleFoundationPCC,
             .appleFoundationCloudPro:
            return nil
        }
    }

    public var requiresCloudConfiguration: Bool {
        switch self {
        case .anthropicCompatible, .openAICompatible:
            return true
        case .appleTranslationLowLatency,
             .appleTranslationHighFidelity,
             .appleFoundationOnDevice,
             .appleFoundationPCC,
             .appleFoundationCloudPro:
            return false
        }
    }

    public static func compatible(with provider: TranslationProvider) -> TranslationEngine {
        switch provider {
        case .anthropic:
            return .anthropicCompatible
        case .openai:
            return .openAICompatible
        }
    }

    public var displayName: String {
        switch self {
        case .anthropicCompatible:
            return "Anthropic-compatible"
        case .openAICompatible:
            return "OpenAI-compatible"
        case .appleTranslationLowLatency:
            return "Apple Translation（低延迟）"
        case .appleTranslationHighFidelity:
            return "Apple Translation（高保真）"
        case .appleFoundationOnDevice:
            return "Apple Intelligence（本地）"
        case .appleFoundationPCC:
            return "Apple Private Cloud Compute（云端）"
        case .appleFoundationCloudPro:
            return "Apple Intelligence Cloud Pro（云端 Pro）"
        }
    }

    public var cliValue: String {
        switch self {
        case .anthropicCompatible:
            return "anthropic-compatible"
        case .openAICompatible:
            return "openai-compatible"
        case .appleTranslationLowLatency:
            return "apple-translation"
        case .appleTranslationHighFidelity:
            return "apple-translation-high-fidelity"
        case .appleFoundationOnDevice:
            return "foundation-on-device"
        case .appleFoundationPCC:
            return "pcc"
        case .appleFoundationCloudPro:
            return "cloud-pro"
        }
    }

    public static var supportedCLIValues: [String] {
        allCases.map(\.cliValue)
    }

    public init?(cliValue: String) {
        let normalized = cliValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "anthropic" || normalized == "claude" {
            self = .anthropicCompatible
            return
        }
        if normalized == "openai" {
            self = .openAICompatible
            return
        }
        if normalized == "apple-translation-low-latency" {
            self = .appleTranslationLowLatency
            return
        }
        if normalized == "apple-foundation-on-device" {
            self = .appleFoundationOnDevice
            return
        }
        if normalized == "apple-foundation-pcc" {
            self = .appleFoundationPCC
            return
        }
        if normalized == "apple-foundation-cloud-pro" {
            self = .appleFoundationCloudPro
            return
        }
        guard let engine = Self.allCases.first(where: { $0.cliValue == normalized }) else {
            return nil
        }
        self = engine
    }

    public var readinessGuidance: String {
        switch self {
        case .anthropicCompatible, .openAICompatible:
            return "填写服务地址、API 凭证和模型后即可测试连接。"
        case .appleTranslationLowLatency:
            return "运行前会检测系统翻译能力、语言组合和目标语言包；就绪后可使用系统 Apple Translation。"
        case .appleTranslationHighFidelity:
            return "运行前会检测系统翻译能力、高保真路径和语言包；就绪后可使用系统 Apple Translation。"
        case .appleFoundationOnDevice:
            return "运行前会检测设备是否支持 Apple Intelligence、本地模型是否可用；就绪后使用本地模型。"
        case .appleFoundationPCC:
            return "当前不可运行：Private Cloud Compute 需要公开运行时接口、申请资格、网络和配额。"
        case .appleFoundationCloudPro:
            return "当前不可运行：Apple Intelligence Cloud Pro 需要公开运行时接口、申请资格、网络和配额。"
        }
    }

    /// 是否能做「文本生成」（如视频内容总结）。Apple Translation 各档只能逐句翻译、
    /// 不能生成自由文本，因此总结不可用；云端 API 与本地 Foundation 模型可以。
    public var canGenerateText: Bool {
        switch self {
        case .anthropicCompatible, .openAICompatible, .appleFoundationOnDevice:
            return true
        case .appleTranslationLowLatency,
             .appleTranslationHighFidelity,
             .appleFoundationPCC,
             .appleFoundationCloudPro:
            return false
        }
    }
}

/// 一次 LLM 调用所需的端点配置。把「翻译」和「总结」从直接读 AppSettings 解耦：
/// 两者可共享同一份默认配置，也可各自单独配置（见 AppSettings.effective*Config）。
public struct LLMEndpointConfig: Sendable, Equatable {
    public var engine: TranslationEngine
    public var baseURL: String
    public var model: String
    public var authToken: String

    public init(
        engine: TranslationEngine,
        baseURL: String,
        model: String,
        authToken: String
    ) {
        self.engine = engine
        self.baseURL = baseURL
        self.model = model
        self.authToken = authToken
    }

    /// 云端 API 引擎需要地址+模型+凭证齐全；Apple 系引擎不需要这些字段。
    public var requiresCloudConfiguration: Bool { engine.requiresCloudConfiguration }

    public var isCloudConfigurationComplete: Bool {
        guard requiresCloudConfiguration else { return true }
        return !baseURL.trimmingCharacters(in: .whitespaces).isEmpty
            && !model.trimmingCharacters(in: .whitespaces).isEmpty
            && !authToken.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

public struct TranslationContext: Codable, Sendable, Equatable {
    public var sourceLanguage: String?
    public var targetLanguage: String

    public init(sourceLanguage: String? = nil, targetLanguage: String = "zh-Hans") {
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
    }

    public static func sourceLanguageIdentifier(fromSubtitleFile file: URL) -> String? {
        let stem = file.deletingPathExtension().lastPathComponent
        guard let dotIndex = stem.lastIndex(of: ".") else { return nil }
        let identifier = stem[stem.index(after: dotIndex)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return identifier.isEmpty ? nil : identifier
    }

    /// LLM 提示词用的目标语言可读名（如「简体中文」「繁體中文」「English」）。
    public var targetLanguageDisplayName: String {
        TranslationLanguage.displayName(for: targetLanguage)
    }

    /// 源语言是否已与目标语言同一脚本（同则跳过翻译，直接使用/烧录原字幕）。
    public var sourceMatchesTarget: Bool {
        TranslationLanguage.matches(source: sourceLanguage, target: targetLanguage)
    }
}

/// 翻译目标语言的归一与展示。区分 zh-Hans / zh-Hant，避免把"中文"当成单一目标。
/// 跨平台共享（桌面 Translator、iOS、CLI 都从这里取目标语言文案与跳过判定）。
public enum TranslationLanguage {
    public static let translatedSubtitleFileSuffixes: Set<String> = [
        ".zh-Hans.srt",
        ".zh-Hant.srt",
        ".en.srt",
    ]

    /// 目标语言代码 → LLM 提示词里的人类可读名。
    public static func displayName(for code: String) -> String {
        switch normalizedScript(code) {
        case "zh-Hans": return "简体中文"
        case "zh-Hant": return "繁體中文"
        case "en": return "English"
        default: return code
        }
    }

    /// 把任意 BCP-47 风格代码归一到"脚本级"标识，区分简繁。
    /// zh / zh-CN / zh-Hans → "zh-Hans"；zh-Hant / zh-TW / zh-HK / zh-MO → "zh-Hant"；其余取主语言子标签。
    public static func normalizedScript(_ code: String) -> String {
        let lower = code.lowercased()
        if lower.hasPrefix("zh") {
            if lower.contains("hant") || lower.contains("tw") || lower.contains("hk") || lower.contains("mo") {
                return "zh-Hant"
            }
            return "zh-Hans"
        }
        return lower.split(separator: "-").first.map(String.init) ?? lower
    }

    public static func translatedSubtitleFileSuffix(for code: String) -> String {
        ".\(normalizedScript(code)).srt"
    }

    public static func isTranslatedSubtitleFileName(_ name: String) -> Bool {
        let lower = name.lowercased()
        guard lower.hasSuffix(".srt") else { return false }
        let stem = String(lower.dropLast(4))
        let parts = stem.split(separator: ".").map(String.init)
        guard parts.count >= 3, let source = parts.dropLast().last, let target = parts.last else {
            return false
        }
        return isLikelyLanguageCode(source) && translatedSubtitleFileSuffixes.contains { suffix in
            suffix.lowercased() == ".\(target).srt"
        }
    }

    /// 源语言与目标语言是否同一脚本。源为空（未知）按"不匹配"处理，从而不跳过翻译。
    public static func matches(source: String?, target: String) -> Bool {
        guard let source, !source.isEmpty else { return false }
        return normalizedScript(source) == normalizedScript(target)
    }

    private static func isLikelyLanguageCode(_ value: String) -> Bool {
        let segments = value.split(separator: "-")
        guard let primary = segments.first, primary.count >= 2, primary.count <= 3 else {
            return false
        }
        return primary.allSatisfy(\.isLetter)
    }
}

public struct TranslationReadinessIssue: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, Equatable, CaseIterable {
        case needsConfiguration
        case needsRuntimeVerification
        case needsLanguageDownload
        case unsupportedLanguagePair
        case appleIntelligenceUnavailable
        case modelUnavailable
        case needsExecutionAdapter
        case pccUnavailable
    }

    public var kind: Kind
    public var message: String

    public init(kind: Kind, message: String? = nil) {
        self.kind = kind
        self.message = message ?? kind.defaultMessage
    }
}

public struct TranslationReadiness: Codable, Sendable, Equatable {
    public var issues: [TranslationReadinessIssue]

    public var isReady: Bool {
        issues.isEmpty
    }

    public static let ready = TranslationReadiness()

    public init(issues: [TranslationReadinessIssue] = []) {
        self.issues = issues
    }
}

public enum AppleTranslationSetupActionKind: String, Codable, Sendable, Equatable, CaseIterable {
    case refreshReadiness
    case openLanguageSettings
    case openAppleIntelligenceSettings
    case chooseDifferentEngine
}

public struct AppleTranslationSetupAction: Codable, Sendable, Equatable, Identifiable {
    public var kind: AppleTranslationSetupActionKind
    public var title: String

    public var id: String { kind.rawValue }

    public init(kind: AppleTranslationSetupActionKind, title: String) {
        self.kind = kind
        self.title = title
    }
}

public struct AppleTranslationSetupGuidance: Codable, Sendable, Equatable {
    public var title: String
    public var steps: [String]
    public var actions: [AppleTranslationSetupAction]

    public init(
        title: String,
        steps: [String],
        actions: [AppleTranslationSetupAction]
    ) {
        self.title = title
        self.steps = steps
        self.actions = actions
    }

    public static func make(
        engine: TranslationEngine,
        readiness: TranslationReadiness
    ) -> AppleTranslationSetupGuidance {
        var builder = AppleTranslationSetupGuidanceBuilder(title: title(for: engine))

        for issue in readiness.issues {
            builder.append(issue.kind, engine: engine, fallbackMessage: issue.message)
        }

        if builder.steps.isEmpty, !readiness.isReady {
            builder.addStep("当前翻译引擎还不可运行，请重新检测或改用 API 兼容引擎。")
            builder.addAction(.refreshReadiness)
            builder.addAction(.chooseDifferentEngine)
        }

        return AppleTranslationSetupGuidance(
            title: builder.title,
            steps: builder.steps,
            actions: builder.actions
        )
    }

    private static func title(for engine: TranslationEngine) -> String {
        switch engine {
        case .appleTranslationLowLatency, .appleTranslationHighFidelity:
            return "完成 Apple Translation 设置"
        case .appleFoundationOnDevice:
            return "完成本地 Apple Intelligence 设置"
        case .appleFoundationPCC:
            return "Apple Intelligence 云端暂不可用"
        case .appleFoundationCloudPro:
            return "Apple Intelligence Cloud Pro 云端 Pro 暂不可用"
        case .anthropicCompatible, .openAICompatible:
            return "完成翻译设置"
        }
    }
}

private struct AppleTranslationSetupGuidanceBuilder {
    var title: String
    var steps: [String] = []
    var actions: [AppleTranslationSetupAction] = []

    mutating func append(
        _ kind: TranslationReadinessIssue.Kind,
        engine: TranslationEngine,
        fallbackMessage: String
    ) {
        switch kind {
        case .needsRuntimeVerification:
            if engine.isUnavailableAppleCloudEngine {
                addAppleCloudUnavailableStep(for: engine)
                addAction(.chooseDifferentEngine)
            } else {
                addRuntimeVerificationStep(for: engine, fallbackMessage: fallbackMessage)
                addAction(.refreshReadiness)
            }
        case .needsLanguageDownload:
            addStep("到系统设置下载需要的翻译语言；App 不会自动下载语言包。")
            addAction(.openLanguageSettings)
        case .unsupportedLanguagePair:
            addStep("当前源语言和目标语言组合不支持，请换一个语言组合或改用 API 兼容引擎。")
            addAction(.chooseDifferentEngine)
        case .appleIntelligenceUnavailable:
            addStep("先确认这台 Mac 和当前系统版本支持 Apple Intelligence。")
            addStep("到系统设置中启用 Apple Intelligence；系统侧开关由你控制。")
            addStep("本机 Apple Intelligence 暂不可用时，可以改用 API 兼容引擎继续翻译。")
            addAction(.openAppleIntelligenceSettings)
        case .modelUnavailable:
            addStep("到系统设置 > Apple Intelligence 与 Siri 查看模型准备状态；App 不会自动下载或替换模型。")
            addStep("本机 Apple Intelligence 暂不可用时，可以改用 API 兼容引擎继续翻译。")
            addAction(.openAppleIntelligenceSettings)
            addAction(.refreshReadiness)
        case .needsExecutionAdapter:
            addStep("当前系统能力可能已就绪，但此版本没有可用于该状态的翻译执行路径。")
            addStep("请先改用其他可运行的翻译引擎。")
            addAction(.chooseDifferentEngine)
        case .pccUnavailable:
            addAppleCloudUnavailableStep(for: engine)
            addAction(.chooseDifferentEngine)
        case .needsConfiguration:
            addStep(fallbackMessage)
        }
    }

    mutating func addStep(_ step: String) {
        guard !steps.contains(step) else { return }
        steps.append(step)
    }

    mutating func addAction(_ kind: AppleTranslationSetupActionKind) {
        guard !actions.contains(where: { $0.kind == kind }) else { return }
        actions.append(AppleTranslationSetupAction(kind: kind, title: title(for: kind)))
    }

    private mutating func addRuntimeVerificationStep(
        for engine: TranslationEngine,
        fallbackMessage: String
    ) {
        switch engine {
        case .appleTranslationLowLatency, .appleTranslationHighFidelity:
            addStep("点“重新检测”，确认当前系统支持 Apple Translation。")
        case .appleFoundationOnDevice:
            addStep("点“重新检测”，确认本地 Apple Intelligence 运行时已经可用。")
        case .appleFoundationPCC:
            addStep("点“重新检测”，确认云端 Apple Intelligence 运行时是否开放。")
        case .appleFoundationCloudPro:
            addStep("点“重新检测”，确认 Apple Intelligence Cloud Pro（云端 Pro）运行时是否开放。")
        case .anthropicCompatible, .openAICompatible:
            addStep(fallbackMessage)
        }
    }

    private mutating func addAppleCloudUnavailableStep(for engine: TranslationEngine) {
        switch engine {
        case .appleFoundationCloudPro:
            addStep("Apple Intelligence Cloud Pro（云端 Pro）暂未提供可用于本 App 的公开运行时接口。")
        default:
            addStep("Private Cloud Compute 暂未提供可用于本 App 的公开运行时接口。")
        }
        addStep("请先改用 Apple Translation、本地 Apple Intelligence 或 API 兼容引擎。")
    }

    private func title(for kind: AppleTranslationSetupActionKind) -> String {
        switch kind {
        case .refreshReadiness:
            return "重新检测"
        case .openLanguageSettings:
            return "打开系统设置"
        case .openAppleIntelligenceSettings:
            return "打开系统设置"
        case .chooseDifferentEngine:
            return "改用 API 兼容引擎"
        }
    }
}

private extension TranslationEngine {
    var isUnavailableAppleCloudEngine: Bool {
        switch self {
        case .appleFoundationPCC, .appleFoundationCloudPro:
            return true
        case .anthropicCompatible,
             .openAICompatible,
             .appleTranslationLowLatency,
             .appleTranslationHighFidelity,
             .appleFoundationOnDevice:
            return false
        }
    }
}

public struct TranslationRuntimeReadinessRequest: Sendable, Equatable {
    public var engine: TranslationEngine
    public var context: TranslationContext
    public var isCloudConfigurationComplete: Bool
    public var fallbackReadiness: TranslationReadiness

    public init(
        engine: TranslationEngine,
        context: TranslationContext = TranslationContext(),
        isCloudConfigurationComplete: Bool,
        fallbackReadiness: TranslationReadiness
    ) {
        self.engine = engine
        self.context = context
        self.isCloudConfigurationComplete = isCloudConfigurationComplete
        self.fallbackReadiness = fallbackReadiness
    }
}

public protocol TranslationRuntimeReadinessEvaluating: Sendable {
    func readiness(for request: TranslationRuntimeReadinessRequest) async -> TranslationReadiness
}

public struct StaticTranslationRuntimeReadinessEvaluator: TranslationRuntimeReadinessEvaluating {
    public init() {}

    public func readiness(for request: TranslationRuntimeReadinessRequest) async -> TranslationReadiness {
        request.fallbackReadiness
    }
}

private extension TranslationReadinessIssue.Kind {
    var defaultMessage: String {
        switch self {
        case .needsConfiguration:
            return "需要先完成翻译设置。"
        case .needsRuntimeVerification:
            return "需要先检测系统翻译能力。"
        case .needsLanguageDownload:
            return "需要先下载对应语言。"
        case .unsupportedLanguagePair:
            return "当前语言组合暂不支持。"
        case .appleIntelligenceUnavailable:
            return "当前设备或系统不可用 Apple Intelligence。"
        case .modelUnavailable:
            return "当前模型不可用。"
        case .needsExecutionAdapter:
            return "此版本暂不能直接用于字幕翻译。"
        case .pccUnavailable:
            return "Private Cloud Compute 当前不可用。"
        }
    }
}
