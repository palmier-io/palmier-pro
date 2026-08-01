using PalmierPro.Core.Editing;
using PalmierPro.Core.Models;
using PalmierPro.Core.Undo;
using Xunit;

namespace PalmierPro.Core.Tests;

public class TimelineEditOperationsTests
{
    private readonly UndoManager _manager = new();
    private readonly EditorUndo _undo = new();

    private TimelineEditOperations MakeOps(Timeline timeline)
    {
        _undo.Attach(_manager);
        return new TimelineEditOperations(timeline, _undo);
    }

    private static Clip VideoClip(string id, int start, int duration, string? linkGroup = null) => new()
    {
        Id = id,
        MediaRef = "media-" + id,
        MediaType = ClipType.Video,
        StartFrame = start,
        DurationFrames = duration,
        LinkGroupId = linkGroup,
    };

    private static Clip AudioClip(string id, int start, int duration, string? linkGroup = null) => new()
    {
        Id = id,
        MediaRef = "media-" + id,
        MediaType = ClipType.Audio,
        SourceClipType = ClipType.Audio,
        StartFrame = start,
        DurationFrames = duration,
        LinkGroupId = linkGroup,
    };

    private static Timeline OneTrack(params Clip[] clips) => new()
    {
        Fps = 30,
        Tracks = [new Track { Type = ClipType.Video, Clips = [.. clips] }],
    };

    private static Clip ClipById(Timeline timeline, string id)
        => timeline.Tracks.SelectMany(t => t.Clips).First(c => c.Id == id);

    private static bool ContainsClip(Timeline timeline, string id)
        => timeline.Tracks.SelectMany(t => t.Clips).Any(c => c.Id == id);

    // MARK: - Move

    [Fact]
    public void MoveClipShiftsAndUndoRedoRestore()
    {
        var timeline = OneTrack(VideoClip("a", 0, 60));
        var ops = MakeOps(timeline);

        Assert.True(ops.MoveClip("a", 90));
        Assert.Equal(90, ClipById(timeline, "a").StartFrame);
        Assert.True(_manager.CanUndo);

        _manager.Undo();
        Assert.Equal(0, ClipById(timeline, "a").StartFrame);

        _manager.Redo();
        Assert.Equal(90, ClipById(timeline, "a").StartFrame);
    }

    [Fact]
    public void MoveClipCarriesLinkedCompanions()
    {
        var timeline = new Timeline
        {
            Tracks =
            [
                new Track { Type = ClipType.Video, Clips = [VideoClip("v", 10, 50, "L")] },
                new Track { Type = ClipType.Audio, Clips = [AudioClip("au", 10, 50, "L")] },
            ],
        };
        var ops = MakeOps(timeline);

        Assert.True(ops.MoveClip("v", 40));
        Assert.Equal(40, ClipById(timeline, "v").StartFrame);
        Assert.Equal(40, ClipById(timeline, "au").StartFrame);

        _manager.Undo();
        Assert.Equal(10, ClipById(timeline, "v").StartFrame);
        Assert.Equal(10, ClipById(timeline, "au").StartFrame);
    }

    [Fact]
    public void MoveOverwritesDestinationCollisions()
    {
        var timeline = OneTrack(VideoClip("a", 0, 60), VideoClip("b", 100, 60));
        var ops = MakeOps(timeline);

        // Move a onto b's span: b is fully covered from 80..140? a=60 long at 80 covers 80..140,
        // b spans 100..160 → partial: b gets trim-started to 140.
        Assert.True(ops.MoveClip("a", 80));
        var b = ClipById(timeline, "b");
        Assert.Equal(140, b.StartFrame);
        Assert.Equal(20, b.DurationFrames);
        Assert.Equal(40, b.TrimStartFrame);
    }

    [Fact]
    public void MoveNoOpAndInvalidCreateNoUndoEntry()
    {
        var ops = MakeOps(OneTrack(VideoClip("a", 5, 60)));
        Assert.False(ops.MoveClip("a", 5));
        Assert.False(ops.MoveClip("a", -1));
        Assert.False(ops.MoveClip("missing", 10));
        Assert.False(_manager.CanUndo);
    }

