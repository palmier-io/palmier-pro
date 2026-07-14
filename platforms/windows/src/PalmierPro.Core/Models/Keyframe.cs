using System.Text.Json.Serialization;
using PalmierPro.Core.Json;

namespace PalmierPro.Core.Models;

[JsonConverter(typeof(SwiftStringEnumConverter<Interpolation>))]
public enum Interpolation
{
    [SwiftRawValue("linear")] Linear,
    [SwiftRawValue("hold")] Hold,
    [SwiftRawValue("smooth")] Smooth,
}

/// A single sample on a <see cref="KeyframeTrack{T}"/>. Swift's synthesized Codable has no
/// custom decoder here, so — unlike Effect/Clip/Track/Timeline — all three properties are
/// REQUIRED on decode despite `interpolationOut` having a default; the default only applies
/// to Swift-side construction, never to decoding. `[JsonRequired]` replicates that.
public sealed class Keyframe<T>
{
    [JsonPropertyName("frame")]
    [JsonRequired]
    public int Frame { get; set; }

    [JsonPropertyName("value")]
    [JsonRequired]
    public T Value { get; set; } = default!;

    [JsonPropertyName("interpolationOut")]
    [JsonRequired]
    public Interpolation InterpolationOut { get; set; } = Interpolation.Smooth;

    public Keyframe()
    {
    }

    public Keyframe(int frame, T value, Interpolation interpolationOut = Interpolation.Smooth)
    {
        Frame = frame;
        Value = value;
        InterpolationOut = interpolationOut;
    }
}

/// Same strictness note as <see cref="Keyframe{T}"/>: no custom decoder on the Swift side, so
/// `keyframes` is required, not defaulted to `[]`, when this type is decoded on its own.
public sealed class KeyframeTrack<T>
{
    [JsonPropertyName("keyframes")]
    [JsonRequired]
    public List<Keyframe<T>> Keyframes { get; set; } = [];

    public KeyframeTrack()
    {
    }

    public KeyframeTrack(IEnumerable<Keyframe<T>> keyframes)
    {
        Keyframes = keyframes.ToList();
    }

    [JsonIgnore]
    public bool IsActive => Keyframes.Count > 0;

    public void Upsert(Keyframe<T> keyframe)
    {
        var i = Keyframes.FindIndex(k => k.Frame == keyframe.Frame);
        if (i >= 0)
        {
            Keyframes[i] = keyframe;
            return;
        }
        var at = Keyframes.FindIndex(k => k.Frame > keyframe.Frame);
        Keyframes.Insert(at < 0 ? Keyframes.Count : at, keyframe);
    }

    public void Remove(int frame) => Keyframes.RemoveAll(k => k.Frame == frame);

    public void Move(int oldFrame, int newFrame)
    {
        var i = Keyframes.FindIndex(k => k.Frame == oldFrame);
        if (i < 0)
        {
            return;
        }
        if (newFrame != oldFrame && Keyframes.Any(k => k.Frame == newFrame))
        {
            return;
        }
        var kf = Keyframes[i];
        Keyframes.RemoveAt(i);
        kf.Frame = newFrame;
        Upsert(kf);
    }

    /// Samples the track at `frame`, easing between the bracketing keyframes per the left
    /// keyframe's `InterpolationOut`. `interpolate` stands in for Swift's `KeyframeInterpolatable`
    /// protocol, which C# can't retroactively attach to `double` — see <see cref="KeyframeInterpolation"/>.
    public T Sample(int frame, T fallback, Func<T, T, double, T> interpolate)
    {
        if (Keyframes.Count == 0)
        {
            return fallback;
        }
        if (Keyframes.Count == 1)
        {
            return Keyframes[0].Value;
        }
        if (frame <= Keyframes[0].Frame)
        {
            return Keyframes[0].Value;
        }
        var last = Keyframes[^1];
        if (frame >= last.Frame)
        {
            return last.Value;
        }

        var bIdx = Keyframes.FindIndex(k => k.Frame > frame);
        if (bIdx < 0)
        {
            return last.Value;
        }
        var a = Keyframes[bIdx - 1];
        var b = Keyframes[bIdx];
        var raw = (double)(frame - a.Frame) / (b.Frame - a.Frame);
        return a.InterpolationOut switch
        {
            Interpolation.Hold => a.Value,
            Interpolation.Linear => interpolate(a.Value, b.Value, raw),
            Interpolation.Smooth => interpolate(a.Value, b.Value, KeyframeInterpolation.SmoothStep(raw)),
            _ => throw new ArgumentOutOfRangeException(),
        };
    }

