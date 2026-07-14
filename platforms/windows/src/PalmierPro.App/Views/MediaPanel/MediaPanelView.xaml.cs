using Microsoft.UI.Xaml.Controls;
using PalmierPro.App.Theme;
using PalmierPro.App.ViewModels.MediaPanel;
using PalmierPro.Core.Theme;

namespace PalmierPro.App.Views.MediaPanel;

public sealed partial class MediaPanelView : UserControl
{
    public MediaPanelView()
    {
        InitializeComponent();
        // {StaticResource} values feeding Thickness/CornerRadius-typed properties don't coerce in
        // WinUI XAML the way literal strings do — every such value below is set here instead.
        TabRail.Padding = AppTheme.UniformThickness(AppThemeTokens.Spacing.Sm);
    }

    public void SetViewModel(MediaTabViewModel? viewModel) => MediaTabContent.ViewModel = viewModel;

    public Task RequestImportAsync() =>
        MediaTabContent.ViewModel?.ImportCommand.ExecuteAsync(null) ?? Task.CompletedTask;
}
