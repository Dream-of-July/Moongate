using System.IO;
using System.Text.Json;
using Moongate.Core;

namespace MoongateCore.Tests;

/// <summary>
/// M2 pure-logic tests mirroring the Swift SubtitleLanguageRecommenderTests /
/// PlatformSubtitleQualityGateTests. Recommendation must follow content (never hardcoded), and the
/// quality gate must never judge whisper by timing (WhisperNeverComparedByTiming).
/// </summary>
public class SubtitleLanguageRecommenderTests
{
    private static SubtitleChoice Manual(string code, string? label = null) =>
        SubtitleChoice.Create(code, label ?? code, SubtitleSourceKind.Manual);

    private static SubtitleChoice Auto(string code, string? label = null) =>
        SubtitleChoice.Create(code, label ?? code, SubtitleSourceKind.PlatformAuto);

    private static SubtitleChoice LocalAsr(string code, string? label = null) =>
        SubtitleChoice.Create(code, label ?? code, SubtitleSourceKind.LocalAsr, provider: "whisper.cpp", variant: "local");

    // MARK: - Aggregation

    [Fact]
    public void AggregateGroupsByNormalizedLanguage()
    {
        var choices = new[] { Auto("ja-JP"), LocalAsr("ja"), Manual("en"), Auto("ja-orig") };
        var groups = SubtitleLanguageChoice.Aggregate(choices);
        Assert.Equal(new[] { "ja", "en" }, groups.Select(g => g.LanguageCode));
        var ja = groups.First(g => g.LanguageCode == "ja");
        Assert.Equal(3, ja.Tracks.Count);
        Assert.True(ja.HasAutoTrack);
        Assert.True(ja.SupportsLocalAsr);
        Assert.False(ja.HasManualTrack);
    }

    [Fact]
    public void PreferredTrackPrefersManualOverAutoOverLocalAsr()
    {
        var groups = SubtitleLanguageChoice.Aggregate(new[] { LocalAsr("en"), Auto("en"), Manual("en") });
        var en = groups.First(g => g.LanguageCode == "en");
        Assert.Equal(SubtitleSourceKind.Manual, en.PreferredTrack?.SourceKind);
    }

    // MARK: - Recommendation follows content (not hardcoded)

    [Fact]
    public void GunjouRecommendsJapanese()
    {
        var groups = SubtitleLanguageChoice.Aggregate(new[] { Auto("ja"), Auto("en") });
        var result = SubtitleLanguageRecommender.Recommend("YOASOBI - 群青 (Gunjou)", groups);
        Assert.Equal("ja", result.Recommended?.LanguageCode);
    }

    [Fact]
    public void GunjouRecommendsJapaneseWhenManualTranslationSubtitlesExist()
    {
        var groups = SubtitleLanguageChoice.Aggregate(new[]
        {
            Auto("ja"), Manual("en"), Manual("zh-Hans"),
            LocalAsr("ja"), LocalAsr("en"), LocalAsr("zh-Hans"),
        });
        var result = SubtitleLanguageRecommender.Recommend("YOASOBI - 群青 (Gunjou)", groups);
        Assert.Equal("ja", result.Recommended?.LanguageCode);
    }

    [Fact]
    public void KoreanMvRecommendsKoreanWhenManualEnglishTranslationExists()
    {
        var groups = SubtitleLanguageChoice.Aggregate(new[] { Auto("ko"), Manual("en"), LocalAsr("ko"), LocalAsr("en") });
        var result = SubtitleLanguageRecommender.Recommend("아이유 (IU) - 좋은 날 MV", groups);
        Assert.Equal("ko", result.Recommended?.LanguageCode);
    }

    [Fact]
    public void EnglishInterviewRecommendsEnglish()
    {
        var groups = SubtitleLanguageChoice.Aggregate(new[] { Auto("en"), Auto("ja") });
        var result = SubtitleLanguageRecommender.Recommend(
            "The Future of AI — A Conversation with Researchers", groups);
        Assert.Equal("en", result.Recommended?.LanguageCode);
    }

