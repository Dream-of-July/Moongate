using System.Globalization;
using System.Text.Json;
using Moongate.Core;

namespace MoongateCore.Tests;

/// <summary>
/// M2 pure-logic tests mirroring Swift PlatformSubtitleQualityGateTests. The load-bearing test is
/// WhisperNeverComparedByTiming: structurally bad-timing but content-healthy auto-captions must
/// stay usable so the gate never triggers a needless whisper fallback on timing grounds.
/// </summary>
public class PlatformSubtitleQualityGateTests
{
    private static string Ms(int totalMs)
    {
        var h = totalMs / 3_600_000;
        var m = (totalMs % 3_600_000) / 60_000;
        var s = (totalMs % 60_000) / 1000;
        var milli = totalMs % 1000;
        return string.Create(CultureInfo.InvariantCulture, $"{h:D2}:{m:D2}:{s:D2},{milli:D3}");
    }

    private static List<SubtitleCue> HealthyCues(int count, Func<int, string>? text = null)
    {
        text ??= i => $"line {i}";
        var cues = new List<SubtitleCue>();
        for (var i = 0; i < count; i++)
        {
            var startMs = i * 2000;
            cues.Add(new SubtitleCue(i + 1, Ms(startMs), Ms(startMs + 1500), text(i)));
        }
        return cues;
    }

    [Fact]
    public void HealthyAutoCaptionUsable()
    {
        var verdict = PlatformSubtitleQualityGate.Assess(HealthyCues(20), "en", "en", 60);
        Assert.True(verdict.Usable);
        Assert.Empty(verdict.Reasons);
    }

    [Fact]
    public void LanguageMismatchUnusable()
    {
        var verdict = PlatformSubtitleQualityGate.Assess(HealthyCues(20), "ja", "en", 60);
        Assert.False(verdict.Usable);
        Assert.Contains(PlatformSubtitleQualityGate.Reason.LanguageMismatch, verdict.Reasons);
    }

    [Fact]
    public void TooFewCuesUnusable()
    {
        var verdict = PlatformSubtitleQualityGate.Assess(HealthyCues(3), "en", "en", 10);
        Assert.False(verdict.Usable);
        Assert.Contains(PlatformSubtitleQualityGate.Reason.TooFewCues, verdict.Reasons);
    }

    [Fact]
    public void LowCoverageUnusable()
    {
        var verdict = PlatformSubtitleQualityGate.Assess(HealthyCues(20), "en", "en", 600);
        Assert.False(verdict.Usable);
        Assert.Contains(PlatformSubtitleQualityGate.Reason.LowCoverage, verdict.Reasons);
    }

    [Fact]
    public void CoverageSkippedWhenDurationUnknown()
    {
        var verdict = PlatformSubtitleQualityGate.Assess(HealthyCues(20), "en", "en", null);
        Assert.True(verdict.Usable);
    }

    [Fact]
    public void RepetitiveUnusable()
    {
        var verdict = PlatformSubtitleQualityGate.Assess(HealthyCues(20, _ => "［音楽］"), "ja", "ja", 60);
        Assert.False(verdict.Usable);
        Assert.Contains(PlatformSubtitleQualityGate.Reason.GarbledOrRepetitive, verdict.Reasons);
    }

    [Fact]
    public void GarbledUnusable()
    {
        var verdict = PlatformSubtitleQualityGate.Assess(
            HealthyCues(20, i => i % 2 == 0 ? "���" : $"ok line {i}"), "en", "en", 60);
        Assert.False(verdict.Usable);
        Assert.Contains(PlatformSubtitleQualityGate.Reason.GarbledOrRepetitive, verdict.Reasons);
    }

