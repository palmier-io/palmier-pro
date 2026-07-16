using PalmierPro.Core.Effects;
using PalmierPro.Rendering;
using EffectParam = PalmierPro.Core.Models.EffectParam;

namespace PalmierPro.Services.Engine;

/// Ports `VideoEngine.swift`'s interactive-scrub coalescing (`enqueueInteractiveSeek`/
/// `flushPendingInteractiveSeek`): latest-wins, throttled to ~30 Hz, with a load-adaptive
/// tolerance. Pure scheduling logic — no native/engine dependency, fully unit-testable by
/// injecting a synchronous `schedule` delegate (see <c>SeekCoordinatorTests</c>).
public sealed class SeekCoordinator
{
    private static readonly TimeSpan InteractiveSeekInterval = TimeSpan.FromSeconds(1.0 / 30.0);

    private readonly Action<int, TimeSpan> _performSeek;
    private readonly Func<DateTime> _now;
    private readonly Action<TimeSpan, Action> _schedule;
    private readonly Lock _gate = new();
    private (int Frame, TimeSpan Tolerance)? _pending;
    private bool _flushScheduled;
    private DateTime _lastDispatch = DateTime.MinValue;

    /// `schedule` fires `callback` once, after (at least) `delay` — defaults to a one-shot
    /// <see cref="Timer"/>. Tests inject a synchronous "call immediately" scheduler to avoid real
    /// wall-clock waits.
    public SeekCoordinator(Action<int, TimeSpan> performSeek, Func<DateTime>? now = null, Action<TimeSpan, Action>? schedule = null)
    {
        _performSeek = performSeek;
        _now = now ?? (() => DateTime.UtcNow);
        _schedule = schedule ?? DefaultSchedule;
    }

    /// Mac: `min(0.75s, 0.15s × max(1, activeLayerCount))` — see `interactiveTolerance(activeLayerCount:)`.
    /// Computed and passed through <see cref="Flush"/> to whichever `performSeek` a caller
    /// supplies, but as of v1 no caller actually applies it to a decode: <see
    /// cref="VideoEngine.PerformAssetPreviewSeek"/> ignores it (PE_PresentFrameAt has no
    /// tolerance parameter), and timeline scrub doesn't route through this coordinator at all —
    /// see <see cref="VideoEngine.Seek"/>'s remarks.
    public static TimeSpan InteractiveTolerance(int activeVideoLayerCount) =>
        TimeSpan.FromSeconds(Math.Min(0.75, 0.15 * Math.Max(1, activeVideoLayerCount)));

    /// `InteractiveScrub` is enqueued/coalesced; every other mode cancels any pending coalesced
    /// seek and dispatches immediately at zero tolerance — mirrors `VideoEngine.seek(to:mode:)`'s
    /// switch exactly (the `.exact`/`.audibleStep*` branches all call `cancelInteractiveSeek()`
    /// before `performSeek`).
    public void Seek(int frame, PreviewSeekMode mode, int activeVideoLayerCount)
    {
        if (mode == PreviewSeekMode.InteractiveScrub)
        {
            Enqueue(frame, InteractiveTolerance(activeVideoLayerCount));
            return;
        }
        CancelPending();
        _performSeek(frame, TimeSpan.Zero);
    }

    private void Enqueue(int frame, TimeSpan tolerance)
    {
        TimeSpan delay;
        lock (_gate)
        {
            _pending = (frame, tolerance);
            if (_flushScheduled)
            {
                return; // a flush is already in flight; it will pick up the latest `_pending`
            }
            delay = InteractiveSeekInterval - (_now() - _lastDispatch);
            _flushScheduled = true;
        }
        if (delay <= TimeSpan.Zero)
        {
            Flush();
        }
        else
        {
            _schedule(delay, Flush);
        }
    }

    private void Flush()
    {
        (int Frame, TimeSpan Tolerance)? toDispatch;
        lock (_gate)
        {
            _flushScheduled = false;
            toDispatch = _pending;
            _pending = null;
            if (toDispatch is not null)
            {
                _lastDispatch = _now();
            }
        }
        if (toDispatch is { } p)
        {
            _performSeek(p.Frame, p.Tolerance);
        }
    }

    public void CancelPending()
    {
        lock (_gate)
        {
            _pending = null; // an already-scheduled timer still fires Flush(), but finds nothing pending
        }
    }

    // An active Timer with no live reference is eligible for GC; its finalizer cancels the
    // pending callback. Root it in a captured local and dispose it from inside the callback once
    // it fires, so it survives until then but doesn't leak past it.
    private static void DefaultSchedule(TimeSpan delay, Action callback)
    {
        Timer? timer = null;
        timer = new Timer(_ =>
        {
            timer?.Dispose();
            callback();
        }, null, delay, Timeout.InfiniteTimeSpan);
    }
}

