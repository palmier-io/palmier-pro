using PalmierPro.App.ViewModels.MediaPanel;
using PalmierPro.Rendering;
using PalmierPro.Services.Media;
using PalmierPro.Services.Project;
using Shouldly;
using Xunit;

namespace PalmierPro.App.Tests.ViewModels.MediaPanel;

[Collection(MediaFixturesCollection.Name)]
public sealed class MediaTabViewModelTests(MediaFixtures fixtures)
{
    private sealed class FakeMediaImportDialogService : IMediaImportDialogService
    {
        public IReadOnlyList<string>? NextPaths { get; set; }
        public Task<IReadOnlyList<string>?> PickMediaFilesAsync() => Task.FromResult(NextPaths);
    }

    private sealed class MediaTabHarness(MediaTabViewModel vm, EngineSession session, MediaVisualCache cache) : IDisposable
    {
        public MediaTabViewModel Vm { get; } = vm;

        public void Dispose()
        {
            Vm.Dispose();
            cache.Dispose();
            session.Dispose();
        }
    }

    private static MediaTabHarness CreateHarness(ProjectDocument doc, IMediaImportDialogService? dialogs = null)
    {
        var session = new EngineSession();
        var cache = new MediaVisualCache(session);
        var importService = new MediaImportService(new EngineMediaProbe(session));
        var missing = new MissingMediaService();
        var vm = new MediaTabViewModel(doc, importService, cache, missing, dialogs ?? new FakeMediaImportDialogService());
        return new MediaTabHarness(vm, session, cache);
    }

    private static async Task WaitUntilAsync(Func<bool> condition, int timeoutMs = 10_000)
    {
        var deadline = DateTime.UtcNow.AddMilliseconds(timeoutMs);
        while (DateTime.UtcNow < deadline)
        {
            if (condition())
            {
                return;
            }
            await Task.Delay(50);
        }
        condition().ShouldBeTrue("timed out waiting for condition");
    }

    private static string CopyFixture(string sourcePath, string destDir, string destName)
    {
        Directory.CreateDirectory(destDir);
        var dest = Path.Combine(destDir, destName);
        File.Copy(sourcePath, dest);
        return dest;
    }

    [Fact]
    [Trait("Category", "Media")]
    public async Task ImportPathsAsync_adds_the_asset_to_the_grid_and_the_manifest()
    {
        using var tmp = new TempDirectory();
        var doc = await ProjectDocument.CreateNewAsync(tmp.Path, "Import Grid");
        using var harness = CreateHarness(doc);
        var path = CopyFixture(fixtures.PngStillPath, tmp.Path, "photo.png");

        var summary = await harness.Vm.ImportPathsAsync([path]);

        summary.Failed.ShouldBeEmpty();
        doc.Manifest.Entries.Count.ShouldBe(1);
        var assetId = doc.Manifest.Entries[0].Id;
        harness.Vm.Items.OfType<MediaAssetItemViewModel>().ShouldContain(a => a.Id == assetId && a.Name == "photo");
    }

    [Fact]
    [Trait("Category", "Media")]
    public async Task ImportPathsAsync_video_asset_progressively_populates_MediaVisualCache_thumbnails()
    {
        using var tmp = new TempDirectory();
        var doc = await ProjectDocument.CreateNewAsync(tmp.Path, "Import Video");
        using var harness = CreateHarness(doc);
        var path = CopyFixture(fixtures.VideoWithAudioPath, tmp.Path, "clip.mp4");

        await harness.Vm.ImportPathsAsync([path]);
        var item = harness.Vm.Items.OfType<MediaAssetItemViewModel>().Single();

        await WaitUntilAsync(() => item.VisualCache.Thumbnails(item.Id) is { Count: > 0 });

        item.VisualCache.Thumbnails(item.Id).ShouldNotBeNull();
    }

    [Fact]
    [Trait("Category", "Media")]
    public async Task SearchQuery_filters_the_grid_to_matching_asset_names()
    {
        using var tmp = new TempDirectory();
        var doc = await ProjectDocument.CreateNewAsync(tmp.Path, "Search");
        using var harness = CreateHarness(doc);
        var alpha = CopyFixture(fixtures.PngStillPath, tmp.Path, "alpha.png");
        var beta = CopyFixture(fixtures.PngStillPath, tmp.Path, "beta.png");
        await harness.Vm.ImportPathsAsync([alpha, beta]);

        harness.Vm.SearchQuery = "alpha";

        var names = harness.Vm.Items.OfType<MediaAssetItemViewModel>().Select(a => a.Name).ToList();
        names.ShouldBe(["alpha"]);

        harness.Vm.SearchQuery = "";
        harness.Vm.Items.OfType<MediaAssetItemViewModel>().Count().ShouldBe(2);
    }

