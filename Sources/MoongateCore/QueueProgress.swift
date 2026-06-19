import Foundation

public enum QueueProgressPhase: String, CaseIterable, Sendable, Equatable {
    case download
    case transcode
    case translate
    case burn
}

public struct QueueProgressPlan: Sendable, Equatable {
    public let phases: [QueueProgressPhase]

    public init(shouldTranscode: Bool, shouldTranslate: Bool, shouldBurn: Bool) {
        var phases: [QueueProgressPhase] = [.download]
        if shouldTranscode { phases.append(.transcode) }
        if shouldTranslate { phases.append(.translate) }
        if shouldBurn { phases.append(.burn) }
        self.phases = phases
    }
}

public struct RemainingEstimate: Sendable, Equatable {
    public let seconds: Double
    public let isApproximate: Bool

    public init(seconds: Double, isApproximate: Bool) {
        self.seconds = seconds
        self.isApproximate = isApproximate
    }
}

public struct TaskProgressSnapshot: Sendable, Equatable {
    public let overallProgress: Double?
    public let remainingSeconds: Double?
    public let isEstimatingRemaining: Bool
    public let isTerminal: Bool
    public let plan: QueueProgressPlan?
    public let currentPhase: QueueProgressPhase?

    public init(
        overallProgress: Double?,
        remainingSeconds: Double?,
        isEstimatingRemaining: Bool,
        isTerminal: Bool,
        plan: QueueProgressPlan? = nil,
        currentPhase: QueueProgressPhase? = nil
    ) {
        self.overallProgress = overallProgress
        self.remainingSeconds = remainingSeconds
        self.isEstimatingRemaining = isEstimatingRemaining
        self.isTerminal = isTerminal
        self.plan = plan
        self.currentPhase = currentPhase
    }
}

public struct QueueProgressSnapshot: Sendable, Equatable {
    public let overallProgress: Double
    public let remainingSeconds: Double?
    public let isEstimatingRemaining: Bool

    public init(overallProgress: Double, remainingSeconds: Double?, isEstimatingRemaining: Bool) {
        self.overallProgress = overallProgress
        self.remainingSeconds = remainingSeconds
        self.isEstimatingRemaining = isEstimatingRemaining
    }
}

public enum QueueProgressEstimator {
    public static func normalizedFraction(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return min(max(value, 0), 1)
    }

    public static func taskOverallProgress(
        plan: QueueProgressPlan,
        currentPhase: QueueProgressPhase?,
        phaseProgress: Double?,
        previousOverallProgress: Double?
    ) -> Double? {
        guard !plan.phases.isEmpty else { return previousOverallProgress }
        guard let currentPhase,
              let index = plan.phases.firstIndex(of: currentPhase) else {
            return previousOverallProgress
        }
        let current = normalizedFraction(phaseProgress) ?? 0
        let phaseWeight = 1.0 / Double(plan.phases.count)
        let computed = Double(index) * phaseWeight + current * phaseWeight
        guard let previous = normalizedFraction(previousOverallProgress) else { return computed }
        return max(previous, computed)
    }

    public static func parseEtaSeconds(_ text: String?) -> Double? {
        guard let raw = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              raw != "N/A",
              raw != "Unknown" else {
            return nil
        }
        let parts = raw.split(separator: ":")
        guard parts.count == 2 || parts.count == 3 else { return nil }
        var total = 0
        for part in parts {
            guard let value = Int(part) else { return nil }
            total = total * 60 + value
        }
        return Double(total)
    }

