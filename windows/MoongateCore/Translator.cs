using System.Globalization;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Moongate.Core;

// MARK: - SRT 解析与序列化 + 清洗

/// <summary>SRT 解析、序列化与清洗（YouTube 滚动字幕去重叠 / 文本去重 / 按句合并）。</summary>
public static partial class SrtTools
{
    [GeneratedRegex(@"(\d{1,2}:\d{2}:\d{2}[,\.]\d{1,3})\s*-->\s*(\d{1,2}:\d{2}:\d{2}[,\.]\d{1,3})")]
    private static partial Regex TimeLineRegex();

    // 圆括号类音效/旁注：(...) 与全角（...）。只在内容命中词表时删，保留对话括号（如"(important note)"）。
    [GeneratedRegex(@"[\(（]\s*([^\)）]{1,48})\s*[\)）]", RegexOptions.IgnoreCase)]
    private static partial Regex NonSpeechMarkerRegex();

    // 方括号 / 书名号类音效标注：[...] 与【...】。这类几乎只用于音效/旁注，内容一律删除，不依赖词表
    //（支持 [음악]、[dramatic orchestral music]、【効果音】等任意语言）。
    [GeneratedRegex(@"[\[【]\s*[^\]】]{1,48}\s*[\]】]")]
    private static partial Regex BracketMarkerRegex();

    // 音符记号 ♪/♫：包裹歌词时只去掉符号本身，保留内部文字（"♪sing this line♪" → "sing this line"）。
    [GeneratedRegex(@"[♪♫]")]
    private static partial Regex MusicNoteRegex();

    // 广播/CART 字幕（CEA-608）的说话人切换标记：行首或空白后的 ">>"/">>>"（含全角 "＞"）。
    // 例如 ">> 从1949年开始…"。这类标记不是台词内容，应在清洗阶段去掉，
    // 否则会原样进入译文。仅匹配「行首」或「空白后」的连续 ≥2 个尖括号，避免误伤行内 "a>>b"。
    [GeneratedRegex(@"(?:^|\s)[>＞]{2,}\s*")]
    private static partial Regex SpeakerChangeMarkerRegex();

    [GeneratedRegex(@"[\p{L}\p{Nd}]+")]
    private static partial Regex WordTokenRegex();

    private static readonly HashSet<string> NonSpeechMarkerTerms = new(StringComparer.OrdinalIgnoreCase)
    {
        "music", "bgm", "backgroundmusic", "instrumentalmusic", "song", "singing", "sings", "lyrics",
        "musica", "música", "musique", "musik", "muziek", "музыка", "♪",
        "音乐", "音樂", "背景音乐", "背景音樂", "歌声", "歌聲",
        "applause", "applauding", "clapping", "claps", "applausecontinues", "clappingcontinues",
        "掌声", "掌聲", "掌声继续", "掌聲繼續", "鼓掌", "鼓掌声", "鼓掌聲", "拍手", "拍手声", "拍手聲",
        "laughter", "laugh", "laughs", "laughing", "chuckle", "chuckles", "chuckling", "giggle",
        "giggles", "giggling", "snicker", "snickers", "laughingcontinues",
        "笑", "笑声", "笑聲", "笑声继续", "笑聲繼續", "大笑", "轻笑", "輕笑", "哄笑", "偷笑", "笑い", "笑い声",
        "risa", "risas", "rire", "rires", "lachen", "gelächter", "웃음",
        "cry", "crying", "sobbing", "sob", "sobs", "weeping", "sniffles", "sniffling",
        "哭", "哭声", "哭聲", "哭泣", "啜泣", "抽泣", "llanto", "pleurs", "weinen",
        "cheer", "cheers", "cheering", "crowdcheering", "audiencecheering", "欢呼", "歡呼", "喝彩",
        "sigh", "sighs", "sighing", "叹气", "嘆氣", "叹息", "嘆息",
        "cough", "coughs", "coughing", "咳嗽",
        "sneeze", "sneezes", "sneezing", "喷嚏", "噴嚏", "打喷嚏", "打噴嚏",
        "gasp", "gasps", "gasping", "breathing", "heavybreathing", "panting", "喘息", "喘气", "喘氣", "呼吸声", "呼吸聲",
        "scream", "screams", "screaming", "yell", "yells", "groan", "groans", "groaning", "moan", "moans", "moaning",
        "尖叫", "喊叫", "呻吟", "低吟",
        "inaudible", "unintelligible", "silence", "silent", "noise", "noises", "static",
        "backgroundnoise", "ambientnoise", "murmur", "murmurs", "murmuring",
        "听不清", "聽不清", "无法听清", "無法聽清", "沉默", "静音", "靜音", "噪音", "杂音", "雜音", "背景音", "背景噪音",
        "dooropens", "doorcloses", "phonerings", "phoneringing", "ringing", "footsteps", "steps",
        "knocking", "knocks", "beep", "beeping", "bellrings", "alarm", "siren", "windblowing", "rainfalling",
        "门开", "門開", "开门", "開門", "关门", "關門", "门关", "門關", "脚步", "腳步", "脚步声", "腳步聲",
        "敲门", "敲門", "电话响", "電話響", "铃声", "鈴聲", "警报", "警報", "风声", "風聲", "雨声", "雨聲", "人群声", "人群聲",
    };

    /// <summary>
    /// 解析 SRT 文本为字幕条。按时间行锚定切条（而非按空行切块）：
    /// YouTube 滚动字幕的文本里常夹空行/纯空白行，按空行切块会把后半句当成
    /// 没有时间行的孤块整体丢掉。容忍 BOM、CRLF、多行文本、序号缺失（按顺序补号）；
    /// 文本为空的条目直接丢弃。
    /// </summary>
    public static List<SubtitleCue> ParseSrt(string raw)
    {
        var text = raw;
        if (text.StartsWith('\uFEFF')) text = text[1..];
        var lines = text.Replace("\r\n", "\n").Replace("\r", "\n").Split('\n');

        // 先找出所有时间行的位置；上一行若是纯数字则视为该条的显式序号。
        var anchors = new List<(int LineIndex, string Start, string End, int? ExplicitIndex, bool HasIndexLine)>();
        for (var i = 0; i < lines.Length; i++)
        {
            var match = TimeLineRegex().Match(lines[i]);
            if (!match.Success) continue;
            int? explicitIndex = null;
            if (i > 0 && int.TryParse(lines[i - 1].Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out var parsed))
            {
                explicitIndex = parsed;
            }
            anchors.Add((i, match.Groups[1].Value, match.Groups[2].Value, explicitIndex, explicitIndex.HasValue));
        }

        var cues = new List<SubtitleCue>();
        var nextIndex = 1;
        for (var a = 0; a < anchors.Count; a++)
        {
            var anchor = anchors[a];
            // 文本范围：本条时间行之后 → 下一条的序号行（或时间行）之前
            var textEnd = lines.Length;
            if (a + 1 < anchors.Count)
            {
                var next = anchors[a + 1];
                textEnd = next.HasIndexLine ? next.LineIndex - 1 : next.LineIndex;
            }
            var textStart = anchor.LineIndex + 1;
            if (textStart > textEnd) continue;
            var textLines = lines[textStart..Math.Min(textEnd, lines.Length)]
                .Select(l => l.Trim())
                .Where(l => l.Length > 0)
                .ToList();
            if (textLines.Count == 0) continue;
            var index = anchor.ExplicitIndex ?? nextIndex;
            cues.Add(new SubtitleCue(index, anchor.Start, anchor.End, string.Join("\n", textLines)));
            nextIndex = index + 1;
        }
        return cues;
    }

    /// <summary>序列化为标准 SRT 文本。</summary>
    public static string SerializeSrt(IEnumerable<SubtitleCue> cues) =>
        string.Join("\n\n", cues.Select(c => $"{c.Index}\n{c.Start} --> {c.End}\n{c.Text}")) + "\n";

    /// <summary>把 "HH:MM:SS,mmm"（或用 "." 作毫秒分隔）解析为秒。失败返回 null。</summary>
    public static double? SrtTimeToSeconds(string s)
    {
        var normalized = s.Replace(',', '.');
        var parts = normalized.Split(':');
        if (parts.Length != 3) return null;
        if (!int.TryParse(parts[0], NumberStyles.Integer, CultureInfo.InvariantCulture, out var h)) return null;
        if (!int.TryParse(parts[1], NumberStyles.Integer, CultureInfo.InvariantCulture, out var m)) return null;
        if (!double.TryParse(parts[2], NumberStyles.Float, CultureInfo.InvariantCulture, out var sec)) return null;
        return h * 3600.0 + m * 60.0 + sec;
    }

    /// <summary>秒转回 "HH:MM:SS,mmm"。</summary>
    public static string SecondsToSrtTime(double seconds)
    {
        var clamped = Math.Max(0, seconds);
        var totalMs = (long)Math.Round(clamped * 1000, MidpointRounding.AwayFromZero);
        var ms = totalMs % 1000;
        var totalSec = totalMs / 1000;
        var s = totalSec % 60;
        var m = totalSec / 60 % 60;
        var h = totalSec / 3600;
        return $"{h:00}:{m:00}:{s:00},{ms:000}";
    }

