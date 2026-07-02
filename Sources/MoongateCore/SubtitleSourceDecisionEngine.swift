import Foundation

/// 统一的字幕源决策权威。把"质量评估(门每候选只跑一次) + 是否生成 Whisper 的计划 + 多候选择优(tie-break)"
/// 收敛到单一处，供下载后执行（`SubtitleSourceResolver` / `QueueManager`）与下载前 UI 预测
/// （`SubtitleSourceDecision`）共享同一套规则、阈值与裁决口径，消除"UI 说用平台字幕、实际却生成 Whisper"
/// 这类不一致，以及 QueueManager 里"门(布尔) + 评分器(5级)"双裁决叠加、门被跑两次的问题。
///
/// 反冲突契约（与 [[moongate-ux-asr-productization-review]] 一致）：
/// - **门 `gateUsable` 只答"这个候选自身是否可用"**，是"是否生成 Whisper"的唯一依据；它绝不看时序、
///   绝不跨源比较（铁律见 `PlatformSubtitleQualityGate`）。
/// - **`score`/`verdict` 只答"真实候选里谁更好"**，用于排名与 tie-break，不参与"是否生成"。
/// - 不变式：`gateUsable == false ⇒ verdict <= .lowConfidence`（门的致命扣分足够把分数压到 usable 以下）。
///
/// tie-break：平分时取**更可信来源**（`sourceKindRank` 更小，manual<auto<local）。已实测确认 Swift
/// `max(by:)` 与 C# `OrderByDescending.ThenBy` 在此口径下一致，两端不再各写一套。
public enum SubtitleSourceDecisionEngine {

    /// 单候选评估：对一个候选只跑一次门（经 `SubtitleQualityScorer` 内部），并暴露门的权威裁决与排名分数。
    public struct Assessment: Equatable, Sendable {
        public let candidateID: String
        public let kind: SubtitleSourceKind
        public let languageCode: String
        public let score: Double
        public let verdict: SubtitleQualityVerdict
        public let gateUsable: Bool
        public let gateReasons: [PlatformSubtitleQualityGate.Reason]
        public let reasons: [String]
        public let report: PlatformSubtitleQualityGate.SubtitleSourceQualityReport?
        public let hasFile: Bool
    }

    /// 执行端"拿到平台自动字幕后该怎么办"的计划。由 policy + 平台候选的门裁决唯一决定。
    public enum ASRPlan: Equatable, Sendable {
        /// 直接用当前平台/人工/导入源，无需生成。
        case none
        /// 生成 Whisper，再让引擎在平台源与本地源之间择优。
        case generateLocalASRThenChoose
        /// 平台不可用且无生成器：沿用平台源、记录原因给 UI 提示（不阻塞）。
        case keepPlatformRecordReasons([PlatformSubtitleQualityGate.Reason])
    }

    // MARK: - 阈值（与 fixture `subtitleSourceDecision` 段两端契约对齐）

    /// `.autoBest` 下，平台自动字幕 verdict 低于此档（即 lowConfidence/unusable）时也重生成 Whisper。
    /// 这是把原本散落在 QueueManager 的 `|| score <= .lowConfidence` 收敛为**具名、可测、单类型**的质量地板，
    /// 而非把"门布尔"与"评分枚举"混在一起 OR。门不可用(`!gateUsable`)始终触发，与本地板取并集。
    public static let autoBestRegenerateBelow: SubtitleQualityVerdict = .usable

    // MARK: - 评估

    public static func assess(
        candidate: SubtitleSourceCandidate,
        requestedSourceLanguageCode: String?,
        videoDurationSeconds: Double?
    ) -> Assessment {
        let score = SubtitleQualityScorer.score(
            candidate: candidate,
            requestedSourceLanguageCode: requestedSourceLanguageCode,
            videoDurationSeconds: videoDurationSeconds
        )
        return Assessment(
            candidateID: score.candidateID,
            kind: score.kind,
            languageCode: score.languageCode,
            score: score.score,
            verdict: score.verdict,
            gateUsable: score.gateUsable,
            gateReasons: score.gateReasons,
            reasons: score.reasons,
            report: score.report,
            hasFile: candidate.fileURL != nil
        )
    }

    // MARK: - 是否生成 Whisper

