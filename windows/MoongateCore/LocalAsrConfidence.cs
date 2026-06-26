using System;
using System.Collections.Generic;
using System.Linq;

namespace Moongate.Core;

/// <summary>
/// Confidence summary of a local Whisper recognition. Whisper often *confidently* mishears or emits
/// low-confidence garbage for sung Chinese/Cantonese/Korean (e.g. 青花瓷 → 「了出情话被风弄转」). There is
/// no better source to switch to (whisper IS the fallback), so the honest behaviour is a "recognition
/// quality is low; for reference only" note rather than presenting garbage as confident subtitles.
///
/// Known limitation (conservative trade-off): whisper confidence is a weak signal — some garbage is
/// confident (BLACKPINK avg_prob 0.85 yet garbled). Thresholds are deliberately conservative: only
/// clearly-low-confidence output is flagged, zero false positives on clean content, at the cost of
/// limited recall. Single source of truth in Tests/fixtures/whisper-timing-constants.json
/// (localASRConfidence); both ends assert their constants equal it. Mirror of Swift LocalASRConfidence.
/// </summary>
public readonly record struct LocalAsrConfidenceSummary(
    int AssessedWordCount,
    double AverageProbability,
    double LowConfidenceWordRatio,
    bool IsLowConfidence);

public static class LocalAsrConfidence
{
    public const double AverageProbabilityFloor = 0.8;
    public const double LowConfidenceWordProbability = 0.5;
    public const double LowConfidenceWordRatioCeiling = 0.2;
    public const int MinimumAssessableWordCount = 24;

    public static LocalAsrConfidenceSummary Assess(IReadOnlyList<AsrWord> words)
    {
        var probabilities = new List<double>(words.Count);
        foreach (var word in words)
        {
            if (string.IsNullOrEmpty(word.Text) || word.Text.All(char.IsWhiteSpace)) continue;
            if (word.Probability is not { } probability) continue;
            probabilities.Add(probability);
        }

        var count = probabilities.Count;
        if (count == 0)
        {
            return new LocalAsrConfidenceSummary(0, 1.0, 0.0, false);
        }

        var average = probabilities.Sum() / count;
        var lowRatio = (double)probabilities.Count(p => p < LowConfidenceWordProbability) / count;
        var isLow = count >= MinimumAssessableWordCount
            && (average < AverageProbabilityFloor || lowRatio > LowConfidenceWordRatioCeiling);
        return new LocalAsrConfidenceSummary(count, average, lowRatio, isLow);
    }
}

/// <summary>Local-ASR generation result: source SRT path + transcript confidence.</summary>
public readonly record struct GeneratedLocalAsrSource(string Url, LocalAsrConfidenceSummary? Confidence);
