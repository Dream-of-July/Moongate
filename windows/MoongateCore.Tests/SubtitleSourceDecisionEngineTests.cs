using Moongate.Core;

namespace MoongateCore.Tests;

public sealed class SubtitleSourceDecisionEngineTests : IDisposable
{
    private readonly string _directory = Path.Combine(Path.GetTempPath(), "mg-engine-" + Guid.NewGuid().ToString("N"));

    public SubtitleSourceDecisionEngineTests() => Directory.CreateDirectory(_directory);

    public void Dispose()
    {
        try { Directory.Delete(_directory, recursive: true); } catch { /* ignore */ }
    }

    private static SubtitleSourceDecisionEngine.Assessment Assessment(
        SubtitleSourceKind kind,
        double score,
        bool gateUsable,
        SubtitleQualityVerdict verdict,
        string id = "c",
        bool hasFile = true) =>
        new(id, kind, "ja", score, verdict, gateUsable,
            gateUsable ? [] : [PlatformSubtitleQualityGate.Reason.TooFewCues],
            [], null, hasFile);

    // ---- generationPlan: gate-only, no conflation ----

    [Fact]
    public void AutoBestKeepsHealthyPlatformWithoutGenerating()
    {
        var platform = Assessment(SubtitleSourceKind.PlatformAuto, 75, true, SubtitleQualityVerdict.Good);
        var plan = SubtitleSourceDecisionEngine.GenerationPlan(SubtitleSourcePolicy.AutoBest, platform, true, true);
        Assert.Equal(SubtitleSourceDecisionEngine.AsrPlanKind.None, plan.Kind);
    }

    [Fact]
    public void AutoBestRegeneratesWhenGateUnusableAndLocalAvailable()
    {
        var platform = Assessment(SubtitleSourceKind.PlatformAuto, 30, false, SubtitleQualityVerdict.Unusable);
        var plan = SubtitleSourceDecisionEngine.GenerationPlan(SubtitleSourcePolicy.AutoBest, platform, true, false);
        Assert.Equal(SubtitleSourceDecisionEngine.AsrPlanKind.GenerateLocalAsrThenChoose, plan.Kind);
    }

    [Fact]
    public void AutoBestKeepsPlatformWithReasonsWhenNoGenerator()
    {
        var platform = Assessment(SubtitleSourceKind.PlatformAuto, 30, false, SubtitleQualityVerdict.Unusable);
        var plan = SubtitleSourceDecisionEngine.GenerationPlan(SubtitleSourcePolicy.AutoBest, platform, false, false);
        Assert.Equal(SubtitleSourceDecisionEngine.AsrPlanKind.KeepPlatformRecordReasons, plan.Kind);
        Assert.Contains(PlatformSubtitleQualityGate.Reason.TooFewCues, plan.Reasons);
    }

    [Fact]
    public void AutoBestRegeneratesWhenGateUsableButVerdictBelowFloor()
    {
        var platform = Assessment(SubtitleSourceKind.PlatformAuto, 45, true, SubtitleQualityVerdict.LowConfidence);
        var plan = SubtitleSourceDecisionEngine.GenerationPlan(SubtitleSourcePolicy.AutoBest, platform, true, false);
        Assert.Equal(SubtitleSourceDecisionEngine.AsrPlanKind.GenerateLocalAsrThenChoose, plan.Kind);
    }

    [Fact]
    public void AutoBestDoesNotRegenerateWhenUsableVerdict()
    {
        var platform = Assessment(SubtitleSourceKind.PlatformAuto, 60, true, SubtitleQualityVerdict.Usable);
        var plan = SubtitleSourceDecisionEngine.GenerationPlan(SubtitleSourcePolicy.AutoBest, platform, true, false);
        Assert.Equal(SubtitleSourceDecisionEngine.AsrPlanKind.None, plan.Kind);
    }

    [Theory]
    [InlineData(SubtitleSourcePolicy.ForcePlatform)]
    [InlineData(SubtitleSourcePolicy.PreferPlatform)]
    [InlineData(SubtitleSourcePolicy.CloudAsr)]
    [InlineData(SubtitleSourcePolicy.ImportedFile)]
    public void PlatformPoliciesNeverGenerate(SubtitleSourcePolicy policy)
    {
        var platform = Assessment(SubtitleSourceKind.PlatformAuto, 30, false, SubtitleQualityVerdict.Unusable);
        var plan = SubtitleSourceDecisionEngine.GenerationPlan(policy, platform, true, true);
        Assert.Equal(SubtitleSourceDecisionEngine.AsrPlanKind.None, plan.Kind);
    }

    [Fact]
    public void ForceLocalAsrAlwaysGenerates()
    {
        var platform = Assessment(SubtitleSourceKind.PlatformAuto, 90, true, SubtitleQualityVerdict.Excellent);
        var plan = SubtitleSourceDecisionEngine.GenerationPlan(SubtitleSourcePolicy.ForceLocalAsr, platform, true, false);
        Assert.Equal(SubtitleSourceDecisionEngine.AsrPlanKind.GenerateLocalAsrThenChoose, plan.Kind);
    }

