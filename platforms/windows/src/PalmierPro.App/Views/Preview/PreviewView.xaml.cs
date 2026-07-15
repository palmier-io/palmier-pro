using System.ComponentModel;
using System.Linq;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using PalmierPro.App.Theme;
using PalmierPro.App.ViewModels.Editor;
using PalmierPro.App.ViewModels.Preview;
using PalmierPro.Core.Theme;
using PalmierPro.Rendering;
using PalmierPro.Services.Engine;
using Serilog;

namespace PalmierPro.App.Views.Preview;

/// SwapChainPanel host (M4, Stage D) — owns the swap-chain threading contract (attach/resize on
/// this, the UI, thread; palmier_engine.h's present loop runs on the engine's own render thread),
/// aspect-fit letterboxing (timeline canvas or, in source mode, the open asset's own dimensions),
/// the Timeline/source-asset tab toggle, and source-asset scrub. Timeline play/pause/step transport
/// is the sibling TransportBar control (EditorPlaceholderView.xaml docks it under this one) — not
/// this class's concern. Detaches on unload/document-switch (EditorPlaceholderView calls
/// `SetViewModel(null)` before handing this a new one, same teardown-before-setup order as
/// MediaPanelHost/TimelineHost) so a stale PE_TimelineHandle never outlives the panel it was
/// attached to.
public sealed partial class PreviewView : UserControl
{
    private PreviewViewModel? _vm;
    private int _canvasWidth;
    private int _canvasHeight;
    private bool _attached;
    private MediaStatus _lastMediaStatus = MediaStatus.Empty;
    private bool _isScrubbing;

    public PreviewView()
    {
        InitializeComponent();
        // {StaticResource} into Padding/CornerRadius/a plain Color-with-opacity brush doesn't
        // coerce the way a literal XAML attribute does (see AGENTS.md) — all set here instead.
        MediaStatusOverlay.Padding = AppTheme.UniformThickness(AppThemeTokens.Spacing.Xl);
        MediaStatusOverlay.Background = new SolidColorBrush(Colors.Black) { Opacity = AppThemeTokens.Opacity.Strong };
        TabBarHost.BorderBrush = AppTheme.Border.PrimaryBrush;
        TabBarHost.BorderThickness = AppTheme.ThicknessOf(0, 0, 0, AppThemeTokens.BorderWidth.Hairline);
        TabBarHost.Padding = AppTheme.ThicknessOf(AppThemeTokens.Spacing.Sm, 0, AppThemeTokens.Spacing.Sm, 0);
        SourceScrubTrack.CornerRadius = AppTheme.UniformCornerRadius(AppThemeTokens.Radius.Xs);
        SourceScrubFill.CornerRadius = AppTheme.UniformCornerRadius(AppThemeTokens.Radius.Xs);
        Unloaded += (_, _) => SetViewModel(null);
    }

    public void SetViewModel(PreviewViewModel? vm)
    {
        DetachSurface();
        if (_vm is not null)
        {
            _vm.MediaStatusChanged -= OnMediaStatusChanged;
            _vm.ModeChanged -= OnModeChanged;
            _vm.Timeline.PropertyChanged -= OnTimelinePropertyChanged;
            _vm.Timeline.StructuralChangeRequested -= OnTimelineStructuralChange;
        }
        _vm = vm;
        _lastMediaStatus = MediaStatus.Empty;
        MediaStatusOverlay.Visibility = Visibility.Collapsed;
        RefreshTabBar();
        RefreshSourceScrubBar();
        if (_vm is null)
        {
            return;
        }
        _vm.MediaStatusChanged += OnMediaStatusChanged;
        _vm.ModeChanged += OnModeChanged;
        _vm.Timeline.PropertyChanged += OnTimelinePropertyChanged;
        _vm.Timeline.StructuralChangeRequested += OnTimelineStructuralChange;
        UpdateCanvasAspect();
        ApplySurfaceSize();
        // Covers "already loaded, size unchanged" (e.g. opening a second project while this
        // control is already on screen) — the natural Surface_SizeChanged handles every other
        // case, including the very first layout pass after a fresh SetViewModel.
        SyncSwapChain((int)Math.Round(Surface.ActualWidth), (int)Math.Round(Surface.ActualHeight));
    }