    /// <summary>
    /// 清洗字幕：
    /// (a) 解析时间戳为秒，按 start 稳定升序；
    /// (b) 去重叠：每条 end 截断到 min(自身 end, 下一条 start)，截断后 &lt;0.3s 则设为 start+0.3s；
    /// (c) 按句合并（仅对滚动字幕启用）：相邻碎条拼接，遇句末标点 / 累积≥6s / 累积≥84 字符断句；
    /// (d) 防误伤：合并后条数 ≥ 原条数则放弃合并，只返回去重叠结果；
    /// (e) 滚动判定（满足其一即按句合并）：时间戳重叠率 &gt; 50%（样式 A），
    ///     或相邻条文本重复率 &gt; 30%（样式 B：两行滚动窗口，先做文本去重再合并）。
    /// </summary>
    public static List<SubtitleCue> CleanCues(List<SubtitleCue> input)
    {
        if (input.Count == 0) return input;

        // (a) 解析时间 + 稳定升序排序
        var timed = new List<TimedCue>();
        for (var i = 0; i < input.Count; i++)
        {
            var start = SrtTimeToSeconds(input[i].Start);
            var end = SrtTimeToSeconds(input[i].End);
            if (start is null || end is null) continue;
            var text = StripNonSpeechMarkers(NormalizeSubtitleEscapes(input[i].Text));
            if (text.Length == 0) continue;
            timed.Add(new TimedCue(start.Value, Math.Max(end.Value, start.Value), text, i));
        }
        if (timed.Count == 0) return [];
        timed.Sort((x, y) => x.Start != y.Start ? x.Start.CompareTo(y.Start) : x.Order.CompareTo(y.Order));

        // (e) 滚动判定一：时间戳重叠（样式 A）——相邻条 start < 上一条 end 的比例 > 50%
        var overlapCount = 0;
        for (var i = 1; i < timed.Count; i++)
        {
            if (timed[i].Start < timed[i - 1].End) overlapCount++;
        }
        var overlapRatio = timed.Count >= 2 ? (double)overlapCount / (timed.Count - 1) : 0;

        // (e2) 滚动判定二：文本重复（样式 B）——每条开头重复上一条的尾行
        //（两行滚动窗口 + 10ms 过渡条，时间戳首尾相接不重叠，靠时间戳判不出来）。
        var textRepeatPairs = 0;
        for (var i = 1; i < timed.Count; i++)
        {
            var prev = timed[i - 1].Text.Split('\n');
            var cur = timed[i].Text.Split('\n');
            if (OverlapPrefixCount(prev, cur) > 0) textRepeatPairs++;
        }
        var textRepeatRatio = timed.Count >= 2 ? (double)textRepeatPairs / (timed.Count - 1) : 0;

        var isRolling = overlapRatio > 0.5 || textRepeatRatio > 0.3;

        // (a2) 样式 B 先做文本去重：删掉每条开头与上一条结尾重复的行，只留新增内容；
        //      删空的条目（纯过渡条）整条丢弃。对照对象用上一条的「原始」行，因为
        //      滚动窗口重复的是原文而非去重后的残句。阈值 0.3 防止误伤歌词等合法重复。
        if (textRepeatRatio > 0.3)
        {
            var deduped = new List<TimedCue>();
            var prevOriginalLines = Array.Empty<string>();
            foreach (var item in timed)
            {
                var curLines = item.Text.Split('\n');
                var k = OverlapPrefixCount(prevOriginalLines, curLines);
                prevOriginalLines = curLines;
                var newLines = curLines.Skip(k).ToArray();
                if (newLines.Length == 0) continue;
                deduped.Add(item with { Text = string.Join("\n", newLines) });
            }
            if (deduped.Count > 0) timed = deduped;
        }

        // (b) 去重叠：end 截断到下一条 start，过短则补到 start+0.3s（但不越过下一条 start）
        const double minDuration = 0.3;
        for (var i = 0; i < timed.Count; i++)
        {
            double? nextStart = i + 1 < timed.Count ? timed[i + 1].Start : null;
            var item = timed[i];
            if (nextStart is { } ns1)
            {
                item = item with { End = Math.Min(item.End, ns1) };
            }
            if (item.End - item.Start < minDuration)
            {
                var compensated = item.Start + minDuration;
                if (nextStart is { } ns2) compensated = Math.Min(compensated, ns2);
                item = item with { End = compensated };
            }
            timed[i] = item;
        }

        // 非滚动字幕：只做去重叠，不合并
        if (!isRolling) return MakeCues(timed);

        // (c) 按句合并：把碎条文本规整空白后用空格累积，满足任一断句条件即收一条
        var merged = new List<TimedCue>();
        var curText = "";
        var curStart = 0.0;
        var curEnd = 0.0;
        var hasCurrent = false;

        void Flush()
        {
            if (!hasCurrent) return;
            merged.Add(new TimedCue(curStart, curEnd, curText, merged.Count));
            hasCurrent = false;
            curText = "";
        }

        const double softDuration = 6.0;
        const int softCharacterBudget = 84;
        const double hardDuration = 18.0;
        const int hardCharacterBudget = 220;

        for (var i = 0; i < timed.Count; i++)
        {
            var t = timed[i];
            var piece = NormalizeWhitespace(t.Text);
            if (!hasCurrent)
            {
                curText = piece;
                curStart = t.Start;
                curEnd = t.End;
                hasCurrent = true;
            }
            else
            {
                curText = NormalizeWhitespace(curText + " " + piece);
                curEnd = t.End;
            }
            var nextPiece = i + 1 < timed.Count ? NormalizeWhitespace(timed[i + 1].Text) : null;
            double? nextGap = i + 1 < timed.Count ? timed[i + 1].Start - curEnd : null;
            var hardLimitReached = curEnd - curStart >= hardDuration || curText.Length >= hardCharacterBudget;
            var softLimitReached = curEnd - curStart >= softDuration || curText.Length >= softCharacterBudget;
            var shouldHoldForContinuation = LooksLikeContinuation(curText, nextPiece);
            if (EndsSentence(curText)
                || nextGap is > 1.2
                || hardLimitReached
                || (softLimitReached && !shouldHoldForContinuation))
            {
                Flush();
            }
        }
        Flush();

        // (d) 防误伤：合并后条数没减少则放弃合并
        return merged.Count < timed.Count ? MakeCues(merged) : MakeCues(timed);
    }

    private sealed record TimedCue(double Start, double End, string Text, int Order);

    private static List<SubtitleCue> MakeCues(List<TimedCue> items) =>
        items.Select((t, idx) => new SubtitleCue(
            idx + 1, SecondsToSrtTime(t.Start), SecondsToSrtTime(t.End), t.Text)).ToList();

    /// <summary>cur 开头与 prev 结尾重复的最大行数（两行滚动窗口的核心判据）。</summary>
    private static int OverlapPrefixCount(IReadOnlyList<string> prev, IReadOnlyList<string> cur)
    {
        var k = Math.Min(prev.Count, cur.Count);
        while (k > 0)
        {
            var equal = true;
            for (var i = 0; i < k; i++)
            {
                if (prev[prev.Count - k + i] != cur[i]) { equal = false; break; }
            }
            if (equal) return k;
            k--;
        }
        return 0;
    }

    private static string NormalizeWhitespace(string s)
    {
        var collapsed = string.Join(' ', s.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
        return RemoveSpacesBetweenCjkCharacters(collapsed);
    }

    /// <summary>
    /// 归一字幕转义：ASS/SRT 的 \N 硬换行 → 真换行；\h、&amp;nbsp;、不间断空格(NBSP) → 普通空格。
    /// 在清洗与翻译前统一，避免这些转义原样进入译文或干扰断句。
    /// </summary>
    private static string NormalizeSubtitleEscapes(string text) =>
        text.Replace("\\N", "\n")
            .Replace("\\n", "\n")
            .Replace("\\h", " ")
            .Replace("&nbsp;", " ")
            .Replace(' ', ' ');

    private static string RemoveSpacesBetweenCjkCharacters(string text)
    {
        if (text.Length < 3) return text;
        var builder = new StringBuilder(text.Length);
        for (var i = 0; i < text.Length; i++)
        {
            var ch = text[i];
            if (ch == ' ' && i > 0 && i < text.Length - 1 && IsCjkSubtitleCharacter(text[i - 1]) && IsCjkSubtitleCharacter(text[i + 1]))
            {
                continue;
            }
            builder.Append(ch);
        }
        return builder.ToString();
    }

    private static bool IsCjkSubtitleCharacter(char ch) =>
        ch is >= '\u3400' and <= '\u4DBF'
        or >= '\u4E00' and <= '\u9FFF'
        or >= '\u3040' and <= '\u30FF'
        or >= '\uAC00' and <= '\uD7AF';

    private static string StripNonSpeechMarkers(string text)
    {
        var lines = new List<string>();
        foreach (var rawLine in text.Split('\n'))
        {
            // 方括号 / 书名号标注：内容一律删（不查词表）。
            var line = BracketMarkerRegex().Replace(rawLine, " ");
            // 圆括号标注：仅当内容命中非语音词表才删，保留对话用括号。
            line = NonSpeechMarkerRegex().Replace(line, match =>
            {
                var marker = NormalizeNonSpeechMarker(match.Groups[1].Value);
                return NonSpeechMarkerTerms.Contains(marker) ? " " : match.Value;
            });
            // 音符记号：只去符号、保留歌词文字。
            line = MusicNoteRegex().Replace(line, " ");
            line = SpeakerChangeMarkerRegex().Replace(line, " ");
            line = NormalizeWhitespace(line);
            if (line.Length > 0) lines.Add(line);
        }
        return string.Join('\n', lines);
    }

    private static string NormalizeNonSpeechMarker(string raw)
    {
        var builder = new StringBuilder();
        foreach (var ch in raw.ToLowerInvariant())
        {
            if (char.IsWhiteSpace(ch) || ch is '-' or '_' or '.' or '!' or '?' or '！' or '？') continue;
            builder.Append(ch);
        }
        return builder.ToString();
    }

    private static readonly HashSet<char> SentenceEnders = ['.', '!', '?', '。', '！', '？'];
    private static readonly HashSet<char> TrailingAllowed = ['"', '\'', '”', '’', ')', '）', '」', '』', ']'];
    private static readonly HashSet<string> ContinuationStarts = new(StringComparer.OrdinalIgnoreCase)
    {
        "if", "that", "which", "who", "whom", "whose", "when", "where", "why", "how",
        "and", "or", "but", "because", "so", "then", "than", "to", "of", "for", "with",
        "as", "in", "on", "at", "by", "from", "do", "does", "did", "is", "are", "was",
        "were", "be", "been", "being", "have", "has", "had", "can", "could", "would",
        "will", "should", "may", "might", "must", "not",
    };
    private static readonly HashSet<string> ContinuationEnds = new(StringComparer.OrdinalIgnoreCase)
    {
        "the", "a", "an", "and", "or", "but", "if", "that", "which", "who", "what",
        "when", "where", "why", "how", "to", "of", "for", "with", "from", "as",
        "is", "are", "was", "were", "be", "been", "being", "do", "does", "did",
        "have", "has", "had", "can", "could", "would", "will", "should", "may",
        "might", "must", "we", "you", "i", "they", "he", "she", "it",
    };

    private static bool EndsSentence(string text)
    {
        var end = text.Length;
        // 跳过尾部的引号 / 括号
        while (end > 0 && (TrailingAllowed.Contains(text[end - 1]) || text[end - 1] == ' '))
        {
            end--;
        }
        return end > 0 && SentenceEnders.Contains(text[end - 1]);
    }

    private static bool LooksLikeContinuation(string current, string? nextPiece)
    {
        if (nextPiece is null || EndsSentence(current)) return false;
        var currentWords = WordTokens(current);
        var nextWords = WordTokens(nextPiece);
        if (currentWords.Count == 0 || nextWords.Count == 0) return false;
        return ContinuationEnds.Contains(currentWords[^1]) || ContinuationStarts.Contains(nextWords[0]);
    }

    private static List<string> WordTokens(string text) =>
        WordTokenRegex().Matches(text.ToLowerInvariant())
            .Select(match => match.Value)
            .ToList();

    /// <summary>
    /// 调试辅助：只清洗不翻译（解析 → CleanCues → 序列化），输出 "&lt;名&gt;.clean.srt"。
    /// 在不调 LLM 的情况下验证字幕清洗效果。
    /// </summary>
    public static (int Parsed, int Cleaned, string OutputPath) CleanSrtFile(string path)
    {
        string raw;
        try
        {
            raw = File.ReadAllText(path);
        }
        catch
        {
            throw MoongateException.TranslateFailed(L10n.T($"无法读取字幕文件：{Path.GetFileName(path)}",
                $"無法讀取字幕檔：{Path.GetFileName(path)}",
                $"Could not read the subtitle file: {Path.GetFileName(path)}"));
        }
        var parsed = ParseSrt(raw);
        if (parsed.Count == 0)
        {
            throw MoongateException.TranslateFailed(L10n.T("字幕文件里没有可识别的字幕内容。",
                "字幕檔中沒有可辨識的字幕內容。",
                "No recognizable subtitles in this file."));
        }
        var cleaned = CleanCues(parsed);
        var name = Path.GetFileName(path);
        var stem = name.EndsWith(".srt", StringComparison.OrdinalIgnoreCase) ? name[..^4] : name;
        var output = Path.Combine(Path.GetDirectoryName(path) ?? ".", stem + ".clean.srt");
        File.WriteAllText(output, SerializeSrt(cleaned));
        return (parsed.Count, cleaned.Count, output);
    }
}

// MARK: - LLM API 请求

/// <summary>一次模型调用的结果：文本 + 是否因为输出上限被截断。</summary>
internal sealed record ModelReply(string Text, bool ReachedOutputLimit);

/// <summary>
/// 翻译服务的 HTTP 协议层：Anthropic Messages 与 OpenAI Responses。
/// 全部方法接受可注入的 HttpMessageHandler（测试用 fake handler 断言请求形状与模拟响应）。
/// </summary>
public static class TranslationApi
{
    private static readonly HttpMessageHandler SharedHandler = new SocketsHttpHandler
    {
        PooledConnectionLifetime = TimeSpan.FromMinutes(5),
    };