    [Fact]
    public void MoveToIncompatibleTrackTypeIsDropped()
    {
        var timeline = new Timeline
        {
            Tracks =
            [
                new Track { Type = ClipType.Video, Clips = [VideoClip("v", 0, 30)] },
                new Track { Type = ClipType.Audio, Clips = [] },
            ],
        };
        var ops = MakeOps(timeline);
        Assert.False(ops.MoveClips([("v", 1, 0)]));
        Assert.False(_manager.CanUndo);
    }

    // MARK: - Trim

    [Fact]
    public void TrimLeftAdjustsStartDurationAndTrim()
    {
        var timeline = OneTrack(VideoClip("a", 30, 60));
        var ops = MakeOps(timeline);

        Assert.True(ops.TrimClip("a", 40, 50, 10));
        var clip = ClipById(timeline, "a");
        Assert.Equal((40, 50, 10), (clip.StartFrame, clip.DurationFrames, clip.TrimStartFrame));

        _manager.Undo();
        clip = ClipById(timeline, "a");
        Assert.Equal((30, 60, 0), (clip.StartFrame, clip.DurationFrames, clip.TrimStartFrame));
        _manager.Redo();
        clip = ClipById(timeline, "a");
        Assert.Equal((40, 50, 10), (clip.StartFrame, clip.DurationFrames, clip.TrimStartFrame));
    }

    [Fact]
    public void TrimRightShorterIncreasesTrimEnd()
    {
        var clip = VideoClip("a", 0, 100);
        clip.Speed = 2.0;
        var ops = MakeOps(OneTrack(clip));

        Assert.True(ops.TrimClip("a", 0, 80, 0));
        var trimmed = ClipById(ops.Timeline, "a");
        Assert.Equal(80, trimmed.DurationFrames);
        Assert.Equal(40, trimmed.TrimEndFrame); // 20 timeline frames * 2.0 speed
    }

    [Fact]
    public void TrimExpansionOverwritesNeighbor()
    {
        var timeline = OneTrack(VideoClip("a", 0, 60), VideoClip("b", 60, 60));
        var ops = MakeOps(timeline);

        // Extend a's right edge into b: b should trim-start to 80.
        Assert.True(ops.TrimClip("a", 0, 80, 0));
        var b = ClipById(timeline, "b");
        Assert.Equal(80, b.StartFrame);
        Assert.Equal(40, b.DurationFrames);
        Assert.Equal(20, b.TrimStartFrame);
    }

    [Fact]
    public void TrimRejectsInvalidArguments()
    {
        var ops = MakeOps(OneTrack(VideoClip("a", 0, 60)));
        Assert.False(ops.TrimClip("a", -1, 60, 0));
        Assert.False(ops.TrimClip("a", 0, 0, 0));
        Assert.False(ops.TrimClip("a", 0, 60, -2));
        Assert.False(_manager.CanUndo);
    }

    // MARK: - Slip

    [Fact]
    public void SlipShiftsSourceWindowWithoutMoving()
    {
        var clip = VideoClip("a", 10, 50);
        clip.TrimStartFrame = 20;
        clip.TrimEndFrame = 20;
        var ops = MakeOps(OneTrack(clip));

        Assert.True(ops.SlipClip("a", 5));
        var slipped = ClipById(ops.Timeline, "a");
        Assert.Equal(10, slipped.StartFrame);
        Assert.Equal(50, slipped.DurationFrames);
        Assert.Equal(15, slipped.TrimStartFrame);
        Assert.Equal(25, slipped.TrimEndFrame);
    }

    [Fact]
    public void SlipClampsToSourceHeadroom()
    {
        var clip = VideoClip("a", 0, 50);
        clip.TrimStartFrame = 3;
        clip.TrimEndFrame = 40;
        var ops = MakeOps(OneTrack(clip));

        Assert.True(ops.SlipClip("a", 10)); // only 3 frames of head trim available
        var slipped = ClipById(ops.Timeline, "a");
        Assert.Equal(0, slipped.TrimStartFrame);
        Assert.Equal(43, slipped.TrimEndFrame);
    }

