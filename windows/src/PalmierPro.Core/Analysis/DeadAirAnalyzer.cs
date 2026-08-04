using PalmierPro.Core.Editing;
using PalmierPro.Core.Models;

namespace PalmierPro.Core.Analysis;

/// <summary>VAD → silence planner → timeline frame ranges for one clip.</summary>
public static class DeadAirAnalyzer
{
    public static List<FrameRange> RemovableTimelineRanges(
        Clip clip, int fps, ReadOnlySpan<float> mono16k,
        SilenceRemovalSettings settings)
    {
        var quiet = VadService.QuietNonSpeechMask(mono16k, EnergyVad.CellDuration);
        var removable = SilenceRemovalPlanner.RemovableMask(quiet, settings, EnergyVad.CellDuration);
        if (removable.Length == 0 || !removable.Contains(true)) return [];

        var trimStartSeconds = clip.TrimStartFrame / (double)Math.Max(1, fps);
        var visibleDurationSeconds = clip.DurationFrames * clip.Speed / Math.Max(1, fps);
        var visibleStart = trimStartSeconds;
        var visibleEnd = trimStartSeconds + visibleDurationSeconds;

        var sourceFrameRanges = SilenceRemovalPlanner.VisibleRemovableRanges(
            removable, visibleStart * fps, visibleEnd * fps, fps, settings, EnergyVad.CellDuration);

        var ranges = new List<FrameRange>();
        foreach (var (srcStart, srcEnd) in sourceFrameRanges)
        {
            var start = SourceFrameToTimeline(clip, srcStart);
            var end = SourceFrameToTimeline(clip, srcEnd);
            start = Math.Clamp(start, clip.StartFrame, clip.EndFrame);
            end = Math.Clamp(end, clip.StartFrame, clip.EndFrame);
            if (end > start) ranges.Add(new FrameRange(start, end));
        }
        return RippleEngine.MergeRanges(ranges);
    }

    private static int SourceFrameToTimeline(Clip clip, double sourceFrame)
    {
        var relative = (sourceFrame - clip.TrimStartFrame) / Math.Max(1e-9, clip.Speed);
        return clip.StartFrame + (int)Math.Round(relative, MidpointRounding.AwayFromZero);
    }
}
