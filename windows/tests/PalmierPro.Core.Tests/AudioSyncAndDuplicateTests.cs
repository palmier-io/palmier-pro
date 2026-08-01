using PalmierPro.Core.Analysis;
using PalmierPro.Core.Editing;
using PalmierPro.Core.Models;
using Xunit;

namespace PalmierPro.Core.Tests;

public class AudioSyncAndDuplicateTests
{
    [Fact]
    public void CrossCorrelationFindsDelayedCopy()
    {
        const int sr = 16000;
        var rng = new Random(42);
        var reference = new float[sr];
        for (var i = 0; i < reference.Length; i++)
            reference[i] = (float)(rng.NextDouble() * 2 - 1) * (i is > 2000 and < 12000 ? 1f : 0.05f);

        var delaySamples = sr / 10; // 100 ms
        var target = new float[sr + delaySamples];
        Array.Copy(reference, 0, target, delaySamples, reference.Length);

        var result = AudioSyncCorrelator.Correlate(
            reference, target, sr, searchWindowSeconds: 1.0);
        // Target content starts later in-file → negative offset so timeline start moves earlier.
        Assert.InRange(result.OffsetSeconds, -0.15, -0.05);
        Assert.True(result.Confidence >= 0.3);
    }

    [Fact]
    public void DuplicateTimelineAssignsNewIds()
    {
        var source = new Timeline
        {
            Name = "A",
            Fps = 24,
            Width = 1280,
            Height = 720,
            Tracks =
            [
                new Track
                {
                    Type = ClipType.Video,
                    Clips =
                    [
                        new Clip
                        {
                            MediaRef = "m",
                            StartFrame = 0,
                            DurationFrames = 24,
                        },
                    ],
                },
            ],
        };
        var clone = TimelineDuplicate.CloneWithNewIds(source, "B");
        Assert.Equal("B", clone.Name);
        Assert.NotEqual(source.Id, clone.Id);
        Assert.NotEqual(source.Tracks[0].Id, clone.Tracks[0].Id);
        Assert.NotEqual(source.Tracks[0].Clips[0].Id, clone.Tracks[0].Clips[0].Id);
        Assert.Equal("m", clone.Tracks[0].Clips[0].MediaRef);
    }
}
