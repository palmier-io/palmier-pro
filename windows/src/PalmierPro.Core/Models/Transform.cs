using System.Text.Json;
using System.Text.Json.Serialization;

namespace PalmierPro.Core.Models;

[JsonConverter(typeof(TransformJsonConverter))]
public record struct Transform()
{
    public double CenterX { get; set; } = 0.5;
    public double CenterY { get; set; } = 0.5;
    public double Width { get; set; } = 1;
    public double Height { get; set; } = 1;
    /// <summary>Degrees, positive = clockwise.</summary>
    public double Rotation { get; set; } = 0;
    public bool FlipHorizontal { get; set; } = false;
    public bool FlipVertical { get; set; } = false;

    public (double X, double Y) TopLeft => (CenterX - Width / 2, CenterY - Height / 2);
    public (double X, double Y) Center => (CenterX, CenterY);

    public static Transform FromTopLeft(double x, double y, double width, double height)
        => new() { CenterX = x + width / 2, CenterY = y + height / 2, Width = width, Height = height };

    public static Transform FromCenter(double x, double y, double width, double height)
        => new() { CenterX = x, CenterY = y, Width = width, Height = height };

    /// <summary>Snap a value to canvas boundaries (0 or 1) within threshold.</summary>
    public static double SnapToBoundary(double value, double threshold)
    {
        if (Math.Abs(value) < threshold) return 0;
        if (Math.Abs(value - 1) < threshold) return 1;
        return value;
    }

    /// <summary>Snap clip edges to canvas boundaries (0 or 1).</summary>
    public void SnapToCanvasEdges(double threshold)
    {
        var tl = TopLeft;
        var snappedLeft = SnapToBoundary(tl.X, threshold);
        var snappedRight = SnapToBoundary(tl.X + Width, threshold);
        if (snappedLeft != tl.X)
        {
            CenterX -= tl.X - snappedLeft;
        }
        else if (snappedRight != tl.X + Width)
        {
            CenterX -= tl.X + Width - snappedRight;
        }

        var tl2 = TopLeft;
        var snappedTop = SnapToBoundary(tl2.Y, threshold);
        var snappedBottom = SnapToBoundary(tl2.Y + Height, threshold);
        if (snappedTop != tl2.Y)
        {
            CenterY -= tl2.Y - snappedTop;
        }
        else if (snappedBottom != tl2.Y + Height)
        {
            CenterY -= tl2.Y + Height - snappedBottom;
        }
    }

    /// <summary>Snap per-axis within threshold. Return tuple lets callers draw guide indicators.</summary>
    public (bool X, bool Y) SnapCenterToCanvasCenter(double thresholdH, double thresholdV)
    {
        var snappedX = false;
        var snappedY = false;
        if (Math.Abs(CenterX - 0.5) < thresholdH)
        {
            CenterX = 0.5;
            snappedX = true;
        }
        if (Math.Abs(CenterY - 0.5) < thresholdV)
        {
            CenterY = 0.5;
            snappedY = true;
        }
        return (snappedX, snappedY);
    }
}

/// <summary>
/// Mirrors the Swift Transform decoder: legacy files stored top-left "x"/"y" instead of center.
/// </summary>
public sealed class TransformJsonConverter : JsonConverter<Transform>
{
    public override Transform Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        double? centerX = null, centerY = null, oldX = null, oldY = null;
        double width = 1, height = 1, rotation = 0;
        bool flipH = false, flipV = false;

        if (reader.TokenType != JsonTokenType.StartObject) throw new JsonException();
        while (reader.Read() && reader.TokenType != JsonTokenType.EndObject)
        {
            var name = reader.GetString();
            reader.Read();
            switch (name)
            {
                case "centerX": centerX = reader.GetDouble(); break;
                case "centerY": centerY = reader.GetDouble(); break;
                case "x": oldX = reader.GetDouble(); break;
                case "y": oldY = reader.GetDouble(); break;
                case "width": width = reader.GetDouble(); break;
                case "height": height = reader.GetDouble(); break;
                case "rotation": rotation = reader.GetDouble(); break;
                case "flipHorizontal": flipH = reader.GetBoolean(); break;
                case "flipVertical": flipV = reader.GetBoolean(); break;
                default: reader.Skip(); break;
            }
        }

        return new Transform
        {
            CenterX = centerX ?? (oldX is { } ox ? ox + width - 0.5 : 0.5),
            CenterY = centerY ?? (oldY is { } oy ? oy + height - 0.5 : 0.5),
            Width = width,
            Height = height,
            Rotation = rotation,
            FlipHorizontal = flipH,
            FlipVertical = flipV,
        };
    }

    public override void Write(Utf8JsonWriter writer, Transform value, JsonSerializerOptions options)
    {
        writer.WriteStartObject();
        writer.WriteNumber("centerX", value.CenterX);
        writer.WriteNumber("centerY", value.CenterY);
        writer.WriteNumber("width", value.Width);
        writer.WriteNumber("height", value.Height);
        writer.WriteNumber("rotation", value.Rotation);
        writer.WriteBoolean("flipHorizontal", value.FlipHorizontal);
        writer.WriteBoolean("flipVertical", value.FlipVertical);
        writer.WriteEndObject();
    }
}

/// <summary>Per-clip crop as edge insets in normalized (0–1) source coordinates.</summary>
public record struct Crop()
{
    public double Left { get; set; } = 0;
    public double Top { get; set; } = 0;
    public double Right { get; set; } = 0;
    public double Bottom { get; set; } = 0;

    [JsonIgnore] public bool IsIdentity => Left == 0 && Top == 0 && Right == 0 && Bottom == 0;
    [JsonIgnore] public double VisibleWidthFraction => Math.Max(0, 1 - Left - Right);
    [JsonIgnore] public double VisibleHeightFraction => Math.Max(0, 1 - Top - Bottom);

    public static Crop Lerp(Crop a, Crop b, double t) => new()
    {
        Left = a.Left + (b.Left - a.Left) * t,
        Top = a.Top + (b.Top - a.Top) * t,
        Right = a.Right + (b.Right - a.Right) * t,
        Bottom = a.Bottom + (b.Bottom - a.Bottom) * t,
    };
}