/// `IVideoEngine`: asset-preview open/present/seek and swap-chain attach/resize/detach are E1
/// surface; timeline-session methods are E2 surface (Stage B) — each open `timelineId` gets its
/// own native <see cref="PalmierPro.Rendering.TimelineSession"/>, keyed in <see cref="_timelines"/>.
/// <see cref="RefreshParams"/> (E3) applies the patch onto the last-built <see
/// cref="TimelineSnapshot"/> for that timeline and pushes the result via
/// PE_TimelineRefreshParams — no decoder/media-session rebuild, see
/// docs/timeline-snapshot-v1.md §11 and native TimelineSession::RefreshParams's media-set
/// assertion. A safe no-op if no session for `patch.TimelineId` is open yet.
///
/// <see cref="Play"/>/<see cref="Pause"/>/<see cref="SetRate"/>/<see cref="IsPlaying"/> are E4.5
/// surface (Stage D) — wired straight to native PE_TimelinePlay/Pause/SetRate via <see
/// cref="PalmierPro.Rendering.TimelineSession"/> (docs/audio-playback-v1.md §4/§7). None of the
/// four touch the swap chain or D3D11 device, so unlike AttachSwapChain/SetActiveTimeline they
/// carry no UI-thread requirement — callable from any thread. <see cref="IsPlaying"/> is a local
/// dictionary read, not a native poll: <see cref="Play"/>/<see cref="Pause"/>/<see cref="SetRate"/>
/// set it directly, and the <see cref="PalmierPro.Rendering.TimelineSession.IsPlayingChanged"/>
/// subscription wired alongside PlayheadChanged in <see cref="UpdateTimelineAsync"/> also updates
/// it — that second path is what catches the engine's own auto-stop at timeline end, which
/// nothing else here calls into. <see cref="Seek"/>'s paired `PE_TimelineScrubAudio` call
/// (docs/audio-playback-v1.md §5) is wired: every non-`Exact` mode issues both the video-seek and
/// the audio-scrub call.
public sealed class VideoEngine : IVideoEngine, IDisposable
{
    private readonly EngineSession _session = new();
    private readonly SeekCoordinator _assetSeekCoordinator;
    private readonly Dictionary<string, PalmierPro.Rendering.TimelineSession> _timelines = [];
    private readonly Dictionary<string, TimelineSnapshot> _lastSnapshots = [];
    private readonly Lock _timelinesGate = new();
    private MediaSource? _assetPreview;
    // Timeline fps the open asset preview was last told to seek against — see SeekAssetPreview's
    // remarks; PerformAssetPreviewSeek reads this instead of _assetPreview.Info.Fps.
    private int _assetPreviewTimelineFps = 30;
    private bool _disposed;

    // docs/audio-playback-v1.md §5: direction is always caller-supplied — native performs no
    // auto-detection from frame history. Mirrors ScrubAudioEngine.scrub's own bookkeeping
    // (VideoEngine.swift derives forward/reverse by comparing the requested sample to the
    // previous one); concurrent-safe since Seek can be invoked off the UI thread (SeekCoordinator's
    // internal Timer callback calls it directly for InteractiveScrub — see TransportViewModel.cs).
    private readonly System.Collections.Concurrent.ConcurrentDictionary<string, int> _lastScrubFrame = new();
    private readonly System.Collections.Concurrent.ConcurrentDictionary<string, int> _lastScrubDirection = new();

    // Last-known IsPlaying per timeline (docs/audio-playback-v1.md §7) — set directly by
    // Play/Pause/SetRate and by the IsPlayingChanged subscription below; missing key == false
    // (never opened or never played).
    private readonly System.Collections.Concurrent.ConcurrentDictionary<string, bool> _isPlaying = new();

    // Swap-chain routing state (see SetActiveTimeline/SetAssetPreviewActive/AttachSwapChain
    // remarks): `_swapChainPanel` is non-null whenever the UI wants a live swap chain;
    // `_attachedTimelineId`/`_assetPreviewAttached` describe which ONE surface actually holds the
    // native attachment right now (at most one of the two is ever "on" — asset preview wins
    // whenever `_assetPreviewActive` is set, regardless of `_activeTimelineId`, mirroring the Mac's
    // one-AVPlayerLayer-follows-activePreviewTab exclusivity).
    private object? _swapChainPanel;
    private int _swapChainWidth;
    private int _swapChainHeight;
    private string? _activeTimelineId;
    private string? _attachedTimelineId;
    private bool _assetPreviewActive;
    private bool _assetPreviewAttached;

