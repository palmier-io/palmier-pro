using System.Runtime.CompilerServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using PalmierPro.App.Controls;
using PalmierPro.App.Theme;
using PalmierPro.App.ViewModels.Inspector;
using PalmierPro.Core.Models;
using PalmierPro.Core.Theme;
using Windows.UI.Text;

namespace PalmierPro.App.Views.Inspector.Tabs;

/// Text tab content (M5) — ports Inspector/Tabs/TextTab.swift. Built once in <see cref="Build"/>
/// off a fresh <see cref="TextViewModel"/> (InspectorView constructs a new instance per selection —
/// see InspectorTabRegistry); <see cref="Render"/> re-syncs every control's displayed value
/// whenever TextViewModel.Changed fires (its own edits reflecting back, or an external Undo/Redo)
/// without rebuilding the tree, so the content TextBox never loses focus/selection mid-edit.
/// Interactive event handlers are wired in <see cref="WireInteractions"/>, strictly *after* the
/// first <see cref="Render"/> call — <see cref="ToggleSwitch.Toggled"/> and
/// <see cref="ColorPicker.ColorChanged"/> both fire from a plain property assignment, not just user
/// gesture, so wiring them before that first sync would fire a spurious apply/commit against
/// whatever those controls' WinUI defaults happen to be.
public sealed partial class TextTabView : UserControl
{
    private readonly TextViewModel _vm;

    private TextBox _contentBox = null!;
    private Border _contentContainer = null!;

    private Button _fontButton = null!;
    private TextBlock _fontButtonText = null!;
    private Flyout _fontFlyout = null!;
    private bool _fontPicked;

    private Border _boldGlyph = null!;
    private TextBlock _boldText = null!;
    private Border _italicGlyph = null!;
    private TextBlock _italicText = null!;

    private LabeledParamRow _sizeRow = null!;
    private LabeledParamRow _opacityRow = null!;

    private ColorSwatch _colorSwatch = null!;
    private ColorSwatch _backgroundSwatch = null!;
    private ToggleSwitch _backgroundToggle = null!;
    private ColorSwatch _borderSwatch = null!;
    private ToggleSwitch _borderToggle = null!;
    private ColorSwatch _shadowSwatch = null!;
    private ToggleSwitch _shadowToggle = null!;

    private Border _alignLeft = null!;
    private TextBlock _alignLeftText = null!;
    private Border _alignCenter = null!;
    private TextBlock _alignCenterText = null!;
    private Border _alignRight = null!;
    private TextBlock _alignRightText = null!;

    private static IReadOnlyList<string>? _cachedSystemFamilies;

    public TextTabView(InspectorTabContext context)
    {
        InitializeComponent();
        _vm = new TextViewModel(context.Timeline, context.SelectedClips);

        RootStack.Spacing = AppThemeTokens.Spacing.XlXxl;
        RootStack.Padding = AppTheme.ThicknessOf(
            AppThemeTokens.Spacing.Lg, AppThemeTokens.Spacing.Md, AppThemeTokens.Spacing.Lg, AppThemeTokens.Spacing.Xl);

        Build();
        Render();
        WireInteractions();

        _vm.Changed += OnViewModelChanged;
        Unloaded += (_, _) => _vm.Dispose();
    }

    private void OnViewModelChanged(object? sender, EventArgs e) => DispatcherQueue.TryEnqueue(Render);

    // MARK: - Build (structure only — no mutating event handlers; see WireInteractions)

    private void Build()
    {
        RootStack.Children.Add(BuildContentField());
        RootStack.Children.Add(Section("TYPOGRAPHY", BuildFontRow(), BuildStyleRow(), BuildSizeRow()));
        RootStack.Children.Add(Section(
            "APPEARANCE", BuildColorRow(), BuildOpacityRow(), BuildBackgroundRow(), BuildOutlineRow(), BuildShadowRow()));
        RootStack.Children.Add(Section("LAYOUT", BuildAlignmentRow()));
    }

