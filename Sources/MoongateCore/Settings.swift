import Foundation
@_exported import MoongateMobileCore

/// App 设置。持久化在 ~/Library/Application Support/月之门/settings.json（0600）。
/// 注意：authToken 属于敏感凭证，只落在本地配置文件，绝不写入代码、日志或版本库。
public struct AppSettings: Codable, Sendable, Equatable {
    /// 翻译接口协议
    public var translationProvider: TranslationProvider
    /// 翻译引擎。兼容 API 引擎继续使用旧 provider/base/model/token 字段；Apple 引擎的运行 readiness 另行判断。
    public var translationEngine: TranslationEngine
    /// 翻译服务地址（官方 API 或企业网关），不含 /v1/messages 或 /v1/responses 路径
    public var translationBaseURL: String
    /// 模型名，例如 "claude-haiku-4-5" 或网关侧的模型标识
    public var translationModel: String
    /// API 凭证（x-api-key / Bearer token）
    public var translationAuthToken: String

    // MARK: AI 默认配置（翻译/总结共享的「默认」槽位）
    /// 默认 AI 引擎。翻译/总结「跟随默认」时用这一组 ai* 字段。
    public var aiEngine: TranslationEngine
    public var aiBaseURL: String
    public var aiModel: String
    public var aiAuthToken: String

    /// 翻译是否跟随默认 AI 配置。true=用 ai*；false=用上面的 translation* 作为单独覆盖。
    public var translationFollowsDefault: Bool

    // MARK: 总结配置
    /// 总结是否跟随默认 AI 配置。true=用 ai*；false=用 summary* 单独覆盖。
    public var summaryFollowsDefault: Bool
    public var summaryEngine: TranslationEngine
    public var summaryBaseURL: String
    public var summaryModel: String
    public var summaryAuthToken: String

    /// 烧录字幕样式
    public var subtitleStyle: SubtitleStyle
    /// 烧录时限制最大分辨率高度：源高于此值则缩放到此值（既快又小，避开 4K60 的 H.264 上限）。
    /// nil = 保持源分辨率。默认 1080。
    public var maxBurnHeight: Int?
    /// 同时进行的下载任务数（1...5，默认 3）。
    public var maxConcurrentDownloads: Int
    /// 同时进行的压制（烧录）任务数（1...3，默认 2）。压制吃满 CPU，并行多了互相拖慢。
    public var maxConcurrentBurns: Int

    public init(
        translationProvider: TranslationProvider = .anthropic,
        translationEngine: TranslationEngine? = nil,
        translationBaseURL: String = TranslationProvider.anthropic.defaultBaseURL,
        translationModel: String = "",
        translationAuthToken: String = "",
        aiEngine: TranslationEngine? = nil,
        aiBaseURL: String? = nil,
        aiModel: String? = nil,
        aiAuthToken: String? = nil,
        translationFollowsDefault: Bool = true,
        summaryFollowsDefault: Bool = true,
        summaryEngine: TranslationEngine? = nil,
        summaryBaseURL: String? = nil,
        summaryModel: String? = nil,
        summaryAuthToken: String? = nil,
        subtitleStyle: SubtitleStyle = .bilingual,
        maxBurnHeight: Int? = 1080,
        maxConcurrentDownloads: Int = 3,
        maxConcurrentBurns: Int = 2
    ) {
        let resolvedEngine = translationEngine ?? TranslationEngine.compatible(with: translationProvider)
        self.translationProvider = resolvedEngine.legacyProvider ?? translationProvider
        self.translationEngine = resolvedEngine
        self.translationBaseURL = translationBaseURL
        self.translationModel = translationModel
        self.translationAuthToken = translationAuthToken
        // 默认 AI 配置缺省时用翻译配置播种，保证「跟随默认」时行为与旧版翻译一致。
        self.aiEngine = aiEngine ?? resolvedEngine
        self.aiBaseURL = aiBaseURL ?? translationBaseURL
        self.aiModel = aiModel ?? translationModel
        self.aiAuthToken = aiAuthToken ?? translationAuthToken
        self.translationFollowsDefault = translationFollowsDefault
        self.summaryFollowsDefault = summaryFollowsDefault
        self.summaryEngine = summaryEngine ?? (aiEngine ?? resolvedEngine)
        self.summaryBaseURL = summaryBaseURL ?? (aiBaseURL ?? translationBaseURL)
        self.summaryModel = summaryModel ?? (aiModel ?? translationModel)
        self.summaryAuthToken = summaryAuthToken ?? (aiAuthToken ?? translationAuthToken)
        self.subtitleStyle = subtitleStyle
        self.maxBurnHeight = maxBurnHeight
        self.maxConcurrentDownloads = maxConcurrentDownloads
        self.maxConcurrentBurns = maxConcurrentBurns
    }

