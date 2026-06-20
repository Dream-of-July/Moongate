using System.Text;
using System.Text.RegularExpressions;

namespace Moongate.Core;

/// <summary>Shared subtitle timing heuristics used by cleaning, evaluation fixtures, and parity tests.</summary>
public static partial class SubtitleTimingPlanner
{
    public const double NormalReadableCueSeconds = 9.0;
    public const double EmergencyReadableCueSeconds = 12.0;
    public const double SentenceHandoffGapSeconds = 0.08;
    public const double HandoffBoundaryBorrowSeconds = 0.14;
    public const double SentenceHandoffForwardSeconds = 0.25;
    public const double ShortSourceFragmentWindowSeconds = 2.4;
    public const double VttUntimedLongCueSeconds = 3.5;
    public const double VttUntimedMaxSecondsPerToken = 1.3;

    private static readonly HashSet<string> ContinuationStarts = new(StringComparer.OrdinalIgnoreCase)
    {
        "if", "that", "which", "who", "whom", "whose", "when", "where", "why", "how",
        "and", "or", "but", "because", "so", "then", "than", "to", "of", "for", "with",
        "as", "in", "on", "at", "by", "from", "do", "does", "did", "is", "are", "was",
        "were", "be", "been", "being", "have", "has", "had", "can", "could", "would",
        "will", "should", "may", "might", "must", "not",
        "a", "al", "del", "de", "el", "la", "los", "las", "un", "una", "unos", "unas",
        "y", "o", "que", "quien", "como", "con", "para", "por", "se", "me", "te", "lo", "le", "les", "no", "veces",
        "tambien", "también",
        "du", "des", "le", "une", "et", "ou", "qui", "dont", "pour", "avec", "dans", "sur", "en", "au", "aux",
        "aussi", "également",
        "di", "della", "dei", "degli", "delle", "il", "gli", "e", "che", "per", "su", "alla", "alle", "ai", "anche",
        "also", "too",
    };

    private static readonly HashSet<string> ContinuationEnds = new(StringComparer.OrdinalIgnoreCase)
    {
        "the", "a", "an", "and", "or", "but", "if", "that", "which", "who", "what",
        "when", "where", "why", "how", "to", "of", "for", "with", "from", "as",
        "is", "are", "was", "were", "be", "been", "being", "do", "does", "did",
        "have", "has", "had", "can", "could", "would", "will", "should", "may",
        "might", "must", "we", "you", "i", "they", "he", "she", "it",
        "al", "del", "de", "el", "la", "los", "las", "un", "una", "unos", "unas",
        "y", "o", "que", "quien", "como", "con", "para", "por", "se", "me", "te", "lo", "le", "les", "no",
        "du", "des", "le", "une", "et", "ou", "qui", "dont", "pour", "avec", "dans", "sur", "en", "au", "aux",
        "di", "della", "dei", "degli", "delle", "il", "gli", "e", "che", "per", "su", "alla", "alle", "ai",
    };

    [GeneratedRegex(@"[\p{L}\p{Nd}]+")]
    private static partial Regex WordTokenRegex();

    public static List<string> WordTokens(string text) =>
        WordTokenRegex().Matches(text.ToLowerInvariant())
            .Select(match => match.Value)
            .ToList();

    public static List<string> SpeechTokens(string text)
    {
        var tokens = new List<string>();
        var current = new StringBuilder();
        foreach (var ch in text.ToLowerInvariant())
        {
            if (char.IsLetterOrDigit(ch) && !IsCjkSpeechCharacter(ch))
            {
                current.Append(ch);
            }
            else if (current.Length > 0)
            {
                tokens.Add(current.ToString());
                current.Clear();
            }
        }
        if (current.Length > 0) tokens.Add(current.ToString());
        return tokens;
    }

    public static List<string> TimingTokens(string text)
    {
        if (ContainsCjkText(text))
        {
            return text.Where(ch => !char.IsWhiteSpace(ch)).Select(ch => ch.ToString()).ToList();
        }

        var tokens = new List<string>();
        var current = new StringBuilder();
        void FlushCurrent()
        {
            if (current.Length == 0) return;
            tokens.Add(current.ToString());
            current.Clear();
        }

        foreach (var ch in text.ToLowerInvariant())
        {
            if (char.IsLetterOrDigit(ch) && !IsCjkSpeechCharacter(ch))
            {
                current.Append(ch);
            }
            else
            {
                FlushCurrent();
                if (IsTimingCurrencySymbol(ch)) tokens.Add(ch.ToString());
            }
        }
        FlushCurrent();
        return tokens;
    }

    public static int VisibleCharacters(string text) =>
        text.Count(ch => !char.IsWhiteSpace(ch));

    public static bool ContainsCjkText(string text) =>
        text.Any(IsCjkSpeechCharacter);

    public static bool ContainsHangulText(string text) =>
        text.Any(ch => ch is >= '\uAC00' and <= '\uD7AF');