    private FrameworkElement BuildContentField()
    {
        var label = new TextBlock
        {
            Text = "Content",
            FontSize = AppThemeTokens.FontSize.Sm,
            FontWeight = AppTheme.FontWeightFor(AppThemeTokens.FontWeight.Medium),
            Foreground = AppTheme.Text.PrimaryBrush,
        };
        _contentBox = new TextBox
        {
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            MinHeight = 80,
            Background = AppTheme.Background.ClearBrush,
            BorderThickness = AppTheme.UniformThickness(0),
            FontSize = AppThemeTokens.FontSize.Md,
            Foreground = AppTheme.Text.PrimaryBrush,
        };
        _contentContainer = new Border
        {
            Padding = AppTheme.UniformThickness(AppThemeTokens.Spacing.Xs),
            CornerRadius = AppTheme.UniformCornerRadius(AppThemeTokens.Radius.Sm),
            Background = TranslucentWhite(AppThemeTokens.Opacity.Hint),
            Child = _contentBox,
        };
        var stack = new StackPanel { Spacing = AppThemeTokens.Spacing.Xs };
        stack.Children.Add(label);
        stack.Children.Add(_contentContainer);
        return stack;
    }

    private FrameworkElement BuildFontRow()
    {
        _fontButtonText = new TextBlock
        {
            FontSize = AppThemeTokens.FontSize.Sm,
            Foreground = AppTheme.Text.PrimaryBrush,
            TextTrimming = TextTrimming.CharacterEllipsis,
            MaxWidth = 130,
        };
        var chevron = new TextBlock
        {
            Text = "▾",
            FontSize = AppThemeTokens.FontSize.Xxs,
            Foreground = AppTheme.Text.TertiaryBrush,
            Margin = AppTheme.ThicknessOf(AppThemeTokens.Spacing.Xs, 0, 0, 0),
            VerticalAlignment = VerticalAlignment.Center,
        };
        var content = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        content.Children.Add(_fontButtonText);
        content.Children.Add(chevron);

        _fontFlyout = new Flyout { Content = BuildFontFlyoutContent() };

        _fontButton = new Button
        {
            Content = content,
            Background = TranslucentWhite(AppThemeTokens.Opacity.Hint),
            BorderThickness = AppTheme.UniformThickness(0),
            CornerRadius = AppTheme.UniformCornerRadius(AppThemeTokens.Radius.Sm),
            Padding = AppTheme.ThicknessOf(
                AppThemeTokens.Spacing.SmMd, AppThemeTokens.Spacing.Xs, AppThemeTokens.Spacing.SmMd, AppThemeTokens.Spacing.Xs),
            Flyout = _fontFlyout,
        };
        return Row("Font", _fontButton);
    }

    private FrameworkElement BuildFontFlyoutContent()
    {
        var stack = new StackPanel { Spacing = AppThemeTokens.Spacing.Xxs };
        stack.Children.Add(FontGroupHeader("Featured"));
        foreach (var name in TextFontCatalog.BundledFamilies)
        {
            stack.Children.Add(BuildFontItem(name));
        }
        stack.Children.Add(new Rectangle
        {
            Height = AppThemeTokens.BorderWidth.Hairline,
            Fill = AppTheme.Border.SubtleBrush,
            Margin = AppTheme.ThicknessOf(0, AppThemeTokens.Spacing.Xs, 0, AppThemeTokens.Spacing.Xs),
        });
        stack.Children.Add(FontGroupHeader("All Fonts"));
        foreach (var name in SystemFamilies())
        {
            stack.Children.Add(BuildFontItem(name));
        }
        return new ScrollViewer
        {
            Content = stack,
            MaxHeight = 320,
            Width = 220,
            Padding = AppTheme.UniformThickness(AppThemeTokens.Spacing.Xxs),
        };
    }

    private static TextBlock FontGroupHeader(string title) => new()
    {
        Text = title,
        FontSize = AppThemeTokens.FontSize.Xxs,
        FontWeight = AppTheme.FontWeightFor(AppThemeTokens.FontWeight.Semibold),
        Foreground = AppTheme.Text.MutedBrush,
        Margin = AppTheme.ThicknessOf(AppThemeTokens.Spacing.Sm, AppThemeTokens.Spacing.Xs, AppThemeTokens.Spacing.Sm, AppThemeTokens.Spacing.Xxs),
    };

