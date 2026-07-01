using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text;
using System.Text.Json.Serialization;

namespace Moongate.Core;

/// <summary>
/// Confidence summary of a local Whisper recognition. Whisper often *confidently* mishears or emits
/// low-confidence garbage for sung Chinese/Cantonese/Korean (e.g. 青花瓷 → 「了出情话被风弄转」). There is
/// no better source to switch to (whisper IS the fallback), so the honest behaviour is a "recognition
/// quality is low; for reference only" note rather than presenting garbage as confident subtitles.
///
/// Known limitation (conservative trade-off): whisper confidence is a weak signal — some garbage is
/// confident. In addition to overall low confidence, we catch a conservative timing/probability
/// combination: multiple stretched CJK tokens with at least one extremely low-probability token.
/// This avoids switching on a single wrong word while catching obvious timing collapse. Single
/// source of truth in Tests/fixtures/whisper-timing-constants.json (localASRConfidence); both ends
/// assert their constants equal it. Mirror of Swift LocalASRConfidence.
/// </summary>
public readonly record struct LocalAsrConfidenceSummary
{
    public int AssessedWordCount { get; init; }
    public double AverageProbability { get; init; }
    public double LowConfidenceWordRatio { get; init; }
    public bool IsLowConfidence { get; init; }
    public double ScriptMismatchRatio { get; init; }
    public double LatinTokenRatio { get; init; }
    public double DominantPhraseRatio { get; init; }
    public double RepeatedPhraseSpanSeconds { get; init; }
    public IReadOnlyList<string> QualityIssues { get; init; }
    public bool IsLowQuality { get; init; }
    [JsonIgnore]
    public bool HasSevereQualityBlocker =>
        QualityIssues.Contains("phraseLoop")
        || QualityIssues.Contains("autoLanguageMismatch")
        || QualityIssues.Contains("nearEmptyTranscript");

    public LocalAsrConfidenceSummary(
        int assessedWordCount,
        double averageProbability,
        double lowConfidenceWordRatio,
        bool isLowConfidence,
        double scriptMismatchRatio = 0,
        double latinTokenRatio = 0,
        double dominantPhraseRatio = 0,
        double repeatedPhraseSpanSeconds = 0,
        IReadOnlyList<string>? qualityIssues = null,
        bool? isLowQuality = null)
    {
        AssessedWordCount = assessedWordCount;
        AverageProbability = averageProbability;
        LowConfidenceWordRatio = lowConfidenceWordRatio;
        IsLowConfidence = isLowConfidence;
        ScriptMismatchRatio = scriptMismatchRatio;
        LatinTokenRatio = latinTokenRatio;
        DominantPhraseRatio = dominantPhraseRatio;
        RepeatedPhraseSpanSeconds = repeatedPhraseSpanSeconds;
        QualityIssues = qualityIssues ?? [];
        IsLowQuality = isLowQuality ?? (isLowConfidence || QualityIssues.Count > 0);
    }
}

public static class LocalAsrConfidence
{
    public const double AverageProbabilityFloor = 0.8;
    public const double LowConfidenceWordProbability = 0.5;
    public const double LowConfidenceWordRatioCeiling = 0.2;
    public const int MinimumAssessableWordCount = 24;
    public const double StretchedCjkTokenSecondsFloor = 2.5;
    public const int StretchedCjkTokenClusterCount = 3;
    public const double StretchedCjkLowProbabilityCeiling = 0.15;

