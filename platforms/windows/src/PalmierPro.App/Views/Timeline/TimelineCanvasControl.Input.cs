using Microsoft.UI.Input;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using PalmierPro.App.Editing;
using PalmierPro.App.ViewModels.Editor;
using PalmierPro.Core.Models;
using PalmierPro.Core.Timeline;
using Windows.Foundation;
using Windows.System;
using Windows.UI.Core;

namespace PalmierPro.App.Views.Timeline;

/// Pointer/keyboard half of TimelineCanvasControl — ports the click-select, drag-move, edge-trim,
/// marquee, zoom/scroll, and playhead-scrub slices of TimelineInputController.swift. Scoped down
/// from the Mac original per the ViewModel's own "not ported" boundary (multicam, razor tool,
/// audio-volume-keyframe drag, fade-knee drag, AI ripple-insert preview, timeline-range selection
/// — all Inspector/M5 or Phase-2 concerns) plus one UI-only simplification: a clip drag renders a
/// ghost preview and only touches the live model on commit (mouse-up), rather than the Mac's
/// live-mutate-then-revert-on-cancel dance — simpler, and avoids re-deriving that revert logic
/// here. Drag-and-drop-IN (media panel / Explorer) lives in TimelineCanvasControl.DragDrop.cs.
public sealed partial class TimelineCanvasControl
{
    private sealed class MoveDrag
    {
        public required string LeadClipId;
        public required int LeadOriginalTrack;
        public required int LeadOriginalFrame;
        public required int GrabOffsetFrames;
        public required List<(string ClipId, int OriginalTrack, int OriginalFrame)> Companions;
        public int DeltaFrames;
        public TrackDropTarget DropTarget = new TrackDropTarget.ExistingTrack(0);
        public SnapEngine.SnapState SnapState;

        public IEnumerable<(string ClipId, int OriginalTrack, int OriginalFrame)> All()
        {
            yield return (LeadClipId, LeadOriginalTrack, LeadOriginalFrame);
            foreach (var c in Companions)
            {
                yield return c;
            }
        }

        public HashSet<string> AllIds() => [.. All().Select(p => p.ClipId)];
    }

    private sealed class TrimDrag
    {
        public required string ClipId;
        public required int TrackIndex;
        public required TrimEdge Edge;
        public required int OriginalStartFrame;
        public required int OriginalDuration;
        public required int OriginalTrimStart;
        public required int OriginalTrimEnd;
        public required bool HasNoSourceMedia;
        public required bool PropagateToLinked;
        public required bool IsRipple;
        public int DeltaFrames;
        public SnapEngine.SnapState SnapState;
    }

    private sealed class MarqueeDrag
    {
        public required Point Origin;
        public Rect Current;
        public required HashSet<string> BaseSelection;
    }

    private sealed class ResizeTrackDrag
    {
        public required int TrackIndex;
        public required double OriginalHeight;
        public double CurrentHeight;
    }

    private sealed class ScrubDrag;

    // MARK: - Pointer down

