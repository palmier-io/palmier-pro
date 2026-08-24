using System.Text.Json.Serialization;
using PalmierPro.Core.Serialization;

namespace PalmierPro.Core.Models;

public enum FadeEdge
{
    Left,
    Right,
}

public sealed class Clip : IJsonOnDeserialized
{
    public string Id { get; set; } = Uuid.NewString();
    public required string MediaRef { get; set; }
    public ClipType MediaType { get; set; } = ClipType.Video;
    /// <summary>Original media type for derived clips; used for color-coding.</summary>
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
    public double EdgeRounding { get; set; }
    public double EdgeSoftness { get; set; }
    public string? LinkGroupId { get; set; }
    public string? CaptionGroupId { get; set; }
    public string? MulticamGroupId { get; set; }

    // Text clips only.
    public string? TextContent { get; set; }
    public TextStyle? TextStyle { get; set; }
    public TextAnimation? TextAnimation { get; set; }
    public List<WordTiming>? WordTimings { get; set; }
    public TextFillMode? TextFillMode { get; set; }

    // Keyframe tracks for each animatable property. Null when no animation exists.
    public KeyframeTrack<double>? OpacityTrack { get; set; }
    public KeyframeTrack<AnimPair>? PositionTrack { get; set; }
    public KeyframeTrack<AnimPair>? ScaleTrack { get; set; }
    public KeyframeTrack<double>? RotationTrack { get; set; }
    public KeyframeTrack<Crop>? CropTrack { get; set; }
    public KeyframeTrack<double>? VolumeTrack { get; set; }

    public List<Effect>? Effects { get; set; }

    /// <summary>How this clip composites over the tracks below it. Null = normal (source-over).</summary>
    public BlendMode? BlendMode { get; set; }

    public const string DenoiseEffectType = "audio.denoise";
    public const double DefaultDenoiseAmount = 0.6;

    void IJsonOnDeserialized.OnDeserialized()
    {
        // Mirrors the Swift decoder: out-of-range normalized values reset to 0.
        if (EdgeRounding is < 0 or > 1 || !double.IsFinite(EdgeRounding)) EdgeRounding = 0;
        if (EdgeSoftness is < 0 or > 1 || !double.IsFinite(EdgeSoftness)) EdgeSoftness = 0;
    }

    /// <summary>Frame where this clip ends on the timeline.</summary>
    [JsonIgnore] public int EndFrame => StartFrame + DurationFrames;

    [JsonIgnore] public bool SupportsRetiming => SourceClipType != ClipType.Sequence;

    /// <summary>Source frames consumed by the visible portion.</summary>
    [JsonIgnore] public int SourceFramesConsumed => (int)Math.Round(DurationFrames * Speed, MidpointRounding.AwayFromZero);

    /// <summary>Total source frames the clip references, including both trims.</summary>
    [JsonIgnore] public int SourceDurationFrames => SourceFramesConsumed + TrimStartFrame + TrimEndFrame;

    [JsonIgnore]
    public bool HasKeyframes =>
        OpacityTrack is not null || PositionTrack is not null || ScaleTrack is not null
        || RotationTrack is not null || CropTrack is not null || VolumeTrack is not null;

    [JsonIgnore]
    public bool HasTransformAnimation =>
        (PositionTrack?.IsActive ?? false)
        || (ScaleTrack?.IsActive ?? false)
        || (RotationTrack?.IsActive ?? false);

    [JsonIgnore]
    public bool HasDenoiseEnabled =>
        Effects?.Any(e => e.Type == DenoiseEffectType && e.Enabled) ?? false;

    [JsonIgnore]
    public double DenoiseAmount =>
        Effects?.FirstOrDefault(e => e.Type == DenoiseEffectType)?.Params.GetValueOrDefault("amount")?.Value
        ?? DefaultDenoiseAmount;

    public bool Contains(int timelineFrame) => timelineFrame >= StartFrame && timelineFrame < EndFrame;

