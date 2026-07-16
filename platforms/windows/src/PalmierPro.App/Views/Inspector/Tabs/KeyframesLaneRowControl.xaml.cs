using System.Numerics;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.Geometry;
using Microsoft.Graphics.Canvas.UI.Xaml;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using PalmierPro.App.Editing;
using PalmierPro.App.Theme;
using PalmierPro.App.ViewModels.Inspector;
using PalmierPro.Core;
using PalmierPro.Core.Models;
using PalmierPro.Core.Theme;
using Windows.Foundation;
using Windows.UI;

namespace PalmierPro.App.Views.Inspector.Tabs;

/// One property's keyframe lane — code-behind half of KeyframesLaneRowControl.xaml (see that file's
/// remarks). Configured once per row by KeyframesTabView; <see cref="Redraw"/> is the tab view's
/// hook for re-rendering on playhead/data changes it observes centrally (this control keeps no
/// TimelineEditorViewModel subscriptions of its own).
public sealed partial class KeyframesLaneRowControl : UserControl
{
    private const double HitTolerancePixels = 7;
    private const double SnapThresholdPixels = 4;

    // Segoe Fluent Icons (same codepoints TransportBar.xaml/TransformTabView.xaml.cs already use).
    private const string GlyphChevronLeft = "";
    private const string GlyphChevronRight = "";

    private sealed class KfDrag
    {
        public required int OriginalFrame { get; init; }
        public required int CurrentFrame { get; set; }
    }

    private KeyframesViewModel? _vm;
    private AnimatableProperty _property;
    private KfDrag? _drag;
    private SnapEngine.SnapState _snapState;
    private double? _snapX;

    public KeyframesLaneRowControl()
    {
        InitializeComponent();
        LabelColumn.Width = AppTheme.PixelGridLength(AppThemeTokens.Slider.LabelColumn);
    }

    public void Configure(KeyframesViewModel vm, AnimatableProperty property, string label)
    {
        _vm = vm;
        _property = property;
        LabelText.Text = label;
        Redraw();
    }

    /// Rebuilds the stamp/nav cluster and repaints the lane — called by KeyframesTabView whenever
    /// the playhead moves or the clip's keyframe data changes.
    public void Redraw()
    {
        BuildControls();
        InvalidateCanvas();
    }

    private void InvalidateCanvas()
    {
        if (LaneCanvas.ReadyToDraw)
        {
            LaneCanvas.Invalidate();
        }
    }

    // MARK: - Stamp / nav controls (mirrors TransformTabView.xaml.cs's BuildKeyframeControls)

    private void BuildControls()
    {
        ControlsPanel.Children.Clear();
        if (_vm is not { } vm)
        {
            return;
        }
        var frame = vm.CurrentFrame;
        var inRange = vm.PlayheadInRange;
        var onKeyframe = vm.HasKeyframe(_property, frame);
        var prev = vm.PreviousKeyframeFrame(_property, frame);
        var next = vm.NextKeyframeFrame(_property, frame);

        ControlsPanel.Children.Add(BuildNavButton(GlyphChevronLeft, "Go to previous keyframe", prev));
        ControlsPanel.Children.Add(BuildStampButton(inRange, onKeyframe, frame));
        ControlsPanel.Children.Add(BuildNavButton(GlyphChevronRight, "Go to next keyframe", next));
    }

    private Button BuildNavButton(string glyph, string help, int? targetFrame)
    {
        var enabled = targetFrame is not null;
        var button = new Button
        {
            Content = new FontIcon { Glyph = glyph, FontSize = AppThemeTokens.FontSize.Xxs, Foreground = AppTheme.Text.TertiaryBrush },
            Width = AppThemeTokens.Inspector.NavButtonWidth + AppThemeTokens.Spacing.Md,
            Height = AppThemeTokens.Inspector.RowHeight,
            Background = AppTheme.Background.ClearBrush,
            BorderThickness = AppTheme.UniformThickness(0),
            Padding = AppTheme.UniformThickness(0),
            IsEnabled = enabled,
            Opacity = enabled ? 1 : AppThemeTokens.Opacity.Moderate,
        };
        ToolTipService.SetToolTip(button, help);
        if (enabled)
        {
            button.Click += (_, _) => _vm!.Seek(targetFrame!.Value);
        }
        return button;
    }

