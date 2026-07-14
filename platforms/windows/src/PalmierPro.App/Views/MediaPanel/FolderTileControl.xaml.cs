using System.ComponentModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using PalmierPro.App.Theme;
using PalmierPro.App.ViewModels.MediaPanel;
using PalmierPro.Core.Theme;

namespace PalmierPro.App.Views.MediaPanel;

public sealed partial class FolderTileControl : UserControl
{
    private MediaFolderItemViewModel? _item;

    public FolderTileControl()
    {
        InitializeComponent();
        DataContextChanged += OnDataContextChanged;
        Unloaded += (_, _) => Detach();

        // {StaticResource} values feeding Thickness/CornerRadius-typed properties don't coerce in
        // WinUI XAML the way literal strings do — every such value below is set here instead.
        ArtworkArea.CornerRadius = AppTheme.UniformCornerRadius(AppThemeTokens.Radius.Sm);
        CountBadge.CornerRadius = AppTheme.UniformCornerRadius(AppThemeTokens.Radius.Xs);
        CountBadge.Padding = AppTheme.UniformThickness(AppThemeTokens.Spacing.Xs);
        CountBadge.Margin = AppTheme.UniformThickness(AppThemeTokens.Spacing.Xs);
    }

    private void OnDataContextChanged(FrameworkElement sender, DataContextChangedEventArgs args)
    {
        Detach();
        _item = args.NewValue as MediaFolderItemViewModel;
        if (_item is null)
        {
            return;
        }
        _item.PropertyChanged += OnItemPropertyChanged;
        Render();
    }

    private void Detach()
    {
        if (_item is null)
        {
            return;
        }
        _item.PropertyChanged -= OnItemPropertyChanged;
        _item = null;
    }

    private void OnItemPropertyChanged(object? sender, PropertyChangedEventArgs e) =>
        DispatcherQueue.TryEnqueue(Render);

    private void Render()
    {
        if (_item is null)
        {
            return;
        }
        NameText.Text = _item.Name;
        CountBadge.Visibility = _item.ChildCount > 0 ? Visibility.Visible : Visibility.Collapsed;
        CountText.Text = _item.ChildCount.ToString();
    }
}
