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

    private static Clip AudioClip(string mediaRef, int start, int duration, int trimStart = 0, double speed = 1)
        => new()
        {
            MediaRef = mediaRef,
            MediaType = ClipType.Audio,
            SourceClipType = ClipType.Audio,
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
        var clip = AudioClip("a", 0, 100);
        clip.Volume = 0;
        var track = new Track { Type = ClipType.Audio, Clips = [clip] };
        Assert.Empty(TimelineFrameRouter.AudibleClipsAt(MakeTimeline(track), 10));
    }

    [Fact]
    public void LinkedVideoAndAudio_OnlyAudioClipIsAudible()
    {
        // Regression: mixing Video + linked Audio of the same file caused echo.
        var video = VideoClip("media", 0, 100);
        video.LinkGroupId = "L";
        var audio = AudioClip("media", 0, 100);
        audio.LinkGroupId = "L";
        var timeline = MakeTimeline(
            new Track { Type = ClipType.Video, Clips = [video] },
            new Track { Type = ClipType.Audio, Clips = [audio] });

        var audible = TimelineFrameRouter.AudibleClipsAt(timeline, 10);
        Assert.Single(audible);
        Assert.Equal(ClipType.Audio, audible[0].Clip.MediaType);
        Assert.Equal("media", audible[0].Clip.MediaRef);
    }

    [Fact]
    public void VideoClipAlone_FallsBackToVideoAudio()
    {
        // No linked audio partner — mix the video clip so orphan drops aren't silent.
        var timeline = MakeTimeline(new Track { Type = ClipType.Video, Clips = [VideoClip("v", 0, 100)] });
        var audible = TimelineFrameRouter.AudibleClipsAt(timeline, 10);
        Assert.Single(audible);
        Assert.Equal("v", audible[0].Clip.MediaRef);
        Assert.Equal(ClipType.Video, audible[0].Clip.MediaType);
    }

    [Fact]
    public void DurationIsMaxClipEnd()
    {
        var a = new Track { Type = ClipType.Video, Clips = [VideoClip("a", 0, 50)] };
        var b = new Track { Type = ClipType.Audio, Clips = [VideoClip("b", 100, 20)] };
        Assert.Equal(120, TimelineFrameRouter.DurationFrames(MakeTimeline(a, b)));
    }

    // MARK: - Nested sequences

    private static Clip SequenceClip(string childId, int start, int duration, int trimStart = 0)
        => new()
        {
            MediaRef = childId,
            MediaType = ClipType.Video,
            SourceClipType = ClipType.Sequence,
            StartFrame = start,
            DurationFrames = duration,
            TrimStartFrame = trimStart,
        };

    [Fact]
    public void SequenceClipResolvesIntoChildTimeline()
    {
        var child = MakeTimeline(new Track
        {
            Type = ClipType.Video,
            Clips = [VideoClip("inner", 0, 100, trimStart: 30)],
        });
        child.Id = "child";
        var parent = MakeTimeline(new Track
        {
            Type = ClipType.Video,
            Clips = [SequenceClip("child", 10, 50, trimStart: 15)],
        });

        // Parent frame 40 → 30 frames into the carrier + 15 trim = child frame 45.
        var source = TimelineFrameRouter.VideoSourceAt(
            parent, 40, id => id == "child" ? child : null);
        Assert.NotNull(source);
        Assert.Equal("inner", source.Clip.MediaRef);
        Assert.Equal((30 + 45) / 30.0, source.SourceSeconds, 9);
    }

    [Fact]
    public void SequenceWithoutResolverOrTargetIsSkipped()
    {
        var under = new Track { Type = ClipType.Video, Clips = [VideoClip("under", 0, 100)] };
        var over = new Track { Type = ClipType.Video, Clips = [SequenceClip("missing", 0, 100)] };
        var timeline = MakeTimeline(under, over);

        Assert.Equal("under", TimelineFrameRouter.VideoSourceAt(timeline, 10)!.Clip.MediaRef);
        Assert.Equal("under", TimelineFrameRouter.VideoSourceAt(timeline, 10, _ => null)!.Clip.MediaRef);
    }

    [Fact]
    public void SelfReferencingSequenceTerminates()
    {
        var timeline = MakeTimeline(new Track
        {
            Type = ClipType.Video,
            Clips = [SequenceClip("self", 0, 100)],
        });
        timeline.Id = "self";
        Assert.Null(TimelineFrameRouter.VideoSourceAt(timeline, 10, _ => timeline));
    }

    [Fact]
    public void NestedAudioScalesByCarrierGain()
    {
        var childClip = AudioClip("inner", 0, 100);
        childClip.Volume = 0.5;
        var child = MakeTimeline(new Track { Type = ClipType.Audio, Clips = [childClip] });
        var carrier = SequenceClip("child", 0, 100);
        carrier.Volume = 0.5;
        var parent = MakeTimeline(new Track { Type = ClipType.Video, Clips = [carrier] });

        var audible = TimelineFrameRouter.AudibleClipsAt(parent, 10, _ => child);
        Assert.Single(audible);
        Assert.Equal("inner", audible[0].Clip.MediaRef);
        Assert.Equal(0.25, audible[0].Gain, 9);
    }
}