    private void Canvas_PointerPressed(object sender, PointerRoutedEventArgs e)
    {
        Canvas.Focus(Microsoft.UI.Xaml.FocusState.Pointer);
        if (Vm is not { } vm)
        {
            return;
        }
        var point = e.GetCurrentPoint(Canvas);
        var pos = point.Position;

        if (pos.X < TimelineGeometry.Layout.HeaderWidth)
        {
            if (HandleHeaderPointerPressed(vm, pos))
            {
                Canvas.CapturePointer(e.Pointer);
                return;
            }
        }

        if (pos.Y < TimelineGeometry.Layout.RulerHeight)
        {
            _drag = new ScrubDrag();
            ScrubToScreenX(vm, pos.X);
            Canvas.CapturePointer(e.Pointer);
            return;
        }

        var geo = BuildGeometry();
        var docX = DocXForScreen(pos.X);
        var docY = DocYForScreen(pos.Y);
        var isCtrl = IsKeyDown(VirtualKey.Control);

        var hit = TimelineHitTesting.HitTestClip(vm.Timeline, geo, docX, docY);
        if (hit is { } loc)
        {
            var clip = vm.Timeline.Tracks[loc.TrackIndex].Clips[loc.ClipIndex];
            SetHoveredClip(clip.Id);
            var docRect = geo.ClipRect(clip, loc.TrackIndex);
            var localX = docX - docRect.X;

            if (isCtrl)
            {
                var group = vm.ExpandToLinkGroup([clip.Id]);
                vm.SelectedClipIds = vm.SelectedClipIds.Contains(clip.Id)
                    ? new HashSet<string>(vm.SelectedClipIds.Except(group))
                    : new HashSet<string>(vm.SelectedClipIds.Union(group));
                RequestRedraw();
                return;
            }
            if (!vm.SelectedClipIds.Contains(clip.Id))
            {
                vm.SelectedClipIds = vm.ExpandToLinkGroup([clip.Id]);
            }
            vm.SelectedGap = null;

            var edge = TimelineHitTesting.EdgeAt(localX, docRect.Width);
            if (edge is { } trimEdge)
            {
                var isRipple = IsKeyDown(VirtualKey.Shift);
                _drag = new TrimDrag
                {
                    ClipId = clip.Id,
                    TrackIndex = loc.TrackIndex,
                    Edge = trimEdge,
                    OriginalStartFrame = clip.StartFrame,
                    OriginalDuration = clip.DurationFrames,
                    OriginalTrimStart = clip.TrimStartFrame,
                    OriginalTrimEnd = EffectiveTrimEnd(vm, clip),
                    HasNoSourceMedia = clip.MediaType is ClipType.Image or ClipType.Text,
                    PropagateToLinked = true,
                    IsRipple = isRipple,
                };
                UpdateTrimCursor(trimEdge);
            }
            else
            {
                var companions = new List<(string ClipId, int OriginalTrack, int OriginalFrame)>();
                for (var ti = 0; ti < vm.Timeline.Tracks.Count; ti++)
                {
                    foreach (var c in vm.Timeline.Tracks[ti].Clips)
                    {
                        if (c.Id != clip.Id && vm.SelectedClipIds.Contains(c.Id))
                        {
                            companions.Add((c.Id, ti, c.StartFrame));
                        }
                    }
                }
                _drag = new MoveDrag
                {
                    LeadClipId = clip.Id,
                    LeadOriginalTrack = loc.TrackIndex,
                    LeadOriginalFrame = clip.StartFrame,
                    GrabOffsetFrames = geo.FrameAt(docX) - clip.StartFrame,
                    Companions = companions,
                    DropTarget = new TrackDropTarget.ExistingTrack(loc.TrackIndex),
                };
            }
        }
        else
        {
            SetHoveredClip(null);
            if (!isCtrl)
            {
                vm.SelectedClipIds = [];
            }
            var trackIndex = geo.TrackAt(docY);
            vm.SelectedGap = TimelineHitTesting.HitTestGap(vm.Timeline, geo, trackIndex, docX, docY);
            _drag = new MarqueeDrag { Origin = pos, BaseSelection = new HashSet<string>(vm.SelectedClipIds) };
        }

        Canvas.CapturePointer(e.Pointer);
        RequestRedraw();
    }

    /// Right-trim ceiling for a clip: source-material length for ordinary clips, but for a nested
    /// sequence the child timeline's *live* length (it may have changed since this clip was placed).
    private static int EffectiveTrimEnd(TimelineEditorViewModel vm, Clip clip)
    {
        if (clip.SourceClipType != ClipType.Sequence || vm.TimelineFor(clip.MediaRef) is not { } child)
        {
            return clip.TrimEndFrame;
        }
        return Math.Max(0, child.TotalFrames - clip.TrimStartFrame - clip.DurationFrames);
    }

