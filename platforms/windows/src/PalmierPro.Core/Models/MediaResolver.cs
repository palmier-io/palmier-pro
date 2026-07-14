using System.Text.Json;

namespace PalmierPro.Core.Models;

/// Resolves asset IDs to file paths using the media manifest. Pure path/existence logic — nothing
/// here is media-framework-dependent, so (unlike <see cref="MediaAsset.LoadMetadataAsync"/>) no
/// probe seam is needed: `System.IO.File.Exists` is the direct portable equivalent of Swift's
/// `FileManager.default.fileExists(atPath:)`.
public sealed class MediaResolver
{
    private readonly Func<MediaManifest> _manifest;
    private readonly Func<string?> _projectPath;

    public MediaResolver(Func<MediaManifest> manifest, Func<string?> projectPath)
    {
        _manifest = manifest;
        _projectPath = projectPath;
    }

    public string? ResolveUrl(string assetId)
    {
        var url = ExpectedUrl(assetId);
        return url is not null && File.Exists(url) ? url : null;
    }

    public string? ExpectedUrl(string assetId)
    {
        var entry = Entry(assetId);
        return entry is null ? null : ExpectedUrlFor(entry, _projectPath());
    }

    public Dictionary<string, string> ExpectedUrlMap() => ExpectedUrlMapFor(_manifest().Entries, _projectPath());

    /// Freezes the manifest/project-path at their current values. Swift's `MediaManifest` is a
    /// value type, so `let manifest = manifest()` alone gets a true copy; ours is a mutable class
    /// (this port's shared struct-to-class convention), so a JSON round-trip stands in for that
    /// copy — otherwise the "snapshot" would keep aliasing the live, still-mutable manifest.
    public MediaResolver Snapshot()
    {
        var manifest = JsonSerializer.Deserialize<MediaManifest>(JsonSerializer.Serialize(_manifest()))!;
        var projectPath = _projectPath();
        return new MediaResolver(() => manifest, () => projectPath);
    }

    public static Dictionary<string, string> ExpectedUrlMapFor(IEnumerable<MediaManifestEntry> entries, string? projectPath)
    {
        var map = new Dictionary<string, string>();
        foreach (var entry in entries)
        {
            if (ExpectedUrlFor(entry, projectPath) is { } url)
            {
                map[entry.Id] = url;
            }
        }
        return map;
    }

    private static string? ExpectedUrlFor(MediaManifestEntry entry, string? projectPath) => entry.Source.Kind switch
    {
        MediaSourceKind.External => entry.Source.Path,
        MediaSourceKind.Project => projectPath is null ? null : Path.Combine(projectPath, entry.Source.Path),
        _ => throw new ArgumentOutOfRangeException(),
    };

    public bool IsMissing(string assetId)
    {
        var url = ExpectedUrl(assetId);
        return url is null || !File.Exists(url);
    }

    /// Computes the set of asset IDs whose backing file is missing on disk, from a snapshot of
    /// manifest entries + the project base path.
    public static HashSet<string> MissingAssetIds(IEnumerable<MediaManifestEntry> entries, string? projectPath)
    {
        var missing = new HashSet<string>();
        foreach (var entry in entries)
        {
            var path = entry.Source.Kind == MediaSourceKind.External
                ? entry.Source.Path
                : projectPath is null ? null : Path.Combine(projectPath, entry.Source.Path);
            if (path is null || !File.Exists(path))
            {
                missing.Add(entry.Id);
            }
        }
        return missing;
    }

    public string DisplayName(string assetId) => Entry(assetId)?.Name ?? "Offline";

    public MediaManifestEntry? Entry(string assetId) => _manifest().Entries.FirstOrDefault(e => e.Id == assetId);
}