    private FrameworkElement BuildFontItem(string name)
    {
        // "✓ " prefix marks the currently-applied family — mirrors FontPickerField.swift's
        // `item.state = .on when name == current` and this codebase's own convention for
        // custom (non-MenuFlyoutItem) menu rows (see TransformTabView's crop/blend menus).
        var isCurrent = name == _vm.FontName;
        var text = new TextBlock
        {
            Text = isCurrent ? $"✓ {name}" : name,
            FontSize = AppThemeTokens.FontSize.Sm,
            FontFamily = TextFontCatalog.PreviewFontFamily(name),
            Foreground = AppTheme.Text.PrimaryBrush,
            TextTrimming = TextTrimming.CharacterEllipsis,
        };
        var row = new Border
        {
            Padding = AppTheme.ThicknessOf(
                AppThemeTokens.Spacing.Sm, AppThemeTokens.Spacing.Xs, AppThemeTokens.Spacing.Sm, AppThemeTokens.Spacing.Xs),
            Background = AppTheme.Background.ClearBrush,
            Child = text,
        };
        row.PointerEntered += (_, _) => _vm.PreviewFont(name);
        row.Tapped += (_, _) =>
        {
            _fontPicked = true;
            _vm.ChangeFont(name);
            _fontFlyout.Hide();
        };
        return row;
    }

    private static IReadOnlyList<string> SystemFamilies() => _cachedSystemFamilies ??= TextFontCatalog.SystemFamilies();

    private FrameworkElement BuildStyleRow()
    {
        (_boldGlyph, _boldText) = BuildTraitButton(isItalic: false);
        (_italicGlyph, _italicText) = BuildTraitButton(isItalic: true);
        var stack = new StackPanel { Orientation = Orientation.Horizontal, Spacing = AppThemeTokens.Spacing.Xs };
        stack.Children.Add(_boldGlyph);
        stack.Children.Add(_italicGlyph);
        return Row("Style", stack);
    }

    private static (Border, TextBlock) BuildTraitButton(bool isItalic)
    {
        var text = new TextBlock
        {
            FontSize = AppThemeTokens.FontSize.Sm,
            FontWeight = AppTheme.FontWeightFor(AppThemeTokens.FontWeight.Semibold),
            FontStyle = isItalic ? FontStyle.Italic : FontStyle.Normal,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        };
        var border = new Border
        {
            Width = AppThemeTokens.IconSize.MdLg,
            Height = AppThemeTokens.IconSize.Md,
            CornerRadius = AppTheme.UniformCornerRadius(AppThemeTokens.Radius.XsSm),
            Child = text,
        };
        return (border, text);
    }

    private FrameworkElement BuildSizeRow()
    {
        _sizeRow = new LabeledParamRow
        {
            Label = "Size",
            Minimum = 12,
            Maximum = 300,
            DefaultValue = 96,
            Format = "%.0f",
            ValueSuffix = " pt",
        };
        return _sizeRow;
    }

    private FrameworkElement BuildColorRow()
    {
        _colorSwatch = new ColorSwatch();
        return Row("Color", _colorSwatch.Button);
    }

    private FrameworkElement BuildOpacityRow()
    {
        _opacityRow = new LabeledParamRow
        {
            Label = "Opacity",
            Minimum = 0,
            Maximum = 1,
            DefaultValue = 1,
            DisplayMultiplier = 100,
            Format = "%.0f",
            ValueSuffix = "%",
        };
        return _opacityRow;
    }

    private FrameworkElement BuildBackgroundRow()
    {
        _backgroundSwatch = new ColorSwatch();
        _backgroundToggle = new ToggleSwitch { OnContent = "", OffContent = "" };
        return Row("Background", ToggleColorStack(_backgroundSwatch, _backgroundToggle));
    }

    private FrameworkElement BuildOutlineRow()
    {
        _borderSwatch = new ColorSwatch();
        _borderToggle = new ToggleSwitch { OnContent = "", OffContent = "" };
        return Row("Outline", ToggleColorStack(_borderSwatch, _borderToggle));
    }

    private FrameworkElement BuildShadowRow()
    {
        _shadowSwatch = new ColorSwatch();
        _shadowToggle = new ToggleSwitch { OnContent = "", OffContent = "" };
        return Row("Shadow", ToggleColorStack(_shadowSwatch, _shadowToggle));
    }

    private static FrameworkElement ToggleColorStack(ColorSwatch swatch, ToggleSwitch toggle)
    {
        var stack = new StackPanel { Orientation = Orientation.Horizontal, Spacing = AppThemeTokens.Spacing.Sm };
        stack.Children.Add(swatch.Button);
        stack.Children.Add(toggle);
        return stack;
    }

