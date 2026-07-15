using System.ComponentModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using PalmierPro.App.Theme;
using PalmierPro.App.ViewModels.MediaPanel;
using PalmierPro.Core.Interop;
using PalmierPro.Core.Theme;
using Windows.ApplicationModel.DataTransfer;
using Windows.System;

namespace PalmierPro.App.Views.MediaPanel;

/// Toolbar + breadcrumb + asset/folder grid for the Media tab. MVVM via CommunityToolkit.Mvvm —
/// the event handlers here are wiring (dialogs, drag-drop, context menus, DataContext plumbing),
/// not feature logic; every actual mutation goes through MediaTabViewModel.
public sealed partial class MediaTabView : UserControl
{
    private MediaTabViewModel? _viewModel;

    public MediaTabView()
    {
        InitializeComponent();

        // {StaticResource} values feeding Thickness/CornerRadius-typed properties don't coerce in
        // WinUI XAML the way literal strings do — every such value below is set here instead.
        Toolbar.Padding = AppTheme.UniformThickness(AppThemeTokens.Spacing.Sm);
        BreadcrumbList.Padding = AppTheme.UniformThickness(AppThemeTokens.Spacing.Sm);
        DropHighlight.BorderThickness = AppTheme.UniformThickness(AppThemeTokens.BorderWidth.Medium);
        DropHighlight.CornerRadius = AppTheme.UniformCornerRadius(AppThemeTokens.Radius.Md);
        DropHighlight.Margin = AppTheme.UniformThickness(AppThemeTokens.Spacing.Xs);
        ErrorBar.Margin = AppTheme.UniformThickness(AppThemeTokens.Spacing.Sm);
    }

    // Same {StaticResource}-into-Thickness limitation as the constructor above — GridViewItem
    // containers are generated per-item, so the tile margin is applied here instead of a Style Setter.
    private void MediaGridView_ContainerContentChanging(ListViewBase sender, ContainerContentChangingEventArgs args) =>
        args.ItemContainer.Margin = AppTheme.UniformThickness(AppThemeTokens.Spacing.Sm);

    public MediaTabViewModel? ViewModel
    {
        get => _viewModel;
        set
        {
            if (_viewModel is not null)
            {
                _viewModel.PropertyChanged -= OnViewModelPropertyChanged;
            }
            _viewModel = value;
            DataContext = value;
            if (_viewModel is not null)
            {
                _viewModel.PropertyChanged += OnViewModelPropertyChanged;
            }
            UpdateErrorBar();
            UpdateEmptyState();
        }
    }