    public static LocalAsrConfidenceSummary Assess(
        IReadOnlyList<AsrWord> words,
        string? languageCode = null,
        IReadOnlyList<AsrSegment>? segments = null,
        string? requestedLanguageCode = null,
        string? languageHintCode = null)
    {
        var probabilities = new List<double>(words.Count);
        foreach (var word in words)
        {
            if (string.IsNullOrEmpty(word.Text) || word.Text.All(char.IsWhiteSpace)) continue;
            if (word.Probability is not { } probability) continue;
            probabilities.Add(probability);
        }

        var count = probabilities.Count;
        var scriptQuality = AssessScriptQuality(words, languageCode);
        var loopIssues = AssessLoopQuality(words, languageCode);
        var timingIssues = AssessTimingQuality(words, languageCode);
        var segmentQuality = AssessSegmentQuality(
            segments ?? [],
            languageCode,
            requestedLanguageCode,
            languageHintCode);
        var qualityIssues = scriptQuality.Issues
            .Concat(loopIssues)
            .Concat(timingIssues)
            .Concat(segmentQuality.Issues)
            .Distinct()
            .Order(StringComparer.Ordinal)
            .ToList();
        if (count == 0)
        {
            return new LocalAsrConfidenceSummary(
                0, 1.0, 0.0, false,
                scriptQuality.MismatchRatio,
                scriptQuality.LatinRatio,
                segmentQuality.DominantPhraseRatio,
                segmentQuality.RepeatedPhraseSpanSeconds,
                qualityIssues);
        }

        var average = probabilities.Sum() / count;
        var lowRatio = (double)probabilities.Count(p => p < LowConfidenceWordProbability) / count;
        var isLow = count >= MinimumAssessableWordCount
            && (average < AverageProbabilityFloor || lowRatio > LowConfidenceWordRatioCeiling);
        return new LocalAsrConfidenceSummary(
            count,
            average,
            lowRatio,
            isLow,
            scriptQuality.MismatchRatio,
            scriptQuality.LatinRatio,
            segmentQuality.DominantPhraseRatio,
            segmentQuality.RepeatedPhraseSpanSeconds,
            qualityIssues);
    }

    public static LocalAsrConfidenceSummary AssessSubtitle(
        string raw,
        string fileName,
        string? languageCode = null,
        string? requestedLanguageCode = null,
        string? languageHintCode = null)
    {
        var cues = SrtTools.ParseSubtitle(raw, fileName);
        var segments = cues
            .Select(cue => new
            {
                cue.Text,
                Start = SrtTools.SrtTimeToSeconds(cue.Start),
                End = SrtTools.SrtTimeToSeconds(cue.End),
            })
            .Where(cue => cue.Start is not null && cue.End is not null)
            .Select(cue => new AsrSegment
            {
                Text = cue.Text,
                StartSeconds = cue.Start!.Value,
                EndSeconds = Math.Max(cue.End!.Value, cue.Start.Value),
            })
            .ToList();
        var words = segments
            .Select(segment => new AsrWord
            {
                Text = segment.Text,
                StartSeconds = segment.StartSeconds,
                EndSeconds = segment.EndSeconds,
            })
            .ToList();
        return Assess(words, languageCode, segments, requestedLanguageCode, languageHintCode);
    }

    private static (double MismatchRatio, double LatinRatio, IReadOnlyList<string> Issues) AssessScriptQuality(
        IReadOnlyList<AsrWord> words,
        string? languageCode)
    {
        var language = NormalizeLanguageCode(languageCode);
        if (language is not ("ja" or "ko" or "zh" or "yue"))
        {
            return (0, 0, []);
        }

        var visible = 0;
        var expected = 0;
        var latin = 0;
        foreach (var scalar in string.Concat(words.Select(word => word.Text)).EnumerateRunes())
        {
            if (ShouldIgnoreForScriptQuality(scalar))
            {
                continue;
            }
            visible++;
            if (IsExpectedScript(scalar, language)) expected++;
            if (IsLatinLetter(scalar)) latin++;
        }
        if (visible < MinimumAssessableWordCount)
        {
            return (0, 0, []);
        }

        var expectedRatio = (double)expected / visible;
        var latinRatio = (double)latin / visible;
        var mismatchRatio = 1.0 - expectedRatio;
        IReadOnlyList<string> issues = expectedRatio < 0.25 && latinRatio > 0.5
            ? ["scriptMismatch"]
            : [];
        return (mismatchRatio, latinRatio, issues);
    }

