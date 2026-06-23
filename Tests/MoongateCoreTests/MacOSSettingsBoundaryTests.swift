import XCTest

final class MacOSSettingsBoundaryTests: XCTestCase {
    func testSettingsViewUsesSplitNavigationHubWithLocalASRAndNotifications() throws {
        let source = try String(contentsOf: packageRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("Moongate")
            .appendingPathComponent("SettingsView.swift"))
        let keys = try String(contentsOf: packageRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("MoongateMobileCore")
            .appendingPathComponent("Localization")
            .appendingPathComponent("LocalizationKeys.swift"))
        let en = try String(contentsOf: packageRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("MoongateMobileCore")
            .appendingPathComponent("Localization")
            .appendingPathComponent("Strings.en.swift"))
        let zhHans = try String(contentsOf: packageRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("MoongateMobileCore")
            .appendingPathComponent("Localization")
            .appendingPathComponent("Strings.zhHans.swift"))
        let zhHant = try String(contentsOf: packageRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("MoongateMobileCore")
            .appendingPathComponent("Localization")
            .appendingPathComponent("Strings.zhHant.swift"))

        XCTAssertTrue(source.contains("enum SettingsPane: String, CaseIterable, Identifiable"))
        XCTAssertTrue(source.contains("case general"))
        XCTAssertTrue(source.contains("case subtitles"))
        XCTAssertTrue(source.contains("case localSpeech"))
        XCTAssertTrue(source.contains("case aiServices"))
        XCTAssertTrue(source.contains("case videoOutput"))
        XCTAssertTrue(source.contains("case siteLogin"))
        XCTAssertTrue(source.contains("case components"))
        XCTAssertTrue(source.contains("case updates"))
        XCTAssertTrue(en.contains("L.Settings.paneComponents: \"Components & Storage\""))
        XCTAssertTrue(en.contains("L.Settings.paneUpdates: \"Updates & About\""))
        XCTAssertTrue(zhHans.contains("L.Settings.paneComponents: \"组件与存储\""))
        XCTAssertTrue(zhHans.contains("L.Settings.paneUpdates: \"更新与关于\""))
        XCTAssertTrue(zhHant.contains("L.Settings.paneComponents: \"元件與儲存\""))
        XCTAssertTrue(zhHant.contains("L.Settings.paneUpdates: \"更新與關於\""))
        XCTAssertTrue(source.contains("@State private var selectedPane: SettingsPane? = .general"))
        XCTAssertTrue(source.contains("NavigationSplitView"))
        XCTAssertTrue(source.contains("List(SettingsPane.allCases, selection: $selectedPane)"))
        XCTAssertTrue(source.contains("settingsPaneDetail"))
        // 11c：设置改为独立窗口 + 实时保存，不再有底部「完成/取消」按钮，改为 persistDraftLive 自动落盘。
        XCTAssertFalse(source.contains("private var bottomBar"))
        XCTAssertTrue(source.contains("private func persistDraftLive"))
        XCTAssertTrue(source.contains(".onChange(of: draft) { _, newValue in"))
        XCTAssertTrue(source.contains("applyPendingSettingsPane()"))
        XCTAssertTrue(source.contains(".onChange(of: model.pendingSettingsPaneID)"))
        XCTAssertTrue(source.contains(".frame(minWidth: 760"))
        XCTAssertFalse(source.contains(".frame(width: 480, height: 560)"))

        XCTAssertTrue(source.contains("localSpeechSection"))
        XCTAssertTrue(source.contains("$draft.localASREnabled"))
        XCTAssertTrue(source.contains("localizer.t(L.Settings.localASRSetupRepair)"))
        XCTAssertTrue(source.contains("importLocalASRModel()"))
        XCTAssertTrue(source.contains("draft.localASRRuntimePath = runtime.executableURL.path"))
        XCTAssertTrue(source.contains("draft.localASRModelPath = destinationURL.path"))
        XCTAssertTrue(source.contains("draft.localASRModelID = importedLocalASRModelID"))
        XCTAssertTrue(source.contains("localizer.t(L.Settings.localASRHelp)"))

        XCTAssertTrue(source.contains("notificationsSection"))
        XCTAssertTrue(source.contains("$draft.completionNotificationsEnabled"))
        XCTAssertTrue(source.contains("$draft.completionSoundEnabled"))

        let detailBody = try XCTUnwrap(functionBody(named: "settingsPaneDetail", in: source))
        XCTAssertTrue(detailBody.contains("case .components:"))
        XCTAssertTrue(detailBody.contains("dependencySection"))
        XCTAssertTrue(detailBody.contains("storageSection"))
        XCTAssertTrue(detailBody.contains("case .updates:"))
        XCTAssertTrue(detailBody.contains("updateSection"))
        XCTAssertTrue(detailBody.contains("aboutSection"))

        let generalCase = try XCTUnwrap(caseBody(named: ".general", before: ".subtitles", in: detailBody))
        XCTAssertTrue(generalCase.contains("languageSection"))
        XCTAssertTrue(generalCase.contains("notificationsSection"))
        XCTAssertFalse(generalCase.contains("performanceSection"))

        let videoOutputCase = try XCTUnwrap(caseBody(named: ".videoOutput", before: ".siteLogin", in: detailBody))
        XCTAssertTrue(videoOutputCase.contains("burnQualitySection"))
        XCTAssertTrue(videoOutputCase.contains("performanceSection"))

        let storageBody = try XCTUnwrap(functionBody(named: "storageSection", in: source))
        // 11i：存储管理页面 — macOS Storage 风格总览条 + 分类行 + 行内清理入口。
        XCTAssertTrue(storageBody.contains("Section(localizer.t(L.Settings.storageSection))"))
        XCTAssertTrue(storageBody.contains("storageOverview"))
        XCTAssertTrue(storageBody.contains("supportDataURL"))
        XCTAssertTrue(storageBody.contains("localASRModelStoreURL"))
        XCTAssertTrue(storageBody.contains("appDownloadsDirectoryURL"))
        XCTAssertTrue(storageBody.contains("storageRow("))
        XCTAssertTrue(storageBody.contains("L.Settings.storageDeleteModels"))
        XCTAssertTrue(storageBody.contains("L.Settings.storageDeleteDownloads"))
        XCTAssertTrue(source.contains("private var storageUsageBar"))
        XCTAssertTrue(source.contains("private var storageTotalBytes"))
        XCTAssertTrue(source.contains("private func storageBarSegment"))
        XCTAssertTrue(source.contains("NSWorkspace.shared.open"))
        XCTAssertTrue(source.contains("ByteCountFormatter"))
        XCTAssertTrue(source.contains("private static nonisolated func directorySize"))
        XCTAssertTrue(source.contains("private var appDownloadsDirectoryURL: URL { ViewModel.appDownloadsDirectory }"))
        XCTAssertTrue(source.contains("max(Self.directorySize(supportDir) - modelsSize, 0)"))
        XCTAssertFalse(source.contains("contentsOfDirectory(atPath: downloadsDir.path)"))

        let deleteDownloadsBody = try XCTUnwrap(functionBody(named: "deleteAllDownloads", in: source))
        XCTAssertTrue(deleteDownloadsBody.contains("appDownloadsDirectoryURL"))
        XCTAssertTrue(deleteDownloadsBody.contains("trashItem(at: downloadsDir"))
        XCTAssertFalse(deleteDownloadsBody.contains("contentsOfDirectory"))

        let aboutBody = try XCTUnwrap(functionBody(named: "aboutSection", in: source))
        XCTAssertTrue(aboutBody.contains("Section(localizer.t(L.Settings.aboutSection))"))
        XCTAssertTrue(aboutBody.contains("localizer.t(L.Settings.aboutAppName)"))
        XCTAssertFalse(aboutBody.contains("updater.currentVersion"))
        XCTAssertTrue(aboutBody.contains("localizer.t(L.Settings.aboutSource)"))
        // 11g：关于页提供 GitHub 仓库跳转按钮。
        XCTAssertTrue(aboutBody.contains("localizer.t(L.Settings.openGitHubRepo)"))
        XCTAssertTrue(aboutBody.contains("updater.openRepoPage()"))

        for key in ["storageSection", "storageStatus", "storageUsed", "aboutSection", "aboutAppName", "aboutSource"] {
            XCTAssertTrue(keys.contains(key))
        }
        for strings in [en, zhHans, zhHant] {
            XCTAssertTrue(strings.contains("L.Settings.storageSection"))
            XCTAssertTrue(strings.contains("L.Settings.storageStatus"))
            XCTAssertTrue(strings.contains("L.Settings.storageUsed"))
            XCTAssertTrue(strings.contains("L.Settings.aboutSection"))
            XCTAssertTrue(strings.contains("L.Settings.aboutAppName"))
            XCTAssertTrue(strings.contains("L.Settings.aboutSource"))
        }
    }