    /// Re-bases the track so `offset` becomes frame 0, inserting a boundary keyframe from
    /// `Sample(offset, ...)` when there isn't already one exactly at the cut point.
    public KeyframeTrack<T>? Rebased(int offset, T fallback, Func<T, T, double, T> interpolate)
    {
        if (!IsActive)
        {
            return null;
        }
        var boundary = Sample(offset, fallback, interpolate);
        var kfs = Keyframes
            .Where(k => k.Frame >= offset)
            .Select(k => new Keyframe<T>(k.Frame - offset, k.Value, k.InterpolationOut))
            .ToList();
        if (kfs.Count == 0 || kfs[0].Frame != 0)
        {
            var interp = Keyframes.LastOrDefault(k => k.Frame < offset)?.InterpolationOut ?? Interpolation.Smooth;
            kfs.Insert(0, new Keyframe<T>(0, boundary, interp));
        }
        return kfs.Count == 0 ? null : new KeyframeTrack<T>(kfs);
    }
}

/// Stands in for Swift's `KeyframeInterpolatable` protocol — C# can't retroactively make
/// `double` implement a new interface, so callers pass one of these as `Sample`'s delegate.
public static class KeyframeInterpolation
{
    public static double SmoothStep(double t) => t * t * (3 - 2 * t);

    public static readonly Func<double, double, double, double> Double = (a, b, t) => a + (b - a) * t;

    public static readonly Func<AnimPair, AnimPair, double, AnimPair> AnimPair = (a, b, t) =>
        new AnimPair(Double(a.A, b.A, t), Double(a.B, b.B, t));

    public static readonly Func<Crop, Crop, double, Crop> Crop = (a, b, t) =>
        new Crop
        {
            Left = Double(a.Left, b.Left, t),
            Top = Double(a.Top, b.Top, t),
            Right = Double(a.Right, b.Right, t),
            Bottom = Double(a.Bottom, b.Bottom, t),
        };
}

/// Two-component keyframe value used for position (x, y) and scale (width, height).
/// Swift's synthesized Codable requires both fields present on decode (no default, no custom init).
public sealed class AnimPair
{
    [JsonPropertyName("a")]
    [JsonRequired]
    public double A { get; set; }

    [JsonPropertyName("b")]
    [JsonRequired]
    public double B { get; set; }

    public AnimPair()
    {
    }

    public AnimPair(double a, double b)
    {
        A = a;
        B = b;
    }
}

/// Identifies which clip property an inspector lane / stamp button drives.
public enum AnimatableProperty
{
    Opacity,
    Position,
    Scale,
    Rotation,
    Crop,
    Volume,
}

public static class AnimatablePropertyExtensions
{
    public static string DisplayName(this AnimatableProperty property) => property switch
    {
        AnimatableProperty.Opacity => "Opacity",
        AnimatableProperty.Position => "Position",
        AnimatableProperty.Scale => "Scale",
        AnimatableProperty.Rotation => "Rotation",
        AnimatableProperty.Crop => "Crop",
        AnimatableProperty.Volume => "Volume",
        _ => throw new ArgumentOutOfRangeException(nameof(property)),
    };
}

/// Clip keyframe helpers ported from Keyframe.swift's `extension Clip`. Split into this file
/// (rather than Timeline.cs, where the rest of Clip lives) to mirror the Swift file split.
public partial class Clip
{
    private int ToOffset(int timelineFrame) => timelineFrame - StartFrame;
    private int ToAbs(int offset) => StartFrame + offset;

