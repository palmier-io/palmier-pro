using Microsoft.UI.Xaml;
using PalmierPro.App.Editing;
using PalmierPro.App.ViewModels.Editor;
using PalmierPro.Core.Interop;
using PalmierPro.Core.Models;
using Windows.ApplicationModel.DataTransfer;
using Windows.Foundation;

namespace PalmierPro.App.Views.Timeline;

/// Drag-drop-IN half of TimelineCanvasControl — accepts a `PalmierPro.ClipRef` drag from the media
/// panel (`ClipRefDragFormat`) and `StorageItems` dropped from Explorer (import, then place).
/// Ports the drop-target-resolution slice of `performDragOperation`/`draggingEntered`/
/// `draggingUpdated` in TimelineView.swift, with the `resolveDropPlan`/`materialize`
/// visual/audio-track split simplified to `TimelineDropPlanner` — see its doc comment.
public sealed partial class TimelineCanvasControl
{
    private sealed record ExternalDropDrag(TrackDropTarget Target, int Frame, int DurationFrames);

    private List<MediaAsset>? _externalDragAssets;
    private SnapEngine.SnapState _externalSnapState;

    private void Canvas_DragLeave(object sender, DragEventArgs e)
    {
        _drag = null;
        _externalDragAssets = null;
        SetExternalSnapX(null);
        RequestRedraw();
    }

    private async void Canvas_DragOver(object sender, DragEventArgs e)
    {
        if (_context is not { } ctx || Vm is not { } vm)
        {
            e.AcceptedOperation = DataPackageOperation.None;
            return;
        }

        var deferral = e.GetDeferral();
        try
        {
            if (_externalDragAssets is null)
            {
                _externalDragAssets = await ResolveClipRefAssetsAsync(ctx, e.DataView) ?? [];
                _externalSnapState = new SnapEngine.SnapState();
            }

            var acceptsStorageItems = e.DataView.Contains(StandardDataFormats.StorageItems);
            if (_externalDragAssets.Count == 0 && !acceptsStorageItems)
            {
                e.AcceptedOperation = DataPackageOperation.None;
                return;
            }

            e.AcceptedOperation = DataPackageOperation.Copy;
            e.DragUIOverride.Caption = _externalDragAssets.Count > 0 ? "Add to Timeline" : "Import";

            var geo = BuildGeometry();
            var pos = e.GetPosition(Canvas);
            var target = geo.DropTargetAt(DocYForScreen(pos.Y));
            var totalDur = _externalDragAssets.Count > 0
                ? _externalDragAssets.Sum(a => vm.ClipDurationFrames(a, null))
                : Math.Max(1, vm.Timeline.Fps * 3);
            var frame = ComputeExternalDropFrame(vm, geo, pos.X, totalDur);

            _drag = new ExternalDropDrag(target, frame, totalDur);
            RequestRedraw();
        }
        finally
        {
            deferral.Complete();
        }
    }

    private async void Canvas_Drop(object sender, DragEventArgs e)
    {
        e.Handled = true;
        _drag = null;
        SetExternalSnapX(null);
        if (_context is not { } ctx || Vm is not { } vm)
        {
            return;
        }

        var deferral = e.GetDeferral();
        try
        {
            var geo = BuildGeometry();
            var pos = e.GetPosition(Canvas);
            var target = geo.DropTargetAt(DocYForScreen(pos.Y));

            List<MediaAsset> assets;
            if (e.DataView.Contains(ClipRefDragFormat.FormatId))
            {
                assets = await ResolveClipRefAssetsAsync(ctx, e.DataView) ?? [];
            }
            else if (e.DataView.Contains(StandardDataFormats.StorageItems))
            {
                var items = await e.DataView.GetStorageItemsAsync();
                var paths = items.Select(i => i.Path).Where(p => !string.IsNullOrEmpty(p)).ToList();
                if (paths.Count == 0)
                {
                    return;
                }
                var summary = await ctx.ImportPathsAsync(paths);
                assets = [.. summary.Imported.Select(i => i.Asset)];
            }
            else
            {
                return;
            }
            if (assets.Count == 0)
            {
                return;
            }

            var totalDur = assets.Sum(a => vm.ClipDurationFrames(a, null));
            var frame = ComputeExternalDropFrame(vm, geo, pos.X, totalDur);
            PlaceExternalDrop(vm, target, frame, assets);
        }
        finally
        {
            deferral.Complete();
            _externalDragAssets = null;
            RequestRedraw();
        }
    }

