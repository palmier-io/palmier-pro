using System.Diagnostics;
using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using PalmierPro.App.Editor;
using PalmierPro.App.Theme;
using System.Collections.ObjectModel;
using PalmierPro.Cloud;
using PalmierPro.Cloud.Account;
using PalmierPro.Cloud.Samples;
using PalmierPro.Core;
using PalmierPro.Core.Localization;
using Windows.Storage.Pickers;

namespace PalmierPro.App.Home;

public sealed partial class HomeWindow : Window
{
    public HomeViewModel ViewModel { get; } = new();
    private bool _closed;

    public HomeWindow()
    {
        InitializeComponent();
        AppAppearanceController.Track(this);
        Title = "Palmier Pro";
        ConfigureWindow();
        AccountService.Shared.Changed += RefreshAccountLabel;
        Closed += (_, _) =>
        {
            _closed = true;
            AccountService.Shared.Changed -= RefreshAccountLabel;
        };
        RefreshAccountLabel();
        ApplyLocalizedChrome();
        _ = ViewModel.LoadAsync();
        _ = LoadSamplesAsync();
        if (AccountService.Shared.IsSignedIn)
            _ = AccountService.Shared.RefreshAccountAsync();
    }

    private void ApplyLocalizedChrome()
    {
        WelcomeText.Text = L10n.String("home.welcome");
        SampleProjectsHeader.Text = L10n.String("home.sampleProjects");
        MyProjectsHeader.Text = L10n.String("home.myProjects");
        NewProjectLabel.Text = L10n.String("home.newProject");
        OpenProjectLabel.Text = L10n.String("home.openProject");
        SettingsLabel.Text = L10n.String("home.settings");
        EmptyProjectsText.Text = L10n.String("home.noProjects");
        EmptyProjectsHint.Text = L10n.String("home.noProjectsHint");
        AccountLabel.Text = L10n.String("home.account");
    }

    private readonly ObservableCollection<SampleCardViewModel> _samples = [];

    private void ConfigureWindow()
    {
        try
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
        catch
        {
            // Pre-HWND AppWindow configure can throw on some hosts.
        }
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
        try
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
        catch (Exception ex)
        {
            await ShowErrorAsync("Couldn't open project", ex.Message);
        }
    }

