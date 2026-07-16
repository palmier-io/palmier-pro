using System.ComponentModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Shapes;
using PalmierPro.App.Theme;
using PalmierPro.App.ViewModels.Editor;
using PalmierPro.App.ViewModels.Inspector;
using PalmierPro.Core.Models;
using PalmierPro.Core.Theme;

namespace PalmierPro.App.Views.Inspector;

/// Panel in the editor's right region (M5, Stage E) — replaces EditorPlaceholderView's static
/// InspectorPanel border. Owns tab-rail layout and the selection-driven content switch; every
/// tab's actual content comes from InspectorTabRegistry, so a tab agent's work never touches this
/// file. EditorPlaceholderView.SetDocument calls <see cref="SetTimeline"/> on every document swap,
/// mirroring how it already wires MediaPanelHost/PreviewHost/TimelineHost.
public sealed partial class InspectorView : UserControl
{
    private readonly InspectorViewModel _viewModel = new();
    private TimelineEditorViewModel? _timeline;

    public InspectorView()
    {
        InitializeComponent();

        // {StaticResource} values feeding Thickness-typed properties don't coerce in WinUI XAML
        // the way literal strings do (see AGENTS.md) — set here instead.
        TabRail.Padding = AppTheme.ThicknessOf(AppThemeTokens.Spacing.Lg, AppThemeTokens.Spacing.Xs, AppThemeTokens.Spacing.Lg, 0);
        EmptyStatePanel.Padding = AppTheme.ThicknessOf(AppThemeTokens.Spacing.Lg, AppThemeTokens.Spacing.Md, AppThemeTokens.Spacing.Lg, AppThemeTokens.Spacing.Md);

        _viewModel.PropertyChanged += OnViewModelPropertyChanged;
        Render();
    }

    public void SetTimeline(TimelineEditorViewModel? timeline)
    {
        _timeline = timeline;
        _viewModel.SetTimeline(timeline);
    }