    private bool HandleHeaderPointerPressed(TimelineEditorViewModel vm, Point pos)
    {
        foreach (var (ti, rect) in _muteButtonRects)
        {
            if (rect.Contains(pos))
            {
                vm.ToggleTrackMute(ti);
                return true;
            }
        }
        foreach (var (ti, rect) in _hideButtonRects)
        {
            if (rect.Contains(pos))
            {
                vm.ToggleTrackHidden(ti);
                return true;
            }
        }
        foreach (var (ti, rect) in _syncLockButtonRects)
        {
            if (rect.Contains(pos))
            {
                vm.ToggleTrackSyncLock(ti);
                return true;
            }
        }

        var geo = BuildGeometry();
        for (var i = 0; i < vm.Timeline.Tracks.Count; i++)
        {
            var bottom = ScreenY(geo.TrackY(i) + geo.TrackHeight(i));
            if (Math.Abs(pos.Y - bottom) <= 4)
            {
                _drag = new ResizeTrackDrag { TrackIndex = i, OriginalHeight = geo.TrackHeight(i), CurrentHeight = geo.TrackHeight(i) };
                return true;
            }
        }
        return false;
    }

    // MARK: - Pointer move

    private void Canvas_PointerMoved(object sender, PointerRoutedEventArgs e)
    {
        if (Vm is not { } vm)
        {
            return;
        }
        var pos = e.GetCurrentPoint(Canvas).Position;
        var geo = BuildGeometry();

        switch (_drag)
        {
            case ScrubDrag:
                ScrubToScreenX(vm, pos.X);
                return;

            case MoveDrag move:
                UpdateMoveDrag(vm, geo, move, pos);
                RequestRedraw();
                return;

            case TrimDrag trim:
                UpdateTrimDrag(vm, geo, trim, pos.X);
                RequestRedraw();
                return;

            case MarqueeDrag marquee:
                UpdateMarquee(vm, geo, marquee, pos, e);
                RequestRedraw();
                return;

            case ResizeTrackDrag resize:
                var trackTop = ScreenY(geo.TrackY(resize.TrackIndex));
                resize.CurrentHeight = Math.Clamp(pos.Y - trackTop, TrackSize.MinHeight, TrackSize.MaxHeight);
                RequestRedraw();
                return;
        }

        UpdateHoverAndCursor(vm, geo, pos);
    }

    private void UpdateMoveDrag(TimelineEditorViewModel vm, TimelineGeometry geo, MoveDrag move, Point pos)
    {
        var frame = geo.FrameAt(DocXForScreen(pos.X));
        var candidateFrame = frame - move.GrabOffsetFrames;
        var allIds = move.AllIds();
        var targets = SnapEngine.CollectTargets(vm.Timeline.Tracks, vm.CurrentFrame, allIds, includePlayhead: true);

        var probeOffsets = new List<int>();
        foreach (var p in move.All())
        {
            var c = vm.ClipFor(p.ClipId);
            if (c is null)
            {
                continue;
            }
            var baseOffset = p.OriginalFrame - move.LeadOriginalFrame;
            probeOffsets.Add(baseOffset);
            probeOffsets.Add(baseOffset + c.DurationFrames);
        }

        var snapState = move.SnapState;
        var snap = SnapEngine.FindSnap(candidateFrame, targets, ref snapState, TimelineInputConstants.Snap.ThresholdPixels, _pixelsPerFrame, probeOffsets);
        move.SnapState = snapState;
        if (snap is { } s)
        {
            SetLocalSnapX(TimelineGeometry.Layout.HeaderWidth + s.X - _scrollX);
            move.DeltaFrames = (s.Frame - s.ProbeOffset) - move.LeadOriginalFrame;
        }
        else
        {
            SetLocalSnapX(null);
            move.DeltaFrames = candidateFrame - move.LeadOriginalFrame;
        }
        var minOriginal = move.All().Select(p => p.OriginalFrame).Min();
        move.DeltaFrames = Math.Max(-minOriginal, move.DeltaFrames);

        var cursorTarget = geo.DropTargetAt(DocYForScreen(pos.Y));
        if (cursorTarget is TrackDropTarget.ExistingTrack(var cursorTrack))
        {
            move.DropTarget = new TrackDropTarget.ExistingTrack(Math.Clamp(cursorTrack, 0, vm.Timeline.Tracks.Count - 1));
        }
        else
        {
            move.DropTarget = cursorTarget;
        }
    }

