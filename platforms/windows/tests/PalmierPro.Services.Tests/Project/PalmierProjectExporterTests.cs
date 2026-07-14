using System.Text.Json;
using PalmierPro.Core.Models;
using PalmierPro.Services.Project;
using Shouldly;
using Xunit;

namespace PalmierPro.Services.Tests;

public class PalmierProjectExporterTests
{
    [Fact]
    public void Export_CopiesInternalAndExternalMediaAndReportsMissing()
    {
        using var tmp = new TempDirectory();
        var sourcePackage = Path.Combine(tmp.Path, "Source.palmier");
        var mediaDir = Path.Combine(sourcePackage, "media");
        Directory.CreateDirectory(mediaDir);
        File.WriteAllBytes(Path.Combine(mediaDir, "clip1.mov"), [1, 2, 3, 4]);

        var externalFile = Path.Combine(tmp.Path, "external.mp4");
        File.WriteAllBytes(externalFile, [5, 6, 7]);

        var manifest = new MediaManifest
        {
            Entries =
            [
                new MediaManifestEntry("a", "Clip 1", ClipType.Video, MediaSource.Project("media/clip1.mov"), 2.0),
                new MediaManifestEntry("b", "External", ClipType.Video, MediaSource.External(externalFile), 1.0),
                new MediaManifestEntry("c", "Missing", ClipType.Video, MediaSource.External(Path.Combine(tmp.Path, "nope.mp4")), 1.0),
            ],
        };
        var projectFile = new ProjectFile([TestFixtures.Timeline()]);
        var destPath = Path.Combine(tmp.Path, "Exported.palmier");

        var report = PalmierProjectExporter.Export(projectFile, manifest, new GenerationLog(), sourcePackage, destPath);

        report.Missing.Count.ShouldBe(1);
        report.Missing[0].Id.ShouldBe("c");
        report.Collected.ShouldBe(["b"]);
        report.CopiedInternal.ShouldBe(1);
        report.TotalBytes.ShouldBe(4 + 3);
        report.Warnings.Count.ShouldBe(1);

        Directory.Exists(destPath).ShouldBeTrue();
        File.Exists(Path.Combine(destPath, "media", "clip1.mov")).ShouldBeTrue();

        var exportedManifest = JsonSerializer.Deserialize<MediaManifest>(File.ReadAllBytes(Path.Combine(destPath, "media.json")))!;
        exportedManifest.Entries.Count.ShouldBe(3);
        exportedManifest.Entries.First(e => e.Id == "b").Source.Kind.ShouldBe(MediaSourceKind.Project);
        // External entries are renamed to "import-<id prefix>.<ext>" rather than keeping their
        // original filename — see PalmierProjectExporter.ImportName.
        exportedManifest.Entries.First(e => e.Id == "b").Source.Path.ShouldBe("media/import-b.mp4");
        // The missing entry's dangling reference is carried across untouched.
        exportedManifest.Entries.First(e => e.Id == "c").Source.Kind.ShouldBe(MediaSourceKind.External);
    }

    [Fact]
    public void Export_DoesNotMutateTheOriginalManifestEntries()
    {
        using var tmp = new TempDirectory();
        var sourcePackage = Path.Combine(tmp.Path, "Source.palmier");
        Directory.CreateDirectory(Path.Combine(sourcePackage, "media"));
        File.WriteAllBytes(Path.Combine(sourcePackage, "media", "clip1.mov"), [1]);

        var entry = new MediaManifestEntry("a", "Clip 1", ClipType.Video, MediaSource.Project("media/clip1.mov"), 2.0);
        var manifest = new MediaManifest { Entries = [entry] };

        PalmierProjectExporter.Export(new ProjectFile([TestFixtures.Timeline()]), manifest, new GenerationLog(), sourcePackage, Path.Combine(tmp.Path, "Out.palmier"));

        // The exporter must clone before rewriting `Source` — the caller's manifest is untouched.
        entry.Source.Kind.ShouldBe(MediaSourceKind.Project);
        entry.Source.Path.ShouldBe("media/clip1.mov");
    }

    [Fact]
    public void Export_DedupesTwoEntriesPointingAtTheSameExternalFile()
    {
        using var tmp = new TempDirectory();
        var externalFile = Path.Combine(tmp.Path, "shared.mp4");
        File.WriteAllBytes(externalFile, [1, 2, 3]);
        var manifest = new MediaManifest
        {
            Entries =
            [
                new MediaManifestEntry("a", "First", ClipType.Video, MediaSource.External(externalFile), 1.0),
                new MediaManifestEntry("b", "Second", ClipType.Video, MediaSource.External(externalFile), 1.0),
            ],
        };
        var destPath = Path.Combine(tmp.Path, "Out.palmier");

        var report = PalmierProjectExporter.Export(new ProjectFile([TestFixtures.Timeline()]), manifest, new GenerationLog(), null, destPath);

        report.Collected.ShouldBe(["a", "b"]);
        report.TotalBytes.ShouldBe(3); // copied once, not twice
        Directory.GetFiles(Path.Combine(destPath, "media")).Length.ShouldBe(1);
    }

    [Fact]
    public void Export_WithoutSourceProjectPath_TreatsProjectRelativeEntriesAsMissing()
    {
        using var tmp = new TempDirectory();
        var manifest = new MediaManifest
        {
            Entries = [new MediaManifestEntry("a", "Clip", ClipType.Video, MediaSource.Project("media/clip.mov"), 1.0)],
        };

        var report = PalmierProjectExporter.Export(
            new ProjectFile([TestFixtures.Timeline()]), manifest, new GenerationLog(), null, Path.Combine(tmp.Path, "Out.palmier"));

        report.Missing.Count.ShouldBe(1);
        report.Missing[0].Id.ShouldBe("a");
    }

    [Fact]
    public void Export_OverExistingDestination_ReplacesItAtomically()
    {
        using var tmp = new TempDirectory();
        var destPath = Path.Combine(tmp.Path, "Out.palmier");
        var manifest = new MediaManifest();

        PalmierProjectExporter.Export(new ProjectFile([TestFixtures.Timeline()]), manifest, new GenerationLog(), null, destPath);
        File.WriteAllBytes(Path.Combine(destPath, "sentinel.txt"), [1]); // proves the old dir is gone after replace
        PalmierProjectExporter.Export(new ProjectFile([TestFixtures.Timeline()]), manifest, new GenerationLog(), null, destPath);

        File.Exists(Path.Combine(destPath, "sentinel.txt")).ShouldBeFalse();
        File.Exists(Path.Combine(destPath, "project.json")).ShouldBeTrue();
    }

    [Fact]
    public void Export_LeavesNoStagingDirectoryWhenCancelledUpFront()
    {
        using var tmp = new TempDirectory();
        using var cts = new CancellationTokenSource();
        cts.Cancel();

        Should.Throw<OperationCanceledException>(() =>
            PalmierProjectExporter.Export(
                new ProjectFile([TestFixtures.Timeline()]), new MediaManifest(), new GenerationLog(), null,
                Path.Combine(tmp.Path, "Out.palmier"), cancellationToken: cts.Token));

        Directory.GetDirectories(tmp.Path).ShouldBeEmpty();
        Directory.GetFiles(tmp.Path).ShouldBeEmpty();
    }
}
