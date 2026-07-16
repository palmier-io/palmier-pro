using PalmierPro.App.ViewModels.Editor;
using PalmierPro.Core;
using PalmierPro.Core.Models;
using PalmierPro.Rendering;
using PalmierPro.Services.Engine;
using PalmierPro.Services.Media;
using PalmierPro.Services.Project;
using Serilog;

namespace PalmierPro.App.ViewModels.Preview;

/// Which surface the one swap chain the window owns is currently showing — the Windows analog of
/// the Mac's `PreviewTab` (`.timeline` vs. `.mediaAsset`), narrowed to a single toggle rather than
/// a full multi-tab history: only one source-asset preview can be open at a time (mirrors
/// <see cref="IVideoEngine.OpenAssetPreviewAsync"/>'s own "only one open" contract), and leaving it
/// closes it rather than keeping it around as a background tab.
public enum PreviewMode
{
    Timeline,
    Source,
}

/// Backs PreviewView (M4, Stage D): builds/pushes timeline snapshots to the engine and keeps
/// `IVideoEngine.SetActiveTimeline` pointed at whichever timeline tab is active, so the one swap
/// chain the window owns always shows the right composition — plus the source-asset preview toggle
/// (double-click a media-panel asset → <see cref="OpenSourcePreviewAsync"/>), which borrows that
/// same swap chain via <see cref="IVideoEngine.SetAssetPreviewActive"/> while it's open. SwapChainPanel
/// attach/resize/detach itself is PreviewView's job (WinUI-owning code stays in the view) — this
/// class stays WinUI-free, same convention as MediaTabViewModel/TimelineEditorViewModel. Timeline
/// play/pause/step transport is a separate concern (TransportViewModel/TransportBar, also Stage D)
/// that talks to the engine directly off `Timeline.ActiveTimelineId` — this class doesn't drive it
/// and isn't driven by it; this only keeps the active timeline's composed frame current, reports
/// media health, and drives source-asset preview open/close/scrub.
public sealed class PreviewViewModel : IDisposable
{
    private readonly ProjectDocument _document;
    private readonly IVideoEngine _engine;
    private readonly MediaResolver _mediaResolver;
    private readonly ILottieBakeService? _lottieBakeService;
    private readonly SemaphoreSlim _rebuildGate = new(1, 1);
    private readonly HashSet<string> _openedTimelineIds = [];
    private bool _disposed;

    public TimelineEditorViewModel Timeline { get; }

    /// Exposed so PreviewView (the only WinUI-owning half of this pair) can drive
    /// AttachSwapChain/ResizeSwapChain/DetachSwapChain directly off SwapChainPanel lifecycle
    /// events — those three take an opaque `object` panel already (see IVideoEngine), so exposing
    /// this doesn't leak a WinUI dependency into this class.
    public IVideoEngine Engine => _engine;

    public PreviewMode Mode { get; private set; } = PreviewMode.Timeline;

    /// Non-null only while <see cref="Mode"/> is <see cref="PreviewMode.Source"/>.
    public MediaAsset? SourceAsset { get; private set; }

    /// Last frame <see cref="SeekSource"/> dispatched — PreviewView's scrub-bar fill reads this
    /// (there's no engine playhead-changed callback for asset preview the way there is for a
    /// timeline session's <see cref="IVideoEngine.PlayheadChanged"/>).
    public int SourceFrame { get; private set; }

    public int SourceDurationFrames =>
        SourceAsset is { } asset ? Math.Max(0, SwiftMath.SecondsToFrame(asset.Duration, Timeline.Timeline.Fps)) : 0;

    /// Fires whenever <see cref="Mode"/>/<see cref="SourceAsset"/> actually change — a failed
    /// <see cref="OpenSourcePreviewAsync"/> or a redundant <see cref="ShowTimeline"/> does not raise
    /// this. PreviewView rebuilds its tab toggle and re-fits the canvas aspect off it.
    public event EventHandler? ModeChanged;

