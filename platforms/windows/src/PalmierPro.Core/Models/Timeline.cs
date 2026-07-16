using System.Text.Json;
using System.Text.Json.Serialization;
using PalmierPro.Core.Json;

namespace PalmierPro.Core.Models;

/// Clip location inside track storage. Not Codable in Swift (a `let`-only lookup key); ported as
/// a value type to match Swift's `Equatable` immutable struct.
public readonly record struct ClipLocation(int TrackIndex, int ClipIndex);

/// Written on tab switch and save, not live — playhead mutates every frame. No custom Swift
/// decoder, so (unlike Timeline/Track/Clip) all three fields are required on decode despite
/// having defaults.
public sealed class TimelineViewState
{
    [JsonPropertyName("playheadFrame")]
    [JsonRequired]
    public int PlayheadFrame { get; set; }

    [JsonPropertyName("zoomScale")]
    [JsonRequired]
    public double ZoomScale { get; set; } = Defaults.PixelsPerFrame;

    [JsonPropertyName("scrollOffsetX")]
    [JsonRequired]
    public double ScrollOffsetX { get; set; }
}

/// Maps a linear amplitude multiplier to dB for the volume slider. Below the floor, snaps to
/// true 0 (hard mute). Ported from Inspector/InspectorView.swift, not Models/Timeline.swift —
/// Clip.volumeAt/rawVolumeAt depend on it, so it travels with the timeline cluster.
public static class VolumeScale
{
    public const double FloorDb = -60;
    public const double CeilingDb = 15;

    public static double DbFromLinear(double linear)
    {
        if (linear <= 0)
        {
            return FloorDb;
        }
        return Math.Min(CeilingDb, Math.Max(FloorDb, 20 * Math.Log10(linear)));
    }

    public static double LinearFromDb(double db)
    {
        if (db <= FloorDb)
        {
            return 0;
        }
        return Math.Pow(10, Math.Min(db, CeilingDb) / 20);
    }
}

[JsonConverter(typeof(TimelineJsonConverter))]
public sealed class Timeline
{
    public string Id { get; set; } = SwiftId.New();
    public string Name { get; set; } = "Timeline 1";
    public int Fps { get; set; } = 30;
    public int Width { get; set; } = 1920;
    public int Height { get; set; } = 1080;
    public bool SettingsConfigured { get; set; }
    public string? FolderId { get; set; }
    public List<Track> Tracks { get; set; } = [];

    public int TotalFrames
    {
        get
        {
            var maxFrame = 0;
            foreach (var track in Tracks)
            {
                maxFrame = Math.Max(maxFrame, track.EndFrame);
            }
            return maxFrame;
        }
    }

    public HashSet<string> NestedTimelineIds
    {
        get
        {
            var ids = new HashSet<string>();
            foreach (var track in Tracks)
            {
                foreach (var clip in track.Clips.Where(c => c.MediaType == ClipType.Sequence || c.SourceClipType == ClipType.Sequence))
                {
                    ids.Add(clip.MediaRef);
                }
            }
            return ids;
        }
    }

    public bool HasAudioClips => Tracks.Any(t => t.Type == ClipType.Audio && t.Clips.Count > 0);

    /// Rescales every clip's frame-based fields by `scale` — ported from
    /// EditorViewModel+ProjectSettings.swift's `Timeline.rescaleFrames(by:)`, used when the
    /// project fps changes (frame counts are absolute, so every frame-denominated value has to
    /// move to the new fps's frame grid). Clips are processed in pre-rescale start-frame order
    /// and each new start is clamped against the previous clip's already-rescaled end, so
    /// independent per-clip rounding can never introduce an overlap that didn't exist before.
    public void RescaleFrames(double scale)
    {
        foreach (var track in Tracks)
        {
            var ordered = track.Clips.OrderBy(c => c.StartFrame).ToList();
            int? previousEnd = null;
            foreach (var clip in ordered)
            {
                var scaledStart = SwiftMath.RoundToInt(clip.StartFrame * scale);
                var scaledEnd = SwiftMath.RoundToInt(clip.EndFrame * scale);
                clip.StartFrame = Math.Max(scaledStart, previousEnd ?? scaledStart);
                clip.DurationFrames = Math.Max(1, scaledEnd - clip.StartFrame);
                clip.TrimStartFrame = SwiftMath.RoundToInt(clip.TrimStartFrame * scale);
                clip.TrimEndFrame = SwiftMath.RoundToInt(clip.TrimEndFrame * scale);
                clip.RescaleKeyframes(scale);
                clip.FadeInFrames = SwiftMath.RoundToInt(clip.FadeInFrames * scale);
                clip.FadeOutFrames = SwiftMath.RoundToInt(clip.FadeOutFrames * scale);
                clip.ClampKeyframesToDuration();
                clip.ClampFadesToDuration();
                previousEnd = clip.EndFrame;
            }
        }
    }