    /// <summary>Convert an absolute timeline frame to the clip-relative offset used by track storage.</summary>
    private int KeyframeOffset(int frame) => frame - StartFrame;

    public double OpacityAt(int frame)
    {
        var baseOpacity = RawOpacityAt(frame);
        if (MediaType == ClipType.Audio || (FadeInFrames <= 0 && FadeOutFrames <= 0)) return baseOpacity;
        return baseOpacity * FadeMultiplier(frame);
    }

    /// <summary>Authored opacity without the fade envelope.</summary>
    public double RawOpacityAt(int frame)
        => OpacityTrack?.Sample(KeyframeOffset(frame), Opacity) ?? Opacity;

    public double RotationAt(int frame)
        => RotationTrack?.Sample(KeyframeOffset(frame), Transform.Rotation) ?? Transform.Rotation;

    /// <summary>Sampled topLeft (normalized canvas space) at frame.</summary>
    public (double X, double Y) TopLeftAt(int frame)
    {
        if (PositionTrack is { IsActive: true } track)
        {
            var p = track.Sample(KeyframeOffset(frame), new AnimPair(0, 0));
            return (p.A, p.B);
        }
        var c = Transform.Center;
        var sz = SizeAt(frame);
        return (c.X - sz.Width / 2, c.Y - sz.Height / 2);
    }

    /// <summary>Sampled (width, height) at frame.</summary>
    public (double Width, double Height) SizeAt(int frame)
    {
        var fallback = new AnimPair(Transform.Width, Transform.Height);
        var s = ScaleTrack?.Sample(KeyframeOffset(frame), fallback) ?? fallback;
        return (s.A, s.B);
    }

    /// <summary>Resolve the full Transform at frame.</summary>
    public Transform TransformAt(int frame)
    {
        var tl = TopLeftAt(frame);
        var sz = SizeAt(frame);
        var t = Transform;
        t.CenterX = tl.X + sz.Width / 2;
        t.CenterY = tl.Y + sz.Height / 2;
        t.Width = sz.Width;
        t.Height = sz.Height;
        t.Rotation = RotationAt(frame);
        return t;
    }

    public Crop CropAt(int frame)
        => CropTrack?.Sample(KeyframeOffset(frame), Crop) ?? Crop;

    public double? LiveVolumeKfDb(int frame)
    {
        if (!Contains(frame) || VolumeTrack is not { IsActive: true } track) return null;
        return track.Sample(frame - StartFrame, 0);
    }

    /// <summary>Effective linear volume at frame: keyframe envelope first, fade ramp on top, static volume as outer gain.</summary>
    public double VolumeAt(int frame)
    {
        double kfGain;
        if (VolumeTrack is { IsActive: true } track)
        {
            var dB = track.Sample(KeyframeOffset(frame), 0);
            kfGain = VolumeScale.LinearFromDb(dB);
        }
        else
        {
            kfGain = 1.0;
        }
        return Volume * kfGain * FadeMultiplier(frame);
    }

    public double RawVolumeAt(int frame)
    {
        double kfGain;
        if (VolumeTrack is { IsActive: true } track)
        {
            kfGain = VolumeScale.LinearFromDb(track.Sample(KeyframeOffset(frame), 0));
        }
        else
        {
            kfGain = 1.0;
        }
        return Volume * kfGain;
    }

    /// <summary>0…1 envelope from the fade head/tail ramps.</summary>
    public double FadeMultiplier(int frame)
    {
        var rel = frame - StartFrame;
        if (rel < 0 || rel > DurationFrames) return 0;

        double inMul = 1.0;
        if (FadeInFrames > 0)
        {
            var t = Math.Min(1.0, (double)rel / FadeInFrames);
            inMul = FadeInInterpolation == Interpolation.Smooth ? Easing.Smoothstep(t) : t;
        }

        var outRem = DurationFrames - rel;
        double outMul = 1.0;
        if (FadeOutFrames > 0)
        {
            var t = Math.Min(1.0, (double)outRem / FadeOutFrames);
            outMul = FadeOutInterpolation == Interpolation.Smooth ? Easing.Smoothstep(t) : t;
        }

        return Math.Min(inMul, outMul);
    }