    private void UpdateTrimDrag(TimelineEditorViewModel vm, TimelineGeometry geo, TrimDrag trim, double screenX)
    {
        var frame = geo.FrameAt(DocXForScreen(screenX));
        var excluding = new HashSet<string> { trim.ClipId };
        var targets = SnapEngine.CollectTargets(vm.Timeline.Tracks, vm.CurrentFrame, excluding, includePlayhead: true);
        var snapState = trim.SnapState;

        if (trim.Edge == TrimEdge.Left)
        {
            var snap = SnapEngine.FindSnap(frame, targets, ref snapState, TimelineInputConstants.Snap.ThresholdPixels, _pixelsPerFrame);
            trim.SnapState = snapState;
            var snappedStart = snap?.Frame ?? frame;
            SetLocalSnapX(snap is { } s ? TimelineGeometry.Layout.HeaderWidth + s.X - _scrollX : null);
            var delta = snappedStart - trim.OriginalStartFrame;
            var maxDelta = trim.OriginalDuration - 1;
            var minDelta = trim.HasNoSourceMedia ? -trim.OriginalStartFrame : -trim.OriginalTrimStart;
            trim.DeltaFrames = Math.Max(minDelta, Math.Min(maxDelta, delta));
        }
        else
        {
            var originalEnd = trim.OriginalStartFrame + trim.OriginalDuration;
            var candidateEnd = Math.Max(trim.OriginalStartFrame + 1, frame);
            var snap = SnapEngine.FindSnap(candidateEnd, targets, ref snapState, TimelineInputConstants.Snap.ThresholdPixels, _pixelsPerFrame);
            trim.SnapState = snapState;
            var snappedEnd = snap?.Frame ?? candidateEnd;
            SetLocalSnapX(snap is { } s ? TimelineGeometry.Layout.HeaderWidth + s.X - _scrollX : null);
            var delta = snappedEnd - originalEnd;
            var minDelta = -(trim.OriginalDuration - 1);
            if (trim.HasNoSourceMedia)
            {
                trim.DeltaFrames = Math.Max(minDelta, delta);
            }
            else
            {
                trim.DeltaFrames = Math.Max(minDelta, Math.Min(trim.OriginalTrimEnd, delta));
            }
        }
    }

    private void UpdateMarquee(TimelineEditorViewModel vm, TimelineGeometry geo, MarqueeDrag marquee, Point pos, PointerRoutedEventArgs e)
    {
        marquee.Current = new Rect(
            Math.Min(marquee.Origin.X, pos.X), Math.Min(marquee.Origin.Y, pos.Y),
            Math.Abs(pos.X - marquee.Origin.X), Math.Abs(pos.Y - marquee.Origin.Y));

        var docRect = new Rect(DocXForScreen(marquee.Current.X), DocYForScreen(marquee.Current.Y), marquee.Current.Width, marquee.Current.Height);
        var selected = new HashSet<string>(marquee.BaseSelection);
        for (var ti = 0; ti < vm.Timeline.Tracks.Count; ti++)
        {
            foreach (var clip in vm.Timeline.Tracks[ti].Clips)
            {
                var r = geo.ClipRect(clip, ti);
                var clipRect = new Rect(r.X, r.Y, r.Width, r.Height);
                if (RectsIntersect(clipRect, docRect))
                {
                    selected.Add(clip.Id);
                }
            }
        }
        if (!IsKeyDown(VirtualKey.Menu))
        {
            selected = vm.ExpandToLinkGroup(selected);
        }
        if (!selected.SetEquals(vm.SelectedClipIds))
        {
            vm.SelectedClipIds = selected;
        }
    }

