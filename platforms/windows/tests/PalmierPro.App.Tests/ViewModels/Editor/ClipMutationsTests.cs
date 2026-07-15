using PalmierPro.App.ViewModels.Editor;
using PalmierPro.Core.Models;
using Shouldly;
using Xunit;

namespace PalmierPro.App.Tests.ViewModels.Editor;

/// Mirrors the subset of Tests/PalmierProTests/Timeline/ClipMutationsTests.swift that's in scope
/// for M3 (Stage C): applyClipSpeed, splitClip(s), removeClips, moveClips, clearRegion.
/// applyTimelineSettings/stampKeyframe/writePosition/commitPosition/text-style commits are M5
/// Inspector concerns and are not ported here — see `TimelineEditorViewModel`'s doc comment.
public class ApplyClipSpeedTests
{
    [Fact]
    public async Task ApplyClipSpeedDoublesScalesDurationDownByHalf()
    {
        var clip = EditorFixtures.Clip(id: "c1", start: 0, duration: 60);
        var (e, temp) = await EditorFixtures.MakeAsync([EditorFixtures.VideoTrack(clips: [clip])]);
        using var _ = temp;

        e.ApplyClipSpeed("c1", 2.0);
        var updated = e.Timeline.Tracks[0].Clips[0];
        updated.Speed.ShouldBe(2.0);
        // sourceFrames=60*1=60; newDuration = 60/2 = 30.
        updated.DurationFrames.ShouldBe(30);
    }

    [Fact]
    public async Task ApplyClipSpeedHalfDoublesDuration()
    {
        var clip = EditorFixtures.Clip(id: "c1", start: 0, duration: 60);
        var (e, temp) = await EditorFixtures.MakeAsync([EditorFixtures.VideoTrack(clips: [clip])]);
        using var _ = temp;

        e.ApplyClipSpeed("c1", 0.5);
        e.Timeline.Tracks[0].Clips[0].DurationFrames.ShouldBe(120);
    }

    [Fact]
    public async Task ApplyClipSpeedRipplesContiguousChainOnSameTrack()
    {
        // Two clips touching at frame 60: c1 [0, 60), c2 [60, 90).
        // Speeding c1 to 2.0 shrinks it to [0, 30) -> contiguous c2 should ripple to [30, 60).
        var c1 = EditorFixtures.Clip(id: "c1", start: 0, duration: 60);
        var c2 = EditorFixtures.Clip(id: "c2", start: 60, duration: 30);
        var (e, temp) = await EditorFixtures.MakeAsync([EditorFixtures.VideoTrack(clips: [c1, c2])]);
        using var _ = temp;

        e.ApplyClipSpeed("c1", 2.0);
        var updated = e.Timeline.Tracks[0].Clips.OrderBy(c => c.StartFrame).ToList();
        updated[0].DurationFrames.ShouldBe(30);
        updated[1].StartFrame.ShouldBe(30);
    }

    [Fact]
    public async Task ApplyClipSpeedDoesNotRippleNonContiguousFollowers()
    {
        var c1 = EditorFixtures.Clip(id: "c1", start: 0, duration: 60);
        var c2 = EditorFixtures.Clip(id: "c2", start: 100, duration: 30);
        var (e, temp) = await EditorFixtures.MakeAsync([EditorFixtures.VideoTrack(clips: [c1, c2])]);
        using var _ = temp;

        e.ApplyClipSpeed("c1", 2.0);
        e.Timeline.Tracks[0].Clips.First(c => c.Id == "c2").StartFrame.ShouldBe(100);
    }

