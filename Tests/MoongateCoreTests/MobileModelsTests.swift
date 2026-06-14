@testable import MoongateMobileCore
import XCTest

final class MobileModelsTests: XCTestCase {
    func testMobileTaskStateRoundTripsStableCodingValues() throws {
        let states: [MobileTaskState] = [
            .waiting,
            .analyzing,
            .ready,
            .downloading,
            .translating,
            .exporting,
            .needsForegroundToContinue,
            .completed,
            .failed,
            .cancelled,
        ]

        let data = try JSONEncoder().encode(states)
        let decoded = try JSONDecoder().decode([MobileTaskState].self, from: data)

        XCTAssertEqual(decoded, states)
    }

    func testMobileTaskErrorSeparatesUserFixableAndSystemLimitedFailures() {
        XCTAssertTrue(MobileTaskError.credentialRequired.isUserFixable)
        XCTAssertTrue(MobileTaskError.permissionDenied.isUserFixable)
        XCTAssertFalse(MobileTaskError.systemBackgroundLimit.isUserFixable)
        XCTAssertFalse(MobileTaskError.unsupportedOnMobile.isUserFixable)
        XCTAssertFalse(MobileTaskError.sourceUnavailableAfterRelaunch.isUserFixable)
    }

    func testMobileExportProfileDefaultsToSubtitleFileWhenBurnInIsNotRequired() {
        let profile = MobileExportProfile()

        XCTAssertEqual(profile.subtitleMode, .translatedSubtitleFile)
        XCTAssertEqual(profile.maxRenderHeight, 1080)
        XCTAssertFalse(profile.requiresVideoRender)
    }

    func testMobileExportProfileBurnInRequiresRender() {
        let profile = MobileExportProfile(subtitleMode: .burnedInSubtitle)

        XCTAssertTrue(profile.requiresVideoRender)
    }

