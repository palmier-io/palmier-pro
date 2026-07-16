using System.ComponentModel;
using System.Numerics;
using System.Runtime.CompilerServices;
using Microsoft.Graphics.Canvas.Text;
using Microsoft.Graphics.Canvas.UI.Xaml;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using PalmierPro.App.Theme;
using PalmierPro.App.ViewModels.Editor;
using PalmierPro.App.ViewModels.Inspector;
using PalmierPro.App.Views.Timeline;
using PalmierPro.Core;
using PalmierPro.Core.Theme;
using Windows.Foundation;
using Windows.UI;

namespace PalmierPro.App.Views.Inspector.Tabs;

/// Keyframes tab content (M5, Stage E) — see KeyframesTabView.xaml's remarks. Registers itself into
/// InspectorTabRegistry for InspectorTab.Keyframes via the module-initializer seam that file
/// documents; nothing outside this pair of files needs to know this class exists.
public sealed partial class KeyframesTabView : UserControl
{
    private static readonly string RulerFontFamily = TimelineFontFamily();

    private readonly TimelineEditorViewModel _timeline;
    private readonly KeyframesViewModel? _vm;
    private readonly List<KeyframesLaneRowControl> _rows = [];
    private bool _headerDragging;
    private CanvasTextFormat? _rulerTextFormat;
    private CanvasTextFormat? _labelTextFormat;

    public KeyframesTabView(InspectorTabContext context)
    {
        InitializeComponent();
        RootStack.Padding = AppTheme.UniformThickness(AppThemeTokens.Spacing.Lg);
        HeaderCanvas.Height = AppThemeTokens.Inspector.RulerHeight + AppThemeTokens.Inspector.StripHeight;

        _timeline = context.Timeline;
        _vm = context.SelectedClips.Count == 1 ? new KeyframesViewModel(context) : null;
        BuildRows();

        _timeline.PropertyChanged += OnTimelinePropertyChanged;
        _timeline.StructuralChangeRequested += OnExternalChange;
        _timeline.RefreshVisualsRequested += OnExternalChange;
        Unloaded += (_, _) =>
        {
            _timeline.PropertyChanged -= OnTimelinePropertyChanged;
            _timeline.StructuralChangeRequested -= OnExternalChange;
            _timeline.RefreshVisualsRequested -= OnExternalChange;
        };
    }

    /// Registration seam — see InspectorTabRegistry's class doc. Runs once at process start, before
    /// any InspectorView exists to ask for a Keyframes tab.
    [ModuleInitializer]
    internal static void RegisterTab() =>
        InspectorTabRegistry.Register(InspectorTab.Keyframes, context => new KeyframesTabView(context));

    /// "Consolas" mirrors TimelineCanvasControl.Rendering.cs's own ruler font choice, kept as a
    /// named accessor rather than a bare literal so the two stay obviously in sync.
    private static string TimelineFontFamily() => "Consolas";

    private CanvasTextFormat RulerTextFormat => _rulerTextFormat ??= new CanvasTextFormat
    {
        FontSize = (float)AppThemeTokens.FontSize.Xs,
        FontFamily = RulerFontFamily,
        VerticalAlignment = CanvasVerticalAlignment.Top,
        HorizontalAlignment = CanvasHorizontalAlignment.Left,
        WordWrapping = CanvasWordWrapping.NoWrap,
    };

    private CanvasTextFormat LabelTextFormat => _labelTextFormat ??= new CanvasTextFormat
    {
        FontSize = (float)AppThemeTokens.FontSize.Xxs,
        VerticalAlignment = CanvasVerticalAlignment.Center,
        HorizontalAlignment = CanvasHorizontalAlignment.Left,
        WordWrapping = CanvasWordWrapping.NoWrap,
        TrimmingGranularity = CanvasTextTrimmingGranularity.Character,
        TrimmingSign = CanvasTrimmingSign.Ellipsis,
    };

    private void BuildRows()
    {
        RowsPanel.Children.Clear();
        _rows.Clear();
        if (_vm is not { } vm)
        {
            return;
        }
        foreach (var spec in KeyframesViewModel.Rows)
        {
            var row = new KeyframesLaneRowControl();
            row.Configure(vm, spec.Property, spec.Label);
            RowsPanel.Children.Add(row);
            _rows.Add(row);
        }
    }