    private void OnViewModelPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(MediaTabViewModel.LastError))
        {
            DispatcherQueue.TryEnqueue(UpdateErrorBar);
        }
        if (e.PropertyName == nameof(MediaTabViewModel.IsEmptyLibrary))
        {
            DispatcherQueue.TryEnqueue(UpdateEmptyState);
        }
    }

    private void UpdateErrorBar()
    {
        ErrorBar.IsOpen = _viewModel?.LastError is not null;
        ErrorBar.Message = _viewModel?.LastError ?? "";
    }

    private void UpdateEmptyState() =>
        EmptyStateText.Visibility = _viewModel?.IsEmptyLibrary == true ? Visibility.Visible : Visibility.Collapsed;

    private void ErrorBar_Closed(InfoBar sender, InfoBarClosedEventArgs args) =>
        _viewModel?.DismissErrorCommand.Execute(null);

    // MARK: - New folder / rename (both need a XamlRoot for ContentDialog, hence code-behind)

    private async void NewFolderButton_Click(object sender, RoutedEventArgs e)
    {
        if (ViewModel is not { } vm)
        {
            return;
        }
        var id = vm.CreateFolder();
        var name = await PromptForNameAsync("New Folder", "New Folder");
        if (name is not null)
        {
            vm.RenameFolder(id, name);
        }
    }

    private async Task<string?> PromptForNameAsync(string title, string suggested)
    {
        var textBox = new TextBox { Text = suggested };
        textBox.SelectAll();
        var dialog = new ContentDialog
        {
            Title = title,
            Content = textBox,
            PrimaryButtonText = "Save",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
            XamlRoot = XamlRoot,
        };
        var result = await dialog.ShowAsync();
        if (result != ContentDialogResult.Primary)
        {
            return null;
        }
        var trimmed = textBox.Text.Trim();
        return trimmed.Length == 0 ? null : trimmed;
    }

    // MARK: - Breadcrumb navigation

    private void BreadcrumbItem_Click(object sender, RoutedEventArgs e)
    {
        if (ViewModel is not { } vm)
        {
            return;
        }
        var folderId = (sender as FrameworkElement)?.Tag as string;
        vm.NavigateToFolder(folderId);
    }

    // MARK: - Folder tile interaction

    private void FolderTile_DoubleTapped(object sender, DoubleTappedRoutedEventArgs e)
    {
        if (ViewModel is not { } vm || (sender as FrameworkElement)?.DataContext is not MediaFolderItemViewModel item)
        {
            return;
        }
        vm.OpenFolder(item.Id);
    }

    private void FolderTile_RightTapped(object sender, RightTappedRoutedEventArgs e)
    {
        if (ViewModel is not { } vm || (sender as FrameworkElement)?.DataContext is not MediaFolderItemViewModel item)
        {
            return;
        }
        var flyout = new MenuFlyout();
        var open = new MenuFlyoutItem { Text = "Open" };
        open.Click += (_, _) => vm.OpenFolder(item.Id);
        var rename = new MenuFlyoutItem { Text = "Rename…" };
        rename.Click += async (_, _) =>
        {
            var name = await PromptForNameAsync("Rename Folder", item.Name);
            if (name is not null)
            {
                vm.RenameFolder(item.Id, name);
            }
        };
        var delete = new MenuFlyoutItem { Text = "Delete" };
        delete.Click += (_, _) => vm.DeleteFolders(SelectedFolderIdsOrSingle(item.Id));
        flyout.Items.Add(open);
        flyout.Items.Add(rename);
        flyout.Items.Add(delete);
        flyout.ShowAt((FrameworkElement)sender, e.GetPosition((FrameworkElement)sender));
    }

    private List<string> SelectedFolderIdsOrSingle(string id)
    {
        var selected = MediaGridView.SelectedItems.OfType<MediaFolderItemViewModel>().Select(f => f.Id).ToList();
        return selected.Contains(id) ? selected : [id];
    }

    // MARK: - Asset tile interaction

    // Mirrors FolderTile_DoubleTapped's shape — opens the source preview instead of navigating.
    private void AssetTile_DoubleTapped(object sender, DoubleTappedRoutedEventArgs e)
    {
        if (ViewModel is not { } vm || (sender as FrameworkElement)?.DataContext is not MediaAssetItemViewModel item)
        {
            return;
        }
        vm.OpenAsset(item.Id);
    }

    private void AssetTile_RightTapped(object sender, RightTappedRoutedEventArgs e)
    {
        if (ViewModel is not { } vm || (sender as FrameworkElement)?.DataContext is not MediaAssetItemViewModel item)
        {
            return;
        }
        var flyout = new MenuFlyout();
        var rename = new MenuFlyoutItem { Text = "Rename…" };
        rename.Click += async (_, _) =>
        {
            var name = await PromptForNameAsync("Rename Asset", item.Name);
            if (name is not null)
            {
                vm.RenameAsset(item.Id, name);
            }
        };
        var delete = new MenuFlyoutItem { Text = "Delete" };
        delete.Click += (_, _) => vm.DeleteAssets(SelectedAssetIdsOrSingle(item.Id));
        flyout.Items.Add(rename);
        flyout.Items.Add(delete);
        flyout.ShowAt((FrameworkElement)sender, e.GetPosition((FrameworkElement)sender));
    }

    private List<string> SelectedAssetIdsOrSingle(string id)
    {
        var selected = MediaGridView.SelectedItems.OfType<MediaAssetItemViewModel>().Select(a => a.Id).ToList();
        return selected.Contains(id) ? selected : [id];
    }

    private void MediaGridView_KeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (ViewModel is not { } vm || e.Key != VirtualKey.Delete)
        {
            return;
        }
        var assetIds = MediaGridView.SelectedItems.OfType<MediaAssetItemViewModel>().Select(a => a.Id).ToList();
        var folderIds = MediaGridView.SelectedItems.OfType<MediaFolderItemViewModel>().Select(f => f.Id).ToList();
        if (assetIds.Count > 0)
        {
            vm.DeleteAssets(assetIds);
        }
        if (folderIds.Count > 0)
        {
            vm.DeleteFolders(folderIds);
        }
        e.Handled = true;
    }

    // MARK: - Drag OUT — asset selection to a "PalmierPro.ClipRef" payload (Stage C timeline consumes it)

    private void MediaGridView_DragItemsStarting(object sender, DragItemsStartingEventArgs e)
    {
        var assetIds = e.Items.OfType<MediaAssetItemViewModel>().Select(a => a.Id).ToList();
        if (assetIds.Count == 0)
        {
            e.Cancel = true;
            return;
        }
        e.Data.SetData(ClipRefDragFormat.FormatId, ClipRefDragFormat.Serialize(assetIds));
        e.Data.RequestedOperation = DataPackageOperation.Copy;
    }

    // MARK: - Drag IN from Explorer

    private void MediaGridView_DragOver(object sender, DragEventArgs e)
    {
        if (e.DataView.Contains(StandardDataFormats.StorageItems))
        {
            e.AcceptedOperation = DataPackageOperation.Copy;
            e.DragUIOverride.Caption = "Import";
            DropHighlight.Visibility = Visibility.Visible;
        }
        else
        {
            e.AcceptedOperation = DataPackageOperation.None;
        }
        e.Handled = true;
    }

    private void MediaGridView_DragLeave(object sender, DragEventArgs e) => DropHighlight.Visibility = Visibility.Collapsed;

    private async void MediaGridView_Drop(object sender, DragEventArgs e)
    {
        DropHighlight.Visibility = Visibility.Collapsed;
        e.Handled = true;
        if (ViewModel is not { } vm || !e.DataView.Contains(StandardDataFormats.StorageItems))
        {
            return;
        }
        var deferral = e.GetDeferral();
        try
        {
            var items = await e.DataView.GetStorageItemsAsync();
            var paths = items.Select(i => i.Path).Where(p => !string.IsNullOrEmpty(p)).ToList();
            if (paths.Count > 0)
            {
                await vm.ImportPathsAsync(paths);
            }
        }
        finally
        {
            deferral.Complete();
        }
    }
}
