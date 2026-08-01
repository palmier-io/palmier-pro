namespace PalmierPro.Core.Models;

public record struct WordTiming(string Text, int StartFrame, int EndFrame);

public sealed class TextAnimation : IEquatable<TextAnimation>
{
    public TextAnimationPreset Preset { get; set; } = TextAnimationPreset.None;
    public int PerWordFrames { get; set; } = 6;
    public Rgba? Highlight { get; set; }

    public bool IsActive => Preset != TextAnimationPreset.None;

    public static readonly Rgba DefaultHighlight = new(1, 0.85, 0, 1);

    public bool Equals(TextAnimation? other)
        => other is not null && Preset == other.Preset && PerWordFrames == other.PerWordFrames && Highlight == other.Highlight;

    public override bool Equals(object? obj) => Equals(obj as TextAnimation);
    public override int GetHashCode() => HashCode.Combine(Preset, PerWordFrames, Highlight);
}

public enum TextAnimationPreset
{
    None,
    // Whole-clip / per-line.
    FadeIn,
    PopIn,
    SlideUp,
    Typewriter,
    // Per word.
    WordReveal,
    WordSlide,
    WordPop,
    WordCycle,
    HighlightPop,
    HighlightBlock,
}

public enum TextAnimationRenderMode
{
    Entrance,
    PerWord,
    Typewriter,
}

public static class TextAnimationPresetExtensions
{
    public static TextAnimationRenderMode RenderMode(this TextAnimationPreset preset) => preset switch
    {
        TextAnimationPreset.None or TextAnimationPreset.FadeIn or TextAnimationPreset.PopIn or TextAnimationPreset.SlideUp
            => TextAnimationRenderMode.Entrance,
        TextAnimationPreset.Typewriter => TextAnimationRenderMode.Typewriter,
        _ => TextAnimationRenderMode.PerWord,
    };

    public static bool IsPerWord(this TextAnimationPreset preset) => preset.RenderMode() == TextAnimationRenderMode.PerWord;
    public static bool UsesHighlight(this TextAnimationPreset preset) => preset.IsPerWord();
}

public enum TextFillMode
{
    Color,
    Footage,
}