    public static func estimatedRemainingSeconds(
        elapsedSeconds: Double,
        phaseProgress: Double?,
        sourceEtaSeconds: Double?,
        minimumElapsedSeconds: Double = 3,
        minimumProgress: Double = 0.03
    ) -> RemainingEstimate? {
        if let sourceEtaSeconds, sourceEtaSeconds.isFinite, sourceEtaSeconds >= 0 {
            return RemainingEstimate(seconds: sourceEtaSeconds, isApproximate: false)
        }
        guard elapsedSeconds >= minimumElapsedSeconds,
              let progress = normalizedFraction(phaseProgress),
              progress >= minimumProgress,
              progress < 1 else {
            return nil
        }
        let remaining = elapsedSeconds * (1 - progress) / progress
        guard remaining.isFinite, remaining >= 0 else { return nil }
        return RemainingEstimate(seconds: remaining, isApproximate: true)
    }

    public static func queueSnapshot(
        items: [TaskProgressSnapshot],
        phaseMedianDurations: [QueueProgressPhase: Double] = [:],
        phaseCapacities: [QueueProgressPhase: Int] = [:]
    ) -> QueueProgressSnapshot {
        guard !items.isEmpty else {
            return QueueProgressSnapshot(overallProgress: 0, remainingSeconds: nil, isEstimatingRemaining: false)
        }
        let total = items.reduce(0.0) { sum, item in
            if item.isTerminal { return sum + (normalizedFraction(item.overallProgress) ?? 1) }
            return sum + (normalizedFraction(item.overallProgress) ?? 0)
        }
        let openItems = items.filter { !$0.isTerminal }
        let overall = min(max(total / Double(items.count), 0), 1)
        let hasPlanningData = openItems.contains { $0.plan != nil }
        guard hasPlanningData else {
            let remaining = openItems.compactMap(\.remainingSeconds).filter { $0.isFinite && $0 >= 0 }.max()
            let estimating = openItems.contains { $0.isEstimatingRemaining }
            return QueueProgressSnapshot(
                overallProgress: overall,
                remainingSeconds: remaining,
                isEstimatingRemaining: estimating
            )
        }

        var phaseWork: [QueueProgressPhase: Double] = [:]
        var longestTaskRemaining = 0.0
        var hasUnknownWork = false
        for item in openItems {
            var taskRemaining = 0.0
            guard let plan = item.plan else {
                if let seconds = validSeconds(item.remainingSeconds) {
                    let phase = item.currentPhase ?? .download
                    phaseWork[phase, default: 0] += seconds
                    taskRemaining += seconds
                } else if item.isEstimatingRemaining {
                    hasUnknownWork = true
                }
                longestTaskRemaining = max(longestTaskRemaining, taskRemaining)
                continue
            }

            let nextIndex: Int
            if let currentPhase = item.currentPhase,
               let index = plan.phases.firstIndex(of: currentPhase) {
                if let seconds = validSeconds(item.remainingSeconds) {
                    phaseWork[currentPhase, default: 0] += seconds
                    taskRemaining += seconds
                } else {
                    hasUnknownWork = true
                }
                nextIndex = index + 1
            } else {
                let completed = Int(floor((normalizedFraction(item.overallProgress) ?? 0) * Double(plan.phases.count) + 0.0001))
                nextIndex = min(max(completed, 0), plan.phases.count)
            }

            for phase in plan.phases.dropFirst(nextIndex) {
                if let seconds = validSeconds(phaseMedianDurations[phase]) {
                    phaseWork[phase, default: 0] += seconds
                    taskRemaining += seconds
                } else {
                    hasUnknownWork = true
                }
            }
            longestTaskRemaining = max(longestTaskRemaining, taskRemaining)
        }

        if hasUnknownWork {
            return QueueProgressSnapshot(overallProgress: overall, remainingSeconds: nil, isEstimatingRemaining: true)
        }

        let phaseBound = phaseWork.map { phase, seconds in
            let capacity = max(1, phaseCapacities[phase] ?? 1)
            return seconds / Double(capacity)
        }.max()
        let remaining = max(phaseBound ?? 0, longestTaskRemaining)
        return QueueProgressSnapshot(
            overallProgress: overall,
            remainingSeconds: remaining > 0 ? remaining : nil,
            isEstimatingRemaining: false
        )
    }

    private static func validSeconds(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }
}
