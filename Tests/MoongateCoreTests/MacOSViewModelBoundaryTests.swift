import XCTest

final class MacOSViewModelBoundaryTests: XCTestCase {
    func testViewModelOwnsUpdaterAndDefersBackgroundChecksToSparkle() throws {
        let source = try viewModelSource()

        XCTAssertTrue(source.contains("let updater: UpdateService"))
        XCTAssertTrue(source.contains("updater: UpdateService? = nil"))
        XCTAssertTrue(source.contains("self.updater = updater ?? UpdateService()"))
        XCTAssertTrue(source.contains("self.updater.prepareForUpdateUI"))
        XCTAssertTrue(source.contains("dismissSheetsForUpdateUI()"))
        let onAppearBody = try XCTUnwrap(functionBody(prefix: "func onAppear", in: source))
        XCTAssertTrue(onAppearBody.contains("checkForUpdatesIfNeeded()"))

        // UPDATE-MAC-001：不再调用实为 no-op 的 updater.check(silent: true)，后台检查交给 Sparkle 调度。
        let checkBody = try XCTUnwrap(functionBody(prefix: "func checkForUpdatesIfNeeded", in: source))
        XCTAssertFalse(checkBody.contains("updater.check(silent: true)"))

        let dismissBody = try XCTUnwrap(functionBody(prefix: "func dismissSheetsForUpdateUI", in: source))
        XCTAssertTrue(dismissBody.contains("showSettings = false"))
    }

    func testStartDownloadSkipsTranslationReadinessGateForChineseSourceSubtitles() throws {
        let source = try viewModelSource()
        let startDownloadBody = try XCTUnwrap(functionBody(prefix: "func startDownload", in: source))

        XCTAssertTrue(source.contains("shouldRequireTranslationReadiness(for mode: ChineseSubtitleMode, info: VideoInfo) -> Bool"))
        XCTAssertTrue(source.contains("mode.requiresTranslation && !translationSourceMatchesTarget(in: info)"))
        XCTAssertTrue(startDownloadBody.contains("shouldRequireTranslationReadiness(for: mode, info: info)"))
        XCTAssertFalse(startDownloadBody.contains("if chineseMode.requiresTranslation"))

        let readinessGate = try XCTUnwrap(
            startDownloadBody.range(of: "shouldRequireTranslationReadiness(for: mode, info: info)")
        )
        let contextConstruction = try XCTUnwrap(startDownloadBody.range(of: "TranslationContext("))
        let contextAwareBlock = try XCTUnwrap(
            startDownloadBody.range(of: "await blockIfTranslationNotReady(")
        )

        XCTAssertLessThan(readinessGate.upperBound, contextConstruction.lowerBound)
        XCTAssertLessThan(contextConstruction.upperBound, contextAwareBlock.lowerBound)
    }