    /// 给定 policy 与平台自动字幕的门裁决，决定执行端动作。`platform` 为 nil 表示没有平台自动字幕候选。
    public static func generationPlan(
        policy: SubtitleSourcePolicy,
        platform: Assessment?,
        localASRAvailable: Bool,
        cloudASRAvailable: Bool
    ) -> ASRPlan {
        switch policy {
        case .forcePlatform, .preferPlatform, .cloudASR, .importedFile:
            return .none
        case .forceLocalASR, .compareLocalASR:
            return localASRAvailable ? .generateLocalASRThenChoose : noGenerator(platform)
        case .preferLocalASR:
            guard let platform else {
                return localASRAvailable ? .generateLocalASRThenChoose : .none
            }
            if platform.gateUsable { return .none }
            return localASRAvailable ? .generateLocalASRThenChoose : noGenerator(platform)
        case .autoBest:
            guard let platform else { return .none }
            let needsRegen = !platform.gateUsable || platform.verdict < autoBestRegenerateBelow
            guard needsRegen else { return .none }
            return localASRAvailable ? .generateLocalASRThenChoose : noGenerator(platform)
        }
    }

    private static func noGenerator(_ platform: Assessment?) -> ASRPlan {
        .keepPlatformRecordReasons(platform?.gateReasons ?? [])
    }

    // MARK: - 生成后本地 ASR 云端救场

    /// 本地 ASR 已生成后，判断是否应在用户启用云端识别时升级为云端重识别。
    /// 这保留原有低置信度救场，同时让生成出的本地 SRT 也经过统一质量门，避免明显不可用的
    /// Whisper 结果被当作可比较候选静默留下。
    public static func shouldEscalateGeneratedLocalASR(
        policy: SubtitleSourcePolicy,
        localAssessment: Assessment?,
        localASRConfidenceIsLowQuality: Bool,
        cloudASRAvailable: Bool
    ) -> Bool {
        guard policy == .autoBest, cloudASRAvailable else { return false }
        if localASRConfidenceIsLowQuality { return true }
        guard let localAssessment else { return false }
        return !localAssessment.gateUsable || localAssessment.verdict < autoBestRegenerateBelow
    }

    // MARK: - 多候选择优（tie-break）

    /// 在已评估的候选中按 `score + policyBoost` 选最优；平分取更可信来源（更小 `sourceKindRank`）。
    /// 只在 `selectableIDs`（有文件的候选）里选。返回胜出候选的 id，无可选时返回 nil。
    public static func choose(
        policy: SubtitleSourcePolicy,
        assessments: [Assessment],
        selectableIDs: Set<String>
    ) -> String? {
        let selectable = assessments.filter { selectableIDs.contains($0.candidateID) }
        guard !selectable.isEmpty else { return nil }
        return selectable.max(by: { lhs, rhs in
            let lhsRank = lhs.score + policyBoost(lhs.kind, policy)
            let rhsRank = rhs.score + policyBoost(rhs.kind, policy)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            // 平分：更可信来源(更小 sourceKindRank)胜出。`max(by:)` 取"非更小"者，故此处返回
            // "lhs 更不可信(rank 更大)即视为更小" → 最终选出 rank 最小者。
            return sourceKindRank(lhs.kind) > sourceKindRank(rhs.kind)
        })?.candidateID
    }

    // MARK: - 排名权重（fixture 契约：subtitleSourceDecision.policyBoost / sourceKindRank）

    static func policyBoost(_ kind: SubtitleSourceKind, _ policy: SubtitleSourcePolicy) -> Double {
        switch policy {
        case .autoBest:
            return 0
        case .preferPlatform:
            return isPlatform(kind) ? 12 : 0
        case .forcePlatform:
            return isPlatform(kind) ? 10_000 : -10_000
        case .preferLocalASR:
            return kind == .localASR ? 12 : 0
        case .forceLocalASR:
            return kind == .localASR ? 10_000 : -10_000
        case .compareLocalASR:
            return 0
        case .cloudASR:
            return kind == .cloudASR ? 10_000 : -10_000
        case .importedFile:
            return kind == .importedFile ? 10_000 : -10_000
        }
    }

    static func isPlatform(_ kind: SubtitleSourceKind) -> Bool {
        kind == .manual || kind == .platformAuto || kind == .hlsManifest
    }

    static func sourceKindRank(_ kind: SubtitleSourceKind) -> Int {
        switch kind {
        case .manual: return 0
        case .importedFile: return 1
        case .hlsManifest: return 2
        case .platformAuto: return 3
        case .cloudASR: return 4
        case .localASR: return 5
        }
    }
}
