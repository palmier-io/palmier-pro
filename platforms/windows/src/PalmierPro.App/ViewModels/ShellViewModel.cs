using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using PalmierPro.Core.Undo;
using PalmierPro.Services.Project;

namespace PalmierPro.App.ViewModels;

/// AppState-equivalent: owns navigation (Home vs. the one open project — Phase 1 is
/// single-window, see the Windows port plan) and the File/Edit menu commands. No WinUI types, so
/// it's testable under plain `dotnet test`; the picker UI lives behind IProjectDialogService.
public sealed partial class ShellViewModel : ObservableObject
{
    public ProjectRegistry Registry { get; }

    private readonly IProjectDialogService _dialogs;
    private UndoService? _wiredUndoService;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(IsEditorOpen))]
    [NotifyPropertyChangedFor(nameof(WindowTitle))]
    [NotifyCanExecuteChangedFor(nameof(SaveCommand))]
    [NotifyCanExecuteChangedFor(nameof(SaveAsCommand))]
    [NotifyCanExecuteChangedFor(nameof(UndoCommand))]
    [NotifyCanExecuteChangedFor(nameof(RedoCommand))]
    public partial ProjectDocument? ActiveDocument { get; set; }

    public bool IsEditorOpen => ActiveDocument is not null;

    public string WindowTitle => ActiveDocument?.DisplayName ?? "Palmier Pro";

    public string UndoMenuText => MenuText("Undo", ActiveDocument?.UndoService.UndoActionName);

    public string RedoMenuText => MenuText("Redo", ActiveDocument?.UndoService.RedoActionName);

    /// MainWindow maps this to Application.Current.Exit() — kept out of this class so it stays
    /// WinUI-free.
    public event EventHandler? RequestQuit;

    public ShellViewModel(ProjectRegistry registry, IProjectDialogService dialogs)
    {
        Registry = registry;
        _dialogs = dialogs;
    }

    partial void OnActiveDocumentChanged(ProjectDocument? value)
    {
        if (_wiredUndoService is not null)
        {
            _wiredUndoService.Changed -= OnUndoChanged;
        }
        _wiredUndoService = value?.UndoService;
        if (_wiredUndoService is not null)
        {
            _wiredUndoService.Changed += OnUndoChanged;
        }
        OnPropertyChanged(nameof(UndoMenuText));
        OnPropertyChanged(nameof(RedoMenuText));
    }

    private void OnUndoChanged(object? sender, EventArgs e)
    {
        OnPropertyChanged(nameof(UndoMenuText));
        OnPropertyChanged(nameof(RedoMenuText));
        UndoCommand.NotifyCanExecuteChanged();
        RedoCommand.NotifyCanExecuteChanged();
    }

    private static string MenuText(string verb, string? actionName) =>
        string.IsNullOrEmpty(actionName) ? verb : $"{verb} {actionName}";

    /// Ports AppState.createProject(named:) — validation lives in ProjectDocument.CreateNewAsync.
    public async Task<ProjectDocument> CreateProjectAsync(string directory, string name)
    {
        var doc = await ProjectDocument.CreateNewAsync(directory, name);
        Registry.Register(doc.PackagePath);
        ActiveDocument = doc;
        return doc;
    }

    /// Ports AppState.openProjectAsync — re-activates the already-open document instead of
    /// re-reading it from disk (Phase 1 has exactly one document, but the path still matters for
    /// idempotent re-opens from the recents grid).
    public async Task<ProjectDocument> OpenProjectAtAsync(string packagePath)
    {
        if (ActiveDocument is { } current && PathsEqual(current.PackagePath, packagePath))
        {
            Registry.Register(packagePath);
            return current;
        }
        var doc = await ProjectDocument.OpenAsync(packagePath);
        Registry.Register(packagePath);
        ActiveDocument = doc;
        return doc;
    }

    /// Ports AppState.showHome(): registers the departing project's last-opened time and clears
    /// the active document. Phase 1 has no other open document to fall back to (single window).
    public void ShowHome()
    {
        if (ActiveDocument is { } doc)
        {
            Registry.Register(doc.PackagePath);
        }
        ActiveDocument = null;
    }

    private static bool PathsEqual(string a, string b) =>
        string.Equals(
            Path.GetFullPath(a).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar),
            Path.GetFullPath(b).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar),
            StringComparison.OrdinalIgnoreCase);

    [RelayCommand]
    private async Task NewAsync()
    {
        var location = await _dialogs.PickProjectLocationAsync(ProjectPackage.DefaultProjectName);
        if (location is null)
        {
            return;
        }
        await CreateProjectAsync(location.Value.Directory, location.Value.Name);
    }

    [RelayCommand]
    private async Task OpenAsync()
    {
        var path = await _dialogs.PickExistingProjectPathAsync();
        if (path is null)
        {
            return;
        }
        await OpenProjectAtAsync(path);
    }

    private bool CanSave() => ActiveDocument is not null;

    [RelayCommand(CanExecute = nameof(CanSave))]
    private Task SaveAsync() => ActiveDocument?.SaveAsync() ?? Task.CompletedTask;

    [RelayCommand(CanExecute = nameof(CanSave))]
    private async Task SaveAsAsync()
    {
        if (ActiveDocument is not { } doc)
        {
            return;
        }
        var location = await _dialogs.PickProjectLocationAsync(doc.DisplayName);
        if (location is null)
        {
            return;
        }
        var oldPath = doc.PackagePath;
        var newPath = ProjectPackage.PackagePath(location.Value.Directory, location.Value.Name);
        await doc.SaveAsAsync(newPath);
        Registry.UpdateUrl(oldPath, doc.PackagePath);
        OnPropertyChanged(nameof(WindowTitle));
    }

    private bool CanUndo() => ActiveDocument?.UndoService.CanUndo ?? false;

    [RelayCommand(CanExecute = nameof(CanUndo))]
    private void Undo() => ActiveDocument?.UndoService.Undo();

    private bool CanRedo() => ActiveDocument?.UndoService.CanRedo ?? false;

    [RelayCommand(CanExecute = nameof(CanRedo))]
    private void Redo() => ActiveDocument?.UndoService.Redo();

    [RelayCommand]
    private void Quit() => RequestQuit?.Invoke(this, EventArgs.Empty);
}
