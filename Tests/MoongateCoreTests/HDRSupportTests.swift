import XCTest
@testable import MoongateCore

final class HDRSupportTests: XCTestCase {

    // MARK: DynamicRange 解析

    func testDynamicRangeParsing() {
        XCTAssertEqual(DynamicRange(ytDlpValue: "SDR"), .sdr)
        XCTAssertEqual(DynamicRange(ytDlpValue: "HDR10"), .hdr10)
        XCTAssertEqual(DynamicRange(ytDlpValue: "HDR10+"), .hdr10)
        XCTAssertEqual(DynamicRange(ytDlpValue: "DV"), .dolbyVision)
        XCTAssertEqual(DynamicRange(ytDlpValue: "Dolby Vision"), .dolbyVision)
        XCTAssertEqual(DynamicRange(ytDlpValue: nil), .sdr)
        XCTAssertTrue(DynamicRange.hdr10.isHDR)
        XCTAssertFalse(DynamicRange.sdr.isHDR)
    }

    // MARK: -f 选择器 HDR 偏好

    func testHDRPreferenceInjectsDynamicRangeConstraintWithFallback() {
        let base = "bv*[height<=2160]+ba/b[height<=2160]"
        let hdr = YtDlpEngine.applyHDRPreference(to: base, preferHDR: true)
        // HDR 版加约束，且以 "/" 回退到原始串。
        XCTAssertTrue(hdr.contains("bv*[dynamic_range!=SDR]"))
        XCTAssertTrue(hdr.hasSuffix(base))
        XCTAssertTrue(hdr.contains("/"))
    }

    func testHDRPreferenceOffReturnsSelectorUnchanged() {
        let base = "bv*+ba/b"
        XCTAssertEqual(YtDlpEngine.applyHDRPreference(to: base, preferHDR: false), base)
    }

    // MARK: vcodec 简称

    func testShortVCodec() {
        XCTAssertEqual(YtDlpEngine.shortVCodec("vp9.2"), "vp9")
        XCTAssertEqual(YtDlpEngine.shortVCodec("av01.0.09M.10.0.110.09"), "av1")
        XCTAssertEqual(YtDlpEngine.shortVCodec("avc1.64002A"), "h264")
        XCTAssertEqual(YtDlpEngine.shortVCodec("hev1.2.4"), "h265")
    }

    // MARK: HDR 烧录编码参数

    func testHDRBurnVideoArgsCarryHDR10Metadata() {
        let args = FFmpegBurner.hdrVideoArgs(
            colorPrimaries: "bt2020",
            colorTransfer: "smpte2084",
            colorSpace: "bt2020nc",
            maxrateK: 12000
        )
        let joined = args.joined(separator: " ")
        XCTAssertTrue(joined.contains("libx265"))
        XCTAssertTrue(joined.contains("yuv420p10le"))
        XCTAssertTrue(joined.contains("colorprim=bt2020"))
        XCTAssertTrue(joined.contains("transfer=smpte2084"))
        XCTAssertTrue(joined.contains("colormatrix=bt2020nc"))
        XCTAssertTrue(joined.contains("hdr-opt=1"))
        XCTAssertTrue(args.contains("12000k"))
    }

    func testHDRBurnVideoArgsFallBackToBT2020WhenColorMissing() {
        let args = FFmpegBurner.hdrVideoArgs(
            colorPrimaries: nil, colorTransfer: nil, colorSpace: nil, maxrateK: 8000
        )
        let joined = args.joined(separator: " ")
        XCTAssertTrue(joined.contains("colorprim=bt2020"))
        XCTAssertTrue(joined.contains("transfer=smpte2084"))
    }

    // MARK: 转码计划

    func testRemuxSameCodecToMkvUsesCopyAndKeepsHDR() {
        let plan = Transcoder.plan(
            format: .mkv, inputPath: "in.webm", outputPath: "out.mkv",
            sourceVCodec: "vp9", sourceIsHDR: true, x265Available: true
        )
        XCTAssertTrue(plan.isRemux)
        XCTAssertFalse(plan.dropsHDR)
        XCTAssertTrue(plan.ffmpegArgs.contains("copy"))
        XCTAssertEqual(plan.outputExtension, "mkv")
    }

    func testTranscodeToH264FromHDRTonemapsAndDropsHDR() {
        let plan = Transcoder.plan(
            format: .mp4H264, inputPath: "in.webm", outputPath: "out.mp4",
            sourceVCodec: "vp9", sourceIsHDR: true, x265Available: true
        )
        XCTAssertFalse(plan.isRemux)
        XCTAssertTrue(plan.dropsHDR)
        let joined = plan.ffmpegArgs.joined(separator: " ")
        XCTAssertTrue(joined.contains("libx264"))
        XCTAssertTrue(joined.contains("tonemap"))
    }

    func testTranscodeToH265FromHDRKeepsHDRWhenX265Available() {
        let plan = Transcoder.plan(
            format: .mp4H265, inputPath: "in.webm", outputPath: "out.mp4",
            sourceVCodec: "vp9", sourceIsHDR: true, x265Available: true
        )
        XCTAssertFalse(plan.dropsHDR)
        let joined = plan.ffmpegArgs.joined(separator: " ")
        XCTAssertTrue(joined.contains("libx265"))
        XCTAssertTrue(joined.contains("yuv420p10le"))
        XCTAssertTrue(joined.contains("transfer=smpte2084"))
    }

    func testTranscodeToH265FromHDRDropsHDRWhenX265Unavailable() {
        let plan = Transcoder.plan(
            format: .mp4H265, inputPath: "in.webm", outputPath: "out.mp4",
            sourceVCodec: "vp9", sourceIsHDR: true, x265Available: false
        )
        XCTAssertTrue(plan.dropsHDR)
        // x265 不可用回退时，HDR 源必须 tonemap 降级成 SDR，否则画面发灰/偏色。
        let joined = plan.ffmpegArgs.joined(separator: " ")
        XCTAssertTrue(joined.contains("tonemap"))
        XCTAssertFalse(joined.contains("yuv420p10le"))
    }

    func testRemuxAlreadyH264ToMp4IsCopy() {
        let plan = Transcoder.plan(
            format: .mp4H264, inputPath: "in.mp4", outputPath: "out.mp4",
            sourceVCodec: "h264", sourceIsHDR: false, x265Available: true
        )
        XCTAssertTrue(plan.isRemux)
        XCTAssertTrue(plan.ffmpegArgs.contains("copy"))
    }

    func testOriginalFormatNeedsNoProcessing() {
        XCTAssertFalse(Transcoder.needsProcessing(.original))
        XCTAssertTrue(Transcoder.needsProcessing(.mp4H265))
    }
}