    public bool Contains(int timelineFrame) => timelineFrame >= StartFrame && timelineFrame < EndFrame;

    public List<int> KeyframeFrames(AnimatableProperty property)
    {
        IEnumerable<int> offsets = property switch
        {
            AnimatableProperty.Opacity => OpacityTrack?.Keyframes.Select(k => k.Frame) ?? [],
            AnimatableProperty.Position => PositionTrack?.Keyframes.Select(k => k.Frame) ?? [],
            AnimatableProperty.Scale => ScaleTrack?.Keyframes.Select(k => k.Frame) ?? [],
            AnimatableProperty.Rotation => RotationTrack?.Keyframes.Select(k => k.Frame) ?? [],
            AnimatableProperty.Crop => CropTrack?.Keyframes.Select(k => k.Frame) ?? [],
            AnimatableProperty.Volume => VolumeTrack?.Keyframes.Select(k => k.Frame) ?? [],
            _ => throw new ArgumentOutOfRangeException(nameof(property)),
        };
        return offsets.Select(ToAbs).ToList();
    }

    public Interpolation? InterpolationAt(AnimatableProperty property, int frame)
    {
        var o = ToOffset(frame);
        return property switch
        {
            AnimatableProperty.Opacity => OpacityTrack?.Keyframes.FirstOrDefault(k => k.Frame == o)?.InterpolationOut,
            AnimatableProperty.Position => PositionTrack?.Keyframes.FirstOrDefault(k => k.Frame == o)?.InterpolationOut,
            AnimatableProperty.Scale => ScaleTrack?.Keyframes.FirstOrDefault(k => k.Frame == o)?.InterpolationOut,
            AnimatableProperty.Rotation => RotationTrack?.Keyframes.FirstOrDefault(k => k.Frame == o)?.InterpolationOut,
            AnimatableProperty.Crop => CropTrack?.Keyframes.FirstOrDefault(k => k.Frame == o)?.InterpolationOut,
            AnimatableProperty.Volume => VolumeTrack?.Keyframes.FirstOrDefault(k => k.Frame == o)?.InterpolationOut,
            _ => throw new ArgumentOutOfRangeException(nameof(property)),
        };
    }

    /// Union of every animatable property's keyframe frames as absolute timeline frames.
    public List<int> AllKeyframeFrames()
    {
        var s = new SortedSet<int>();
        void AddAll<T>(KeyframeTrack<T>? track)
        {
            if (track is null)
            {
                return;
            }
            foreach (var kf in track.Keyframes)
            {
                s.Add(kf.Frame + StartFrame);
            }
        }
        AddAll(OpacityTrack);
        AddAll(PositionTrack);
        AddAll(ScaleTrack);
        AddAll(RotationTrack);
        AddAll(CropTrack);
        AddAll(VolumeTrack);
        return [.. s];
    }

    public void UpsertOpacityKeyframe(int frame, double value)
    {
        var track = OpacityTrack ?? new KeyframeTrack<double>();
        track.Upsert(new Keyframe<double>(ToOffset(frame), value));
        OpacityTrack = track;
    }

    public void UpsertPositionKeyframe(int frame, AnimPair value)
    {
        var track = PositionTrack ?? new KeyframeTrack<AnimPair>();
        track.Upsert(new Keyframe<AnimPair>(ToOffset(frame), value));
        PositionTrack = track;
    }

    public void UpsertScaleKeyframe(int frame, AnimPair value)
    {
        var track = ScaleTrack ?? new KeyframeTrack<AnimPair>();
        track.Upsert(new Keyframe<AnimPair>(ToOffset(frame), value));
        ScaleTrack = track;
    }

    public void UpsertRotationKeyframe(int frame, double value)
    {
        var track = RotationTrack ?? new KeyframeTrack<double>();
        track.Upsert(new Keyframe<double>(ToOffset(frame), value));
        RotationTrack = track;
    }

    public void UpsertCropKeyframe(int frame, Crop value)
    {
        var track = CropTrack ?? new KeyframeTrack<Crop>();
        track.Upsert(new Keyframe<Crop>(ToOffset(frame), value));
        CropTrack = track;
    }

