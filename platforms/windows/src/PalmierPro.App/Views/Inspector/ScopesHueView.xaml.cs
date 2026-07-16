using System.Numerics;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.Geometry;
using Microsoft.Graphics.Canvas.UI.Xaml;
using Microsoft.UI;
using Microsoft.UI.Xaml.Controls;
using PalmierPro.App.Theme;
using PalmierPro.App.ViewModels.Inspector;
using PalmierPro.Core.Theme;
using Windows.UI;

namespace PalmierPro.App.Views.Inspector;

/// Win2D code-behind for ScopesHueView.xaml (Stage E, E6) — see that file's doc comment for the
/// layering split with the Adjust tab's interactive hue-curve editor. Same SetViewModel(vm) /
/// Loaded-Unloaded-drives-Activate-Deactivate convention as ScopesHistogramView — see its doc
/// comment for why that alone satisfies "runs only while the Inspector color panel is visible."
public sealed partial class ScopesHueView : UserControl
{
    private ScopesViewModel? _viewModel;
    private bool _isLoaded;

    public ScopesHueView()
    {
        InitializeComponent();
        // {StaticResource} into a CornerRadius-typed property throws at runtime (AGENTS.md) — set
        // here instead, same as AssetTileControl.xaml.cs's ThumbArea.
        RootGrid.CornerRadius = AppTheme.UniformCornerRadius(AppThemeTokens.Radius.Sm);
        Loaded += (_, _) => { _isLoaded = true; _viewModel?.Activate(); };
        Unloaded += (_, _) => { _isLoaded = false; _viewModel?.Deactivate(); };
    }

    public void SetViewModel(ScopesViewModel? vm)
    {
        if (ReferenceEquals(_viewModel, vm))
        {
            return;
        }
        if (_viewModel is not null)
        {
            _viewModel.ResultChanged -= OnResultChanged;
            if (_isLoaded)
            {
                _viewModel.Deactivate();
            }
        }
        _viewModel = vm;
        if (_viewModel is not null)
        {
            _viewModel.ResultChanged += OnResultChanged;
            if (_isLoaded)
            {
                _viewModel.Activate();
            }
        }
        RequestRedraw();
    }

    private void OnResultChanged(object? sender, EventArgs e) => RequestRedraw();

    private void RequestRedraw()
    {
        if (Canvas.ReadyToDraw)
        {
            Canvas.Invalidate();
        }
    }

    private void Canvas_Draw(CanvasControl sender, CanvasDrawEventArgs args)
    {
        var ds = args.DrawingSession;
        var width = (float)sender.ActualWidth;
        var height = (float)sender.ActualHeight;
        if (width <= 0 || height <= 0)
        {
            return;
        }

        if (_viewModel?.Result is { } result && result.HueHistogram.Count > 1)
        {
            var bins = result.HueHistogram;
            FillHistogram(ds, bins, width, height, WithAlpha(Colors.White, AppThemeTokens.Opacity.Muted));
            StrokeHistogramLine(ds, bins, width, height, WithAlpha(Colors.White, AppThemeTokens.Opacity.Prominent), (float)AppThemeTokens.BorderWidth.Thin);
        }

        DrawGridAndBorder(ds, width, height);
    }

    /// Hue sixths (6 divisions) + dashed midline + border — shared coordinate chrome for whatever
    /// hue-curve line the Adjust tab overlays.
    private static void DrawGridAndBorder(CanvasDrawingSession ds, float width, float height)
    {
        var gridColor = WithAlpha(AppTheme.Border.Subtle, AppThemeTokens.Opacity.Medium);
        var hairline = (float)AppThemeTokens.BorderWidth.Hairline;
        for (var i = 0; i <= 6; i++)
        {
            var x = i / 6f * width;
            ds.DrawLine(x, 0, x, height, gridColor, hairline);
        }

        var dash = new CanvasStrokeStyle { CustomDashStyle = [3f, 3f] };
        ds.DrawLine(0, height / 2f, width, height / 2f, AppTheme.Border.Subtle, hairline, dash);
        ds.DrawRectangle(0, 0, width, height, AppTheme.Border.Subtle, hairline);
    }

    private static void FillHistogram(CanvasDrawingSession ds, IReadOnlyList<float> bins, float width, float height, Color color)
    {
        using var builder = new CanvasPathBuilder(ds);
        builder.BeginFigure(new Vector2(0, height));
        for (var i = 0; i < bins.Count; i++)
        {
            var x = (float)i / (bins.Count - 1) * width;
            builder.AddLine(new Vector2(x, height - bins[i] * height));
        }
        builder.AddLine(new Vector2(width, height));
        builder.EndFigure(CanvasFigureLoop.Closed);
        using var geometry = CanvasGeometry.CreatePath(builder);
        ds.FillGeometry(geometry, color);
    }

    /// The histogram's top contour only — stroked over the fill, matching
    /// HueCurveEditorView.swift's `histogramLine`.
    private static void StrokeHistogramLine(CanvasDrawingSession ds, IReadOnlyList<float> bins, float width, float height, Color color, float strokeWidth)
    {
        using var builder = new CanvasPathBuilder(ds);
        builder.BeginFigure(new Vector2(0, height - bins[0] * height));
        for (var i = 1; i < bins.Count; i++)
        {
            var x = (float)i / (bins.Count - 1) * width;
            builder.AddLine(new Vector2(x, height - bins[i] * height));
        }
        builder.EndFigure(CanvasFigureLoop.Open);
        using var geometry = CanvasGeometry.CreatePath(builder);
        ds.DrawGeometry(geometry, color, strokeWidth);
    }

    private static Color WithAlpha(Color color, double alpha) =>
        Color.FromArgb((byte)Math.Round(Math.Clamp(alpha, 0, 1) * 255), color.R, color.G, color.B);
}
