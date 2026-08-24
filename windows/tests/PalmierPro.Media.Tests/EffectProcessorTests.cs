using PalmierPro.Core.Compositing;
using PalmierPro.Core.Models;
using PalmierPro.Media.Compositing;
using PalmierPro.Media.Playback;
using Xunit;

namespace PalmierPro.Media.Tests;

public class EffectProcessorTests
{
    private static VideoFrame Solid(byte b, byte g, byte r, byte a = 255, int w = 4, int h = 4)
    {
        var data = new byte[w * h * 4];
        for (var i = 0; i < data.Length; i += 4)
        {
            data[i] = b; data[i + 1] = g; data[i + 2] = r; data[i + 3] = a;
        }
        return new VideoFrame(data, w, h, w * 4);
    }

    [Fact]
    public void InvertFlipsChannels()
    {
        var frame = Solid(0, 64, 128);
        var result = EffectProcessor.Apply(frame, "stylize.invert",
            new ResolvedEffectParams { Values = [], Strings = [] });
        Assert.Equal(255, result.Bgra[0]);
        Assert.Equal(191, result.Bgra[1]);
        Assert.Equal(127, result.Bgra[2]);
    }

    [Fact]
    public void ClipPipelineAppliesEnabledEffectsInOrder()
    {
        var clip = new Clip
        {
            MediaRef = "x",
            MediaType = ClipType.Video,
            SourceClipType = ClipType.Video,
            StartFrame = 0,
            DurationFrames = 30,
            Effects =
            [
                Effect.Make("color.exposure", new Dictionary<string, double> { ["ev"] = 1 }),
                Effect.Make("stylize.invert"),
            ],
        };
        // Mid gray 128 → exposure +1 → ~255 → invert → ~0
        var frame = Solid(128, 128, 128);
        var result = EffectProcessor.ApplyClipPipeline(frame, clip, timelineFrame: 0);
        Assert.True(result.Bgra[2] < 10);
    }

    [Fact]
    public void DisabledEffectIsSkipped()
    {
        var clip = new Clip
        {
            MediaRef = "x",
            MediaType = ClipType.Video,
            SourceClipType = ClipType.Video,
            StartFrame = 0,
            DurationFrames = 30,
            Effects =
            [
                new Effect { Type = "stylize.invert", Enabled = false },
            ],
        };
        var frame = Solid(10, 20, 30);
        var result = EffectProcessor.ApplyClipPipeline(frame, clip, 0);
        Assert.Equal(10, result.Bgra[0]);
        Assert.Equal(20, result.Bgra[1]);
        Assert.Equal(30, result.Bgra[2]);
    }

    [Fact]
    public void TextRendererProducesNonEmptyFrame()
    {
        var clip = new Clip
        {
            MediaRef = "t",
            MediaType = ClipType.Text,
            SourceClipType = ClipType.Text,
            StartFrame = 0,
            DurationFrames = 30,
            TextContent = "Hello",
            TextStyle = new TextStyle { FontSize = 48 },
        };
        var frame = TextFrameRenderer.Render(clip, 320, 180);
        Assert.NotNull(frame);
        Assert.Equal(320, frame.Width);
        Assert.True(frame.Bgra.Any(b => b > 0));
    }
}
