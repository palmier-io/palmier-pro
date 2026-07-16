using System.ComponentModel;
using System.Runtime.CompilerServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using PalmierPro.App.Controls;
using PalmierPro.App.Theme;
using PalmierPro.App.ViewModels.Editor;
using PalmierPro.App.ViewModels.Inspector;
using PalmierPro.Core.Models;
using PalmierPro.Core.Theme;

namespace PalmierPro.App.Views.Inspector.Tabs;

/// Video tab content (M5, Stage E) — see TransformTabView.xaml's remarks. Registers itself into
/// InspectorTabRegistry for InspectorTab.Video via the module-initializer seam that file documents;
/// nothing outside this pair of files needs to know this class exists.
public sealed partial class TransformTabView : UserControl
{
    // Segoe Fluent Icons glyphs (same font TransportBar.xaml/TimelineTabBarView.xaml already use).
    private const string GlyphChevronDown = "";
    private const string GlyphChevronRight = "";
    private const string GlyphChevronLeft = "";
    private const string GlyphRefresh = "";

    private readonly TransformViewModel _vm;
    private readonly TimelineEditorViewModel _timeline;
    private bool _transformExpanded = true;

    public TransformTabView(InspectorTabContext context)
    {
        InitializeComponent();
        _vm = new TransformViewModel(context);
        _timeline = context.Timeline;

        RootStack.Padding = AppTheme.UniformThickness(AppThemeTokens.Spacing.Lg);

        _timeline.PropertyChanged += OnTimelinePropertyChanged;
        _timeline.StructuralChangeRequested += OnExternalChange;
        _timeline.RefreshVisualsRequested += OnExternalChange;
        Unloaded += (_, _) =>
        {
            _timeline.PropertyChanged -= OnTimelinePropertyChanged;
            _timeline.StructuralChangeRequested -= OnExternalChange;
            _timeline.RefreshVisualsRequested -= OnExternalChange;
        };

        Render();
    }

    /// Registration seam — see InspectorTabRegistry's class doc. Runs once at process start, before
    /// any InspectorView exists to ask for a Video tab.
    [ModuleInitializer]
    internal static void RegisterTab() =>
        InspectorTabRegistry.Register(InspectorTab.Video, context => new TransformTabView(context));

