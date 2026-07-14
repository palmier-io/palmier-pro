using PalmierPro.Core.Models;
using Shouldly;
using Xunit;

namespace PalmierPro.Core.Tests;

/// Mirrors Tests/PalmierProTests/Media/MediaResolverTests.swift.
public class MediaResolverTests
{
    private static MediaManifestEntry Entry(string id, MediaSource source, string name = "X") =>
        new(id, name, ClipType.Video, source, duration: 1);

    private static string MakeTempFile()
    {
        var path = Path.Combine(Path.GetTempPath(), $"f-{Guid.NewGuid()}.mp4");
        File.WriteAllBytes(path, []);
        return path;
    }

    // MARK: - Entry(for:)

    [Fact]
    public void EntryReturnsMatchingEntry()
    {
        var manifest = new MediaManifest { Entries = [Entry("a", MediaSource.External("/tmp/a"))] };
        var resolver = new MediaResolver(() => manifest, () => null);
        resolver.Entry("a")!.Id.ShouldBe("a");
    }

    [Fact]
    public void EntryReturnsNullWhenMissing()
    {
        var resolver = new MediaResolver(() => new MediaManifest(), () => null);
        resolver.Entry("ghost").ShouldBeNull();
    }

    // MARK: - DisplayName

    [Fact]
    public void DisplayNameReturnsEntryName()
    {
        var manifest = new MediaManifest { Entries = [Entry("a", MediaSource.External("/tmp/a"), name: "Hello")] };
        var resolver = new MediaResolver(() => manifest, () => null);
        resolver.DisplayName("a").ShouldBe("Hello");
    }

    [Fact]
    public void DisplayNameFallsBackToOfflineWhenMissing()
    {
        var resolver = new MediaResolver(() => new MediaManifest(), () => null);
        resolver.DisplayName("ghost").ShouldBe("Offline");
    }

    // MARK: - ResolveUrl: external source

    [Fact]
    public void ResolveExternalReturnsUrlWhenFileExists()
    {
        var file = MakeTempFile();
        try
        {
            var manifest = new MediaManifest { Entries = [Entry("a", MediaSource.External(file))] };
            var resolver = new MediaResolver(() => manifest, () => null);
            resolver.ResolveUrl("a").ShouldBe(file);
        }
        finally
        {
            File.Delete(file);
        }
    }

    [Fact]
    public void ResolveExternalReturnsNullWhenFileMissing()
    {
        var manifest = new MediaManifest { Entries = [Entry("a", MediaSource.External($"/tmp/does-not-exist-{Guid.NewGuid()}"))] };
        var resolver = new MediaResolver(() => manifest, () => null);
        resolver.ResolveUrl("a").ShouldBeNull();
    }

    // MARK: - ResolveUrl: project-relative source

    [Fact]
    public void ResolveProjectAppendsRelativePathToProjectPath()
    {
        var projectDir = Path.Combine(Path.GetTempPath(), $"proj-{Guid.NewGuid()}");
        var inner = Path.Combine(projectDir, "media", "asset.mp4");
        Directory.CreateDirectory(Path.GetDirectoryName(inner)!);
        File.WriteAllBytes(inner, []);
        try
        {
            var manifest = new MediaManifest { Entries = [Entry("a", MediaSource.Project(Path.Combine("media", "asset.mp4")))] };
            var resolver = new MediaResolver(() => manifest, () => projectDir);
            resolver.ResolveUrl("a").ShouldBe(inner);
        }
        finally
        {
            Directory.Delete(projectDir, recursive: true);
        }
    }

    [Fact]
    public void ResolveProjectReturnsNullWhenProjectPathIsNull()
    {
        var manifest = new MediaManifest { Entries = [Entry("a", MediaSource.Project("media/asset.mp4"))] };
        var resolver = new MediaResolver(() => manifest, () => null);
        resolver.ResolveUrl("a").ShouldBeNull();
    }

    // MARK: - MissingAssetIds

