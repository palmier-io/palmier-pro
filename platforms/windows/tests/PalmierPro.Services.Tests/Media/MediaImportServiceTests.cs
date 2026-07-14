using System.Security.AccessControl;
using System.Security.Principal;
using PalmierPro.Core.Models;
using PalmierPro.Rendering;
using PalmierPro.Services.Media;
using PalmierPro.Services.Project;
using Shouldly;
using Xunit;

namespace PalmierPro.Services.Tests.Media;

[Collection(MediaFixturesCollection.Name)]
public sealed class MediaImportServiceTests(MediaFixtures fixtures)
{
    [Fact]
    [Trait("Category", "Media")]
    public async Task ImportAsync_CopyMode_PlacesFilesUnderPackageMediaDirectory_WithCorrectManifestEntries()
    {
        using var tmp = new TempDirectory();
        using var session = new EngineSession();
        var doc = await ProjectDocument.CreateNewAsync(tmp.Path, "Import Copy");
        var importer = new MediaImportService(new EngineMediaProbe(session));

        MediaImportSummary summary = await importer.ImportAsync(
            doc, [fixtures.VideoWithAudioPath, fixtures.PngStillPath], mode: MediaImportMode.Copy);

        summary.Failed.ShouldBeEmpty();
        summary.Imported.Count.ShouldBe(2);
        doc.Manifest.Entries.Count.ShouldBe(2);

        string mediaDir = ProjectPackage.MediaDirectoryPath(doc.PackagePath);
        Directory.Exists(mediaDir).ShouldBeTrue();

        MediaImportItem videoItem = summary.Imported.Single(i => i.Asset.Type == ClipType.Video);
        MediaImportItem imageItem = summary.Imported.Single(i => i.Asset.Type == ClipType.Image);

        // Files per Mac naming: <package>/media/<filename>, matching Project.mediaDirectoryName
        // ("media") — see VideoProject.swift's copyMediaDirectoryIfNeeded and
        // Constants.swift's Project.mediaDirectoryName.
        videoItem.Asset.Url.ShouldBe(Path.Combine(mediaDir, Path.GetFileName(fixtures.VideoWithAudioPath)));
        imageItem.Asset.Url.ShouldBe(Path.Combine(mediaDir, Path.GetFileName(fixtures.PngStillPath)));
        File.Exists(videoItem.Asset.Url).ShouldBeTrue();
        File.Exists(imageItem.Asset.Url).ShouldBeTrue();

        MediaManifestEntry videoEntry = doc.Manifest.Entries.Single(e => e.Id == videoItem.Asset.Id);
        videoEntry.Source.Kind.ShouldBe(MediaSourceKind.Project);
        videoEntry.Source.Path.Replace('\\', '/').ShouldBe($"media/{Path.GetFileName(fixtures.VideoWithAudioPath)}");
        videoEntry.Duration.ShouldBe(MediaFixtures.VideoDurationSeconds, 0.25);
        videoEntry.SourceWidth.ShouldBe(MediaFixtures.VideoWidth);
        videoEntry.SourceHeight.ShouldBe(MediaFixtures.VideoHeight);
        videoEntry.SourceFPS!.Value.ShouldBe(MediaFixtures.VideoFps, 0.5);
        videoEntry.HasAudio.ShouldBe(true);

        MediaManifestEntry imageEntry = doc.Manifest.Entries.Single(e => e.Id == imageItem.Asset.Id);
        imageEntry.Source.Kind.ShouldBe(MediaSourceKind.Project);
        imageEntry.Source.Path.Replace('\\', '/').ShouldBe($"media/{Path.GetFileName(fixtures.PngStillPath)}");
        imageEntry.SourceWidth.ShouldBe(MediaFixtures.PngWidth);
        imageEntry.SourceHeight.ShouldBe(MediaFixtures.PngHeight);
        imageEntry.Duration.ShouldBe(Defaults.ImageDurationSeconds);
    }

    [Fact]
    [Trait("Category", "Media")]
    public async Task ImportAsync_ReferenceMode_IsTheDefault_AndDoesNotCopyTheSourceFile()
    {
        using var tmp = new TempDirectory();
        using var session = new EngineSession();
        var doc = await ProjectDocument.CreateNewAsync(tmp.Path, "Import Reference");
        var importer = new MediaImportService(new EngineMediaProbe(session));

        // No `mode:` argument — Reference must be the default, mirroring the Mac's Finder/drag
        // import path (EditorViewModel+MediaLibrary.swift never copies a plain user-dropped file).
        MediaImportSummary summary = await importer.ImportAsync(doc, [fixtures.VideoWithAudioPath]);

        summary.Failed.ShouldBeEmpty();
        MediaImportItem item = summary.Imported.Single();
        item.Asset.Url.ShouldBe(fixtures.VideoWithAudioPath);
        Directory.Exists(ProjectPackage.MediaDirectoryPath(doc.PackagePath)).ShouldBeFalse();

        MediaManifestEntry entry = doc.Manifest.Entries.Single();
        entry.Source.Kind.ShouldBe(MediaSourceKind.External);
        entry.Source.Path.ShouldBe(Path.GetFullPath(fixtures.VideoWithAudioPath));
    }

