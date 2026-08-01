using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using PalmierPro.Core;
using PalmierPro.Core.Models;
using PalmierPro.Core.Project;
using PalmierPro.Core.Serialization;

namespace PalmierPro.App.Home;

public sealed partial class HomeViewModel : ObservableObject
{
    public static ProjectRegistry Registry { get; } = new();

    public ObservableCollection<ProjectCardViewModel> Projects { get; } = [];

    [ObservableProperty]
    private bool _isEmpty = true;

    public async Task LoadAsync()
    {
        await Registry.LoadAsync();
        Refresh();
    }

    public void Refresh()
    {
        Projects.Clear();
        foreach (var entry in Registry.SortedEntries)
        {
            Projects.Add(new ProjectCardViewModel(entry));
        }
        IsEmpty = Projects.Count == 0;
    }

    /// <summary>Create a new untitled project package in the storage directory and register it.</summary>
    public async Task<string> CreateProjectAsync()
    {
        var path = await Task.Run(() =>
        {
            ProjectConstants.EnsureStorageDirectory();
            var packagePath = UniqueProjectPath(ProjectConstants.DefaultProjectName);
            var timeline = new Timeline();
            var file = new ProjectFile
            {
                Timelines = [timeline],
                ActiveTimelineId = timeline.Id,
                OpenTimelineIds = [timeline.Id],
            };
            ProjectPackage.Write(new ProjectPackageSnapshot
            {
                Timeline = PalmierJson.Encode(file),
                Manifest = PalmierJson.Encode(new MediaManifest()),
            }, packagePath, sourcePath: null);
            return packagePath;
        });

        await Registry.RegisterAsync(path);
        Refresh();
        return path;
    }

    public async Task RegisterAndRefreshAsync(string path)
    {
        await Registry.RegisterAsync(path);
        Refresh();
    }

    public async Task RemoveFromRecentsAsync(ProjectCardViewModel card)
    {
        await Registry.RemoveAsync(card.Path);
        Refresh();
    }

    public async Task<ProjectDeletionResult> DeleteAsync(ProjectCardViewModel card)
    {
        var entry = Registry.Entries.FirstOrDefault(e => e.Id == card.Id);
        if (entry is null) return new ProjectDeletionResult(new HashSet<Guid>(), []);
        var result = await Registry.DeleteAsync([entry]);
        Refresh();
        return result;
    }

    private static string UniqueProjectPath(string baseName)
    {
        var directory = ProjectConstants.StorageDirectory;
        var candidate = Path.Combine(directory, $"{baseName}.{ProjectConstants.FileExtension}");
        var counter = 2;
        while (Directory.Exists(candidate) || File.Exists(candidate))
        {
            candidate = Path.Combine(directory, $"{baseName} {counter}.{ProjectConstants.FileExtension}");
            counter += 1;
        }
        return candidate;
    }
}

public sealed class ProjectCardViewModel
{
    public Guid Id { get; }
    public string Path { get; }
    public string Name { get; }
    public string CreatedRelative { get; }
    public bool IsAccessible { get; }

    /// <summary>
    /// Null when the package has no thumbnail. Never bind a null string to Image.Source —
    /// that throws ArgumentException and takes down the Home window.
    /// </summary>
    public ImageSource? ThumbnailImage { get; }

    public double InaccessibleOverlayOpacity => IsAccessible ? 0 : 1;
    public double CardOpacity => IsAccessible ? 1.0 : 0.6;

    public ProjectCardViewModel(ProjectEntry entry)
    {
        Id = entry.Id;
        Path = entry.Path;
        Name = entry.Name;
        IsAccessible = entry.IsAccessible;
        CreatedRelative = RelativeDate(entry.CreatedDate);
        var thumb = System.IO.Path.Combine(entry.Path, ProjectConstants.ThumbnailFilename);
        if (File.Exists(thumb))
        {
            try { ThumbnailImage = new BitmapImage(new Uri(thumb)); }
            catch { ThumbnailImage = null; }
        }
    }

    private static string RelativeDate(DateTime date)
    {
        var delta = DateTime.UtcNow - date.ToUniversalTime();
        if (delta < TimeSpan.Zero) return "just now";
        if (delta.TotalMinutes < 1) return "just now";
        if (delta.TotalMinutes < 60) return $"{(int)delta.TotalMinutes} minute{(delta.TotalMinutes < 2 ? "" : "s")} ago";
        if (delta.TotalHours < 24) return $"{(int)delta.TotalHours} hour{(delta.TotalHours < 2 ? "" : "s")} ago";
        if (delta.TotalDays < 30) return $"{(int)delta.TotalDays} day{(delta.TotalDays < 2 ? "" : "s")} ago";
        if (delta.TotalDays < 365) return $"{(int)(delta.TotalDays / 30)} month{(delta.TotalDays < 60 ? "" : "s")} ago";
        return $"{(int)(delta.TotalDays / 365)} year{(delta.TotalDays < 730 ? "" : "s")} ago";
    }
}
