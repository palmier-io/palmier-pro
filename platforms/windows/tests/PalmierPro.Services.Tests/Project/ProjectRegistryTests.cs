using PalmierPro.Services.Project;
using Shouldly;
using Xunit;

namespace PalmierPro.Services.Tests;

public class ProjectRegistryTests
{
    [Fact]
    public void Register_AddsEntryAndPersistsAcrossInstances()
    {
        using var tmp = new TempDirectory();
        var registryPath = Path.Combine(tmp.Path, "project-registry.json");
        var projectPath = Path.Combine(tmp.Path, "A.palmier");

        var registry = new ProjectRegistry(registryPath);
        registry.Register(projectPath);

        registry.Entries.Count.ShouldBe(1);
        File.Exists(registryPath).ShouldBeTrue();

        var reloaded = new ProjectRegistry(registryPath);
        reloaded.Entries.Count.ShouldBe(1);
        string.Equals(reloaded.Entries[0].Url, Path.GetFullPath(projectPath), StringComparison.OrdinalIgnoreCase).ShouldBeTrue();
    }

    [Fact]
    public void Register_SameUrlTwice_UpdatesInPlaceRatherThanDuplicating()
    {
        using var tmp = new TempDirectory();
        var registry = new ProjectRegistry(Path.Combine(tmp.Path, "project-registry.json"));
        var projectPath = Path.Combine(tmp.Path, "A.palmier");

        registry.Register(projectPath);
        var firstId = registry.Entries[0].Id;
        registry.Register(projectPath);

        registry.Entries.Count.ShouldBe(1);
        registry.Entries[0].Id.ShouldBe(firstId);
    }

    [Fact]
    public void Register_IsCaseInsensitiveOnWindowsPaths()
    {
        using var tmp = new TempDirectory();
        var registry = new ProjectRegistry(Path.Combine(tmp.Path, "project-registry.json"));
        var projectPath = Path.Combine(tmp.Path, "A.palmier");

        registry.Register(projectPath.ToUpperInvariant());
        registry.Register(projectPath.ToLowerInvariant());

        registry.Entries.Count.ShouldBe(1);
    }

    [Fact]
    public void Remove_DropsEntryAndPersists()
    {
        using var tmp = new TempDirectory();
        var registryPath = Path.Combine(tmp.Path, "project-registry.json");
        var registry = new ProjectRegistry(registryPath);
        var projectPath = Path.Combine(tmp.Path, "A.palmier");
        registry.Register(projectPath);

        registry.Remove(projectPath);

        registry.Entries.ShouldBeEmpty();
        var reloaded = new ProjectRegistry(registryPath);
        reloaded.Entries.ShouldBeEmpty();
    }

    [Fact]
    public void UpdateUrl_RepointsExistingEntryWithoutChangingId()
    {
        using var tmp = new TempDirectory();
        var registry = new ProjectRegistry(Path.Combine(tmp.Path, "project-registry.json"));
        var oldPath = Path.Combine(tmp.Path, "Old.palmier");
        var newPath = Path.Combine(tmp.Path, "New.palmier");
        registry.Register(oldPath);
        var id = registry.Entries[0].Id;

        registry.UpdateUrl(oldPath, newPath);

        registry.Entries.Count.ShouldBe(1);
        registry.Entries[0].Id.ShouldBe(id);
        string.Equals(registry.Entries[0].Url, Path.GetFullPath(newPath), StringComparison.OrdinalIgnoreCase).ShouldBeTrue();
        registry.IdFor(newPath).ShouldBe(id);
        registry.IdFor(oldPath).ShouldBeNull();
    }

    [Fact]
    public void SortedEntries_OrdersMostRecentlyOpenedFirst()
    {
        using var tmp = new TempDirectory();
        var registry = new ProjectRegistry(Path.Combine(tmp.Path, "project-registry.json"));
        registry.Register(Path.Combine(tmp.Path, "First.palmier"));
        registry.Register(Path.Combine(tmp.Path, "Second.palmier"));
        // Re-touch "First" so it becomes the most recently opened.
        registry.Register(Path.Combine(tmp.Path, "First.palmier"));

        registry.SortedEntries[0].Name.ShouldBe("First");
    }

    [Fact]
    public void IsAccessible_ReflectsWhetherThePackageDirectoryExists()
    {
        using var tmp = new TempDirectory();
        var registry = new ProjectRegistry(Path.Combine(tmp.Path, "project-registry.json"));
        var missingPath = Path.Combine(tmp.Path, "Missing.palmier");
        registry.Register(missingPath);
        registry.Entries[0].IsAccessible.ShouldBeFalse();

        Directory.CreateDirectory(missingPath);
        registry.Entries[0].IsAccessible.ShouldBeTrue();
    }

    [Fact]
    public async Task Register_ConcurrentCallsAcrossThreads_PersistsEveryEntryToDisk()
    {
        using var tmp = new TempDirectory();
        var registryPath = Path.Combine(tmp.Path, "project-registry.json");
        var registry = new ProjectRegistry(registryPath);

        // Save() used to snapshot _entries under the lock but write to disk outside it, so two
        // concurrent Register() calls could race their writes and the one holding the staler
        // snapshot could land last, silently dropping the other's entry from disk.
        const int count = 50;
        var tasks = Enumerable.Range(0, count)
            .Select(i => Task.Run(() => registry.Register(Path.Combine(tmp.Path, $"Project{i}.palmier"))));
        await Task.WhenAll(tasks);

        registry.Entries.Count.ShouldBe(count);

        var reloaded = new ProjectRegistry(registryPath);
        reloaded.Entries.Count.ShouldBe(count);
    }

    [Fact]
    public void Load_TolerantOfMissingOrCorruptRegistryFile()
    {
        using var tmp = new TempDirectory();
        var registryPath = Path.Combine(tmp.Path, "project-registry.json");

        new ProjectRegistry(registryPath).Entries.ShouldBeEmpty();

        File.WriteAllBytes(registryPath, "not json"u8.ToArray());
        new ProjectRegistry(registryPath).Entries.ShouldBeEmpty();
    }
}
