using Microsoft.UI.Xaml;
using PalmierPro.App.ViewModels.MediaPanel;
using PalmierPro.Services;
using WinRT.Interop;
using Windows.Storage.Pickers;

namespace PalmierPro.App.Services;

/// FileOpenPicker-backed IMediaImportDialogService — ports the file leg of MediaTab.importMedia's
/// NSOpenPanel (video/audio/image/Lottie types). Windows pickers can't mix file- and folder-picking
/// in one dialog the way NSOpenPanel's canChooseDirectories does, so directory import is left to
/// Explorer drag-drop (MediaImportService.ImportAsync already expands directories recursively).
public sealed class MediaImportDialogService(Window window) : IMediaImportDialogService
{
    private static readonly string[] Extensions =
    [
        ".mov", ".mp4", ".m4v",
        ".mp3", ".wav", ".aac", ".m4a", ".aiff", ".aif", ".aifc", ".flac",
        ".png", ".jpg", ".jpeg", ".tiff", ".heic", ".webp",
        ".json", ".lottie",
    ];

    public async Task<IReadOnlyList<string>?> PickMediaFilesAsync()
    {
        if (AutomationMode.Enabled)
        {
            return AutomationMode.NextImportFiles();
        }
        var picker = new FileOpenPicker { SuggestedStartLocation = PickerLocationId.VideosLibrary };
        foreach (var ext in Extensions)
        {
            picker.FileTypeFilter.Add(ext);
        }
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(window));
        var files = await picker.PickMultipleFilesAsync();
        return files.Count == 0 ? null : [.. files.Select(f => f.Path)];
    }
}
