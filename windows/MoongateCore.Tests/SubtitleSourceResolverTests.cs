using Moongate.Core;

namespace MoongateCore.Tests;

public sealed class SubtitleSourceResolverTests : IDisposable
{
    private readonly string _directory = Path.Combine(Path.GetTempPath(), "mg-subtitle-resolver-" + Guid.NewGuid().ToString("N"));

    public SubtitleSourceResolverTests()
    {
        Directory.CreateDirectory(_directory);
    }

    public void Dispose()
    {
        try { Directory.Delete(_directory, recursive: true); } catch { /* ignore */ }
    }

    [Fact]
    public void QualityScorerPenalizesCjkHallucinationLikePhrases()
    {
        var file = WriteSrt("bad.ja.srt",
        [
            Cue(1, 0, 2, "世界の銀行が崩れた"),
            Cue(2, 3, 5, "冥府より現れしいお酒"),
            Cue(3, 6, 8, "偉いドクネストレード"),
            Cue(4, 9, 11, "チョコナナナ"),
            Cue(5, 12, 14, "くじ引き野郎"),
        ]);

        var score = SubtitleQualityScorer.Score(
            Candidate("bad", SubtitleSourceKind.PlatformAuto, file),
            "ja",
            60);

        Assert.True(score.Score < 55, $"Expected low score, got {score.Score}");
        Assert.True((int)score.Verdict <= (int)SubtitleQualityVerdict.LowConfidence);
        Assert.Contains("hallucinationLikePhrase", score.Reasons);
        Assert.Contains("shortCueFragmentation", score.Reasons);
    }

    [Fact]
    public void ResolverReportsLowConfidenceWhenAllCandidatesAreBad()
    {
        var platform = WriteSrt("platform.ja.srt",
        [
            Cue(1, 0, 2, "世界の銀行が崩れた"),
            Cue(2, 3, 5, "冥府より現れしいお酒"),
            Cue(3, 6, 8, "チョコナナナ"),
            Cue(4, 9, 11, "くじ引き野郎"),
        ]);
        var local = WriteSrt("local.ja.srt",
        [
            Cue(1, 0, 2, "チョコナナナ"),
            Cue(2, 3, 5, "くじ引き野郎"),
            Cue(3, 6, 8, "世界の銀行が崩れた"),
            Cue(4, 9, 11, "冥府より現れしいお酒"),
        ]);

        var resolved = SubtitleSourceResolver.Resolve(new SubtitleResolutionRequest(
            SourceLanguageIntent.Language("ja"),
            SubtitleSourcePolicy.AutoBest,
            [
                Candidate("platform", SubtitleSourceKind.PlatformAuto, platform),
                Candidate("local", SubtitleSourceKind.LocalAsr, local),
            ],
            60));

        Assert.NotNull(resolved);
        Assert.True((int)(resolved.SourceQualityVerdict ?? SubtitleQualityVerdict.Excellent)
            <= (int)SubtitleQualityVerdict.LowConfidence);
        Assert.All(resolved.CandidateReports, report =>
            Assert.True((int)report.QualityVerdict <= (int)SubtitleQualityVerdict.LowConfidence));
    }

    private string WriteSrt(string name, IEnumerable<SubtitleCue> cues)
    {
        var path = Path.Combine(_directory, name);
        File.WriteAllText(path, SrtTools.SerializeSrt(cues));
        return path;
    }

    private static SubtitleCue Cue(int index, double start, double end, string text) =>
        new(index, SrtTools.SecondsToSrtTime(start), SrtTools.SecondsToSrtTime(end), text, []);

    private static SubtitleSourceCandidate Candidate(string id, SubtitleSourceKind kind, string path) =>
        new(id, kind, "ja", Path.GetFileName(path), path, kind is SubtitleSourceKind.LocalAsr, null);
}