    public VideoEngine()
    {
        _assetSeekCoordinator = new SeekCoordinator(PerformAssetPreviewSeek);
    }

    public Task OpenTimelineSessionAsync(string timelineId, TimelineSnapshotBuildResult snapshot, CancellationToken ct = default) =>
        UpdateTimelineAsync(timelineId, snapshot, ct);

    public Task UpdateTimelineAsync(string timelineId, TimelineSnapshotBuildResult snapshot, CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrEmpty(timelineId);
        ArgumentNullException.ThrowIfNull(snapshot);
        ThrowIfDisposed();
        byte[] json = TimelineSnapshotSerializer.ToJsonBytes(snapshot.Snapshot);
        return Task.Run(
            () =>
            {
                PalmierPro.Rendering.TimelineSession? timeline;
                lock (_timelinesGate)
                {
                    _timelines.TryGetValue(timelineId, out timeline);
                }

                if (timeline is null)
                {
                    timeline = PalmierPro.Rendering.TimelineSession.Open(_session, json);
                    timeline.PlayheadChanged += frame => PlayheadChanged?.Invoke(this, new PlayheadChangedEventArgs(timelineId, checked((int)frame)));
                    timeline.IsPlayingChanged += isPlaying =>
                    {
                        _isPlaying[timelineId] = isPlaying;
                        IsPlayingChanged?.Invoke(this, isPlaying);
                    };
                    lock (_timelinesGate)
                    {
                        _timelines[timelineId] = timeline;
                    }
                }
                else
                {
                    timeline.Update(json);
                }

                lock (_timelinesGate)
                {
                    _lastSnapshots[timelineId] = snapshot.Snapshot;
                }

                var unprocessable = timeline.GetUnprocessableMediaRefs();
                MediaStatusChanged?.Invoke(this, new MediaStatus(snapshot.OfflineMediaRefs, unprocessable));
            },
            ct);
    }

    public void RefreshParams(TimelineParamPatch patch)
    {
        ArgumentNullException.ThrowIfNull(patch);
        PalmierPro.Rendering.TimelineSession timeline;
        TimelineSnapshot lastSnapshot;
        lock (_timelinesGate)
        {
            if (!_timelines.TryGetValue(patch.TimelineId, out timeline!) ||
                !_lastSnapshots.TryGetValue(patch.TimelineId, out lastSnapshot!))
            {
                return; // no open session for this timeline — nothing to refresh (see class remarks)
            }
        }

        var patchedTracks = new List<SnapshotTrack>(lastSnapshot.Tracks.Count);
        foreach (var track in lastSnapshot.Tracks)
        {
            var patchedClips = new List<SnapshotClip>(track.Clips.Count);
            foreach (var clip in track.Clips)
            {
                var clipPatch = patch.Clips.FirstOrDefault(c => c.ClipId == clip.Id);
                patchedClips.Add(clipPatch is null ? clip : ApplyClipPatch(clip, clipPatch));
            }
            // TextClips carries over unpatched — RefreshParams only ever patches SnapshotClip
            // params (opacity/effects), never text (docs/timeline-snapshot-v1.md §12); omitting it
            // here would silently drop a track's text clips on every param-only refresh.
            patchedTracks.Add(new SnapshotTrack { Id = track.Id, Type = track.Type, Muted = track.Muted, Clips = patchedClips, TextClips = track.TextClips });
        }

        var patched = new TimelineSnapshot
        {
            Version = lastSnapshot.Version,
            MinorVersion = lastSnapshot.MinorVersion,
            FpsNumerator = lastSnapshot.FpsNumerator,
            FpsDenominator = lastSnapshot.FpsDenominator,
            OutputWidth = lastSnapshot.OutputWidth,
            OutputHeight = lastSnapshot.OutputHeight,
            Tracks = patchedTracks,
        };

        byte[] json = TimelineSnapshotSerializer.ToJsonBytes(patched);
        // Synchronous and fast (JSON parse + atomic pointer swap — no decode/rebuild; see
        // TimelineSession::RefreshParams native-side), matching the "live slider feedback"
        // contract this interface method exists for.
        timeline.RefreshParams(json);
        lock (_timelinesGate)
        {
            _lastSnapshots[patch.TimelineId] = patched;
        }
    }

