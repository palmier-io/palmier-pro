using PalmierPro.Core.Models;
using PalmierPro.Core.Serialization;

namespace PalmierPro.Core.Project;

public sealed record MediaImportPlan(
    List<MediaFolder> NewFolders,
    List<MediaImportItem> Items);

/// <summary>A file to register as an external-source library asset.</summary>
public sealed record MediaImportItem(string Path, ClipType Type, string? FolderId);

/// <summary>
/// Scans dropped or picked Finder items into an import plan: supported files become
/// external-source assets, directories become folders mirroring the tree. Reference
/// import only — nothing is copied into the package. Run off the UI thread.
/// </summary>
public static class MediaImportScanner
{
    public static MediaImportPlan Scan(
        IReadOnlyList<string> roots,
        string? destinationFolderId,
        CancellationToken ct = default)
    {
        var folders = new List<MediaFolder>();
        var items = new List<MediaImportItem>();
        foreach (var root in roots)
        {
            ct.ThrowIfCancellationRequested();
            if (Directory.Exists(root))
            {
                ScanDirectory(root, destinationFolderId, folders, items, ct);
            }
            else if (File.Exists(root) && Classify(root) is { } type)
            {
                items.Add(new MediaImportItem(root, type, destinationFolderId));
            }
        }
        return new MediaImportPlan(folders, items);
    }

    private static void ScanDirectory(
        string directory,
        string? parentFolderId,
        List<MediaFolder> folders,
        List<MediaImportItem> items,
        CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        var folder = new MediaFolder
        {
            Id = Uuid.NewString(),
            Name = Path.GetFileName(Path.TrimEndingDirectorySeparator(directory)),
            ParentFolderId = parentFolderId,
        };
        var countBefore = items.Count + folders.Count;
        folders.Add(folder);

        foreach (var file in Directory.EnumerateFiles(directory))
        {
            if (Classify(file) is { } type)
                items.Add(new MediaImportItem(file, type, folder.Id));
        }
        foreach (var subdirectory in Directory.EnumerateDirectories(directory))
        {
            ScanDirectory(subdirectory, folder.Id, folders, items, ct);
        }

        // Prune folders that contributed no importable content.
        if (items.Count + folders.Count == countBefore + 1)
            folders.Remove(folder);
    }

    public static ClipType? Classify(string path)
    {
        var extension = Path.GetExtension(path).TrimStart('.');
        return extension.Length == 0 ? null : ClipTypeExtensions.FromFileExtension(extension);
    }
}
