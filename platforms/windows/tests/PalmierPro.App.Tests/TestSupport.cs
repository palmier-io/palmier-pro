// ViewModel/logic tests only. Plain `dotnet test` has no WinUI host — never instantiate
// WinUI types (Window, Control, anything from Microsoft.UI.Xaml) in this project.

using PalmierPro.App.ViewModels;
using PalmierPro.Services.Project;

namespace PalmierPro.App.Tests;

/// Self-contained isolated directory for one test; deleted best-effort on dispose so a failed
/// assertion doesn't leak temp files across the suite. Mirrors
/// PalmierPro.Services.Tests.TempDirectory (not shared — see that file's own note on why).
internal sealed class TempDirectory : IDisposable
{
    public string Path { get; }

    public TempDirectory()
    {
        Path = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "PalmierProAppTests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(Path);
    }

    public void Dispose()
    {
        try
        {
            if (Directory.Exists(Path))
            {
                Directory.Delete(Path, recursive: true);
            }
        }
        catch (IOException)
        {
            // Best effort — a lingering handle shouldn't fail the test run.
        }
    }
}

/// Scriptable stand-in for the Windows.Storage-picker-backed service — lets ShellViewModel's
/// New/Open/Save As commands be exercised without a Window.
internal sealed class FakeProjectDialogService : IProjectDialogService
{
    public (string Directory, string Name)? NextLocation { get; set; }
    public string? NextExistingPath { get; set; }
    public int LocationPromptCount { get; private set; }
    public int OpenPromptCount { get; private set; }

    public Task<(string Directory, string Name)?> PickProjectLocationAsync(string suggestedName)
    {
        LocationPromptCount++;
        return Task.FromResult(NextLocation);
    }

    public Task<string?> PickExistingProjectPathAsync()
    {
        OpenPromptCount++;
        return Task.FromResult(NextExistingPath);
    }
}

internal static class TestFactory
{
    public static (ShellViewModel Shell, FakeProjectDialogService Dialogs, ProjectRegistry Registry) MakeShell(string registryDirectory)
    {
        var registry = new ProjectRegistry(System.IO.Path.Combine(registryDirectory, "project-registry.json"));
        var dialogs = new FakeProjectDialogService();
        return (new ShellViewModel(registry, dialogs), dialogs, registry);
    }
}
