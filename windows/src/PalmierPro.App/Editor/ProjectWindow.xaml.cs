using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using PalmierPro.Media.Playback;
using Windows.Storage.Pickers;

namespace PalmierPro.App.Editor;

/// <summary>
/// Phase 2 editor window: media panel, D3D11 preview with transport, timeline placeholder.
/// </summary>
public sealed partial class ProjectWindow : Window
{
    public ProjectViewModel ViewModel { get; }

    private SwapChainPresenter? _presenter;
    private VideoPlaybackEngine? _engine;
    private bool _scrubbing;

    public ProjectWindow(string packagePath)
    {
        ViewModel = new ProjectViewModel(packagePath, Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread());
        InitializeComponent();
        Title = ViewModel.ProjectName;
        AppWindow.TitleBar.ExtendsContentIntoTitleBar = true;
        AppWindow.TitleBar.ButtonBackgroundColor = Colors.Transparent;
        ProjectNameText.Text = ViewModel.ProjectName;

        ViewModel.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(ProjectViewModel.IsPlaying))
                PlayPauseIcon.Glyph = ViewModel.IsPlaying ? "\uE769" : "\uE768";
            if (e.PropertyName == nameof(ProjectViewModel.PlayheadFrame) && !_scrubbing)
                ScrubSlider.Value = ViewModel.PlayheadFrame;
        };

        Closed += OnClosed;
        _ = InitializeAsync();
    }

    private async Task InitializeAsync()
    {
        try
        {
            await ViewModel.LoadAsync();
        }
        catch (Exception ex)
        {
            ProjectNameText.Text = $"{ViewModel.ProjectName} — failed to load: {ex.Message}";
            return;
        }

        _presenter = new SwapChainPresenter(
            PreviewPanel,
            Math.Max(8, (int)PreviewPanel.ActualWidth),
            Math.Max(8, (int)PreviewPanel.ActualHeight));
        _engine = new VideoPlaybackEngine(_presenter);
        ViewModel.AttachEngine(_engine);
        ViewModel.SeekExact(0);
    }

    private void OnClosed(object sender, WindowEventArgs args)
    {
        _engine?.Dispose();
        _presenter?.Dispose();
    }

    private void OnPreviewSizeChanged(object sender, SizeChangedEventArgs e)
        => _presenter?.Resize((int)e.NewSize.Width, (int)e.NewSize.Height);

    private void OnPlayPauseClicked(object sender, RoutedEventArgs e) => ViewModel.TogglePlayback();
    private void OnStepBackClicked(object sender, RoutedEventArgs e) => ViewModel.StepBackward();
    private void OnStepForwardClicked(object sender, RoutedEventArgs e) => ViewModel.StepForward();

    private void OnScrubValueChanged(object sender, RangeBaseValueChangedEventArgs e)
    {
        // Ignore programmatic updates from playhead sync.
        if (Math.Abs(e.NewValue - ViewModel.PlayheadFrame) < 1) return;
        _scrubbing = true;
        ViewModel.Scrub((int)e.NewValue);
    }

    private void OnScrubEnded(object sender, PointerRoutedEventArgs e)
    {
        if (!_scrubbing) return;
        _scrubbing = false;
        ViewModel.SeekExact((int)ScrubSlider.Value);
    }

    private void OnMediaTileLoaded(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { DataContext: MediaItemViewModel item })
            _ = item.LoadThumbnailAsync();
    }

    private async void OnImportClicked(object sender, RoutedEventArgs e)
    {
        var picker = new FileOpenPicker();
        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);
        WinRT.Interop.InitializeWithWindow.Initialize(picker, hwnd);
        foreach (var ext in new[] { ".mov", ".mp4", ".m4v", ".mp3", ".wav", ".aac", ".m4a", ".aiff",
                     ".aif", ".flac", ".png", ".jpg", ".jpeg", ".tiff", ".heic", ".webp", ".json", ".lottie" })
        {
            picker.FileTypeFilter.Add(ext);
        }
        var files = await picker.PickMultipleFilesAsync();
        if (files.Count == 0) return;
        await ViewModel.ImportAsync([.. files.Select(f => f.Path)]);
    }
}