    [Fact]
    public void SlipRefusesImageTextAndZeroDelta()
    {
        var image = VideoClip("img", 0, 50);
        image.MediaType = ClipType.Image;
        var ops = MakeOps(OneTrack(image));
        Assert.False(ops.SlipClip("img", 5));
        Assert.False(ops.SlipClip("img", 0));
        Assert.False(_manager.CanUndo);
    }

    // MARK: - Split

    [Fact]
    public void SplitCreatesRightClipWithShiftedTrim()
    {
        var clip = VideoClip("a", 0, 100);
        clip.TrimStartFrame = 5;
        clip.Speed = 2.0;
        clip.FadeOutFrames = 12;
        var timeline = OneTrack(clip);
        var ops = MakeOps(timeline);

        var rightIds = ops.SplitClip("a", 40);
        Assert.Single(rightIds);
        var clips = timeline.Tracks[0].Clips;
        Assert.Equal(2, clips.Count);
        Assert.Equal(40, clips[0].DurationFrames);
        Assert.Equal(0, clips[0].FadeOutFrames);
        Assert.Equal(120, clips[0].TrimEndFrame); // += 60 * 2.0 speed
        Assert.Equal(40, clips[1].StartFrame);
        Assert.Equal(60, clips[1].DurationFrames);
        Assert.Equal(85, clips[1].TrimStartFrame); // 5 + 40 * 2.0 speed
        Assert.Equal(0, clips[1].FadeInFrames);

        _manager.Undo();
        Assert.Single(timeline.Tracks[0].Clips);
        var restored = ClipById(timeline, "a");
        Assert.Equal(100, restored.DurationFrames);
        Assert.Equal(12, restored.FadeOutFrames);
        Assert.Equal(0, restored.TrimEndFrame);
    }

    [Fact]
    public void SplitLinkedGroupRegroupsRightHalves()
    {
        var timeline = new Timeline
        {
            Tracks =
            [
                new Track { Type = ClipType.Video, Clips = [VideoClip("v", 0, 100, "L")] },
                new Track { Type = ClipType.Audio, Clips = [AudioClip("au", 0, 100, "L")] },
            ],
        };
        var ops = MakeOps(timeline);

        var rightIds = ops.SplitClip("v", 40);
        Assert.Equal(2, rightIds.Count);
        var rights = rightIds.Select(id => ClipById(timeline, id)).ToList();
        Assert.All(rights, r => Assert.Equal(40, r.StartFrame));
        Assert.NotNull(rights[0].LinkGroupId);
        Assert.Equal(rights[0].LinkGroupId, rights[1].LinkGroupId);
        Assert.NotEqual("L", rights[0].LinkGroupId);
        Assert.Equal("L", ClipById(timeline, "v").LinkGroupId);
    }

    [Fact]
    public void SplitAtEdgeIsRefused()
    {
        var timeline = OneTrack(VideoClip("a", 10, 50));
        var ops = MakeOps(timeline);
        Assert.Empty(ops.SplitClip("a", 10));
        Assert.Empty(ops.SplitClip("a", 60));
        Assert.False(_manager.CanUndo);
    }

    // MARK: - Delete and ripple

    [Fact]
    public void DeleteRemovesAndUndoReinserts()
    {
        var timeline = OneTrack(VideoClip("a", 0, 30), VideoClip("b", 30, 30), VideoClip("c", 60, 30));
        var ops = MakeOps(timeline);

        Assert.Equal(1, ops.DeleteClips(["b"]));
        Assert.Equal(["a", "c"], timeline.Tracks[0].Clips.Select(c => c.Id));

        _manager.Undo();
        Assert.Equal(["a", "b", "c"], timeline.Tracks[0].Clips.Select(c => c.Id));

        _manager.Redo();
        Assert.Equal(["a", "c"], timeline.Tracks[0].Clips.Select(c => c.Id));
    }

