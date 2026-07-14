using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using PalmierPro.App.Theme;
using PalmierPro.Core.Theme;

namespace PalmierPro.App.Views;

/// Empty-state "+" tile — ports HomeView.swift's private NewProjectCard as the primary create
/// affordance shown in place of the recents grid when there are no projects yet.
public sealed partial class NewProjectCard : UserControl
{
    public event EventHandler? CreateRequested;

    public NewProjectCard()
    {
        InitializeComponent();
        RootGrid.CornerRadius = AppTheme.UniformCornerRadius(AppThemeTokens.Radius.MdLg);
        GradientOverlay.Height = AppThemeTokens.ComponentSize.ProjectCardHeight * 0.5;
        NameText.Margin = AppTheme.ThicknessOf(AppThemeTokens.Spacing.Md, 0, AppThemeTokens.Spacing.Md, AppThemeTokens.Spacing.SmMd);
    }

    private void RootGrid_Tapped(object sender, TappedRoutedEventArgs e) => CreateRequested?.Invoke(this, EventArgs.Empty);
}