    [Fact]
    public void MissingAssetIdsFlagsExternalMissingAndKeepsPresent()
    {
        var present = MakeTempFile();
        try
        {
            var entries = new[]
            {
                Entry("present", MediaSource.External(present)),
                Entry("gone", MediaSource.External($"/tmp/missing-{Guid.NewGuid()}")),
            };
            var missing = MediaResolver.MissingAssetIds(entries, null);
            missing.ShouldBe(["gone"]);
        }
        finally
        {
            File.Delete(present);
        }
    }

    [Fact]
    public void MissingAssetIdsResolvesProjectRelativePaths()
    {
        var projectDir = Path.Combine(Path.GetTempPath(), $"proj-{Guid.NewGuid()}");
        var inner = Path.Combine(projectDir, "media", "asset.mp4");
        Directory.CreateDirectory(Path.GetDirectoryName(inner)!);
        File.WriteAllBytes(inner, []);
        try
        {
            var entries = new[] { Entry("a", MediaSource.Project(Path.Combine("media", "asset.mp4"))) };
            MediaResolver.MissingAssetIds(entries, projectDir).ShouldBeEmpty();
            // No project base path -> project-relative entry cannot resolve -> missing.
            MediaResolver.MissingAssetIds(entries, null).ShouldBe(["a"]);
        }
        finally
        {
            Directory.Delete(projectDir, recursive: true);
        }
    }

    // MARK: - Live-manifest reads (resolver always reflects the CURRENT manifest state)

    [Fact]
    public void ReflectsReplacedEntryAtSameCount()
    {
        var manifest = new MediaManifest { Entries = [Entry("a", MediaSource.External("/tmp/a")), Entry("b", MediaSource.External("/tmp/b"))] };
        var resolver = new MediaResolver(() => manifest, () => null);
        _ = resolver.Entry("a");

        manifest.Entries = [Entry("a", MediaSource.External("/tmp/a")), Entry("c", MediaSource.External("/tmp/c"))];
        resolver.Entry("c")!.Id.ShouldBe("c");
        resolver.Entry("b").ShouldBeNull();
    }

    [Fact]
    public void ReflectsRenamedEntryAtSameCount()
    {
        var manifest = new MediaManifest { Entries = [Entry("a", MediaSource.External("/tmp/a"), name: "First")] };
        var resolver = new MediaResolver(() => manifest, () => null);
        _ = resolver.Entry("a");

        manifest.Entries = [Entry("a", MediaSource.External("/tmp/a"), name: "Renamed")];
        resolver.Entry("a")!.Name.ShouldBe("Renamed");
    }

    // MARK: - IsMissing / ExpectedUrlMap / Snapshot

    [Fact]
    public void IsMissingTrueForUnknownAsset()
    {
        var resolver = new MediaResolver(() => new MediaManifest(), () => null);
        resolver.IsMissing("ghost").ShouldBeTrue();
    }

    [Fact]
    public void ExpectedUrlMapCoversOnlyResolvableEntries()
    {
        var manifest = new MediaManifest
        {
            Entries = [Entry("a", MediaSource.External("/tmp/a")), Entry("b", MediaSource.Project("media/b.mp4"))],
        };
        var resolver = new MediaResolver(() => manifest, () => null); // no project path -> "b" unresolvable
        var map = resolver.ExpectedUrlMap();
        map.ShouldContainKey("a");
        map.ShouldNotContainKey("b");
    }

    [Fact]
    public void SnapshotFreezesManifestAtCallTime()
    {
        var manifest = new MediaManifest { Entries = [Entry("a", MediaSource.External("/tmp/a"))] };
        var resolver = new MediaResolver(() => manifest, () => null);
        var snapshot = resolver.Snapshot();

        manifest.Entries = [];
        snapshot.Entry("a")!.Id.ShouldBe("a"); // snapshot is unaffected by later mutation
        resolver.Entry("a").ShouldBeNull(); // live resolver reflects the mutation
    }
}
