using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using PalmierPro.App.Theme;
using PalmierPro.Core.Theme;

namespace PalmierPro.App.Controls;

/// Label + ParamSlider + ScrubbableNumberBox row — the shared building block behind every
/// adjustment row in AdjustTab.swift/AudioTab.swift/TextTab.swift on the Mac. Both inner controls'
/// ValueChanged/ValueCommitted are re-raised as one pair of row-level events, since the caller
/// never cares whether the edit came from the slider or the number box.
public sealed partial class LabeledParamRow : UserControl
{
    public LabeledParamRow()
    {
        InitializeComponent();
        LabelColumn.Width = AppTheme.PixelGridLength(AppThemeTokens.Slider.LabelColumn);

        Slider.ValueChanged += (_, v) => ValueChanged?.Invoke(this, v);
        Slider.ValueCommitted += (_, v) => ValueCommitted?.Invoke(this, v);
        NumberBox.ValueChanged += (_, v) => ValueChanged?.Invoke(this, v);
        NumberBox.ValueCommitted += (_, v) => ValueCommitted?.Invoke(this, v);
    }

    public string Label
    {
        get => LabelText.Text;
        set => LabelText.Text = value;
    }

    /// False for field-only rows (Volume, Fade In/Out) that skip the slider entirely on the Mac.
    public bool ShowSlider
    {
        get => Slider.Visibility == Visibility.Visible;
        set
        {
            Slider.Visibility = value ? Visibility.Visible : Visibility.Collapsed;
            SliderColumn.Width = value ? new GridLength(1, GridUnitType.Star) : AppTheme.PixelGridLength(0);
        }
    }

    public double Minimum
    {
        get => Slider.Minimum;
        set { Slider.Minimum = value; NumberBox.Minimum = value; }
    }

    public double Maximum
    {
        get => Slider.Maximum;
        set { Slider.Maximum = value; NumberBox.Maximum = value; }
    }

    public double DefaultValue
    {
        get => Slider.DefaultValue;
        set => Slider.DefaultValue = value;
    }

    /// Non-gradient rows leave this null (plain track); gradient rows (temp/tint/luma) set it,
    /// e.g. to AppTheme.Slider.TempGradientBrush.
    public LinearGradientBrush? Gradient
    {
        get => Slider.Gradient;
        set => Slider.Gradient = value;
    }

    public double DisplayMultiplier
    {
        get => NumberBox.DisplayMultiplier;
        set => NumberBox.DisplayMultiplier = value;
    }

    public string Format
    {
        get => NumberBox.Format;
        set => NumberBox.Format = value;
    }

    public string ValueSuffix
    {
        get => NumberBox.ValueSuffix;
        set => NumberBox.ValueSuffix = value;
    }

    public double DragSensitivity
    {
        get => NumberBox.DragSensitivity;
        set => NumberBox.DragSensitivity = value;
    }

    public Func<double, string?>? DisplayTextOverride
    {
        get => NumberBox.DisplayTextOverride;
        set => NumberBox.DisplayTextOverride = value;
    }

    /// Null = mixed selection. The slider (which has no concept of "mixed") falls back to
    /// DefaultValue, matching adjustmentRow's `sharedClipValue(clips) { ... } ?? spec.defaultValue`.
    public double? Value
    {
        get => NumberBox.Value;
        set
        {
            NumberBox.Value = value;
            Slider.Value = value ?? DefaultValue;
        }
    }

    public event EventHandler<double>? ValueChanged;
    public event EventHandler<double>? ValueCommitted;
}
