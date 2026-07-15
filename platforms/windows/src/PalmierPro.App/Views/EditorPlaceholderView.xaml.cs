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

/// Media panel (Stage B), timeline (Stage C), and preview canvas (Stage D) are real; inspector
/// remains a themed skeleton until Stage E. The media panel's EngineSession and preview's
/// IVideoEngine are two independent native sessions — the former backs thumbnail/peak extraction
/// (per-asset), the latter backs timeline composition/swap-chain presentation; both are
/// created/disposed alongside their document.
public sealed partial class EditorPlaceholderView : UserControl
{
    private readonly Window _window;
    private EngineSession? _engineSession;
    private MediaVisualCache? _visualCache;
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
        if (document is null || timeline is null)
        {
            MediaPanelHost.SetViewModel(null);
            return;
        }

        try
        {
            var session = new EngineSession();
            var visualCache = new MediaVisualCache(session);
            var importService = new MediaImportService(new EngineMediaProbe(session));
            var missingMediaService = new MissingMediaService();
            var dialogService = new MediaImportDialogService(_window);
            var viewModel = new MediaTabViewModel(document, importService, visualCache, missingMediaService, dialogService);

            _engineSession = session;
            _visualCache = visualCache;
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
            var previewViewModel = new PreviewViewModel(document, timeline, engine);
            _previewViewModel = previewViewModel;
            PreviewHost.SetViewModel(previewViewModel);

            // `dispatch` marshals TransportViewModel's engine-thread callbacks (PlayheadChanged/
            // IsPlayingChanged) onto this UI thread — see that class's ctor remarks.
            var transportViewModel = new TransportViewModel(timeline, engine, dispatch: action => DispatcherQueue.TryEnqueue(() => action()));
            _transportViewModel = transportViewModel;
            TransportBarHost.SetViewModel(transportViewModel);
        }
        else
        {
            PreviewHost.SetViewModel(null);
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
        _engineSession?.Dispose();
        _engineSession = null;
    }

    /// PreviewHost.SetViewModel(null) detaches the swap chain (and unsubscribes) before the engine
    /// itself gets disposed below — same teardown-before-setup order TearDownMediaTab already uses.
    private void TearDownPreview()
    {
        PreviewHost.SetViewModel(null);
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
