using PalmierPro.Core.Models;
using PalmierPro.Rendering;

namespace PalmierPro.Services.Engine;

/// Ports `Preview/VideoEngine.swift`'s four `PreviewSeekMode` cases. `AudibleStepForward`/
/// `AudibleStepBackward` (and `InteractiveScrub`) get audio scrub feedback via the native
/// `PE_TimelineScrubAudio` ABI added by E4.5 — see docs/audio-playback-v1.md §5 for exactly
/// which modes pair with it. On the video-seek side all four still collapse to the same two
/// `PE_SeekMode` values (see <see cref="VideoEngine.ToNativeSeekMode"/>); this enum is the
/// only place all four are distinguished.
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

/// Raw linear-amplitude peak + RMS per channel from the most recently mixed audio block — the
/// native mix-bus tap (PE_TimelineGetAudioLevels, Stage E's AudioMeterView). NOT dB, NOT
/// ballistics-processed; PalmierPro.Core.Audio.AudioMeterHub owns the dB mapping/decay/peak-hold/
/// clip-latch math, mirroring the Mac's AudioMeterChannelState (Audio/AudioMeter.swift) exactly.
public readonly record struct AudioLevels(float LeftPeak, float LeftRms, float RightPeak, float RightRms)
{
    public static readonly AudioLevels Silence = new(0, 0, 0, 0);
}

/// One effect param override within a <see cref="ClipParamPatch"/> — identifies the effect by
/// `Type` (an effect list may contain at most one of a given type in practice, mirroring the
/// Mac's one-effect-instance-per-type convention) and the param by key (EffectRegistry.swift's
/// `EffectParamSpec.key`, e.g. "blacks"/"whites" for `color.blacksWhites`).
public sealed record EffectParamPatch(string EffectType, string ParamKey, double Value);

/// One clip's sparse param delta — only the fields `CompositionBuilder.buildVisuals`/
/// `VideoEngine.refreshVisuals()` can change without a structural rebuild. Any field left `null`
/// is unchanged. E3 semantics: applied in place against the engine's already-open timeline
/// session (<see cref="VideoEngine.RefreshParams"/>), no rebuild.
public sealed record ClipParamPatch(
    string ClipId,
    double? Opacity = null,
    Transform? Transform = null,
    Crop? Crop = null,
    double? VolumeGain = null,
    BlendMode? BlendMode = null,
    IReadOnlyList<EffectParamPatch>? Effects = null);

public sealed record TimelineParamPatch(string TimelineId, IReadOnlyList<ClipParamPatch> Clips);

public sealed record PlayheadChangedEventArgs(string TimelineId, int Frame);

