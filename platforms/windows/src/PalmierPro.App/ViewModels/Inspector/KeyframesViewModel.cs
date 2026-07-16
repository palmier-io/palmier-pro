using PalmierPro.App.Editing;
using PalmierPro.App.Views.Inspector;
using PalmierPro.App.ViewModels.Editor;
using PalmierPro.Core.Models;

namespace PalmierPro.App.ViewModels.Inspector;

/// One property lane's row spec — mirrors KeyframesPanel.videoRows/audioRows' `(AnimatableProperty, String)` pairs.
public readonly record struct KeyframeRowSpec(AnimatableProperty Property, string Label);

/// Backs KeyframesTabView (M5, Stage E) for the single selected clip — ports the read/glue half of
/// Inspector/Keyframes/KeyframesLane.swift's `KeyframesPanel`/`KeyframesLaneRow` (row list, snap
/// targets, clip label) plus the parts of `EditorViewModel+Keyframes.swift` that don't need
/// undo/notify wiring (that lives on TimelineEditorViewModel.Keyframes.cs — see that file's class
/// doc). KeyframesTabView builds a fresh instance whenever the active tab/selection changes, same as
/// every other M5 tab (see InspectorTabRegistry's class doc) — cheap to construct, no lifetime to
/// manage beyond that.
///
/// Holds the clip id, not a `Clip` reference: an undo/redo swap replaces `Track.Clips` entries
/// wholesale (see TimelineEditorViewModel's class doc), so a `Clip` captured at construction can go
/// stale the moment an undo lands while this tab instance is still alive. Every read/write below
/// re-resolves through <see cref="TimelineEditorViewModel.ClipFor"/> instead — mirrors
/// TransformViewModel's identical rationale.
public sealed class KeyframesViewModel
{
    private readonly TimelineEditorViewModel _timeline;
    private readonly string _clipId;
    private readonly MediaResolver _mediaResolver;

    /// Video/Image/Lottie/Sequence rows only — InspectorViewModel.ComputeAvailableTabs only ever
    /// offers InspectorTab.Keyframes for a single non-text visual clip (never audio-only, never
    /// text-only — see that method's doc comment), so the Mac's `audioRows` (Volume) case never
    /// applies here.
    public static readonly IReadOnlyList<KeyframeRowSpec> Rows =
    [
        new(AnimatableProperty.Position, "Position"),
        new(AnimatableProperty.Scale, "Scale"),
        new(AnimatableProperty.Rotation, "Rotation"),
        new(AnimatableProperty.Opacity, "Opacity"),
        new(AnimatableProperty.Crop, "Crop"),
    ];

    public KeyframesViewModel(InspectorTabContext context)
    {
        _timeline = context.Timeline;
        _clipId = context.SelectedClips[0].Id;
        _mediaResolver = new MediaResolver(() => _timeline.Document.Manifest, () => _timeline.Document.PackagePath);
    }

    /// Re-resolved every call — see class doc's staleness note.
    public Clip? Clip => _timeline.ClipFor(_clipId);

    public string ClipId => _clipId;

    public string ClipLabel => Clip is { } c ? _mediaResolver.DisplayName(c.MediaRef) : "";

    public ClipType SourceClipType => Clip?.SourceClipType ?? ClipType.Video;

    public int ClipStartFrame => Clip?.StartFrame ?? 0;

    public int ClipEndFrame => Clip?.EndFrame ?? 0;

    public int ClipSpanFrames => Math.Max(1, ClipEndFrame - ClipStartFrame);

    public int Fps => _timeline.Timeline.Fps;

    public int CurrentFrame => _timeline.CurrentFrame;

    public bool PlayheadInRange => Clip?.Contains(CurrentFrame) ?? false;

    public List<int> KeyframeFrames(AnimatableProperty property) => Clip?.KeyframeFrames(property) ?? [];

    public bool HasKeyframe(AnimatableProperty property, int frame) => KeyframeFrames(property).Contains(frame);

    public int? PreviousKeyframeFrame(AnimatableProperty property, int beforeFrame)
    {
        var candidates = KeyframeFrames(property).Where(f => f < beforeFrame).ToList();
        return candidates.Count == 0 ? null : candidates.Max();
    }

    public int? NextKeyframeFrame(AnimatableProperty property, int afterFrame)
    {
        var candidates = KeyframeFrames(property).Where(f => f > afterFrame).ToList();
        return candidates.Count == 0 ? null : candidates.Min();
    }

    public Interpolation InterpolationAt(AnimatableProperty property, int frame) =>
        Clip?.InterpolationAt(property, frame) ?? Interpolation.Smooth;

    /// Snap targets for a property row's drag — in-range playhead, clip edges, and every other
    /// row's own keyframes on this same clip. Mirrors KeyframesLaneRow.snapTargets().
    public List<SnapEngine.SnapTarget> SnapTargets(AnimatableProperty property)
    {
        var targets = new List<SnapEngine.SnapTarget>();
        if (Clip is not { } clip)
        {
            return targets;
        }
        if (PlayheadInRange)
        {
            targets.Add(new SnapEngine.SnapTarget(CurrentFrame, SnapEngine.SnapTargetKind.Playhead));
        }
        targets.Add(new SnapEngine.SnapTarget(clip.StartFrame, SnapEngine.SnapTargetKind.ClipEdge));
        targets.Add(new SnapEngine.SnapTarget(clip.EndFrame, SnapEngine.SnapTargetKind.ClipEdge));
        foreach (var row in Rows)
        {
            if (row.Property == property)
            {
                continue;
            }
            foreach (var f in KeyframeFrames(row.Property))
            {
                targets.Add(new SnapEngine.SnapTarget(f, SnapEngine.SnapTargetKind.ClipEdge));
            }
        }
        return targets;
    }

    public void Seek(int frame) => _timeline.SeekToFrame(frame);

    public void StampAtPlayhead(AnimatableProperty property) => _timeline.StampKeyframe(_clipId, property, CurrentFrame);

    public void Remove(AnimatableProperty property, int frame) => _timeline.RemoveKeyframe(_clipId, property, frame);

    public void SetInterpolation(AnimatableProperty property, int frame, Interpolation interpolation) =>
        _timeline.SetKeyframeInterpolation(_clipId, property, frame, interpolation);

    public void ApplyMove(AnimatableProperty property, int fromFrame, int toFrame) =>
        _timeline.ApplyMoveKeyframe(_clipId, property, fromFrame, toFrame);

    public void CommitMove() => _timeline.CommitMoveKeyframe(_clipId);

    public void CancelMove() => _timeline.CancelMoveKeyframeDrag(_clipId);
}
