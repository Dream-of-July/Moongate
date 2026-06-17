import Foundation

/// ffmpeg 硬件加速家族。用于解释当前计划走的是哪类系统媒体/显卡能力。
public enum HardwareAccelerationFamily: String, Sendable, Equatable {
    case none
    case videoToolbox
    case nvidia
    case intelQuickSync
    case amdAMF
}

/// 一条转码/压制计划实际使用的加速路径摘要。
public struct PipelineAccelerationReport: Sendable, Equatable {
    public static var compatibilityModeNotice: String {
        CoreL10n.t(L.Core.compatibilityModeNotice)
    }

    public var family: HardwareAccelerationFamily
    public var usesHardwareDecode: Bool
    public var usesHardwareFilter: Bool
    public var usesHardwareEncode: Bool
    public var compatibilityNotice: String?

    public init(
        family: HardwareAccelerationFamily = .none,
        usesHardwareDecode: Bool = false,
        usesHardwareFilter: Bool = false,
        usesHardwareEncode: Bool = false,
        compatibilityNotice: String? = nil
    ) {
        self.family = family
        self.usesHardwareDecode = usesHardwareDecode
        self.usesHardwareFilter = usesHardwareFilter
        self.usesHardwareEncode = usesHardwareEncode
        self.compatibilityNotice = compatibilityNotice
    }

    public static let none = PipelineAccelerationReport()
}

enum HardwareAccelerationPlanner {
    static func inputArgs(
        family: HardwareAccelerationFamily,
        requiresCPUVideoFilter: Bool
    ) -> [String] {
        guard !requiresCPUVideoFilter else { return [] }
        switch family {
        case .videoToolbox:
            return ["-hwaccel", "videotoolbox"]
        case .nvidia:
            return ["-hwaccel", "cuda"]
        case .intelQuickSync:
            return ["-hwaccel", "qsv"]
        case .amdAMF:
            return ["-hwaccel", "d3d11va"]
        case .none:
            return []
        }
    }

    static func report(
        family: HardwareAccelerationFamily,
        usesHardwareEncode: Bool,
        requiresCPUVideoFilter: Bool
    ) -> PipelineAccelerationReport {
        PipelineAccelerationReport(
            family: family,
            usesHardwareDecode: family != .none && !requiresCPUVideoFilter,
            usesHardwareFilter: false,
            usesHardwareEncode: usesHardwareEncode,
            compatibilityNotice: family != .none && requiresCPUVideoFilter
                ? PipelineAccelerationReport.compatibilityModeNotice
                : nil
        )
    }
}
