using System.Text.Json.Serialization;

namespace PalmierPro.Core.Models;

public sealed class TextStyle : IEquatable<TextStyle>
{
    public const double AxisScaleMin = 0.1;
    public const double AxisScaleMax = 10.0;

    public string FontName { get; set; } = "Helvetica-Bold";
    public double FontSize { get; set; } = 96;
    public double FontScale { get; set; } = 1.0;
    public double WidthScale { get; set; } = 1.0;
    public double HeightScale { get; set; } = 1.0;
    public double Tracking { get; set; } = 0;
    public double LineSpacing { get; set; } = 0;
    public FontCase FontCase { get; set; } = FontCase.Mixed;
    public bool IsBold { get; set; } = true;
    public bool IsItalic { get; set; } = false;
    public bool IsUnderlined { get; set; } = false;
    public bool IsStruckThrough { get; set; } = false;
    public bool IsOverlined { get; set; } = false;
    public Rgba Color { get; set; } = new();
    public TextAlignment Alignment { get; set; } = TextAlignment.Center;
    public TextShadow Shadow { get; set; } = new();
    public TextBackground Background { get; set; } = new();
    public TextOutline Border { get; set; } = new();

    /// <summary>Bake fontScale into the size-dependent values, mirroring Swift's scaledVisualStyle.</summary>
    [JsonIgnore]
    public TextStyle ScaledVisualStyle
    {
        get
        {
            if (FontScale == 1) return this;
            var style = Clone();
            style.FontSize *= FontScale;
            style.Tracking *= FontScale;
            style.LineSpacing *= FontScale;
            var shadow = style.Shadow;
            shadow.OffsetX *= FontScale;
            shadow.OffsetY *= FontScale;
            shadow.Blur *= FontScale;
            style.Shadow = shadow;
            var border = style.Border;
            border.Width *= FontScale;
            style.Border = border;
            var background = style.Background;
            background.PaddingX *= FontScale;
            background.PaddingY *= FontScale;
            background.CornerRadius *= FontScale;
            background.OffsetX *= FontScale;
            background.OffsetY *= FontScale;
            background.OutlineWidth *= FontScale;
            style.Background = background;
            style.FontScale = 1;
            return style;
        }
    }

    public string DisplayText(string text) => FontCase.Apply(text);

    public TextStyle Clone() => new()
    {
        FontName = FontName,
        FontSize = FontSize,
        FontScale = FontScale,
        WidthScale = WidthScale,
        HeightScale = HeightScale,
        Tracking = Tracking,
        LineSpacing = LineSpacing,
        FontCase = FontCase,
        IsBold = IsBold,
        IsItalic = IsItalic,
        IsUnderlined = IsUnderlined,
        IsStruckThrough = IsStruckThrough,
        IsOverlined = IsOverlined,
        Color = Color,
        Alignment = Alignment,
        Shadow = Shadow with { },
        Background = Background with { },
        Border = Border with { },
    };

    public bool Equals(TextStyle? other)
        => other is not null
            && FontName == other.FontName && FontSize == other.FontSize && FontScale == other.FontScale
            && WidthScale == other.WidthScale && HeightScale == other.HeightScale
            && Tracking == other.Tracking && LineSpacing == other.LineSpacing && FontCase == other.FontCase
            && IsBold == other.IsBold && IsItalic == other.IsItalic && IsUnderlined == other.IsUnderlined
            && IsStruckThrough == other.IsStruckThrough && IsOverlined == other.IsOverlined
            && Color == other.Color && Alignment == other.Alignment
            && Shadow == other.Shadow && Background == other.Background && Border == other.Border;

    public override bool Equals(object? obj) => Equals(obj as TextStyle);
    public override int GetHashCode() => HashCode.Combine(FontName, FontSize, Color, Alignment);
}

public enum TextAlignment
{
    Left,
    Center,
    Right,
}

public enum FontCase
{
    Mixed,
    Uppercase,
    Lowercase,
}

public static class FontCaseExtensions
{
    public static string Apply(this FontCase fontCase, string text) => fontCase switch
    {
        FontCase.Uppercase => text.ToUpperInvariant(),
        FontCase.Lowercase => text.ToLowerInvariant(),
        _ => text,
    };
}

public record struct Rgba()
{
    public double R { get; set; } = 1;
    public double G { get; set; } = 1;
    public double B { get; set; } = 1;
    public double A { get; set; } = 1;

    public Rgba(double r, double g, double b, double a) : this()
    {
        R = r;
        G = g;
        B = b;
        A = a;
    }

    /// <summary>Accepts #RGB, #RRGGBB, or #RRGGBBAA. Leading # optional. Null when malformed.</summary>
    public static Rgba? FromHex(string hex)
    {
        var s = hex.Trim();
        if (s.StartsWith('#')) s = s[1..];

        static double? Component(string src, int start, int len)
        {
            var slice = src.Substring(start, len);
            var byteStr = len == 1 ? slice + slice : slice;
            return byte.TryParse(byteStr, System.Globalization.NumberStyles.HexNumber, null, out var n)
                ? n / 255.0
                : null;
        }

        switch (s.Length)
        {
            case 3:
            {
                if (Component(s, 0, 1) is not { } r || Component(s, 1, 1) is not { } g || Component(s, 2, 1) is not { } b) return null;
                return new Rgba(r, g, b, 1);
            }
            case 6:
            {
                if (Component(s, 0, 2) is not { } r || Component(s, 2, 2) is not { } g || Component(s, 4, 2) is not { } b) return null;
                return new Rgba(r, g, b, 1);
            }
            case 8:
            {
                if (Component(s, 0, 2) is not { } r || Component(s, 2, 2) is not { } g
                    || Component(s, 4, 2) is not { } b || Component(s, 6, 2) is not { } a) return null;
                return new Rgba(r, g, b, a);
            }
            default:
                return null;
        }
    }
}

public record struct TextShadow()
{
    public bool Enabled { get; set; } = true;
    /// <summary>Alpha doubles as opacity.</summary>
    public Rgba Color { get; set; } = new(0, 0, 0, 0.6);
    /// <summary>Canvas points; scaled at render time.</summary>
    public double OffsetX { get; set; } = 0;
    public double OffsetY { get; set; } = -2;
    public double Blur { get; set; } = 6;
}

public record struct TextOutline()
{
    public bool Enabled { get; set; } = false;
    public Rgba Color { get; set; } = new(0, 0, 0, 1);
    /// <summary>Width in reference-canvas points.</summary>
    public double Width { get; set; } = 4;
}

public record struct TextBackground()
{
    public bool Enabled { get; set; } = false;
    public Rgba Color { get; set; } = new(0, 0, 0, 0.6);
    public double PaddingX { get; set; } = 0;
    public double PaddingY { get; set; } = 0;
    public double CornerRadius { get; set; } = 0;
    public double OffsetX { get; set; } = 0;
    public double OffsetY { get; set; } = 0;
    public Rgba OutlineColor { get; set; } = new(0, 0, 0, 1);
    public double OutlineWidth { get; set; } = 0;
}
