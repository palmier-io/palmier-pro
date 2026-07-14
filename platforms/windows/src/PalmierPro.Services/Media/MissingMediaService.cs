using PalmierPro.Core.Models;
using PalmierPro.Services.Project;

namespace PalmierPro.Services.Media;

/// Thin async wrapper around Core's `MediaResolver.MissingAssetIds`, mirroring the Mac's
/// `EditorViewModel.refreshMissingMediaCache()` (off-main-thread compute, published back for UI
/// "offline" badges) — the media-panel-wide surface, covering every manifest entry regardless of
/// timeline placement. Distinct from `TimelineSnapshotBuilder`'s `OfflineMediaRefs`/the
/// `IVideoEngine.MediaStatus` surface, which only covers refs actually placed on the timeline
/// currently being rendered.
///
/// TODO(Phase 2, generation): the Mac's `refreshMissingMediaCache()` additionally computes
/// `missing.subtracting(recovering)` where `recovering` = assets with `isGenerating ||
/// isRecoveringGeneration` — an asset whose file hasn't landed on disk YET because it's mid
/// AI-generation is not "offline," it's "in progress," and must not get the same badge. This
/// wrapper doesn't do that subtraction. Harmless today (Phase 1 has no generation, so no asset can
/// ever be in that state) but once generation lands, a consumer using DetectAsync for offline
/// badges will incorrectly flag an in-progress generated asset as missing until this threads the
/// generating/recovering id set through and subtracts it here.
public sealed class MissingMediaService
{
    public Task<IReadOnlySet<string>> DetectAsync(ProjectDocument document, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(document);
        return DetectAsync(document.Manifest, document.PackagePath, ct);
    }

    public Task<IReadOnlySet<string>> DetectAsync(MediaManifest manifest, string? projectPath, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(manifest);
        var entries = manifest.Entries;
        return Task.Run(() =>
        {
            ct.ThrowIfCancellationRequested();
            return (IReadOnlySet<string>)MediaResolver.MissingAssetIds(entries, projectPath);
        }, ct);
    }
}
