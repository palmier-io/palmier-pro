using System.Linq;
using PalmierPro.App.ViewModels;
using Shouldly;
using Xunit;

namespace PalmierPro.App.Tests.ViewModels;

public class HomeViewModelTests
{
    [Fact]
    public void RecentProjects_reflects_the_registry_sorted_by_most_recently_opened()
    {
        using var temp = new TempDirectory();
        var (shell, _, registry) = TestFactory.MakeShell(temp.Path);
        var home = new HomeViewModel(shell);

        var older = Path.Combine(temp.Path, "Older.palmier");
        var newer = Path.Combine(temp.Path, "Newer.palmier");
        registry.Register(older);
        registry.Register(newer);

        home.RecentProjects.Count.ShouldBe(2);
        home.RecentProjects[0].Url.ShouldBe(newer);
        home.RecentProjects[1].Url.ShouldBe(older);
    }

    [Fact]
    public void RecentProjects_starts_populated_from_an_already_nonempty_registry()
    {
        using var temp = new TempDirectory();
        var (shell, _, registry) = TestFactory.MakeShell(temp.Path);
        registry.Register(Path.Combine(temp.Path, "Existing.palmier"));

        var home = new HomeViewModel(shell);

        home.RecentProjects.Count.ShouldBe(1);
    }

    [Fact]
    public void RemoveEntryCommand_removes_the_entry_from_the_registry_and_the_list()
    {
        using var temp = new TempDirectory();
        var (shell, _, registry) = TestFactory.MakeShell(temp.Path);
        var home = new HomeViewModel(shell);
        var path = Path.Combine(temp.Path, "Removable.palmier");
        registry.Register(path);
        var entry = home.RecentProjects.Single();

        home.RemoveEntryCommand.Execute(entry);

        home.RecentProjects.ShouldBeEmpty();
        registry.SortedEntries.ShouldBeEmpty();
    }

    [Fact]
    public async Task OpenEntryCommand_opens_the_entrys_project_through_the_shell()
    {
        using var temp = new TempDirectory();
        var (shell, _, _) = TestFactory.MakeShell(temp.Path);
        var home = new HomeViewModel(shell);
        var created = await shell.CreateProjectAsync(temp.Path, "Openable");
        shell.ShowHome();
        var entry = home.RecentProjects.Single(e => e.Url == created.PackagePath);

        await home.OpenEntryCommand.ExecuteAsync(entry);

        shell.IsEditorOpen.ShouldBeTrue();
        shell.ActiveDocument!.PackagePath.ShouldBe(created.PackagePath);
    }

    [Fact]
    public void NewProjectCommand_and_OpenProjectCommand_delegate_to_the_shell()
    {
        using var temp = new TempDirectory();
        var (shell, _, _) = TestFactory.MakeShell(temp.Path);
        var home = new HomeViewModel(shell);

        home.NewProjectCommand.ShouldBeSameAs(shell.NewCommand);
        home.OpenProjectCommand.ShouldBeSameAs(shell.OpenCommand);
    }
}
