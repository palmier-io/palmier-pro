using PalmierPro.App.Views.Inspector;
using PalmierPro.App.ViewModels.Editor;
using PalmierPro.Core.Models;
using PalmierPro.Services.Engine;

namespace PalmierPro.App.ViewModels.Inspector;

/// Backs TransformTabView (M5, Stage E) — the Video tab's transform/crop/opacity/flip/blend/speed
/// controls. Ports the relevant slice of `EditorViewModel+Keyframes.swift` (the animation-aware
/// `applyX`/`commitX`/`writeX` triples) and `InspectorView.swift`'s `transformSection`/
/// `speedSection`/`cropRow`/`flipRow`/`blendRow`.
///
/// Every live-drag/commit mutation routes through TimelineEditorViewModel.ClipProperties.cs's
/// `ApplyClipProperties`/`CommitClipProperties` (added alongside the Text/Keyframes tabs) rather
/// than a locally-duplicated apply/commit pair — that class owns the pre-gesture `_dragBefore`
/// snapshot dictionary already shared with `ApplyClipSpeed`/`CommitClipSpeed`, so a timeline-tab
/// switch mid-drag correctly reverts a Transform gesture too, not just a Speed one. Flip/Blend/Reset
/// (no live-drag phase) go through the older, still-current `MutateClips` primitive; Speed goes
/// through `ApplyClipSpeed`/`CommitClipSpeed`; keyframe stamp/remove delegate to
/// TimelineEditorViewModel.Keyframes.cs's `StampKeyframe`/`RemoveKeyframe`.
///
/// Holds clip IDs, not `Clip` references: every undo/redo swap on this class replaces `Track.Clips`
/// entries wholesale, so a `Clip` reference captured at construction can go stale the moment an undo
/// lands while this tab instance is still alive. Every read/write below re-resolves through
/// <see cref="TimelineEditorViewModel.ClipFor"/> instead.
public sealed class TransformViewModel
{
    private readonly TimelineEditorViewModel _timeline;
    private readonly List<string> _clipIds;
    private readonly List<string> _speedClipIds;

    public TransformViewModel(InspectorTabContext context)
    {
        _timeline = context.Timeline;
        _clipIds = [.. context.SelectedClips
            .Where(c => c.MediaType.IsVisual() && c.MediaType != ClipType.Text)
            .Select(c => c.Id)];
        // Mirrors the Mac's `(nonTextVisualClips + selectedAudioClips).filter(\.supportsRetiming)` —
        // Speed applies to any non-text clip that supports retiming, visual or audio.
        _speedClipIds = [.. context.SelectedClips
            .Where(c => c.MediaType != ClipType.Text && c.SupportsRetiming)
            .Select(c => c.Id)];
    }

    private int Frame => _timeline.CurrentFrame;

    private List<Clip> ResolveClips(List<string> ids) =>
        [.. ids.Select(id => _timeline.ClipFor(id)).Where(c => c is not null).Select(c => c!)];

    public List<Clip> Clips => ResolveClips(_clipIds);

    public List<Clip> SpeedClips => ResolveClips(_speedClipIds);

    public Clip? Single => _clipIds.Count == 1 ? _timeline.ClipFor(_clipIds[0]) : null;

    // MARK: - Shared-value reads (mixed selection -> null, mirrors `sharedClipValue`)

    private static T? SharedValue<T>(IReadOnlyList<Clip> clips, Func<Clip, T> extract) where T : struct, IEquatable<T>
    {
        if (clips.Count == 0)
        {
            return null;
        }
        var v = extract(clips[0]);
        for (var i = 1; i < clips.Count; i++)
        {
            if (!extract(clips[i]).Equals(v))
            {
                return null;
            }
        }
        return v;
    }

    public double? PositionXShared => SharedValue(Clips, c => c.TopLeftAt(Frame).X);

    public double? PositionYShared => SharedValue(Clips, c => c.TopLeftAt(Frame).Y);

    public double? ScaleShared => SharedValue(Clips, c => c.SizeAt(Frame).Width);

    public double? RotationShared => SharedValue(Clips, c => c.RotationAt(Frame));

    public double? OpacityShared => SharedValue(Clips, c => c.RawOpacityAt(Frame));

    public double? SpeedShared => SharedValue(SpeedClips, c => c.Speed);