    private static SnapshotClip ApplyClipPatch(SnapshotClip clip, ClipParamPatch patch)
    {
        var effects = clip.Effects;
        if (patch.Effects is { Count: > 0 })
        {
            effects = ApplyEffectPatches(clip.Effects, patch.Effects);
        }
        return new SnapshotClip
        {
            Id = clip.Id,
            Type = clip.Type,
            StartFrame = clip.StartFrame,
            DurationFrames = clip.DurationFrames,
            TrimStartFrame = clip.TrimStartFrame,
            Speed = clip.Speed,
            MediaPath = clip.MediaPath,
            HasAlphaHint = clip.HasAlphaHint,
            BlendMode = patch.BlendMode ?? clip.BlendMode,
            Opacity = patch.Opacity ?? clip.Opacity,
            Transform = patch.Transform ?? clip.Transform,
            Crop = patch.Crop ?? clip.Crop,
            VolumeGain = patch.VolumeGain ?? clip.VolumeGain,
            FadeInFrames = clip.FadeInFrames,
            FadeOutFrames = clip.FadeOutFrames,
            FadeInInterpolation = clip.FadeInInterpolation,
            FadeOutInterpolation = clip.FadeOutInterpolation,
            OpacityKeyframes = clip.OpacityKeyframes,
            CropKeyframes = clip.CropKeyframes,
            TransformKeyframes = clip.TransformKeyframes,
            Effects = effects,
        };
    }

    /// Internal (not private) so VideoEngineEffectPatchesTests can drive the real patch-merge logic
    /// directly — RefreshParams itself needs a live native TimelineSession to exercise end-to-end.
    internal static List<SnapshotEffect> ApplyEffectPatches(List<SnapshotEffect> effects, IReadOnlyList<EffectParamPatch> patches)
    {
        var result = new List<SnapshotEffect>(effects.Count);
        var matchedTypes = new HashSet<string>();
        foreach (var effect in effects)
        {
            var relevant = patches.Where(p => p.EffectType == effect.Type).ToList();
            if (relevant.Count == 0)
            {
                result.Add(effect);
                continue;
            }
            matchedTypes.Add(effect.Type);
            var newParams = new Dictionary<string, EffectParam>(effect.Params);
            foreach (var p in relevant)
            {
                var existing = newParams.GetValueOrDefault(p.ParamKey);
                // Overwrites the static value only — a keyframed param (Track active) is left
                // animated; a plain slider-drag patch targets the static value, matching
                // EffectParam.Resolved's own "no active track -> use Value" precedence.
                newParams[p.ParamKey] = new EffectParam(p.Value, existing?.StringValue, existing?.Track);
            }
            result.Add(new SnapshotEffect(effect.Type, effect.Enabled, newParams));
        }

        // A patch can target an effect type the clip doesn't have yet — e.g. the first color-wheel
        // drag on a clip with no color.wheels effect. Only iterating `effects` above silently drops
        // those patches, so the live preview stays frozen for the whole drag and only snaps to the
        // graded frame on commit (which upserts the effect via a full rebuild). Synthesize the
        // missing effect from its registry descriptor — defaults for every un-patched key, same as
        // a real "Add Effect" — and insert it in canonical order so it refreshes live too.
        foreach (var effectType in patches.Select(p => p.EffectType).Distinct())
        {
            if (matchedTypes.Contains(effectType) || EffectRegistry.Descriptor(effectType) is not { } descriptor)
            {
                continue;
            }
            var newParams = new Dictionary<string, EffectParam>();
            foreach (var spec in descriptor.Params)
            {
                newParams[spec.Key] = new EffectParam(spec.DefaultValue);
            }
            foreach (var p in patches.Where(p => p.EffectType == effectType))
            {
                newParams[p.ParamKey] = new EffectParam(p.Value);
            }
            result.Insert(EffectInsertIndex(result, effectType), new SnapshotEffect(effectType, true, newParams));
        }
        return result;
    }

    /// Canonical-order insert position for a synthesized effect — mirrors
    /// EffectRegistry.InsertIndex, adapted for SnapshotEffect (a plain type string) rather than the
    /// model-layer Effect list that method operates on. Shares EffectRegistry.RankOf so the two
    /// stay in lockstep (unregistered types sort last, int.MaxValue).
    private static int EffectInsertIndex(IReadOnlyList<SnapshotEffect> effects, string effectType)
    {
        var rank = EffectRegistry.RankOf(effectType);
        for (var i = 0; i < effects.Count; i++)
        {
            if (EffectRegistry.RankOf(effects[i].Type) > rank)
            {
                return i;
            }
        }
        return effects.Count;
    }

    public void EvictTimeline(string timelineId)
    {
        lock (_timelinesGate)
        {
            if (_timelines.Remove(timelineId, out var timeline))
            {
                timeline.Dispose();
            }
        }
        _lastScrubFrame.TryRemove(timelineId, out _);
        _lastScrubDirection.TryRemove(timelineId, out _);
        _isPlaying.TryRemove(timelineId, out _);
        if (_attachedTimelineId == timelineId)
        {
            // The handle above is already disposed — nothing left to call DetachSwapChain on;
            // just stop believing it's still holding the swap chain.
            _attachedTimelineId = null;
        }
    }