    /// Reachable nested timelines, breadth-first, deduped, excluding self and filtered by `include`.
    public List<Timeline> ReachableTimelines(Func<string, Timeline?> resolve, int maxDepth = int.MaxValue, Func<Timeline, bool>? include = null)
    {
        include ??= _ => true;
        var found = new List<Timeline>();
        var seen = new HashSet<string> { Id };
        var queue = new List<(Timeline T, int Depth)> { (this, 0) };
        var i = 0;
        while (i < queue.Count)
        {
            var (t, depth) = queue[i];
            i += 1;
            if (depth >= maxDepth)
            {
                continue;
            }
            foreach (var clip in t.Tracks.SelectMany(tr => tr.Clips).Where(c => c.SourceClipType == ClipType.Sequence))
            {
                if (!seen.Add(clip.MediaRef))
                {
                    continue;
                }
                var child = resolve(clip.MediaRef);
                if (child is null || !include(child))
                {
                    continue;
                }
                found.Add(child);
                queue.Add((child, depth + 1));
            }
        }
        return found;
    }
}

[JsonConverter(typeof(TrackJsonConverter))]
public sealed class Track
{
    public string Id { get; set; } = SwiftId.New();
    public ClipType Type { get; set; }
    public bool Muted { get; set; }
    public bool Hidden { get; set; }
    public bool SyncLocked { get; set; } = true;
    public List<Clip> Clips { get; set; } = [];
    public double DisplayHeight { get; set; } = 50;

    public Track(ClipType type)
    {
        Type = type;
    }

    public Track(ClipType type, List<Clip> clips)
    {
        Type = type;
        Clips = clips;
    }

    public int EndFrame
    {
        get
        {
            var maxFrame = 0;
            foreach (var clip in Clips)
            {
                maxFrame = Math.Max(maxFrame, clip.EndFrame);
            }
            return maxFrame;
        }
    }

    /// Returns ids of clips forming a contiguous chain starting at `fromEnd`, excluding `excludeId`.
    public HashSet<string> ContiguousClipIds(int fromEnd, string excludeId)
    {
        var ids = new HashSet<string>();
        var chainEnd = fromEnd;
        foreach (var c in Clips.OrderBy(c => c.StartFrame).Where(c => c.Id != excludeId && c.StartFrame >= fromEnd))
        {
            if (c.StartFrame != chainEnd)
            {
                break;
            }
            chainEnd = c.EndFrame;
            ids.Add(c.Id);
        }
        return ids;
    }
}

/// Core Clip fields + timeline-position/opacity/volume/retiming math ported from
/// Models/Timeline.swift. Keyframe-frame bookkeeping (upsert/remove/move-by-property) lives in
/// Keyframe.cs's `partial class Clip`, mirroring the Swift file split.
[JsonConverter(typeof(ClipJsonConverter))]
public sealed partial class Clip
{
    public const string DenoiseEffectType = "audio.denoise";
    public const double DefaultDenoiseAmount = 0.6;

    public string Id { get; set; } = SwiftId.New();
    public string MediaRef { get; set; }
    public ClipType MediaType { get; set; } = ClipType.Video;
    /// Original media type for derived clips; used for color-coding.
    public ClipType SourceClipType { get; set; } = ClipType.Video;
    public int StartFrame { get; set; }
    public int DurationFrames { get; set; }
    public int TrimStartFrame { get; set; }
    public int TrimEndFrame { get; set; }
    public double Speed { get; set; } = 1.0;
    public double Volume { get; set; } = 1.0;
    public int FadeInFrames { get; set; }
    public int FadeOutFrames { get; set; }
    public Interpolation FadeInInterpolation { get; set; } = Interpolation.Linear;
    public Interpolation FadeOutInterpolation { get; set; } = Interpolation.Linear;
    public double Opacity { get; set; } = 1.0;
    public Transform Transform { get; set; } = new();
    public Crop Crop { get; set; } = new();
    public string? LinkGroupId { get; set; }
    public string? CaptionGroupId { get; set; }
    public string? MulticamGroupId { get; set; }

    // Text clips only.
    public string? TextContent { get; set; }
    /// Out of scope for this cluster (TextStyle.swift/TextAnimation.swift belong to the text-model
    /// port) — captured as raw JSON so round-tripping a project never drops data.
    public JsonElement? TextStyle { get; set; }
    public JsonElement? TextAnimation { get; set; }
    /// Unlike TextStyle/TextAnimation, WordTiming is self-contained (no TextStyle dependency) and
    /// feeds `RescaleWordTimings`/`SetDuration` below, so it's fully typed rather than raw JSON.
    public List<WordTiming>? WordTimings { get; set; }

    // Keyframe tracks for each animatable property. Null when no animation exists.
    public KeyframeTrack<double>? OpacityTrack { get; set; }
    public KeyframeTrack<AnimPair>? PositionTrack { get; set; }
    public KeyframeTrack<AnimPair>? ScaleTrack { get; set; }
    public KeyframeTrack<double>? RotationTrack { get; set; }
    public KeyframeTrack<Crop>? CropTrack { get; set; }
    public KeyframeTrack<double>? VolumeTrack { get; set; }

    public List<Effect>? Effects { get; set; }

    /// How this clip composites over the tracks below it. Null = normal (source-over).
    public BlendMode? BlendMode { get; set; }

