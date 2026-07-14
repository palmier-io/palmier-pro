using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using PalmierPro.Services.Project;

namespace PalmierPro.App.ViewModels;

/// Backs HomeView's recent-projects grid. Mirrors HomeView.projectGrid reading
/// ProjectRegistry.shared.sortedEntries directly — this just keeps an observable copy in sync via
/// ProjectRegistry.Changed instead of re-deriving on every render.
public sealed partial class HomeViewModel : ObservableObject
{
    private readonly ShellViewModel _shell;

    public ObservableCollection<ProjectEntry> RecentProjects { get; } = [];

    public IAsyncRelayCommand NewProjectCommand => _shell.NewCommand;

    public IAsyncRelayCommand OpenProjectCommand => _shell.OpenCommand;

    public HomeViewModel(ShellViewModel shell)
    {
        _shell = shell;
        _shell.Registry.Changed += (_, _) => Refresh();
        Refresh();
    }

    private void Refresh()
    {
        RecentProjects.Clear();
        foreach (var entry in _shell.Registry.SortedEntries)
        {
            RecentProjects.Add(entry);
        }
    }

    [RelayCommand]
    private Task OpenEntryAsync(ProjectEntry entry) => _shell.OpenProjectAtAsync(entry.Url);

    [RelayCommand]
    private void RemoveEntry(ProjectEntry entry) => _shell.Registry.Remove(entry.Url);
}
