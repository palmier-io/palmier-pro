using System.Numerics;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.Geometry;
using Microsoft.Graphics.Canvas.UI.Xaml;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using PalmierPro.App.Controls;
using PalmierPro.App.Theme;
using PalmierPro.App.ViewModels.Inspector;
using PalmierPro.Core.Models;
using PalmierPro.Core.Theme;
using Windows.Foundation;
using Windows.UI;

namespace PalmierPro.App.Views.Inspector.Tabs;

/// Interactive overlay half of the "Curves" section (color.curves) — see ColorCurveEditorView.xaml's
/// doc comment for the ScopesHistogramView layering split. Port of CurveEditorView.swift minus its
/// histogram fetch (owned by ScopesViewModel/ScopesHistogramView now): channel picker, curve line,
/// point add/drag/delete with the AppTheme.Curve.pointHitDiameter grab target.
public sealed partial class ColorCurveEditorView : UserControl
{
    /// Matches CurveEditorView.swift's `DragGesture(minimumDistance: 3)` — a bare click/release
    /// that never crosses this many pixels from the press position never grabs or creates a point.
    private const double DragThreshold = 3;

    private readonly ColorViewModel _vm;
    private ColorCurveChannel _channel = ColorCurveChannel.Master;
    private (List<CurvePoint> Points, int Index)? _liveDrag;
    private Point? _pressPosition;

    public ColorCurveEditorView(ColorViewModel vm)
    {
        InitializeComponent();
        Canvas.Background = new SolidColorBrush(Colors.Transparent);
        _vm = vm;
        RebuildChannelRow();
    }

    /// ColorTabView hands this the one ScopesViewModel shared with ScopesHueView — see
    /// ScopesViewModel's class doc for why a single shared instance is the contract.
    public void SetScopesViewModel(ScopesViewModel? vm) => Backdrop.SetViewModel(vm);

    /// Re-reads the model and redraws — call after an external change (undo/redo, a different
    /// control editing the same clip) that this view didn't itself cause.
    public void Refresh()
    {
        _liveDrag = null;
        Canvas.Invalidate();
    }

    // MARK: - Channel picker

    private void RebuildChannelRow()
    {
        ChannelRow.Children.Clear();
        foreach (var channel in new[] { ColorCurveChannel.Master, ColorCurveChannel.Red, ColorCurveChannel.Green, ColorCurveChannel.Blue })
        {
            ChannelRow.Children.Add(BuildChannelButton(channel));
        }
    }

    private FrameworkElement BuildChannelButton(ColorCurveChannel channel)
    {
        var isActive = channel == _channel;
        var text = new TextBlock
        {
            Text = ChannelLabel(channel),
            FontSize = AppThemeTokens.FontSize.Xs,
            FontWeight = AppTheme.FontWeightFor(isActive ? AppThemeTokens.FontWeight.Semibold : AppThemeTokens.FontWeight.Regular),
            Foreground = new SolidColorBrush(isActive ? ChannelColor(channel) : AppTheme.Text.Tertiary),
        };
        var button = new Border
        {
            Background = AppTheme.Background.ClearBrush,
            Padding = AppTheme.ThicknessOf(AppThemeTokens.Spacing.Sm, AppThemeTokens.Spacing.Xxs, AppThemeTokens.Spacing.Sm, AppThemeTokens.Spacing.Xxs),
            Child = text,
        };
        button.Tapped += (_, e) =>
        {
            _channel = channel;
            _liveDrag = null;
            RebuildChannelRow();
            Canvas.Invalidate();
            e.Handled = true;
        };
        return button;
    }

    private static string ChannelLabel(ColorCurveChannel channel) => channel switch
    {
        ColorCurveChannel.Master => "Y",
        ColorCurveChannel.Red => "R",
        ColorCurveChannel.Green => "G",
        ColorCurveChannel.Blue => "B",
        _ => "Y",
    };

