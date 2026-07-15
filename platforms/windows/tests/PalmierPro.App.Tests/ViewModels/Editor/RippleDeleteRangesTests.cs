using PalmierPro.App.ViewModels.Editor;
using PalmierPro.Core.Models;
using PalmierPro.Core.Timeline;
using Shouldly;
using Xunit;

namespace PalmierPro.App.Tests.ViewModels.Editor;

/// Mirrors Tests/PalmierProTests/Timeline/RippleDeleteRangesTests.swift.
public class RippleDeleteRangesTests
{
    private static List<int> Starts(Track track) => [.. track.Clips.OrderBy(c => c.StartFrame).Select(c => c.StartFrame)];

    private static List<int[]> Spans(Track track) =>
        [.. track.Clips.OrderBy(c => c.StartFrame).Select(c => new[] { c.StartFrame, c.EndFrame })];

    [Fact]
    public async Task CutsMidClipAndClosesGap()
    {
        // [0,100), remove [40,50): head [0,40) stays, tail slides left by 10 to meet it.
        var (e, temp) = await EditorFixtures.MakeAsync([EditorFixtures.VideoTrack(clips: [EditorFixtures.Clip(id: "c1", start: 0, duration: 100)])]);
        using var _ = temp;

        var outcome = e.RippleDeleteRanges("c1", [new FrameRange(40, 50)]);
        var report = ((RippleRangesOutcome.Ok)outcome).Report;
        report.RemovedFrames.ShouldBe(10);
        Spans(e.Timeline.Tracks[0]).ShouldBe([[0, 40], [40, 90]]);
    }

    [Fact]
    public async Task MultipleRangesAccumulateShifts()
    {
        var (e, temp) = await EditorFixtures.MakeAsync([EditorFixtures.VideoTrack(clips: [EditorFixtures.Clip(id: "c1", start: 0, duration: 100)])]);
        using var _ = temp;

        var outcome = e.RippleDeleteRanges("c1", [new FrameRange(60, 70), new FrameRange(20, 30)]);
        var report = ((RippleRangesOutcome.Ok)outcome).Report;
        report.RemovedFrames.ShouldBe(20);
        Spans(e.Timeline.Tracks[0]).ShouldBe([[0, 20], [20, 50], [50, 80]]);
    }

    [Fact]
    public async Task OverlappingRangesMergeBeforeCounting()
    {
        var (e, temp) = await EditorFixtures.MakeAsync([EditorFixtures.VideoTrack(clips: [EditorFixtures.Clip(id: "c1", start: 0, duration: 100)])]);
        using var _ = temp;

        var outcome = e.RippleDeleteRanges("c1", [new FrameRange(40, 55), new FrameRange(50, 70)]);
        var report = ((RippleRangesOutcome.Ok)outcome).Report;
        report.RemovedFrames.ShouldBe(30);
        Spans(e.Timeline.Tracks[0]).ShouldBe([[0, 40], [40, 70]]);
    }

    [Fact]
    public async Task DownstreamClipShiftsByTotalRemoved()
    {
        var track = EditorFixtures.VideoTrack(clips: [
            EditorFixtures.Clip(id: "c1", start: 0, duration: 100),
            EditorFixtures.Clip(id: "c2", start: 100, duration: 50),
        ]);
        var (e, temp) = await EditorFixtures.MakeAsync([track]);
        using var _ = temp;

        e.RippleDeleteRanges("c1", [new FrameRange(40, 50)]);
        Starts(e.Timeline.Tracks[0]).ShouldBe([0, 40, 90]);
    }

    [Fact]
    public async Task LinkedPartnerCutInSync()
    {
        var v1 = EditorFixtures.Clip(id: "v1", start: 0, duration: 100);
        v1.LinkGroupId = "G";
        var a1 = EditorFixtures.Clip(id: "a1", mediaType: ClipType.Audio, start: 0, duration: 100);
        a1.LinkGroupId = "G";
        var (e, temp) = await EditorFixtures.MakeAsync([EditorFixtures.VideoTrack(clips: [v1]), EditorFixtures.AudioTrack(clips: [a1])]);
        using var _ = temp;

        var outcome = e.RippleDeleteRanges("v1", [new FrameRange(40, 50)]);
        var report = ((RippleRangesOutcome.Ok)outcome).Report;
        report.ClearedTracks.ShouldBe(2);
        Spans(e.Timeline.Tracks[0]).ShouldBe([[0, 40], [40, 90]]);
        Spans(e.Timeline.Tracks[1]).ShouldBe([[0, 40], [40, 90]]);
    }

