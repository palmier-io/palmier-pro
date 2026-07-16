using System.Globalization;

namespace PalmierPro.App.Controls;

/// Pure drag/slider math shared by ScrubbableNumberBox and ParamSlider — no WinUI types, so it's
/// unit-testable from PalmierPro.App.Tests. Mirrors the inline math in ScrubbableNumberField.swift
/// (onDragChanged/commitEdit) and AdjustSlider.swift (value(atX:)).
public static class ScrubMath
{
    public static double Clamp(double value, double min, double max) =>
        Math.Min(Math.Max(value, min), max);

    public static double FractionOf(double value, double min, double max)
    {
        var span = max - min;
        return span > 0 ? Clamp((value - min) / span, 0, 1) : 0;
    }

    public static double ValueAtFraction(double fraction, double min, double max) =>
        min + Clamp(fraction, 0, 1) * (max - min);

    /// Maps a pointer X within a track of the given width to a clamped value — mirrors
    /// AdjustSlider.value(atX:width:).
    public static double ValueAtPosition(double x, double width, double min, double max) =>
        ValueAtFraction(width > 0 ? x / width : 0, min, max);

    /// Next value mid-drag for a ScrubbableNumberBox. Shift is coarse (10x), Alt is fine (0.1x,
    /// standing in for the Mac's ⌘); displayMultiplier converts the pixel delta (in display units)
    /// back into the underlying value's units.
    public static double NextDragValue(
        double dragStartValue, double deltaX, ScrubModifiers modifiers,
        double dragSensitivity, double displayMultiplier, double min, double max)
    {
        var sensitivity = dragSensitivity;
        if (modifiers.HasFlag(ScrubModifiers.Shift)) sensitivity *= 10;
        if (modifiers.HasFlag(ScrubModifiers.Alt)) sensitivity *= 0.1;
        var multiplier = displayMultiplier == 0 ? 1 : displayMultiplier;
        return Clamp(dragStartValue + deltaX * sensitivity / multiplier, min, max);
    }

    /// Parses committed edit text back into a raw (unmultiplied, clamped) value — mirrors
    /// commitEdit. Returns false for unparseable text, matching the Swift `guard let parsed = ...`
    /// (no commit at all, not a fallback value).
    public static bool TryParseCommit(
        string text, string valueSuffix, double displayMultiplier, double min, double max, out double result)
    {
        var trimmed = text.Trim();
        if (!string.IsNullOrEmpty(valueSuffix) && trimmed.EndsWith(valueSuffix, StringComparison.Ordinal))
        {
            trimmed = trimmed[..^valueSuffix.Length];
        }
        trimmed = trimmed.Trim().Replace(',', '.');
        if (!double.TryParse(trimmed, NumberStyles.Float, CultureInfo.InvariantCulture, out var parsed))
        {
            result = 0;
            return false;
        }
        var multiplier = displayMultiplier == 0 ? 1 : displayMultiplier;
        result = Clamp(parsed / multiplier, min, max);
        return true;
    }

    /// Formats a raw value for display. Supports the "%.Nf" printf patterns every
    /// ScrubbableNumberField call site on the Mac uses (N = 0, 1, or 2) — the only forms this port
    /// needs; anything unparseable falls back to N=0 rather than throwing.
    public static string FormatDisplay(double rawValue, double displayMultiplier, string format, string valueSuffix) =>
        (rawValue * displayMultiplier).ToString("F" + PrintfDigits(format), CultureInfo.InvariantCulture) + valueSuffix;

    private static int PrintfDigits(string format)
    {
        var dot = format.IndexOf('.');
        var f = format.IndexOf('f');
        return dot >= 0 && f > dot && int.TryParse(format[(dot + 1)..f], out var digits) ? digits : 0;
    }
}
