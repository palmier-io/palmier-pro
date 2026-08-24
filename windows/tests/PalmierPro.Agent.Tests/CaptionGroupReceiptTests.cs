using System.Text.Json;
using PalmierPro.Agent.Tools;
using PalmierPro.Core.Models;
using Xunit;

namespace PalmierPro.Agent.Tests;

public class CaptionGroupReceiptTests
{
    [Fact]
    public async Task GetTimeline_FoldsModalCaptions_KeepsStyleDeviantsLoose()
    {
        var host = new FakeAgentHost();
        var gid = Guid.NewGuid().ToString("N");
        var sharedStyle = new TextStyle { FontSize = 48 };
        var deviantStyle = new TextStyle { FontSize = 96 };

        host.Timeline.Tracks[0].Clips.Add(new Clip
        {
            MediaRef = "caption",
            MediaType = ClipType.Text,
            StartFrame = 0,
            DurationFrames = 20,
            TextContent = "One",
            CaptionGroupId = gid,
            TextStyle = sharedStyle,
        });
        host.Timeline.Tracks[0].Clips.Add(new Clip
        {
            MediaRef = "caption",
            MediaType = ClipType.Text,
            StartFrame = 20,
            DurationFrames = 20,
            TextContent = "Two",
            CaptionGroupId = gid,
            TextStyle = sharedStyle.Clone(),
        });
        host.Timeline.Tracks[0].Clips.Add(new Clip
        {
            MediaRef = "caption",
            MediaType = ClipType.Text,
            StartFrame = 40,
            DurationFrames = 20,
            TextContent = "Big",
            CaptionGroupId = gid,
            TextStyle = deviantStyle,
        });

        var executor = new ToolExecutor(host);
        var result = await executor.ExecuteAsync("get_timeline", "{}");
        Assert.False(result.IsError, result.Content);

        using var doc = JsonDocument.Parse(result.Content);
        var track = doc.RootElement.GetProperty("tracks")[0];
        Assert.True(track.TryGetProperty("captionGroups", out var groups));
        Assert.Equal(1, groups.GetArrayLength());
        Assert.Equal(2, groups[0].GetProperty("clipCount").GetInt32());
        Assert.True(groups[0].TryGetProperty("shared", out _));

        Assert.True(track.TryGetProperty("clips", out var clips));
        Assert.Equal(1, clips.GetArrayLength());
        Assert.Equal("Big", clips[0].GetProperty("textContent").GetString());
    }
}
