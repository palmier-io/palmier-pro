using System.Runtime.CompilerServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using PalmierPro.App.Theme;
using PalmierPro.App.ViewModels.Editor;
using PalmierPro.App.ViewModels.Inspector;
using PalmierPro.Core.Theme;

namespace PalmierPro.App.Views.Inspector.Tabs;

/// Content view for <see cref="InspectorTab.Color"/> — registered into InspectorTabRegistry via
/// <see cref="RegisterTab"/> below, per that registry's documented module-initializer pattern. See
/// ColorTabView.xaml's doc comment for why color grading gets its own Windows tab. Three sections —
/// Color Wheels, Curves, Hue Curves — each collapsible; all default expanded (unlike the Mac's
/// AdjustTab, which defaults every one of these collapsed since they compete for space with Basic
/// Correction/LUTs/Effects in one shared tab — this tab has nothing else in it). InspectorView
/// builds a fresh instance per tab/selection change; <see cref="Unloaded"/> detaches the
/// TimelineEditorViewModel subscription so it doesn't outlive this control.
public sealed partial class ColorTabView : UserControl
{
    private readonly ColorViewModel _vm;
    private readonly TimelineEditorViewModel _timeline;
    private readonly ScopesViewModel? _scopesVm;

    private readonly ColorWheelControl _lift = new() { Title = "Lift" };
    private readonly ColorWheelControl _gamma = new() { Title = "Gamma" };
    private readonly ColorWheelControl _gain = new() { Title = "Gain" };
    private readonly ColorCurveEditorView _curveEditor;
    private readonly ColorHueCurveEditorView _hueCurveEditor;

    private Button? _wheelsReset;
    private Button? _curvesReset;
    private Button? _hueReset;

    public ColorTabView(InspectorTabContext context)
    {
        InitializeComponent();
        // {StaticResource} values feeding Thickness-typed properties don't coerce in WinUI XAML
        // the way literal strings do (see AGENTS.md) — set here instead.
        Root.Padding = AppTheme.UniformThickness(AppThemeTokens.Spacing.Lg);
        Root.Spacing = AppThemeTokens.Spacing.Lg;

        _timeline = context.Timeline;
        _vm = new ColorViewModel(context);
        // No engine under `dotnet test` (TimelineEditorViewModel.Engine is nullable) — scopes are a
        // visual aid on top of the editable curves, not a hard dependency of them.
        _scopesVm = _timeline.Engine is { } engine
            ? new ScopesViewModel(engine, _timeline, action => DispatcherQueue.TryEnqueue(() => action()))
            : null;

        _curveEditor = new ColorCurveEditorView(_vm);
        _curveEditor.SetScopesViewModel(_scopesVm);
        _hueCurveEditor = new ColorHueCurveEditorView(_vm);
        _hueCurveEditor.SetScopesViewModel(_scopesVm);

        WireWheel(_lift, "lift");
        WireWheel(_gamma, "gamma");
        WireWheel(_gain, "gain");
        ConfigureWheelRange(_lift, "lift");
        ConfigureWheelRange(_gamma, "gamma");
        ConfigureWheelRange(_gain, "gain");

        BuildLayout();
        RefreshAll();

        _timeline.StructuralChangeRequested += OnStructuralChangeRequested;
        Unloaded += (_, _) => _timeline.StructuralChangeRequested -= OnStructuralChangeRequested;
    }

    [ModuleInitializer]
    internal static void RegisterTab() =>
        InspectorTabRegistry.Register(InspectorTab.Color, context => new ColorTabView(context));

    /// Undo/redo, or a different control editing the same clip(s), can change the color effects
    /// without this view having caused it — mirrors EffectsViewModel's own StructuralChangeRequested
    /// hookup. May run off the UI thread's own call path indirectly (NotifyTimelineChanged is
    /// synchronous on the caller's thread in practice, but DispatcherQueue keeps this safe either way).
    private void OnStructuralChangeRequested(object? sender, EventArgs e) => DispatcherQueue.TryEnqueue(RefreshAll);

    private void WireWheel(ColorWheelControl wheel, string prefix)
    {
        wheel.ColorChanged += (_, v) => _vm.ApplyWheelColor(prefix, v.X, v.Y);
        wheel.ColorCommitted += (_, v) =>
        {
            _vm.CommitWheelColor(prefix, v.X, v.Y);
            RefreshAll();
        };
        wheel.MasterChanged += (_, m) => _vm.ApplyWheelMaster(prefix, m);
        wheel.MasterCommitted += (_, m) =>
        {
            _vm.CommitWheelMaster(prefix, m);
            RefreshAll();
        };
    }

    /// Master-slider range/default/gradient come from the registry and never change — set once,
    /// unlike the X/Y/Master values themselves (see <see cref="RefreshAll"/>).
    private void ConfigureWheelRange(ColorWheelControl wheel, string prefix)
    {
        var reading = _vm.ReadWheel(prefix);
        wheel.MasterMinimum = reading.MasterMin;
        wheel.MasterMaximum = reading.MasterMax;
        wheel.MasterDefault = reading.MasterDefault;
        wheel.MasterGradient = AppTheme.Slider.LumaGradientBrush;
    }

