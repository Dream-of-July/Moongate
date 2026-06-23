import SwiftUI
#if canImport(MoongateCore)
import MoongateCore
#endif

/// 队列区。直接 @ObservedObject 观察 QueueManager —— 这是队列 UI 唯一的订阅点：
/// 进度 tick 只触发本子树重绘，不会放大成整窗刷新；也修复了此前
/// 「ViewModel 不转发 queue.objectWillChange 导致进度条冻结」的断裂。
struct QueueSectionView: View {
    @ObservedObject var queue: QueueManager
    /// 非 nil 时头部显示「收起」按钮（铺满态收回成底部小把手）。
    var onCollapse: (() -> Void)? = nil
    var onConfigureLocalASR: () -> Void = {}
    @EnvironmentObject private var localizer: Localizer

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(localizer.t(L.Queue.title))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(localizer.t(L.Queue.taskCount, queue.items.count))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                if queue.hasFinishedItems {
                    Button(localizer.t(L.Queue.clearFinished)) {
                        queue.clearFinished()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .help(clearFinishedHelpText)
                    .accessibilityHint(clearFinishedHelpText)
                }
                if let onCollapse {
                    Button {
                        onCollapse()
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(localizer.t(L.Queue.collapse))
                    .accessibilityLabel(localizer.t(L.Queue.collapse))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(localizer.t(L.Queue.title))
            .accessibilityValue(queueHeaderAccessibilityValue)
            Divider()
            ScrollView {
                // Lazy：批量粘贴上百条时只实体化可见行
                LazyVStack(spacing: 0) {
                    ForEach(queue.items) { item in
                        QueueItemView(
                            item: item,
                            canRetryWithLocalASR: queue.canRetryWithLocalASR(item.id),
                            isLocalASRRetryReady: queue.hasLocalASRGenerator,
                            onPause: { queue.pause(item.id) },
                            onResume: { queue.resume(item.id) },
                            onCancel: { queue.cancel(item.id) },
                            onRetry: { queue.retry(item.id) },
                            onRetryWithLocalASR: {
                                if queue.hasLocalASRGenerator {
                                    queue.retryWithLocalASR(item.id)
                                } else {
                                    onConfigureLocalASR()
                                }
                            },
                            onRemove: { queue.remove(item.id) },
                            onReveal: { queue.revealInFinder(item.id) }
                        )
                        Divider().padding(.leading, 86)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var clearFinishedHelpText: String {
        localizer.t(L.Queue.clearFinishedHint)
    }

    private var queueHeaderAccessibilityValue: String {
        let total = localizer.t(L.Queue.taskCount, queue.items.count)
        let open = queue.openTaskCount
        if open == 0 {
            return localizer.t(L.Queue.headerAllFinished, total)
        }
        let openLabel = localizer.t(L.Queue.inProgressCount, open)
        if queue.pausedOpenTaskCount == open {
            return localizer.t(L.Queue.headerAllPaused, total, openLabel)
        }
        return localizer.t(L.Queue.headerInProgress, total, openLabel)
    }
}