    [Fact]
    public async Task ApplyClipSpeedRescalesKeyframesInsteadOfDroppingThem()
    {
        // 2x speed halves a 60-frame clip; keyframes must rescale, not get clamped away.
        var clip = EditorFixtures.Clip(id: "c1", start: 0, duration: 60);
        clip.OpacityTrack = new KeyframeTrack<double>([
            new Keyframe<double>(0, 1.0),
            new Keyframe<double>(30, 0.5),
            new Keyframe<double>(60, 0.0),
        ]);
        clip.ScaleTrack = new KeyframeTrack<AnimPair>([new Keyframe<AnimPair>(60, new AnimPair(2.0, 2.0))]);
        var (e, temp) = await EditorFixtures.MakeAsync([EditorFixtures.VideoTrack(clips: [clip])]);
        using var _ = temp;

        e.ApplyClipSpeed("c1", 2.0);
        var updated = e.Timeline.Tracks[0].Clips[0];

        updated.DurationFrames.ShouldBe(30);
        updated.OpacityTrack!.Keyframes.Select(k => k.Frame).ShouldBe([0, 15, 30]);
        updated.ScaleTrack!.Keyframes.Select(k => k.Frame).ShouldBe([30]);
    }

    [Fact]
    public async Task CommitClipSpeedRegistersSingleUndoStep()
    {
        var clip = EditorFixtures.Clip(id: "c1", start: 0, duration: 60);
        var (e, temp) = await EditorFixtures.MakeAsync([EditorFixtures.VideoTrack(clips: [clip])]);
        using var _ = temp;

        e.CommitClipSpeed(["c1"], 2.0);
        e.Timeline.Tracks[0].Clips[0].Speed.ShouldBe(2.0);
        e.Document.UndoService.CanUndo.ShouldBeTrue();
        e.Document.UndoService.UndoActionName.ShouldBe("Change Speed");

        e.Document.UndoService.Undo();
        e.Timeline.Tracks[0].Clips[0].Speed.ShouldBe(1.0);
        e.Timeline.Tracks[0].Clips[0].DurationFrames.ShouldBe(60);
    }
}

public class SplitClipTests
{
    [Fact]
    public async Task SplitClipDividesAtFrameAndReturnsRightHalfId()
    {
        var clip = EditorFixtures.Clip(id: "c1", start: 0, duration: 60);
        var (e, temp) = await EditorFixtures.MakeAsync([EditorFixtures.VideoTrack(clips: [clip])]);
        using var _ = temp;

        var rightIds = e.SplitClip("c1", 30);
        rightIds.Count.ShouldBe(1);
        var clips = e.Timeline.Tracks[0].Clips.OrderBy(c => c.StartFrame).ToList();
        clips.Count.ShouldBe(2);
        clips[0].DurationFrames.ShouldBe(30);
        clips[1].DurationFrames.ShouldBe(30);
        clips[1].Id.ShouldBe(rightIds[0]);
    }

    [Fact]
    public async Task SplitClipReturnsEmptyForUnknownId()
    {
        var (e, temp) = await EditorFixtures.MakeAsync();
        using var _ = temp;
        e.SplitClip("ghost", 10).ShouldBeEmpty();
    }

    [Fact]
    public async Task SplitAtClipBoundaryIsRejected()
    {
        var clip = EditorFixtures.Clip(id: "c1", start: 0, duration: 60);
        var (e, temp) = await EditorFixtures.MakeAsync([EditorFixtures.VideoTrack(clips: [clip])]);
        using var _ = temp;

        e.SplitClip("c1", 0).ShouldBeEmpty();
        e.SplitClip("c1", 60).ShouldBeEmpty();
        e.Timeline.Tracks[0].Clips.Count.ShouldBe(1);
    }

    [Fact]
    public async Task SplitClipDoesNotCutAnotherClipOnSameTrack()
    {
        // c1 = 0..30, c2 = 30..60. Splitting c1 at frame 45 (inside c2, outside c1) must do
        // nothing -- not resolve to c2 and cut it.
        var (e, temp) = await EditorFixtures.MakeAsync([EditorFixtures.VideoTrack(clips: [
            EditorFixtures.Clip(id: "c1", start: 0, duration: 30),
            EditorFixtures.Clip(id: "c2", start: 30, duration: 30),
        ])]);
        using var _ = temp;

        e.SplitClip("c1", 45).ShouldBeEmpty();
        e.Timeline.Tracks[0].Clips.Count.ShouldBe(2);
    }