    public Clip(string mediaRef, int startFrame, int durationFrames)
    {
        MediaRef = mediaRef;
        StartFrame = startFrame;
        DurationFrames = durationFrames;
    }

    /// Frame where this clip ends on the timeline.
    public int EndFrame => StartFrame + DurationFrames;

    public bool SupportsRetiming => SourceClipType != ClipType.Sequence;

    /// Source frames consumed by the visible portion.
    public int SourceFramesConsumed => SwiftMath.RoundToInt(DurationFrames * Speed);

    /// Total source frames the clip references, including both trims.
    public int SourceDurationFrames => SourceFramesConsumed + TrimStartFrame + TrimEndFrame;

    public double OpacityAt(int frame)
    {
        var baseValue = RawOpacityAt(frame);
        if (MediaType == ClipType.Audio || (FadeInFrames <= 0 && FadeOutFrames <= 0))
        {
            return baseValue;
        }
        return baseValue * FadeMultiplier(frame);
    }

    /// Authored opacity without the fade envelope.
    public double RawOpacityAt(int frame) => OpacityTrack?.Sample(ToOffset(frame), Opacity, KeyframeInterpolation.Double) ?? Opacity;

    public double RotationAt(int frame) => RotationTrack?.Sample(ToOffset(frame), Transform.Rotation, KeyframeInterpolation.Double) ?? Transform.Rotation;

    /// Sampled top-left (normalized canvas space) at `frame`.
    public (double X, double Y) TopLeftAt(int frame)
    {
        if (PositionTrack is { IsActive: true } track)
        {
            var p = track.Sample(ToOffset(frame), new AnimPair(0, 0), KeyframeInterpolation.AnimPair);
            return (p.A, p.B);
        }
        var sz = SizeAt(frame);
        return (Transform.CenterX - sz.Width / 2, Transform.CenterY - sz.Height / 2);
    }

    /// Sampled (width, height) at `frame`.
    public (double Width, double Height) SizeAt(int frame)
    {
        var fallback = new AnimPair(Transform.Width, Transform.Height);
        var s = ScaleTrack?.Sample(ToOffset(frame), fallback, KeyframeInterpolation.AnimPair) ?? fallback;
        return (s.A, s.B);
    }

    /// Resolves the full Transform at `frame`.
    public Transform TransformAt(int frame)
    {
        var tl = TopLeftAt(frame);
        var sz = SizeAt(frame);
        var t = Transform.FromTopLeft(tl.X, tl.Y, sz.Width, sz.Height);
        t.Rotation = RotationAt(frame);
        return t;
    }

    public bool HasTransformAnimation =>
        (PositionTrack?.IsActive ?? false) || (ScaleTrack?.IsActive ?? false) || (RotationTrack?.IsActive ?? false);

    public Crop CropAt(int frame) => CropTrack?.Sample(ToOffset(frame), Crop, KeyframeInterpolation.Crop) ?? Crop;

    public double? LiveVolumeKfDb(int frame)
    {
        if (!Contains(frame) || VolumeTrack is not { IsActive: true } track)
        {
            return null;
        }
        return track.Sample(frame - StartFrame, 0, KeyframeInterpolation.Double);
    }

    /// Effective linear volume at `frame`: keyframe envelope first, fade ramp on top, static
    /// volume as outer gain.
    public double VolumeAt(int frame)
    {
        var kfGain = VolumeTrack is { IsActive: true } track
            ? VolumeScale.LinearFromDb(track.Sample(ToOffset(frame), 0, KeyframeInterpolation.Double))
            : 1.0;
        return Volume * kfGain * FadeMultiplier(frame);
    }

    public bool HasDenoiseEnabled => Effects?.Any(e => e.Type == DenoiseEffectType && e.Enabled) ?? false;

    public double DenoiseAmount =>
        Effects?.FirstOrDefault(e => e.Type == DenoiseEffectType)?.Params.GetValueOrDefault("amount")?.Value ?? DefaultDenoiseAmount;

    public double RawVolumeAt(int frame)
    {
        var kfGain = VolumeTrack is { IsActive: true } track
            ? VolumeScale.LinearFromDb(track.Sample(ToOffset(frame), 0, KeyframeInterpolation.Double))
            : 1.0;
        return Volume * kfGain;
    }

    /// 0…1 envelope from the fade head/tail ramps.
    public double FadeMultiplier(int frame)
    {
        var rel = frame - StartFrame;
        if (rel < 0 || rel > DurationFrames)
        {
            return 0;
        }

        double inMul;
        if (FadeInFrames <= 0)
        {
            inMul = 1.0;
        }
        else
        {
            var t = Math.Min(1.0, (double)rel / FadeInFrames);
            inMul = FadeInInterpolation == Interpolation.Smooth ? KeyframeInterpolation.SmoothStep(t) : t;
        }

        var outRem = DurationFrames - rel;
        double outMul;
        if (FadeOutFrames <= 0)
        {
            outMul = 1.0;
        }
        else
        {
            var t = Math.Min(1.0, (double)outRem / FadeOutFrames);
            outMul = FadeOutInterpolation == Interpolation.Smooth ? KeyframeInterpolation.SmoothStep(t) : t;
        }

        return Math.Min(inMul, outMul);
    }