    private FrameworkElement BuildAlignmentRow()
    {
        (_alignLeft, _alignLeftText) = BuildAlignButton("Left");
        (_alignCenter, _alignCenterText) = BuildAlignButton("Center");
        (_alignRight, _alignRightText) = BuildAlignButton("Right");
        var stack = new StackPanel { Orientation = Orientation.Horizontal, Spacing = AppThemeTokens.Spacing.Xs };
        stack.Children.Add(_alignLeft);
        stack.Children.Add(_alignCenter);
        stack.Children.Add(_alignRight);
        return Row("Alignment", stack);
    }

    private static (Border, TextBlock) BuildAlignButton(string label)
    {
        var text = new TextBlock
        {
            Text = label,
            FontSize = AppThemeTokens.FontSize.Xs,
            FontWeight = AppTheme.FontWeightFor(AppThemeTokens.FontWeight.Medium),
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        };
        var border = new Border
        {
            Padding = AppTheme.ThicknessOf(
                AppThemeTokens.Spacing.Sm, AppThemeTokens.Spacing.Xxs, AppThemeTokens.Spacing.Sm, AppThemeTokens.Spacing.Xxs),
            CornerRadius = AppTheme.UniformCornerRadius(AppThemeTokens.Radius.XsSm),
            Child = text,
        };
        return (border, text);
    }

    // MARK: - Wiring (deferred — see class doc comment)

    private void WireInteractions()
    {
        _contentBox.TextChanged += (_, _) => _vm.ApplyContent(_contentBox.Text);
        _contentBox.LostFocus += (_, _) => _vm.CommitContent(_contentBox.Text);

        // Rebuilt on every open (not just at construction) so the "✓ current" row tracks the
        // live selection — mirrors FontPickerField.swift's presentMenu() building a fresh NSMenu
        // each time rather than caching state from whenever the flyout was first shown.
        _fontFlyout.Opened += (_, _) =>
        {
            _fontPicked = false;
            _fontFlyout.Content = BuildFontFlyoutContent();
        };
        _fontFlyout.Closed += (_, _) =>
        {
            if (!_fontPicked)
            {
                _vm.CancelFont();
            }
        };

        _boldGlyph.Tapped += (_, _) => _vm.SetBold(!(_vm.IsBold ?? false));
        _italicGlyph.Tapped += (_, _) => _vm.SetItalic(!(_vm.IsItalic ?? false));

        _sizeRow.ValueChanged += (_, v) => _vm.ApplySize(v);
        _sizeRow.ValueCommitted += (_, v) => _vm.CommitSize(v);
        _opacityRow.ValueChanged += (_, v) => _vm.ApplyOpacity(v);
        _opacityRow.ValueCommitted += (_, v) => _vm.CommitOpacity(v);

        _colorSwatch.Activate(_vm.ApplyColor, _vm.CommitColor);
        _backgroundSwatch.Activate(_vm.ApplyBackgroundColor, _vm.CommitBackgroundColor);
        _borderSwatch.Activate(_vm.ApplyBorderColor, _vm.CommitBorderColor);
        _shadowSwatch.Activate(_vm.ApplyShadowColor, _vm.CommitShadowColor);

        _backgroundToggle.Toggled += (_, _) => _vm.SetBackgroundEnabled(_backgroundToggle.IsOn);
        _borderToggle.Toggled += (_, _) => _vm.SetBorderEnabled(_borderToggle.IsOn);
        _shadowToggle.Toggled += (_, _) => _vm.SetShadowEnabled(_shadowToggle.IsOn);

        _alignLeft.Tapped += (_, _) => _vm.SetAlignment(TextStyleAlignment.Left);
        _alignCenter.Tapped += (_, _) => _vm.SetAlignment(TextStyleAlignment.Center);
        _alignRight.Tapped += (_, _) => _vm.SetAlignment(TextStyleAlignment.Right);
    }

    // MARK: - Render (visual sync only — never attaches/detaches an event handler)

