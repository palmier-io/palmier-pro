using PalmierPro.Core.Models;
using PalmierPro.Services.Engine;

namespace PalmierPro.Services.Media;

/// One request to bake: a Lottie/dotLottie source file (already resolved to an absolute path via
/// <see cref="MediaResolver"/>) at a specific target pixel size. Two requests with the
/// same <see cref="SourcePath"/> but different sizes are independent bakes — see
/// docs/lottie-bake-v1.md §5.
public sealed record LottieBakeRequest(string MediaRef, string SourcePath, int Width, int Height);

public enum LottieBakeStatus
{
    /// Never requested via <see cref="ILottieBakeService.BakeAsync"/>, and nothing cached.
    NotStarted,
    InProgress,
    Completed,
    Failed,
}

/// Fired whenever a tracked bake's status changes. <see cref="OutputPath"/> is non-null only when
/// <see cref="Status"/> is <see cref="LottieBakeStatus.Completed"/>; <see cref="ErrorMessage"/> only
/// when <see cref="LottieBakeStatus.Failed"/>.
public sealed record LottieBakeStatusChangedEventArgs(
    string MediaRef,
    int Width,
    int Height,
    LottieBakeStatus Status,
    string? OutputPath,
    string? ErrorMessage);

/// Ports the video-bake half of `Preview/LottieVideoGenerator.swift` (its metadata/thumbnail half
/// is a separate, already-declared seam — <see cref="IMediaProbe.ProbeLottieAsync"/>,
/// see docs/lottie-bake-v1.md §11). Bakes a Lottie/dotLottie source to a disk-cached, alpha-capable
/// ProRes 4444 .mov via vendored ThorVG + native <c>PE_BakeLottieVideo</c>
/// (native/include/palmier_engine.h) so <c>TimelineSnapshotBuilder</c> can hand the compositor an
/// ordinary video clip instead of a clip type it has no render path for — see
/// docs/lottie-bake-v1.md for the full contract this interface implements. Lives in
/// <c>PalmierPro.Services.Media</c> (not <c>.Engine</c>, despite its <c>TimelineSnapshotBuilder</c>
/// caller): it is a media-derivative cache, the same conceptual family as
/// <see cref="MediaVisualCache"/>, not an engine/timeline concept itself.
public interface ILottieBakeService
{
    /// Non-blocking cache probe: returns the cached output path if a bake for this exact
    /// (content hash, size, bake version) key already completed, else <c>null</c>. Never triggers
    /// a bake itself — pair with <see cref="BakeAsync"/> (doc §4/§5).
    string? TryGetCachedPath(LottieBakeRequest request);

    /// Fire-and-forget, mirroring <see cref="MediaVisualCache.GenerateVideoThumbnails"/>: starts a
    /// background bake, or — if a bake for the IDENTICAL key (doc §5: content hash + size + bake
    /// version, not just <see cref="LottieBakeRequest.MediaRef"/>) is already in flight or already
    /// cached — does nothing. Progress/completion surface via <see cref="StatusChanged"/>, never
    /// through this call's own (unawaited) <see cref="Task"/>. Safe to call even when
    /// <see cref="TryGetCachedPath"/> would already return non-null; callers are not required to
    /// check first.
    void BakeAsync(LottieBakeRequest request, CancellationToken ct = default);

    /// Synchronous, locally-tracked status for one (MediaRef, Width, Height) key — same
    /// "tracked locally, not a native poll" convention as
    /// <see cref="IVideoEngine.IsPlaying"/>. <see cref="LottieBakeStatus.NotStarted"/> for a
    /// key <see cref="BakeAsync"/> was never called for AND nothing is cached on disk for.
    LottieBakeStatus StatusFor(string mediaRef, int width, int height);

    /// Fires whenever a tracked bake's status changes. A consumer (doc §10's
    /// <c>TimelineSnapshotBuilder</c> integration) reacts to <see cref="LottieBakeStatus.Completed"/>
    /// by rebuilding whichever open timeline referenced the clip — a newly-baked
    /// <c>mediaPath</c> is a structural change (<c>UpdateTimelineAsync</c>, never
    /// <c>RefreshParams</c> — see docs/timeline-snapshot-v1.md's Rebuild-vs-RefreshParams split)
    /// — and to <see cref="LottieBakeStatus.Failed"/> by leaving the clip's current
    /// (pending/invisible) presentation alone rather than retrying automatically.
    event EventHandler<LottieBakeStatusChangedEventArgs>? StatusChanged;
}
