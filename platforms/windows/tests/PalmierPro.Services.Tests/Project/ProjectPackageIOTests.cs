using System.Text.Json;
using PalmierPro.Core.Models;
using PalmierPro.Services.Project;
using Shouldly;
using Xunit;

namespace PalmierPro.Services.Tests;

public class ProjectPackageIOTests
{
    private static ProjectPackageSnapshot SnapshotFor(Timeline timeline, byte[]? manifest = null, byte[]? generationLog = null, byte[]? thumbnail = null) =>
        new(
            JsonSerializer.SerializeToUtf8Bytes(new ProjectFile([timeline], timeline.Id, [timeline.Id])),
            manifest,
            generationLog,
            thumbnail,
            []);

    [Fact]
    public void Load_MissingTimelineFile_ThrowsCorrupt()
    {
        using var tmp = new TempDirectory();
        var packageDir = Path.Combine(tmp.Path, "Empty.palmier");
        Directory.CreateDirectory(packageDir);

        Should.Throw<ProjectPackageCorruptException>(() => ProjectPackageIO.Load(packageDir));
    }

    [Fact]
    public void Load_CorruptManifest_ReturnsNullManifestButFlagsUnreadable()
    {
        using var tmp = new TempDirectory();
        var packageDir = Path.Combine(tmp.Path, "Corrupt.palmier");
        Directory.CreateDirectory(packageDir);
        var timeline = TestFixtures.Timeline();
        ProjectPackageIO.Write(SnapshotFor(timeline), packageDir, null);
        File.WriteAllBytes(ProjectPackage.ManifestPath(packageDir), "not json"u8.ToArray());

        var contents = ProjectPackageIO.Load(packageDir);

        contents.Manifest.ShouldBeNull();
        contents.ManifestUnreadable.ShouldBeTrue();
        contents.ProjectFile.Timelines.Count.ShouldBe(1);
    }

    [Fact]
    public void Write_OverExistingPackage_ReplacesTimelineFileContents()
    {
        using var tmp = new TempDirectory();
        var packageDir = Path.Combine(tmp.Path, "Replace.palmier");
        var first = TestFixtures.Timeline();
        first.Name = "First";
        ProjectPackageIO.Write(SnapshotFor(first), packageDir, null);

        var second = TestFixtures.Timeline();
        second.Name = "Second";
        ProjectPackageIO.Write(SnapshotFor(second), packageDir, packageDir);

        var reloaded = ProjectPackageIO.Load(packageDir);
        reloaded.ProjectFile.Timelines[0].Name.ShouldBe("Second");
    }

    [Fact]
    public void Write_NoManifestBytes_PreservesSourcePackagesManifest()
    {
        using var tmp = new TempDirectory();
        var sourceDir = Path.Combine(tmp.Path, "Source.palmier");
        var timeline = TestFixtures.Timeline();
        var manifestBytes = JsonSerializer.SerializeToUtf8Bytes(new MediaManifest
        {
            Entries = [new MediaManifestEntry("a", "Clip", ClipType.Video, MediaSource.Project("media/a.mov"), 1.0)],
        });
        ProjectPackageIO.Write(SnapshotFor(timeline, manifest: manifestBytes), sourceDir, null);

        var destDir = Path.Combine(tmp.Path, "Dest.palmier");
        ProjectPackageIO.Write(SnapshotFor(timeline, manifest: null), destDir, sourceDir);

        File.Exists(ProjectPackage.ManifestPath(destDir)).ShouldBeTrue();
        var reloaded = ProjectPackageIO.Load(destDir);
        reloaded.Manifest!.Entries.Count.ShouldBe(1);
    }

    [Fact]
    public void Write_CopiesMediaDirectoryFromSourceWhenDestinationDiffers()
    {
        using var tmp = new TempDirectory();
        var sourceDir = Path.Combine(tmp.Path, "Source.palmier");
        Directory.CreateDirectory(Path.Combine(sourceDir, "media"));
        File.WriteAllBytes(Path.Combine(sourceDir, "media", "a.mov"), [1, 2, 3]);
        ProjectPackageIO.Write(SnapshotFor(TestFixtures.Timeline()), sourceDir, null);

        var destDir = Path.Combine(tmp.Path, "Dest.palmier");
        ProjectPackageIO.Write(SnapshotFor(TestFixtures.Timeline()), destDir, sourceDir);

        File.Exists(Path.Combine(destDir, "media", "a.mov")).ShouldBeTrue();
    }

    [Theory]
    [InlineData(true, 0, 0, true)]
    [InlineData(false, 0, 0, false)]
    [InlineData(true, 1, 0, false)]
    public void ManifestSnapshot_OnlySuppressesWriteWhenLoadFailedAndEmpty(bool loadFailed, int entryCount, int folderCount, bool expectNull)
    {
        var manifest = new MediaManifest
        {
            Entries = Enumerable.Range(0, entryCount)
                .Select(i => new MediaManifestEntry($"e{i}", "x", ClipType.Video, MediaSource.External("x"), 1.0))
                .ToList(),
            Folders = Enumerable.Range(0, folderCount).Select(i => new MediaFolder($"f{i}")).ToList(),
        };

        var result = ProjectPackageIO.ManifestSnapshot(manifest, loadFailed);

        (result is null).ShouldBe(expectNull);
    }
}
