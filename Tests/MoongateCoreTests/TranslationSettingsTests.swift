@testable import MoongateCore
import XCTest

final class TranslationSettingsTests: XCTestCase {
    func testNewSettingsDefaultToAnthropicCompatibleEngineAndLegacyProvider() {
        let settings = AppSettings()

        XCTAssertEqual(settings.translationEngine, .anthropicCompatible)
        XCTAssertEqual(settings.translationProvider, .anthropic)
    }

    func testLegacyJSONWithOpenAIProviderMigratesToOpenAICompatibleEngine() throws {
        let settings = try decodeSettings("""
        {
          "translationProvider": "openai",
          "translationBaseURL": "https://api.openai.com",
          "translationModel": "gpt-5-mini",
          "translationAuthToken": "token"
        }
        """)

        XCTAssertEqual(settings.translationEngine, .openAICompatible)
        XCTAssertEqual(settings.translationProvider, .openai)
    }

    func testLegacyJSONWithoutProviderInfersOpenAICompatibleEngineFromBaseAndModel() throws {
        let settings = try decodeSettings("""
        {
          "translationBaseURL": "https://api.openai.com/v1",
          "translationModel": "gpt-5-mini",
          "translationAuthToken": "token"
        }
        """)

        XCTAssertEqual(settings.translationEngine, .openAICompatible)
        XCTAssertEqual(settings.translationProvider, .openai)
    }

    func testAppleEnginesAreConfigurationCompleteWithoutCloudFields() {
        let engines: [TranslationEngine] = [
            .appleTranslationLowLatency,
            .appleTranslationHighFidelity,
            .appleFoundationOnDevice,
            .appleFoundationPCC,
            .appleFoundationCloudPro
        ]

        for engine in engines {
            let settings = AppSettings(
                translationEngine: engine,
                translationBaseURL: "",
                translationModel: "",
                translationAuthToken: ""
            )

            XCTAssertTrue(settings.isTranslationConfigured, "\(engine.rawValue) should not require cloud fields")
        }
    }

    func testCloudCompatibleEnginesStillRequireBaseModelAndToken() {
        let cloudEngines: [TranslationEngine] = [.anthropicCompatible, .openAICompatible]

        for engine in cloudEngines {
            XCTAssertFalse(AppSettings(
                translationEngine: engine,
                translationBaseURL: "",
                translationModel: "model",
                translationAuthToken: "token"
            ).isTranslationConfigured)
            XCTAssertFalse(AppSettings(
                translationEngine: engine,
                translationBaseURL: "https://example.com",
                translationModel: "",
                translationAuthToken: "token"
            ).isTranslationConfigured)
            XCTAssertFalse(AppSettings(
                translationEngine: engine,
                translationBaseURL: "https://example.com",
                translationModel: "model",
                translationAuthToken: ""
            ).isTranslationConfigured)
            XCTAssertTrue(AppSettings(
                translationEngine: engine,
                translationBaseURL: "https://example.com",
                translationModel: "model",
                translationAuthToken: "token"
            ).isTranslationConfigured)
        }
    }

    func testAPICompatibleEnginesNeedConfigurationWhenCloudFieldsAreMissing() {
        let cloudEngines: [TranslationEngine] = [.anthropicCompatible, .openAICompatible]

        for engine in cloudEngines {
            XCTAssertEqual(readinessIssues(for: AppSettings(
                translationEngine: engine,
                translationBaseURL: "",
                translationModel: "model",
                translationAuthToken: "token"
            )), [.needsConfiguration])
            XCTAssertEqual(readinessIssues(for: AppSettings(
                translationEngine: engine,
                translationBaseURL: "https://example.com",
                translationModel: "",
                translationAuthToken: "token"
            )), [.needsConfiguration])
            XCTAssertEqual(readinessIssues(for: AppSettings(
                translationEngine: engine,
                translationBaseURL: "https://example.com",
                translationModel: "model",
                translationAuthToken: ""
            )), [.needsConfiguration])
        }
    }

    func testAPICompatibleEnginesAreReadyWhenCloudFieldsAreComplete() {
        let cloudEngines: [TranslationEngine] = [.anthropicCompatible, .openAICompatible]

        for engine in cloudEngines {
            let readiness = AppSettings(
                translationEngine: engine,
                translationBaseURL: "https://example.com",
                translationModel: "model",
                translationAuthToken: "token"
            ).translationReadiness()

            XCTAssertTrue(readiness.isReady, "\(engine.rawValue) should be ready with complete cloud fields")
            XCTAssertTrue(readiness.issues.isEmpty)
        }
    }

    func testAppleTranslationEnginesDoNotNeedTokenButRequireRuntimeLanguageReadiness() {
        let engines: [TranslationEngine] = [
            .appleTranslationLowLatency,
            .appleTranslationHighFidelity
        ]

        for engine in engines {
            let readiness = AppSettings(
                translationEngine: engine,
                translationBaseURL: "",
                translationModel: "",
                translationAuthToken: ""
            ).translationReadiness(context: TranslationContext(sourceLanguage: "en", targetLanguage: "zh-Hans"))

            XCTAssertFalse(readiness.isReady, "\(engine.rawValue) should require runtime language readiness")
            XCTAssertEqual(readiness.issues.map(\.kind), [.needsRuntimeVerification, .needsLanguageDownload])
        }
    }

    func testAppleTranslationReadinessRejectsMissingTargetLanguage() {
        let readiness = AppSettings(
            translationEngine: .appleTranslationLowLatency,
            translationBaseURL: "",
            translationModel: "",
            translationAuthToken: ""
        ).translationReadiness(context: TranslationContext(sourceLanguage: "en", targetLanguage: " "))

        XCTAssertFalse(readiness.isReady)
        XCTAssertEqual(readiness.issues.map(\.kind), [.needsRuntimeVerification, .unsupportedLanguagePair])
    }

