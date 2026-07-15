using PalmierPro.App.ViewModels.Editor;
using PalmierPro.Core.Models;
using Shouldly;
using Xunit;

namespace PalmierPro.App.Tests.ViewModels.Editor;

/// Deliverable-driven coverage (not a direct Swift-file port): undo/redo round-trips for the
/// mutations in `TimelineEditorViewModel`, with particular attention to the STAGE C HANDOFF case
/// — a multi-selection loop (`SplitAtPlayhead`) must collapse to ONE undo step, not one per clip
/// — per `UndoService`'s doc comment and `UndoServiceTests.NestedGroupsCollapseToOneUndoStep`.
public class UndoRoundTripTests
{
    [Fact]
    public async Task SplitAtPlayheadWithMultipleSelectedClipsIsOneUndoStep()
    {
        // Three clips on three tracks, all spanning the playhead and all selected: one
        // SplitAtPlayhead call splits all three, but must still register as a single undo group.
        var v = EditorFixtures.VideoTrack(clips: [EditorFixtures.Clip(id: "a", start: 0, duration: 100)]);
        var a1 = EditorFixtures.AudioTrack(clips: [EditorFixtures.Clip(id: "b", mediaType: ClipType.Audio, start: 0, duration: 100)]);
        var a2 = EditorFixtures.AudioTrack(clips: [EditorFixtures.Clip(id: "c", mediaType: ClipType.Audio, start: 0, duration: 100)]);
        var (e, temp) = await EditorFixtures.MakeAsync([v, a1, a2]);
        using var _ = temp;

        e.CurrentFrame = 40;
        e.SelectedClipIds = ["a", "b", "c"];
        var depthBefore = e.Document.UndoService.UndoStackDepth;
        e.SplitAtPlayhead();
        (e.Document.UndoService.UndoStackDepth - depthBefore).ShouldBe(1);

        e.Timeline.Tracks[0].Clips.Count.ShouldBe(2);
        e.Timeline.Tracks[1].Clips.Count.ShouldBe(2);
        e.Timeline.Tracks[2].Clips.Count.ShouldBe(2);

        e.Document.UndoService.Undo();
        e.Timeline.Tracks[0].Clips.Count.ShouldBe(1);
        e.Timeline.Tracks[1].Clips.Count.ShouldBe(1);
        e.Timeline.Tracks[2].Clips.Count.ShouldBe(1);

        e.Document.UndoService.Redo();
        e.Timeline.Tracks[0].Clips.Count.ShouldBe(2);
        e.Timeline.Tracks[1].Clips.Count.ShouldBe(2);
        e.Timeline.Tracks[2].Clips.Count.ShouldBe(2);
    }

    [Fact]
    public async Task TrimStartToPlayheadAcrossSelectionCollapsesToOneUndo()
    {
        var track = EditorFixtures.VideoTrack(clips: [
            EditorFixtures.Clip(id: "a", start: 0, duration: 60),
            EditorFixtures.Clip(id: "b", start: 100, duration: 60),
        ]);
        var (e, temp) = await EditorFixtures.MakeAsync([track]);
        using var _ = temp;

        e.CurrentFrame = 30; // inside "a" only; "b" spans [100,160) so its own trim is a no-op
        e.SelectedClipIds = ["a", "b"];
        var depthBefore = e.Document.UndoService.UndoStackDepth;
        e.TrimStartToPlayhead();
        (e.Document.UndoService.UndoStackDepth - depthBefore).ShouldBe(1);

        e.Document.UndoService.Undo();
        e.Timeline.Tracks[0].Clips.First(c => c.Id == "a").StartFrame.ShouldBe(0);
    }

    [Fact]
    public async Task MoveClipsUndoRedoRoundTrips()
    {
        // A second clip stays behind on track 0 so moving "c1" off it doesn't leave the track
        // empty — moveClips ends every swap with pruneEmptyTracks() (ported verbatim from the
        // Mac's moveClips), which would otherwise remove track 0 and shift track 1 down to index
        // 0, confounding the track-index assertions below with an unrelated pruning effect.
        var c1 = EditorFixtures.Clip(id: "c1", start: 0, duration: 30);
        var keep = EditorFixtures.Clip(id: "keep", start: 200, duration: 30);
        var (e, temp) = await EditorFixtures.MakeAsync([
            EditorFixtures.VideoTrack(clips: [c1, keep]),
            EditorFixtures.VideoTrack(),
        ]);
        using var _ = temp;

        e.MoveClips([("c1", 1, 100)]);
        e.FindClip("c1")!.Value.TrackIndex.ShouldBe(1);

        e.Document.UndoService.Undo();
        var loc = e.FindClip("c1")!.Value;
        loc.TrackIndex.ShouldBe(0);
        e.Timeline.Tracks[0].Clips[loc.ClipIndex].StartFrame.ShouldBe(0);

        e.Document.UndoService.Redo();
        e.FindClip("c1")!.Value.TrackIndex.ShouldBe(1);
    }