    [Fact]
    public void GunjouLikeJapaneseAutoCaptionWithRomanizedLoopIsUnusable()
    {
        var texts = new[]
        {
            "ああいつものようにすぎる一里にあくびが出る",
            "さんざめくよる声今日渋谷街に字買うん",
            "どこか話した",
            "anas あのこれええええええええええ",
            "しらす各 carano",
            "ni nani",
            "ni",
            "ni",
            "dare",
            "dare",
            "ni",
            "ana ni",
            "me ni",
            "ani box",
            "car ni",
            "悔しい気持ちだけ",
            "なくて涙立てる",
            "好きなことを続けること",
            "それは楽しいだけじゃない",
            "本当にできる",
        };
        var verdict = PlatformSubtitleQualityGate.Assess(
            HealthyCues(texts.Length, i => texts[i]), "ja", "ja", 50);
        Assert.False(verdict.Usable);
        Assert.Contains(PlatformSubtitleQualityGate.Reason.GarbledOrRepetitive, verdict.Reasons);
    }

    [Fact]
    public void CjkTrackWithMostlyLatinRomanizedNoiseIsUnusable()
    {
        var texts = new[] { "ni", "ni", "dare ni", "carano", "anas", "nani", "ana ni", "me ni" };
        var verdict = PlatformSubtitleQualityGate.Assess(
            HealthyCues(texts.Length, i => texts[i]), "ja", "ja", 18);

        Assert.False(verdict.Usable);
        Assert.Contains(PlatformSubtitleQualityGate.Reason.GarbledOrRepetitive, verdict.Reasons);
        Assert.True(verdict.QualityReport.LatinScalarRatio >= PlatformSubtitleQualityGate.CjkContentMismatchLatinRatioThreshold);
    }

    [Fact]
    public void HealthyJapaneseAutoCaptionWithSomeLatinTermsStaysUsable()
    {
        var texts = new[]
        {
            "今日はYOASOBIの曲について話します",
            "まず最初のメロディーを聴いてください",
            "この部分はとても静かに始まります",
            "サビでは声の重なりが強くなります",
            "歌詞のイメージも青い世界を描いています",
            "MVの映像もその雰囲気に合わせています",
            "ここでピアノの音が前に出ます",
            "次にベースのリズムを確認します",
            "英語のタイトルGunjouも紹介されています",
            "全体として青春の迷いを表しています",
            "最後は明るい余韻で終わります",
            "この表現はライブでも印象的です",
        };
        var verdict = PlatformSubtitleQualityGate.Assess(
            HealthyCues(texts.Length, i => texts[i]), "ja", "ja", 28);
        Assert.True(verdict.Usable);
        Assert.Empty(verdict.Reasons);
    }

    [Fact]
    public void JapaneseLyricsWithParentheticalRomajiGlossStaysUsable()
    {
        var texts = new[]
        {
            "沈むように溶けていくように (Shizumu you ni tokete yuku you ni)",
            "二人だけの空が広がる夜に (Futari dake no sora ga hirogaru you ni)",
            "さよならだけだった (Sayonara dakedatta)",
            "その一言で全てが分かった (Sono hitokoto de subete ga wakatta)",
            "日が沈み出した空と君の姿 (Higa shizumi dashita sora to kimi no sugata)",
            "フェンス越しに重なっていた (Fensu-goshi ni kasanatte ita)",
            "初めて会った日から (Hajimete atta hi kara)",
            "僕の心の全てを奪った (Boku no kokoro no subete o ubatta)",
            "どこか儚い空気を纏う君は (Doko ka hakanai kuuki o matou kimi wa)",
            "寂しい目をしてたんだ (Sabishii me wo shitetanda)",
        };
        var verdict = PlatformSubtitleQualityGate.Assess(
            HealthyCues(texts.Length, i => texts[i]), "ja", "ja", null);
        Assert.True(verdict.Usable);
        Assert.Empty(verdict.Reasons);
        Assert.True(verdict.QualityReport.LatinScalarRatio < 0.10);
        Assert.Equal(0, verdict.QualityReport.RomanizedLoopTokenCount);
    }