    [Fact]
    public async Task SplitWithLinkedPartnerSplitsBothAndRegroupsRightHalves()
    {
        // video + audio sharing g1. After split at 30, the right halves should share a *new*
        // group id (not the original g1).
        var v = EditorFixtures.Clip(id: "v", start: 0, duration: 60);
        v.LinkGroupId = "g1";
        var a = EditorFixtures.Clip(id: "a", mediaType: ClipType.Audio, start: 0, duration: 60);
        a.LinkGroupId = "g1";

        var (e, temp) = await EditorFixtures.MakeAsync([
            EditorFixtures.VideoTrack(clips: [v]),
            EditorFixtures.AudioTrack(clips: [a]),
        ]);
        using var _ = temp;

        var rightIds = new HashSet<string>(e.SplitClip("v", 30));
        rightIds.Count.ShouldBe(2, "both partners should split");

        var allClips = e.Timeline.Tracks.SelectMany(t => t.Clips).ToList();
        var rightGroups = new HashSet<string?>(allClips.Where(c => rightIds.Contains(c.Id)).Select(c => c.LinkGroupId));
        rightGroups.Count.ShouldBe(1);
        rightGroups.First().ShouldNotBe("g1");

        var leftIds = new HashSet<string> { "v", "a" };
        var leftGroups = new HashSet<string?>(allClips.Where(c => leftIds.Contains(c.Id)).Select(c => c.LinkGroupId));
        leftGroups.ShouldBe(["g1"]);
    }

    [Fact]
    public async Task SplitClipsAtMultiplePointsCutsEachAndSkipsBoundaries()
    {
        var clip = EditorFixtures.Clip(id: "c1", start: 0, duration: 90);
        var (e, temp) = await EditorFixtures.MakeAsync([EditorFixtures.VideoTrack(clips: [clip])]);
        using var _ = temp;

        // Two real cuts plus a repeat of the first: the repeat lands on a boundary and is a no-op.
        var rightIds = e.SplitClips([(0, 30), (0, 60), (0, 30)]);
        var clips = e.Timeline.Tracks[0].Clips.OrderBy(c => c.StartFrame).ToList();
        clips.Select(c => c.StartFrame).ShouldBe([0, 30, 60]);
        clips.Select(c => c.DurationFrames).ShouldBe([30, 30, 30]);
        rightIds.Count.ShouldBe(2);
    }

    [Fact]
    public async Task SplitClipKeepsSegmentInterpolationOnRightHalf()
    {
        // Hold opacity (0->1.0) and linear rotation (0deg->20deg). Splitting mid-segment must
        // not turn the right half's opening keyframe smooth: hold stays flat, linear stays
        // straight.
        var clip = EditorFixtures.Clip(id: "c1", start: 0, duration: 60);
        clip.OpacityTrack = new KeyframeTrack<double>([
            new Keyframe<double>(0, 1.0, Interpolation.Hold),
            new Keyframe<double>(30, 0.5),
        ]);
        clip.RotationTrack = new KeyframeTrack<double>([
            new Keyframe<double>(0, 0.0, Interpolation.Linear),
            new Keyframe<double>(20, 20.0),
        ]);
        var (e, temp) = await EditorFixtures.MakeAsync([EditorFixtures.VideoTrack(clips: [clip])]);
        using var _ = temp;

        var rightId = e.SplitClip("c1", 10)[0];
        var right = e.Timeline.Tracks[0].Clips.First(c => c.Id == rightId);
        right.OpacityTrack!.Sample(5, 0.0, KeyframeInterpolation.Double).ShouldBe(1.0); // hold: still flat
        right.RotationTrack!.Sample(5, 0.0, KeyframeInterpolation.Double).ShouldBe(15.0); // linear: 10->20 at halfway
    }