    func testLocalSpeechSettingsShowsRecommendedModelCatalogWithExplicitDownloadAction() throws {
        let source = try String(contentsOf: packageRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("Moongate")
            .appendingPathComponent("SettingsView.swift"))
        let keys = try String(contentsOf: packageRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("MoongateMobileCore")
            .appendingPathComponent("Localization")
            .appendingPathComponent("LocalizationKeys.swift"))

        let body = try XCTUnwrap(functionBody(named: "localSpeechSection", in: source))
        // v0.8：本地语音识别保留 Form/Section 原生结构；导入入口放标题动作区，
        // 模型列表不再使用彩色卡片，状态行负责告诉用户下一步。
        XCTAssertTrue(body.contains("localASRModelCatalogEntries"))
        XCTAssertTrue(body.contains("ForEach(localASRModelCatalogEntries"))
        XCTAssertTrue(body.contains("localizer.t(L.Settings.localASRRecommendedModels)"))
        XCTAssertTrue(body.contains("LocalASRSetupStatusView(state: localASRSetupState)"))
        XCTAssertTrue(body.contains("LocalASRModelListHeader("))
        XCTAssertTrue(body.contains("importAction: importLocalASRModel"))
        XCTAssertTrue(body.contains("localASRModelRow(entry, isRecommended: entry.id == recommended?.id)"))
        XCTAssertTrue(body.contains("recommendedModelForDevice()"))
        XCTAssertTrue(body.contains("localizer.t(L.Settings.localASRImportModel)"))
        XCTAssertTrue(body.contains("importedLocalASRModelRow()"))
        XCTAssertFalse(body.contains("Button {\n                        importLocalASRModel()"))
        XCTAssertFalse(body.contains("L.Settings.localASRRecommendedForDevice"))
        XCTAssertFalse(body.contains("DisclosureGroup(localizer.t(L.Settings.localASRAdvancedSettings))"))
        XCTAssertFalse(body.contains("TextField("))

        let statusBody = try XCTUnwrap(functionBody(named: "LocalASRSetupStatusView", in: source))
        XCTAssertTrue(statusBody.contains("localASRSetupAction(for: state)"))
        XCTAssertTrue(statusBody.contains(".accessibilityLabel(localASRSetupTitle(for: state))"))
        XCTAssertTrue(source.contains("private var localASRSetupState"))
        XCTAssertTrue(source.contains("case ready(runtimePath: String)"))
        XCTAssertTrue(source.contains("case missingRuntime"))
        XCTAssertTrue(source.contains("case missingModel"))
        XCTAssertTrue(source.contains("case badHash"))
        XCTAssertTrue(source.contains("case downloading(modelName: String)"))
        XCTAssertTrue(source.contains("requestDependencySetup()"))
        XCTAssertTrue(source.contains("installRecommendedLocalASRModel()"))

        let headerBody = try XCTUnwrap(functionBody(named: "LocalASRModelListHeader", in: source))
        XCTAssertTrue(headerBody.contains("Image(systemName: \"square.and.arrow.down\")"))
        XCTAssertTrue(headerBody.contains(".help(importTitle)"))
        XCTAssertTrue(headerBody.contains(".accessibilityLabel(importTitle)"))

        // 模型行本体：原生列表行图标、能力文案、下载/删除/进度。
        let rowBody = try XCTUnwrap(functionBody(named: "LocalASRModelRow", in: source))
        XCTAssertTrue(rowBody.contains("modelIcon(entry)"))
        XCTAssertTrue(rowBody.contains("modelTint(entry)"))
        XCTAssertTrue(rowBody.contains("modelCapabilityText(entry)"))
        XCTAssertTrue(rowBody.contains("localizer.t(L.Settings.localASRModelSizeMemory"))
        XCTAssertTrue(rowBody.contains("isRecommended"))
        XCTAssertTrue(rowBody.contains("localizer.t(L.Settings.localASRRecommendedBadge)"))
        XCTAssertTrue(rowBody.contains("localASRModelAccessibilityLabel(entry)"))
        XCTAssertTrue(rowBody.contains("localASRInstallingModelID"))
        XCTAssertTrue(rowBody.contains("ProgressView(value: localASRModelInstallProgress)"))
        XCTAssertTrue(rowBody.contains("installLocalASRModel(entry)"))
        XCTAssertTrue(rowBody.contains("deleteLocalASRModel(entry)"))
        XCTAssertTrue(rowBody.contains("useLocalASRModel(entry)"))
        XCTAssertTrue(rowBody.contains("localizer.t(L.Settings.localASRUseModel)"))
        XCTAssertTrue(rowBody.contains("localizer.t(L.Settings.localASRModelInUse)"))
        XCTAssertTrue(rowBody.contains("arrow.down.circle"))
        XCTAssertTrue(rowBody.contains("\"trash\""))
        XCTAssertTrue(rowBody.contains("role: .destructive"))
        XCTAssertFalse(rowBody.contains("RoundedRectangle(cornerRadius: 8"))
        XCTAssertFalse(source.contains("\"textformat\""))
        XCTAssertTrue(source.contains("\"text.bubble.fill\""))

        let importedRowBody = try XCTUnwrap(functionBody(named: "importedLocalASRModelRow", in: source))
        XCTAssertTrue(importedRowBody.contains("localizer.t(L.Settings.localASRImportedModelBadge)"))
        XCTAssertTrue(importedRowBody.contains("deleteImportedLocalASRModel()"))
        XCTAssertTrue(importedRowBody.contains("localizer.t(L.Settings.localASRImportedModelAccessibility"))
        XCTAssertFalse(importedRowBody.contains("RoundedRectangle(cornerRadius: 8"))

        let capabilityBody = try XCTUnwrap(functionBody(named: "modelCapabilityLabel", in: source))
        XCTAssertTrue(capabilityBody.contains("localizer.t(L.Settings.localASRModelCapabilityFast)"))
        XCTAssertTrue(capabilityBody.contains("localizer.t(L.Settings.localASRModelCapabilityBalanced)"))
        XCTAssertTrue(capabilityBody.contains("localizer.t(L.Settings.localASRModelCapabilityAccurate)"))
        XCTAssertTrue(capabilityBody.contains("localizer.t(L.Settings.localASRModelCapabilityEnglish)"))
        XCTAssertTrue(capabilityBody.contains("localizer.t(L.Settings.localASRModelCapabilityLongVideo)"))
        XCTAssertTrue(capabilityBody.contains("localizer.t(L.Settings.localASRModelCapabilityTurbo)"))
        XCTAssertFalse(source.contains("实时快速"))
        XCTAssertFalse(source.contains("日常平衡"))
        XCTAssertFalse(source.contains("高精度"))

        let recommendationBody = try XCTUnwrap(functionBody(named: "recommendedModelForDevice", in: source))
        XCTAssertTrue(source.contains("private var unsortedLocalASRModelCatalogEntries"))
        XCTAssertTrue(source.contains("let recommendedEntry = sorted.remove(at: recommendedIndex)"))
        XCTAssertTrue(source.contains("sorted.insert(recommendedEntry, at: 0)"))
        XCTAssertTrue(recommendationBody.contains("\"whisper.cpp:small-q5_1\""))
        XCTAssertTrue(recommendationBody.contains("\"whisper.cpp:large-v3-turbo-q5_0\""))
        XCTAssertFalse(recommendationBody.contains("!$0.isInstalled"))

        XCTAssertTrue(source.contains("manifest: .recommendedWhisperCpp"))
        XCTAssertTrue(source.contains("ASRModelCatalog"))
        XCTAssertTrue(source.contains("ASRModelInstaller"))
        XCTAssertTrue(source.contains("NSOpenPanel"))
        XCTAssertTrue(source.contains("private func importLocalASRModel()"))
        XCTAssertTrue(source.contains("private func importLocalASRModel(from sourceURL: URL)"))
        XCTAssertTrue(source.contains("ASRRuntimeLocator(extraSearchURLs: localASRRuntimeSearchURLs).locate()"))
        XCTAssertTrue(source.contains("private func adoptLocalASRRuntime()"))
        XCTAssertTrue(source.contains("needsUserDownloadConsent"))
        XCTAssertTrue(source.contains("private func installLocalASRModel(_ entry: ASRModelCatalogEntry)"))
        XCTAssertFalse(source.contains("downloadLocalASRModel"))
        XCTAssertFalse(source.contains("URLSession.shared.download"))

        XCTAssertTrue(keys.contains("localASRRecommendedModels"))
        XCTAssertTrue(keys.contains("localASRFindRuntime"))
        XCTAssertTrue(keys.contains("localASRRepairSetup"))
        XCTAssertTrue(keys.contains("localASRSetupReady"))
        XCTAssertTrue(keys.contains("localASRSetupMissingRuntime"))
        XCTAssertTrue(keys.contains("localASRSetupMissingModel"))
        XCTAssertTrue(keys.contains("localASRSetupRepair"))
        XCTAssertTrue(keys.contains("localASRSetupChooseModel"))
        XCTAssertTrue(keys.contains("localASRSetupBadModel"))
        XCTAssertTrue(keys.contains("localASRSetupDownloadRecommended"))
        XCTAssertTrue(keys.contains("localASROptionalNotConfigured"))
        XCTAssertTrue(keys.contains("localASRRuntimeFound"))
        XCTAssertTrue(keys.contains("localASRRuntimeNotFound"))
        XCTAssertTrue(keys.contains("localASRDownloadModel"))
        XCTAssertTrue(keys.contains("localASRInstallingModel"))
        XCTAssertTrue(keys.contains("localASRModelInstallComplete"))
        XCTAssertTrue(keys.contains("localASRImportModel"))
        XCTAssertTrue(keys.contains("localASRImportedModelBadge"))
        XCTAssertTrue(keys.contains("localASRImportedModelDetail"))
        XCTAssertTrue(keys.contains("localASRModelImportComplete"))
        XCTAssertTrue(keys.contains("localASRDeleteModel"))
        XCTAssertTrue(keys.contains("localASRDeleteImportedModel"))
        XCTAssertTrue(keys.contains("localASRRecommendedBadge"))
        XCTAssertTrue(keys.contains("localASRModelCapability"))
        XCTAssertTrue(keys.contains("localASRModelCapabilityFast"))
        XCTAssertTrue(keys.contains("localASRModelCapabilityBalanced"))
        XCTAssertTrue(keys.contains("localASRModelCapabilityAccurate"))
        XCTAssertTrue(keys.contains("localASRModelCapabilityRecommended"))
        XCTAssertTrue(keys.contains("localASRModelCapabilityDetailed"))
        XCTAssertTrue(keys.contains("localASRModelCapabilityEnglish"))
        XCTAssertTrue(keys.contains("localASRModelCapabilityLongVideo"))
        XCTAssertTrue(keys.contains("localASRModelCapabilityTurbo"))
        XCTAssertTrue(keys.contains("localASRUseModel"))
        XCTAssertTrue(keys.contains("localASRModelInUse"))
    }

