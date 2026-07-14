using System.Text.Json;
using System.Text.Json.Serialization;
using PalmierPro.Core.Json;

namespace PalmierPro.Core.Models;

/// Font resolution (NSFont lookup, symbolic-trait inspection, glyph attribute building) is a
/// render-time concern on both platforms — CoreText on Mac, DirectWrite on Windows. This project
/// carries no font stack, so `resolvedFont`/`attributes`/`paragraphStyle` from TextStyle.swift are
/// NOT ported here; only this seam lets the lenient decoder mirror Swift's isBold/isItalic trait
/// inference without depending on one. The Windows renderer implements it.
public interface ITextStyleFontResolver
{
    /// Mirrors `TextStyle.symbolicTraits(fontName:size:)` — the traits carried by a named font,
    /// used only to backfill isBold/isItalic when an older project omits them.
    (bool IsBold, bool IsItalic) SymbolicTraits(string fontName, double fontSize);
}

/// Registered by the Windows renderer at startup. Null (-> no inferred traits) until then, which
/// diverges from Swift for legacy files missing isBold/isItalic until the renderer wires up.
public static class TextStyleFontResolver
{
    public static ITextStyleFontResolver? Current { get; set; }
}

[JsonConverter(typeof(SwiftStringEnumConverter<TextStyleAlignment>))]
public enum TextStyleAlignment
{
    [SwiftRawValue("left")] Left,
    [SwiftRawValue("center")] Center,
    [SwiftRawValue("right")] Right,
}

/// Solid RGBA color, straight alpha, sRGB (`TextStyle.RGBA` in Swift — shared by TextStyle and
/// TextAnimation). Flattened to a top-level type per this port's nested-type convention (see
/// MulticamSource.cs). Plain Codable, no custom init: all four fields required on decode.
public sealed class TextStyleRgba
{
    [JsonPropertyName("r")]
    [JsonRequired]
    public double R { get; set; } = 1;

    [JsonPropertyName("g")]
    [JsonRequired]
    public double G { get; set; } = 1;

    [JsonPropertyName("b")]
    [JsonRequired]
    public double B { get; set; } = 1;

    [JsonPropertyName("a")]
    [JsonRequired]
    public double A { get; set; } = 1;

    public TextStyleRgba()
    {
    }

    public TextStyleRgba(double r, double g, double b, double a)
    {
        R = r;
        G = g;
        B = b;
        A = a;
    }

    /// Accepts `#RGB`, `#RRGGBB`, or `#RRGGBBAA`; leading `#` optional. Null on any parse failure.
    public static TextStyleRgba? FromHex(string hex)
    {
        var s = hex.Trim();
        if (s.StartsWith('#'))
        {
            s = s[1..];
        }

        double? Component(int start, int len)
        {
            if (start + len > s.Length)
            {
                return null;
            }
            var slice = s.Substring(start, len);
            var byteStr = len == 1 ? slice + slice : slice;
            // AllowHexSpecifier only — no leading/trailing-whitespace tolerance, unlike
            // NumberStyles.HexNumber, so embedded whitespace correctly fails to parse.
            return byte.TryParse(byteStr, System.Globalization.NumberStyles.AllowHexSpecifier, null, out var n)
                ? n / 255.0
                : null;
        }

        switch (s.Length)
        {
            case 3:
            {
                var r = Component(0, 1);
                var g = Component(1, 1);
                var b = Component(2, 1);
                return r is null || g is null || b is null ? null : new TextStyleRgba(r.Value, g.Value, b.Value, 1);
            }
            case 6:
            {
                var r = Component(0, 2);
                var g = Component(2, 2);
                var b = Component(4, 2);
                return r is null || g is null || b is null ? null : new TextStyleRgba(r.Value, g.Value, b.Value, 1);
            }
            case 8:
            {
                var r = Component(0, 2);
                var g = Component(2, 2);
                var b = Component(4, 2);
                var a = Component(6, 2);
                return r is null || g is null || b is null || a is null
                    ? null
                    : new TextStyleRgba(r.Value, g.Value, b.Value, a.Value);
            }
            default:
                return null;
        }
    }
}

/// `TextStyle.Shadow` — plain Codable, no custom init: all five fields required on decode.
public sealed class TextStyleShadow
{
    [JsonPropertyName("enabled")]
    [JsonRequired]
    public bool Enabled { get; set; } = true;

    /// Alpha doubles as opacity; layer.shadowOpacity stays at 1 — a render-time detail, not modeled here.
    [JsonPropertyName("color")]
    [JsonRequired]
    public TextStyleRgba Color { get; set; } = new(0, 0, 0, 0.6);

    /// Canvas points; scaled at render time.
    [JsonPropertyName("offsetX")]
    [JsonRequired]
    public double OffsetX { get; set; }

    [JsonPropertyName("offsetY")]
    [JsonRequired]
    public double OffsetY { get; set; } = -2;

