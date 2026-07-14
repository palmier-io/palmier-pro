using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using PalmierPro.Core.Theme;
using PalmierPro.Rendering;
using Windows.Storage.Pickers;
using WinRT.Interop;

namespace PalmierPro.DevHarness;

public sealed partial class MainWindow : Window
{
    private static readonly string[] VideoExtensions =
        [".mp4", ".mov", ".mkv", ".m4v", ".avi", ".webm"];

    private readonly EngineSession _session = new();
    private MediaSource? _media;
    private bool _swapChainAttached;

    public MainWindow()
    {
        InitializeComponent();
        Title = "PalmierPro DevHarness";
        ApplyTheme();
        TimelineHarness.Initialize(this);

        Closed += MainWindow_Closed;
    }

    private void ApplyTheme()
    {
        RootGrid.Background = HarnessTheme.BackgroundBaseBrush;
        PreviewHost.Background = HarnessTheme.BackgroundBaseBrush;

        Toolbar.Background = HarnessTheme.BackgroundSurfaceBrush;
        Toolbar.Padding = HarnessTheme.UniformThickness(AppThemeTokens.Spacing.Md);
        Toolbar.Spacing = AppThemeTokens.Spacing.SmMd;
        Toolbar.BorderBrush = HarnessTheme.BorderPrimaryBrush;
        Toolbar.BorderThickness = HarnessTheme.ThicknessOf(0, 0, 0, AppThemeTokens.BorderWidth.Thin);

        MediaStatusText.Foreground = HarnessTheme.TextSecondaryBrush;
        MediaStatusText.FontSize = AppThemeTokens.FontSize.Sm;
        MediaStatusText.MinWidth = 220;

        TimeReadoutText.Foreground = HarnessTheme.TextMutedBrush;
        TimeReadoutText.FontSize = AppThemeTokens.FontSize.Sm;
        TimeReadoutText.MinWidth = 60;

        TimeSlider.MinWidth = 260;
        TimeSlider.VerticalAlignment = VerticalAlignment.Center;
    }

    private async void OpenButton_Click(object sender, RoutedEventArgs e)
    {
        var picker = new FileOpenPicker { SuggestedStartLocation = PickerLocationId.VideosLibrary };
        foreach (string ext in VideoExtensions)
        {
            picker.FileTypeFilter.Add(ext);
        }
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));

        Windows.Storage.StorageFile? file = await picker.PickSingleFileAsync();
        if (file is null)
        {
            return;
        }

        try
        {
            OpenMedia(file.Path);
        }
        catch (EngineException ex)
        {
            MediaStatusText.Text = $"Open failed: {ex.Message}";
            MediaStatusText.Foreground = HarnessTheme.StatusErrorBrush;
        }
    }

    private void OpenMedia(string path)
    {
        _media?.Dispose();
        _media = null;

        MediaSource media = _session.OpenMedia(path);
        _media = media;

        MediaStatusText.Text = $"{System.IO.Path.GetFileName(path)} — {media.Info.Width}x{media.Info.Height} @ {media.Info.Fps:0.##}fps, {media.Info.Duration:mm\\:ss\\.ff}";
        MediaStatusText.Foreground = HarnessTheme.TextSecondaryBrush;

        TimeSlider.Maximum = Math.Max(media.Info.Duration.TotalSeconds, 0);
        TimeSlider.Value = 0;
        TimeSlider.IsEnabled = true;
        ShowFrameButton.IsEnabled = true;

        PresentCurrentFrame();
    }

    private void TimeSlider_ValueChanged(object sender, Microsoft.UI.Xaml.Controls.Primitives.RangeBaseValueChangedEventArgs e)
    {
        TimeReadoutText.Text = $"{e.NewValue:0.00}s";
    }

    private void ShowFrameButton_Click(object sender, RoutedEventArgs e) => PresentCurrentFrame();

    private void PresentCurrentFrame()
    {
        if (_media is null)
        {
            return;
        }
        try
        {
            _session.PresentFrameAt(_media, TimeSlider.Value);
        }
        catch (EngineException ex)
        {
            MediaStatusText.Text = $"Present failed: {ex.Message}";
            MediaStatusText.Foreground = HarnessTheme.StatusErrorBrush;
        }
    }

    // UI-thread call, per the SwapChainPanel threading contract in palmier_engine.h:
    // first SizeChanged (once the panel has laid out to a real size) attaches; every
    // one after that resizes the already-attached swap chain.
    private void EngineSurface_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        int width = (int)Math.Round(e.NewSize.Width);
        int height = (int)Math.Round(e.NewSize.Height);
        if (width <= 0 || height <= 0)
        {
            return;
        }

        try
        {
            if (!_swapChainAttached)
            {
                _session.AttachSwapChain(EngineSurface, width, height);
                _swapChainAttached = true;
                PresentCurrentFrame();
            }
            else
            {
                _session.ResizeSwapChain(width, height);
                PresentCurrentFrame();
            }
        }
        catch (EngineException ex)
        {
            MediaStatusText.Text = $"Swap chain error: {ex.Message}";
            MediaStatusText.Foreground = HarnessTheme.StatusErrorBrush;
        }
    }

    private void MainWindow_Closed(object sender, WindowEventArgs args)
    {
        if (_swapChainAttached)
        {
            _session.DetachSwapChain();
        }
        _media?.Dispose();
        _session.Dispose();
        TimelineHarness.Cleanup();
    }
}