    public bool FlipHorizontalActive => Clips.Count > 0 && Clips[0].Transform.FlipHorizontal;

    public bool FlipVerticalActive => Clips.Count > 0 && Clips[0].Transform.FlipVertical;

    public BlendMode BlendCurrent => Clips.Count > 0 ? Clips[0].BlendMode ?? BlendMode.Normal : BlendMode.Normal;

    public bool BlendMixed => Clips.Count > 1 && Clips.Any(c => (c.BlendMode ?? BlendMode.Normal) != BlendCurrent);

    /// Last aspect preset picked from the crop menu — UI-only memory, not persisted (the Mac's
    /// `editor.cropAspectLock` is a `@State` on EditorViewModel with the same "just remembers the
    /// last pick" scope; this tab instance is rebuilt on every selection change anyway).
    public CropAspectLock CropAspectLockState { get; private set; } = CropAspectLock.Free;

    /// Pushes the current per-clip param values straight to the engine (PE_TimelineRefreshParams),
    /// skipping a full snapshot rebuild — the live-preview half of the M5 contract. Called directly
    /// by this tab rather than through `RefreshVisualsRequested`: nothing in this port wires that
    /// event to `IVideoEngine.RefreshParams` yet (see TimelineEditorViewModel.ClipProperties.cs's
    /// own remarks), and doing it here keeps Transform's live preview correct regardless of whether
    /// or when that central wiring lands.
    private void PushLiveRefresh(IReadOnlyList<Clip> targets)
    {
        if (_timeline.Engine is not { } engine || targets.Count == 0)
        {
            return;
        }
        var patches = targets.Select(c => new ClipParamPatch(
            c.Id,
            Opacity: c.RawOpacityAt(Frame),
            Transform: c.TransformAt(Frame),
            Crop: c.CropAt(Frame),
            BlendMode: c.BlendMode)).ToList();
        engine.RefreshParams(new TimelineParamPatch(_timeline.ActiveTimelineId, patches));
    }

    // MARK: - Position

    private void WritePosition(Clip c, double? setX, double? setY)
    {
        var frame = Frame;
        var tl = c.TopLeftAt(frame);
        var newX = setX ?? tl.X;
        var newY = setY ?? tl.Y;
        var sz = c.SizeAt(frame);
        if (c.PositionTrack is { IsActive: true })
        {
            c.UpsertPositionKeyframe(frame, new AnimPair(newX, newY));
        }
        else
        {
            c.Transform.CenterX = newX + sz.Width / 2;
            c.Transform.CenterY = newY + sz.Height / 2;
        }
    }

    public void ApplyPosition(double? x, double? y)
    {
        _timeline.ApplyClipProperties(_clipIds, rebuild: false, c => WritePosition(c, x, y));
        PushLiveRefresh(Clips);
    }

    public void CommitPosition(double? x, double? y)
    {
        _timeline.CommitClipProperties(_clipIds, c => WritePosition(c, x, y));
        _timeline.Document.UndoService.SetActionName("Change Position");
    }

    // MARK: - Scale

    private double? MediaCanvasAspect(Clip clip)
    {
        var dims = SourceDimensions(clip);
        if (dims is not { } d || _timeline.Timeline.Width <= 0 || _timeline.Timeline.Height <= 0)
        {
            return null;
        }
        var canvasAspect = (double)_timeline.Timeline.Width / _timeline.Timeline.Height;
        return ((double)d.Width / d.Height) / canvasAspect;
    }

    /// Source pixel dimensions for a clip: media-manifest entry dims, or the child timeline's for
    /// nested-sequence carriers. Mirrors `EditorViewModel.sourceDimensions(for:)`.
    private (int Width, int Height)? SourceDimensions(Clip clip)
    {
        var entry = _timeline.Document.Manifest.Entries.FirstOrDefault(e => e.Id == clip.MediaRef);
        if (entry is { SourceWidth: { } w, SourceHeight: { } h } && w > 0 && h > 0)
        {
            return (w, h);
        }
        if (clip.SourceClipType == ClipType.Sequence)
        {
            var child = _timeline.Timelines.FirstOrDefault(t => t.Id == clip.MediaRef);
            if (child is { Width: > 0, Height: > 0 })
            {
                return (child.Width, child.Height);
            }
        }
        return null;
    }

