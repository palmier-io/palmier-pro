using PalmierPro.Core.Models;
using PalmierPro.Core.Serialization;

namespace PalmierPro.Core.Project;

/// <summary>Folder path resolve/create and organize mutations on MediaManifest.</summary>
public static class MediaFolderOps
{
    public static string PathFor(MediaManifest manifest, string folderId)
    {
        var parts = new List<string>();
        var id = folderId;
        var guard = 0;
        while (!string.IsNullOrEmpty(id) && guard++ < 64)
        {
            var folder = manifest.Folders.FirstOrDefault(f => f.Id == id);
            if (folder is null) break;
            parts.Add(folder.Name);
            id = folder.ParentFolderId ?? "";
        }
        parts.Reverse();
        return string.Join('/', parts);
    }

    public static string? ResolveFolderId(MediaManifest manifest, string? path)
    {
        if (string.IsNullOrWhiteSpace(path)) return null;
        var segments = path.Split('/', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        string? parent = null;
        foreach (var seg in segments)
        {
            var next = manifest.Folders.FirstOrDefault(f =>
                string.Equals(f.Name, seg, StringComparison.OrdinalIgnoreCase)
                && f.ParentFolderId == parent);
            if (next is null) return null;
            parent = next.Id;
        }
        return parent;
    }

    public static string ResolveOrCreateFolder(MediaManifest manifest, string path)
    {
        var segments = path.Split('/', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        string? parent = null;
        foreach (var seg in segments)
        {
            var existing = manifest.Folders.FirstOrDefault(f =>
                string.Equals(f.Name, seg, StringComparison.OrdinalIgnoreCase)
                && f.ParentFolderId == parent);
            if (existing is not null)
            {
                parent = existing.Id;
                continue;
            }
            var created = new MediaFolder { Id = Uuid.NewString(), Name = seg, ParentFolderId = parent };
            manifest.Folders.Add(created);
            parent = created.Id;
        }
        return parent ?? throw new InvalidOperationException("Empty folder path.");
    }

    public static string CreateFolder(MediaManifest manifest, string name, string? parentPath)
    {
        string? parentId = null;
        if (!string.IsNullOrWhiteSpace(parentPath))
            parentId = ResolveOrCreateFolder(manifest, parentPath);
        var folder = new MediaFolder { Name = name.Trim(), ParentFolderId = parentId };
        manifest.Folders.Add(folder);
        return folder.Id;
    }
}
