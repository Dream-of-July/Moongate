using Moongate.Core;

namespace MoongateCore.Tests;

public class TranslationLanguageTests
{
    [Fact]
    public void DisplayName_CoversSupportedTargets()
    {
        Assert.Equal("简体中文", TranslationLanguage.DisplayName("zh-Hans"));
        Assert.Equal("繁體中文", TranslationLanguage.DisplayName("zh-Hant"));
        Assert.Equal("English", TranslationLanguage.DisplayName("en"));
    }

    [Fact]
    public void TranslatedSubtitleSuffix_FollowsSupportedTargets()
    {
        Assert.Equal(".zh-Hans.srt", TranslationLanguage.TranslatedSubtitleFileSuffix("zh-Hans"));
        Assert.Equal(".zh-Hant.srt", TranslationLanguage.TranslatedSubtitleFileSuffix("zh-Hant"));
        Assert.Equal(".en.srt", TranslationLanguage.TranslatedSubtitleFileSuffix("en"));
        Assert.Contains(".zh-Hans.srt", TranslationLanguage.TranslatedSubtitleFileSuffixes);
        Assert.Contains(".zh-Hant.srt", TranslationLanguage.TranslatedSubtitleFileSuffixes);
        Assert.Contains(".en.srt", TranslationLanguage.TranslatedSubtitleFileSuffixes);
        Assert.True(TranslationLanguage.IsTranslatedSubtitleFileName("video.en.zh-Hans.srt"));
        Assert.True(TranslationLanguage.IsTranslatedSubtitleFileName("video.zh-Hant.en.srt"));
        Assert.False(TranslationLanguage.IsTranslatedSubtitleFileName("video.en.srt"));
        Assert.False(TranslationLanguage.IsTranslatedSubtitleFileName("video.zh-Hans.srt"));
    }

    /// <summary>同脚本才跳过翻译；简↔繁视为不同脚本，必须仍翻译（与 Swift TranslationLanguage 同构）。</summary>
    [Fact]
    public void Matches_IsScriptAwareForChinese()
    {
        Assert.True(TranslationLanguage.Matches("zh-Hans", "zh-Hans"));
        Assert.True(TranslationLanguage.Matches("zh-CN", "zh-Hans"));
        Assert.True(TranslationLanguage.Matches("zh-TW", "zh-Hant"));
        Assert.True(TranslationLanguage.Matches("en-US", "en"));
        Assert.False(TranslationLanguage.Matches("zh-Hans", "zh-Hant"));
        Assert.False(TranslationLanguage.Matches("en", "zh-Hans"));
        Assert.False(TranslationLanguage.Matches(null, "zh-Hans"));
    }
}