    [Fact]
    public void CjkAutoCaptionWithExcessiveLongRollingCuesIsUnusable()
    {
        var cues = new List<SubtitleCue>
        {
            new(1, "00:00:01,120", "00:00:15,750", "私さは愚かさとはそれが何か見せつけて"),
            new(2, "00:00:15,760", "00:00:20,150", "やるちっちゃな頃から言うとせついたら"),
            new(3, "00:00:20,160", "00:00:24,990", "大人になってたナフのような思考会"),
            new(4, "00:00:25,000", "00:00:28,710", "持ち合わせる負けもなくでも遊び足りない"),
            new(5, "00:00:28,720", "00:00:33,590", "何か足りない困っちまうこれは誰かのせも"),
            new(6, "00:00:36,480", "00:00:42,630", "するましか最の流行は当然の白経のど"),
            new(7, "00:00:42,640", "00:00:49,750", "も中な精神でしは社会人は然の"),
            new(8, "00:01:08,960", "00:01:24,390", "メロディは頭の敵が違うので問題は"),
            new(9, "00:01:24,400", "00:01:30,150", "なしずっても私も半人間ったりするのはせ"),
            new(10, "00:01:30,160", "00:01:47,190", "ったら言葉の中をその仲にきつけては"),
        };
        var verdict = PlatformSubtitleQualityGate.Assess(cues, "ja", "ja", null);

        Assert.False(verdict.Usable);
        Assert.Contains(PlatformSubtitleQualityGate.Reason.GarbledOrRepetitive, verdict.Reasons);
        Assert.True(verdict.QualityReport.LongCueCount >= PlatformSubtitleQualityGate.CjkLongCueMinCount);
    }

    [Fact]
    public void KoreanLyricsWithEnglishHookStaysUsable()
    {
        var texts = new[]
        {
            "이 노래는 It's about you baby",
            "Only you",
            "내가 힘들 때 울 것 같을 때",
            "It's you I got done honey",
            "말 안 해도 돼 boy",
            "멀리든 언제든지 달려와",
            "dreams come true",
            "That's my life",
            "I'll be far away",
            "Be your writer",
            "내일 내게 열리는 건 big stage",
            "You and me",
        };
        var verdict = PlatformSubtitleQualityGate.Assess(
            HealthyCues(texts.Length, i => texts[i]), "ko", "ko", null);

        Assert.True(verdict.Usable);
        Assert.Empty(verdict.Reasons);
        Assert.Equal(0, verdict.QualityReport.RomanizedLoopTokenCount);
    }

    [Fact]
    public void AutoCaptionWithManySoundEffectCuesIsUnusable()
    {
        var texts = new[]
        {
            "ルルルル",
            "[拍手]",
            "ルルルルル",
            "[音楽]",
            "君の中にある赤とはせも",
            "[拍手]",
            "[音楽]",
            "それらが結ばれるのは真の像",
            "風の中でも負けないような声で",
            "[拍手]",
            "届ける言葉を今は育ててる",
            "[音楽]",
        };
        var verdict = PlatformSubtitleQualityGate.Assess(
            HealthyCues(texts.Length, i => texts[i]), "ja", "ja", null);

        Assert.False(verdict.Usable);
        Assert.Contains(PlatformSubtitleQualityGate.Reason.GarbledOrRepetitive, verdict.Reasons);
        Assert.True(verdict.QualityReport.SoundEffectCueCount >= PlatformSubtitleQualityGate.SoundEffectCueMinCount);
    }