    private static bool RectsIntersect(Rect a, Rect b) =>
        a.X < b.X + b.Width && a.X + a.Width > b.X && a.Y < b.Y + b.Height && a.Y + a.Height > b.Y;

    private void UpdateHoverAndCursor(TimelineEditorViewModel vm, TimelineGeometry geo, Point pos)
    {
        if (pos.X < TimelineGeometry.Layout.HeaderWidth)
        {
            SetHoveredClip(null);
            var overResize = false;
            for (var i = 0; i < vm.Timeline.Tracks.Count; i++)
            {
                var bottom = ScreenY(geo.TrackY(i) + geo.TrackHeight(i));
                if (Math.Abs(pos.Y - bottom) <= 4)
                {
                    overResize = true;
                    break;
                }
            }
            ProtectedCursor = InputSystemCursor.Create(overResize ? InputSystemCursorShape.SizeNorthSouth : InputSystemCursorShape.Arrow);
            return;
        }
        if (pos.Y < TimelineGeometry.Layout.RulerHeight)
        {
            SetHoveredClip(null);
            ProtectedCursor = InputSystemCursor.Create(InputSystemCursorShape.Hand);
            return;
        }

        var hit = TimelineHitTesting.HitTestClip(vm.Timeline, geo, DocXForScreen(pos.X), DocYForScreen(pos.Y));
        if (hit is { } loc)
        {
            var clip = vm.Timeline.Tracks[loc.TrackIndex].Clips[loc.ClipIndex];
            SetHoveredClip(clip.Id);
            var rect = geo.ClipRect(clip, loc.TrackIndex);
            var localX = DocXForScreen(pos.X) - rect.X;
            var edge = TimelineHitTesting.EdgeAt(localX, rect.Width);
            if (edge is { } e)
            {
                UpdateTrimCursor(e);
                return;
            }
            ProtectedCursor = InputSystemCursor.Create(InputSystemCursorShape.Arrow);
        }
        else
        {
            SetHoveredClip(null);
            ProtectedCursor = InputSystemCursor.Create(InputSystemCursorShape.Arrow);
        }
    }

    private void UpdateTrimCursor(TrimEdge edge) =>
        ProtectedCursor = InputSystemCursor.Create(InputSystemCursorShape.SizeWestEast);

    // MARK: - Pointer up

    private void Canvas_PointerReleased(object sender, PointerRoutedEventArgs e)
    {
        Canvas.ReleasePointerCapture(e.Pointer);
        if (Vm is not { } vm)
        {
            _drag = null;
            return;
        }

        switch (_drag)
        {
            case MoveDrag move:
                CommitMove(vm, move);
                break;
            case TrimDrag trim:
                CommitTrim(vm, trim);
                break;
            case ResizeTrackDrag resize when Math.Abs(resize.CurrentHeight - resize.OriginalHeight) > 0.5:
                vm.SetTrackHeight(resize.TrackIndex, resize.CurrentHeight);
                break;
        }

        _drag = null;
        SetLocalSnapX(null);
        RequestRedraw();
    }