/// The UI↔engine contract for timeline/source preview — the C# mirror of `Preview/VideoEngine.swift`.
/// See docs/timeline-snapshot-v1.md for the JSON shape `OpenTimelineSessionAsync`/
/// `UpdateTimelineAsync` exchange with native. Every method here is safe to call against the real
/// implementation (<see cref="VideoEngine"/>) — see its class remarks for exactly which native ABI
/// call each one lands on.
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

    /// Parameter-only change (opacity/transform/crop/volume/blendMode/effect-param edits with no
    /// structural change) → refresh without a rebuild. Mirrors `refreshVisuals()` — this split is
    /// what makes live slider feedback possible while dragging. Applied against the engine's
    /// already-open timeline session via PE_TimelineRefreshParams, which asserts the media set is
    /// unchanged and fails loudly (see <see cref="VideoEngine"/>) rather than silently rebuilding
    /// if it isn't — a genuine no-op if no session for `patch.TimelineId` is open yet (nothing to
    /// refresh).
    void RefreshParams(TimelineParamPatch patch);

    /// Frees the native session/composition cache for a closed or evicted timeline tab. Mirrors
    /// `evictComposition(for:)`. Safe to call even if no session for `timelineId` was ever
    /// successfully opened (cleanup/tab-close paths must not fail).
    void EvictTimeline(string timelineId);

    /// Seeks `timelineId`'s preview playhead. All four <see cref="PreviewSeekMode"/> cases are
    /// accepted; <see cref="PreviewSeekMode.InteractiveScrub"/> is expected to be coalesced by the
    /// implementation (see <see cref="SeekCoordinator"/>), not by the caller. Valid to call while
    /// <see cref="Play"/>ing — this rebases the A/V clock and playback continues; it does not
    /// implicitly pause (see docs/audio-playback-v1.md §3.3). E4.5's real implementation additionally
    /// issues a native `PE_TimelineScrubAudio` call whenever `mode != Exact` (audio scrub feedback —
    /// see docs/audio-playback-v1.md §5); a v1 stub implementation may leave that half unimplemented.
    void Seek(string timelineId, int frame, PreviewSeekMode mode);

    /// Starts (or resumes) continuous playback of `timelineId` from its current playhead position.
    /// Mirrors `VideoEngine.play()`. Idempotent — safe to call while already playing. → native
    /// `PE_TimelinePlay`; see docs/audio-playback-v1.md §3/§4/§7.
    void Play(string timelineId);

    /// Stops continuous playback of `timelineId`, freezing the A/V clock at its current position.
    /// Mirrors `VideoEngine.pause()`. Idempotent — safe to call while already paused. → native
    /// `PE_TimelinePause`; see docs/audio-playback-v1.md §3/§4/§7.
    void Pause(string timelineId);

    /// Sets `timelineId`'s playback rate. v1 accepts only 0.0 (equivalent to <see cref="Pause"/>) or
    /// 1.0 (equivalent to <see cref="Play"/>) — any other value should fail fast on the C# side
    /// rather than rely solely on the native `PE_ERROR_INVALID_ARGUMENT` round-trip. → native
    /// `PE_TimelineSetRate`; see docs/audio-playback-v1.md §4 for why the primitive is more general
    /// than what Phase 1 actually exercises.
    void SetRate(string timelineId, double rate);

    /// Synchronous GPU compute of `timelineId`'s live color scopes at `frame` — the Inspector
    /// Adjust tab's Curves/Hue Curves editors' data source (docs/color-scopes-v1.md). Mirrors
    /// `VideoEngine.swift`'s `histogramYRGB`/`hueHistogram`, ported as ONE combined call (doc
    /// §4's last bullet: a single shared <see cref="ColorScopesResult"/> for both editors, not
    /// the Mac's two independent fetches). Returns `null` if no session for `timelineId` is open
    /// yet. → native `PE_TimelineComputeColorScopes`, run on a background `Task` (doc §5) — the
    /// compose + GPU readback cost is not free, and this must never be awaited on the UI thread.
    /// Caller discipline (never while <see cref="IsPlaying"/>, coalesced, unreachable while the
    /// Adjust tab isn't selected) is the Inspector ViewModel's responsibility (doc §4), not this
    /// call's.
    Task<ColorScopesResult?> GetColorScopesAsync(string timelineId, int frame, CancellationToken ct = default);

    /// Synchronous query of whether `timelineId` is currently playing. Not backed by a native poll
    /// call — the real implementation tracks last-known state locally (updated by
    /// <see cref="Play"/>/<see cref="Pause"/>/<see cref="SetRate"/> and by
    /// <see cref="IsPlayingChanged"/>, including the engine's own auto-stop at timeline end — see
    /// docs/audio-playback-v1.md §3.5). `false` for a timeline that was opened but never played.
    bool IsPlaying(string timelineId);

    /// Master meter tap (Stage E, AudioMeterView) — see <see cref="AudioLevels"/>. Same
    /// "call OpenTimelineSessionAsync first" contract as <see cref="Play"/>/<see cref="Pause"/>:
    /// throws <see cref="InvalidOperationException"/> if no open session exists for
    /// <paramref name="timelineId"/>. Callers are expected to only poll this while
    /// <see cref="IsPlaying"/> is true — the tap doesn't move otherwise.
    AudioLevels GetAudioLevels(string timelineId);

    /// Opens the media-panel source-preview surface for one asset — distinct from timeline
    /// preview (mirrors the Mac's `previewAsset`/`activePreviewTab` split). Only one asset preview
    /// is open at a time; opening a new one implicitly closes the previous.
    Task OpenAssetPreviewAsync(string mediaPath, CancellationToken ct = default);

    /// Seeks the currently open asset preview. `timelineFps` is the ACTIVE TIMELINE's fps, not the
    /// asset's own decoded fps — `frame` is always expressed in timeline fps on the C# side (see
    /// <c>PreviewViewModel.SourceDurationFrames</c>/<c>SourceFrame</c>), mirroring the Mac's
    /// `CMTime(value: frame, timescale: editor.timeline.fps)` (VideoEngine.swift). Throws
    /// <see cref="InvalidOperationException"/> if no asset preview is open.
    void SeekAssetPreview(int frame, PreviewSeekMode mode, int timelineFps);

    /// Closes the open asset preview (a no-op if none is open) and, if it was the surface
    /// currently receiving swap-chain output, hands presentation back to whichever timeline
    /// <see cref="SetActiveTimeline"/> last designated — same "switch back cleanly" contract as
    /// calling <see cref="SetAssetPreviewActive"/>(false) first, but callers only need this one
    /// call (see <see cref="VideoEngine"/>'s remarks).
    void CloseAssetPreview();

    /// Designates which open timeline session receives swap-chain compose/present output — the
    /// Preview UI (Stage D) calls this on every active-timeline switch (tab change, or a fresh
    /// document's first open) so the one swap chain the single project window owns always shows
    /// whichever timeline is active, mirroring the Mac's one-AVPlayerLayer-follows-activePreviewTab
    /// behavior. Safe to call with a `timelineId` that has no open session yet, or with `null`
    /// (nothing presents); the attach happens/moves lazily once a session for it exists AND a swap
    /// chain panel is currently attached via <see cref="AttachSwapChain"/> — see
    /// <see cref="VideoEngine"/>'s remarks. UI-thread call whenever a swap chain panel is currently
    /// attached (this may perform PE_TimelineAttachSwapChain/PE_TimelineDetachSwapChain under the
    /// hood) — see palmier_engine.h's swap-chain threading contract.
    ///
    /// Does NOT hand presentation to a timeline while an asset preview is active (see
    /// <see cref="SetAssetPreviewActive"/>) — bookkeeping for `timelineId` is still updated (so it's
    /// ready the moment asset-preview mode ends), but the swap chain stays put. Mirrors the Mac's
    /// `VideoEngine.rebuild()` early-returning while `activePreviewTab != .timeline`: a structural
    /// timeline edit while the media panel's source preview is on screen must not steal the one
    /// swap chain out from under it.
    void SetActiveTimeline(string? timelineId);

    /// Designates the open asset preview (see <see cref="OpenAssetPreviewAsync"/>), rather than any
    /// timeline session, as the surface that receives swap-chain compose/present output — the
    /// media-panel source-preview counterpart to <see cref="SetActiveTimeline"/>. Mutually exclusive
    /// with it: whichever of the two was activated most recently wins the one swap chain panel this
    /// window owns. `active: false` hands presentation back to whichever timeline
    /// <see cref="SetActiveTimeline"/> last designated, without needing to re-pass its id. UI-thread
    /// call whenever a swap chain panel is currently attached — same threading contract as
    /// <see cref="SetActiveTimeline"/>.
    void SetAssetPreviewActive(bool active);

    // Swap-chain passthrough — single project window in Phase 1 (see plan's window-model
    // decision), so these take no timelineId; presentation itself still routes to whichever
    // timeline SetActiveTimeline last designated (see VideoEngine's remarks).
    void AttachSwapChain(object swapChainPanel, int width, int height);
    void ResizeSwapChain(int width, int height);
    void DetachSwapChain();

    /// Fires once per frame the native engine actually composes/presents — on a seek, or
    /// continuously during <see cref="Play"/> against the A/V clock (→ native
    /// `PE_PlayheadCallback`, broadened by E4.5 — see docs/audio-playback-v1.md §3.5/§4). Declared
    /// since Stage B so the Preview ViewModel could be built against a stable event contract ahead
    /// of the native present loop; <see cref="VideoEngine"/> now raises it from both paths. May run
    /// on a native background thread — marshal to the UI thread in the subscriber.
    event EventHandler<PlayheadChangedEventArgs>? PlayheadChanged;

    /// Fires whenever `IsPlaying` actually transitions — <see cref="Play"/>/<see cref="Pause"/>/
    /// <see cref="SetRate"/>, AND the engine's own automatic stop at timeline end (→ native
    /// `PE_TimelineSetIsPlayingCallback`, E4.5 — see docs/audio-playback-v1.md §3.5/§4/§7).
    /// Declared since Stage B for the same reason as <see cref="PlayheadChanged"/>; same
    /// thread-marshaling contract.
    event EventHandler<bool>? IsPlayingChanged;

    /// Fires after every successful <see cref="OpenTimelineSessionAsync"/>/<see cref="UpdateTimelineAsync"/>
    /// with the union of builder-side and engine-side media problems — see <see cref="MediaStatus"/>.
    event EventHandler<MediaStatus>? MediaStatusChanged;
}
