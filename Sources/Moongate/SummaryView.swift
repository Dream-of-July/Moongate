import SwiftUI

/// AI 总结卡片：仿 Apple Intelligence 的「计算时流光边框 + 完成后展开」效果。
/// 计算中：圆角卡片描一圈缓慢旋转/呼吸的彩色渐变光边；完成：结果淡入并展开。
struct SummaryCard: View {
    let state: ViewModel.SummaryState
    let unavailableReason: String?
    let isAvailable: Bool
    let onSummarize: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch state {
            case .idle:
                idleContent
            case .running:
                runningContent
            case .done(let summary):
                doneContent(summary)
            case .failed(let message):
                failedContent(message)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.smooth(duration: 0.45), value: stateID)
    }

    // 给 animation 一个稳定可比较的标识，触发状态切换动画。
    private var stateID: Int {
        switch state {
        case .idle: return 0
        case .running: return 1
        case .done: return 2
        case .failed: return 3
        }
    }

    @ViewBuilder
    private var idleContent: some View {
        Button(action: onSummarize) {
            Label("总结视频内容", systemImage: "sparkles")
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .disabled(!isAvailable)
        if let reason = unavailableReason {
            Text(reason)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("下载前先用 AI 看一眼这是什么视频。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var runningContent: some View {
        HStack(spacing: 10) {
            ShimmerText(text: "正在理解视频内容…")
            Spacer(minLength: 0)
            Button("取消", action: onCancel)
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.quaternary.opacity(0.25))
        )
        .overlay(
            FlowingBorder()
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("正在生成总结")
    }

    @ViewBuilder
    private func doneContent(_ summary: String) -> some View {
        Text(summary)
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.quaternary.opacity(0.25))
            )
            .transition(.asymmetric(
                insertion: .scale(scale: 0.96, anchor: .top)
                    .combined(with: .opacity)
                    .combined(with: .move(edge: .top)),
                removal: .opacity
            ))
        HStack {
            Spacer(minLength: 0)
            Button(action: onSummarize) {
                Label("重新总结", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .font(.caption)
        }
    }

    @ViewBuilder
    private func failedContent(_ message: String) -> some View {
        Text(message)
            .font(.callout)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
        HStack {
            Spacer(minLength: 0)
            Button("重试", action: onSummarize)
                .buttonStyle(.bordered)
                .disabled(!isAvailable)
        }
    }
}

// MARK: - Apple Intelligence 风格的流光与微光

private let intelligenceColors = [
    Color(red: 0.40, green: 0.52, blue: 1.00),
    Color(red: 0.66, green: 0.40, blue: 0.98),
    Color(red: 0.96, green: 0.42, blue: 0.62),
    Color(red: 0.98, green: 0.62, blue: 0.36),
    Color(red: 0.40, green: 0.52, blue: 1.00),
]

/// 跑马灯式流光描边：边框形状固定不动，只让多彩渐变沿边框「流动」（旋转渐变角度），
/// 呼应 Apple Intelligence 的计算灯效。尊重 Reduce Motion（静态渐变）。
private struct FlowingBorder: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var angle: Double = 0

    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(
                AngularGradient(
                    colors: intelligenceColors,
                    center: .center,
                    angle: .degrees(angle)
                ),
                lineWidth: 2.5
            )
            .shadow(color: Color(red: 0.55, green: 0.45, blue: 1.0).opacity(0.35), radius: 4)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 2.2).repeatForever(autoreverses: false)) {
                    angle = 360
                }
            }
    }
}

/// 文字流光：浅底色上扫过一道高光，呼应 Apple Intelligence 的「思考中」文案。
private struct ShimmerText: View {
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    var body: some View {
        Text(text)
            .font(.callout.weight(.medium))
            .foregroundStyle(.secondary)
            .overlay {
                if !reduceMotion {
                    GeometryReader { geo in
                        LinearGradient(
                            colors: [.clear, Color(red: 0.55, green: 0.45, blue: 1.0).opacity(0.9), .clear],
                            startPoint: .leading, endPoint: .trailing
                        )
                        .frame(width: geo.size.width * 0.5)
                        .offset(x: phase * geo.size.width * 1.5)
                        .blendMode(.plusLighter)
                        .mask(Text(text).font(.callout.weight(.medium)))
                    }
                }
            }
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}
