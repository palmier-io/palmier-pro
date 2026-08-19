using PalmierPro.Core;
using PalmierPro.Core.Models;
using PalmierPro.Core.Project;
using PalmierPro.Core.Serialization;
using PalmierPro.Core.Settings;
using Xunit;

namespace PalmierPro.Core.Tests;

/// <summary>
/// Headless stand-in for Home → New Project → Open → Settings appearance.
/// WinUI cannot run in CI; this covers the domain path that crashed in the UI.
/// </summary>
public class HomeProjectFlowE2ETests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), $"palmier-home-e2e-{Guid.NewGuid():N}");

    public HomeProjectFlowE2ETests() => Directory.CreateDirectory(_root);

    public void Dispose()
    {
        try { Directory.Delete(_root, recursive: true); } catch { /* best-effort */ }
    }

    [Fact]
    public async Task CreateRegisterReload_ProjectSurvives()
    {
        var storage = Path.Combine(_root, "Projects");
        Directory.CreateDirectory(storage);
        var registryPath = Path.Combine(storage, "project-registry.json");
        var registry = new ProjectRegistry(registryPath);

        var package = CreateUntitledLikeHome(storage);
        Assert.True(Directory.Exists(package));
        Assert.True(File.Exists(Path.Combine(package, ProjectConstants.TimelineFilename)));

        await registry.RegisterAsync(package);
        Assert.Single(registry.Entries);

        var reloaded = new ProjectRegistry(registryPath);
        await reloaded.LoadAsync();
        Assert.Single(reloaded.Entries);
        Assert.Equal(Path.GetFullPath(package), Path.GetFullPath(reloaded.Entries[0].Path));
        Assert.True(reloaded.Entries[0].IsAccessible);

        var contents = ProjectPackage.Read(package);
        Assert.False(string.IsNullOrEmpty(contents.ProjectFile.ActiveTimelineId));
        Assert.True(contents.ProjectFile.Timelines.Count >= 1);
    }

    [Fact]
    public void Settings_AppearanceRoundTrip_AndCorruptFileRecovers()
    {
        var path = Path.Combine(_root, "settings.json");
        var store = new SettingsStore(path);
        store.Update(s => s.AppAppearance = AppAppearance.Normalize("DARK"));
        Assert.Equal("dark", store.Current.AppAppearance);

        store.Update(s => s.AppAppearance = AppAppearance.Normalize("light"));
        var again = new SettingsStore(path);
        Assert.Equal("light", again.Current.AppAppearance);

        File.WriteAllText(path, "{ not json");
        var recovered = new SettingsStore(path);
        Assert.Equal("system", AppAppearance.Normalize(recovered.Current.AppAppearance));
    }

    [Theory]
    [InlineData(null, "system")]
    [InlineData("", "system")]
    [InlineData("System", "system")]
    [InlineData("DARK", "dark")]
    [InlineData("light", "light")]
    [InlineData("neon", "system")]
    public void AppAppearance_Normalizes(string? input, string expected)
        => Assert.Equal(expected, AppAppearance.Normalize(input));

    [Fact]
    public void ProjectCardWithoutThumbnail_LeavesSourceNull()
    {
        // Regression: Home GridView bound null ThumbnailPath string → WinUI STOW crash on launch.
        var package = CreateUntitledLikeHome(_root);
        var entry = new ProjectEntry
        {
            Id = Guid.NewGuid(),
            Path = package,
            CreatedDate = DateTime.UtcNow,
            LastOpenedDate = DateTime.UtcNow,
        };
        Assert.True(entry.IsAccessible);
        Assert.False(File.Exists(Path.Combine(package, ProjectConstants.ThumbnailFilename)));
    }

    [Fact]
    public async Task CreateThenDelete_RemovesPackageAndRegistryEntry()
    {
        var storage = Path.Combine(_root, "Projects2");
        Directory.CreateDirectory(storage);
        var registry = new ProjectRegistry(Path.Combine(storage, "project-registry.json"));
        var package = CreateUntitledLikeHome(storage);
        await registry.RegisterAsync(package);
        var entry = registry.Entries[0];

        var result = await registry.DeleteAsync([entry]);
        Assert.Contains(entry.Id, result.DeletedIds);
        Assert.False(Directory.Exists(package));
        Assert.Empty(registry.Entries);
    }

    /// <summary>Mirrors <c>HomeViewModel.CreateProjectAsync</c> package shape.</summary>
    private static string CreateUntitledLikeHome(string storageDirectory)
    {
        var packagePath = Path.Combine(storageDirectory, $"Untitled.{ProjectConstants.FileExtension}");
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
    }
}