    func testStartDownloadAwaitsRuntimeReadinessForNonChineseSourceSubtitles() throws {
        let source = try viewModelSource()
        let startDownloadBody = try XCTUnwrap(functionBody(prefix: "func startDownload", in: source))
        let compactStartDownloadBody = compactWhitespace(startDownloadBody)

        XCTAssertTrue(source.contains("func startDownload() async"))
        XCTAssertTrue(startDownloadBody.contains("let startSession = session"))
        XCTAssertTrue(startDownloadBody.contains("let mode = chineseMode"))
        XCTAssertTrue(startDownloadBody.contains("let selectedFormatIDSnapshot = selectedFormatID"))
        XCTAssertTrue(startDownloadBody.contains("let selectedSubtitleIDsSnapshot = selectedSubtitleIDs"))
        XCTAssertTrue(startDownloadBody.contains("let primarySubtitleTrackIDSnapshot = primarySubtitleTrackID"))
        XCTAssertTrue(startDownloadBody.contains("let currentSettings = settings"))
        XCTAssertTrue(startDownloadBody.contains("shouldRequireTranslationReadiness(for: mode, info: info)"))
        XCTAssertTrue(startDownloadBody.contains("currentSettings.makeTranslationContext("))
        XCTAssertTrue(startDownloadBody.contains("sourceLanguage: translationSourceSubtitle(in: info)?.languageCode"))
        XCTAssertTrue(startDownloadBody.contains("await blockIfTranslationNotReady("))
        XCTAssertTrue(startDownloadBody.contains("settings: currentSettings"))
        XCTAssertTrue(startDownloadBody.contains("guard startSession == session else { return }"))
        XCTAssertTrue(startDownloadBody.contains("guard case .ready(let currentInfo) = stage"))
        XCTAssertTrue(startDownloadBody.contains("currentInfo.sourceURL == info.sourceURL"))
        XCTAssertTrue(startDownloadBody.contains("currentInfo.videoID == info.videoID"))
        XCTAssertTrue(startDownloadBody.contains("guard let formatID = selectedFormatIDSnapshot ?? info.formats.first?.id else { return }"))
        XCTAssertTrue(startDownloadBody.contains("selectedSubtitleIDsSnapshot.contains($0.id)"))
        XCTAssertTrue(startDownloadBody.contains("primarySubtitleTrackID: primarySubtitleTrackIDSnapshot"))
        XCTAssertTrue(startDownloadBody.contains("queue.enqueue(info: info, request: request, chineseMode: mode, settings: currentSettings)"))
        XCTAssertFalse(compactStartDownloadBody.contains(
            "guard blockIfTranslationNotReady(for: chineseMode) else { return }"
        ))
        XCTAssertTrue(source.contains("translationRuntimeReadiness("))
        XCTAssertTrue(source.contains("context: translationContext"))
        XCTAssertTrue(source.contains("evaluator: runtimeReadinessEvaluator"))
    }

    func testStartDownloadScopesPreferHDRToSelectedFormatAvailability() throws {
        let source = try viewModelSource()
        let startDownloadBody = try XCTUnwrap(functionBody(prefix: "func startDownload", in: source))

        XCTAssertTrue(startDownloadBody.contains("let selectedFormat = info.formats.first { $0.id == formatID }"))
        XCTAssertTrue(startDownloadBody.contains("let requestPreferHDR = preferHDRSnapshot && (selectedFormat?.hdrAvailable ?? false)"))
        XCTAssertTrue(startDownloadBody.contains("preferHDR: requestPreferHDR"))
        XCTAssertFalse(startDownloadBody.contains("preferHDR: preferHDRSnapshot"))
    }

    func testBatchChecksTranslationReadinessAfterAutoSelectingSubtitleSource() throws {
        let source = try viewModelSource()
        let processBatchBody = try XCTUnwrap(functionBody(prefix: "private func processBatch", in: source))
        let compactBatchBody = compactWhitespace(processBatchBody)

        XCTAssertTrue(compactBatchBody.contains("let mode = chineseMode guard dependenciesReady(for: mode) else { return }"))
        XCTAssertFalse(compactBatchBody.contains(
            "let mode = chineseMode guard blockIfTranslationNotReady(for: mode) else { return }"
        ))

        let subtitleSelection = try XCTUnwrap(processBatchBody.range(of: "autoSubtitleLangs = [sub.languageCode]"))
        let readinessGate = try XCTUnwrap(processBatchBody.range(of: "shouldRequireTranslationReadiness"))
        let translationContext = try XCTUnwrap(processBatchBody.range(of: "TranslationContext("))
        let contextAwareBlock = try XCTUnwrap(processBatchBody.range(
            of: "blockIfTranslationNotReady("
        ))
        let requestConstruction = try XCTUnwrap(processBatchBody.range(of: "let request = DownloadRequest"))

        XCTAssertLessThan(subtitleSelection.upperBound, readinessGate.lowerBound)
        XCTAssertLessThan(readinessGate.upperBound, translationContext.lowerBound)
        XCTAssertLessThan(translationContext.upperBound, contextAwareBlock.lowerBound)
        XCTAssertLessThan(contextAwareBlock.upperBound, requestConstruction.lowerBound)
        XCTAssertTrue(compactBatchBody.contains("shouldRequireTranslationReadiness( for: mode, info: info,"))
        XCTAssertTrue(processBatchBody.contains("currentSettings.makeTranslationContext("))
        XCTAssertTrue(processBatchBody.contains("sourceLanguage: subtitleTracks.first?.languageCode"))
        XCTAssertTrue(processBatchBody.contains("await blockIfTranslationNotReady("))
        XCTAssertTrue(processBatchBody.contains("settings: currentSettings"))
        XCTAssertTrue(source.contains(
            "private func blockIfTranslationNotReady("
        ))
        XCTAssertTrue(source.contains("settings: AppSettings"))
        XCTAssertTrue(source.contains("translationRuntimeReadiness("))
        XCTAssertTrue(source.contains("context: context"))
        XCTAssertTrue(source.contains("evaluator: runtimeReadinessEvaluator"))
    }