    [Fact]
    public async Task AddAndRemoveTrackUndoRedoRoundTrips()
    {
        var (e, temp) = await EditorFixtures.MakeAsync([EditorFixtures.VideoTrack()]);
        using var _ = temp;

        var newIndex = e.InsertTrack(1, ClipType.Audio);
        e.Timeline.Tracks.Count.ShouldBe(2);
        var addedId = e.Timeline.Tracks[newIndex].Id;

        e.Document.UndoService.Undo();
        e.Timeline.Tracks.Count.ShouldBe(1);

        e.Document.UndoService.Redo();
        e.Timeline.Tracks.Count.ShouldBe(2);
        e.Timeline.Tracks.Any(t => t.Id == addedId).ShouldBeTrue();

        e.RemoveTrack(addedId);
        e.Timeline.Tracks.Count.ShouldBe(1);
        e.Document.UndoService.Undo();
        e.Timeline.Tracks.Count.ShouldBe(2);
    }

    [Fact]
    public async Task RippleDeleteSelectedClipsUndoRedoRoundTrips()
    {
        var track = EditorFixtures.VideoTrack(clips: [
            EditorFixtures.Clip(id: "a", start: 0, duration: 50),
            EditorFixtures.Clip(id: "b", start: 50, duration: 50),
        ]);
        var (e, temp) = await EditorFixtures.MakeAsync([track]);
        using var _ = temp;

        e.SelectedClipIds = ["a"];
        e.RippleDeleteSelectedClips();
        e.Timeline.Tracks[0].Clips.Count.ShouldBe(1);
        e.Timeline.Tracks[0].Clips[0].StartFrame.ShouldBe(0);

        e.Document.UndoService.Undo();
        e.Timeline.Tracks[0].Clips.Count.ShouldBe(2);
        e.Timeline.Tracks[0].Clips.Select(c => c.StartFrame).OrderBy(f => f).ShouldBe([0, 50]);

        e.Document.UndoService.Redo();
        e.Timeline.Tracks[0].Clips.Count.ShouldBe(1);
    }

    [Fact]
    public async Task RippleTrimClipUndoRedoRoundTrips()
    {
        var track = EditorFixtures.VideoTrack(clips: [
            EditorFixtures.Clip(id: "c1", start: 0, duration: 100, trimEnd: 50),
            EditorFixtures.Clip(id: "c2", start: 100, duration: 50),
        ]);
        var (e, temp) = await EditorFixtures.MakeAsync([track]);
        using var _ = temp;

        e.RippleTrimClip("c1", TimelineEditorViewModel.TrimEdge.Right, 20, propagateToLinked: false);
        e.Timeline.Tracks[0].Clips.First(c => c.Id == "c1").DurationFrames.ShouldBe(120);

        e.Document.UndoService.Undo();
        e.Timeline.Tracks[0].Clips.First(c => c.Id == "c1").DurationFrames.ShouldBe(100);
        e.Timeline.Tracks[0].Clips.First(c => c.Id == "c2").StartFrame.ShouldBe(100);

        e.Document.UndoService.Redo();
        e.Timeline.Tracks[0].Clips.First(c => c.Id == "c1").DurationFrames.ShouldBe(120);
        e.Timeline.Tracks[0].Clips.First(c => c.Id == "c2").StartFrame.ShouldBe(120);
    }

    [Fact]
    public async Task CommitClipSpeedUndoRestoresDurationAndKeyframes()
    {
        var clip = EditorFixtures.Clip(id: "c1", start: 0, duration: 60);
        clip.OpacityTrack = new KeyframeTrack<double>([
            new Keyframe<double>(0, 1.0),
            new Keyframe<double>(60, 0.0),
        ]);
        var (e, temp) = await EditorFixtures.MakeAsync([EditorFixtures.VideoTrack(clips: [clip])]);
        using var _ = temp;

        e.CommitClipSpeed(["c1"], 2.0);
        e.Timeline.Tracks[0].Clips[0].DurationFrames.ShouldBe(30);
        e.Timeline.Tracks[0].Clips[0].OpacityTrack!.Keyframes.Select(k => k.Frame).ShouldBe([0, 30]);

        e.Document.UndoService.Undo();
        e.Timeline.Tracks[0].Clips[0].DurationFrames.ShouldBe(60);
        e.Timeline.Tracks[0].Clips[0].Speed.ShouldBe(1.0);
        e.Timeline.Tracks[0].Clips[0].OpacityTrack!.Keyframes.Select(k => k.Frame).ShouldBe([0, 60]);

        e.Document.UndoService.Redo();
        e.Timeline.Tracks[0].Clips[0].DurationFrames.ShouldBe(30);
        e.Timeline.Tracks[0].Clips[0].Speed.ShouldBe(2.0);
    }
}
