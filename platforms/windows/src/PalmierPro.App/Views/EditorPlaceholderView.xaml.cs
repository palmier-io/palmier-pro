using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using PalmierPro.App.Services;
using PalmierPro.App.Theme;
using PalmierPro.App.ViewModels.Editor;
using PalmierPro.App.ViewModels.MediaPanel;
using PalmierPro.App.Views.Timeline;
using PalmierPro.Core.Theme;
using PalmierPro.Rendering;
using PalmierPro.Services.Media;
using PalmierPro.Services.Project;
using Serilog;

namespace PalmierPro.App.Views;

/// Media panel (Stage B) and timeline (Stage C) are real, both wired to a per-document native
/// EngineSession created/disposed alongside them; preview/inspector remain themed skeletons until
/// Stage D/E.
public sealed partial class EditorPlaceholderView : UserControl
{
    private readonly Window _window;
    private EngineSession? _engineSession;
    private MediaVisualCache? _visualCache;
    private MediaTabViewModel? _mediaTabViewModel;

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
    /// to null on ShowHome, at which point the previous document's engine session/media cache are
    /// torn down.
    public void SetDocument(ProjectDocument? document, TimelineEditorViewModel? timeline)
    {
        TearDownMediaTab();
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
            MediaPanelHost.SetViewModel(viewModel);

            TimelineTabBarHost.SetViewModel(timeline);
            TimelineHost.Attach(new TimelineCanvasContext(timeline, visualCache, viewModel.AssetById, viewModel.ImportPathsAsync));
        }
        catch (EngineException ex)
        {
            Log.Error(ex, "media panel: failed to start the native engine session");
            MediaPanelHost.SetViewModel(null);
        }
    }

    public Task RequestImportMediaAsync() => MediaPanelHost.RequestImportAsync();

    private void TearDownMediaTab()
    {
        _mediaTabViewModel?.Dispose();
        _mediaTabViewModel = null;
        _visualCache?.Dispose();
        _visualCache = null;
        _engineSession?.Dispose();
        _engineSession = null;
    }
}