    /// Coalescing (~30 Hz, latest-wins) and in-flight-decode cancellation for
    /// <see cref="PreviewSeekMode.InteractiveScrub"/> happen natively, inside PalmierEngine's own
    /// per-timeline render thread (mirrors <see cref="SeekCoordinator"/>'s coalescing logic — see
    /// native/TimelineSession.cpp's RenderThreadLoop) — this call enqueues/dispatches and returns
    /// immediately without waiting for a render, satisfying the "coalesced by the implementation,
    /// not the caller" contract on <see cref="IVideoEngine.Seek"/>.
    ///
    /// Tolerance sizing is NOT threaded through, despite the name: <see cref="SeekCoordinator.
    /// InteractiveTolerance"/> implements the Mac's load-adaptive `min(0.75s, 0.15s × layers)`
    /// formula, but PE_TimelineSeek's ABI takes only (frame, mode) — the native render thread
    /// always snaps an interactive seek to the nearest PRECEDING KEYFRAME
    /// (MediaSource::DecodeFrameAtEx approximate=true) regardless of active layer count, so a
    /// single-layer scrub can snap by up to a full GOP where the Mac would hold within ~0.15s.
    /// Accepted as a v1 simplification — see the plan's scrub-strategy section. Threading a
    /// tolerance value into the native seek would additionally require DecodeFrameAtEx to decode
    /// forward from the keyframe to a frame within tolerance (today's `approximate` is a plain
    /// boolean: return the keyframe itself, or the exact requested frame), not just accept the
    /// value.
    public void Seek(string timelineId, int frame, PreviewSeekMode mode)
    {
        ArgumentException.ThrowIfNullOrEmpty(timelineId);
        var timeline = GetOpenTimelineOrThrow(timelineId);
        timeline.Seek(frame, ToNativeSeekMode(mode));
        if (mode != PreviewSeekMode.Exact)
        {
            // docs/audio-playback-v1.md §5: audio scrub feedback pairs with every non-Exact
            // mode — InteractiveScrub (continuous drag) and both AudibleStep* cases alike, not
            // only the two the ABI call's name emphasizes.
            timeline.ScrubAudio(frame, ScrubDirectionFor(timelineId, frame));
        }
        else
        {
            // Mac parity (VideoEngine.swift's scrubAudioEngine.stopScrubbing() on .exact): an Exact
            // settle cuts any lingering grain from the scrub gesture it concludes, rather than
            // letting the last ~50 ms grain play out (docs/audio-playback-v1.md §5).
            timeline.StopScrubAudio();
        }
    }

    // Mirrors PE_SeekMode (palmier_engine.h): 0 = exact, 1 = interactive scrub. The two
    // AudibleStep* cases are still treated as Exact on THIS (video-seek) call — their audio
    // scrub feedback is the separate PE_TimelineScrubAudio call above, not a third
    // PE_SeekMode value. See docs/audio-playback-v1.md §5.
    private static int ToNativeSeekMode(PreviewSeekMode mode) => mode == PreviewSeekMode.InteractiveScrub ? 1 : 0;

    /// Shared by every per-timeline call (Seek, Play, Pause, SetRate) that requires an
    /// already-open session — same "call OpenTimelineSessionAsync first" contract for all of them.
    private PalmierPro.Rendering.TimelineSession GetOpenTimelineOrThrow(string timelineId)
    {
        lock (_timelinesGate)
        {
            if (_timelines.TryGetValue(timelineId, out var timeline))
            {
                return timeline;
            }
        }
        throw new InvalidOperationException(
            $"No open timeline session for '{timelineId}' — call OpenTimelineSessionAsync first.");
    }

    /// Direction is derived by comparing `frame` to the last frame scrubbed on `timelineId` —
    /// mirrors ScrubAudioEngine.scrub's own history-based forward/reverse detection
    /// (VideoEngine.swift), since native performs no auto-detection (doc §5). A timeline with no
    /// prior scrub this session, or a `frame` equal to the last one, keeps the previous direction
    /// (default forward), matching the Mac's `lastDirection` carry-over.
    private int ScrubDirectionFor(string timelineId, int frame)
    {
        int previous = _lastScrubFrame.GetOrAdd(timelineId, frame);
        int direction = frame == previous
            ? _lastScrubDirection.GetOrAdd(timelineId, PalmierPro.Rendering.TimelineSession.ScrubForward)
            : (frame > previous ? PalmierPro.Rendering.TimelineSession.ScrubForward : PalmierPro.Rendering.TimelineSession.ScrubReverse);
        _lastScrubFrame[timelineId] = frame;
        _lastScrubDirection[timelineId] = direction;
        return direction;
    }

