namespace PalmierPro.Core.Models;

public enum Interpolation
{
    Linear,
    Hold,
    Smooth,
}

public static class Easing
{
    public static double Smoothstep(double t) => t * t * (3 - 2 * t);
}

public sealed class Keyframe<TValue> : IEquatable<Keyframe<TValue>> where TValue : IEquatable<TValue>
{
    public int Frame { get; set; }
    public required TValue Value { get; set; }
    public Interpolation InterpolationOut { get; set; } = Interpolation.Smooth;

    public bool Equals(Keyframe<TValue>? other)
        => other is not null && Frame == other.Frame && Value.Equals(other.Value) && InterpolationOut == other.InterpolationOut;

    public override bool Equals(object? obj) => Equals(obj as Keyframe<TValue>);
    public override int GetHashCode() => HashCode.Combine(Frame, Value, InterpolationOut);
}

public sealed class KeyframeTrack<TValue> : IEquatable<KeyframeTrack<TValue>> where TValue : IEquatable<TValue>
{
    public List<Keyframe<TValue>> Keyframes { get; set; } = [];

    public bool IsActive => Keyframes.Count > 0;

    public void Upsert(Keyframe<TValue> kf)
    {
        var existing = Keyframes.FindIndex(k => k.Frame == kf.Frame);
        if (existing >= 0)
        {
            Keyframes[existing] = kf;
            return;
        }
        var at = Keyframes.FindIndex(k => k.Frame > kf.Frame);
        Keyframes.Insert(at < 0 ? Keyframes.Count : at, kf);
    }

    public void Remove(int frame) => Keyframes.RemoveAll(k => k.Frame == frame);

    public void Move(int oldFrame, int newFrame)
    {
        var i = Keyframes.FindIndex(k => k.Frame == oldFrame);
        if (i < 0) return;
        if (newFrame != oldFrame && Keyframes.Any(k => k.Frame == newFrame)) return;
        var kf = Keyframes[i];
        Keyframes.RemoveAt(i);
        kf.Frame = newFrame;
        Upsert(kf);
    }

    public TValue Sample(int frame, TValue fallback, Func<TValue, TValue, double, TValue> lerp)
    {
        var kfs = Keyframes;
        if (kfs.Count == 0) return fallback;
        if (kfs.Count == 1) return kfs[0].Value;
        if (frame <= kfs[0].Frame) return kfs[0].Value;
        if (frame >= kfs[^1].Frame) return kfs[^1].Value;

        var bIdx = kfs.FindIndex(k => k.Frame > frame);
        if (bIdx < 0) return kfs[^1].Value;
        var a = kfs[bIdx - 1];
        var b = kfs[bIdx];
        var raw = (double)(frame - a.Frame) / (b.Frame - a.Frame);
        return a.InterpolationOut switch
        {
            Interpolation.Hold => a.Value,
            Interpolation.Linear => lerp(a.Value, b.Value, raw),
            _ => lerp(a.Value, b.Value, Easing.Smoothstep(raw)),
        };
    }

    /// <summary>Shift keyframes left by <paramref name="offset"/>, inserting a sampled boundary keyframe at 0. Null when nothing remains.</summary>
    public KeyframeTrack<TValue>? Rebased(int offset, TValue fallback, Func<TValue, TValue, double, TValue> lerp)
    {
        if (!IsActive) return null;
        var boundary = Sample(offset, fallback, lerp);
        var kfs = Keyframes
            .Where(k => k.Frame >= offset)
            .Select(k => new Keyframe<TValue> { Frame = k.Frame - offset, Value = k.Value, InterpolationOut = k.InterpolationOut })
            .ToList();
        if (kfs.Count == 0 || kfs[0].Frame != 0)
        {
            var interp = Keyframes.LastOrDefault(k => k.Frame < offset)?.InterpolationOut ?? Interpolation.Smooth;
            kfs.Insert(0, new Keyframe<TValue> { Frame = 0, Value = boundary, InterpolationOut = interp });
        }
        return kfs.Count == 0 ? null : new KeyframeTrack<TValue> { Keyframes = kfs };
    }

    public bool Equals(KeyframeTrack<TValue>? other)
        => other is not null && Keyframes.SequenceEqual(other.Keyframes);

    public override bool Equals(object? obj) => Equals(obj as KeyframeTrack<TValue>);
    public override int GetHashCode() => Keyframes.Count;
}

/// <summary>Two-component keyframe value used for position (x, y) and scale (width, height).</summary>
public record struct AnimPair(double A, double B)
{
    public static AnimPair Lerp(AnimPair from, AnimPair to, double t)
        => new(from.A + (to.A - from.A) * t, from.B + (to.B - from.B) * t);
}

public static class KeyframeSampling
{
    public static double Sample(this KeyframeTrack<double> track, int frame, double fallback)
        => track.Sample(frame, fallback, static (a, b, t) => a + (b - a) * t);

    public static AnimPair Sample(this KeyframeTrack<AnimPair> track, int frame, AnimPair fallback)
        => track.Sample(frame, fallback, AnimPair.Lerp);

    public static Crop Sample(this KeyframeTrack<Crop> track, int frame, Crop fallback)
        => track.Sample(frame, fallback, Crop.Lerp);

    public static KeyframeTrack<double>? Rebased(this KeyframeTrack<double> track, int offset, double fallback)
        => track.Rebased(offset, fallback, static (a, b, t) => a + (b - a) * t);

    public static KeyframeTrack<AnimPair>? Rebased(this KeyframeTrack<AnimPair> track, int offset, AnimPair fallback)
        => track.Rebased(offset, fallback, AnimPair.Lerp);

    public static KeyframeTrack<Crop>? Rebased(this KeyframeTrack<Crop> track, int offset, Crop fallback)
        => track.Rebased(offset, fallback, Crop.Lerp);
}

/// <summary>Identifies which clip property an inspector lane / stamp button drives.</summary>
public enum AnimatableProperty
{
    Opacity,
    Position,
    Scale,
    Rotation,
    Crop,
    Volume,
}
