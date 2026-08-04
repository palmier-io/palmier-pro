using System.Text.Json;
using PalmierPro.Agent.Tools;
using PalmierPro.Core.Models;
using PalmierPro.Core.Settings;
using Xunit;

namespace PalmierPro.Agent.Tests;

/// <summary>
/// Broad headless coverage of Agent/editor filmmaker flows (no WinUI).
/// </summary>
public class FilmmakerFlowsE2ETests
{
    [Fact]
    public async Task ImportAddSplitRippleDelete_KeepsTimelineConsistent()
    {
        var host = new FakeAgentHost();
        var executor = new ToolExecutor(host);

        var imported = await executor.ExecuteAsync("import_media",
            """{"paths":["C:\\\\media\\\\flow.mp4"]}""");
        Assert.False(imported.IsError, imported.Content);

        var mediaRef = host.Manifest.Entries.FirstOrDefault()?.Id;
        Assert.False(string.IsNullOrEmpty(mediaRef));

        var add = await executor.ExecuteAsync("add_clips",
            $$"""{"entries":[{"mediaRef":"{{mediaRef}}","startFrame":0,"endFrame":90}]}""");
        Assert.False(add.IsError, add.Content);

        var clipId = host.Timeline.Tracks.SelectMany(t => t.Clips).First().Id;
        var split = await executor.ExecuteAsync("split_clips",
            $$"""{"splits":[{"clipId":"{{clipId}}","atFrame":30}]}""");
        Assert.False(split.IsError, split.Content);

        var ids = host.Timeline.Tracks.SelectMany(t => t.Clips).Select(c => c.Id).ToArray();
        Assert.True(ids.Length >= 2);

        var ripple = await executor.ExecuteAsync("remove_clips",
            $$"""{"clipIds":["{{ids[0]}}"],"ripple":true}""");
        Assert.False(ripple.IsError, ripple.Content);

        var tl = await executor.ExecuteAsync("get_timeline", "{}");
        Assert.False(tl.IsError, tl.Content);
        using var doc = JsonDocument.Parse(tl.Content);
        Assert.True(doc.RootElement.TryGetProperty("tracks", out _));
    }

    [Fact]
    public async Task ProjectSettings_Effects_ExportRefuseProRes()
    {
        var host = new FakeAgentHost();
        host.Manifest.Entries.Add(new MediaManifestEntry
        {
            Id = "m1",
            Name = "A",
            Type = ClipType.Video,
            Source = new MediaSource.External("a.mp4"),
            Duration = 2,
        });
        var executor = new ToolExecutor(host);

        Assert.False((await executor.ExecuteAsync("add_clips",
            """{"entries":[{"mediaRef":"m1","startFrame":0,"endFrame":60}]}""")).IsError);
        Assert.False((await executor.ExecuteAsync("set_project_settings",
            """{"fps":24,"aspectRatio":"16:9"}""")).IsError);

        var clipId = host.Timeline.Tracks.SelectMany(t => t.Clips).First().Id;
        Assert.False((await executor.ExecuteAsync("apply_effect",
            "{\"clipIds\":[\"" + clipId + "\"],\"effects\":[{\"type\":\"blur.gaussian\",\"params\":{\"radius\":4}}]}")).IsError);

        var tracks = await executor.ExecuteAsync("manage_tracks", """{"action":"add","type":"video"}""");
        Assert.False(tracks.IsError, tracks.Content);

        var export = await executor.ExecuteAsync("export_project",
            """{"mode":"video","codec":"prores"}""");
        Assert.True(export.IsError);
        Assert.Contains("ProRes", export.Content);
    }

    [Fact]
    public async Task AppearanceSetting_DoesNotBreakSubsequentEdits()
    {
        var settingsPath = Path.Combine(Path.GetTempPath(), "palmier-app-" + Guid.NewGuid().ToString("N") + ".json");
        try
        {
            var store = new SettingsStore(settingsPath);
            store.Update(s => s.AppAppearance = AppAppearance.Normalize("light"));
            store.Update(s => s.AppAppearance = AppAppearance.Normalize("dark"));
            Assert.Equal("dark", store.Current.AppAppearance);

            var host = new FakeAgentHost();
            host.Manifest.Entries.Add(new MediaManifestEntry
            {
                Id = "m1",
                Name = "A",
                Type = ClipType.Video,
                Source = new MediaSource.External("a.mp4"),
                Duration = 1,
            });
            var executor = new ToolExecutor(host);
            var add = await executor.ExecuteAsync("add_clips",
                """{"entries":[{"mediaRef":"m1","startFrame":0,"endFrame":30}]}""");
            Assert.False(add.IsError, add.Content);
            Assert.NotEmpty(host.Timeline.Tracks.SelectMany(t => t.Clips));
        }
        finally
        {
            try { File.Delete(settingsPath); } catch { /* ignore */ }
        }
    }
}