    [Fact]
    [Trait("Category", "Media")]
    public async Task ImportAsync_UnsupportedExtension_RecordsAPerFileError_AndDoesNotAbortTheBatch()
    {
        using var tmp = new TempDirectory();
        using var session = new EngineSession();
        var doc = await ProjectDocument.CreateNewAsync(tmp.Path, "Import Unsupported");
        var importer = new MediaImportService(new EngineMediaProbe(session));

        string unsupportedPath = Path.Combine(tmp.Path, "notes.xyz");
        await File.WriteAllTextAsync(unsupportedPath, "not media");

        MediaImportSummary summary = await importer.ImportAsync(doc, [fixtures.VideoWithAudioPath, unsupportedPath]);

        summary.Imported.Count.ShouldBe(1);
        summary.Imported[0].Asset.Url.ShouldBe(fixtures.VideoWithAudioPath);
        summary.Failed.Count.ShouldBe(1);
        summary.Failed[0].Path.ShouldBe(unsupportedPath);
        summary.Failed[0].Message.ShouldContain("unsupported file type");
    }

    [Fact]
    [Trait("Category", "Media")]
    public async Task ImportAsync_MissingFile_RecordsAPerFileError_AndDoesNotAbortTheBatch()
    {
        using var tmp = new TempDirectory();
        using var session = new EngineSession();
        var doc = await ProjectDocument.CreateNewAsync(tmp.Path, "Import Missing");
        var importer = new MediaImportService(new EngineMediaProbe(session));

        string missingPath = Path.Combine(tmp.Path, "ghost.mp4");

        MediaImportSummary summary = await importer.ImportAsync(doc, [missingPath, fixtures.PngStillPath]);

        summary.Imported.Count.ShouldBe(1);
        summary.Failed.Count.ShouldBe(1);
        summary.Failed[0].Path.ShouldBe(missingPath);
        summary.Failed[0].Message.ShouldContain("not found");
    }

    [Fact]
    [Trait("Category", "Media")]
    public async Task ImportAsync_SamePathImportedTwice_ReturnsTheExistingAssetInsteadOfDuplicating()
    {
        using var tmp = new TempDirectory();
        using var session = new EngineSession();
        var doc = await ProjectDocument.CreateNewAsync(tmp.Path, "Import Duplicate");
        var importer = new MediaImportService(new EngineMediaProbe(session));

        MediaImportSummary first = await importer.ImportAsync(doc, [fixtures.PngStillPath]);
        MediaImportSummary second = await importer.ImportAsync(doc, [fixtures.PngStillPath]);

        doc.Manifest.Entries.Count.ShouldBe(1);
        first.Imported.Single().WasAlreadyImported.ShouldBeFalse();
        second.Imported.Single().WasAlreadyImported.ShouldBeTrue();
        second.Imported.Single().Asset.Id.ShouldBe(first.Imported.Single().Asset.Id);
    }

    [Fact]
    [Trait("Category", "Media")]
    public async Task ImportAsync_FolderWithInaccessibleSubdirectory_SkipsItAndImportsTheRestOfTheBatch()
    {
        using var tmp = new TempDirectory();
        using var session = new EngineSession();
        var doc = await ProjectDocument.CreateNewAsync(tmp.Path, "Import Inaccessible");
        var importer = new MediaImportService(new EngineMediaProbe(session));

        string folder = Path.Combine(tmp.Path, "drop");
        Directory.CreateDirectory(folder);
        string goodPath = Path.Combine(folder, Path.GetFileName(fixtures.PngStillPath));
        File.Copy(fixtures.PngStillPath, goodPath);

        string lockedDir = Path.Combine(folder, "locked");
        Directory.CreateDirectory(lockedDir);
        File.Copy(fixtures.VideoWithAudioPath, Path.Combine(lockedDir, Path.GetFileName(fixtures.VideoWithAudioPath)));

        // Deny this identity ListDirectory on `locked` — reproduces the realistic "ACL-locked
        // folder" trigger from the finding (also covers "System Volume Information", $RECYCLE.BIN,
        // a OneDrive placeholder: anything Directory.EnumerateFiles can't descend into).
        var lockedInfo = new DirectoryInfo(lockedDir);
        DirectorySecurity security = lockedInfo.GetAccessControl();
        var identity = (SecurityIdentifier)WindowsIdentity.GetCurrent().User!;
        var denyRule = new FileSystemAccessRule(identity, FileSystemRights.ListDirectory, AccessControlType.Deny);
        security.AddAccessRule(denyRule);
        lockedInfo.SetAccessControl(security);

        try
        {
            // Pre-fix, Directory.EnumerateFiles(path, "*", SearchOption.AllDirectories) throws
            // UnauthorizedAccessException out of ExpandPaths' MoveNext — OUTSIDE ImportAsync's
            // per-file try/catch — aborting the whole import instead of just skipping `locked`.
            MediaImportSummary summary = await importer.ImportAsync(doc, [folder]);

            summary.Imported.ShouldHaveSingleItem();
            summary.Imported[0].Asset.Url.ShouldBe(goodPath);
            summary.Failed.ShouldBeEmpty();
        }
        finally
        {
            security.RemoveAccessRule(denyRule);
            lockedInfo.SetAccessControl(security);
        }
    }

