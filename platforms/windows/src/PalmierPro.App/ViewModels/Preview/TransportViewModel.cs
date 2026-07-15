using CommunityToolkit.Mvvm.ComponentModel;
using PalmierPro.App.ViewModels.Editor;
using PalmierPro.Services.Engine;
using Serilog;

namespace PalmierPro.App.ViewModels.Preview;

/// Transport controls + playhead sync (M4, Stage D) — ports the play/pause/step/skip surface of
/// `EditorViewModel`'s "Playback" section (`Sources/PalmierPro/Editor/ViewModel/EditorViewModel.swift`)
/// plus `VideoEngine.swift`'s time-observer→playhead flow. WinUI-free (plain `ObservableObject`,
/// no XAML types) so `PalmierPro.App.Tests` can drive the play/pause state machine, step math, and
/// the engine↔UI sync-loop guard under plain `dotnet test` — see `TransportBar.xaml.cs` for the
/// WinUI half (button wiring, DispatcherQueue marshaling).
///
/// `IVideoEngine.Play`/`Pause` (E4.5 "infra" slice, see docs/audio-playback-v1.md) throw
/// `InvalidOperationException` when no engine session is open yet for the active timeline
/// (`VideoEngine.GetOpenTimelineOrThrow` — the same failure mode `ForwardSeek` below already
/// tolerates) — a real, reachable race (e.g. a transport keypress landing before
/// `PreviewViewModel.RebuildAsync`'s `OpenTimelineSessionAsync` completes), not a "feature not
/// landed yet" placeholder. Every call is wrapped so that race degrades to a locally-tracked
/// `IsPlaying` flag instead of crashing the transport UI.
public sealed partial class TransportViewModel : ObservableObject, IDisposable
{
    /// Mirrors `TimelineEditorViewModel.NotifyTimelineChangedDebounced`'s own 120ms default
    /// (`Sources/PalmierPro/Editor/ViewModel/EditorViewModel.swift`'s Mac-matching debounce) — reused
    /// here as the "no further playhead movement" settle window before committing a decode-accurate
    /// (zero-tolerance) seek. See `ScheduleSettle`.
    private static readonly TimeSpan SettleDelay = TimeSpan.FromMilliseconds(120);

    public TimelineEditorViewModel Timeline { get; }

    private readonly IVideoEngine _engine;
    private readonly Action<Action> _dispatch;
    private readonly Action<TimeSpan, Action> _scheduleSettle;
    private readonly SeekCoordinator _seekCoordinator;

    /// Guards the engine↔UI seek loop: set for the duration of any `Timeline.CurrentFrame` write
    /// this class itself performs (from an engine `PlayheadChanged` callback, or from its own
    /// step/skip/seek methods immediately before issuing the matching `Engine.Seek`), so
    /// `OnTimelinePropertyChanged` never re-forwards a frame change this class already accounted
    /// for. Every write to `Timeline.CurrentFrame` in this file goes through this guard.
    private bool _suppressForwarding;

    private long _settleGeneration;

    [ObservableProperty]
    public partial bool IsPlaying { get; set; }

    /// `dispatch` marshals engine-thread callbacks (`PlayheadChanged`/`IsPlayingChanged` — see
    /// `IVideoEngine`'s remarks: "raised on whatever thread the native render worker runs on")
    /// onto the UI thread; defaults to synchronous (same-thread) for `dotnet test` callers with no
    /// `DispatcherQueue`. `scheduleSettle` is the same "inject a synchronous scheduler for tests"
    /// pattern `SeekCoordinator` already uses — see its own doc comment.
    public TransportViewModel(
        TimelineEditorViewModel timeline,
        IVideoEngine engine,
        Action<Action>? dispatch = null,
        Action<TimeSpan, Action>? scheduleSettle = null)
    {
        Timeline = timeline;
        _engine = engine;
        _dispatch = dispatch ?? (action => action());
        _scheduleSettle = scheduleSettle ?? DefaultScheduleSettle;
        _seekCoordinator = new SeekCoordinator((frame, _) => ForwardSeek(frame, PreviewSeekMode.InteractiveScrub));

        Timeline.PropertyChanged += OnTimelinePropertyChanged;
        _engine.PlayheadChanged += OnEnginePlayheadChanged;
        _engine.IsPlayingChanged += OnEngineIsPlayingChanged;
    }

