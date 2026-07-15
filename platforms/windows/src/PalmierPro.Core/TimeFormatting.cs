namespace PalmierPro.Core;

/// Ported from Utilities/TimeFormatting.swift's `formatTimecode(frame:fps:)` — always the full
/// HH:MM:SS:FF form, unlike TimelineCanvasControl's compact ruler-label variant (which drops a
/// leading all-zero hours group).
public static class TimeFormatting
{
    public static string FormatTimecode(int frame, int fps)
    {
        if (fps <= 0)
        {
            return "00:00:00:00";
        }
        var absFrame = Math.Abs(frame);
        var totalSeconds = absFrame / fps;
        var ff = absFrame % fps;
        var ss = totalSeconds % 60;
        var mm = totalSeconds / 60 % 60;
        var hh = totalSeconds / 3600;
        var sign = frame < 0 ? "-" : "";
        return $"{sign}{hh:D2}:{mm:D2}:{ss:D2}:{ff:D2}";
    }
}
