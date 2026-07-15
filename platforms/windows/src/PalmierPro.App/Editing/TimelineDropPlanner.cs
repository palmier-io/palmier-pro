using PalmierPro.Core.Models;

namespace PalmierPro.App.Editing;

/// Resolves a `TrackDropTarget` (see TimelineGeometry) plus the existing track-type layout into a
/// concrete placement instruction for a homogeneous-type batch of dropped assets — either an
/// existing compatible track, or a new track of `PreferredType` to insert. Pure/testable;
/// TimelineCanvasControl executes the plan against `TimelineEditorViewModel` (`InsertTrack` +
/// `AddClips`). No direct Mac equivalent (`resolveDropPlan`/`materialize` in
/// EditorViewModel+Linking.swift do the same job against a live `Timeline`, not testable in
/// isolation the way this pure port is) — see AGENTS.md-adjacent plan note on scoped simplification.
public static class TimelineDropPlanner
{
    /// `ExistingIndex` is set when the drop target already accepts `PreferredType`; otherwise a new
    /// track of `PreferredType` must be inserted at `InsertIndex` first.
    public readonly record struct TrackPlacement(int? ExistingIndex, ClipType PreferredType, int InsertIndex)
    {
        public bool NeedsNewTrack => ExistingIndex is null;
    }

    public static TrackPlacement ResolvePlacement(IReadOnlyList<ClipType> trackTypes, TrackDropTarget target, ClipType preferredType)
    {
        if (target is TrackDropTarget.ExistingTrack(var index) && index >= 0 && index < trackTypes.Count)
        {
            var existingType = trackTypes[index];
            var compatible = preferredType == ClipType.Audio ? existingType == ClipType.Audio : existingType.IsVisual();
            return compatible ? new TrackPlacement(index, preferredType, index) : new TrackPlacement(null, preferredType, index);
        }
        if (target is TrackDropTarget.NewTrackAt(var insertIndex))
        {
            return new TrackPlacement(null, preferredType, insertIndex);
        }
        return new TrackPlacement(null, preferredType, trackTypes.Count);
    }
}