    /// → native PE_TimelinePlay (docs/audio-playback-v1.md §4/§7). Callable from any thread — no
    /// swap-chain/D3D11 involvement (see class remarks). Sets the local <see cref="IsPlaying"/>
    /// state directly so a caller reading it immediately after this returns never sees a stale
    /// value; the <see cref="PalmierPro.Rendering.TimelineSession.IsPlayingChanged"/> subscription
    /// (see <see cref="UpdateTimelineAsync"/>) also fires for this same transition and sets it
    /// again — redundant here, but it's the only path that catches the engine's auto-stop.
    public void Play(string timelineId)
    {
        ArgumentException.ThrowIfNullOrEmpty(timelineId);
        var timeline = GetOpenTimelineOrThrow(timelineId);
        timeline.Play();
        _isPlaying[timelineId] = true;
    }

    /// → native PE_TimelinePause. See <see cref="Play"/>'s remarks on local state tracking.
    public void Pause(string timelineId)
    {
        ArgumentException.ThrowIfNullOrEmpty(timelineId);
        var timeline = GetOpenTimelineOrThrow(timelineId);
        timeline.Pause();
        _isPlaying[timelineId] = false;
    }

    /// → native PE_TimelineSetRate. Rejects anything but {0.0, 1.0} client-side (docs/audio-playback-v1.md
    /// §4/§7) — fails fast rather than relying solely on the native PE_ERROR_INVALID_ARGUMENT
    /// round-trip. See <see cref="Play"/>'s remarks on local state tracking.
    public void SetRate(string timelineId, double rate)
    {
        ArgumentException.ThrowIfNullOrEmpty(timelineId);
        if (rate != 0.0 && rate != 1.0)
        {
            throw new ArgumentOutOfRangeException(nameof(rate), rate,
                "v1 accepts only 0.0 (paused) or 1.0 (playing) — see docs/audio-playback-v1.md §4.");
        }
        var timeline = GetOpenTimelineOrThrow(timelineId);
        timeline.SetRate(rate);
        _isPlaying[timelineId] = rate == 1.0;
    }

    /// Local last-known-state read, not a native poll — see <see cref="IVideoEngine.IsPlaying"/>'s
    /// remarks. `false` for a timeline that was never opened or never played.
    public bool IsPlaying(string timelineId) => _isPlaying.GetValueOrDefault(timelineId);

    /// → native PE_TimelineComputeColorScopes (docs/color-scopes-v1.md), off the UI thread via
    /// <see cref="Task.Run(Action, CancellationToken)"/> — mirrors <see cref="UpdateTimelineAsync"/>'s
    /// dictionary-lookup shape. `null` (not a throw) if no session for `timelineId` is open yet —
    /// callers are expected to have already called <see cref="OpenTimelineSessionAsync"/>, but a
    /// scopes refresh racing a timeline close/evict should degrade quietly, not fault the caller's task.
    public Task<ColorScopesResult?> GetColorScopesAsync(string timelineId, int frame, CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrEmpty(timelineId);
        ThrowIfDisposed();
        return Task.Run(
            () =>
            {
                PalmierPro.Rendering.TimelineSession? timeline;
                lock (_timelinesGate)
                {
                    _timelines.TryGetValue(timelineId, out timeline);
                }
                return timeline?.ComputeColorScopes(frame);
            },
            ct);
    }

    /// → native PE_TimelineGetAudioLevels (Stage E, AudioMeterView). See <see cref="AudioLevels"/>.
    public AudioLevels GetAudioLevels(string timelineId)
    {
        ArgumentException.ThrowIfNullOrEmpty(timelineId);
        var timeline = GetOpenTimelineOrThrow(timelineId);
        var (leftPeak, leftRms, rightPeak, rightRms) = timeline.GetAudioLevels();
        return new AudioLevels(leftPeak, leftRms, rightPeak, rightRms);
    }

    public Task OpenAssetPreviewAsync(string mediaPath, CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrEmpty(mediaPath);
        ThrowIfDisposed();
        return Task.Run(
            () =>
            {
                var opened = _session.OpenMedia(mediaPath);
                _assetPreview?.Dispose();
                _assetPreview = opened;
            },
            ct);
    }

    public void SeekAssetPreview(int frame, PreviewSeekMode mode, int timelineFps)
    {
        ThrowIfDisposed();
        if (_assetPreview is null)
        {
            throw new InvalidOperationException("No asset preview is open — call OpenAssetPreviewAsync first.");
        }
        // Captured before enqueueing, same latest-wins contract as `frame` itself (see
        // SeekCoordinator): a coalesced interactive-scrub flush replays whatever fps the most
        // recent SeekAssetPreview call was made with. The timeline's fps doesn't change mid-scrub
        // in practice, so this can't actually race against it.
        _assetPreviewTimelineFps = timelineFps;
        // A single open asset is always exactly one active video layer.
        _assetSeekCoordinator.Seek(frame, mode, activeVideoLayerCount: 1);
    }