    func testDirectLLMMessagePathStillBlocksAppleTranslationAndUsesContext() async throws {
        let settings = AppSettings(
            translationEngine: .appleTranslationLowLatency,
            translationBaseURL: "",
            translationModel: "",
            translationAuthToken: ""
        )

        do {
            _ = try await sendConfiguredMessage(
                settings: settings,
                system: nil,
                userContent: "1|hello",
                maxTokens: 128,
                context: TranslationContext(sourceLanguage: "en", targetLanguage: " ")
            )
            XCTFail("Direct LLM message path should not run Apple Translation engines.")
        } catch MoongateError.translateFailed(let message) {
            XCTAssertTrue(message.contains("当前语言组合暂不支持。"))
        }
    }

    func testListTranslationModelsRejectsAppleEngineBeforeCloudValidationOrFetch() async throws {
        ModelListURLProtocol.reset()
        URLProtocol.registerClass(ModelListURLProtocol.self)
        defer { URLProtocol.unregisterClass(ModelListURLProtocol.self) }

        let appleEngines: [TranslationEngine] = [
            .appleTranslationLowLatency,
            .appleTranslationHighFidelity,
            .appleFoundationOnDevice,
            .appleFoundationPCC,
            .appleFoundationCloudPro
        ]

        for engine in appleEngines {
            let settings = AppSettings(
                translationEngine: engine,
                translationBaseURL: "https://models.example.invalid",
                translationModel: "unused-model",
                translationAuthToken: "unused-token"
            )
            do {
                _ = try await listTranslationModels(settings: settings)
                XCTFail("Apple engines should not use the cloud model-list endpoint.")
            } catch MoongateError.translateFailed(let message) {
                XCTAssertTrue(message.contains("不支持拉取云端模型列表"))
                XCTAssertFalse(message.contains("API 凭证"))
                XCTAssertFalse(message.contains("服务地址"))
                XCTAssertFalse(message.contains("模型名称"))
            }
        }
        XCTAssertEqual(ModelListURLProtocol.requestCount(), 0)
    }

    func testAppleFoundationOnDeviceReadinessIsBlockedWhenRuntimeModelAvailabilityIsUnknown() {
        let readiness = AppSettings(
            translationEngine: .appleFoundationOnDevice,
            translationBaseURL: "",
            translationModel: "",
            translationAuthToken: ""
        ).translationReadiness(context: TranslationContext(sourceLanguage: "en", targetLanguage: "zh-Hans"))

        XCTAssertFalse(readiness.isReady)
        XCTAssertEqual(readiness.issues.map(\.kind), [.appleIntelligenceUnavailable, .modelUnavailable])
    }

    func testAppleFoundationCloudEnginesStayBlockedUntilPublicRuntimeIsAvailable() {
        let engines: [TranslationEngine] = [
            .appleFoundationPCC,
            .appleFoundationCloudPro
        ]

        for engine in engines {
            let readiness = AppSettings(
                translationEngine: engine,
                translationBaseURL: "",
                translationModel: "",
                translationAuthToken: ""
            ).translationReadiness()

            XCTAssertFalse(readiness.isReady, "\(engine.rawValue) should remain gated")
            XCTAssertEqual(readiness.issues.map(\.kind), [.pccUnavailable])
            XCTAssertNil(engine.legacyProvider)
            XCTAssertFalse(engine.requiresCloudConfiguration)
        }
    }

    func testAppleFoundationCloudProReadinessUsesCloudProSpecificCopy() {
        let readiness = AppSettings(
            translationEngine: .appleFoundationCloudPro,
            translationBaseURL: "",
            translationModel: "",
            translationAuthToken: ""
        ).translationReadiness()
        let message = readiness.issues.first?.message ?? ""

        XCTAssertFalse(readiness.isReady)
        XCTAssertEqual(readiness.issues.map(\.kind), [.pccUnavailable])
        XCTAssertTrue(message.contains("Cloud Pro") || message.contains("云端 Pro"))
        XCTAssertFalse(message.contains("Private Cloud Compute"))
    }

    func testDefaultRuntimeReadinessMatchesStaticFallback() async {
        let contexts = [
            TranslationContext(sourceLanguage: "en", targetLanguage: "zh-Hans"),
            TranslationContext(sourceLanguage: "en", targetLanguage: " ")
        ]
        let settingsCases = [
            AppSettings(
                translationEngine: .anthropicCompatible,
                translationBaseURL: "",
                translationModel: "model",
                translationAuthToken: "token"
            ),
            AppSettings(
                translationEngine: .openAICompatible,
                translationBaseURL: "https://example.com",
                translationModel: "model",
                translationAuthToken: "token"
            ),
            AppSettings(
                translationEngine: .appleTranslationLowLatency,
                translationBaseURL: "",
                translationModel: "",
                translationAuthToken: ""
            ),
            AppSettings(
                translationEngine: .appleFoundationOnDevice,
                translationBaseURL: "",
                translationModel: "",
                translationAuthToken: ""
            ),
            AppSettings(
                translationEngine: .appleFoundationPCC,
                translationBaseURL: "",
                translationModel: "",
                translationAuthToken: ""
            ),
            AppSettings(
                translationEngine: .appleFoundationCloudPro,
                translationBaseURL: "",
                translationModel: "",
                translationAuthToken: ""
            )
        ]

        for settings in settingsCases {
            for context in contexts {
                let runtimeReadiness = await settings.translationRuntimeReadiness(context: context)

                XCTAssertEqual(
                    runtimeReadiness,
                    settings.translationReadiness(context: context),
                    "\(settings.translationEngine.rawValue) should default to conservative static readiness"
                )
            }
        }
    }

