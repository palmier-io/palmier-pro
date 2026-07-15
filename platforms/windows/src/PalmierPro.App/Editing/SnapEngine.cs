using PalmierPro.Core.Models;

namespace PalmierPro.App.Editing;

/// Pure timeline-drag snap math, ported near-verbatim from Timeline/SnapEngine.swift. No WinUI
/// dependency — lives in `PalmierPro.App` (not `PalmierPro.Core`) because it's UI-drag-flavored
/// math, not a domain model; testable under plain `dotnet test`.
///
/// The Mac version calls `NSHapticFeedbackManager` on every successful snap (trackpad click
/// feedback) — there is no Windows equivalent and it's a side effect, not part of the mutation, so
/// it's dropped rather than ported.
public static class SnapEngine
{
    public enum SnapTargetKind
    {
        Playhead,
        ClipEdge,
        Beat,
    }

    public readonly record struct SnapTarget(int Frame, SnapTargetKind Kind);

    public readonly record struct SnapResult(int Frame, int ProbeOffset, double X);

    /// Sticky-snap multiplier: hold threshold = base threshold * this, once snapped.
    private const double StickyMultiplier = 1.5;

    /// Playhead targets get a wider catch threshold than clip edges.
    private const double PlayheadMultiplier = 1.5;

    /// Mutable state that persists across drag events for sticky snap behavior.
    public struct SnapState
    {
        public int? CurrentlySnappedTo;
        public int CurrentProbeOffset;
    }

    /// Collects all clip edges, and optionally the playhead, as snap targets. Pass
    /// `excludeClipIds` to skip clips being dragged. Pass `includePlayhead: true` when the
    /// playhead itself is NOT what's being moved.
    public static List<SnapTarget> CollectTargets(
        IReadOnlyList<Track> tracks,
        int playheadFrame = 0,
        ISet<string>? excludeClipIds = null,
        bool includePlayhead = false,
        Func<Clip, IEnumerable<int>>? beatFrames = null,
        bool includeExcludedClipBeats = false)
    {
        excludeClipIds ??= new HashSet<string>();
        var targets = new List<SnapTarget>();
        if (includePlayhead)
        {
            targets.Add(new SnapTarget(playheadFrame, SnapTargetKind.Playhead));
        }
        foreach (var track in tracks)
        {
            foreach (var clip in track.Clips)
            {
                var excluded = excludeClipIds.Contains(clip.Id);
                if (!excluded)
                {
                    targets.Add(new SnapTarget(clip.StartFrame, SnapTargetKind.ClipEdge));
                    targets.Add(new SnapTarget(clip.EndFrame, SnapTargetKind.ClipEdge));
                }
                if (beatFrames is not null && (!excluded || includeExcludedClipBeats))
                {
                    foreach (var frame in beatFrames(clip))
                    {
                        targets.Add(new SnapTarget(frame, SnapTargetKind.Beat));
                    }
                }
            }
        }
        return targets;
    }

    /// Snap position(s) to nearest target, with sticky behavior and playhead priority. Tests one
    /// or more probe positions (e.g., clip start and end) against all targets.
    public static SnapResult? FindSnap(
        int position,
        IReadOnlyList<SnapTarget> targets,
        ref SnapState state,
        double baseThreshold,
        double pixelsPerFrame,
        IReadOnlyList<int>? probeOffsets = null)
    {
        probeOffsets ??= [0];
        var baseFrameThreshold = baseThreshold / pixelsPerFrame;

        // Sticky: stay snapped until moved 2.5x threshold away.
        if (state.CurrentlySnappedTo is { } snapped)
        {
            var holdThreshold = baseFrameThreshold * StickyMultiplier;
            var probePos = position + state.CurrentProbeOffset;
            if (Math.Abs((double)(probePos - snapped)) <= holdThreshold && targets.Any(t => t.Frame == snapped))
            {
                return new SnapResult(snapped, state.CurrentProbeOffset, snapped * pixelsPerFrame);
            }
            state.CurrentlySnappedTo = null;
            state.CurrentProbeOffset = 0;
        }

        // Find closest (probe, target) pair.
        (int ProbeOffset, SnapTarget Target, double Distance)? best = null;
        foreach (var probeOffset in probeOffsets)
        {
            var probePos = position + probeOffset;
            foreach (var target in targets)
            {
                var threshold = target.Kind switch
                {
                    SnapTargetKind.Playhead => baseFrameThreshold * PlayheadMultiplier,
                    _ => baseFrameThreshold,
                };
                var dist = Math.Abs((double)(probePos - target.Frame));
                if (dist <= threshold && dist < (best?.Distance ?? double.PositiveInfinity))
                {
                    best = (probeOffset, target, dist);
                }
            }
        }

        if (best is not { } b)
        {
            return null;
        }
        state.CurrentlySnappedTo = b.Target.Frame;
        state.CurrentProbeOffset = b.ProbeOffset;
        return new SnapResult(b.Target.Frame, b.ProbeOffset, b.Target.Frame * pixelsPerFrame);
    }
}
