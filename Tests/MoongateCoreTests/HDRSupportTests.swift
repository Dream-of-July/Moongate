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
    }

    func testTranscodeExecutionGuardsH265WhenNoEncoderIsAvailable() throws {
        let source = try String(contentsOf: packageRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("MoongateCore")
            .appendingPathComponent("Transcoder.swift"))

        XCTAssertTrue(source.contains("format == .mp4H265"))
        XCTAssertTrue(source.contains("!hevcVT"))
        XCTAssertTrue(source.contains("!x265"))
        XCTAssertTrue(source.contains("缺少 HEVC 编码器"))
    }

    func testTranscodeExecutionProbesActualHDRBeforePlanning() throws {
        let source = try String(contentsOf: packageRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("MoongateCore")
            .appendingPathComponent("Transcoder.swift"))

        XCTAssertTrue(source.contains("probeVideoHDRStatus(file: inputFile) ?? sourceIsHDR"))
        let probeRange = try XCTUnwrap(source.range(of: "probeVideoHDRStatus(file: inputFile) ?? sourceIsHDR"))
        let planRange = try XCTUnwrap(source.range(of: "let probePlan = Self.plan("))
        XCTAssertLessThan(probeRange.lowerBound, planRange.lowerBound)

        let queue = try String(contentsOf: packageRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("Moongate")
            .appendingPathComponent("QueueManager.swift"))
        XCTAssertTrue(queue.contains("requestedHDRFallback = current.request.preferHDR"))
        XCTAssertFalse(queue.contains("sourceIsHDR: current.request.preferHDR"))
    }

    func testTranscodeAndBurnClearActivePIDWithDefer() throws {
        let transcoder = try String(contentsOf: packageRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("MoongateCore")
            .appendingPathComponent("Transcoder.swift"))
        XCTAssertTrue(transcoder.contains("defer { control?.setActivePID(0) }"))

        let burner = try String(contentsOf: packageRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("MoongateCore")
            .appendingPathComponent("Burner.swift"))
        XCTAssertTrue(burner.contains("defer { control?.setActivePID(0) }"))
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

    // MARK: - 编码器选择矩阵（硬件 / 软件 × 源编码 × HDR × 强制H264）

    private func select(
        backend: EncodeBackend,
        alwaysH264: Bool = false,
        sourceIsHEVC: Bool = false,
        isHDR: Bool = false,
        x265: Bool = true,
        hevcVT: Bool = true,
        h264VT: Bool = true
    ) -> FFmpegBurner.VideoEncoderSelection {
        FFmpegBurner.selectVideoEncoder(
            backend: backend, alwaysH264: alwaysH264, sourceIsHEVC: sourceIsHEVC, isHDR: isHDR,
            colorPrimaries: nil, colorTransfer: nil, colorSpace: nil, maxrateK: 6000,
            x265Available: x265, hevcVTAvailable: hevcVT, h264VTAvailable: h264VT
        )
    }

    func testAutoSDRHEVCSourceUsesHardwareHEVC() {
        let s = select(backend: .auto, sourceIsHEVC: true)
        XCTAssertTrue(s.encoderArgs.contains("hevc_videotoolbox"))
        XCTAssertTrue(s.encoderArgs.contains("hvc1"))
        XCTAssertFalse(s.encoderArgs.contains("libx265"))
    }

    func testSoftwareSDRHEVCSourceUsesLibx265() {
        let s = select(backend: .software, sourceIsHEVC: true)
        XCTAssertTrue(s.encoderArgs.contains("libx265"))
        XCTAssertFalse(s.encoderArgs.contains("hevc_videotoolbox"))
    }

    func testAutoSDRNonHEVCUsesHardwareH264() {
        let s = select(backend: .auto, sourceIsHEVC: false)
        XCTAssertTrue(s.encoderArgs.contains("h264_videotoolbox"))
    }

    func testAlwaysH264ForcesH264EvenForHEVCSource() {
        let hw = select(backend: .auto, alwaysH264: true, sourceIsHEVC: true)
        XCTAssertTrue(hw.encoderArgs.contains("h264_videotoolbox"))
        let sw = select(backend: .software, alwaysH264: true, sourceIsHEVC: true)
        XCTAssertTrue(sw.encoderArgs.contains("libx264"))
    }

    func testHDRAutoUsesHardwareMain10WithColorMetadata() {
        let s = select(backend: .auto, isHDR: true)
        XCTAssertTrue(s.encoderArgs.contains("hevc_videotoolbox"))
        XCTAssertTrue(s.encoderArgs.contains("main10"))
        XCTAssertTrue(s.encoderArgs.contains("p010le"))
        // 硬件 HDR 必须显式带色彩元数据，否则输出 trc/prim 为 unknown。
        XCTAssertTrue(s.colorArgs.contains("smpte2084"))
        XCTAssertTrue(s.colorArgs.contains("bt2020"))
        XCTAssertTrue(s.filterSuffix.contains("p010le"))
    }

    func testHDRSoftwareUsesLibx265TenBit() {
        let s = select(backend: .software, isHDR: true)
        XCTAssertTrue(s.encoderArgs.contains("libx265"))
        XCTAssertTrue(s.encoderArgs.contains("yuv420p10le"))
        XCTAssertTrue(s.filterSuffix.contains("yuv420p10le"))
    }

    func testHDRPlusAlwaysH264TonemapsToSDR() {
        let s = select(backend: .auto, alwaysH264: true, isHDR: true)
        XCTAssertTrue(s.filterPrefix.contains("tonemap"))
        XCTAssertTrue(s.encoderArgs.contains("h264_videotoolbox"))
    }

    func testHardwarePreferredButUnavailableFallsBackToSoftware() {
        // 想用硬件但 VideoToolbox HEVC 不可用 → 回退 libx265。
        let s = select(backend: .auto, sourceIsHEVC: true, hevcVT: false)
        XCTAssertTrue(s.encoderArgs.contains("libx265"))
    }

    func testHDRHardwareUnavailableFallsBackToLibx265TenBit() {
        let s = select(backend: .hardware, isHDR: true, hevcVT: false)
        XCTAssertTrue(s.encoderArgs.contains("libx265"))
        XCTAssertTrue(s.encoderArgs.contains("yuv420p10le"))
    }

    // MARK: - Transcoder 硬件路径

    func testTranscodeH265HardwareUsesVideotoolbox() {
        let plan = Transcoder.plan(
            format: .mp4H265, inputPath: "in.webm", outputPath: "out.mp4",
            sourceVCodec: "vp9", sourceIsHDR: false, x265Available: true,
            backend: .auto, hevcVTAvailable: true, h264VTAvailable: true
        )
        XCTAssertTrue(plan.ffmpegArgs.contains("hevc_videotoolbox"))
        XCTAssertFalse(plan.ffmpegArgs.contains("libx265"))
    }

    func testTranscodeH265HardwareUsesVideotoolboxInputAccelerationWhenFilterless() {
        let plan = Transcoder.plan(
            format: .mp4H265, inputPath: "in.webm", outputPath: "out.mp4",
            sourceVCodec: "vp9", sourceIsHDR: false, x265Available: true,
            backend: .auto, hevcVTAvailable: true, h264VTAvailable: true
        )
        let joined = plan.ffmpegArgs.joined(separator: " ")
        XCTAssertTrue(joined.contains("-hwaccel videotoolbox"))
        XCTAssertEqual(plan.accelerationReport.family, .videoToolbox)
        XCTAssertTrue(plan.accelerationReport.usesHardwareDecode)
        XCTAssertTrue(plan.accelerationReport.usesHardwareEncode)
        XCTAssertNil(plan.accelerationReport.compatibilityNotice)
    }

    func testTranscodeHDRToH264KeepsCpuTonemapFilterOnCompatibleInputPath() {
        let plan = Transcoder.plan(
            format: .mp4H264, inputPath: "in.webm", outputPath: "out.mp4",
            sourceVCodec: "vp9", sourceIsHDR: true, x265Available: true,
            backend: .auto, hevcVTAvailable: true, h264VTAvailable: true
        )
        let joined = plan.ffmpegArgs.joined(separator: " ")
        XCTAssertFalse(joined.contains("-hwaccel videotoolbox"))
        XCTAssertEqual(
            plan.accelerationReport.compatibilityNotice,
            PipelineAccelerationReport.compatibilityModeNotice
        )
        XCTAssertFalse(
            PipelineAccelerationReport.compatibilityModeNotice.localizedCaseInsensitiveContains("CPU")
        )
    }

    func testTranscodeH265HardwareHDRKeepsHDRMain10() {
        let plan = Transcoder.plan(
            format: .mp4H265, inputPath: "in.webm", outputPath: "out.mp4",
            sourceVCodec: "vp9", sourceIsHDR: true, x265Available: true,
            backend: .auto, hevcVTAvailable: true, h264VTAvailable: true
        )
        XCTAssertFalse(plan.dropsHDR)
        let joined = plan.ffmpegArgs.joined(separator: " ")
        XCTAssertTrue(joined.contains("hevc_videotoolbox"))
        XCTAssertTrue(joined.contains("main10"))
        XCTAssertTrue(joined.contains("smpte2084"))
    }

    func testTranscodeH265SoftwareBackendStillUsesLibx265() {
        let plan = Transcoder.plan(
            format: .mp4H265, inputPath: "in.webm", outputPath: "out.mp4",
            sourceVCodec: "vp9", sourceIsHDR: true, x265Available: true,
            backend: .software, hevcVTAvailable: true, h264VTAvailable: true
        )
        XCTAssertTrue(plan.ffmpegArgs.contains("libx265"))
        XCTAssertFalse(plan.dropsHDR)
    }

    func testTranscodeDefaultBackendUnchangedPreservesLibx265() {
        // 不传 backend（默认 .software）：保持旧行为，便于其余既有断言不变。
        let plan = Transcoder.plan(
            format: .mp4H265, inputPath: "in.webm", outputPath: "out.mp4",
            sourceVCodec: "vp9", sourceIsHDR: false, x265Available: true
        )
        XCTAssertTrue(plan.ffmpegArgs.contains("libx265"))
    }

    // MARK: - 编码回退链（硬件失败 → 软件同编码，绝不降级）

    private func chain(
        backend: EncodeBackend,
        sourceIsHEVC: Bool = false,
        isHDR: Bool = false,
        alwaysH264: Bool = false,
        x265: Bool = true,
        hevcVT: Bool = true,
        h264VT: Bool = true
    ) -> [FFmpegBurner.VideoEncoderSelection] {
        FFmpegBurner.selectVideoEncoderChain(
            backend: backend, alwaysH264: alwaysH264, sourceIsHEVC: sourceIsHEVC, isHDR: isHDR,
            colorPrimaries: nil, colorTransfer: nil, colorSpace: nil, maxrateK: nil,
            x265Available: x265, hevcVTAvailable: hevcVT, h264VTAvailable: h264VT
        )
    }

    func testHardwareHEVCChainFallsBackToLibx265SameCodec() {
        let c = chain(backend: .auto, sourceIsHEVC: true)
        XCTAssertEqual(c.count, 2, "硬件主选 + 软件回退")
        XCTAssertTrue(c[0].encoderArgs.contains("hevc_videotoolbox"))
        // 回退仍是 HEVC（libx265），绝不降级成 H.264。
        XCTAssertTrue(c[1].encoderArgs.contains("libx265"))
        XCTAssertFalse(c[1].encoderArgs.contains("libx264"))
    }

    func testHardwareHDRChainFallbackKeepsHDRTenBit() {
        let c = chain(backend: .auto, isHDR: true)
        XCTAssertEqual(c.count, 2)
        XCTAssertTrue(c[0].encoderArgs.contains("hevc_videotoolbox"))
        XCTAssertTrue(c[1].encoderArgs.contains("libx265"))
        XCTAssertTrue(c[1].encoderArgs.contains("yuv420p10le"), "HDR 回退仍保 10-bit")
    }

    func testSoftwareBackendChainHasNoHardwareCandidate() {
        let c = chain(backend: .software, sourceIsHEVC: true)
        XCTAssertEqual(c.count, 1)
        XCTAssertTrue(c[0].encoderArgs.contains("libx265"))
    }

    func testHardwareUnavailableChainHasSingleSoftwareCandidate() {
        // 想用硬件但 VT 不可用：主选已落到软件，回退与主选相同 → 不重复，只一个候选。
        let c = chain(backend: .auto, sourceIsHEVC: true, hevcVT: false)
        XCTAssertEqual(c.count, 1)
        XCTAssertTrue(c[0].encoderArgs.contains("libx265"))
    }

    // MARK: - 码率一致（不缩放时纯 CRF / -q:v，无 maxrate）

    func testSoftwareNoScaleUsesPureCRFNoMaxrate() {
        let args = FFmpegBurner.sdrH264VideoArgs(maxrateK: nil)
        XCTAssertTrue(args.contains("-crf"))
        XCTAssertFalse(args.contains("-maxrate"), "保持源分辨率时不封顶码率，画质一致")
    }

    func testSoftwareScaledKeepsMaxrateCap() {
        let args = FFmpegBurner.sdrH264VideoArgs(maxrateK: 6000)
        XCTAssertTrue(args.contains("-maxrate"))
        XCTAssertTrue(args.contains("6000k"))
    }

    func testHEVCSoftwareNoScaleIsPureCRF() {
        let args = FFmpegBurner.sdrHEVCVideoArgs(maxrateK: nil)
        XCTAssertFalse(args.contains("-maxrate"))
        XCTAssertTrue(args.contains("libx265"))
    }

    func testHDRSoftwareNoScaleIsPureCRF() {
        let args = FFmpegBurner.hdrVideoArgs(
            colorPrimaries: nil, colorTransfer: nil, colorSpace: nil, maxrateK: nil
        )
        XCTAssertFalse(args.contains("-maxrate"))
        XCTAssertTrue(args.contains("yuv420p10le"))
    }

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