    private void OnProjectClicked(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is ProjectCardViewModel card && card.IsAccessible)
            _ = OpenRegisteredProjectAsync(card.Path);
    }

    private void OnCardOpen(object sender, RoutedEventArgs e)
    {
        if (CardFrom(sender) is { IsAccessible: true } card)
            _ = OpenRegisteredProjectAsync(card.Path);
    }

    private async Task OpenRegisteredProjectAsync(string path)
    {
        try
        {
            await ViewModel.RegisterAndRefreshAsync(path);
            OpenProject(path);
        }
        catch (Exception ex)
        {
            await ShowErrorAsync("Couldn't open project", ex.Message);
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
            CloseButtonText = L10n.String("common.cancel"),
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

    private async void OnAccount(object sender, RoutedEventArgs e)
    {
        var account = AccountService.Shared;
        var status = new TextBlock
        {
            TextWrapping = TextWrapping.Wrap,
            Text = account.IsSignedIn
                ? $"{account.Account?.DisplayName ?? "Signed in"}\n{account.RemainingCredits:0} credits · {account.Account?.Tier}"
                : BackendConfig.IsConfigured
                    ? "Signed out. Sign in with Google, or paste a Clerk session token for local testing."
                    : "Cloud backend not configured. Set PALMIER_CLERK_PUBLISHABLE_KEY, PALMIER_CONVEX_DEPLOYMENT_URL, PALMIER_CONVEX_HTTP_URL.",
        };
        var tokenBox = new TextBox
        {
            PlaceholderText = "Dev bearer token",
            Visibility = account.IsSignedIn ? Visibility.Collapsed : Visibility.Visible,
        };
        var panel = new StackPanel { Spacing = 12, Children = { status, tokenBox } };

        var dialog = new ContentDialog
        {
            Title = "Account",
            Content = panel,
            PrimaryButtonText = account.IsSignedIn ? "Sign Out" : "Use Dev Token",
            SecondaryButtonText = account.IsSignedIn ? "Refresh" : "Sign In with Google",
            CloseButtonText = L10n.String("common.close"),
            DefaultButton = ContentDialogButton.Close,
            XamlRoot = Content.XamlRoot,
        };
        var result = await dialog.ShowAsync();
        if (result == ContentDialogResult.Primary)
        {
            if (account.IsSignedIn) account.SignOut();
            else if (!string.IsNullOrWhiteSpace(tokenBox.Text))
            {
                account.SignInWithDevToken(tokenBox.Text.Trim());
                await account.RefreshAccountAsync();
            }
        }
        else if (result == ContentDialogResult.Secondary)
        {
            if (account.IsSignedIn)
            {
                await account.RefreshAccountAsync();
                if (account.LastError is { } refreshErr)
                    await ShowErrorAsync("Account", refreshErr);
            }
            else
            {
                await account.SignInWithGoogleAsync();
                if (account.LastError is { } err)
                    await ShowErrorAsync("Sign in", err);
            }
        }
        await LoadSamplesAsync();
    }

    private async Task LoadSamplesAsync()
    {
        if (!BackendConfig.IsConfigured && BackendConfig.ConvexHttpUrl is null)
        {
            SamplesPanel.Visibility = Visibility.Collapsed;
            return;
        }

        try
        {
            var list = await SampleProjectClient.Shared.ListAsync();
            _samples.Clear();
            foreach (var s in list)
                _samples.Add(new SampleCardViewModel { Slug = s.Slug, Title = s.Title });
            SamplesList.ItemsSource = _samples;
            SamplesPanel.Visibility = _samples.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        }
        catch
        {
            SamplesPanel.Visibility = Visibility.Collapsed;
        }
    }

    private async void OnSampleClicked(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is not SampleCardViewModel sample) return;
        var progress = new ProgressBar { IsIndeterminate = true };
        var dialog = new ContentDialog
        {
            Title = $"Opening “{sample.Title}”",
            Content = progress,
            XamlRoot = Content.XamlRoot,
        };
        var show = dialog.ShowAsync();
        try
        {
            var path = await SampleProjectClient.Shared.MaterializeAsync(sample.Slug);
            dialog.Hide();
            await ViewModel.RegisterAndRefreshAsync(path);
            OpenProject(path);
        }
        catch (Exception ex)
        {
            try { dialog.Hide(); } catch { /* already closed */ }
            await ShowErrorAsync("Sample project", ex.Message);
        }
        // Do not Cancel() after Hide() — WinUI ContentDialog double-completes.
        _ = show;
    }

    private void RefreshAccountLabel()
    {
        if (_closed) return;
        DispatcherQueue.TryEnqueue(() =>
        {
            if (_closed) return;
            var account = AccountService.Shared;
            AccountLabel.Text = account.IsSignedIn
                ? L10n.String(
                    "home.accountSignedIn",
                    account.Account?.DisplayName ?? L10n.String("home.account"),
                    account.RemainingCredits.ToString("0"))
                : L10n.String("home.account");
        });
    }

    private void OnSettings(object sender, RoutedEventArgs e)
    {
        try
        {
            var window = new Settings.SettingsWindow();
            window.Activate();
        }
        catch (Exception ex)
        {
            _ = ShowErrorAsync("Settings", ex.Message);
        }
    }

    private void OpenProject(string path)
    {
        try
        {
            var window = new ProjectWindow(path);
            window.Activate();
        }
        catch (Exception ex)
        {
            try { App.WriteCrashLog(ex); } catch { /* best-effort */ }
            _ = ShowErrorAsync("Couldn't open project", ex.Message);
        }
    }

    private static ProjectCardViewModel? CardFrom(object sender)
        => (sender as FrameworkElement)?.Tag as ProjectCardViewModel;

    private async Task ShowErrorAsync(string title, string message)
    {
        var dialog = new ContentDialog
        {
            Title = title,
            Content = message,
            CloseButtonText = L10n.String("common.ok"),
            XamlRoot = Content.XamlRoot,
        };
        await dialog.ShowAsync();
    }
}