    [Fact]
    [Trait("Category", "Media")]
    public async Task RenameAsset_updates_the_grid_item_and_the_manifest_entry()
    {
        using var tmp = new TempDirectory();
        var doc = await ProjectDocument.CreateNewAsync(tmp.Path, "Rename Asset");
        using var harness = CreateHarness(doc);
        var path = CopyFixture(fixtures.PngStillPath, tmp.Path, "before.png");
        await harness.Vm.ImportPathsAsync([path]);
        var id = doc.Manifest.Entries[0].Id;

        harness.Vm.RenameAsset(id, "After");

        doc.Manifest.Entries[0].Name.ShouldBe("After");
        harness.Vm.Items.OfType<MediaAssetItemViewModel>().Single(a => a.Id == id).Name.ShouldBe("After");
    }

    [Fact]
    [Trait("Category", "Media")]
    public async Task DeleteAssets_removes_the_asset_from_the_grid_and_the_manifest()
    {
        using var tmp = new TempDirectory();
        var doc = await ProjectDocument.CreateNewAsync(tmp.Path, "Delete Asset");
        using var harness = CreateHarness(doc);
        var path = CopyFixture(fixtures.PngStillPath, tmp.Path, "gone.png");
        await harness.Vm.ImportPathsAsync([path]);
        var id = doc.Manifest.Entries[0].Id;

        harness.Vm.DeleteAssets([id]);

        doc.Manifest.Entries.ShouldBeEmpty();
        harness.Vm.Items.OfType<MediaAssetItemViewModel>().ShouldNotContain(a => a.Id == id);
    }

    [Fact]
    [Trait("Category", "Media")]
    public async Task CreateFolder_RenameFolder_DeleteFolder_round_trip_through_the_manifest()
    {
        using var tmp = new TempDirectory();
        var doc = await ProjectDocument.CreateNewAsync(tmp.Path, "Folder Ops");
        using var harness = CreateHarness(doc);

        var id = harness.Vm.CreateFolder("Clips");
        doc.Manifest.Folders.ShouldContain(f => f.Id == id && f.Name == "Clips");
        harness.Vm.Items.OfType<MediaFolderItemViewModel>().ShouldContain(f => f.Id == id && f.Name == "Clips");

        harness.Vm.RenameFolder(id, "Renamed");
        doc.Manifest.Folders.Single(f => f.Id == id).Name.ShouldBe("Renamed");
        harness.Vm.Items.OfType<MediaFolderItemViewModel>().Single(f => f.Id == id).Name.ShouldBe("Renamed");

        harness.Vm.DeleteFolders([id]);
        doc.Manifest.Folders.ShouldBeEmpty();
        harness.Vm.Items.OfType<MediaFolderItemViewModel>().ShouldNotContain(f => f.Id == id);
    }

    [Fact]
    [Trait("Category", "Media")]
    public async Task NavigateToFolder_scopes_the_grid_to_that_folders_assets()
    {
        using var tmp = new TempDirectory();
        var doc = await ProjectDocument.CreateNewAsync(tmp.Path, "Folder Scope");
        using var harness = CreateHarness(doc);
        var folderId = harness.Vm.CreateFolder("Clips");

        harness.Vm.NavigateToFolder(folderId);
        var inFolder = CopyFixture(fixtures.PngStillPath, tmp.Path, "in-folder.png");
        await harness.Vm.ImportPathsAsync([inFolder]);

        harness.Vm.Items.OfType<MediaAssetItemViewModel>().Select(a => a.Name).ShouldBe(["in-folder"]);

        harness.Vm.NavigateToFolder(null);
        harness.Vm.Items.OfType<MediaAssetItemViewModel>().ShouldBeEmpty();
        harness.Vm.Items.OfType<MediaFolderItemViewModel>().ShouldContain(f => f.Id == folderId);
    }

    [Fact]
    [Trait("Category", "Media")]
    public async Task Missing_media_badge_turns_on_after_the_backing_file_disappears()
    {
        using var tmp = new TempDirectory();
        var doc = await ProjectDocument.CreateNewAsync(tmp.Path, "Missing Media");
        using var harness = CreateHarness(doc);
        var path = CopyFixture(fixtures.PngStillPath, tmp.Path, "will-vanish.png");
        await harness.Vm.ImportPathsAsync([path]);
        var item = harness.Vm.Items.OfType<MediaAssetItemViewModel>().Single();
        item.IsMissing.ShouldBeFalse();

        File.Delete(path);
        await harness.Vm.RefreshMissingMediaAsync();

        item.IsMissing.ShouldBeTrue();
    }

    [Fact]
    [Trait("Category", "Media")]
    public async Task ImportCommand_uses_the_dialog_service_and_imports_the_picked_paths()
    {
        using var tmp = new TempDirectory();
        var doc = await ProjectDocument.CreateNewAsync(tmp.Path, "Import Command");
        var dialogs = new FakeMediaImportDialogService();
        using var harness = CreateHarness(doc, dialogs);
        var path = CopyFixture(fixtures.PngStillPath, tmp.Path, "picked.png");
        dialogs.NextPaths = [path];

        await harness.Vm.ImportCommand.ExecuteAsync(null);

        doc.Manifest.Entries.ShouldContain(e => e.Name == "picked");
    }
}
