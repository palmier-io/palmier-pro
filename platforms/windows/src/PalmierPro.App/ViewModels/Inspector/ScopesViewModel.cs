using PalmierPro.App.ViewModels.Editor;
using PalmierPro.Rendering;
using PalmierPro.Services.Engine;
using Serilog;

namespace PalmierPro.App.ViewModels.Inspector;

/// Shared data source behind the Inspector Adjust tab's Curves/Hue Curves scope backdrops
/// (docs/color-scopes-v1.md) — one cached <see cref="ColorScopesResult"/>, refreshed per §4's
/// trigger set, consumed by both ScopesHistogramView and ScopesHueView. Ports
/// CurveEditorView.swift/HueCurveEditorView.swift's shared refreshHistogram() shape, combined into
/// the engine's single PE_TimelineComputeColorScopes call (doc §4's last bullet — one in-flight/
/// dirty pair, not two independent Mac-style fetches).
///
/// WinUI-free (plain event, no ObservableObject) so it's testable under plain `dotnet test` — same
/// convention as PreviewViewModel. Construct one instance per Adjust-tab content instantiation and
/// hand it to both views via their `SetViewModel` (AudioMeterView/TransportBar convention, not
/// `{x:Bind}`); production callers must pass <paramref name="dispatch"/> as
/// `action => DispatcherQueue.TryEnqueue(() => action())` (see EditorPlaceholderView's
/// TransportViewModel construction) since <see cref="IVideoEngine.PlayheadChanged"/>/
/// <see cref="IVideoEngine.IsPlayingChanged"/> may fire on a native background thread.
///
/// <see cref="Activate"/>/<see cref="Deactivate"/> are reference-counted so either scope view can
/// be Loaded/Unloaded independently without one tearing down the other's subscription; a refresh
/// only ever runs while at least one view is active, which is what satisfies "runs only while the
/// Inspector color panel is visible" — InspectorView only constructs the active tab's content (see
/// InspectorTabRegistry), so Loaded/Unloaded already tracks tab visibility with no extra wiring
/// needed from whichever tab hosts these views.
public sealed class ScopesViewModel
{
    private readonly IVideoEngine _engine;
    private readonly TimelineEditorViewModel _timeline;
    private readonly Action<Action> _dispatch;

    private int _activeCount;
    private bool _inFlight;
    private bool _dirty;
    private CancellationTokenSource? _cts;

    public ColorScopesResult? Result { get; private set; }

    /// Fires on the dispatched thread whenever <see cref="Result"/> lands a fresh readback — never
    /// for a dropped/cancelled/failed refresh, so a view's last-good frame stays on screen instead
    /// of flashing empty.
    public event EventHandler? ResultChanged;

    public ScopesViewModel(IVideoEngine engine, TimelineEditorViewModel timeline, Action<Action>? dispatch = null)
    {
        _engine = engine;
        _timeline = timeline;
        _dispatch = dispatch ?? (action => action());
    }

    /// First appearance (or re-appearance) of a scope view — mirrors CurveEditorView's `.onAppear`.
    public void Activate()
    {
        if (_activeCount++ > 0)
        {
            return;
        }
        _timeline.StructuralChangeRequested += OnStructuralChangeRequested;
        _engine.PlayheadChanged += OnPlayheadChanged;
        _engine.IsPlayingChanged += OnIsPlayingChanged;
        Refresh();
    }

    /// A scope view unloaded (tab switched away, or torn down with the rest of the Adjust tab's
    /// content). Only tears the subscription down once every activator has deactivated.
    public void Deactivate()
    {
        if (_activeCount == 0 || --_activeCount > 0)
        {
            return;
        }
        _timeline.StructuralChangeRequested -= OnStructuralChangeRequested;
        _engine.PlayheadChanged -= OnPlayheadChanged;
        _engine.IsPlayingChanged -= OnIsPlayingChanged;
        _cts?.Cancel();
        _dirty = false;
    }

    private void OnStructuralChangeRequested(object? sender, EventArgs e) => Refresh();

    // PlayheadChanged/IsPlayingChanged "may run on a native background thread" (IVideoEngine) —
    // dispatch before touching any field Refresh/RefreshAsync's continuation also touch.

    private void OnPlayheadChanged(object? sender, PlayheadChangedEventArgs e)
    {
        if (e.TimelineId == _timeline.ActiveTimelineId)
        {
            _dispatch(Refresh);
        }
    }

    private void OnIsPlayingChanged(object? sender, bool isPlaying)
    {
        if (!isPlaying)
        {
            _dispatch(Refresh);
        }
    }

    /// One generator pass in flight at a time; coalesce mid-pass triggers into a trailing refresh —
    /// ports CurveEditorView.swift/HueCurveEditorView.swift's histInFlight/histDirty pattern
    /// verbatim (doc §4). Never while playing — a settle-time readout, not a live-playback overlay.
    private void Refresh()
    {
        var timelineId = _timeline.ActiveTimelineId;
        if (string.IsNullOrEmpty(timelineId) || _engine.IsPlaying(timelineId))
        {
            return;
        }
        if (_inFlight)
        {
            _dirty = true;
            return;
        }
        _inFlight = true;
        var frame = _timeline.CurrentFrame;
        var cts = new CancellationTokenSource();
        _cts = cts;
        _ = RefreshAsync(timelineId, frame, cts.Token);
    }

    private async Task RefreshAsync(string timelineId, int frame, CancellationToken ct)
    {
        ColorScopesResult? result = null;
        try
        {
            result = await _engine.GetColorScopesAsync(timelineId, frame, ct);
        }
        catch (OperationCanceledException)
        {
        }
        catch (EngineException ex)
        {
            Log.Debug(ex, "scopes: refresh failed for {TimelineId} @ {Frame}", timelineId, frame);
        }

        _dispatch(() =>
        {
            _inFlight = false;
            if (result is not null)
            {
                Result = result;
                ResultChanged?.Invoke(this, EventArgs.Empty);
            }
            if (_dirty)
            {
                _dirty = false;
                Refresh();
            }
        });
    }
}