    private void CommitMove(TimelineEditorViewModel vm, MoveDrag move)
    {
        if (move.DropTarget is TrackDropTarget.ExistingTrack(var idx) && idx == move.LeadOriginalTrack && move.DeltaFrames == 0)
        {
            return;
        }

        var participants = move.All().ToList();
        var minOriginal = participants.Min(p => p.OriginalFrame);
        var frameDelta = Math.Max(-minOriginal, move.DeltaFrames);

        if (move.DropTarget is TrackDropTarget.ExistingTrack(var toTrack))
        {
            var delta = toTrack - move.LeadOriginalTrack;
            var moves = participants.Select(p => (p.ClipId, ToTrack: p.OriginalTrack + delta, ToFrame: p.OriginalFrame + frameDelta)).ToList();
            vm.MoveClips(moves);
        }
        else if (move.DropTarget is TrackDropTarget.NewTrackAt(var insertIndex))
        {
            var leadClip = vm.ClipFor(move.LeadClipId);
            if (leadClip is null)
            {
                return;
            }
            var newType = leadClip.MediaType == ClipType.Audio ? ClipType.Audio : ClipType.Video;
            vm.Document.UndoService.BeginGrouping();
            try
            {
                var newIdx = vm.InsertTrack(insertIndex, newType);
                var moves = participants.Select(p =>
                {
                    var toTrack = p.OriginalTrack == move.LeadOriginalTrack ? newIdx : (p.OriginalTrack >= newIdx ? p.OriginalTrack + 1 : p.OriginalTrack);
                    return (p.ClipId, ToTrack: toTrack, ToFrame: p.OriginalFrame + frameDelta);
                }).ToList();
                vm.MoveClips(moves);
            }
            finally
            {
                vm.Document.UndoService.EndGrouping();
                vm.Document.UndoService.SetActionName(participants.Count == 1 ? "Move Clip" : "Move Clips");
            }
        }
    }

    private void CommitTrim(TimelineEditorViewModel vm, TrimDrag trim)
    {
        if (trim.DeltaFrames == 0)
        {
            return;
        }
        if (trim.IsRipple)
        {
            var edge = trim.Edge == TrimEdge.Left ? TimelineEditorViewModel.TrimEdge.Left : TimelineEditorViewModel.TrimEdge.Right;
            vm.RippleTrimClip(trim.ClipId, edge, trim.DeltaFrames, trim.PropagateToLinked);
            return;
        }

        var targets = new List<string> { trim.ClipId };
        if (trim.PropagateToLinked)
        {
            targets.AddRange(vm.LinkedPartnerIds(trim.ClipId));
        }
        var mode = trim.Edge == TrimEdge.Left ? TimelineEditorViewModel.TrimEdge.Left : TimelineEditorViewModel.TrimEdge.Right;
        var edits = new List<(string ClipId, int TrimStartFrame, int TrimEndFrame)>();
        foreach (var id in targets)
        {
            if (vm.ClipFor(id) is not { } c)
            {
                continue;
            }
            var (trimStart, trimEnd) = TimelineEditorViewModel.TrimValues(c, mode, trim.DeltaFrames);
            edits.Add((id, trimStart, trimEnd));
        }
        vm.TrimClips(edits);
    }

    // MARK: - Wheel / zoom

    private void Canvas_PointerWheelChanged(object sender, PointerRoutedEventArgs e)
    {
        if (Vm is null)
        {
            return;
        }
        var point = e.GetCurrentPoint(Canvas);
        var props = point.Properties;
        var notches = props.MouseWheelDelta / 120.0;

        if (IsKeyDown(VirtualKey.Control))
        {
            ApplyZoom(notches * 10, point.Position.X);
            e.Handled = true;
            return;
        }

        const double lineSize = 50;
        if (props.IsHorizontalMouseWheel || IsKeyDown(VirtualKey.Shift))
        {
            _scrollX = Math.Clamp(_scrollX - notches * lineSize, 0, HorizontalScrollBar.Maximum);
        }
        else
        {
            _scrollY = Math.Clamp(_scrollY - notches * lineSize, 0, VerticalScrollBar.Maximum);
        }
        UpdateScrollBarRanges();
        RequestRedraw();
        e.Handled = true;
    }

    private void ApplyZoom(double wheelDelta, double anchorScreenX)
    {
        var geo = BuildGeometry();
        var anchorFrame = Math.Max(0.0, DocXForScreen(anchorScreenX) - TimelineGeometry.Layout.HeaderWidth) / _pixelsPerFrame;
        var newScale = TimelineZoom.Apply(_pixelsPerFrame, wheelDelta);
        if (newScale == _pixelsPerFrame)
        {
            return;
        }
        _pixelsPerFrame = newScale;
        _scrollX = TimelineZoom.ScrollXForAnchor(anchorFrame, newScale, anchorScreenX, TimelineGeometry.Layout.HeaderWidth);
        UpdateScrollBarRanges();
        RequestRedraw();
    }

