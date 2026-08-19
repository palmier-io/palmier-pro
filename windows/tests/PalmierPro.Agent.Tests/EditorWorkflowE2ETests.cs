using System.Text.Json;
using PalmierPro.Agent.Tools;
using PalmierPro.Core;
using PalmierPro.Core.Models;
using PalmierPro.Core.Project;
using PalmierPro.Core.Serialization;
using PalmierPro.Core.Settings;
using Xunit;

namespace PalmierPro.Agent.Tests;

/// <summary>
/// Headless E2E: package create → agent edits → settings → timeline receipt.
/// Covers the filmmaker path without WinUI.
/// </summary>
public class EditorWorkflowE2ETests
{
    [Fact]
    public async Task CreateProject_AddClip_SetSettings_GetTimeline()
    {
        var dir = Path.Combine(Path.GetTempPath(), "palmier-e2e-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        try
        {
            var package = Path.Combine(dir, "Demo.palmier");
            var timeline = new Timeline { Fps = 30, Width = 1920, Height = 1080 };
            var file = new ProjectFile
            {
                Timelines = [timeline],
                ActiveTimelineId = timeline.Id,
                OpenTimelineIds = [timeline.Id],
            };
            ProjectPackage.Write(new ProjectPackageSnapshot
            {
                Timeline = PalmierJson.Encode(file),
                Manifest = PalmierJson.Encode(new MediaManifest()),
            }, package, sourcePath: null);

            Assert.True(Directory.Exists(package));
            Assert.True(File.Exists(Path.Combine(package, ProjectConstants.TimelineFilename)));

            var host = new FakeAgentHost();
            // Seed media + place a clip like import + add_clips.
            host.Manifest.Entries.Add(new MediaManifestEntry
            {
                Id = "media1",
                Name = "ClipA",
                Type = ClipType.Video,
                Source = new MediaSource.External(Path.Combine(dir, "a.mp4")),
                Duration = 2,
            });
            var executor = new ToolExecutor(host);

            var add = await executor.ExecuteAsync("add_clips", """
                {"entries":[{"mediaRef":"media1","startFrame":0,"endFrame":60}]}
                """);
            Assert.False(add.IsError, add.Content);

            var settings = await executor.ExecuteAsync("set_project_settings", """
                {"fps":24,"aspectRatio":"16:9"}
                """);
            Assert.False(settings.IsError, settings.Content);

            var tl = await executor.ExecuteAsync("get_timeline", "{}");
            Assert.False(tl.IsError, tl.Content);
            using var doc = JsonDocument.Parse(tl.Content);
            Assert.Equal(24, doc.RootElement.GetProperty("fps").GetInt32());
            Assert.True(doc.RootElement.GetProperty("tracks").GetArrayLength() >= 1);
        }
        finally
        {
            try { Directory.Delete(dir, true); } catch { /* best-effort */ }
        }
    }

    [Fact]
    public async Task NestUnnest_ViaOrganizeMedia_RoundTrips()
    {
        var host = new FakeAgentHost();
        host.Manifest.Entries.Add(new MediaManifestEntry
        {
            Id = "v1",
            Name = "V",
            Type = ClipType.Video,
            Source = new MediaSource.External("v.mp4"),
            Duration = 1,
        });
        var executor = new ToolExecutor(host);
        var add = await executor.ExecuteAsync("add_clips", """
            {"entries":[{"mediaRef":"v1","startFrame":0,"endFrame":30}]}
            """);
        Assert.False(add.IsError, add.Content);

        var clipId = host.Timeline.Tracks.SelectMany(t => t.Clips).FirstOrDefault()?.Id;
        Assert.False(string.IsNullOrEmpty(clipId));

        var nest = await executor.ExecuteAsync("organize_media",
            $$"""{"action":"nest","clipIds":["{{clipId}}"]}""");
        Assert.False(nest.IsError, nest.Content);

        var sequence = host.Timeline.Tracks.SelectMany(t => t.Clips)
            .FirstOrDefault(c => c.MediaType == ClipType.Sequence);
        Assert.NotNull(sequence);

        var unnest = await executor.ExecuteAsync("organize_media",
            $$"""{"action":"unnest","clipIds":["{{sequence!.Id}}"]}""");
        Assert.False(unnest.IsError, unnest.Content);
    }

    [Fact]
    public void SettingsStore_PersistsAndReloads()
    {
        var path = Path.Combine(Path.GetTempPath(), "palmier-settings-e2e-" + Guid.NewGuid().ToString("N") + ".json");
        try
        {
            var store = new SettingsStore(path);
            store.Update(s =>
            {
                s.AppLanguage = "fr";
                s.McpEnabled = false;
                s.WhisperModelSize = "base";
            });

            var reloaded = new SettingsStore(path);
            Assert.Equal("fr", reloaded.Current.AppLanguage);
            Assert.False(reloaded.Current.McpEnabled);
            Assert.Equal("base", reloaded.Current.WhisperModelSize);
        }
        finally
        {
            try { File.Delete(path); } catch { /* ignore */ }
        }
    }
}