    private Button BuildStampButton(bool inRange, bool onKeyframe, int frame)
    {
        var diamond = new Rectangle
        {
            Width = AppThemeTokens.Inspector.DiamondSize,
            Height = AppThemeTokens.Inspector.DiamondSize,
            Fill = onKeyframe ? AppTheme.Accent.TimecodeBrush : AppTheme.Background.ClearBrush,
            Stroke = onKeyframe ? AppTheme.Accent.TimecodeBrush : AppTheme.Text.TertiaryBrush,
            StrokeThickness = AppThemeTokens.BorderWidth.Medium,
            RenderTransformOrigin = new Point(0.5, 0.5),
            RenderTransform = new RotateTransform { Angle = 45 },
        };
        var button = new Button
        {
            Content = diamond,
            Width = AppThemeTokens.Inspector.StampButtonWidth,
            Height = AppThemeTokens.Inspector.RowHeight,
            Background = AppTheme.Background.ClearBrush,
            BorderThickness = AppTheme.UniformThickness(0),
            Padding = AppTheme.UniformThickness(0),
            IsEnabled = inRange,
            Opacity = inRange ? 1 : AppThemeTokens.Opacity.Medium,
        };
        ToolTipService.SetToolTip(button, !inRange ? "Move playhead inside the clip" : onKeyframe ? "Remove keyframe at playhead" : "Add keyframe at playhead");
        button.Click += (_, _) =>
        {
            if (onKeyframe)
            {
                _vm!.Remove(_property, frame);
            }
            else
            {
                _vm!.StampAtPlayhead(_property);
            }
            Redraw();
        };
        return button;
    }

    // MARK: - Coordinates

    private static float XForFrame(KeyframesViewModel vm, int frame, float width)
    {
        var t = (double)(frame - vm.ClipStartFrame) / vm.ClipSpanFrames;
        return (float)(Math.Clamp(t, 0, 1) * width);
    }

    private static int FrameAtX(KeyframesViewModel vm, double x, double width)
    {
        if (width <= 0)
        {
            return vm.ClipStartFrame;
        }
        var t = Math.Clamp(x / width, 0, 1);
        return vm.ClipStartFrame + SwiftMath.RoundToInt(t * vm.ClipSpanFrames);
    }

    /// Substitutes the in-progress drag's live position for its original frame — mirrors
    /// KeyframesLaneRow.displayedFrames().
    private List<int> DisplayedFrames(KeyframesViewModel vm)
    {
        var frames = vm.KeyframeFrames(_property);
        if (_drag is not { } d)
        {
            return frames;
        }
        return frames.ConvertAll(f => f == d.OriginalFrame ? d.CurrentFrame : f);
    }

    private int? NearestKeyframe(KeyframesViewModel vm, double x, double width)
    {
        (int Frame, double Dx)? best = null;
        foreach (var f in vm.KeyframeFrames(_property))
        {
            var dx = Math.Abs(x - XForFrame(vm, f, (float)width));
            if (dx <= HitTolerancePixels && dx < (best?.Dx ?? double.MaxValue))
            {
                best = (f, dx);
            }
        }
        return best?.Frame;
    }

    // MARK: - Pointer input

    private void LaneCanvas_PointerPressed(object sender, PointerRoutedEventArgs e)
    {
        if (_vm is not { } vm)
        {
            return;
        }
        var pos = e.GetCurrentPoint(LaneCanvas).Position;
        var width = LaneCanvas.ActualWidth;
        if (NearestKeyframe(vm, pos.X, width) is { } hit)
        {
            _drag = new KfDrag { OriginalFrame = hit, CurrentFrame = hit };
            LaneCanvas.CapturePointer(e.Pointer);
        }
        else
        {
            vm.Seek(FrameAtX(vm, pos.X, width));
            Redraw();
        }
        e.Handled = true;
    }

    private void LaneCanvas_PointerMoved(object sender, PointerRoutedEventArgs e)
    {
        if (_vm is not { } vm || _drag is not { } d)
        {
            return;
        }
        var pos = e.GetCurrentPoint(LaneCanvas).Position;
        var width = LaneCanvas.ActualWidth;
        var pxPerFrame = Math.Max(0.0001, width / vm.ClipSpanFrames);
        var raw = FrameAtX(vm, pos.X, width);
        var snapped = ApplySnap(vm, raw, pxPerFrame, width);
        if (snapped != d.CurrentFrame)
        {
            vm.ApplyMove(_property, d.CurrentFrame, snapped);
            // A snap onto an already-occupied frame is a silent no-op (KeyframeTrack.Move's own
            // guard) — only advance the drag's tracked position once the move actually landed.
            if (!vm.KeyframeFrames(_property).Contains(d.CurrentFrame))
            {
                d.CurrentFrame = snapped;
            }
        }
        e.Handled = true;
        InvalidateCanvas();
    }

    private void LaneCanvas_PointerReleased(object sender, PointerRoutedEventArgs e)
    {
        EndDrag();
        e.Handled = true;
    }

    private void LaneCanvas_PointerCaptureLost(object sender, PointerRoutedEventArgs e) => EndDrag();

    private void EndDrag()
    {
        if (_vm is { } vm && _drag is { } d)
        {
            if (d.CurrentFrame != d.OriginalFrame)
            {
                vm.CommitMove();
            }
            else
            {
                vm.CancelMove();
            }
        }
        _drag = null;
        _snapState = new SnapEngine.SnapState();
        _snapX = null;
        Redraw();
    }

    private int ApplySnap(KeyframesViewModel vm, int raw, double pxPerFrame, double width)
    {
        var targets = vm.SnapTargets(_property);
        var snap = SnapEngine.FindSnap(raw, targets, ref _snapState, SnapThresholdPixels, pxPerFrame);
        var candidate = snap?.Frame ?? raw;

        var clamped = Math.Max(vm.ClipStartFrame, Math.Min(vm.ClipEndFrame, candidate));
        _snapX = clamped == candidate && candidate != raw ? XForFrame(vm, candidate, (float)width) : null;
        return clamped;
    }

