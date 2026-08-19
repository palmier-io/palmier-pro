using PalmierPro.Core.Project;
using Xunit;

namespace PalmierPro.Core.Tests;

public class PackageCoordinatorTests
{
    [Fact]
    public async Task MutationRunsImmediatelyWhenNoSaveInFlight()
    {
        var coordinator = new ProjectPackageCoordinator();
        var ran = await coordinator.PerformMutationAsync(() => 42);
        Assert.Equal(42, ran);
    }

    [Fact]
    public async Task MutationDefersUntilSaveSucceeds()
    {
        var coordinator = new ProjectPackageCoordinator();
        coordinator.SaveStarted();
        var ran = false;
        var pending = coordinator.PerformMutationAsync(() => ran = true);
        await Task.Delay(50);
        Assert.False(ran);
        coordinator.SaveFinished(success: true);
        Assert.True(await pending);
    }

    [Fact]
    public async Task FailedSaveCancelsQueuedMutations()
    {
        var coordinator = new ProjectPackageCoordinator();
        coordinator.SaveStarted();
        var pending = coordinator.PerformMutationAsync(() => 1);
        coordinator.SaveFinished(success: false);
        await Assert.ThrowsAsync<TaskCanceledException>(() => pending);
    }

    [Fact]
    public async Task BeginMutationAfterClosingThrows()
    {
        var coordinator = new ProjectPackageCoordinator();
        await coordinator.BeginClosingAsync();
        Assert.Throws<OperationCanceledException>(() => coordinator.BeginMutation());
        coordinator.CancelClosing();
        coordinator.BeginMutation();
        coordinator.EndMutation();
    }

    [Fact]
    public async Task ClosingWaitsForAdmittedMutation()
    {
        var coordinator = new ProjectPackageCoordinator();
        coordinator.BeginMutation();
        var closing = coordinator.BeginClosingAsync();
        await Task.Delay(50);
        Assert.False(closing.IsCompleted);
        coordinator.EndMutation();
        await closing.WaitAsync(TimeSpan.FromSeconds(5));
    }

    [Fact]
    public async Task CancelledCallerRemovesPendingMutation()
    {
        var coordinator = new ProjectPackageCoordinator();
        coordinator.SaveStarted();
        using var cts = new CancellationTokenSource();
        var pending = coordinator.PerformMutationAsync(() => 1, cts.Token);
        cts.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => pending);
        // Save completing later must not run the cancelled operation.
        coordinator.SaveFinished(success: true);
    }
}

public class PackageMediaInstallerTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "palmier-test-" + Guid.NewGuid().ToString("N"));

    public PackageMediaInstallerTests() => Directory.CreateDirectory(_root);

    public void Dispose()
    {
        try { Directory.Delete(_root, recursive: true); } catch { }
    }

    private string Stage(byte[] contents)
    {
        var staged = Path.Combine(_root, "palmier-stage-" + Guid.NewGuid().ToString("N") + ".bin");
        File.WriteAllBytes(staged, contents);
        return staged;
    }

    [Fact]
    public async Task InstallsIntoMediaFolderAndConsumesStage()
    {
        var package = Path.Combine(_root, "Test.palmier");
        Directory.CreateDirectory(package);
        var staged = Stage([1, 2, 3]);

        var installer = new PackageMediaInstaller(new ProjectPackageCoordinator());
        var installed = await installer.CommitStagedMediaAsync(staged, "clip.bin", () => package);

        Assert.Equal(Path.Combine(package, "media", "clip.bin"), installed);
        Assert.Equal([1, 2, 3], await File.ReadAllBytesAsync(installed));
        Assert.False(File.Exists(staged));
        Assert.Empty(Directory.GetFiles(_root, ".palmier-stage-*"));
    }

    [Fact]
    public async Task InstallWaitsForSaveThenCommits()
    {
        var package = Path.Combine(_root, "Test.palmier");
        Directory.CreateDirectory(package);
        var coordinator = new ProjectPackageCoordinator();
        coordinator.SaveStarted();

        var installer = new PackageMediaInstaller(coordinator);
        var install = installer.CommitStagedMediaAsync(Stage([9]), "a.bin", () => package);
        await Task.Delay(100);
        Assert.False(File.Exists(Path.Combine(package, "media", "a.bin")));

        coordinator.SaveFinished(success: true);
        var installed = await install.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.True(File.Exists(installed));
    }

    [Fact]
    public async Task SaveAsRebaseRetriesIntoNewPackage()
    {
        var oldPackage = Path.Combine(_root, "Old.palmier");
        var newPackage = Path.Combine(_root, "New.palmier");
        Directory.CreateDirectory(oldPackage);
        Directory.CreateDirectory(newPackage);

        var current = oldPackage;
        var coordinator = new ProjectPackageCoordinator();
        coordinator.SaveStarted();
        var installer = new PackageMediaInstaller(coordinator);
        var install = installer.CommitStagedMediaAsync(Stage([7]), "b.bin", () => current);

        current = newPackage; // Save As lands while the install is queued.
        coordinator.SaveFinished(success: true);

        var installed = await install.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.StartsWith(newPackage, installed);
        Assert.True(File.Exists(installed));
        Assert.False(File.Exists(Path.Combine(oldPackage, "media", "b.bin")));
    }

    [Fact]
    public async Task OversizedFileIsRejectedBeforeCopy()
    {
        var package = Path.Combine(_root, "Test.palmier");
        Directory.CreateDirectory(package);
        var installer = new PackageMediaInstaller(new ProjectPackageCoordinator());
        await Assert.ThrowsAsync<FileTooLargeException>(() =>
            installer.CommitStagedMediaAsync(Stage(new byte[64]), "c.bin", () => package, maxBytes: 16));
    }

    [Fact]
    public async Task UnsavedProjectInstallsToTempHome()
    {
        var installer = new PackageMediaInstaller(new ProjectPackageCoordinator());
        var installed = await installer.CommitStagedMediaAsync(Stage([5]), "d.bin", () => null);
        try
        {
            Assert.True(File.Exists(installed));
            Assert.EndsWith("d.bin", installed);
        }
        finally
        {
            try { Directory.Delete(Path.GetDirectoryName(installed)!, recursive: true); } catch { }
        }
    }
}
