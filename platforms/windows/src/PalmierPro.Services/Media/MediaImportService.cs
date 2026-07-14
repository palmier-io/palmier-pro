using PalmierPro.Core.Models;
using PalmierPro.Services.Project;

namespace PalmierPro.Services.Media;

public enum MediaImportMode
{
    /// Reference the file at its existing location — the Mac's default for a Finder/drag/open-panel
    /// import; see `EditorViewModel+MediaLibrary.swift`'s `addMediaAsset(from:)` and
    /// `applyMediaImportPlan`, which build `MediaAsset(url: file.url, ...)` directly off the
    /// dropped path. No file is copied; `MediaAsset.ToManifestEntry` then stores it as
    /// `MediaSource.External` since the path doesn't fall under the package directory.
    Reference,

    /// Copy into `<package>/media/` first, then reference the copy. On Mac this is what
    /// `importPastedImageData`, `captureCurrentFrameToMedia`, and the agent's `import_media` tool
    /// do — never a plain user-initiated Finder/drag import. `ToManifestEntry` then stores it as
    /// `MediaSource.Project` (path now falls under the package directory).
    Copy,
}

public sealed class MediaImportException(string message) : Exception(message);

public sealed record MediaImportItem(MediaAsset Asset, bool WasAlreadyImported);

public sealed record MediaImportFailure(string Path, string Message);

public sealed record MediaImportSummary(IReadOnlyList<MediaImportItem> Imported, IReadOnlyList<MediaImportFailure> Failed);

/// Imports files into an open <see cref="ProjectDocument"/>'s media manifest. Ports the
/// file-handling half of `EditorViewModel+MediaLibrary.swift`'s import path
/// (`addMediaAsset`/`applyMediaImportPlan`'s file leg, `finalizeImportedAsset`'s metadata-probe
/// branch, `MediaAsset.toManifestEntry`) — undo registration, drag-payload parsing, and kicking off
/// `MediaVisualCache` generation are ViewModel-layer concerns for a later stage, not this service's
/// job. A per-file problem (unsupported extension, missing/unreadable media, copy failure) is
/// recorded in the returned summary and the batch continues — one bad file in a multi-file drop
/// must never abort the rest, mirroring the Mac's non-fatal `mediaPanelToast` messaging.
public sealed class MediaImportService(IMediaProbe probe)
{
    /// Directory entries in `paths` are scanned recursively — inaccessible subdirectories and
    /// hidden/system entries are skipped and nested-unsupported files are dropped silently, same
    /// as `MediaImportScanner`'s folder walk (see `ExpandPaths`/`ImportOneAsync` remarks) — and
    /// every file underneath is imported flat into `folderId`; building matching `MediaFolder`
    /// subtree structure is a MediaPanel/ViewModel concern, out of scope here.
    public async Task<MediaImportSummary> ImportAsync(
        ProjectDocument document,
        IReadOnlyList<string> paths,
        string? folderId = null,
        MediaImportMode mode = MediaImportMode.Reference,
        CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(document);
        ArgumentNullException.ThrowIfNull(paths);

        var imported = new List<MediaImportItem>();
        var failed = new List<MediaImportFailure>();
        foreach ((string path, bool isRoot) in ExpandPaths(paths))
        {
            ct.ThrowIfCancellationRequested();
            try
            {
                MediaImportItem? item = await ImportOneAsync(document, path, folderId, mode, isRoot, ct).ConfigureAwait(false);
                if (item is not null)
                {
                    imported.Add(item);
                }
            }
            catch (MediaImportException ex)
            {
                failed.Add(new MediaImportFailure(path, ex.Message));
            }
        }
        return new MediaImportSummary(imported, failed);
    }

    /// `isRoot` mirrors `MediaImportScanner.scanFile`'s `isRootItem`: true only for an entry that
    /// was itself one of the literal `paths` passed in (a file dropped directly, not discovered by
    /// walking a directory) — every file found by recursing into a directory is `isRoot: false`,
    /// no matter how shallow. `ImportOneAsync` uses this to decide whether an unsupported-extension
    /// file is worth surfacing as a failure at all (see its remarks).
    private static IEnumerable<(string Path, bool IsRoot)> ExpandPaths(IReadOnlyList<string> paths)
    {
        // IgnoreInaccessible=true: skip a directory we can't enumerate (ACL-locked, a OneDrive
        // placeholder, "System Volume Information", $RECYCLE.BIN — all reachable from a plain
        // folder/drive drop) instead of throwing UnauthorizedAccessException/IOException out of
        // this iterator and aborting the whole import — mirrors MediaImportScanner.directoryEntries'
        // `try? FileManager...contentsOfDirectory`, which just skips what it can't read.
        // AttributesToSkip Hidden|System mirrors `.skipsHiddenFiles` (desktop.ini, Thumbs.db,
        // .git/, node_modules dotfiles, etc. never enter the walk at all).
        var options = new EnumerationOptions
        {
            RecurseSubdirectories = true,
            IgnoreInaccessible = true,
            AttributesToSkip = FileAttributes.Hidden | FileAttributes.System,
        };
        foreach (string path in paths)
        {
            if (Directory.Exists(path))
            {
                foreach (string file in Directory.EnumerateFiles(path, "*", options))
                {
                    yield return (file, IsRoot: false);
                }
            }
            else
            {
                yield return (path, IsRoot: true);
            }
        }
    }

