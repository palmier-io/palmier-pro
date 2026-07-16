using System.Numerics;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.Geometry;
using Microsoft.Graphics.Canvas.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using PalmierPro.App.Theme;
using PalmierPro.App.ViewModels.Inspector;
using PalmierPro.Core.Theme;
using Windows.UI;

namespace PalmierPro.App.Views.Inspector;

/// Win2D code-behind for ScopesHistogramView.xaml (Stage E, E6) — see that file's doc comment for
/// the layering split with the Adjust tab's interactive curve editor. Same SetViewModel(vm)
/// convention as AudioMeterView/TransportBar (not `{x:Bind}`); Loaded/Unloaded drive
/// ScopesViewModel.Activate/Deactivate, which is what satisfies "runs only while the Inspector
/// color panel is visible" (docs/color-scopes-v1.md §4) — InspectorView only constructs the active
/// tab's content (InspectorTabRegistry), so this control only exists in the tree while the Adjust
/// tab is selected.
public sealed partial class ScopesHistogramView : UserControl
{
    private ScopesViewModel? _viewModel;
    private bool _isLoaded;

    public ScopesHistogramView()
    {
        InitializeComponent();
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

        // Luma silhouette behind, then the RGB parade additively on top — mirrors
        // CurveEditorView.swift's Canvas draw (`.plusLighter` blend for R/G/B).
        if (_viewModel?.Result is { } result && result.YHistogram.Count > 1)
        {
            FillHistogram(ds, result.YHistogram, width, height, WithAlpha(AppTheme.Curve.LumaColor, AppThemeTokens.Opacity.Medium));
            ds.Blend = CanvasBlend.Add;
            FillHistogram(ds, result.RHistogram, width, height, WithAlpha(AppTheme.Curve.RedColor, AppThemeTokens.Opacity.Medium));
            FillHistogram(ds, result.GHistogram, width, height, WithAlpha(AppTheme.Curve.GreenColor, AppThemeTokens.Opacity.Medium));
            FillHistogram(ds, result.BHistogram, width, height, WithAlpha(AppTheme.Curve.BlueColor, AppThemeTokens.Opacity.Medium));
            ds.Blend = CanvasBlend.SourceOver;
        }

        DrawGridAndBorder(ds, width, height);
    }

    /// Quarter grid (black·shadow·mid·highlight·white stops) + border + diagonal identity
    /// reference — shared coordinate chrome for whatever curve line the Adjust tab overlays.
    private static void DrawGridAndBorder(CanvasDrawingSession ds, float width, float height)
    {
        var gridColor = WithAlpha(AppTheme.Border.Subtle, AppThemeTokens.Opacity.Medium);
        var hairline = (float)AppThemeTokens.BorderWidth.Hairline;
        for (var i = 0; i <= 4; i++)
        {
            var t = i / 4f;
            ds.DrawLine(t * width, 0, t * width, height, gridColor, hairline);
            ds.DrawLine(0, t * height, width, t * height, gridColor, hairline);
        }
        ds.DrawRectangle(0, 0, width, height, AppTheme.Border.Subtle, hairline);

        var dash = new CanvasStrokeStyle { CustomDashStyle = [3f, 3f] };
        ds.DrawLine(0, height, width, 0, AppTheme.Border.Subtle, hairline, dash);
    }

    private static void FillHistogram(CanvasDrawingSession ds, IReadOnlyList<float> bins, float width, float height, Color color)
    {
        if (bins.Count < 2)
        {
            return;
        }
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

    private static Color WithAlpha(Color color, double alpha) =>
        Color.FromArgb((byte)Math.Round(Math.Clamp(alpha, 0, 1) * 255), color.R, color.G, color.B);
}