    /// `frame → seconds` for <see cref="PerformAssetPreviewSeek"/> — `frame` is always expressed in
    /// TIMELINE fps (see <see cref="SeekAssetPreview"/>'s remarks), never the asset's own decoded
    /// fps (<see cref="MediaSource.Info"/>'s `Fps`, which is PE_GetMediaInfo's file-native rate and
    /// can legitimately differ from the timeline's — e.g. a 24fps clip previewed on a 30fps
    /// timeline). Dividing by the wrong one seeks off by `frame × (1/actualFps − 1/timelineFps)`,
    /// which grows without bound as playhead advances (e.g. lands ~2.5s past EOF at the end of a
    /// 10s 24fps clip on a 30fps timeline). Mirrors the Mac's
    /// `CMTime(value: frame, timescale: editor.timeline.fps)` (VideoEngine.swift). `public static`
    /// (not `private`) purely so <c>VideoEngineAssetPreviewSeekTests</c> can pin the exact formula
    /// without a native session — same reasoning as <see cref="SeekCoordinator.InteractiveTolerance"/>.
    public static double AssetPreviewSeekSeconds(int frame, int timelineFps) =>
        frame / (double)(timelineFps > 0 ? timelineFps : 30);

    private void PerformAssetPreviewSeek(int frame, TimeSpan tolerance)
    {
        // PE_PresentFrameAt has no tolerance parameter yet (E1 surface) — every dispatched seek is
        // an exact decode+present regardless of `tolerance`; the coordinator still throttles
        // dispatch frequency during a scrub, which is the load-shedding half of the Mac's behavior.
        // Presents to the session-level swap chain (PE_AttachSwapChain) — Stage D's Preview UI
        // attaches it here whenever asset-preview mode is active (see SetAssetPreviewActive); the
        // one swap chain the app owns is otherwise timeline-scoped (see AttachSwapChain/
        // SetActiveTimeline). Presenting to a not-currently-attached session swap chain is harmless
        // (native no-ops without a live attachment) — a caller that seeks before ever activating
        // asset-preview mode just doesn't render anywhere yet.
        if (_assetPreview is not { } media)
        {
            return;
        }
        _session.PresentFrameAt(media, AssetPreviewSeekSeconds(frame, _assetPreviewTimelineFps));
    }

    /// Also deactivates asset-preview swap-chain routing (see <see cref="SetAssetPreviewActive"/>)
    /// so a caller only has to make this one call to "switch back to timeline mode cleanly" — see
    /// <see cref="IVideoEngine.CloseAssetPreview"/>.
    public void CloseAssetPreview()
    {
        _assetSeekCoordinator.CancelPending();
        _assetPreview?.Dispose();
        _assetPreview = null;
        _assetPreviewActive = false;
        ReattachSwapChain();
    }

    /// See <see cref="IVideoEngine.SetActiveTimeline"/>. Runs on the caller's thread (expected to
    /// be the UI thread whenever a swap chain panel is currently attached — see that method's
    /// remarks); reattaches the live swap chain (if any) from whatever previously held it to the
    /// newly-active timeline's session, via <see cref="ReattachSwapChain"/> — a no-op on the swap
    /// chain itself while asset-preview mode is active (see that method's remarks).
    public void SetActiveTimeline(string? timelineId)
    {
        ThrowIfDisposed();
        _activeTimelineId = timelineId;
        ReattachSwapChain();
    }

    /// See <see cref="IVideoEngine.SetAssetPreviewActive"/>.
    public void SetAssetPreviewActive(bool active)
    {
        ThrowIfDisposed();
        _assetPreviewActive = active;
        ReattachSwapChain();
    }

    public void AttachSwapChain(object swapChainPanel, int width, int height)
    {
        ThrowIfDisposed();
        _swapChainPanel = swapChainPanel;
        _swapChainWidth = width;
        _swapChainHeight = height;
        ReattachSwapChain();
    }

    public void ResizeSwapChain(int width, int height)
    {
        ThrowIfDisposed();
        _swapChainWidth = width;
        _swapChainHeight = height;
        if (_assetPreviewAttached)
        {
            _session.ResizeSwapChain(width, height);
        }
        else if (_attachedTimelineId is { } id && TryGetTimeline(id, out var timeline))
        {
            timeline.ResizeSwapChain(width, height);
        }
    }