    /// Source-seconds → project-timeline-frame through this clip's placement, trim, and speed.
    public int? TimelineFrame(double sourceSeconds, int fps)
    {
        var sourceFrame = sourceSeconds * fps;
        var offsetFromTrim = sourceFrame - TrimStartFrame;
        if (offsetFromTrim < 0)
        {
            return null;
        }
        var frame = SwiftMath.RoundToInt(StartFrame + offsetFromTrim / Math.Max(Speed, 0.0001));
        if (frame < StartFrame || frame >= EndFrame)
        {
            return null;
        }
        return frame;
    }

    /// Fresh clip id; link/caption group ids remapped consistently via `groups`.
    public void FreshenIds(Dictionary<string, string> groups)
    {
        string? Remap(string? old)
        {
            if (old is null)
            {
                return null;
            }
            if (groups.TryGetValue(old, out var existing))
            {
                return existing;
            }
            var fresh = SwiftId.New();
            groups[old] = fresh;
            return fresh;
        }
        Id = SwiftId.New();
        LinkGroupId = Remap(LinkGroupId);
        CaptionGroupId = Remap(CaptionGroupId);
    }

    /// Drops volume keyframes outside `DurationFrames`. Kept for callers that only touch volume.
    public void ClampVolumeKfsToDuration() => VolumeTrack = ClampedKeyframeTrack(VolumeTrack);

    /// Drops keyframes past `DurationFrames`. Call after any mutation that shrinks the clip.
    public void ClampKeyframesToDuration()
    {
        OpacityTrack = ClampedKeyframeTrack(OpacityTrack);
        PositionTrack = ClampedKeyframeTrack(PositionTrack);
        ScaleTrack = ClampedKeyframeTrack(ScaleTrack);
        RotationTrack = ClampedKeyframeTrack(RotationTrack);
        CropTrack = ClampedKeyframeTrack(CropTrack);
        VolumeTrack = ClampedKeyframeTrack(VolumeTrack);
    }

    public void RescaleKeyframes(double scale)
    {
        OpacityTrack = RescaledKeyframeTrack(OpacityTrack, scale);
        PositionTrack = RescaledKeyframeTrack(PositionTrack, scale);
        ScaleTrack = RescaledKeyframeTrack(ScaleTrack, scale);
        RotationTrack = RescaledKeyframeTrack(RotationTrack, scale);
        CropTrack = RescaledKeyframeTrack(CropTrack, scale);
        VolumeTrack = RescaledKeyframeTrack(VolumeTrack, scale);
    }

    private KeyframeTrack<TValue>? ClampedKeyframeTrack<TValue>(KeyframeTrack<TValue>? track)
    {
        if (track is null)
        {
            return null;
        }
        var normalized = new KeyframeTrack<TValue>();
        foreach (var kf in track.Keyframes.Where(k => k.Frame >= 0 && k.Frame <= DurationFrames))
        {
            normalized.Upsert(kf);
        }
        return normalized.Keyframes.Count == 0 ? null : normalized;
    }

    private static KeyframeTrack<TValue>? RescaledKeyframeTrack<TValue>(KeyframeTrack<TValue>? track, double scale)
    {
        if (track is null)
        {
            return null;
        }
        if (!double.IsFinite(scale) || scale <= 0)
        {
            return track;
        }
        var normalized = new KeyframeTrack<TValue>();
        foreach (var kf in track.Keyframes)
        {
            normalized.Upsert(new Keyframe<TValue>(SwiftMath.RoundToInt(kf.Frame * scale), kf.Value, kf.InterpolationOut));
        }
        return normalized.Keyframes.Count == 0 ? null : normalized;
    }

    /// Clamp fade ramps so head + tail can't exceed the clip's duration.
    public void ClampFadesToDuration()
    {
        FadeInFrames = Math.Max(0, Math.Min(FadeInFrames, DurationFrames));
        FadeOutFrames = Math.Max(0, Math.Min(FadeOutFrames, DurationFrames - FadeInFrames));
    }

    public void RescaleWordTimings(int oldDuration)
    {
        if (MediaType != ClipType.Text || WordTimings is not { } timings || oldDuration <= 0 || DurationFrames <= 0)
        {
            return;
        }
        var scale = (double)DurationFrames / oldDuration;
        WordTimings = timings.Select(timing =>
        {
            var start = Math.Min(Math.Max(0, SwiftMath.RoundToInt(timing.StartFrame * scale)), Math.Max(0, DurationFrames - 1));
            var end = Math.Min(Math.Max(start + 1, SwiftMath.RoundToInt(timing.EndFrame * scale)), DurationFrames);
            return new WordTiming(timing.Text, start, end);
        }).ToList();
    }

    /// Set the fade length for one edge and clamp to fit.
    public void SetFade(FadeEdge edge, int frames)
    {
        var v = Math.Max(0, frames);
        switch (edge)
        {
            case FadeEdge.Left: FadeInFrames = v; break;
            case FadeEdge.Right: FadeOutFrames = v; break;
        }
        ClampFadesToDuration();
    }