    private static Color ChannelColor(ColorCurveChannel channel) => channel switch
    {
        ColorCurveChannel.Master => AppTheme.Text.Secondary,
        ColorCurveChannel.Red => AppTheme.Curve.RedColor,
        ColorCurveChannel.Green => AppTheme.Curve.GreenColor,
        ColorCurveChannel.Blue => AppTheme.Curve.BlueColor,
        _ => AppTheme.Text.Secondary,
    };

    // MARK: - Drawing

    private void Canvas_Draw(CanvasControl sender, CanvasDrawEventArgs args)
    {
        var ds = args.DrawingSession;
        var size = new Size(sender.ActualWidth, sender.ActualHeight);
        if (size.Width <= 0 || size.Height <= 0)
        {
            return;
        }

        var points = ActivePoints();
        var color = ChannelColor(_channel);

        using (var builder = new CanvasPathBuilder(ds))
        {
            var first = true;
            for (var i = 0; i <= 50; i++)
            {
                var t = i / 50.0;
                var p = PointOf(new CurvePoint(t, GradeCurve.Eval(points, t)), size);
                if (first)
                {
                    builder.BeginFigure(p);
                    first = false;
                }
                else
                {
                    builder.AddLine(p);
                }
            }
            builder.EndFigure(CanvasFigureLoop.Open);
            using var geometry = CanvasGeometry.CreatePath(builder);
            ds.DrawGeometry(geometry, color, (float)AppThemeTokens.BorderWidth.Medium);
        }

        var pointRadius = (float)(AppThemeTokens.Curve.PointDiameter / 2);
        foreach (var p in points)
        {
            ds.FillCircle(PointOf(p, size), pointRadius, color);
        }
    }

    // MARK: - Points

    private List<CurvePoint> ActivePoints() => _liveDrag?.Points ?? SortedPoints();

    private List<CurvePoint> SortedPoints()
    {
        var curve = _vm.ReadGradeCurve();
        var points = ChannelPoints(curve);
        var source = points.Count == 0 ? GradeCurve.IdentityPoints : points;
        return [.. source.OrderBy(p => p.X)];
    }

    private List<CurvePoint> ChannelPoints(GradeCurve curve) => _channel switch
    {
        ColorCurveChannel.Master => curve.Master,
        ColorCurveChannel.Red => curve.Red,
        ColorCurveChannel.Green => curve.Green,
        ColorCurveChannel.Blue => curve.Blue,
        _ => curve.Master,
    };

    private static Vector2 PointOf(CurvePoint p, Size size) =>
        new((float)(p.X * size.Width), (float)((1 - p.Y) * size.Height));

    private static CurvePoint ValueOf(Point pos, Size size) =>
        new(ScrubMath.Clamp(pos.X / size.Width, 0, 1), ScrubMath.Clamp(1 - pos.Y / size.Height, 0, 1));

    // MARK: - Pointer input

    private void Canvas_PointerPressed(object sender, PointerRoutedEventArgs e)
    {
        var size = new Size(Canvas.ActualWidth, Canvas.ActualHeight);
        if (size.Width <= 0 || size.Height <= 0)
        {
            return;
        }
        Canvas.CapturePointer(e.Pointer);
        // Gesture doesn't actually start here — see Canvas_PointerMoved. A bare click/release with
        // no intervening move must stay inert (no point grabbed or created).
        _pressPosition = e.GetCurrentPoint(Canvas).Position;
        _liveDrag = null;
    }

    private void Canvas_PointerMoved(object sender, PointerRoutedEventArgs e)
    {
        if (_pressPosition is not { } press || !e.GetCurrentPoint(Canvas).Properties.IsLeftButtonPressed)
        {
            return;
        }
        var size = new Size(Canvas.ActualWidth, Canvas.ActualHeight);
        if (size.Width <= 0 || size.Height <= 0)
        {
            return;
        }
        var pos = e.GetCurrentPoint(Canvas).Position;
        if (_liveDrag is not { } drag)
        {
            var dx = pos.X - press.X;
            var dy = pos.Y - press.Y;
            if (dx * dx + dy * dy < DragThreshold * DragThreshold)
            {
                return;
            }
            // Threshold just crossed — the gesture starts now, grabbing at the original press
            // position (mirrors DragGesture's `v.startLocation`), then moves to the live position.
            drag = Grab(press, size);
        }
        _liveDrag = (Moved(drag.Points, drag.Index, pos, size), drag.Index);
        Apply(commit: false);
    }

