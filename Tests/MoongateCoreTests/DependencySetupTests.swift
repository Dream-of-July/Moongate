@testable import MoongateCore
import XCTest

final class DependencySetupTests: XCTestCase {
    func testFfmpegDependencyUsesFullBuildForSubtitleBurning() {
        let components = DependencySetup.components(
            ytDlpInstalled: true,
            subtitleRendererFfmpegInstalled: false,
            jsRuntimeInstalled: true,
            localWhisperInstalled: false
        )

        let ffmpeg = components.first { $0.id == "ffmpeg" }
        XCTAssertEqual(ffmpeg?.formula, "ffmpeg-full")
        XCTAssertEqual(ffmpeg?.isInstalled, false)
        XCTAssertEqual(ffmpeg?.isRequired, true)
    }

    func testNeedsSetupFollowsSharedMissingRequiredComponentList() {
        let ready = DependencySetup.components(
            ytDlpInstalled: true,
            subtitleRendererFfmpegInstalled: true,
            jsRuntimeInstalled: true,
            localWhisperInstalled: false
        )
        let missingDeno = DependencySetup.components(
            ytDlpInstalled: true,
            subtitleRendererFfmpegInstalled: true,
            jsRuntimeInstalled: false,
            localWhisperInstalled: false
        )

        XCTAssertFalse(DependencySetup.needsSetup(ready))
        XCTAssertTrue(DependencySetup.needsSetup(missingDeno))
        XCTAssertEqual(DependencySetup.missingRequired(from: missingDeno).map(\.id), ["deno"])
        XCTAssertEqual(DependencySetup.missingOptional(from: missingDeno).map(\.id), ["whisper-cli"])
    }

    func testLocalWhisperDependencyIsOptionalAndUsesWhisperCppFormula() {
        let components = DependencySetup.components(
            ytDlpInstalled: true,
            subtitleRendererFfmpegInstalled: true,
            jsRuntimeInstalled: true,
            localWhisperInstalled: false
        )

        let whisper = components.first { $0.id == "whisper-cli" }
        XCTAssertEqual(whisper?.formula, "whisper-cpp")
        XCTAssertEqual(whisper?.isInstalled, false)
        XCTAssertEqual(whisper?.isRequired, false)
        XCTAssertFalse(DependencySetup.needsSetup(components))
        XCTAssertEqual(DependencySetup.missingOptional(from: components).map(\.id), ["whisper-cli"])
    }

    func testBurnerSkipsFfmpegWithoutSubtitleRenderer() {
        let chosen = FFmpegBurner.locateSubtitleRendererFFmpeg(
            candidates: ["/opt/homebrew/bin/ffmpeg", "/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg"],
            environment: [:],
            fileIsExecutable: { _ in true },
            supportsSubtitleRendering: { path in path.contains("ffmpeg-full") }
        )

        XCTAssertEqual(chosen, "/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg")
    }
}