    func testLocalASRRuntimeFinderSearchesBundledRuntimeAndSupportDirectory() throws {
        let source = try String(contentsOf: packageRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("Moongate")
            .appendingPathComponent("SettingsView.swift"))
        let searchBody = try XCTUnwrap(functionBody(named: "localASRRuntimeSearchURLs", in: source))

        XCTAssertTrue(searchBody.contains("Bundle.main.resourceURL"))
        XCTAssertTrue(searchBody.contains("appendingPathComponent(\"asr\", isDirectory: true)"))
        XCTAssertTrue(searchBody.contains("appendingPathComponent(\"runtime\", isDirectory: true)"))
        XCTAssertTrue(searchBody.contains("AppSettings.supportDirectory"))
        XCTAssertTrue(searchBody.contains("runtimeURL.appendingPathComponent(\"bin\", isDirectory: true)"))
        XCTAssertTrue(searchBody.contains("bundledRuntimeURL.appendingPathComponent(\"bin\", isDirectory: true)"))
        XCTAssertTrue(source.contains("ASRRuntimeLocator(extraSearchURLs: localASRRuntimeSearchURLs).locate()"))
    }

    func testSettingsSidebarShowsUpdateBadgeWhenUpdateIsAvailable() throws {
        let source = try String(contentsOf: packageRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("Moongate")
            .appendingPathComponent("SettingsView.swift"))
        let rowBody = try XCTUnwrap(functionBody(named: "settingsPaneRow", in: source))
        let badgeBody = try XCTUnwrap(functionBody(named: "settingsUpdateBadge", in: source))

        XCTAssertTrue(rowBody.contains("if pane == .updates && updater.updateAvailable"))
        XCTAssertTrue(rowBody.contains("settingsUpdateBadge"))
        XCTAssertTrue(rowBody.contains("localizer.t(L.Update.updateAvailableStatus)"))
        XCTAssertTrue(rowBody.contains(".accessibilityValue"))
        XCTAssertFalse(badgeBody.contains("Text(\"1\")"))
        XCTAssertTrue(badgeBody.contains("Circle()"))
        XCTAssertTrue(badgeBody.contains(".fill(.red)"))
        XCTAssertTrue(badgeBody.contains(".accessibilityHidden(true)"))
    }