    public static bool ShouldAlignToSpeechWindow(
        string text,
        double originalDuration,
        bool speechAlignTimings,
        bool canUseSourceAnchors,
        bool endsSentence)
    {
        if (canUseSourceAnchors) return false;
        var containsCjk = ContainsCjkText(text);
        var speechTokenCount = SpeechTokens(text).Count;
        if (speechTokenCount > 0 && !containsCjk)
        {
            if (speechTokenCount <= 3) return true;
            if (speechTokenCount == 4
                && !endsSentence
                && HasTrailingSoftPause(text)
                && originalDuration > SpeechAlignedVisibleSeconds(text, endsSentence) + 0.1)
            {
                return true;
            }
            return speechAlignTimings && originalDuration > NormalReadableCueSeconds;
        }

        var visibleCount = VisibleCharacters(text);
        if (!containsCjk || visibleCount is 0 or > 12) return false;
        if (!speechAlignTimings && originalDuration <= NormalReadableCueSeconds) return false;
        return originalDuration > SpeechAlignedVisibleSeconds(text, endsSentence) + 0.5;
    }

    public static int CharacterSplitPartCount(string text, int requestedParts)
    {
        var visibleCount = VisibleCharacters(text);
        if (visibleCount == 0) return 1;
        var minVisibleCharacters = ContainsCjkText(text) ? 4 : 1;
        var maxReadableParts = Math.Max(1, visibleCount / minVisibleCharacters);
        return Math.Min(Math.Max(1, requestedParts), maxReadableParts);
    }

    public static double SpeechAlignedVisibleSeconds(string text, bool endsSentence)
    {
        var tokens = SpeechTokens(text);
        if (tokens.Count == 0)
        {
            return Clamp(VisibleCharacters(text) * 0.18 + 0.8, 1.5, 6.0);
        }

        if (tokens.Count >= 2 && tokens.All(token => token.All(char.IsDigit)))
        {
            return Clamp(tokens.Count * 0.65 + 0.5, 2.0, 8.0);
        }

        if (tokens.Count <= 3)
        {
            if (ShouldExtendShortCue(text, tokens.Count, endsSentence)) return 2.45;
            return 2.0;
        }
        if (tokens.Count == 4 && !endsSentence) return 1.92;

        var sentencePause = endsSentence ? 0.8 : 0.45;
        return Clamp(tokens.Count * 0.42 + sentencePause, 2.2, NormalReadableCueSeconds);
    }

    public static bool IsWeakBoundary(string leftToken, string rightToken)
    {
        var left = NormalizedBoundaryWord(leftToken);
        var right = NormalizedBoundaryWord(rightToken);
        if (left.Length == 0 || right.Length == 0) return false;
        return ContinuationEnds.Contains(left) || ContinuationStarts.Contains(right);
    }

    public static bool ShouldBorrowBoundaryForHandoff(string previousText, string nextText)
    {
        if (string.IsNullOrWhiteSpace(nextText)) return false;
        var last = LastMeaningfulCharacter(previousText);
        return last is ':' or '：' or ';' or '；';
    }

    private static double Clamp(double value, double min, double max) =>
        Math.Min(Math.Max(value, min), max);

    private static bool IsCjkSpeechCharacter(char ch) =>
        ch is >= '\u3400' and <= '\u4DBF'
            or >= '\u4E00' and <= '\u9FFF'
            or >= '\u3040' and <= '\u30FF'
            or >= '\uAC00' and <= '\uD7AF';

    private static bool IsTimingCurrencySymbol(char ch) =>
        ch is '€' or '$' or '£' or '¥' or '₩';

    private static bool ShouldExtendShortCue(string text, int tokenCount, bool endsSentence)
    {
        if (!endsSentence) return false;
        if (HasEmphaticTerminalPunctuation(text)) return true;
        return tokenCount >= 2 && VisibleCharacters(text) >= 10;
    }

    private static bool HasEmphaticTerminalPunctuation(string text)
    {
        var trimmed = text.Trim();
        return trimmed.Contains("!!", StringComparison.Ordinal)
            || trimmed.Contains("??", StringComparison.Ordinal)
            || trimmed.Contains("!?", StringComparison.Ordinal)
            || trimmed.Contains("?!", StringComparison.Ordinal);
    }

    private static char? LastMeaningfulCharacter(string text)
    {
        var trailingAllowed = new HashSet<char> { '"', '\'', '”', '’', ')', '）', '」', '』', ']' };
        for (var i = text.Length - 1; i >= 0; i--)
        {
            var ch = text[i];
            if (trailingAllowed.Contains(ch) || char.IsWhiteSpace(ch)) continue;
            return ch;
        }
        return null;
    }

    private static bool HasTrailingSoftPause(string text)
    {
        var last = LastMeaningfulCharacter(text);
        return last is ',' or '，' or ';' or '；' or ':' or '：';
    }

    private static string NormalizedBoundaryWord(string raw)
    {
        var builder = new StringBuilder();
        foreach (var ch in raw.ToLowerInvariant())
        {
            if (char.IsLetterOrDigit(ch)) builder.Append(ch);
        }
        return builder.ToString();
    }
}