    private void RefreshAll()
    {
        ApplyReading(_lift, _vm.ReadWheel("lift"));
        ApplyReading(_gamma, _vm.ReadWheel("gamma"));
        ApplyReading(_gain, _vm.ReadWheel("gain"));

        _curveEditor.Refresh();
        _hueCurveEditor.Refresh();

        if (_wheelsReset is { } wheelsReset)
        {
            wheelsReset.IsEnabled = _vm.HasWheelAdjustment;
        }
        if (_curvesReset is { } curvesReset)
        {
            curvesReset.IsEnabled = _vm.HasCurveAdjustment;
        }
        if (_hueReset is { } hueReset)
        {
            hueReset.IsEnabled = _vm.HasHueCurveAdjustment;
        }
    }

    private static void ApplyReading(ColorWheelControl wheel, ColorViewModel.WheelReading reading) =>
        wheel.SetValues(reading.X, reading.Y, reading.Master);

    // MARK: - Layout / section chrome

    private void BuildLayout()
    {
        Root.Children.Clear();

        var wheelsRow = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = AppThemeTokens.Spacing.LgXl,
            HorizontalAlignment = HorizontalAlignment.Center,
        };
        wheelsRow.Children.Add(_lift);
        wheelsRow.Children.Add(_gamma);
        wheelsRow.Children.Add(_gain);

        var wheels = BuildSection("Color Wheels", wheelsRow, () =>
        {
            _vm.ResetWheels();
            RefreshAll();
        });
        _wheelsReset = wheels.Reset;
        Root.Children.Add(wheels.Root);

        var curves = BuildSection("Curves", _curveEditor, () =>
        {
            _vm.ResetCurves();
            RefreshAll();
        });
        _curvesReset = curves.Reset;
        Root.Children.Add(curves.Root);

        var hueCurves = BuildSection("Hue Curves", _hueCurveEditor, () =>
        {
            _vm.ResetHueCurves();
            RefreshAll();
        });
        _hueReset = hueCurves.Reset;
        Root.Children.Add(hueCurves.Root);
    }

    /// One collapsible section: chevron + title header (tap to expand/collapse) with a Reset button
    /// on the right, and `content` below while expanded. Mirrors AdjustTab.swift's `adjustSection`
    /// chrome, minus the enable/disable checkbox — this tab edits exactly one effect type's params
    /// per section, and a whole-section on/off toggle isn't part of this control's scope.
    ///
    /// Collapse removes `content` from the tree (rather than toggling Visibility.Collapsed) so
    /// Loaded/Unloaded actually fire on its descendants — for the Curves/Hue Curves sections that's
    /// what drives ScopesViewModel.Activate/Deactivate (see ScopesHistogramView/ScopesHueView), and
    /// Visibility alone does not satisfy that gating (docs/color-scopes-v1.md §4's "a
    /// Visibility-toggled-but-still-loaded XAML tree does not satisfy" warning) — a collapsed section
    /// would otherwise keep the shared scopes backdrop active and issuing GPU histogram work for
    /// content nobody can see. Mirrors the Mac's AdjustTab.swift `if expanded { content() }`, which
    /// never instantiates CurveEditorView/HueCurveEditorView while collapsed either.
    private static (FrameworkElement Root, Button Reset) BuildSection(string title, FrameworkElement content, Action onReset)
    {
        var chevron = new TextBlock
        {
            Text = "▾",
            FontSize = AppThemeTokens.FontSize.Xxs,
            Foreground = AppTheme.Text.MutedBrush,
            VerticalAlignment = VerticalAlignment.Center,
            Width = AppThemeTokens.IconSize.Xxs,
            TextAlignment = TextAlignment.Center,
        };
        var titleText = new TextBlock
        {
            Text = title.ToUpperInvariant(),
            FontSize = AppThemeTokens.FontSize.Xxs,
            FontWeight = AppTheme.FontWeightFor(AppThemeTokens.FontWeight.Semibold),
            Foreground = AppTheme.Text.MutedBrush,
            VerticalAlignment = VerticalAlignment.Center,
        };
        var resetButton = new Button
        {
            Content = "Reset",
            FontSize = AppThemeTokens.FontSize.Xxs,
            Padding = AppTheme.ThicknessOf(AppThemeTokens.Spacing.Sm, AppThemeTokens.Spacing.Xxs, AppThemeTokens.Spacing.Sm, AppThemeTokens.Spacing.Xxs),
            Background = AppTheme.Background.ClearBrush,
        };
        resetButton.Click += (_, _) => onReset();

        var headerRow = new Grid { ColumnSpacing = AppThemeTokens.Spacing.Sm };
        headerRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        headerRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        headerRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Grid.SetColumn(chevron, 0);
        headerRow.Children.Add(chevron);
        Grid.SetColumn(titleText, 1);
        headerRow.Children.Add(titleText);
        Grid.SetColumn(resetButton, 2);
        headerRow.Children.Add(resetButton);

        var header = new Border
        {
            Background = AppTheme.Background.ClearBrush,
            Padding = AppTheme.ThicknessOf(0, AppThemeTokens.Spacing.Xs, 0, AppThemeTokens.Spacing.Xs),
            Child = headerRow,
        };
        var section = new StackPanel { Spacing = AppThemeTokens.Spacing.Sm };
        var expanded = true; // sections default expanded (see class doc)
        header.Tapped += (_, e) =>
        {
            expanded = !expanded;
            if (expanded)
            {
                if (!section.Children.Contains(content))
                {
                    section.Children.Add(content);
                }
            }
            else
            {
                section.Children.Remove(content);
            }
            chevron.Text = expanded ? "▾" : "▸";
            e.Handled = true;
        };

        section.Children.Add(header);
        section.Children.Add(content);
        return (section, resetButton);
    }
}