    private void OnViewModelPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is null
            or nameof(InspectorViewModel.SelectionState)
            or nameof(InspectorViewModel.AvailableTabs)
            or nameof(InspectorViewModel.ActiveTab)
            or nameof(InspectorViewModel.TimelineName)
            or nameof(InspectorViewModel.ProjectPath)
            or nameof(InspectorViewModel.TimelineWidth)
            or nameof(InspectorViewModel.TimelineHeight)
            or nameof(InspectorViewModel.TimelineFps)
            or nameof(InspectorViewModel.TimelineDurationText)
            or nameof(InspectorViewModel.TimelineAspectRatioText))
        {
            DispatcherQueue.TryEnqueue(Render);
        }
    }

    private void Render()
    {
        RefreshTabRail();
        RefreshContent();
    }

    private void RefreshTabRail()
    {
        TabRail.Children.Clear();
        var tabs = _viewModel.AvailableTabs;
        // Mirrors the Mac's `if tabs.count > 1` — a single-tab selection (e.g. text-only) shows no
        // rail at all, same as EditorPlaceholderView's other panels showing nothing extraneous.
        TabRailHost.Visibility = tabs.Count > 1 ? Visibility.Visible : Visibility.Collapsed;
        foreach (var tab in tabs)
        {
            TabRail.Children.Add(BuildTabButton(tab, tab == _viewModel.ActiveTab));
        }
    }

    private FrameworkElement BuildTabButton(InspectorTab tab, bool isActive)
    {
        var root = new Grid
        {
            Background = AppTheme.Background.ClearBrush,
            Padding = AppTheme.ThicknessOf(0, 0, 0, AppThemeTokens.Spacing.Xs),
        };
        var stack = new StackPanel { Spacing = AppThemeTokens.Spacing.Xs };

        stack.Children.Add(new TextBlock
        {
            Text = tab.DisplayName(),
            FontSize = AppThemeTokens.FontSize.Sm,
            FontWeight = AppTheme.FontWeightFor(isActive ? AppThemeTokens.FontWeight.Medium : AppThemeTokens.FontWeight.Regular),
            Foreground = isActive ? AppTheme.Text.PrimaryBrush : AppTheme.Text.TertiaryBrush,
        });
        stack.Children.Add(new Rectangle
        {
            Height = AppThemeTokens.BorderWidth.Medium,
            Fill = isActive ? AppTheme.Text.PrimaryBrush : AppTheme.Background.ClearBrush,
        });

        root.Children.Add(stack);
        root.Tapped += (_, e) =>
        {
            _viewModel.SelectTab(tab);
            e.Handled = true;
        };
        return root;
    }

    private void RefreshContent()
    {
        ContentHost.Content = null;

        if (_viewModel.SelectionState == InspectorSelectionState.None || _timeline is null)
        {
            EmptyStateHost.Visibility = Visibility.Visible;
            RefreshEmptyState();
            return;
        }
        EmptyStateHost.Visibility = Visibility.Collapsed;

        // Selection resolves to no in-scope tab (an audio-only clip — no tab content owns that
        // yet) — render nothing, same treatment Phase 1 gives Multicam/AI.
        if (_viewModel.ActiveTab is not { } tab)
        {
            return;
        }

        var context = new InspectorTabContext
        {
            SelectionState = _viewModel.SelectionState,
            SelectedClips = _viewModel.SelectedClips,
            Timeline = _timeline,
        };
        ContentHost.Content = InspectorTabRegistry.TryCreate(tab, context);
    }

    private void RefreshEmptyState()
    {
        NameValueText.Text = _viewModel.TimelineName;
        PathValueText.Text = _viewModel.ProjectPath;
        DurationValueText.Text = _viewModel.TimelineDurationText;

        // Menu-backed — ports `menuMetadataRow` -> qualityMenuItems/fpsMenuItems/aspectMenuItems,
        // each calling editor.applyTimelineSettings so the timeline's fps/resolution can be
        // changed straight from the no-selection inspector, matching InspectorView.swift.
        SettingsSectionRows.Children.Clear();
        SettingsSectionRows.Children.Add(BuildResolutionRow());
        SettingsSectionRows.Children.Add(BuildFrameRateRow());
        SettingsSectionRows.Children.Add(BuildAspectRatioRow());
    }

    // MARK: - Settings menu rows

    private FrameworkElement BuildResolutionRow() =>
        BuildMenuMetadataRow("Resolution", $"{_viewModel.TimelineWidth} × {_viewModel.TimelineHeight}", flyout =>
        {
            foreach (var preset in QualityPresetExtensions.All)
            {
                var isCurrent = preset.Matches(_viewModel.TimelineWidth, _viewModel.TimelineHeight);
                var item = new MenuFlyoutItem { Text = isCurrent ? $"✓ {preset.Label()}" : preset.Label() };
                item.Click += (_, _) =>
                {
                    var (w, h) = preset.Resolution(_viewModel.TimelineWidth, _viewModel.TimelineHeight);
                    _timeline?.ApplyTimelineSettings(_viewModel.TimelineFps, w, h);
                };
                flyout.Items.Add(item);
            }
        });

    private FrameworkElement BuildFrameRateRow() =>
        BuildMenuMetadataRow("Frame Rate", $"{_viewModel.TimelineFps} fps", flyout =>
        {
            foreach (var fps in FpsChoices)
            {
                var isCurrent = _viewModel.TimelineFps == fps;
                var item = new MenuFlyoutItem { Text = isCurrent ? $"✓ {fps} fps" : $"{fps} fps" };
                item.Click += (_, _) => _timeline?.ApplyTimelineSettings(fps, _viewModel.TimelineWidth, _viewModel.TimelineHeight);
                flyout.Items.Add(item);
            }
        });

    private FrameworkElement BuildAspectRatioRow() =>
        BuildMenuMetadataRow("Aspect Ratio", _viewModel.TimelineAspectRatioText, flyout =>
        {
            foreach (var preset in AspectPresetExtensions.All)
            {
                var isCurrent = _viewModel.TimelineWidth == preset.Width() && _viewModel.TimelineHeight == preset.Height();
                var item = new MenuFlyoutItem { Text = isCurrent ? $"✓ {preset.Label()}" : preset.Label() };
                item.Click += (_, _) => _timeline?.ApplyTimelineSettings(_viewModel.TimelineFps, preset.Width(), preset.Height());
                flyout.Items.Add(item);
            }
        });

    /// Mirrors the Mac's fixed `fpsMenuItems` choice list — InspectorView.swift's
    /// `ForEach([24, 25, 30, 50, 60], id: \.self)`.
    private static readonly int[] FpsChoices = [24, 25, 30, 50, 60];

    /// `[label] .... [value ▾]` — ports `menuMetadataRow`: a right-aligned button opens a fresh
    /// MenuFlyout on every click (rebuilt each time, like TransformTabView's crop/blend menus) so
    /// the "✓ current" mark always reflects the live timeline settings, not whatever was true when
    /// the flyout was first built.
    private FrameworkElement BuildMenuMetadataRow(string label, string value, Action<MenuFlyout> populate)
    {
        var grid = new Grid { Height = AppThemeTokens.IconSize.Md };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        var labelText = new TextBlock
        {
            Text = label,
            FontSize = AppThemeTokens.FontSize.Xs,
            Foreground = AppTheme.Text.TertiaryBrush,
        };
        Grid.SetColumn(labelText, 0);

        var menuStack = new StackPanel { Orientation = Orientation.Horizontal, Spacing = AppThemeTokens.Spacing.Xxs };
        menuStack.Children.Add(new TextBlock
        {
            Text = value,
            FontSize = AppThemeTokens.FontSize.Xs,
            Foreground = AppTheme.Text.SecondaryBrush,
        });
        menuStack.Children.Add(new TextBlock
        {
            Text = "▾",
            FontSize = AppThemeTokens.FontSize.Xxs,
            Foreground = AppTheme.Text.MutedBrush,
            Margin = AppTheme.ThicknessOf(AppThemeTokens.Spacing.Xxs, 0, 0, 0),
            VerticalAlignment = VerticalAlignment.Center,
        });
        var menuButton = new Button
        {
            Content = menuStack,
            Background = AppTheme.Background.ClearBrush,
            BorderThickness = AppTheme.UniformThickness(0),
            Padding = AppTheme.UniformThickness(0),
            HorizontalAlignment = HorizontalAlignment.Right,
            IsEnabled = _timeline is not null,
        };
        menuButton.Click += (_, _) =>
        {
            var flyout = new MenuFlyout();
            populate(flyout);
            flyout.ShowAt(menuButton);
        };
        Grid.SetColumn(menuButton, 1);

        grid.Children.Add(labelText);
        grid.Children.Add(menuButton);
        return grid;
    }
}
