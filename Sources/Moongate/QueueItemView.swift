import AppKit
import SwiftUI
#if canImport(MoongateCore)
import MoongateCore
#endif

/// 队列中的一行：缩略图 + 标题 + 阶段文案 + 进度条 + 右侧按钮组。
struct QueueItemView: View {
    let item: QueueManager.QueueItem
    let canRetryWithLocalASR: Bool
    let isLocalASRRetryReady: Bool
    let onPause: () -> Void
    let onResume: () -> Void
    let onCancel: () -> Void
    let onRetry: () -> Void
    let onRetryWithLocalASR: () -> Void
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
                if showsTimingSuggestion {
                    Text(localizer.t(L.Queue.localASRQualitySuggestion))
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                subtitleSourceDisclosure
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
            if let localASRText = localASRProgressText { return statusWithDetails(localASRText, includeSpeed: false) }
            if item.isPostDownloadProcessing { return statusWithDetails(postDownloadProcessingText, includeSpeed: false) }
            if let p = item.progress { return statusWithDetails(localizer.t(L.Queue.downloadingPercent, Int(p * 100))) }
            return statusWithDetails(localizer.t(L.Queue.downloading))
        case .translating:
            if let p = item.progress { return statusWithDetails(localizer.t(L.Queue.translatingPercent, Int(p * 100)), includeSpeed: false) }
            return statusWithDetails(localizer.t(L.Queue.translating), includeSpeed: false)
        case .burning:
            if let p = item.progress { return statusWithDetails(localizer.t(L.Queue.burningPercent, Int(p * 100)), includeSpeed: false) }
            return statusWithDetails(localizer.t(L.Queue.burning), includeSpeed: false)
        case .done:
            return item.statusText ?? localizer.t(L.Queue.done)
        case .cancelled:
            return item.statusText ?? localizer.t(L.Queue.cancelled)
        case .failed(let reason):
            return localizer.t(L.Queue.failedWithReason, reason)
        }
    }

    private var localASRProgressText: String? {
        switch item.progressPhase {
        case .audioExtract:
            if let p = item.progress { return localizer.t(L.Queue.audioExtractingPercent, Int(p * 100)) }
            return localizer.t(L.Queue.audioExtracting)
        case .speechRecognition:
            if let p = item.progress { return localizer.t(L.Queue.speechRecognizingPercent, Int(p * 100)) }
            return localizer.t(L.Queue.speechRecognizing)
        case .subtitleSegment:
            if let p = item.progress { return localizer.t(L.Queue.subtitleSegmentingPercent, Int(p * 100)) }
            return localizer.t(L.Queue.subtitleSegmenting)
        default:
            return nil
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

    private func statusWithDetails(_ base: String, includeSpeed: Bool = true) -> String {
        var parts = [base]
        if includeSpeed, let speed = item.speedText, !speed.isEmpty {
            parts.append(speed)
        }
        if let remaining = remainingText {
            parts.append(remaining)
        }
        return parts.joined(separator: " · ")
    }

    private var remainingText: String? {
        if let seconds = item.remainingSeconds {
            if item.remainingIsApproximate {
                return localizer.t(L.Queue.remainingApprox, approximateDurationText(seconds))
            }
            return localizer.t(L.Queue.remainingExact, clockDurationText(seconds))
        }
        if item.isEstimatingRemaining {
            return localizer.t(L.Queue.remainingEstimating)
        }
        return nil
    }

    private func clockDurationText(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
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

    /// Done item whose produced subtitle timing looks unreliable (e.g. platform rolling captions)
    /// and which can be re-run with AI-enhanced recognition — surface the gentle suggestion.
    private var showsTimingSuggestion: Bool {
        item.timingWarning && canRetryWithLocalASR
    }

    @ViewBuilder
    private var subtitleSourceDisclosure: some View {
        if let source = item.resolvedSubtitleSource {
            if let reason = subtitleSourceReason(source) {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(localizer.t(L.Queue.subtitleSourceReason, reason))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                } label: {
                    Text(subtitleSourceSummary(source))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .disclosureGroupStyle(.automatic)
            } else {
                Text(subtitleSourceSummary(source))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
    }

    private func subtitleSourceSummary(_ source: ResolvedSubtitleSource) -> String {
        localizer.t(
            L.Queue.subtitleSourceActual,
            subtitleSourceKindLabel(source.selectedKind),
            subtitleDisplayLanguage(source.languageCode)
        )
    }

    private func subtitleSourceReason(_ source: ResolvedSubtitleSource) -> String? {
        if let note = item.subtitleSourceNote, !note.isEmpty { return note }
        let reasons = source.fallbackReasons.map(subtitleFallbackReasonLabel)
        if !reasons.isEmpty { return reasons.joined(separator: " / ") }
        if let verdict = source.sourceQualityVerdict, verdict <= .lowConfidence {
            return localizer.t(L.Queue.subtitleSourceLowConfidenceSuggestion)
        }
        if let verdict = source.qualityVerdict, !verdict.usable {
            return localizer.t(L.Queue.subtitleSourceLowConfidenceSuggestion)
        }
        return nil
    }

    private func subtitleFallbackReasonLabel(_ reason: PlatformSubtitleQualityGate.Reason) -> String {
        switch reason {
        case .languageMismatch:
            return localizer.t(L.Queue.subtitleSourceFallbackLanguageMismatch)
        case .lowCoverage:
            return localizer.t(L.Queue.subtitleSourceFallbackCoverage)
        case .garbledOrRepetitive:
            return localizer.t(L.Queue.subtitleSourceFallbackGarbled)
        case .tooFewCues:
            return localizer.t(L.Queue.subtitleSourceFallbackFewCues)
        }
    }

    private func subtitleSourceKindLabel(_ kind: SubtitleSourceKind) -> String {
        switch kind {
        case .manual:
            return localizer.t(L.Ready.manualSubtitle)
        case .platformAuto:
            return localizer.t(L.Ready.platformSubtitle)
        case .hlsManifest:
            return localizer.t(L.Ready.platformSubtitle)
        case .localASR:
            return localizer.t(L.Ready.localASR)
        case .cloudASR:
            return localizer.t(L.Ready.localASR)
        case .importedFile:
            return localizer.t(L.Ready.importedSubtitle)
        }
    }

    private func subtitleDisplayLanguage(_ code: String) -> String {
        let normalized = LanguageCatalog.normalize(code)
        if normalized.isEmpty || normalized == "auto" {
            return "auto"
        }
        return TranslationLanguage.sourceDisplayName(for: normalized) ?? normalized
    }

    private var progressBar: some View {
        Group {
            if let p = item.overallProgress {
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
            switch item.progressPhase {
            case .audioExtract:
                return localizer.t(L.Queue.audioExtractProgress)
            case .speechRecognition:
                return localizer.t(L.Queue.speechRecognitionProgress)
            case .subtitleSegment:
                return localizer.t(L.Queue.subtitleSegmentProgress)
            default:
                break
            }
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
        if let p = item.overallProgress {
            let percent = Int((min(max(p, 0), 1) * 100).rounded())
            return "\(percent)%"
        }
        switch item.stage {
        case .queued:
            return item.statusText ?? localizer.t(L.Queue.queued)
        case .downloading:
            switch item.progressPhase {
            case .audioExtract:
                return localizer.t(L.Queue.progressIndeterminateAudioExtract)
            case .speechRecognition:
                return localizer.t(L.Queue.progressIndeterminateSpeechRecognition)
            case .subtitleSegment:
                return localizer.t(L.Queue.progressIndeterminateSubtitleSegment)
            default:
                break
            }
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
                if canRetryWithLocalASR {
                    iconButton(
                        "waveform",
                        help: localizer.t(L.Queue.retryWithLocalASR),
                        hint: localizer.t(isLocalASRRetryReady ? L.Queue.retryWithLocalASRHint : L.Queue.retryWithLocalASRConfigureHint),
                        action: onRetryWithLocalASR
                    )
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