    [Fact]
    public void AutoCaptionWithLongSoundEffectHoldsIsUnusable()
    {
        var cues = new List<SubtitleCue>
        {
            new(1, Ms(1_000), Ms(16_000), "[Musica]"),
            new(2, Ms(16_000), Ms(18_000), "Marco se n'è andato e non"),
            new(3, Ms(18_000), Ms(23_000), "ritorna il treno delle sette e trenta"),
            new(4, Ms(23_000), Ms(27_000), "un cuore di metallo senza l'anima"),
            new(5, Ms(27_000), Ms(31_000), "nel freddo del mattino grigio di città"),
            new(6, Ms(31_000), Ms(35_000), "a scuola il banco è vuoto"),
            new(7, Ms(35_000), Ms(39_000), "dolce il suo respiro"),
            new(8, Ms(39_000), Ms(43_000), "ma il cuore batte forte"),
            new(9, Ms(75_000), Ms(89_000), "[Musica]"),
        };
        var verdict = PlatformSubtitleQualityGate.Assess(cues, "it", "it", null);

        Assert.False(verdict.Usable);
        Assert.Contains(PlatformSubtitleQualityGate.Reason.GarbledOrRepetitive, verdict.Reasons);
        Assert.True(verdict.QualityReport.SoundEffectDurationRatio >= PlatformSubtitleQualityGate.SoundEffectDurationRatioThreshold);
    }

    [Fact]
    public void EnglishLyricsWithMusicNoteMarkersStaysUsable()
    {
        var texts = new[]
        {
            "♪ I WANT YOU TO STAY ♪",
            "'TIL I'M IN THE GRAVE ♪",
            "IF YOU GO, I'M GOING TOO, UH ♪",
            "BIRDS OF A FEATHER, WE SHOULD STICK TOGETHER, I KNOW ♪",
            "I'LL LOVE YOU 'TIL THE DAY THAT I DIE ♪",
            "♪♪♪",
            "TIL THE LIGHT LEAVES MY EYES ♪",
            "CAN'T CHANGE THE WEATHER, MIGHT NOT BE FOREVER ♪",
        };
        var verdict = PlatformSubtitleQualityGate.Assess(
            HealthyCues(texts.Length, i => texts[i]), "en", "en", null);

        Assert.True(verdict.Usable);
        Assert.Empty(verdict.Reasons);
        Assert.Equal(1, verdict.QualityReport.SoundEffectCueCount);
    }

    /// <summary>
    /// Load-bearing regression: structurally bad timing (every cue spans the whole video) but the
    /// content is fine. Timing is explicitly out of scope, so the verdict must stay usable.
    /// </summary>
    [Fact]
    public void WhisperNeverComparedByTiming()
    {
        var cues = new List<SubtitleCue>();
        for (var i = 0; i < 20; i++)
        {
            cues.Add(new SubtitleCue(i + 1, Ms(0), Ms(60_000), $"distinct healthy sentence number {i}"));
        }
        var verdict = PlatformSubtitleQualityGate.Assess(cues, "en", "en", 60);
        Assert.True(verdict.Usable);
        Assert.Empty(verdict.Reasons);
    }

    [Fact]
    public void SongSourceArbiterPrefersManualBeforeAutoAndLocalAsr()
    {
        var arbitration = SongSubtitleSourceArbiter.Arbitrate(
            "ja",
            [
                SubtitleChoice.Create("ja", "Japanese auto", SubtitleSourceKind.PlatformAuto),
                SubtitleChoice.Create("ja", "Japanese", SubtitleSourceKind.Manual),
            ],
            new PlatformSubtitleQualityGate.Verdict(true, []),
            localAsrAvailable: true);

        Assert.Equal(SubtitleSourceKind.Manual, arbitration.SelectedKind);
        var manual = arbitration.CandidateReports.Single(report => report.SourceKind == SubtitleSourceKind.Manual);
        var auto = arbitration.CandidateReports.Single(report => report.SourceKind == SubtitleSourceKind.PlatformAuto);
        var localAsr = arbitration.CandidateReports.Single(report => report.SourceKind == SubtitleSourceKind.LocalAsr);
        Assert.True(manual.Selected);
        Assert.False(auto.Selected);
        Assert.False(localAsr.Selected);
    }

