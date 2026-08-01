using System.Diagnostics;
using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using PalmierPro.App.Editor;
using PalmierPro.App.Theme;
using PalmierPro.Core;
using Windows.Storage.Pickers;

namespace PalmierPro.App.Home;

public sealed partial class HomeWindow : Window
{
    public HomeViewModel ViewModel { get; } = new();

    public HomeWindow()
    {
        InitializeComponent();
        Title = "Palmier Pro";
        ConfigureWindow();
        _ = ViewModel.LoadAsync();
    }

    private void ConfigureWindow()
    {
        AppWindow.Resize(new Windows.Graphics.SizeInt32(
            (int)AppTheme.Window.HomeDefaultWidth,
            (int)AppTheme.Window.HomeDefaultHeight));
        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.PreferredMinimumWidth = (int)AppTheme.Window.HomeMinWidth;
            presenter.PreferredMinimumHeight = (int)AppTheme.Window.HomeMinHeight;
        }
        AppWindow.TitleBar.ExtendsContentIntoTitleBar = true;
        AppWindow.TitleBar.ButtonBackgroundColor = Colors.Transparent;
        AppWindow.TitleBar.ButtonInactiveBackgroundColor = Colors.Transparent;
    }

    private async void OnNewProject(object sender, RoutedEventArgs e)
    {
        try
        {
            var path = await ViewModel.CreateProjectAsync();
            OpenProject(path);
        }
        catch (Exception ex)
        {
            await ShowErrorAsync("Couldn't create project", ex.Message);
        }
    }

    private async void OnOpenProject(object sender, RoutedEventArgs e)
    {
        var picker = new FolderPicker { SuggestedStartLocation = PickerLocationId.DocumentsLibrary };
        picker.FileTypeFilter.Add("*");
        WinRT.Interop.InitializeWithWindow.Initialize(
            picker, WinRT.Interop.WindowNative.GetWindowHandle(this));

        var folder = await picker.PickSingleFolderAsync();
        if (folder is null) return;

        var projectJson = Path.Combine(folder.Path, ProjectConstants.TimelineFilename);
        if (!File.Exists(projectJson))
        {
            await ShowErrorAsync(
                "Not a Palmier project",
                $"The folder doesn't contain {ProjectConstants.TimelineFilename}. Choose a .{ProjectConstants.FileExtension} package.");
            return;
        }

        await ViewModel.RegisterAndRefreshAsync(folder.Path);
        OpenProject(folder.Path);
    }

    private void OnProjectClicked(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is ProjectCardViewModel card && card.IsAccessible)
        {
            _ = ViewModel.RegisterAndRefreshAsync(card.Path);
            OpenProject(card.Path);
        }
    }

    private void OnCardOpen(object sender, RoutedEventArgs e)
    {
        if (CardFrom(sender) is { IsAccessible: true } card)
        {
            _ = ViewModel.RegisterAndRefreshAsync(card.Path);
            OpenProject(card.Path);
        }
    }

    private void OnCardReveal(object sender, RoutedEventArgs e)
    {
        if (CardFrom(sender) is { } card && (Directory.Exists(card.Path) || File.Exists(card.Path)))
        {
            Process.Start("explorer.exe", $"/select,\"{card.Path}\"");
        }
    }

    private async void OnCardRemove(object sender, RoutedEventArgs e)
    {
        if (CardFrom(sender) is { } card)
        {
            await ViewModel.RemoveFromRecentsAsync(card);
        }
    }

    private async void OnCardDelete(object sender, RoutedEventArgs e)
    {
        if (CardFrom(sender) is not { } card) return;

        var dialog = new ContentDialog
        {
            Title = "Delete Project",
            Content = $"Delete \u201c{card.Name}\u201d? This removes the project package from disk.",
            PrimaryButtonText = "Delete",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Close,
            XamlRoot = Content.XamlRoot,
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;

        var result = await ViewModel.DeleteAsync(card);
        if (result.FailedNames.Count > 0)
        {
            await ShowErrorAsync("Couldn't delete", string.Join(", ", result.FailedNames));
        }
    }

    private async void OnSettings(object sender, RoutedEventArgs e)
    {
        var dialog = new ContentDialog
        {
            Title = "Settings",
            Content = "Settings arrive in a later phase of the Windows port.",
            CloseButtonText = "OK",
            XamlRoot = Content.XamlRoot,
        };
        await dialog.ShowAsync();
    }

    private void OpenProject(string path)
    {
        var window = new ProjectWindow(path);
        window.Activate();
    }

    private static ProjectCardViewModel? CardFrom(object sender)
        => (sender as FrameworkElement)?.Tag as ProjectCardViewModel;

    private async Task ShowErrorAsync(string title, string message)
    {
        var dialog = new ContentDialog
        {
            Title = title,
            Content = message,
            CloseButtonText = "OK",
            XamlRoot = Content.XamlRoot,
        };
        await dialog.ShowAsync();
    }
}