    private static IReadOnlyList<string> AssessLoopQuality(IReadOnlyList<AsrWord> words, string? languageCode)
    {
        var language = NormalizeLanguageCode(languageCode);
        if (language is not ("ja" or "ko" or "zh" or "yue"))
        {
            return [];
        }

        var tokens = words
            .Select(word => NormalizeLoopToken(word.Text))
            .Where(token => token.Length > 0)
            .ToList();
        if (tokens.Count < MinimumAssessableWordCount)
        {
            return [];
        }

        var counts = new Dictionary<string, int>(StringComparer.Ordinal);
        var maxRun = 0;
        var currentRun = 0;
        string? previous = null;
        foreach (var token in tokens)
        {
            counts[token] = counts.GetValueOrDefault(token) + 1;
            if (token == previous)
            {
                currentRun++;
            }
            else
            {
                currentRun = 1;
                previous = token;
            }
            maxRun = Math.Max(maxRun, currentRun);
        }

        var uniqueRatio = (double)counts.Count / tokens.Count;
        var dominantRatio = (double)counts.Values.DefaultIfEmpty(0).Max() / tokens.Count;
        var issues = new List<string>();
        if (uniqueRatio <= 0.16) issues.Add("lowDiversity");
        if (maxRun >= 8 || (dominantRatio >= 0.5 && uniqueRatio <= 0.20)) issues.Add("repetitionLoop");
        return issues;
    }

    private static IReadOnlyList<string> AssessTimingQuality(IReadOnlyList<AsrWord> words, string? languageCode)
    {
        var language = NormalizeLanguageCode(languageCode);
        if (!IsCjkLanguage(language) || words.Count < MinimumAssessableWordCount)
        {
            return [];
        }

        var stretchedCjkWords = words
            .Where(word => word.EndSeconds > word.StartSeconds
                && word.EndSeconds - word.StartSeconds >= StretchedCjkTokenSecondsFloor
                && (word.Text ?? "").EnumerateRunes().Any(scalar => IsExpectedScript(scalar, language)))
            .ToList();
        if (stretchedCjkWords.Count < StretchedCjkTokenClusterCount)
        {
            return [];
        }

        return stretchedCjkWords.Any(word => word.Probability is { } probability
                                            && probability <= StretchedCjkLowProbabilityCeiling)
            ? ["stretchedLowConfidenceCJKToken"]
            : [];
    }

    private static (double DominantPhraseRatio, double RepeatedPhraseSpanSeconds, IReadOnlyList<string> Issues)
        AssessSegmentQuality(
            IReadOnlyList<AsrSegment> segments,
            string? languageCode,
            string? requestedLanguageCode,
            string? languageHintCode)
    {
        var phrases = segments
            .Select(segment => new
            {
                Phrase = NormalizeLoopToken(segment.Text),
                segment.StartSeconds,
                segment.EndSeconds,
            })
            .Where(segment => segment.Phrase.Length > 0)
            .ToList();
        var issues = new List<string>();
        if (LooksNearEmptyTranscript(segments))
        {
            issues.Add("nearEmptyTranscript");
        }
        var detected = NormalizeLanguageCode(languageCode);
        var hint = NormalizeLanguageCode(languageHintCode);
        if (IsAutoLanguage(requestedLanguageCode)
            && IsCjkLanguage(hint)
            && detected.Length > 0
            && detected != hint)
        {
            issues.Add("autoLanguageMismatch");
        }

        if (phrases.Count < 3)
        {
            return (0, 0, issues);
        }

        var groups = phrases
            .GroupBy(segment => segment.Phrase, StringComparer.Ordinal)
            .OrderByDescending(group => group.Count())
            .ToList();
        var dominant = groups.First();
        var dominantCount = dominant.Count();
        var dominantRatio = (double)dominantCount / phrases.Count;
        var earliest = dominant.Min(segment => segment.StartSeconds);
        var latest = dominant.Max(segment => segment.EndSeconds);
        var repeatedSpan = Math.Max(0, latest - earliest);
        var overallSpan = Math.Max(
            0,
            phrases.Max(segment => segment.EndSeconds) - phrases.Min(segment => segment.StartSeconds));

        if (groups.Count == 1
            && dominantCount >= 3
            && phrases.Count <= 4
            && repeatedSpan >= 20)
        {
            issues.Add("lowSegmentDiversity");
        }
        if (dominantCount >= 6
            && dominantRatio >= 0.6
            && repeatedSpan >= 25
            && dominant.Key.Length >= 4)
        {
            issues.Add("phraseLoop");
        }
        if (IsFragmentedCjkLoop(
            phrases.Select(segment => segment.Phrase).ToList(),
            detected.Length == 0 ? hint : detected,
            groups.Count,
            overallSpan))
        {
            repeatedSpan = Math.Max(repeatedSpan, overallSpan);
            issues.Add("lowSegmentDiversity");
            issues.Add("phraseLoop");
        }
        return (dominantRatio, repeatedSpan, issues);
    }

