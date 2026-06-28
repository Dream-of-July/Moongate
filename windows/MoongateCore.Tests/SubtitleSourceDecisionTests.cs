using Moongate.Core;

namespace Moongate.Core.Tests;

public class SubtitleSourceDecisionTests
{
    [Fact]
    public void MkbhdMetadataChoosesManualEnglishAndNeverRunsAsr()
    {
        var report = SubtitleSourceDecision.Decide(
            videoTitle: "Top 5 Android 17 Features: I Swear It's New!",
            detectedLanguageCode: "en",
            targetLanguageCode: "zh-Hans",
            preferredSourceLanguageCode: null,
            sourcePolicy: SubtitleSourcePolicy.AutoBest,
            choices:
            [
                Auto("en"),
                Auto("en-orig", "orig"),
                Manual("en"),
                Manual("ja"),
                Local("en"),
            ],
            localAsrAvailable: true,
            cloudAsrAvailable: false);

        Assert.Equal(SubtitleSourceKind.Manual, report.SelectedTrack?.SourceKind);
        Assert.Equal("en", report.SelectedTrack?.LanguageCode);
        Assert.Equal(SubtitleAsrTrigger.Never, report.AsrTrigger);
        Assert.Equal(SubtitleSourceDecisionReason.ManualMatchesVideoLanguage, report.UserFacingReason);
        Assert.Contains(report.CandidateReports, r => r.SourceKind == SubtitleSourceKind.PlatformAuto && r.Status == SubtitleSourceDecisionCandidateStatus.Backup);
        Assert.Contains(report.CandidateReports, r => r.SourceKind == SubtitleSourceKind.LocalAsr && r.Status == SubtitleSourceDecisionCandidateStatus.Backup);
    }

    [Fact]
    public void ForeignManualSubtitleDoesNotBeatDetectedEnglishPlatformSubtitle()
    {
        var report = SubtitleSourceDecision.Decide(
            videoTitle: "The Weird Future Of User Interfaces",
            detectedLanguageCode: "en",
            targetLanguageCode: "zh-Hans",
            preferredSourceLanguageCode: null,
            sourcePolicy: SubtitleSourcePolicy.AutoBest,
            choices:
            [
                Manual("tlh"),
                Auto("en"),
                Auto("en-orig", "orig"),
                Local("en"),
            ],
            localAsrAvailable: true,
            cloudAsrAvailable: false);

        Assert.Equal(SubtitleSourceKind.PlatformAuto, report.SelectedTrack?.SourceKind);
        Assert.Equal("en-orig", report.SelectedTrack?.LanguageCode);
        Assert.Equal(SubtitleAsrTrigger.FallbackOnly, report.AsrTrigger);
        Assert.Equal(SubtitleSourceDecisionReason.PlatformAutoMatchesVideoLanguage, report.UserFacingReason);
        Assert.Contains(report.CandidateReports, r =>
            r.LanguageCode == "tlh"
            && r.Status == SubtitleSourceDecisionCandidateStatus.NotUsed
            && r.Reason == SubtitleSourceDecisionReason.ManualLanguageMismatch);
    }

    [Fact]
    public void TargetLanguageManualSubtitleDoesNotBecomeTranslationSource()
    {
        var report = SubtitleSourceDecision.Decide(
            videoTitle: "日本語インタビュー",
            detectedLanguageCode: "ja",
            targetLanguageCode: "zh-Hans",
            preferredSourceLanguageCode: null,
            sourcePolicy: SubtitleSourcePolicy.AutoBest,
            choices:
            [
                Manual("zh-Hans"),
                Auto("ja"),
                Local("ja"),
            ],
            localAsrAvailable: true,
            cloudAsrAvailable: false);

        Assert.Equal(SubtitleSourceKind.PlatformAuto, report.SelectedTrack?.SourceKind);
        Assert.Equal("ja", report.SelectedTrack?.LanguageCode);
        Assert.Contains(report.CandidateReports, r =>
            r.LanguageCode == "zh-Hans"
            && r.Status == SubtitleSourceDecisionCandidateStatus.NotUsed
            && r.Reason == SubtitleSourceDecisionReason.TargetLanguageSubtitleNotSource);
    }

    [Fact]
    public void ExplicitCompareAndForceLocalAsrAreSeparateTriggers()
    {
        var compare = SubtitleSourceDecision.Decide(
            "How transformers actually work",
            "en",
            "zh-Hans",
            null,
            SubtitleSourcePolicy.CompareLocalAsr,
            [Auto("en"), Local("en")],
            localAsrAvailable: true,
            cloudAsrAvailable: false);
        var force = SubtitleSourceDecision.Decide(
            "How transformers actually work",
            "en",
            "zh-Hans",
            null,
            SubtitleSourcePolicy.ForceLocalAsr,
            [Manual("en"), Local("en")],
            localAsrAvailable: true,
            cloudAsrAvailable: false);

        Assert.Equal(SubtitleSourceKind.PlatformAuto, compare.SelectedTrack?.SourceKind);
        Assert.Equal(SubtitleAsrTrigger.ExplicitCompare, compare.AsrTrigger);
        Assert.Equal(SubtitleSourceKind.LocalAsr, force.SelectedTrack?.SourceKind);
        Assert.Equal(SubtitleAsrTrigger.ExplicitForce, force.AsrTrigger);
    }

    private static SubtitleChoice Manual(string code) =>
        SubtitleChoice.Create(code, code, SubtitleSourceKind.Manual);

    private static SubtitleChoice Auto(string code, string? variant = null) =>
        SubtitleChoice.Create(code, code, SubtitleSourceKind.PlatformAuto, variant: variant);

    private static SubtitleChoice Local(string code) =>
        SubtitleChoice.Create(code, code, SubtitleSourceKind.LocalAsr, provider: "whisper.cpp", variant: "local");
}
