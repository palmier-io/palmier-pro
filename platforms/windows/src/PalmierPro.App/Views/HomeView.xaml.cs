using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using PalmierPro.App.Theme;
using PalmierPro.App.ViewModels;
using PalmierPro.Core.Theme;
using PalmierPro.Services.Project;

namespace PalmierPro.App.Views;

/// Ports HomeView.swift's structure: welcome header, New/Open actions, recent-project grid with
/// an empty state (a clickable NewProjectCard tile, matching Mac). Mac splits New/Open between a
/// left sidebar (also carrying sign-in/Settings, both Phase 2/account-system dependent) and the
/// empty-grid tile; this collapses both to one action row since a left rail isn't load-bearing
/// without those account features. SampleProjectsStrip is deliberately not ported yet — no
/// bundled sample content exists on this platform to back it.
public sealed partial class HomeView : UserControl
{
    public HomeViewModel? ViewModel { get; private set; }

    public HomeView()
    {
        InitializeComponent();
        RootBorder.Padding = AppTheme.UniformThickness(AppThemeTokens.Spacing.XlXxl);
    }

    public void Initialize(HomeViewModel viewModel)
    {
        ViewModel = viewModel;
        Bindings.Update();
    }

    public Visibility EmptyStateVisibility(int count) => count == 0 ? Visibility.Visible : Visibility.Collapsed;

    public Visibility GridVisibility(int count) => count == 0 ? Visibility.Collapsed : Visibility.Visible;

    private void NewProjectButton_Click(object sender, RoutedEventArgs e) => ViewModel?.NewProjectCommand.Execute(null);

    private void NewProjectCard_CreateRequested(object sender, EventArgs e) => ViewModel?.NewProjectCommand.Execute(null);

    private void OpenProjectButton_Click(object sender, RoutedEventArgs e) => ViewModel?.OpenProjectCommand.Execute(null);

    private void ProjectCard_OpenRequested(object sender, ProjectEntry entry) => ViewModel?.OpenEntryCommand.Execute(entry);

    private void ProjectCard_RemoveRequested(object sender, ProjectEntry entry) => ViewModel?.RemoveEntryCommand.Execute(entry);
}