    private void OnTimelinePropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(TimelineEditorViewModel.CurrentFrame))
        {
            DispatcherQueue.TryEnqueue(Render);
        }
    }

    /// Undo/redo, or an edit from elsewhere (Keyframes tab, timeline drag) touching a clip this tab
    /// is currently showing — re-render so stale values don't linger. This tab's own commits also
    /// route through here (NotifyTimelineChanged fires both events), but every call site below
    /// re-renders explicitly too rather than depending on that ordering.
    private void OnExternalChange(object? sender, EventArgs e) => DispatcherQueue.TryEnqueue(Render);

    private void Render()
    {
        RootStack.Children.Clear();
        RootStack.Children.Add(BuildTransformSection());
        var speedSection = BuildSpeedSection();
        if (speedSection is not null)
        {
            RootStack.Children.Add(speedSection);
        }
    }

    // MARK: - Transform section

    private FrameworkElement BuildTransformSection()
    {
        var stack = new StackPanel { Spacing = AppThemeTokens.Spacing.Md };
        stack.Children.Add(BuildTransformHeader());
        if (_transformExpanded)
        {
            var single = _vm.Single;
            stack.Children.Add(BuildAnimatableRow("Position", AnimatableProperty.Position, BuildPositionFields()));
            stack.Children.Add(BuildAnimatableRow("Scale", AnimatableProperty.Scale, BuildScaleField()));
            stack.Children.Add(BuildAnimatableRow("Rotation", AnimatableProperty.Rotation, BuildRotationField()));
            stack.Children.Add(BuildAnimatableRow("Opacity", AnimatableProperty.Opacity, BuildOpacityField()));
            stack.Children.Add(BuildCropRow(single));
            stack.Children.Add(BuildFlipRow());
            stack.Children.Add(BuildBlendRow());
        }
        return stack;
    }

    private FrameworkElement BuildTransformHeader()
    {
        var root = new Grid();
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var titleStack = new StackPanel { Orientation = Orientation.Horizontal, Spacing = AppThemeTokens.Spacing.Xs, VerticalAlignment = VerticalAlignment.Center };
        titleStack.Children.Add(SectionTitleLabel("Transform"));
        titleStack.Children.Add(new FontIcon
        {
            Glyph = _transformExpanded ? GlyphChevronDown : GlyphChevronRight,
            FontSize = AppThemeTokens.FontSize.Xxs,
            Foreground = AppTheme.Text.MutedBrush,
        });
        var toggle = new Button
        {
            Content = titleStack,
            Background = AppTheme.Background.ClearBrush,
            BorderThickness = AppTheme.UniformThickness(0),
            Padding = AppTheme.UniformThickness(0),
            HorizontalContentAlignment = HorizontalAlignment.Left,
        };
        toggle.Click += (_, _) => { _transformExpanded = !_transformExpanded; Render(); };
        Grid.SetColumn(toggle, 0);
        root.Children.Add(toggle);

        if (_transformExpanded)
        {
            var reset = new Button
            {
                Content = new FontIcon { Glyph = GlyphRefresh, FontSize = AppThemeTokens.FontSize.Sm, Foreground = AppTheme.Text.TertiaryBrush },
                Background = AppTheme.Background.ClearBrush,
                BorderThickness = AppTheme.UniformThickness(0),
                Padding = AppTheme.UniformThickness(AppThemeTokens.Spacing.Xs),
            };
            ToolTipService.SetToolTip(reset, "Reset transform");
            reset.Click += (_, _) => { _vm.ResetTransform(); Render(); };
            Grid.SetColumn(reset, 2);
            root.Children.Add(reset);
        }
        return root;
    }

    private static TextBlock SectionTitleLabel(string title) => new()
    {
        Text = title.ToUpperInvariant(),
        FontSize = AppThemeTokens.FontSize.Xxs,
        FontWeight = AppTheme.FontWeightFor(AppThemeTokens.FontWeight.Semibold),
        Foreground = AppTheme.Text.MutedBrush,
    };

    // MARK: - Row scaffolding

    private FrameworkElement BuildPropertyRow(string label, FrameworkElement trailing, double height = AppThemeTokens.Inspector.RowHeight)
    {
        var row = new Grid { Height = height };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        var labelText = new TextBlock
        {
            Text = label,
            FontSize = AppThemeTokens.FontSize.Sm,
            Foreground = AppTheme.Text.SecondaryBrush,
            VerticalAlignment = VerticalAlignment.Center,
        };
        Grid.SetColumn(labelText, 0);

        trailing.HorizontalAlignment = HorizontalAlignment.Right;
        trailing.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(trailing, 1);

        row.Children.Add(labelText);
        row.Children.Add(trailing);
        return row;
    }

    /// Property row with an optional keyframe stamp/nav control appended after the fields —
    /// mirrors `animatableRow`/`keyframeControls`. Only rendered when exactly one clip is selected,
    /// matching the Mac's `clipId: single?.id` gate.
    private FrameworkElement BuildAnimatableRow(string label, AnimatableProperty property, FrameworkElement fields)
    {
        var trailing = new StackPanel { Orientation = Orientation.Horizontal, Spacing = AppThemeTokens.Spacing.Sm };
        trailing.Children.Add(fields);
        if (_vm.Single is { } single)
        {
            trailing.Children.Add(BuildKeyframeControls(single.Id, property));
        }
        return BuildPropertyRow(label, trailing);
    }

    private FrameworkElement BuildKeyframeControls(string clipId, AnimatableProperty property)
    {
        var frame = _timeline.CurrentFrame;
        var inRange = _timeline.ClipFor(clipId)?.Contains(frame) ?? false;
        var onKeyframe = _vm.HasKeyframe(clipId, property, frame);
        var prev = _vm.PreviousKeyframeFrame(clipId, property, frame);
        var next = _vm.NextKeyframeFrame(clipId, property, frame);

        var stack = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 0 };
        stack.Children.Add(BuildKeyframeNavButton(GlyphChevronLeft, "Go to previous keyframe", prev, f => _timeline.SeekToFrame(f)));

        var diamond = BuildDiamond(onKeyframe);
        var stampButton = new Button
        {
            Content = diamond,
            Width = AppThemeTokens.Inspector.StampButtonWidth,
            Height = 18,
            Background = AppTheme.Background.ClearBrush,
            BorderThickness = AppTheme.UniformThickness(0),
            Padding = AppTheme.UniformThickness(0),
            IsEnabled = inRange,
            Opacity = inRange ? 1 : AppThemeTokens.Opacity.Medium,
        };
        ToolTipService.SetToolTip(stampButton, !inRange ? "Move playhead inside the clip" : onKeyframe ? "Remove keyframe at playhead" : "Add keyframe at playhead");
        stampButton.Click += (_, _) =>
        {
            if (onKeyframe)
            {
                _vm.RemoveKeyframe(clipId, property, frame);
            }
            else
            {
                _vm.StampKeyframe(clipId, property);
            }
            Render();
        };
        stack.Children.Add(stampButton);

        stack.Children.Add(BuildKeyframeNavButton(GlyphChevronRight, "Go to next keyframe", next, f => _timeline.SeekToFrame(f)));
        return stack;
    }

    private static FrameworkElement BuildDiamond(bool filled)
    {
        var rect = new Rectangle
        {
            Width = AppThemeTokens.Inspector.DiamondSize,
            Height = AppThemeTokens.Inspector.DiamondSize,
            Fill = filled ? AppTheme.Accent.TimecodeBrush : AppTheme.Background.ClearBrush,
            Stroke = filled ? AppTheme.Accent.TimecodeBrush : AppTheme.Text.TertiaryBrush,
            StrokeThickness = AppThemeTokens.BorderWidth.Medium,
            RenderTransformOrigin = new Windows.Foundation.Point(0.5, 0.5),
            RenderTransform = new RotateTransform { Angle = 45 },
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        };
        return rect;
    }

    private static Button BuildKeyframeNavButton(string glyph, string help, int? targetFrame, Action<int> seek)
    {
        var enabled = targetFrame is not null;
        var button = new Button
        {
            Content = new FontIcon { Glyph = glyph, FontSize = AppThemeTokens.FontSize.Xxs, Foreground = AppTheme.Text.TertiaryBrush },
            Width = AppThemeTokens.Inspector.NavButtonWidth + AppThemeTokens.Spacing.Md,
            Height = 18,
            Background = AppTheme.Background.ClearBrush,
            BorderThickness = AppTheme.UniformThickness(0),
            Padding = AppTheme.UniformThickness(0),
            IsEnabled = enabled,
            Opacity = enabled ? 1 : AppThemeTokens.Opacity.Moderate,
        };
        ToolTipService.SetToolTip(button, help);
        if (enabled)
        {
            button.Click += (_, _) => seek(targetFrame!.Value);
        }
        return button;
    }

    // MARK: - Position / Scale / Rotation / Opacity fields

    private FrameworkElement BuildPositionFields()
    {
        var canvasW = _timeline.Timeline.Width;
        var canvasH = _timeline.Timeline.Height;
        var stack = new StackPanel { Orientation = Orientation.Horizontal, Spacing = AppThemeTokens.Spacing.Xs };

        var x = new ScrubbableNumberBox { Minimum = -10, Maximum = 10, DisplayMultiplier = canvasW, Format = "%.0f", FieldWidth = 36, TrailingLabel = "X" };
        x.Value = _vm.PositionXShared;
        x.ValueChanged += (_, v) => _vm.ApplyPosition(v, null);
        x.ValueCommitted += (_, v) => { _vm.CommitPosition(v, null); Render(); };
        stack.Children.Add(x);

        var y = new ScrubbableNumberBox { Minimum = -10, Maximum = 10, DisplayMultiplier = canvasH, Format = "%.0f", FieldWidth = 36, TrailingLabel = "Y" };
        y.Value = _vm.PositionYShared;
        y.ValueChanged += (_, v) => _vm.ApplyPosition(null, v);
        y.ValueCommitted += (_, v) => { _vm.CommitPosition(null, v); Render(); };
        stack.Children.Add(y);

        return stack;
    }

    private FrameworkElement BuildScaleField()
    {
        var box = new ScrubbableNumberBox { Minimum = 0.01, Maximum = double.MaxValue, DisplayMultiplier = 100, Format = "%.0f", ValueSuffix = "%", FieldWidth = 50 };
        box.Value = _vm.ScaleShared;
        box.ValueChanged += (_, v) => _vm.ApplyScale(v);
        box.ValueCommitted += (_, v) => { _vm.CommitScale(v); Render(); };
        return box;
    }

    private FrameworkElement BuildRotationField()
    {
        var box = new ScrubbableNumberBox { Minimum = -3600, Maximum = 3600, DisplayMultiplier = 1, Format = "%.0f", ValueSuffix = "°", FieldWidth = 50 };
        box.Value = _vm.RotationShared;
        box.ValueChanged += (_, v) => _vm.ApplyRotation(v);
        box.ValueCommitted += (_, v) => { _vm.CommitRotation(v); Render(); };
        return box;
    }

    private FrameworkElement BuildOpacityField()
    {
        var box = new ScrubbableNumberBox { Minimum = 0, Maximum = 1, DisplayMultiplier = 100, Format = "%.0f", ValueSuffix = "%", FieldWidth = 50 };
        box.Value = _vm.OpacityShared;
        box.ValueChanged += (_, v) => _vm.ApplyOpacity(v);
        box.ValueCommitted += (_, v) => { _vm.CommitOpacity(v); Render(); };
        return box;
    }

    // MARK: - Crop

    private FrameworkElement BuildCropRow(Clip? single)
    {
        var trailing = new StackPanel { Orientation = Orientation.Horizontal, Spacing = AppThemeTokens.Spacing.Sm };

        var menuStack = new StackPanel { Orientation = Orientation.Horizontal, Spacing = AppThemeTokens.Spacing.Xs };
        menuStack.Children.Add(new TextBlock
        {
            Text = _vm.CropAspectLockState.Label(),
            FontSize = AppThemeTokens.FontSize.Sm,
            FontWeight = AppTheme.FontWeightFor(AppThemeTokens.FontWeight.Medium),
            Foreground = AppTheme.Text.SecondaryBrush,
        });
        menuStack.Children.Add(new FontIcon { Glyph = GlyphChevronDown, FontSize = AppThemeTokens.FontSize.Xxs, Foreground = AppTheme.Text.TertiaryBrush });
        var menuButton = new Button
        {
            Content = menuStack,
            Background = AppTheme.Background.ClearBrush,
            BorderThickness = AppTheme.UniformThickness(0),
            Padding = AppTheme.ThicknessOf(AppThemeTokens.Spacing.Sm, AppThemeTokens.Spacing.Xxs, AppThemeTokens.Spacing.Sm, AppThemeTokens.Spacing.Xxs),
            IsEnabled = single is not null,
            Opacity = single is not null ? 1 : AppThemeTokens.Opacity.Medium,
        };
        ToolTipService.SetToolTip(menuButton, "Choose a crop aspect");
        menuButton.Click += (_, _) =>
        {
            var flyout = new MenuFlyout();
            foreach (var preset in Enum.GetValues<CropAspectLock>())
            {
                var item = new MenuFlyoutItem { Text = preset == _vm.CropAspectLockState ? $"✓ {preset.Label()}" : preset.Label() };
                item.Click += (_, _) => { _vm.ApplyCropPreset(preset); Render(); };
                flyout.Items.Add(item);
            }
            flyout.ShowAt(menuButton);
        };
        trailing.Children.Add(menuButton);

        if (single is { } clip)
        {
            trailing.Children.Add(BuildKeyframeControls(clip.Id, AnimatableProperty.Crop));
        }

        var row = BuildPropertyRow("Crop", trailing);
        row.Opacity = single is not null ? 1 : AppThemeTokens.Opacity.Medium;
        return row;
    }

    // MARK: - Flip

    private FrameworkElement BuildFlipRow()
    {
        var stack = new StackPanel { Orientation = Orientation.Horizontal, Spacing = AppThemeTokens.Spacing.Xs };
        stack.Children.Add(BuildFlipToggle("H", _vm.FlipHorizontalActive, "Flip horizontally", () => { _vm.ToggleFlipHorizontal(); Render(); }));
        stack.Children.Add(BuildFlipToggle("V", _vm.FlipVerticalActive, "Flip vertically", () => { _vm.ToggleFlipVertical(); Render(); }));
        return BuildPropertyRow("Flip", stack);
    }

    private static Button BuildFlipToggle(string label, bool isOn, string help, Action toggle)
    {
        var button = new Button
        {
            Content = new TextBlock
            {
                Text = label,
                FontSize = AppThemeTokens.FontSize.Sm,
                FontWeight = AppTheme.FontWeightFor(AppThemeTokens.FontWeight.Medium),
                Foreground = isOn ? AppTheme.Accent.PrimaryBrush : AppTheme.Text.SecondaryBrush,
                HorizontalTextAlignment = TextAlignment.Center,
            },
            Width = AppThemeTokens.IconSize.Md,
            Height = AppThemeTokens.IconSize.Md,
            Background = isOn ? new SolidColorBrush(Windows.UI.Color.FromArgb((byte)(255 * AppThemeTokens.Opacity.Subtle), 255, 255, 255)) : AppTheme.Background.ClearBrush,
            BorderThickness = AppTheme.UniformThickness(0),
            Padding = AppTheme.UniformThickness(0),
            CornerRadius = AppTheme.UniformCornerRadius(AppThemeTokens.Radius.Xs),
        };
        ToolTipService.SetToolTip(button, help);
        button.Click += (_, _) => toggle();
        return button;
    }

    // MARK: - Blend

    private FrameworkElement BuildBlendRow()
    {
        var current = _vm.BlendCurrent;
        var mixed = _vm.BlendMixed;

        var menuStack = new StackPanel { Orientation = Orientation.Horizontal, Spacing = AppThemeTokens.Spacing.Xxs };
        menuStack.Children.Add(new TextBlock
        {
            Text = mixed ? "—" : current.DisplayName(),
            FontSize = AppThemeTokens.FontSize.Sm,
            FontWeight = AppTheme.FontWeightFor(AppThemeTokens.FontWeight.Medium),
            Foreground = AppTheme.Text.TertiaryBrush,
        });
        menuStack.Children.Add(new FontIcon { Glyph = GlyphChevronDown, FontSize = AppThemeTokens.FontSize.Xxs, Foreground = AppTheme.Text.TertiaryBrush });
        var menuButton = new Button
        {
            Content = menuStack,
            Background = AppTheme.Background.ClearBrush,
            BorderThickness = AppTheme.UniformThickness(0),
            Padding = AppTheme.UniformThickness(0),
        };
        menuButton.Click += (_, _) =>
        {
            var flyout = new MenuFlyout();
            foreach (var mode in Enum.GetValues<BlendMode>())
            {
                var item = new MenuFlyoutItem { Text = !mixed && mode == current ? $"✓ {mode.DisplayName()}" : mode.DisplayName() };
                item.Click += (_, _) => { _vm.SetBlendMode(mode); Render(); };
                flyout.Items.Add(item);
            }
            flyout.ShowAt(menuButton);
        };
        return BuildPropertyRow("Blend", menuButton);
    }

    // MARK: - Speed (Playback)

    private FrameworkElement? BuildSpeedSection()
    {
        if (_vm.SpeedClips.Count == 0)
        {
            return null;
        }
        var stack = new StackPanel { Spacing = AppThemeTokens.Spacing.SmMd };
        stack.Children.Add(SectionTitleLabel("Playback"));

        var box = new ScrubbableNumberBox { Minimum = 0.25, Maximum = 4.0, DisplayMultiplier = 1, Format = "%.2f", ValueSuffix = "x", DragSensitivity = 0.01, FieldWidth = 50 };
        box.Value = _vm.SpeedShared;
        box.ValueChanged += (_, v) => _vm.ApplySpeed(v);
        box.ValueCommitted += (_, v) => { _vm.CommitSpeed(v); Render(); };
        stack.Children.Add(BuildPropertyRow("Speed", box));

        return stack;
    }
}