    [Fact]
    public async Task SyncLockedFollowerShifts()
    {
        var v = EditorFixtures.VideoTrack(clips: [EditorFixtures.Clip(id: "c1", start: 0, duration: 100)]);
        var a = EditorFixtures.AudioTrack(clips: [EditorFixtures.Clip(id: "a1", start: 120, duration: 30)]);
        var (e, temp) = await EditorFixtures.MakeAsync([v, a]);
        using var _ = temp;

        e.RippleDeleteRanges("c1", [new FrameRange(40, 50)]);
        Spans(e.Timeline.Tracks[0]).ShouldBe([[0, 40], [40, 90]]);
        Starts(e.Timeline.Tracks[1]).ShouldBe([110]);
    }

    [Fact]
    public async Task SyncLockedFollowerCutInSync()
    {
        var v = EditorFixtures.VideoTrack(clips: [EditorFixtures.Clip(id: "c1", start: 0, duration: 100)]);
        var a = EditorFixtures.AudioTrack(clips: [EditorFixtures.Clip(id: "a1", start: 0, duration: 100)]);
        var (e, temp) = await EditorFixtures.MakeAsync([v, a]);
        using var _ = temp;

        var outcome = e.RippleDeleteRanges("c1", [new FrameRange(40, 50)]);
        var report = ((RippleRangesOutcome.Ok)outcome).Report;
        report.ClearedTracks.ShouldBe(2);
        Spans(e.Timeline.Tracks[0]).ShouldBe([[0, 40], [40, 90]]);
        Spans(e.Timeline.Tracks[1]).ShouldBe([[0, 40], [40, 90]]);
    }

    [Fact]
    public async Task TrackWideCutSpansMultipleClips()
    {
        var track = EditorFixtures.VideoTrack(clips: [
            EditorFixtures.Clip(id: "c1", start: 0, duration: 100),
            EditorFixtures.Clip(id: "c2", start: 100, duration: 100),
        ]);
        var (e, temp) = await EditorFixtures.MakeAsync([track]);
        using var _ = temp;

        var outcome = e.RippleDeleteRangesOnTrack(0, [new FrameRange(40, 50), new FrameRange(150, 160)]);
        var report = ((RippleRangesOutcome.Ok)outcome).Report;
        report.RemovedFrames.ShouldBe(20);
        Spans(e.Timeline.Tracks[0]).ShouldBe([[0, 40], [40, 90], [90, 140], [140, 180]]);
    }

    [Fact]
    public async Task TrackWideCutSyncsLinkedPartnersOfEachClip()
    {
        var v1 = EditorFixtures.Clip(id: "v1", start: 0, duration: 100);
        v1.LinkGroupId = "G1";
        var v2 = EditorFixtures.Clip(id: "v2", start: 100, duration: 100);
        v2.LinkGroupId = "G2";
        var a1 = EditorFixtures.Clip(id: "a1", mediaType: ClipType.Audio, start: 0, duration: 100);
        a1.LinkGroupId = "G1";
        var a2 = EditorFixtures.Clip(id: "a2", mediaType: ClipType.Audio, start: 100, duration: 100);
        a2.LinkGroupId = "G2";
        var (e, temp) = await EditorFixtures.MakeAsync([
            EditorFixtures.VideoTrack(clips: [v1, v2]),
            EditorFixtures.AudioTrack(clips: [a1, a2]),
        ]);
        using var _ = temp;

        var outcome = e.RippleDeleteRangesOnTrack(0, [new FrameRange(40, 50), new FrameRange(150, 160)]);
        var report = ((RippleRangesOutcome.Ok)outcome).Report;
        report.ClearedTracks.ShouldBe(2);
        Spans(e.Timeline.Tracks[0]).ShouldBe(Spans(e.Timeline.Tracks[1]));
    }

