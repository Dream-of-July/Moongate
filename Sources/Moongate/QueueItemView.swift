import AppKit
import SwiftUI
#if canImport(MoongateCore)
import MoongateCore
#endif

/// 队列中的一行：缩略图 + 标题 + 阶段文案 + 进度条 + 右侧按钮组。
struct QueueItemView: View {
    let item: QueueManager.QueueItem
    let onPause: () -> Void
    let onResume: () -> Void
    let onCancel: () -> Void
    let onRetry: () -> Void
    let onRemove: () -> Void
    let onReveal: () -> Void
    @EnvironmentObject private var localizer: Localizer

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            thumbnail
            VStack(alignment: .leading, spacing: 5) {
                Text(item.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(item.title)
                statusLine
                if showsProgressBar {
                    progressBar
                }
            }
            Spacer(minLength: 8)
            buttons
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - 缩略图

    private var thumbnail: some View {
        AsyncImage(url: item.thumbnailURL) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            default:
                Rectangle()
                    .fill(.quaternary)
                    .overlay(Image(systemName: "film").foregroundStyle(.tertiary))
            }
        }
        .frame(width: 64, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    // MARK: - 文案

    private var statusLine: some View {
        Text(statusText)
            .font(.caption)
            .foregroundStyle(isFailed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            .lineLimit(2)
    }

    private var statusText: String {
        if item.isPaused { return localizer.t(L.Queue.paused) }
        switch item.stage {
        case .queued:
            // 等槽位/等待恢复等具体原因（QueueManager 写入），没有就显示通用文案
            return item.statusText ?? localizer.t(L.Queue.queuedEllipsis)
        case .downloading:
            if item.isPostDownloadProcessing { return postDownloadProcessingText }
            if let p = item.progress { return localizer.t(L.Queue.downloadingPercent, Int(p * 100)) }
            return localizer.t(L.Queue.downloading)
        case .translating:
            if let p = item.progress { return localizer.t(L.Queue.translatingPercent, Int(p * 100)) }
            return localizer.t(L.Queue.translating)
        case .burning:
            if let p = item.progress { return localizer.t(L.Queue.burningPercent, Int(p * 100)) }
            return localizer.t(L.Queue.burning)
        case .done:
            return item.statusText ?? localizer.t(L.Queue.done)
        case .cancelled:
            return item.statusText ?? localizer.t(L.Queue.cancelled)
        case .failed(let reason):
            return localizer.t(L.Queue.failedWithReason, reason)
        }
    }

    private var postDownloadProcessingText: String {
        switch item.postDownloadProcessingKind {
        case .transcoding:
            if let p = item.progress { return localizer.t(L.Queue.transcodingPercent, Int(p * 100)) }
            return localizer.t(L.Queue.transcoding)
        case .generic, nil:
            return (item.statusText ?? localizer.t(L.Queue.processing)) + "…"
        }
    }

    private var isFailed: Bool {
        if case .failed = item.stage { return true }
        return false
    }

    // MARK: - 进度条

    private var showsProgressBar: Bool {
        switch item.stage {
        case .queued, .downloading, .translating, .burning:
            return true
        case .done, .failed, .cancelled:
            return false
        }
    }

    private var progressBar: some View {
        Group {
            if let p = item.progress {
                ProgressView(value: min(max(p, 0), 1))
                    .tint(item.isPaused ? .gray : nil)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(item.isPaused ? .gray : nil)
            }
        }
        .accessibilityLabel(progressAccessibilityLabel)
        .accessibilityValue(progressAccessibilityValue)
    }

    private var progressAccessibilityLabel: String {
        "\(item.title) \(progressStageAccessibilityName)"
    }

    private var progressStageAccessibilityName: String {
        switch item.stage {
        case .queued:
            return localizer.t(L.Queue.queueProgress)
        case .downloading:
            if item.postDownloadProcessingKind == .transcoding { return localizer.t(L.Queue.transcodeProgress) }
            return item.isPostDownloadProcessing ? localizer.t(L.Queue.processingProgress) : localizer.t(L.Queue.downloadProgress)
        case .translating:
            return localizer.t(L.Queue.translationProgress)
        case .burning:
            return localizer.t(L.Queue.burnProgress)
        case .done:
            return localizer.t(L.Queue.doneProgress)
        case .failed:
            return localizer.t(L.Queue.failedProgress)
        case .cancelled:
            return localizer.t(L.Queue.cancelledProgress)
        }
    }

    private var progressAccessibilityValue: String {
        if item.isPaused { return localizer.t(L.Queue.paused) }
        if let p = item.progress {
            let percent = Int((min(max(p, 0), 1) * 100).rounded())
            return "\(percent)%"
        }
        switch item.stage {
        case .queued:
            return item.statusText ?? localizer.t(L.Queue.queued)
        case .downloading:
            if item.postDownloadProcessingKind == .transcoding { return localizer.t(L.Queue.progressIndeterminateTranscoding) }
            return item.isPostDownloadProcessing ? localizer.t(L.Queue.progressDownloadProcessing) : localizer.t(L.Queue.progressIndeterminateDownloading)
        case .translating:
            return localizer.t(L.Queue.progressIndeterminateTranslating)
        case .burning:
            return localizer.t(L.Queue.progressIndeterminateBurning)
        case .done:
            return item.statusText ?? localizer.t(L.Queue.done)
        case .failed(let reason):
            return localizer.t(L.Queue.failedWithReason, reason)
        case .cancelled:
            return item.statusText ?? localizer.t(L.Queue.cancelled)
        }
    }

    // MARK: - 按钮组

    @ViewBuilder
    private var buttons: some View {
        switch item.stage {
        case .queued, .downloading, .translating, .burning:
            HStack(spacing: 6) {
                if item.isPaused {
                    iconButton("play.fill", help: localizer.t(L.Queue.resume), hint: localizer.t(L.Queue.resumeHint), action: onResume)
                } else {
                    iconButton("pause.fill", help: localizer.t(L.Queue.pause), hint: localizer.t(L.Queue.pauseHint), action: onPause)
                }
                iconButton("xmark", help: localizer.t(L.Queue.cancelAction), hint: localizer.t(L.Queue.cancelHint), action: onCancel)
            }
        case .done:
            HStack(spacing: 6) {
                if item.partialFailure {
                    // 部分成功（视频已下载、字幕处理失败）：只重跑字幕处理，不重新下载
                    iconButton("arrow.clockwise", help: localizer.t(L.Queue.retrySubtitle), hint: localizer.t(L.Queue.retrySubtitleHint), action: onRetry)
                }
                if !item.resultFiles.isEmpty {
                    iconButton("folder", help: localizer.t(L.Queue.revealInFinder), hint: localizer.t(L.Queue.revealInFinderHint), action: onReveal)
                }
                iconButton("trash", help: localizer.t(L.Queue.remove), hint: localizer.t(L.Queue.removeHint), action: onRemove)
            }
        case .failed:
            HStack(spacing: 6) {
                iconButton("arrow.clockwise", help: localizer.t(L.Queue.retryTask), hint: localizer.t(L.Queue.retryTaskHint), action: onRetry)
                iconButton("trash", help: localizer.t(L.Queue.remove), hint: localizer.t(L.Queue.removeHint), action: onRemove)
            }
        case .cancelled:
            HStack(spacing: 6) {
                iconButton("arrow.clockwise", help: localizer.t(L.Queue.retryTask), hint: localizer.t(L.Queue.retryTaskHint), action: onRetry)
                if !item.resultFiles.isEmpty {
                    iconButton("folder", help: localizer.t(L.Queue.revealInFinder), hint: localizer.t(L.Queue.revealInFinderHint), action: onReveal)
                }
                iconButton("trash", help: localizer.t(L.Queue.remove), hint: localizer.t(L.Queue.removeHint), action: onRemove)
            }
        }
    }

    private func iconButton(_ systemName: String, help: String, hint: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.bordered)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityHint(hint)
    }
}
