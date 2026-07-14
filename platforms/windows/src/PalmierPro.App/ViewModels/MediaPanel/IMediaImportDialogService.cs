namespace PalmierPro.App.ViewModels.MediaPanel;

/// Picker seam MediaTabViewModel depends on instead of Windows.Storage.Pickers directly — mirrors
/// IProjectDialogService's rationale, keeping the ViewModel instantiable under plain `dotnet test`.
public interface IMediaImportDialogService
{
    /// Null means the user cancelled; an empty list never happens (the picker returns null instead).
    Task<IReadOnlyList<string>?> PickMediaFilesAsync();
}
