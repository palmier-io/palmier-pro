using PalmierPro.App.ViewModels;
using Shouldly;
using Xunit;

namespace PalmierPro.App.Tests.ViewModels;

/// CanExecute matrix for the menu commands PalmierMenuBar binds against: the functional
/// ShellViewModel commands react to document state; every DisabledMenuCommands entry (mirroring
/// MainMenuBuilder items with no Windows implementation yet) never executes.
public class MenuCommandMatrixTests
{
    [Theory]
    [InlineData(false, false, false)] // no document -> Save, SaveAs, Undo/Redo all disabled
    [InlineData(true, true, false)] // document open, no undo history yet -> Save/SaveAs enabled, Undo still not
    public async Task Document_dependent_commands_track_active_document_state(bool hasDocument, bool expectedSave, bool expectedUndo)
    {
        using var temp = new TempDirectory();
        var (shell, _, _) = TestFactory.MakeShell(temp.Path);
        if (hasDocument)
        {
            await shell.CreateProjectAsync(temp.Path, "Matrix");
        }

        shell.SaveCommand.CanExecute(null).ShouldBe(expectedSave);
        shell.SaveAsCommand.CanExecute(null).ShouldBe(expectedSave);
        shell.UndoCommand.CanExecute(null).ShouldBe(expectedUndo);
        shell.RedoCommand.CanExecute(null).ShouldBe(expectedUndo);
        shell.ImportMediaCommand.CanExecute(null).ShouldBe(expectedSave);
    }

    [Fact]
    public async Task ImportMediaCommand_raises_ImportMediaRequested_only_when_a_document_is_open()
    {
        using var temp = new TempDirectory();
        var (shell, _, _) = TestFactory.MakeShell(temp.Path);
        var raised = 0;
        shell.ImportMediaRequested += (_, _) => raised++;

        shell.ImportMediaCommand.CanExecute(null).ShouldBeFalse();

        await shell.CreateProjectAsync(temp.Path, "Import Wiring");
        shell.ImportMediaCommand.CanExecute(null).ShouldBeTrue();
        shell.ImportMediaCommand.Execute(null);

        raised.ShouldBe(1);
    }

    [Fact]
    public void New_Open_and_Quit_are_always_available()
    {
        using var temp = new TempDirectory();
        var (shell, _, _) = TestFactory.MakeShell(temp.Path);

        shell.NewCommand.CanExecute(null).ShouldBeTrue();
        shell.OpenCommand.CanExecute(null).ShouldBeTrue();
        shell.QuitCommand.CanExecute(null).ShouldBeTrue();
    }

    public static IEnumerable<object[]> TimelineEditingCommands(ShellViewModel shell)
    {
        yield return [shell.SplitAtPlayheadCommand];
        yield return [shell.TrimStartToPlayheadCommand];
        yield return [shell.TrimEndToPlayheadCommand];
        yield return [shell.DeleteSelectedClipsCommand];
        yield return [shell.RippleDeleteCommand];
        yield return [shell.SelectForwardOnTrackCommand];
        yield return [shell.SelectForwardOnAllTracksCommand];
    }

    /// Stage C (M3): the seven timeline-editing menu items moved off `DisabledMenuCommands` onto
    /// `ShellViewModel`, backed by `TimelineEditorViewModel` — same document-gated shape as
    /// Save/Undo, not permanently disabled.
    [Fact]
    public async Task Timeline_editing_commands_track_active_document_state()
    {
        using var temp = new TempDirectory();
        var (shell, _, _) = TestFactory.MakeShell(temp.Path);

        foreach (var command in TimelineEditingCommands(shell))
        {
            ((CommunityToolkit.Mvvm.Input.IRelayCommand)command[0]).CanExecute(null).ShouldBeFalse();
        }

        await shell.CreateProjectAsync(temp.Path, "Timeline Commands");

        foreach (var command in TimelineEditingCommands(shell))
        {
            ((CommunityToolkit.Mvvm.Input.IRelayCommand)command[0]).CanExecute(null).ShouldBeTrue();
        }
    }

    public static IEnumerable<object[]> DisabledCommands()
    {
        yield return [DisabledMenuCommands.About];
        yield return [DisabledMenuCommands.CheckForUpdates];
        yield return [DisabledMenuCommands.Settings];
        yield return [DisabledMenuCommands.Export];
        yield return [DisabledMenuCommands.Cut];
        yield return [DisabledMenuCommands.Copy];
        yield return [DisabledMenuCommands.Paste];
        yield return [DisabledMenuCommands.SelectAll];
        yield return [DisabledMenuCommands.ToggleMediaPanel];
        yield return [DisabledMenuCommands.ToggleInspector];
        yield return [DisabledMenuCommands.ToggleAgentPanel];
        yield return [DisabledMenuCommands.ToggleMaximizePanel];
        yield return [DisabledMenuCommands.SetLayoutDefault];
        yield return [DisabledMenuCommands.SetLayoutMedia];
        yield return [DisabledMenuCommands.SetLayoutVertical];
        yield return [DisabledMenuCommands.Tutorial];
        yield return [DisabledMenuCommands.KeyboardShortcuts];
        yield return [DisabledMenuCommands.MCPInstructions];
        yield return [DisabledMenuCommands.SendFeedback];
    }

    [Theory]
    [MemberData(nameof(DisabledCommands))]
    public void Disabled_menu_command_never_executes(CommunityToolkit.Mvvm.Input.IRelayCommand command) =>
        command.CanExecute(null).ShouldBeFalse();
}
