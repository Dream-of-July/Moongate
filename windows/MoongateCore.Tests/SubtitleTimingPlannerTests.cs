using Moongate.Core;

namespace MoongateCore.Tests;

public class SubtitleTimingPlannerTests
{
    [Fact]
    public void SpeechAlignedVisibleSeconds_KeepsShortFeedbackBrief()
    {
        Assert.Equal(2.0, SubtitleTimingPlanner.SpeechAlignedVisibleSeconds("Copy.", endsSentence: true));
        Assert.Equal(2.0, SubtitleTimingPlanner.SpeechAlignedVisibleSeconds("What heat?", endsSentence: true));
    }

    [Fact]
    public void SpeechAlignedVisibleSeconds_ExtendsShortEmphaticLines()
    {
        Assert.Equal(2.45, SubtitleTimingPlanner.SpeechAlignedVisibleSeconds("10,000 hours!", endsSentence: true));
        Assert.Equal(2.45, SubtitleTimingPlanner.SpeechAlignedVisibleSeconds("No!!", endsSentence: true));
        Assert.Equal(2.45, SubtitleTimingPlanner.SpeechAlignedVisibleSeconds("Ever again.", endsSentence: true));
        Assert.Equal(1.92, SubtitleTimingPlanner.SpeechAlignedVisibleSeconds("like around week eight,", endsSentence: false));
    }

    [Fact]
    public void SpeechAlignedVisibleSeconds_ScalesLongSpeechWithoutDragging()
    {
        var duration = SubtitleTimingPlanner.SpeechAlignedVisibleSeconds(
            "This is a longer spoken sentence that should stay readable without lingering too long.",
            endsSentence: true);

        Assert.True(duration > 4.0);
        Assert.True(duration <= 9.0);
    }

    [Fact]
    public void WeakSemanticBoundary_DetectsBadEnglishSplits()
    {
        Assert.True(SubtitleTimingPlanner.IsWeakBoundary("the", "ship"));
        Assert.True(SubtitleTimingPlanner.IsWeakBoundary("moon", "and"));
        Assert.False(SubtitleTimingPlanner.IsWeakBoundary("moon.", "Next"));
    }

    [Fact]
    public void WeakSemanticBoundary_DetectsRomanceLanguageSplits()
    {
        Assert.True(SubtitleTimingPlanner.IsWeakBoundary("tono", "de"));
        Assert.True(SubtitleTimingPlanner.IsWeakBoundary("de", "ponerte"));
        Assert.True(SubtitleTimingPlanner.IsWeakBoundary("des", "chaussures"));
        Assert.True(SubtitleTimingPlanner.IsWeakBoundary("di", "fronte"));
        Assert.True(SubtitleTimingPlanner.IsWeakBoundary("muchas", "veces"));
        Assert.True(SubtitleTimingPlanner.IsWeakBoundary("no", "hacen"));
    }

    [Fact]
    public void Tokenizers_HandleLatinAndCjkText()
    {
        Assert.Equal(["hello", "starship"], SubtitleTimingPlanner.WordTokens("Hello, Starship!"));
        Assert.Equal(["copy", "10", "engines"], SubtitleTimingPlanner.SpeechTokens("Copy. 10 engines?"));
        Assert.Equal(
            ["sì", "può", "iniziare", "questa", "settimana"],
            SubtitleTimingPlanner.SpeechTokens("Sì, può iniziare questa settimana?"));
        Assert.Equal(["3", "€", "4", "99", "€"], SubtitleTimingPlanner.TimingTokens("3 € 4,99€."));
        Assert.Empty(SubtitleTimingPlanner.SpeechTokens("今天我们继续"));
        Assert.Empty(SubtitleTimingPlanner.SpeechTokens("내가 서 있는 곳"));
        Assert.Equal(7, SubtitleTimingPlanner.VisibleCharacters("你 好 world"));
    }
}