    /// <summary>Source-seconds → project-timeline-frame through this clip's placement, trim, and speed.</summary>
    public int? TimelineFrame(double sourceSeconds, int fps)
    {
        var sourceFrame = sourceSeconds * fps;
        var offsetFromTrim = sourceFrame - TrimStartFrame;
        if (offsetFromTrim < 0) return null;
        var frame = (int)Math.Round(StartFrame + offsetFromTrim / Math.Max(Speed, 0.0001), MidpointRounding.AwayFromZero);
        if (frame < StartFrame || frame >= EndFrame) return null;
        return frame;
    }

    // MARK: - Mutations

    /// <summary>Fresh clip id; link/caption group ids remapped consistently via <paramref name="groups"/>.</summary>
    public void FreshenIds(Dictionary<string, string> groups)
    {
        string? Remap(string? old)
        {
            if (old is null) return null;
            if (groups.TryGetValue(old, out var mapped)) return mapped;
            var fresh = Uuid.NewString();
            groups[old] = fresh;
            return fresh;
        }
        Id = Uuid.NewString();
        LinkGroupId = Remap(LinkGroupId);
        CaptionGroupId = Remap(CaptionGroupId);
    }

    /// <summary>Drops keyframes past DurationFrames. Call after any mutation that shrinks the clip.</summary>
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
        where TValue : IEquatable<TValue>
    {
        if (track is null) return null;
        var normalized = new KeyframeTrack<TValue>();
        foreach (var kf in track.Keyframes.Where(k => k.Frame >= 0 && k.Frame <= DurationFrames))
        {
            normalized.Upsert(kf);
        }
        track.Keyframes = normalized.Keyframes;
        return track.Keyframes.Count == 0 ? null : track;
    }

    private static KeyframeTrack<TValue>? RescaledKeyframeTrack<TValue>(KeyframeTrack<TValue>? track, double scale)
        where TValue : IEquatable<TValue>
    {
        if (track is null) return null;
        if (!double.IsFinite(scale) || scale <= 0) return track;
        var normalized = new KeyframeTrack<TValue>();
        foreach (var kf in track.Keyframes)
        {
            normalized.Upsert(new Keyframe<TValue>
            {
                Frame = (int)Math.Round(kf.Frame * scale, MidpointRounding.AwayFromZero),
                Value = kf.Value,
                InterpolationOut = kf.InterpolationOut,
            });
        }
        return normalized.Keyframes.Count == 0 ? null : normalized;
    }

    /// <summary>Clamp fade ramps so head + tail can't exceed the clip's duration.</summary>
    public void ClampFadesToDuration()
    {
        FadeInFrames = Math.Max(0, Math.Min(FadeInFrames, DurationFrames));
        FadeOutFrames = Math.Max(0, Math.Min(FadeOutFrames, DurationFrames - FadeInFrames));
    }

    public void RescaleWordTimings(int oldDuration)
    {
        if (MediaType != ClipType.Text || WordTimings is not { } timings || oldDuration <= 0 || DurationFrames <= 0) return;
        var scale = (double)DurationFrames / oldDuration;
        WordTimings = timings.Select(timing =>
        {
            var start = Math.Min(
                Math.Max(0, (int)Math.Round(timing.StartFrame * scale, MidpointRounding.AwayFromZero)),
                Math.Max(0, DurationFrames - 1));
            var end = Math.Min(
                Math.Max(start + 1, (int)Math.Round(timing.EndFrame * scale, MidpointRounding.AwayFromZero)),
                DurationFrames);
            return new WordTiming(timing.Text, start, end);
        }).ToList();
    }