    private void WriteScale(Clip c, double newScale)
    {
        var aspect = MediaCanvasAspect(c) ?? 1.0;
        var w = newScale;
        var h = newScale / aspect;
        if (c.ScaleTrack is { IsActive: true })
        {
            c.UpsertScaleKeyframe(Frame, new AnimPair(w, h));
        }
        else
        {
            c.Transform.Width = w;
            c.Transform.Height = h;
        }
    }

    public void ApplyScale(double newScale)
    {
        _timeline.ApplyClipProperties(_clipIds, rebuild: false, c => WriteScale(c, newScale));
        PushLiveRefresh(Clips);
    }

    public void CommitScale(double newScale)
    {
        _timeline.CommitClipProperties(_clipIds, c => WriteScale(c, newScale));
        _timeline.Document.UndoService.SetActionName("Change Scale");
    }

    // MARK: - Rotation

    private void WriteRotation(Clip c, double valueDeg)
    {
        if (c.RotationTrack is { IsActive: true })
        {
            c.UpsertRotationKeyframe(Frame, valueDeg);
        }
        else
        {
            c.Transform.Rotation = valueDeg;
        }
    }

    public void ApplyRotation(double valueDeg)
    {
        _timeline.ApplyClipProperties(_clipIds, rebuild: false, c => WriteRotation(c, valueDeg));
        PushLiveRefresh(Clips);
    }

    public void CommitRotation(double valueDeg)
    {
        _timeline.CommitClipProperties(_clipIds, c => WriteRotation(c, valueDeg));
        _timeline.Document.UndoService.SetActionName("Change Rotation");
    }

    // MARK: - Opacity

    private void WriteOpacity(Clip c, double value)
    {
        if (c.OpacityTrack is { IsActive: true })
        {
            c.UpsertOpacityKeyframe(Frame, value);
        }
        else
        {
            c.Opacity = value;
        }
    }

    public void ApplyOpacity(double value)
    {
        _timeline.ApplyClipProperties(_clipIds, rebuild: false, c => WriteOpacity(c, value));
        PushLiveRefresh(Clips);
    }

    public void CommitOpacity(double value)
    {
        _timeline.CommitClipProperties(_clipIds, c => WriteOpacity(c, value));
        _timeline.Document.UndoService.SetActionName("Change Opacity");
    }

    // MARK: - Crop

    private void WriteCrop(Clip c, Crop newCrop)
    {
        if (c.CropTrack is { IsActive: true })
        {
            c.UpsertCropKeyframe(Frame, newCrop);
        }
        else
        {
            c.Crop = newCrop;
        }
    }

    /// Fits a crop box to `target`'s pixel aspect, anchored at the source's center. Mirrors
    /// `EditorViewModel.cropFittingAspect(for:targetPixelAspect:)`.
    private Crop CropFittingAspect(Clip clip, double target)
    {
        if (SourceDimensions(clip) is not { } dims || target <= 0)
        {
            return new Crop();
        }
        var sourceAspect = (double)dims.Width / dims.Height;
        if (Math.Abs(sourceAspect - target) < 0.0001)
        {
            return new Crop();
        }
        if (sourceAspect > target)
        {
            var total = 1 - target / sourceAspect;
            var left = total * 0.5;
            return new Crop { Left = left, Top = 0, Right = total - left, Bottom = 0 };
        }
        var totalV = 1 - sourceAspect / target;
        var top = totalV * 0.5;
        return new Crop { Left = 0, Top = top, Right = 0, Bottom = totalV - top };
    }

    /// Applies an aspect-lock preset to the single selected clip's crop (no live-drag phase — a
    /// menu pick commits immediately). Mirrors the Mac `cropMenu`/`applyCropPreset`. A no-op
    /// selection-wise (just remembers the pick) for `Free`, which intentionally leaves the current
    /// crop shape alone.
    public void ApplyCropPreset(CropAspectLock preset)
    {
        CropAspectLockState = preset;
        if (Single is not { } clip || preset == CropAspectLock.Free)
        {
            return;
        }
        var newCrop = preset == CropAspectLock.Original
            ? new Crop()
            : CropFittingAspect(clip, preset.PixelAspect() ?? 1.0);
        _timeline.CommitClipProperties([clip.Id], c => WriteCrop(c, newCrop));
        _timeline.Document.UndoService.SetActionName("Change Crop");
        PushLiveRefresh(Clips);
    }