    func testBatchSubtitleSourceUsesLanguageRecommendation() throws {
        let source = try viewModelSource()
        let processBatchBody = try XCTUnwrap(functionBody(prefix: "private func processBatch", in: source))

        XCTAssertTrue(processBatchBody.contains("SubtitleLanguageRecommender.recommend("))
        XCTAssertTrue(processBatchBody.contains("availableSubtitleChoices(for: info)"))
        XCTAssertTrue(processBatchBody.contains("recommended.preferredTrack"))
        XCTAssertFalse(processBatchBody.contains("info.subtitles.first(where: { !$0.isAuto }) ?? info.subtitles.first"))
    }

    func testSummaryAvailabilityUsesSummaryRuntimeReadiness() throws {
        let source = try viewModelSource()
        let refreshBody = try XCTUnwrap(functionBody(prefix: "func refreshSummaryRuntimeReadiness", in: source))
        let unavailableBody = try XCTUnwrap(functionBody(prefix: "var summaryUnavailableReason", in: source))

        XCTAssertTrue(source.contains("@Published private(set) var runtimeSummaryReadiness"))
        XCTAssertTrue(source.contains("private var runtimeSummaryReadinessContext"))
        XCTAssertTrue(source.contains("private var summaryReadinessTask"))
        XCTAssertTrue(refreshBody.contains("settings.applyingTranslationConfig(settings.effectiveSummaryConfig)"))
        XCTAssertTrue(refreshBody.contains("summaryReadinessContext()"))
        XCTAssertTrue(refreshBody.contains("translationRuntimeReadiness("))
        XCTAssertTrue(refreshBody.contains("runtimeSummaryReadiness = readiness"))

        XCTAssertTrue(unavailableBody.contains("let config = settings.effectiveSummaryConfig"))
        XCTAssertTrue(unavailableBody.contains("let summarySettings = settings.applyingTranslationConfig(config)"))
        XCTAssertTrue(unavailableBody.contains("runtimeSummaryReadinessContext == context"))
        XCTAssertTrue(unavailableBody.contains("runtimeSummaryReadiness ?? summarySettings.translationReadiness(context: context)"))
        XCTAssertFalse(unavailableBody.contains("settings.translationReadiness(context: context)"))
    }

    func testSummaryRuntimeReadinessRefreshesOnAppearAndSettingsChange() throws {
        let source = try viewModelSource()
        let onAppearBody = try XCTUnwrap(functionBody(prefix: "func onAppear", in: source))
        let settingsBody = try XCTUnwrap(publishedSettingsBody(in: source))

        XCTAssertTrue(onAppearBody.contains("refreshTranslationRuntimeReadiness()"))
        XCTAssertTrue(onAppearBody.contains("refreshSummaryRuntimeReadiness()"))
        XCTAssertTrue(settingsBody.contains("refreshTranslationRuntimeReadiness()"))
        XCTAssertTrue(settingsBody.contains("refreshSummaryRuntimeReadiness()"))
    }

