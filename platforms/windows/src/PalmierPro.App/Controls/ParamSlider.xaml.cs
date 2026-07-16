using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using PalmierPro.App.Theme;
using PalmierPro.Core.Theme;

namespace PalmierPro.App.Controls;

/// Port of AdjustSlider.swift: drag (or click-to-jump) the track to change Value, double-tap to
/// reset to DefaultValue. ValueChanged fires per pixel while dragging (no undo entry);
/// ValueCommitted fires exactly once per gesture end (one undo entry) — including the double-tap
/// reset, which is itself a single commit with no preceding ValueChanged.
public sealed partial class ParamSlider : UserControl
{
    private double _value;
    private LinearGradientBrush? _gradient;
    private bool _gestureActive;

    public ParamSlider()
    {
        InitializeComponent();

        var trackRadius = AppTheme.UniformCornerRadius(AppThemeTokens.Slider.TrackHeight / 2);
        TrackBackground.CornerRadius = trackRadius;
        TrackFill.CornerRadius = trackRadius;
        TrackGradient.CornerRadius = trackRadius;

        var trackTop = (AppThemeTokens.Slider.ThumbSize - AppThemeTokens.Slider.TrackHeight) / 2;
        Canvas.SetTop(TrackBackground, trackTop);
        Canvas.SetTop(TrackFill, trackTop);
        Canvas.SetTop(TrackGradient, trackTop);
        Canvas.SetTop(Thumb, 0);
    }

    public double Minimum { get; set; }
    public double Maximum { get; set; } = 1;
    public double DefaultValue { get; set; }

    public double Value
    {
        get => _value;
        set
        {
            _value = ScrubMath.Clamp(value, Minimum, Maximum);
            Layout();
        }
    }

    /// Null renders the plain (non-gradient) track; set (e.g. AppTheme.Slider.TempGradientBrush)
    /// to color the whole track instead — mirrors AdjustSlider.swift's `gradient: [Color]?`.
    public LinearGradientBrush? Gradient
    {
        get => _gradient;
        set
        {
            _gradient = value;
            TrackGradient.Background = value;
            TrackGradient.Visibility = value is null ? Visibility.Collapsed : Visibility.Visible;
            var plainVisibility = value is null ? Visibility.Visible : Visibility.Collapsed;
            TrackBackground.Visibility = plainVisibility;
            TrackFill.Visibility = plainVisibility;
        }
    }

    public event EventHandler<double>? ValueChanged;
    public event EventHandler<double>? ValueCommitted;

    private void Layout()
    {
        var width = TrackArea.ActualWidth;
        if (width <= 0)
        {
            return;
        }
        var thumbSize = AppThemeTokens.Slider.ThumbSize;
        var thumbX = ScrubMath.FractionOf(_value, Minimum, Maximum) * width;
        TrackBackground.Width = width;
        TrackGradient.Width = width;
        TrackFill.Width = Math.Clamp(thumbX, 0, width);
        Canvas.SetLeft(Thumb, Math.Clamp(thumbX - thumbSize / 2, 0, Math.Max(0, width - thumbSize)));
    }

    private void TrackArea_SizeChanged(object sender, SizeChangedEventArgs e) => Layout();

    private void TrackArea_PointerPressed(object sender, PointerRoutedEventArgs e)
    {
        TrackArea.CapturePointer(e.Pointer);
        _gestureActive = true;
        UpdateFromPointer(e, commit: false);
    }

    private void TrackArea_PointerMoved(object sender, PointerRoutedEventArgs e)
    {
        if (!e.GetCurrentPoint(TrackArea).Properties.IsLeftButtonPressed)
        {
            return;
        }
        UpdateFromPointer(e, commit: false);
    }

    private void TrackArea_PointerReleased(object sender, PointerRoutedEventArgs e)
    {
        if (!_gestureActive)
        {
            return;
        }
        _gestureActive = false;
        TrackArea.ReleasePointerCapture(e.Pointer);
        UpdateFromPointer(e, commit: true);
    }

    // A normal release raises PointerReleased AND a subsequent PointerCaptureLost (the explicit
    // ReleasePointerCapture above raises it too) — _gestureActive ensures only whichever fires
    // first commits. Also covers a capture lost mid-drag with no PointerReleased at all (e.g.
    // Alt+Tab): settle at the last known position rather than leave the gesture stuck (see
    // PreviewView.xaml.cs's _isScrubbing for the identical pattern).
    private void TrackArea_PointerCaptureLost(object sender, PointerRoutedEventArgs e)
    {
        if (!_gestureActive)
        {
            return;
        }
        _gestureActive = false;
        UpdateFromPointer(e, commit: true);
    }

    private void TrackArea_DoubleTapped(object sender, DoubleTappedRoutedEventArgs e)
    {
        Value = DefaultValue;
        ValueCommitted?.Invoke(this, Value);
    }

    private void UpdateFromPointer(PointerRoutedEventArgs e, bool commit)
    {
        var x = e.GetCurrentPoint(TrackArea).Position.X;
        Value = ScrubMath.ValueAtPosition(x, TrackArea.ActualWidth, Minimum, Maximum);
        if (commit)
        {
            ValueCommitted?.Invoke(this, Value);
        }
        else
        {
            ValueChanged?.Invoke(this, Value);
        }
    }
}