    private static HttpClient MakeClient(HttpMessageHandler? handler, TimeSpan timeout) =>
        new(handler ?? SharedHandler, disposeHandler: false) { Timeout = timeout };

    private static readonly JsonSerializerOptions PayloadOptions = new()
    {
        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull,
    };

    // MARK: 工具

    internal static string NormalizedToken(string raw)
    {
        var token = raw.Trim();
        // 用户误把 "Bearer xxx" 整段贴进凭证框时剥掉前缀，避免双重 Bearer。
        if (token.StartsWith("bearer ", StringComparison.OrdinalIgnoreCase))
        {
            token = token["bearer ".Length..].Trim();
        }
        return token;
    }

    internal static Uri EndpointUrl(string baseUrl, string endpointPath)
    {
        var b = baseUrl.Trim();
        while (b.EndsWith('/')) b = b[..^1];

        var path = endpointPath.StartsWith('/') ? endpointPath : "/" + endpointPath;
        var lowerBase = b.ToLowerInvariant();
        var lowerPath = path.ToLowerInvariant();
        string urlString;
        if (lowerBase.EndsWith(lowerPath))
        {
            urlString = b;
        }
        else if (lowerBase.EndsWith("/v1") && lowerPath.StartsWith("/v1/"))
        {
            urlString = b + path["/v1".Length..];
        }
        else
        {
            urlString = b + path;
        }

        if (b.Length == 0
            || !Uri.TryCreate(urlString, UriKind.Absolute, out var url)
            || (url.Scheme != "http" && url.Scheme != "https")
            || string.IsNullOrEmpty(url.Host))
        {
            throw MoongateException.TranslateFailed(L10n.T("服务地址无效", "服務地址無效", "Invalid service URL"));
        }
        return url;
    }

    private static string ResponseErrorMessage(string body)
    {
        string? decoded = null;
        try
        {
            using var doc = JsonDocument.Parse(body);
            if (doc.RootElement.ValueKind == JsonValueKind.Object
                && doc.RootElement.TryGetProperty("error", out var error)
                && error.ValueKind == JsonValueKind.Object
                && error.TryGetProperty("message", out var message)
                && message.ValueKind == JsonValueKind.String)
            {
                decoded = message.GetString();
            }
        }
        catch
        {
            // 非 JSON 响应：走 fallback
        }
        var fallback = body.Length > 200 ? body[..200].Trim() : body.Trim();
        return decoded ?? (fallback.Length == 0 ? L10n.T("请求失败", "請求失敗", "Request failed") : fallback);
    }

    internal static string RequestFailureMessage(int statusCode, string body, AppSettings settings)
    {
        var message = ResponseErrorMessage(body);
        var lowerMessage = message.ToLowerInvariant();
        if (statusCode != 503 && !lowerMessage.Contains("no available accounts"))
        {
            return L10n.T($"HTTP {statusCode}：{message}", $"HTTP {statusCode}：{message}", $"HTTP {statusCode}: {message}");
        }

        var model = settings.TranslationModel.Trim();
        var modelTextZh = model.Length == 0 ? "已填写" : $"「{model}」";
        var modelTextZhHant = model.Length == 0 ? "已填寫" : $"「{model}」";
        var modelTextEn = model.Length == 0 ? "(empty)" : $"\"{model}\"";
        return L10n.T(
            $"HTTP {statusCode}：网关没有可用账号或模型映射未命中。请确认模型名 {modelTextZh} 在公司网关里已登记——点「拉取模型」选一个网关实际提供的模型。原始错误：{message}",
            $"HTTP {statusCode}：網關沒有可用帳號或模型映射未命中。請確認模型名稱 {modelTextZhHant} 已在公司網關登記，點「拉取模型」選一個網關實際提供的模型。原始錯誤：{message}",
            $"HTTP {statusCode}: the gateway has no available account or the model mapping was not found. Make sure model {modelTextEn} is registered on your gateway — use \"Fetch models\" to pick one it actually serves. Original error: {message}");
    }

    // MARK: 协议分发

    internal static Task<ModelReply> SendConfiguredMessageAsync(
        AppSettings settings, string? system, string userContent, int maxTokens,
        HttpMessageHandler? handler, CancellationToken ct) => settings.TranslationProvider switch
    {
        TranslationProvider.Anthropic => SendAnthropicMessageAsync(settings, system, userContent, maxTokens, handler, ct),
        _ => SendOpenAiResponseAsync(settings, system, userContent, maxTokens, handler, ct),
    };

    private static (string Model, string Token) RequireModelAndToken(AppSettings settings)
    {
        var model = settings.TranslationModel.Trim();
        if (model.Length == 0)
        {
            throw MoongateException.TranslateFailed(L10n.T("尚未配置模型，请在设置里填写模型名称。",
                "尚未設定模型，請在設定裡填寫模型名稱。",
                "No model configured. Enter a model name in Settings."));
        }
        var token = NormalizedToken(settings.TranslationAuthToken);
        if (token.Length == 0)
        {
            throw MoongateException.TranslateFailed(L10n.T("尚未配置 API 凭证，请在设置里填写。",
                "尚未設定 API 憑證，請在設定裡填寫。",
                "No API credential configured. Enter it in Settings."));
        }
        return (model, token);
    }

    /// <summary>
    /// 调一次 Anthropic Messages API，返回回复里所有 type=="text" 块拼接后的文本。
    /// 429/5xx 指数退避重试最多 2 次（2s、8s）；其余错误映射为 MoongateException。
    /// </summary>
    internal static async Task<ModelReply> SendAnthropicMessageAsync(
        AppSettings settings, string? system, string userContent, int maxTokens,
        HttpMessageHandler? handler, CancellationToken ct)
    {
        var (model, token) = RequireModelAndToken(settings);
        var url = EndpointUrl(settings.TranslationBaseUrl, "/v1/messages");
        var isOfficialAnthropic = string.Equals(url.Host, "api.anthropic.com", StringComparison.OrdinalIgnoreCase);

        var payload = new Dictionary<string, object?>
        {
            ["model"] = model,
            ["max_tokens"] = maxTokens,
            ["system"] = system,
            ["messages"] = new[] { new Dictionary<string, string> { ["role"] = "user", ["content"] = userContent } },
        };
        var body = JsonSerializer.Serialize(payload, PayloadOptions);

        HttpRequestMessage MakeRequest()
        {
            var request = new HttpRequestMessage(HttpMethod.Post, url)
            {
                Content = new StringContent(body, Encoding.UTF8, "application/json"),
            };
            request.Headers.Add("anthropic-version", "2023-06-01");
            // 官方 API 只认 x-api-key（两个鉴权头同时发会被拒）；其他网关两个都发以求兼容。
            request.Headers.Add("x-api-key", token);
            if (!isOfficialAnthropic)
            {
                request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
            }
            return request;
        }

        using var client = MakeClient(handler, TimeSpan.FromSeconds(120));
        return await SendWithRetryAsync(client, MakeRequest, settings, ParseAnthropicReply, ct).ConfigureAwait(false);
    }