    // MARK: 存储位置

    public static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("月之门", isDirectory: true)
    }

    public static var legacySupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("视频下载器", isDirectory: true)
    }

    public static var settingsFileURL: URL {
        supportDirectory.appendingPathComponent("settings.json")
    }

    /// 站点登录后导出的 Netscape 格式 cookies 文件；存在时引擎自动以 --cookies 传给 yt-dlp
    public static var cookieFileURL: URL {
        supportDirectory.appendingPathComponent("cookies.txt")
    }

    // MARK: 读写

    private enum CodingKeys: String, CodingKey {
        case translationProvider, translationEngine, translationBaseURL, translationModel, translationAuthToken, subtitleStyle, maxBurnHeight
        case maxConcurrentDownloads, maxConcurrentBurns
        case aiEngine, aiBaseURL, aiModel, aiAuthToken, translationFollowsDefault
        case summaryFollowsDefault, summaryEngine, summaryBaseURL, summaryModel, summaryAuthToken
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        translationBaseURL = try c.decodeIfPresent(String.self, forKey: .translationBaseURL)
            ?? TranslationProvider.anthropic.defaultBaseURL
        translationModel = try c.decodeIfPresent(String.self, forKey: .translationModel) ?? ""
        let rawProvider = try c.decodeIfPresent(String.self, forKey: .translationProvider)
        let inferredProvider = rawProvider.flatMap { TranslationProvider(rawValue: $0) }
            ?? Self.inferProvider(baseURL: translationBaseURL, model: translationModel)
        let rawEngine = try c.decodeIfPresent(String.self, forKey: .translationEngine)
        translationEngine = rawEngine.flatMap { TranslationEngine(rawValue: $0) }
            ?? TranslationEngine.compatible(with: inferredProvider)
        translationProvider = translationEngine.legacyProvider ?? inferredProvider
        translationAuthToken = try c.decodeIfPresent(String.self, forKey: .translationAuthToken) ?? ""

        // AI 默认配置：旧 settings.json 没有 ai* 字段时用翻译配置播种，保证「跟随默认」行为不变。
        let rawAIEngine = try c.decodeIfPresent(String.self, forKey: .aiEngine)
        aiEngine = rawAIEngine.flatMap { TranslationEngine(rawValue: $0) } ?? translationEngine
        aiBaseURL = try c.decodeIfPresent(String.self, forKey: .aiBaseURL) ?? translationBaseURL
        aiModel = try c.decodeIfPresent(String.self, forKey: .aiModel) ?? translationModel
        aiAuthToken = try c.decodeIfPresent(String.self, forKey: .aiAuthToken) ?? translationAuthToken
        translationFollowsDefault = try c.decodeIfPresent(Bool.self, forKey: .translationFollowsDefault) ?? true

        // 总结配置：缺省跟随默认；单独覆盖槽缺省用默认 AI 配置播种。
        summaryFollowsDefault = try c.decodeIfPresent(Bool.self, forKey: .summaryFollowsDefault) ?? true
        let rawSummaryEngine = try c.decodeIfPresent(String.self, forKey: .summaryEngine)
        summaryEngine = rawSummaryEngine.flatMap { TranslationEngine(rawValue: $0) } ?? aiEngine
        summaryBaseURL = try c.decodeIfPresent(String.self, forKey: .summaryBaseURL) ?? aiBaseURL
        summaryModel = try c.decodeIfPresent(String.self, forKey: .summaryModel) ?? aiModel
        summaryAuthToken = try c.decodeIfPresent(String.self, forKey: .summaryAuthToken) ?? aiAuthToken

        subtitleStyle = try c.decodeIfPresent(SubtitleStyle.self, forKey: .subtitleStyle) ?? .bilingual
        // 旧版 settings.json 没有这个键：缺失时按默认 1080 处理，而非「保持源分辨率」
        if c.contains(.maxBurnHeight) {
            maxBurnHeight = try c.decodeIfPresent(Int.self, forKey: .maxBurnHeight)
        } else {
            maxBurnHeight = 1080
        }
        // 并发数：缺失按默认，读入时夹回合法区间
        let downloads = try c.decodeIfPresent(Int.self, forKey: .maxConcurrentDownloads) ?? 3
        maxConcurrentDownloads = min(max(downloads, 1), 5)
        let burns = try c.decodeIfPresent(Int.self, forKey: .maxConcurrentBurns) ?? 2
        maxConcurrentBurns = min(max(burns, 1), 3)
    }

    public static func load() -> AppSettings {
        guard let data = try? migratedData(
            supportDirectory: supportDirectory,
            legacySupportDirectory: legacySupportDirectory,
            settingsFileName: "settings.json",
            cookieFileName: "cookies.txt"
        ),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return settings
    }

    static func load(
        supportDirectory: URL,
        legacySupportDirectory: URL,
        settingsFileName: String = "settings.json",
        cookieFileName: String = "cookies.txt"
    ) -> AppSettings {
        guard let data = try? migratedData(
            supportDirectory: supportDirectory,
            legacySupportDirectory: legacySupportDirectory,
            settingsFileName: settingsFileName,
            cookieFileName: cookieFileName
        ),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return settings
    }

    private static func migratedData(
        supportDirectory dir: URL,
        legacySupportDirectory legacyDir: URL,
        settingsFileName: String,
        cookieFileName: String
    ) throws -> Data {
        // cookies 与 settings 解耦：只登录过站点、从没改过设置的用户没有 settings.json，
        // 但有 cookies.txt。若把 cookie 迁移挂在 settings 读取后面，settings 缺失时整段抛错，
        // 改名（视频下载器→月之门）后登录态会被静默丢弃。所以先无条件迁移 cookies。
        migrateCookieFileIfNeeded(
            supportDirectory: dir,
            legacySupportDirectory: legacyDir,
            cookieFileName: cookieFileName
        )

        let settingsURL = dir.appendingPathComponent(settingsFileName)
        if let data = try? Data(contentsOf: settingsURL) {
            return data
        }

        let legacySettingsURL = legacyDir.appendingPathComponent(settingsFileName)
        let data = try Data(contentsOf: legacySettingsURL)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: settingsURL.path) {
            try? FileManager.default.copyItem(at: legacySettingsURL, to: settingsURL)
            #if !os(Windows)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settingsURL.path)
            #endif
        }

        return data
    }

    /// 把旧目录下的 cookies.txt 迁移到新目录。与 settings 读取互相独立，
    /// 任一文件缺失都不影响另一个的迁移。
    private static func migrateCookieFileIfNeeded(
        supportDirectory dir: URL,
        legacySupportDirectory legacyDir: URL,
        cookieFileName: String
    ) {
        let cookieURL = dir.appendingPathComponent(cookieFileName)
        let legacyCookieURL = legacyDir.appendingPathComponent(cookieFileName)
        guard FileManager.default.fileExists(atPath: legacyCookieURL.path),
              !FileManager.default.fileExists(atPath: cookieURL.path) else {
            return
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.copyItem(at: legacyCookieURL, to: cookieURL)
        #if !os(Windows)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cookieURL.path)
        #endif
    }

    public func save() throws {
        try save(supportDirectory: Self.supportDirectory, settingsFileURL: Self.settingsFileURL)
    }

    func save(supportDirectory dir: URL, settingsFileURL url: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        // 先写临时文件再原子替换：写失败时旧配置（含凭证）原样保留，不能像以前那样
        // 删旧文件导致磁盘满/权限问题时配置全丢。临时文件一步创建即 0600。
        let temp = dir.appendingPathComponent("settings.json.tmp-\(UUID().uuidString)")
        #if os(Windows)
        let attributes: [FileAttributeKey: Any]? = nil
        #else
        let attributes: [FileAttributeKey: Any]? = [.posixPermissions: 0o600]
        #endif
        guard FileManager.default.createFile(
            atPath: temp.path, contents: data,
            attributes: attributes
        ) else {
            try? FileManager.default.removeItem(at: temp)
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
            } else {
                try FileManager.default.moveItem(at: temp, to: url)
            }
            #if !os(Windows)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            #endif
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    // MARK: 有效配置（翻译/总结实际运行时用的端点）

    /// 翻译实际使用的端点配置：跟随默认时用 ai*，否则用 translation* 覆盖槽。
    public var effectiveTranslationConfig: LLMEndpointConfig {
        translationFollowsDefault
            ? LLMEndpointConfig(engine: aiEngine, baseURL: aiBaseURL, model: aiModel, authToken: aiAuthToken)
            : LLMEndpointConfig(engine: translationEngine, baseURL: translationBaseURL, model: translationModel, authToken: translationAuthToken)
    }

    /// 总结实际使用的端点配置：跟随默认时用 ai*，否则用 summary* 覆盖槽。
    public var effectiveSummaryConfig: LLMEndpointConfig {
        summaryFollowsDefault
            ? LLMEndpointConfig(engine: aiEngine, baseURL: aiBaseURL, model: aiModel, authToken: aiAuthToken)
            : LLMEndpointConfig(engine: summaryEngine, baseURL: summaryBaseURL, model: summaryModel, authToken: summaryAuthToken)
    }

    /// 返回一份把 translation*/engine 替换成给定端点配置的副本。
    /// LLM 调用（翻译、总结）统一走 translation* 字段，用它把有效配置喂进去。
    public func applyingTranslationConfig(_ config: LLMEndpointConfig) -> AppSettings {
        var copy = self
        copy.translationEngine = config.engine
        copy.translationProvider = config.engine.legacyProvider ?? copy.translationProvider
        copy.translationBaseURL = config.baseURL
        copy.translationModel = config.model
        copy.translationAuthToken = config.authToken
        return copy
    }

    /// 翻译功能是否已配置完整（按有效翻译配置判断）。
    public var isTranslationConfigured: Bool {
        effectiveTranslationConfig.isCloudConfigurationComplete
    }

    /// 总结功能是否可用：引擎能生成文本，且（云端引擎时）地址/模型/凭证齐全。
    public var isSummaryConfigured: Bool {
        let config = effectiveSummaryConfig
        guard config.engine.canGenerateText else { return false }
        return config.isCloudConfigurationComplete
    }

    /// 已填好服务地址和凭证，但模型可以稍后从候选菜单里选择。
    public var isTranslationEndpointConfigured: Bool {
        guard translationEngine.requiresCloudConfiguration else { return true }
        return !translationBaseURL.trimmingCharacters(in: .whitespaces).isEmpty
            && !translationAuthToken.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// 翻译运行前 readiness。区别于 `isTranslationConfigured`：
    /// `isTranslationConfigured` 只表示设置表单是否填完；readiness 表示当前引擎是否可实际运行。
    /// 按「有效翻译引擎」判断（跟随默认时即 aiEngine）。
    public func translationReadiness(context: TranslationContext = TranslationContext()) -> TranslationReadiness {
        switch effectiveTranslationConfig.engine {
        case .anthropicCompatible, .openAICompatible:
            return isTranslationConfigured
                ? .ready
                : TranslationReadiness(issues: [TranslationReadinessIssue(kind: .needsConfiguration)])
        case .appleTranslationLowLatency, .appleTranslationHighFidelity:
            var issues = [TranslationReadinessIssue(kind: .needsRuntimeVerification)]
            if context.targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(TranslationReadinessIssue(kind: .unsupportedLanguagePair))
            } else {
                issues.append(TranslationReadinessIssue(kind: .needsLanguageDownload))
            }
            return TranslationReadiness(issues: issues)
        case .appleFoundationOnDevice:
            return TranslationReadiness(issues: [
                TranslationReadinessIssue(kind: .appleIntelligenceUnavailable),
                TranslationReadinessIssue(kind: .modelUnavailable)
            ])
        case .appleFoundationPCC:
            return TranslationReadiness(issues: [
                TranslationReadinessIssue(kind: .pccUnavailable)
            ])
        case .appleFoundationCloudPro:
            return TranslationReadiness(issues: [
                TranslationReadinessIssue(
                    kind: .pccUnavailable,
                    message: "Apple Intelligence Cloud Pro（云端 Pro）当前不可用。"
                )
            ])
        }
    }

    public func translationRuntimeReadiness(
        context: TranslationContext = TranslationContext(),
        evaluator: any TranslationRuntimeReadinessEvaluating = StaticTranslationRuntimeReadinessEvaluator()
    ) async -> TranslationReadiness {
        await evaluator.readiness(for: TranslationRuntimeReadinessRequest(
            engine: effectiveTranslationConfig.engine,
            context: context,
            isCloudConfigurationComplete: isTranslationConfigured,
            fallbackReadiness: translationReadiness(context: context)
        ))
    }

    public mutating func setTranslationProvider(_ provider: TranslationProvider) {
        let trimmedBaseURL = translationBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultBaseURLs = Set(TranslationProvider.allCases.map(\.defaultBaseURL))

        translationProvider = provider
        translationEngine = TranslationEngine.compatible(with: provider)

        if trimmedBaseURL.isEmpty || defaultBaseURLs.contains(trimmedBaseURL) {
            translationBaseURL = provider.defaultBaseURL
        }
    }

    private static func inferProvider(baseURL: String, model: String) -> TranslationProvider {
        let normalizedBase = baseURL.lowercased()
        let normalizedModel = model.lowercased()
        if normalizedBase.contains("api.openai.com")
            || normalizedModel.hasPrefix("gpt-")
            || normalizedModel.hasPrefix("o1")
            || normalizedModel.hasPrefix("o3")
            || normalizedModel.hasPrefix("o4")
            || normalizedModel.hasPrefix("o5") {
            return .openai
        }
        return .anthropic
    }
}