    [Fact]
    public void DeleteUnknownIdsIsNoOp()
    {
        var ops = MakeOps(OneTrack(VideoClip("a", 0, 30)));
        Assert.Equal(0, ops.DeleteClips(["zzz"]));
        Assert.False(_manager.CanUndo);
    }

    [Fact]
    public void RippleDeleteClosesGapAndShiftsSyncLockedTracks()
    {
        var timeline = new Timeline
        {
            Tracks =
            [
                new Track
                {
                    Type = ClipType.Video,
                    Clips = [VideoClip("a", 0, 30), VideoClip("b", 30, 30), VideoClip("c", 60, 30)],
                },
                new Track
                {
                    Type = ClipType.Audio,
                    SyncLocked = true,
                    Clips = [AudioClip("x", 70, 20)],
                },
            ],
        };
        var ops = MakeOps(timeline);

        Assert.True(ops.RippleDeleteClips(["b"]));
        Assert.False(ContainsClip(timeline, "b"));
        Assert.Equal(30, ClipById(timeline, "c").StartFrame);
        Assert.Equal(40, ClipById(timeline, "x").StartFrame); // shifted by global range

        _manager.Undo();
        Assert.Equal(60, ClipById(timeline, "c").StartFrame);
        Assert.Equal(70, ClipById(timeline, "x").StartFrame);
        Assert.True(ContainsClip(timeline, "b"));
    }

    [Fact]
    public void RippleDeleteRefusedWhenSyncLockedShiftWouldOverlap()
    {
        var timeline = new Timeline
        {
            Tracks =
            [
                new Track
                {
                    Type = ClipType.Video,
                    Clips = [VideoClip("a", 0, 30), VideoClip("b", 30, 30), VideoClip("c", 60, 30)],
                },
                new Track
                {
                    Type = ClipType.Audio,
                    SyncLocked = true,
                    // Shifting y left by 30 (to frame 40) would overlap x [20, 50).
                    Clips = [AudioClip("x", 20, 30), AudioClip("y", 70, 20)],
                },
            ],
        };
        var ops = MakeOps(timeline);

        Assert.False(ops.RippleDeleteClips(["b"]));
        Assert.True(ContainsClip(timeline, "b"));
        Assert.False(_manager.CanUndo);
    }

    [Fact]
    public void UnsyncedTrackDoesNotShiftOnRippleDelete()
    {
        var timeline = new Timeline
        {
            Tracks =
            [
                new Track
                {
                    Type = ClipType.Video,
                    Clips = [VideoClip("a", 0, 30), VideoClip("c", 60, 30)],
                },
                new Track
                {
                    Type = ClipType.Audio,
                    SyncLocked = false,
                    Clips = [AudioClip("x", 70, 20)],
                },
            ],
        };
        var ops = MakeOps(timeline);

        Assert.True(ops.RippleDeleteClips(["a"]));
        Assert.Equal(30, ClipById(timeline, "c").StartFrame);
        Assert.Equal(70, ClipById(timeline, "x").StartFrame);
    }

    [Fact]
    public void RippleDeleteGapRequiresEmptySpan()
    {
        var timeline = OneTrack(VideoClip("a", 0, 30), VideoClip("c", 60, 30));
        var ops = MakeOps(timeline);

        Assert.False(ops.RippleDeleteGap(0, new FrameRange(20, 40))); // overlaps a
        Assert.True(ops.RippleDeleteGap(0, new FrameRange(30, 60)));
        Assert.Equal(30, ClipById(timeline, "c").StartFrame);
    }

    // MARK: - Link / unlink

    [Fact]
    public void LinkAndUnlinkRoundTrip()
    {
        var timeline = OneTrack(VideoClip("a", 0, 30), VideoClip("b", 40, 30));
        var ops = MakeOps(timeline);

        Assert.True(ops.LinkClips(["a", "b"]));
        var group = ClipById(timeline, "a").LinkGroupId;
        Assert.NotNull(group);
        Assert.Equal(group, ClipById(timeline, "b").LinkGroupId);

        Assert.True(ops.UnlinkClips(["a"]));
        Assert.Null(ClipById(timeline, "a").LinkGroupId);
        Assert.Null(ClipById(timeline, "b").LinkGroupId);

        Assert.False(ops.LinkClips(["a"])); // needs at least 2
    }