    [Fact]
    public async Task SplitClipZerosOpacityFadesAcrossCut()
    {
        var clip = EditorFixtures.Clip(id: "c1", start: 0, duration: 60);
        clip.FadeInFrames = 15;
        clip.FadeOutFrames = 20;
        var (e, temp) = await EditorFixtures.MakeAsync([EditorFixtures.VideoTrack(clips: [clip])]);
        using var _ = temp;

        e.SplitClip("c1", 30);
        var halves = e.Timeline.Tracks[0].Clips.OrderBy(c => c.StartFrame).ToList();
        halves.Count.ShouldBe(2);
        halves[0].FadeInFrames.ShouldBe(15);
        halves[0].FadeOutFrames.ShouldBe(0);
        halves[1].FadeInFrames.ShouldBe(0);
        halves[1].FadeOutFrames.ShouldBe(20);
    }
}

public class RemoveClipsTests
{
    [Fact]
    public async Task RemoveClipsPrunesEmptyTracksByDefault()
    {
        var clip = EditorFixtures.Clip(id: "c1", start: 0, duration: 30);
        var (e, temp) = await EditorFixtures.MakeAsync([EditorFixtures.VideoTrack(clips: [clip])]);
        using var _ = temp;

        e.RemoveClips(new HashSet<string> { "c1" });
        e.Timeline.Tracks.ShouldBeEmpty();
    }

    [Fact]
    public async Task RemoveClipsWithPruneFalseKeepsEmptyTracks()
    {
        var clip = EditorFixtures.Clip(id: "c1", start: 0, duration: 30);
        var (e, temp) = await EditorFixtures.MakeAsync([EditorFixtures.VideoTrack(clips: [clip])]);
        using var _ = temp;

        e.RemoveClips(new HashSet<string> { "c1" }, prune: false);
        e.Timeline.Tracks.Count.ShouldBe(1);
        e.Timeline.Tracks[0].Clips.ShouldBeEmpty();
    }

    [Fact]
    public async Task RemoveClipsIsNoOpForUnknownIds()
    {
        var clip = EditorFixtures.Clip(id: "c1", start: 0, duration: 30);
        var (e, temp) = await EditorFixtures.MakeAsync([EditorFixtures.VideoTrack(clips: [clip])]);
        using var _ = temp;

        e.RemoveClips(new HashSet<string> { "ghost" });
        e.Timeline.Tracks[0].Clips.Count.ShouldBe(1);
    }

    [Fact]
    public async Task RemoveClipsAlsoClearsSelection()
    {
        var clip = EditorFixtures.Clip(id: "c1", start: 0, duration: 30);
        var (e, temp) = await EditorFixtures.MakeAsync([EditorFixtures.VideoTrack(clips: [clip])]);
        using var _ = temp;

        e.SelectedClipIds = ["c1", "ghost"];
        e.RemoveClips(new HashSet<string> { "c1" });
        e.SelectedClipIds.ShouldNotContain("c1");
    }

    [Fact]
    public async Task RemoveClipsUndoRestoresClip()
    {
        var clip = EditorFixtures.Clip(id: "c1", start: 0, duration: 30);
        var (e, temp) = await EditorFixtures.MakeAsync([EditorFixtures.VideoTrack(clips: [clip])]);
        using var _ = temp;

        e.RemoveClips(new HashSet<string> { "c1" });
        e.Timeline.Tracks.ShouldBeEmpty();
        e.Document.UndoService.Undo();
        e.Timeline.Tracks.Count.ShouldBe(1);
        e.Timeline.Tracks[0].Clips[0].Id.ShouldBe("c1");
    }
}

public class MoveClipsTests
{
    [Fact]
    public async Task MoveClipsMovesSingleClipToTargetTrackAndFrame()
    {
        var c1 = EditorFixtures.Clip(id: "c1", start: 0, duration: 30);
        var (e, temp) = await EditorFixtures.MakeAsync([
            EditorFixtures.VideoTrack(clips: [c1]),
            EditorFixtures.VideoTrack(),
        ]);
        using var _ = temp;

        var destTrackId = e.Timeline.Tracks[1].Id;
        e.MoveClips([("c1", 1, 100)]);
        var loc = e.FindClip("c1")!.Value;
        e.Timeline.Tracks[loc.TrackIndex].Id.ShouldBe(destTrackId);
        e.Timeline.Tracks[loc.TrackIndex].Clips[loc.ClipIndex].StartFrame.ShouldBe(100);
    }

