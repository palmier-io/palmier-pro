using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using PalmierPro.App.ViewModels;
using PalmierPro.Services;
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
        if (AutomationMode.Enabled)
        {
            var path = AutomationMode.NextSavePath();
            var directory = string.IsNullOrEmpty(path) ? null : Path.GetDirectoryName(path);
            var name = string.IsNullOrEmpty(path) ? null : Path.GetFileName(path);
            return string.IsNullOrEmpty(directory) || string.IsNullOrEmpty(name) ? null : (directory, name);
        }
        var folder = await PickFolderAsync();
        if (folder is null)
        {
            return null;
        }
        var promptedName = await PromptForNameAsync(suggestedName);
        return promptedName is null ? null : (folder, promptedName);
    }

    public Task<string?> PickExistingProjectPathAsync() =>
        AutomationMode.Enabled ? Task.FromResult(AutomationMode.NextOpenProjectPath()) : PickFolderAsync();

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
