using PalmierPro.App.ViewModels.Editor;
using PalmierPro.Core.Models;
using PalmierPro.Core.Timeline;
using Shouldly;
using Xunit;

namespace PalmierPro.App.Tests.ViewModels.Editor;

/// Mirrors Tests/PalmierProTests/Timeline/RippleTrimTests.swift.
public class RippleTrimTests
{
    private static List<int[]> Spans(Track track) =>
        [.. track.Clips.OrderBy(c => c.StartFrame).Select(c => new[] { c.StartFrame, c.EndFrame })];

    [Fact]
    public async Task RightExtendPushesDownstream()
    {
        // c1 has 50 frames of tail headroom; extend the out-point by 20 and c2 rides forward.
        var track = EditorFixtures.VideoTrack(clips: [
            EditorFixtures.Clip(id: "c1", start: 0, duration: 100, trimEnd: 50),
            EditorFixtures.Clip(id: "c2", start: 100, duration: 50),
        ]);
        var (e, temp) = await EditorFixtures.MakeAsync([track]);
        using var _ = temp;

        e.RippleTrimClip("c1", TimelineEditorViewModel.TrimEdge.Right, 20, propagateToLinked: false);
        Spans(e.Timeline.Tracks[0]).ShouldBe([[0, 120], [120, 170]]);
    }

    [Fact]
    public async Task RightShrinkPullsDownstreamBack()
    {
        var track = EditorFixtures.VideoTrack(clips: [
            EditorFixtures.Clip(id: "c1", start: 0, duration: 100),
            EditorFixtures.Clip(id: "c2", start: 100, duration: 50),
        ]);
        var (e, temp) = await EditorFixtures.MakeAsync([track]);
        using var _ = temp;

        e.RippleTrimClip("c1", TimelineEditorViewModel.TrimEdge.Right, -20, propagateToLinked: false);
        Spans(e.Timeline.Tracks[0]).ShouldBe([[0, 80], [80, 130]]);
    }

    [Fact]
    public async Task ExtendNeverOverwritesFollowingClip()
    {
        var track = EditorFixtures.VideoTrack(clips: [
            EditorFixtures.Clip(id: "c1", start: 0, duration: 100, trimEnd: 80),
            EditorFixtures.Clip(id: "c2", start: 100, duration: 50),
        ]);
        var (e, temp) = await EditorFixtures.MakeAsync([track]);
        using var _ = temp;

        e.RippleTrimClip("c1", TimelineEditorViewModel.TrimEdge.Right, 60, propagateToLinked: false);
        Spans(e.Timeline.Tracks[0]).ShouldBe([[0, 160], [160, 210]]);
    }

    [Fact]
    public async Task LeftRippleAnchorsStartAndShiftsDownstream()
    {
        var track = EditorFixtures.VideoTrack(clips: [
            EditorFixtures.Clip(id: "c1", start: 0, duration: 100, trimStart: 30),
            EditorFixtures.Clip(id: "c2", start: 100, duration: 50),
        ]);
        var (e, temp) = await EditorFixtures.MakeAsync([track]);
        using var _ = temp;

        e.RippleTrimClip("c1", TimelineEditorViewModel.TrimEdge.Left, -20, propagateToLinked: false);
        Spans(e.Timeline.Tracks[0]).ShouldBe([[0, 120], [120, 170]]);
        e.Timeline.Tracks[0].Clips.First(c => c.Id == "c1").TrimStartFrame.ShouldBe(10);
    }

