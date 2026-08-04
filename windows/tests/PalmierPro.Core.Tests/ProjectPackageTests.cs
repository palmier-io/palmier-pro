using PalmierPro.Core;
using PalmierPro.Core.Models;
using PalmierPro.Core.Project;
using PalmierPro.Core.Serialization;
using Xunit;

namespace PalmierPro.Core.Tests;

public class ProjectPackageTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), $"palmier-tests-{Guid.NewGuid():N}");

    public ProjectPackageTests() => Directory.CreateDirectory(_root);

    public void Dispose()
    {
        try
        {
            Directory.Delete(_root, recursive: true);
        }
        catch
        {
            // Temp cleanup is best-effort.
        }
    }

    private string PackagePath(string name) => Path.Combine(_root, $"{name}.palmier");

    private static ProjectFile SampleProject() => new()
    {
        Timelines =
        [
            new Timeline
            {
                Id = "T1",
                Name = "Main",
                Tracks = [new Track { Type = ClipType.Video, Clips = [new Clip { MediaRef = "A", StartFrame = 0, DurationFrames = 60 }] }],
            },
        ],
        ActiveTimelineId = "T1",
    };

    [Fact]
    public void WriteThenReadRoundTripsPackage()
    {
        var package = PackagePath("roundtrip");
        var manifest = new MediaManifest
        {
            Entries =
            [
                new MediaManifestEntry
                {
                    Id = "A",
                    Name = "clip.mp4",
                    Type = ClipType.Video,
                    Source = new MediaSource.Project("media/clip.mp4"),
                    Duration = 2.5,
                },
            ],
        };

        ProjectPackage.Write(new ProjectPackageSnapshot
        {
            Timeline = PalmierJson.Encode(SampleProject()),
            Manifest = PalmierJson.Encode(manifest),
            Thumbnail = [1, 2, 3],
            ChatSessionFiles = [("S1.json", "{}"u8.ToArray())],
        }, package, sourcePath: null);

        Assert.True(File.Exists(Path.Combine(package, ProjectConstants.TimelineFilename)));
        Assert.True(File.Exists(Path.Combine(package, ProjectConstants.ManifestFilename)));
        Assert.True(File.Exists(Path.Combine(package, ProjectConstants.ThumbnailFilename)));
        Assert.True(Directory.Exists(Path.Combine(package, ProjectConstants.MediaDirectoryName)));
        Assert.True(File.Exists(Path.Combine(package, ProjectConstants.ChatDirectoryName, "S1.json")));

        var contents = ProjectPackage.Read(package);
        Assert.Equal("T1", contents.ProjectFile.ActiveTimelineId);
        Assert.Equal("A", contents.Manifest!.Entries[0].Id);
        Assert.False(contents.ManifestUnreadable);
    }

    [Fact]
    public void ReadMissingProjectJsonThrows()
    {
        var package = PackagePath("missing");
        Directory.CreateDirectory(package);
        Assert.ThrowsAny<IOException>(() => ProjectPackage.Read(package));
    }

    [Fact]
    public void CorruptManifestDegradesToUnreadableWithoutLosingProject()
    {
        var package = PackagePath("corrupt-manifest");
        Directory.CreateDirectory(package);
        File.WriteAllBytes(Path.Combine(package, ProjectConstants.TimelineFilename), PalmierJson.Encode(SampleProject()));
        File.WriteAllText(Path.Combine(package, ProjectConstants.ManifestFilename), "{ not json");

        var contents = ProjectPackage.Read(package);
        Assert.Null(contents.Manifest);
        Assert.True(contents.ManifestUnreadable);
        Assert.Single(contents.ProjectFile.Timelines);
    }

    [Fact]
    public void SaveWithoutManifestPreservesExistingManifestFile()
    {
        var package = PackagePath("preserve");
        ProjectPackage.Write(new ProjectPackageSnapshot
        {
            Timeline = PalmierJson.Encode(SampleProject()),
            Manifest = "{ \"version\": 2, \"entries\": [], \"folders\": [] }"u8.ToArray(),
        }, package, sourcePath: null);

        // Second save with no manifest snapshot (unreadable-manifest path) must keep the file.
        ProjectPackage.Write(new ProjectPackageSnapshot
        {
            Timeline = PalmierJson.Encode(SampleProject()),
            Manifest = null,
        }, package, sourcePath: package);

        Assert.True(File.Exists(Path.Combine(package, ProjectConstants.ManifestFilename)));
    }

    [Fact]
    public void SaveAsCopiesMediaAndPreservedFilesFromSource()
    {
        var source = PackagePath("original");
        ProjectPackage.Write(new ProjectPackageSnapshot
        {
            Timeline = PalmierJson.Encode(SampleProject()),
            Manifest = PalmierJson.Encode(new MediaManifest()),
            Thumbnail = [9, 9, 9],
        }, source, sourcePath: null);
        File.WriteAllBytes(Path.Combine(source, ProjectConstants.MediaDirectoryName, "clip.mp4"), [7, 7]);

        var destination = PackagePath("copy");
        ProjectPackage.Write(new ProjectPackageSnapshot
        {
            Timeline = PalmierJson.Encode(SampleProject()),
            Manifest = null,
            Thumbnail = null,
        }, destination, sourcePath: source);

        Assert.True(File.Exists(Path.Combine(destination, ProjectConstants.ManifestFilename)));
        Assert.True(File.Exists(Path.Combine(destination, ProjectConstants.ThumbnailFilename)));
        Assert.Equal([7, 7], File.ReadAllBytes(Path.Combine(destination, ProjectConstants.MediaDirectoryName, "clip.mp4")));
    }

    [Fact]
    public void ChatDirectoryIsReplacedNotMerged()
    {
        var package = PackagePath("chat");
        ProjectPackage.Write(new ProjectPackageSnapshot
        {
            Timeline = PalmierJson.Encode(SampleProject()),
            ChatSessionFiles = [("old.json", "{}"u8.ToArray())],
        }, package, sourcePath: null);

        ProjectPackage.Write(new ProjectPackageSnapshot
        {
            Timeline = PalmierJson.Encode(SampleProject()),
            ChatSessionFiles = [("new.json", "{}"u8.ToArray())],
        }, package, sourcePath: package);

        Assert.False(File.Exists(Path.Combine(package, ProjectConstants.ChatDirectoryName, "old.json")));
        Assert.True(File.Exists(Path.Combine(package, ProjectConstants.ChatDirectoryName, "new.json")));
    }

    [Fact]
    public async Task RegistryRegistersUpdatesAndPersists()
    {
        var registryPath = Path.Combine(_root, "registry.json");
        var registry = new ProjectRegistry(registryPath);
        await registry.LoadAsync();

        var projectA = PackagePath("a");
        Directory.CreateDirectory(projectA);
        await registry.RegisterAsync(projectA);
        Assert.Single(registry.Entries);

        // Re-registering bumps lastOpened instead of duplicating.
        await registry.RegisterAsync(projectA);
        Assert.Single(registry.Entries);

        var renamed = PackagePath("a-renamed");
        await registry.UpdatePathAsync(projectA, renamed);
        Assert.Equal(Path.GetFullPath(renamed), registry.Entries[0].Path);
        Assert.Equal("a-renamed", registry.Entries[0].Name);

        // A fresh instance reads the same state back from disk.
        var reloaded = new ProjectRegistry(registryPath);
        await reloaded.LoadAsync();
        Assert.Single(reloaded.Entries);
        Assert.Equal(registry.Entries[0].Id, reloaded.Entries[0].Id);

        // Registry file uses the Swift shape: file URL string + uppercase UUID.
        var raw = await File.ReadAllTextAsync(registryPath);
        Assert.Contains("\"url\":\"file:///", raw);
        Assert.Contains(registry.Entries[0].Id.ToString("D").ToUpperInvariant(), raw);
    }

    [Fact]
    public async Task RegistryRemoveDropsEntry()
    {
        var registryPath = Path.Combine(_root, "registry-remove.json");
        var registry = new ProjectRegistry(registryPath);
        await registry.LoadAsync();

        var project = PackagePath("gone");
        await registry.RegisterAsync(project);
        await registry.RemoveAsync(project);
        Assert.Empty(registry.Entries);
    }
}
