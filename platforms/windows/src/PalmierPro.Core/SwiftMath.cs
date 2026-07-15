namespace PalmierPro.Core;

/// Swift's `Double.rounded()` is round-half-away-from-zero; .NET's `Math.Round` defaults to
/// round-half-to-even. Every frame/pixel rounding ported from Swift must go through here.
public static class SwiftMath
{
    public static double Round(double value) => Math.Round(value, MidpointRounding.AwayFromZero);

    public static int RoundToInt(double value) => (int)Round(value);

    /// Ported from Utilities/TimeFormatting.swift's `secondsToFrame` — truncates (Swift's
    /// `Int(_:)` on a Double), not rounds.
    public static int SecondsToFrame(double seconds, int fps) => (int)(seconds * fps);
}
