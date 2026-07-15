using System.Runtime.InteropServices;
using Shouldly;
using Xunit;

namespace PalmierPro.Rendering.Tests;

// E4.5 clock slice (docs/audio-playback-v1.md §3). Drives the pure PlaybackClock through its native
// self-test seam with hand-driven fake QPC + SamplesPlayed readers — no audio device — so the audio
// branch, the QPC branch, the paused freeze, rebase, and the seamless audio<->QPC handover math are
// all asserted deterministically on a device-less CI runner (the real audio-clock path is otherwise
// unreachable there, since a null device keeps the whole timeline on QPC).
public sealed class PlaybackClockSelfTests
{
    // Test-local P/Invoke into the self-test seam exported from native/PlaybackClock.cpp —
    // deliberately not routed through NativeMethods.cs (same pattern as AudioEngineSmokeTests).
    [DllImport("PalmierEngine.dll")]
    private static extern int PE_PlaybackClockSelfTest([Out] long[] outFrames, int cap, out int outCount);

    [Fact]
    public void SelfTest_AudioQpcFreezeRebaseHandover_MatchExpectedFrames()
    {
        var frames = new long[16];
        int rc = PE_PlaybackClockSelfTest(frames, frames.Length, out int count);

        rc.ShouldBe(0);
        count.ShouldBe(8);

        // Scenario (30 fps, 48 kHz, 10 MHz QPC) — see PE_PlaybackClockSelfTest:
        //  0 paused @0 -> 0                                (frozen, rate 0)
        //  1 play on QPC, +0.5 s -> 15                     (QPC formula)
        //  2 +0.5 s more (1.0 s) -> 30
        //  3 seamless handover to the audio clock @30 -> 30 (no jump across the mode flip)
        //  4 audio +0.5 s (24000 samples) -> 45            (SamplesPlayed formula)
        //  5 pause: frozen @45 even as both readers run on
        //  6 seek-rebase to 100 while paused -> 100
        //  7 resume on QPC from 100, +0.25 s -> 107        (100 + floor(7.5))
        long[] expected = [0, 15, 30, 30, 45, 45, 100, 107];
        frames[..count].ShouldBe(expected);
    }

    [Fact]
    public void SelfTest_NullBuffer_IsRejected()
    {
        int rc = PE_PlaybackClockSelfTest(null!, 0, out _);
        rc.ShouldBe(-2); // PE_ERROR_INVALID_ARGUMENT
    }
}