    func testRuntimeReadinessUsesInjectedEvaluatorRequest() async {
        let settings = AppSettings(
            translationEngine: .appleTranslationLowLatency,
            translationBaseURL: "",
            translationModel: "",
            translationAuthToken: ""
        )
        let context = TranslationContext(sourceLanguage: "en", targetLanguage: "ja")
        let evaluator = FakeTranslationRuntimeReadinessEvaluator { request in
            guard request.engine == .appleTranslationLowLatency,
                  request.context == context,
                  request.isCloudConfigurationComplete else {
                return TranslationReadiness(issues: [
                    TranslationReadinessIssue(kind: .needsRuntimeVerification)
                ])
            }
            return .ready
        }

        let runtimeReadiness = await settings.translationRuntimeReadiness(
            context: context,
            evaluator: evaluator
        )

        XCTAssertTrue(runtimeReadiness.isReady)
    }

    func testSettingLegacyProviderKeepsEngineDispatchInSync() {
        var settings = AppSettings(
            translationProvider: .anthropic,
            translationEngine: .anthropicCompatible,
            translationBaseURL: TranslationProvider.anthropic.defaultBaseURL,
            translationModel: "claude-haiku-4-5",
            translationAuthToken: "token"
        )

        settings.setTranslationProvider(.openai)

        XCTAssertEqual(settings.translationProvider, .openai)
        XCTAssertEqual(settings.translationEngine, .openAICompatible)
        XCTAssertEqual(settings.translationBaseURL, TranslationProvider.openai.defaultBaseURL)

        settings.setTranslationProvider(.anthropic)

        XCTAssertEqual(settings.translationProvider, .anthropic)
        XCTAssertEqual(settings.translationEngine, .anthropicCompatible)
        XCTAssertEqual(settings.translationBaseURL, TranslationProvider.anthropic.defaultBaseURL)
    }

    func testSettingProviderDoesNotOverwriteCustomGatewayBaseURL() {
        var settings = AppSettings(
            translationProvider: .anthropic,
            translationEngine: .anthropicCompatible,
            translationBaseURL: "https://gateway.example.com",
            translationModel: "deepseek-chat",
            translationAuthToken: "token"
        )

        settings.setTranslationProvider(.openai)

        XCTAssertEqual(settings.translationProvider, .openai)
        XCTAssertEqual(settings.translationEngine, .openAICompatible)
        XCTAssertEqual(settings.translationBaseURL, "https://gateway.example.com")
    }