    [Fact]
    public void SongSourceArbiterFallsBackToLocalAsrWhenAutoIsGarbled()
    {
        var arbitration = SongSubtitleSourceArbiter.Arbitrate(
            "ja",
            [SubtitleChoice.Create("ja", "Japanese auto", SubtitleSourceKind.PlatformAuto)],
            new PlatformSubtitleQualityGate.Verdict(
                false,
                [PlatformSubtitleQualityGate.Reason.GarbledOrRepetitive]),
            localAsrAvailable: true);

        Assert.Equal(SubtitleSourceKind.LocalAsr, arbitration.SelectedKind);
        var auto = arbitration.CandidateReports.Single(report => report.SourceKind == SubtitleSourceKind.PlatformAuto);
        var localAsr = arbitration.CandidateReports.Single(report => report.SourceKind == SubtitleSourceKind.LocalAsr);
        Assert.False(auto.Usable);
        Assert.False(auto.Selected);
        Assert.Equal(["garbledOrRepetitive"], auto.Reasons);
        Assert.True(localAsr.Usable);
        Assert.True(localAsr.Selected);
    }

    [Fact]
    public void QualityGateConstantsMatchFixture()
    {
        var section = SubtitleLanguageRecommenderTests.LoadSection("platformSubtitleQualityGate");
        Assert.Equal(PlatformSubtitleQualityGate.MinimumUsableCueCount, section.GetProperty("minimumUsableCueCount").GetInt32());
        Assert.Equal(PlatformSubtitleQualityGate.MinimumCoverageRatio, section.GetProperty("minimumCoverageRatio").GetDouble());
        Assert.Equal(PlatformSubtitleQualityGate.RepetitionRatioThreshold, section.GetProperty("repetitionRatioThreshold").GetDouble());
        Assert.Equal(PlatformSubtitleQualityGate.GarbledRatioThreshold, section.GetProperty("garbledRatioThreshold").GetDouble());
        Assert.Equal(PlatformSubtitleQualityGate.CjkLatinNoiseRatioThreshold, section.GetProperty("cjkLatinNoiseRatioThreshold").GetDouble());
        Assert.Equal(PlatformSubtitleQualityGate.CjkContentMismatchLatinRatioThreshold, section.GetProperty("cjkContentMismatchLatinRatioThreshold").GetDouble());
        Assert.Equal(PlatformSubtitleQualityGate.CjkContentMismatchCjkRatioThreshold, section.GetProperty("cjkContentMismatchCJKRatioThreshold").GetDouble());
        Assert.Equal(PlatformSubtitleQualityGate.CjkLongCueDurationThreshold, section.GetProperty("cjkLongCueDurationThreshold").GetDouble());
        Assert.Equal(PlatformSubtitleQualityGate.CjkLongCueRatioThreshold, section.GetProperty("cjkLongCueRatioThreshold").GetDouble());
        Assert.Equal(PlatformSubtitleQualityGate.CjkLongCueMinCount, section.GetProperty("cjkLongCueMinCount").GetInt32());
        Assert.Equal(PlatformSubtitleQualityGate.RomanizedLoopTokenRatioThreshold, section.GetProperty("romanizedLoopTokenRatioThreshold").GetDouble());
        Assert.Equal(PlatformSubtitleQualityGate.RomanizedLoopMinTokenCount, section.GetProperty("romanizedLoopMinTokenCount").GetInt32());
        Assert.Equal(PlatformSubtitleQualityGate.RomanizedLoopMinMaxRun, section.GetProperty("romanizedLoopMinMaxRun").GetInt32());
        Assert.Equal(PlatformSubtitleQualityGate.SoundEffectCueRatioThreshold, section.GetProperty("soundEffectCueRatioThreshold").GetDouble());
        Assert.Equal(PlatformSubtitleQualityGate.SoundEffectCueMinCount, section.GetProperty("soundEffectCueMinCount").GetInt32());
        Assert.Equal(PlatformSubtitleQualityGate.SoundEffectDurationRatioThreshold, section.GetProperty("soundEffectDurationRatioThreshold").GetDouble());
        Assert.Equal(PlatformSubtitleQualityGate.SoundEffectDurationMinCount, section.GetProperty("soundEffectDurationMinCount").GetInt32());
    }
}
