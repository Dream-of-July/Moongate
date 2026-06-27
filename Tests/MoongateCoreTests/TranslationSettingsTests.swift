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

    func testSmartTranslationPromptSettingDefaultsOffAndRoundTrips() throws {
        XCTAssertFalse(AppSettings().smartTranslationPromptsEnabled)
        let settings = try decodeSettings("""
        {
          "smartTranslationPromptsEnabled": true
        }
        """)
        XCTAssertTrue(settings.smartTranslationPromptsEnabled)

        let encoded = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: encoded)
        XCTAssertTrue(decoded.smartTranslationPromptsEnabled)
    }

    func testLocalASRSettingsDefaultOffAndRoundTripThroughJSON() throws {
        let fresh = AppSettings()
        XCTAssertFalse(fresh.localASREnabled)
        XCTAssertEqual(fresh.localASRRuntimePath, "")
        XCTAssertEqual(fresh.localASRModelPath, "")
        XCTAssertEqual(fresh.localASRModelID, "")
        XCTAssertFalse(fresh.localASRPreciseModeEnabled)
        XCTAssertEqual(fresh.localASRSidecarRuntimePath, "")
        XCTAssertEqual(fresh.localASRSidecarModelPath, "")
        XCTAssertFalse(fresh.isLocalASRSidecarConfigured)

        let settings = AppSettings(
            localASREnabled: true,
            localASRRuntimePath: " /opt/moongate/bin/whisper-cli\n",
            localASRModelPath: "\n/Users/me/Library/Application Support/Moongate/asr/ggml-small.bin ",
            localASRModelID: " whisper.cpp:small-q5_1\n",
            localASRPreciseModeEnabled: true,
            localASRSidecarRuntimePath: " /opt/moongate/bin/faster-whisper-sidecar\n",
            localASRSidecarModelPath: "\n/Users/me/Models/faster-whisper-small "
        )
        let encoded = try JSONEncoder().encode(settings)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["localASREnabled"] as? Bool, true)
        XCTAssertEqual(object["localASRRuntimePath"] as? String, "/opt/moongate/bin/whisper-cli")
        XCTAssertEqual(object["localASRModelPath"] as? String, "/Users/me/Library/Application Support/Moongate/asr/ggml-small.bin")
        XCTAssertEqual(object["localASRModelID"] as? String, "whisper.cpp:small-q5_1")
        XCTAssertEqual(object["localASRPreciseModeEnabled"] as? Bool, true)
        XCTAssertEqual(object["localASRSidecarRuntimePath"] as? String, "/opt/moongate/bin/faster-whisper-sidecar")
        XCTAssertEqual(object["localASRSidecarModelPath"] as? String, "/Users/me/Models/faster-whisper-small")

        let decoded = try JSONDecoder().decode(AppSettings.self, from: encoded)
        XCTAssertTrue(decoded.localASREnabled)
        XCTAssertEqual(decoded.localASRRuntimePath, "/opt/moongate/bin/whisper-cli")
        XCTAssertEqual(decoded.localASRModelPath, "/Users/me/Library/Application Support/Moongate/asr/ggml-small.bin")
        XCTAssertEqual(decoded.localASRModelID, "whisper.cpp:small-q5_1")
        XCTAssertTrue(decoded.localASRPreciseModeEnabled)
        XCTAssertEqual(decoded.localASRSidecarRuntimePath, "/opt/moongate/bin/faster-whisper-sidecar")
        XCTAssertEqual(decoded.localASRSidecarModelPath, "/Users/me/Models/faster-whisper-small")
        XCTAssertTrue(decoded.isLocalASRSidecarConfigured)
    }

    func testCloudASRSettingsDefaultOffRequireConsentAndRoundTrip() throws {
        let fresh = AppSettings()
        XCTAssertFalse(fresh.cloudASREnabled)
        XCTAssertFalse(fresh.cloudASRConsentAccepted)
        XCTAssertEqual(fresh.cloudASRBaseURL, "https://api.openai.com")
        XCTAssertEqual(fresh.cloudASRModel, "whisper-1")
        XCTAssertEqual(fresh.cloudASRAuthToken, "")
        XCTAssertFalse(fresh.isCloudASRConfigured)
        XCTAssertFalse(fresh.cloudASRModelRequiresAlignment)

        let settings = AppSettings(
            cloudASREnabled: true,
            cloudASRConsentAccepted: true,
            cloudASRBaseURL: " https://api.openai.com/v1\n",
            cloudASRModel: "\nwhisper-1 ",
            cloudASRAuthToken: "token"
        )
        XCTAssertTrue(settings.isCloudASRConfigured)
        XCTAssertFalse(settings.cloudASRModelRequiresAlignment)

        let alignmentOnly = AppSettings(
            cloudASREnabled: true,
            cloudASRConsentAccepted: true,
            cloudASRBaseURL: "https://api.openai.com",
            cloudASRModel: "gpt-4o-transcribe",
            cloudASRAuthToken: "token"
        )
        XCTAssertFalse(alignmentOnly.isCloudASRConfigured)
        XCTAssertTrue(alignmentOnly.cloudASRModelRequiresAlignment)
        XCTAssertNil(CloudASRGeneratorFactory.make(settings: alignmentOnly))

        let encoded = try JSONEncoder().encode(settings)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["cloudASREnabled"] as? Bool, true)
        XCTAssertEqual(object["cloudASRConsentAccepted"] as? Bool, true)
        XCTAssertEqual(object["cloudASRBaseURL"] as? String, "https://api.openai.com/v1")
        XCTAssertEqual(object["cloudASRModel"] as? String, "whisper-1")

        let decoded = try JSONDecoder().decode(AppSettings.self, from: encoded)
        XCTAssertTrue(decoded.cloudASREnabled)
        XCTAssertTrue(decoded.cloudASRConsentAccepted)
        XCTAssertEqual(decoded.cloudASRBaseURL, "https://api.openai.com/v1")
        XCTAssertEqual(decoded.cloudASRModel, "whisper-1")
        XCTAssertEqual(decoded.cloudASRAuthToken, "token")
        XCTAssertTrue(decoded.isCloudASRConfigured)
    }

    func testBurnInPreservesSourceResolutionByDefault() throws {
        XCTAssertNil(AppSettings().maxBurnHeight)

        let migrated = try decodeSettings("""
        {
          "translationProvider": "anthropic",
          "translationBaseURL": "https://api.anthropic.com",
          "translationModel": "claude",
          "translationAuthToken": ""
        }
        """)
        XCTAssertNil(migrated.maxBurnHeight)

        let explicit1080 = try decodeSettings("""
        {"maxBurnHeight": 1080}
        """)
        XCTAssertEqual(explicit1080.maxBurnHeight, 1080)
    }

    func testCLIHelpDescribesBurnDefaultAsKeepingSourceResolution() throws {
        let cliSource = try String(contentsOf: packageRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("moongate-cli")
            .appendingPathComponent("main.swift"))

        XCTAssertTrue(cliSource.contains("burn 默认保持源分辨率"))
        XCTAssertFalse(cliSource.contains("缺省 1080p"))
    }

    func testCLIInjectsKeychainCredentialStoreBeforeLoadingSettings() throws {
        let cliSource = try String(contentsOf: packageRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("moongate-cli")
            .appendingPathComponent("main.swift"))

        let injectionRange = try XCTUnwrap(cliSource.range(of: "AppSettings.credentialStore = KeychainCredentialStore()"))
        let firstLoadRange = try XCTUnwrap(cliSource.range(of: "AppSettings.load()"))
        XCTAssertLessThan(injectionRange.lowerBound, firstLoadRange.lowerBound)
        XCTAssertTrue(cliSource.contains("#if canImport(Security)"))
    }

    func testCLIEndpointFlagsDisableFollowDefaultForCurrentCommand() throws {
        let cliSource = try String(contentsOf: packageRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("moongate-cli")
            .appendingPathComponent("main.swift"))

        XCTAssertTrue(cliSource.contains("var endpointOverridden = false"))
        XCTAssertTrue(cliSource.contains("settings.translationFollowsDefault = false"))
    }

    func testCompletionNotificationSettingsDefaultOnAndRoundTrip() throws {
        let fresh = AppSettings()
        XCTAssertTrue(fresh.completionNotificationsEnabled)
        XCTAssertTrue(fresh.completionSoundEnabled)

        let settings = AppSettings(
            completionNotificationsEnabled: false,
            completionSoundEnabled: false
        )
        let encoded = try JSONEncoder().encode(settings)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["completionNotificationsEnabled"] as? Bool, false)
        XCTAssertEqual(object["completionSoundEnabled"] as? Bool, false)

        let decoded = try JSONDecoder().decode(AppSettings.self, from: encoded)
        XCTAssertFalse(decoded.completionNotificationsEnabled)
        XCTAssertFalse(decoded.completionSoundEnabled)
    }

    func testSmartTranslationAdviceParsesLyricsAndChangesPrompt() throws {
        let advice = try XCTUnwrap(ConfiguredTranslator.parseTranslationPromptAdvice("""
        {
          "summary":"这是一首关于告别的歌曲。",
          "context":"YOASOBI 在 THE FIRST TAKE 中演唱，开场提到 Ayase、乐队成员和 Plusonica 合唱团。",
          "terms":["Ayase：YOASOBI 成员/制作人","Plusonica：合唱团体，字幕中写作ぷらそにか时不要误拼为 Plasonica"],
          "preset":"songLyrics"
        }
        """))

        XCTAssertEqual(advice.preset, .songLyrics)
        XCTAssertEqual(advice.terms.count, 2)
        let prompt = ConfiguredTranslator.systemPrompt(
            targetLanguageDisplayName: "简体中文",
            sourceLanguageCode: "ja",
            advice: advice
        )
        XCTAssertTrue(prompt.contains("这是一首关于告别的歌曲。"))
        XCTAssertTrue(prompt.contains("翻译前上下文"))
        XCTAssertTrue(prompt.contains("Ayase"))
        XCTAssertTrue(prompt.contains("Plusonica"))
        XCTAssertTrue(prompt.contains("不要把上下文里没有对应原文的信息加进译文"))
        XCTAssertTrue(prompt.contains("歌词"))
        XCTAssertTrue(prompt.contains("呼吸感"))
        XCTAssertFalse(prompt.contains("不要擅自扩写"))
        // 源语言点名 + 自然语序/防悬空规则：避免日语语序直接漏进中文。
        XCTAssertTrue(prompt.contains("正在把日语字幕翻译成简体中文"))
        XCTAssertTrue(prompt.contains("自然语序"))
        XCTAssertTrue(prompt.contains("不要让某行停在"))
        // 拆行时不得在前面的行提前译出靠后行的动词、造成重复。
        XCTAssertTrue(prompt.contains("不要提前把动词译出来"))
        // 数字/单位/所有格跨行时要用完整上下文理解。
        XCTAssertTrue(prompt.contains("99."))
        XCTAssertTrue(prompt.contains("8%"))
        XCTAssertTrue(prompt.contains("Sun's"))
        XCTAssertTrue(prompt.contains("太阳的"))
        // 上下文尾句不再要求逐字贴原文，改为允许同句相邻行间重排。
        XCTAssertFalse(prompt.contains("逐字逐句贴近原文"))
        // 日语源语言：含少样本重排范例。
        XCTAssertTrue(prompt.contains("日文→中文重排示例"))
        XCTAssertTrue(prompt.contains("别让某行停在「你的」"))
        XCTAssertTrue(prompt.contains("谐音梗"))
        XCTAssertTrue(prompt.contains("保留原词"))
        XCTAssertTrue(prompt.contains("チョコバナナ"))
        XCTAssertTrue(prompt.contains("ソースせんべい"))
        XCTAssertTrue(prompt.contains("くじ引きやろう"))
        // 歌曲：文学化改写 + 放宽不增不减（带护栏）。
        XCTAssertTrue(prompt.contains("文学性"))
        XCTAssertTrue(prompt.contains("放宽前面第 4 条"))
        XCTAssertTrue(prompt.contains("不得编造原文完全没有的情节或事实"))
    }

    func testSystemPromptSourceLanguageAndJapaneseExamplesGating() {
        let ja = ConfiguredTranslator.systemPrompt(
            targetLanguageDisplayName: "简体中文",
            sourceLanguageCode: "ja"
        )
        XCTAssertTrue(ja.contains("正在把日语字幕翻译成简体中文"))
        XCTAssertTrue(ja.contains("日文→中文重排示例"))
        XCTAssertTrue(ja.contains("谐音梗"))
        XCTAssertTrue(ja.contains("保留原词"))
        XCTAssertTrue(ja.contains("チョコバナナ"))

        let unknown = ConfiguredTranslator.systemPrompt(
            targetLanguageDisplayName: "简体中文",
            sourceLanguageCode: nil
        )
        // 未知源语言：不点名、不加日语范例；自然语序规则与源语言无关，仍应在。
        XCTAssertFalse(unknown.contains("正在把"))
        XCTAssertTrue(unknown.contains("把用户给出的字幕翻译成简体中文"))
        XCTAssertFalse(unknown.contains("日文→中文重排示例"))
        XCTAssertFalse(unknown.contains("チョコバナナ"))
        XCTAssertTrue(unknown.contains("自然语序"))

        // 非日语源语言（英语）：点名但不加日语范例。
        let en = ConfiguredTranslator.systemPrompt(
            targetLanguageDisplayName: "简体中文",
            sourceLanguageCode: "en"
        )
        XCTAssertTrue(en.contains("正在把英语字幕翻译成简体中文"))
        XCTAssertTrue(en.contains("99."))
        XCTAssertTrue(en.contains("Sun's"))
        XCTAssertFalse(en.contains("日文→中文重排示例"))
        XCTAssertFalse(en.contains("チョコバナナ"))
    }

    func testSmartTranslationAdviceKeepsLegacySummaryOnlyJSONCompatible() throws {
        let advice = try XCTUnwrap(ConfiguredTranslator.parseTranslationPromptAdvice("""
        {"summary":"测试摘要","preset":"songLyrics"}
        """))

        XCTAssertEqual(advice.summary, "测试摘要")
        XCTAssertEqual(advice.context, "")
        XCTAssertEqual(advice.terms, [])
    }

    func testSmartTranslationPromptPresetsCoverCommonVideoTypes() throws {
        let presets: [(String, String)] = [
            ("interviewConversation", "访谈"),
            ("tutorialHowTo", "步骤"),
            ("lectureCourse", "课程"),
            ("newsExplainer", "客观"),
            ("reviewProduct", "体验"),
            ("vlogLifestyle", "口吻"),
            ("shortSocial", "节奏"),
            ("documentaryNarrative", "叙事"),
            ("gamingEntertainment", "游戏")
        ]

        for (rawPreset, expectedHint) in presets {
            let advice = try XCTUnwrap(ConfiguredTranslator.parseTranslationPromptAdvice("""
            {"summary":"测试摘要","preset":"\(rawPreset)"}
            """), rawPreset)
            let prompt = ConfiguredTranslator.systemPrompt(
                targetLanguageDisplayName: "简体中文",
                advice: advice
            )

            XCTAssertTrue(prompt.contains(expectedHint), rawPreset)
            XCTAssertTrue(prompt.contains("测试摘要"), rawPreset)
            // 文学化"放宽不增不减"只对歌曲开放，不得泄漏到其它内容类型。
            XCTAssertFalse(prompt.contains("放宽前面第 4 条"), rawPreset)
        }
    }

    func testTranslationPromptPresetProfilesCoverEveryPromptLayer() {
        XCTAssertEqual(TranslationPromptPreset.allCases.count, 12)
        for preset in TranslationPromptPreset.allCases {
            let profile = preset.profile
            XCTAssertFalse(profile.planningHint.isEmpty, "\(preset).planningHint")
            XCTAssertFalse(profile.segmentationGuidance.isEmpty, "\(preset).segmentationGuidance")
            XCTAssertFalse(profile.translationGuidance.isEmpty, "\(preset).translationGuidance")
            XCTAssertFalse(profile.qualityAnchors.isEmpty, "\(preset).qualityAnchors")
        }
    }

    func testTranslationPromptPresetProfilesExpressDistinctStyleAnchors() {
        let anchors: [(TranslationPromptPreset, [String], [String])] = [
            (.songLyrics, ["诗意", "意象", "副歌"], ["客观", "按钮名"]),
            (.anime, ["角色", "称呼", "口癖"], ["严肃科普"]),
            (.lectureCourse, ["专业", "严肃", "逻辑"], ["诗意"]),
            (.newsExplainer, ["客观", "数字", "时间"], ["副歌"]),
            (.shortSocial, ["节奏", "梗", "语义完整"], ["课程"]),
            (.gamingEntertainment, ["现场感", "术语", "即时反应"], ["新闻"]),
        ]

        for (preset, required, forbidden) in anchors {
            let prompt = ConfiguredTranslator.systemPrompt(
                targetLanguageDisplayName: "简体中文",
                advice: TranslationPromptAdvice(summary: "测试摘要", preset: preset)
            )
            for word in required {
                XCTAssertTrue(prompt.contains(word), "\(preset) should contain \(word)")
            }
            for word in forbidden {
                XCTAssertFalse(prompt.contains(word), "\(preset) should not leak \(word)")
            }
        }
    }

    func testSmartTranslationUnknownPresetFallsBackToGeneral() throws {
        let advice = try XCTUnwrap(ConfiguredTranslator.parseTranslationPromptAdvice("""
        {"summary":"测试摘要","preset":"unknownFuturePreset"}
        """))

        XCTAssertEqual(advice.preset, .general)
    }

    func testSmartTranslationAdviceParsesPlanningFieldsAndInjectsThem() throws {
        let advice = try XCTUnwrap(ConfiguredTranslator.parseTranslationPromptAdvice("""
        {
          "summary":"一群冒险者的战斗对白。",
          "context":"奇幻动画第二季，主角与对手交战。",
          "sourceLanguageCode":"ja",
          "preset":"anime",
          "terms":["魔法：保留原文"],
          "characters":["王城ハル：主角，使用敬语","レン：对手，说话粗鲁"],
          "translationNotes":["保持ハル的敬语口吻","战斗拟声词保留情绪"]
        }
        """))

        XCTAssertEqual(advice.preset, .anime)
        XCTAssertEqual(advice.sourceLanguageCode, "ja")
        XCTAssertEqual(advice.characters.count, 2)
        XCTAssertEqual(advice.translationNotes.count, 2)

        // 第二层 prompt：源语言（advice 兜底点名）、人物、翻译注意、anime 风格句都要注入。
        let prompt = ConfiguredTranslator.systemPrompt(
            targetLanguageDisplayName: "简体中文",
            sourceLanguageCode: nil,
            advice: advice
        )
        XCTAssertTrue(prompt.contains("正在把日语字幕翻译成简体中文"), "advice.sourceLanguageCode 应在管线缺值时兜底点名源语言")
        XCTAssertTrue(prompt.contains("日文→中文重排示例"))
        XCTAssertTrue(prompt.contains("人物/角色"))
        XCTAssertTrue(prompt.contains("王城ハル"))
        XCTAssertTrue(prompt.contains("翻译注意"))
        XCTAssertTrue(prompt.contains("战斗拟声词保留情绪"))
        XCTAssertTrue(prompt.contains("动漫或动画对白"))
    }

    func testSmartTranslationAdviceLegacyJSONDefaultsPlanningFields() throws {
        let advice = try XCTUnwrap(ConfiguredTranslator.parseTranslationPromptAdvice("""
        {"summary":"测试摘要","preset":"songLyrics"}
        """))

        XCTAssertEqual(advice.sourceLanguageCode, "unknown")
        XCTAssertEqual(advice.characters, [])
        XCTAssertEqual(advice.translationNotes, [])
    }

    func testSubtitlePipelineAdviceParsesSourceActionAndTimingProfile() throws {
        let advice = try XCTUnwrap(ConfiguredTranslator.parseSubtitlePipelineAdvice("""
        {
          "summary":"YOASOBI 歌曲 MV，YouTube 自动字幕疑似罗马音循环。",
          "context":"日语歌词，源字幕混入大量 ni/dare/carano。",
          "sourceLanguageCode":"ja",
          "preset":"songLyrics",
          "terms":["群青：歌名，保留意象"],
          "translationNotes":["按整段歌词意象翻译"],
          "sourceAssessment":"bad",
          "recommendedSourceAction":"useLocalASR",
          "timingProfile":"japaneseLyrics",
          "asrHints":{
            "disablePromptContext":true,
            "preferVAD":true,
            "suppressIntroHallucination":true
          },
          "qualityRisks":["romajiLoop","lyricsContext"]
        }
        """))

        XCTAssertEqual(advice.sourceLanguageCode, "ja")
        XCTAssertEqual(advice.preset, .songLyrics)
        XCTAssertEqual(advice.sourceAssessment, .bad)
        XCTAssertEqual(advice.recommendedSourceAction, .useLocalASR)
        XCTAssertEqual(advice.timingProfile, .japaneseLyrics)
        XCTAssertTrue(advice.asrHints.disablePromptContext)
        XCTAssertTrue(advice.asrHints.preferVAD)
        XCTAssertTrue(advice.asrHints.suppressIntroHallucination)
        XCTAssertEqual(advice.qualityRisks, ["romajiLoop", "lyricsContext"])

        let translationAdvice = advice.translationAdvice
        XCTAssertEqual(translationAdvice.preset, .songLyrics)
        XCTAssertEqual(translationAdvice.translationNotes, ["按整段歌词意象翻译"])
    }

    func testSubtitlePipelineAdviceLegacyTranslationJSONDefaultsToSafeSourceDecision() throws {
        let advice = try XCTUnwrap(ConfiguredTranslator.parseSubtitlePipelineAdvice("""
        {"summary":"测试摘要","preset":"anime","sourceLanguageCode":"ja"}
        """))

        XCTAssertEqual(advice.preset, .anime)
        XCTAssertEqual(advice.sourceLanguageCode, "ja")
        XCTAssertEqual(advice.sourceAssessment, .unknown)
        XCTAssertEqual(advice.recommendedSourceAction, .keepPlatform)
        XCTAssertEqual(advice.timingProfile, .speech)
        XCTAssertFalse(advice.asrHints.disablePromptContext)
        XCTAssertEqual(advice.translationAdvice.preset, .anime)
    }

    func testSubtitlePipelinePlanningPromptIncludesSourceAndASRDecisionSchema() {
        let prompt = ConfiguredTranslator.subtitlePipelinePlanningSystemPrompt

        XCTAssertTrue(prompt.contains("字幕流水线规划器"))
        XCTAssertTrue(prompt.contains("sourceAssessment"))
        XCTAssertTrue(prompt.contains("recommendedSourceAction"))
        XCTAssertTrue(prompt.contains("timingProfile"))
        XCTAssertTrue(prompt.contains("asrHints"))
        XCTAssertTrue(prompt.contains("useLocalASR"))
        XCTAssertTrue(prompt.contains("japaneseLyrics"))
        XCTAssertTrue(prompt.contains("不能直接写时间轴"))
        XCTAssertTrue(prompt.contains("不能覆盖 local-ASR 源字幕"))
    }

    func testTranslationOutputDetectsSourceLanguageLeakage() {
        let leakedJapanese = TranslationOutputQualityGate.assess(
            lines: [
                "チョコナナナ很好吃",
                "我们去くじ引き野郎吧",
                "世界の銀行が崩れ了"
            ],
            sourceLanguageCode: "ja",
            targetLanguageCode: "zh-Hans"
        )

        XCTAssertFalse(leakedJapanese.usable)
        XCTAssertTrue(leakedJapanese.reasons.contains(.sourceLanguageLeakage))
        XCTAssertGreaterThanOrEqual(leakedJapanese.report.affectedLineCount, 2)

        let cleanChinese = TranslationOutputQualityGate.assess(
            lines: [
                "巧克力香蕉很好吃",
                "我们去抽签吧",
                "世界银行倒闭了"
            ],
            sourceLanguageCode: "ja",
            targetLanguageCode: "zh-Hans"
        )

        XCTAssertTrue(cleanChinese.usable)
        XCTAssertFalse(cleanChinese.reasons.contains(.sourceLanguageLeakage))

        let leakedEnglish = TranslationOutputQualityGate.assess(
            lines: [
                "This subtitle is still mostly English",
                "It should have been translated into Chinese"
            ],
            sourceLanguageCode: "en",
            targetLanguageCode: "zh-Hans"
        )

        XCTAssertFalse(leakedEnglish.usable)
        XCTAssertTrue(leakedEnglish.reasons.contains(.sourceLanguageLeakage))
    }

    func testSmartTranslationAdviceNormalizesSourceLanguageAndCapsLists() throws {
        let manyCharacters = (0..<12).map { "\"角色\($0)\"" }.joined(separator: ",")
        let advice = try XCTUnwrap(ConfiguredTranslator.parseTranslationPromptAdvice("""
        {"summary":"测试摘要","sourceLanguageCode":"Japanese","characters":[\(manyCharacters)]}
        """))

        XCTAssertEqual(advice.sourceLanguageCode, "unknown", "不在允许集合里的源语言串应落到 unknown")
        XCTAssertEqual(advice.characters.count, 8, "人物列表最多 8 条")
    }

    func testSettingsSingleLineFieldsAreTrimmedWhenRoundTripping() throws {
        let settings = AppSettings(
            translationBaseURL: " https://translation.example.com\n",
            translationModel: "\ntranslation-model ",
            translationAuthToken: "token",
            aiBaseURL: "https://ai.example.com\n\n",
            aiModel: " ai-model\n",
            aiAuthToken: "ai-token",
            summaryBaseURL: "\nhttps://summary.example.com ",
            summaryModel: "summary-model\n",
            summaryAuthToken: "summary-token"
        )

        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))

        XCTAssertEqual(decoded.translationBaseURL, "https://translation.example.com")
        XCTAssertEqual(decoded.translationModel, "translation-model")
        XCTAssertEqual(decoded.aiBaseURL, "https://ai.example.com")
        XCTAssertEqual(decoded.aiModel, "ai-model")
        XCTAssertEqual(decoded.summaryBaseURL, "https://summary.example.com")
        XCTAssertEqual(decoded.summaryModel, "summary-model")
    }

    func testTranslatedSubtitleSuffixFollowsTargetLanguage() {
        XCTAssertEqual(TranslationLanguage.translatedSubtitleFileSuffix(for: "zh-Hans"), ".zh-Hans.srt")
        XCTAssertEqual(TranslationLanguage.translatedSubtitleFileSuffix(for: "zh-Hant"), ".zh-Hant.srt")
        XCTAssertEqual(TranslationLanguage.translatedSubtitleFileSuffix(for: "en"), ".en.srt")
        XCTAssertTrue(TranslationLanguage.translatedSubtitleFileSuffixes.contains(".zh-Hans.srt"))
        XCTAssertTrue(TranslationLanguage.translatedSubtitleFileSuffixes.contains(".zh-Hant.srt"))
        XCTAssertTrue(TranslationLanguage.translatedSubtitleFileSuffixes.contains(".en.srt"))
        XCTAssertTrue(TranslationLanguage.isTranslatedSubtitleFileName("video.en.zh-Hans.srt"))
        XCTAssertTrue(TranslationLanguage.isTranslatedSubtitleFileName("video.zh-Hant.en.srt"))
        XCTAssertFalse(TranslationLanguage.isTranslatedSubtitleFileName("video.en.srt"))
        XCTAssertFalse(TranslationLanguage.isTranslatedSubtitleFileName("video.zh-Hans.srt"))
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

    func testListTranslationModelsRetriesGatewayWithoutLimitWhenRequestShapeIsRejected() async throws {
        ModelListURLProtocol.reset(responses: [
            (400, #"{"error":"unexpected query"}"#),
            (200, #"{"data":[{"id":"claude-gateway"},{"id":"claude-gateway"}]}"#)
        ])
        URLProtocol.registerClass(ModelListURLProtocol.self)
        defer { URLProtocol.unregisterClass(ModelListURLProtocol.self) }

        let settings = AppSettings(
            translationEngine: .anthropicCompatible,
            translationBaseURL: "https://gateway.example.com",
            translationModel: "",
            translationAuthToken: "secret-token"
        )

        let models = try await listTranslationModels(settings: settings)

        XCTAssertEqual(models, ["claude-gateway"])
        let requests = ModelListURLProtocol.capturedRequests()
        XCTAssertEqual(requests.map { $0.url?.absoluteString }, [
            "https://gateway.example.com/v1/models?limit=1000",
            "https://gateway.example.com/v1/models"
        ])
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "x-api-key"), "secret-token")
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
    }

    func testListTranslationModelsDoesNotRetryOfficialAnthropicWithoutLimit() async throws {
        ModelListURLProtocol.reset(responses: [
            (400, #"{"error":"bad request"}"#),
            (200, #"{"data":[{"id":"should-not-fetch"}]}"#)
        ])
        URLProtocol.registerClass(ModelListURLProtocol.self)
        defer { URLProtocol.unregisterClass(ModelListURLProtocol.self) }

        let settings = AppSettings(
            translationEngine: .anthropicCompatible,
            translationBaseURL: "https://api.anthropic.com",
            translationModel: "",
            translationAuthToken: "secret-token"
        )

        do {
            _ = try await listTranslationModels(settings: settings)
            XCTFail("Official Anthropic should not retry without the limit query.")
        } catch MoongateError.translateFailed {
            XCTAssertEqual(ModelListURLProtocol.capturedRequests().map { $0.url?.absoluteString }, [
                "https://api.anthropic.com/v1/models?limit=1000"
            ])
        }
    }

    func testListTranslationModelsOpenAICompatibleUsesBearerOnly() async throws {
        ModelListURLProtocol.reset(responses: [
            (200, #"{"data":[{"id":"gpt-gateway"}]}"#)
        ])
        URLProtocol.registerClass(ModelListURLProtocol.self)
        defer { URLProtocol.unregisterClass(ModelListURLProtocol.self) }

        let settings = AppSettings(
            translationEngine: .openAICompatible,
            translationBaseURL: "https://gateway.example.com",
            translationModel: "",
            translationAuthToken: "secret-token"
        )

        let models = try await listTranslationModels(settings: settings)

        XCTAssertEqual(models, ["gpt-gateway"])
        let request = try XCTUnwrap(ModelListURLProtocol.capturedRequests().first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
        XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
        XCTAssertNil(request.value(forHTTPHeaderField: "anthropic-version"))
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
        // SEC-CRED-001：settings.json 不再含明文 Token（已进安全存储）。
        XCTAssertFalse(try String(contentsOf: settingsURL, encoding: .utf8).contains("TEST_SECRET_VALUE_DO_NOT_STORE"))
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
        // SEC-CRED-001：settings.json 不再含明文 Token（已进安全存储）。
        XCTAssertFalse(try String(contentsOf: settingsURL, encoding: .utf8).contains("TEST_SECRET_VALUE_DO_NOT_STORE"))
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

    func testLoadingCorruptSettingsBacksUpAndReturnsDefaults() throws {
        // DATA-SETTINGS-002：settings.json 损坏时不静默回默认覆盖，而是改名备份 + 置位提示 + 回默认。
        let root = try makeTemporarySettingsDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let currentDirectory = root.appendingPathComponent("月之门", isDirectory: true)
        let legacyDirectory = root.appendingPathComponent("视频下载器", isDirectory: true)
        try FileManager.default.createDirectory(at: currentDirectory, withIntermediateDirectories: true)
        let settingsURL = currentDirectory.appendingPathComponent("settings.json")
        try Data("{ this is not valid json ".utf8).write(to: settingsURL)
        AppSettings.lastCorruptBackupPath = nil
        defer { AppSettings.lastCorruptBackupPath = nil }

        let loaded = AppSettings.load(
            supportDirectory: currentDirectory,
            legacySupportDirectory: legacyDirectory
        )

        XCTAssertEqual(loaded.translationBaseURL, AppSettings().translationBaseURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: settingsURL.path))
        XCTAssertNotNil(AppSettings.lastCorruptBackupPath)
        let backups = try FileManager.default.contentsOfDirectory(atPath: currentDirectory.path)
            .filter { $0.hasPrefix("settings.corrupt-") }
        XCTAssertEqual(backups.count, 1)
    }

    // MARK: - SEC-CRED-001 凭证安全存储

    private final class ThrowingCredentialStore: CredentialStore, @unchecked Sendable {
        func get(_ key: String) -> String? { nil }
        func set(_ key: String, _ value: String) throws { throw NSError(domain: "test", code: 1) }
        func delete(_ key: String) {}
    }

    /// 统计 get 调用次数，用于验证启动期 load 不读 Keychain（避免首次启动弹授权）。
    private final class CountingCredentialStore: CredentialStore, @unchecked Sendable {
        private let backing = InMemoryCredentialStore()
        private(set) var getCount = 0
        func get(_ key: String) -> String? { getCount += 1; return backing.get(key) }
        func set(_ key: String, _ value: String) throws { try backing.set(key, value) }
        func delete(_ key: String) { backing.delete(key) }
    }

    func testStartupLoadSkipsCredentialReadsUntilHydrated() throws {
        let prevStore = AppSettings.credentialStore
        defer { AppSettings.credentialStore = prevStore }
        let store = CountingCredentialStore()
        AppSettings.credentialStore = store

        let root = try makeTemporarySettingsDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("月之门", isDirectory: true)
        let settingsURL = dir.appendingPathComponent("settings.json")
        var s = AppSettings()
        s.aiBaseURL = "https://example.com"
        s.aiAuthToken = "tok-ai"
        try s.save(supportDirectory: dir, settingsFileURL: settingsURL)
        let legacy = root.appendingPathComponent("none")

        // 启动路径：readCredentials: false 不应触发任何 Keychain 读取，Token 留空待 hydrate。
        let countBeforeLazy = store.getCount
        let lazy = AppSettings.load(supportDirectory: dir, legacySupportDirectory: legacy, readCredentials: false)
        XCTAssertEqual(store.getCount, countBeforeLazy, "启动 load 不应读取凭证")
        XCTAssertEqual(lazy.aiAuthToken, "")

        // 显式需要时：readCredentials: true 从安全存储补齐。
        let hydrated = AppSettings.load(supportDirectory: dir, legacySupportDirectory: legacy, readCredentials: true)
        XCTAssertEqual(hydrated.aiAuthToken, "tok-ai")
        XCTAssertGreaterThan(store.getCount, countBeforeLazy, "hydrate 路径应读取凭证")
    }

    func testCredentialsMigrateLegacyPlaintextIntoStoreAndStripFromDisk() throws {
        let prevStore = AppSettings.credentialStore
        defer { AppSettings.credentialStore = prevStore }
        let store = InMemoryCredentialStore()
        AppSettings.credentialStore = store

        let root = try makeTemporarySettingsDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("月之门", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let settingsURL = dir.appendingPathComponent("settings.json")
        // 旧版文件：明文 Token 直接编码进 JSON（encode(to:) 仍含 token）。
        var legacy = AppSettings()
        legacy.translationAuthToken = "secret-t"
        legacy.aiAuthToken = "secret-ai"
        try JSONEncoder().encode(legacy).write(to: settingsURL)

        let loaded = AppSettings.load(supportDirectory: dir, legacySupportDirectory: root.appendingPathComponent("none"))

        XCTAssertEqual(store.get("translationAuthToken"), "secret-t")
        XCTAssertEqual(store.get("aiAuthToken"), "secret-ai")
        XCTAssertEqual(loaded.translationAuthToken, "secret-t")
        let raw = try String(contentsOf: settingsURL, encoding: .utf8)
        XCTAssertFalse(raw.contains("secret-t"))
        XCTAssertFalse(raw.contains("secret-ai"))
    }

    func testCredentialsSaveWritesNoPlaintextButRoundTripsViaStore() throws {
        let prevStore = AppSettings.credentialStore
        defer { AppSettings.credentialStore = prevStore }
        let store = InMemoryCredentialStore()
        AppSettings.credentialStore = store

        let root = try makeTemporarySettingsDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("月之门", isDirectory: true)
        let settingsURL = dir.appendingPathComponent("settings.json")
        var s = AppSettings()
        s.translationAuthToken = "plaintext-xyz"
        try s.save(supportDirectory: dir, settingsFileURL: settingsURL)

        let raw = try String(contentsOf: settingsURL, encoding: .utf8)
        XCTAssertFalse(raw.contains("plaintext-xyz"))
        XCTAssertEqual(store.get("translationAuthToken"), "plaintext-xyz")
        let loaded = AppSettings.load(supportDirectory: dir, legacySupportDirectory: root.appendingPathComponent("none"))
        XCTAssertEqual(loaded.translationAuthToken, "plaintext-xyz")
    }

    func testCredentialsMigrationStoreFailureKeepsTokenNotLost() throws {
        let prevStore = AppSettings.credentialStore
        defer { AppSettings.credentialStore = prevStore }
        AppSettings.credentialStore = ThrowingCredentialStore()

        let root = try makeTemporarySettingsDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("月之门", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let settingsURL = dir.appendingPathComponent("settings.json")
        var legacy = AppSettings()
        legacy.translationAuthToken = "secret-t"
        try JSONEncoder().encode(legacy).write(to: settingsURL)

        let loaded = AppSettings.load(supportDirectory: dir, legacySupportDirectory: root.appendingPathComponent("none"))

        // 安全存储写入失败：Token 不丢——内存仍有，磁盘明文仍保留。
        XCTAssertEqual(loaded.translationAuthToken, "secret-t")
        XCTAssertTrue(try String(contentsOf: settingsURL, encoding: .utf8).contains("secret-t"))
    }

    func testLoadingSettingsMigratesLegacyCookiesEvenWhenLegacySettingsAbsent() throws {        #if os(Windows)
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

    func testLastDownloadOptionsSurviveCodableRoundTrip() throws {
        var original = AppSettings(translationModel: "")
        original.lastSubtitleMode = "burnIn"
        original.lastSubtitleLangs = ["en", "en-orig"]
        original.lastPrimarySubtitleTrackID = "localASR|whisper.cpp|ja|local"
        original.lastOutputFormat = .mp4H264
        original.lastPreferHDR = true

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(decoded.lastSubtitleMode, "burnIn")
        XCTAssertEqual(decoded.lastSubtitleLangs, ["en", "en-orig"])
        XCTAssertEqual(decoded.lastPrimarySubtitleTrackID, "localASR|whisper.cpp|ja|local")
        XCTAssertEqual(decoded.lastOutputFormat, .mp4H264)
        XCTAssertTrue(decoded.lastPreferHDR)
    }

    func testLegacySettingsWithoutLastDownloadOptionsDecodeToEmptyDefaults() throws {
        // 旧版本 settings.json 没有这些键，必须安全回退为「无记忆」默认，不抛错。
        let legacyJSON = """
        {
          "translationProvider": "anthropic",
          "translationEngine": "anthropicCompatible",
          "translationBaseURL": "https://api.anthropic.com",
          "translationModel": "claude-haiku-4-5",
          "translationAuthToken": ""
        }
        """
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(legacyJSON.utf8))
        XCTAssertNil(decoded.lastSubtitleMode)
        XCTAssertEqual(decoded.lastSubtitleLangs, [])
        XCTAssertNil(decoded.lastPrimarySubtitleTrackID)
        XCTAssertNil(decoded.lastOutputFormat)
        XCTAssertFalse(decoded.lastPreferHDR)
    }

    func testSubtitleTrackIDsDistinguishSameLanguageSources() {
        let manual = SubtitleChoice(languageCode: "ja", label: "Japanese", sourceKind: .manual)
        let auto = SubtitleChoice(languageCode: "ja", label: "Japanese auto", sourceKind: .platformAuto)
        let localASR = SubtitleChoice(
            languageCode: "ja",
            label: "Japanese local ASR",
            sourceKind: .localASR,
            provider: "whisper.cpp",
            variant: "ggml-small"
        )
        let cloudASR = SubtitleChoice(
            languageCode: "ja",
            label: "Japanese cloud ASR",
            sourceKind: .cloudASR,
            provider: "cloud",
            variant: "precise"
        )

        XCTAssertEqual(manual.languageCode, "ja")
        XCTAssertEqual(auto.languageCode, "ja")
        XCTAssertEqual(localASR.languageCode, "ja")
        XCTAssertEqual(cloudASR.languageCode, "ja")
        XCTAssertEqual(Set([manual.id, auto.id, localASR.id, cloudASR.id]).count, 4)
        XCTAssertFalse(manual.isAuto)
        XCTAssertTrue(auto.isAuto)
        XCTAssertFalse(localASR.isAuto)
        XCTAssertFalse(cloudASR.isAuto)

        XCTAssertEqual(SubtitleTrackID(rawValue: manual.id).sourceKind, .manual)
        XCTAssertEqual(SubtitleTrackID(rawValue: auto.id).sourceKind, .platformAuto)
        XCTAssertEqual(SubtitleTrackID(rawValue: cloudASR.id).sourceKind, .cloudASR)
        XCTAssertEqual(SubtitleTrackID(rawValue: "ja").languageCode, "ja")
        XCTAssertEqual(SubtitleTrackID(rawValue: "ja").sourceKind, .manual)
    }

    func testDownloadRequestKeepsStableSubtitleTracksAndFiltersYtDlpSources() {
        let manual = SubtitleChoice(languageCode: "ja", label: "Japanese", sourceKind: .manual)
        let auto = SubtitleChoice(languageCode: "ja", label: "Japanese auto", sourceKind: .platformAuto)
        let localASR = SubtitleChoice(
            languageCode: "ja",
            label: "Japanese local ASR",
            sourceKind: .localASR,
            provider: "whisper.cpp",
            variant: "small"
        )
        let imported = SubtitleChoice(
            languageCode: "ja",
            label: "Imported Japanese",
            sourceKind: .importedFile,
            provider: "user"
        )

        let request = DownloadRequest(
            url: "https://example.com/video",
            videoID: "video",
            formatID: "137",
            subtitleLangs: [],
            autoSubtitleLangs: [],
            subtitleTracks: [manual, auto, localASR, imported],
            primarySubtitleTrackID: localASR.id,
            destinationDirectory: URL(fileURLWithPath: "/tmp")
        )

        XCTAssertEqual(request.requestedSubtitleTracks.map(\.id), [manual.id, auto.id, localASR.id, imported.id])
        XCTAssertEqual(request.primarySubtitleTrack?.id, localASR.id)
        XCTAssertEqual(request.primarySubtitleLanguageCode, "ja")
        XCTAssertEqual(request.ytDlpSubtitleLangs, ["ja"])
        XCTAssertEqual(request.ytDlpAutoSubtitleLangs, ["ja"])
    }

    func testDownloadRequestFallsBackToManualFirstPrimarySubtitleTrack() {
        let manual = SubtitleChoice(languageCode: "ja", label: "Japanese", sourceKind: .manual)
        let auto = SubtitleChoice(languageCode: "ja", label: "Japanese auto", sourceKind: .platformAuto)
        let localASR = SubtitleChoice(
            languageCode: "ja",
            label: "Japanese local ASR",
            sourceKind: .localASR,
            provider: "whisper.cpp",
            variant: "small"
        )

        let request = DownloadRequest(
            url: "https://example.com/video",
            videoID: "video",
            formatID: "137",
            subtitleLangs: [],
            autoSubtitleLangs: [],
            subtitleTracks: [localASR, auto, manual],
            destinationDirectory: URL(fileURLWithPath: "/tmp")
        )

        XCTAssertEqual(request.primarySubtitleTrack?.id, manual.id)
        XCTAssertEqual(request.primarySubtitleLanguageCode, "ja")
    }

    // MARK: 0.7 多语言 / 翻译目标 / 引导（M1.5 跨平台 parity 门禁）

    func testLanguageAndOnboardingSettingsSurviveCodableRoundTrip() throws {
        var original = AppSettings()
        original.appLanguage = "zh-Hant"
        original.translationTargetLanguage = "en"
        original.preferredSourceLanguage = "ja"
        original.onboardingCompleted = true

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(decoded.appLanguage, "zh-Hant")
        XCTAssertEqual(decoded.translationTargetLanguage, "en")
        XCTAssertEqual(decoded.preferredSourceLanguage, "ja")
        XCTAssertTrue(decoded.onboardingCompleted)
    }

    func testLegacySettingsWithoutLanguageKeysKeepTokenAndUseSafeDefaults() throws {
        // 关键回归：旧 settings.json 没有 0.7 新键。解码必须保住已存的 API token，
        // 并把三字段安全回退为默认——翻译目标默认 zh-Hans，保证升级后行为零变化。
        let legacyJSON = """
        {
          "translationProvider": "anthropic",
          "translationEngine": "anthropicCompatible",
          "translationBaseURL": "https://api.anthropic.com",
          "translationModel": "claude-haiku-4-5",
          "translationAuthToken": "TEST_SECRET_VALUE_DO_NOT_STORE"
        }
        """
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(legacyJSON.utf8))

        XCTAssertEqual(decoded.translationAuthToken, "TEST_SECRET_VALUE_DO_NOT_STORE", "升级不得清空已保存凭证")
        XCTAssertEqual(decoded.appLanguage, "auto")
        XCTAssertEqual(decoded.translationTargetLanguage, "zh-Hans")
        XCTAssertEqual(decoded.preferredSourceLanguage, "auto")
        XCTAssertFalse(decoded.onboardingCompleted)
    }

    func testPreferredSourceLanguageNormalizesUnsupportedValuesToAuto() throws {
        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: Data(#"{"preferredSourceLanguage":"klingon"}"#.utf8)
        )

        XCTAssertEqual(AppSettings().preferredSourceLanguage, "auto")
        XCTAssertEqual(decoded.preferredSourceLanguage, "auto")
    }

    func testMakeTranslationContextUsesConfiguredTargetLanguage() {
        var settings = AppSettings()
        settings.translationTargetLanguage = "zh-Hant"
        let ctx = settings.makeTranslationContext(sourceLanguage: "en")
        XCTAssertEqual(ctx.targetLanguage, "zh-Hant")
        XCTAssertEqual(ctx.targetLanguageDisplayName, "繁體中文")
    }

    func testTranslationLanguageDisplayNamesCoverSupportedTargets() {
        XCTAssertEqual(TranslationLanguage.displayName(for: "zh-Hans"), "简体中文")
        XCTAssertEqual(TranslationLanguage.displayName(for: "zh-Hant"), "繁體中文")
        XCTAssertEqual(TranslationLanguage.displayName(for: "en"), "English")
    }

    func testSourceMatchesTargetIsScriptAwareForChinese() {
        // 同脚本才跳过翻译；简↔繁视为不同脚本，必须仍翻译。
        XCTAssertTrue(TranslationLanguage.matches(source: "zh-Hans", target: "zh-Hans"))
        XCTAssertTrue(TranslationLanguage.matches(source: "zh-CN", target: "zh-Hans"))
        XCTAssertTrue(TranslationLanguage.matches(source: "zh-TW", target: "zh-Hant"))
        XCTAssertFalse(TranslationLanguage.matches(source: "zh-Hans", target: "zh-Hant"))
        XCTAssertFalse(TranslationLanguage.matches(source: "en", target: "zh-Hans"))
        XCTAssertTrue(TranslationLanguage.matches(source: "en-US", target: "en"))
        XCTAssertFalse(TranslationLanguage.matches(source: nil, target: "zh-Hans"))
    }

    func testEncodedSettingsUseAgreedCrossPlatformJSONKeys() throws {
        // parity：Swift 侧必须用与 Windows ToJson 完全一致的 JSON key 名。
        let data = try JSONEncoder().encode(AppSettings())
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        for key in ["appLanguage", "translationTargetLanguage", "onboardingCompleted"] {
            XCTAssertTrue(json.contains("\"\(key)\""), "缺少跨平台约定 key: \(key)")
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

    func testEncodeBackendSurvivesCodableRoundTrip() throws {
        var settings = AppSettings()
        settings.encodeBackend = .software
        settings.burnAlwaysH264 = true
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded.encodeBackend, .software)
        XCTAssertTrue(decoded.burnAlwaysH264)
    }

    func testEncodeBackendDefaultsToAutoWhenKeyMissing() throws {
        // 旧 settings.json 没有 encodeBackend / burnAlwaysH264：默认 auto / false。
        let settings = try decodeSettings("""
        { "translationBaseURL": "https://api.anthropic.com", "translationModel": "claude" }
        """)
        XCTAssertEqual(settings.encodeBackend, .auto)
        XCTAssertFalse(settings.burnAlwaysH264)
    }

    func testEffectiveMaxConcurrentBurnsBumpsForHardwareBackend() {
        var s = AppSettings(maxConcurrentBurns: 2, encodeBackend: .auto)
        XCTAssertEqual(s.effectiveMaxConcurrentBurns, 3, "硬件后端编码不占 CPU，可多放一路")
        s.encodeBackend = .hardware
        XCTAssertEqual(s.effectiveMaxConcurrentBurns, 3)
        s.encodeBackend = .software
        XCTAssertEqual(s.effectiveMaxConcurrentBurns, 2, "软件后端维持原始值")
    }

    func testEffectiveMaxConcurrentBurnsClampsAtFour() {
        let s = AppSettings(maxConcurrentBurns: 3, encodeBackend: .auto)
        XCTAssertEqual(s.effectiveMaxConcurrentBurns, 4, "上限 4")
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

    func testParseVTTKeepsInlineWordTimingFragments() {
        let raw = """
        WEBVTT

        00:00:00.000 --> 00:00:02.000 align:start position:0%
        Hello<00:00:00.500><c> world</c><00:00:01.200><c> again</c>
        """

        let cues = parseVTT(raw)

        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].text, "Hello world again")
        XCTAssertEqual(cues[0].sourceFragments.map(\.text), ["Hello", "world", "again"])
        XCTAssertEqual(cues[0].sourceFragments[0].startSeconds, 0.0, accuracy: 0.001)
        XCTAssertEqual(cues[0].sourceFragments[0].endSeconds, 0.5, accuracy: 0.001)
        XCTAssertEqual(cues[0].sourceFragments[1].startSeconds, 0.5, accuracy: 0.001)
        XCTAssertEqual(cues[0].sourceFragments[1].endSeconds, 1.2, accuracy: 0.001)
        XCTAssertEqual(cues[0].sourceFragments[2].startSeconds, 1.2, accuracy: 0.001)
        XCTAssertEqual(cues[0].sourceFragments[2].endSeconds, 2.0, accuracy: 0.001)
    }

    func testParseVTTDropsRollingTransitionAndDisplaysOnlyNewText() {
        let raw = """
        WEBVTT

        00:00:15.760 --> 00:00:20.150 align:start position:0%
        やる<00:00:16.760><c>ちっちゃ</c><00:00:17.240><c>な</c><00:00:17.400><c>頃</c>

        00:00:20.150 --> 00:00:20.160 align:start position:0%
        やるちっちゃな頃

        00:00:20.160 --> 00:00:24.990 align:start position:0%
        やるちっちゃな頃
        大人<00:00:20.600><c>に</c><00:00:20.800><c>なっ</c><00:00:21.080><c>て</c><00:00:21.320><c>た</c>
        """

        let cues = parseVTT(raw)

        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues.map(\.text), ["やるちっちゃな頃", "大人になってた"])
        XCTAssertEqual(cues[1].sourceFragments.map(\.text), ["大人", "に", "なっ", "て", "た"])
    }

    func testParseVTTSkipsCueIdentifiersAndMetadataBlocks() {
        let raw = """
        WEBVTT

        STYLE
        ::cue { color: red; }

        REGION
        id:fred
        width:40%

        NOTE this block is not a cue
        00:00:00.000 --> 00:00:01.000
        Should not appear

        cue-1
        00:00:01.000 --> 00:00:03.000 align:start position:0%
        Hello<00:00:02.000><c> world</c>

        cue-2
        00:00:03.500 --> 00:00:04.500
        Next line
        """

        let cues = parseVTT(raw)

        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues.map(\.text), ["Hello world", "Next line"])
        XCTAssertEqual(cues[0].sourceFragments.map(\.text), ["Hello", "world"])
        XCTAssertFalse(cues.map(\.text).joined(separator: " ").contains("cue-"))
        XCTAssertFalse(cues.map(\.text).joined(separator: " ").contains("Should not appear"))
    }

    func testParseVTTCapsTrailingInlineDisplayHold() {
        let raw = """
        WEBVTT

        00:00:00.000 --> 00:00:10.000 align:start position:0%
        avoir<00:00:01.000><c> deux</c><00:00:02.000><c> euros</c>
        """

        let cues = parseVTT(raw)

        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].sourceFragments.map(\.text), ["avoir", "deux", "euros"])
        XCTAssertEqual(cues[0].sourceFragments[2].startSeconds, 2.0, accuracy: 0.001)
        XCTAssertEqual(cues[0].sourceFragments[2].endSeconds, 3.3, accuracy: 0.001)
    }

    func testParseVTTCapsNoInlineRollingDisplayHold() {
        let raw = """
        WEBVTT

        00:00:00.000 --> 00:00:03.000 align:start position:0%
        avoir<00:00:01.000><c> deux</c>

        00:00:03.000 --> 00:00:08.000 align:start position:0%
        avoir deux
        euros
        """

        let cues = parseVTT(raw)

        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[1].text, "euros")
        XCTAssertEqual(cues[1].sourceFragments.map(\.text), ["euros"])
        XCTAssertEqual(cues[1].sourceFragments[0].startSeconds, 3.0, accuracy: 0.001)
        XCTAssertEqual(cues[1].sourceFragments[0].endSeconds, 4.3, accuracy: 0.001)
    }

    func testParseVTTKeepsShortNoInlineRollingCueWindow() {
        let raw = """
        WEBVTT

        00:00:00.000 --> 00:00:03.000 align:start position:0%
        au<00:00:01.000><c> prix</c>

        00:00:03.000 --> 00:00:05.000 align:start position:0%
        au prix
        kilo.
        """

        let cues = parseVTT(raw)

        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[1].text, "kilo.")
        XCTAssertEqual(cues[1].sourceFragments.map(\.text), ["kilo."])
        XCTAssertEqual(cues[1].sourceFragments[0].startSeconds, 3.0, accuracy: 0.001)
        XCTAssertEqual(cues[1].sourceFragments[0].endSeconds, 5.0, accuracy: 0.001)
    }

    func testCleanCuesUsesVTTWordFragmentsForRollingCaptions() {
        let raw = """
        WEBVTT

        00:00:00.000 --> 00:00:02.000 align:start position:0%
        Hello<00:00:00.500><c> world</c>

        00:00:02.000 --> 00:00:02.010 align:start position:0%
        Hello world

        00:00:02.010 --> 00:00:04.000 align:start position:0%
        Hello world
        again<00:00:02.400><c> today.</c>
        """

        let cleaned = cleanCues(parseVTT(raw))

        XCTAssertEqual(cleaned.map(\.text), ["Hello world again today."])
        XCTAssertEqual(cleaned[0].start, "00:00:00,000")
        XCTAssertEqual(cleaned[0].end, "00:00:04,000")
    }

    func testCleanCuesTrimsVTTDisplayHoldAfterRollingPunctuationIsland() {
        let raw = """
        WEBVTT

        00:04:35.120 --> 00:04:40.629 align:start position:0%
        Ceux-là<00:04:35.960><c> viennent</c><00:04:36.800><c> du</c><00:04:37.320><c> Pérou</c><00:04:38.759><c> et</c><00:04:39.639><c> on</c><00:04:40.000><c> peut</c><00:04:40.320><c> en</c>

        00:04:40.639 --> 00:04:46.590 align:start position:0%
        Ceux-là viennent du Pérou et on peut en
        avoir<00:04:41.320><c> deux</c><00:04:41.960><c> pour</c><00:04:42.840><c> 3</c><00:04:43.199><c> €</c><00:04:44.680><c> 4,99</c>

        00:04:46.600 --> 00:04:50.350 align:start position:0%
        avoir deux pour 3 € 4,99
        €.

        00:04:50.360 --> 00:04:52.000 align:start position:0%
        Le<00:04:50.500><c> primeur</c>
        """

        let cleaned = cleanCues(parseVTT(raw))
        let priceCue = try! XCTUnwrap(cleaned.first { $0.text.contains("4,99") })

        XCTAssertLessThanOrEqual(srtTimeToSeconds(priceCue.end) ?? 0, 288.0)
    }

    func testParseVTTNoInlineCueKeepsSourceFragment() {
        let raw = """
        WEBVTT

        00:00:50.430 --> 00:00:55.610
        大家如果有來過台北的話，就知道台北的摩托車還蠻多的
        """

        let cues = parseVTT(raw)

        let cue = try! XCTUnwrap(cues.first)
        XCTAssertEqual(cue.sourceFragments.count, 1)
        XCTAssertEqual(cue.sourceFragments[0].text, "大家如果有來過台北的話，就知道台北的摩托車還蠻多的")
        XCTAssertEqual(cue.sourceFragments[0].startSeconds, 50.430, accuracy: 0.001)
        XCTAssertEqual(cue.sourceFragments[0].endSeconds, 55.610, accuracy: 0.001)
    }

    func testCleanCuesTrimsNoInlineVTTCJKIdleTailWithoutSplitting() {
        let raw = """
        WEBVTT

        00:02:05.100 --> 00:02:11.380
        大家應該有發現吧！如果你跟臺灣人一起出去玩，車上都有飲料

        00:02:11.660 --> 00:02:20.720
        剛剛我跟我姐去買飲料喝，這樣子開車的時候也比較有樂趣、比較好玩

        00:02:20.940 --> 00:02:32.470
        因為大概20分鐘的車程，所以喝一杯飲料剛剛好也不錯，現在在等紅綠燈
        """

        let cleaned = cleanCues(parseVTT(raw))
        let middle = try! XCTUnwrap(cleaned.first { $0.text.hasPrefix("剛剛我跟我姐") })

        XCTAssertEqual(cleaned.count, 3)
        XCTAssertEqual(middle.text, "剛剛我跟我姐去買飲料喝，這樣子開車的時候也比較有樂趣、比較好玩")
        XCTAssertGreaterThanOrEqual(srtTimeToSeconds(middle.start)!, 132.0)
        XCTAssertLessThanOrEqual(srtTimeToSeconds(middle.end)!, 140.5)
    }

    func testCleanCuesDoesNotClampVTTWordAnchorsBeforeRollingTransition() {
        let raw = """
        WEBVTT

        00:00:00.160 --> 00:00:01.350 align:start position:0%
        안녕하세요

        00:00:01.350 --> 00:00:01.360 align:start position:0%
        안녕하세요

        00:00:01.360 --> 00:00:06.150 align:start position:0%
        안녕하세요
        보세요<00:00:02.679><c> 드릴게</c><00:00:03.679><c> 진짜요</c><00:00:04.080><c> 와</c><00:00:04.359><c> 엄합니다</c>

        00:00:06.150 --> 00:00:06.160 align:start position:0%
        보세요 드릴게 진짜요 와 엄합니다

        00:00:06.160 --> 00:00:12.950 align:start position:0%
        보세요 드릴게 진짜요 와 엄합니다
        5점<00:00:07.160><c> 1점</c><00:00:08.400><c> 진짜</c><00:00:09.400><c> 점</c>
        """

        let cleaned = cleanCues(parseVTT(raw))

        guard let cue = cleaned.first(where: { $0.text.contains("엄합니다") }) else {
            return XCTFail("Expected cue containing 엄합니다, got: \(cleaned.map(\.text))")
        }
        let cleanedDescription = cleaned
            .map { "\($0.start) --> \($0.end) | \($0.text)" }
            .joined(separator: " / ")
        let end = srtTimeToSeconds(cue.end)!
        XCTAssertGreaterThanOrEqual(
            end,
            4.35,
            "VTT word-anchored rolling captions must not be clamped to a transition cue before the spoken word ends: \(cleanedDescription)"
        )
    }

    func testCleanCuesDoesNotClampManualShortVlogCueBeforeSourceEnd() {
        let raw = """
        1
        00:00:01,200 --> 00:00:03,360
        All right, so here we are, in front of the
        elephants

        2
        00:00:05,318 --> 00:00:07,974
        the cool thing about these guys is that they
        have really...

        3
        00:00:07,974 --> 00:00:12,616
        really really long trunks

        4
        00:00:12,616 --> 00:00:14,367
        and that's cool
        """

        let cleaned = cleanCues(parseSRT(raw))

        guard let cue = cleaned.first(where: { $0.text == "really really long trunks" }) else {
            return XCTFail("Expected short vlog cue, got: \(cleaned.map(\.text))")
        }
        let cleanedDescription = cleaned
            .map { "\($0.start) --> \($0.end) | \($0.text)" }
            .joined(separator: " / ")
        XCTAssertGreaterThanOrEqual(
            srtTimeToSeconds(cue.end)!,
            12.5,
            "Manual short vlog cue should not be clamped to a 1.9s display window before the source cue ends: \(cleanedDescription)"
        )
    }

    func testCleanCuesKeepsKoreanVTTWordAnchorsAcrossRollingCarry() {
        let raw = """
        WEBVTT

        00:00:04.270 --> 00:00:09.720 align:start position:0%
        [박수]
        아니야<00:00:04.840><c> 화면들이</c><00:00:05.290><c> 한번</c><00:00:05.590><c> 갈까요</c><00:00:05.920><c> 이제</c><00:00:06.550><c> 아</c><00:00:06.580><c> 여기서</c><00:00:07.359><c> 내용이다</c><00:00:07.750><c> 아예</c><00:00:08.400><c> 아무</c><00:00:09.400><c> 이상이</c>

        00:00:09.720 --> 00:00:09.730 align:start position:0%
        아니야 화면들이 한번 갈까요 이제 아 여기서 내용이다 아예 아무 이상이

        00:00:09.730 --> 00:00:12.600 align:start position:0%
        아니야 화면들이 한번 갈까요 이제 아 여기서 내용이다 아예 아무 이상이
        좋아요<00:00:10.420><c> 4면을</c><00:00:11.200><c> 있어</c><00:00:11.410><c> 좋다</c>
        """

        let cleaned = cleanCues(parseVTT(raw))

        guard let cue = cleaned.first(where: { $0.text.contains("좋다") }) else {
            return XCTFail("Expected cue containing 좋다, got: \(cleaned.map(\.text))")
        }
        let cleanedDescription = cleaned
            .map { "\($0.start) --> \($0.end) | \($0.text)" }
            .joined(separator: " / ")
        XCTAssertGreaterThanOrEqual(
            srtTimeToSeconds(cue.end)!,
            12.5,
            "Korean VTT rolling carry must keep the later word anchor instead of compressing the cue: \(cleanedDescription)"
        )
    }

    func testCleanCuesKeepsFirstWordFragmentAtReadableSplitBoundary() {
        let firstWords = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
        let secondWords = ["eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty."]

        func fragments(words: [String], start: Double) -> [SubtitleCueSourceFragment] {
            words.enumerated().map { index, word in
                SubtitleCueSourceFragment(
                    startSeconds: start + Double(index) * 0.5,
                    endSeconds: start + Double(index + 1) * 0.5,
                    text: word
                )
            }
        }

        let cues = [
            SubtitleCue(
                index: 1,
                start: "00:00:00,000",
                end: "00:00:05,000",
                text: firstWords.joined(separator: " "),
                sourceFragments: fragments(words: firstWords, start: 0)
            ),
            SubtitleCue(
                index: 2,
                start: "00:00:05,000",
                end: "00:00:10,000",
                text: firstWords.joined(separator: " ") + "\n" + secondWords.joined(separator: " "),
                sourceFragments: fragments(words: secondWords, start: 5)
            )
        ]

        let cleaned = cleanCues(cues)

        guard let second = cleaned.first(where: { $0.text.contains("eleven") }) else {
            return XCTFail("Expected readable split containing eleven, got: \(cleaned.map(\.text))")
        }
        XCTAssertEqual(second.start, "00:00:05,000")
        XCTAssertTrue(second.text.hasPrefix("eleven"))
    }

    func testCleanCuesDropsMultilingualNonSpeechMarkersBeforeTranslation() {
        let input = [
            SubtitleCue(index: 1, start: "00:00:00,000", end: "00:00:01,000", text: "[Music]"),
            SubtitleCue(index: 2, start: "00:00:01,000", end: "00:00:02,000", text: "[音乐][笑]"),
            SubtitleCue(index: 3, start: "00:00:02,000", end: "00:00:03,000", text: "Welcome [Music] back."),
            SubtitleCue(index: 4, start: "00:00:03,000", end: "00:00:04,000", text: "(Applause)"),
            SubtitleCue(index: 5, start: "00:00:04,000", end: "00:00:05,000", text: "(Acclamations)"),
            SubtitleCue(index: 6, start: "00:00:05,000", end: "00:00:06,000", text: "(Applaudissements)")
        ]

        let cleaned = cleanCues(input)

        XCTAssertEqual(cleaned.map(\.text), ["Welcome back."])
        XCTAssertFalse(cleaned.contains { $0.text.contains("[") || $0.text.contains("Music") || $0.text.contains("音乐") })
    }

    func testCleanCuesDropsBracketMarkersWithoutDependingOnLanguageTerms() {
        // 方括号 [] / 书名号【】里的内容一律删（不查词表，支持任意语言）；
        // 音符 ♪ 只去符号留歌词；圆括号 () 仍只在命中词表时删（保留对话括号）。
        let input = [
            SubtitleCue(index: 1, start: "00:00:00,000", end: "00:00:01,000", text: "[음악]"),
            SubtitleCue(index: 2, start: "00:00:01,000", end: "00:00:02,000", text: "Open [dramatic orchestral music] now"),
            SubtitleCue(index: 3, start: "00:00:02,000", end: "00:00:03,000", text: "続けて【効果音】話す"),
            SubtitleCue(index: 4, start: "00:00:03,000", end: "00:00:04,000", text: "♪sing this line♪"),
            SubtitleCue(index: 5, start: "00:00:04,000", end: "00:00:05,000", text: "Keep (important note) here")
        ]

        let cleaned = cleanCues(input)

        XCTAssertEqual(cleaned.map(\.text), [
            "Open now",
            "続けて話す",
            "sing this line",
            "Keep (important note) here"
        ])
    }

    func testCleanCuesNormalizesSubtitleEscapesBeforeCleaning() {
        // \N 硬换行 → 真换行；\h、&nbsp;、NBSP → 普通空格。与 Windows 对齐。
        let input = [
            SubtitleCue(index: 1, start: "00:00:00,000", end: "00:00:01,000",
                        text: "NVIDIA\\hCEO\\Nnext&nbsp;line\u{00A0}here")
        ]

        let cleaned = cleanCues(input)

        XCTAssertEqual(cleaned.count, 1)
        XCTAssertEqual(cleaned[0].text, "NVIDIA CEO\nnext line here")
    }

    func testCleanCuesStripsSpeakerChangeMarkers() {
        // 广播/CART 字幕的 ">>"/">>>" 说话人切换标记应被去掉，不应进入译文。
        let input = [
            SubtitleCue(index: 1, start: "00:00:00,000", end: "00:00:03,000", text: ">> 从1949年开始"),
            SubtitleCue(index: 2, start: "00:00:03,000", end: "00:00:06,000", text: ">>> Beginning in December"),
            SubtitleCue(index: 3, start: "00:00:06,000", end: "00:00:09,000", text: "蒋介石努力"),
            SubtitleCue(index: 4, start: "00:00:09,000", end: "00:00:12,000", text: "Hello >> world")
        ]

        let cleaned = cleanCues(input)

        XCTAssertEqual(cleaned.map(\.text), [
            "从1949年开始",
            "Beginning in December",
            "蒋介石努力",
            "Hello world"
        ])
        XCTAssertFalse(cleaned.contains { $0.text.contains(">>") })
    }

    func testCleanCuesKeepsInlineComparisonOperators() {
        // 行内 "a>>b"（无前导空白）不是说话人标记，不应被去掉。
        let input = [
            SubtitleCue(index: 1, start: "00:00:00,000", end: "00:00:03,000", text: "a>>b shift right")
        ]

        let cleaned = cleanCues(input)

        XCTAssertEqual(cleaned.map(\.text), ["a>>b shift right"])
    }

    func testCleanCuesDropsBroaderNonSpeechMarkersWithoutRemovingDialogueParentheses() {
        let input = [
            SubtitleCue(index: 1, start: "00:00:00,000", end: "00:00:01,000", text: "[Sighs]"),
            SubtitleCue(index: 2, start: "00:00:01,000", end: "00:00:02,000", text: "Start [door opens] now"),
            SubtitleCue(index: 3, start: "00:00:02,000", end: "00:00:03,000", text: "Keep (important note) here"),
            SubtitleCue(index: 4, start: "00:00:03,000", end: "00:00:04,000", text: "继续【掌声继续】讲")
        ]

        let cleaned = cleanCues(input)

        XCTAssertEqual(cleaned.map(\.text), [
            "Start now",
            "Keep (important note) here",
            "继续讲"
        ])
    }

    private func assertReadableSemanticWindows(
        _ cleaned: [SubtitleCue],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(cleaned.isEmpty, file: file, line: line)
        for cue in cleaned {
            let start = try! XCTUnwrap(srtTimeToSeconds(cue.start), file: file, line: line)
            let end = try! XCTUnwrap(srtTimeToSeconds(cue.end), file: file, line: line)
            XCTAssertGreaterThanOrEqual(end, start, file: file, line: line)
            XCTAssertLessThanOrEqual(end - start, 12.2, "Cue 过长：\(cue.start) --> \(cue.end)", file: file, line: line)
        }
        for index in 1..<cleaned.count {
            let previousEnd = try! XCTUnwrap(srtTimeToSeconds(cleaned[index - 1].end), file: file, line: line)
            let start = try! XCTUnwrap(srtTimeToSeconds(cleaned[index].start), file: file, line: line)
            XCTAssertGreaterThanOrEqual(start, previousEnd, file: file, line: line)
        }
    }

    private func assertNoBadSemanticBoundaries(
        _ cleaned: [SubtitleCue],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let weakEnds: Set<String> = ["a", "an", "the", "to", "of", "and", "or", "but", "that", "which", "what", "is", "are", "in"]
        let weakStarts: Set<String> = ["and", "or", "but", "that", "which", "who", "whose", "when", "where", "why", "how", "to", "of", "for", "with", "in"]
        func words(_ text: String) -> [String] {
            text.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
        }
        for index in cleaned.indices {
            let tokens = words(cleaned[index].text)
            if index < cleaned.count - 1, let last = tokens.last {
                XCTAssertFalse(weakEnds.contains(last), "Bad semantic tail: \(cleaned[index].text)", file: file, line: line)
            }
            if index > 0, let first = tokens.first {
                XCTAssertFalse(weakStarts.contains(first), "Bad semantic head: \(cleaned[index].text)", file: file, line: line)
            }
        }
    }

    func testCleanCuesContinuationSentenceKeepsTextButSplitsReadableWindows() {
        let input = [
            SubtitleCue(index: 1, start: "00:00:00,000", end: "00:00:04,000", text: "we know it what is the vision for what"),
            SubtitleCue(index: 2, start: "00:00:03,500", end: "00:00:08,000", text: "you see coming next we asked ourselves"),
            SubtitleCue(index: 3, start: "00:00:07,500", end: "00:00:12,000", text: "if it can do this how far can it go how"),
            SubtitleCue(index: 4, start: "00:00:11,500", end: "00:00:15,000", text: "do we get from the robots we have now?")
        ]

        let cleaned = cleanCues(input)

        XCTAssertGreaterThan(
            cleaned.count,
            1,
            cleaned.map { "\($0.start) --> \($0.end) :: \($0.text)" }.joined(separator: " | ")
        )
        XCTAssertEqual(cleaned.first?.start, "00:00:00,000")
        XCTAssertEqual(cleaned.last?.end, "00:00:15,000")
        XCTAssertEqual(
            cleaned.map(\.text).joined(separator: " "),
            "we know it what is the vision for what you see coming next we asked ourselves if it can do this how far can it go how do we get from the robots we have now?"
        )
        for cue in cleaned {
            let start = try! XCTUnwrap(srtTimeToSeconds(cue.start))
            let end = try! XCTUnwrap(srtTimeToSeconds(cue.end))
            XCTAssertLessThanOrEqual(end - start, 12.2, "Cue 过长：\(cue.start) --> \(cue.end)")
        }
        assertNoBadSemanticBoundaries(cleaned)
    }

    func testCleanCuesSplitsLongRollingCaptionWithoutWeakSemanticBoundaries() {
        let raw = """
        1
        00:00:00,080 --> 00:00:02,000
        this is the

        2
        00:00:02,000 --> 00:00:02,010
        this is the


        3
        00:00:02,010 --> 00:00:05,000
        this is the
        story of the

        4
        00:00:05,000 --> 00:00:05,010
        story of the


        5
        00:00:05,010 --> 00:00:08,000
        story of the
        people who

        6
        00:00:08,000 --> 00:00:08,010
        people who


        7
        00:00:08,010 --> 00:00:12,000
        people who
        wanted to learn how to speak English.
        """

        let cleaned = cleanCues(parseSRT(raw))

        XCTAssertEqual(cleaned.first?.start, "00:00:00,080")
        XCTAssertLessThanOrEqual(
            try XCTUnwrap(srtTimeToSeconds(cleaned.last?.end ?? "")),
            try XCTUnwrap(srtTimeToSeconds("00:00:12,200"))
        )
        XCTAssertEqual(
            cleaned.map(\.text).joined(separator: " "),
            "this is the story of the people who wanted to learn how to speak English."
        )
        assertReadableSemanticWindows(cleaned)
        assertNoBadSemanticBoundaries(cleaned)
    }

    func testCleanCuesStarshipSnippetKeepsReadableSemanticBoundaries() throws {
        let raw = """
        1
        00:02:28,239 --> 00:02:32,849
        We are in Starfactory and this is an

        2
        00:02:32,849 --> 00:02:32,859
        We are in Starfactory and this is an


        3
        00:02:32,859 --> 00:02:37,460
        We are in Starfactory and this is an
        almost 1 million square ft facility that we've built

        4
        00:02:37,460 --> 00:02:37,470
        almost 1 million square ft facility that we've built


        5
        00:02:37,470 --> 00:02:42,070
        almost 1 million square ft facility that we've built
        to enable that production of both ship and booster.
        """

        let cleaned = cleanCues(parseSRT(raw))

        XCTAssertLessThan(cleaned.count, 3, "不应把一个完整意群硬切成三段残句")
        XCTAssertEqual(cleaned.first?.start, "00:02:28,239")
        let latestEnd = try XCTUnwrap(srtTimeToSeconds(cleaned.map(\.end).max() ?? ""))
        let earliestStart = try XCTUnwrap(srtTimeToSeconds(cleaned.map(\.start).min() ?? ""))
        XCTAssertLessThanOrEqual(latestEnd - earliestStart, 14.0)
        XCTAssertEqual(
            cleaned.map(\.text).joined(separator: " "),
            "We are in Starfactory and this is an almost 1 million square ft facility that we've built to enable that production of both ship and booster."
        )
        assertReadableSemanticWindows(cleaned)
        assertNoBadSemanticBoundaries(cleaned)
        XCTAssertFalse(cleaned.contains { $0.text == "." || $0.text == "。" || $0.text == "-" || $0.text == "—" })
    }

    func testCleanCuesStarshipVTTKeepsFinalSourceWordsVisible() throws {
        let raw = """
        WEBVTT

        00:04:13.599 --> 00:04:15.670 align:start position:0%
        [music]
        &gt;&gt; And<00:04:13.760><c> so</c><00:04:14.000><c> those</c><00:04:14.239><c> pieces,</c><00:04:14.720><c> which</c><00:04:15.120><c> at</c><00:04:15.360><c> the</c><00:04:15.519><c> time</c>

        00:04:15.670 --> 00:04:15.680 align:start position:0%
        &gt;&gt; And so those pieces, which at the time


        00:04:15.680 --> 00:04:18.150 align:start position:0%
        &gt;&gt; And so those pieces, which at the time
        did<00:04:15.920><c> not</c><00:04:16.079><c> seem</c><00:04:16.400><c> small</c><00:04:16.639><c> at</c><00:04:16.880><c> all,</c><00:04:17.440><c> were</c><00:04:17.759><c> Falcon</c>

        00:04:18.150 --> 00:04:18.160 align:start position:0%
        did not seem small at all, were Falcon


        00:04:18.160 --> 00:04:20.949 align:start position:0%
        did not seem small at all, were Falcon
        1,

        00:04:31.199 --> 00:04:33.110 align:start position:0%
        Falcon Heavy.
        &gt;&gt; Falcon<00:04:31.600><c> Heavy</c><00:04:31.919><c> is</c><00:04:32.080><c> supersonic.</c>

        00:04:33.110 --> 00:04:33.120 align:start position:0%
        &gt;&gt; Falcon Heavy is supersonic.


        00:04:33.120 --> 00:04:34.950 align:start position:0%
        &gt;&gt; Falcon Heavy is supersonic.
        &gt;&gt; These<00:04:33.360><c> were</c><00:04:33.520><c> the</c><00:04:33.759><c> building</c><00:04:34.080><c> blocks</c><00:04:34.479><c> that</c><00:04:34.800><c> let</c>

        00:04:34.950 --> 00:04:34.960 align:start position:0%
        &gt;&gt; These were the building blocks that let


        00:04:34.960 --> 00:04:37.350 align:start position:0%
        &gt;&gt; These were the building blocks that let
        us<00:04:35.199><c> cut</c><00:04:35.360><c> our</c><00:04:35.600><c> teeth</c><00:04:36.160><c> on</c><00:04:36.479><c> learning</c><00:04:36.800><c> how</c><00:04:36.960><c> to</c><00:04:37.120><c> do</c>

        00:04:37.350 --> 00:04:37.360 align:start position:0%
        us cut our teeth on learning how to do


        00:04:37.360 --> 00:04:39.909 align:start position:0%
        us cut our teeth on learning how to do
        rockets.
        """

        let cleaned = cleanCues(parseVTT(raw))
        let falconOne = try XCTUnwrap(cleaned.first { $0.text.contains("were Falcon 1,") })
        let rockets = try XCTUnwrap(cleaned.first { $0.text.contains("learning how to do rockets.") })

        XCTAssertGreaterThanOrEqual(
            try XCTUnwrap(srtTimeToSeconds(falconOne.end)),
            try XCTUnwrap(srtTimeToSeconds("00:04:20,949"))
        )
        XCTAssertGreaterThanOrEqual(
            try XCTUnwrap(srtTimeToSeconds(rockets.end)),
            try XCTUnwrap(srtTimeToSeconds("00:04:39,909"))
        )
        XCTAssertFalse(cleaned.contains { $0.text.contains("[music]") || $0.text.contains(">>") })
        assertReadableSemanticWindows(cleaned)
        assertNoBadSemanticBoundaries(cleaned)
    }

    func testCleanCuesShortLongCueIsCappedWithoutCharacterSplitting() {
        let raw = """
        1
        00:14:21,040 --> 00:14:46,215
        Copy.

        2
        00:15:06,800 --> 00:15:21,590
        What heat?
        """

        let cleaned = cleanCues(parseSRT(raw))

        XCTAssertEqual(cleaned.map(\.text), ["Copy.", "What heat?"])
        assertReadableSemanticWindows(cleaned)
        XCTAssertEqual(cleaned.first?.start, "00:14:21,040")
        XCTAssertEqual(cleaned.first?.end, "00:14:23,040")
        XCTAssertEqual(cleaned.last?.start, "00:15:06,800")
        XCTAssertEqual(cleaned.last?.end, "00:15:08,800")
    }

    func testCleanCuesShortCJKFeedbackIsCappedWithoutSingleCharacterSplitting() {
        let raw = """
        1
        00:00:10,000 --> 00:00:30,000
        没问题
        """

        let cleaned = cleanCues(parseSRT(raw))

        XCTAssertEqual(cleaned.map(\.text), ["没问题"])
        XCTAssertEqual(cleaned.first?.start, "00:00:10,000")
        XCTAssertEqual(cleaned.first?.end, "00:00:11,500")
    }

    func testCleanCuesLongCJKCueDoesNotSplitIntoSingletonCharacters() {
        let raw = """
        1
        00:00:00,000 --> 00:00:24,000
        今天我们先看一下这个问题然后再继续往下讲
        """

        let cleaned = cleanCues(parseSRT(raw))
        if cleaned.count <= 1 {
            XCTFail(cleaned.map { "\($0.start) --> \($0.end) :: \($0.text)" }.joined(separator: " | "))
        }
        XCTAssertGreaterThan(cleaned.count, 1)
        XCTAssertEqual(
            cleaned.map(\.text).joined(),
            "今天我们先看一下这个问题然后再继续往下讲"
        )
        XCTAssertFalse(cleaned.contains { $0.text.filter { !$0.isWhitespace }.count == 1 })
        assertReadableSemanticWindows(cleaned)
    }

    func testCleanCuesKoreanPreservesWordSpaces() {
        let raw = """
        1
        00:03:00,077 --> 00:03:04,181
        내가 서 있는 곳에
        정확히 멈추는 버스의 제동 소리.

        2
        00:03:05,015 --> 00:03:08,885
        터벅터벅 집을 향해 걸어가는
        나의 발걸음과
        """

        let cleaned = cleanCues(parseSRT(raw))

        let joined = cleaned.map(\.text).joined(separator: " ")
        XCTAssertTrue(joined.contains("내가 서 있는 곳에"))
        XCTAssertTrue(joined.contains("정확히 멈추는 버스의 제동 소리."))
        XCTAssertTrue(joined.contains("터벅터벅 집을 향해 걸어가는"))
        XCTAssertFalse(joined.contains("내가서있는곳에"))
        XCTAssertFalse(joined.contains("멈추는버스의제동소리"))
    }

    func testCleanCuesKoreanSplitsOnWordBoundaries() {
        let raw = """
        1
        00:03:09,019 --> 00:03:22,490
        현관을 들어서면 나를 반겨주는 반려 동물의 울음 소리와 조용히 움직이는 가족의 목소리.
        """

        let cleaned = cleanCues(parseSRT(raw))

        XCTAssertGreaterThan(cleaned.count, 1)
        XCTAssertEqual(
            cleaned.map(\.text).joined(separator: " "),
            "현관을 들어서면 나를 반겨주는 반려 동물의 울음 소리와 조용히 움직이는 가족의 목소리."
        )
        XCTAssertFalse(cleaned.contains { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("반겨주") })
        XCTAssertFalse(cleaned.contains { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("는 ") })
    }

    func testCleanCuesManualMultilineKoreanCueIsNotSplit() {
        let raw = """
        1
        00:03:35,378 --> 00:03:40,817
        그런데 ‘소리가 없다‘,
        ‘소리가 전혀 들리지 않는다’라는,
        """

        let cleaned = cleanCues(parseSRT(raw))

        XCTAssertEqual(cleaned.count, 1)
        XCTAssertEqual(cleaned.first?.start, "00:03:35,378")
        XCTAssertEqual(cleaned.first?.end, "00:03:40,817")
        XCTAssertEqual(cleaned.first?.text, "그런데 ‘소리가 없다‘,\n‘소리가 전혀 들리지 않는다’라는,")
    }

    func testCleanCuesManualSingleLineKoreanCueKeepsEndTiming() {
        let raw = """
        1
        00:03:27,537 --> 00:03:30,640
        끊임없이 소리를 듣고,
        """

        let cleaned = cleanCues(parseSRT(raw))

        XCTAssertEqual(cleaned.count, 1)
        XCTAssertEqual(cleaned.first?.start, "00:03:27,537")
        XCTAssertEqual(cleaned.first?.end, "00:03:30,640")
        XCTAssertEqual(cleaned.first?.text, "끊임없이 소리를 듣고,")
    }

    func testCleanCuesManualMultilineCJKCueIsNotSplit() {
        let raw = """
        1
        00:02:01,044 --> 00:02:05,724
        參與了很多心靈成長課程、
        工作坊，飛到國外找大師，
        """

        let cleaned = cleanCues(parseSRT(raw))

        XCTAssertEqual(cleaned.count, 1)
        XCTAssertEqual(cleaned.first?.start, "00:02:01,044")
        XCTAssertEqual(cleaned.first?.end, "00:02:05,724")
        XCTAssertEqual(cleaned.first?.text, "參與了很多心靈成長課程、\n工作坊，飛到國外找大師，")
    }

    func testCleanCuesRollingCJKUsesReadableSourceAnchoredPieces() {
        let raw = """
        1
        00:01:09,080 --> 00:01:12,000
        あったわけで働きたいです

        2
        00:01:12,000 --> 00:01:12,010
        あったわけで働きたいです

        3
        00:01:12,010 --> 00:01:15,890
        あったわけで働きたいです
        東京がわかるんですよそう東京で
        """

        let cleaned = cleanCues(parseSRT(raw))

        XCTAssertGreaterThan(cleaned.count, 1)
        XCTAssertEqual(
            cleaned.map(\.text).joined(),
            "あったわけで働きたいです東京がわかるんですよそう東京で"
        )
        XCTAssertFalse(cleaned.contains { $0.text.filter { !$0.isWhitespace }.count == 1 })
        assertReadableSemanticWindows(cleaned)
    }

    func testCleanCuesJapaneseVTTUsesReadableSourceBoundaries() {
        let raw = """
        WEBVTT

        00:00:19.140 --> 00:00:20.510 align:start position:0%
        えーと今
        昨日<00:00:19.320><c>あの</c><00:00:19.740><c>弟</c><00:00:19.740><c>の</c>

        00:00:20.510 --> 00:00:20.520 align:start position:0%
        昨日あの弟の

        00:00:20.520 --> 00:00:24.890 align:start position:0%
        昨日あの弟の
        家に<00:00:20.820><c>泊まっ</c><00:00:20.939><c>て</c><00:00:21.380><c>そう</c><00:00:22.380><c>です</c><00:00:22.500><c>ね</c><00:00:22.640><c>ちょっと</c><00:00:23.640><c>今日</c><00:00:24.539><c>の</c>

        00:00:24.890 --> 00:00:24.900 align:start position:0%
        家に泊まってそうですねちょっと今日の

        00:00:24.900 --> 00:00:25.790 align:start position:0%
        家に泊まってそうですねちょっと今日の
        キャンプ<00:00:25.080><c>の</c>

        00:00:25.790 --> 00:00:25.800 align:start position:0%
        キャンプの

        00:00:25.800 --> 00:00:28.310 align:start position:0%
        キャンプの
        準備<00:00:25.920><c>を</c><00:00:26.039><c>し</c><00:00:26.160><c>て</c><00:00:26.160><c>い</c><00:00:26.279><c>ます</c>

        00:00:28.320 --> 00:00:32.450 align:start position:0%
        任天<00:00:28.500><c>堂</c><00:00:28.680><c>スイッチ</c><00:00:28.820><c>も</c><00:00:30.000><c>持っ</c><00:00:30.000><c>て</c><00:00:30.060><c>いき</c><00:00:30.180><c>ます</c><00:00:30.180><c>よ</c><00:00:30.500><c>一応</c><00:00:31.500><c>ね</c>
        """

        let cleaned = cleanCues(parseVTT(raw))
        let combined = cleaned.map(\.text).joined()

        XCTAssertEqual(
            combined,
            "えーと今昨日あの弟の家に泊まってそうですねちょっと今日のキャンプの準備をしています任天堂スイッチも持っていきますよ一応ね"
        )
        XCTAssertGreaterThan(cleaned.count, 1)
        XCTAssertFalse(cleaned.contains { $0.text.hasSuffix("泊") || $0.text.hasPrefix("まって") })
        XCTAssertFalse(cleaned.contains { $0.text.hasSuffix("ちょ") || $0.text.hasPrefix("っと") })
        XCTAssertFalse(cleaned.contains { $0.text.hasSuffix("スイ") || $0.text.hasPrefix("ッチ") })
        XCTAssertFalse(cleaned.contains { $0.text.filter { !$0.isWhitespace }.count <= 3 && cleaned.count > 1 })
        assertReadableSemanticWindows(cleaned)
    }

    func testCleanCuesJapaneseVTTTrimsTerminalDisplayHold() throws {
        let raw = """
        WEBVTT

        00:00:28.320 --> 00:00:32.450 align:start position:0%
        任天<00:00:28.500><c>堂</c><00:00:28.680><c>スイッチ</c><00:00:28.820><c>も</c><00:00:30.000><c>持っ</c><00:00:30.000><c>て</c><00:00:30.060><c>いき</c><00:00:30.180><c>ます</c><00:00:30.180><c>よ</c><00:00:30.500><c>一応</c><00:00:31.500><c>ね</c>

        00:00:32.450 --> 00:00:32.460 align:start position:0%
        任天堂スイッチも持っていきますよ一応ね

        00:00:32.460 --> 00:00:36.110 align:start position:0%
        任天堂スイッチも持っていきますよ一応ね
        はい<00:00:32.759><c>たくさん</c><00:00:33.899><c>荷物</c><00:00:34.020><c>が</c><00:00:34.200><c>あり</c><00:00:34.260><c>ます</c><00:00:34.260><c>ね</c>

        00:00:36.110 --> 00:00:36.120 align:start position:0%
        はいたくさん荷物がありますね

        00:00:36.120 --> 00:00:39.290 align:start position:0%
        はいたくさん荷物がありますね
        楽しみ<00:00:36.300><c>です</c><00:00:36.360><c>か</c>
        """

        let cleaned = cleanCues(parseVTT(raw))
        let parsedCue = try XCTUnwrap(parseVTT(raw).first { $0.text.contains("楽しみですか") })
        XCTAssertEqual(parsedCue.sourceFragments.map(\.text), ["楽しみ", "です", "か"])
        XCTAssertLessThanOrEqual(parsedCue.sourceFragments.last?.endSeconds ?? 0, 37.9)
        let cue = try XCTUnwrap(cleaned.first { $0.text.contains("楽しみですか") })

        XCTAssertLessThanOrEqual(try XCTUnwrap(srtTimeToSeconds(cue.end)), 37.9)
    }

    func testCleanCuesJapaneseVTTMergesShortKanaFragments() throws {
        let raw = """
        WEBVTT

        00:02:58.040 --> 00:03:01.070 align:start position:0%
        マジで
        おなら<00:02:59.360><c>つまら</c><00:03:00.360><c>ない</c><00:03:00.420><c>おなら</c><00:03:00.840><c>」</c><00:03:00.900><c>って</c><00:03:00.959><c>書い</c><00:03:01.019><c>て</c><00:03:01.080><c>ある</c>

        00:03:01.070 --> 00:03:01.080 align:start position:0%
        おならつまらないおなら」って書いてある

        00:03:01.080 --> 00:03:08.030 align:start position:0%
        おならつまらないおなら」って書いてある
        や<00:03:01.200><c>ん</c>
        """

        let cleaned = cleanCues(parseVTT(raw))
        let joined = cleaned.map(\.text).joined()

        XCTAssertTrue(joined.contains("やん"))
        XCTAssertFalse(cleaned.contains { $0.text == "や" || $0.text == "ん" })
        XCTAssertFalse(cleaned.contains {
            guard let start = srtTimeToSeconds($0.start), let end = srtTimeToSeconds($0.end) else { return false }
            return end - start <= 0.08 && $0.text.contains("おなら")
        })
        let cue = try XCTUnwrap(cleaned.first { $0.text == "やん" })
        XCTAssertLessThanOrEqual(try XCTUnwrap(srtTimeToSeconds(cue.end)), 182.5)
    }

    func testCleanCuesDenseShortCJKCueDoesNotSplitIntoBlinkPieces() {
        let raw = """
        1
        00:01:25,510 --> 00:01:27,510
        美味しい食べ物がはいっぱいありますああそうですか便利じゃないですか
        """

        let cleaned = cleanCues(parseSRT(raw))

        XCTAssertEqual(cleaned.count, 1)
        XCTAssertEqual(cleaned.first?.start, "00:01:25,510")
        XCTAssertEqual(cleaned.first?.end, "00:01:27,510")
    }

    func testCleanCuesReadableCJKCueWithoutSourceAnchorsIsNotBlindlySplit() {
        let raw = """
        1
        00:00:50,430 --> 00:00:55,610
        大家如果有來過台北的話，就知道台北的摩托車還蠻多的
        """

        let cleaned = cleanCues(parseSRT(raw))

        XCTAssertEqual(cleaned.count, 1)
        XCTAssertEqual(cleaned.first?.start, "00:00:50,430")
        XCTAssertEqual(cleaned.first?.end, "00:00:55,610")
        XCTAssertEqual(cleaned.first?.text, "大家如果有來過台北的話，就知道台北的摩托車還蠻多的")
    }

    func testCleanCuesSlightlyLongCJKCueWithoutSourceAnchorsKeepsSourceWindow() {
        let raw = """
        1
        00:00:55,670 --> 00:01:04,770
        今天路上感覺車還好，然後天氣沒有下雨，但是不是晴天，沒有太陽
        """

        let cleaned = cleanCues(parseSRT(raw))

        XCTAssertEqual(cleaned.count, 1)
        XCTAssertEqual(cleaned.first?.start, "00:00:55,670")
        XCTAssertEqual(cleaned.first?.end, "00:01:04,770")
        XCTAssertEqual(cleaned.first?.text, "今天路上感覺車還好，然後天氣沒有下雨，但是不是晴天，沒有太陽")
    }

    func testCleanCuesNoAnchorCJKCueUnderHardWindowKeepsSourceWindow() {
        let raw = """
        1
        00:01:16,360 --> 00:01:29,220
        那我們現在可以來學一些車上的字，後照鏡可以看到後面的車
        """

        let cleaned = cleanCues(parseSRT(raw))

        XCTAssertEqual(cleaned.count, 1)
        XCTAssertEqual(cleaned.first?.start, "00:01:16,360")
        XCTAssertEqual(cleaned.first?.end, "00:01:29,220")
        XCTAssertEqual(cleaned.first?.text, "那我們現在可以來學一些車上的字，後照鏡可以看到後面的車")
    }

    func testCleanCuesCJKCueWithDigitsIsNotCappedAsShortFeedback() {
        let raw = """
        1
        00:02:20,940 --> 00:02:32,470
        因為大概20分鐘的車程，所以喝一杯飲料剛剛好 也不錯，現在在等紅綠燈
        """

        let cleaned = cleanCues(parseSRT(raw))

        XCTAssertEqual(cleaned.count, 1)
        XCTAssertEqual(cleaned.first?.start, "00:02:20,940")
        XCTAssertEqual(cleaned.first?.end, "00:02:32,470")
        XCTAssertEqual(cleaned.first?.text, "因為大概20分鐘的車程，所以喝一杯飲料剛剛好也不錯，現在在等紅綠燈")
    }

    func testCleanCuesRollingTailUsesSpeechAlignedWindowInsteadOfSourceDrag() {
        let raw = """
        1
        00:05:36,240 --> 00:05:39,350
        It's because we need that size to do the

        2
        00:05:39,350 --> 00:05:39,360
        It's because we need that size to do the

        3
        00:05:39,360 --> 00:06:19,270
        It's because we need that size to do the
        things we dream of doing with it.
        """

        let cleaned = cleanCues(parseSRT(raw))

        XCTAssertEqual(cleaned.first?.start, "00:05:36,240")
        XCTAssertLessThanOrEqual(
            try XCTUnwrap(srtTimeToSeconds(cleaned.last?.end ?? "")),
            try XCTUnwrap(srtTimeToSeconds("00:05:45,240")),
            "滚动字幕的异常源拖尾不应把完整短句拖到几十秒"
        )
        XCTAssertEqual(
            cleaned.map(\.text).joined(separator: " "),
            "It's because we need that size to do the things we dream of doing with it."
        )
        XCTAssertFalse(cleaned.contains { $0.text == "C" || $0.text == "op" || $0.text == "y." })
        assertReadableSemanticWindows(cleaned)
        assertNoBadSemanticBoundaries(cleaned)
    }

    func testCleanCuesRollingSplitsStayAnchoredToSourceTiming() throws {
        let questionRaw = """
        1
        00:00:43,120 --> 00:00:44,630
        All right, test all B19 operators. This
        final go now go pull for today's

        2
        00:00:44,630 --> 00:00:44,640
        final go now go pull for today's

        3
        00:00:44,640 --> 00:00:46,869
        final go now go pull for today's
        operations. Our main objective today is

        4
        00:00:46,869 --> 00:00:46,879
        operations. Our main objective today is

        5
        00:00:46,879 --> 00:00:48,950
        operations. Our main objective today is
        a 10 engine static fire.

        6
        00:00:48,950 --> 00:00:48,960
        a 10 engine static fire.

        7
        00:00:48,960 --> 00:00:51,590
        a 10 engine static fire.
        >> Why 10 engines instead of all 33? This

        8
        00:00:51,590 --> 00:00:51,600
        >> Why 10 engines instead of all 33? This

        9
        00:00:51,600 --> 00:00:53,750
        >> Why 10 engines instead of all 33? This
        is the first V3 booster down at the pad
        """

        let cleanedQuestion = cleanCues(parseSRT(questionRaw))
        guard let whyCue = cleanedQuestion.first(where: { $0.text == "Why 10 engines instead of all 33?" }) else {
            return XCTFail("Expected source-anchored question cue, got: \(cleanedQuestion.map(\.text))")
        }
        let whyStart = try XCTUnwrap(srtTimeToSeconds(whyCue.start))
        let whyEnd = try XCTUnwrap(srtTimeToSeconds(whyCue.end))
        XCTAssertGreaterThanOrEqual(
            whyEnd - whyStart,
            2.2
        )
        XCTAssertGreaterThanOrEqual(
            whyEnd,
            try XCTUnwrap(srtTimeToSeconds("00:00:51,000")),
            "The question should stay visible until its source window has mostly completed."
        )
        if let mainCue = cleanedQuestion.first(where: { $0.text == "Our main objective today is a 10 engine static fire." }) {
            XCTAssertGreaterThanOrEqual(
                try XCTUnwrap(srtTimeToSeconds(mainCue.start)),
                try XCTUnwrap(srtTimeToSeconds("00:00:45,430")),
                "A new sentence should not appear immediately at the previous source boundary."
            )
        } else {
            XCTFail("Expected main objective cue, got: \(cleanedQuestion.map(\.text))")
        }
        if let firstV3Cue = cleanedQuestion.first(where: { $0.text.hasPrefix("This is the first V3") }) {
            XCTAssertGreaterThanOrEqual(
                try XCTUnwrap(srtTimeToSeconds(firstV3Cue.start)),
                try XCTUnwrap(srtTimeToSeconds(whyCue.end)),
                "The next sentence should not be pulled before the question finishes."
            )
        }

        let moonRaw = """
        1
        00:05:03,520 --> 00:05:05,430
        foundational design of Starship booster
        in the pad. That's going to give us the

        2
        00:05:05,430 --> 00:05:05,440
        in the pad. That's going to give us the

        3
        00:05:05,440 --> 00:05:07,430
        in the pad. That's going to give us the
        new capabilities we need to do the

        4
        00:05:07,430 --> 00:05:07,440
        new capabilities we need to do the

        5
        00:05:07,440 --> 00:05:09,510
        new capabilities we need to do the
        missions in front of us. It'll be the

        6
        00:05:09,510 --> 00:05:09,520
        missions in front of us. It'll be the

        7
        00:05:09,520 --> 00:05:11,670
        missions in front of us. It'll be the
        one that puts humans back on the moon.
        """

        let cleanedMoon = cleanCues(parseSRT(moonRaw))
        guard let moonCue = cleanedMoon.first(where: { $0.text == "It'll be the one that puts humans back on the moon." }) else {
            return XCTFail("Expected complete moon sentence, got: \(cleanedMoon.map(\.text))")
        }
        let moonStart = try XCTUnwrap(srtTimeToSeconds(moonCue.start))
        let moonExpectedStart = try XCTUnwrap(srtTimeToSeconds("00:05:09,520"))
        XCTAssertLessThanOrEqual(
            abs(moonStart - moonExpectedStart),
            0.25
        )
        XCTAssertGreaterThanOrEqual(
            try XCTUnwrap(srtTimeToSeconds(moonCue.end)),
            try XCTUnwrap(srtTimeToSeconds("00:05:11,400"))
        )
        XCTAssertFalse(cleanedMoon.contains { $0.text == "It'll be the one that puts" })
        XCTAssertFalse(cleanedMoon.contains { $0.text == "humans back on the moon." })
    }

    func testCleanCuesRollingRomanceFragmentBorrowDoesNotDelayMidSentenceStart() throws {
        let raw = """
        1
        00:01:15,479 --> 00:01:18,649
        el tiempo descubrí que no
        no tengo el poder de leer Mentes pero

        2
        00:01:18,649 --> 00:01:18,659
        no tengo el poder de leer Mentes pero

        3
        00:01:18,659 --> 00:01:20,210
        no tengo el poder de leer Mentes pero
        poco a poco fui desarrollando la

        4
        00:01:20,210 --> 00:01:20,220
        poco a poco fui desarrollando la

        5
        00:01:20,220 --> 00:01:22,670
        poco a poco fui desarrollando la
        habilidad de conectar y sobre todo

        6
        00:01:22,670 --> 00:01:22,680
        habilidad de conectar y sobre todo

        7
        00:01:22,680 --> 00:01:26,149
        habilidad de conectar y sobre todo
        entender los corazones de ahí surgió mi

        8
        00:01:26,149 --> 00:01:26,159
        entender los corazones de ahí surgió mi

        9
        00:01:26,159 --> 00:01:27,830
        entender los corazones de ahí surgió mi
        verdadera Pasión por todo el mundo del

        10
        00:01:27,830 --> 00:01:27,840
        verdadera Pasión por todo el mundo del

        11
        00:01:27,840 --> 00:01:29,690
        verdadera Pasión por todo el mundo del
        lenguaje no verbal todo lo que me

        12
        00:01:29,690 --> 00:01:29,700
        lenguaje no verbal todo lo que me

        13
        00:01:29,700 --> 00:01:31,609
        lenguaje no verbal todo lo que me
        pudiera empezar a platicar la historia

        14
        00:01:31,609 --> 00:01:31,619
        pudiera empezar a platicar la historia

        15
        00:01:31,619 --> 00:01:33,710
        pudiera empezar a platicar la historia
        de las personas que tenía enfrente su

        16
        00:01:33,710 --> 00:01:33,720
        de las personas que tenía enfrente su

        17
        00:01:33,720 --> 00:01:36,109
        de las personas que tenía enfrente su
        lenguaje corporal su lenguaje facial la

        18
        00:01:36,109 --> 00:01:36,119
        lenguaje corporal su lenguaje facial la

        19
        00:01:36,119 --> 00:01:39,469
        lenguaje corporal su lenguaje facial la
        ropa los movimientos el tono de voz todo

        20
        00:01:39,469 --> 00:01:39,479
        ropa los movimientos el tono de voz todo

        21
        00:01:39,479 --> 00:01:41,510
        ropa los movimientos el tono de voz todo
        lo que me dijera Quién era la persona

        22
        00:01:41,510 --> 00:01:41,520
        lo que me dijera Quién era la persona

        23
        00:01:41,520 --> 00:01:44,510
        lo que me dijera Quién era la persona
        que estaba enfrente de mí eso con el
        """

        let cleaned = cleanCues(parseSRT(raw))

        guard let cue = cleaned.first(where: { $0.text.contains("a platicar la historia") }) else {
            return XCTFail("Expected Spanish mid-sentence cue, got: \(cleaned.map(\.text))")
        }
        XCTAssertLessThanOrEqual(
            try XCTUnwrap(srtTimeToSeconds(cue.start)),
            try XCTUnwrap(srtTimeToSeconds("00:01:30,950")),
            "Mid-sentence fragments should borrow the earlier source token timing instead of waiting for the next rolling window."
        )
    }

    func testCleanCuesMergesShortRomancePrefixWithContinuationAdverb() throws {
        let raw = """
        1
        00:01:28,000 --> 00:01:31,109
        des oranges maltaises mais elles
        viennent de Tunisie et elles sont

        2
        00:01:31,109 --> 00:01:31,119
        viennent de Tunisie et elles sont


        3
        00:01:31,119 --> 00:01:35,830
        viennent de Tunisie et elles sont
        également à 3,99 € le kilo. On trouve

        4
        00:01:35,830 --> 00:01:35,840
        également à 3,99 € le kilo. On trouve


        5
        00:01:35,840 --> 00:01:39,389
        également à 3,99 € le kilo. On trouve
        aussi en toute saison des pommes.

        6
        00:01:39,389 --> 00:01:39,399
        aussi en toute saison des pommes.


        7
        00:01:39,399 --> 00:01:42,830
        aussi en toute saison des pommes.
        Ici nous avons des pommes Golden

        8
        00:01:42,830 --> 00:01:42,840
        Ici nous avons des pommes Golden


        9
        00:01:42,840 --> 00:01:47,230
        Ici nous avons des pommes Golden
        qui coûtent 3,99 € le kilo.
        """

        let cleaned = cleanCues(parseSRT(raw))

        XCTAssertFalse(
            cleaned.contains { $0.text == "On trouve" },
            "A two-word Romance prefix should not blink as its own cue when the next cue starts with a continuation adverb."
        )
        guard let cue = cleaned.first(where: { $0.text == "On trouve aussi en toute saison des pommes." }) else {
            return XCTFail("Expected merged French continuation cue, got: \(cleaned.map(\.text))")
        }
        XCTAssertGreaterThanOrEqual(
            try XCTUnwrap(srtTimeToSeconds(cue.end)),
            try XCTUnwrap(srtTimeToSeconds("00:01:39,000"))
        )
    }

    func testCleanCuesDelaysTightSentenceHandoffToAvoidEarlyCutoff() throws {
        let raw = """
        1
        00:01:39,399 --> 00:01:42,830
        aussi en toute saison des pommes.
        Ici nous avons des pommes Golden

        2
        00:01:42,830 --> 00:01:42,840
        Ici nous avons des pommes Golden


        3
        00:01:42,840 --> 00:01:47,230
        Ici nous avons des pommes Golden
        qui coûtent 3,99 € le kilo.

        4
        00:01:47,240 --> 00:01:50,389
        qui coûtent 3,99 € le kilo.
        On trouve aussi d'autres pommes

        5
        00:01:50,389 --> 00:01:50,399
        On trouve aussi d'autres pommes


        6
        00:01:50,399 --> 00:01:53,069
        On trouve aussi d'autres pommes
        qui sont des pommes Royal Gala au même

        7
        00:01:53,069 --> 00:01:53,079
        qui sont des pommes Royal Gala au même


        8
        00:01:53,079 --> 00:01:56,310
        qui sont des pommes Royal Gala au même
        prix. Ici, il y a trois sortes de

        9
        00:01:56,310 --> 00:01:56,320
        prix. Ici, il y a trois sortes de


        10
        00:01:56,320 --> 00:01:59,190
        prix. Ici, il y a trois sortes de
        poivrons. Des poivrons jaunes, des
        """

        let cleaned = cleanCues(parseSRT(raw))

        guard let priceCue = cleaned.first(where: { $0.text == "On trouve aussi d'autres pommes qui sont des pommes Royal Gala au même prix." }) else {
            return XCTFail("Expected price sentence cue, got: \(cleaned.map(\.text))")
        }
        XCTAssertGreaterThanOrEqual(
            try XCTUnwrap(srtTimeToSeconds(priceCue.end)),
            try XCTUnwrap(srtTimeToSeconds("00:01:54,050")),
            "A complete sentence should not disappear immediately before a tightly attached new sentence starts."
        )
    }

    func testCleanCuesLowRepeatRatioLyricsAreNotMergedAsRomanceContinuation() {
        let input = [
            SubtitleCue(index: 1, start: "00:00:01,000", end: "00:00:02,000", text: "la la la"),
            SubtitleCue(index: 2, start: "00:00:03,000", end: "00:00:04,000", text: "la la la"),
            SubtitleCue(index: 3, start: "00:00:05,000", end: "00:00:06,000", text: "different"),
            SubtitleCue(index: 4, start: "00:00:07,000", end: "00:00:08,000", text: "lines"),
            SubtitleCue(index: 5, start: "00:00:09,000", end: "00:00:10,000", text: "ending")
        ]

        let cleaned = cleanCues(input)

        XCTAssertEqual(cleaned.count, 5)
        XCTAssertEqual(cleaned[1].text, "la la la")
    }

    func testCleanCuesKeepsDecimalPercentAndMergesEnglishOrphanTail() {
        let input = [
            SubtitleCue(
                index: 1,
                start: "00:00:00,000",
                end: "00:00:12,000",
                text: "The The Sun is uh 99.8% of all mass in the solar system."
            ),
            SubtitleCue(
                index: 2,
                start: "00:00:12,010",
                end: "00:00:15,000",
                text: "And Jupiter is about 0.1% and Earth is in the miscellaneous category."
            ),
            SubtitleCue(
                index: 3,
                start: "00:00:15,010",
                end: "00:00:19,500",
                text: "hopefully at the solar system, and send spaceships to other star"
            ),
            SubtitleCue(
                index: 4,
                start: "00:00:19,510",
                end: "00:00:20,800",
                text: "systems."
            ),
            SubtitleCue(
                index: 5,
                start: "00:00:20,900",
                end: "00:00:21,140",
                text: "The Starship"
            ),
            SubtitleCue(
                index: 6,
                start: "00:00:21,150",
                end: "00:00:25,400",
                text: "V4 will make uh Starship V3 look kind of short."
            )
        ]

        let cleaned = cleanCues(input)
        let texts = cleaned.map(\.text)

        XCTAssertTrue(texts.contains { $0.contains("99.8%") })
        XCTAssertFalse(texts.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("99.") })
        XCTAssertFalse(texts.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("8%") })
        XCTAssertTrue(texts.contains { $0.contains("0.1%") })
        XCTAssertTrue(texts.contains { $0.contains("other star systems.") })
        XCTAssertFalse(texts.contains("systems."))
        XCTAssertTrue(texts.contains { $0.contains("The Starship V4 will make") })
        XCTAssertFalse(texts.contains("The Starship"))
    }

    func testCleanCuesTedxColonHandoffAndShortAsideAvoidLateHolds() throws {
        let raw = """
        1
        00:01:36,718 --> 00:01:40,247
        when the sleep deprivation
        really kicked in,

        2
        00:01:40,247 --> 00:01:42,299
        like around week eight,

        3
        00:01:42,299 --> 00:01:45,732
        I had this thought,
        and it was the same thought

        4
        00:01:45,732 --> 00:01:49,773
        that parents across the ages,
        internationally,

        5
        00:01:49,773 --> 00:01:52,467
        everybody has had this thought,
        which is:

        6
        00:01:52,467 --> 00:01:58,054
        I am never going to have
        free time ever again.
        """

        let cleaned = cleanCues(parseSRT(raw))

        guard let shortAside = cleaned.first(where: { $0.text == "like around week eight," }) else {
            return XCTFail("Expected short aside cue, got: \(cleaned.map(\.text))")
        }
        XCTAssertLessThanOrEqual(
            try XCTUnwrap(srtTimeToSeconds(shortAside.end)),
            try XCTUnwrap(srtTimeToSeconds("00:01:42,180")),
            "A short non-sentence aside should not linger almost a second after speech has ended."
        )

        guard let punchline = cleaned.first(where: { $0.text == "I am never going to have\nfree time ever again." }) else {
            return XCTFail("Expected punchline cue, got: \(cleaned.map(\.text))")
        }
        XCTAssertLessThanOrEqual(
            try XCTUnwrap(srtTimeToSeconds(punchline.start)),
            try XCTUnwrap(srtTimeToSeconds("00:01:52,350")),
            "A colon handoff should let the following sentence appear slightly before the delayed source cue boundary without cutting the previous cue too early."
        )
        assertReadableSemanticWindows(cleaned)
    }

    func testCleanCuesKeepsEmphaticShortSentenceVisibleAfterHandoff() throws {
        let raw = """
        1
        00:03:03,040 --> 00:03:05,117
        You know what I found?

        2
        00:03:05,117 --> 00:03:09,438
        10,000 hours!

        3
        00:03:09,438 --> 00:03:11,200
        Anybody ever heard this?
        """

        let cleaned = cleanCues(parseSRT(raw))
        let emphatic = try XCTUnwrap(cleaned.first(where: { $0.text == "10,000 hours!" }))

        XCTAssertLessThanOrEqual(
            try XCTUnwrap(srtTimeToSeconds(emphatic.start)),
            try XCTUnwrap(srtTimeToSeconds("00:03:05,367"))
        )
        XCTAssertGreaterThanOrEqual(
            try XCTUnwrap(srtTimeToSeconds(emphatic.end)),
            try XCTUnwrap(srtTimeToSeconds("00:03:07,567")),
            "A short emphatic sentence should not disappear immediately after a sentence handoff shifts its start later."
        )
    }

    func testCleanCuesDoesNotBorrowColonHandoffBeforePreviousSpeechEnds() throws {
        let raw = """
        WEBVTT

        00:04:49.608 --> 00:04:52.095
        We had the place crammed
        full of agents in T-shirts:

        00:04:52.119 --> 00:04:53.533
        "James Robinson IS Joseph!"
        """

        let cleaned = cleanCues(parseVTT(raw))

        guard let setup = cleaned.first(where: { $0.text.contains("agents in T-shirts:") }) else {
            return XCTFail("Expected colon setup cue, got: \(cleaned.map(\.text))")
        }
        XCTAssertGreaterThanOrEqual(
            try XCTUnwrap(srtTimeToSeconds(setup.end)),
            try XCTUnwrap(srtTimeToSeconds("00:04:51,945")),
            "Colon handoff should not cut the setup cue more than 150ms before its source speech window ends."
        )
        guard let punchline = cleaned.first(where: { $0.text.contains("James Robinson") }) else {
            return XCTFail("Expected punchline cue, got: \(cleaned.map(\.text))")
        }
        XCTAssertLessThanOrEqual(
            try XCTUnwrap(srtTimeToSeconds(punchline.start)),
            try XCTUnwrap(srtTimeToSeconds("00:04:51,960")),
            "Colon handoff should still let the response appear slightly before the source cue boundary."
        )
    }

    func testCloudTranslationRetriesMissingLinesBySplittingLongChunk() async throws {
        TranslationRetryURLProtocol.reset()
        URLProtocol.registerClass(TranslationRetryURLProtocol.self)
        defer { URLProtocol.unregisterClass(TranslationRetryURLProtocol.self) }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("moongate-translation-retry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let source = tempDir.appendingPathComponent("long.en.srt")
        let cues = (1...30).map {
            SubtitleCue(
                index: $0,
                start: secondsToSRTTime(Double($0 * 10)),
                end: secondsToSRTTime(Double($0 * 10 + 2)),
                text: "Sentence \($0)."
            )
        }
        try serializeSRT(cues).write(to: source, atomically: true, encoding: .utf8)
        let settings = AppSettings(
            translationEngine: .anthropicCompatible,
            translationBaseURL: "https://translation-retry.example.com",
            translationModel: "test-model",
            translationAuthToken: "token"
        )
        let translator = ConfiguredTranslator(settings: settings)

        let output = try await translator.translate(
            srtFile: source,
            style: .chineseOnly,
            context: TranslationContext(sourceLanguage: "en", targetLanguage: "zh-Hans"),
            control: nil,
            progress: { _ in }
        )

        let result = parseSRT(try String(contentsOf: output, encoding: .utf8))
        XCTAssertEqual(result.count, 30)
        XCTAssertEqual(result.map(\.text), (1...30).map { "中\($0)" })
        XCTAssertEqual(TranslationRetryURLProtocol.requestCount(), 3)
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

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
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
    private static var responses: [(Int, String)] = []

    static func reset(responses newResponses: [(Int, String)] = []) {
        lock.lock()
        requests = []
        responses = newResponses
        lock.unlock()
    }

    static func requestCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.count
    }

    static func capturedRequests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    private static func recordAndNextResponse(_ request: URLRequest) -> (Int, String) {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
        if responses.isEmpty {
            return (200, #"{"data":[{"id":"should-not-fetch"}]}"#)
        }
        return responses.removeFirst()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let (statusCode, body) = Self.recordAndNextResponse(request)
        let response = HTTPURLResponse(
            url: request.url ?? URL(fileURLWithPath: "/"),
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class TranslationRetryURLProtocol: URLProtocol, @unchecked Sendable {
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
        request.url?.host == "translation-retry.example.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        Self.lock.unlock()

        let content = Self.userContent(from: request)
        let lineCount = content.split(separator: "\n", omittingEmptySubsequences: false).count
        let replyText: String
        if lineCount == 30 {
            replyText = "1|中1"
        } else {
            replyText = content
                .split(separator: "\n")
                .map { line -> String in
                    let number = line.split(separator: "|", maxSplits: 1).first ?? ""
                    return "\(number)|中\(number)"
                }
                .joined(separator: "\n")
        }
        let body = """
        {"content":[{"type":"text","text":\(Self.jsonString(replyText))}],"stop_reason":"end_turn"}
        """
        let response = HTTPURLResponse(
            url: request.url ?? URL(fileURLWithPath: "/"),
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func userContent(from request: URLRequest) -> String {
        guard let body = bodyData(from: request),
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let messages = object["messages"] as? [[String: Any]],
              let content = messages.first?["content"] as? String else {
            return ""
        }
        return content
    }

    private static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            if count < 0 { return nil }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    private static func jsonString(_ value: String) -> String {
        let data = try! JSONEncoder().encode(value)
        return String(decoding: data, as: UTF8.self)
    }
}
