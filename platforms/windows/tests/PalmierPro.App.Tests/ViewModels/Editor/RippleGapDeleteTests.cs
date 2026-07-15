using PalmierPro.App.ViewModels.Editor;
using PalmierPro.Core.Models;
using PalmierPro.Core.Timeline;
using Shouldly;
using Xunit;

namespace PalmierPro.App.Tests.ViewModels.Editor;

/// Mirrors Tests/PalmierProTests/Timeline/RippleGapDeleteTests.swift.
public class RippleGapDeleteTests
{
    private static List<int> Starts(Track track) => [.. track.Clips.OrderBy(c => c.StartFrame).Select(c => c.StartFrame)];

    [Fact]
    public async Task ClosesGapAndClearsSelection()
    {
        // V1: [0,50) gap [100,150). Deleting the gap pulls c2 to 50.
        var c1 = EditorFixtures.Clip(id: "c1", start: 0, duration: 50);
        var c2 = EditorFixtures.Clip(id: "c2", start: 100, duration: 50);
        var (e, temp) = await EditorFixtures.MakeAsync([EditorFixtures.VideoTrack(clips: [c1, c2])]);
        using var _ = temp;

        e.SelectedGap = new GapSelection(0, new FrameRange(50, 100));
        e.RippleDeleteSelectedGap();
        Starts(e.Timeline.Tracks[0]).ShouldBe([0, 50]);
        e.SelectedGap.ShouldBeNull();
    }

    [Fact]
    public async Task SyncLockedTrackFollows()
    {
        var v = EditorFixtures.VideoTrack(clips: [
            EditorFixtures.Clip(id: "c1", start: 0, duration: 50),
            EditorFixtures.Clip(id: "c2", start: 100, duration: 50),
        ]);
        var a = EditorFixtures.AudioTrack(clips: [EditorFixtures.Clip(id: "a1", start: 120, duration: 30)]);
        var (e, temp) = await EditorFixtures.MakeAsync([v, a]);
        using var _ = temp;

        e.SelectedGap = new GapSelection(0, new FrameRange(50, 100));
        e.RippleDeleteSelectedGap();
        Starts(e.Timeline.Tracks[0]).ShouldBe([0, 50]);
        Starts(e.Timeline.Tracks[1]).ShouldBe([70]);
    }

    [Fact]
    public async Task RefusesWhenSyncLockedFollowerWouldCollide()
    {
        // a2 (at/after the gap end) shifts left by 50 onto a1 -> whole edit refused, nothing moves.
        var v = EditorFixtures.VideoTrack(clips: [
            EditorFixtures.Clip(id: "c1", start: 0, duration: 50),
            EditorFixtures.Clip(id: "c2", start: 100, duration: 50),
        ]);
        var a = EditorFixtures.AudioTrack(clips: [
            EditorFixtures.Clip(id: "a1", start: 0, duration: 55),
            EditorFixtures.Clip(id: "a2", start: 100, duration: 50),
        ]);
        var (e, temp) = await EditorFixtures.MakeAsync([v, a]);
        using var _ = temp;

        e.SelectedGap = new GapSelection(0, new FrameRange(50, 100));
        e.RippleDeleteSelectedGap();
        Starts(e.Timeline.Tracks[0]).ShouldBe([0, 100]);
        Starts(e.Timeline.Tracks[1]).ShouldBe([0, 100]);
    }

    [Fact]
    public async Task NoOpWhenGapNoLongerEmpty()
    {
        // A stale selection whose range a clip now occupies must not shift anything.
        var v = EditorFixtures.VideoTrack(clips: [
            EditorFixtures.Clip(id: "c1", start: 0, duration: 50),
            EditorFixtures.Clip(id: "c3", start: 60, duration: 30),
            EditorFixtures.Clip(id: "c2", start: 100, duration: 50),
        ]);
        var (e, temp) = await EditorFixtures.MakeAsync([v]);
        using var _ = temp;

        e.SelectedGap = new GapSelection(0, new FrameRange(50, 100));
        e.RippleDeleteSelectedGap();
        Starts(e.Timeline.Tracks[0]).ShouldBe([0, 60, 100]);
        e.SelectedGap.ShouldBeNull();
    }
}
