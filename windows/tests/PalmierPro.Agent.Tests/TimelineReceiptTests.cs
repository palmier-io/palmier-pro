using System.Text.Json;
using PalmierPro.Agent.Tools;
using PalmierPro.Core.Models;
using Xunit;

namespace PalmierPro.Agent.Tests;

public class TimelineReceiptTests
{
    [Fact]
    public async Task GetTimelineIncludesFramesGapsAndLinkedFold()
    {
        var host = new FakeAgentHost();
        var link = Guid.NewGuid().ToString("N");
        var video = new Clip
        {
            MediaRef = "v1",
            MediaType = ClipType.Video,
            StartFrame = 0,
            DurationFrames = 60,
            LinkGroupId = link,
        };
        var audio = new Clip
        {
            MediaRef = "v1",
            MediaType = ClipType.Audio,
            StartFrame = 0,
            DurationFrames = 60,
            LinkGroupId = link,
        };
        var later = new Clip
        {
            MediaRef = "v2",
            MediaType = ClipType.Video,
            StartFrame = 120,
            DurationFrames = 30,
        };
        host.Timeline.Tracks[0].Clips.Add(video);
        host.Timeline.Tracks[0].Clips.Add(later);
        host.Timeline.Tracks[1].Clips.Add(audio);

        var executor = new ToolExecutor(host);
        var result = await executor.ExecuteAsync("get_timeline", "{}");
        Assert.False(result.IsError, result.Content);

        using var doc = JsonDocument.Parse(result.Content);
        var tracks = doc.RootElement.GetProperty("tracks");
        Assert.True(tracks.GetArrayLength() >= 2);

        var vTrack = tracks.EnumerateArray().First(t => t.GetProperty("type").GetString() == "video");
        Assert.True(vTrack.TryGetProperty("gaps", out var gaps));
        Assert.True(gaps.GetArrayLength() >= 1);
        Assert.Equal(60, gaps[0][0].GetInt32());
        Assert.Equal(120, gaps[0][1].GetInt32());

        var clips = vTrack.GetProperty("clips");
        Assert.True(clips.GetArrayLength() >= 1);
        var first = clips[0];
        Assert.True(first.TryGetProperty("frames", out var frames));
        Assert.Equal(0, frames[0].GetInt32());
        Assert.Equal(60, frames[1].GetInt32());
        Assert.True(first.TryGetProperty("audio", out _), "Linked audio should fold under the video clip");

        var aTrack = tracks.EnumerateArray().First(t => t.GetProperty("type").GetString() == "audio");
        if (aTrack.TryGetProperty("clips", out var aClips))
            Assert.Equal(0, aClips.GetArrayLength());
        Assert.True(aTrack.TryGetProperty("linkedClips", out var linked) && linked.GetInt32() >= 1);
    }
}
