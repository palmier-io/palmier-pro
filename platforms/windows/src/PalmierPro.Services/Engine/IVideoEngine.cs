using PalmierPro.Core.Models;
using PalmierPro.Rendering;

namespace PalmierPro.Services.Engine;

/// Ports `Preview/VideoEngine.swift`'s four `PreviewSeekMode` cases. `AudibleStepForward`/
/// `AudibleStepBackward` land with E4.5 (audio playback / `ScrubAudioEngine` port) — the case
/// exists now so UI code (frame-step buttons) can be written against the final surface; until
/// E4.5, the native engine treats them the same as `Exact` (silent, no scrub-audio feedback).
public enum PreviewSeekMode
{
    /// Decode-accurate; used on settle/pause and for direct playhead entry.
    Exact,
    /// Tolerance-based, latest-wins coalesced (~30 Hz) — see <see cref="SeekCoordinator"/>.
    InteractiveScrub,
    AudibleStepForward,
    AudibleStepBackward,
}

/// Offline refs come from <see cref="TimelineSnapshotBuilder"/> (path resolution, at snapshot-build
/// time); unprocessable refs come from the engine (decode-time failures, discovered only once
/// native actually tries to open the file) — see docs/timeline-snapshot-v1.md §8. Populated from
/// PE_TimelineGetUnprocessableMediaRefsJson after every Open/UpdateTimelineAsync (see
/// <see cref="VideoEngine"/>).
public sealed record MediaStatus(IReadOnlySet<string> OfflineMediaRefs, IReadOnlySet<string> UnprocessableMediaRefs)
{
    public static readonly MediaStatus Empty = new(new HashSet<string>(), new HashSet<string>());
}

/// One clip's sparse param delta — only the fields `CompositionBuilder.buildVisuals`/
/// `VideoEngine.refreshVisuals()` can change without a structural rebuild. Any field left `null`
/// is unchanged. E3 semantics: applied in place against the engine's already-open timeline session,
/// no rebuild. v1: see remarks on <see cref="IVideoEngine.RefreshParams"/> — reserved shape only.
public sealed record ClipParamPatch(
    string ClipId,
    double? Opacity = null,
    Transform? Transform = null,
    Crop? Crop = null,
    double? VolumeGain = null,
    BlendMode? BlendMode = null);

public sealed record TimelineParamPatch(string TimelineId, IReadOnlyList<ClipParamPatch> Clips);

public sealed record PlayheadChangedEventArgs(string TimelineId, int Frame);

/// The UI↔engine contract for timeline/source preview — the C# mirror of `Preview/VideoEngine.swift`.
/// See docs/timeline-snapshot-v1.md for the JSON shape `OpenTimelineSessionAsync`/
/// `UpdateTimelineAsync` exchange with native once E2 lands. Every method here is safe to call
/// from the v1 stub implementation (<see cref="VideoEngine"/>) today — see its class remarks for
/// which calls actually do something yet vs. which are throw/no-op placeholders.
public interface IVideoEngine
{
    /// Opens a per-timeline engine session from a freshly-built snapshot, or rebuilds it if a
    /// session for `timelineId` already exists. Same cost/semantics as <see cref="UpdateTimelineAsync"/>
    /// — kept as a separate entry point (mirroring the Mac's `activateTab` first-open vs.
    /// mid-session `rebuild()`) so a future native ABI can distinguish "create" from "swap
    /// snapshot on an existing session" without a C#-side signature break.
    Task OpenTimelineSessionAsync(string timelineId, TimelineSnapshotBuildResult snapshot, CancellationToken ct = default);

    /// Structural change (edit that alters the clip list, trims, media refs, track order, or
    /// retiming) → async rebuild. Mirrors `VideoEngine.rebuild()`. Callers debounce (~120 ms,
    /// matching the Mac's `notifyTimelineChangedDebounced`) before invoking this — the debounce is
    /// the UI VM's responsibility, not this interface's.
    Task UpdateTimelineAsync(string timelineId, TimelineSnapshotBuildResult snapshot, CancellationToken ct = default);

    /// Parameter-only change (opacity/transform/crop/volume/blendMode edits with no structural
    /// change) → refresh without a rebuild. Mirrors `refreshVisuals()` — this split is what makes
    /// live slider feedback possible while dragging. E3 semantics: applied against the engine's
    /// per-clip GPU param state in place. v1: the native engine has no such state yet (no render
    /// graph — that's E3), so this is a safe no-op, not a throw — see <see cref="VideoEngine"/>.
    void RefreshParams(TimelineParamPatch patch);

    /// Frees the native session/composition cache for a closed or evicted timeline tab. Mirrors
    /// `evictComposition(for:)`. Safe to call even if no session for `timelineId` was ever
    /// successfully opened (cleanup/tab-close paths must not fail).
    void EvictTimeline(string timelineId);

    /// Seeks `timelineId`'s preview playhead. All four <see cref="PreviewSeekMode"/> cases are
    /// accepted; <see cref="PreviewSeekMode.InteractiveScrub"/> is expected to be coalesced by the
    /// implementation (see <see cref="SeekCoordinator"/>), not by the caller.
    void Seek(string timelineId, int frame, PreviewSeekMode mode);

    /// Opens the media-panel source-preview surface for one asset — distinct from timeline
    /// preview (mirrors the Mac's `previewAsset`/`activePreviewTab` split). Only one asset preview
    /// is open at a time; opening a new one implicitly closes the previous.
    Task OpenAssetPreviewAsync(string mediaPath, CancellationToken ct = default);

    /// Seeks the currently open asset preview. Throws <see cref="InvalidOperationException"/> if
    /// no asset preview is open.
    void SeekAssetPreview(int frame, PreviewSeekMode mode);

    void CloseAssetPreview();

    // Swap-chain passthrough — single project window in Phase 1 (see plan's window-model
    // decision), so these are not scoped per timeline.
    void AttachSwapChain(object swapChainPanel, int width, int height);
    void ResizeSwapChain(int width, int height);
    void DetachSwapChain();

    /// Wired in Stage D (M4, preview UI). v1 declares the surface now so the Preview ViewModel can
    /// be built against a stable event contract before the native present loop exists.
    event EventHandler<PlayheadChangedEventArgs>? PlayheadChanged;
    event EventHandler<bool>? IsPlayingChanged;

    /// Fires after every successful <see cref="OpenTimelineSessionAsync"/>/<see cref="UpdateTimelineAsync"/>
    /// with the union of builder-side and engine-side media problems — see <see cref="MediaStatus"/>.
    event EventHandler<MediaStatus>? MediaStatusChanged;
}
