using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using PalmierPro.App.Services;
using PalmierPro.App.Theme;
using PalmierPro.App.ViewModels.Editor;
using PalmierPro.App.ViewModels.MediaPanel;
using PalmierPro.App.ViewModels.Preview;
using PalmierPro.App.Views.Timeline;
using PalmierPro.Core.Models;
using PalmierPro.Core.Theme;
using PalmierPro.Rendering;
using PalmierPro.Services.Media;
using PalmierPro.Services.Project;
using Serilog;
using Windows.System;
using Windows.UI.Core;

namespace PalmierPro.App.Views;

/// Media panel (Stage B), timeline (Stage C), preview canvas (Stage D), and inspector (Stage E)
/// are all real. The media panel's EngineSession and preview's IVideoEngine are two independent
/// native sessions — the former backs thumbnail/peak extraction (per-asset), the latter backs
/// timeline composition/swap-chain presentation; both are created/disposed alongside their
/// document. InspectorHost owns no engine session of its own — it only reads the same
/// TimelineEditorViewModel the timeline/preview already share.
public sealed partial class EditorPlaceholderView : UserControl
{
    private readonly Window _window;
    private EngineSession? _engineSession;
    private MediaVisualCache? _visualCache;
    private LottieBakeService? _lottieBakeService;
    private MediaTabViewModel? _mediaTabViewModel;
    private PreviewViewModel? _previewViewModel;
    private TransportViewModel? _transportViewModel;

    public EditorPlaceholderView(Window window)
    {
        InitializeComponent();
        _window = window;
        foreach (var panel in new[] { MediaPanel, PreviewPanel, InspectorPanel, TimelinePanel })
        {
            panel.CornerRadius = AppTheme.UniformCornerRadius(AppThemeTokens.Radius.Md);
            panel.BorderBrush = AppTheme.Border.SubtleBrush;
            panel.BorderThickness = AppTheme.UniformThickness(AppThemeTokens.BorderWidth.Hairline);
        }
    }

    /// Called whenever ShellViewModel.ActiveDocument (and its paired Timeline) changes — including
    /// to null on ShowHome, at which point the previous document's engine sessions/media cache are
    /// torn down.
    public void SetDocument(ProjectDocument? document, TimelineEditorViewModel? timeline)
    {
        TearDownMediaTab();
        TearDownPreview();
        TimelineTabBarHost.SetViewModel(null);
        TimelineHost.Attach(null);
        InspectorHost.SetTimeline(null);
        if (document is null || timeline is null)
        {
            MediaPanelHost.SetViewModel(null);
            return;
        }

        // Unlike the media panel/timeline/preview above, the inspector owns no engine session of
        // its own — it only reads clip selection off `timeline`, so it's wired independently of
        // whether the native engine session below succeeds.
        InspectorHost.SetTimeline(timeline);

        try
        {
            var session = new EngineSession();
            var visualCache = new MediaVisualCache(session);
            var importService = new MediaImportService(new EngineMediaProbe(session));
            var missingMediaService = new MissingMediaService();
            var dialogService = new MediaImportDialogService(_window);
            var viewModel = new MediaTabViewModel(document, importService, visualCache, missingMediaService, dialogService);
            // Shares `session` rather than opening a third native session — PE_BakeLottieVideo/
            // PE_ProbeLottieMetadata touch no session-scoped state beyond error-message reporting
            // (docs/lottie-bake-v1.md §8), and this service's lifetime already tracks the media
            // tab's (both torn down together below, both recreated together per document).
            var lottieBakeService = new LottieBakeService(session);

            _engineSession = session;
            _visualCache = visualCache;
            _lottieBakeService = lottieBakeService;
            _mediaTabViewModel = viewModel;
            viewModel.AssetOpenRequested += OnAssetOpenRequested;
            MediaPanelHost.SetViewModel(viewModel);

            TimelineTabBarHost.SetViewModel(timeline);
            TimelineHost.Attach(new TimelineCanvasContext(timeline, visualCache, viewModel.AssetById, viewModel.ImportPathsAsync));
        }
        catch (EngineException ex)
        {
            Log.Error(ex, "media panel: failed to start the native engine session");
            MediaPanelHost.SetViewModel(null);
        }

        // timeline.Engine is null only for a `dotnet test`-style caller that built ShellViewModel
        // without an engine factory (see ShellViewModel's ctor) — the real app always supplies one.
        if (timeline.Engine is { } engine)
        {
            var previewViewModel = new PreviewViewModel(document, timeline, engine, _lottieBakeService);
            _previewViewModel = previewViewModel;
            PreviewHost.SetViewModel(previewViewModel);
            AudioMeterHost.SetViewModel(previewViewModel);

            // `dispatch` marshals TransportViewModel's engine-thread callbacks (PlayheadChanged/
            // IsPlayingChanged) onto this UI thread — see that class's ctor remarks.
            var transportViewModel = new TransportViewModel(timeline, engine, dispatch: action => DispatcherQueue.TryEnqueue(() => action()));
            _transportViewModel = transportViewModel;
            TransportBarHost.SetViewModel(transportViewModel);
        }
        else
        {
            PreviewHost.SetViewModel(null);
            AudioMeterHost.SetViewModel(null);
            TransportBarHost.SetViewModel(null);
        }
    }