    /// Returns null (no import, no failure recorded) for a nested (`isRoot: false`)
    /// unsupported-extension file — mirrors `MediaImportScanner.scanFile`'s
    /// `if isRootItem { plan.rejectedUnsupportedNames.append(...) }`: only a root-level unsupported
    /// item is worth telling the user about; a stray dotfile or tooling-directory member three
    /// levels inside a dropped folder is not.
    private async Task<MediaImportItem?> ImportOneAsync(ProjectDocument document, string path, string? folderId, MediaImportMode mode, bool isRoot, CancellationToken ct)
    {
        string fileName = Path.GetFileName(path);
        if (!File.Exists(path))
        {
            throw new MediaImportException($"\"{fileName}\" not found.");
        }

        string ext = Path.GetExtension(path).TrimStart('.').ToLowerInvariant();
        if (!ClipTypeExtensions.TryFromFileExtension(ext, out ClipType type))
        {
            if (!isRoot)
            {
                return null;
            }
            throw new MediaImportException($"Can't import \"{fileName}\" — unsupported file type.");
        }

        // Not a Mac behavior (Finder/drag import there always creates a fresh asset id, even for a
        // re-imported path) — a deliberate Windows-side addition so re-selecting an already-linked
        // file in the picker doesn't silently duplicate a manifest entry.
        if (FindExistingAssetByResolvedPath(document, path) is { } existing)
        {
            return new MediaImportItem(existing, WasAlreadyImported: true);
        }

        string assetPath = mode == MediaImportMode.Copy
            ? await CopyIntoPackageAsync(document.PackagePath, path, ct).ConfigureAwait(false)
            : path;

        var asset = new MediaAsset(assetPath, type, Path.GetFileNameWithoutExtension(path)) { FolderId = folderId };

        bool readable;
        try
        {
            readable = await asset.LoadMetadataAsync(probe).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            throw new MediaImportException($"Couldn't read \"{fileName}\": {ex.Message}");
        }
        if (!readable)
        {
            throw new MediaImportException(File.Exists(assetPath)
                ? $"Couldn't read \"{fileName}\" — unsupported or corrupt media."
                : $"\"{fileName}\" is missing.");
        }

        document.Manifest.Entries.Add(asset.ToManifestEntry(document.PackagePath));
        return new MediaImportItem(asset, WasAlreadyImported: false);
    }

    private static MediaAsset? FindExistingAssetByResolvedPath(ProjectDocument document, string path)
    {
        string normalized = Path.GetFullPath(path);
        foreach ((string id, string url) in MediaResolver.ExpectedUrlMapFor(document.Manifest.Entries, document.PackagePath))
        {
            if (!string.Equals(Path.GetFullPath(url), normalized, StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }
            MediaManifestEntry entry = document.Manifest.Entries.First(e => e.Id == id);
            return MediaAsset.FromManifestEntry(entry, url);
        }
        return null;
    }

    /// Mirrors the package-relative naming the Mac uses for content it copies in
    /// (`<project>/media/<original-or-generated-name>`) — collisions get a " N" suffix rather than
    /// overwriting, since (unlike the Mac's `imported-<id8>.<ext>` agent-import naming) a plain
    /// Finder-style copy keeps the user's original filename.
    private static async Task<string> CopyIntoPackageAsync(string packagePath, string sourcePath, CancellationToken ct)
    {
        string mediaDir = ProjectPackage.MediaDirectoryPath(packagePath);
        Directory.CreateDirectory(mediaDir);
        string destPath = Path.Combine(mediaDir, UniqueFileName(mediaDir, Path.GetFileName(sourcePath)));
        try
        {
            await using var source = new FileStream(sourcePath, FileMode.Open, FileAccess.Read, FileShare.Read, 81920, useAsync: true);
            await using var dest = new FileStream(destPath, FileMode.CreateNew, FileAccess.Write, FileShare.None, 81920, useAsync: true);
            await source.CopyToAsync(dest, ct).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            throw new MediaImportException($"Couldn't copy \"{Path.GetFileName(sourcePath)}\" into the project: {ex.Message}");
        }
        return destPath;
    }

    private static string UniqueFileName(string directory, string fileName)
    {
        string stem = Path.GetFileNameWithoutExtension(fileName);
        string ext = Path.GetExtension(fileName);
        string candidate = fileName;
        for (int n = 1; File.Exists(Path.Combine(directory, candidate)); n++)
        {
            candidate = $"{stem} {n}{ext}";
        }
        return candidate;
    }
}