    private static ModelReply ParseAnthropicReply(string json)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            if (root.TryGetProperty("content", out var content) && content.ValueKind == JsonValueKind.Array)
            {
                var parts = new List<string>();
                var sawText = false;
                foreach (var block in content.EnumerateArray())
                {
                    if (block.TryGetProperty("type", out var type) && type.GetString() == "text")
                    {
                        sawText = true;
                        if (block.TryGetProperty("text", out var text) && text.ValueKind == JsonValueKind.String)
                        {
                            parts.Add(text.GetString() ?? "");
                        }
                    }
                }
                if (sawText)
                {
                    var stopReason = root.TryGetProperty("stop_reason", out var sr) && sr.ValueKind == JsonValueKind.String
                        ? sr.GetString() : null;
                    return new ModelReply(string.Concat(parts), stopReason == "max_tokens");
                }
            }
        }
        catch (JsonException)
        {
            // 落到下面的协议错误
        }
        throw MoongateException.TranslateFailed(L10n.T("服务响应不符合 Anthropic Messages 协议，请检查服务地址。",
            "服務回應不符合 Anthropic Messages 協定，請檢查服務地址。",
            "The response does not match the Anthropic Messages protocol. Check the service URL."));
    }

    /// <summary>
    /// 调一次 OpenAI Responses API，返回 output_text 块拼接后的文本。
    /// 429/5xx 指数退避重试最多 2 次（2s、8s）；其余错误映射为 MoongateException。
    /// </summary>
    internal static async Task<ModelReply> SendOpenAiResponseAsync(
        AppSettings settings, string? instructions, string input, int maxOutputTokens,
        HttpMessageHandler? handler, CancellationToken ct)
    {
        var (model, token) = RequireModelAndToken(settings);
        var url = EndpointUrl(settings.TranslationBaseUrl, "/v1/responses");

        var payload = new Dictionary<string, object?>
        {
            ["model"] = model,
            ["instructions"] = instructions,
            ["input"] = input,
            ["max_output_tokens"] = maxOutputTokens,
            ["store"] = false,
        };
        var body = JsonSerializer.Serialize(payload, PayloadOptions);

        HttpRequestMessage MakeRequest()
        {
            var request = new HttpRequestMessage(HttpMethod.Post, url)
            {
                Content = new StringContent(body, Encoding.UTF8, "application/json"),
            };
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
            return request;
        }

        using var client = MakeClient(handler, TimeSpan.FromSeconds(120));
        return await SendWithRetryAsync(client, MakeRequest, settings, ParseOpenAiReply, ct).ConfigureAwait(false);
    }

    private static ModelReply ParseOpenAiReply(string json)
    {
        JsonDocument doc;
        try
        {
            doc = JsonDocument.Parse(json);
        }
        catch (JsonException)
        {
            throw MoongateException.TranslateFailed(L10n.T("服务响应不符合 OpenAI Responses 协议，请检查服务地址。",
                "服務回應不符合 OpenAI Responses 協定，請檢查服務地址。",
                "The response does not match the OpenAI Responses protocol. Check the service URL."));
        }
        using (doc)
        {
            var root = doc.RootElement;
            if (!root.TryGetProperty("output", out var output) || output.ValueKind != JsonValueKind.Array)
            {
                throw MoongateException.TranslateFailed(L10n.T("服务响应不符合 OpenAI Responses 协议，请检查服务地址。",
                    "服務回應不符合 OpenAI Responses 協定，請檢查服務地址。",
                    "The response does not match the OpenAI Responses protocol. Check the service URL."));
            }
            var textParts = new List<string>();
            foreach (var item in output.EnumerateArray())
            {
                if (!item.TryGetProperty("type", out var itemType) || itemType.GetString() != "message") continue;
                if (!item.TryGetProperty("content", out var content) || content.ValueKind != JsonValueKind.Array) continue;
                foreach (var block in content.EnumerateArray())
                {
                    var blockType = block.TryGetProperty("type", out var bt) ? bt.GetString() : null;
                    if (blockType != "output_text" && blockType != "text") continue;
                    if (block.TryGetProperty("text", out var text) && text.ValueKind == JsonValueKind.String)
                    {
                        textParts.Add(text.GetString() ?? "");
                    }
                }
            }
            var joined = string.Concat(textParts);
            if (joined.Length == 0)
            {
                throw MoongateException.TranslateFailed(L10n.T("OpenAI 响应里没有文本内容，请检查模型或服务地址。",
                    "OpenAI 回應中沒有文字內容，請檢查模型或服務地址。",
                    "The OpenAI response contains no text. Check the model or service URL."));
            }
            var status = root.TryGetProperty("status", out var st) && st.ValueKind == JsonValueKind.String ? st.GetString() : null;
            string? incompleteReason = null;
            if (root.TryGetProperty("incomplete_details", out var details) && details.ValueKind == JsonValueKind.Object
                && details.TryGetProperty("reason", out var reason) && reason.ValueKind == JsonValueKind.String)
            {
                incompleteReason = reason.GetString();
            }
            return new ModelReply(joined, status == "incomplete" && incompleteReason == "max_output_tokens");
        }
    }

    /// <summary>共用的发送 + 429/5xx 退避重试（2s、8s）+ 错误归一化。</summary>
    private static async Task<ModelReply> SendWithRetryAsync(
        HttpClient client,
        Func<HttpRequestMessage> makeRequest,
        AppSettings settings,
        Func<string, ModelReply> parse,
        CancellationToken ct)
    {
        var backoff = new[] { TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(8) };
        var attempt = 0;
        // 瞬时网络错误（连接被掐、超时）至少重试一次，与 macOS sendModelMessage 的瞬时重试对齐。
        var networkRetriesLeft = 1;
        while (true)
        {
            ct.ThrowIfCancellationRequested();
            string responseBody;
            int statusCode;
            try
            {
                using var request = makeRequest();
                using var response = await client.SendAsync(request, ct).ConfigureAwait(false);
                statusCode = (int)response.StatusCode;
                responseBody = await response.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                throw;
            }
            catch (Exception ex) when (ex is HttpRequestException or OperationCanceledException)
            {
                // HttpClient 超时（非外部取消）或连接错误：瞬时故障先重试，重试用尽才报错。
                if (networkRetriesLeft > 0)
                {
                    networkRetriesLeft--;
                    continue;
                }
                throw MoongateException.TranslateFailed(L10n.T("无法连接到翻译服务，请检查服务地址和网络。",
                    "無法連線到翻譯服務，請檢查服務地址與網路。",
                    "Could not reach the translation service. Check the service URL and your network."));
            }

            if (statusCode == 200)
            {
                return parse(responseBody);
            }
            var retryable = statusCode == 429 || statusCode is >= 500 and <= 599;
            if (retryable && attempt < backoff.Length)
            {
                await Task.Delay(backoff[attempt], ct).ConfigureAwait(false);
                attempt++;
                continue;
            }
            throw MoongateException.TranslateFailed(RequestFailureMessage(statusCode, responseBody, settings));
        }
    }

    // MARK: 连接测试 / 模型列表

    /// <summary>设置面板「测试连接」：发一条迷你请求，返回模型回复文本。</summary>
    public static async Task<string> TestConnectionAsync(
        AppSettings settings, HttpMessageHandler? handler = null, CancellationToken ct = default)
    {
        // 上限别给太小：推理型模型（gpt-5 / o 系列等）会先消耗思考 token，
        // 太小会导致可见输出为空、把"连接正常"误报成失败。
        var reply = await SendConfiguredMessageAsync(
            settings, system: null, userContent: "请只回复两个字：正常", maxTokens: 1024,
            handler, ct).ConfigureAwait(false);
        return reply.Text.Trim();
    }

    /// <summary>
    /// 用配置的云端模型生成中文视频内容概述（下载前判断是不是想要的视频）。
    /// source = 字幕全文或视频简介（可空）。与 macOS summarizeVideo 同构。
    /// </summary>
    public static async Task<string> SummarizeVideoAsync(
        string title,
        string? uploader,
        string? durationText,
        string? source,
        AppSettings settings,
        HttpMessageHandler? handler = null,
        CancellationToken ct = default)
    {
        const string system =
            "你是中文视频内容助手。根据用户给出的视频信息，用简体中文输出 3-5 句话的内容概述，" +
            "帮助用户在下载前判断这是不是自己想要的视频。只依据给出的信息，不要编造未提及的细节；" +
            "信息不足时如实说明。不要寒暄，不要使用 Markdown 列表，直接给概述。";

        var lines = new List<string> { $"标题：{title}" };
        if (!string.IsNullOrWhiteSpace(uploader)) lines.Add($"作者/频道：{uploader}");
        if (!string.IsNullOrWhiteSpace(durationText)) lines.Add($"时长：{durationText}");
        var trimmedSource = (source ?? "").Trim();
        if (trimmedSource.Length > 0)
        {
            // 控制 prompt 体量：超长字幕/简介截断，保留开头足够判断内容主题。
            var capped = trimmedSource.Length > 6000 ? trimmedSource[..6000] + "…（已截断）" : trimmedSource;
            lines.Add($"以下是该视频的字幕或简介内容：\n{capped}");
        }
        else
        {
            lines.Add("（没有可用的字幕或简介，只能依据标题等元信息概述。）");
        }
        var userContent = string.Join("\n", lines);

        var reply = await SendConfiguredMessageAsync(
            settings, system, userContent, maxTokens: 1500, handler, ct).ConfigureAwait(false);
        var text = reply.Text.Trim();
        if (text.Length == 0)
        {
            throw MoongateException.TranslateFailed(L10n.T(
                "AI 没有返回可用的总结内容，请稍后重试或更换模型。",
                "AI 沒有返回可用的摘要內容，請稍後重試或更換模型。",
                "The AI returned no summary. Try again later or switch models."));
        }
        return text;
    }

    /// <summary>
    /// 拉取服务端可用模型列表（GET {baseURL}/v1/models）。
    /// 官方 Anthropic 与 OpenAI、以及大多数企业网关都暴露这个端点；返回模型 id 数组。
    /// 只需服务地址 + 凭证，不需要先填模型。
    /// </summary>
    public static async Task<IReadOnlyList<string>> ListModelsAsync(
        AppSettings settings, HttpMessageHandler? handler = null, CancellationToken ct = default)
    {
        var token = NormalizedToken(settings.TranslationAuthToken);
        if (token.Length == 0)
        {
            throw MoongateException.TranslateFailed(L10n.T("尚未配置 API 凭证，请先填写凭证再拉取模型。",
                "尚未設定 API 憑證，請先填寫憑證再拉取模型。",
                "No API credential configured. Enter it before fetching models."));
        }
        var url = EndpointUrl(settings.TranslationBaseUrl, "/v1/models");
        // Anthropic 协议的 /v1/models 默认每页只回 20 条，不带 limit 会漏模型；
        // OpenAI 与多数网关会忽略未知查询参数，统一加上无副作用。
        if (string.IsNullOrEmpty(url.Query))
        {
            url = new UriBuilder(url) { Query = "limit=1000" }.Uri;
        }
        var isOfficialAnthropic = string.Equals(url.Host, "api.anthropic.com", StringComparison.OrdinalIgnoreCase);

        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        // 同时带两种鉴权头以兼容网关；官方 Anthropic 只认 x-api-key + version。
        request.Headers.Add("x-api-key", token);
        if (!isOfficialAnthropic)
        {
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        }
        request.Headers.Add("anthropic-version", "2023-06-01");

        using var client = MakeClient(handler, TimeSpan.FromSeconds(20));
        string body;
        int statusCode;
        try
        {
            using var response = await client.SendAsync(request, ct).ConfigureAwait(false);
            statusCode = (int)response.StatusCode;
            body = await response.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception e) when (e is HttpRequestException or OperationCanceledException)
        {
            throw MoongateException.TranslateFailed(L10n.T("无法连接到翻译服务，请检查服务地址和网络。",
                "無法連線到翻譯服務，請檢查服務地址與網路。",
                "Could not reach the translation service. Check the service URL and your network."));
        }

        if (statusCode != 200)
        {
            throw MoongateException.TranslateFailed(RequestFailureMessage(statusCode, body, settings));
        }
        var ids = ParseModelIds(body);
        if (ids.Count == 0)
        {
            throw MoongateException.TranslateFailed(L10n.T("服务返回的模型列表为空，请手动填写模型名。",
                "服務返回的模型清單為空，請手動填寫模型名稱。",
                "The service returned an empty model list. Enter a model name manually."));
        }
        return ids;
    }

    /// <summary>
    /// 解析 /v1/models 响应。兼容 OpenAI 风格 {"data":[{"id":...}]} 与 Anthropic 风格
    /// {"data":[{"id":...,"type":"model"}]}，以及个别网关的 {"models":[...]} / 纯数组。
    /// </summary>
    internal static List<string> ParseModelIds(string json)
    {
        JsonDocument doc;
        try
        {
            doc = JsonDocument.Parse(json);
        }
        catch (JsonException)
        {
            return [];
        }
        using (doc)
        {
            static List<string> Ids(JsonElement arr)
            {
                var result = new List<string>();
                foreach (var entry in arr.EnumerateArray())
                {
                    if (entry.ValueKind == JsonValueKind.String)
                    {
                        result.Add(entry.GetString() ?? "");
                    }
                    else if (entry.ValueKind == JsonValueKind.Object)
                    {
                        foreach (var key in new[] { "id", "name", "model" })
                        {
                            if (entry.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.String)
                            {
                                result.Add(v.GetString() ?? "");
                                break;
                            }
                        }
                    }
                }
                return result;
            }

            var root = doc.RootElement;
            if (root.ValueKind == JsonValueKind.Object)
            {
                if (root.TryGetProperty("data", out var data) && data.ValueKind == JsonValueKind.Array)
                {
                    return DedupePreservingOrder(Ids(data));
                }
                if (root.TryGetProperty("models", out var models) && models.ValueKind == JsonValueKind.Array)
                {
                    return DedupePreservingOrder(Ids(models));
                }
            }
            if (root.ValueKind == JsonValueKind.Array)
            {
                return DedupePreservingOrder(Ids(root));
            }
            return [];
        }
    }

    private static List<string> DedupePreservingOrder(List<string> items)
    {
        var seen = new HashSet<string>();
        var output = new List<string>();
        foreach (var item in items)
        {
            if (item.Length > 0 && seen.Add(item)) output.Add(item);
        }
        return output;
    }
}