    public void SetFadeInterpolation(FadeEdge edge, Interpolation interpolation)
    {
        switch (edge)
        {
            case FadeEdge.Left: FadeInInterpolation = interpolation; break;
            case FadeEdge.Right: FadeOutInterpolation = interpolation; break;
        }
    }

    public int FadeFrames(FadeEdge edge) => edge == FadeEdge.Left ? FadeInFrames : FadeOutFrames;

    public Interpolation FadeInterpolation(FadeEdge edge) => edge == FadeEdge.Left ? FadeInInterpolation : FadeOutInterpolation;

    public void SetDuration(int newDuration)
    {
        var oldDuration = DurationFrames;
        DurationFrames = newDuration;
        RescaleWordTimings(oldDuration);
        ClampKeyframesToDuration();
        ClampFadesToDuration();
    }
}

public enum FadeEdge
{
    Left,
    Right,
}

/// From Models/TextAnimation.swift — only this trivial, TextStyle-independent piece is ported;
/// see the doc comment on `Clip.TextStyle`/`Clip.TextAnimation` for why the rest stays raw JSON.
/// Synthesized Codable, no custom init: all three fields are required on decode.
public sealed class WordTiming
{
    [JsonPropertyName("text")]
    [JsonRequired]
    public string Text { get; set; } = "";

    [JsonPropertyName("startFrame")]
    [JsonRequired]
    public int StartFrame { get; set; }

    [JsonPropertyName("endFrame")]
    [JsonRequired]
    public int EndFrame { get; set; }

    public WordTiming()
    {
    }

    public WordTiming(string text, int startFrame, int endFrame)
    {
        Text = text;
        StartFrame = startFrame;
        EndFrame = endFrame;
    }
}

[JsonConverter(typeof(TransformJsonConverter))]
public sealed class Transform
{
    public double CenterX { get; set; } = 0.5;
    public double CenterY { get; set; } = 0.5;
    public double Width { get; set; } = 1;
    public double Height { get; set; } = 1;
    /// Degrees, positive = clockwise.
    public double Rotation { get; set; }
    public bool FlipHorizontal { get; set; }
    public bool FlipVertical { get; set; }

    public (double X, double Y) TopLeft => (CenterX - Width / 2, CenterY - Height / 2);
    public (double X, double Y) Center => (CenterX, CenterY);

    public static Transform FromTopLeft(double x, double y, double w, double h) => new()
    {
        CenterX = x + w / 2,
        CenterY = y + h / 2,
        Width = w,
        Height = h,
    };

    public static Transform FromCenter(double x, double y, double w, double h) => new()
    {
        CenterX = x,
        CenterY = y,
        Width = w,
        Height = h,
    };

    /// Snap a value to canvas boundaries (0 or 1) within threshold.
    public static double SnapToBoundary(double value, double threshold)
    {
        if (Math.Abs(value) < threshold)
        {
            return 0;
        }
        if (Math.Abs(value - 1) < threshold)
        {
            return 1;
        }
        return value;
    }

    /// Snap clip edges to canvas boundaries (0 or 1).
    public void SnapToCanvasEdges(double threshold)
    {
        var tl = TopLeft;
        var snappedLeft = SnapToBoundary(tl.X, threshold);
        var snappedRight = SnapToBoundary(tl.X + Width, threshold);
        if (snappedLeft != tl.X)
        {
            CenterX -= tl.X - snappedLeft;
        }
        else if (snappedRight != tl.X + Width)
        {
            CenterX -= tl.X + Width - snappedRight;
        }

        var tl2 = TopLeft;
        var snappedTop = SnapToBoundary(tl2.Y, threshold);
        var snappedBottom = SnapToBoundary(tl2.Y + Height, threshold);
        if (snappedTop != tl2.Y)
        {
            CenterY -= tl2.Y - snappedTop;
        }
        else if (snappedBottom != tl2.Y + Height)
        {
            CenterY -= tl2.Y + Height - snappedBottom;
        }
    }

    /// Snap per-axis within threshold. Return value lets callers draw guide indicators.
    public (bool X, bool Y) SnapCenterToCanvasCenter(double thresholdH, double thresholdV)
    {
        bool snappedX = false, snappedY = false;
        if (Math.Abs(CenterX - 0.5) < thresholdH)
        {
            CenterX = 0.5;
            snappedX = true;
        }
        if (Math.Abs(CenterY - 0.5) < thresholdV)
        {
            CenterY = 0.5;
            snappedY = true;
        }
        return (snappedX, snappedY);
    }
}

/// Per-clip crop as edge insets in normalized (0-1) source coordinates. Synthesized Codable, no
/// custom init: all four fields are required on decode despite defaulting to 0.
public sealed class Crop
{
    [JsonPropertyName("left")]
    [JsonRequired]
    public double Left { get; set; }

    [JsonPropertyName("top")]
    [JsonRequired]
    public double Top { get; set; }

    [JsonPropertyName("right")]
    [JsonRequired]
    public double Right { get; set; }

    [JsonPropertyName("bottom")]
    [JsonRequired]
    public double Bottom { get; set; }

