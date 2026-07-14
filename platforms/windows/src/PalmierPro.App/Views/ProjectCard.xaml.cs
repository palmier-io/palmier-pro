using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using PalmierPro.App.Theme;
using PalmierPro.Core.Theme;
using PalmierPro.Services.Project;

namespace PalmierPro.App.Views;

/// One recent-project tile. Ports ProjectCard.swift's layout (thumbnail-or-icon, bottom gradient
/// + label, hover trash button) minus the thumbnail image itself (no thumbnail-decoding pipeline
/// exists yet — E1, next stage) and minus the context menu / delete-to-Recycle-Bin flow (kept to
/// "Remove from Recents" for M1; Reveal-in-Explorer and hard delete land with the media/export
/// stages that actually need Explorer/shell interop).
public sealed partial class ProjectCard : UserControl
{
    public event EventHandler<ProjectEntry>? OpenRequested;
    public event EventHandler<ProjectEntry>? RemoveRequested;

    private static readonly SolidColorBrush WhiteBrush = new(Colors.White);

    public ProjectCard()
    {
        InitializeComponent();
        RootGrid.CornerRadius = AppTheme.UniformCornerRadius(AppThemeTokens.Radius.MdLg);
        GradientOverlay.Height = AppThemeTokens.ComponentSize.ProjectCardHeight * 0.5;
        LabelStack.Padding = AppTheme.ThicknessOf(AppThemeTokens.Spacing.Md, 0, AppThemeTokens.Spacing.Md, AppThemeTokens.Spacing.SmMd);
        RemoveButton.Margin = AppTheme.UniformThickness(AppThemeTokens.Spacing.Xs);
        DataContextChanged += (_, _) => ApplyAccessibilityState();
    }

    private ProjectEntry? Entry => DataContext as ProjectEntry;

    /// GridView recycles item containers, so a card's DataContext can be repointed at a
    /// different (possibly now-inaccessible) entry without this control being reconstructed.
    private void ApplyAccessibilityState()
    {
        bool accessible = Entry?.IsAccessible ?? true;
        // Mirrors ProjectCard.swift's own inline 0.6 (not routed through AppTheme.Opacity there
        // either — see #99000000 on InaccessibleOverlay in the .xaml).
        RootGrid.Opacity = accessible ? 1.0 : 0.6;
        InaccessibleOverlay.Visibility = accessible ? Visibility.Collapsed : Visibility.Visible;
        NameText.Foreground = accessible ? WhiteBrush : AppTheme.Text.MutedBrush;
    }

    private void RootGrid_PointerEntered(object sender, PointerRoutedEventArgs e) => RemoveButton.Visibility = Visibility.Visible;

    private void RootGrid_PointerExited(object sender, PointerRoutedEventArgs e) => RemoveButton.Visibility = Visibility.Collapsed;

    private void RootGrid_Tapped(object sender, TappedRoutedEventArgs e)
    {
        if (Entry is { IsAccessible: true } entry)
        {
            OpenRequested?.Invoke(this, entry);
        }
    }

    private void RemoveButton_Click(object sender, RoutedEventArgs e)
    {
        if (Entry is { } entry)
        {
            RemoveRequested?.Invoke(this, entry);
        }
    }
}