    [JsonPropertyName("blur")]
    [JsonRequired]
    public double Blur { get; set; } = 6;
}

/// Toggleable solid color for text box fill and glyph outline (`TextStyle.Fill` in Swift). Plain
/// Codable, no custom init: both fields required on decode.
public sealed class TextStyleFill
{
    [JsonPropertyName("enabled")]
    [JsonRequired]
    public bool Enabled { get; set; }

    [JsonPropertyName("color")]
    [JsonRequired]
    public TextStyleRgba Color { get; set; } = new();

    public TextStyleFill()
    {
    }

    public TextStyleFill(bool enabled, TextStyleRgba color)
    {
        Enabled = enabled;
        Color = color;
    }
}

[JsonConverter(typeof(TextStyleJsonConverter))]
public sealed class TextStyle
{
    public const double GlyphBorderStrokeWidth = -4;

    /// Stored default only — NOT a render-time font (see <see cref="ITextStyleFontResolver"/>).
    /// Substituting a real bundled fallback for "Helvetica-Bold" (or any font missing on this
    /// machine) is a render-time concern; it must never mutate this stored value.
    public string FontName { get; set; } = "Helvetica-Bold";
    public double FontSize { get; set; } = 96;
    public double FontScale { get; set; } = 1.0;
    public bool IsBold { get; set; } = true;
    public bool IsItalic { get; set; }
    public TextStyleRgba Color { get; set; } = new();
    public TextStyleAlignment Alignment { get; set; } = TextStyleAlignment.Center;
    public TextStyleShadow Shadow { get; set; } = new();
    public TextStyleFill Background { get; set; } = new(false, new TextStyleRgba(0, 0, 0, 0.6));
    public TextStyleFill Border { get; set; } = new(false, new TextStyleRgba(0, 0, 0, 1));

    /// Pure half of `TextStyle.glyphBorderPadding(fontSize:)`.
    public static double GlyphBorderPadding(double fontSize) =>
        Math.Ceiling(fontSize * Math.Abs(GlyphBorderStrokeWidth) / 100);
}

public sealed class TextStyleJsonConverter : JsonConverter<TextStyle>
{
    public override TextStyle Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        using var doc = JsonDocument.ParseValue(ref reader);
        var root = doc.RootElement;

        var fontName = LenientJson.TryOr(root, "fontName", options, "Helvetica-Bold");
        var fontSize = LenientJson.TryOr(root, "fontSize", options, 96.0);

        // Only consulted when isBold/isItalic is actually missing/mistyped, matching Swift's
        // `(try? c.decode(...)) ?? inferredTraits.contains(...)` fallback semantics exactly —
        // Swift computes inferredTraits unconditionally, but it's only ever read on that path.
        var isBold = LenientJson.TryOrNullValue<bool>(root, "isBold", options);
        var isItalic = LenientJson.TryOrNullValue<bool>(root, "isItalic", options);
        if (isBold is null || isItalic is null)
        {
            var traits = TextStyleFontResolver.Current?.SymbolicTraits(fontName, fontSize) ?? (false, false);
            isBold ??= traits.IsBold;
            isItalic ??= traits.IsItalic;
        }

        return new TextStyle
        {
            FontName = fontName,
            FontSize = fontSize,
            FontScale = LenientJson.TryOr(root, "fontScale", options, 1.0),
            IsBold = isBold.Value,
            IsItalic = isItalic.Value,
            Color = LenientJson.TryOr(root, "color", options, new TextStyleRgba()),
            Alignment = LenientJson.TryOr(root, "alignment", options, TextStyleAlignment.Center),
            Shadow = LenientJson.TryOr(root, "shadow", options, new TextStyleShadow()),
            Background = LenientJson.TryOr(root, "background", options, new TextStyleFill(false, new TextStyleRgba(0, 0, 0, 0.6))),
            Border = LenientJson.TryOr(root, "border", options, new TextStyleFill(false, new TextStyleRgba(0, 0, 0, 1))),
        };
    }

    public override void Write(Utf8JsonWriter writer, TextStyle value, JsonSerializerOptions options)
    {
        writer.WriteStartObject();
        writer.WriteString("fontName", value.FontName);
        writer.WriteNumber("fontSize", value.FontSize);
        writer.WriteNumber("fontScale", value.FontScale);
        writer.WriteBoolean("isBold", value.IsBold);
        writer.WriteBoolean("isItalic", value.IsItalic);
        writer.WritePropertyName("color");
        JsonSerializer.Serialize(writer, value.Color, options);
        writer.WritePropertyName("alignment");
        JsonSerializer.Serialize(writer, value.Alignment, options);
        writer.WritePropertyName("shadow");
        JsonSerializer.Serialize(writer, value.Shadow, options);
        writer.WritePropertyName("background");
        JsonSerializer.Serialize(writer, value.Background, options);
        writer.WritePropertyName("border");
        JsonSerializer.Serialize(writer, value.Border, options);
        writer.WriteEndObject();
    }
}