    private void Render()
    {
        // Never stomps the content box while the user has it focused — mirrors
        // TextContentField.swift's own `guard textView.window?.firstResponder !== textView`.
        if (_contentBox.FocusState == FocusState.Unfocused)
        {
            var text = _vm.Content;
            if (_contentBox.Text != text)
            {
                _contentBox.Text = text;
            }
        }
        _contentBox.IsEnabled = !_vm.IsBatch;
        _contentContainer.Opacity = _vm.IsBatch ? AppThemeTokens.Opacity.Medium : AppThemeTokens.Opacity.Opaque;

        _fontButtonText.Text = _vm.FontName is { } fontName ? TextFontCatalog.DisplayFamilyName(fontName) : "Mixed";

        RenderTrait(_boldGlyph, _boldText, "B", _vm.IsBold);
        RenderTrait(_italicGlyph, _italicText, "I", _vm.IsItalic);

        _sizeRow.Value = _vm.FontSize;
        _opacityRow.Value = _vm.Opacity;

        _colorSwatch.SetColor(_vm.Color);
        RenderToggleColor(_backgroundSwatch, _backgroundToggle, _vm.BackgroundEnabled, _vm.BackgroundColor);
        RenderToggleColor(_borderSwatch, _borderToggle, _vm.BorderEnabled, _vm.BorderColor);
        RenderToggleColor(_shadowSwatch, _shadowToggle, _vm.ShadowEnabled, _vm.ShadowColor);

        RenderAlign(_alignLeft, _alignLeftText, TextStyleAlignment.Left);
        RenderAlign(_alignCenter, _alignCenterText, TextStyleAlignment.Center);
        RenderAlign(_alignRight, _alignRightText, TextStyleAlignment.Right);
    }

    private static void RenderTrait(Border border, TextBlock text, string glyph, bool? state)
    {
        var isActive = state == true;
        text.Text = state is null ? "−" : glyph;
        text.Foreground = isActive ? AppTheme.Background.BaseBrush : AppTheme.Text.TertiaryBrush;
        border.Background = isActive ? AppTheme.Accent.PrimaryBrush : TranslucentWhite(AppThemeTokens.Opacity.Hint);
        border.BorderBrush = isActive ? AppTheme.Accent.PrimaryBrush : AppTheme.Border.SubtleBrush;
        border.BorderThickness = AppTheme.UniformThickness(
            isActive ? AppThemeTokens.BorderWidth.Thin : AppThemeTokens.BorderWidth.Hairline);
    }

    private static void RenderToggleColor(ColorSwatch swatch, ToggleSwitch toggle, bool enabled, TextStyleRgba color)
    {
        swatch.SetColor(color);
        swatch.Button.IsEnabled = enabled;
        swatch.Button.Opacity = enabled ? AppThemeTokens.Opacity.Opaque : AppThemeTokens.Opacity.Medium;
        // Only ever a genuine change fires ToggleSwitch.Toggled (WinUI DP setters no-op when the
        // new value equals the old one) — safe to set unconditionally on every render.
        toggle.IsOn = enabled;
    }

    private void RenderAlign(Border border, TextBlock text, TextStyleAlignment value)
    {
        var isActive = _vm.Alignment == value;
        border.Background = isActive ? AppTheme.Accent.PrimaryBrush : TranslucentWhite(AppThemeTokens.Opacity.Hint);
        border.BorderBrush = isActive ? AppTheme.Accent.PrimaryBrush : AppTheme.Border.SubtleBrush;
        border.BorderThickness = AppTheme.UniformThickness(
            isActive ? AppThemeTokens.BorderWidth.Thin : AppThemeTokens.BorderWidth.Hairline);
        text.Foreground = isActive ? AppTheme.Background.BaseBrush : AppTheme.Text.SecondaryBrush;
    }

    // MARK: - Shared layout/color helpers

    private static TextBlock SectionHeader(string title) => new()
    {
        Text = title,
        FontSize = AppThemeTokens.FontSize.Xxs,
        FontWeight = AppTheme.FontWeightFor(AppThemeTokens.FontWeight.Semibold),
        Foreground = AppTheme.Text.MutedBrush,
        // WinUI's CharacterSpacing is thousandths-of-an-em; AppThemeTokens.Tracking is Mac
        // point-tracking — no shared conversion exists yet, so this stays a local, documented
        // derivation rather than a bare literal.
        CharacterSpacing = (int)(AppThemeTokens.Tracking.Wide * 100),
    };

    private static StackPanel Section(string title, params FrameworkElement[] rows)
    {
        var outer = new StackPanel { Spacing = AppThemeTokens.Spacing.SmMd };
        outer.Children.Add(SectionHeader(title));
        var inner = new StackPanel { Spacing = AppThemeTokens.Spacing.Md };
        foreach (var row in rows)
        {
            inner.Children.Add(row);
        }
        outer.Children.Add(inner);
        return outer;
    }