    func testSettingsExposeAppAndTargetLanguagePickersAndPersistThem() throws {
        let source = try String(contentsOf: packageRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("Moongate")
            .appendingPathComponent("SettingsView.swift"))

        XCTAssertTrue(source.contains("@EnvironmentObject private var localizer: Localizer"))
        XCTAssertTrue(source.contains("languageSection"))
        XCTAssertTrue(source.contains("Section(localizer.t(L.Settings.languageSection))"))
        XCTAssertTrue(source.contains("Picker(localizer.t(L.Settings.appLanguage)"))
        XCTAssertTrue(source.contains("Text(localizer.t(L.Settings.followSystem))"))
        XCTAssertTrue(source.contains("Picker(localizer.t(L.Settings.targetLanguage)"))
        XCTAssertTrue(source.contains("Text(localizer.t(L.Settings.languageHelp))"))
        XCTAssertTrue(source.contains("$draft.appLanguage"))
        XCTAssertTrue(source.contains("$draft.translationTargetLanguage"))
        XCTAssertTrue(source.contains("localizer.setLanguage("))
        // 11c：实时保存把草稿写回 model.settings（persistDraftLive 里 model.settings = newValue）。
        XCTAssertTrue(source.contains("model.settings = newValue"))
    }

    func testPrimaryAIConfigurationSectionsUseLocalizer() throws {
        let source = try String(contentsOf: packageRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("Moongate")
            .appendingPathComponent("SettingsView.swift"))

        let translationSectionBody = try XCTUnwrap(functionBody(named: "translationSection", in: source))
        XCTAssertTrue(translationSectionBody.contains("Section(localizer.t(L.Settings.aiSettingsSection))"))
        XCTAssertTrue(translationSectionBody.contains("Text(localizer.t(L.Settings.aiSettingsDescription))"))
        XCTAssertTrue(translationSectionBody.contains("Picker(localizer.t(L.Settings.aiEngine)"))

        let translationConfigBody = try XCTUnwrap(functionBody(named: "translationConfigSection", in: source))
        XCTAssertTrue(translationConfigBody.contains("Section(localizer.t(L.Settings.aiTranslationSection))"))
        XCTAssertTrue(translationConfigBody.contains("Toggle(localizer.t(L.Settings.smartTranslationPrompts)"))
        XCTAssertTrue(translationConfigBody.contains("Text(localizer.t(L.Settings.smartTranslationPromptsHelp))"))
        XCTAssertTrue(translationConfigBody.contains("Picker(localizer.t(L.Settings.configMode)"))
        XCTAssertTrue(translationConfigBody.contains("Text(localizer.t(L.Settings.followAISettings))"))
        XCTAssertTrue(translationConfigBody.contains("Text(localizer.t(L.Settings.configureSeparately))"))
        XCTAssertTrue(translationConfigBody.contains("Picker(localizer.t(L.Settings.translationEngine)"))

        let summaryBody = try XCTUnwrap(functionBody(named: "summarySection", in: source))
        XCTAssertTrue(summaryBody.contains("Section(localizer.t(L.Settings.aiSummarySection))"))
        XCTAssertTrue(summaryBody.contains("Picker(localizer.t(L.Settings.configMode)"))
        XCTAssertTrue(summaryBody.contains("Text(localizer.t(L.Settings.defaultEngineCannotSummarize))"))
    }

    func testUpdateSectionExposesSparkleCheckAndReleaseFallback() throws {
        let source = try String(contentsOf: packageRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("Moongate")
            .appendingPathComponent("SettingsView.swift"))
        let body = try XCTUnwrap(functionBody(named: "updateSection", in: source))
        // 当前版本、Sparkle 原生检查入口、队列保护、GitHub 兜底。
        XCTAssertTrue(body.contains("updater.currentVersion"))
        XCTAssertTrue(body.contains("Section(localizer.t(L.Update.sectionTitle))"))
        XCTAssertTrue(body.contains("Text(localizer.t(L.Update.currentVersion))"))
        XCTAssertTrue(body.contains("Button(localizer.t(L.Update.check))"))
        XCTAssertTrue(body.contains("startUpdateCheckFromSettings()"))
        XCTAssertTrue(body.contains(".disabled(!updater.canCheckForUpdates)"))
        XCTAssertTrue(body.contains("Button(localizer.t(L.Update.openReleases))"))
        XCTAssertTrue(body.contains("updater.openReleasesPage()"))
        XCTAssertTrue(body.contains("Button(localizer.t(L.Common.retry))"))
        XCTAssertTrue(body.contains("Button(localizer.t(L.Update.openGitHubDownload))"))
        XCTAssertTrue(body.contains("case .idle"))
        XCTAssertTrue(body.contains("case .failed(let reason)"))
        XCTAssertFalse(body.contains("updater.downloadAndInstall(info)"))
        XCTAssertFalse(body.contains("case .available(let info)"))
        XCTAssertFalse(body.contains("case .downloading"))
        XCTAssertFalse(body.contains("case .installerOpened"))
        let helper = try XCTUnwrap(functionBody(named: "startUpdateCheckFromSettings", in: source))
        XCTAssertTrue(helper.contains("model.queue.openTaskCount"))
        XCTAssertTrue(helper.contains("updater.blockInstallDueToOpenTasks"))
        XCTAssertTrue(helper.contains("model.showSettings = false"))
        XCTAssertTrue(helper.contains("DispatchQueue.main.asyncAfter"))
        XCTAssertTrue(helper.contains("updater.checkForUpdates()"))
        // 更新区被挂进 Form（与其他 section 并列）。
        XCTAssertTrue(source.contains("performanceSection"))
        XCTAssertTrue(source.contains("loginSection\n                updateSection")
            || source.contains("updateSection"))
    }