    [Fact]
    public async Task LinkedPartnerRipplesInSync()
    {
        var v1 = EditorFixtures.Clip(id: "v1", start: 0, duration: 100, trimEnd: 50);
        var a1 = EditorFixtures.Clip(id: "a1", mediaType: ClipType.Audio, start: 0, duration: 100, trimEnd: 50);
        v1.LinkGroupId = "g";
        a1.LinkGroupId = "g";
        var (e, temp) = await EditorFixtures.MakeAsync([
            EditorFixtures.VideoTrack(clips: [v1, EditorFixtures.Clip(id: "v2", start: 100, duration: 50)]),
            EditorFixtures.AudioTrack(clips: [a1, EditorFixtures.Clip(id: "a2", mediaType: ClipType.Audio, start: 100, duration: 50)]),
        ]);
        using var _ = temp;

        e.RippleTrimClip("v1", TimelineEditorViewModel.TrimEdge.Right, 20, propagateToLinked: true);
        Spans(e.Timeline.Tracks[0]).ShouldBe([[0, 120], [120, 170]]);
        Spans(e.Timeline.Tracks[1]).ShouldBe([[0, 120], [120, 170]]);
    }

    [Fact]
    public async Task LinkedExtendClampsToMostConstrainedPartner()
    {
        // Video has 50 frames of tail headroom, audio only 10. A 20-frame extend binds to the
        // audio's limit so both grow by 10 and stay the same length.
        var v1 = EditorFixtures.Clip(id: "v1", start: 0, duration: 100, trimEnd: 50);
        var a1 = EditorFixtures.Clip(id: "a1", mediaType: ClipType.Audio, start: 0, duration: 100, trimEnd: 10);
        v1.LinkGroupId = "g";
        a1.LinkGroupId = "g";
        var (e, temp) = await EditorFixtures.MakeAsync([
            EditorFixtures.VideoTrack(clips: [v1, EditorFixtures.Clip(id: "v2", start: 100, duration: 50)]),
            EditorFixtures.AudioTrack(clips: [a1, EditorFixtures.Clip(id: "a2", mediaType: ClipType.Audio, start: 100, duration: 50)]),
        ]);
        using var _ = temp;

        e.RippleTrimClip("v1", TimelineEditorViewModel.TrimEdge.Right, 20, propagateToLinked: true);
        Spans(e.Timeline.Tracks[0]).ShouldBe([[0, 110], [110, 160]]);
        Spans(e.Timeline.Tracks[1]).ShouldBe([[0, 110], [110, 160]]);
    }

    [Fact]
    public async Task PlanExposesDownstreamShiftsForPreview()
    {
        var track = EditorFixtures.VideoTrack(clips: [
            EditorFixtures.Clip(id: "c1", start: 0, duration: 100, trimEnd: 50),
            EditorFixtures.Clip(id: "c2", start: 100, duration: 50),
        ]);
        var (e, temp) = await EditorFixtures.MakeAsync([track]);
        using var _ = temp;

        var plan = e.PlanRippleTrim("c1", TimelineEditorViewModel.TrimEdge.Right, 20, propagateToLinked: false);
        plan!.DurationDelta.ShouldBe(20);
        plan.Shifts.ShouldBe([new ClipShift("c2", 120)]);
        plan.Resizes[0].Duration.ShouldBe(120);
    }

    [Fact]
    public async Task PlanClampsDeltaToConstrainedPartner()
    {
        var v1 = EditorFixtures.Clip(id: "v1", start: 0, duration: 100, trimEnd: 50);
        var a1 = EditorFixtures.Clip(id: "a1", mediaType: ClipType.Audio, start: 0, duration: 100, trimEnd: 10);
        v1.LinkGroupId = "g";
        a1.LinkGroupId = "g";
        var (e, temp) = await EditorFixtures.MakeAsync([
            EditorFixtures.VideoTrack(clips: [v1]),
            EditorFixtures.AudioTrack(clips: [a1]),
        ]);
        using var _ = temp;

        var plan = e.PlanRippleTrim("v1", TimelineEditorViewModel.TrimEdge.Right, 20, propagateToLinked: true);
        plan!.DurationDelta.ShouldBe(10);
    }

