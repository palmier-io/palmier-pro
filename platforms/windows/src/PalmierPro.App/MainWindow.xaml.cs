using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using PalmierPro.App.Services;
using PalmierPro.App.ViewModels;
using PalmierPro.App.Views;
using PalmierPro.Core.Theme;
using PalmierPro.Services.Project;
using Windows.Graphics;
using WinRT.Interop;

namespace PalmierPro.App;

/// Single-window shell (Phase 1 — see the Windows port plan's "Window model" decision): one
/// MainWindow navigates between HomeView and the editor placeholder rather than opening separate
/// NSWindow-style windows per document, and hosts the in-titlebar menu bar in place of Mac's OS
/// menu bar.
public sealed partial class MainWindow : Window
{
    public ShellViewModel Shell { get; }

    private readonly HomeView _homeView = new();
    private readonly EditorPlaceholderView _editorView;
    private readonly AppWindow _appWindow;
    private readonly nint _hwnd;
    private OverlappedPresenter _presenter;
    private bool _isFullScreen;

    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(nint hWnd);

    public MainWindow()
    {
        InitializeComponent();
        Title = "Palmier Pro";

        ProjectPackage.EnsureDefaultProjectsDirectory();
        var registry = ProjectRegistry.CreateDefault();
        _editorView = new EditorPlaceholderView(this);

        Shell = new ShellViewModel(registry, new ProjectDialogService(this));
        Shell.PropertyChanged += Shell_PropertyChanged;
        Shell.RequestQuit += (_, _) => Application.Current.Exit();
        Shell.ImportMediaRequested += (_, _) => _ = _editorView.RequestImportMediaAsync();

        _homeView.Initialize(new HomeViewModel(Shell));
        MenuBarHost.Initialize(Shell);
        MenuBarHost.EnterFullScreenRequested += (_, _) => ToggleFullScreen();

        _hwnd = WindowNative.GetWindowHandle(this);
        var windowId = Win32Interop.GetWindowIdFromWindow(_hwnd);
        _appWindow = AppWindow.GetFromWindowId(windowId);
        if (_appWindow.Presenter is OverlappedPresenter presenter)
        {
            _presenter = presenter;
        }
        else
        {
            _presenter = OverlappedPresenter.Create();
            _appWindow.SetPresenter(_presenter);
        }

        ExtendsContentIntoTitleBar = true;
        SetTitleBar(DragRegion);

        // AppThemeTokens.Window.* are Mac logical points; AppWindow.Resize/PreferredMinimum*
        // take physical pixels, so every dimension must be scaled by the window's DPI or it opens
        // far too small on any non-100%-scale display (the common case on real Windows laptops).
        if (Content?.XamlRoot is { } xamlRoot)
        {
            xamlRoot.Changed += (_, _) =>
                UpdateMinSize(Shell.IsEditorOpen ? AppThemeTokens.Window.ProjectMin : AppThemeTokens.Window.HomeMin);
        }

        double scale = DpiScale();
        _appWindow.Resize(new SizeInt32(
            (int)(AppThemeTokens.Window.HomeDefault.Width * scale),
            (int)(AppThemeTokens.Window.HomeDefault.Height * scale)));

        ShowHome();
    }

    private double DpiScale()
    {
        uint dpi = GetDpiForWindow(_hwnd);
        return dpi > 0 ? dpi / 96.0 : 1.0;
    }

    private void Shell_PropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is null or nameof(ShellViewModel.ActiveDocument))
        {
            _editorView.SetDocument(Shell.ActiveDocument);
        }
        if (e.PropertyName is null or nameof(ShellViewModel.IsEditorOpen))
        {
            if (Shell.IsEditorOpen) ShowEditor(); else ShowHome();
        }
        if (e.PropertyName is null or nameof(ShellViewModel.WindowTitle))
        {
            UpdateTitle();
        }
    }

    private void ShowHome()
    {
        ContentHost.Content = _homeView;
        UpdateMinSize(AppThemeTokens.Window.HomeMin);
        UpdateTitle();
    }

    private void ShowEditor()
    {
        ContentHost.Content = _editorView;
        UpdateMinSize(AppThemeTokens.Window.ProjectMin);
        UpdateTitle();
    }

    private void UpdateTitle()
    {
        Title = Shell.WindowTitle;
        TitleText.Text = Shell.WindowTitle;
    }

    private void UpdateMinSize(ThemeSize min)
    {
        double scale = DpiScale();
        _presenter.PreferredMinimumWidth = (int)(min.Width * scale);
        _presenter.PreferredMinimumHeight = (int)(min.Height * scale);
    }

    private void ToggleFullScreen()
    {
        _isFullScreen = !_isFullScreen;
        _appWindow.SetPresenter(_isFullScreen ? AppWindowPresenterKind.FullScreen : AppWindowPresenterKind.Overlapped);
        // SetPresenter(AppWindowPresenterKind) can hand back a new OverlappedPresenter instance —
        // re-resolve rather than trust the cached reference, or a post-fullscreen min-size update
        // would silently apply to a detached presenter.
        if (_appWindow.Presenter is OverlappedPresenter presenter)
        {
            _presenter = presenter;
            UpdateMinSize(Shell.IsEditorOpen ? AppThemeTokens.Window.ProjectMin : AppThemeTokens.Window.HomeMin);
        }
    }
}
