using System.Text;

namespace Moongate.Core;

public enum SubtitleQualityVerdict
{
    Unusable,
    LowConfidence,
    Usable,
    Good,
    Excellent,
}

public sealed record SubtitleSourceCandidate(
    string Id,
    SubtitleSourceKind Kind,
    string LanguageCode,
    string DisplayName,
    string? FilePath,
    bool IsGenerated,
    string? Provider);

public sealed record SubtitleSourceScore(
    string CandidateId,
    SubtitleSourceKind Kind,
    string LanguageCode,
    double Score,
    SubtitleQualityVerdict Verdict,
    IReadOnlyList<string> Reasons,
    PlatformSubtitleQualityGate.SubtitleSourceQualityReport? Report);

public sealed record SubtitleResolutionRequest(
    SourceLanguageIntent LanguageIntent,
    SubtitleSourcePolicy SourcePolicy,
    IReadOnlyList<SubtitleSourceCandidate> Candidates,
    double? VideoDurationSeconds);

public static class SubtitleQualityScorer
{
    public static SubtitleSourceScore Score(
        SubtitleSourceCandidate candidate,
        string? requestedLanguageCode,
        double? videoDurationSeconds)
    {
        if (string.IsNullOrWhiteSpace(candidate.FilePath) || !File.Exists(candidate.FilePath))
        {
            var generated = candidate.Kind is SubtitleSourceKind.LocalAsr or SubtitleSourceKind.CloudAsr;
            return new SubtitleSourceScore(
                candidate.Id,
                candidate.Kind,
                NormalizeLanguage(candidate.LanguageCode),
                generated ? 45 : 0,
                generated ? SubtitleQualityVerdict.Usable : SubtitleQualityVerdict.Unusable,
                generated ? ["notGeneratedYet"] : ["missingFile"],
                null);
        }

        var raw = File.ReadAllText(candidate.FilePath);
        var rawCues = SrtTools.ParseSubtitle(raw, candidate.FilePath);
        var cleaned = SrtTools.CleanCues(rawCues);
        var gate = PlatformSubtitleQualityGate.Assess(
            cleaned,
            requestedLanguageCode,
            candidate.LanguageCode,
            videoDurationSeconds);
        var rawReport = PlatformSubtitleQualityGate.QualityReport(
            rawCues,
            requestedLanguageCode,
            candidate.LanguageCode);
        var report = DiagnosticReport(gate.QualityReport, rawReport);
        var reasons = gate.Reasons.Select(ReasonCode).ToList();
        var extraReasons = ContentReasons(rawCues);
        var value = BaseScore(candidate.Kind);

        value += Math.Min(0.80, CoverageEstimate(gate.QualityReport)) * 25;
        value += Math.Min(1.0, gate.QualityReport.VisibleScalarCount / 1400.0) * 10;
        value += gate.QualityReport.UniqueCueTextRatio * 8;

        if (gate.Reasons.Contains(PlatformSubtitleQualityGate.Reason.LanguageMismatch)) value -= 80;
        if (gate.Reasons.Contains(PlatformSubtitleQualityGate.Reason.TooFewCues)) value -= 30;
        if (gate.Reasons.Contains(PlatformSubtitleQualityGate.Reason.LowCoverage)) value -= 25;
        if (gate.Reasons.Contains(PlatformSubtitleQualityGate.Reason.GarbledOrRepetitive)) value -= 35;
        if (SoundEffectDominated(rawReport) && !reasons.Contains("garbledOrRepetitive"))
        {
            value -= 35;
            reasons.Add("garbledOrRepetitive");
        }

        value -= Math.Min(25, report.SoundEffectCueRatio * 80);
        value -= Math.Min(20, report.LongCueRatio * 90);
        value -= Math.Min(25, report.AdjacentIdenticalRatio * 70);
        value -= Math.Min(20, report.BadScalarRatio * 200);
        value -= Math.Min(18, report.RomanizedLoopTokenRatio * 40);

        if (extraReasons.Contains("hallucinationLikePhrase")) value -= 45;
        if (extraReasons.Contains("shortCueFragmentation")) value -= 16;
        reasons.AddRange(extraReasons);

        var clamped = Math.Clamp(value, 0, 100);
        var verdict = VerdictFor(clamped);
        if (verdict == SubtitleQualityVerdict.LowConfidence) reasons.Add("lowConfidence");
        if (verdict == SubtitleQualityVerdict.Unusable) reasons.Add("unusable");

        return new SubtitleSourceScore(
            candidate.Id,
            candidate.Kind,
            NormalizeLanguage(candidate.LanguageCode),
            clamped,
            verdict,
            reasons.Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal).ToArray(),
            report);
    }

    private static double BaseScore(SubtitleSourceKind kind) => kind switch
    {
        SubtitleSourceKind.Manual => 85,
        SubtitleSourceKind.ImportedFile => 82,
        SubtitleSourceKind.HlsManifest => 76,
        SubtitleSourceKind.PlatformAuto => 58,
        SubtitleSourceKind.CloudAsr => 70,
        SubtitleSourceKind.LocalAsr => 50,
        _ => 0,
    };

    private static SubtitleQualityVerdict VerdictFor(double score)
    {
        if (score >= 85) return SubtitleQualityVerdict.Excellent;
        if (score >= 72) return SubtitleQualityVerdict.Good;
        if (score >= 55) return SubtitleQualityVerdict.Usable;
        if (score >= 35) return SubtitleQualityVerdict.LowConfidence;
        return SubtitleQualityVerdict.Unusable;
    }

    private static double CoverageEstimate(PlatformSubtitleQualityGate.SubtitleSourceQualityReport report)
    {
        if (report.CueCount == 0) return 0;
        var cueScore = Math.Min(1.0, report.CueCount / 80.0);
        var textScore = Math.Min(1.0, report.VisibleScalarCount / 1800.0);
        return cueScore * 0.45 + textScore * 0.55;
    }

    private static PlatformSubtitleQualityGate.SubtitleSourceQualityReport DiagnosticReport(
        PlatformSubtitleQualityGate.SubtitleSourceQualityReport cleaned,
        PlatformSubtitleQualityGate.SubtitleSourceQualityReport raw) =>
        new(
            Math.Max(cleaned.CueCount, raw.CueCount),
            cleaned.VisibleScalarCount,
            cleaned.CjkLanguage || raw.CjkLanguage,
            cleaned.CjkScalarRatio,
            cleaned.LatinScalarRatio,
            cleaned.AdjacentIdenticalRatio,
            cleaned.BadScalarRatio,
            cleaned.UniqueCueTextRatio,
            cleaned.RomanizedLoopTokenCount,
            cleaned.RomanizedLoopMaxRun,
            cleaned.RomanizedLoopTokenRatio,
            Math.Max(cleaned.SoundEffectCueCount, raw.SoundEffectCueCount),
            Math.Max(cleaned.SoundEffectCueRatio, raw.SoundEffectCueRatio),
            Math.Max(cleaned.SoundEffectDurationRatio, raw.SoundEffectDurationRatio),
            Math.Max(cleaned.LongCueCount, raw.LongCueCount),
            Math.Max(cleaned.LongCueRatio, raw.LongCueRatio),
            Math.Max(cleaned.MaxCueDuration, raw.MaxCueDuration));

    private static bool SoundEffectDominated(PlatformSubtitleQualityGate.SubtitleSourceQualityReport report)
    {
        if (report.SoundEffectCueCount >= PlatformSubtitleQualityGate.SoundEffectCueMinCount
            && report.SoundEffectCueRatio >= PlatformSubtitleQualityGate.SoundEffectCueRatioThreshold)
        {
            return true;
        }
        return report.SoundEffectCueCount >= PlatformSubtitleQualityGate.SoundEffectDurationMinCount
            && report.SoundEffectDurationRatio >= PlatformSubtitleQualityGate.SoundEffectDurationRatioThreshold;
    }

    private static IReadOnlyList<string> ContentReasons(IReadOnlyList<SubtitleCue> cues)
    {
        var reasons = new List<string>();
        var texts = cues.Select(cue => cue.Text.Trim()).ToArray();
        var joined = string.Join("\n", texts);
        string[] hallucinationLikePhrases =
        [
            "世界の銀行が崩れた",
            "冥府より現れしいお酒",
            "偉いドクネストレード",
            "ドクネストレード",
        ];
        if (hallucinationLikePhrases.Any(joined.Contains)) reasons.Add("hallucinationLikePhrase");

        var cjkShortCueCount = texts.Count(text =>
        {
            var visibleCount = text.EnumerateRunes().Count(rune => !Rune.IsWhiteSpace(rune));
            return visibleCount is > 0 and <= 6 && text.EnumerateRunes().Any(rune => IsCjkScalar(rune.Value));
        });
        string[] knownFragmentLikePhrases = ["チョコナナナ", "くじ引き野郎", "ソスせんべい", "あいい行く"];
        var hasKnownFragments = knownFragmentLikePhrases.Any(joined.Contains);
        if (texts.Length > 0 && ((double)cjkShortCueCount / texts.Length >= 0.35 || hasKnownFragments))
        {
            reasons.Add("shortCueFragmentation");
        }
        return reasons;
    }

    internal static string ReasonCode(PlatformSubtitleQualityGate.Reason reason) => reason switch
    {
        PlatformSubtitleQualityGate.Reason.LanguageMismatch => "languageMismatch",
        PlatformSubtitleQualityGate.Reason.TooFewCues => "tooFewCues",
        PlatformSubtitleQualityGate.Reason.LowCoverage => "lowCoverage",
        PlatformSubtitleQualityGate.Reason.GarbledOrRepetitive => "garbledOrRepetitive",
        _ => reason.ToString(),
    };

    private static string NormalizeLanguage(string code) => SubtitleLanguageChoice.NormalizedLanguageCode(code);

    private static bool IsCjkScalar(int value) =>
        value is >= 0x3040 and <= 0x30FF
            or >= 0x3400 and <= 0x4DBF
            or >= 0x4E00 and <= 0x9FFF
            or >= 0xAC00 and <= 0xD7A3
            or >= 0xF900 and <= 0xFAFF
            or >= 0x20000 and <= 0x2FA1F;
}