    func testSettingsViewReusesSharedUpdaterFromViewModel() throws {
        let source = try String(contentsOf: packageRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("Moongate")
            .appendingPathComponent("SettingsView.swift"))

        XCTAssertTrue(source.contains("@ObservedObject private var updater: UpdateService"))
        XCTAssertFalse(source.contains("@StateObject private var updater = UpdateService()"))
        XCTAssertTrue(source.contains("init(model: ViewModel)"))
        XCTAssertTrue(source.contains("self._updater = ObservedObject(wrappedValue: model.updater)"))
        XCTAssertTrue(source.contains("model.checkForUpdatesIfNeeded()"))
    }

    func testUpdateServiceWrapsSparkleNativeUpdater() throws {
        let source = try String(contentsOf: packageRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("Moongate")
            .appendingPathComponent("UpdateService.swift"))

        XCTAssertTrue(source.contains("SPUStandardUpdaterController"))
        XCTAssertTrue(source.contains("SPUStandardUserDriverDelegate"))
        XCTAssertTrue(source.contains("userDriverDelegate: self"))
        XCTAssertTrue(source.contains("prepareForUpdateUI?()"))
        XCTAssertTrue(source.contains("@Published private(set) var canCheckForUpdates"))
        XCTAssertTrue(source.contains("updaterController.checkForUpdates(nil)"))
        // UPDATE-MAC-001：移除 no-op 的 silent 检查，后台检查交给 Sparkle 调度。
        XCTAssertFalse(source.contains("guard !silent else { return }"))
        XCTAssertTrue(source.contains("NSWorkspace.shared.open(releasesPageURL)"))
        XCTAssertFalse(source.contains("hasAvailableUpdate"))
    }

    func testSecondarySettingsSectionsUseLocalizer() throws {
        let source = try String(contentsOf: packageRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("Moongate")
            .appendingPathComponent("SettingsView.swift"))

        let performanceBody = try XCTUnwrap(functionBody(named: "performanceSection", in: source))
        XCTAssertTrue(performanceBody.contains("Section(localizer.t(L.Settings.performanceSection))"))
        XCTAssertTrue(performanceBody.contains("Text(localizer.t(L.Settings.concurrentDownloads))"))
        XCTAssertTrue(performanceBody.contains("Text(localizer.t(L.Settings.concurrentBurns))"))
        XCTAssertTrue(performanceBody.contains("Text(localizer.t(L.Settings.performanceHelp))"))

        let styleBody = try XCTUnwrap(functionBody(named: "styleSection", in: source))
        XCTAssertTrue(styleBody.contains("Section(localizer.t(L.Settings.styleSection))"))
        XCTAssertTrue(styleBody.contains("Picker(localizer.t(L.Settings.subtitleStyle),"))
        XCTAssertTrue(styleBody.contains("Text(localizer.t(L.Settings.subtitleStyleBilingual))"))
        XCTAssertTrue(styleBody.contains("Text(localizer.t(L.Settings.subtitleStyleChineseOnly))"))

        let burnBody = try XCTUnwrap(functionBody(named: "burnQualitySection", in: source))
        XCTAssertTrue(burnBody.contains("Section(localizer.t(L.Settings.burnSection))"))
        XCTAssertTrue(burnBody.contains("Picker(localizer.t(L.Settings.encodeBackend),"))
        XCTAssertTrue(burnBody.contains("Picker(localizer.t(L.Settings.burnEncoding),"))
        XCTAssertTrue(burnBody.contains("Text(localizer.t(L.Settings.followSourceHEVC))"))
        XCTAssertTrue(burnBody.contains("Text(localizer.t(L.Settings.alwaysH264))"))
        XCTAssertTrue(burnBody.contains("localizer.t(L.Settings.scaleHD1080)"))

        let loginBody = try XCTUnwrap(functionBody(named: "loginSection", in: source))
        XCTAssertTrue(loginBody.contains("Section(localizer.t(L.Settings.loginSection))"))
        XCTAssertTrue(loginBody.contains("Button(localizer.t(L.Settings.loginYouTube))"))
        XCTAssertTrue(loginBody.contains("Button(localizer.t(L.Settings.loginBilibili))"))
        XCTAssertTrue(loginBody.contains("Button(localizer.t(L.Settings.clearAppLogin), role: .destructive)"))
        XCTAssertTrue(loginBody.contains("localizer.t(L.Settings.clearLoginDialogTitle)"))
        XCTAssertTrue(loginBody.contains("Button(localizer.t(L.Settings.clearLoginAction), role: .destructive)"))

        // 11c：底部「完成/取消」按钮已移除，改为实时保存；通知改用 safeAreaInset 横幅展示。
        XCTAssertFalse(source.contains("private var bottomBar"))
        XCTAssertTrue(source.contains("model.settingsNotice"))

        let loginStatusBody = try XCTUnwrap(functionBody(named: "loginStatusText", in: source))
        XCTAssertTrue(loginStatusBody.contains("localizer.t(L.Settings.loginNone)"))
        XCTAssertTrue(loginStatusBody.contains("localizer.t(L.Settings.loginSaved"))
    }

    func testAppleTranslationReadinessUsesUserVisibleSourceLanguageContext() throws {
        let source = try String(contentsOf: packageRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("Moongate")
            .appendingPathComponent("SettingsView.swift"))

        XCTAssertTrue(source.contains("@State private var appleTranslationSourceLanguage"))
        XCTAssertTrue(source.contains("Picker(localizer.t(L.Settings.sourceLanguage)"))
        XCTAssertTrue(source.contains("appleTranslationReadinessContext()"))
        XCTAssertTrue(source.contains(".onChange(of: appleTranslationSourceLanguage)"))

        let readinessContextBody = try XCTUnwrap(functionBody(named: "appleTranslationReadinessContext", in: source))
        // B：目标语言来自设置（单一漏斗），源语言仍来自用户可见的选择器。
        XCTAssertTrue(readinessContextBody.contains("draft.makeTranslationContext(sourceLanguage: nil)"))
        XCTAssertTrue(readinessContextBody.contains("draft.makeTranslationContext(sourceLanguage: appleTranslationSourceLanguage)"))
        XCTAssertFalse(readinessContextBody.contains("targetLanguage: \"zh-Hans\""))
    }

