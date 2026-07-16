using System.Runtime.CompilerServices;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using PalmierPro.App.Controls;
using PalmierPro.App.Theme;
using PalmierPro.App.ViewModels.Inspector;
using PalmierPro.Core.Effects;
using PalmierPro.Core.Theme;

namespace PalmierPro.App.Views.Inspector.Tabs;

/// Content view for <see cref="InspectorTab.Effects"/> — registered into InspectorTabRegistry via
/// <see cref="RegisterTab"/> below, per that registry's documented module-initializer pattern.
/// InspectorView builds a fresh instance per tab/selection change; <see cref="Unloaded"/> detaches
/// the backing <see cref="EffectsViewModel"/> so its TimelineEditorViewModel subscriptions don't
/// outlive this control (see that class's remarks).
public sealed partial class EffectsTabView : UserControl
{
    private readonly EffectsViewModel _viewModel;

    public EffectsTabView(InspectorTabContext context)
    {
        InitializeComponent();
        RootStack.Padding = AppTheme.UniformThickness(AppThemeTokens.Spacing.Lg);
        RootStack.Spacing = AppThemeTokens.Spacing.Md;

        _viewModel = new EffectsViewModel(context);
        _viewModel.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName is null or nameof(EffectsViewModel.Stack))
            {
                DispatcherQueue.TryEnqueue(Render);
            }
        };
        Unloaded += (_, _) => _viewModel.Detach();

        Render();
    }

    [ModuleInitializer]
    internal static void RegisterTab() =>
        InspectorTabRegistry.Register(InspectorTab.Effects, context => new EffectsTabView(context));

    private void Render()
    {
        RootStack.Children.Clear();
        RootStack.Children.Add(BuildHeader());

        if (_viewModel.Stack.Count == 0)
        {
            RootStack.Children.Add(BuildEmptyState());
            return;
        }
        foreach (var item in _viewModel.Stack)
        {
            RootStack.Children.Add(BuildEffectCard(item));
        }
    }

    // MARK: - Header / add-effect catalog

    private FrameworkElement BuildHeader()
    {
        var row = new Grid();
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var title = new TextBlock
        {
            Text = "EFFECTS",
            FontSize = AppThemeTokens.FontSize.Xxs,
            FontWeight = AppTheme.FontWeightFor(AppThemeTokens.FontWeight.Semibold),
            Foreground = AppTheme.Text.MutedBrush,
            VerticalAlignment = VerticalAlignment.Center,
        };
        Grid.SetColumn(title, 0);
        row.Children.Add(title);

        var addButton = new Button
        {
            Content = "+ Add Effect",
            FontSize = AppThemeTokens.FontSize.Xs,
            Padding = AppTheme.ThicknessOf(
                AppThemeTokens.Spacing.Sm, AppThemeTokens.Spacing.Xxs, AppThemeTokens.Spacing.Sm, AppThemeTokens.Spacing.Xxs),
        };
        addButton.Click += (_, _) => ShowCatalogFlyout(addButton);
        Grid.SetColumn(addButton, 1);
        row.Children.Add(addButton);

        return row;
    }

    private void ShowCatalogFlyout(FrameworkElement target)
    {
        var flyout = new MenuFlyout();
        foreach (var (category, effects) in _viewModel.Catalog)
        {
            var sub = new MenuFlyoutSubItem { Text = category };
            foreach (var descriptor in effects)
            {
                var alreadyAdded = _viewModel.IsInStack(descriptor.Id);
                var item = new MenuFlyoutItem
                {
                    Text = alreadyAdded ? $"✓ {descriptor.DisplayName}" : descriptor.DisplayName,
                    IsEnabled = !alreadyAdded,
                };
                item.Click += (_, _) => _viewModel.AddEffect(descriptor);
                sub.Items.Add(item);
            }
            flyout.Items.Add(sub);
        }
        flyout.ShowAt(target);
    }

    private static FrameworkElement BuildEmptyState() =>
        new TextBlock
        {
            Text = "No effects applied.",
            FontSize = AppThemeTokens.FontSize.Sm,
            Foreground = AppTheme.Text.TertiaryBrush,
        };

    // MARK: - Effect card

    private FrameworkElement BuildEffectCard(EffectStackItem item)
    {
        var card = new StackPanel { Spacing = AppThemeTokens.Spacing.Sm };
        card.Children.Add(BuildEffectHeader(item));
        foreach (var row in item.Params)
        {
            card.Children.Add(BuildParamRow(item.EffectId, row));
        }
        if (item.Descriptor.ResourceKey is not null)
        {
            card.Children.Add(BuildResourceNotice(item.Descriptor));
        }

        var wrapper = new StackPanel { Spacing = AppThemeTokens.Spacing.Sm };
        wrapper.Children.Add(card);
        wrapper.Children.Add(new Border
        {
            Height = AppThemeTokens.BorderWidth.Hairline,
            Background = AppTheme.Border.PrimaryBrush,
        });
        return wrapper;
    }

    private FrameworkElement BuildEffectHeader(EffectStackItem item)
    {
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var left = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = AppThemeTokens.Spacing.Xxs,
            VerticalAlignment = VerticalAlignment.Center,
        };
        left.Children.Add(IconButton("▲", "Move up", () => _viewModel.MoveEffect(item.EffectId, -1)));
        left.Children.Add(IconButton("▼", "Move down", () => _viewModel.MoveEffect(item.EffectId, 1)));
        left.Children.Add(IconButton(
            item.Enabled ? "●" : "○",
            item.Enabled ? "Disable effect" : "Enable effect",
            () => _viewModel.ToggleEnabled(item.EffectId)));
        left.Children.Add(new TextBlock
        {
            Text = item.Descriptor.DisplayName,
            FontSize = AppThemeTokens.FontSize.Sm,
            FontWeight = AppTheme.FontWeightFor(AppThemeTokens.FontWeight.Medium),
            Foreground = item.Enabled ? AppTheme.Text.PrimaryBrush : AppTheme.Text.MutedBrush,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = AppTheme.ThicknessOf(AppThemeTokens.Spacing.Xxs, 0, 0, 0),
        });
        Grid.SetColumn(left, 0);
        grid.Children.Add(left);

        var remove = IconButton("✕", "Remove effect", () => _viewModel.RemoveEffect(item.EffectId));
        Grid.SetColumn(remove, 1);
        grid.Children.Add(remove);

        return grid;
    }

    private FrameworkElement BuildParamRow(string effectId, EffectParamRow row)
    {
        var container = new Grid { ColumnSpacing = AppThemeTokens.Spacing.Xs };
        container.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        container.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var labeled = new LabeledParamRow
        {
            Label = row.Spec.Label,
            Minimum = row.Spec.RangeMin,
            Maximum = row.Spec.RangeMax,
            DefaultValue = row.Spec.DefaultValue,
            Format = EffectParamFormat(row.Spec),
            ValueSuffix = row.Spec.Unit.Length == 0 ? "" : $" {row.Spec.Unit}",
            DragSensitivity = EffectParamSensitivity(row.Spec),
            Value = row.Value,
        };
        labeled.ValueChanged += (_, v) => _viewModel.ApplyParamValue(effectId, row.Spec.Key, v);
        labeled.ValueCommitted += (_, v) => _viewModel.CommitParamValue(effectId, row.Spec.Key, v);
        Grid.SetColumn(labeled, 0);
        container.Children.Add(labeled);

        if (row.CanToggleKeyframe)
        {
            var kfButton = IconButton(
                row.HasKeyframeAtPlayhead ? "◆" : "◇",
                row.HasKeyframeAtPlayhead ? "Remove keyframe at playhead" : "Add keyframe at playhead",
                () => _viewModel.ToggleKeyframe(effectId, row.Spec.Key));
            Grid.SetColumn(kfButton, 1);
            container.Children.Add(kfButton);
        }

        return container;
    }

    /// LUT (the only registry entry with a `ResourceKey`) has no Windows file-choose control yet —
    /// its `intensity` param row still renders above via the generated-row path, this just flags
    /// the gap rather than silently omitting the file it applies to.
    private static FrameworkElement BuildResourceNotice(EffectDescriptor descriptor) =>
        new TextBlock
        {
            Text = $"Choose a {descriptor.ResourceKey} file — not yet available in this build.",
            FontSize = AppThemeTokens.FontSize.Xs,
            Foreground = AppTheme.Text.TertiaryBrush,
            TextWrapping = TextWrapping.Wrap,
        };

    private static Button IconButton(string glyph, string tooltip, Action onClick)
    {
        var button = new Button
        {
            Content = glyph,
            FontSize = AppThemeTokens.FontSize.Xs,
            Padding = AppTheme.UniformThickness(AppThemeTokens.Spacing.Xxs),
            Background = new SolidColorBrush(Colors.Transparent),
            BorderThickness = AppTheme.UniformThickness(0),
        };
        ToolTipService.SetToolTip(button, tooltip);
        button.Click += (_, _) => onClick();
        return button;
    }

    /// Mirrors AdjustTab.swift's `effectParamFormat`/`effectParamSensitivity` — printf-style, per
    /// ScrubbableNumberBox.Format's contract (see that control).
    private static string EffectParamFormat(EffectParamSpec spec) => (spec.RangeMax - spec.RangeMin) <= 20 ? "%.2f" : "%.0f";

    private static double EffectParamSensitivity(EffectParamSpec spec) => Math.Max(0.01, (spec.RangeMax - spec.RangeMin) / 200);
}