    // MARK: - Speed

    [Fact]
    public void SetClipSpeedRetimesDuration()
    {
        var timeline = OneTrack(VideoClip("a", 0, 100));
        var ops = MakeOps(timeline);

        Assert.True(ops.SetClipSpeed("a", 2.0));
        var clip = ClipById(timeline, "a");
        Assert.Equal(50, clip.DurationFrames);
        Assert.Equal(2.0, clip.Speed);

        _manager.Undo();
        clip = ClipById(timeline, "a");
        Assert.Equal(100, clip.DurationFrames);
        Assert.Equal(1.0, clip.Speed);
    }

    [Theory]
    [InlineData(100, 1.0, 2.0, 50)]
    [InlineData(100, 2.0, 1.0, 200)]
    [InlineData(1, 1.0, 4.0, 1)]
    [InlineData(30, 1.0, 0.25, 120)]
    public void RetimedDurationMatchesSwiftFormula(int duration, double speed, double newSpeed, int expected)
    {
        Assert.Equal(expected, TimelineEditOperations.RetimedDurationFrames(duration, speed, newSpeed));
    }

    [Fact]
    public void SpeedRefusedForSequenceAndOutOfRange()
    {
        var nest = VideoClip("n", 0, 100);
        nest.SourceClipType = ClipType.Sequence;
        var ops = MakeOps(OneTrack(nest));
        Assert.False(ops.SetClipSpeed("n", 2.0));

        var ops2 = MakeOps(OneTrack(VideoClip("a", 0, 100)));
        Assert.False(ops2.SetClipSpeed("a", 0.1));
        Assert.False(ops2.SetClipSpeed("a", 5.0));
    }

    // MARK: - Notifications

    [Fact]
    public void MutationsRaiseTimelineChangedIncludingUndo()
    {
        var timeline = OneTrack(VideoClip("a", 0, 60));
        var ops = MakeOps(timeline);
        var notifications = 0;
        ops.TimelineChanged += () => notifications++;

        ops.MoveClip("a", 30);
        Assert.Equal(1, notifications);
        _manager.Undo();
        Assert.Equal(2, notifications);
        _manager.Redo();
        Assert.Equal(3, notifications);
    }
}

public class TimelineClipboardAndTrackTests
{
    private readonly UndoManager _manager = new();
    private readonly EditorUndo _undo = new();

    private TimelineEditOperations MakeOps(Timeline timeline)
    {
        _undo.Attach(_manager);
        return new TimelineEditOperations(timeline, _undo);
    }

    private static Clip VideoClip(string id, int start, int duration, string? linkGroup = null) => new()
    {
        Id = id,
        MediaRef = "media-" + id,
        MediaType = ClipType.Video,
        StartFrame = start,
        DurationFrames = duration,
        LinkGroupId = linkGroup,
    };

    private static Clip AudioClip(string id, int start, int duration, string? linkGroup = null) => new()
    {
        Id = id,
        MediaRef = "media-" + id,
        MediaType = ClipType.Audio,
        SourceClipType = ClipType.Audio,
        StartFrame = start,
        DurationFrames = duration,
        LinkGroupId = linkGroup,
    };

    [Fact]
    public void CopyPastePreservesRelativeLayoutAndFreshensIds()
    {
        var timeline = new Timeline
        {
            Tracks =
            [
                new Track { Type = ClipType.Video, Clips = [VideoClip("v", 30, 50, "L")] },
                new Track { Type = ClipType.Audio, Clips = [AudioClip("au", 40, 50, "L")] },
            ],
        };
        var ops = MakeOps(timeline);

        var payload = ops.CopyClips(["v", "au"]);
        Assert.NotNull(payload);
        var pasted = ops.PasteClips(payload!, atTrack: 0, atFrame: 200);
        Assert.Equal(2, pasted.Count);

        var newVideo = timeline.Tracks[0].Clips.First(c => c.Id != "v");
        var newAudio = timeline.Tracks[1].Clips.First(c => c.Id != "au");
        Assert.Equal(200, newVideo.StartFrame);
        Assert.Equal(210, newAudio.StartFrame); // relative offset preserved
        Assert.NotNull(newVideo.LinkGroupId);
        Assert.Equal(newVideo.LinkGroupId, newAudio.LinkGroupId);
        Assert.NotEqual("L", newVideo.LinkGroupId); // remapped group
    }

