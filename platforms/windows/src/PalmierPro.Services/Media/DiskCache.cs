using System.Security.Cryptography;
using System.Text;
using PalmierPro.Services.Project;

namespace PalmierPro.Services.Media;

/// Ports `Utilities/DiskCache.swift`: a named directory under the app's cache root, plus a
/// `(path, size, mtime)` key so a source-file edit busts any entry keyed off it. Scoped to
/// `PalmierPro.Services.Media` for now (only <see cref="MediaVisualCache"/> uses it) — move up if
/// a second subsystem needs a disk cache.
public sealed class DiskCache
{
    public string Directory { get; }

    public DiskCache(string name, string? rootDirectory = null)
    {
        ArgumentException.ThrowIfNullOrEmpty(name);
        Directory = Path.Combine(rootDirectory ?? AppPaths.CacheDirectory, name);
        System.IO.Directory.CreateDirectory(Directory);
    }

    /// Cache-key fragment that changes when the file at `path` is replaced. `File.Exists` guards
    /// the same way Swift's `try? attributesOfItem` does — a deleted/inaccessible file yields no
    /// key rather than throwing, so callers naturally skip the cache and go straight to
    /// live extraction.
    public static string? SizeMtimeKey(string path)
    {
        if (!File.Exists(path))
        {
            return null;
        }
        var info = new FileInfo(path);
        var seed = $"{Path.GetFullPath(path)}|{info.Length}|{info.LastWriteTimeUtc.Ticks}";
        var hash = SHA256.HashData(Encoding.UTF8.GetBytes(seed));
        return Convert.ToHexStringLower(hash.AsSpan(0, 16));
    }

    public string PathFor(string key, string extension) => Path.Combine(Directory, key + extension);
}