    private async Task<List<MediaAsset>?> ResolveClipRefAssetsAsync(TimelineCanvasContext ctx, DataPackageView dataView)
    {
        if (!dataView.Contains(ClipRefDragFormat.FormatId))
        {
            return null;
        }
        var json = await dataView.GetTextAsync(ClipRefDragFormat.FormatId);
        var ids = ClipRefDragFormat.Deserialize(json);
        if (ids is null)
        {
            return [];
        }
        return [.. ids.Select(ctx.AssetResolver).Where(a => a is not null).Select(a => a!)];
    }

    private int ComputeExternalDropFrame(TimelineEditorViewModel vm, TimelineGeometry geo, double screenX, int totalDurationFrames)
    {
        var candidate = geo.FrameAt(DocXForScreen(screenX));
        if (_externalDragAssets is not { Count: > 0 })
        {
            SetExternalSnapX(null);
            return candidate;
        }
        var targets = SnapEngine.CollectTargets(vm.Timeline.Tracks);
        var state = _externalSnapState;
        var snap = SnapEngine.FindSnap(candidate, targets, ref state, TimelineInputConstants.Snap.ThresholdPixels, _pixelsPerFrame, [0, totalDurationFrames]);
        _externalSnapState = state;
        if (snap is { } s)
        {
            SetExternalSnapX(TimelineGeometry.Layout.HeaderWidth + s.X - _scrollX);
            return s.Frame - s.ProbeOffset;
        }
        SetExternalSnapX(null);
        return candidate;
    }

    /// Visual (non-audio) assets land on a video-zone track (creating one if the drop target isn't
    /// visual-compatible); audio-only assets land on the drop target if it's already an audio
    /// track, else the first free/auto-created audio track — mirrors `PlaceClip`'s own
    /// video-track-first bias for linked audio rather than forcing a second brand-new track next
    /// to the one just inserted for the visual assets.
    private void PlaceExternalDrop(TimelineEditorViewModel vm, TrackDropTarget target, int frame, List<MediaAsset> assets)
    {
        var visual = assets.Where(a => a.Type != ClipType.Audio).ToList();
        var audioOnly = assets.Where(a => a.Type == ClipType.Audio).ToList();
        if (visual.Count == 0 && audioOnly.Count == 0)
        {
            return;
        }

        vm.Document.UndoService.BeginGrouping();
        try
        {
            if (visual.Count > 0)
            {
                var trackTypes = vm.Timeline.Tracks.Select(t => t.Type).ToList();
                var placement = TimelineDropPlanner.ResolvePlacement(trackTypes, target, ClipType.Video);
                var idx = placement.NeedsNewTrack ? vm.InsertTrack(placement.InsertIndex, placement.PreferredType) : placement.ExistingIndex!.Value;
                vm.AddClips(visual, idx, frame);
            }
            if (audioOnly.Count > 0)
            {
                var trackTypes = vm.Timeline.Tracks.Select(t => t.Type).ToList();
                var placement = TimelineDropPlanner.ResolvePlacement(trackTypes, target, ClipType.Audio);
                var idx = placement.NeedsNewTrack
                    ? vm.ResolveOrCreateAudioTrack(frame, audioOnly.Sum(a => vm.ClipDurationFrames(a, null)))
                    : placement.ExistingIndex!.Value;
                vm.AddClips(audioOnly, idx, frame);
            }
        }
        finally
        {
            vm.Document.UndoService.EndGrouping();
            vm.Document.UndoService.SetActionName("Add Clips");
        }
    }
}
