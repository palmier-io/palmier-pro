using System.Runtime.InteropServices;
using Shouldly;
using Xunit;

namespace PalmierPro.Rendering.Tests;

// E4.5 infra (docs/audio-playback-v1.md §9): drives the native XAudio2 AudioEngine
// end-to-end through its self-test seam. Plays 200 ms of a generated sine through the real
// device when one exists, or exercises the null-device fallback (doc §3.4) otherwise — so
// this passes on a device-less CI runner without special-casing.
public sealed class AudioEngineSmokeTests
{
    // Test-local P/Invoke (DllImport, not the LibraryImport source generator, to avoid an
    // AllowUnsafeBlocks flip on this test project) into the smoke seam exported from
    // native/AudioEngine.cpp — deliberately not routed through NativeMethods.cs.
    [DllImport("PalmierEngine.dll")]
    private static extern int PE_AudioEngineSmokeTest(int ms, out int outDevicePresent, out ulong outPlayedFrames);

    [Fact]
    [Trait("Category", "Audio")]
    public void SmokeTest_PlaysThroughDeviceOrFallsBackCleanly()
    {
        int rc = PE_AudioEngineSmokeTest(200, out int devicePresent, out ulong playedFrames);

        rc.ShouldBe(0);
        if (devicePresent != 0)
        {
            // A real endpoint drove ~200 ms @ 48 kHz — SamplesPlayed must have advanced past 0,
            // and well under a full second (guards against a runaway/garbage counter).
            playedFrames.ShouldBeGreaterThan(0UL);
            playedFrames.ShouldBeLessThan(48_000UL);
        }
        else
        {
            // Null-device fallback ran without crashing; nothing was played.
            playedFrames.ShouldBe(0UL);
        }
    }

    [Fact]
    [Trait("Category", "Audio")]
    public void SmokeTest_ForcedNullDevice_RunsSilentlyAndReportsFallback()
    {
        // Force the doc §3.4 no-device path (mirrors PALMIERENGINE_FORCE_WARP) so the fallback
        // is covered deterministically even on a runner that has an audio endpoint.
        Environment.SetEnvironmentVariable("PALMIERENGINE_FORCE_NULL_AUDIO", "1");
        try
        {
            int rc = PE_AudioEngineSmokeTest(50, out int devicePresent, out ulong playedFrames);

            rc.ShouldBe(0);
            devicePresent.ShouldBe(0);
            playedFrames.ShouldBe(0UL);
        }
        finally
        {
            Environment.SetEnvironmentVariable("PALMIERENGINE_FORCE_NULL_AUDIO", null);
        }
    }
}
