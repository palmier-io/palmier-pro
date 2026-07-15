using PalmierPro.Core.Models;

namespace PalmierPro.App.Editing;

/// Pure zoom/drop-placement math pulled out of the input controller so it's unit-testable under
/// plain `dotnet test`. Ports the exponential-zoom half of `TimelineInputController.applyZoom`
/// (Mac: Option+scroll; here: Ctrl+wheel — see AGENTS.md-adjacent plan note on the gesture swap).
public static class TimelineZoom
{
    /// New pixels-per-frame after a wheel tick. `wheelDelta` is the raw (unscaled) wheel delta —
    /// positive zooms in, matching `exp(scrollingDeltaY * scrollSensitivity)` on the Mac.
    public static double Apply(
        double currentPixelsPerFrame,
        double wheelDelta,
        double sensitivity = TimelineInputConstants.Zoom.ScrollSensitivity,
        double min = TimelineInputConstants.Zoom.Min,
        double max = TimelineInputConstants.Zoom.Max) =>
        Math.Clamp(currentPixelsPerFrame * Math.Exp(wheelDelta * sensitivity), min, max);

    /// Horizontal scroll offset (px) that keeps `anchorFrame` under `anchorViewportX` after a zoom
    /// change — mirrors `applyZoom`'s scroll-origin recompute so the frame under the cursor doesn't
    /// visually jump when the scale changes. `headerWidth` matches `TimelineGeometry.HeaderWidth`
    /// (frame 0 renders at document-x = headerWidth, not 0).
    public static double ScrollXForAnchor(double anchorFrame, double newPixelsPerFrame, double anchorViewportX, double headerWidth = 0) =>
        Math.Max(0, headerWidth + anchorFrame * newPixelsPerFrame - anchorViewportX);

    /// Which `ClipType` to give a brand-new track created by an external drop (media-panel
    /// `ClipRef` or Explorer files) landing in a "new track" drop zone — all-audio assets get an
    /// audio track, anything else (including a mixed selection) gets a video track, matching
    /// `PlaceClip`'s own video-track-first bias for linked audio.
    public static ClipType PreferredTrackType(IReadOnlyList<MediaAsset> assets) =>
        assets.Count > 0 && assets.All(a => a.Type == ClipType.Audio) ? ClipType.Audio : ClipType.Video;
}
