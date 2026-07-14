using PalmierPro.Rendering;

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
/// <see cref="RefreshParams"/> still no-ops: v1's native engine has no per-clip GPU param state to
/// patch in place yet (that's the render graph's effect-chain seam — E3); a param-only edit falls
/// back to a full <see cref="UpdateTimelineAsync"/> rebuild upstream in the VM today. See
/// docs/timeline-snapshot-v1.md.
public sealed class VideoEngine : IVideoEngine, IDisposable
{
    private readonly EngineSession _session = new();
    private readonly SeekCoordinator _assetSeekCoordinator;
    private readonly Dictionary<string, PalmierPro.Rendering.TimelineSession> _timelines = [];
    private readonly Lock _timelinesGate = new();
    private MediaSource? _assetPreview;
    private bool _disposed;

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
                    lock (_timelinesGate)
                    {
                        _timelines[timelineId] = timeline;
                    }
                }
                else
                {
                    timeline.Update(json);
                }

                var unprocessable = timeline.GetUnprocessableMediaRefs();
                MediaStatusChanged?.Invoke(this, new MediaStatus(snapshot.OfflineMediaRefs, unprocessable));
            },
            ct);
    }

    public void RefreshParams(TimelineParamPatch patch)
    {
        // No-op: v1's native engine has no per-clip GPU param state to refresh in place yet
        // (that's the render graph's effect-chain seam — E3). Intentionally does not throw —
        // see class remarks.
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
        PalmierPro.Rendering.TimelineSession timeline;
        lock (_timelinesGate)
        {
            if (!_timelines.TryGetValue(timelineId, out timeline!))
            {
                throw new InvalidOperationException(
                    $"No open timeline session for '{timelineId}' — call OpenTimelineSessionAsync first.");
            }
        }
        timeline.Seek(frame, ToNativeSeekMode(mode));
    }

    // Mirrors PE_SeekMode (palmier_engine.h): 0 = exact, 1 = interactive scrub. The two
    // AudibleStep* cases are treated as Exact until E4.5 lands scrub-audio feedback — see
    // IVideoEngine.cs's PreviewSeekMode remarks.
    private static int ToNativeSeekMode(PreviewSeekMode mode) => mode == PreviewSeekMode.InteractiveScrub ? 1 : 0;

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

    public void SeekAssetPreview(int frame, PreviewSeekMode mode)
    {
        ThrowIfDisposed();
        if (_assetPreview is null)
        {
            throw new InvalidOperationException("No asset preview is open — call OpenAssetPreviewAsync first.");
        }
        // A single open asset is always exactly one active video layer.
        _assetSeekCoordinator.Seek(frame, mode, activeVideoLayerCount: 1);
    }

    private void PerformAssetPreviewSeek(int frame, TimeSpan tolerance)
    {
        // PE_PresentFrameAt has no tolerance parameter yet (E1 surface) — every dispatched seek is
        // an exact decode+present regardless of `tolerance`; the coordinator still throttles
        // dispatch frequency during a scrub, which is the load-shedding half of the Mac's behavior.
        if (_assetPreview is not { } media)
        {
            return;
        }
        var fps = media.Info.Fps > 0 ? media.Info.Fps : 30;
        _session.PresentFrameAt(media, frame / fps);
    }

    public void CloseAssetPreview()
    {
        _assetSeekCoordinator.CancelPending();
        _assetPreview?.Dispose();
        _assetPreview = null;
    }

    public void AttachSwapChain(object swapChainPanel, int width, int height)
    {
        ThrowIfDisposed();
        _session.AttachSwapChain(swapChainPanel, width, height);
    }

    public void ResizeSwapChain(int width, int height)
    {
        ThrowIfDisposed();
        _session.ResizeSwapChain(width, height);
    }

    public void DetachSwapChain()
    {
        ThrowIfDisposed();
        _session.DetachSwapChain();
    }

    /// Raised from a native render-thread callback each time a timeline actually composes a
    /// frame in response to <see cref="Seek"/> — see <see cref="PalmierPro.Rendering.TimelineSession.PlayheadChanged"/>.
    /// Fired on whatever thread the native render worker runs on; subscribers marshal to the UI
    /// thread themselves (mirrors the Mac's `AVPlayer` periodic time observer callback contract).
    public event EventHandler<PlayheadChangedEventArgs>? PlayheadChanged;

    /// Wired in Stage D (M4, preview UI / playback loop) — v1 has no play/pause transport yet.
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