    func testSavingSettingsCreatesMissingFileWithOwnerOnlyPermissions() throws {
        #if os(Windows)
        throw XCTSkip("POSIX permissions are not available on Windows.")
        #else
        let directory = try makeTemporarySettingsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let settingsURL = directory.appendingPathComponent("settings.json")
        try AppSettings(translationAuthToken: "TEST_SECRET_VALUE_DO_NOT_STORE")
            .save(supportDirectory: directory, settingsFileURL: settingsURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: settingsURL.path))
        XCTAssertEqual(try filePermissions(at: settingsURL) & 0o777, 0o600)
        let loaded = try JSONDecoder().decode(AppSettings.self, from: Data(contentsOf: settingsURL))
        XCTAssertEqual(loaded.translationAuthToken, "TEST_SECRET_VALUE_DO_NOT_STORE")
        #endif
    }

    func testSavingSettingsTightensExistingLoosePermissions() throws {
        #if os(Windows)
        throw XCTSkip("POSIX permissions are not available on Windows.")
        #else
        let directory = try makeTemporarySettingsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let settingsURL = directory.appendingPathComponent("settings.json")
        FileManager.default.createFile(
            atPath: settingsURL.path,
            contents: Data("{}".utf8),
            attributes: [.posixPermissions: 0o644]
        )
        try AppSettings(translationAuthToken: "TEST_SECRET_VALUE_DO_NOT_STORE")
            .save(supportDirectory: directory, settingsFileURL: settingsURL)

        XCTAssertEqual(try filePermissions(at: settingsURL) & 0o777, 0o600)
        let loaded = try JSONDecoder().decode(AppSettings.self, from: Data(contentsOf: settingsURL))
        XCTAssertEqual(loaded.translationAuthToken, "TEST_SECRET_VALUE_DO_NOT_STORE")
        #endif
    }

    func testLoadingSettingsMigratesLegacySupportDirectoryAndCookies() throws {
        #if os(Windows)
        throw XCTSkip("POSIX file permissions are not available on Windows.")
        #else
        let root = try makeTemporarySettingsDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let currentDirectory = root.appendingPathComponent("月之门", isDirectory: true)
        let legacyDirectory = root.appendingPathComponent("视频下载器", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        let legacySettingsURL = legacyDirectory.appendingPathComponent("settings.json")
        let legacyCookieURL = legacyDirectory.appendingPathComponent("cookies.txt")
        try AppSettings(
            translationEngine: .openAICompatible,
            translationBaseURL: "https://api.openai.com",
            translationModel: "gpt-5-mini",
            translationAuthToken: "TEST_SECRET_VALUE_DO_NOT_STORE"
        ).save(supportDirectory: legacyDirectory, settingsFileURL: legacySettingsURL)
        try Data("# Netscape HTTP Cookie File\n".utf8).write(to: legacyCookieURL)

        let loaded = AppSettings.load(
            supportDirectory: currentDirectory,
            legacySupportDirectory: legacyDirectory
        )

        XCTAssertEqual(loaded.translationEngine, .openAICompatible)
        XCTAssertEqual(loaded.translationAuthToken, "TEST_SECRET_VALUE_DO_NOT_STORE")
        XCTAssertTrue(FileManager.default.fileExists(atPath: currentDirectory.appendingPathComponent("settings.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: currentDirectory.appendingPathComponent("cookies.txt").path))
        XCTAssertEqual(try filePermissions(at: currentDirectory.appendingPathComponent("settings.json")) & 0o777, 0o600)
        XCTAssertEqual(try filePermissions(at: currentDirectory.appendingPathComponent("cookies.txt")) & 0o777, 0o600)
        #endif
    }

    func testLoadingSettingsMigratesLegacyCookiesEvenWhenLegacySettingsAbsent() throws {
        #if os(Windows)
        throw XCTSkip("POSIX file permissions are not available on Windows.")
        #else
        // 只登录过站点、从没改过设置的用户：旧目录有 cookies.txt 但没有 settings.json。
        // 改名（视频下载器→月之门）后登录态必须照样迁移，不能被 settings 读取失败连带丢弃。
        let root = try makeTemporarySettingsDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let currentDirectory = root.appendingPathComponent("月之门", isDirectory: true)
        let legacyDirectory = root.appendingPathComponent("视频下载器", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        let legacyCookieURL = legacyDirectory.appendingPathComponent("cookies.txt")
        try Data("# Netscape HTTP Cookie File\n".utf8).write(to: legacyCookieURL)

        let loaded = AppSettings.load(
            supportDirectory: currentDirectory,
            legacySupportDirectory: legacyDirectory
        )

        // settings 缺失：回落到默认值，但 cookies 仍被迁移。
        XCTAssertEqual(loaded.translationEngine, .anthropicCompatible)
        let migratedCookieURL = currentDirectory.appendingPathComponent("cookies.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: migratedCookieURL.path))
        XCTAssertEqual(try filePermissions(at: migratedCookieURL) & 0o777, 0o600)
        XCTAssertFalse(FileManager.default.fileExists(atPath: currentDirectory.appendingPathComponent("settings.json").path))
        #endif
    }

    func testAppleEngineSurvivesCodableRoundTrip() throws {
        // Apple 本地引擎 legacyProvider == nil；decode 路径会重算 provider，
        // 必须保证 translationEngine 本身原样回放，且不被当成「未配置」。
        for engine in [TranslationEngine.appleTranslationLowLatency, .appleFoundationOnDevice] {
            let original = AppSettings(
                translationEngine: engine,
                translationBaseURL: "",
                translationModel: "",
                translationAuthToken: ""
            )
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
            XCTAssertEqual(decoded.translationEngine, engine)
            XCTAssertTrue(decoded.isTranslationConfigured, "Apple 本地引擎不应要求填 token/model")
        }
    }

    func testLegacySettingsSeedDefaultAIConfigSoTranslationBehaviorIsUnchanged() throws {
        // 旧 settings.json 只有 translation* 字段、没有 ai*/summary*/follow 标志。
        // 解码后「有效翻译配置」必须等于旧 translation 配置，行为零回归。
        let legacyJSON = """
        {
          "translationProvider": "openai",
          "translationEngine": "openAICompatible",
          "translationBaseURL": "https://gateway.example.com",
          "translationModel": "gpt-5-mini",
          "translationAuthToken": "TEST_SECRET_VALUE_DO_NOT_STORE",
          "subtitleStyle": "bilingual"
        }
        """
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(legacyJSON.utf8))

        XCTAssertTrue(decoded.translationFollowsDefault)
        XCTAssertTrue(decoded.summaryFollowsDefault)
        let effective = decoded.effectiveTranslationConfig
        XCTAssertEqual(effective.engine, .openAICompatible)
        XCTAssertEqual(effective.baseURL, "https://gateway.example.com")
        XCTAssertEqual(effective.model, "gpt-5-mini")
        XCTAssertEqual(effective.authToken, "TEST_SECRET_VALUE_DO_NOT_STORE")
        XCTAssertTrue(decoded.isTranslationConfigured)
    }

    func testTranslationOverrideSlotIsUsedWhenNotFollowingDefault() {
        var settings = AppSettings(
            aiEngine: .anthropicCompatible,
            aiBaseURL: "https://default.example.com",
            aiModel: "claude",
            aiAuthToken: "DEFAULT_TOKEN"
        )
        settings.translationFollowsDefault = false
        settings.translationEngine = .openAICompatible
        settings.translationBaseURL = "https://translate.example.com"
        settings.translationModel = "gpt-5-mini"
        settings.translationAuthToken = "TRANSLATE_TOKEN"

        let effective = settings.effectiveTranslationConfig
        XCTAssertEqual(effective.engine, .openAICompatible)
        XCTAssertEqual(effective.baseURL, "https://translate.example.com")
        XCTAssertEqual(effective.model, "gpt-5-mini")
        XCTAssertEqual(effective.authToken, "TRANSLATE_TOKEN")

        settings.translationFollowsDefault = true
        XCTAssertEqual(settings.effectiveTranslationConfig.baseURL, "https://default.example.com")
    }

    func testSummaryReadinessRejectsAppleTranslationEngine() {
        let appleSettings = AppSettings(aiEngine: .appleTranslationLowLatency)
        XCTAssertFalse(appleSettings.isSummaryConfigured)
        XCTAssertFalse(appleSettings.effectiveSummaryConfig.engine.canGenerateText)

        let cloudSettings = AppSettings(
            aiEngine: .anthropicCompatible,
            aiBaseURL: "https://api.example.com",
            aiModel: "claude-haiku",
            aiAuthToken: "TOKEN"
        )
        XCTAssertTrue(cloudSettings.isSummaryConfigured)

        let onDevice = AppSettings(aiEngine: .appleFoundationOnDevice)
        XCTAssertTrue(onDevice.isSummaryConfigured)
    }

    func testSummaryOverrideSlotSurvivesCodableRoundTrip() throws {
        var settings = AppSettings(
            aiEngine: .anthropicCompatible,
            aiBaseURL: "https://default.example.com",
            aiModel: "claude",
            aiAuthToken: "DEFAULT"
        )
        settings.summaryFollowsDefault = false
        settings.summaryEngine = .openAICompatible
        settings.summaryBaseURL = "https://summary.example.com"
        settings.summaryModel = "gpt-5"
        settings.summaryAuthToken = "SUMMARY_TOKEN"

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertFalse(decoded.summaryFollowsDefault)
        let effective = decoded.effectiveSummaryConfig
        XCTAssertEqual(effective.engine, .openAICompatible)
        XCTAssertEqual(effective.baseURL, "https://summary.example.com")
        XCTAssertEqual(effective.model, "gpt-5")
        XCTAssertEqual(effective.authToken, "SUMMARY_TOKEN")
    }

    func testSummarizeVideoRejectsTextIncapableEngineWithoutNetwork() async {
        // Apple Translation 不能生成文本：summarizeVideo 必须在发任何请求前抛错。
        let config = LLMEndpointConfig(
            engine: .appleTranslationLowLatency,
            baseURL: "https://unused.example.com",
            model: "",
            authToken: ""
        )
        do {
            _ = try await summarizeVideo(
                title: "测试视频",
                uploader: "频道",
                durationText: "3:00",
                source: "一些字幕文本",
                config: config,
                settings: AppSettings()
            )
            XCTFail("Apple Translation 引擎不应能做总结")
        } catch let MoongateError.translateFailed(message) {
            XCTAssertTrue(message.contains("只能翻译") || message.contains("生成"))
        } catch {
            XCTFail("应抛 translateFailed，实际：\(error)")
        }
    }

    func testCleanCuesMergesRollingCaptionOverlap() {
        // 样式 A：时间戳大幅重叠的滚动碎句应被去重叠并按句合并成更少的条目。
        let raw = """
        1
        00:00:00,000 --> 00:00:03,000
        Hello there

        2
        00:00:01,000 --> 00:00:04,000
        Hello there how

        3
        00:00:02,000 --> 00:00:05,000
        Hello there how are you.
        """
        let parsed = parseSRT(raw)
        XCTAssertEqual(parsed.count, 3)
        let cleaned = cleanCues(parsed)
        XCTAssertLessThan(cleaned.count, parsed.count, "滚动重叠碎句应被合并")
        XCTAssertTrue(
            cleaned.contains { $0.text.contains("how are you") },
            "合并结果应保留完整句尾"
        )
    }


    func testTranslationContextDefaultTargetLanguageIsStable() {
        let context = TranslationContext()

        XCTAssertNil(context.sourceLanguage)
        XCTAssertEqual(context.targetLanguage, "zh-Hans")
    }

    func testTranslationContextCanInferSourceLanguageFromSubtitleFilename() {
        XCTAssertEqual(
            TranslationContext.sourceLanguageIdentifier(fromSubtitleFile: URL(fileURLWithPath: "/tmp/video.en-US.srt")),
            "en-us"
        )
        XCTAssertEqual(
            TranslationContext.sourceLanguageIdentifier(fromSubtitleFile: URL(fileURLWithPath: "/tmp/video.zh-Hans.srt")),
            "zh-hans"
        )
        XCTAssertNil(TranslationContext.sourceLanguageIdentifier(fromSubtitleFile: URL(fileURLWithPath: "/tmp/video.srt")))
    }

    func testSubtitleTranslatorConvenienceMethodCallsCoreMethodWithoutControlToken() async throws {
        let recorder = TranslationControlRecorder()
        let translator: any SubtitleTranslator = RecordingSubtitleTranslator(recorder: recorder)
        let source = URL(fileURLWithPath: "/tmp/source.en.srt")

        let output = try await translator.translate(
            srtFile: source,
            style: .bilingual
        ) { _ in }

        let controlWasNil = await recorder.controlWasNil()
        let contexts = await recorder.contexts()
        XCTAssertEqual(output, source)
        XCTAssertEqual(controlWasNil, [true])
        XCTAssertEqual(contexts, [TranslationContext()])
    }

    func testSubtitleTranslatorProtocolReceivesTranslationContext() async throws {
        let recorder = TranslationControlRecorder()
        let translator: any SubtitleTranslator = RecordingSubtitleTranslator(recorder: recorder)
        let context = TranslationContext(sourceLanguage: "en", targetLanguage: "zh-Hans")
        let source = URL(fileURLWithPath: "/tmp/source.en.srt")

        let output = try await translator.translate(
            srtFile: source,
            style: .bilingual,
            context: context
        ) { _ in }

        let contexts = await recorder.contexts()
        XCTAssertEqual(output, source)
        XCTAssertEqual(contexts, [context])
    }

    func testSubtitleTranslatorContextConvenienceKeepsControlTokenNil() async throws {
        let recorder = TranslationControlRecorder()
        let translator: any SubtitleTranslator = RecordingSubtitleTranslator(recorder: recorder)
        let context = TranslationContext(sourceLanguage: "en", targetLanguage: "zh-Hans")
        let source = URL(fileURLWithPath: "/tmp/source.en.srt")

        let output = try await translator.translate(
            srtFile: source,
            style: .chineseOnly,
            context: context
        ) { _ in }

        let controlWasNil = await recorder.controlWasNil()
        let contexts = await recorder.contexts()
        XCTAssertEqual(output, source)
        XCTAssertEqual(controlWasNil, [true])
        XCTAssertEqual(contexts, [context])
    }

    func testContextualSubtitleTranslatorOldControlOverloadUsesEmptyContext() async throws {
        let recorder = TranslationControlRecorder()
        let translator: any SubtitleTranslator = RecordingSubtitleTranslator(recorder: recorder)
        let control = TaskControlToken()
        let source = URL(fileURLWithPath: "/tmp/source.en.srt")

        let output = try await translator.translate(
            srtFile: source,
            style: .bilingual,
            control: control
        ) { _ in }

        let controlWasNil = await recorder.controlWasNil()
        let contexts = await recorder.contexts()
        XCTAssertEqual(output, source)
        XCTAssertEqual(controlWasNil, [false])
        XCTAssertEqual(contexts, [TranslationContext()])
    }

    func testLegacySubtitleTranslatorOldControlOverloadStillCompilesAndRuns() async throws {
        let recorder = TranslationControlRecorder()
        let translator: any SubtitleTranslator = LegacyRecordingSubtitleTranslator(recorder: recorder)
        let control = TaskControlToken()
        let source = URL(fileURLWithPath: "/tmp/source.en.srt")

        let output = try await translator.translate(
            srtFile: source,
            style: .chineseOnly,
            control: control
        ) { _ in }

        let controlWasNil = await recorder.controlWasNil()
        let contexts = await recorder.contexts()
        XCTAssertEqual(output, source)
        XCTAssertEqual(controlWasNil, [false])
        XCTAssertEqual(contexts, [])
    }

    func testLegacySubtitleTranslatorContextOverloadFallsBackToOldControlSignature() async throws {
        let recorder = TranslationControlRecorder()
        let translator: any SubtitleTranslator = LegacyRecordingSubtitleTranslator(recorder: recorder)
        let context = TranslationContext(sourceLanguage: "en", targetLanguage: "zh-Hans")
        let control = TaskControlToken()
        let source = URL(fileURLWithPath: "/tmp/source.en.srt")

        let output = try await translator.translate(
            srtFile: source,
            style: .chineseOnly,
            context: context,
            control: control
        ) { _ in }

        let controlWasNil = await recorder.controlWasNil()
        let contexts = await recorder.contexts()
        XCTAssertEqual(output, source)
        XCTAssertEqual(controlWasNil, [false])
        XCTAssertEqual(contexts, [])
    }

    func testTranslationEngineDisplayMetadataCoversAllEngines() {
        let expectedLabels: [TranslationEngine: String] = [
            .anthropicCompatible: "Anthropic-compatible",
            .openAICompatible: "OpenAI-compatible",
            .appleTranslationLowLatency: "Apple Translation（低延迟）",
            .appleTranslationHighFidelity: "Apple Translation（高保真）",
            .appleFoundationOnDevice: "Apple Intelligence（本地）",
            .appleFoundationPCC: "Apple Private Cloud Compute（云端）",
            .appleFoundationCloudPro: "Apple Intelligence Cloud Pro（云端 Pro）"
        ]

        XCTAssertEqual(Set(expectedLabels.keys), Set(TranslationEngine.allCases))
        for engine in TranslationEngine.allCases {
            XCTAssertEqual(engine.displayName, expectedLabels[engine])
            XCTAssertFalse(engine.readinessGuidance.isEmpty)
        }
    }

    func testTranslationEngineReadinessGuidanceReflectsConditionalAppleRuntimeSupport() {
        XCTAssertEqual(
            TranslationEngine.appleTranslationLowLatency.readinessGuidance,
            "运行前会检测系统翻译能力、语言组合和目标语言包；就绪后可使用系统 Apple Translation。"
        )
        XCTAssertEqual(
            TranslationEngine.appleTranslationHighFidelity.readinessGuidance,
            "运行前会检测系统翻译能力、高保真路径和语言包；就绪后可使用系统 Apple Translation。"
        )
        XCTAssertEqual(
            TranslationEngine.appleFoundationOnDevice.readinessGuidance,
            "运行前会检测设备是否支持 Apple Intelligence、本地模型是否可用；就绪后使用本地模型。"
        )
        XCTAssertEqual(
            TranslationEngine.appleFoundationPCC.readinessGuidance,
            "当前不可运行：Private Cloud Compute 需要公开运行时接口、申请资格、网络和配额。"
        )
        XCTAssertEqual(
            TranslationEngine.appleFoundationCloudPro.readinessGuidance,
            "当前不可运行：Apple Intelligence Cloud Pro 需要公开运行时接口、申请资格、网络和配额。"
        )
    }

    func testTranslationEngineCLIAliasesResolveSupportedValues() {
        let expectedAliases: [String: TranslationEngine] = [
            "anthropic-compatible": .anthropicCompatible,
            "openai-compatible": .openAICompatible,
            "apple-translation": .appleTranslationLowLatency,
            "apple-translation-high-fidelity": .appleTranslationHighFidelity,
            "foundation-on-device": .appleFoundationOnDevice,
            "pcc": .appleFoundationPCC,
            "cloud-pro": .appleFoundationCloudPro
        ]

        XCTAssertEqual(Set(expectedAliases.keys), Set(TranslationEngine.supportedCLIValues))
        for (alias, engine) in expectedAliases {
        XCTAssertEqual(TranslationEngine(cliValue: alias), engine)
        }
        XCTAssertEqual(TranslationEngine(cliValue: "apple-foundation-cloud-pro"), .appleFoundationCloudPro)
        XCTAssertNil(TranslationEngine(cliValue: "apple-cloud"))
    }

    func testReadinessIssueExposesStableKindAndDisplayMessage() {
        let issue = TranslationReadinessIssue(kind: .needsLanguageDownload, message: "需要先下载语言包。")

        XCTAssertEqual(issue.kind, .needsLanguageDownload)
        XCTAssertFalse(issue.message.isEmpty)
    }

    func testAppleTranslationSetupGuidanceExplainsRuntimeVerificationAndLanguageDownload() {
        let guidance = AppleTranslationSetupGuidance.make(
            engine: .appleTranslationLowLatency,
            readiness: TranslationReadiness(issues: [
                TranslationReadinessIssue(kind: .needsRuntimeVerification),
                TranslationReadinessIssue(kind: .needsLanguageDownload)
            ])
        )

        XCTAssertEqual(guidance.title, "完成 Apple Translation 设置")
        XCTAssertEqual(guidance.actions.map(\.kind), [.refreshReadiness, .openLanguageSettings])
        XCTAssertTrue(guidance.steps.contains("点“重新检测”，确认当前系统支持 Apple Translation。"))
        XCTAssertTrue(guidance.steps.contains("到系统设置下载需要的翻译语言；App 不会自动下载语言包。"))
    }

    func testAppleTranslationSetupGuidanceExplainsUnsupportedLanguagePair() {
        let guidance = AppleTranslationSetupGuidance.make(
            engine: .appleTranslationHighFidelity,
            readiness: TranslationReadiness(issues: [
                TranslationReadinessIssue(kind: .unsupportedLanguagePair)
            ])
        )

        XCTAssertEqual(guidance.actions.map(\.kind), [.chooseDifferentEngine])
        XCTAssertTrue(guidance.steps.contains("当前源语言和目标语言组合不支持，请换一个语言组合或改用 API 兼容引擎。"))
    }

    func testAppleTranslationSetupGuidanceExplainsUnavailableExecutionPath() throws {
        let guidance = AppleTranslationSetupGuidance.make(
            engine: .appleTranslationLowLatency,
            readiness: TranslationReadiness(issues: [
                TranslationReadinessIssue(kind: .needsExecutionAdapter),
                TranslationReadinessIssue(kind: .needsExecutionAdapter)
            ])
        )
        let data = try JSONEncoder().encode(guidance)
        let encoded = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertEqual(guidance.actions.map(\.kind), [.chooseDifferentEngine])
        XCTAssertTrue(guidance.steps.contains("当前系统能力可能已就绪，但此版本没有可用于该状态的翻译执行路径。"))
        XCTAssertTrue(guidance.steps.contains("请先改用其他可运行的翻译引擎。"))
        XCTAssertFalse(encoded.contains("systemSettingsURL"))
    }

    func testAppleFoundationSetupGuidanceExplainsIntelligenceAndModelReadiness() {
        let guidance = AppleTranslationSetupGuidance.make(
            engine: .appleFoundationOnDevice,
            readiness: TranslationReadiness(issues: [
                TranslationReadinessIssue(kind: .appleIntelligenceUnavailable),
                TranslationReadinessIssue(kind: .modelUnavailable)
            ])
        )

        XCTAssertEqual(guidance.title, "完成本地 Apple Intelligence 设置")
        XCTAssertEqual(guidance.actions.map(\.kind), [.openAppleIntelligenceSettings, .refreshReadiness])
        XCTAssertTrue(guidance.steps.contains("先确认这台 Mac 和当前系统版本支持 Apple Intelligence。"))
        XCTAssertTrue(guidance.steps.contains("到系统设置中启用 Apple Intelligence；系统侧开关由你控制。"))
        XCTAssertTrue(guidance.steps.contains("到系统设置 > Apple Intelligence 与 Siri 查看模型准备状态；App 不会自动下载或替换模型。"))
        XCTAssertTrue(guidance.steps.contains("本机 Apple Intelligence 暂不可用时，可以改用 API 兼容引擎继续翻译。"))
    }

    func testAppleFoundationModelUnavailableGuidanceOpensSettingsBeforeRefresh() {
        let guidance = AppleTranslationSetupGuidance.make(
            engine: .appleFoundationOnDevice,
            readiness: TranslationReadiness(issues: [
                TranslationReadinessIssue(kind: .modelUnavailable)
            ])
        )
        let stepText = guidance.steps.joined(separator: "\n")

        XCTAssertEqual(guidance.actions.map(\.kind), [.openAppleIntelligenceSettings, .refreshReadiness])
        XCTAssertTrue(guidance.steps.contains("到系统设置 > Apple Intelligence 与 Siri 查看模型准备状态；App 不会自动下载或替换模型。"))
        XCTAssertTrue(guidance.steps.contains("本机 Apple Intelligence 暂不可用时，可以改用 API 兼容引擎继续翻译。"))
        XCTAssertFalse(stepText.contains("Private Cloud Compute"))
        XCTAssertFalse(stepText.contains("Cloud Pro"))
        XCTAssertFalse(stepText.contains("云端可运行"))
    }

    func testAppleFoundationUnavailableGuidanceIncludesAPICompatibleFallback() {
        let guidance = AppleTranslationSetupGuidance.make(
            engine: .appleFoundationOnDevice,
            readiness: TranslationReadiness(issues: [
                TranslationReadinessIssue(kind: .appleIntelligenceUnavailable)
            ])
        )

        XCTAssertEqual(guidance.actions.map(\.kind), [.openAppleIntelligenceSettings])
        XCTAssertTrue(guidance.steps.contains("本机 Apple Intelligence 暂不可用时，可以改用 API 兼容引擎继续翻译。"))
    }

    func testAppleFoundationPCCSetupGuidanceStaysUnavailable() {
        let guidance = AppleTranslationSetupGuidance.make(
            engine: .appleFoundationPCC,
            readiness: TranslationReadiness(issues: [
                TranslationReadinessIssue(kind: .pccUnavailable)
            ])
        )

        XCTAssertEqual(guidance.title, "Apple Intelligence 云端暂不可用")
        XCTAssertEqual(guidance.actions.map(\.kind), [.chooseDifferentEngine])
        XCTAssertTrue(guidance.steps.contains("Private Cloud Compute 暂未提供可用于本 App 的公开运行时接口。"))
        XCTAssertTrue(guidance.steps.contains("请先改用 Apple Translation、本地 Apple Intelligence 或 API 兼容引擎。"))
    }

    func testAppleFoundationCloudProSetupGuidanceHasSeparateUnavailableCopy() {
        let guidance = AppleTranslationSetupGuidance.make(
            engine: .appleFoundationCloudPro,
            readiness: TranslationReadiness(issues: [
                TranslationReadinessIssue(kind: .pccUnavailable)
            ])
        )

        XCTAssertEqual(guidance.title, "Apple Intelligence Cloud Pro 云端 Pro 暂不可用")
        XCTAssertEqual(guidance.actions.map(\.kind), [.chooseDifferentEngine])
        XCTAssertTrue(guidance.steps.contains("Apple Intelligence Cloud Pro（云端 Pro）暂未提供可用于本 App 的公开运行时接口。"))
        XCTAssertTrue(guidance.steps.contains("请先改用 Apple Translation、本地 Apple Intelligence 或 API 兼容引擎。"))
    }

    func testAppleCloudSetupGuidanceDoesNotOfferRefreshForRuntimeVerificationIssues() {
        let cases: [(TranslationEngine, String)] = [
            (.appleFoundationPCC, "Private Cloud Compute 暂未提供可用于本 App 的公开运行时接口。"),
            (.appleFoundationCloudPro, "Apple Intelligence Cloud Pro（云端 Pro）暂未提供可用于本 App 的公开运行时接口。")
        ]

        for (engine, unavailableStep) in cases {
            let guidance = AppleTranslationSetupGuidance.make(
                engine: engine,
                readiness: TranslationReadiness(issues: [
                    TranslationReadinessIssue(kind: .needsRuntimeVerification)
                ])
            )
            let steps = guidance.steps.joined(separator: "\n")

            XCTAssertEqual(guidance.actions.map(\.kind), [.chooseDifferentEngine])
            XCTAssertTrue(guidance.steps.contains(unavailableStep))
            XCTAssertTrue(guidance.steps.contains("请先改用 Apple Translation、本地 Apple Intelligence 或 API 兼容引擎。"))
            XCTAssertFalse(steps.contains("重新检测"))
            XCTAssertFalse(steps.contains("是否开放"))
        }
    }

    func testMobileTranslationConfigurationFromSettingsDoesNotExposeAuthToken() throws {
        let settings = AppSettings(
            translationEngine: .openAICompatible,
            translationBaseURL: "https://api.openai.com",
            translationModel: "gpt-5-mini",
            translationAuthToken: "TEST_TRANSLATION_AUTH_VALUE_DO_NOT_STORE"
        )

        let config = MobileTranslationConfiguration(
            engine: settings.translationEngine,
            baseURL: settings.translationBaseURL,
            model: settings.translationModel,
            credential: SecureCredentialReference(service: "translation.openai", account: "default"),
            readiness: settings.isTranslationConfigured ? .ready : TranslationReadiness(issues: [
                TranslationReadinessIssue(kind: .needsConfiguration)
            ])
        )
        let data = try JSONEncoder().encode(config)
        let encoded = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertFalse(encoded.contains(settings.translationAuthToken))
        XCTAssertFalse(encoded.contains("TEST_TRANSLATION_AUTH_VALUE_DO_NOT_STORE"))
    }

    private func decodeSettings(_ json: String) throws -> AppSettings {
        try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
    }

    private func readinessIssues(for settings: AppSettings) -> [TranslationReadinessIssue.Kind] {
        settings.translationReadiness().issues.map(\.kind)
    }

    #if !os(Windows)
    private func makeTemporarySettingsDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("moongate-settings-save-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func filePermissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? Int)
    }
    #endif
}

private struct FakeTranslationRuntimeReadinessEvaluator: TranslationRuntimeReadinessEvaluating {
    var evaluate: @Sendable (TranslationRuntimeReadinessRequest) async -> TranslationReadiness

    func readiness(for request: TranslationRuntimeReadinessRequest) async -> TranslationReadiness {
        await evaluate(request)
    }
}

private actor TranslationControlRecorder {
    private var capturedNilStates: [Bool] = []
    private var capturedContexts: [TranslationContext] = []

    func record(context: TranslationContext, control: TaskControlToken?) {
        capturedContexts.append(context)
        capturedNilStates.append(control == nil)
    }

    func recordLegacy(control: TaskControlToken?) {
        capturedNilStates.append(control == nil)
    }

    func controlWasNil() -> [Bool] {
        capturedNilStates
    }

    func contexts() -> [TranslationContext] {
        capturedContexts
    }
}

private struct RecordingSubtitleTranslator: ContextualSubtitleTranslator {
    let recorder: TranslationControlRecorder

    func translate(
        srtFile: URL,
        style: SubtitleStyle,
        control: TaskControlToken?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        await recorder.record(context: TranslationContext(), control: control)
        progress(1)
        return srtFile
    }

    func translate(
        srtFile: URL,
        style: SubtitleStyle,
        context: TranslationContext,
        control: TaskControlToken?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        await recorder.record(context: context, control: control)
        progress(1)
        return srtFile
    }
}

private struct LegacyRecordingSubtitleTranslator: SubtitleTranslator {
    let recorder: TranslationControlRecorder

    func translate(
        srtFile: URL,
        style: SubtitleStyle,
        control: TaskControlToken?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        await recorder.recordLegacy(control: control)
        progress(1)
        return srtFile
    }
}

private final class ModelListURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var requests: [URLRequest] = []

    static func reset() {
        lock.lock()
        requests = []
        lock.unlock()
    }

    static func requestCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.count
    }

    override class func canInit(with request: URLRequest) -> Bool {
        lock.lock()
        requests.append(request)
        lock.unlock()
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url ?? URL(fileURLWithPath: "/"),
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"data":[{"id":"should-not-fetch"}]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
