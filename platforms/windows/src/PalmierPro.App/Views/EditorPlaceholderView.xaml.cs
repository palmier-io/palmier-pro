using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using PalmierPro.App.Services;
using PalmierPro.App.Theme;
using PalmierPro.App.ViewModels.MediaPanel;
using PalmierPro.Core.Theme;
using PalmierPro.Rendering;
using PalmierPro.Services.Media;
using PalmierPro.Services.Project;
using Serilog;

namespace PalmierPro.App.Views;

/// Media panel is real (Stage B), wired to a per-document native EngineSession created/disposed
/// alongside it; preview/inspector/timeline remain themed skeletons until Stage C/D.
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

    /// Called whenever ShellViewModel.ActiveDocument changes — including to null on ShowHome, at
    /// which point the previous document's engine session/media cache are torn down.
    public void SetDocument(ProjectDocument? document)
    {
        TearDownMediaTab();
        if (document is null)
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
