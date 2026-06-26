import Foundation

/// 本地 Whisper 识别输出的置信度概要。Whisper 对中/粤/韩等语言的歌唱内容常**自信地听错**或产出
/// 低置信乱码（青花瓷→「了出情话被风弄转」），此时没有更好的源可换（whisper 本就是 fallback），
/// 诚实做法是给用户「识别质量较低、字幕仅供参考」提示，而非把乱码当成自信字幕呈现。
///
/// **已知局限（保守取舍）**：whisper 置信度是弱信号——部分乱码（如韩语、个别中文）置信度并不低
/// （实测 BLACKPINK avg_prob 0.85 却是乱码）。阈值刻意保守，只对**明显低置信**的输出报警，
/// 零误伤干净内容；代价是 recall 有限（抓不住自信误识）。常量唯一真值在
/// `Tests/fixtures/whisper-timing-constants.json` 的 `localASRConfidence` 段，两端契约断言。
/// 跨端镜像：windows/MoongateCore/LocalAsrConfidence.cs。
public struct LocalASRConfidenceSummary: Codable, Equatable, Sendable {
    public let assessedWordCount: Int
    public let averageProbability: Double
    public let lowConfidenceWordRatio: Double
    public let isLowConfidence: Bool

    public init(assessedWordCount: Int, averageProbability: Double, lowConfidenceWordRatio: Double, isLowConfidence: Bool) {
        self.assessedWordCount = assessedWordCount
        self.averageProbability = averageProbability
        self.lowConfidenceWordRatio = lowConfidenceWordRatio
        self.isLowConfidence = isLowConfidence
    }
}

public enum LocalASRConfidence {
    /// 平均词概率低于此值视为整体低置信。
    static let averageProbabilityFloor = 0.8
    /// 单词概率低于此值算「低置信词」。
    static let lowConfidenceWordProbability = 0.5
    /// 低置信词占比超过此值视为整体低置信。
    static let lowConfidenceWordRatioCeiling = 0.2
    /// 样本不足时不评估（短片段噪声大），避免误报。
    static let minimumAssessableWordCount = 24

    /// 评估一段转写的整体置信度。只统计有概率、含可见字符的词。
    public static func assess(words: [ASRWord]) -> LocalASRConfidenceSummary {
        var probabilities: [Double] = []
        probabilities.reserveCapacity(words.count)
        for word in words {
            guard word.text.contains(where: { !$0.isWhitespace }) else { continue }
            guard let probability = word.probability else { continue }
            probabilities.append(probability)
        }
        let count = probabilities.count
        guard count > 0 else {
            return LocalASRConfidenceSummary(
                assessedWordCount: 0, averageProbability: 1, lowConfidenceWordRatio: 0, isLowConfidence: false)
        }
        let average = probabilities.reduce(0, +) / Double(count)
        let lowRatio = Double(probabilities.filter { $0 < lowConfidenceWordProbability }.count) / Double(count)
        let isLow = count >= minimumAssessableWordCount
            && (average < averageProbabilityFloor || lowRatio > lowConfidenceWordRatioCeiling)
        return LocalASRConfidenceSummary(
            assessedWordCount: count,
            averageProbability: average,
            lowConfidenceWordRatio: lowRatio,
            isLowConfidence: isLow)
    }
}