// MARK: - ConfiguredTranslator

public enum TranslationPromptPreset
{
    General,
    SongLyrics,
    InterviewConversation,
    TutorialHowTo,
    LectureCourse,
    NewsExplainer,
    ReviewProduct,
    VlogLifestyle,
    ShortSocial,
    DocumentaryNarrative,
    GamingEntertainment,
}

public sealed record TranslationPromptAdvice(
    string Summary,
    string Context,
    IReadOnlyList<string> Terms,
    TranslationPromptPreset Preset);

/// <summary>
/// 通过设置里选择的协议翻译字幕。服务地址、模型、凭证全部来自 AppSettings。
/// handler 供测试注入 fake HTTP。
/// </summary>
public sealed class ConfiguredTranslator : ISubtitleTranslator
{
    private readonly AppSettings _settings;
    private readonly HttpMessageHandler? _handler;

    /// <summary>每次请求翻译的字幕条数。</summary>
    private const int ChunkSize = 30;
    /// <summary>最多同时在途的分块请求数。</summary>
    private const int MaxInFlight = 3;

    /// <summary>翻译系统提示词。目标语言由设置决定（简体中文 / 繁體中文 / English），不再写死。</summary>
    internal static string SystemPrompt(string targetLanguageDisplayName, TranslationPromptAdvice? advice = null)
        => SystemPrompt(targetLanguageDisplayName, sourceLanguageCode: null, advice);

    internal static string SystemPrompt(
        string targetLanguageDisplayName,
        string? sourceLanguageCode,
        TranslationPromptAdvice? advice = null)
    {
        // 点名源语言能让模型针对日语/韩语等谓语后置、修饰语前置的语言主动调整语序；未知源语言时退回不点名的措辞。
        var sourceLanguageDisplayName = TranslationLanguage.SourceDisplayName(sourceLanguageCode);
        var sourceClause = sourceLanguageDisplayName is { Length: > 0 }
            ? $"正在把{sourceLanguageDisplayName}字幕翻译成{targetLanguageDisplayName}"
            : $"把用户给出的字幕翻译成{targetLanguageDisplayName}";
        var prompt = $"你是专业字幕翻译，{sourceClause}。" +
            "输入每行格式为 编号|原文。请先通读整段，判断哪些相邻行其实属于同一句话。" +
            "输出必须严格逐行 编号|译文，行数与输入完全一致、编号不变，不要输出任何其他内容。\n" +
            "要求：\n" +
            "1) 按目标语言的自然语序表达，不要保留原文语序——尤其日语等谓语后置、修饰语/领属前置的语言，要把句尾谓语、被动施事、领属修饰语挪到目标语言的自然位置。\n" +
            "2) 一句话被拆到多行时，先在心里组成完整自然的译句，再按原行数在目标语言的自然停顿处切回各行；不要让某行停在「你的」「被你」这类悬空成分，也不要让某行变成没有主语或中心词的残句。当一句的谓语/动词落在靠后的行时，前面的行只翻译修饰语或状语，不要提前把动词译出来、造成相邻行重复同一个动作。\n" +
            "3) 口语自然、简洁，保留专有名词；只翻译原文已有的信息，不增不减。圆括号、方括号里的音效/旁注（如「(笑声)」「[音乐]」）若已残留在原文中，按原样保留对应译文，不要展开描写。";
        // 日语源语言额外给重排范例：抽象规则对弱模型不够稳，用具体「日文→自然中文」示例压制"逐行硬贴原文语序"的倒退。
        if (TranslationLanguage.NormalizedScript(sourceLanguageCode ?? "") == "ja")
        {
            prompt += "\n\n日文→中文重排示例（务必按中文语序，不要留悬空成分）：\n" +
                "- 「左隣、あなたの」「横顔を月が照らした」→「你坐在我的左侧」「月光映照着你的侧脸」（领属词上移，别让某行停在「你的」）\n" +
                "- 「確かにほら救われたんだよ」「あなたに」→「你看，我确实被拯救了」「是被你拯救的」（把谓语补完整，别让某行只剩「被你」）";
        }
        if (advice is null) return prompt;
        prompt += $"\n\n翻译前上下文：\n内容摘要：{advice.Summary}";
        if (advice.Context.Length > 0)
        {
            prompt += $"\n人物/场景/发生的事：{advice.Context}";
        }
        if (advice.Terms.Count > 0)
        {
            prompt += "\n专名参考：\n" + string.Join("\n", advice.Terms.Select(term => "- " + term));
        }
        prompt += "\n这些上下文只用于理解人物、专名、场景和主题；不要把上下文里没有对应原文的信息添加到某一行译文，仍按输入编号逐字逐句贴近原文翻译。";
        prompt += advice.Preset switch
        {
            TranslationPromptPreset.SongLyrics =>
                "\n这段字幕更接近歌曲、歌词或带旋律的演唱内容。翻译时优先保留画面感、情绪流动、意象和可吟唱的自然度；不必逐字贴着原句，但要守住原意、语气和每一句的情绪重心。若原文有重复、副歌或短句节奏，译文也尽量保留这种呼吸感。",
            TranslationPromptPreset.InterviewConversation =>
                "\n这段内容更像访谈或对话。翻译时优先保留说话人的口吻、犹豫、转折和真实交流感；句子可以自然顺一点，但不要把口语磨成书面报告。",
            TranslationPromptPreset.TutorialHowTo =>
                "\n这段内容更像教程或操作说明。翻译时优先让步骤、条件、按钮名和动作顺序清楚可跟做；语气保持简洁直接，技术词前后统一。",
            TranslationPromptPreset.LectureCourse =>
                "\n这段内容更像课程或讲座。翻译时优先保留概念层次、因果关系和术语一致性；表达可以更清楚，但不要把讲者的铺垫和重点压扁。",
            TranslationPromptPreset.NewsExplainer =>
                "\n这段内容更像新闻、评论或解释型视频。翻译时保持客观、克制、信息密度清楚；专名、数字、时间和因果关系要稳，避免额外立场。",
            TranslationPromptPreset.ReviewProduct =>
                "\n这段内容更像产品评测或体验分享。翻译时保留体验感、比较关系和优缺点的细微语气；规格、型号、功能名和结论要清楚一致。",
            TranslationPromptPreset.VlogLifestyle =>
                "\n这段内容更像 vlog 或生活记录。翻译时保留轻松自然的口吻、场景感和个人语气；不要过度正式，短句可以保持日常说话的节奏。",
            TranslationPromptPreset.ShortSocial =>
                "\n这段内容更像短视频或社交平台内容。翻译时优先保留节奏、梗、反差和情绪推进；可以使用更贴近目标语言的自然说法，但不要生造原文没有的信息。",
            TranslationPromptPreset.DocumentaryNarrative =>
                "\n这段内容更像纪录片或叙事旁白。翻译时保留画面感、时间线和叙事张力；用词可以更凝练，但要让信息和气氛都稳稳落在字幕里。",
            TranslationPromptPreset.GamingEntertainment =>
                "\n这段内容更像游戏或娱乐解说。翻译时保留即时反应、玩笑、术语和场面节奏；游戏名、角色名、机制名要一致，语气可以更有现场感。",
            _ => "\n根据摘要保持术语与语气一致，但仍以逐条字幕的准确翻译为准。",
        };
        return prompt;
    }

    internal static TranslationPromptAdvice? ParseTranslationPromptAdvice(string text)
    {
        var trimmed = text.Trim();
        string json;
        if (trimmed.StartsWith('{') && trimmed.EndsWith('}'))
        {
            json = trimmed;
        }
        else
        {
            var start = trimmed.IndexOf('{');
            var end = trimmed.LastIndexOf('}');
            if (start < 0 || end < start) return null;
            json = trimmed[start..(end + 1)];
        }
        try
        {
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            var summary = root.TryGetProperty("summary", out var s) && s.ValueKind == JsonValueKind.String
                ? s.GetString()?.Trim() ?? "" : "";
            var context = root.TryGetProperty("context", out var contextElement) && contextElement.ValueKind == JsonValueKind.String
                ? contextElement.GetString()?.Trim() ?? "" : "";
            var terms = new List<string>();
            if (root.TryGetProperty("terms", out var termsElement) && termsElement.ValueKind == JsonValueKind.Array)
            {
                foreach (var termElement in termsElement.EnumerateArray())
                {
                    if (termElement.ValueKind != JsonValueKind.String) continue;
                    var term = termElement.GetString()?.Trim() ?? "";
                    if (term.Length == 0) continue;
                    terms.Add(term);
                    if (terms.Count >= 8) break;
                }
            }
            var presetRaw = root.TryGetProperty("preset", out var p) && p.ValueKind == JsonValueKind.String
                ? p.GetString() ?? "" : "";
            if (summary.Length == 0) return null;
            var preset = presetRaw.Trim() switch
            {
                "songLyrics" => TranslationPromptPreset.SongLyrics,
                "interviewConversation" => TranslationPromptPreset.InterviewConversation,
                "tutorialHowTo" => TranslationPromptPreset.TutorialHowTo,
                "lectureCourse" => TranslationPromptPreset.LectureCourse,
                "newsExplainer" => TranslationPromptPreset.NewsExplainer,
                "reviewProduct" => TranslationPromptPreset.ReviewProduct,
                "vlogLifestyle" => TranslationPromptPreset.VlogLifestyle,
                "shortSocial" => TranslationPromptPreset.ShortSocial,
                "documentaryNarrative" => TranslationPromptPreset.DocumentaryNarrative,
                "gamingEntertainment" => TranslationPromptPreset.GamingEntertainment,
                _ => TranslationPromptPreset.General,
            };
            return new TranslationPromptAdvice(summary, context, terms, preset);
        }
        catch (JsonException)
        {
            return null;
        }
    }

    public ConfiguredTranslator(AppSettings settings, HttpMessageHandler? handler = null)
    {
        _settings = settings;
        _handler = handler;
    }