    public void DetachSwapChain()
    {
        ThrowIfDisposed();
        if (_assetPreviewAttached)
        {
            _session.DetachSwapChain();
        }
        else if (_attachedTimelineId is { } id && TryGetTimeline(id, out var timeline))
        {
            timeline.DetachSwapChain();
        }
        _attachedTimelineId = null;
        _assetPreviewAttached = false;
        _swapChainPanel = null;
    }

    /// Moves the one live swap chain (if <see cref="_swapChainPanel"/> is attached) to whichever
    /// surface — the open asset preview (<see cref="_assetPreviewActive"/>, via the session-level
    /// swap chain) or the active timeline's session (<see cref="_activeTimelineId"/>) — is
    /// currently desired; asset preview always wins over any active timeline while it's on, mirroring
    /// the Mac's one-AVPlayerLayer-follows-activePreviewTab exclusivity. A no-op if the desired
    /// surface already matches what's attached (covers "nothing changed" and "no panel either way"),
    /// and a no-op (deferred) if the desired timeline has no open session yet: the next
    /// <see cref="SetActiveTimeline"/> or <see cref="UpdateTimelineAsync"/> call for that id
    /// retries. Called from <see cref="AttachSwapChain"/>, <see cref="SetActiveTimeline"/>, and
    /// <see cref="SetAssetPreviewActive"/> so any order of "panel attaches" / "timeline opens" /
    /// "asset preview opens" ends up presenting correctly.
    private void ReattachSwapChain()
    {
        if (_swapChainPanel is not { } panel)
        {
            return;
        }
        string? desiredTimelineId = _assetPreviewActive ? null : _activeTimelineId;
        if (_assetPreviewAttached == _assetPreviewActive && _attachedTimelineId == desiredTimelineId)
        {
            return;
        }
        if (_assetPreviewAttached)
        {
            _session.DetachSwapChain();
        }
        else if (_attachedTimelineId is { } oldId && TryGetTimeline(oldId, out var oldTimeline))
        {
            oldTimeline.DetachSwapChain();
        }
        _attachedTimelineId = null;
        _assetPreviewAttached = false;

        if (_assetPreviewActive)
        {
            _session.AttachSwapChain(panel, _swapChainWidth, _swapChainHeight);
            _assetPreviewAttached = true;
        }
        else if (desiredTimelineId is { } newId && TryGetTimeline(newId, out var newTimeline))
        {
            newTimeline.AttachSwapChain(panel, _swapChainWidth, _swapChainHeight);
            _attachedTimelineId = newId;
        }
    }

    private bool TryGetTimeline(string timelineId, out PalmierPro.Rendering.TimelineSession timeline)
    {
        lock (_timelinesGate)
        {
            return _timelines.TryGetValue(timelineId, out timeline!);
        }
    }

    /// Raised from a native render-thread callback each time a timeline actually composes a
    /// frame — in response to <see cref="Seek"/>, or continuously against the A/V clock once
    /// <see cref="Play"/> starts playback (docs/audio-playback-v1.md §3.5) — see
    /// <see cref="PalmierPro.Rendering.TimelineSession.PlayheadChanged"/>. Fired on whatever thread
    /// the native render worker runs on; subscribers marshal to the UI thread themselves (mirrors
    /// the Mac's `AVPlayer` periodic time observer callback contract).
    public event EventHandler<PlayheadChangedEventArgs>? PlayheadChanged;

    /// Raised whenever any open timeline's isPlaying actually transitions — explicit
    /// <see cref="Play"/>/<see cref="Pause"/>/<see cref="SetRate"/>, and the engine's own
    /// auto-stop at timeline end (docs/audio-playback-v1.md §4/§7, via
    /// <see cref="PalmierPro.Rendering.TimelineSession.IsPlayingChanged"/>). Synchronous with the
    /// calling thread for explicit Play/Pause/SetRate, but may run on a native background thread
    /// for the auto-stop case — subscribers marshal to the UI thread themselves, same contract as
    /// <see cref="PlayheadChanged"/>. No timelineId in the payload (matches the declared
    /// signature): Phase 1's transport UI drives exactly one active timeline at a time.
    public event EventHandler<bool>? IsPlayingChanged;

    /// Fires after every successful Open/UpdateTimelineAsync with the union of the builder-side
    /// OfflineMediaRefs and whatever the engine itself failed to decode this pass — see
    /// docs/timeline-snapshot-v1.md §8.
    public event EventHandler<MediaStatus>? MediaStatusChanged;

    private void ThrowIfDisposed() => ObjectDisposedException.ThrowIf(_disposed, this);

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }
        _disposed = true;
        lock (_timelinesGate)
        {
            foreach (var timeline in _timelines.Values)
            {
                timeline.Dispose();
            }
            _timelines.Clear();
        }
        _assetPreview?.Dispose();
        _session.Dispose();
    }
}
