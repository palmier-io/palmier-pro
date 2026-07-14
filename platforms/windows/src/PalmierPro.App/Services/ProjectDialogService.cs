using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using PalmierPro.App.ViewModels;
using WinRT.Interop;
using Windows.Storage.Pickers;

namespace PalmierPro.App.Services;

/// Windows.Storage picker-backed IProjectDialogService — ports the NSSavePanel/NSOpenPanel flows
/// in AppState.createProjectInteractively/openProjectFromPanel. A .palmier package is a directory
/// on Windows (no UTType-package concept), so both flows resolve to a folder pick; "new project"
/// additionally prompts for a name via ContentDialog since FolderPicker has no save-style name
/// field the way NSSavePanel does.
public sealed class ProjectDialogService(Window window) : IProjectDialogService
{
    public async Task<(string Directory, string Name)?> PickProjectLocationAsync(string suggestedName)
    {
        var folder = await PickFolderAsync();
        if (folder is null)
        {
            return null;
        }
        var name = await PromptForNameAsync(suggestedName);
        return name is null ? null : (folder, name);
    }

    public Task<string?> PickExistingProjectPathAsync() => PickFolderAsync();

    private async Task<string?> PickFolderAsync()
    {
        var picker = new FolderPicker { SuggestedStartLocation = PickerLocationId.DocumentsLibrary };
        picker.FileTypeFilter.Add("*");
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(window));
        var folder = await picker.PickSingleFolderAsync();
        return folder?.Path;
    }

    private async Task<string?> PromptForNameAsync(string suggestedName)
    {
        var textBox = new TextBox { Text = suggestedName };
        textBox.SelectAll();
        var dialog = new ContentDialog
        {
            Title = "New Project",
            Content = textBox,
            PrimaryButtonText = "Create",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
            XamlRoot = window.Content.XamlRoot,
        };
        var result = await dialog.ShowAsync();
        if (result != ContentDialogResult.Primary)
        {
            return null;
        }
        var trimmed = textBox.Text.Trim();
        return trimmed.Length == 0 ? suggestedName : trimmed;
    }
}