    public async Task<string> TranslateAsync(
        string srtFile,
        SubtitleStyle style,
        TaskControlToken? control,
        Action<double> progress,
        CancellationToken ct = default)
    {
        string raw;
        try
        {
            raw = await File.ReadAllTextAsync(srtFile, ct).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch
        {
            throw MoongateException.TranslateFailed(L10n.T($"无法读取字幕文件：{Path.GetFileName(srtFile)}",
                $"無法讀取字幕檔：{Path.GetFileName(srtFile)}",
                $"Could not read the subtitle file: {Path.GetFileName(srtFile)}"));
        }
        var parsed = SrtTools.ParseSrt(raw);
        if (parsed.Count == 0)
        {
            throw MoongateException.TranslateFailed(L10n.T("字幕文件里没有可识别的字幕内容。",
                "字幕檔中沒有可辨識的字幕內容。",
                "No recognizable subtitles in this file."));
        }
        // 翻译前清洗：消除 YouTube 自动字幕的重叠滚动碎句、按句合并，减少疯狂刷新。
        var cues = SrtTools.CleanCues(parsed);
        // 智能提示词开启且字幕像逐字无标点的 ASR 自动字幕时，先重分段成完整句子再翻译，
        // 显著改善翻译质量与可读性。重分段失败（对齐不上）会原样返回，不影响后续。
        if (_settings.SmartTranslationPromptsEnabled && LooksLikeAutoCaption(cues))
        {
            cues = await ResegmentForReadabilityAsync(cues, ct).ConfigureAwait(false);
        }
        // 源语言从文件名推断（如 "video.ja.srt" → "ja"），用于给提示词点名源语言并触发日语重排示例。
        var sourceLanguageCode = TranslationLanguage.SourceLanguageIdentifierFromSubtitleFile(srtFile);
        var advice = await MakeTranslationPromptAdviceAsync(cues, ct).ConfigureAwait(false);

        // 分块并行请求（最多 3 个在途）：编号用全局序号（1 起），回贴与完成顺序无关。
        // 每调度一个新块前过一次 gate（暂停挂起 / 取消抛出）；在途块自然跑完。
        var chunkRanges = new List<(int Start, int Count)>();
        var rangeStart = 0;
        while (rangeStart < cues.Count)
        {
            var upper = Math.Min(rangeStart + ChunkSize, cues.Count);
            chunkRanges.Add((rangeStart, upper - rangeStart));
            rangeStart = upper;
        }

        var merged = new Dictionary<int, string>();
        var completedCues = 0;
        // 某块失败时取消兄弟块（等价 Swift TaskGroup 的隐式取消），避免白白烧 token。
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(ct);
        var inFlight = new List<Task<((int Start, int Count) Range, Dictionary<int, string> Map)>>();
        var nextChunk = 0;

        async Task ScheduleNextAsync()
        {
            if (nextChunk >= chunkRanges.Count) return;
            ct.ThrowIfCancellationRequested();
            if (control is not null) await control.GateAsync(ct).ConfigureAwait(false);
            var range = chunkRanges[nextChunk];
            nextChunk++;
            var token = linked.Token;
            inFlight.Add(Task.Run(async () =>
            {
                var mapping = await TranslateChunkAsync(
                    cues, range.Start, range.Count, range.Start + 1, advice, sourceLanguageCode, depth: 0, token).ConfigureAwait(false);
                return (range, mapping);
            }, token));
        }

        try
        {
            for (var i = 0; i < Math.Min(MaxInFlight, chunkRanges.Count); i++)
            {
                await ScheduleNextAsync().ConfigureAwait(false);
            }
            while (inFlight.Count > 0)
            {
                var done = await Task.WhenAny(inFlight).ConfigureAwait(false);
                inFlight.Remove(done);
                var (range, mapping) = await done.ConfigureAwait(false);
                foreach (var pair in mapping) merged[pair.Key] = pair.Value;
                completedCues += range.Count;
                progress((double)completedCues / cues.Count);
                await ScheduleNextAsync().ConfigureAwait(false);
            }
        }
        catch
        {
            linked.Cancel();
            // 等在途块收敛，避免悬挂任务在测试/退出时乱抛
            try { await Task.WhenAll(inFlight).ConfigureAwait(false); } catch { /* 已取消 */ }
            throw;
        }

        var output = cues.Select(c => new SubtitleCue(c.Index, c.Start, c.End, c.Text)).ToList();
        for (var cueIndex = 0; cueIndex < cues.Count; cueIndex++)
        {
            if (!merged.TryGetValue(cueIndex + 1, out var rawChinese))
            {
                throw MoongateException.TranslateFailed(L10n.T("模型返回格式异常，缺失译文行",
                    "模型返回格式異常，缺少譯文行",
                    "Malformed model reply: translation lines are missing"));
            }
            var chinese = SanitizeTranslation(rawChinese);
            if (chinese.Length == 0)
            {
                throw MoongateException.TranslateFailed(L10n.T("模型返回格式异常，缺失译文行",
                    "模型返回格式異常，缺少譯文行",
                    "Malformed model reply: translation lines are missing"));
            }
            output[cueIndex].Text = style switch
            {
                // 中文在上、原文在下（烧录时原文用更小字号）
                SubtitleStyle.Bilingual => chinese + "\n" + cues[cueIndex].Text,
                _ => chinese,
            };
        }

        // 写 "<原文件名去.srt>.<target>.srt"
        var name = Path.GetFileName(srtFile);
        var stem = name.EndsWith(".srt", StringComparison.OrdinalIgnoreCase) ? name[..^4] : name;
        var outputPath = Path.Combine(
            Path.GetDirectoryName(srtFile) ?? ".",
            stem + TranslationLanguage.TranslatedSubtitleFileSuffix(_settings.TranslationTargetLanguage));
        try
        {
            await File.WriteAllTextAsync(outputPath, SrtTools.SerializeSrt(output), ct).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception e)
        {
            throw MoongateException.TranslateFailed(L10n.T($"无法写入译文文件：{e.Message}",
                $"無法寫入譯文檔案：{e.Message}",
                $"Could not write the translated file: {e.Message}"));
        }
        return outputPath;
    }

    /// <summary>
    /// 翻译一块字幕，返回 [全局编号: 译文]。
    /// 译文被输出上限截断时按减半的条数自动重试：最多再分两层、每块最小 8 条；仍截断则抛错。
    /// 只要译文缺失行即视为模型返回格式异常，抛错而不是静默保留原文。
    /// </summary>
    private async Task<Dictionary<int, string>> TranslateChunkAsync(
        IReadOnlyList<SubtitleCue> allCues, int offset, int count, int startNumber,
        TranslationPromptAdvice? advice, string? sourceLanguageCode, int depth,
        CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        var userContent = string.Join("\n", Enumerable.Range(0, count)
            .Select(i => $"{startNumber + i}|{Flattened(allCues[offset + i].Text)}"));

        var reply = await TranslationApi.SendConfiguredMessageAsync(
            _settings, SystemPrompt(TranslationLanguage.DisplayName(_settings.TranslationTargetLanguage), sourceLanguageCode, advice),
            userContent, maxTokens: 8000, _handler, ct).ConfigureAwait(false);
        if (reply.ReachedOutputLimit)
        {
            var half = count / 2;
            if (depth < 2 && half >= 8)
            {
                var mergedMap = await TranslateChunkAsync(
                    allCues, offset, half, startNumber, advice, sourceLanguageCode, depth + 1, ct).ConfigureAwait(false);
                var second = await TranslateChunkAsync(
                    allCues, offset + half, count - half, startNumber + half, advice, sourceLanguageCode, depth + 1, ct).ConfigureAwait(false);
                foreach (var pair in second) mergedMap[pair.Key] = pair.Value;
                return mergedMap;
            }
            // 无法再二分（块已很小或递归到底）：逐行补漏，每行单独请求，仍失败的行回退原文。
            return await RepairMissingTranslationsAsync(
                allCues, offset, count, startNumber, new Dictionary<int, string>(),
                advice, sourceLanguageCode, ct).ConfigureAwait(false);
        }

        var map = ParseReply(reply.Text);
        var missing = Enumerable.Range(startNumber, count)
            .Count(n => !map.TryGetValue(n, out var v) || v.Length == 0);
        if (missing > 0)
        {
            var half = count / 2;
            if (depth < 2 && half >= 8)
            {
                var mergedMap = await TranslateChunkAsync(
                    allCues, offset, half, startNumber, advice, sourceLanguageCode, depth + 1, ct).ConfigureAwait(false);
                var second = await TranslateChunkAsync(
                    allCues, offset + half, count - half, startNumber + half, advice, sourceLanguageCode, depth + 1, ct).ConfigureAwait(false);
                foreach (var pair in second) mergedMap[pair.Key] = pair.Value;
                return mergedMap;
            }
            // 无法再二分：对缺失行逐行补齐，仍失败则回退原文，整体不归零、不抛错。
            return await RepairMissingTranslationsAsync(
                allCues, offset, count, startNumber, map,
                advice, sourceLanguageCode, ct).ConfigureAwait(false);
        }
        return map;
    }

    /// <summary>
    /// 对块内缺失译文的行逐行单独请求补齐（与 macOS RepairMissingTranslations 对齐）。
    /// 单行请求失败或仍为空时回退原文，保证整体翻译不因个别行失败而归零。
    /// </summary>
    private async Task<Dictionary<int, string>> RepairMissingTranslationsAsync(
        IReadOnlyList<SubtitleCue> allCues, int offset, int count, int startNumber,
        Dictionary<int, string> currentMap, TranslationPromptAdvice? advice,
        string? sourceLanguageCode, CancellationToken ct)
    {
        var repaired = new Dictionary<int, string>(currentMap);
        for (var i = 0; i < count; i++)
        {
            ct.ThrowIfCancellationRequested();
            var number = startNumber + i;
            if (repaired.TryGetValue(number, out var existing) && existing.Length > 0) continue;
            var original = Flattened(allCues[offset + i].Text);
            try
            {
                var reply = await TranslationApi.SendConfiguredMessageAsync(
                    _settings,
                    SystemPrompt(TranslationLanguage.DisplayName(_settings.TranslationTargetLanguage), sourceLanguageCode, advice),
                    $"{number}|{original}", maxTokens: 1200, _handler, ct).ConfigureAwait(false);
                var retryMap = ParseReply(reply.Text);
                var retryText = retryMap.TryGetValue(number, out var v) ? v.Trim() : "";
                repaired[number] = retryText.Length > 0 ? retryText : original;
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                throw;
            }
            catch
            {
                repaired[number] = original;
            }
        }
        return repaired;
    }

    private async Task<TranslationPromptAdvice?> MakeTranslationPromptAdviceAsync(
        IReadOnlyList<SubtitleCue> cues,
        CancellationToken ct)
    {
        if (!_settings.SmartTranslationPromptsEnabled) return null;
        // 增强模式依赖可生成文本的总结模型；未配置则给出可操作的报错，而不是默默发空请求。
        if (!_settings.IsSummaryConfigured)
        {
            throw MoongateException.TranslateFailed(L10n.T(
                "增强模式需要可生成文本的总结模型，请在 AI 总结设置里填写模型。",
                "增強模式需要可生成文字的摘要模型，請在 AI 摘要設定裡填寫模型。",
                "Enhanced mode requires a summary model that can generate text. Configure a summary model in AI summary settings."));
        }
        var system =
            "你是字幕内容分析器。根据字幕判断视频内容类型，并只输出 JSON：" +
            "{\"summary\":\"不超过80字的中文摘要\",\"context\":\"不超过160字，写清人物、组织、场景、发生的事和主题\",\"terms\":[\"原文专名或术语：目标语言说明，最多8个\"],\"preset\":\"general|songLyrics|interviewConversation|tutorialHowTo|lectureCourse|newsExplainer|reviewProduct|vlogLifestyle|shortSocial|documentaryNarrative|gamingEntertainment\"}。" +
            "summary 写整体内容；context 写会影响翻译的背景，不要编造字幕没有支持的信息；terms 只放字幕里出现或能高置信识别的专名、人物、组织、作品名、品牌、术语，不确定官方译名时保留原文写法并说明不确定。" +
            "preset 选择最贴近的一个：歌曲/歌词/MV 用 songLyrics；访谈播客对话用 interviewConversation；教程操作演示用 tutorialHowTo；课程讲座用 lectureCourse；新闻评论解释用 newsExplainer；产品评测体验用 reviewProduct；vlog 生活记录用 vlogLifestyle；短视频社交平台内容用 shortSocial；纪录片旁白叙事用 documentaryNarrative；游戏或娱乐解说用 gamingEntertainment；无法判断用 general。不要输出 Markdown。";
        var userContent = $"目标译文语言：{TranslationLanguage.DisplayName(_settings.TranslationTargetLanguage)}\n" +
            "字幕内容分析样本：\n" + SubtitleAnalysisSample(cues);
        var reply = await TranslationApi.SendConfiguredMessageAsync(
            _settings.ForSummary(), system, userContent, maxTokens: 1200, _handler, ct).ConfigureAwait(false);
        return ParseTranslationPromptAdvice(reply.Text)
            ?? throw MoongateException.TranslateFailed(L10n.T(
                "增强模式分析返回格式异常，请重试或关闭增强模式。",
                "增強模式分析返回格式異常，請重試或關閉增強模式。",
                "Enhanced mode analysis returned an invalid format. Try again or turn off enhanced mode."));
    }

    private static string SubtitleAnalysisSample(IReadOnlyList<SubtitleCue> cues)
    {
        var text = string.Join("\n", cues.Take(120).Select(c => Flattened(c.Text)));
        return text.Length > 6000 ? text[..6000] + "…（已截断）" : text;
    }

    /// <summary>
    /// 字幕条内部换行折叠成一行发给模型。用空格连接（旧版用 " / " 会被模型原样抄进译文，
    /// 出现「可你要真想玩 / 《马力欧赛车 世界》」这种把分隔符当正文的脏输出）。
    /// </summary>
    internal static string Flattened(string text) =>
        string.Join(" ", text
            .Replace("\\N", "\n")
            .Replace("\\n", "\n")
            .Replace("\\h", " ")
            .Replace("&nbsp;", " ")
            .Replace(" ", " ")
            .Split('\n')
            .Select(l => l.Trim())
            .Where(l => l.Length > 0));

    /// <summary>
    /// 清洗单行译文：去掉模型偶尔自加的行首对话破折号（原文并无），并兜底去掉残留的 " / " 分隔符。
    /// 与 macOS sanitizeTranslation 同构。
    /// </summary>
    internal static string SanitizeTranslation(string raw)
    {
        var t = raw.Trim();
        // 行首对话破折号（"- " / "– " / "— "）：原文没有时模型有时会自加，去掉。
        while (t.Length > 0 && (t[0] == '-' || t[0] == '–' || t[0] == '—'))
        {
            t = t[1..].Trim();
        }
        // 兜底：把残留的 " / " 折叠分隔符还原成自然停顿（正常译文不会出现）。
        t = t.Replace(" / ", "，");
        t = RemoveChineseTerminalPeriod(t);
        return t.Trim();
    }

    private static string RemoveChineseTerminalPeriod(string text)
    {
        var t = text.Trim();
        var closers = "";
        while (t.Length > 0 && t[^1] is '"' or '\'' or '”' or '’' or ')' or '）' or '」' or '』' or ']' or '】')
        {
            closers = t[^1] + closers;
            t = t[..^1];
        }
        if (t.EndsWith('。')) t = t[..^1];
        return t + closers;
    }

    /// <summary>把模型回复按行解析为 [编号: 译文]；不合规的行忽略。</summary>
    internal static Dictionary<int, string> ParseReply(string reply)
    {
        var map = new Dictionary<int, string>();
        foreach (var line in reply.Split('\n', '\r'))
        {
            if (line.Length == 0) continue;
            var separator = line.IndexOf('|');
            if (separator < 0) continue;
            if (!int.TryParse(line[..separator].Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out var number)) continue;
            map[number] = line[(separator + 1)..].Trim();
        }
        return map;
    }

    /// <summary>
    /// 把一条「双语长 cue」（中文行 + 原文行）按句切成多片，时间在原区间内按累计字符比例插值。
    /// 中文按中日标点断句，原文按英文句末标点断句；两侧句子等数配对，每片 Text = "中文\n原文"。
    /// 无损：所有片的中文/原文分别拼接后与输入一致（不丢字不增字）。
    /// </summary>
    internal static List<SubtitleCue> SplitTranslatedCueBySentence(
        string zhText, string sourceText, string startSrt, string endSrt)
    {
        var zhSentences = SplitIntoSentences(zhText);
        var srcSentences = SplitIntoSentences(sourceText);
        // 句数不等无法稳妥配对：退回单片，保持原样不拆。
        if (zhSentences.Count == 0 || zhSentences.Count != srcSentences.Count)
        {
            return [new SubtitleCue(1, startSrt, endSrt,
                $"{zhText.Trim()}\n{sourceText.Trim()}".Trim())];
        }

        var startSec = SrtTools.SrtTimeToSeconds(startSrt) ?? 0;
        var endSec = SrtTools.SrtTimeToSeconds(endSrt) ?? startSec;
        var totalChars = zhSentences.Sum(s => s.Length);
        if (totalChars <= 0) totalChars = 1;

        var pieces = new List<SubtitleCue>();
        var accChars = 0;
        for (var i = 0; i < zhSentences.Count; i++)
        {
            var pieceStart = i == 0
                ? startSec
                : startSec + (endSec - startSec) * accChars / totalChars;
            accChars += zhSentences[i].Length;
            var pieceEnd = i == zhSentences.Count - 1
                ? endSec
                : startSec + (endSec - startSec) * accChars / totalChars;
            pieces.Add(new SubtitleCue(
                i + 1,
                SrtTools.SecondsToSrtTime(pieceStart),
                SrtTools.SecondsToSrtTime(pieceEnd),
                $"{zhSentences[i]}\n{srcSentences[i]}"));
        }
        return pieces;
    }

    /// <summary>把文本按句末标点切成句子，标点归属前句；保留句内原字符，不做 trim 之外的改动。</summary>
    private static readonly HashSet<char> SentenceEndPunctuation = ['.', '!', '?', '。', '！', '？', '…'];

    private static List<string> SplitIntoSentences(string text)
    {
        var sentences = new List<string>();
        var current = new StringBuilder();
        foreach (var ch in text)
        {
            current.Append(ch);
            if (SentenceEndPunctuation.Contains(ch))
            {
                var piece = current.ToString().Trim();
                if (piece.Length > 0) sentences.Add(piece);
                current.Clear();
            }
        }
        var tail = current.ToString().Trim();
        if (tail.Length > 0) sentences.Add(tail);
        return sentences;
    }

    // MARK: - ASR 字幕重分段（resegment for readability）
    // 这里把整段转写发给模型断句，再把断好的句子「严格对齐」回原始 token 序列，
    // 用每个 token 所在原 cue 的本地时间线性插值，重建带正确时间轴的整句字幕。
    // 对齐失败（模型擅自改词/漏词）时原样返回输入，绝不产出错位时间轴。

    // 单次发给模型的最多原始 cue 数（在 cue 边界切块，保证插值时 token 不跨块丢失上下文）。
    private const int ResegmentChunkCues = 25;
    // 单条重分段字幕的安全时长上限（秒）：超过且 token 足够多时再切，避免一条字幕长到糊屏。
    private const double ResegmentMaxSegmentSeconds = 6.0;
    // 只有 token 数达到此值的段才考虑按时长再切（避免把稀疏长 cue 里的极短句强行劈开）。
    private const int ResegmentMinSplitTokens = 6;
    // 合并判据：一段同时「时长 < 此秒数」且「token < 下面的 token 数」才算碎句，并入前一段。
    private const double ResegmentMinSegmentSeconds = 3.0;
    private const int ResegmentMinMergeTokens = 3;

    /// <summary>归一化单个 token 用于对齐比较：小写 + 去掉首尾标点（保留内部，如 well-known）。</summary>
    private static string NormalizeAlignToken(string raw)
    {
        var lower = raw.ToLowerInvariant();
        int start = 0, end = lower.Length;
        while (start < end && !char.IsLetterOrDigit(lower[start])) start++;
        while (end > start && !char.IsLetterOrDigit(lower[end - 1])) end--;
        return lower[start..end];
    }

    /// <summary>把文本拆成「词 token」：按空白切分后丢弃归一化后为空的纯标点 token。</summary>
    private static List<string> AlignTokens(string text) =>
        text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries)
            .Where(t => NormalizeAlignToken(t).Length > 0)
            .ToList();