    func testDefaultQueueReceivesLocalASRGeneratorThroughSettingsFactory() throws {
        let source = try viewModelSource()
        let initializerBody = try XCTUnwrap(functionBody(prefix: "init(", in: source))

        XCTAssertTrue(initializerBody.contains("let initialSettings = AppSettings.load(readCredentials: false)"))
        XCTAssertTrue(initializerBody.contains("LocalASRGeneratorFactory.make(settings: initialSettings)"))
        XCTAssertTrue(initializerBody.contains("localASRGenerator:"))
        XCTAssertFalse(initializerBody.contains("WhisperCppLocalASRSubtitleGenerator("))
    }

    func testDownloadOptionPersistenceDoesNotRebuildLocalASRGenerator() throws {
        let source = try viewModelSource()
        let settingsBody = try XCTUnwrap(publishedSettingsBody(in: source))

        XCTAssertTrue(source.contains("private static func localASRGeneratorSettingsChanged"))
        XCTAssertTrue(settingsBody.contains("if Self.localASRGeneratorSettingsChanged(oldValue, settings)"))
        XCTAssertTrue(settingsBody.contains("queue.syncLocalASRGenerator(from: settings)"))
        XCTAssertFalse(settingsBody.contains("queue.syncLocalASRGenerator(from: settings)\n            refreshTranslationRuntimeReadiness()"))
    }

    func testDefaultQueueReceivesCompletionNotifierThroughAppLayer() throws {
        let source = try viewModelSource()
        let initializerBody = try XCTUnwrap(functionBody(prefix: "init(", in: source))

        XCTAssertTrue(initializerBody.contains("SystemQueueCompletionNotifier("))
        XCTAssertTrue(initializerBody.contains("settingsProvider: { AppSettings.load(readCredentials: false) }"))
        XCTAssertTrue(initializerBody.contains("completionNotifier:"))
    }

    func testStartupDefersKeychainCredentialReadUntilFirstUse() throws {
        let source = try viewModelSource()
        let initializerBody = try XCTUnwrap(functionBody(prefix: "init(", in: source))
        // 启动不读凭证（避免首次启动弹 Keychain 授权）
        XCTAssertTrue(initializerBody.contains("AppSettings.load(readCredentials: false)"))
        // 幂等 hydrate：真正需要时才从安全存储补齐
        XCTAssertTrue(source.contains("func hydrateCredentials()"))
        let hydrateBody = try XCTUnwrap(functionBody(prefix: "func hydrateCredentials", in: source))
        XCTAssertTrue(hydrateBody.contains("guard !credentialsHydrated"))
        XCTAssertTrue(hydrateBody.contains("AppSettings.load(readCredentials: true)"))
        // 首次处理任务 / 开始下载时补齐凭证
        let parseBody = try XCTUnwrap(functionBody(prefix: "func parse(", in: source))
        XCTAssertTrue(parseBody.contains("hydrateCredentials()"))
        let startBody = try XCTUnwrap(functionBody(prefix: "func startDownload", in: source))
        XCTAssertTrue(startBody.contains("hydrateCredentials()"))
    }

    func testCompleteOnboardingHydratesCredentialsBeforeBuildingDraft() throws {
        // 回归保护：completeOnboarding 发生在首次启动、任何 parse/download 之前，此时凭证尚未 hydrate。
        // 若以启动期（readCredentials:false）的空 Token settings 为 draft 直接 save()，
        // writeTokensToStore() 会把空值当“删除”抹掉 Keychain 既有 Token（重跑 onboarding / settings 被重置时）。
        // 因此必须先 hydrate，且必须在取 draft 之前，draft 才能继承真实 Token。
        let source = try viewModelSource()
        let body = try XCTUnwrap(functionBody(prefix: "func completeOnboarding", in: source))
        XCTAssertTrue(body.contains("hydrateCredentials()"), "completeOnboarding 必须先 hydrateCredentials()")
        let hydrateIndex = try XCTUnwrap(body.range(of: "hydrateCredentials()")?.lowerBound)
        let draftIndex = try XCTUnwrap(body.range(of: "var draft = settings")?.lowerBound)
        XCTAssertTrue(hydrateIndex < draftIndex, "hydrateCredentials() 必须在 var draft = settings 之前")
    }