    /// `[label] .... [trailing]` — LabeledParamRow already carries its own label, so Size/Opacity
    /// rows go straight into a section without this wrapper.
    private static Grid Row(string label, FrameworkElement trailing)
    {
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var text = new TextBlock
        {
            Text = label,
            FontSize = AppThemeTokens.FontSize.Sm,
            FontWeight = AppTheme.FontWeightFor(AppThemeTokens.FontWeight.Medium),
            Foreground = AppTheme.Text.PrimaryBrush,
            VerticalAlignment = VerticalAlignment.Center,
        };
        Grid.SetColumn(text, 0);
        trailing.HorizontalAlignment = HorizontalAlignment.Right;
        trailing.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(trailing, 1);
        grid.Children.Add(text);
        grid.Children.Add(trailing);
        return grid;
    }

    private static SolidColorBrush TranslucentWhite(double opacity) =>
        new(Windows.UI.Color.FromArgb((byte)Math.Round(opacity * 255), 255, 255, 255));

    private static Windows.UI.Color ToUiColor(TextStyleRgba c) => Windows.UI.Color.FromArgb(
        (byte)Math.Round(Math.Clamp(c.A, 0, 1) * 255),
        (byte)Math.Round(Math.Clamp(c.R, 0, 1) * 255),
        (byte)Math.Round(Math.Clamp(c.G, 0, 1) * 255),
        (byte)Math.Round(Math.Clamp(c.B, 0, 1) * 255));

    private static TextStyleRgba ToStyleRgba(Windows.UI.Color c) => new(c.R / 255.0, c.G / 255.0, c.B / 255.0, c.A / 255.0);

    /// A clickable swatch that opens a `ColorPicker` flyout — the WinUI equivalent of
    /// ColorField.swift's `NSColorPanel`-backed button, minus the debounce ColorField needs: a
    /// `Flyout` gives a clean "gesture ended" signal (`Closed`) that `NSColorPanel` (non-modal, no
    /// close event) doesn't, so previewing on `ColorChanged` and committing on `Closed` needs no
    /// separate debounce timer.
    private sealed class ColorSwatch
    {
        private readonly Border _swatch;
        private readonly ColorPicker _picker;
        private readonly Flyout _flyout;

        public ColorSwatch()
        {
            _swatch = new Border
            {
                Width = AppThemeTokens.IconSize.MdLg,
                Height = AppThemeTokens.IconSize.Xxs,
                CornerRadius = AppTheme.UniformCornerRadius(AppThemeTokens.Radius.Xs),
                BorderThickness = AppTheme.UniformThickness(AppThemeTokens.BorderWidth.Thin),
                BorderBrush = TranslucentWhite(AppThemeTokens.Opacity.Medium),
            };
            _picker = new ColorPicker { IsAlphaEnabled = true, IsAlphaTextInputVisible = true };
            _flyout = new Flyout { Content = _picker };
            Button = new Button
            {
                Content = _swatch,
                Background = AppTheme.Background.ClearBrush,
                BorderThickness = AppTheme.UniformThickness(0),
                Padding = AppTheme.UniformThickness(0),
                Flyout = _flyout,
            };
        }

        public Button Button { get; }

        public void SetColor(TextStyleRgba color)
        {
            var uiColor = ToUiColor(color);
            _swatch.Background = new SolidColorBrush(uiColor);
            _picker.Color = uiColor;
        }

        /// Deferred past the constructor — see TextTabView's class doc comment for why.
        public void Activate(Action<TextStyleRgba> onPreview, Action<TextStyleRgba> onCommit)
        {
            _picker.ColorChanged += (_, args) => onPreview(ToStyleRgba(args.NewColor));
            _flyout.Closed += (_, _) => onCommit(ToStyleRgba(_picker.Color));
        }
    }
}

/// Registers this tab's factory with the shell (InspectorTabRegistry's documented pattern — see
/// its own doc comment) without InspectorView ever needing to know this file exists.
file static class TextTabViewRegistration
{
    [ModuleInitializer]
    internal static void Register() => InspectorTabRegistry.Register(InspectorTab.Text, context => new TextTabView(context));
}
