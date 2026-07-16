using PalmierPro.Core.Audio;
using Shouldly;
using Xunit;

namespace PalmierPro.Core.Tests.Audio;

// Verbatim numeric port of Tests/PalmierProTests/Audio/AudioMeterTests.swift — same inputs, same
// expected dB values, so a ballistics regression here would also regress on the Mac.
public sealed class AudioMeterTests
{
    [Fact]
    public void HoldsPeakAndDecaysLevel()
    {
        var state = new AudioMeterChannelState();
        state.Ingest(0.5f, 10);
        var initial = state.Display(10);
        var afterOneSecond = state.Display(11);
        var afterTwoSeconds = state.Display(12);

        initial.LevelDb.ShouldBe(-6.0206f, tolerance: 0.001);
        initial.PeakDb.ShouldBe(-6.0206f, tolerance: 0.001);
        afterOneSecond.LevelDb.ShouldBe(-30.0206f, tolerance: 0.001);
        afterOneSecond.PeakDb.ShouldBe(initial.PeakDb, tolerance: 0.001); // still within the 1.5 s hold
        afterTwoSeconds.PeakDb.ShouldBe(-15.0206f, tolerance: 0.001); // hold expired at 11.5 s, decays 18 dB/s for 0.5 s
    }

    [Fact]
    public void LatchesClippingUntilReset()
    {
        var state = new AudioMeterChannelState();
        state.Ingest(1.01f, 0);
        state.Ingest(0f, 3);
        state.Display(3).Clipped.ShouldBeTrue();

        state.ResetClipping();
        state.Display(3).Clipped.ShouldBeFalse();
    }

    [Fact]
    public void HubIngestsBothChannelsAndResetsToFloor()
    {
        var hub = new AudioMeterHub();
        hub.Ingest(new AudioMeterAnalysis(1f, 0.25f), 0);

        var display = hub.Display(0);
        display.Left.LevelDb.ShouldBe(0f, tolerance: 0.001); // 20*log10(1) == 0 dBFS
        display.Right.LevelDb.ShouldBe(AudioMeterChannelState.Decibels(0.25f), tolerance: 0.001);

        hub.Reset();
        var afterReset = hub.Display(0);
        afterReset.Left.LevelDb.ShouldBe(AudioMeterChannelState.FloorDb, tolerance: 0.001);
        afterReset.Right.LevelDb.ShouldBe(AudioMeterChannelState.FloorDb, tolerance: 0.001);
        afterReset.Left.Clipped.ShouldBeFalse();
    }
}