public static class SubtitleSourceResolver
{
    public static ResolvedSubtitleSource? Resolve(SubtitleResolutionRequest request)
    {
        var requestedLanguage = NormalizedLanguage(request.LanguageIntent);
        var candidates = FilterByLanguage(request.Candidates, requestedLanguage).ToArray();
        if (candidates.Length == 0) return null;

        var scored = candidates
            .Select(candidate => SubtitleQualityScorer.Score(candidate, requestedLanguage, request.VideoDurationSeconds))
            .ToArray();
        var winner = scored
            .OrderByDescending(score => score.Score + PolicyBoost(score.Kind, request.SourcePolicy))
            .ThenBy(score => SourceKindRank(score.Kind))
            .First();
        var selected = candidates.First(candidate => candidate.Id == winner.CandidateId);

        return new ResolvedSubtitleSource
        {
            LanguageCode = selected.LanguageCode,
            SelectedFile = selected.FilePath ?? "",
            SelectedKind = selected.Kind,
            QualityVerdict = new PlatformSubtitleQualityGate.Verdict(
                winner.Verdict >= SubtitleQualityVerdict.Usable,
                [],
                winner.Report ?? PlatformSubtitleQualityGate.SubtitleSourceQualityReport.Empty),
            SourceQualityVerdict = winner.Verdict,
            UsedLocalAsrFallback = selected.Kind == SubtitleSourceKind.LocalAsr
                && candidates.Any(candidate => candidate.Kind != SubtitleSourceKind.LocalAsr),
            CandidateReports = scored.Select(score =>
                new SubtitleSourceCandidateReport(
                    score.Kind,
                    score.LanguageCode,
                    candidates.Any(candidate => candidate.Id == score.CandidateId
                        && !string.IsNullOrWhiteSpace(candidate.FilePath)
                        && File.Exists(candidate.FilePath)),
                    score.CandidateId == winner.CandidateId,
                    score.Verdict >= SubtitleQualityVerdict.Usable,
                    score.Reasons,
                    score.Verdict)).ToArray(),
        };
    }

