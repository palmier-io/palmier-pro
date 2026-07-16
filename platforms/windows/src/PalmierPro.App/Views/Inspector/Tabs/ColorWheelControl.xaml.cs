using System.Numerics;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.UI;
using Microsoft.Graphics.Canvas.UI.Xaml;
using Microsoft.UI;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using PalmierPro.App.Controls;
using PalmierPro.App.Theme;
using PalmierPro.Core.Theme;
using Windows.Foundation;
using Windows.Graphics.DirectX;
using Windows.UI;

namespace PalmierPro.App.Views.Inspector.Tabs;

/// One Lift/Gamma/Gain wheel — see ColorWheelControl.xaml's doc comment. Position is value-space
/// (X, Y) in the unit disk, Y pointing up, mirroring ColorWheelPad.swift exactly.
public sealed partial class ColorWheelControl : UserControl
{
    /// Neutral gray center fading to saturated hue at the rim, matching ColorWheelPad.swift's
    /// private `wheelImage` — built once per instance (not shared/static: a Win2D CanvasBitmap is
    /// bound to the CanvasControl's own device, and re-created automatically whenever
    /// CreateResources re-fires, e.g. after a device-lost recovery).
    private CanvasBitmap? _face;

    /// Matches ColorWheelPad.swift's `DragGesture(minimumDistance: 2)` — a bare click/release that
    /// never crosses this many pixels from the press position never moves the puck.
    private const double DragThreshold = 2;

    private double _x;
    private double _y;
    private Point? _pressPosition;
    private bool _dragStarted;

    public ColorWheelControl()
    {
        InitializeComponent();
        MasterSlider.ValueChanged += (_, v) => MasterChanged?.Invoke(this, v);
        MasterSlider.ValueCommitted += (_, v) => MasterCommitted?.Invoke(this, v);
    }

    public string Title
    {
        get => TitleText.Text;
        set => TitleText.Text = value;
    }

    public double X
    {
        get => _x;
        set { _x = value; Pad.Invalidate(); }
    }

    public double Y
    {
        get => _y;
        set { _y = value; Pad.Invalidate(); }
    }

    public double Master
    {
        get => MasterSlider.Value;
        set => MasterSlider.Value = value;
    }

    public double MasterMinimum
    {
        get => MasterSlider.Minimum;
        set => MasterSlider.Minimum = value;
    }

    public double MasterMaximum
    {
        get => MasterSlider.Maximum;
        set => MasterSlider.Maximum = value;
    }

    public double MasterDefault
    {
        get => MasterSlider.DefaultValue;
        set => MasterSlider.DefaultValue = value;
    }

    public LinearGradientBrush? MasterGradient
    {
        get => MasterSlider.Gradient;
        set => MasterSlider.Gradient = value;
    }

    /// Sets X/Y/Master together without three separate Invalidate/Layout passes — call from a
    /// refresh driven by an external change (undo/redo, a different control editing the same clip).
    public void SetValues(double x, double y, double master)
    {
        _x = x;
        _y = y;
        MasterSlider.Value = master;
        Pad.Invalidate();
    }

    public event EventHandler<(double X, double Y)>? ColorChanged;
    public event EventHandler<(double X, double Y)>? ColorCommitted;
    public event EventHandler<double>? MasterChanged;
    public event EventHandler<double>? MasterCommitted;

    private void Pad_CreateResources(CanvasControl sender, CanvasCreateResourcesEventArgs args) =>
        _face = BuildFaceBitmap(sender);

    private void Pad_Draw(CanvasControl sender, CanvasDrawEventArgs args)
    {
        var ds = args.DrawingSession;
        var size = (float)AppThemeTokens.Wheels.PadSize;
        var radius = size / 2f;
        var center = new Vector2(radius, radius);

        if (_face is { } face)
        {
            ds.DrawImage(face, new Rect(0, 0, size, size));
        }

        ds.DrawLine(0, radius, size, radius, AppTheme.Wheels.CrosshairColor, (float)AppThemeTokens.BorderWidth.Hairline);
        ds.DrawLine(radius, 0, radius, size, AppTheme.Wheels.CrosshairColor, (float)AppThemeTokens.BorderWidth.Hairline);
        ds.DrawCircle(center, radius - (float)AppThemeTokens.Wheels.RingWidth / 2f, AppTheme.Border.Subtle, (float)AppThemeTokens.Wheels.RingWidth);

        var puck = new Vector2(center.X + (float)_x * radius, center.Y - (float)_y * radius);
        var puckRadius = (float)AppThemeTokens.Wheels.PuckSize / 2f;
        ds.FillCircle(puck, puckRadius, Colors.White);
        ds.DrawCircle(puck, puckRadius, AppTheme.Background.Base, (float)AppThemeTokens.BorderWidth.Thin);
    }

    private void Pad_PointerPressed(object sender, PointerRoutedEventArgs e)
    {
        Pad.CapturePointer(e.Pointer);
        // Gesture doesn't actually start here — see Pad_PointerMoved. A bare click/release with no
        // intervening move must leave the puck untouched (mirrors DragGesture(minimumDistance: 2)).
        _pressPosition = e.GetCurrentPoint(Pad).Position;
        _dragStarted = false;
    }