    [Fact]
    public void PreferLocalAsrGeneratesOnlyWhenPlatformUnusable()
    {
        var healthy = Assessment(SubtitleSourceKind.PlatformAuto, 80, true, SubtitleQualityVerdict.Good);
        Assert.Equal(SubtitleSourceDecisionEngine.AsrPlanKind.None,
            SubtitleSourceDecisionEngine.GenerationPlan(SubtitleSourcePolicy.PreferLocalAsr, healthy, true, false).Kind);
        var bad = Assessment(SubtitleSourceKind.PlatformAuto, 30, false, SubtitleQualityVerdict.Unusable);
        Assert.Equal(SubtitleSourceDecisionEngine.AsrPlanKind.GenerateLocalAsrThenChoose,
            SubtitleSourceDecisionEngine.GenerationPlan(SubtitleSourcePolicy.PreferLocalAsr, bad, true, false).Kind);
    }

    // ---- post-generation local ASR escalation ----

    [Fact]
    public void AutoBestEscalatesGeneratedLocalAsrWhenLocalAssessmentBelowUsable()
    {
        var local = Assessment(SubtitleSourceKind.LocalAsr, 40, false, SubtitleQualityVerdict.LowConfidence);

        Assert.True(SubtitleSourceDecisionEngine.ShouldEscalateGeneratedLocalAsr(
            SubtitleSourcePolicy.AutoBest,
            local,
            localAsrConfidenceIsLowQuality: false,
            cloudAsrAvailable: true));
    }

    [Fact]
    public void AutoBestEscalatesGeneratedLocalAsrWhenConfidenceIsLowQuality()
    {
        var local = Assessment(SubtitleSourceKind.LocalAsr, 80, true, SubtitleQualityVerdict.Good);

        Assert.True(SubtitleSourceDecisionEngine.ShouldEscalateGeneratedLocalAsr(
            SubtitleSourcePolicy.AutoBest,
            local,
            localAsrConfidenceIsLowQuality: true,
            cloudAsrAvailable: true));
    }

    [Fact]
    public void AutoBestEscalatesGeneratedLocalAsrWhenScoredSubtitleContentFallsBelowUsable()
    {
        var path = WriteTimedSrt(
            "local-asr.ja.srt",
            Enumerable.Range(0, 12)
                .Select(index => ($"作詞・作曲・編曲 初音ミク {index}", index * 14.0, index * 14.0 + 13.0))
                .ToArray());
        var local = SubtitleSourceDecisionEngine.Assess(
            new SubtitleSourceCandidate("l", SubtitleSourceKind.LocalAsr, "ja", "L", path, true, "whisper.cpp"),
            "ja", null);

        Assert.True(local.Verdict < SubtitleQualityVerdict.Usable);
        Assert.True(SubtitleSourceDecisionEngine.ShouldEscalateGeneratedLocalAsr(
            SubtitleSourcePolicy.AutoBest,
            local,
            localAsrConfidenceIsLowQuality: false,
            cloudAsrAvailable: true));
    }

    [Fact]
    public void GeneratedLocalAsrEscalationRespectsPolicyAndCloudAvailability()
    {
        var lowQualityLocal = Assessment(SubtitleSourceKind.LocalAsr, 40, false, SubtitleQualityVerdict.LowConfidence);

        Assert.False(SubtitleSourceDecisionEngine.ShouldEscalateGeneratedLocalAsr(
            SubtitleSourcePolicy.PreferLocalAsr,
            lowQualityLocal,
            localAsrConfidenceIsLowQuality: true,
            cloudAsrAvailable: true));
        Assert.False(SubtitleSourceDecisionEngine.ShouldEscalateGeneratedLocalAsr(
            SubtitleSourcePolicy.AutoBest,
            lowQualityLocal,
            localAsrConfidenceIsLowQuality: true,
            cloudAsrAvailable: false));
    }

    [Fact]
    public void GeneratedLocalAsrDoesNotEscalateHealthyLocalResult()
    {
        var healthyLocal = Assessment(SubtitleSourceKind.LocalAsr, 80, true, SubtitleQualityVerdict.Good);

        Assert.False(SubtitleSourceDecisionEngine.ShouldEscalateGeneratedLocalAsr(
            SubtitleSourcePolicy.AutoBest,
            healthyLocal,
            localAsrConfidenceIsLowQuality: false,
            cloudAsrAvailable: true));
    }

    // ---- choose: tie-break prefers more-trusted source ----

    [Fact]
    public void ChooseTieBreakPrefersLowerSourceKindRank()
    {
        var manual = Assessment(SubtitleSourceKind.Manual, 70, true, SubtitleQualityVerdict.Good, "m");
        var local = Assessment(SubtitleSourceKind.LocalAsr, 70, true, SubtitleQualityVerdict.Good, "l");
        Assert.Equal("m", SubtitleSourceDecisionEngine.Choose(
            SubtitleSourcePolicy.AutoBest, [manual, local], new HashSet<string> { "m", "l" }));
        Assert.Equal("m", SubtitleSourceDecisionEngine.Choose(
            SubtitleSourcePolicy.AutoBest, [local, manual], new HashSet<string> { "m", "l" }));
    }