    // MARK: - Context menu (right-click a diamond: interpolation + delete)

    private void LaneCanvas_RightTapped(object sender, RightTappedRoutedEventArgs e)
    {
        if (_vm is not { } vm)
        {
            return;
        }
        var pos = e.GetPosition(LaneCanvas);
        if (NearestKeyframe(vm, pos.X, LaneCanvas.ActualWidth) is not { } frame)
        {
            return;
        }

        var current = vm.InterpolationAt(_property, frame);
        var flyout = new MenuFlyout();
        AddInterpolationItem(flyout, "Linear", Interpolation.Linear, current, frame);
        AddInterpolationItem(flyout, "Smooth", Interpolation.Smooth, current, frame);
        AddInterpolationItem(flyout, "Hold", Interpolation.Hold, current, frame);
        flyout.Items.Add(new MenuFlyoutSeparator());
        var delete = new MenuFlyoutItem { Text = "Delete Keyframe" };
        delete.Click += (_, _) => { vm.Remove(_property, frame); Redraw(); };
        flyout.Items.Add(delete);

        flyout.ShowAt(LaneCanvas, pos);
        e.Handled = true;
    }

    private void AddInterpolationItem(MenuFlyout flyout, string text, Interpolation value, Interpolation current, int frame)
    {
        var item = new ToggleMenuFlyoutItem { Text = text, IsChecked = value == current };
        item.Click += (_, _) => { _vm!.SetInterpolation(_property, frame, value); Redraw(); };
        flyout.Items.Add(item);
    }

    // MARK: - Draw

    private void LaneCanvas_Draw(CanvasControl sender, CanvasDrawEventArgs args)
    {
        var ds = args.DrawingSession;
        var width = (float)sender.ActualWidth;
        var height = (float)sender.ActualHeight;
        if (_vm is not { } vm || width <= 0 || height <= 0)
        {
            return;
        }

        ds.FillRectangle(0, 0, width, height, WithAlpha(Colors.White, AppThemeTokens.Opacity.Subtle));

        if (_snapX is { } sx)
        {
            var dashed = new CanvasStrokeStyle { DashStyle = CanvasDashStyle.Dash };
            ds.DrawLine((float)sx, 0, (float)sx, height, AppTheme.AudioMeter.YellowSegment, 1, dashed);
        }

        var tint = TrackTint(vm.SourceClipType);
        var half = (float)(AppThemeTokens.Inspector.DiamondSize / 2);
        var midY = height / 2;
        foreach (var f in DisplayedFrames(vm))
        {
            var x = XForFrame(vm, f, width);
            var diamond = new[]
            {
                new Vector2(x, midY - half),
                new Vector2(x + half, midY),
                new Vector2(x, midY + half),
                new Vector2(x - half, midY),
            };
            FillPolygon(ds, diamond, tint);
            StrokePolygon(ds, diamond, WithAlpha(Colors.Black, 0.4));
        }

        if (vm.PlayheadInRange)
        {
            var px = XForFrame(vm, vm.CurrentFrame, width);
            ds.DrawLine(px, 0, px, height, AppTheme.Status.Error, (float)AppThemeTokens.BorderWidth.Thin);
        }
    }

    /// Shared with KeyframesTabView's header clip-strip fill.
    internal static Color TrackTint(ClipType type) => type switch
    {
        ClipType.Video => AppTheme.TrackColor.Video,
        ClipType.Image => AppTheme.TrackColor.Image,
        ClipType.Lottie => AppTheme.TrackColor.Lottie,
        ClipType.Sequence => AppTheme.TrackColor.Sequence,
        _ => AppTheme.TrackColor.Video,
    };

    private static void FillPolygon(CanvasDrawingSession ds, Vector2[] points, Color color)
    {
        using var geometry = PolygonGeometry(ds, points);
        ds.FillGeometry(geometry, color);
    }

    private static void StrokePolygon(CanvasDrawingSession ds, Vector2[] points, Color color)
    {
        using var geometry = PolygonGeometry(ds, points);
        ds.DrawGeometry(geometry, color, (float)AppThemeTokens.BorderWidth.Hairline);
    }

    private static CanvasGeometry PolygonGeometry(CanvasDrawingSession ds, Vector2[] points)
    {
        using var builder = new CanvasPathBuilder(ds);
        builder.BeginFigure(points[0]);
        for (var i = 1; i < points.Length; i++)
        {
            builder.AddLine(points[i]);
        }
        builder.EndFigure(CanvasFigureLoop.Closed);
        return CanvasGeometry.CreatePath(builder);
    }

    /// Shared with KeyframesTabView's header clip-strip fill and label.
    internal static Color WithAlpha(Color color, double alpha) =>
        Color.FromArgb((byte)Math.Round(Math.Clamp(alpha, 0, 1) * 255), color.R, color.G, color.B);
}
