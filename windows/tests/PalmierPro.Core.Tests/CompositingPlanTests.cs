using System.Numerics;
using PalmierPro.Core.Compositing;
using PalmierPro.Core.Models;
using Xunit;

namespace PalmierPro.Core.Tests;

public class CompositingPlanTests
{
    private static Clip VisualClip(string mediaRef, ClipType type, int start, int duration)
        => new()
        {
            MediaRef = mediaRef,
            MediaType = type == ClipType.Text ? ClipType.Text : ClipType.Video,
            SourceClipType = type,
            StartFrame = start,
            DurationFrames = duration,
        };

    private static Timeline MakeTimeline(params Track[] tracks)
        => new() { Fps = 30, Width = 1920, Height = 1080, Tracks = [.. tracks] };

    [Fact]
    public void LayersStackBottomTrackFirst()
    {
        var timeline = MakeTimeline(
            new Track { Type = ClipType.Video, Clips = [VisualClip("bottom", ClipType.Video, 0, 100)] },
            new Track { Type = ClipType.Video, Clips = [VisualClip("top", ClipType.Video, 0, 100)] },
            new Track { Type = ClipType.Audio, Clips = [VisualClip("audio", ClipType.Video, 0, 100)] });
        timeline.Tracks[2].Clips[0].MediaType = ClipType.Audio;

        var layers = FrameLayerPlanner.LayersAt(timeline, 10);
        Assert.Equal(2, layers.Count);
        Assert.Equal("bottom", layers[0].Clip.MediaRef);
        Assert.Equal("top", layers[1].Clip.MediaRef);
    }

    [Fact]
    public void HiddenTrackAndOutOfRangeClipsAreExcluded()
    {
        var timeline = MakeTimeline(
            new Track { Type = ClipType.Video, Hidden = true, Clips = [VisualClip("hidden", ClipType.Video, 0, 100)] },
            new Track { Type = ClipType.Video, Clips = [VisualClip("later", ClipType.Video, 50, 100)] });
        Assert.Empty(FrameLayerPlanner.LayersAt(timeline, 10));
    }

    [Fact]
    public void TextClipBecomesTextLayer()
    {
        var timeline = MakeTimeline(new Track
        {
            Type = ClipType.Video,
            Clips = [VisualClip("t", ClipType.Text, 0, 100)],
        });
        var layers = FrameLayerPlanner.LayersAt(timeline, 10);
        Assert.Single(layers);
        Assert.Equal(FrameLayerKind.Text, layers[0].Kind);
    }

    [Fact]
    public void SequenceClipBecomesGroupWithChildCanvas()
    {
        var child = MakeTimeline(new Track
        {
            Type = ClipType.Video,
            Clips = [VisualClip("inner", ClipType.Video, 0, 200)],
        });
        child.Id = "child";
        child.Width = 1280;
        child.Height = 720;
        var parent = MakeTimeline(new Track
        {
            Type = ClipType.Video,
            Clips = [VisualClip("child", ClipType.Sequence, 0, 100)],
        });

        var layers = FrameLayerPlanner.LayersAt(parent, 10, id => id == "child" ? child : null);
        Assert.Single(layers);
        Assert.Equal(FrameLayerKind.Group, layers[0].Kind);
        Assert.Equal((1280, 720), (layers[0].ChildCanvasWidth, layers[0].ChildCanvasHeight));
        Assert.Single(layers[0].Children!);
        Assert.Equal("inner", layers[0].Children![0].Clip.MediaRef);
    }

    [Fact]
    public void IdentityTransformMapsSourceOntoFullCanvas()
    {
        var matrix = LayerTransform.Placement(new Transform(), 1280, 720, 1920, 1080);
        var origin = Vector2.Transform(Vector2.Zero, matrix);
        var corner = Vector2.Transform(new Vector2(1280, 720), matrix);
        Assert.Equal(0, origin.X, 3);
        Assert.Equal(0, origin.Y, 3);
        Assert.Equal(1920, corner.X, 3);
        Assert.Equal(1080, corner.Y, 3);
    }

    [Fact]
    public void HalfSizeCenteredTransformMapsToCenterQuarter()
    {
        var t = Transform.FromCenter(0.5, 0.5, 0.5, 0.5);
        var matrix = LayerTransform.Placement(t, 100, 100, 1000, 1000);
        var origin = Vector2.Transform(Vector2.Zero, matrix);
        var corner = Vector2.Transform(new Vector2(100, 100), matrix);
        Assert.Equal(250, origin.X, 3);
        Assert.Equal(250, origin.Y, 3);
        Assert.Equal(750, corner.X, 3);
        Assert.Equal(750, corner.Y, 3);
    }

    [Fact]
    public void HorizontalFlipMirrorsAroundSlot()
    {
        var t = new Transform { FlipHorizontal = true };
        var matrix = LayerTransform.Placement(t, 100, 100, 1000, 1000);
        var left = Vector2.Transform(Vector2.Zero, matrix);
        var right = Vector2.Transform(new Vector2(100, 0), matrix);
        Assert.Equal(1000, left.X, 3);  // source left edge lands on canvas right
        Assert.Equal(0, right.X, 3);
    }

    [Fact]
    public void RotationPreservesClipCenter()
    {
        var t = Transform.FromCenter(0.25, 0.25, 0.5, 0.5);
        t.Rotation = 90;
        var matrix = LayerTransform.Placement(t, 200, 200, 1000, 1000);
        var center = Vector2.Transform(new Vector2(100, 100), matrix);
        Assert.Equal(250, center.X, 2);
        Assert.Equal(250, center.Y, 2);
    }
}
