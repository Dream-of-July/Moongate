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
    PlatformSubtitleQualityGate.SubtitleSourceQualityReport? Report,
    bool GateUsable = true,
    IReadOnlyList<PlatformSubtitleQualityGate.Reason>? GateReasons = null);

public sealed record SubtitleResolutionRequest(
    SourceLanguageIntent LanguageIntent,
    SubtitleSourcePolicy SourcePolicy,
    IReadOnlyList<SubtitleSourceCandidate> Candidates,
    double? VideoDurationSeconds);

public static class SubtitleQualityScorer
{
    public static SubtitleSourceScore Score(
        SubtitleSourceCandidate candidate,
        string? requestedSourceLanguageCode,
        double? videoDurationSeconds)
    {
        if (string.IsNullOrWhiteSpace(candidate.FilePath) || !File.Exists(candidate.FilePath))
        {
            var generated = candidate.Kind is SubtitleSourceKind.LocalAsr or SubtitleSourceKind.CloudAsr;
            return new SubtitleSourceScore(
                candidate.Id,
                candidate.Kind,
                NormalizeLanguage(candidate.LanguageCode),
                0,
                SubtitleQualityVerdict.Unusable,
                [generated ? "pendingGeneration" : "missingFile"],
                null,
                false,
                []);
        }

        var raw = File.ReadAllText(candidate.FilePath);
        var rawCues = SrtTools.ParseSubtitle(raw, candidate.FilePath);
        var cleaned = SrtTools.CleanCues(rawCues);
        var gate = PlatformSubtitleQualityGate.Assess(
            cleaned,
            requestedSourceLanguageCode,
            candidate.LanguageCode,
            videoDurationSeconds);
        var rawReport = PlatformSubtitleQualityGate.QualityReport(
            rawCues,
            requestedSourceLanguageCode,
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

        if (extraReasons.Contains("shortCueFragmentation")) value -= 30;
        if (extraReasons.Contains("longShortCueHold")) value -= 40;
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
            report,
            gate.Usable,
            gate.Reasons.ToArray());
    }

    /// <summary>来源出处先验分（fixture subtitleSourceDecision.baseScore 两端契约真值）。internal 供契约测试断言。</summary>
    internal static double BaseScore(SubtitleSourceKind kind) => kind switch
    {
        SubtitleSourceKind.Manual => 85,
        SubtitleSourceKind.ImportedFile => 82,
        SubtitleSourceKind.HlsManifest => 76,
        SubtitleSourceKind.PlatformAuto => 58,
        SubtitleSourceKind.CloudAsr => 70,
        SubtitleSourceKind.LocalAsr => 50,
        _ => 0,
    };

    /// <summary>score→5 档裁决分界（fixture subtitleSourceDecision.verdictThresholds）。</summary>
    internal static readonly (double Excellent, double Good, double Usable, double LowConfidence) VerdictThresholds = (85, 72, 55, 35);

    private static SubtitleQualityVerdict VerdictFor(double score)
    {
        if (score >= VerdictThresholds.Excellent) return SubtitleQualityVerdict.Excellent;
        if (score >= VerdictThresholds.Good) return SubtitleQualityVerdict.Good;
        if (score >= VerdictThresholds.Usable) return SubtitleQualityVerdict.Usable;
        if (score >= VerdictThresholds.LowConfidence) return SubtitleQualityVerdict.LowConfidence;
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
        var cjkShortCueCount = texts.Count(text =>
        {
            var visibleCount = text.EnumerateRunes().Count(rune => !Rune.IsWhiteSpace(rune));
            return visibleCount is > 0 and <= 6 && text.EnumerateRunes().Any(rune => IsCjkScalar(rune.Value));
        });
        if (texts.Length > 0 && (double)cjkShortCueCount / texts.Length >= 0.35)
        {
            reasons.Add("shortCueFragmentation");
        }
        var longShortCueDurations = cues
            .Select(cue =>
            {
                var text = cue.Text.Trim();
                var visibleCount = text.EnumerateRunes().Count(rune => !Rune.IsWhiteSpace(rune));
                if (visibleCount is <= 0 or > 2
                    || !text.EnumerateRunes().Any(rune => IsCjkScalar(rune.Value)))
                {
                    return (double?)null;
                }
                var start = SrtTools.SrtTimeToSeconds(cue.Start);
                var end = SrtTools.SrtTimeToSeconds(cue.End);
                if (start is null || end is null || end <= start) return null;
                var duration = end.Value - start.Value;
                return duration >= 2.5 ? duration : null;
            })
            .OfType<double>()
            .ToArray();
        if (longShortCueDurations.Length >= 2 || (longShortCueDurations.Length > 0 && longShortCueDurations.Max() >= 5))
        {
            reasons.Add("longShortCueHold");
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

        // 评估 + 择优统一委托给 SubtitleSourceDecisionEngine（门每候选只跑一次、tie-break 单一口径）。
        var assessments = candidates
            .Select(candidate => SubtitleSourceDecisionEngine.Assess(candidate, requestedLanguage, request.VideoDurationSeconds))
            .ToArray();
        var selectableIds = candidates
            .Where(candidate => !string.IsNullOrWhiteSpace(candidate.FilePath) && File.Exists(candidate.FilePath))
            .Select(candidate => candidate.Id)
            .ToHashSet(StringComparer.Ordinal);
        if (selectableIds.Count == 0) return null;
        var winnerId = SubtitleSourceDecisionEngine.Choose(request.SourcePolicy, assessments, selectableIds);
        if (winnerId is null) return null;
        var winner = assessments.First(a => a.CandidateId == winnerId);
        var selected = candidates.First(candidate => candidate.Id == winnerId);

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
            CandidateReports = assessments.Select(assessment =>
                new SubtitleSourceCandidateReport(
                    assessment.Kind,
                    assessment.LanguageCode,
                    candidates.Any(candidate => candidate.Id == assessment.CandidateId
                        && !string.IsNullOrWhiteSpace(candidate.FilePath)
                        && File.Exists(candidate.FilePath)),
                    assessment.CandidateId == winnerId,
                    assessment.Verdict >= SubtitleQualityVerdict.Usable,
                    assessment.Reasons,
                    assessment.Verdict)).ToArray(),
        };
    }

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