    func testReadySelectionAlwaysIncludesLocalASRTracksAndGatesDownloadOnReadiness() throws {
        let source = try viewModelSource()
        let availableBody = try XCTUnwrap(functionBody(prefix: "func availableSubtitleChoices", in: source))
        let startDownloadBody = try XCTUnwrap(functionBody(prefix: "func startDownload", in: source))
        let translationSourceBody = try XCTUnwrap(functionBody(prefix: "func translationSourceSubtitle", in: source))
        let settingsBody = try XCTUnwrap(publishedSettingsBody(in: source))

        XCTAssertFalse(availableBody.contains("guard queue.hasLocalASRGenerator else { return choices }"))
        XCTAssertTrue(availableBody.contains("SubtitleChoice("))
        XCTAssertTrue(availableBody.contains("sourceKind: .localASR"))
        XCTAssertTrue(availableBody.contains("provider: \"whisper.cpp\""))
        XCTAssertTrue(availableBody.contains("variant: \"local\""))
        XCTAssertTrue(source.contains("var localASRReadyForDownload: Bool"))
        XCTAssertTrue(source.contains("func openLocalASRSettings()"))
        XCTAssertTrue(source.contains("pendingSettingsPaneID"))
        XCTAssertTrue(settingsBody.contains("queue.syncLocalASRGenerator(from: settings)"))
        XCTAssertTrue(startDownloadBody.contains("availableSubtitleChoices(for: info)"))
        XCTAssertTrue(startDownloadBody.contains("primaryTrack.sourceKind == .localASR"))
        XCTAssertTrue(startDownloadBody.contains("!localASRReadyForDownload"))
        XCTAssertTrue(startDownloadBody.contains("openLocalASRSettings()"))
        XCTAssertTrue(startDownloadBody.contains("selectedSubtitleIDsSnapshot.contains($0.id)"))
        XCTAssertTrue(source.contains("@Published var primarySubtitleTrackID: String?"))
        XCTAssertTrue(source.contains("selectedSubtitleIDs = primarySubtitleTrackID.map { [$0] } ?? []"))
        XCTAssertTrue(translationSourceBody.contains("primarySubtitleTrack(in: info)"))
        let primaryTrackBody = try XCTUnwrap(functionBody(prefix: "func primarySubtitleTrack", in: source))
        XCTAssertTrue(primaryTrackBody.contains("availableSubtitleChoices(for: info)"))
    }

    func testReadySelectionPersistsStablePrimarySubtitleTrackID() throws {
        let source = try viewModelSource()
        let restoreBody = try XCTUnwrap(functionBody(prefix: "private func restoreDownloadOptions", in: source))
        let persistBody = try XCTUnwrap(functionBody(prefix: "private func persistCurrentDownloadOptions", in: source))
        let startDownloadBody = try XCTUnwrap(functionBody(prefix: "func startDownload", in: source))

        XCTAssertTrue(restoreBody.contains("settings.lastPrimarySubtitleTrackID"))
        XCTAssertTrue(restoreBody.contains("available.first(where: { $0.id == lastPrimarySubtitleTrackID })"))
        XCTAssertTrue(restoreBody.contains("exact.sourceKind != .localASR || localASRReadyForDownload"))
        XCTAssertTrue(restoreBody.contains("best.sourceKind != .localASR"))
        XCTAssertTrue(persistBody.contains("lastPrimarySubtitleTrackID = primarySubtitleTrackID"))
        XCTAssertTrue(startDownloadBody.contains("primarySubtitleTrackIDSnapshot"))
    }