    func testAppleTranslationPickerVisibilityAndRuntimeReadinessUseExpectedContext() throws {
        let source = try String(contentsOf: packageRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("Moongate")
            .appendingPathComponent("SettingsView.swift"))

        let pickerVisibilityBody = try XCTUnwrap(functionBody(named: "shouldShowAppleTranslationSourceLanguagePicker", in: source))
        let compactPickerVisibilityBody = compactWhitespace(pickerVisibilityBody)
        XCTAssertTrue(compactPickerVisibilityBody.contains("case .appleTranslationLowLatency, .appleTranslationHighFidelity: return true"))
        XCTAssertTrue(compactPickerVisibilityBody.contains("case .anthropicCompatible, .openAICompatible, .appleFoundationOnDevice, .appleFoundationPCC, .appleFoundationCloudPro: return false"))

        let refreshReadinessBody = try XCTUnwrap(functionBody(named: "refreshDraftRuntimeReadiness", in: source))
        XCTAssertTrue(refreshReadinessBody.contains("let context = appleTranslationReadinessContext()"))
        XCTAssertTrue(refreshReadinessBody.contains("translationRuntimeReadiness("))
        XCTAssertTrue(refreshReadinessBody.contains("context: context"))
    }

    func testAPICredentialCopyKeepsProtocolDetailsBehindDisclosure() throws {
        let source = try String(contentsOf: packageRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("Moongate")
            .appendingPathComponent("SettingsView.swift"))

        let apiFieldsBody = try XCTUnwrap(functionBody(named: "apiTranslationFields", in: source))
        XCTAssertTrue(apiFieldsBody.contains("DisclosureGroup"))
        XCTAssertTrue(apiFieldsBody.contains("credentialSummaryText"))
        XCTAssertTrue(apiFieldsBody.contains("credentialDetailText"))
        XCTAssertLessThan(
            try XCTUnwrap(apiFieldsBody.range(of: "credentialSummaryText")).lowerBound,
            try XCTUnwrap(apiFieldsBody.range(of: "DisclosureGroup")).lowerBound,
            "Credential summary should stay always-visible, outside the advanced disclosure."
        )

        let summaryBody = try XCTUnwrap(functionBody(named: "credentialSummaryText", in: source))
        let technicalTerms = [
            "ANTHROPIC_BASE_URL",
            "ANTHROPIC_AUTH_TOKEN",
            "Responses API",
            "Bearer",
            "DeepSeek",
        ]
        for term in technicalTerms {
            XCTAssertFalse(summaryBody.contains(term), "\(term) should stay out of always-visible credential copy")
        }

        let detailBody = try XCTUnwrap(functionBody(named: "credentialDetailText", in: source))
        XCTAssertTrue(detailBody.contains("localizer.t(L.Settings.credentialDetailAnthropic)"))
        XCTAssertTrue(detailBody.contains("localizer.t(L.Settings.credentialDetailOpenAI)"))
        XCTAssertFalse(detailBody.contains("appleTranslation"))
        XCTAssertFalse(detailBody.contains("appleFoundation"))
        XCTAssertFalse(detailBody.contains("PCC"))
    }

    func testAPICredentialCopyNamesOnlyUserTriggeredNetworkActions() throws {
        let source = try String(contentsOf: packageRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("Moongate")
            .appendingPathComponent("SettingsView.swift"))

        let summaryBody = try XCTUnwrap(functionBody(named: "credentialSummaryText", in: source))
        XCTAssertTrue(summaryBody.contains("localizer.t(L.Settings.credentialSummary)"))
        XCTAssertFalse(summaryBody.contains("测试连接前不会发送"))

        let apiFieldsBody = try XCTUnwrap(functionBody(named: "apiTranslationFields", in: source))
        XCTAssertTrue(apiFieldsBody.contains("Text(credentialSummaryText)"))
        XCTAssertLessThan(
            try XCTUnwrap(apiFieldsBody.range(of: "Text(credentialSummaryText)")).lowerBound,
            try XCTUnwrap(apiFieldsBody.range(of: "DisclosureGroup")).lowerBound,
            "Credential summary must remain visible before advanced protocol details."
        )
    }

    func testDefaultAIConnectionActionsDoNotUseTranslationOverrideEndpoint() throws {
        let source = try String(contentsOf: packageRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("Moongate")
            .appendingPathComponent("SettingsView.swift"))

        let testBody = try XCTUnwrap(functionBody(named: "runConnectionTest", in: source))
        XCTAssertTrue(testBody.contains("draft.applyingTranslationConfig(defaultAIConfig)"))
        XCTAssertFalse(testBody.contains("draft.effectiveTranslationConfig"))

        let fetchBody = try XCTUnwrap(functionBody(named: "fetchModels", in: source))
        XCTAssertTrue(fetchBody.contains("draft.applyingTranslationConfig(defaultAIConfig)"))
        XCTAssertFalse(fetchBody.contains("draft.effectiveTranslationConfig"))

        let apiFieldsBody = try XCTUnwrap(functionBody(named: "apiTranslationFields", in: source))
        XCTAssertTrue(apiFieldsBody.contains("!draft.applyingTranslationConfig(defaultAIConfig).isTranslationConfigured"))
        XCTAssertFalse(apiFieldsBody.contains("!draft.translationReadiness().isReady"))

        let configBody = try XCTUnwrap(functionBody(named: "defaultAIConfig", in: source))
        XCTAssertTrue(configBody.contains("engine: draft.aiEngine"))
        XCTAssertTrue(configBody.contains("baseURL: draft.aiBaseURL"))
        XCTAssertTrue(configBody.contains("model: draft.aiModel"))
        XCTAssertTrue(configBody.contains("authToken: draft.aiAuthToken"))
    }

    func testAPITranslationProgressIndicatorsExposeAccessibleLabels() throws {
        let source = try String(contentsOf: packageRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("Moongate")
            .appendingPathComponent("SettingsView.swift"))

        let apiFieldsBody = try XCTUnwrap(functionBody(named: "apiTranslationFields", in: source))

        let modelProgressStart = try XCTUnwrap(apiFieldsBody.range(of: "ProgressView().controlSize(.small)"))
        let modelProgressEnd = try XCTUnwrap(apiFieldsBody.range(
            of: "case .loaded",
            range: modelProgressStart.upperBound..<apiFieldsBody.endIndex
        ))
        let modelProgressSnippet = String(apiFieldsBody[modelProgressStart.lowerBound..<modelProgressEnd.lowerBound])
        XCTAssertTrue(modelProgressSnippet.contains(".accessibilityLabel(localizer.t(L.Settings.fetchingModels))"))

        let testProgressStart = try XCTUnwrap(apiFieldsBody.range(of: "case .testing:"))
        let testProgressEnd = try XCTUnwrap(apiFieldsBody.range(
            of: "case .success:",
            range: testProgressStart.upperBound..<apiFieldsBody.endIndex
        ))
        let testProgressSnippet = String(apiFieldsBody[testProgressStart.lowerBound..<testProgressEnd.lowerBound])
        XCTAssertTrue(testProgressSnippet.contains(".accessibilityLabel(localizer.t(L.Settings.testingConnection))"))
    }

