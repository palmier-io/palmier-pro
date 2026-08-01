namespace PalmierPro.Core.Models;

/// <summary>How a visual clip composites over the layers below it. Normal = source-over.</summary>
public enum BlendMode
{
    Normal,
    Darken,
    Multiply,
    ColorBurn,
    Lighten,
    Screen,
    ColorDodge,
    Overlay,
    SoftLight,
    HardLight,
    Difference,
    Exclusion,
    Hue,
    Saturation,
    Color,
    Luminosity,
}
