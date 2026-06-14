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

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("下载队列")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("\(queue.items.count) 个任务")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                if queue.hasFinishedItems {
                    Button("清除已结束任务") {
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
                    .help("收起队列")
                    .accessibilityLabel("收起队列")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("下载队列")
            .accessibilityValue(queueHeaderAccessibilityValue)
            Divider()
            ScrollView {
                // Lazy：批量粘贴上百条时只实体化可见行
                LazyVStack(spacing: 0) {
                    ForEach(queue.items) { item in
                        QueueItemView(
                            item: item,
                            onPause: { queue.pause(item.id) },
                            onResume: { queue.resume(item.id) },
                            onCancel: { queue.cancel(item.id) },
                            onRetry: { queue.retry(item.id) },
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
        "从队列移除已完成、失败或已取消的任务；不会删除已下载文件。"
    }

    private var queueHeaderAccessibilityValue: String {
        let total = "\(queue.items.count) 个任务"
        let open = queue.openTaskCount
        if open == 0 {
            return "\(total)，全部已结束"
        }
        if queue.pausedOpenTaskCount == open {
            return "\(total)，\(open) 个进行中，全部暂停"
        }
        return "\(total)，\(open) 个进行中"
    }
}
