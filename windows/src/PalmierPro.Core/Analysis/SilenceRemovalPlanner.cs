namespace PalmierPro.Core.Analysis;

public sealed class SilenceRemovalSettings : IEquatable<SilenceRemovalSettings>
{
    public static readonly (double Min, double Max) MinimumPauseRange = (0.25, 3.0);
    public static readonly (double Min, double Max) SpeechPaddingRange = (0.0, 0.5);

    public static SilenceRemovalSettings Default { get; } = new(0.5, 0.15);

    public double MinimumPauseSeconds { get; }
    public double SpeechPaddingSeconds { get; }

    private SilenceRemovalSettings(double minimumPauseSeconds, double speechPaddingSeconds)
    {
        MinimumPauseSeconds = minimumPauseSeconds;
        SpeechPaddingSeconds = speechPaddingSeconds;
    }

    public static SilenceRemovalSettings? Create(double minimumPauseSeconds, double speechPaddingSeconds)
    {
        if (!double.IsFinite(minimumPauseSeconds) || !double.IsFinite(speechPaddingSeconds))
            return null;
        if (minimumPauseSeconds < MinimumPauseRange.Min || minimumPauseSeconds > MinimumPauseRange.Max)
            return null;
        if (speechPaddingSeconds < SpeechPaddingRange.Min || speechPaddingSeconds > SpeechPaddingRange.Max)
            return null;
        return new SilenceRemovalSettings(minimumPauseSeconds, speechPaddingSeconds);
    }

    public bool Equals(SilenceRemovalSettings? other)
        => other is not null
           && MinimumPauseSeconds.Equals(other.MinimumPauseSeconds)
           && SpeechPaddingSeconds.Equals(other.SpeechPaddingSeconds);

    public override bool Equals(object? obj) => Equals(obj as SilenceRemovalSettings);
    public override int GetHashCode() => HashCode.Combine(MinimumPauseSeconds, SpeechPaddingSeconds);
}

public static class SilenceRemovalPlanner
{
    public const double DefaultCellDuration = 0.032; // Silero / VoiceActivity chunk

    public static bool[] RemovableMask(
        IReadOnlyList<bool> quietNonSpeechMask,
        SilenceRemovalSettings settings,
        double cellDuration = DefaultCellDuration)
    {
        if (quietNonSpeechMask.Count == 0 || !double.IsFinite(cellDuration) || cellDuration <= 0)
            return [];

        var minimumCells = CellCount(settings.MinimumPauseSeconds, cellDuration, quietNonSpeechMask.Count + 1);
        var paddingCells = CellCount(settings.SpeechPaddingSeconds, cellDuration, quietNonSpeechMask.Count);
        var removable = new bool[quietNonSpeechMask.Count];
        var i = 0;
        while (i < quietNonSpeechMask.Count)
        {
            if (!quietNonSpeechMask[i]) { i++; continue; }
            var j = i + 1;
            while (j < quietNonSpeechMask.Count && quietNonSpeechMask[j]) j++;
            if (j - i >= minimumCells)
            {
                var start = i + (i > 0 ? paddingCells : 0);
                var end = j - (j < quietNonSpeechMask.Count ? paddingCells : 0);
                if (start < end)
                {
                    for (var cell = start; cell < end; cell++)
                        removable[cell] = true;
                }
            }
            i = j;
        }
        return removable;
    }

    public static List<(double Start, double End)> VisibleRemovableRanges(
        IReadOnlyList<bool> removableMask,
        double visibleStart,
        double visibleEnd,
        int framesPerSecond,
        SilenceRemovalSettings settings,
        double cellDuration = DefaultCellDuration)
    {
        var cellFrames = cellDuration * Math.Max(1, framesPerSecond);
        if (!double.IsFinite(cellFrames) || cellFrames <= 0
            || !double.IsFinite(visibleStart) || !double.IsFinite(visibleEnd))
            return [];

        var visibleCellsStart = visibleStart / cellFrames;
        var visibleCellsEnd = visibleEnd / cellFrames;
        return VisibleRemovableCellRanges(
                removableMask, visibleCellsStart, visibleCellsEnd, settings, cellDuration)
            .Select(r => (r.Start * cellFrames, r.End * cellFrames))
            .ToList();
    }

    private static List<(double Start, double End)> VisibleRemovableCellRanges(
        IReadOnlyList<bool> removableMask,
        double visibleStart,
        double visibleEnd,
        SilenceRemovalSettings settings,
        double cellDuration)
    {
        if (removableMask.Count == 0 || visibleEnd <= visibleStart
            || !double.IsFinite(visibleStart) || !double.IsFinite(visibleEnd)
            || !double.IsFinite(cellDuration) || cellDuration <= 0)
            return [];

        var edgePadding = (double)CellCount(
            settings.SpeechPaddingSeconds, cellDuration, removableMask.Count);
        var scanStart = (int)Math.Max(0, Math.Min(removableMask.Count, Math.Floor(visibleStart - edgePadding)));
        var scanEnd = (int)Math.Max(scanStart, Math.Min(removableMask.Count, Math.Ceiling(visibleEnd + edgePadding)));
        var ranges = new List<(double, double)>();
        var i = scanStart;
        while (i < scanEnd)
        {
            if (!removableMask[i]) { i++; continue; }
            var j = i + 1;
            while (j < scanEnd && removableMask[j]) j++;
            var expanded = ExpandToVisibleEdges(i, j, visibleStart, visibleEnd, edgePadding);
            var start = Math.Max(expanded.Start, visibleStart);
            var end = Math.Min(expanded.End, visibleEnd);
            if (start < end) ranges.Add((start, end));
            i = j;
        }
        return ranges;
    }

    private static (double Start, double End) ExpandToVisibleEdges(
        double remStart, double remEnd, double visStart, double visEnd, double edgePadding)
    {
        if (edgePadding < 0) return (remStart, remEnd);
        var start = remEnd > visStart && remStart <= visStart + edgePadding ? visStart : remStart;
        var end = remStart < visEnd && remEnd >= visEnd - edgePadding ? visEnd : remEnd;
        return (start, end);
    }

    private static int CellCount(double seconds, double cellDuration, int maximum)
    {
        var count = Math.Ceiling(seconds / cellDuration);
        if (!double.IsFinite(count) || count >= maximum) return maximum;
        return Math.Max(0, (int)count);
    }
}
