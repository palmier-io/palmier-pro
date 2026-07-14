using System.Text.Json;
using PalmierPro.Core.Json;
using PalmierPro.Core.Models;
using Shouldly;
using Xunit;

namespace PalmierPro.Core.Tests;

/// Mirrors TextAnimation.swift's Preset classification/display logic + its lenient decoder.
public class TextAnimationPresetTests
{
    [Theory]
    [InlineData(TextAnimationPreset.None, TextAnimationRenderMode.Entrance)]
    [InlineData(TextAnimationPreset.FadeIn, TextAnimationRenderMode.Entrance)]
    [InlineData(TextAnimationPreset.PopIn, TextAnimationRenderMode.Entrance)]
    [InlineData(TextAnimationPreset.SlideUp, TextAnimationRenderMode.Entrance)]
    [InlineData(TextAnimationPreset.Typewriter, TextAnimationRenderMode.Typewriter)]
    [InlineData(TextAnimationPreset.WordReveal, TextAnimationRenderMode.PerWord)]
    [InlineData(TextAnimationPreset.WordSlide, TextAnimationRenderMode.PerWord)]
    [InlineData(TextAnimationPreset.WordPop, TextAnimationRenderMode.PerWord)]
    [InlineData(TextAnimationPreset.WordCycle, TextAnimationRenderMode.PerWord)]
    [InlineData(TextAnimationPreset.HighlightPop, TextAnimationRenderMode.PerWord)]
    [InlineData(TextAnimationPreset.HighlightBlock, TextAnimationRenderMode.PerWord)]
    public void RenderModeMatchesSwiftClassification(TextAnimationPreset preset, TextAnimationRenderMode expected) =>
        preset.RenderMode().ShouldBe(expected);

    [Fact]
    public void IsPerWordAndUsesHighlightAgreeWithRenderMode()
    {
        foreach (var preset in Enum.GetValues<TextAnimationPreset>())
        {
            preset.IsPerWord().ShouldBe(preset.RenderMode() == TextAnimationRenderMode.PerWord);
            preset.UsesHighlight().ShouldBe(preset.IsPerWord());
        }
    }

    [Fact]
    public void AgentValuesUsesOffInsteadOfNoneButKeepsRawValuesForTheRest()
    {
        TextAnimationPresetExtensions.AgentValues[0].ShouldBe("off");
        TextAnimationPresetExtensions.AgentValues.ShouldNotContain("none");
        TextAnimationPresetExtensions.AgentValues.ShouldContain("wordReveal");
        TextAnimationPresetExtensions.AgentValues.Count.ShouldBe(11); // 10 non-none cases + "off"
    }

    [Fact]
    public void PerLineAndPerWordListsPartitionTheNonEntranceCases()
    {
        TextAnimationPresetExtensions.PerLine.ShouldBe(
            [TextAnimationPreset.FadeIn, TextAnimationPreset.PopIn, TextAnimationPreset.SlideUp, TextAnimationPreset.Typewriter]);
        TextAnimationPresetExtensions.PerWord.ShouldBe(
        [
            TextAnimationPreset.WordReveal, TextAnimationPreset.WordSlide, TextAnimationPreset.WordPop,
            TextAnimationPreset.WordCycle, TextAnimationPreset.HighlightPop, TextAnimationPreset.HighlightBlock,
        ]);
    }

    [Fact]
    public void RawValuesMatchSwiftCaseNamesExactly()
    {
        SwiftStringEnumConverter<TextAnimationPreset>.RawValue(TextAnimationPreset.None).ShouldBe("none");
        SwiftStringEnumConverter<TextAnimationPreset>.RawValue(TextAnimationPreset.WordCycle).ShouldBe("wordCycle");
        SwiftStringEnumConverter<TextAnimationPreset>.RawValue(TextAnimationPreset.HighlightBlock).ShouldBe("highlightBlock");
    }
}

public class TextAnimationJsonTests
{
    [Fact]
    public void DefaultsMatchSwiftMemberwiseInit()
    {
        var anim = new TextAnimation();
        anim.Preset.ShouldBe(TextAnimationPreset.None);
        anim.PerWordFrames.ShouldBe(6);
        anim.Highlight.ShouldBeNull();
        anim.IsActive.ShouldBeFalse();
    }

    [Fact]
    public void IsActiveIsFalseOnlyForNone()
    {
        new TextAnimation(TextAnimationPreset.WordPop).IsActive.ShouldBeTrue();
        new TextAnimation(TextAnimationPreset.None).IsActive.ShouldBeFalse();
    }

    [Fact]
    public void FullObjectRoundTripsThroughJson()
    {
        var anim = new TextAnimation(TextAnimationPreset.HighlightPop, perWordFrames: 4, highlight: new TextStyleRgba(1, 0.5, 0, 1));
        var json = JsonSerializer.Serialize(anim);
        var decoded = JsonSerializer.Deserialize<TextAnimation>(json)!;
        decoded.Preset.ShouldBe(TextAnimationPreset.HighlightPop);
        decoded.PerWordFrames.ShouldBe(4);
        decoded.Highlight!.R.ShouldBe(1);
        decoded.Highlight.G.ShouldBe(0.5);
    }

    [Fact]
    public void HighlightKeyIsOmittedWhenNull()
    {
        var json = JsonSerializer.Serialize(new TextAnimation());
        json.ShouldNotContain("\"highlight\"");
    }

    [Fact]
    public void MissingPresetFallsBackToNone()
    {
        const string json = """{"perWordFrames": 8}""";
        var anim = JsonSerializer.Deserialize<TextAnimation>(json)!;
        anim.Preset.ShouldBe(TextAnimationPreset.None);
        anim.PerWordFrames.ShouldBe(8);
    }

    [Fact]
    public void MissingPerWordFramesFallsBackToSix()
    {
        const string json = """{"preset": "wordSlide"}""";
        var anim = JsonSerializer.Deserialize<TextAnimation>(json)!;
        anim.PerWordFrames.ShouldBe(6);
    }

    [Fact]
    public void UnknownPresetSwallowsToNone()
    {
        const string json = """{"preset": "explode"}""";
        var anim = JsonSerializer.Deserialize<TextAnimation>(json)!;
        anim.Preset.ShouldBe(TextAnimationPreset.None);
    }

    [Fact]
    public void MalformedHighlightSwallowsToNull()
    {
        const string json = """{"preset": "wordPop", "highlight": {"r": 1}}""";
        var anim = JsonSerializer.Deserialize<TextAnimation>(json)!;
        anim.Highlight.ShouldBeNull();
    }

    [Fact]
    public void EmptyObjectDecodesToAllDefaults()
    {
        var anim = JsonSerializer.Deserialize<TextAnimation>("{}")!;
        anim.Preset.ShouldBe(TextAnimationPreset.None);
        anim.PerWordFrames.ShouldBe(6);
        anim.Highlight.ShouldBeNull();
    }
}