    private static bool LooksNearEmptyTranscript(IReadOnlyList<AsrSegment> segments)
    {
        var meaningfulScalarCount = string.Concat(segments.Select(segment => segment.Text ?? ""))
            .EnumerateRunes()
            .Count(scalar => !ShouldIgnoreForScriptQuality(scalar));
        return segments.Count == 1 && meaningfulScalarCount <= 2;
    }

    private static bool IsFragmentedCjkLoop(
        IReadOnlyList<string> phrases,
        string languageCode,
        int groupCount,
        double repeatedSpan)
    {
        if (!IsCjkLanguage(languageCode)
            || phrases.Count < 5
            || groupCount < 3
            || repeatedSpan < 20)
        {
            return false;
        }
        var scalars = string.Concat(phrases)
            .EnumerateRunes()
            .Where(scalar => !ShouldIgnoreForScriptQuality(scalar))
            .ToList();
        if (scalars.Count < 18) return false;
        var uniqueRatio = (double)scalars.Select(scalar => scalar.Value).Distinct().Count() / scalars.Count;
        var averagePhraseLength = (double)scalars.Count / phrases.Count;
        return uniqueRatio <= 0.25 && averagePhraseLength <= 8;
    }

    private static string NormalizeLoopToken(string raw)
    {
        var builder = new StringBuilder();
        foreach (var scalar in (raw ?? "").Trim().EnumerateRunes())
        {
            if (ShouldIgnoreForScriptQuality(scalar)) continue;
            builder.Append(scalar.ToString().ToLowerInvariant());
        }
        return builder.ToString();
    }

    private static string NormalizeLanguageCode(string? raw)
    {
        var lower = (raw ?? "").Trim().ToLowerInvariant();
        if (lower is "" or "auto" or "und" or "unknown") return "";
        if (lower == "yue") return "yue";
        if (lower.StartsWith("zh", StringComparison.Ordinal)) return "zh";
        if (lower.StartsWith("ja", StringComparison.Ordinal)) return "ja";
        if (lower.StartsWith("ko", StringComparison.Ordinal)) return "ko";
        return lower;
    }

    private static bool IsAutoLanguage(string? raw)
    {
        var lower = (raw ?? "").Trim().ToLowerInvariant();
        return lower is "" or "auto" or "und" or "unknown";
    }

    private static bool IsCjkLanguage(string language) => language is "ja" or "ko" or "zh" or "yue";

    private static bool IsExpectedScript(Rune scalar, string language)
    {
        var value = scalar.Value;
        return language switch
        {
            "ko" => value is >= 0xAC00 and <= 0xD7AF,
            "ja" => value is >= 0x3040 and <= 0x30FF or >= 0x4E00 and <= 0x9FFF,
            "zh" or "yue" => value is >= 0x4E00 and <= 0x9FFF,
            _ => false,
        };
    }

    private static bool IsLatinLetter(Rune scalar)
    {
        var value = scalar.Value;
        return value is >= 'A' and <= 'Z' or >= 'a' and <= 'z';
    }

    private static bool ShouldIgnoreForScriptQuality(Rune scalar)
    {
        if (Rune.IsWhiteSpace(scalar)) return true;
        return Rune.GetUnicodeCategory(scalar) switch
        {
            UnicodeCategory.ConnectorPunctuation
                or UnicodeCategory.DashPunctuation
                or UnicodeCategory.OpenPunctuation
                or UnicodeCategory.ClosePunctuation
                or UnicodeCategory.InitialQuotePunctuation
                or UnicodeCategory.FinalQuotePunctuation
                or UnicodeCategory.OtherPunctuation
                or UnicodeCategory.MathSymbol
                or UnicodeCategory.CurrencySymbol
                or UnicodeCategory.ModifierSymbol
                or UnicodeCategory.OtherSymbol
                or UnicodeCategory.Control => true,
            _ => false,
        };
    }
}

/// <summary>Local-ASR generation result: source SRT path + transcript confidence.</summary>
public readonly record struct GeneratedLocalAsrSource(string Url, LocalAsrConfidenceSummary? Confidence);