    [Fact]
    public void KoreanMvRecommendsKorean()
    {
        var groups = SubtitleLanguageChoice.Aggregate(new[] { Auto("ko"), Auto("en") });
        var result = SubtitleLanguageRecommender.Recommend("아이유 (IU) - 좋은 날 MV", groups);
        Assert.Equal("ko", result.Recommended?.LanguageCode);
    }

    [Fact]
    public void RecommendationNotHardcoded()
    {
        var groups = SubtitleLanguageChoice.Aggregate(new[] { Auto("ja"), Auto("en"), Auto("ko") });
        Assert.Equal("ja", SubtitleLanguageRecommender.Recommend("夜に駆ける 歌ってみた", groups).Recommended?.LanguageCode);
        Assert.Equal("en", SubtitleLanguageRecommender.Recommend("How transformers actually work", groups).Recommended?.LanguageCode);
        Assert.Equal("ko", SubtitleLanguageRecommender.Recommend("방탄소년단 라이브 무대", groups).Recommended?.LanguageCode);
    }

    [Fact]
    public void ManualTrackPreferredOverAutoWhenScriptNeutral()
    {
        var groups = SubtitleLanguageChoice.Aggregate(new[] { Auto("en"), Manual("fr") });
        var result = SubtitleLanguageRecommender.Recommend("12345", groups);
        Assert.Equal("fr", result.Recommended?.LanguageCode);
    }

    [Fact]
    public void EmptyLanguagesReturnsNullRecommendation()
    {
        var result = SubtitleLanguageRecommender.Recommend("anything", []);
        Assert.Null(result.Recommended);
        Assert.Empty(result.Others);
    }

    // MARK: - Fixture contract (ARCH-3)

    [Fact]
    public void LanguageRecommenderConstantsMatchFixture()
    {
        var section = LoadSection("languageRecommender");
        Assert.Equal(SubtitleLanguageRecommender.ManualTrackScore, section.GetProperty("manualTrackScore").GetInt32());
        Assert.Equal(SubtitleLanguageRecommender.AutoTrackScore, section.GetProperty("autoTrackScore").GetInt32());
        Assert.Equal(SubtitleLanguageRecommender.LocalAsrOnlyScore, section.GetProperty("localASROnlyScore").GetInt32());
        Assert.Equal(SubtitleLanguageRecommender.JapaneseScriptBonus, section.GetProperty("japaneseScriptBonus").GetInt32());
        Assert.Equal(SubtitleLanguageRecommender.KoreanScriptBonus, section.GetProperty("koreanScriptBonus").GetInt32());
        Assert.Equal(SubtitleLanguageRecommender.LatinScriptBonus, section.GetProperty("latinScriptBonus").GetInt32());
        Assert.Equal(SubtitleLanguageRecommender.CjkPresenceBonus, section.GetProperty("cjkPresenceBonus").GetInt32());
        Assert.Equal(SubtitleLanguageRecommender.PlatformAutoCjkPresenceBonus, section.GetProperty("platformAutoCJKPresenceBonus").GetInt32());
        Assert.Equal(SubtitleLanguageRecommender.TitleLanguageHintBonus, section.GetProperty("titleLanguageHintBonus").GetInt32());
        Assert.Equal(SubtitleLanguageRecommender.TitleScriptDominanceRatio, section.GetProperty("titleScriptDominanceRatio").GetDouble());
    }

    internal static JsonElement LoadSection(string section)
    {
        var path = Path.Combine(RepoRoot(), "Tests", "fixtures", "whisper-timing-constants.json");
        using var doc = JsonDocument.Parse(File.ReadAllText(path));
        return doc.RootElement.GetProperty(section).Clone();
    }

    internal static string RepoRoot()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null)
        {
            if (File.Exists(Path.Combine(dir.FullName, "Package.swift"))
                && Directory.Exists(Path.Combine(dir.FullName, "windows")))
            {
                return dir.FullName;
            }
            dir = dir.Parent;
        }
        throw new DirectoryNotFoundException("Could not locate repository root.");
    }
}