    [Fact]
    [Trait("Category", "Media")]
    public async Task ImportAsync_FolderWithNestedUnsupportedFile_SkipsItSilently_UnlikeARootUnsupportedFile()
    {
        using var tmp = new TempDirectory();
        using var session = new EngineSession();
        var doc = await ProjectDocument.CreateNewAsync(tmp.Path, "Import Nested Unsupported");
        var importer = new MediaImportService(new EngineMediaProbe(session));

        string folder = Path.Combine(tmp.Path, "drop");
        string nested = Path.Combine(folder, "nested");
        Directory.CreateDirectory(nested);
        File.Copy(fixtures.PngStillPath, Path.Combine(folder, Path.GetFileName(fixtures.PngStillPath)));
        await File.WriteAllTextAsync(Path.Combine(nested, "notes.xyz"), "not media");

        MediaImportSummary summary = await importer.ImportAsync(doc, [folder]);

        // Mirrors MediaImportScanner.scanFile's `isRootItem` guard: an unsupported-extension file
        // found by walking INTO a dropped folder is dropped from the plan with no failure recorded
        // — contrast with ImportAsync_UnsupportedExtension_RecordsAPerFileError_AndDoesNotAbortTheBatch
        // above, where the unsupported path is one of the literal `paths` passed to ImportAsync
        // (isRoot: true) and DOES get recorded.
        summary.Imported.ShouldHaveSingleItem();
        summary.Failed.ShouldBeEmpty();
    }

    [Fact]
    [Trait("Category", "Media")]
    public async Task ImportAsync_FolderWithHiddenFile_SkipsItEntirely_NoFailureRecorded()
    {
        using var tmp = new TempDirectory();
        using var session = new EngineSession();
        var doc = await ProjectDocument.CreateNewAsync(tmp.Path, "Import Hidden");
        var importer = new MediaImportService(new EngineMediaProbe(session));

        string folder = Path.Combine(tmp.Path, "drop");
        Directory.CreateDirectory(folder);
        string visiblePath = Path.Combine(folder, Path.GetFileName(fixtures.PngStillPath));
        File.Copy(fixtures.PngStillPath, visiblePath);
        string hiddenPath = Path.Combine(folder, "desktop.ini");
        await File.WriteAllTextAsync(hiddenPath, "[.ShellClassInfo]");
        File.SetAttributes(hiddenPath, FileAttributes.Hidden);

        MediaImportSummary summary = await importer.ImportAsync(doc, [folder]);

        // AttributesToSkip=Hidden mirrors MediaImportScanner.directoryEntries' .skipsHiddenFiles —
        // a hidden desktop.ini/Thumbs.db-style file never enters the walk at all, so it's not even
        // an "unsupported file type" failure — it's invisible to the import entirely.
        summary.Imported.ShouldHaveSingleItem();
        summary.Imported[0].Asset.Url.ShouldBe(visiblePath);
        summary.Failed.ShouldBeEmpty();
    }

    [Fact]
    [Trait("Category", "Media")]
    public async Task ImportAsync_FolderTargeting_SetsFolderIdOnTheImportedAsset()
    {
        using var tmp = new TempDirectory();
        using var session = new EngineSession();
        var doc = await ProjectDocument.CreateNewAsync(tmp.Path, "Import Folder");
        doc.Manifest.Folders.Add(new MediaFolder("Clips", id: "folder-1"));
        var importer = new MediaImportService(new EngineMediaProbe(session));

        MediaImportSummary summary = await importer.ImportAsync(doc, [fixtures.PngStillPath], folderId: "folder-1");

        summary.Imported.Single().Asset.FolderId.ShouldBe("folder-1");
        doc.Manifest.Entries.Single().FolderId.ShouldBe("folder-1");
    }
}