    [JsonIgnore]
    public bool IsIdentity => Left == 0 && Top == 0 && Right == 0 && Bottom == 0;

    [JsonIgnore]
    public double VisibleWidthFraction => Math.Max(0, 1 - Left - Right);

    [JsonIgnore]
    public double VisibleHeightFraction => Math.Max(0, 1 - Top - Bottom);
}

/// Aspect-ratio constraint for the Crop overlay. Not Codable in Swift.
public enum CropAspectLock
{
    Free,
    Original,
    R16x9,
    R9x16,
    R1x1,
    R4x3,
    R3x4,
    R21x9,
}

public static class CropAspectLockExtensions
{
    public static string Label(this CropAspectLock lockMode) => lockMode switch
    {
        CropAspectLock.Free => "Custom",
        CropAspectLock.Original => "Original",
        CropAspectLock.R16x9 => "16:9",
        CropAspectLock.R9x16 => "9:16",
        CropAspectLock.R1x1 => "1:1",
        CropAspectLock.R4x3 => "4:3",
        CropAspectLock.R3x4 => "3:4",
        CropAspectLock.R21x9 => "21:9",
        _ => throw new ArgumentOutOfRangeException(nameof(lockMode)),
    };

    public static double? PixelAspect(this CropAspectLock lockMode) => lockMode switch
    {
        CropAspectLock.Free or CropAspectLock.Original => null,
        CropAspectLock.R16x9 => 16.0 / 9.0,
        CropAspectLock.R9x16 => 9.0 / 16.0,
        CropAspectLock.R1x1 => 1.0,
        CropAspectLock.R4x3 => 4.0 / 3.0,
        CropAspectLock.R3x4 => 3.0 / 4.0,
        CropAspectLock.R21x9 => 21.0 / 9.0,
        _ => throw new ArgumentOutOfRangeException(nameof(lockMode)),
    };
}

// MARK: - JSON converters (Timeline/Track/Clip/Transform replicate Swift's `try? … ?? default`
// per-field leniency; see LenientJson for the shared Require/TryOr/TryOrNull helpers).

public sealed class TimelineJsonConverter : JsonConverter<Timeline>
{
    public override Timeline Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        using var doc = JsonDocument.ParseValue(ref reader);
        var root = doc.RootElement;
        return new Timeline
        {
            Id = LenientJson.TryOr(root, "id", options, SwiftId.New()),
            Name = LenientJson.TryOr(root, "name", options, "Timeline 1"),
            Fps = LenientJson.Require<int>(root, "fps", options),
            Width = LenientJson.Require<int>(root, "width", options),
            Height = LenientJson.Require<int>(root, "height", options),
            SettingsConfigured = LenientJson.TryOr(root, "settingsConfigured", options, false),
            FolderId = LenientJson.TryOrNull<string>(root, "folderId", options),
            Tracks = LenientJson.Require<List<Track>>(root, "tracks", options),
        };
    }

    public override void Write(Utf8JsonWriter writer, Timeline value, JsonSerializerOptions options)
    {
        writer.WriteStartObject();
        writer.WriteString("id", value.Id);
        writer.WriteString("name", value.Name);
        writer.WriteNumber("fps", value.Fps);
        writer.WriteNumber("width", value.Width);
        writer.WriteNumber("height", value.Height);
        writer.WriteBoolean("settingsConfigured", value.SettingsConfigured);
        if (value.FolderId is not null)
        {
            writer.WriteString("folderId", value.FolderId);
        }
        writer.WritePropertyName("tracks");
        JsonSerializer.Serialize(writer, value.Tracks, options);
        writer.WriteEndObject();
    }
}

public sealed class TrackJsonConverter : JsonConverter<Track>
{
    public override Track Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        using var doc = JsonDocument.ParseValue(ref reader);
        var root = doc.RootElement;

        var displayHeight = 50.0;
        if (LenientJson.TryOrNullValue<double>(root, "displayHeight", options) is { } h)
        {
            displayHeight = Math.Min(Math.Max(h, TrackSize.MinHeight), TrackSize.MaxHeight);
        }

        return new Track(LenientJson.Require<ClipType>(root, "type", options))
        {
            Id = LenientJson.TryOr(root, "id", options, SwiftId.New()),
            Muted = LenientJson.TryOr(root, "muted", options, false),
            Hidden = LenientJson.TryOr(root, "hidden", options, false),
            SyncLocked = LenientJson.TryOr(root, "syncLocked", options, true),
            Clips = LenientJson.TryOr(root, "clips", options, new List<Clip>()),
            DisplayHeight = displayHeight,
        };
    }

    public override void Write(Utf8JsonWriter writer, Track value, JsonSerializerOptions options)
    {
        writer.WriteStartObject();
        writer.WriteString("id", value.Id);
        writer.WritePropertyName("type");
        JsonSerializer.Serialize(writer, value.Type, options);
        writer.WriteBoolean("muted", value.Muted);
        writer.WriteBoolean("hidden", value.Hidden);
        writer.WriteBoolean("syncLocked", value.SyncLocked);
        writer.WritePropertyName("clips");
        JsonSerializer.Serialize(writer, value.Clips, options);
        writer.WriteNumber("displayHeight", value.DisplayHeight);
        writer.WriteEndObject();
    }
}