    // MARK: - Playback (mirrors EditorViewModel.togglePlayback/play/pause)

    public void TogglePlayback()
    {
        if (IsPlaying)
        {
            Pause();
        }
        else
        {
            Play();
        }
    }

    public void Play()
    {
        try
        {
            _engine.Play(Timeline.ActiveTimelineId);
            IsPlaying = true;
        }
        catch (InvalidOperationException ex)
        {
            Log.Debug(ex, "transport: Play dropped, no open session for {TimelineId} yet", Timeline.ActiveTimelineId);
        }
    }

    public void Pause()
    {
        try
        {
            _engine.Pause(Timeline.ActiveTimelineId);
        }
        catch (InvalidOperationException ex)
        {
            Log.Debug(ex, "transport: Pause dropped, no open session for {TimelineId} yet", Timeline.ActiveTimelineId);
        }
        // Always reflect "not playing" locally regardless of whether the native call itself
        // succeeded — pausing an already-stopped transport is always the correct end state.
        IsPlaying = false;
    }

    // MARK: - Frame step / skip (keyboard — mirrors stepForward/stepBackward/skipForward/skipBackward)

    /// `audibleStep*` modes pause first if playing, mirroring `VideoEngine.seek(to:mode:)`'s own
    /// `if editor.isPlaying { pause() }` guard for those two cases specifically (see
    /// docs/audio-playback-v1.md §5 — this caller-side policy is expected to live in the future
    /// `VideoEngine.Seek` C# caller; `TransportViewModel` IS that caller for the keyboard step
    /// shortcuts).
    public void StepBackward() => StepCommit(Timeline.CurrentFrame - 1, PreviewSeekMode.AudibleStepBackward);

    public void StepForward() => StepCommit(Timeline.CurrentFrame + 1, PreviewSeekMode.AudibleStepForward);

    public void SkipBackward(int frames = 5) => StepCommit(Timeline.CurrentFrame - frames, PreviewSeekMode.AudibleStepBackward);

    public void SkipForward(int frames = 5) => StepCommit(Timeline.CurrentFrame + frames, PreviewSeekMode.AudibleStepForward);

    private void StepCommit(int frame, PreviewSeekMode mode)
    {
        if (IsPlaying)
        {
            Pause();
        }
        SeekAndCommit(frame, mode);
    }

    // MARK: - Transport-bar buttons (mirrors PreviewContainerView.swift's transportBar — plain
    // `.exact` seeks, no pause-first, no audible-step feedback)

    public void SeekToStart() => SeekAndCommit(0, PreviewSeekMode.Exact);

    public void SeekToEnd() => SeekAndCommit(Timeline.Timeline.TotalFrames, PreviewSeekMode.Exact);

    public void FrameStepBackward() => SeekAndCommit(Timeline.CurrentFrame - 1, PreviewSeekMode.Exact);

    public void FrameStepForward() => SeekAndCommit(Timeline.CurrentFrame + 1, PreviewSeekMode.Exact);

    /// Commits one explicit, immediate seek this class itself initiated: updates the shared
    /// playhead, then forwards it to the engine at exactly the requested mode. Guarded so
    /// `OnTimelinePropertyChanged` doesn't also forward the same frame change.
    private void SeekAndCommit(int frame, PreviewSeekMode mode)
    {
        var clamped = Math.Clamp(frame, 0, Math.Max(0, Timeline.Timeline.TotalFrames));
        _suppressForwarding = true;
        try
        {
            Timeline.CurrentFrame = clamped;
        }
        finally
        {
            _suppressForwarding = false;
        }
        ForwardSeek(clamped, mode);
    }

