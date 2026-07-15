using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using PalmierPro.App.Theme;
using PalmierPro.App.ViewModels.Editor;
using PalmierPro.Core.Theme;
using Windows.System;

namespace PalmierPro.App.Views.Timeline;

public sealed partial class TimelineTabBarView : UserControl
{
    private TimelineEditorViewModel? _vm;
    private string? _renamingTabId;

    public TimelineTabBarView()
    {
        InitializeComponent();
        AllTimelinesButton.Padding = AppTheme.UniformThickness(AppThemeTokens.Spacing.Xs);
        AddTabButton.Padding = AppTheme.UniformThickness(AppThemeTokens.Spacing.Xs);
    }

    public void SetViewModel(TimelineEditorViewModel? vm)
    {
        if (_vm is not null)
        {
            _vm.PropertyChanged -= OnViewModelPropertyChanged;
        }
        _vm = vm;
        if (_vm is not null)
        {
            _vm.PropertyChanged += OnViewModelPropertyChanged;
        }
        _renamingTabId = null;
        RefreshTabs();
    }

    private void OnViewModelPropertyChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        if (e.PropertyName is null or nameof(TimelineEditorViewModel.ActiveTimelineId))
        {
            DispatcherQueue.TryEnqueue(RefreshTabs);
        }
    }

    public void RefreshTabs()
    {
        TabsPanel.Children.Clear();
        if (_vm is not { } vm)
        {
            return;
        }

        foreach (var id in vm.OpenTimelineIds)
        {
            if (vm.TimelineFor(id) is not { } timeline)
            {
                continue;
            }
            TabsPanel.Children.Add(BuildTab(vm, id, timeline.Name));
        }
    }

    private FrameworkElement BuildTab(TimelineEditorViewModel vm, string id, string name)
    {
        var isActive = id == vm.ActiveTimelineId;

        var root = new Grid
        {
            Padding = AppTheme.ThicknessOf(AppThemeTokens.Spacing.Xs, AppThemeTokens.Spacing.Xxs, AppThemeTokens.Spacing.Xs, AppThemeTokens.Spacing.Xxs),
        };
        var stack = new StackPanel { Orientation = Orientation.Horizontal, Spacing = AppThemeTokens.Spacing.Xs, VerticalAlignment = VerticalAlignment.Center };

        if (_renamingTabId == id)
        {
            var box = new TextBox { Text = name, Width = AppThemeTokens.ComponentSize.TimelineTabRenameWidth };
            box.Loaded += (_, _) => box.SelectAll();
            box.KeyDown += (_, e) =>
            {
                if (e.Key == VirtualKey.Enter)
                {
                    Commit(box.Text);
                    e.Handled = true;
                }
                else if (e.Key == VirtualKey.Escape)
                {
                    _renamingTabId = null;
                    RefreshTabs();
                    e.Handled = true;
                }
            };
            box.LostFocus += (_, _) => Commit(box.Text);
            stack.Children.Add(box);

            void Commit(string text)
            {
                vm.RenameTimeline(id, text);
                _renamingTabId = null;
                RefreshTabs();
            }
        }
        else
        {
            var label = new TextBlock
            {
                Text = name,
                FontSize = AppThemeTokens.FontSize.Xs,
                FontWeight = AppTheme.FontWeightFor(isActive ? AppThemeTokens.FontWeight.Semibold : AppThemeTokens.FontWeight.Medium),
                Foreground = isActive ? AppTheme.Text.PrimaryBrush : AppTheme.Text.SecondaryBrush,
                VerticalAlignment = VerticalAlignment.Center,
            };
            stack.Children.Add(label);

            if (vm.OpenTimelineIds.Count > 1)
            {
                var close = new Button
                {
                    Content = "",
                    FontFamily = new FontFamily("Segoe Fluent Icons"),
                    FontSize = AppThemeTokens.FontSize.Xxs,
                    Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
                    BorderThickness = AppTheme.UniformThickness(0),
                    Padding = AppTheme.UniformThickness(AppThemeTokens.Spacing.Xxs),
                };
                close.Click += (_, _) => vm.CloseTimelineTab(id);
                stack.Children.Add(close);
            }
        }

        root.Children.Add(stack);

        var underline = new Border
        {
            Height = AppThemeTokens.BorderWidth.Medium,
            VerticalAlignment = VerticalAlignment.Bottom,
            Background = isActive ? AppTheme.Accent.PrimaryBrush : new SolidColorBrush(Microsoft.UI.Colors.Transparent),
        };
        root.Children.Add(underline);

        root.DoubleTapped += (_, e) =>
        {
            _renamingTabId = id;
            RefreshTabs();
            e.Handled = true;
        };
        root.Tapped += (_, e) =>
        {
            vm.ActivateTimeline(id);
            e.Handled = true;
        };
        root.RightTapped += (s, e) => ShowTabContextMenu(vm, id, (FrameworkElement)s, e.GetPosition((FrameworkElement)s));

        return root;
    }

    private void ShowTabContextMenu(TimelineEditorViewModel vm, string id, FrameworkElement target, Windows.Foundation.Point position)
    {
        var flyout = new MenuFlyout();

        var rename = new MenuFlyoutItem { Text = "Rename" };
        rename.Click += (_, _) => { _renamingTabId = id; RefreshTabs(); };
        flyout.Items.Add(rename);

        var duplicate = new MenuFlyoutItem { Text = "Duplicate" };
        duplicate.Click += (_, _) => { vm.DuplicateTimeline(id); RefreshTabs(); };
        flyout.Items.Add(duplicate);

        flyout.Items.Add(new MenuFlyoutSeparator());

        var closeTab = new MenuFlyoutItem { Text = "Close Tab", IsEnabled = vm.OpenTimelineIds.Count > 1 };
        closeTab.Click += (_, _) => { vm.CloseTimelineTab(id); RefreshTabs(); };
        flyout.Items.Add(closeTab);

        var closeOthers = new MenuFlyoutItem { Text = "Close Other Tabs", IsEnabled = vm.OpenTimelineIds.Count > 1 };
        closeOthers.Click += (_, _) => { vm.CloseOtherTimelineTabs(id); RefreshTabs(); };
        flyout.Items.Add(closeOthers);

        flyout.Items.Add(new MenuFlyoutSeparator());

        var delete = new MenuFlyoutItem { Text = "Delete Timeline", IsEnabled = vm.Timelines.Count > 1 };
        delete.Click += (_, _) => { vm.DeleteTimeline(id); RefreshTabs(); };
        flyout.Items.Add(delete);

        flyout.ShowAt(target, position);
    }

    private void AllTimelinesButton_Click(object sender, RoutedEventArgs e)
    {
        if (_vm is not { } vm)
        {
            return;
        }
        var flyout = new MenuFlyout();
        foreach (var timeline in vm.Timelines)
        {
            var item = new MenuFlyoutItem
            {
                Text = timeline.Id == vm.ActiveTimelineId ? $"✓ {timeline.Name}" : timeline.Name,
            };
            var id = timeline.Id;
            item.Click += (_, _) => vm.ActivateTimeline(id);
            flyout.Items.Add(item);
        }
        flyout.ShowAt(AllTimelinesButton);
    }

    private void AddTabButton_Click(object sender, RoutedEventArgs e) => _vm?.CreateTimeline();
}
