@testable import MoongateCore
import XCTest

final class CoreRuntimeLocalizationTests: XCTestCase {
    override func tearDown() {
        CoreL10n.setLanguage(.zhHans)
        super.tearDown()
    }

    func testCoreErrorDescriptionsUseRuntimeLanguage() {
        CoreL10n.setLanguage(.en)
        XCTAssertEqual(
            MoongateError.binaryNotFound("yt-dlp").errorDescription,
            "Cannot find yt-dlp. Confirm it was installed with Homebrew (brew install yt-dlp)."
        )

        CoreL10n.setLanguage(.zhHant)
        XCTAssertEqual(MoongateError.cancelled.errorDescription, "已取消")
        XCTAssertTrue(
            MoongateError.loginRequired("youtube.com").errorDescription?.contains("前往登入") == true
        )
    }

    func testCoreReadinessMessagesUseRuntimeLanguage() {
        CoreL10n.setLanguage(.en)
        let cloudPro = AppSettings(aiEngine: .appleFoundationCloudPro)
            .translationReadiness()
        XCTAssertEqual(
            cloudPro.issues.first?.message,
            "Apple Intelligence Cloud Pro is not available yet."
        )

        CoreL10n.setLanguage(.zhHant)
        let appleTranslation = AppSettings(aiEngine: .appleTranslationLowLatency)
            .translationReadiness(context: TranslationContext(sourceLanguage: nil, targetLanguage: "zh-Hant"))
        XCTAssertTrue(
            appleTranslation.issues.map(\.message).contains("需要先下載對應語言。")
        )
    }

    func testAppleTranslationExecutorErrorsUseRuntimeLanguage() async throws {
        CoreL10n.setLanguage(.zhHant)
        let executor = DefaultAppleTranslationExecutor()
        let request = AppleTranslationBatchRequest(
            engine: .appleTranslationLowLatency,
            context: TranslationContext(sourceLanguage: nil, targetLanguage: "zh-Hant"),
            segments: [AppleTranslationSegment(number: 1, text: "Hello.")]
        )

        do {
            _ = try await executor.translate(request)
            XCTFail("Expected missing source language to fail before runtime execution.")
        } catch MoongateError.translateFailed(let message) {
            XCTAssertEqual(
                message,
                "Apple Translation 需要明確來源語言。請先選擇或推斷來源字幕語言後重試。"
            )
        }
    }

    func testHardwareAccelerationNoticeUsesRuntimeLanguage() {
        CoreL10n.setLanguage(.en)
        XCTAssertEqual(
            PipelineAccelerationReport.compatibilityModeNotice,
            "Compatibility mode is in use, so processing may take longer than estimated."
        )

        CoreL10n.setLanguage(.zhHant)
        XCTAssertEqual(
            PipelineAccelerationReport.compatibilityModeNotice,
            "遇到相容性問題，實際耗時可能比預估更久。"
        )
    }
}
