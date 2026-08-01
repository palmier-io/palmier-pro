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

    private static Timeline OneTrack(params Clip[] clips) => new()
    {
        Fps = 30,
        Tracks = [new Track { Type = ClipType.Video, Clips = [.. clips] }],
    };

    [Fact]
    public void MoveClipShiftsAndUndoRestores()
    {
        var timeline = OneTrack(VideoClip("a", 0, 60));
        var ops = MakeOps(timeline);

        Assert.True(ops.MoveClip("a", 90));
        Assert.Equal(90, timeline.Tracks[0].Clips[0].StartFrame);
        Assert.True(_manager.CanUndo);

        _manager.Undo();
        Assert.Equal(0, timeline.Tracks[0].Clips[0].StartFrame);

        _manager.Redo();
        Assert.Equal(90, timeline.Tracks[0].Clips[0].StartFrame);
    }

    [Fact]
    public void MoveClipCarriesLinkedCompanions()
    {
        var video = VideoClip("v", 10, 50, linkGroup: "L");
        var audio = new Clip
        {
            Id = "au", MediaRef = "m-au", MediaType = ClipType.Audio,
            StartFrame = 10, DurationFrames = 50, LinkGroupId = "L",
        };
        var timeline = new Timeline
        {
            Tracks =
            [
                new Track { Type = ClipType.Video, Clips = [video] },
                new Track { Type = ClipType.Audio, Clips = [audio] },
            ],
        };
        var ops = MakeOps(timeline);

        Assert.True(ops.MoveClip("v", 40));
        Assert.Equal(40, video.StartFrame);
        Assert.Equal(40, audio.StartFrame);

        _manager.Undo();
        Assert.Equal(10, video.StartFrame);
        Assert.Equal(10, audio.StartFrame);
    }

    [Fact]
    public void MoveNoOpAndNegativeCreateNoUndoEntry()
    {
        var ops = MakeOps(OneTrack(VideoClip("a", 5, 60)));
        Assert.False(ops.MoveClip("a", 5));
        Assert.False(ops.MoveClip("a", -1));
        Assert.False(ops.MoveClip("missing", 10));
        Assert.False(_manager.CanUndo);
    }

    [Fact]
    public void TrimLeftAdjustsStartDurationAndTrim()
    {
        var timeline = OneTrack(VideoClip("a", 30, 60));
        var ops = MakeOps(timeline);
        var clip = timeline.Tracks[0].Clips[0];

        Assert.True(ops.TrimClip("a", 40, 50, 10));
        Assert.Equal(40, clip.StartFrame);
        Assert.Equal(50, clip.DurationFrames);
        Assert.Equal(10, clip.TrimStartFrame);

        _manager.Undo();
        Assert.Equal((30, 60, 0), (clip.StartFrame, clip.DurationFrames, clip.TrimStartFrame));
        _manager.Redo();
        Assert.Equal((40, 50, 10), (clip.StartFrame, clip.DurationFrames, clip.TrimStartFrame));
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

    [Fact]
    public void DeleteRemovesAndUndoReinsertsAtOriginalIndex()
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
    public void SplitCreatesRightClipWithShiftedTrim()
    {
        var clip = VideoClip("a", 0, 100);
        clip.TrimStartFrame = 5;
        clip.Speed = 2.0;
        clip.FadeOutFrames = 12;
        var timeline = OneTrack(clip);
        var ops = MakeOps(timeline);

        var rightId = ops.SplitClip("a", 40);
        Assert.NotNull(rightId);
        var clips = timeline.Tracks[0].Clips;
        Assert.Equal(2, clips.Count);
        Assert.Equal(40, clips[0].DurationFrames);
        Assert.Equal(0, clips[0].FadeOutFrames);
        Assert.Equal(40, clips[1].StartFrame);
        Assert.Equal(60, clips[1].DurationFrames);
        // trimStart' = 5 + 40 * 2.0 speed.
        Assert.Equal(85, clips[1].TrimStartFrame);
        Assert.Equal(0, clips[1].FadeInFrames);

        _manager.Undo();
        Assert.Single(timeline.Tracks[0].Clips);
        Assert.Equal(100, clip.DurationFrames);
        Assert.Equal(12, clip.FadeOutFrames);
    }

    [Fact]
    public void SplitAtEdgeIsRefused()
    {
        var timeline = OneTrack(VideoClip("a", 10, 50));
        var ops = MakeOps(timeline);
        Assert.Null(ops.SplitClip("a", 10));
        Assert.Null(ops.SplitClip("a", 60));
        Assert.False(_manager.CanUndo);
    }

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