    [Fact]
    public async Task MoveClipsRejectsIncompatibleTrackType()
    {
        // Moving a video clip onto an audio track is silently skipped (type mismatch).
        var c1 = EditorFixtures.Clip(id: "c1", start: 0, duration: 30);
        var (e, temp) = await EditorFixtures.MakeAsync([
            EditorFixtures.VideoTrack(clips: [c1]),
            EditorFixtures.AudioTrack(),
        ]);
        using var _ = temp;

        e.MoveClips([("c1", 1, 100)]);
        var loc = e.FindClip("c1")!.Value;
        e.Timeline.Tracks[loc.TrackIndex].Type.ShouldBe(ClipType.Video);
    }

    [Fact]
    public async Task MoveClipsClampsNegativeFrameToZero()
    {
        var c1 = EditorFixtures.Clip(id: "c1", start: 0, duration: 30);
        var (e, temp) = await EditorFixtures.MakeAsync([
            EditorFixtures.VideoTrack(clips: [c1]),
            EditorFixtures.VideoTrack(),
        ]);
        using var _ = temp;

        e.MoveClips([("c1", 1, -50)]);
        var loc = e.FindClip("c1")!.Value;
        e.Timeline.Tracks[loc.TrackIndex].Clips[loc.ClipIndex].StartFrame.ShouldBe(0);
    }
}

public class ClearRegionTests
{
    [Fact]
    public async Task ClearRegionRemovesClipFullyInside()
    {
        var inside = EditorFixtures.Clip(id: "inside", start: 50, duration: 30); // [50, 80)
        var (e, temp) = await EditorFixtures.MakeAsync([EditorFixtures.VideoTrack(clips: [inside])]);
        using var _ = temp;

        e.ClearRegion(0, 0, 100);
        (e.Timeline.Tracks.Count == 0 || e.Timeline.Tracks[0].Clips.Count == 0).ShouldBeTrue();
    }

    [Fact]
    public async Task ClearRegionTrimsLeftOverlapper()
    {
        // Clip [0, 100) with region [50, 200) -> trim end so clip becomes [0, 50).
        var clip = EditorFixtures.Clip(id: "c1", start: 0, duration: 100);
        var (e, temp) = await EditorFixtures.MakeAsync([EditorFixtures.VideoTrack(clips: [clip])]);
        using var _ = temp;

        e.ClearRegion(0, 50, 200);
        var remaining = e.Timeline.Tracks[0].Clips[0];
        remaining.StartFrame.ShouldBe(0);
        remaining.DurationFrames.ShouldBe(50);
    }

    [Fact]
    public async Task ClearRegionTrimsRightOverlapper()
    {
        // Clip [100, 200) with region [0, 150) -> trim start so clip becomes [150, 200).
        var clip = EditorFixtures.Clip(id: "c1", start: 100, duration: 100);
        var (e, temp) = await EditorFixtures.MakeAsync([EditorFixtures.VideoTrack(clips: [clip])]);
        using var _ = temp;

        e.ClearRegion(0, 0, 150);
        var remaining = e.Timeline.Tracks[0].Clips[0];
        remaining.StartFrame.ShouldBe(150);
        remaining.DurationFrames.ShouldBe(50);
    }

    [Fact]
    public async Task ClearRegionLeavesAdjacentClipUntouched()
    {
        // Half-open boundary: clip starts exactly at regionEnd -> not touched.
        var clip = EditorFixtures.Clip(id: "c1", start: 100, duration: 30);
        var (e, temp) = await EditorFixtures.MakeAsync([EditorFixtures.VideoTrack(clips: [clip])]);
        using var _ = temp;

        e.ClearRegion(0, 0, 100);
        e.Timeline.Tracks[0].Clips[0].StartFrame.ShouldBe(100);
        e.Timeline.Tracks[0].Clips[0].DurationFrames.ShouldBe(30);
    }
}