    [Fact]
    public void PasteSingleLinkedMemberDropsLinkGroup()
    {
        var timeline = new Timeline
        {
            Tracks = [new Track { Type = ClipType.Video, Clips = [VideoClip("v", 0, 50, "L")] }],
        };
        var ops = MakeOps(timeline);
        var payload = ops.CopyClips(["v"]);
        var pasted = ops.PasteClips(payload!, 0, 100);
        Assert.Single(pasted);
        var clip = timeline.Tracks[0].Clips.First(c => c.Id == pasted[0]);
        Assert.Null(clip.LinkGroupId);
    }

    [Fact]
    public void PasteGarbageReturnsEmpty()
    {
        var ops = MakeOps(new Timeline { Tracks = [new Track { Type = ClipType.Video }] });
        Assert.Empty(ops.PasteClips("not json", 0, 0));
        Assert.False(_manager.CanUndo);
    }

    [Fact]
    public void DuplicateClonesAtPositions()
    {
        var timeline = new Timeline
        {
            Tracks = [new Track { Type = ClipType.Video, Clips = [VideoClip("a", 0, 30)] }],
        };
        var ops = MakeOps(timeline);
        var ids = ops.DuplicateClipsToPositions([("a", 0, 100)]);
        Assert.Single(ids);
        Assert.Equal(2, timeline.Tracks[0].Clips.Count);
        Assert.Equal(100, timeline.Tracks[0].Clips[1].StartFrame);
        Assert.NotEqual("a", timeline.Tracks[0].Clips[1].Id);
    }

    [Fact]
    public void InsertTrackRespectsVideoAudioZones()
    {
        var timeline = new Timeline
        {
            Tracks =
            [
                new Track { Type = ClipType.Video },
                new Track { Type = ClipType.Audio },
            ],
        };
        var ops = MakeOps(timeline);

        // Audio track cannot go above the video zone.
        var audioIndex = ops.InsertTrack(0, ClipType.Audio);
        Assert.Equal(1, audioIndex);
        Assert.Equal(ClipType.Audio, timeline.Tracks[1].Type);

        // Video track cannot go below the audio zone.
        var videoIndex = ops.InsertTrack(3, ClipType.Video);
        Assert.Equal(1, videoIndex);
        Assert.Equal(ClipType.Video, timeline.Tracks[1].Type);
    }

    [Fact]
    public void TrackTogglesRoundTripWithUndo()
    {
        var timeline = new Timeline { Tracks = [new Track { Type = ClipType.Audio }] };
        var ops = MakeOps(timeline);

        Assert.True(ops.ToggleTrackMute(0));
        Assert.True(timeline.Tracks[0].Muted);
        _manager.Undo();
        Assert.False(timeline.Tracks[0].Muted);

        Assert.True(ops.ToggleTrackSyncLock(0));
        Assert.False(timeline.Tracks[0].SyncLocked);
    }

    [Fact]
    public void SetTrackHeightClamps()
    {
        var timeline = new Timeline { Tracks = [new Track { Type = ClipType.Video }] };
        var ops = MakeOps(timeline);
        Assert.True(ops.SetTrackHeight(0, 500));
        Assert.Equal(PalmierPro.Core.TrackSize.MaxHeight, timeline.Tracks[0].DisplayHeight);
    }
}

public class OverwriteEngineTests
{
    private static Clip MakeClip(string id, int start, int duration, double speed = 1.0) => new()
    {
        Id = id,
        MediaRef = "m",
        StartFrame = start,
        DurationFrames = duration,
        Speed = speed,
    };

