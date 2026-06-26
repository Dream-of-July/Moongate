using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;

namespace Moongate.Core;

/// <summary>
/// Assesses whether a platform (YouTube) auto-caption track is USABLE as a translation source.
///
/// Critical design rule (hard-won): this gate must NEVER compare a whisper transcript against the
/// auto-caption, and must NEVER score timing. YouTube auto-captions pass through Google's
/// human-aligned word timestamps, so their timing is structurally better than whisper's — judging
/// "quality" by timing would make whisper always lose and defeat the whole point of the fallback.
/// Instead we only look at the auto-caption's OWN intrinsic usability: language match, cue density,
/// coverage, and garbling/repetition. Whisper is only generated when this gate says "not usable".
/// </summary>
public static class PlatformSubtitleQualityGate
{
    public enum Reason
    {
        LanguageMismatch,
        TooFewCues,
        LowCoverage,
        GarbledOrRepetitive,
    }

    public sealed record SubtitleSourceQualityReport(
        int CueCount,
        int VisibleScalarCount,
        bool CjkLanguage,
        double CjkScalarRatio,
        double LatinScalarRatio,
        double AdjacentIdenticalRatio,
        double BadScalarRatio,
        double UniqueCueTextRatio,
        int RomanizedLoopTokenCount,
        int RomanizedLoopMaxRun,
        double RomanizedLoopTokenRatio,
        int SoundEffectCueCount,
        double SoundEffectCueRatio,
        double SoundEffectDurationRatio,
        int LongCueCount,
        double LongCueRatio,
        double MaxCueDuration)
    {
        public static SubtitleSourceQualityReport Empty { get; } = new(
            0, 0, false, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    }

    public sealed record Verdict(
        bool Usable,
        IReadOnlyList<Reason> Reasons,
        SubtitleSourceQualityReport? Report = null)
    {
        public SubtitleSourceQualityReport QualityReport => Report ?? SubtitleSourceQualityReport.Empty;
    }

    // Thresholds. Single source of truth lives in the cross-platform fixture
    // (platformSubtitleQualityGate section); Swift and C# copies are each asserted equal to it.
    public const int MinimumUsableCueCount = 8;
    public const double MinimumCoverageRatio = 0.35;
    public const double RepetitionRatioThreshold = 0.5;
    public const double GarbledRatioThreshold = 0.05;
    public const double CjkLatinNoiseRatioThreshold = 0.20;
    public const double CjkContentMismatchLatinRatioThreshold = 0.55;
    public const double CjkContentMismatchCjkRatioThreshold = 0.15;
    public const double CjkLongCueDurationThreshold = 12.0;
    public const double CjkLongCueRatioThreshold = 0.08;
    public const int CjkLongCueMinCount = 2;
    public const double RomanizedLoopTokenRatioThreshold = 0.35;
    public const int RomanizedLoopMinTokenCount = 6;
    public const int RomanizedLoopMinMaxRun = 3;
    public const double SoundEffectCueRatioThreshold = 0.10;
    public const int SoundEffectCueMinCount = 4;
    public const double SoundEffectDurationRatioThreshold = 0.12;
    public const int SoundEffectDurationMinCount = 2;

    public static Verdict Assess(
        IReadOnlyList<SubtitleCue> cues,
        string? requestedLanguageCode,
        string? subtitleLanguageCode,
        double? videoDurationSeconds)
    {
        var reasons = new List<Reason>();
        var report = QualityReport(cues, requestedLanguageCode, subtitleLanguageCode);

        // 1) Language match (fatal). Normalize both sides to language buckets.
        if (!string.IsNullOrEmpty(requestedLanguageCode) && !string.IsNullOrEmpty(subtitleLanguageCode))
        {
            var r = SubtitleLanguageChoice.NormalizedLanguageCode(requestedLanguageCode);
            var a = SubtitleLanguageChoice.NormalizedLanguageCode(subtitleLanguageCode);
            if (r != a) reasons.Add(Reason.LanguageMismatch);
        }

        // 2) Cue density.
        if (cues.Count < MinimumUsableCueCount) reasons.Add(Reason.TooFewCues);

        // 3) Coverage (only when duration is known and positive).
        if (videoDurationSeconds is { } duration && duration > 0)
        {
            var covered = TotalCoveredSeconds(cues);
            if (covered / duration < MinimumCoverageRatio) reasons.Add(Reason.LowCoverage);
        }

        // 4) Garbling / repetition.
        if (ReportLooksGarbledOrRepetitive(report)) reasons.Add(Reason.GarbledOrRepetitive);

        return new Verdict(reasons.Count == 0, reasons, report);
    }

    internal static double TotalCoveredSeconds(IReadOnlyList<SubtitleCue> cues)
    {
        var total = 0.0;
        foreach (var cue in cues)
        {
            var s = SrtTools.SrtTimeToSeconds(cue.Start);
            var e = SrtTools.SrtTimeToSeconds(cue.End);
            if (s is { } start && e is { } end && end > start) total += end - start;
        }
        return total;
    }

    internal static bool LooksGarbledOrRepetitive(IReadOnlyList<SubtitleCue> cues)
    {
        return ReportLooksGarbledOrRepetitive(QualityReport(cues, null, null));
    }

    public static SubtitleSourceQualityReport QualityReport(
        IReadOnlyList<SubtitleCue> cues,
        string? requestedLanguageCode,
        string? subtitleLanguageCode)
    {
        if (cues.Count == 0) return SubtitleSourceQualityReport.Empty;

        var cjkLanguage = IsCjkLanguageCode(requestedLanguageCode) || IsCjkLanguageCode(subtitleLanguageCode);
        var romanizedLoopSensitiveLanguage = IsRomanizedLoopSensitiveLanguageCode(requestedLanguageCode)
            || IsRomanizedLoopSensitiveLanguageCode(subtitleLanguageCode);
        int identical = 0, comparable = 0, visibleScalars = 0, badScalars = 0, cjkScalars = 0, latinScalars = 0;
        string? previous = null;
        var uniqueTexts = new HashSet<string>(StringComparer.Ordinal);
        var latinTokens = new List<string>();
        var soundEffectCueCount = 0;
        var soundEffectDuration = 0.0;
        var subtitleDuration = 0.0;
        var longCueCount = 0;
        var maxCueDuration = 0.0;
        foreach (var cue in cues)
        {
            var trimmed = cue.Text.Trim();
            var start = SrtTools.SrtTimeToSeconds(cue.Start);
            var end = SrtTools.SrtTimeToSeconds(cue.End);
            var duration = start is { } s && end is { } e && e > s ? e - s : 0.0;
            subtitleDuration += duration;
            maxCueDuration = Math.Max(maxCueDuration, duration);
            if (duration >= CjkLongCueDurationThreshold) longCueCount++;
            if (previous is not null)
            {
                comparable++;
                if (trimmed.Length > 0 && trimmed == previous) identical++;
            }
            previous = trimmed;
            if (trimmed.Length > 0) uniqueTexts.Add(trimmed);
            if (IsSoundEffectCueText(trimmed))
            {
                soundEffectCueCount++;
                soundEffectDuration += duration;
            }
            var qualityText = cjkLanguage ? RemoveParentheticalLatinGlosses(cue.Text) : cue.Text;
            latinTokens.AddRange(LatinWordTokens(qualityText));
            foreach (var rune in qualityText.EnumerateRunes())
            {
                if (Rune.IsWhiteSpace(rune)) continue;
                visibleScalars++;
                if (rune.Value == 0xFFFD || IsControlScalar(rune.Value)) badScalars++;
                if (IsCjkScalar(rune.Value)) cjkScalars++;
                if (IsLatinLetterScalar(rune.Value)) latinScalars++;
            }
        }

        var counts = new Dictionary<string, int>(StringComparer.Ordinal);
        IEnumerable<string> suspiciousTokens = romanizedLoopSensitiveLanguage
            ? latinTokens.Where(IsSuspiciousRomanizedLoopToken)
            : Array.Empty<string>();
        foreach (var token in suspiciousTokens)
        {
            counts[token] = counts.TryGetValue(token, out var count) ? count + 1 : 1;
        }
        var repeatedLoopTokenCount = counts.Values.Where(count => count >= 2).Sum();
        var maxRun = counts.Count == 0 ? 0 : counts.Values.Max();
        var loopRatio = latinTokens.Count == 0 ? 0 : (double)repeatedLoopTokenCount / latinTokens.Count;

        return new SubtitleSourceQualityReport(
            cues.Count,
            visibleScalars,
            cjkLanguage,
            visibleScalars == 0 ? 0 : (double)cjkScalars / visibleScalars,
            visibleScalars == 0 ? 0 : (double)latinScalars / visibleScalars,
            comparable == 0 ? 0 : (double)identical / comparable,
            visibleScalars == 0 ? 0 : (double)badScalars / visibleScalars,
            cues.Count == 0 ? 0 : (double)uniqueTexts.Count / cues.Count,
            repeatedLoopTokenCount,
            maxRun,
            loopRatio,
            soundEffectCueCount,
            cues.Count == 0 ? 0 : (double)soundEffectCueCount / cues.Count,
            subtitleDuration > 0 ? soundEffectDuration / subtitleDuration : 0,
            longCueCount,
            cues.Count == 0 ? 0 : (double)longCueCount / cues.Count,
            maxCueDuration);
    }

    private static bool ReportLooksGarbledOrRepetitive(SubtitleSourceQualityReport report)
    {
        if (report.AdjacentIdenticalRatio >= RepetitionRatioThreshold) return true;
        if (report.BadScalarRatio >= GarbledRatioThreshold) return true;
        if (report.CjkLanguage
            && report.VisibleScalarCount >= 6
            && report.LatinScalarRatio >= CjkContentMismatchLatinRatioThreshold
            && report.CjkScalarRatio <= CjkContentMismatchCjkRatioThreshold)
        {
            return true;
        }
        var romanizedLoop = report.RomanizedLoopTokenCount >= RomanizedLoopMinTokenCount
            && report.RomanizedLoopMaxRun >= RomanizedLoopMinMaxRun
            && report.RomanizedLoopTokenRatio >= RomanizedLoopTokenRatioThreshold;
        if (report.CjkLanguage
            && report.VisibleScalarCount >= 80
            && report.LatinScalarRatio >= CjkLatinNoiseRatioThreshold
            && romanizedLoop)
        {
            return true;
        }
        if (report.CjkLanguage
            && report.LongCueCount >= CjkLongCueMinCount
            && report.LongCueRatio >= CjkLongCueRatioThreshold)
        {
            return true;
        }
        return report.SoundEffectCueCount >= SoundEffectCueMinCount
                && report.SoundEffectCueRatio >= SoundEffectCueRatioThreshold
            || report.SoundEffectCueCount >= SoundEffectDurationMinCount
                && report.SoundEffectDurationRatio >= SoundEffectDurationRatioThreshold;
    }

    private static bool IsSoundEffectCueText(string text)
    {
        var compact = string.Concat(text.Where(ch => !char.IsWhiteSpace(ch))).ToLowerInvariant();
        if (compact.Length == 0) return false;
        string[] markers =
        [
            "[音楽]", "［音楽］", "[拍手]", "［拍手］",
            "[music]", "[applause]", "(music)", "(applause)",
            "[musica]", "[música]", "[musique]", "[musik]",
            "(musica)", "(música)", "(musique)", "(musik)",
        ];
        return markers.Any(marker => compact.Contains(marker, StringComparison.Ordinal))
            || compact.All(ch => ch is '♪' or '♫')
            || compact is "音楽" or "拍手" or "music" or "applause" or "musica" or "música" or "musique" or "musik";
    }

    private static string RemoveParentheticalLatinGlosses(string text)
    {
        if (!ContainsCjkScalar(text)) return text;
        var builder = new StringBuilder();
        var index = 0;
        while (index < text.Length)
        {
            var current = text[index];
            var close = current switch
            {
                '(' => ')',
                '（' => '）',
                _ => '\0',
            };
            if (close != '\0')
            {
                var closeIndex = text.IndexOf(close, index + 1);
                if (closeIndex > index)
                {
                    var inner = text.Substring(index + 1, closeIndex - index - 1);
                    if (ContainsLatinLetter(inner) && !ContainsCjkScalar(inner))
                    {
                        index = closeIndex + 1;
                        continue;
                    }
                }
            }
            builder.Append(current);
            index++;
        }
        return builder.ToString();
    }

    private static bool ContainsCjkScalar(string text) =>
        text.EnumerateRunes().Any(rune => IsCjkScalar(rune.Value));

    private static bool ContainsLatinLetter(string text) =>
        text.EnumerateRunes().Any(rune => IsLatinLetterScalar(rune.Value));

    private static bool IsCjkLanguageCode(string? code)
    {
        if (string.IsNullOrWhiteSpace(code)) return false;
        var normalized = SubtitleLanguageChoice.NormalizedLanguageCode(code);
        return normalized is "ja" or "ko" or "zh" or "yue" or "cmn";
    }

    private static bool IsRomanizedLoopSensitiveLanguageCode(string? code)
    {
        if (string.IsNullOrWhiteSpace(code)) return false;
        var normalized = SubtitleLanguageChoice.NormalizedLanguageCode(code);
        return normalized is "ja" or "zh" or "yue" or "cmn";
    }

    private static bool IsCjkScalar(int v) =>
        v is >= 0x3040 and <= 0x30FF
            or >= 0x3400 and <= 0x4DBF
            or >= 0x4E00 and <= 0x9FFF
            or >= 0xAC00 and <= 0xD7A3
            or >= 0xF900 and <= 0xFAFF
            or >= 0x20000 and <= 0x2FA1F;

    private static bool IsLatinLetterScalar(int v) =>
        v is >= 0x41 and <= 0x5A or >= 0x61 and <= 0x7A;

    private static IEnumerable<string> LatinWordTokens(string text)
    {
        var current = new StringBuilder();
        foreach (var rune in text.EnumerateRunes())
        {
            if (IsLatinLetterScalar(rune.Value))
            {
                current.Append(rune.ToString());
            }
            else if (current.Length > 0)
            {
                yield return current.ToString().ToLowerInvariant();
                current.Clear();
            }
        }
        if (current.Length > 0)
        {
            yield return current.ToString().ToLowerInvariant();
        }
    }

    private static bool IsSuspiciousRomanizedLoopToken(string token)
    {
        if (token.Length is < 2 or > 6) return false;
        if (token.Any(ch => !((ch is >= 'A' and <= 'Z') || (ch is >= 'a' and <= 'z')))) return false;
        if (!token.Any(ch => "aeiou".Contains(ch, StringComparison.Ordinal))) return false;
        return token is not ("mv" or "live" or "music" or "video" or "cover" or "official" or "the" or "and" or "you" or "yo");
    }

    internal static bool IsControlScalar(int v)
    {
        // C0 controls except tab/newline/carriage return, plus DEL and C1 controls.
        if (v is 0x09 or 0x0A or 0x0D) return false;
        return v < 0x20 || v is >= 0x7F and <= 0x9F;
    }

    /// <summary>
    /// Convenience: parse + clean a subtitle file (the cues the viewer actually sees) and assess it.
    /// An unreadable file is treated as usable (can't fault content we couldn't read).
    /// </summary>
    public static Verdict Assess(
        string subtitleFilePath,
        string? requestedLanguageCode,
        string? subtitleLanguageCode,
        double? videoDurationSeconds)
    {
        string raw;
        try { raw = File.ReadAllText(subtitleFilePath); }
        catch { return new Verdict(true, []); }
        var isVtt = Path.GetExtension(subtitleFilePath).TrimStart('.').ToLowerInvariant() == "vtt";
        var cleaned = SrtTools.CleanCues(isVtt ? SrtTools.ParseVtt(raw) : SrtTools.ParseSrt(raw));
        return Assess(cleaned, requestedLanguageCode, subtitleLanguageCode, videoDurationSeconds);
    }

    /// <summary>
    /// Parses a yt-dlp style duration string ("2:31", "1:02:03", "45") into seconds. null when the
    /// string is missing or unparseable (callers then skip the coverage check).
    /// </summary>
    public static double? ParseDurationSeconds(string? text)
    {
        if (text is null) return null;
        var trimmed = text.Trim();
        if (trimmed.Length == 0) return null;
        var parts = trimmed.Split(':');
        if (parts.Length > 3) return null;
        var total = 0.0;
        foreach (var part in parts)
        {
            if (!double.TryParse(part, NumberStyles.Float, CultureInfo.InvariantCulture, out var value) || value < 0)
            {
                return null;
            }
            total = total * 60 + value;
        }
        return total;
    }
}

/// <summary>
/// Outcome of post-download subtitle source resolution: which file/source the translation pipeline
/// will actually use, why, and whether we fell back to local ASR. Surfaced to the UI's disclosure
/// area so the user can see the real source behind their language pick.
/// </summary>
public sealed record ResolvedSubtitleSource
{
    public required string LanguageCode { get; init; }
    public required string SelectedFile { get; init; }
    public required SubtitleSourceKind SelectedKind { get; init; }
    public PlatformSubtitleQualityGate.Verdict? QualityVerdict { get; init; }
    public bool UsedLocalAsrFallback { get; init; }
    public IReadOnlyList<PlatformSubtitleQualityGate.Reason> FallbackReasons { get; init; } = [];
    public IReadOnlyList<SubtitleSourceCandidateReport> CandidateReports { get; init; } = [];
}

public sealed record SubtitleSourceCandidateReport(
    SubtitleSourceKind SourceKind,
    string LanguageCode,
    bool Available,
    bool Selected,
    bool Usable,
    IReadOnlyList<string> Reasons);

public sealed record SongSubtitleSourceArbitration(
    SubtitleSourceKind? SelectedKind,
    IReadOnlyList<SubtitleSourceCandidateReport> CandidateReports);

public static class SongSubtitleSourceArbiter
{
    public static SongSubtitleSourceArbitration Arbitrate(
        string languageCode,
        IReadOnlyList<SubtitleChoice> tracks,
        PlatformSubtitleQualityGate.Verdict? platformAutoVerdict,
        bool localAsrAvailable)
    {
        var normalized = SubtitleLanguageChoice.NormalizedLanguageCode(languageCode);
        var sameLanguageTracks = tracks
            .Where(track => SubtitleLanguageChoice.NormalizedLanguageCode(track.LanguageCode) == normalized)
            .ToArray();
        var manualAvailable = sameLanguageTracks.Any(track => track.SourceKind
            is SubtitleSourceKind.Manual or SubtitleSourceKind.HlsManifest or SubtitleSourceKind.ImportedFile);
        var autoAvailable = sameLanguageTracks.Any(track => track.SourceKind == SubtitleSourceKind.PlatformAuto);
        var autoUsable = platformAutoVerdict?.Usable ?? autoAvailable;

        SubtitleSourceKind? selected = null;
        if (manualAvailable) selected = SubtitleSourceKind.Manual;
        else if (autoAvailable && autoUsable) selected = SubtitleSourceKind.PlatformAuto;
        else if (localAsrAvailable) selected = SubtitleSourceKind.LocalAsr;
        else if (autoAvailable) selected = SubtitleSourceKind.PlatformAuto;

        var autoReasons = platformAutoVerdict?.Reasons.Select(ReasonCode).ToArray() ?? [];
        var reports = new[]
        {
            new SubtitleSourceCandidateReport(
                SubtitleSourceKind.Manual,
                normalized,
                manualAvailable,
                selected == SubtitleSourceKind.Manual,
                manualAvailable,
                manualAvailable ? [] : ["missing"]),
            new SubtitleSourceCandidateReport(
                SubtitleSourceKind.PlatformAuto,
                normalized,
                autoAvailable,
                selected == SubtitleSourceKind.PlatformAuto,
                autoAvailable && autoUsable,
                autoAvailable ? autoReasons : ["missing"]),
            new SubtitleSourceCandidateReport(
                SubtitleSourceKind.LocalAsr,
                normalized,
                localAsrAvailable,
                selected == SubtitleSourceKind.LocalAsr,
                localAsrAvailable,
                localAsrAvailable ? [] : ["unavailable"]),
        };
        return new SongSubtitleSourceArbitration(selected, reports);
    }

    private static string ReasonCode(PlatformSubtitleQualityGate.Reason reason) => reason switch
    {
        PlatformSubtitleQualityGate.Reason.LanguageMismatch => "languageMismatch",
        PlatformSubtitleQualityGate.Reason.TooFewCues => "tooFewCues",
        PlatformSubtitleQualityGate.Reason.LowCoverage => "lowCoverage",
        PlatformSubtitleQualityGate.Reason.GarbledOrRepetitive => "garbledOrRepetitive",
        _ => reason.ToString(),
    };
}
