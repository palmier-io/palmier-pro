using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using PalmierPro.Core.Models;
using PalmierPro.Services.Media;
using PalmierPro.Services.Project;

namespace PalmierPro.App.ViewModels.MediaPanel;

/// Backs MediaTabView: folder navigation, the asset/folder grid, name search, import, and
/// delete/rename/new-folder ops persisted through the document's MediaManifest. Ports the relevant
/// slice of MediaTab.swift + EditorViewModel+MediaLibrary.swift/+Folders.swift for Phase 1 — no
/// visual/spoken moment search (Phase 3 on-device AI), no grouped/flat view modes, no undo
/// integration for library edits (out of scope for this stage; see the Windows port plan's M2/M3
/// split). Deliberately WinUI-free so PalmierPro.App.Tests can drive it under plain `dotnet test`.
public sealed partial class MediaTabViewModel : ObservableObject, IDisposable
{
    private readonly ProjectDocument _document;
    private readonly MediaImportService _importService;
    private readonly MediaVisualCache _visualCache;
    private readonly MissingMediaService _missingMediaService;
    private readonly IMediaImportDialogService _dialogService;

    private readonly List<MediaAsset> _assets = [];
    private readonly Dictionary<string, MediaAssetItemViewModel> _assetItemsById = [];
    private readonly Dictionary<string, MediaFolderItemViewModel> _folderItemsById = [];
    private IReadOnlySet<string> _missingAssetIds = new HashSet<string>();

    public ObservableCollection<object> Items { get; } = [];
    public ObservableCollection<MediaBreadcrumbItem> Breadcrumbs { get; } = [];

    public string? CurrentFolderId { get; private set; }

    [ObservableProperty]
    public partial string SearchQuery { get; set; } = "";

    [ObservableProperty]
    public partial bool IsEmptyLibrary { get; set; }

    [ObservableProperty]
    public partial string? LastError { get; set; }

    public MediaTabViewModel(
        ProjectDocument document,
        MediaImportService importService,
        MediaVisualCache visualCache,
        MissingMediaService missingMediaService,
        IMediaImportDialogService dialogService)
    {
        _document = document;
        _importService = importService;
        _visualCache = visualCache;
        _missingMediaService = missingMediaService;
        _dialogService = dialogService;
        _visualCache.ThumbnailsUpdated += OnThumbnailsUpdated;

        RebuildAssetsFromManifest();
        Refresh();
        foreach (var asset in _assets.Where(a => a.Type == ClipType.Video))
        {
            _visualCache.GenerateVideoThumbnails(asset.Id, asset.Url);
        }
        _ = RefreshMissingMediaAsync();
    }

    public void Dispose() => _visualCache.ThumbnailsUpdated -= OnThumbnailsUpdated;

    private void RebuildAssetsFromManifest()
    {
        _assets.Clear();
        var resolver = new MediaResolver(() => _document.Manifest, () => _document.PackagePath);
        foreach (var entry in _document.Manifest.Entries)
        {
            var url = resolver.ExpectedUrl(entry.Id) ?? entry.Name;
            _assets.Add(MediaAsset.FromManifestEntry(entry, url));
        }
    }

    // MARK: - Navigation

    public void NavigateToFolder(string? folderId)
    {
        CurrentFolderId = folderId;
        Refresh();
    }

    public void OpenFolder(string id)
    {
        if (_document.Manifest.Folders.All(f => f.Id != id))
        {
            return;
        }
        NavigateToFolder(id);
    }

    public void NavigateUp()
    {
        if (CurrentFolderId is not { } id)
        {
            return;
        }
        var folder = _document.Manifest.Folders.FirstOrDefault(f => f.Id == id);
        NavigateToFolder(folder?.ParentFolderId);
    }

    // MARK: - Search / grid contents

    partial void OnSearchQueryChanged(string value) => Refresh();

    private void Refresh()
    {
        Items.Clear();
        var query = SearchQuery.Trim();

        if (query.Length > 0)
        {
            foreach (var asset in _assets
                         .Where(a => a.Name.Contains(query, StringComparison.OrdinalIgnoreCase))
                         .OrderBy(a => a.Name, StringComparer.OrdinalIgnoreCase))
            {
                Items.Add(GetOrCreateAssetItem(asset));
            }
        }
        else
        {
            foreach (var folder in _document.Manifest.Folders
                         .Where(f => f.ParentFolderId == CurrentFolderId)
                         .OrderBy(f => f.Name, StringComparer.OrdinalIgnoreCase))
            {
                Items.Add(GetOrCreateFolderItem(folder));
            }
            foreach (var asset in _assets.Where(a => a.FolderId == CurrentFolderId))
            {
                Items.Add(GetOrCreateAssetItem(asset));
            }
        }

        RefreshBreadcrumbs();
        IsEmptyLibrary = _assets.Count == 0 && _document.Manifest.Folders.Count == 0;
    }