    /// Union of builder- and engine-side media problems for whichever timeline was last
    /// built/opened — see <see cref="MediaStatus"/>. Raised off the UI thread (mirrors
    /// <see cref="IVideoEngine.MediaStatusChanged"/>); PreviewView marshals it.
    public event EventHandler<MediaStatus>? MediaStatusChanged;

    /// `lottieBakeService` is optional — a caller (tests, DevHarness) that doesn't wire one up gets
    /// the same "every Lottie clip stays pending forever" behavior `TimelineSnapshotBuilder.Build`
    /// already falls back to when its own `lottieBakeService` parameter is omitted (doc §10).
    public PreviewViewModel(ProjectDocument document, TimelineEditorViewModel timeline, IVideoEngine engine, ILottieBakeService? lottieBakeService = null)
    {
        _document = document;
        Timeline = timeline;
        _engine = engine;
        _lottieBakeService = lottieBakeService;
        _mediaResolver = new MediaResolver(() => _document.Manifest, () => _document.PackagePath);

        _engine.MediaStatusChanged += OnEngineMediaStatusChanged;
        Timeline.StructuralChangeRequested += OnStructuralChangeRequested;
        if (_lottieBakeService is not null)
        {
            _lottieBakeService.StatusChanged += OnLottieBakeStatusChanged;
        }

        // Fire-and-forget, matching MediaTabViewModel's own ctor-time RefreshMissingMediaAsync —
        // failures land in the log, not as an unobservable exception; nothing here can synchronously
        // fail loudly for the caller to catch anyway (EditorPlaceholderView.SetDocument is void).
        _ = RebuildAsync();
    }

    private void OnStructuralChangeRequested(object? sender, EventArgs e) => _ = RebuildAsync();

    /// Rebuild-on-complete (docs/lottie-bake-v1.md §10's "whichever component owns the open
    /// ProjectDocument/timeline VMs subscribes to StatusChanged" — this is that subscriber): a
    /// newly-baked `mediaPath` is a new entry in the media set, a structural change, so a fresh
    /// <see cref="RebuildAsync"/> (which always calls <see cref="IVideoEngine.UpdateTimelineAsync"/>,
    /// never RefreshParams) is exactly the right response — no need to check whether the completed
    /// bake's MediaRef is even referenced by the currently active timeline; an unrelated rebuild is
    /// a harmless no-op cost, same as any other <see cref="OnStructuralChangeRequested"/> firing.
    /// Ignores Failed — a failed bake leaves the clip pending/invisible rather than retrying.
    private void OnLottieBakeStatusChanged(object? sender, LottieBakeStatusChangedEventArgs e)
    {
        if (e.Status == LottieBakeStatus.Completed)
        {
            _ = RebuildAsync();
        }
    }

    private void OnEngineMediaStatusChanged(object? sender, MediaStatus status) => MediaStatusChanged?.Invoke(this, status);

    /// Builds a fresh snapshot for whichever timeline is currently active and opens/updates it on
    /// the engine, then designates it the swap-chain-presenting timeline. Serialized against
    /// itself (`_rebuildGate`) so rapid-fire edits apply in order instead of racing; re-reads
    /// `Timeline.ActiveTimelineId` only after acquiring the gate so a tab switch landing while an
    /// earlier rebuild is still in flight is never clobbered by that earlier call's stale id.
    private async Task RebuildAsync()
    {
        await _rebuildGate.WaitAsync();
        try
        {
            var timelineId = Timeline.ActiveTimelineId;
            var result = TimelineSnapshotBuilder.Build(_document.ProjectFile, timelineId, _mediaResolver, _lottieBakeService);
            // No ConfigureAwait(false): a WinUI window installs a DispatcherQueueSynchronizationContext
            // on its UI thread, so resuming on the captured context is what puts SetActiveTimeline
            // (below — a UI-thread-only call, see its remarks) back on the UI thread every caller of
            // RebuildAsync (ctor, StructuralChangeRequested) already runs on. Same reasoning as
            // TimelineEditorViewModel.DebounceStructuralChangeAsync.
            if (_openedTimelineIds.Add(timelineId))
            {
                await _engine.OpenTimelineSessionAsync(timelineId, result);
            }
            else
            {
                await _engine.UpdateTimelineAsync(timelineId, result);
            }
            _engine.SetActiveTimeline(timelineId);
            Log.Information("preview: timeline {TimelineId} composed and set active", timelineId);
        }
        catch (Exception ex) when (ex is EngineException or ArgumentException)
        {
            Log.Warning(ex, "preview: failed to build/apply timeline snapshot for {TimelineId}", Timeline.ActiveTimelineId);
        }
        finally
        {
            _rebuildGate.Release();
        }
    }