    /// <summary>展平后的单个 token：归一化文本 + 所属原 cue 索引 + 在该 cue 内的位置（用于本地时间插值）。</summary>
    private readonly record struct FlatToken(string Norm, int CueIndex, int PosInCue, int CueTokenCount);

    /// <summary>把一段（连续若干原 cue）展平为带定位信息的 token 序列。</summary>
    private static List<FlatToken> FlattenCueTokens(IReadOnlyList<SubtitleCue> cues, int start, int count)
    {
        var flat = new List<FlatToken>();
        for (var c = start; c < start + count; c++)
        {
            var tokens = AlignTokens(Flattened(cues[c].Text));
            for (var i = 0; i < tokens.Count; i++)
            {
                flat.Add(new FlatToken(NormalizeAlignToken(tokens[i]), c, i, tokens.Count));
            }
        }
        return flat;
    }

    /// <summary>
    /// 一个 token 的「时间点」：用它所在原 cue 的本地时间线性插值。
    /// edge=false 取 token 起点（pos/count），edge=true 取 token 终点（(pos+1)/count）。
    /// </summary>
    private static double TokenTime(IReadOnlyList<SubtitleCue> cues, FlatToken token, bool edge)
    {
        var cue = cues[token.CueIndex];
        var s = SrtTools.SrtTimeToSeconds(cue.Start) ?? 0;
        var e = SrtTools.SrtTimeToSeconds(cue.End) ?? s;
        if (token.CueTokenCount <= 0 || e <= s) return edge ? e : s;
        var frac = (double)(edge ? token.PosInCue + 1 : token.PosInCue) / token.CueTokenCount;
        return s + (e - s) * frac;
    }

