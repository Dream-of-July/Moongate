namespace Moongate.Core;

/// <summary>
/// 统一的字幕源决策权威（C# 镜像 Swift `SubtitleSourceDecisionEngine`）。把"质量评估(门每候选只跑一次) +
/// 是否生成 Whisper 的计划 + 多候选择优(tie-break)"收敛到单一处，供下载后执行（SubtitleSourceResolver /
/// Queue）共享同一套规则，消除"门(布尔) || 评分器(枚举)"双裁决叠加与门被多次跑的问题。
///
/// 反冲突契约：门 <c>GateUsable</c> 只答"这个候选自身是否可用"，是"是否生成 Whisper"的唯一依据，绝不看时序、
/// 绝不跨源比较；<c>Score</c>/<c>Verdict</c> 只答"真实候选里谁更好"，用于排名与 tie-break。
/// </summary>
public static class SubtitleSourceDecisionEngine
{
    /// <summary>单候选评估：对一个候选只跑一次门（经 SubtitleQualityScorer 内部），暴露门权威裁决与排名分数。</summary>
    public sealed record Assessment(
        string CandidateId,
        SubtitleSourceKind Kind,
        string LanguageCode,
        double Score,
        SubtitleQualityVerdict Verdict,
        bool GateUsable,
        IReadOnlyList<PlatformSubtitleQualityGate.Reason> GateReasons,
        IReadOnlyList<string> Reasons,
        PlatformSubtitleQualityGate.SubtitleSourceQualityReport? Report,
        bool HasFile);

    public enum AsrPlanKind
    {
        /// <summary>直接用当前平台/人工/导入源，无需生成。</summary>
        None,
        /// <summary>生成 Whisper，再让引擎在平台源与本地源之间择优。</summary>
        GenerateLocalAsrThenChoose,
        /// <summary>平台不可用且无生成器：沿用平台源、记录原因给 UI 提示（不阻塞）。</summary>
        KeepPlatformRecordReasons,
    }

    public sealed record AsrPlan(AsrPlanKind Kind, IReadOnlyList<PlatformSubtitleQualityGate.Reason> Reasons);

    /// <summary>
    /// `.autoBest` 下，平台自动字幕 verdict 低于此档（即 LowConfidence/Unusable）时也重生成。这是把原本散落在
    /// Queue 的 <c>|| platformScore.Verdict &lt;= LowConfidence</c> 收敛为具名、可测、单类型的质量地板。
    /// </summary>
    public const SubtitleQualityVerdict AutoBestRegenerateBelow = SubtitleQualityVerdict.Usable;

    public static Assessment Assess(
        SubtitleSourceCandidate candidate,
        string? requestedSourceLanguageCode,
        double? videoDurationSeconds)
    {
        var score = SubtitleQualityScorer.Score(candidate, requestedSourceLanguageCode, videoDurationSeconds);
        return new Assessment(
            score.CandidateId,
            score.Kind,
            score.LanguageCode,
            score.Score,
            score.Verdict,
            score.GateUsable,
            score.GateReasons ?? [],
            score.Reasons,
            score.Report,
            !string.IsNullOrWhiteSpace(candidate.FilePath) && File.Exists(candidate.FilePath));
    }

    public static AsrPlan GenerationPlan(
        SubtitleSourcePolicy policy,
        Assessment? platform,
        bool localAsrAvailable,
        bool cloudAsrAvailable)
    {
        switch (policy)
        {
            case SubtitleSourcePolicy.ForcePlatform:
            case SubtitleSourcePolicy.PreferPlatform:
            case SubtitleSourcePolicy.CloudAsr:
            case SubtitleSourcePolicy.ImportedFile:
                return new AsrPlan(AsrPlanKind.None, []);
            case SubtitleSourcePolicy.ForceLocalAsr:
            case SubtitleSourcePolicy.CompareLocalAsr:
                return localAsrAvailable
                    ? new AsrPlan(AsrPlanKind.GenerateLocalAsrThenChoose, [])
                    : NoGenerator(platform);
            case SubtitleSourcePolicy.PreferLocalAsr:
                if (platform is null)
                {
                    return localAsrAvailable
                        ? new AsrPlan(AsrPlanKind.GenerateLocalAsrThenChoose, [])
                        : new AsrPlan(AsrPlanKind.None, []);
                }
                if (platform.GateUsable) return new AsrPlan(AsrPlanKind.None, []);
                return localAsrAvailable
                    ? new AsrPlan(AsrPlanKind.GenerateLocalAsrThenChoose, [])
                    : NoGenerator(platform);
            case SubtitleSourcePolicy.AutoBest:
            default:
                if (platform is null) return new AsrPlan(AsrPlanKind.None, []);
                var needsRegen = !platform.GateUsable || platform.Verdict < AutoBestRegenerateBelow;
                if (!needsRegen) return new AsrPlan(AsrPlanKind.None, []);
                return localAsrAvailable
                    ? new AsrPlan(AsrPlanKind.GenerateLocalAsrThenChoose, [])
                    : NoGenerator(platform);
        }
    }