    // MARK: - Flip / Blend / Reset (single-shot commits — no live-drag phase)

    public void ToggleFlipHorizontal()
    {
        var clips = Clips;
        if (clips.Count == 0)
        {
            return;
        }
        var newValue = !clips[0].Transform.FlipHorizontal;
        _timeline.MutateClips(new HashSet<string>(clips.Select(c => c.Id)), "Flip Horizontal", c => c.Transform.FlipHorizontal = newValue);
        PushLiveRefresh(ResolveClips(_clipIds));
    }

    public void ToggleFlipVertical()
    {
        var clips = Clips;
        if (clips.Count == 0)
        {
            return;
        }
        var newValue = !clips[0].Transform.FlipVertical;
        _timeline.MutateClips(new HashSet<string>(clips.Select(c => c.Id)), "Flip Vertical", c => c.Transform.FlipVertical = newValue);
        PushLiveRefresh(ResolveClips(_clipIds));
    }

    public void SetBlendMode(BlendMode mode)
    {
        var clips = Clips;
        if (clips.Count == 0)
        {
            return;
        }
        _timeline.MutateClips(new HashSet<string>(clips.Select(c => c.Id)), "Blend Mode", c => c.BlendMode = mode == BlendMode.Normal ? null : mode);
        PushLiveRefresh(ResolveClips(_clipIds));
    }

    public void ResetTransform()
    {
        var clips = Clips;
        if (clips.Count == 0)
        {
            return;
        }
        var canvasW = _timeline.Timeline.Width;
        var canvasH = _timeline.Timeline.Height;
        _timeline.MutateClips(new HashSet<string>(clips.Select(c => c.Id)), "Reset Transform", c =>
        {
            var dims = SourceDimensions(c);
            c.Transform = TimelineEditorViewModel.FitTransform(dims?.Width, dims?.Height, canvasW, canvasH);
            c.Opacity = 1;
            c.OpacityTrack = null;
            c.PositionTrack = null;
            c.ScaleTrack = null;
            c.RotationTrack = null;
            c.FadeInFrames = 0;
            c.FadeOutFrames = 0;
            c.FadeInInterpolation = Interpolation.Linear;
            c.FadeOutInterpolation = Interpolation.Linear;
        });
        PushLiveRefresh(ResolveClips(_clipIds));
    }

    // MARK: - Speed (thin wrapper over the existing ApplyClipSpeed/CommitClipSpeed contract)

    public void ApplySpeed(double newSpeed)
    {
        foreach (var id in _speedClipIds)
        {
            _timeline.ApplyClipSpeed(id, newSpeed);
        }
    }

    public void CommitSpeed(double newSpeed) => _timeline.CommitClipSpeed(_speedClipIds, newSpeed);

    // MARK: - Keyframes (read helpers stay local — thin queries over Clip.KeyframeFrames; mutations
    // delegate to TimelineEditorViewModel.Keyframes.cs's shared stamp/remove, also used by the
    // Keyframes tab).

    private List<int> KeyframeFrames(string clipId, AnimatableProperty property) =>
        _timeline.ClipFor(clipId)?.KeyframeFrames(property) ?? [];

    public bool HasKeyframe(string clipId, AnimatableProperty property, int frame) =>
        KeyframeFrames(clipId, property).Contains(frame);

    public int? PreviousKeyframeFrame(string clipId, AnimatableProperty property, int frame)
    {
        var candidates = KeyframeFrames(clipId, property).Where(f => f < frame).ToList();
        return candidates.Count == 0 ? null : candidates.Max();
    }

    public int? NextKeyframeFrame(string clipId, AnimatableProperty property, int frame)
    {
        var candidates = KeyframeFrames(clipId, property).Where(f => f > frame).ToList();
        return candidates.Count == 0 ? null : candidates.Min();
    }

    public void StampKeyframe(string clipId, AnimatableProperty property) => _timeline.StampKeyframe(clipId, property, Frame);

    public void RemoveKeyframe(string clipId, AnimatableProperty property, int frame) => _timeline.RemoveKeyframe(clipId, property, frame);
}