    /// <summary>Set the fade length for one edge and clamp to fit.</summary>
    public void SetFade(FadeEdge edge, int frames)
    {
        var v = Math.Max(0, frames);
        if (edge == FadeEdge.Left) FadeInFrames = v;
        else FadeOutFrames = v;
        ClampFadesToDuration();
    }

    public void SetFadeInterpolation(FadeEdge edge, Interpolation interpolation)
    {
        if (edge == FadeEdge.Left) FadeInInterpolation = interpolation;
        else FadeOutInterpolation = interpolation;
    }

    public int FadeFrames(FadeEdge edge) => edge == FadeEdge.Left ? FadeInFrames : FadeOutFrames;

    public Interpolation FadeInterpolation(FadeEdge edge)
        => edge == FadeEdge.Left ? FadeInInterpolation : FadeOutInterpolation;

    public void SetDuration(int newDuration)
    {
        var oldDuration = DurationFrames;
        DurationFrames = newDuration;
        RescaleWordTimings(oldDuration);
        ClampKeyframesToDuration();
        ClampFadesToDuration();
    }

    // MARK: - Keyframe helpers

    /// <summary>Absolute timeline frames that carry a keyframe for the property.</summary>
    public IReadOnlyList<int> KeyframeFrames(AnimatableProperty property)
    {
        IEnumerable<int> offsets = property switch
        {
            AnimatableProperty.Opacity => OpacityTrack?.Keyframes.Select(k => k.Frame) ?? [],
            AnimatableProperty.Position => PositionTrack?.Keyframes.Select(k => k.Frame) ?? [],
            AnimatableProperty.Scale => ScaleTrack?.Keyframes.Select(k => k.Frame) ?? [],
            AnimatableProperty.Rotation => RotationTrack?.Keyframes.Select(k => k.Frame) ?? [],
            AnimatableProperty.Crop => CropTrack?.Keyframes.Select(k => k.Frame) ?? [],
            AnimatableProperty.Volume => VolumeTrack?.Keyframes.Select(k => k.Frame) ?? [],
            _ => [],
        };
        return offsets.Select(o => StartFrame + o).ToList();
    }

    public Interpolation? InterpolationFor(AnimatableProperty property, int atFrame)
    {
        var o = KeyframeOffset(atFrame);
        return property switch
        {
            AnimatableProperty.Opacity => OpacityTrack?.Keyframes.FirstOrDefault(k => k.Frame == o)?.InterpolationOut,
            AnimatableProperty.Position => PositionTrack?.Keyframes.FirstOrDefault(k => k.Frame == o)?.InterpolationOut,
            AnimatableProperty.Scale => ScaleTrack?.Keyframes.FirstOrDefault(k => k.Frame == o)?.InterpolationOut,
            AnimatableProperty.Rotation => RotationTrack?.Keyframes.FirstOrDefault(k => k.Frame == o)?.InterpolationOut,
            AnimatableProperty.Crop => CropTrack?.Keyframes.FirstOrDefault(k => k.Frame == o)?.InterpolationOut,
            AnimatableProperty.Volume => VolumeTrack?.Keyframes.FirstOrDefault(k => k.Frame == o)?.InterpolationOut,
            _ => null,
        };
    }

    public void UpsertKeyframe(AnimatableProperty property, int frame, double value)
    {
        var kf = new Keyframe<double> { Frame = KeyframeOffset(frame), Value = value };
        switch (property)
        {
            case AnimatableProperty.Opacity:
                (OpacityTrack ??= new()).Upsert(kf);
                break;
            case AnimatableProperty.Rotation:
                (RotationTrack ??= new()).Upsert(kf);
                break;
            case AnimatableProperty.Volume:
                (VolumeTrack ??= new()).Upsert(kf);
                break;
            default:
                throw new ArgumentException($"{property} does not take a scalar keyframe value");
        }
    }

