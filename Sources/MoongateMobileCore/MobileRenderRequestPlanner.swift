import Foundation

public enum MobileRenderRequestPlanStatus: String, Codable, Sendable, Equatable, CaseIterable {
    case notRequired
    case ready
    case blocked
}

public enum MobileRenderRequestBlockedReason: String, Codable, Sendable, Equatable, CaseIterable {
    case taskNotCompleted
    case unsupportedExportProfile
    case missingSourceMedia
    case missingSubtitle
}

public struct MobileRenderRequestPlan: Codable, Sendable, Equatable {
    public var status: MobileRenderRequestPlanStatus
    public var request: MobileRenderRequest?
    public var blockedReason: MobileRenderRequestBlockedReason?

    public init(
        status: MobileRenderRequestPlanStatus,
        request: MobileRenderRequest? = nil,
        blockedReason: MobileRenderRequestBlockedReason? = nil
    ) {
        self.status = status
        self.request = request
        self.blockedReason = blockedReason
    }
}

public struct MobileRenderRequestPlanner: Sendable {
    public init() {}

    public func plan(for task: MobileTaskSnapshot) -> MobileRenderRequestPlan {
        guard task.exportProfile.requiresVideoRender else {
            return MobileRenderRequestPlan(status: .notRequired)
        }

        guard task.state == .completed else {
            return MobileRenderRequestPlan(status: .blocked, blockedReason: .taskNotCompleted)
        }

        guard task.capabilities.canSatisfy(task.exportProfile) else {
            return MobileRenderRequestPlan(status: .blocked, blockedReason: .unsupportedExportProfile)
        }

        let artifacts = task.result?.artifacts ?? []
        guard let sourceMedia = artifacts.first(where: Self.isRenderableSourceMedia) else {
            return MobileRenderRequestPlan(status: .blocked, blockedReason: .missingSourceMedia)
        }

        let subtitles = artifacts.filter(Self.isRenderableSubtitle)
        guard !subtitles.isEmpty else {
            return MobileRenderRequestPlan(status: .blocked, blockedReason: .missingSubtitle)
        }

        return MobileRenderRequestPlan(
            status: .ready,
            request: MobileRenderRequest(
                sourceMedia: sourceMedia,
                subtitles: subtitles,
                exportProfile: task.exportProfile
            )
        )
    }

    private static func isRenderableSourceMedia(_ artifact: MobileTaskArtifact) -> Bool {
        artifact.kind == .originalMedia
    }

    private static func isRenderableSubtitle(_ artifact: MobileTaskArtifact) -> Bool {
        artifact.kind == .translatedSubtitleFile
    }
}
