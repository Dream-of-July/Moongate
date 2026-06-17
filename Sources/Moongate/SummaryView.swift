import SwiftUI
#if canImport(MoongateCore)
import MoongateCore
#endif

/// AI 总结卡片：仿 Apple Intelligence 的「计算时流光边框 + 完成后展开」效果。
/// 计算中：圆角卡片描一圈缓慢旋转/呼吸的彩色渐变光边；完成：结果淡入并展开。
struct SummaryCard: View {
    let state: ViewModel.SummaryState
    let unavailableReason: String?
    let isAvailable: Bool
    let onSummarize: () -> Void
    let onCancel: () -> Void
    @EnvironmentObject private var localizer: Localizer

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
            Label(localizer.t(L.Summary.title), systemImage: "sparkles")
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
            Text(localizer.t(L.Summary.idleDescription))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var runningContent: some View {
        HStack(spacing: 10) {
            ShimmerText(text: localizer.t(L.Summary.running))
            Spacer(minLength: 0)
            Button(localizer.t(L.Common.cancel), action: onCancel)
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
        .accessibilityLabel(localizer.t(L.Summary.runningAccessibility))
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
                Label(localizer.t(L.Summary.retry), systemImage: "arrow.clockwise")
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
            Button(localizer.t(L.Common.retry), action: onSummarize)
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

/// 文字海浪高光：一道高光波峰沿文字逐字滚过，字符随波峰起伏（上浮 + 提亮 + 微放大），
/// 波峰扫完整行后留一段平静间隔再来下一道，像偶尔涌起的海浪。呼应 Apple Intelligence 的
/// 「思考中」文案。尊重 Reduce Motion（静态文字、无动画）。
private struct ShimmerText: View {
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 波峰每秒扫过的字符数。
    private let speed: Double = 6.5
    /// 扫完整行后的平静间隔（秒），制造「偶尔」涌起的节奏。
    private let calmGap: Double = 1.1
    /// 波峰宽度（影响同时被照亮的字符数，越大越「连续」）。
    private let sigma: Double = 1.15
    /// 波峰处字符上浮的最大像素。
    private let amplitude: CGFloat = 2.5

    var body: some View {
        if reduceMotion {
            Text(text)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
        } else {
            let characters = Array(text)
            TimelineView(.animation) { timeline in
                let crest = crestPosition(at: timeline.date, count: characters.count)
                HStack(spacing: 0) {
                    ForEach(Array(characters.enumerated()), id: \.offset) { index, character in
                        characterView(character, intensity: intensity(index: index, crest: crest))
                    }
                }
            }
            .accessibilityElement()
            .accessibilityLabel(text)
        }
    }

    /// 波峰位置：在 [0, count) 区间匀速推进，之后进入 calmGap 平静期（波峰移到行外，全行回落）。
    private func crestPosition(at date: Date, count: Int) -> Double {
        guard count > 0 else { return 0 }
        // 波峰需要多扫出 sigma*3 个字符，让行尾字符也能完整落下后再进入平静。
        let runDistance = Double(count) + sigma * 3
        let period = runDistance / speed + calmGap
        let t = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period)
        return t * speed - sigma * 1.5
    }

    /// 单个字符的高光强度（0…1）：到波峰中心最亮，呈高斯钟形向两侧衰减。
    private func intensity(index: Int, crest: Double) -> Double {
        let d = Double(index) - crest
        return exp(-(d * d) / (2 * sigma * sigma))
    }

    private func characterView(_ character: Character, intensity: Double) -> some View {
        let string = String(character)
        return Text(string)
            .font(.callout.weight(.medium))
            .foregroundStyle(.secondary)
            .overlay {
                Text(string)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(waveColor(intensity: intensity))
                    .opacity(intensity)
            }
            .scaleEffect(1 + 0.14 * intensity, anchor: .bottom)
            .offset(y: -amplitude * intensity)
    }

    /// 波峰高光颜色：在 Apple Intelligence 蓝紫到亮白之间按强度过渡。
    /// 手动 RGB 插值（Color.mix 需 macOS 15，部署目标是 macOS 14）。
    private func waveColor(intensity: Double) -> Color {
        let baseR = 0.55, baseG = 0.45, baseB = 1.0
        // 越接近波峰越偏亮白，制造浪尖泛光的层次。
        let t = min(1, intensity * 0.6)
        return Color(
            red: baseR + (1.0 - baseR) * t,
            green: baseG + (1.0 - baseG) * t,
            blue: baseB + (1.0 - baseB) * t
        )
    }
}