    [Fact]
    public async Task LinkedPartnerOnSyncLockOffTrackCutInSync()
    {
        // Cut anchored on an unrelated track: the sync-locked audio a1 is cleared, so its linked
        // video v1 must be cut too even though v1's track has sync lock off.
        var v1 = EditorFixtures.Clip(id: "v1", start: 0, duration: 100);
        v1.LinkGroupId = "G";
        var a1 = EditorFixtures.Clip(id: "a1", mediaType: ClipType.Audio, start: 0, duration: 100);
        a1.LinkGroupId = "G";
        var r1 = EditorFixtures.Clip(id: "r1", mediaType: ClipType.Audio, start: 0, duration: 100);
        var (e, temp) = await EditorFixtures.MakeAsync([
            EditorFixtures.VideoTrack(clips: [v1]),
            EditorFixtures.AudioTrack(clips: [a1]),
            EditorFixtures.AudioTrack(clips: [r1]),
        ]);
        using var _ = temp;

        e.Timeline.Tracks[0].SyncLocked = false;
        var outcome = e.RippleDeleteRangesOnTrack(2, [new FrameRange(40, 50)]);
        var report = ((RippleRangesOutcome.Ok)outcome).Report;
        report.ClearedTracks.ShouldBe(3);
        Spans(e.Timeline.Tracks[0]).ShouldBe([[0, 40], [40, 90]]);
        Spans(e.Timeline.Tracks[1]).ShouldBe([[0, 40], [40, 90]]);
        Spans(e.Timeline.Tracks[2]).ShouldBe([[0, 40], [40, 90]]);
    }

    [Fact]
    public async Task RippleInsertPushesDownstream()
    {
        // c1 [0,50), c2 [50,100). Insert a 30-frame asset at 50 -> c2 pushed to [80,130).
        var track = EditorFixtures.VideoTrack(clips: [
            EditorFixtures.Clip(id: "c1", start: 0, duration: 50),
            EditorFixtures.Clip(id: "c2", start: 50, duration: 50),
        ]);
        var (e, temp) = await EditorFixtures.MakeAsync([track]);
        using var _ = temp;

        var asset = new MediaAsset("/tmp/m1.mov", ClipType.Video, "m1", id: "m1", duration: 1.0) { HasAudio = false };
        var created = e.RippleInsertClips([asset], 0, 50);
        created.Count.ShouldBe(1);
        // int[] has no structural Equals, so ShouldContain (reference-equality Contains) always
        // misses on freshly literal arrays — compare the whole ordered span list instead.
        Spans(e.Timeline.Tracks[0]).ShouldBe([[0, 50], [50, 80], [80, 130]]);
    }

    [Fact]
    public async Task SyncLockedFollowerCutAvoidsShiftCollision()
    {
        var v = EditorFixtures.VideoTrack(clips: [EditorFixtures.Clip(id: "c1", start: 0, duration: 100)]);
        var a = EditorFixtures.AudioTrack(clips: [
            EditorFixtures.Clip(id: "a1", start: 0, duration: 95),
            EditorFixtures.Clip(id: "a2", start: 100, duration: 50),
        ]);
        var (e, temp) = await EditorFixtures.MakeAsync([v, a]);
        using var _ = temp;

        var outcome = e.RippleDeleteRanges("c1", [new FrameRange(40, 50)]);
        outcome.ShouldBeOfType<RippleRangesOutcome.Ok>();
        Spans(e.Timeline.Tracks[0]).ShouldBe([[0, 40], [40, 90]]);
        Spans(e.Timeline.Tracks[1]).ShouldBe([[0, 40], [40, 85], [90, 140]]);
    }

    [Fact]
    public async Task IgnoreSyncLockedTracksLetsCutProceedAndLeavesThemInPlace()
    {
        var v = EditorFixtures.VideoTrack(clips: [EditorFixtures.Clip(id: "c1", start: 0, duration: 100)]);
        var a = EditorFixtures.AudioTrack(clips: [
            EditorFixtures.Clip(id: "a1", start: 0, duration: 95),
            EditorFixtures.Clip(id: "a2", start: 100, duration: 50),
        ]);
        var (e, temp) = await EditorFixtures.MakeAsync([v, a]);
        using var _ = temp;

        var outcome = e.RippleDeleteRangesOnTrack(0, [new FrameRange(40, 50)], ignoreSyncLockTrackIndices: new HashSet<int> { 1 });
        outcome.ShouldBeOfType<RippleRangesOutcome.Ok>();
        Spans(e.Timeline.Tracks[0]).ShouldBe([[0, 40], [40, 90]]);
        Starts(e.Timeline.Tracks[1]).ShouldBe([0, 100]);
    }
}
