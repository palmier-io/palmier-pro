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

    public static IEnumerable<object[]> DisabledCommands()
    {
        yield return [DisabledMenuCommands.About];
        yield return [DisabledMenuCommands.CheckForUpdates];
        yield return [DisabledMenuCommands.Settings];
        yield return [DisabledMenuCommands.ImportMedia];
        yield return [DisabledMenuCommands.Export];
        yield return [DisabledMenuCommands.Cut];
        yield return [DisabledMenuCommands.Copy];
        yield return [DisabledMenuCommands.Paste];
        yield return [DisabledMenuCommands.SelectAll];
        yield return [DisabledMenuCommands.SelectForwardOnTrack];
        yield return [DisabledMenuCommands.SelectForwardOnAllTracks];
        yield return [DisabledMenuCommands.SplitAtPlayhead];
        yield return [DisabledMenuCommands.TrimStartToPlayhead];
        yield return [DisabledMenuCommands.TrimEndToPlayhead];
        yield return [DisabledMenuCommands.DeleteSelectedClips];
        yield return [DisabledMenuCommands.RippleDelete];
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
