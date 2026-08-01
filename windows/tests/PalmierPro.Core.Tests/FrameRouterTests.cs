using PalmierPro.Core.Models;
using PalmierPro.Core.Playback;
using Xunit;

namespace PalmierPro.Core.Tests;

public class FrameRouterTests
{
    private static Timeline MakeTimeline(params Track[] tracks) => new()
    {
        Fps = 30,
        Tracks = [.. tracks],
    };

    private static Clip VideoClip(string mediaRef, int start, int duration, int trimStart = 0, double speed = 1)
        => new()
        {
            MediaRef = mediaRef,
            MediaType = ClipType.Video,
            SourceClipType = ClipType.Video,
            StartFrame = start,
            DurationFrames = duration,
            TrimStartFrame = trimStart,
            Speed = speed,
        };

    [Fact]
    public void TopmostVisibleTrackWins()
    {
        var bottom = new Track { Type = ClipType.Video, Clips = [VideoClip("under", 0, 100)] };
        var top = new Track { Type = ClipType.Video, Clips = [VideoClip("over", 10, 20)] };
        var timeline = MakeTimeline(bottom, top);

        Assert.Equal("over", TimelineFrameRouter.VideoSourceAt(timeline, 15)!.Clip.MediaRef);
        Assert.Equal("under", TimelineFrameRouter.VideoSourceAt(timeline, 5)!.Clip.MediaRef);
        Assert.Equal("under", TimelineFrameRouter.VideoSourceAt(timeline, 50)!.Clip.MediaRef);
    }

    [Fact]
    public void HiddenTrackIsSkipped()
    {
        var bottom = new Track { Type = ClipType.Video, Clips = [VideoClip("under", 0, 100)] };
        var top = new Track { Type = ClipType.Video, Hidden = true, Clips = [VideoClip("over", 0, 100)] };
        Assert.Equal("under", TimelineFrameRouter.VideoSourceAt(MakeTimeline(bottom, top), 10)!.Clip.MediaRef);
    }

    [Fact]
    public void GapReturnsNull()
    {
        var track = new Track { Type = ClipType.Video, Clips = [VideoClip("a", 10, 10)] };
        Assert.Null(TimelineFrameRouter.VideoSourceAt(MakeTimeline(track), 5));
        Assert.Null(TimelineFrameRouter.VideoSourceAt(MakeTimeline(track), 20));
    }

    [Theory]
    [InlineData(10, 0, 1.0, 0.0)]     // clip start, no trim
    [InlineData(40, 0, 1.0, 1.0)]     // 30 frames in at 30fps
    [InlineData(10, 15, 1.0, 0.5)]    // trim offsets source position
    [InlineData(40, 0, 2.0, 2.0)]     // 2x speed doubles source consumption
    public void SourceSecondsAccountForTrimAndSpeed(int frame, int trimStart, double speed, double expected)
    {
        var clip = VideoClip("a", 10, 100, trimStart, speed);
        Assert.Equal(expected, TimelineFrameRouter.SourceSecondsFor(clip, frame, 30), 9);
    }

    [Fact]
    public void MutedTrackContributesNoAudio()
    {
        var clip = VideoClip("a", 0, 100);
        var track = new Track { Type = ClipType.Video, Muted = true, Clips = [clip] };
        Assert.Empty(TimelineFrameRouter.AudibleClipsAt(MakeTimeline(track), 10));
    }

    [Fact]
    public void FadedOutFrameContributesNoAudio()
    {
        var clip = VideoClip("a", 0, 100);
        clip.Volume = 0;
        var track = new Track { Type = ClipType.Video, Clips = [clip] };
        Assert.Empty(TimelineFrameRouter.AudibleClipsAt(MakeTimeline(track), 10));
    }

    [Fact]
    public void DurationIsMaxClipEnd()
    {
        var a = new Track { Type = ClipType.Video, Clips = [VideoClip("a", 0, 50)] };
        var b = new Track { Type = ClipType.Audio, Clips = [VideoClip("b", 100, 20)] };
        Assert.Equal(120, TimelineFrameRouter.DurationFrames(MakeTimeline(a, b)));
    }
}