    [Fact]
    public void ChooseAutoBestPicksHigherScore()
    {
        var manual = Assessment(SubtitleSourceKind.Manual, 60, true, SubtitleQualityVerdict.Usable, "m");
        var local = Assessment(SubtitleSourceKind.LocalAsr, 80, true, SubtitleQualityVerdict.Good, "l");
        Assert.Equal("l", SubtitleSourceDecisionEngine.Choose(
            SubtitleSourcePolicy.AutoBest, [manual, local], new HashSet<string> { "m", "l" }));
    }

    [Fact]
    public void ChooseForcePlatformPicksPlatformEvenWhenLocalScoresHigher()
    {
        var platform = Assessment(SubtitleSourceKind.PlatformAuto, 55, true, SubtitleQualityVerdict.Usable, "p");
        var local = Assessment(SubtitleSourceKind.LocalAsr, 95, true, SubtitleQualityVerdict.Excellent, "l");
        Assert.Equal("p", SubtitleSourceDecisionEngine.Choose(
            SubtitleSourcePolicy.ForcePlatform, [platform, local], new HashSet<string> { "p", "l" }));
    }

    [Fact]
    public void ChooseSkipsNonSelectableCandidates()
    {
        var pending = Assessment(SubtitleSourceKind.LocalAsr, 0, false, SubtitleQualityVerdict.Unusable, "pending", hasFile: false);
        var platform = Assessment(SubtitleSourceKind.PlatformAuto, 60, true, SubtitleQualityVerdict.Usable, "p");
        Assert.Equal("p", SubtitleSourceDecisionEngine.Choose(
            SubtitleSourcePolicy.AutoBest, [pending, platform], new HashSet<string> { "p" }));
    }

    // ---- assess: one gate run, authoritative gateUsable ----

    [Fact]
    public void AssessHealthyJapaneseIsGateUsable()
    {
        var path = WriteSrt("local-asr.ja.srt", new[]
        {
            "今日は楽しいお祭りの日です", "みんなでチョコバナナを食べよう", "ソースせんべいも買ってきたよ",
            "お風呂はとても気持ちいいね", "ありがとうと言われるとうれしい", "風が涼しくて気持ちいい",
            "友だちと一緒に歩いている", "次はくじ引きをやってみよう", "小さな声でもちゃんと聞こえる", "また明日も遊びに来よう",
        });
        var assessment = SubtitleSourceDecisionEngine.Assess(
            new SubtitleSourceCandidate("l", SubtitleSourceKind.LocalAsr, "ja", "L", path, true, "whisper.cpp"),
            "ja", null);
        Assert.True(assessment.GateUsable);
        Assert.Empty(assessment.GateReasons);
        Assert.True(assessment.Verdict >= SubtitleQualityVerdict.Usable);
    }

    [Fact]
    public void AssessTooFewCuesIsGateUnusable()
    {
        var path = WriteSrt("auto.ja.srt", new[] { "短い", "字幕", "です" });
        var assessment = SubtitleSourceDecisionEngine.Assess(
            new SubtitleSourceCandidate("p", SubtitleSourceKind.PlatformAuto, "ja", "P", path, true, "yt-dlp"),
            "ja", null);
        Assert.False(assessment.GateUsable);
        Assert.Contains(PlatformSubtitleQualityGate.Reason.TooFewCues, assessment.GateReasons);
        Assert.True(assessment.Verdict <= SubtitleQualityVerdict.LowConfidence);
    }

    [Fact]
    public void AssessMissingFileIsGateUnusable()
    {
        var assessment = SubtitleSourceDecisionEngine.Assess(
            new SubtitleSourceCandidate("pending", SubtitleSourceKind.LocalAsr, "ja", "L", null, false, "whisper.cpp"),
            "ja", null);
        Assert.False(assessment.GateUsable);
        Assert.False(assessment.HasFile);
    }

    private string WriteSrt(string name, IReadOnlyList<string> texts)
    {
        return WriteTimedSrt(
            name,
            texts.Select((text, index) => (text, index * 2.0, index * 2.0 + 1.5)).ToArray());
    }

    private string WriteTimedSrt(string name, IReadOnlyList<(string Text, double Start, double End)> cues)
    {
        var srtCues = cues.Select((cue, index) =>
            new SubtitleCue(index + 1,
                SrtTools.SecondsToSrtTime(cue.Start),
                SrtTools.SecondsToSrtTime(cue.End),
                cue.Text, [])).ToArray();
        var path = Path.Combine(_directory, name);
        File.WriteAllText(path, SrtTools.SerializeSrt(srtCues));
        return path;
    }
}
