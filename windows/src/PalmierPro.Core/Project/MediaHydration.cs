using PalmierPro.Core.Models;

namespace PalmierPro.Core.Project;

public sealed record HydratedLibrary(List<MediaAsset> Assets, HashSet<string> MissingRefs);

/// <summary>
/// Rebuilds runtime media assets from a loaded manifest on project open. The existence
/// scan touches the filesystem, so call from an off-UI-thread context.
/// </summary>
public static class MediaHydration
{
    public static HydratedLibrary Restore(MediaManifest manifest, string? projectPath)
    {
        var assets = new List<MediaAsset>(manifest.Entries.Count);
        var missing = new HashSet<string>();
        var seenIds = new HashSet<string>();
        foreach (var entry in manifest.Entries)
        {
            if (!seenIds.Add(entry.Id)) continue;
            var expected = ExpectedPath(entry, projectPath);
            var exists = expected is not null && File.Exists(expected);
            var asset = MediaAsset.FromEntry(entry, exists ? expected : null);
            if (!exists) missing.Add(entry.Id);
            ApplyInterruptedWorkPolicy(asset, exists);
            assets.Add(asset);
        }
        return new HydratedLibrary(assets, missing);
    }

    /// <summary>
    /// Missing + interrupted import fails; missing + resumable generation stays
    /// generating; present media clears leftover import state.
    /// </summary>
    private static void ApplyInterruptedWorkPolicy(MediaAsset asset, bool exists)
    {
        if (!exists)
        {
            if (asset.ImportInput is not null && asset.GenerationStatus.Phase != GenerationPhase.Failed)
                asset.GenerationStatus = GenerationState.Failed("Import interrupted");
            else if (asset.GenerationInput?.BackendJobId is not null)
                asset.GenerationStatus = GenerationState.Generating;
        }
        else if (asset.ImportInput is not null)
        {
            asset.ImportInput = null;
            if (asset.GenerationStatus.Phase != GenerationPhase.None)
                asset.GenerationStatus = GenerationState.None;
        }
    }

    private static string? ExpectedPath(MediaManifestEntry entry, string? projectPath) => entry.Source switch
    {
        MediaSource.External external when external.AbsolutePath.Length > 0 => external.AbsolutePath,
        MediaSource.Project project when projectPath is not null
            => Path.Combine(projectPath, project.RelativePath.Replace('/', Path.DirectorySeparatorChar)),
        _ => null,
    };
}