    public Task RequestImportMediaAsync() => MediaPanelHost.RequestImportAsync();

    /// Double-click on a media-panel asset tile → the source-asset preview toggle. Fire-and-forget
    /// (same reasoning as PreviewViewModel's own ctor-time RebuildAsync): a failed open is caught
    /// and logged inside OpenSourcePreviewAsync, nothing here can surface it more loudly anyway.
    private void OnAssetOpenRequested(object? sender, MediaAsset asset) => _ = _previewViewModel?.OpenSourcePreviewAsync(asset);

    private void TearDownMediaTab()
    {
        if (_mediaTabViewModel is not null)
        {
            _mediaTabViewModel.AssetOpenRequested -= OnAssetOpenRequested;
        }
        _mediaTabViewModel?.Dispose();
        _mediaTabViewModel = null;
        _visualCache?.Dispose();
        _visualCache = null;
        // PreviewViewModel (torn down by TearDownPreview, called right after this) unsubscribes
        // from _lottieBakeService.StatusChanged itself — nulling this field here doesn't affect
        // that, since it holds its own captured reference from construction.
        _lottieBakeService = null;
        _engineSession?.Dispose();
        _engineSession = null;
    }

    /// PreviewHost.SetViewModel(null) detaches the swap chain (and unsubscribes) before the engine
    /// itself gets disposed below — same teardown-before-setup order TearDownMediaTab already uses.
    private void TearDownPreview()
    {
        PreviewHost.SetViewModel(null);
        AudioMeterHost.SetViewModel(null);
        _previewViewModel?.Dispose();
        _previewViewModel = null;
        TransportBarHost.SetViewModel(null);
        _transportViewModel?.Dispose();
        _transportViewModel = null;
    }

    // MARK: - Transport keyboard shortcuts (Space/arrows — see KeyRouter.HandleTransportKey)

    private void RootGrid_KeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (_transportViewModel is not { } transport)
        {
            return;
        }
        if (KeyRouter.HandleTransportKey(transport, XamlRoot, e.Key, CurrentModifiers()))
        {
            e.Handled = true;
        }
    }

    private static VirtualKeyModifiers CurrentModifiers()
    {
        var modifiers = VirtualKeyModifiers.None;
        if (IsKeyDown(VirtualKey.Shift)) modifiers |= VirtualKeyModifiers.Shift;
        if (IsKeyDown(VirtualKey.Control)) modifiers |= VirtualKeyModifiers.Control;
        if (IsKeyDown(VirtualKey.Menu)) modifiers |= VirtualKeyModifiers.Menu;
        return modifiers;
    }

    private static bool IsKeyDown(VirtualKey key) =>
        InputKeyboardSource.GetKeyStateForCurrentThread(key).HasFlag(CoreVirtualKeyStates.Down);
}
