namespace PalmierPro.App.ViewModels;

/// Picker seam ShellViewModel depends on instead of Windows.Storage directly, so it stays
/// instantiable (and testable) without a WinUI window. The real implementation
/// (Services/ProjectDialogService.cs) wraps FolderPicker + InitializeWithWindow.
public interface IProjectDialogService
{
    /// Ports the combined folder+name step of NSSavePanel (New/Save As). Packages are directories
    /// on Windows, not single files, so this is a folder pick plus a name prompt rather than one
    /// native save dialog.
    Task<(string Directory, string Name)?> PickProjectLocationAsync(string suggestedName);

    /// Ports NSOpenPanel with canChooseDirectories=false, treatsFilePackagesAsDirectories=false:
    /// on Mac a .palmier is a selectable file-like bundle; on Windows it's a plain directory, so
    /// the user picks the package's own folder.
    Task<string?> PickExistingProjectPathAsync();
}