    public void UpsertVolumeKeyframe(int frame, double value)
    {
        var track = VolumeTrack ?? new KeyframeTrack<double>();
        track.Upsert(new Keyframe<double>(ToOffset(frame), value));
        VolumeTrack = track;
    }

    public void RemoveKeyframe(AnimatableProperty property, int frame)
    {
        var o = ToOffset(frame);
        switch (property)
        {
            case AnimatableProperty.Opacity:
                OpacityTrack?.Remove(o);
                if (OpacityTrack?.Keyframes.Count == 0) OpacityTrack = null;
                break;
            case AnimatableProperty.Position:
                PositionTrack?.Remove(o);
                if (PositionTrack?.Keyframes.Count == 0) PositionTrack = null;
                break;
            case AnimatableProperty.Scale:
                ScaleTrack?.Remove(o);
                if (ScaleTrack?.Keyframes.Count == 0) ScaleTrack = null;
                break;
            case AnimatableProperty.Rotation:
                RotationTrack?.Remove(o);
                if (RotationTrack?.Keyframes.Count == 0) RotationTrack = null;
                break;
            case AnimatableProperty.Crop:
                CropTrack?.Remove(o);
                if (CropTrack?.Keyframes.Count == 0) CropTrack = null;
                break;
            case AnimatableProperty.Volume:
                VolumeTrack?.Remove(o);
                if (VolumeTrack?.Keyframes.Count == 0) VolumeTrack = null;
                break;
            default:
                throw new ArgumentOutOfRangeException(nameof(property));
        }
    }

    public void ClearKeyframes(AnimatableProperty property)
    {
        switch (property)
        {
            case AnimatableProperty.Opacity: OpacityTrack = null; break;
            case AnimatableProperty.Position: PositionTrack = null; break;
            case AnimatableProperty.Scale: ScaleTrack = null; break;
            case AnimatableProperty.Rotation: RotationTrack = null; break;
            case AnimatableProperty.Crop: CropTrack = null; break;
            case AnimatableProperty.Volume: VolumeTrack = null; break;
            default: throw new ArgumentOutOfRangeException(nameof(property));
        }
    }

    public void SetInterpolation(AnimatableProperty property, int frame, Interpolation interpolation)
    {
        var o = ToOffset(frame);
        void Apply<T>(KeyframeTrack<T>? track)
        {
            var i = track?.Keyframes.FindIndex(k => k.Frame == o) ?? -1;
            if (i >= 0)
            {
                track!.Keyframes[i].InterpolationOut = interpolation;
            }
        }
        switch (property)
        {
            case AnimatableProperty.Opacity: Apply(OpacityTrack); break;
            case AnimatableProperty.Position: Apply(PositionTrack); break;
            case AnimatableProperty.Scale: Apply(ScaleTrack); break;
            case AnimatableProperty.Rotation: Apply(RotationTrack); break;
            case AnimatableProperty.Crop: Apply(CropTrack); break;
            case AnimatableProperty.Volume: Apply(VolumeTrack); break;
            default: throw new ArgumentOutOfRangeException(nameof(property));
        }
    }

    public void MoveKeyframe(AnimatableProperty property, int from, int to)
    {
        var fromO = ToOffset(from);
        var toO = ToOffset(to);
        switch (property)
        {
            case AnimatableProperty.Opacity: OpacityTrack?.Move(fromO, toO); break;
            case AnimatableProperty.Position: PositionTrack?.Move(fromO, toO); break;
            case AnimatableProperty.Scale: ScaleTrack?.Move(fromO, toO); break;
            case AnimatableProperty.Rotation: RotationTrack?.Move(fromO, toO); break;
            case AnimatableProperty.Crop: CropTrack?.Move(fromO, toO); break;
            case AnimatableProperty.Volume: VolumeTrack?.Move(fromO, toO); break;
            default: throw new ArgumentOutOfRangeException(nameof(property));
        }
    }
}
