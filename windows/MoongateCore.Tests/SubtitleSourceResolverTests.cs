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
    public void QualityScorerPenalizesCjkShortCueFragmentationWithoutHardcodedPhrases()
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
        Assert.Contains("shortCueFragmentation", score.Reasons);
    }

    [Fact]
    public void NilLocalAsrCandidateIsNotUsable()
    {
        var score = SubtitleQualityScorer.Score(
            new SubtitleSourceCandidate(
                "pending-local",
                SubtitleSourceKind.LocalAsr,
                "en",
                "Local recognition",
                null,
                false,
                "whisper.cpp"),
            "en",
            null);

        Assert.Equal(0, score.Score);
        Assert.Equal(SubtitleQualityVerdict.Unusable, score.Verdict);
        Assert.Contains("pendingGeneration", score.Reasons);
        Assert.DoesNotContain("notGeneratedYet", score.Reasons);
    }

    [Fact]
    public void LocalAsrDetectsLongCjkShortCueHolds()
    {
        var file = WriteSrt("blackpink.long-hold.local-asr.ko.srt",
        [
            Cue(1, 1.91, 5.06, "착"),
            Cue(2, 5.34, 10.16, "한"),
            Cue(3, 10.44, 12.10, "얼굴에"),
            Cue(4, 12.50, 14.00, "그렇지 못한대도"),
            Cue(5, 14.20, 15.70, "volume은 두 배로"),
            Cue(6, 16.00, 17.50, "거침없이 직진"),
            Cue(7, 17.80, 19.30, "나는 믿고 있어"),
            Cue(8, 19.60, 21.10, "지금 이 순간"),
        ]);

        var score = SubtitleQualityScorer.Score(
            new SubtitleSourceCandidate(
                "local-ko",
                SubtitleSourceKind.LocalAsr,
                "ko",
                "Local Korean",
                file,
                true,
                "whisper.cpp"),
            "ko",
            null);

        Assert.True((int)score.Verdict <= (int)SubtitleQualityVerdict.LowConfidence);
        Assert.Contains("longShortCueHold", score.Reasons);
    }

    [Fact]
    public void ResolverNeverReturnsEmptySelectedFileForMissingCandidate()
    {
        var resolved = SubtitleSourceResolver.Resolve(new SubtitleResolutionRequest(
            SourceLanguageIntent.Language("en"),
            SubtitleSourcePolicy.AutoBest,
            [
                new SubtitleSourceCandidate(
                    "pending-local",
                    SubtitleSourceKind.LocalAsr,
                    "en",
                    "Local recognition",
                    null,
                    false,
                    "whisper.cpp"),
            ],
            null));

        Assert.Null(resolved);
    }

    [Fact]
    public void ProductionScorerDoesNotHardcodeObservedBadSamplePhrases()
    {
        var source = File.ReadAllText(Path.Combine(
            SubtitleLanguageRecommenderTests.RepoRoot(),
            "windows",
            "MoongateCore",
            "SubtitleSourceResolver.cs"));
        foreach (var phrase in new[]
        {
            "世界の銀行が崩れた",
            "冥府より現れしいお酒",
            "偉いドクネストレード",
            "チョコナナナ",
            "ソスせんべい",
            "くじ引き野郎",
            "あいい行く",
        })
        {
            Assert.DoesNotContain(phrase, source);
        }
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