    private void OnTimelinePropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(TimelineEditorViewModel.CurrentFrame))
        {
            DispatcherQueue.TryEnqueue(RedrawAll);
        }
    }

    /// Undo/redo, or an edit from elsewhere (Video tab's inline stamp buttons, timeline drag)
    /// touching the clip this tab is showing — re-render so stale diamonds/values don't linger.
    /// This tab's own commits also route through here (mirrors TransformTabView's identical note).
    private void OnExternalChange(object? sender, EventArgs e) => DispatcherQueue.TryEnqueue(RedrawAll);

    private void RedrawAll()
    {
        if (HeaderCanvas.ReadyToDraw)
        {
            HeaderCanvas.Invalidate();
        }
        foreach (var row in _rows)
        {
            row.Redraw();
        }
    }

    // MARK: - Header: ruler + clip strip (ports ClipRulerBlock)

    private void HeaderCanvas_Draw(CanvasControl sender, CanvasDrawEventArgs args)
    {
        var ds = args.DrawingSession;
        var width = (float)sender.ActualWidth;
        if (_vm is not { } vm || width <= 0)
        {
            return;
        }

        var rulerHeight = (float)AppThemeTokens.Inspector.RulerHeight;
        ds.FillRectangle(0, 0, width, rulerHeight, AppTheme.Background.Surface);
        ds.DrawLine(0, rulerHeight - 0.5f, width, rulerHeight - 0.5f, AppTheme.Border.Primary, 1);

        var fps = Math.Max(1, vm.Fps);
        var pxPerFrame = width / vm.ClipSpanFrames;
        if (pxPerFrame > 0 && !double.IsNaN(pxPerFrame) && !double.IsInfinity(pxPerFrame))
        {
            var framesPerMajor = TickInterval(pxPerFrame, fps);
            if (framesPerMajor > 0)
            {
                for (var frame = 0; frame <= vm.ClipSpanFrames; frame += framesPerMajor)
                {
                    var x = (float)(frame * pxPerFrame);
                    ds.DrawLine(x, rulerHeight - 8, x, rulerHeight, AppTheme.Text.Muted, 1);
                    var label = TimelineCanvasControl.FormatTimecode(vm.ClipStartFrame + frame, fps);
                    ds.DrawText(label, new Vector2(x + 3, 2), AppTheme.Text.Tertiary, RulerTextFormat);
                }
            }
        }

        var stripHeight = (float)AppThemeTokens.Inspector.StripHeight;
        var stripRect = new Rect(0, rulerHeight, width, stripHeight);
        var tint = KeyframesLaneRowControl.WithAlpha(KeyframesLaneRowControl.TrackTint(vm.SourceClipType), AppThemeTokens.Opacity.Medium);
        ds.FillRoundedRectangle(stripRect, (float)AppThemeTokens.Radius.Xs, (float)AppThemeTokens.Radius.Xs, tint);
        using (ds.CreateLayer(1f, stripRect))
        {
            ds.DrawText(vm.ClipLabel,
                new Vector2((float)(stripRect.X + AppThemeTokens.Spacing.Sm), (float)(stripRect.Y + stripRect.Height / 2)),
                KeyframesLaneRowControl.WithAlpha(Colors.White, AppThemeTokens.Opacity.Prominent),
                LabelTextFormat);
        }
    }

    private static int TickInterval(double pixelsPerFrame, int fps)
    {
        const double targetPixels = 60.0;
        var rawFrames = targetPixels / Math.Max(0.0001, pixelsPerFrame);
        int[] seconds = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1200, 1800, 3600];
        foreach (var s in seconds)
        {
            var candidate = s * fps;
            if (candidate >= rawFrames)
            {
                return candidate;
            }
        }
        return seconds[^1] * fps;
    }

    private void HeaderCanvas_PointerPressed(object sender, PointerRoutedEventArgs e)
    {
        _headerDragging = true;
        HeaderCanvas.CapturePointer(e.Pointer);
        SeekAtHeader(e);
        e.Handled = true;
    }

    private void HeaderCanvas_PointerMoved(object sender, PointerRoutedEventArgs e)
    {
        if (!_headerDragging)
        {
            return;
        }
        SeekAtHeader(e);
        e.Handled = true;
    }

    private void HeaderCanvas_PointerReleased(object sender, PointerRoutedEventArgs e)
    {
        _headerDragging = false;
        e.Handled = true;
    }

    private void HeaderCanvas_PointerCaptureLost(object sender, PointerRoutedEventArgs e) => _headerDragging = false;

    private void SeekAtHeader(PointerRoutedEventArgs e)
    {
        if (_vm is not { } vm)
        {
            return;
        }
        var x = e.GetCurrentPoint(HeaderCanvas).Position.X;
        var width = HeaderCanvas.ActualWidth;
        var t = width > 0 ? Math.Clamp(x / width, 0, 1) : 0;
        vm.Seek(vm.ClipStartFrame + SwiftMath.RoundToInt(t * vm.ClipSpanFrames));
    }
}
