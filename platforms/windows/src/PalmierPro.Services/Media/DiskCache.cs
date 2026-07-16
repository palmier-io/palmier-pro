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

    /// Cache-key fragment for a source file's own *content* (docs/lottie-bake-v1.md §5) — SHA-256
    /// of the file's bytes, same hex-16 convention as <see cref="SizeMtimeKey"/>, but content
    /// identity rather than (path, length, mtime) identity: a project copy/move or a re-save of an
    /// unchanged export can touch mtime without touching a byte, which would spuriously invalidate
    /// under <see cref="SizeMtimeKey"/> — Lottie sources are small enough (typically well under a
    /// few hundred KB) that hashing the whole file is cheap. Same "no key rather than throwing"
    /// discipline as <see cref="SizeMtimeKey"/> for a missing/inaccessible file.
    public static string? ContentHashKey(string path)
    {
        if (!File.Exists(path))
        {
            return null;
        }
        try
        {
            using FileStream stream = File.OpenRead(path);
            byte[] hash = SHA256.HashData(stream);
            return Convert.ToHexStringLower(hash.AsSpan(0, 16));
        }
        catch (IOException)
        {
            return null;
        }
        catch (UnauthorizedAccessException)
        {
            return null;
        }
    }

    public string PathFor(string key, string extension) => Path.Combine(Directory, key + extension);
}
