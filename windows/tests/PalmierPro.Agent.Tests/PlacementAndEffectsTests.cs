using PalmierPro.Agent.Tools;
using PalmierPro.Core.Editing;
using PalmierPro.Core.Export;
using PalmierPro.Core.Models;
using PalmierPro.Core.Undo;
using Xunit;

namespace PalmierPro.Agent.Tests;

public class PlacementAndEffectsTests
{
    [Fact]
    public void RippleInsertPushesLaterClips()
    {
        var timeline = NewTimeline();
        var existing = new Clip
        {
            MediaRef = "a",
            StartFrame = 0,
            DurationFrames = 30,
        };
        timeline.Tracks[0].Clips.Add(existing);
        var later = new Clip
        {
            MediaRef = "b",
            StartFrame = 30,
            DurationFrames = 30,
        };
        timeline.Tracks[0].Clips.Add(later);

        var ops = Ops(timeline);
        var created = ops.RippleInsertClips(
        [
            new RippleInsertSpec("c", ClipType.Video, 1, false, 20),
        ], trackIndex: 0, atFrame: 30);

        Assert.Single(created);
        Assert.Equal(50, later.StartFrame);
        Assert.Equal(30, timeline.Tracks[0].Clips.First(c => c.MediaRef == "c").StartFrame);
    }

    [Fact]
    public async Task ApplyEffectAddsBlur()
    {
        var host = new FakeAgentHost();
        var clip = new Clip { MediaRef = "m", StartFrame = 0, DurationFrames = 60 };
        host.Timeline.Tracks[0].Clips.Add(clip);
        var executor = new ToolExecutor(host);

        var result = await executor.ExecuteAsync("apply_effect",
            $$$"""{"clipIds":["{{{clip.Id}}}"],"effects":[{"type":"blur.gaussian","params":{"radius":4}}]}""");
        Assert.False(result.IsError);
        Assert.Contains(clip.Effects!, e => e.Type == "blur.gaussian");
    }

    [Fact]
    public async Task ApplyColorSetsExposure()
    {
        var host = new FakeAgentHost();
        var clip = new Clip { MediaRef = "m", StartFrame = 0, DurationFrames = 60 };
        host.Timeline.Tracks[0].Clips.Add(clip);
        var executor = new ToolExecutor(host);

        var result = await executor.ExecuteAsync("apply_color",
            "{\"clipIds\":[\"" + clip.Id + "\"],\"exposure\":1.5}");
        Assert.False(result.IsError);
        var exposure = clip.Effects!.First(e => e.Type == "color.exposure");
        Assert.Equal(1.5, exposure.Params["ev"].Value);
    }

    [Fact]
    public async Task InspectTimelineReturnsLayers()
    {
        var host = new FakeAgentHost();
        host.Timeline.Tracks[0].Clips.Add(new Clip
        {
            MediaRef = "m",
            StartFrame = 0,
            DurationFrames = 60,
        });
        var executor = new ToolExecutor(host);
        var result = await executor.ExecuteAsync("inspect_timeline", """{"startFrame":10}""");
        Assert.False(result.IsError);
        Assert.NotEmpty(result.Images);
        Assert.Contains("frames", result.Content);
    }

    private static Timeline NewTimeline() => new()
    {
        Fps = 30,
        Width = 1920,
        Height = 1080,
        Tracks =
        [
            new Track { Type = ClipType.Video },
            new Track { Type = ClipType.Audio },
        ],
    };

    private static TimelineEditOperations Ops(Timeline timeline)
    {
        var undo = new UndoManager();
        var editorUndo = new EditorUndo();
        editorUndo.Attach(undo);
        return new TimelineEditOperations(timeline, editorUndo);
    }
}