    [Fact]
    public void FullyCoveredClipIsRemoved()
    {
        var actions = OverwriteEngine.ClearActions([MakeClip("a", 10, 20)], 0, 40);
        var remove = Assert.IsType<OverwriteEngine.ClearAction.Remove>(Assert.Single(actions));
        Assert.Equal("a", remove.ClipId);
    }

    [Fact]
    public void StraddlingClipIsSplitWithSpeedScaledTrim()
    {
        var actions = OverwriteEngine.ClearActions([MakeClip("a", 0, 100, speed: 2.0)], 30, 60);
        var split = Assert.IsType<OverwriteEngine.ClearAction.Split>(Assert.Single(actions));
        Assert.Equal(30, split.LeftDurationFrames);
        Assert.Equal(60, split.RightStartFrame);
        Assert.Equal(40, split.RightDurationFrames);
        Assert.Equal(120, split.RightTrimStartFrame); // 60 * 2.0
    }

    [Fact]
    public void OverlapLeftGetsTrimEnd_OverlapRightGetsTrimStart()
    {
        var clips = new[] { MakeClip("left", 0, 50), MakeClip("right", 80, 50) };
        var actions = OverwriteEngine.ClearActions(clips, 40, 100);
        Assert.Equal(2, actions.Count);
        var trimEnd = Assert.IsType<OverwriteEngine.ClearAction.TrimEnd>(actions[0]);
        Assert.Equal(40, trimEnd.NewDurationFrames);
        var trimStart = Assert.IsType<OverwriteEngine.ClearAction.TrimStart>(actions[1]);
        Assert.Equal(100, trimStart.NewStartFrame);
        Assert.Equal(30, trimStart.NewDurationFrames);
        Assert.Equal(20, trimStart.NewTrimStartFrame);
    }

    [Fact]
    public void ExcludedAndNonIntersectingClipsUntouched()
    {
        var clips = new[] { MakeClip("a", 0, 10), MakeClip("b", 20, 10) };
        Assert.Empty(OverwriteEngine.ClearActions(clips, 10, 20));
        Assert.Empty(OverwriteEngine.ClearActions(clips, 0, 30, new HashSet<string> { "a", "b" }));
        Assert.Empty(OverwriteEngine.ClearActions(clips, 30, 30)); // empty region
    }
}

public class RippleEngineTests
{
    private static Clip MakeClip(string id, int start, int duration) => new()
    {
        Id = id,
        MediaRef = "m",
        StartFrame = start,
        DurationFrames = duration,
    };

    [Fact]
    public void MergesOverlappingAndTouchingRanges()
    {
        var merged = RippleEngine.MergeRanges([
            new FrameRange(10, 20), new FrameRange(20, 30), new FrameRange(50, 60),
            new FrameRange(55, 70), new FrameRange(5, 5),
        ]);
        Assert.Equal([new FrameRange(10, 30), new FrameRange(50, 70)], merged);
    }

    [Fact]
    public void ShiftSumsOnlyRangesFullyLeftOfClip()
    {
        var clips = new[] { MakeClip("a", 0, 10), MakeClip("b", 40, 10), MakeClip("c", 80, 10) };
        var shifts = RippleEngine.ComputeRippleShiftsForRanges(
            clips, [new FrameRange(10, 20), new FrameRange(60, 70)]);
        Assert.Equal(2, shifts.Count);
        Assert.Equal(new ClipShift("b", 30), shifts[0]);
        Assert.Equal(new ClipShift("c", 60), shifts[1]);
    }

    [Fact]
    public void PushMovesClipsAtOrAfterInsertFrame()
    {
        var clips = new[] { MakeClip("a", 0, 10), MakeClip("b", 30, 10) };
        var shifts = RippleEngine.ComputePushShifts(clips, 30, 25);
        Assert.Equal([new ClipShift("b", 55)], shifts);
        Assert.Empty(RippleEngine.ComputePushShifts(clips, 30, 0));
    }
}
