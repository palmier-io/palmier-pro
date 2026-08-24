using System.Text.Json;
using PalmierPro.Agent.Tools;
using PalmierPro.Core.Editing;
using PalmierPro.Core.Export;
using PalmierPro.Core.Models;
using PalmierPro.Core.Undo;
using Xunit;

namespace PalmierPro.Agent.Tests;

public class ToolExecutorTests
{
    [Fact]
    public async Task GetTimelineReturnsTracksAndClips()
    {
        var host = new FakeAgentHost();
        var clip = new Clip
        {
            MediaRef = "media1",
            StartFrame = 0,
            DurationFrames = 90,
        };
        host.Timeline.Tracks[0].Clips.Add(clip);
        var executor = new ToolExecutor(host);

        var result = await executor.ExecuteAsync("get_timeline", "{}");
        Assert.False(result.IsError);
        using var doc = JsonDocument.Parse(result.Content);
        Assert.Equal(30, doc.RootElement.GetProperty("fps").GetInt32());
        Assert.Equal(90, doc.RootElement.GetProperty("totalFrames").GetInt32());
        Assert.True(doc.RootElement.GetProperty("tracks").GetArrayLength() >= 1);
    }

    [Fact]
    public async Task RemoveClipsDeletesAndReports()
    {
        var host = new FakeAgentHost();
        var clip = new Clip
        {
            MediaRef = "media1",
            StartFrame = 10,
            DurationFrames = 40,
        };
        host.Timeline.Tracks[0].Clips.Add(clip);
        var executor = new ToolExecutor(host);

        var result = await executor.ExecuteAsync("remove_clips",
            $$"""{"clipIds":["{{clip.Id}}"]}""");
        Assert.False(result.IsError);
        Assert.Empty(host.Timeline.Tracks[0].Clips);
    }

    [Fact]
    public async Task UnknownToolIsError()
    {
        var executor = new ToolExecutor(new FakeAgentHost());
        var result = await executor.ExecuteAsync("not_a_tool", "{}");
        Assert.True(result.IsError);
    }

    [Fact]
    public async Task AddClipsPlacesOnTimeline()
    {
        var host = new FakeAgentHost();
        host.Manifest.Entries.Add(new MediaManifestEntry
        {
            Id = "abc123",
            Name = "clip.mp4",
            Type = ClipType.Video,
            Source = new MediaSource.Project("media/clip.mp4"),
            Duration = 3,
            HasAudio = true,
        });
        var executor = new ToolExecutor(host);
        var result = await executor.ExecuteAsync("add_clips",
            """{"entries":[{"mediaRef":"abc123","trackIndex":0,"startFrame":0,"endFrame":90}]}""");
        Assert.False(result.IsError);
        Assert.NotEmpty(host.Timeline.Tracks[0].Clips);
        Assert.Equal(90, host.Timeline.Tracks[0].Clips[0].DurationFrames);
    }

    [Fact]
    public async Task ImportAndOrganizeAndDuplicateTimelineWork()
    {
        var host = new FakeAgentHost();
        var executor = new ToolExecutor(host);
        var imported = await executor.ExecuteAsync("import_media",
            """{"paths":["C:\\\\media\\\\a.mp4"]}""");
        Assert.False(imported.IsError);

        var org = await executor.ExecuteAsync("organize_media",
            """{"createFolders":[{"name":"B-roll"}]}""");
        Assert.False(org.IsError);
        Assert.NotEmpty(host.Manifest.Folders);

        var dup = await executor.ExecuteAsync("create_timeline",
            $$"""{"from":"{{host.Timeline.Id}}","name":"Copy"}""");
        Assert.False(dup.IsError);
        Assert.Equal(2, host.Timelines.Count);
    }

    [Fact]
    public async Task PreviouslyStubbedToolsAreWired()
    {
        var host = new FakeAgentHost();
        var executor = new ToolExecutor(host);
        Assert.False((await executor.ExecuteAsync("capture_frame", """{"timelineFrame":0}""")).IsError);
        Assert.False((await executor.ExecuteAsync("inspect_color", """{"mediaRef":"x"}""")).IsError);
        Assert.False((await executor.ExecuteAsync("sync_clips",
            """{"referenceClipId":"a","targetClipIds":["b"]}""")).IsError);
    }

    [Fact]
    public async Task ExportProjectRefusesProResOnWindows()
    {
        var executor = new ToolExecutor(new FakeAgentHost());
        var result = await executor.ExecuteAsync("export_project",
            """{"mode":"video","codec":"prores"}""");
        Assert.True(result.IsError);
        Assert.Contains("ProRes", result.Content);
        Assert.DoesNotContain("not yet implemented", result.Content, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task UpdateTextMutatesTextClip()
    {
        var host = new FakeAgentHost();
        var clip = new Clip
        {
            MediaRef = "text",
            MediaType = ClipType.Text,
            TextContent = "Hello",
            StartFrame = 0,
            DurationFrames = 30,
        };
        host.Timeline.Tracks[0].Clips.Add(clip);
        var executor = new ToolExecutor(host);
        var result = await executor.ExecuteAsync("update_text",
            $$"""{"clipIds":["{{clip.Id}}"],"content":"World"}""");
        Assert.False(result.IsError);
        Assert.Equal("World", clip.TextContent);
    }

    [Fact]
    public async Task ManageMulticamCreateNeedsMembers()
    {
        var host = new FakeAgentHost();
        host.Manifest.Entries.Add(new MediaManifestEntry
        {
            Id = "camA", Name = "A", Type = ClipType.Video,
            Source = new MediaSource.External("a.mp4"), Duration = 5,
        });
        host.Manifest.Entries.Add(new MediaManifestEntry
        {
            Id = "camB", Name = "B", Type = ClipType.Video,
            Source = new MediaSource.External("b.mp4"), Duration = 5,
        });
        var executor = new ToolExecutor(host);
        var result = await executor.ExecuteAsync("manage_multicam",
            """{"create":{"name":"Interview","members":[{"mediaRef":"camA"},{"mediaRef":"camB"}]}}""");
        Assert.False(result.IsError);
        Assert.Single(host.MulticamGroups);
    }

    [Fact]
    public async Task NoToolFallsThroughToNotYetImplementedStub()
    {
        var host = new FakeAgentHost();
        var executor = new ToolExecutor(host);
        foreach (ToolName tool in Enum.GetValues<ToolName>())
        {
            var result = await executor.ExecuteAsync(tool.ApiName(), "{}");
            Assert.DoesNotContain(
                "registered but not yet implemented",
                result.Content,
                StringComparison.OrdinalIgnoreCase);
        }
    }
}