    private void OnTimelinePropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(TimelineEditorViewModel.ActiveTimelineId))
        {
            DispatcherQueue.TryEnqueue(() =>
            {
                UpdateCanvasAspect();
                ApplySurfaceSize();
            });
        }
    }

    private void OnTimelineStructuralChange(object? sender, EventArgs e) => DispatcherQueue.TryEnqueue(() =>
    {
        UpdateCanvasAspect();
        ApplySurfaceSize();
    });

    /// Timeline ↔ source-asset toggle (see PreviewViewModel.ModeChanged) — rebuilds the tab bar,
    /// re-fits the canvas to whichever surface is now active, and shows/hides the pieces that are
    /// mode-specific (media-status overlay, source scrub bar).
    private void OnModeChanged(object? sender, EventArgs e) => DispatcherQueue.TryEnqueue(() =>
    {
        RefreshTabBar();
        UpdateCanvasAspect();
        ApplySurfaceSize();
        RefreshMediaStatusOverlay();
        RefreshSourceScrubBar();
    });

    private void UpdateCanvasAspect()
    {
        if (_vm is null)
        {
            return;
        }
        if (_vm.Mode == PreviewMode.Source && _vm.SourceAsset is { SourceWidth: { } w, SourceHeight: { } h } && w > 0 && h > 0)
        {
            _canvasWidth = w;
            _canvasHeight = h;
            return;
        }
        var timeline = _vm.Timeline.Timeline;
        _canvasWidth = timeline.Width;
        _canvasHeight = timeline.Height;
    }

    private void CanvasArea_SizeChanged(object sender, SizeChangedEventArgs e) => ApplySurfaceSize();

    /// Aspect-fit + center Surface (and the status overlay, sized to match it) inside CanvasArea —
    /// the letterbox itself is just whatever of CanvasArea's black background is left uncovered.
    /// Falls back to 16:9 before a timeline's (or source asset's) real dimensions are known.
    private void ApplySurfaceSize()
    {
        double containerW = CanvasArea.ActualWidth;
        double containerH = CanvasArea.ActualHeight;
        if (containerW <= 0 || containerH <= 0)
        {
            return;
        }
        double aspect = _canvasWidth > 0 && _canvasHeight > 0 ? (double)_canvasWidth / _canvasHeight : 16.0 / 9.0;
        double fitW = containerH * aspect;
        double fitH;
        if (fitW <= containerW)
        {
            fitH = containerH;
        }
        else
        {
            fitW = containerW;
            fitH = containerW / aspect;
        }
        Surface.Width = fitW;
        Surface.Height = fitH;
        MediaStatusOverlay.Width = fitW;
        MediaStatusOverlay.Height = fitH;
    }

    private void Surface_SizeChanged(object sender, SizeChangedEventArgs e) =>
        SyncSwapChain((int)Math.Round(e.NewSize.Width), (int)Math.Round(e.NewSize.Height));

    /// Threading contract (palmier_engine.h): attach/resize are UI-thread calls — this method is
    /// only ever invoked from a XAML event handler or from SetViewModel, both on the UI thread.
    /// Resize itself quiesces/ResizeBuffers/re-SetSwapChain natively; nothing extra to do here
    /// beyond picking attach vs. resize based on whether this panel has attached before.
    private void SyncSwapChain(int width, int height)
    {
        if (_vm is null || width <= 0 || height <= 0)
        {
            return;
        }
        try
        {
            if (!_attached)
            {
                _vm.Engine.AttachSwapChain(Surface, width, height);
                _attached = true;
                Log.Information("preview: swap chain attached ({Width}x{Height})", width, height);
            }
            else
            {
                _vm.Engine.ResizeSwapChain(width, height);
            }
        }
        catch (EngineException ex)
        {
            Log.Warning(ex, "preview: swap chain attach/resize failed");
        }
    }

    private void DetachSurface()
    {
        if (_attached)
        {
            try
            {
                _vm?.Engine.DetachSwapChain();
            }
            catch (EngineException ex)
            {
                Log.Warning(ex, "preview: swap chain detach failed");
            }
        }
        _attached = false;
    }

    private void OnMediaStatusChanged(object? sender, MediaStatus status) => DispatcherQueue.TryEnqueue(() =>
    {
        _lastMediaStatus = status;
        RefreshMediaStatusOverlay();
    });

    /// Timeline media health only — hidden in source-asset mode (see OnModeChanged) rather than
    /// shown over an unrelated asset, since `_lastMediaStatus` describes the active timeline, not
    /// whatever's currently in the source-asset preview.
    private void RefreshMediaStatusOverlay()
    {
        if (_vm is not { Mode: PreviewMode.Timeline })
        {
            MediaStatusOverlay.Visibility = Visibility.Collapsed;
            return;
        }
        ApplyMediaStatus(_lastMediaStatus);
    }

    /// Global (whole-timeline) rather than the Mac's under-the-playhead-only banner — this doesn't
    /// read TransportViewModel's `Timeline.CurrentFrame` to scope which clip is actually under the
    /// playhead right now; showing the banner whenever ANY clip in the active timeline is
    /// offline/unprocessable is the honest v1 behavior until that frame-scoping is wired up.
    private void ApplyMediaStatus(MediaStatus status)
    {
        int total = status.OfflineMediaRefs.Count + status.UnprocessableMediaRefs.Count;
        if (total == 0)
        {
            MediaStatusOverlay.Visibility = Visibility.Collapsed;
            return;
        }
        bool isUnprocessable = status.UnprocessableMediaRefs.Count > 0;
        MediaStatusTitle.Text = isUnprocessable ? "Couldn't Prepare Media" : "Media Offline";
        MediaStatusMessage.Text = isUnprocessable
            ? "Palmier loaded this clip's source file but couldn't prepare it for playback. The file may be corrupt or in an unsupported format."
            : "Palmier couldn't load this clip's source file. It may be missing, on an ejected drive, or unreadable.";
        MediaStatusPath.Text = string.Join(", ", status.UnprocessableMediaRefs.Concat(status.OfflineMediaRefs));
        MediaStatusOverlay.Visibility = Visibility.Visible;
    }

    // MARK: - Tab bar (Timeline / source-asset toggle)

    /// Built in code-behind rather than data-templated — same reasoning as TimelineTabBarView
    /// (RefreshTabs): at most two tabs, rebuilt whole on every mode change, no incremental diffing
    /// needed.
    private void RefreshTabBar()
    {
        TabBar.Children.Clear();
        if (_vm is null)
        {
            return;
        }
        TabBar.Children.Add(BuildTab("Timeline", isActive: _vm.Mode == PreviewMode.Timeline, closeable: false));
        if (_vm.SourceAsset is { } asset)
        {
            TabBar.Children.Add(BuildTab(asset.Name, isActive: _vm.Mode == PreviewMode.Source, closeable: true));
        }
    }

    private FrameworkElement BuildTab(string label, bool isActive, bool closeable)
    {
        var root = new Grid
        {
            Padding = AppTheme.ThicknessOf(AppThemeTokens.Spacing.Xs, AppThemeTokens.Spacing.Xxs, AppThemeTokens.Spacing.Xs, AppThemeTokens.Spacing.Xxs),
        };
        var stack = new StackPanel { Orientation = Orientation.Horizontal, Spacing = AppThemeTokens.Spacing.Xs, VerticalAlignment = VerticalAlignment.Center };
        stack.Children.Add(new TextBlock
        {
            Text = label,
            FontSize = AppThemeTokens.FontSize.Xs,
            FontWeight = AppTheme.FontWeightFor(isActive ? AppThemeTokens.FontWeight.Semibold : AppThemeTokens.FontWeight.Medium),
            Foreground = isActive ? AppTheme.Text.PrimaryBrush : AppTheme.Text.SecondaryBrush,
            VerticalAlignment = VerticalAlignment.Center,
        });

        if (closeable)
        {
            var close = new Button
            {
                Content = "", // Cancel glyph — matches TimelineTabBarView's close button.
                FontFamily = new FontFamily("Segoe Fluent Icons"),
                FontSize = AppThemeTokens.FontSize.Xxs,
                Background = new SolidColorBrush(Colors.Transparent),
                BorderThickness = AppTheme.UniformThickness(0),
                Padding = AppTheme.UniformThickness(AppThemeTokens.Spacing.Xxs),
            };
            close.Click += (_, _) => _vm?.ShowTimeline();
            stack.Children.Add(close);
        }
        root.Children.Add(stack);

        root.Children.Add(new Border
        {
            Height = AppThemeTokens.BorderWidth.Medium,
            VerticalAlignment = VerticalAlignment.Bottom,
            Background = isActive ? AppTheme.Accent.PrimaryBrush : new SolidColorBrush(Colors.Transparent),
        });

        if (!closeable)
        {
            // The Timeline tab is the only one ever tapped to switch mode — the source-asset tab
            // is only ever shown while it's already active (see RefreshTabBar), so it only needs
            // its close button wired.
            root.Tapped += (_, e) => { _vm?.ShowTimeline(); e.Handled = true; };
        }
        return root;
    }

    // MARK: - Source-asset scrub bar

    private void RefreshSourceScrubBar()
    {
        SourceScrubBar.Visibility = _vm?.Mode == PreviewMode.Source ? Visibility.Visible : Visibility.Collapsed;
        UpdateScrubFill();
    }

    private void UpdateScrubFill()
    {
        if (_vm is not { Mode: PreviewMode.Source } vm)
        {
            SourceScrubFill.Width = 0;
            return;
        }
        var duration = vm.SourceDurationFrames;
        var fraction = duration > 0 ? Math.Clamp((double)vm.SourceFrame / duration, 0, 1) : 0;
        SourceScrubFill.Width = SourceScrubTrack.ActualWidth * fraction;
    }

    private void SourceScrubBar_PointerPressed(object sender, PointerRoutedEventArgs e)
    {
        if (_vm is not { Mode: PreviewMode.Source })
        {
            return;
        }
        _isScrubbing = true;
        SourceScrubBar.CapturePointer(e.Pointer);
        ScrubTo(e.GetCurrentPoint(SourceScrubBar).Position.X, PreviewSeekMode.InteractiveScrub);
    }

    private void SourceScrubBar_PointerMoved(object sender, PointerRoutedEventArgs e)
    {
        if (!_isScrubbing)
        {
            return;
        }
        ScrubTo(e.GetCurrentPoint(SourceScrubBar).Position.X, PreviewSeekMode.InteractiveScrub);
    }

    private void SourceScrubBar_PointerReleased(object sender, PointerRoutedEventArgs e)
    {
        if (!_isScrubbing)
        {
            return;
        }
        _isScrubbing = false;
        SourceScrubBar.ReleasePointerCapture(e.Pointer);
        ScrubTo(e.GetCurrentPoint(SourceScrubBar).Position.X, PreviewSeekMode.Exact);
    }

    // A capture can be lost mid-drag (e.g. Alt+Tab) without a matching PointerReleased — settle at
    // the last known position rather than leave the coordinator's coalesced seek mid-flight.
    private void SourceScrubBar_PointerCaptureLost(object sender, PointerRoutedEventArgs e)
    {
        if (!_isScrubbing)
        {
            return;
        }
        _isScrubbing = false;
        ScrubTo(e.GetCurrentPoint(SourceScrubBar).Position.X, PreviewSeekMode.Exact);
    }

    private void ScrubTo(double x, PreviewSeekMode mode)
    {
        if (_vm is not { Mode: PreviewMode.Source } vm || SourceScrubBar.ActualWidth <= 0)
        {
            return;
        }
        var duration = vm.SourceDurationFrames;
        if (duration <= 0)
        {
            return;
        }
        var fraction = Math.Clamp(x / SourceScrubBar.ActualWidth, 0, 1);
        vm.SeekSource((int)Math.Round(fraction * duration), mode);
        UpdateScrubFill();
    }
}