    // MARK: - Source-asset preview (M4, Stage D)

    /// Opens `asset` as the source-asset preview and hands it the one swap chain the window owns
    /// (mirrors the Mac's `selectMediaAsset`/`activateTab(.mediaAsset)`). A no-op on failure — state
    /// (and <see cref="ModeChanged"/>) only changes once the engine confirms the asset actually
    /// opened, so a broken file double-clicked while viewing something else (timeline or a
    /// different asset) leaves that current view untouched rather than switching to a blank tab.
    /// Does not disturb the active timeline's own session — it keeps composing/updating in the
    /// background (see <see cref="RebuildAsync"/>) so <see cref="ShowTimeline"/> has an up-to-date
    /// frame ready the instant it's called.
    public async Task OpenSourcePreviewAsync(MediaAsset asset, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(asset);
        try
        {
            // No ConfigureAwait(false) — see RebuildAsync's remarks; SetAssetPreviewActive/
            // SeekAssetPreview below are UI-thread-only calls.
            await _engine.OpenAssetPreviewAsync(asset.Url, ct);
        }
        catch (Exception ex) when (ex is EngineException or ArgumentException)
        {
            Log.Warning(ex, "preview: failed to open source preview for asset {AssetId}", asset.Id);
            return;
        }
        SourceAsset = asset;
        Mode = PreviewMode.Source;
        SourceFrame = 0;
        _engine.SetAssetPreviewActive(true);
        _engine.SeekAssetPreview(0, PreviewSeekMode.Exact, Timeline.Timeline.Fps);
        ModeChanged?.Invoke(this, EventArgs.Empty);
        Log.Information("preview: opened source preview for asset {AssetId}", asset.Id);
    }

    /// Switches back to the timeline, closing the source-asset preview cleanly (see
    /// <see cref="IVideoEngine.CloseAssetPreview"/> — frees the decoder, hands the swap chain back
    /// to the active timeline session). A no-op while already on the timeline.
    public void ShowTimeline()
    {
        if (Mode == PreviewMode.Timeline)
        {
            return;
        }
        Mode = PreviewMode.Timeline;
        SourceAsset = null;
        _engine.CloseAssetPreview();
        ModeChanged?.Invoke(this, EventArgs.Empty);
    }

    /// Seeks within the open source-asset preview — the source-asset counterpart to
    /// TransportViewModel's timeline seeking, but scoped to this class since it already owns
    /// asset-preview session lifetime. A no-op while <see cref="Mode"/> is
    /// <see cref="PreviewMode.Timeline"/> — the engine throws if asked to seek an asset preview
    /// that isn't open, so this guard is what lets PreviewView wire scrub-bar drag events without
    /// separately tracking mode itself.
    public void SeekSource(int frame, PreviewSeekMode mode = PreviewSeekMode.Exact)
    {
        if (Mode != PreviewMode.Source)
        {
            return;
        }
        SourceFrame = Math.Clamp(frame, 0, Math.Max(0, SourceDurationFrames));
        _engine.SeekAssetPreview(SourceFrame, mode, Timeline.Timeline.Fps);
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }
        _disposed = true;
        Timeline.StructuralChangeRequested -= OnStructuralChangeRequested;
        _engine.MediaStatusChanged -= OnEngineMediaStatusChanged;
        if (_lottieBakeService is not null)
        {
            _lottieBakeService.StatusChanged -= OnLottieBakeStatusChanged;
        }
        if (Mode == PreviewMode.Source)
        {
            _engine.CloseAssetPreview();
        }
        (_engine as IDisposable)?.Dispose();
        _rebuildGate.Dispose();
    }
}