    func testClearLoginActionExplainsAppScopedSideEffects() throws {
        let source = try String(contentsOf: packageRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("Moongate")
            .appendingPathComponent("SettingsView.swift"))

        let loginSectionBody = try XCTUnwrap(functionBody(named: "loginSection", in: source))
        let outerButtonRange = try XCTUnwrap(loginSectionBody.range(of: "Button(localizer.t(L.Settings.clearAppLogin), role: .destructive)"))
        let confirmationDialogRange = try XCTUnwrap(loginSectionBody.range(of: ".confirmationDialog"))
        let outerClearLoginButton = String(loginSectionBody[outerButtonRange.lowerBound..<confirmationDialogRange.lowerBound])

        XCTAssertTrue(outerClearLoginButton.contains("Button(localizer.t(L.Settings.clearAppLogin), role: .destructive)"))
        XCTAssertTrue(outerClearLoginButton.contains(".accessibilityHint(clearLoginHelpText)"))
        XCTAssertTrue(loginSectionBody.contains("Text(clearLoginHelpText)"))
        XCTAssertTrue(loginSectionBody.contains("localizer.t(L.Settings.clearLoginDialogTitle)"))
        XCTAssertTrue(loginSectionBody.contains("Button(localizer.t(L.Settings.clearLoginAction), role: .destructive)"))
        XCTAssertTrue(loginSectionBody.contains("Button(localizer.t(L.Common.cancel), role: .cancel)"))
        XCTAssertFalse(loginSectionBody.contains("\"确定要清除所有登录吗？\""))
        XCTAssertFalse(loginSectionBody.contains("Button(\"清除所有登录\", role: .destructive)"))

        XCTAssertTrue(source.contains("private var clearLoginHelpText"))
        let clearLoginHelpTextBody = try XCTUnwrap(functionBody(named: "clearLoginHelpText", in: source))
        XCTAssertTrue(clearLoginHelpTextBody.contains("localizer.t(L.Settings.clearLoginHelp)"))
    }

    func testCloudCredentialSurfaceStaysLimitedToAPICompatibleProviders() throws {
        let source = try String(contentsOf: packageRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("Moongate")
            .appendingPathComponent("SettingsView.swift"))

        let translationSectionBody = try XCTUnwrap(functionBody(named: "translationSection", in: source))
        XCTAssertTrue(translationSectionBody.contains("if draft.aiEngine.requiresCloudConfiguration"))
        XCTAssertTrue(translationSectionBody.contains("apiTranslationFields"))
        XCTAssertTrue(translationSectionBody.contains("appleTranslationReadiness"))

        let apiFieldsBody = try XCTUnwrap(functionBody(named: "apiTranslationFields", in: source))
        XCTAssertFalse(apiFieldsBody.contains("TranslationEngine.allCases"))
        XCTAssertFalse(apiFieldsBody.contains("appleTranslation"))
        XCTAssertFalse(apiFieldsBody.contains("appleFoundation"))
        XCTAssertFalse(apiFieldsBody.contains("PCC"))

        let apiProviderBody = try XCTUnwrap(functionBody(named: "apiProvider", in: source))
        XCTAssertTrue(apiProviderBody.contains("draft.aiEngine.legacyProvider ?? .anthropic"))

        let detailBody = try XCTUnwrap(functionBody(named: "credentialDetailText", in: source))
        XCTAssertTrue(detailBody.contains("switch apiProvider"))
        XCTAssertTrue(detailBody.contains("case .anthropic"))
        XCTAssertTrue(detailBody.contains("case .openai"))
        XCTAssertFalse(detailBody.contains("appleTranslation"))
        XCTAssertFalse(detailBody.contains("appleFoundation"))
        XCTAssertFalse(detailBody.contains("PCC"))
    }

    func testAppleReadinessPanelExposesStateAndFallbackSemantics() throws {
        let source = try String(contentsOf: packageRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("Moongate")
            .appendingPathComponent("SettingsView.swift"))

        let readinessBody = try XCTUnwrap(functionBody(named: "appleTranslationReadiness", in: source))
        XCTAssertTrue(readinessBody.contains(".accessibilityElement(children: .combine)"))
        XCTAssertTrue(readinessBody.contains(".accessibilityLabel(localizer.t(L.Settings.appleTranslationStatus))"))
        XCTAssertTrue(readinessBody.contains("let statusText = readiness.isReady ? localizer.t(L.Settings.statusReady) : localizer.t(L.Settings.statusNeedsAction)"))
        XCTAssertTrue(readinessBody.contains(".accessibilityValue(\"\\(draft.aiEngine.displayName)，\\(statusText)：\\(readinessMessage(readiness))\")"))

        let guidanceBody = try XCTUnwrap(functionBody(named: "appleSetupGuidance", in: source))
        XCTAssertTrue(guidanceBody.contains("fallbackEngineText"))
        XCTAssertTrue(guidanceBody.contains("Text(fallbackEngineText)"))
        XCTAssertTrue(guidanceBody.contains(".accessibilityHint(localizer.t(L.Settings.fallbackEngineHint))"))

        let fallbackBody = try XCTUnwrap(functionBody(named: "fallbackEngineText", in: source))
        XCTAssertTrue(fallbackBody.contains("localizer.t(L.Settings.fallbackEngine)"))
        XCTAssertFalse(fallbackBody.contains("Apple 本机引擎"))
        XCTAssertFalse(fallbackBody.contains("PCC"))
        XCTAssertFalse(fallbackBody.localizedCaseInsensitiveContains("Cloud Pro"))
        XCTAssertFalse(fallbackBody.contains("云端"))
        XCTAssertFalse(fallbackBody.contains("NSWorkspace"))
        XCTAssertFalse(fallbackBody.localizedCaseInsensitiveContains("token"))
        XCTAssertFalse(fallbackBody.localizedCaseInsensitiveContains("cookie"))
    }

