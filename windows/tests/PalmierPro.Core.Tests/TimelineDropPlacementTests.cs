using PalmierPro.Core.Editing;
using PalmierPro.Core.Models;
using PalmierPro.Core.Undo;
using Xunit;

namespace PalmierPro.Core.Tests;

/// <summary>Domain path used by UI media→timeline drop (PlaceClip + track resolve).</summary>
public class TimelineDropPlacementTests
{
    [Fact]
    public void PlaceClip_OnCompatibleTrack_CreatesClipAtFrame()
    {
        var timeline = new Timeline
        {
            Tracks =
            [
                new Track { Type = ClipType.Video },
                new Track { Type = ClipType.Audio },
            ],
        };
        var ops = new TimelineEditOperations(timeline, new EditorUndo());
        var ids = ops.PlaceClip(new PlaceClipRequest(
            "vid1",
            ClipType.Video,
            DurationSeconds: 2,
            HasAudio: true,
            TrackIndex: 0,
            StartFrame: 30,
            DurationFrames: 60,
            AddLinkedAudio: true));

        Assert.NotEmpty(ids);
        var video = timeline.Tracks[0].Clips.Single();
        Assert.Equal(30, video.StartFrame);
        Assert.Equal(60, video.DurationFrames);
        Assert.Equal("vid1", video.MediaRef);
        Assert.Contains(timeline.Tracks[1].Clips, c => c.MediaRef == "vid1" && c.MediaType == ClipType.Audio);
    }

    [Fact]
    public void PlaceClip_AudioOnAudioTrack_DoesNotRequireVideo()
    {
        var timeline = new Timeline { Tracks = [new Track { Type = ClipType.Audio }] };
        var ops = new TimelineEditOperations(timeline, new EditorUndo());
        var ids = ops.PlaceClip(new PlaceClipRequest(
            "aud1",
            ClipType.Audio,
            DurationSeconds: 1,
            HasAudio: true,
            TrackIndex: 0,
            StartFrame: 0,
            DurationFrames: 24,
            AddLinkedAudio: false));

        Assert.Single(ids);
        Assert.Equal(ClipType.Audio, timeline.Tracks[0].Clips[0].MediaType);
    }

    [Fact]
    public void RemoveTracks_DeletesTrackAndItsClips()
    {
        var timeline = new Timeline
        {
            Tracks =
            [
                new Track { Type = ClipType.Video, Clips = [new Clip { MediaRef = "v", StartFrame = 0, DurationFrames = 30 }] },
                new Track { Type = ClipType.Audio, Clips = [new Clip { MediaRef = "a", StartFrame = 0, DurationFrames = 30, MediaType = ClipType.Audio }] },
            ],
        };
        var ops = new TimelineEditOperations(timeline, new EditorUndo());
        Assert.True(ops.RemoveTracks([1]));
        Assert.Single(timeline.Tracks);
        Assert.Equal(ClipType.Video, timeline.Tracks[0].Type);
        Assert.Single(timeline.Tracks[0].Clips);
    }

    [Fact]
    public void DeleteClips_RemovesLinkedAudioPartner()
    {
        var timeline = new Timeline
        {
            Tracks =
            [
                new Track { Type = ClipType.Video },
                new Track { Type = ClipType.Audio },
            ],
        };
        var ops = new TimelineEditOperations(timeline, new EditorUndo());
        var ids = ops.PlaceClip(new PlaceClipRequest(
            "vid1", ClipType.Video, 1, true, 0, 0, 30, AddLinkedAudio: true));
        Assert.Equal(2, ids.Count);

        Assert.Equal(2, ops.DeleteClips([ids[0]]));
        Assert.Empty(timeline.Tracks[0].Clips);
        Assert.Empty(timeline.Tracks[1].Clips);
    }

    [Fact]
    public void InsertTrack_ThenPlace_WhenNoCompatibleTrack()
    {
        var timeline = new Timeline { Tracks = [new Track { Type = ClipType.Video }] };
        var ops = new TimelineEditOperations(timeline, new EditorUndo());
        var audioTrack = ops.InsertTrack(timeline.Tracks.Count, ClipType.Audio);
        Assert.True(audioTrack >= 0);
        var ids = ops.PlaceClip(new PlaceClipRequest(
            "aud2",
            ClipType.Audio,
            1,
            true,
            audioTrack,
            10,
            30,
            AddLinkedAudio: false));
        Assert.Single(ids);
        Assert.Equal(10, timeline.Tracks[audioTrack].Clips[0].StartFrame);
    }
}