    private void Canvas_PointerReleased(object sender, PointerRoutedEventArgs e)
    {
        Canvas.ReleasePointerCapture(e.Pointer);
        Settle();
    }

    private void Canvas_PointerCaptureLost(object sender, PointerRoutedEventArgs e) => Settle();

    private void Settle()
    {
        _pressPosition = null;
        if (_liveDrag is null)
        {
            return;
        }
        Apply(commit: true);
        _liveDrag = null;
        Canvas.Invalidate();
    }

    private void Apply(bool commit)
    {
        if (_liveDrag is not { } drag)
        {
            return;
        }
        Emit(drag.Points, commit);
        Canvas.Invalidate();
    }

    private void Canvas_DoubleTapped(object sender, DoubleTappedRoutedEventArgs e)
    {
        var size = new Size(Canvas.ActualWidth, Canvas.ActualHeight);
        if (size.Width <= 0 || size.Height <= 0)
        {
            return;
        }
        var pos = e.GetPosition(Canvas);
        var pts = SortedPoints();
        if (NearestIndex(pos, pts, size) is not { } i || pts.Count <= 2 || i == 0 || i == pts.Count - 1)
        {
            return;
        }
        var outPoints = new List<CurvePoint>(pts);
        outPoints.RemoveAt(i);
        Emit(outPoints, commit: true);
        Canvas.Invalidate();
    }

    private void Emit(List<CurvePoint> points, bool commit)
    {
        var value = points.SequenceEqual(GradeCurve.IdentityPoints) ? [] : points;
        if (commit)
        {
            _vm.CommitCurveChannel(_channel, value);
        }
        else
        {
            _vm.ApplyCurveChannel(_channel, value);
        }
    }

    /// Grab the nearest existing point at press, or drop a new one at the click position — one
    /// gesture: grab-then-drag, mirroring CurveEditorView.swift's `curveDrag`.
    private (List<CurvePoint> Points, int Index) Grab(Point pos, Size size)
    {
        var pts = SortedPoints();
        if (NearestIndex(pos, pts, size) is { } i)
        {
            return (pts, i);
        }
        var newPoint = ValueOf(pos, size);
        pts.Add(newPoint);
        pts = [.. pts.OrderBy(p => p.X)];
        var index = pts.FindIndex(p => p.X == newPoint.X && p.Y == newPoint.Y);
        return (pts, index < 0 ? 0 : index);
    }

    private static int? NearestIndex(Point pos, List<CurvePoint> points, Size size)
    {
        int? best = null;
        var bestDist = double.MaxValue;
        for (var i = 0; i < points.Count; i++)
        {
            var sp = PointOf(points[i], size);
            var dist = Math.Sqrt(Math.Pow(sp.X - pos.X, 2) + Math.Pow(sp.Y - pos.Y, 2));
            if (dist <= AppThemeTokens.Curve.PointHitDiameter / 2 && dist < bestDist)
            {
                best = i;
                bestDist = dist;
            }
        }
        return best;
    }

    /// Moves `index` to `pos`'s value. Endpoints (index 0/last) never move on X; interior points are
    /// clamped between their neighbors so the point order — and therefore curve monotonicity in X —
    /// never inverts. Always replaces the list slot with a new CurvePoint rather than mutating one in
    /// place: an untouched channel's points may alias GradeCurve.IdentityPoints's shared singletons.
    private static List<CurvePoint> Moved(List<CurvePoint> points, int index, Point pos, Size size)
    {
        var pts = new List<CurvePoint>(points);
        var v = ValueOf(pos, size);
        var x = pts[index].X;
        if (index != 0 && index != pts.Count - 1)
        {
            x = Math.Min(pts[index + 1].X - 0.001, Math.Max(pts[index - 1].X + 0.001, v.X));
        }
        pts[index] = new CurvePoint(x, v.Y);
        return pts;
    }
}