    func testMobileTaskSnapshotRoundTripsStableCodableContract() throws {
        let snapshot = MobileTaskSnapshot(
            id: "task-1",
            platform: .iOS,
            state: .exporting,
            progress: MobileTaskProgress(
                phase: .exporting,
                completedUnitCount: 7,
                totalUnitCount: 10
            ),
            downloadSelection: MobileDownloadSelection(
                candidateID: "candidate-1",
                formatID: "720p",
                subtitleIDs: ["en"],
                autoSubtitleIDs: ["zh-Hans-auto"]
            ),
            exportProfile: MobileExportProfile(subtitleMode: .softSubtitle, maxRenderHeight: 720),
            capabilities: MobileProcessingCapabilities(
                platform: .iOS,
                supportedCapabilities: [.analysis, .subtitleExport, .videoRender],
                maxRenderHeight: 1080
            ),
            backgroundPolicy: MobileBackgroundPolicy(
                execution: .systemManaged,
                resumability: .resumable,
                systemTimeLimitSeconds: 30
            ),
            executionGenerationID: "moongate-generation-mobile-contract",
            result: MobileTaskResult(
                artifacts: [
                    MobileTaskArtifact(
                        id: "subtitle-1",
                        kind: .translatedSubtitleFile,
                        displayName: "translation.srt",
                        storageIdentifier: "exports/translation.srt",
                        byteCount: 512
                    )
                ],
                primaryArtifactID: "subtitle-1"
            )
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(MobileTaskSnapshot.self, from: data)

        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(decoded.downloadSelection?.formatID, "720p")
        XCTAssertEqual(decoded.downloadSelection?.subtitleIDs, ["en"])
        XCTAssertEqual(decoded.downloadSelection?.autoSubtitleIDs, ["zh-Hans-auto"])
        XCTAssertEqual(decoded.executionGenerationID, "moongate-generation-mobile-contract")
    }

    func testMobileModelsUseConservativeDefaults() {
        let progress = MobileTaskProgress()
        let capabilities = MobileProcessingCapabilities(platform: .android)
        let backgroundPolicy = MobileBackgroundPolicy()

        XCTAssertEqual(progress.phase, .waiting)
        XCTAssertEqual(progress.completedUnitCount, 0)
        XCTAssertNil(progress.totalUnitCount)
        XCTAssertNil(progress.fractionCompleted)
        XCTAssertEqual(capabilities.platform, .android)
        XCTAssertTrue(capabilities.supportedCapabilities.isEmpty)
        XCTAssertEqual(backgroundPolicy.execution, .foregroundRequired)
        XCTAssertEqual(backgroundPolicy.resumability, .resumable)
        XCTAssertTrue(backgroundPolicy.requiresForeground)
        XCTAssertFalse(backgroundPolicy.allowsUnboundedBackgroundExecution)
    }

    func testMobileBackgroundPolicyExpressesSystemLimitsAndResumeBehavior() {
        let deferred = MobileBackgroundPolicy(execution: .systemDeferred, resumability: .resumable)
        let interrupted = MobileBackgroundPolicy(execution: .systemInterrupted, resumability: .nonResumable)
        let continued = MobileBackgroundPolicy(
            execution: .continuedProcessing,
            resumability: .resumable,
            limits: [.systemTimeLimit, .userVisibleNotificationRequired]
        )

        XCTAssertTrue(deferred.isSystemLimited)
        XCTAssertFalse(deferred.requiresForeground)
        XCTAssertTrue(deferred.canResume)
        XCTAssertTrue(interrupted.isSystemLimited)
        XCTAssertFalse(interrupted.canResume)
        XCTAssertTrue(continued.isSystemLimited)
        XCTAssertTrue(continued.canResume)
        XCTAssertFalse(continued.allowsUnboundedBackgroundExecution)
        XCTAssertFalse(interrupted.allowsUnboundedBackgroundExecution)
    }

    func testPlatformProfilesKeepNativeDesignSystemsAndSharedSurfacesConservative() throws {
        let ios = MobilePlatformProfile.iOSDefault
        let android = MobilePlatformProfile.androidDefault

        XCTAssertEqual(ios.platform, .iOS)
        XCTAssertEqual(ios.designSystem, .appleHIG)
        XCTAssertEqual(android.platform, .android)
        XCTAssertEqual(android.designSystem, .material3)
        XCTAssertEqual(ios.surfaces, [.add, .queue, .library, .settings])
        XCTAssertEqual(android.surfaces, [.add, .queue, .library, .settings])
        XCTAssertTrue(ios.capabilities.supportedCapabilities.isEmpty)
        XCTAssertTrue(android.capabilities.supportedCapabilities.isEmpty)
        XCTAssertFalse(android.capabilities.supports(.appleIntelligence))
        XCTAssertFalse(android.capabilities.supports(.localTranslationModel))
        XCTAssertEqual(ios.defaultBackgroundPolicy.execution, .foregroundRequired)
        XCTAssertEqual(android.defaultBackgroundPolicy.execution, .foregroundRequired)
        XCTAssertFalse(ios.defaultBackgroundPolicy.allowsUnboundedBackgroundExecution)
        XCTAssertFalse(android.defaultBackgroundPolicy.allowsUnboundedBackgroundExecution)

        let data = try JSONEncoder().encode([ios, android])
        let decoded = try JSONDecoder().decode([MobilePlatformProfile].self, from: data)

        XCTAssertEqual(decoded, [ios, android])
    }

    func testMobileCapabilitiesValidateExportProfiles() {
        let subtitleOnly = MobileProcessingCapabilities(
            platform: .iOS,
            supportedCapabilities: [.download, .translation, .subtitleExport]
        )
        let renderCapable = MobileProcessingCapabilities(
            platform: .android,
            supportedCapabilities: [.download, .translation, .subtitleExport, .videoRender],
            maxRenderHeight: 1080
        )

        XCTAssertTrue(subtitleOnly.canSatisfy(MobileExportProfile(subtitleMode: .translatedSubtitleFile)))
        XCTAssertTrue(subtitleOnly.canSatisfy(MobileExportProfile(subtitleMode: .softSubtitle)))
        XCTAssertFalse(subtitleOnly.canSatisfy(MobileExportProfile(subtitleMode: .burnedInSubtitle)))
        XCTAssertTrue(renderCapable.canSatisfy(MobileExportProfile(subtitleMode: .burnedInSubtitle, maxRenderHeight: 720)))
        XCTAssertTrue(renderCapable.canSatisfy(MobileExportProfile(subtitleMode: .burnedInSubtitle, maxRenderHeight: 1080)))
        XCTAssertFalse(renderCapable.canSatisfy(MobileExportProfile(subtitleMode: .burnedInSubtitle, maxRenderHeight: 2160)))
    }

    func testMobileRenderRequestPlannerSkipsProfilesThatDoNotNeedVideoRender() {
        let task = completedTask(
            exportProfile: MobileExportProfile(subtitleMode: .translatedSubtitleFile),
            artifacts: [
                originalMediaArtifact(),
                translatedSubtitleArtifact()
            ]
        )

        let plan = MobileRenderRequestPlanner().plan(for: task)

        XCTAssertEqual(plan.status, .notRequired)
        XCTAssertNil(plan.request)
        XCTAssertNil(plan.blockedReason)
    }

    func testMobileRenderRequestPlannerBuildsBurnedInRequestFromMediaAndSubtitleArtifacts() throws {
        let task = completedTask(
            exportProfile: MobileExportProfile(subtitleMode: .burnedInSubtitle, maxRenderHeight: 720),
            capabilities: MobileProcessingCapabilities(
                platform: .iOS,
                supportedCapabilities: [.videoRender],
                maxRenderHeight: 1080
            ),
            artifacts: [
                originalMediaArtifact(),
                translatedSubtitleArtifact()
            ]
        )

        let plan = MobileRenderRequestPlanner().plan(for: task)
        let request = try XCTUnwrap(plan.request)

        XCTAssertEqual(plan.status, .ready)
        XCTAssertNil(plan.blockedReason)
        XCTAssertEqual(request.sourceMedia.kind, .originalMedia)
        XCTAssertEqual(request.subtitles.map(\.kind), [.translatedSubtitleFile])
        XCTAssertEqual(request.exportProfile, task.exportProfile)
    }

    func testMobileRenderRequestPlannerBlocksActiveTasksBeforeCreatingRequest() {
        let task = MobileTaskSnapshot(
            id: "task-render-active",
            platform: .iOS,
            state: .exporting,
            exportProfile: MobileExportProfile(subtitleMode: .burnedInSubtitle),
            capabilities: MobileProcessingCapabilities(platform: .iOS, supportedCapabilities: [.videoRender]),
            result: MobileTaskResult(
                artifacts: [
                    originalMediaArtifact(),
                    translatedSubtitleArtifact()
                ],
                primaryArtifactID: "original"
            )
        )

        let plan = MobileRenderRequestPlanner().plan(for: task)

        XCTAssertEqual(plan.status, .blocked)
        XCTAssertEqual(plan.blockedReason, .taskNotCompleted)
        XCTAssertNil(plan.request)
    }

    func testMobileRenderRequestPlannerRejectsSoftSubtitleArtifactForBurnIn() {
        let task = completedTask(
            exportProfile: MobileExportProfile(subtitleMode: .burnedInSubtitle),
            capabilities: MobileProcessingCapabilities(platform: .iOS, supportedCapabilities: [.videoRender]),
            artifacts: [
                originalMediaArtifact(),
                MobileTaskArtifact(
                    id: "soft-subtitle",
                    kind: .softSubtitle,
                    displayName: "video.zh.movtxt",
                    storageIdentifier: "Subtitles/video.zh.movtxt"
                )
            ]
        )

        let plan = MobileRenderRequestPlanner().plan(for: task)

        XCTAssertEqual(plan.status, .blocked)
        XCTAssertEqual(plan.blockedReason, .missingSubtitle)
        XCTAssertNil(plan.request)
    }

    func testMobileRenderRequestPlannerDoesNotUseRenderedVideoAsSourceMedia() {
        let task = completedTask(
            exportProfile: MobileExportProfile(subtitleMode: .burnedInSubtitle),
            capabilities: MobileProcessingCapabilities(platform: .iOS, supportedCapabilities: [.videoRender]),
            artifacts: [
                MobileTaskArtifact(
                    id: "rendered",
                    kind: .renderedVideo,
                    displayName: "video.rendered.mp4",
                    storageIdentifier: "Renders/video.rendered.mp4"
                ),
                translatedSubtitleArtifact()
            ]
        )

        let plan = MobileRenderRequestPlanner().plan(for: task)

        XCTAssertEqual(plan.status, .blocked)
        XCTAssertEqual(plan.blockedReason, .missingSourceMedia)
        XCTAssertNil(plan.request)
    }

    func testMobileRenderRequestPlannerPrefersOriginalMediaOverRenderedOutputs() throws {
        let task = completedTask(
            exportProfile: MobileExportProfile(subtitleMode: .burnedInSubtitle),
            capabilities: MobileProcessingCapabilities(platform: .iOS, supportedCapabilities: [.videoRender]),
            artifacts: [
                MobileTaskArtifact(
                    id: "rendered",
                    kind: .renderedVideo,
                    displayName: "video.rendered.mp4",
                    storageIdentifier: "Renders/video.rendered.mp4"
                ),
                originalMediaArtifact(),
                translatedSubtitleArtifact()
            ]
        )

        let plan = MobileRenderRequestPlanner().plan(for: task)
        let request = try XCTUnwrap(plan.request)

        XCTAssertEqual(plan.status, .ready)
        XCTAssertEqual(request.sourceMedia.id, "original")
        XCTAssertEqual(request.sourceMedia.kind, .originalMedia)
    }

    func testMobileRenderRequestPlannerReportsMissingSourceMediaWithoutFakeRequest() {
        let task = completedTask(
            exportProfile: MobileExportProfile(subtitleMode: .burnedInSubtitle),
            capabilities: MobileProcessingCapabilities(platform: .iOS, supportedCapabilities: [.videoRender]),
            artifacts: [translatedSubtitleArtifact()]
        )

        let plan = MobileRenderRequestPlanner().plan(for: task)

        XCTAssertEqual(plan.status, .blocked)
        XCTAssertEqual(plan.blockedReason, .missingSourceMedia)
        XCTAssertNil(plan.request)
    }

    func testMobileRenderRequestPlannerReportsMissingSubtitleWithoutFakeRequest() {
        let task = completedTask(
            exportProfile: MobileExportProfile(subtitleMode: .burnedInSubtitle),
            capabilities: MobileProcessingCapabilities(platform: .iOS, supportedCapabilities: [.videoRender]),
            artifacts: [originalMediaArtifact()]
        )

        let plan = MobileRenderRequestPlanner().plan(for: task)

        XCTAssertEqual(plan.status, .blocked)
        XCTAssertEqual(plan.blockedReason, .missingSubtitle)
        XCTAssertNil(plan.request)
    }

    func testMobileRenderRequestPlannerRespectsRenderCapabilitiesAndHeight() {
        let task = completedTask(
            exportProfile: MobileExportProfile(subtitleMode: .burnedInSubtitle, maxRenderHeight: 2160),
            capabilities: MobileProcessingCapabilities(
                platform: .iOS,
                supportedCapabilities: [.videoRender],
                maxRenderHeight: 1080
            ),
            artifacts: [
                originalMediaArtifact(),
                translatedSubtitleArtifact()
            ]
        )

        let plan = MobileRenderRequestPlanner().plan(for: task)

        XCTAssertEqual(plan.status, .blocked)
        XCTAssertEqual(plan.blockedReason, .unsupportedExportProfile)
        XCTAssertNil(plan.request)
    }

    func testMobileTaskResultExpressesArtifactsWithoutCredentials() throws {
        let artifact = MobileTaskArtifact(
            id: "render-1",
            kind: .renderedVideo,
            displayName: "rendered.mp4",
            storageIdentifier: "exports/rendered.mp4",
            byteCount: 1_024
        )
        let snapshot = MobileTaskSnapshot(
            id: "task-2",
            platform: .android,
            state: .completed,
            result: MobileTaskResult(artifacts: [artifact], primaryArtifactID: artifact.id)
        )

        XCTAssertEqual(snapshot.result?.primaryArtifact, artifact)
        XCTAssertEqual(snapshot.result?.artifacts.first?.kind, .renderedVideo)

        let data = try JSONEncoder().encode(snapshot)
        let encoded = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertFalse(encoded.contains("apiKey"))
        XCTAssertFalse(encoded.contains("token"))
    }

    func testMobileAddSessionExpressesUnsupportedCandidateWithoutPretendingItCanRun() throws {
        let source = MobileInputSource(kind: .pastedURL, value: "https://example.com/watch", displayName: "Example")
        let unsupported = MobileVideoCandidate(
            id: "candidate-1",
            sourceURL: "https://example.com/watch",
            kind: .webPageVideo,
            title: "Example video",
            detail: "Requires desktop extractor",
            unsupportedReason: .requiresDesktopExtractor
        )
        let session = MobileAddSessionSnapshot(
            id: "add-1",
            input: source,
            state: .unsupported,
            candidates: [unsupported],
            selectedCandidateID: unsupported.id,
            error: .unsupportedOnMobile
        )

        XCTAssertFalse(unsupported.isSupportedOnMobile)
        XCTAssertEqual(session.selectedCandidate, unsupported)

        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(MobileAddSessionSnapshot.self, from: data)

        XCTAssertEqual(decoded, session)
    }

    func testMobileTranslationConfigurationClassifiesCredentialAndRuntimeNeeds() throws {
        let api = MobileTranslationConfiguration(
            engine: .openAICompatible,
            baseURL: "https://api.openai.com",
            model: "gpt-5-mini",
            credential: SecureCredentialReference(service: "translation.openai", account: "default")
        )
        let appleOnDevice = MobileTranslationConfiguration(engine: .appleFoundationOnDevice)
        let applePCC = MobileTranslationConfiguration(engine: .appleFoundationPCC)
        let appleCloudPro = MobileTranslationConfiguration(engine: .appleFoundationCloudPro)
        let appleTranslation = MobileTranslationConfiguration(engine: .appleTranslationHighFidelity)

        XCTAssertEqual(api.credentialRequirement, .secureCredential)
        XCTAssertTrue(api.usesCloudService)
        XCTAssertFalse(api.isRunnableWithoutUserCredential)
        XCTAssertEqual(appleOnDevice.credentialRequirement, .localModel)
        XCTAssertFalse(appleOnDevice.usesCloudService)
        XCTAssertTrue(appleOnDevice.isRunnableWithoutUserCredential)
        XCTAssertEqual(applePCC.credentialRequirement, .runtimeEntitlement)
        XCTAssertTrue(applePCC.usesCloudService)
        XCTAssertEqual(appleCloudPro.credentialRequirement, .runtimeEntitlement)
        XCTAssertTrue(appleCloudPro.usesCloudService)
        XCTAssertEqual(appleTranslation.credentialRequirement, .runtimeEntitlement)
        XCTAssertFalse(appleTranslation.usesCloudService)
        XCTAssertEqual(api.readiness.issues.map(\.kind), [.needsConfiguration])
        XCTAssertEqual(appleOnDevice.readiness.issues.map(\.kind), [.appleIntelligenceUnavailable, .modelUnavailable])
        XCTAssertEqual(applePCC.readiness.issues.map(\.kind), [.pccUnavailable])
        XCTAssertEqual(appleCloudPro.readiness.issues.map(\.kind), [.pccUnavailable])
        XCTAssertTrue(appleCloudPro.readiness.issues[0].message.contains("Cloud Pro")
            || appleCloudPro.readiness.issues[0].message.contains("云端 Pro"))
        XCTAssertFalse(appleCloudPro.readiness.issues[0].message.contains("Private Cloud Compute"))
        XCTAssertEqual(appleTranslation.readiness.issues.map(\.kind), [.needsRuntimeVerification, .needsLanguageDownload])

        let data = try JSONEncoder().encode([api, appleOnDevice, applePCC, appleCloudPro, appleTranslation])
        let encoded = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertFalse(encoded.contains("secret"))
        XCTAssertFalse(encoded.contains("sk-"))
    }

    func testMobileVideoInfoDownloadRequestAndSubtitleChoicesArePortable() throws {
        let candidate = MobileVideoCandidate(
            id: "candidate-2",
            sourceURL: "https://cdn.example.com/video.m3u8",
            kind: .hlsStream,
            title: "Launch trailer"
        )
        let info = MobileVideoInfo(
            candidate: candidate,
            videoID: "video-1",
            title: "Launch trailer",
            durationSeconds: 75,
            thumbnailURL: "https://cdn.example.com/thumb.jpg",
            formats: [
                MobileFormatChoice(id: "720p", label: "720p", detail: "HLS", height: 720, isAudioOnly: false),
                MobileFormatChoice(id: "audio", label: "Audio", detail: "m4a", height: nil, isAudioOnly: true)
            ],
            subtitles: [
                MobileSubtitleChoice(id: "en", languageCode: "en", label: "English", isAutoGenerated: false),
                MobileSubtitleChoice(id: "ja-auto", languageCode: "ja", label: "Japanese auto", isAutoGenerated: true)
            ]
        )
        let request = MobileDownloadRequest(
            id: "download-1",
            sourceURL: candidate.sourceURL,
            candidateID: candidate.id,
            videoID: info.videoID,
            formatID: "720p",
            subtitleIDs: ["en"],
            autoSubtitleIDs: ["ja-auto"],
            exportProfile: MobileExportProfile(subtitleMode: .burnedInSubtitle, maxRenderHeight: 720),
            preferredTitle: info.title
        )

        XCTAssertEqual(info.recommendedFormat?.id, "720p")
        XCTAssertTrue(info.hasSubtitleOptions)
        XCTAssertTrue(request.exportProfile.requiresVideoRender)

        let data = try JSONEncoder().encode([request])
        let decoded = try JSONDecoder().decode([MobileDownloadRequest].self, from: data)

        XCTAssertEqual(decoded, [request])
    }

    func testMobileTaskSnapshotDerivesSafeUserActionsFromState() {
        let active = MobileTaskSnapshot(id: "task-active", platform: .iOS, state: .downloading)
        let activeNonResumable = MobileTaskSnapshot(
            id: "task-active-non-resumable",
            platform: .iOS,
            state: .exporting,
            backgroundPolicy: MobileBackgroundPolicy(resumability: .nonResumable)
        )
        let backgroundLimited = MobileTaskSnapshot(
            id: "task-bg",
            platform: .iOS,
            state: .needsForegroundToContinue,
            backgroundPolicy: MobileBackgroundPolicy(execution: .foregroundRequired)
        )
        let completed = MobileTaskSnapshot(
            id: "task-done",
            platform: .android,
            state: .completed,
            result: MobileTaskResult(artifacts: [
                MobileTaskArtifact(
                    id: "video",
                    kind: .renderedVideo,
                    displayName: "video.mp4",
                    storageIdentifier: "library/video.mp4"
                )
            ], primaryArtifactID: "video")
        )

        XCTAssertEqual(active.availableActions, [.pause, .cancel])
        XCTAssertEqual(activeNonResumable.availableActions, [.cancel])
        XCTAssertEqual(backgroundLimited.availableActions, [.openAppToContinue, .cancel])
        XCTAssertEqual(completed.availableActions, [.openResult, .shareResult, .remove])
    }

    func testDownloadReadyTasksExposeStartDownloadAction() {
        let waiting = MobileTaskSnapshot(id: "task-waiting", platform: .iOS, state: .waiting)
        let ready = MobileTaskSnapshot(id: "task-ready", platform: .iOS, state: .ready)
        let analyzing = MobileTaskSnapshot(id: "task-analyzing", platform: .iOS, state: .analyzing)

        XCTAssertEqual(waiting.availableActions, [.startDownload, .cancel])
        XCTAssertEqual(ready.availableActions, [.startDownload, .cancel])
        XCTAssertEqual(analyzing.availableActions, [.cancel])
    }

    func testCompletedTasksWithTranscriptExposeSubtitleExportAction() {
        let task = MobileTaskSnapshot(
            id: "task-subtitle",
            platform: .iOS,
            state: .completed,
            exportProfile: MobileExportProfile(subtitleMode: .translatedSubtitleFile),
            result: MobileTaskResult(artifacts: [
                MobileTaskArtifact(
                    id: "original",
                    kind: .originalMedia,
                    displayName: "Launch Clip.mp4",
                    storageIdentifier: "Downloads/launch.mp4"
                ),
                MobileTaskArtifact(
                    id: "transcript",
                    kind: .transcript,
                    displayName: "Launch Clip.en.srt",
                    storageIdentifier: "Subtitles/launch.en.srt"
                )
            ], primaryArtifactID: "original")
        )

        XCTAssertEqual(task.availableActions, [.exportTranslatedSubtitle, .openResult, .shareResult, .remove])
    }

    func testCompletedTasksWithTranscriptExposeSoftSubtitleExportActionUntilPackageExists() {
        let pendingSoftSubtitleTask = MobileTaskSnapshot(
            id: "task-soft-subtitle",
            platform: .iOS,
            state: .completed,
            exportProfile: MobileExportProfile(subtitleMode: .softSubtitle),
            capabilities: MobileProcessingCapabilities(
                platform: .iOS,
                supportedCapabilities: [.translation, .subtitleExport]
            ),
            result: MobileTaskResult(artifacts: [
                MobileTaskArtifact(
                    id: "original",
                    kind: .originalMedia,
                    displayName: "Launch Clip.mp4",
                    storageIdentifier: "Downloads/launch.mp4"
                ),
                MobileTaskArtifact(
                    id: "transcript",
                    kind: .transcript,
                    displayName: "Launch Clip.en.srt",
                    storageIdentifier: "Subtitles/launch.en.srt"
                )
            ], primaryArtifactID: "original")
        )
        let completedSoftSubtitleTask = MobileTaskSnapshot(
            id: "task-soft-subtitle",
            platform: .iOS,
            state: .completed,
            exportProfile: MobileExportProfile(subtitleMode: .softSubtitle),
            capabilities: MobileProcessingCapabilities(
                platform: .iOS,
                supportedCapabilities: [.translation, .subtitleExport]
            ),
            result: MobileTaskResult(artifacts: [
                MobileTaskArtifact(
                    id: "original",
                    kind: .originalMedia,
                    displayName: "Launch Clip.mp4",
                    storageIdentifier: "Downloads/launch.mp4"
                ),
                MobileTaskArtifact(
                    id: "transcript",
                    kind: .transcript,
                    displayName: "Launch Clip.en.srt",
                    storageIdentifier: "Subtitles/launch.en.srt"
                ),
                MobileTaskArtifact(
                    id: "soft-subtitle",
                    kind: .softSubtitle,
                    displayName: "Launch Clip.soft-subtitles",
                    storageIdentifier: "SoftSubtitles/launch.soft-subtitles"
                )
            ], primaryArtifactID: "original")
        )

        XCTAssertEqual(pendingSoftSubtitleTask.availableActions, [.exportTranslatedSubtitle, .openResult, .shareResult, .remove])
        XCTAssertEqual(completedSoftSubtitleTask.availableActions, [.openResult, .shareResult, .remove])
    }

    func testCompletedBurnedInTasksExposeRenderActionOnlyWithTranslatedSubtitleArtifact() {
        let translatedSubtitleTask = completedTask(
            exportProfile: MobileExportProfile(subtitleMode: .burnedInSubtitle),
            capabilities: MobileProcessingCapabilities(platform: .iOS, supportedCapabilities: [.videoRender]),
            artifacts: [
                originalMediaArtifact(),
                translatedSubtitleArtifact()
            ]
        )
        let softSubtitleTask = completedTask(
            exportProfile: MobileExportProfile(subtitleMode: .burnedInSubtitle),
            capabilities: MobileProcessingCapabilities(platform: .iOS, supportedCapabilities: [.videoRender]),
            artifacts: [
                originalMediaArtifact(),
                MobileTaskArtifact(
                    id: "soft-subtitle",
                    kind: .softSubtitle,
                    displayName: "video.zh.movtxt",
                    storageIdentifier: "Subtitles/video.zh.movtxt"
                )
            ]
        )

        XCTAssertEqual(translatedSubtitleTask.availableActions, [.exportRenderedVideo, .openResult, .shareResult, .remove])
        XCTAssertEqual(softSubtitleTask.availableActions, [.openResult, .shareResult, .remove])
    }

    func testMobileLibraryItemKeepsCompletedOutputsSeparateFromQueueWork() throws {
        let artifact = MobileTaskArtifact(
            id: "subtitle",
            kind: .translatedSubtitleFile,
            displayName: "Launch trailer.zh.srt",
            storageIdentifier: "library/Launch trailer.zh.srt"
        )
        let item = MobileLibraryItem(
            id: "library-1",
            title: "Launch trailer",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            artifacts: [artifact],
            state: .available,
            sourceTaskID: "task-1"
        )

        XCTAssertEqual(item.availableActions, [.open, .share, .saveToFiles, .deleteRecord])

        let data = try JSONEncoder().encode(item)
        let encoded = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertFalse(encoded.contains("secret"))
        XCTAssertFalse(encoded.contains("apiKey"))
        XCTAssertEqual(try JSONDecoder().decode(MobileLibraryItem.self, from: data), item)
    }

    func testMobileLibraryActionOutcomeCarriesSystemPresentationWithoutSecrets() throws {
        let artifact = MobileTaskArtifact(
            id: "video",
            kind: .originalMedia,
            displayName: "Launch trailer.mp4",
            storageIdentifier: "library/Launch trailer.mp4"
        )
        let outcome = MobileLibraryActionOutcome(
            action: .share,
            itemID: "library-1",
            itemTitle: "Launch trailer",
            artifacts: [artifact],
            presentation: .shareSheet,
            status: .requiresSystemPresentation,
            statusMessage: "准备分享 Launch trailer.mp4",
            requiresSystemUI: true
        )

        XCTAssertEqual(outcome.presentation, .shareSheet)
        XCTAssertEqual(outcome.status, .requiresSystemPresentation)
        XCTAssertTrue(outcome.requiresSystemUI)
        XCTAssertFalse(outcome.completedRecordMutation)

        let data = try JSONEncoder().encode(outcome)
        let encoded = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertFalse(encoded.contains("secret"))
        XCTAssertFalse(encoded.contains("apiKey"))
        XCTAssertEqual(try JSONDecoder().decode(MobileLibraryActionOutcome.self, from: data), outcome)
    }

    func testSecureCredentialReferenceStoresOnlyMetadata() throws {
        let reference = SecureCredentialReference(
            service: "translation.openai",
            account: "default",
            displayName: "OpenAI-compatible"
        )

        let data = try JSONEncoder().encode(reference)
        let encoded = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(encoded.contains("OpenAI-compatible"))
        XCTAssertFalse(encoded.contains("sk-"))
        XCTAssertFalse(encoded.contains("token"))
    }

    func testMobilePublicProtocolsCanBeMockedWithoutPlatformFrameworks() async throws {
        let parser = MockMobileParser()
        let downloader = MockMobileDownloadEngine()
        let translator = MockMobileTranslationProvider()
        let processor = MockSubtitleProcessor()
        let renderer = MockRenderExporter()
        let credentials = MockSecureCredentialStore()
        let repository = MockTaskRepository()

        let input = MobileInputSource(kind: .clipboardURL, value: "https://cdn.example.com/video.mp4")
        let candidates = try await parser.resolveCandidates(for: input)
        let info = try await parser.analyze(candidate: try XCTUnwrap(candidates.first))
        let result = try await downloader.download(
            MobileDownloadRequest(
                id: "download",
                sourceURL: input.value,
                candidateID: candidates[0].id,
                videoID: info.videoID,
                formatID: try XCTUnwrap(info.recommendedFormat?.id),
                subtitleIDs: [],
                autoSubtitleIDs: [],
                exportProfile: MobileExportProfile()
            ),
            progress: { _ in }
        )
        let translation = try await translator.translate(
            MobileTranslationRequest(
                segments: [MobileTranslationSegment(id: "1", startTime: "00:00:01,000", endTime: "00:00:02,000", text: "Hello")],
                context: TranslationContext(targetLanguage: "zh-Hans")
            )
        )
        let subtitleArtifact = try await processor.process(
            MobileSubtitleProcessingRequest(
                sourceSubtitle: MobileTaskArtifact(id: "srt", kind: .transcript, displayName: "source.srt", storageIdentifier: "source.srt"),
                translation: translation,
                exportProfile: MobileExportProfile()
            ),
            progress: { _ in }
        )
        let rendered = try await renderer.export(
            MobileRenderRequest(
                sourceMedia: result.artifacts[0],
                subtitles: [subtitleArtifact],
                exportProfile: MobileExportProfile(subtitleMode: .softSubtitle)
            ),
            progress: { _ in }
        )
        let credential = try await credentials.saveCredential(
            "TEST_CREDENTIAL_VALUE_DO_NOT_STORE",
            for: SecureCredentialReference(service: "translation", account: "default")
        )
        try await repository.saveTask(MobileTaskSnapshot(id: "task", platform: .iOS, state: .completed, result: rendered))

        let hasCredential = try await credentials.hasCredential(credential)
        let savedTasks = try await repository.loadTasks()

        XCTAssertTrue(hasCredential)
        XCTAssertEqual(savedTasks.first?.state, .completed)
    }

    private func completedTask(
        exportProfile: MobileExportProfile,
        capabilities: MobileProcessingCapabilities = MobileProcessingCapabilities(
            platform: .iOS,
            supportedCapabilities: [.videoRender],
            maxRenderHeight: 1080
        ),
        artifacts: [MobileTaskArtifact]
    ) -> MobileTaskSnapshot {
        MobileTaskSnapshot(
            id: "task-render",
            platform: capabilities.platform,
            state: .completed,
            exportProfile: exportProfile,
            capabilities: capabilities,
            result: MobileTaskResult(artifacts: artifacts, primaryArtifactID: artifacts.first?.id)
        )
    }

    private func originalMediaArtifact() -> MobileTaskArtifact {
        MobileTaskArtifact(
            id: "original",
            kind: .originalMedia,
            displayName: "video.mp4",
            storageIdentifier: "Downloads/video.mp4"
        )
    }

    private func translatedSubtitleArtifact() -> MobileTaskArtifact {
        MobileTaskArtifact(
            id: "subtitle",
            kind: .translatedSubtitleFile,
            displayName: "video.zh.srt",
            storageIdentifier: "Subtitles/video.zh.srt"
        )
    }
}

private struct MockMobileParser: MobileParser {
    func resolveCandidates(for input: MobileInputSource) async throws -> [MobileVideoCandidate] {
        [
            MobileVideoCandidate(
                id: "candidate",
                sourceURL: input.value,
                kind: .directFile,
                title: "Mock video"
            )
        ]
    }