    // MARK: - Double-click / playhead scrub

    private void Canvas_DoubleTapped(object sender, DoubleTappedRoutedEventArgs e)
    {
        if (Vm is not { } vm)
        {
            return;
        }
        var pos = e.GetPosition(Canvas);
        if (pos.X < TimelineGeometry.Layout.HeaderWidth || pos.Y < TimelineGeometry.Layout.RulerHeight)
        {
            return;
        }
        var geo = BuildGeometry();
        if (TimelineHitTesting.HitTestClip(vm.Timeline, geo, DocXForScreen(pos.X), DocYForScreen(pos.Y)) is not { } loc)
        {
            return;
        }
        var clip = vm.Timeline.Tracks[loc.TrackIndex].Clips[loc.ClipIndex];
        if (clip.SourceClipType == ClipType.Sequence)
        {
            vm.ActivateTimeline(clip.MediaRef);
            RequestRedraw();
        }
    }

    private void ScrubToScreenX(TimelineEditorViewModel vm, double screenX)
    {
        var geo = BuildGeometry();
        vm.SeekToFrame(geo.FrameAt(DocXForScreen(screenX)));
        RequestRedraw();
    }

    // MARK: - Keyboard

    private void Canvas_KeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (Vm is not { } vm)
        {
            return;
        }
        switch (e.Key)
        {
            case VirtualKey.Escape when _drag is not null:
                _drag = null;
                SetLocalSnapX(null);
                RequestRedraw();
                e.Handled = true;
                break;
            case VirtualKey.Left:
                vm.SeekToFrame(vm.CurrentFrame - (IsKeyDown(VirtualKey.Shift) ? 10 : 1));
                e.Handled = true;
                break;
            case VirtualKey.Right:
                vm.SeekToFrame(vm.CurrentFrame + (IsKeyDown(VirtualKey.Shift) ? 10 : 1));
                e.Handled = true;
                break;
            case VirtualKey.Home:
                vm.SeekToFrame(0);
                e.Handled = true;
                break;
            case VirtualKey.End:
                vm.SeekToFrame(vm.Timeline.TotalFrames);
                e.Handled = true;
                break;
        }
    }

    private static bool IsKeyDown(VirtualKey key) =>
        InputKeyboardSource.GetKeyStateForCurrentThread(key).HasFlag(CoreVirtualKeyStates.Down);

    // MARK: - Context menus (right-click) — mirrors the ported slice of TimelineView.swift's
    // `menu(for:)`: multicam/AI-edit/nest/sync/media-swap items are Phase-2 or M5 concerns not
    // present on this ViewModel yet (see TimelineEditorViewModel's top-level doc comment) and are
    // not offered here.

    private void Canvas_RightTapped(object sender, RightTappedRoutedEventArgs e)
    {
        if (Vm is not { } vm)
        {
            return;
        }
        var pos = e.GetPosition(Canvas);
        var geo = BuildGeometry();

        if (pos.Y < TimelineGeometry.Layout.RulerHeight)
        {
            return;
        }
        if (pos.X < TimelineGeometry.Layout.HeaderWidth)
        {
            ShowTrackContextMenu(vm, geo.TrackAt(DocYForScreen(pos.Y)), pos);
            return;
        }

        var hit = TimelineHitTesting.HitTestClip(vm.Timeline, geo, DocXForScreen(pos.X), DocYForScreen(pos.Y));
        if (hit is { } loc)
        {
            var clip = vm.Timeline.Tracks[loc.TrackIndex].Clips[loc.ClipIndex];
            if (!vm.SelectedClipIds.Contains(clip.Id))
            {
                vm.SelectedClipIds = vm.ExpandToLinkGroup([clip.Id]);
                RequestRedraw();
            }
            ShowClipContextMenu(vm, clip, pos);
        }
        else
        {
            ShowEmptyAreaContextMenu(vm, geo.TrackAt(DocYForScreen(pos.Y)), pos);
        }
    }

    private void ShowClipContextMenu(TimelineEditorViewModel vm, Clip clip, Point pos)
    {
        var flyout = new MenuFlyout();
        var withinClip = vm.CurrentFrame > clip.StartFrame && vm.CurrentFrame < clip.EndFrame;

        AddMenuItem(flyout, "Select Forward on Track", () => vm.SelectForward(clip.Id, TimelineEditorViewModel.SelectForwardScope.Track));
        AddMenuItem(flyout, "Select Forward on All Tracks", () => vm.SelectForward(clip.Id, TimelineEditorViewModel.SelectForwardScope.AllTracks));
        flyout.Items.Add(new MenuFlyoutSeparator());
        AddMenuItem(flyout, "Split at Playhead", vm.SplitAtPlayhead, enabled: withinClip);
        AddMenuItem(flyout, "Trim Start to Playhead", vm.TrimStartToPlayhead, enabled: withinClip);
        AddMenuItem(flyout, "Trim End to Playhead", vm.TrimEndToPlayhead, enabled: withinClip);
        flyout.Items.Add(new MenuFlyoutSeparator());
        AddMenuItem(flyout, "Delete", vm.DeleteSelectedClips);
        AddMenuItem(flyout, "Ripple Delete", vm.RippleDeleteSelectedClips);

        flyout.ShowAt(Canvas, pos);
    }

    private void ShowTrackContextMenu(TimelineEditorViewModel vm, int trackIndex, Point pos)
    {
        var flyout = new MenuFlyout();
        if (trackIndex >= 0 && trackIndex < vm.Timeline.Tracks.Count)
        {
            var track = vm.Timeline.Tracks[trackIndex];
            if (track.Type == ClipType.Audio)
            {
                AddMenuItem(flyout, track.Muted ? "Unmute Track" : "Mute Track", () => vm.ToggleTrackMute(trackIndex));
            }
            else
            {
                AddMenuItem(flyout, track.Hidden ? "Show Track" : "Hide Track", () => vm.ToggleTrackHidden(trackIndex));
            }
            AddMenuItem(flyout, track.SyncLocked ? "Unlock Track Sync" : "Sync Lock Track", () => vm.ToggleTrackSyncLock(trackIndex));
            flyout.Items.Add(new MenuFlyoutSeparator());
            AddMenuItem(flyout, "Remove Track", () => vm.RemoveTrack(track.Id));
            flyout.Items.Add(new MenuFlyoutSeparator());
        }
        AddMenuItem(flyout, "Add Video Track", () => vm.InsertTrack(Math.Max(0, trackIndex), ClipType.Video));
        AddMenuItem(flyout, "Add Audio Track", () => vm.InsertTrack(vm.Timeline.Tracks.Count, ClipType.Audio));
        flyout.ShowAt(Canvas, pos);
    }

    private void ShowEmptyAreaContextMenu(TimelineEditorViewModel vm, int trackIndex, Point pos)
    {
        var flyout = new MenuFlyout();
        AddMenuItem(flyout, "Add Video Track", () => vm.InsertTrack(Math.Max(0, trackIndex), ClipType.Video));
        AddMenuItem(flyout, "Add Audio Track", () => vm.InsertTrack(vm.Timeline.Tracks.Count, ClipType.Audio));
        if (vm.SelectedGap is not null)
        {
            flyout.Items.Add(new MenuFlyoutSeparator());
            AddMenuItem(flyout, "Ripple Delete Gap", vm.RippleDeleteSelectedGap);
        }
        flyout.ShowAt(Canvas, pos);
    }

    private void AddMenuItem(MenuFlyout flyout, string text, Action action, bool enabled = true)
    {
        var item = new MenuFlyoutItem { Text = text, IsEnabled = enabled };
        item.Click += (_, _) => { action(); RequestRedraw(); };
        flyout.Items.Add(item);
    }
}
