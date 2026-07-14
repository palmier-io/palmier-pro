using Shouldly;
using Xunit;

namespace PalmierPro.App.Tests.ViewModels;

public class ShellViewModelTests
{
    [Fact]
    public async Task CreateProjectAsync_sets_active_document_and_registers_it()
    {
        using var temp = new TempDirectory();
        var (shell, _, registry) = TestFactory.MakeShell(temp.Path);

        var doc = await shell.CreateProjectAsync(temp.Path, "My Movie");

        shell.ActiveDocument.ShouldBe(doc);
        shell.IsEditorOpen.ShouldBeTrue();
        shell.WindowTitle.ShouldBe("My Movie");
        registry.SortedEntries.ShouldContain(e => e.Url == doc.PackagePath);
    }

    [Fact]
    public async Task OpenProjectAtAsync_reopening_the_active_document_does_not_create_a_new_instance()
    {
        using var temp = new TempDirectory();
        var (shell, _, _) = TestFactory.MakeShell(temp.Path);
        var doc = await shell.CreateProjectAsync(temp.Path, "Reopen Me");

        var reopened = await shell.OpenProjectAtAsync(doc.PackagePath);

        reopened.ShouldBeSameAs(doc);
    }

    [Fact]
    public async Task ShowHome_clears_the_active_document_and_registers_it_for_recents()
    {
        using var temp = new TempDirectory();
        var (shell, _, registry) = TestFactory.MakeShell(temp.Path);
        var doc = await shell.CreateProjectAsync(temp.Path, "Going Home");

        shell.ShowHome();

        shell.ActiveDocument.ShouldBeNull();
        shell.IsEditorOpen.ShouldBeFalse();
        shell.WindowTitle.ShouldBe("Palmier Pro");
        registry.SortedEntries.ShouldContain(e => e.Url == doc.PackagePath);
    }

    [Fact]
    public void Save_and_SaveAs_are_disabled_without_an_active_document()
    {
        using var temp = new TempDirectory();
        var (shell, _, _) = TestFactory.MakeShell(temp.Path);

        shell.SaveCommand.CanExecute(null).ShouldBeFalse();
        shell.SaveAsCommand.CanExecute(null).ShouldBeFalse();
    }

    [Fact]
    public async Task SaveAsAsync_repoints_the_existing_recents_entry_instead_of_adding_a_new_one()
    {
        using var temp = new TempDirectory();
        var (shell, dialogs, registry) = TestFactory.MakeShell(temp.Path);
        var doc = await shell.CreateProjectAsync(temp.Path, "Original");
        var originalId = registry.Entries[0].Id;

        dialogs.NextLocation = (temp.Path, "Renamed");
        await shell.SaveAsCommand.ExecuteAsync(null);

        registry.Entries.Count.ShouldBe(1);
        registry.Entries[0].Id.ShouldBe(originalId);
        registry.Entries[0].Url.ShouldBe(doc.PackagePath);
    }

    [Fact]
    public async Task Save_becomes_enabled_once_a_document_is_open()
    {
        using var temp = new TempDirectory();
        var (shell, _, _) = TestFactory.MakeShell(temp.Path);
        await shell.CreateProjectAsync(temp.Path, "Saveable");

        shell.SaveCommand.CanExecute(null).ShouldBeTrue();
        shell.SaveAsCommand.CanExecute(null).ShouldBeTrue();
    }

    [Fact]
    public void Undo_and_Redo_are_disabled_without_an_active_document()
    {
        using var temp = new TempDirectory();
        var (shell, _, _) = TestFactory.MakeShell(temp.Path);

        shell.UndoCommand.CanExecute(null).ShouldBeFalse();
        shell.RedoCommand.CanExecute(null).ShouldBeFalse();
        shell.UndoMenuText.ShouldBe("Undo");
        shell.RedoMenuText.ShouldBe("Redo");
    }

    [Fact]
    public async Task Undo_reflects_the_active_documents_UndoService()
    {
        using var temp = new TempDirectory();
        var (shell, _, _) = TestFactory.MakeShell(temp.Path);
        var doc = await shell.CreateProjectAsync(temp.Path, "Undoable");

        // Swap pattern (see UndoService's own doc comment): the handler re-registers its own
        // inverse, which is what populates the redo stack after an Undo().
        var value = 0;
        void RegisterIncrement() => doc.UndoService.RegisterUndo("Increment", () => { value--; RegisterDecrement(); });
        void RegisterDecrement() => doc.UndoService.RegisterUndo("Increment", () => { value++; RegisterIncrement(); });
        RegisterIncrement();
        value++;

        shell.UndoCommand.CanExecute(null).ShouldBeTrue();
        shell.UndoMenuText.ShouldBe("Undo Increment");

        shell.UndoCommand.Execute(null);

        value.ShouldBe(0);
        shell.RedoCommand.CanExecute(null).ShouldBeTrue();
        shell.RedoMenuText.ShouldBe("Redo Increment");

        shell.RedoCommand.Execute(null);

        value.ShouldBe(1);
    }

    [Fact]
    public async Task NewCommand_uses_the_dialog_service_and_creates_a_project()
    {
        using var temp = new TempDirectory();
        var (shell, dialogs, _) = TestFactory.MakeShell(temp.Path);
        dialogs.NextLocation = (temp.Path, "From Dialog");

        await shell.NewCommand.ExecuteAsync(null);

        dialogs.LocationPromptCount.ShouldBe(1);
        shell.WindowTitle.ShouldBe("From Dialog");
    }

    [Fact]
    public async Task NewCommand_does_nothing_when_the_dialog_is_cancelled()
    {
        using var temp = new TempDirectory();
        var (shell, dialogs, _) = TestFactory.MakeShell(temp.Path);
        dialogs.NextLocation = null;

        await shell.NewCommand.ExecuteAsync(null);

        shell.ActiveDocument.ShouldBeNull();
    }

    [Fact]
    public async Task OpenCommand_uses_the_dialog_service_and_opens_the_picked_path()
    {
        using var temp = new TempDirectory();
        var (shell, dialogs, _) = TestFactory.MakeShell(temp.Path);
        var created = await shell.CreateProjectAsync(temp.Path, "Existing");
        shell.ShowHome();
        dialogs.NextExistingPath = created.PackagePath;

        await shell.OpenCommand.ExecuteAsync(null);

        dialogs.OpenPromptCount.ShouldBe(1);
        shell.IsEditorOpen.ShouldBeTrue();
        shell.WindowTitle.ShouldBe("Existing");
    }

    [Fact]
    public void QuitCommand_raises_RequestQuit()
    {
        using var temp = new TempDirectory();
        var (shell, _, _) = TestFactory.MakeShell(temp.Path);
        var raised = false;
        shell.RequestQuit += (_, _) => raised = true;

        shell.QuitCommand.Execute(null);

        raised.ShouldBeTrue();
    }
}