    func testAppleReadinessPanelShowsScannableEngineStatusSummary() throws {
        let source = try String(contentsOf: packageRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("Moongate")
            .appendingPathComponent("SettingsView.swift"))

        let readinessBody = try XCTUnwrap(functionBody(named: "appleTranslationReadiness", in: source))
        XCTAssertTrue(readinessBody.contains("let statusText = readiness.isReady ? localizer.t(L.Settings.statusReady) : localizer.t(L.Settings.statusNeedsAction)"))
        XCTAssertTrue(readinessBody.contains("Text(localizer.t(L.Settings.currentEngine))"))
        XCTAssertTrue(readinessBody.contains("Text(draft.aiEngine.displayName)"))
        XCTAssertTrue(readinessBody.contains("Text(localizer.t(L.Settings.status))"))
        XCTAssertTrue(readinessBody.contains("Text(statusText)"))
        XCTAssertTrue(readinessBody.contains("Text(localizer.t(L.Settings.primaryReason))"))
        XCTAssertTrue(readinessBody.contains("Text(readinessMessage(readiness))"))
        XCTAssertTrue(readinessBody.contains(".accessibilityValue(\"\\(draft.aiEngine.displayName)，\\(statusText)：\\(readinessMessage(readiness))\")"))
        XCTAssertFalse(readinessBody.contains("Text(\"中文字幕翻译状态\")"))
        XCTAssertTrue(readinessBody.contains("if !readiness.isReady"))
        XCTAssertTrue(readinessBody.contains("appleSetupGuidance(guidance)"))

        let guidanceBody = try XCTUnwrap(functionBody(named: "appleSetupGuidance", in: source))
        XCTAssertTrue(guidanceBody.contains("Text(fallbackEngineText)"))

        let fallbackBody = try XCTUnwrap(functionBody(named: "fallbackEngineText", in: source))
        XCTAssertTrue(fallbackBody.contains("localizer.t(L.Settings.fallbackEngine)"))
        XCTAssertFalse(fallbackBody.contains("Apple 本机引擎"))
        XCTAssertFalse(fallbackBody.contains("PCC"))
        XCTAssertFalse(fallbackBody.localizedCaseInsensitiveContains("Cloud Pro"))
        XCTAssertFalse(fallbackBody.contains("云端"))
    }

    func testDependencyStatusRowsExposeCombinedAccessibilitySemantics() throws {
        let source = try String(contentsOf: packageRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("Moongate")
            .appendingPathComponent("SettingsView.swift"))

        let dependencySectionBody = try XCTUnwrap(functionBody(named: "dependencySection", in: source))
        let rowsStart = try XCTUnwrap(dependencySectionBody.range(of: "ForEach(dependencyComponents)"))
        let rowsEnd = try XCTUnwrap(dependencySectionBody.range(
            of: "HStack(spacing: 10)",
            range: rowsStart.upperBound..<dependencySectionBody.endIndex
        ))
        let componentRowsBody = String(dependencySectionBody[rowsStart.lowerBound..<rowsEnd.lowerBound])

        XCTAssertTrue(componentRowsBody.contains(".accessibilityElement(children: .combine)"))
        XCTAssertTrue(componentRowsBody.contains(".accessibilityLabel(componentAccessibilityLabel(component))"))
        XCTAssertTrue(componentRowsBody.contains(".accessibilityValue(componentReadyText(component))"))
        XCTAssertTrue(componentRowsBody.contains("!component.isRequired"))
        XCTAssertTrue(componentRowsBody.contains("localizer.t(L.Dependency.optionalBadge)"))
        XCTAssertFalse(componentRowsBody.contains(".accessibilityHint("))

        let helperBody = try XCTUnwrap(functionBody(named: "componentAccessibilityLabel", in: source))
        XCTAssertTrue(helperBody.contains("component.id"))
        XCTAssertTrue(helperBody.contains("componentPurposeText(component)"))
        XCTAssertTrue(helperBody.contains("localizer.t(L.Dependency.componentAccessibilityLabel"))

        let readyBody = try XCTUnwrap(functionBody(named: "componentReadyText", in: source))
        XCTAssertTrue(readyBody.contains("component.isRequired"))
        XCTAssertTrue(readyBody.contains("localizer.t(L.Dependency.statusOptionalMissing)"))
    }

    func testAppleSetupActionButtonsExposeSideEffectHelp() throws {
        let source = try String(contentsOf: packageRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("Moongate")
            .appendingPathComponent("SettingsView.swift"))

        let guidanceBody = try XCTUnwrap(functionBody(named: "appleSetupGuidance", in: source))
        XCTAssertTrue(guidanceBody.contains("ForEach(guidance.actions)"))
        XCTAssertTrue(guidanceBody.contains("Button(appleSetupActionTitle(action.kind))"))
        XCTAssertTrue(guidanceBody.contains("performAppleSetupAction(action)"))

        let buttonStart = try XCTUnwrap(guidanceBody.range(of: "Button(appleSetupActionTitle(action.kind))"))
        let buttonEnd = guidanceBody.range(
            of: ".buttonStyle(.bordered)",
            range: buttonStart.upperBound..<guidanceBody.endIndex
        )?.upperBound ?? guidanceBody.endIndex
        let actionButtonSnippet = String(guidanceBody[buttonStart.lowerBound..<buttonEnd])
        XCTAssertTrue(actionButtonSnippet.contains(".help(appleSetupActionHelpText(action.kind))"))
        XCTAssertTrue(actionButtonSnippet.contains(".accessibilityHint(appleSetupActionHelpText(action.kind))"))

        XCTAssertTrue(source.contains("private func appleSetupActionHelpText(_ kind: AppleTranslationSetupActionKind) -> String"))
        let helpTextBody = try XCTUnwrap(functionBody(named: "appleSetupActionHelpText", in: source))
        XCTAssertTrue(helpTextBody.contains("localizer.t(L.Settings.appleActionRefreshHelp)"))
        XCTAssertTrue(helpTextBody.contains("localizer.t(L.Settings.appleActionOpenLanguageSettingsHelp)"))
        XCTAssertTrue(helpTextBody.contains("localizer.t(L.Settings.appleActionChooseDifferentEngineHelp)"))
        XCTAssertFalse(helpTextBody.contains("切回 Apple 引擎"))

        let appleIntelligenceCaseStart = try XCTUnwrap(
            helpTextBody.range(of: "case .openAppleIntelligenceSettings:")
        )
        let appleIntelligenceCaseEnd = try XCTUnwrap(
            helpTextBody.range(
                of: "case .chooseDifferentEngine:",
                range: appleIntelligenceCaseStart.upperBound..<helpTextBody.endIndex
            )
        )
        let appleIntelligenceHelpSnippet = String(
            helpTextBody[appleIntelligenceCaseStart.lowerBound..<appleIntelligenceCaseEnd.lowerBound]
        )
        XCTAssertTrue(appleIntelligenceHelpSnippet.contains("localizer.t(L.Settings.appleActionOpenAppleIntelligenceSettingsHelp)"))
        XCTAssertFalse(appleIntelligenceHelpSnippet.contains("Anthropic-compatible"))
    }

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func functionBody(named name: String, in source: String) -> String? {
        let declarations = [
            "private func \(name)(",
            "private var \(name):",
            "private var \(name) "
        ]
        guard let declaration = declarations.compactMap({ source.range(of: $0) }).first else { return nil }
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

    private func caseBody(named caseName: String, before nextCaseName: String, in source: String) -> String? {
        guard let start = source.range(of: "case \(caseName):") else { return nil }
        guard let end = source.range(of: "case \(nextCaseName):", range: start.upperBound..<source.endIndex) else {
            return nil
        }
        return String(source[start.lowerBound..<end.lowerBound])
    }

    private func compactWhitespace(_ source: String) -> String {
        source.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