    private static double PolicyBoost(SubtitleSourceKind kind, SubtitleSourcePolicy policy) => policy switch
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

    private static bool IsPlatform(SubtitleSourceKind kind) =>
        kind is SubtitleSourceKind.Manual or SubtitleSourceKind.PlatformAuto or SubtitleSourceKind.HlsManifest;

    private static int SourceKindRank(SubtitleSourceKind kind) => kind switch
    {
        SubtitleSourceKind.Manual => 0,
        SubtitleSourceKind.ImportedFile => 1,
        SubtitleSourceKind.HlsManifest => 2,
        SubtitleSourceKind.PlatformAuto => 3,
        SubtitleSourceKind.CloudAsr => 4,
        SubtitleSourceKind.LocalAsr => 5,
        _ => 6,
    };

    private static string? NormalizedLanguage(SourceLanguageIntent intent)
    {
        if (intent.IsAutomatic) return null;
        var normalized = SubtitleLanguageChoice.NormalizedLanguageCode(intent.LanguageCode ?? "");
        return normalized.Length == 0 ? null : normalized;
    }

    private static IEnumerable<SubtitleSourceCandidate> FilterByLanguage(
        IReadOnlyList<SubtitleSourceCandidate> candidates,
        string? requestedLanguage)
    {
        if (requestedLanguage is null) return candidates;
        var exact = candidates
            .Where(candidate => SubtitleLanguageChoice.NormalizedLanguageCode(candidate.LanguageCode) == requestedLanguage)
            .ToArray();
        return exact.Length == 0 ? candidates : exact;
    }
}