    [Fact]
    public async Task OutOfSyncPartnerRipplesFromItsOwnEnd()
    {
        var v1 = EditorFixtures.Clip(id: "v1", start: 0, duration: 100, trimEnd: 50);
        var a1 = EditorFixtures.Clip(id: "a1", mediaType: ClipType.Audio, start: 0, duration: 90, trimEnd: 50);
        v1.LinkGroupId = "g";
        a1.LinkGroupId = "g";
        var (e, temp) = await EditorFixtures.MakeAsync([
            EditorFixtures.VideoTrack(clips: [v1, EditorFixtures.Clip(id: "v2", start: 100, duration: 50)]),
            EditorFixtures.AudioTrack(clips: [a1, EditorFixtures.Clip(id: "a2", mediaType: ClipType.Audio, start: 90, duration: 50)]),
        ]);
        using var _ = temp;

        e.RippleTrimClip("v1", TimelineEditorViewModel.TrimEdge.Right, 20, propagateToLinked: true);
        Spans(e.Timeline.Tracks[0]).ShouldBe([[0, 120], [120, 170]]);
        Spans(e.Timeline.Tracks[1]).ShouldBe([[0, 110], [110, 160]]);
    }

    [Fact]
    public async Task ShrinkClampsAtSyncLockedObstacle()
    {
        // Lead ends at 100; the follower b1 sits at 120 with b0 ending at 90, so its downstream
        // can slide left only 30. A 50-frame shrink clamps to 30. The wall is b0's edge (frame
        // 90 on track 1), not the trimmed clip's stopped edge (frame 70 on track 0).
        var a = EditorFixtures.VideoTrack(clips: [EditorFixtures.Clip(id: "c1", start: 0, duration: 100)]);
        var b = EditorFixtures.VideoTrack(clips: [
            EditorFixtures.Clip(id: "b0", start: 60, duration: 30),
            EditorFixtures.Clip(id: "b1", start: 120, duration: 50),
        ]);
        var (e, temp) = await EditorFixtures.MakeAsync([a, b]);
        using var _ = temp;

        var plan = e.PlanRippleTrim("c1", TimelineEditorViewModel.TrimEdge.Right, -50, propagateToLinked: false);
        plan!.DurationDelta.ShouldBe(-30);
        plan.BlockedAtFrame.ShouldBe(90);

        e.RippleTrimClip("c1", TimelineEditorViewModel.TrimEdge.Right, -50, propagateToLinked: false);
        Spans(e.Timeline.Tracks[0]).ShouldBe([[0, 70]]);
        Spans(e.Timeline.Tracks[1]).ShouldBe([[60, 90], [90, 140]]);
    }

    [Fact]
    public async Task ExtendNeverBlocksOnSyncLock()
    {
        var a = EditorFixtures.VideoTrack(clips: [EditorFixtures.Clip(id: "c1", start: 0, duration: 100, trimEnd: 50)]);
        var b = EditorFixtures.VideoTrack(clips: [EditorFixtures.Clip(id: "b1", start: 100, duration: 50)]);
        var (e, temp) = await EditorFixtures.MakeAsync([a, b]);
        using var _ = temp;

        var plan = e.PlanRippleTrim("c1", TimelineEditorViewModel.TrimEdge.Right, 20, propagateToLinked: false);
        plan!.DurationDelta.ShouldBe(20);
        plan.BlockedAtFrame.ShouldBeNull();
    }

    [Fact]
    public async Task UnlinkedTrimLeavesPartnerTrackAlone()
    {
        var v1 = EditorFixtures.Clip(id: "v1", start: 0, duration: 100, trimEnd: 50);
        var a1 = EditorFixtures.Clip(id: "a1", mediaType: ClipType.Audio, start: 0, duration: 100, trimEnd: 50);
        v1.LinkGroupId = "g";
        a1.LinkGroupId = "g";
        var (e, temp) = await EditorFixtures.MakeAsync([
            EditorFixtures.VideoTrack(clips: [v1]),
            EditorFixtures.AudioTrack(clips: [a1]),
        ]);
        using var _ = temp;

        e.RippleTrimClip("v1", TimelineEditorViewModel.TrimEdge.Right, 20, propagateToLinked: false);
        Spans(e.Timeline.Tracks[0]).ShouldBe([[0, 120]]);
        Spans(e.Timeline.Tracks[1]).ShouldBe([[0, 100]]);
    }
}
