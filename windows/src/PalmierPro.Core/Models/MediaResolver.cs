namespace PalmierPro.Core.Models;

/// <summary>Resolves asset IDs to file paths using the media manifest.</summary>
public sealed class MediaResolver
{
    private readonly Func<MediaManifest> _manifest;
    private readonly Func<string?> _projectPath;

    public MediaResolver(Func<MediaManifest> manifest, Func<string?> projectPath)
    {
        _manifest = manifest;
        _projectPath = projectPath;
    }

    public string? ResolvePath(string assetId)
    {
        var path = ExpectedPath(assetId);
        return path is not null && File.Exists(path) ? path : null;
    }

    public string? ExpectedPath(string assetId)
    {
        var entry = Entry(assetId);
        return entry is null ? null : ExpectedPath(entry, _projectPath());
    }

    public Dictionary<string, string> ExpectedPathMap()
        => ExpectedPathMap(_manifest().Entries, _projectPath());

    public MediaResolver Snapshot()
    {
        var manifest = _manifest();
        var projectPath = _projectPath();
        return new MediaResolver(() => manifest, () => projectPath);
    }

    public static Dictionary<string, string> ExpectedPathMap(IReadOnlyList<MediaManifestEntry> entries, string? projectPath)
    {
        var seenIds = new HashSet<string>();
        var paths = new Dictionary<string, string>(entries.Count);
        foreach (var entry in entries)
        {
            if (!seenIds.Add(entry.Id)) continue;
            if (ExpectedPath(entry, projectPath) is { } path)
            {
                paths[entry.Id] = path;
            }
        }
        return paths;
    }

    private static string? ExpectedPath(MediaManifestEntry entry, string? projectPath) => entry.Source switch
    {
        MediaSource.External external => external.AbsolutePath,
        MediaSource.Project project => projectPath is null ? null : Path.Combine(projectPath, project.RelativePath),
        _ => null,
    };

    public bool IsMissing(string assetId)
    {
        var path = ExpectedPath(assetId);
        return path is null || !File.Exists(path);
    }

    /// <summary>Asset IDs whose backing file is missing on disk, from a snapshot of manifest entries + the project base path.</summary>
    public static HashSet<string> MissingAssetIds(IReadOnlyList<MediaManifestEntry> entries, string? projectPath)
    {
        var missing = new HashSet<string>();
        foreach (var entry in entries)
        {
            var path = ExpectedPath(entry, projectPath);
            if (path is null || !File.Exists(path))
            {
                missing.Add(entry.Id);
            }
        }
        return missing;
    }

    public string DisplayName(string assetId) => Entry(assetId)?.Name ?? "Offline";

    public MediaManifestEntry? Entry(string assetId)
        => _manifest().Entries.FirstOrDefault(e => e.Id == assetId);
}
