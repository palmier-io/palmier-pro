using PalmierPro.Core.Models;
using PalmierPro.Rendering;
using PalmierPro.Services.Media;
using PalmierPro.Services.Project;
using Shouldly;
using Xunit;

namespace PalmierPro.Services.Tests.Media;

[Collection(MediaFixturesCollection.Name)]
public sealed class MissingMediaServiceTests(MediaFixtures fixtures)
{
    [Fact]
    [Trait("Category", "Media")]
    public async Task DetectAsync_FlagsADeletedFile_ButNotAFileThatStillExists()
    {
        using var tmp = new TempDirectory();
        using var session = new EngineSession();
        var doc = await ProjectDocument.CreateNewAsync(tmp.Path, "Missing Media");
        var importer = new MediaImportService(new EngineMediaProbe(session));

        // Copy so the asset's backing file lives inside the temp project and can be deleted
        // without touching the shared fixture.
        MediaImportSummary summary = await importer.ImportAsync(
            doc, [fixtures.VideoWithAudioPath, fixtures.PngStillPath], mode: MediaImportMode.Copy);
        summary.Failed.ShouldBeEmpty();
        string deletedAssetId = summary.Imported.Single(i => i.Asset.Type == ClipType.Video).Asset.Id;
        string survivingAssetId = summary.Imported.Single(i => i.Asset.Type == ClipType.Image).Asset.Id;
        string deletedAssetUrl = summary.Imported.Single(i => i.Asset.Id == deletedAssetId).Asset.Url;

        File.Delete(deletedAssetUrl);

        IReadOnlySet<string> missing = await new MissingMediaService().DetectAsync(doc);

        missing.ShouldContain(deletedAssetId);
        missing.ShouldNotContain(survivingAssetId);
    }

    [Fact]
    [Trait("Category", "Media")]
    public async Task DetectAsync_ExternalReferenceToANonexistentPath_IsFlaggedMissing()
    {
        using var tmp = new TempDirectory();
        var doc = await ProjectDocument.CreateNewAsync(tmp.Path, "Missing External");
        string ghostPath = Path.Combine(tmp.Path, "ghost.mp4");
        doc.Manifest.Entries.Add(new MediaManifestEntry(
            id: "ghost-asset", name: "Ghost", type: ClipType.Video,
            source: PalmierPro.Core.Models.MediaSource.External(ghostPath), duration: 1.0));

        IReadOnlySet<string> missing = await new MissingMediaService().DetectAsync(doc);

        missing.ShouldContain("ghost-asset");
    }

    [Fact]
    [Trait("Category", "Media")]
    public async Task DetectAsync_EmptyManifest_ReturnsEmptySet()
    {
        using var tmp = new TempDirectory();
        var doc = await ProjectDocument.CreateNewAsync(tmp.Path, "Missing Empty");

        IReadOnlySet<string> missing = await new MissingMediaService().DetectAsync(doc);

        missing.ShouldBeEmpty();
    }
}