    private void RefreshBreadcrumbs()
    {
        Breadcrumbs.Clear();
        Breadcrumbs.Add(new MediaBreadcrumbItem(null, "Library"));
        foreach (var folder in FolderPath(CurrentFolderId))
        {
            Breadcrumbs.Add(new MediaBreadcrumbItem(folder.Id, folder.Name));
        }
    }

    private List<MediaFolder> FolderPath(string? folderId)
    {
        var path = new List<MediaFolder>();
        var visited = new HashSet<string>();
        var current = folderId;
        while (current is { } id && visited.Add(id))
        {
            var folder = _document.Manifest.Folders.FirstOrDefault(f => f.Id == id);
            if (folder is null)
            {
                break;
            }
            path.Add(folder);
            current = folder.ParentFolderId;
        }
        path.Reverse();
        return path;
    }

    private MediaFolderItemViewModel GetOrCreateFolderItem(MediaFolder folder)
    {
        if (!_folderItemsById.TryGetValue(folder.Id, out var item))
        {
            item = new MediaFolderItemViewModel(folder.Id, folder.Name, ChildCount(folder.Id));
            _folderItemsById[folder.Id] = item;
        }
        else
        {
            item.Name = folder.Name;
            item.ChildCount = ChildCount(folder.Id);
        }
        return item;
    }

    private int ChildCount(string folderId) =>
        _document.Manifest.Folders.Count(f => f.ParentFolderId == folderId) +
        _assets.Count(a => a.FolderId == folderId);

    private MediaAssetItemViewModel GetOrCreateAssetItem(MediaAsset asset)
    {
        if (!_assetItemsById.TryGetValue(asset.Id, out var item))
        {
            item = new MediaAssetItemViewModel(asset, _visualCache);
            _assetItemsById[asset.Id] = item;
        }
        else
        {
            item.Name = asset.Name;
            item.Duration = asset.Duration;
        }
        item.IsMissing = _missingAssetIds.Contains(asset.Id);
        return item;
    }

    private void OnThumbnailsUpdated(object? sender, ThumbnailsUpdatedEventArgs e)
    {
        if (_assetItemsById.TryGetValue(e.MediaRef, out var item))
        {
            item.RaiseThumbnailsChanged();
        }
    }

    // MARK: - Import

    [RelayCommand]
    private async Task ImportAsync()
    {
        var paths = await _dialogService.PickMediaFilesAsync();
        if (paths is null)
        {
            return;
        }
        await ImportPathsAsync(paths);
    }

    public async Task<MediaImportSummary> ImportPathsAsync(IReadOnlyList<string> paths)
    {
        if (paths.Count == 0)
        {
            return new MediaImportSummary([], []);
        }

        var summary = await _importService.ImportAsync(_document, paths, folderId: CurrentFolderId, mode: MediaImportMode.Reference);

        // A re-imported path (WasAlreadyImported: true — see MediaImportService's own remarks on
        // this being a deliberate Windows-only divergence from the Mac, which always creates a
        // fresh MediaAsset even for a duplicate) is a deliberate silent no-op here: the asset is
        // already in `_assets` from its first import, so there is nothing new to add, no thumbnail
        // regen to kick off, and no "changed" state. This VM has no selection/scroll-into-view
        // concept yet (that's later MediaPanel UI work) to give the user feedback that they
        // re-picked something already in the library — tracked as a known gap, not an oversight.
        var changed = false;
        foreach (var item in summary.Imported.Where(i => !i.WasAlreadyImported))
        {
            _assets.Add(item.Asset);
            changed = true;
            if (item.Asset.Type == ClipType.Video)
            {
                _visualCache.GenerateVideoThumbnails(item.Asset.Id, item.Asset.Url);
            }
        }

        LastError = summary.Failed.Count > 0 ? summary.Failed[^1].Message : null;

        if (changed)
        {
            MarkDirtyAndAutosave();
        }
        Refresh();
        await RefreshMissingMediaAsync();
        return summary;
    }

    [RelayCommand]
    private void DismissError() => LastError = null;

