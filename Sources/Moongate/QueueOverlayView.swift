import SwiftUI
#if canImport(MoongateCore)
import MoongateCore
#endif

/// 队列浮层：有任务时要么铺满内容区（expanded），要么缩成右下角小把手。
/// 直接观察 QueueManager（与 QueueSectionView 同理）：任务增删、进度 tick
/// 只重绘本子树；空队列时整层消失、不挡下层点击。
struct QueueOverlayView: View {
    @ObservedObject var queue: QueueManager
    @Binding var expanded: Bool
    var onConfigureLocalASR: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var localizer: Localizer

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if !queue.items.isEmpty {
                if expanded {
                    QueueSectionView(queue: queue) {
                        expanded = false
                    } onConfigureLocalASR: {
                        onConfigureLocalASR()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.regularMaterial)
                    .transition(overlayTransition)
                } else {
                    handle
                        .padding([.bottom, .trailing], 14)
                        .transition(overlayTransition)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .animation(overlayAnimation, value: expanded)
        .animation(overlayAnimation, value: queue.items.isEmpty)
    }

    // MARK: - 小把手

    private var overlayTransition: AnyTransition {
        reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity)
    }

    private var overlayAnimation: Animation? {
        reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.82)
    }

    private var openCount: Int { queue.openTaskCount }

    /// 队列整体完成度：终态算 1，进行中按各自进度（未知进度按 0 计）。
    private var overallProgress: Double {
        queue.progressSnapshot.overallProgress
    }

    private var handleLabel: String {
        if openCount == 0 { return terminalHandleLabel }
        if queue.pausedOpenTaskCount == openCount { return localizer.t(L.Queue.pausedCount, openCount) }
        var label = localizer.t(L.Queue.inProgressCount, openCount)
        if let remaining = queueRemainingText {
            label += " · " + remaining
        }
        return label
    }

    private var terminalHandleLabel: String {
        let allSucceeded = queue.items.allSatisfy { item in
            if case .done = item.stage { return true }
            return false
        }
        return localizer.t(allSucceeded ? L.Queue.allDone : L.Queue.allEnded)
    }

    private var queueRemainingText: String? {
        let snapshot = queue.progressSnapshot
        if let seconds = snapshot.remainingSeconds {
            return localizer.t(L.Queue.remainingApprox, approximateDurationText(seconds))
        }
        if snapshot.isEstimatingRemaining {
            return localizer.t(L.Queue.remainingEstimating)
        }
        return nil
    }

    private var progressAccessibilityValue: String {
        if openCount == 0 { return localizer.t(L.Queue.allEnded) }
        let percent = Int((overallProgress * 100).rounded())
        return "\(percent)%"
    }

    private var handle: some View {
        Button {
            expanded = true
        } label: {
            HStack(spacing: 8) {
                ProgressRingView(progress: overallProgress, finished: openCount == 0)
                Text(handleLabel)
                    .font(.callout)
                Image(systemName: "chevron.up")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(localizer.t(L.Queue.openQueue))
        .accessibilityLabel(localizer.t(L.Queue.openQueueWithLabel, handleLabel))
        .accessibilityValue(localizer.t(L.Queue.progressValue, progressAccessibilityValue))
    }

    private func approximateDurationText(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        if total < 60 {
            return localizer.t(L.Queue.remainingLessThanMinute)
        }
        let minutes = Int(ceil(Double(total) / 60.0))
        if minutes < 60 {
            return localizer.t(L.Queue.remainingMinutes, minutes)
        }
        let hours = minutes / 60
        let rest = minutes % 60
        return localizer.t(L.Queue.remainingHoursMinutes, hours, rest)
    }
}

/// 小把手上的圆形整体进度环；全部到终态后换成对勾。
struct ProgressRingView: View {
    let progress: Double
    let finished: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var localizer: Localizer

    var body: some View {
        ZStack {
            if finished {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.green)
            } else {
                Circle()
                    .stroke(.quaternary, lineWidth: 3)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: progress)
            }
        }
        .frame(width: 18, height: 18)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(localizer.t(L.Queue.overallProgress))
        .accessibilityValue(progressAccessibilityValue)
    }

    private var progressAccessibilityValue: String {
        if finished { return localizer.t(L.Queue.allEnded) }
        let percent = Int((min(1, max(0, progress)) * 100).rounded())
        return "\(percent)%"
    }
}
