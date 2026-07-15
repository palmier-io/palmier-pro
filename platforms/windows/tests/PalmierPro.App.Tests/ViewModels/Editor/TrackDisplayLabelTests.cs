using PalmierPro.Core.Models;
using Shouldly;
using Xunit;

namespace PalmierPro.App.Tests.ViewModels.Editor;

/// Mirrors Tests/PalmierProTests/Timeline/TrackDisplayLabelTests.swift.
public class TrackDisplayLabelTests
{
    [Fact]
    public async Task LabelsVisualTracksTopToBottomThenAudio()
    {
        var (e, temp) = await EditorFixtures.MakeAsync([
            EditorFixtures.VideoTrack(),
            EditorFixtures.VideoTrack(),
            EditorFixtures.AudioTrack(),
        ]);
        using var _ = temp;

        e.TimelineTrackDisplayLabel(0).ShouldBe("V2");
        e.TimelineTrackDisplayLabel(1).ShouldBe("V1");
        e.TimelineTrackDisplayLabel(2).ShouldBe("A1");
    }

    [Fact]
    public async Task OutOfRangeIndexReturnsEmpty()
    {
        var (e, temp) = await EditorFixtures.MakeAsync([EditorFixtures.VideoTrack()]);
        using var _ = temp;

        e.TimelineTrackDisplayLabel(5).ShouldBe("");
    }

    [Fact]
    public async Task VisualTrackAfterAudioDoesNotTrap()
    {
        // Invariant-violating order (visual below audio) -- must not crash on the empty range.
        var text = EditorFixtures.VideoTrack();
        text.Type = ClipType.Text;
        var (e, temp) = await EditorFixtures.MakeAsync([
            EditorFixtures.VideoTrack(),
            EditorFixtures.AudioTrack(),
            text,
        ]);
        using var _ = temp;

        e.TimelineTrackDisplayLabel(2).ShouldBe("T1");
    }
}
