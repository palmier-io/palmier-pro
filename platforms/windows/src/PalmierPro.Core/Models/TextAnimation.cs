using System.Text.Json;
using System.Text.Json.Serialization;
using PalmierPro.Core.Json;

namespace PalmierPro.Core.Models;

/// Not Codable in Swift — a derived grouping, never persisted.
public enum TextAnimationRenderMode
{
    Entrance,
    PerWord,
    Typewriter,
}

/// `TextAnimation.Preset` — flattened to a top-level type per this port's nested-type convention
/// (see MulticamSource.cs).
[JsonConverter(typeof(SwiftStringEnumConverter<TextAnimationPreset>))]
public enum TextAnimationPreset
{
    [SwiftRawValue("none")] None,
    // Whole-clip / per-line.
    [SwiftRawValue("fadeIn")] FadeIn,
    [SwiftRawValue("popIn")] PopIn,
    [SwiftRawValue("slideUp")] SlideUp,
    [SwiftRawValue("typewriter")] Typewriter,
    // Per word.
    [SwiftRawValue("wordReveal")] WordReveal,
    [SwiftRawValue("wordSlide")] WordSlide,
    [SwiftRawValue("wordPop")] WordPop,
    [SwiftRawValue("wordCycle")] WordCycle,
    [SwiftRawValue("highlightPop")] HighlightPop,
    [SwiftRawValue("highlightBlock")] HighlightBlock,
}

public static class TextAnimationPresetExtensions
{
    public static TextAnimationRenderMode RenderMode(this TextAnimationPreset preset) => preset switch
    {
        TextAnimationPreset.None or TextAnimationPreset.FadeIn or TextAnimationPreset.PopIn or TextAnimationPreset.SlideUp
            => TextAnimationRenderMode.Entrance,
        TextAnimationPreset.Typewriter => TextAnimationRenderMode.Typewriter,
        TextAnimationPreset.WordReveal or TextAnimationPreset.WordSlide or TextAnimationPreset.WordPop or
            TextAnimationPreset.WordCycle or TextAnimationPreset.HighlightPop or TextAnimationPreset.HighlightBlock
            => TextAnimationRenderMode.PerWord,
        _ => throw new ArgumentOutOfRangeException(nameof(preset)),
    };

    public static bool IsPerWord(this TextAnimationPreset preset) => preset.RenderMode() == TextAnimationRenderMode.PerWord;

    public static bool UsesHighlight(this TextAnimationPreset preset) => preset.IsPerWord();

    public static string DisplayName(this TextAnimationPreset preset) => preset switch
    {
        TextAnimationPreset.None => "Off",
        TextAnimationPreset.FadeIn => "Fade In",
        TextAnimationPreset.PopIn => "Pop In",
        TextAnimationPreset.SlideUp => "Slide Up",
        TextAnimationPreset.Typewriter => "Typewriter",
        TextAnimationPreset.WordReveal => "Word Reveal",
        TextAnimationPreset.WordSlide => "Word Slide",
        TextAnimationPreset.WordPop => "Word Pop",
        TextAnimationPreset.WordCycle => "Word Cycle",
        TextAnimationPreset.HighlightPop => "Highlight",
        TextAnimationPreset.HighlightBlock => "Highlight Block",
        _ => throw new ArgumentOutOfRangeException(nameof(preset)),
    };

    /// "off" (not "none") is the agent-facing token; JSON persistence still uses the raw value "none".
    public static readonly IReadOnlyList<string> AgentValues = BuildAgentValues();

    private static List<string> BuildAgentValues()
    {
        var values = new List<string> { "off" };
        foreach (var preset in Enum.GetValues<TextAnimationPreset>())
        {
            if (preset != TextAnimationPreset.None)
            {
                values.Add(SwiftStringEnumConverter<TextAnimationPreset>.RawValue(preset));
            }
        }
        return values;
    }

    public static readonly IReadOnlyList<TextAnimationPreset> PerLine =
    [
        TextAnimationPreset.FadeIn, TextAnimationPreset.PopIn, TextAnimationPreset.SlideUp, TextAnimationPreset.Typewriter,
    ];

    public static readonly IReadOnlyList<TextAnimationPreset> PerWord =
    [
        TextAnimationPreset.WordReveal, TextAnimationPreset.WordSlide, TextAnimationPreset.WordPop,
        TextAnimationPreset.WordCycle, TextAnimationPreset.HighlightPop, TextAnimationPreset.HighlightBlock,
    ];
}

[JsonConverter(typeof(TextAnimationJsonConverter))]
public sealed class TextAnimation
{
    public TextAnimationPreset Preset { get; set; } = TextAnimationPreset.None;
    public int PerWordFrames { get; set; } = 6;
    public TextStyleRgba? Highlight { get; set; }

    public static readonly TextStyleRgba DefaultHighlight = new(1, 0.85, 0, 1);

    [JsonIgnore]
    public bool IsActive => Preset != TextAnimationPreset.None;

    public TextAnimation()
    {
    }

    public TextAnimation(TextAnimationPreset preset = TextAnimationPreset.None, int perWordFrames = 6, TextStyleRgba? highlight = null)
    {
        Preset = preset;
        PerWordFrames = perWordFrames;
        Highlight = highlight;
    }
}

public sealed class TextAnimationJsonConverter : JsonConverter<TextAnimation>
{
    public override TextAnimation Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        using var doc = JsonDocument.ParseValue(ref reader);
        var root = doc.RootElement;
        return new TextAnimation(
            preset: LenientJson.TryOr(root, "preset", options, TextAnimationPreset.None),
            perWordFrames: LenientJson.TryOr(root, "perWordFrames", options, 6),
            highlight: LenientJson.TryOrNull<TextStyleRgba>(root, "highlight", options));
    }

    public override void Write(Utf8JsonWriter writer, TextAnimation value, JsonSerializerOptions options)
    {
        writer.WriteStartObject();
        writer.WritePropertyName("preset");
        JsonSerializer.Serialize(writer, value.Preset, options);
        writer.WriteNumber("perWordFrames", value.PerWordFrames);
        if (value.Highlight is not null)
        {
            writer.WritePropertyName("highlight");
            JsonSerializer.Serialize(writer, value.Highlight, options);
        }
        writer.WriteEndObject();
    }
}
