using System.Text.Json.Serialization;
using PalmierPro.Core.Json;

namespace PalmierPro.Core.Models;

/// How a visual clip composites over the layers below it. Normal = source-over.
[JsonConverter(typeof(SwiftStringEnumConverter<BlendMode>))]
public enum BlendMode
{
    [SwiftRawValue("normal")] Normal,
    [SwiftRawValue("darken")] Darken,
    [SwiftRawValue("multiply")] Multiply,
    [SwiftRawValue("colorBurn")] ColorBurn,
    [SwiftRawValue("lighten")] Lighten,
    [SwiftRawValue("screen")] Screen,
    [SwiftRawValue("colorDodge")] ColorDodge,
    [SwiftRawValue("overlay")] Overlay,
    [SwiftRawValue("softLight")] SoftLight,
    [SwiftRawValue("hardLight")] HardLight,
    [SwiftRawValue("difference")] Difference,
    [SwiftRawValue("exclusion")] Exclusion,
    [SwiftRawValue("hue")] Hue,
    [SwiftRawValue("saturation")] Saturation,
    [SwiftRawValue("color")] Color,
    [SwiftRawValue("luminosity")] Luminosity,
}

public static class BlendModeExtensions
{
    public static string DisplayName(this BlendMode mode) => mode switch
    {
        BlendMode.Normal => "Normal",
        BlendMode.Darken => "Darken",
        BlendMode.Multiply => "Multiply",
        BlendMode.ColorBurn => "Color Burn",
        BlendMode.Lighten => "Lighten",
        BlendMode.Screen => "Screen",
        BlendMode.ColorDodge => "Color Dodge",
        BlendMode.Overlay => "Overlay",
        BlendMode.SoftLight => "Soft Light",
        BlendMode.HardLight => "Hard Light",
        BlendMode.Difference => "Difference",
        BlendMode.Exclusion => "Exclusion",
        BlendMode.Hue => "Hue",
        BlendMode.Saturation => "Saturation",
        BlendMode.Color => "Color",
        BlendMode.Luminosity => "Luminosity",
        _ => throw new ArgumentOutOfRangeException(nameof(mode)),
    };
}