    func testReadySelectionIncludesAutoLocalASRWhenNoPlatformSubtitles() throws {
        let source = try viewModelSource()
        let availableBody = try XCTUnwrap(functionBody(prefix: "func availableSubtitleChoices", in: source))

        XCTAssertTrue(availableBody.contains("info.subtitles.isEmpty"))
        XCTAssertTrue(availableBody.contains("languageCode: \"auto\""))
        XCTAssertTrue(availableBody.contains("CoreL10n.t(L.Ready.localASRAutoDetectLabel)"))
        XCTAssertTrue(availableBody.contains("sourceKind: .localASR"))
        XCTAssertTrue(availableBody.contains("provider: \"whisper.cpp\""))
        XCTAssertTrue(availableBody.contains("variant: \"local\""))
    }

    func testReadyPageUsesLanguageFirstRecommendationAndThreadsPreferredLanguage() throws {
        let source = try viewModelSource()

        // 语言优先 API：聚合 + 推荐 + 选择，全部委托给共享 SubtitleLanguageRecommender。
        XCTAssertTrue(source.contains("func recommendedLanguage(for info: VideoInfo) -> SubtitleLanguageChoice?"))
        XCTAssertTrue(source.contains("func otherLanguages(for info: VideoInfo) -> [SubtitleLanguageChoice]"))
        XCTAssertTrue(source.contains("SubtitleLanguageRecommender.recommend("))
        XCTAssertTrue(source.contains("func selectLanguage(_ language: SubtitleLanguageChoice)"))
        XCTAssertTrue(source.contains("primarySubtitleTrackID = track.id"))
        XCTAssertTrue(source.contains("@Published var languageSectionExpanded: Bool = false"))

        // 恢复优先级：上次手选/语言未命中时，回退到推荐语言。
        let restoreBody = try XCTUnwrap(functionBody(prefix: "private func restoreDownloadOptions", in: source))
        XCTAssertTrue(restoreBody.contains("recommendedLanguage(for: info)?.preferredTrack"))
        XCTAssertTrue(restoreBody.contains("languageSectionExpanded = false"))

        // 构造请求填 preferredSubtitleLanguageCode（语言优先选择）。
        XCTAssertTrue(source.contains("preferredSubtitleLanguageCode: primarySubtitleTrackIDSnapshot.map(normalizedLang)"))
    }

    func testDownloadsUseAppOwnedDirectoryForStorageSafety() throws {
        let source = try viewModelSource()
        let destinationBody = try XCTUnwrap(functionBody(prefix: "static func destinationDirectory", in: source))

        XCTAssertTrue(source.contains("static var appDownloadsDirectory"))
        XCTAssertTrue(source.contains("appendingPathComponent(\"Moongate\", isDirectory: true)"))
        XCTAssertTrue(destinationBody.contains("let downloads = appDownloadsDirectory"))
        XCTAssertTrue(destinationBody.contains("guard multiFile else { return downloads }"))
        XCTAssertTrue(destinationBody.contains("downloads.appendingPathComponent(sanitizedFolderName(title), isDirectory: true)"))
    }

    private func viewModelSource() throws -> String {
        try String(contentsOf: packageRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("Moongate")
            .appendingPathComponent("ViewModel.swift"))
    }

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func functionBody(prefix: String, in source: String) -> String? {
        guard let declaration = source.range(of: prefix) else { return nil }
        guard let openingBrace = source[declaration.lowerBound...].firstIndex(of: "{") else { return nil }

        var depth = 0
        var cursor = openingBrace
        while cursor < source.endIndex {
            switch source[cursor] {
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return String(source[openingBrace...cursor])
                }
            default:
                break
            }
            cursor = source.index(after: cursor)
        }
        return nil
    }

    private func publishedSettingsBody(in source: String) -> String? {
        guard let declaration = source.range(of: "@Published var settings") else { return nil }
        guard let didSet = source.range(of: "didSet", range: declaration.lowerBound..<source.endIndex) else { return nil }
        guard let openingBrace = source[didSet.lowerBound...].firstIndex(of: "{") else { return nil }

        var depth = 0
        var cursor = openingBrace
        while cursor < source.endIndex {
            switch source[cursor] {
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return String(source[openingBrace...cursor])
                }
            default:
                break
            }
            cursor = source.index(after: cursor)
        }
        return nil
    }

    private func compactWhitespace(_ source: String) -> String {
        source.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