    /// <summary>
    /// 把一块原 cue 的转写文本发给模型断句，返回模型给出的句子列表（已按 | 解析、按编号排序）。
    /// 命中输出上限（max_tokens）时把这块的 cue 数减半递归重试；最小到 1 条仍截断则用原文兜底。
    /// </summary>
    private async Task<List<string>> SegmentChunkAsync(
        IReadOnlyList<SubtitleCue> cues, int start, int count, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        var transcript = string.Join(" ",
            Enumerable.Range(start, count).Select(c => Flattened(cues[c].Text)));
        const string systemPreamble =
            "你是字幕断句助手。下面是一段逐字、缺少标点的自动语音字幕转写。" +
            "请在不改动、不增减、不翻译任何词的前提下，仅添加标点并按完整句子重新断行，" +
            "每个完整句子输出为一行，格式严格为 编号|句子（编号从 1 递增）。" +
            "只能输出这些行，不要解释。\n待断句文本：\n";
        var system = systemPreamble + transcript;

        var reply = await TranslationApi.SendConfiguredMessageAsync(
            _settings, system, transcript, maxTokens: 4000, _handler, ct).ConfigureAwait(false);

        if (reply.ReachedOutputLimit)
        {
            if (count <= 1)
            {
                // 单条仍截断：无法再切小，退回原文这一条，保证整体不丢内容。
                return [Flattened(cues[start].Text)];
            }
            var half = count / 2;
            var first = await SegmentChunkAsync(cues, start, half, ct).ConfigureAwait(false);
            var second = await SegmentChunkAsync(cues, start + half, count - half, ct).ConfigureAwait(false);
            return [.. first, .. second];
        }

        var map = ParseReply(reply.Text);
        var sentences = map.OrderBy(kv => kv.Key)
            .Select(kv => kv.Value.Trim())
            .Where(v => v.Length > 0)
            .ToList();
        return sentences.Count > 0 ? sentences : [transcript];
    }

    /// <summary>
    /// ASR 判定：像逐字无标点的自动字幕才重分段，尽量避免误伤正常字幕/歌词。
    /// 需同时满足：(1) cue 数足够多；(2) 带句末标点的 cue 比例很低；
    /// (3) 平均时长偏短（碎句特征）；(4) 整体几乎没有换行（ASR 每条单行碎词）。
    /// 与 macOS looksLikeAutoCaption 同构。
    /// </summary>
    internal static bool LooksLikeAutoCaption(IReadOnlyList<SubtitleCue> cues)
    {
        if (cues.Count < 8) return false;
        var enders = new HashSet<char> { '.', '!', '?', '。', '！', '？' };
        var closers = new HashSet<char> { '"', '\'', '”', '’', ')', '）', '」', '』', ']', '】' };
        bool EndsWithPunct(string text)
        {
            var end = text.Length;
            while (end > 0 && (closers.Contains(text[end - 1]) || text[end - 1] == ' ')) end--;
            return end > 0 && enders.Contains(text[end - 1]);
        }
        var punctuated = cues.Count(c => EndsWithPunct(c.Text));
        if ((double)punctuated / cues.Count >= 0.15) return false;

        // 平均时长：ASR 碎句通常每条很短；过长（≥6s/条）更像已成句的正常字幕。
        var totalDuration = 0.0;
        var measured = 0;
        foreach (var cue in cues)
        {
            var s = SrtTools.SrtTimeToSeconds(cue.Start);
            var e = SrtTools.SrtTimeToSeconds(cue.End);
            if (s is null || e is null || e <= s) continue;
            totalDuration += e.Value - s.Value;
            measured++;
        }
        var avgDuration = measured > 0 ? totalDuration / measured : 0;
        if (measured > 0 && avgDuration >= 6.0) return false;

        // 多行比例：ASR 自动字幕基本每条单行；大量多行排版更像人工字幕。
        var multiline = cues.Count(c => c.Text.Contains('\n'));
        if ((double)multiline / cues.Count >= 0.5) return false;
        return true;
    }

    /// <summary>
    /// ASR 字幕重分段：把逐字无标点的自动字幕重新断成完整句子，保留原始时间轴。
    /// 对齐失败（模型改词/漏词）时原样返回输入，绝不产出错位时间轴。
    /// </summary>
    public async Task<List<SubtitleCue>> ResegmentForReadabilityAsync(
        IReadOnlyList<SubtitleCue> cues, CancellationToken ct)
    {
        if (cues.Count == 0) return [];

        // 1) 在 cue 边界分块请求断句，拼出全部句子。
        var sentences = new List<string>();
        for (var start = 0; start < cues.Count; start += ResegmentChunkCues)
        {
            var count = Math.Min(ResegmentChunkCues, cues.Count - start);
            var chunk = await SegmentChunkAsync(cues, start, count, ct).ConfigureAwait(false);
            sentences.AddRange(chunk);
        }

        // 2) 展平原始 token，并把所有句子的 token 顺序拼接，逐 token 严格对齐。
        var flat = FlattenCueTokens(cues, 0, cues.Count);
        var sentenceTokenCounts = new List<int>();
        var alignedNorms = new List<string>();
        foreach (var sentence in sentences)
        {
            var toks = AlignTokens(sentence);
            sentenceTokenCounts.Add(toks.Count);
            alignedNorms.AddRange(toks.Select(NormalizeAlignToken));
        }

        // 对齐校验：句子拼接后的 token 必须与原 token 序列逐一一致；不一致则放弃重分段。
        if (alignedNorms.Count != flat.Count
            || alignedNorms.Where((t, i) => t != flat[i].Norm).Any())
        {
            ResegmentLog($"对齐失败（原 {flat.Count} token vs 模型 {alignedNorms.Count} token），保留原 {cues.Count} 条字幕");
            return [.. cues];
        }

        // 3) 按每句覆盖的 token 范围切出带时间的 cue。
        var segments = BuildSegments(cues, flat, sentences, sentenceTokenCounts);
        // 4) 短句合并 + 长句安全拆分 + 重排 Index。
        var result = FinalizeSegments(cues, flat, segments);
        ResegmentLog($"生效：{cues.Count} 条 → {result.Count} 条整句");
        return result;
    }

    /// <summary>重分段诊断日志：写 stderr，便于排查「是否生效 / 为何回退」。与 macOS resegmentLog 一致。</summary>
    private static void ResegmentLog(string message) =>
        Console.Error.WriteLine($"[resegment] {message}");

    /// <summary>重分段中间结果：一段连续 token 的起止秒 + 文本。</summary>
    private sealed class Segment
    {
        public double StartSec;
        public double EndSec;
        public int TokenStart;   // 在 flat 序列中的起始索引（含）
        public int TokenEnd;     // 结束索引（不含）
        public string Text = "";
    }

    /// <summary>按每句覆盖的 token 范围，用 token 所在原 cue 的本地时间插值，切出带时间的段。</summary>
    private static List<Segment> BuildSegments(
        IReadOnlyList<SubtitleCue> cues, List<FlatToken> flat,
        List<string> sentences, List<int> sentenceTokenCounts)
    {
        var segments = new List<Segment>();
        var cursor = 0;
        for (var s = 0; s < sentences.Count; s++)
        {
            var tokenCount = sentenceTokenCounts[s];
            if (tokenCount == 0) continue;
            var tokenStart = cursor;
            var tokenEnd = cursor + tokenCount; // 不含
            cursor = tokenEnd;
            segments.Add(new Segment
            {
                TokenStart = tokenStart,
                TokenEnd = tokenEnd,
                StartSec = TokenTime(cues, flat[tokenStart], edge: false),
                EndSec = TokenTime(cues, flat[tokenEnd - 1], edge: true),
                Text = sentences[s].Trim(),
            });
        }
        return segments;
    }

    /// <summary>合并碎句 → 按时长安全拆分过长段 → 单调钳制时间 → 重排 Index → 转 SubtitleCue。</summary>
    private static List<SubtitleCue> FinalizeSegments(
        IReadOnlyList<SubtitleCue> cues, List<FlatToken> flat, List<Segment> segments)
    {
        if (segments.Count == 0) return [.. cues];

        // 合并：把「时长短且 token 少」的碎句并入前一段（首段无前段则作为基底保留）。
        var merged = new List<Segment> { segments[0] };
        for (var i = 1; i < segments.Count; i++)
        {
            var seg = segments[i];
            var tokenCount = seg.TokenEnd - seg.TokenStart;
            var durationShort = seg.EndSec - seg.StartSec < ResegmentMinSegmentSeconds;
            if (durationShort && tokenCount < ResegmentMinMergeTokens)
            {
                var prev = merged[^1];
                prev.TokenEnd = seg.TokenEnd;
                prev.EndSec = seg.EndSec;
                prev.Text = (prev.Text + " " + seg.Text).Trim();
            }
            else
            {
                merged.Add(seg);
            }
        }

        // 拆分：把「时长超限且 token 足够多」的段在 token 边界均分成若干份。
        var split = new List<Segment>();
        foreach (var seg in merged)
        {
            split.AddRange(SplitLongSegment(cues, flat, seg));
        }

        // 转 SubtitleCue：Index 从 1 连续，时间单调（钳制 end<=下一段 start）。
        var result = new List<SubtitleCue>();
        for (var i = 0; i < split.Count; i++)
        {
            var seg = split[i];
            var endSec = seg.EndSec;
            if (i + 1 < split.Count) endSec = Math.Min(endSec, split[i + 1].StartSec);
            if (endSec < seg.StartSec) endSec = seg.StartSec;
            result.Add(new SubtitleCue(
                i + 1,
                SrtTools.SecondsToSrtTime(seg.StartSec),
                SrtTools.SecondsToSrtTime(endSec),
                seg.Text));
        }
        return result;
    }

    /// <summary>
    /// 把过长段（时长超限且 token 足够多）在 token 边界均分成若干份；否则原样返回单段。
    /// 各份时间用边界 token 的本地插值，文本按词数等比切分（测试只校验份数与首尾时间）。
    /// </summary>
    private static List<Segment> SplitLongSegment(
        IReadOnlyList<SubtitleCue> cues, List<FlatToken> flat, Segment seg)
    {
        var tokenCount = seg.TokenEnd - seg.TokenStart;
        var duration = seg.EndSec - seg.StartSec;
        if (duration <= ResegmentMaxSegmentSeconds || tokenCount < ResegmentMinSplitTokens)
        {
            return [seg];
        }

        var parts = (int)Math.Ceiling(duration / ResegmentMaxSegmentSeconds);
        parts = Math.Max(2, Math.Min(parts, tokenCount)); // 至少 2 份，至多每份 1 token
        var words = seg.Text.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        var output = new List<Segment>();
        for (var p = 0; p < parts; p++)
        {
            var tStart = seg.TokenStart + (int)((long)tokenCount * p / parts);
            var tEnd = seg.TokenStart + (int)((long)tokenCount * (p + 1) / parts);
            if (tEnd <= tStart) tEnd = tStart + 1;
            if (p == parts - 1) tEnd = seg.TokenEnd;

            var wStart = (int)((long)words.Length * p / parts);
            var wEnd = p == parts - 1 ? words.Length : (int)((long)words.Length * (p + 1) / parts);
            if (wEnd < wStart) wEnd = wStart;
            var text = string.Join(' ', words[wStart..wEnd]).Trim();

            output.Add(new Segment
            {
                TokenStart = tStart,
                TokenEnd = tEnd,
                StartSec = TokenTime(cues, flat[tStart], edge: false),
                EndSec = TokenTime(cues, flat[tEnd - 1], edge: true),
                Text = text.Length > 0 ? text : seg.Text,
            });
        }
        return output;
    }
}