    // MARK: - Folder ops

    public string CreateFolder(string name = "New Folder")
    {
        var folder = new MediaFolder(name, CurrentFolderId);
        _document.Manifest.Folders.Add(folder);
        MarkDirtyAndAutosave();
        Refresh();
        return folder.Id;
    }

    public void RenameFolder(string id, string name)
    {
        name = name.Trim();
        if (name.Length == 0)
        {
            return;
        }
        var folder = _document.Manifest.Folders.FirstOrDefault(f => f.Id == id);
        if (folder is null || folder.Name == name)
        {
            return;
        }
        folder.Name = name;
        MarkDirtyAndAutosave();
        Refresh();
    }

    public void DeleteFolders(IEnumerable<string> ids)
    {
        var idSet = FolderIdsIncludingDescendants(ids);
        if (idSet.Count == 0)
        {
            return;
        }

        string? fallbackFolderId = null;
        if (CurrentFolderId is { } cur && idSet.Contains(cur))
        {
            fallbackFolderId = _document.Manifest.Folders.FirstOrDefault(f => f.Id == cur)?.ParentFolderId;
            while (fallbackFolderId is { } fid && idSet.Contains(fid))
            {
                fallbackFolderId = _document.Manifest.Folders.FirstOrDefault(f => f.Id == fid)?.ParentFolderId;
            }
        }

        var assetIdsToDelete = _assets.Where(a => a.FolderId is { } fid2 && idSet.Contains(fid2)).Select(a => a.Id).ToHashSet();
        _assets.RemoveAll(a => assetIdsToDelete.Contains(a.Id));
        _document.Manifest.Entries.RemoveAll(e => assetIdsToDelete.Contains(e.Id));
        _document.Manifest.Folders.RemoveAll(f => idSet.Contains(f.Id));
        foreach (var id in idSet)
        {
            _folderItemsById.Remove(id);
        }
        foreach (var id in assetIdsToDelete)
        {
            _assetItemsById.Remove(id);
        }

        if (CurrentFolderId is { } curNow && idSet.Contains(curNow))
        {
            CurrentFolderId = fallbackFolderId;
        }

        MarkDirtyAndAutosave();
        Refresh();
        _ = RefreshMissingMediaAsync();
    }

    private HashSet<string> FolderIdsIncludingDescendants(IEnumerable<string> ids)
    {
        var all = new HashSet<string>(ids.Where(id => _document.Manifest.Folders.Any(f => f.Id == id)));
        var childrenByParent = _document.Manifest.Folders.ToLookup(f => f.ParentFolderId);
        var queue = new Queue<string>(all);
        while (queue.Count > 0)
        {
            var id = queue.Dequeue();
            foreach (var child in childrenByParent[id])
            {
                if (all.Add(child.Id))
                {
                    queue.Enqueue(child.Id);
                }
            }
        }
        return all;
    }

    // MARK: - Asset ops

    public void RenameAsset(string id, string name)
    {
        name = name.Trim();
        if (name.Length == 0)
        {
            return;
        }
        var asset = _assets.FirstOrDefault(a => a.Id == id);
        if (asset is null || asset.Name == name)
        {
            return;
        }
        asset.Name = name;
        var entry = _document.Manifest.Entries.FirstOrDefault(e => e.Id == id);
        if (entry is not null)
        {
            entry.Name = name;
        }
        MarkDirtyAndAutosave();
        Refresh();
    }

    public void DeleteAssets(IEnumerable<string> ids)
    {
        var idSet = ids.ToHashSet();
        if (idSet.Count == 0)
        {
            return;
        }
        _assets.RemoveAll(a => idSet.Contains(a.Id));
        _document.Manifest.Entries.RemoveAll(e => idSet.Contains(e.Id));
        foreach (var id in idSet)
        {
            _assetItemsById.Remove(id);
        }
        MarkDirtyAndAutosave();
        Refresh();
        _ = RefreshMissingMediaAsync();
    }

    // MARK: - Missing media

    public async Task RefreshMissingMediaAsync()
    {
        _missingAssetIds = await _missingMediaService.DetectAsync(_document.Manifest, _document.PackagePath);
        foreach (var (id, item) in _assetItemsById)
        {
            item.IsMissing = _missingAssetIds.Contains(id);
        }
    }

    private void MarkDirtyAndAutosave()
    {
        _document.MarkDirty();
        _ = _document.RequestCheckpointAutosaveAsync();
    }
}