    // MARK: - Timeline → engine (scrub/click/local arrow keys the timeline canvas already applies
    // straight to `CurrentFrame` — see platforms/windows/AGENTS.md's file-ownership split; this is
    // the seam that finally wires those changes through to the engine)

    private void OnTimelinePropertyChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        if (e.PropertyName != nameof(TimelineEditorViewModel.CurrentFrame) || _suppressForwarding)
        {
            return;
        }
        var frame = Timeline.CurrentFrame;
        // Interactive while still moving (coalesced ~30 Hz by SeekCoordinator, tolerance-based —
        // may land on an approximate/keyframe-snapped frame, see VideoEngine.cs's remarks), then
        // one decode-accurate commit once nothing else changes CurrentFrame for SettleDelay —
        // mirrors PreviewContainerView.swift's `finishScrub` issuing one final `.exact` seek.
        _seekCoordinator.Seek(frame, PreviewSeekMode.InteractiveScrub, activeVideoLayerCount: 1);
        ScheduleSettle(frame);
    }

    private void ScheduleSettle(int frame)
    {
        var generation = System.Threading.Interlocked.Increment(ref _settleGeneration);
        _scheduleSettle(SettleDelay, () =>
        {
            if (System.Threading.Interlocked.Read(ref _settleGeneration) != generation)
            {
                return; // superseded by a newer CurrentFrame change — that one's own timer will settle instead
            }
            _dispatch(() => ForwardSeek(frame, PreviewSeekMode.Exact));
        });
    }

    private void ForwardSeek(int frame, PreviewSeekMode mode)
    {
        if (string.IsNullOrEmpty(Timeline.ActiveTimelineId))
        {
            return;
        }
        try
        {
            _engine.Seek(Timeline.ActiveTimelineId, frame, mode);
        }
        catch (InvalidOperationException ex)
        {
            // No open engine session for this timeline yet (e.g. mid-rebuild after a tab switch)
            // — a genuine no-op, mirrors RefreshParams's own "nothing to refresh yet" tolerance.
            Log.Debug(ex, "transport: seek dropped, no open session for {TimelineId} yet", Timeline.ActiveTimelineId);
        }
    }

    // MARK: - Engine → timeline (mirrors VideoEngine.swift's periodic time-observer writing
    // editor.currentFrame back, guarded there by `!editor.isScrubbing`; guarded here by
    // `_suppressForwarding` so this never re-enters ForwardSeek)

    private void OnEnginePlayheadChanged(object? sender, PlayheadChangedEventArgs e)
    {
        if (e.TimelineId != Timeline.ActiveTimelineId)
        {
            return;
        }
        _dispatch(() =>
        {
            _suppressForwarding = true;
            try
            {
                Timeline.CurrentFrame = Math.Clamp(e.Frame, 0, Math.Max(0, Timeline.Timeline.TotalFrames));
            }
            finally
            {
                _suppressForwarding = false;
            }
        });
    }

    private void OnEngineIsPlayingChanged(object? sender, bool isPlaying) => _dispatch(() => IsPlaying = isPlaying);

    // Rooted-timer idiom matching SeekCoordinator.DefaultSchedule — an un-rooted Timer is GC-eligible,
    // whose finalizer would cancel the pending settle callback.
    private static void DefaultScheduleSettle(TimeSpan delay, Action callback)
    {
        System.Threading.Timer? timer = null;
        timer = new System.Threading.Timer(
            _ =>
            {
                timer?.Dispose();
                callback();
            },
            null,
            delay,
            System.Threading.Timeout.InfiniteTimeSpan);
    }

    public void Dispose()
    {
        Timeline.PropertyChanged -= OnTimelinePropertyChanged;
        _engine.PlayheadChanged -= OnEnginePlayheadChanged;
        _engine.IsPlayingChanged -= OnEngineIsPlayingChanged;
        _seekCoordinator.CancelPending();
    }
}
