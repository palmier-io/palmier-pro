namespace PalmierPro.Core.Audio;

/// One block's peak per channel handed to <see cref="AudioMeterHub"/> — mirrors the shape of the
/// Mac's `AudioMeterAnalysis` (Sources/PalmierPro/Audio/AudioMeter.swift). The Windows native tap
/// (PE_TimelineGetAudioLevels) also measures RMS per channel, but the Mac's ballistics never
/// consume it, so it stops at PalmierPro.Services.Engine.AudioLevels and isn't threaded through here.
public readonly record struct AudioMeterAnalysis(float LeftPeak, float RightPeak)
{
    public static readonly AudioMeterAnalysis Silence = new(0, 0);
}

public readonly record struct AudioMeterChannelDisplay(float LevelDb, float PeakDb, bool Clipped);

public readonly record struct StereoAudioMeterDisplay(AudioMeterChannelDisplay Left, AudioMeterChannelDisplay Right);

/// Verbatim port of `Audio/AudioMeter.swift`'s `AudioMeterChannelState` — same floor/ceiling/decay
/// constants and the same ballistics: level jumps up to an incoming peak then decays linearly
/// (dB/s), a separate peak marker holds for <see cref="PeakHoldSeconds"/> then decays at its own
/// rate, and a clip latch sticks until explicitly reset. A mutable value type exactly as on the
/// Mac (`var left = AudioMeterChannelState()`) — keep instances in a plain field (not a property,
/// not an array element) so mutating calls apply in place rather than to a copy.
public struct AudioMeterChannelState
{
    public const float FloorDb = -60f;
    public const float CeilingDb = 0f;
    public const float LevelDecayDbPerSecond = 24f;
    public const float PeakDecayDbPerSecond = 18f;
    public const double PeakHoldSeconds = 1.5;

    private float _levelDb;
    private double _levelTime;
    private float _peakDb;
    private double _peakHoldUntil;

    public bool Clipped { get; private set; }

    public AudioMeterChannelState()
    {
        _levelDb = FloorDb;
        _peakDb = FloorDb;
    }

    public void Ingest(float peak, double time)
    {
        var current = Display(time);
        float incomingPeak = Decibels(peak);
        _levelDb = MathF.Max(incomingPeak, current.LevelDb);
        _levelTime = time;

        if (incomingPeak >= current.PeakDb)
        {
            _peakDb = incomingPeak;
            _peakHoldUntil = time + PeakHoldSeconds;
        }
        else if (time > _peakHoldUntil)
        {
            _peakDb = current.PeakDb;
            _peakHoldUntil = time;
        }
        Clipped = Clipped || peak >= 1f;
    }

    public readonly AudioMeterChannelDisplay Display(double time)
    {
        float levelElapsed = (float)Math.Max(0.0, time - _levelTime);
        float peakElapsed = (float)Math.Max(0.0, time - _peakHoldUntil);
        return new AudioMeterChannelDisplay(
            MathF.Max(FloorDb, _levelDb - levelElapsed * LevelDecayDbPerSecond),
            MathF.Max(FloorDb, _peakDb - peakElapsed * PeakDecayDbPerSecond),
            Clipped);
    }

    public void ResetClipping() => Clipped = false;

    public static float Decibels(float amplitude) => amplitude > 0f ? MathF.Max(FloorDb, 20f * MathF.Log10(amplitude)) : FloorDb;
}

/// Verbatim port of `Audio/AudioMeter.swift`'s `AudioMeterHub` — owns one <see cref="AudioMeterChannelState"/>
/// per stereo channel. The Mac's is `@MainActor`; this isn't thread-affine by construction, but
/// AudioMeterView (its only caller) only ever touches it from the UI thread, so the effective
/// contract is the same.
public sealed class AudioMeterHub
{
    private AudioMeterChannelState _left = new();
    private AudioMeterChannelState _right = new();

    public void Ingest(AudioMeterAnalysis analysis, double time)
    {
        _left.Ingest(analysis.LeftPeak, time);
        _right.Ingest(analysis.RightPeak, time);
    }

    public StereoAudioMeterDisplay Display(double time) => new(_left.Display(time), _right.Display(time));

    public void ResetClipping()
    {
        _left.ResetClipping();
        _right.ResetClipping();
    }

    public void Reset()
    {
        _left = new AudioMeterChannelState();
        _right = new AudioMeterChannelState();
    }
}