    func analyze(candidate: MobileVideoCandidate) async throws -> MobileVideoInfo {
        MobileVideoInfo(
            candidate: candidate,
            videoID: "mock-video",
            title: candidate.title,
            durationSeconds: 12,
            thumbnailURL: nil,
            formats: [MobileFormatChoice(id: "best", label: "Best", detail: nil, height: 720, isAudioOnly: false)],
            subtitles: []
        )
    }
}

private struct MockMobileDownloadEngine: MobileDownloadEngine {
    func download(
        _ request: MobileDownloadRequest,
        progress: @escaping @Sendable (MobileTaskProgress) -> Void
    ) async throws -> MobileTaskResult {
        progress(MobileTaskProgress(phase: .downloading, completedUnitCount: 1, totalUnitCount: 1))
        return MobileTaskResult(artifacts: [
            MobileTaskArtifact(id: "media", kind: .originalMedia, displayName: "video.mp4", storageIdentifier: request.videoID)
        ], primaryArtifactID: "media")
    }
}

private struct MockMobileTranslationProvider: MobileTranslationProvider {
    func readiness(for context: TranslationContext) async -> TranslationReadiness {
        .ready
    }

    func translate(_ request: MobileTranslationRequest) async throws -> MobileTranslationResult {
        MobileTranslationResult(
            segments: request.segments.map {
                MobileTranslationSegment(
                    id: $0.id,
                    startTime: $0.startTime,
                    endTime: $0.endTime,
                    text: "你好"
                )
            }
        )
    }
}

private struct MockSubtitleProcessor: SubtitleProcessor {
    func process(
        _ request: MobileSubtitleProcessingRequest,
        progress: @escaping @Sendable (MobileTaskProgress) -> Void
    ) async throws -> MobileTaskArtifact {
        progress(MobileTaskProgress(phase: .translating, completedUnitCount: 1, totalUnitCount: 1))
        return MobileTaskArtifact(id: "subtitle", kind: .translatedSubtitleFile, displayName: "video.zh.srt", storageIdentifier: "video.zh.srt")
    }
}

private struct MockRenderExporter: RenderExporter {
    func export(
        _ request: MobileRenderRequest,
        progress: @escaping @Sendable (MobileTaskProgress) -> Void
    ) async throws -> MobileTaskResult {
        progress(MobileTaskProgress(phase: .exporting, completedUnitCount: 1, totalUnitCount: 1))
        return MobileTaskResult(artifacts: [
            MobileTaskArtifact(id: "render", kind: .renderedVideo, displayName: "video.mp4", storageIdentifier: "video.mp4")
        ], primaryArtifactID: "render")
    }
}

private actor MockSecureCredentialStore: SecureCredentialStore {
    private var stored: [SecureCredentialReference: String] = [:]

    func saveCredential(_ secret: String, for reference: SecureCredentialReference) async throws -> SecureCredentialReference {
        stored[reference] = secret
        return reference
    }

    func deleteCredential(_ reference: SecureCredentialReference) async throws {
        stored.removeValue(forKey: reference)
    }

    func hasCredential(_ reference: SecureCredentialReference) async throws -> Bool {
        stored[reference] != nil
    }

    func credential(for reference: SecureCredentialReference) async throws -> String? {
        stored[reference]
    }
}

private actor MockTaskRepository: TaskRepository {
    private var tasks: [MobileTaskSnapshot] = []

    func loadTasks() async throws -> [MobileTaskSnapshot] {
        tasks
    }

    func saveTask(_ snapshot: MobileTaskSnapshot) async throws {
        tasks.removeAll { $0.id == snapshot.id }
        tasks.append(snapshot)
    }

    func removeTask(id: String) async throws {
        tasks.removeAll { $0.id == id }
    }
}