public sealed class ClipJsonConverter : JsonConverter<Clip>
{
    public override Clip Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        using var doc = JsonDocument.ParseValue(ref reader);
        var root = doc.RootElement;

        return new Clip(
            mediaRef: LenientJson.Require<string>(root, "mediaRef", options),
            startFrame: LenientJson.Require<int>(root, "startFrame", options),
            durationFrames: LenientJson.Require<int>(root, "durationFrames", options))
        {
            Id = LenientJson.TryOr(root, "id", options, SwiftId.New()),
            MediaType = LenientJson.TryOr(root, "mediaType", options, ClipType.Video),
            SourceClipType = LenientJson.TryOr(root, "sourceClipType", options, ClipType.Video),
            TrimStartFrame = LenientJson.TryOr(root, "trimStartFrame", options, 0),
            TrimEndFrame = LenientJson.TryOr(root, "trimEndFrame", options, 0),
            Speed = LenientJson.TryOr(root, "speed", options, 1.0),
            Volume = LenientJson.TryOr(root, "volume", options, 1.0),
            FadeInFrames = LenientJson.TryOr(root, "fadeInFrames", options, 0),
            FadeOutFrames = LenientJson.TryOr(root, "fadeOutFrames", options, 0),
            FadeInInterpolation = LenientJson.TryOr(root, "fadeInInterpolation", options, Interpolation.Linear),
            FadeOutInterpolation = LenientJson.TryOr(root, "fadeOutInterpolation", options, Interpolation.Linear),
            Opacity = LenientJson.TryOr(root, "opacity", options, 1.0),
            Transform = LenientJson.TryOr(root, "transform", options, new Transform()),
            Crop = LenientJson.TryOr(root, "crop", options, new Crop()),
            LinkGroupId = LenientJson.TryOrNull<string>(root, "linkGroupId", options),
            CaptionGroupId = LenientJson.TryOrNull<string>(root, "captionGroupId", options),
            MulticamGroupId = LenientJson.TryOrNull<string>(root, "multicamGroupId", options),
            TextContent = LenientJson.TryOrNull<string>(root, "textContent", options),
            TextStyle = TryGetRaw(root, "textStyle"),
            TextAnimation = TryGetRaw(root, "textAnimation"),
            WordTimings = LenientJson.TryOrNull<List<WordTiming>>(root, "wordTimings", options),
            OpacityTrack = LenientJson.TryOrNull<KeyframeTrack<double>>(root, "opacityTrack", options),
            PositionTrack = LenientJson.TryOrNull<KeyframeTrack<AnimPair>>(root, "positionTrack", options),
            ScaleTrack = LenientJson.TryOrNull<KeyframeTrack<AnimPair>>(root, "scaleTrack", options),
            RotationTrack = LenientJson.TryOrNull<KeyframeTrack<double>>(root, "rotationTrack", options),
            CropTrack = LenientJson.TryOrNull<KeyframeTrack<Crop>>(root, "cropTrack", options),
            VolumeTrack = LenientJson.TryOrNull<KeyframeTrack<double>>(root, "volumeTrack", options),
            Effects = LenientJson.TryOrNull<List<Effect>>(root, "effects", options),
            BlendMode = LenientJson.TryOrNullValue<BlendMode>(root, "blendMode", options),
        };
    }

    private static JsonElement? TryGetRaw(JsonElement root, string property)
    {
        if (!root.TryGetProperty(property, out var element) || element.ValueKind == JsonValueKind.Null)
        {
            return null;
        }
        return element.Clone();
    }

    public override void Write(Utf8JsonWriter writer, Clip value, JsonSerializerOptions options)
    {
        writer.WriteStartObject();
        writer.WriteString("id", value.Id);
        writer.WriteString("mediaRef", value.MediaRef);
        writer.WritePropertyName("mediaType");
        JsonSerializer.Serialize(writer, value.MediaType, options);
        writer.WritePropertyName("sourceClipType");
        JsonSerializer.Serialize(writer, value.SourceClipType, options);
        writer.WriteNumber("startFrame", value.StartFrame);
        writer.WriteNumber("durationFrames", value.DurationFrames);
        writer.WriteNumber("trimStartFrame", value.TrimStartFrame);
        writer.WriteNumber("trimEndFrame", value.TrimEndFrame);
        writer.WriteNumber("speed", value.Speed);
        writer.WriteNumber("volume", value.Volume);
        writer.WriteNumber("fadeInFrames", value.FadeInFrames);
        writer.WriteNumber("fadeOutFrames", value.FadeOutFrames);
        writer.WritePropertyName("fadeInInterpolation");
        JsonSerializer.Serialize(writer, value.FadeInInterpolation, options);
        writer.WritePropertyName("fadeOutInterpolation");
        JsonSerializer.Serialize(writer, value.FadeOutInterpolation, options);
        writer.WriteNumber("opacity", value.Opacity);
        writer.WritePropertyName("transform");
        JsonSerializer.Serialize(writer, value.Transform, options);
        writer.WritePropertyName("crop");
        JsonSerializer.Serialize(writer, value.Crop, options);
        WriteIfNotNull(writer, "linkGroupId", value.LinkGroupId);
        WriteIfNotNull(writer, "captionGroupId", value.CaptionGroupId);
        WriteIfNotNull(writer, "multicamGroupId", value.MulticamGroupId);
        WriteIfNotNull(writer, "textContent", value.TextContent);
        WriteRawIfPresent(writer, "textStyle", value.TextStyle);
        WriteRawIfPresent(writer, "textAnimation", value.TextAnimation);
        WriteObjectIfNotNull(writer, "wordTimings", value.WordTimings, options);
        WriteObjectIfNotNull(writer, "opacityTrack", value.OpacityTrack, options);
        WriteObjectIfNotNull(writer, "positionTrack", value.PositionTrack, options);
        WriteObjectIfNotNull(writer, "scaleTrack", value.ScaleTrack, options);
        WriteObjectIfNotNull(writer, "rotationTrack", value.RotationTrack, options);
        WriteObjectIfNotNull(writer, "cropTrack", value.CropTrack, options);
        WriteObjectIfNotNull(writer, "volumeTrack", value.VolumeTrack, options);
        WriteObjectIfNotNull(writer, "effects", value.Effects, options);
        if (value.BlendMode is { } blendMode)
        {
            writer.WritePropertyName("blendMode");
            JsonSerializer.Serialize(writer, blendMode, options);
        }
        writer.WriteEndObject();
    }

    private static void WriteIfNotNull(Utf8JsonWriter writer, string name, string? value)
    {
        if (value is not null)
        {
            writer.WriteString(name, value);
        }
    }

    private static void WriteRawIfPresent(Utf8JsonWriter writer, string name, JsonElement? value)
    {
        if (value is { } element)
        {
            writer.WritePropertyName(name);
            element.WriteTo(writer);
        }
    }

    private static void WriteObjectIfNotNull<TValue>(Utf8JsonWriter writer, string name, TValue? value, JsonSerializerOptions options)
        where TValue : class
    {
        if (value is not null)
        {
            writer.WritePropertyName(name);
            JsonSerializer.Serialize(writer, value, options);
        }
    }
}