    private static AsrPlan NoGenerator(Assessment? platform) =>
        new(AsrPlanKind.KeepPlatformRecordReasons, platform?.GateReasons ?? []);

    /// <summary>
    /// Local ASR has already been generated; decide whether an opt-in cloud recognizer should rescue it.
    /// This keeps the existing confidence-based path and also routes the generated local SRT through the
    /// same quality gate so obviously unusable Whisper output is not silently kept as a comparable source.
    /// </summary>
    public static bool ShouldEscalateGeneratedLocalAsr(
        SubtitleSourcePolicy policy,
        Assessment? localAssessment,
        bool localAsrConfidenceIsLowQuality,
        bool cloudAsrAvailable)
    {
        if (policy != SubtitleSourcePolicy.AutoBest || !cloudAsrAvailable) return false;
        if (localAsrConfidenceIsLowQuality) return true;
        return localAssessment is not null
            && (!localAssessment.GateUsable || localAssessment.Verdict < AutoBestRegenerateBelow);
    }

    /// <summary>
    /// 在已评估候选中按 Score + PolicyBoost 选最优；平分取更可信来源（更小 SourceKindRank）。
    /// 只在 selectableIds（有文件的候选）里选。无可选时返回 null。
    /// </summary>
    public static string? Choose(
        SubtitleSourcePolicy policy,
        IReadOnlyList<Assessment> assessments,
        ISet<string> selectableIds)
    {
        var selectable = assessments.Where(a => selectableIds.Contains(a.CandidateId)).ToArray();
        if (selectable.Length == 0) return null;
        return selectable
            .OrderByDescending(a => a.Score + PolicyBoost(a.Kind, policy))
            .ThenBy(a => SourceKindRank(a.Kind))
            .First()
            .CandidateId;
    }

    internal static double PolicyBoost(SubtitleSourceKind kind, SubtitleSourcePolicy policy) => policy switch
    {
        SubtitleSourcePolicy.AutoBest => 0,
        SubtitleSourcePolicy.PreferPlatform => IsPlatform(kind) ? 12 : 0,
        SubtitleSourcePolicy.ForcePlatform => IsPlatform(kind) ? 10_000 : -10_000,
        SubtitleSourcePolicy.PreferLocalAsr => kind == SubtitleSourceKind.LocalAsr ? 12 : 0,
        SubtitleSourcePolicy.ForceLocalAsr => kind == SubtitleSourceKind.LocalAsr ? 10_000 : -10_000,
        SubtitleSourcePolicy.CompareLocalAsr => 0,
        SubtitleSourcePolicy.CloudAsr => kind == SubtitleSourceKind.CloudAsr ? 10_000 : -10_000,
        SubtitleSourcePolicy.ImportedFile => kind == SubtitleSourceKind.ImportedFile ? 10_000 : -10_000,
        _ => 0,
    };

    internal static bool IsPlatform(SubtitleSourceKind kind) =>
        kind is SubtitleSourceKind.Manual or SubtitleSourceKind.PlatformAuto or SubtitleSourceKind.HlsManifest;

    internal static int SourceKindRank(SubtitleSourceKind kind) => kind switch
    {
        SubtitleSourceKind.Manual => 0,
        SubtitleSourceKind.ImportedFile => 1,
        SubtitleSourceKind.HlsManifest => 2,
        SubtitleSourceKind.PlatformAuto => 3,
        SubtitleSourceKind.CloudAsr => 4,
        SubtitleSourceKind.LocalAsr => 5,
        _ => 6,
    };
}