    private void Pad_PointerMoved(object sender, PointerRoutedEventArgs e)
    {
        if (_pressPosition is not { } press || !e.GetCurrentPoint(Pad).Properties.IsLeftButtonPressed)
        {
            return;
        }
        if (!_dragStarted)
        {
            var pos = e.GetCurrentPoint(Pad).Position;
            var dx = pos.X - press.X;
            var dy = pos.Y - press.Y;
            if (dx * dx + dy * dy < DragThreshold * DragThreshold)
            {
                return;
            }
            _dragStarted = true;
        }
        UpdateFromPointer(e, commit: false);
    }

    private void Pad_PointerReleased(object sender, PointerRoutedEventArgs e)
    {
        Pad.ReleasePointerCapture(e.Pointer);
        Settle(e);
    }

    // A capture can be lost mid-drag without a matching PointerReleased — settle at the last known
    // position instead of leaving the gesture stuck (see ParamSlider/PreviewView.xaml.cs). A normal
    // release raises PointerReleased AND a subsequent PointerCaptureLost — clearing _dragStarted
    // before committing ensures only whichever fires first commits.
    private void Pad_PointerCaptureLost(object sender, PointerRoutedEventArgs e) => Settle(e);

    private void Settle(PointerRoutedEventArgs e)
    {
        var started = _dragStarted;
        _pressPosition = null;
        _dragStarted = false;
        if (started)
        {
            UpdateFromPointer(e, commit: true);
        }
    }

    private void Pad_DoubleTapped(object sender, DoubleTappedRoutedEventArgs e)
    {
        _x = 0;
        _y = 0;
        Pad.Invalidate();
        ColorCommitted?.Invoke(this, (0, 0));
    }

    private void UpdateFromPointer(PointerRoutedEventArgs e, bool commit)
    {
        var size = (float)AppThemeTokens.Wheels.PadSize;
        var radius = size / 2f;
        var center = new Vector2(radius, radius);
        var pos = e.GetCurrentPoint(Pad).Position;

        var vx = (pos.X - center.X) / radius;
        var vy = (center.Y - pos.Y) / radius;
        var mag = Math.Sqrt(vx * vx + vy * vy);
        if (mag > 1)
        {
            vx /= mag;
            vy /= mag;
        }

        _x = vx;
        _y = vy;
        Pad.Invalidate();
        if (commit)
        {
            ColorCommitted?.Invoke(this, (vx, vy));
        }
        else
        {
            ColorChanged?.Invoke(this, (vx, vy));
        }
    }

    // MARK: - Face bitmap (port of ColorWheels.swift's hueRGB/displayColor — decorative-widget math
    // only; the compositor's actual grade coefficients live in native Wheels.hlsl)

    private static CanvasBitmap BuildFaceBitmap(ICanvasResourceCreator creator)
    {
        const int d = 128;
        const double c = d / 2.0;
        var px = new byte[d * d * 4];

        byte Byte(double v) => (byte)Math.Clamp(v * 255.0, 0, 255);

        for (var j = 0; j < d; j++)
        {
            for (var i = 0; i < d; i++)
            {
                var vx = (i - c) / c;
                var vy = (c - j) / c;
                var r = Math.Sqrt(vx * vx + vy * vy);
                if (r > 1.02)
                {
                    continue;
                }
                var (cr, cg, cb) = DisplayColor(vx, vy);
                var a = r <= 1 ? 1.0 : Math.Max(0, 1 - (r - 1) / 0.02);
                var o = (j * d + i) * 4;
                // BGRA, premultiplied.
                px[o + 0] = Byte(cb * a);
                px[o + 1] = Byte(cg * a);
                px[o + 2] = Byte(cr * a);
                px[o + 3] = Byte(a);
            }
        }

        return CanvasBitmap.CreateFromBytes(
            creator, px, d, d, DirectXPixelFormat.B8G8R8A8UIntNormalized, 96, CanvasAlphaMode.Premultiplied);
    }

    /// Wheel-face color — a dark, lightly tinted body fading to a vivid saturated rim. Port of
    /// ColorWheels.swift's `displayColor`.
    private static (double R, double G, double B) DisplayColor(double x, double y)
    {
        var r = Math.Min(1, Math.Sqrt(x * x + y * y));
        var (hr, hg, hb) = HueRgb(Math.Atan2(y, x) / (2 * Math.PI));
        var v = 0.08 + 0.5 * Math.Pow(r, 1.7);
        var s = Math.Pow(r, 1.4);
        var rim = RimRamp((r - 0.86) / 0.14);

        double Face(double h)
        {
            var body = v * ((1 - s) + h * s);
            return body + (h - body) * rim;
        }

        return (Face(hr), Face(hg), Face(hb));
    }

    /// Fully-saturated hue at `h` in [0,1). Port of ColorWheels.swift's `hueRGB`.
    private static (double R, double G, double B) HueRgb(double h)
    {
        var x = (h - Math.Floor(h)) * 6;
        var f = x - Math.Floor(x);
        return ((int)Math.Floor(x) % 6) switch
        {
            0 => (1, f, 0),
            1 => (1 - f, 1, 0),
            2 => (0, 1, f),
            3 => (0, 1 - f, 1),
            4 => (f, 0, 1),
            _ => (1, 0, 1 - f),
        };
    }

    private static double RimRamp(double t)
    {
        var x = Math.Min(1, Math.Max(0, t));
        return x * x * (3 - 2 * x);
    }
}