public sealed class TransformJsonConverter : JsonConverter<Transform>
{
    public override Transform Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        using var doc = JsonDocument.ParseValue(ref reader);
        var root = doc.RootElement;

        var w = ReadDoubleIfPresent(root, "width") ?? 1;
        var h = ReadDoubleIfPresent(root, "height") ?? 1;

        double centerX;
        if (ReadDoubleIfPresent(root, "centerX") is { } cx)
        {
            centerX = cx;
        }
        else
        {
            centerX = ReadDoubleIfPresent(root, "x") is { } oldX ? oldX + w - 0.5 : 0.5;
        }

        double centerY;
        if (ReadDoubleIfPresent(root, "centerY") is { } cy)
        {
            centerY = cy;
        }
        else
        {
            centerY = ReadDoubleIfPresent(root, "y") is { } oldY ? oldY + h - 0.5 : 0.5;
        }

        return new Transform
        {
            CenterX = centerX,
            CenterY = centerY,
            Width = w,
            Height = h,
            Rotation = ReadDoubleIfPresent(root, "rotation") ?? 0,
            FlipHorizontal = ReadBoolIfPresent(root, "flipHorizontal") ?? false,
            FlipVertical = ReadBoolIfPresent(root, "flipVertical") ?? false,
        };
    }

    /// Mirrors Swift's `decodeIfPresent`: missing key or JSON null -> null; present with the
    /// wrong shape -> throws (not swallowed — the caller decides whether to swallow it).
    private static double? ReadDoubleIfPresent(JsonElement root, string property)
    {
        if (!root.TryGetProperty(property, out var element) || element.ValueKind == JsonValueKind.Null)
        {
            return null;
        }
        if (element.ValueKind != JsonValueKind.Number)
        {
            throw new JsonException($"'{property}' expected a number.");
        }
        return element.GetDouble();
    }

    private static bool? ReadBoolIfPresent(JsonElement root, string property)
    {
        if (!root.TryGetProperty(property, out var element) || element.ValueKind == JsonValueKind.Null)
        {
            return null;
        }
        if (element.ValueKind is not (JsonValueKind.True or JsonValueKind.False))
        {
            throw new JsonException($"'{property}' expected a bool.");
        }
        return element.GetBoolean();
    }

    public override void Write(Utf8JsonWriter writer, Transform value, JsonSerializerOptions options)
    {
        writer.WriteStartObject();
        writer.WriteNumber("centerX", value.CenterX);
        writer.WriteNumber("centerY", value.CenterY);
        writer.WriteNumber("width", value.Width);
        writer.WriteNumber("height", value.Height);
        writer.WriteNumber("rotation", value.Rotation);
        writer.WriteBoolean("flipHorizontal", value.FlipHorizontal);
        writer.WriteBoolean("flipVertical", value.FlipVertical);
        writer.WriteEndObject();
    }
}