    public void UpsertKeyframe(AnimatableProperty property, int frame, AnimPair value)
    {
        var kf = new Keyframe<AnimPair> { Frame = KeyframeOffset(frame), Value = value };
        switch (property)
        {
            case AnimatableProperty.Position:
                (PositionTrack ??= new()).Upsert(kf);
                break;
            case AnimatableProperty.Scale:
                (ScaleTrack ??= new()).Upsert(kf);
                break;
            default:
                throw new ArgumentException($"{property} does not take a pair keyframe value");
        }
    }

    public void UpsertCropKeyframe(int frame, Crop value)
        => (CropTrack ??= new()).Upsert(new Keyframe<Crop> { Frame = KeyframeOffset(frame), Value = value });

    public void RemoveKeyframe(AnimatableProperty property, int frame)
    {
        var o = KeyframeOffset(frame);
        switch (property)
        {
            case AnimatableProperty.Opacity:
                OpacityTrack?.Remove(o);
                if (OpacityTrack is { IsActive: false }) OpacityTrack = null;
                break;
            case AnimatableProperty.Position:
                PositionTrack?.Remove(o);
                if (PositionTrack is { IsActive: false }) PositionTrack = null;
                break;
            case AnimatableProperty.Scale:
                ScaleTrack?.Remove(o);
                if (ScaleTrack is { IsActive: false }) ScaleTrack = null;
                break;
            case AnimatableProperty.Rotation:
                RotationTrack?.Remove(o);
                if (RotationTrack is { IsActive: false }) RotationTrack = null;
                break;
            case AnimatableProperty.Crop:
                CropTrack?.Remove(o);
                if (CropTrack is { IsActive: false }) CropTrack = null;
                break;
            case AnimatableProperty.Volume:
                VolumeTrack?.Remove(o);
                if (VolumeTrack is { IsActive: false }) VolumeTrack = null;
                break;
        }
    }

    public void SetInterpolation(AnimatableProperty property, int atFrame, Interpolation interpolation)
    {
        var o = KeyframeOffset(atFrame);
        var kf = property switch
        {
            AnimatableProperty.Opacity => OpacityTrack?.Keyframes.FirstOrDefault(k => k.Frame == o) as object,
            AnimatableProperty.Position => PositionTrack?.Keyframes.FirstOrDefault(k => k.Frame == o),
            AnimatableProperty.Scale => ScaleTrack?.Keyframes.FirstOrDefault(k => k.Frame == o),
            AnimatableProperty.Rotation => RotationTrack?.Keyframes.FirstOrDefault(k => k.Frame == o),
            AnimatableProperty.Crop => CropTrack?.Keyframes.FirstOrDefault(k => k.Frame == o),
            AnimatableProperty.Volume => VolumeTrack?.Keyframes.FirstOrDefault(k => k.Frame == o),
            _ => null,
        };
        switch (kf)
        {
            case Keyframe<double> d: d.InterpolationOut = interpolation; break;
            case Keyframe<AnimPair> p: p.InterpolationOut = interpolation; break;
            case Keyframe<Crop> c: c.InterpolationOut = interpolation; break;
        }
    }

    public void MoveKeyframe(AnimatableProperty property, int from, int to)
    {
        var fromO = KeyframeOffset(from);
        var toO = KeyframeOffset(to);
        switch (property)
        {
            case AnimatableProperty.Opacity: OpacityTrack?.Move(fromO, toO); break;
            case AnimatableProperty.Position: PositionTrack?.Move(fromO, toO); break;
            case AnimatableProperty.Scale: ScaleTrack?.Move(fromO, toO); break;
            case AnimatableProperty.Rotation: RotationTrack?.Move(fromO, toO); break;
            case AnimatableProperty.Crop: CropTrack?.Move(fromO, toO); break;
            case AnimatableProperty.Volume: VolumeTrack?.Move(fromO, toO); break;
        }
    }
}
