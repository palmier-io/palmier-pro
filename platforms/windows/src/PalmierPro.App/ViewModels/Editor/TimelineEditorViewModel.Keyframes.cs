using PalmierPro.Core.Models;

namespace PalmierPro.App.ViewModels.Editor;

/// Keyframe stamp/remove/interpolation/drag-move mutations for the Inspector's Keyframes tab (M5).
/// Ports `EditorViewModel+Keyframes.swift`'s mutation half — read helpers (frame lists,
/// interpolation-at) stay on `Clip` itself (see Keyframe.cs's `partial class Clip`) since they need
/// no undo/notify wiring. One-shot edits (stamp/remove/interpolation) route through the existing
/// `MutateClips` primitive, which already registers the undo swap under a fixed action name and
/// fires the immediate `NotifyTimelineChanged` rebuild appropriate for a discrete commit. The
/// drag-move gesture instead reuses TimelineEditorViewModel.ClipProperties.cs's
/// `ApplyClipProperties`/`CommitClipProperties`/`RevertClipProperty` trio (the same continuous-edit
/// primitives the Text tab's live editing uses) so live ticks stay param-only
/// (`RefreshVisualsRequested`, no rebuild — moving an existing keyframe never changes clip duration
/// or track membership) and only the final release registers one undo entry.
public sealed partial class TimelineEditorViewModel
{
    public void StampKeyframe(string clipId, AnimatableProperty property, int? frame = null)
    {
        if (ClipFor(clipId) is not { } clip)
        {
            return;
        }
        var f = frame ?? CurrentFrame;
        if (!clip.Contains(f))
        {
            return;
        }
        MutateClips(new HashSet<string> { clipId }, "Add Keyframe", c => StampValue(c, property, f));
    }

    /// Captures the clip's currently-sampled value at `f` as the new keyframe's value, so stamping
    /// never causes a visible jump.
    private static void StampValue(Clip c, AnimatableProperty property, int f)
    {
        switch (property)
        {
            case AnimatableProperty.Opacity:
                c.UpsertOpacityKeyframe(f, c.RawOpacityAt(f));
                break;
            case AnimatableProperty.Position:
                var tl = c.TopLeftAt(f);
                c.UpsertPositionKeyframe(f, new AnimPair(tl.X, tl.Y));
                break;
            case AnimatableProperty.Scale:
                var sz = c.SizeAt(f);
                c.UpsertScaleKeyframe(f, new AnimPair(sz.Width, sz.Height));
                break;
            case AnimatableProperty.Rotation:
                c.UpsertRotationKeyframe(f, c.RotationAt(f));
                break;
            case AnimatableProperty.Crop:
                c.UpsertCropKeyframe(f, c.CropAt(f));
                break;
            case AnimatableProperty.Volume:
                c.UpsertVolumeKeyframe(f, c.LiveVolumeKfDb(f) ?? 0.0);
                break;
            default:
                throw new ArgumentOutOfRangeException(nameof(property));
        }
    }

    public void RemoveKeyframe(string clipId, AnimatableProperty property, int frame) =>
        MutateClips(new HashSet<string> { clipId }, "Delete Keyframe", c => c.RemoveKeyframe(property, frame));

    public void SetKeyframeInterpolation(string clipId, AnimatableProperty property, int frame, Interpolation interpolation) =>
        MutateClips(new HashSet<string> { clipId }, "Change Interpolation", c => c.SetInterpolation(property, frame, interpolation));

    // MARK: - Drag-to-move

    /// Live move during a drag — pair with <see cref="CommitMoveKeyframe"/> on release for a single
    /// undo entry. `rebuild: false` since a keyframe move never changes clip duration or track
    /// membership — always the param-only refresh path.
    public void ApplyMoveKeyframe(string clipId, AnimatableProperty property, int fromFrame, int toFrame) =>
        ApplyClipProperties([clipId], rebuild: false, c => c.MoveKeyframe(property, fromFrame, toFrame));

    /// Closes the drag started by <see cref="ApplyMoveKeyframe"/>. The modify closure is a no-op —
    /// ApplyMoveKeyframe already moved the keyframe live; this just turns the accumulated live edit
    /// into one undo entry (mirrors the Mac's `commitClipProperty(clipId) { _ in }`). A no-op drag
    /// (the keyframe never actually moved) registers nothing, matching CommitClipProperties' own
    /// equality guard.
    public void CommitMoveKeyframe(string clipId)
    {
        CommitClipProperties([clipId], _ => { });
        Document.UndoService.SetActionName("Move Keyframe");
    }

    /// Drops an in-progress drag's before-snapshot without committing (mouse-up with no net move).
    public void CancelMoveKeyframeDrag(string clipId) => RevertClipProperty(clipId);
}
