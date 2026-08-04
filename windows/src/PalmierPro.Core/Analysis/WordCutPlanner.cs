using PalmierPro.Core.Editing;

namespace PalmierPro.Core.Analysis;

public enum CutAggressiveness
{
    Tight,
    Balanced,
    Loose,
}

public static class CutAggressivenessExtensions
{
    public static double KeptGapMs(this CutAggressiveness a) => a switch
    {
        CutAggressiveness.Tight => 60,
        CutAggressiveness.Loose => 320,
        _ => 150,
    };
}

public static class WordCutPlanner
{
    public readonly record struct Word(int StartFrame, int EndFrame, bool Selected);

    public static List<FrameRange> CutRanges(
        IReadOnlyList<Word> words, int clipStart, int clipEnd, int keepGapFrames)
    {
        var filtered = words.Where(w => w.EndFrame > w.StartFrame).ToList();
        if (clipEnd <= clipStart || filtered.Count == 0) return [];

        var half = Math.Max(0, keepGapFrames / 2);
        var ranges = new List<FrameRange>();
        var k = 0;
        while (k < filtered.Count)
        {
            if (!filtered[k].Selected) { k++; continue; }
            var l = k;
            while (l + 1 < filtered.Count && filtered[l + 1].Selected) l++;
            var left = k > 0 ? filtered[k - 1].EndFrame : clipStart;
            var right = l + 1 < filtered.Count ? filtered[l + 1].StartFrame : clipEnd;
            var runStart = filtered[k].StartFrame;
            var runEnd = filtered[l].EndFrame;
            var keepBefore = Math.Min(Math.Max(0, runStart - left), half);
            var keepAfter = Math.Min(Math.Max(0, right - runEnd), half);
            var start = Math.Max(clipStart, Math.Min(left + keepBefore, runStart));
            var end = Math.Min(clipEnd, Math.Max(runEnd, right - keepAfter));
            if (end > start) ranges.Add(new FrameRange(start, end));
            k = l + 1;
        }
        return RippleEngine.MergeRanges(ranges);
    }
}
