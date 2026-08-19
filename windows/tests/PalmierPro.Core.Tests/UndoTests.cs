using PalmierPro.Core.Undo;
using Xunit;

namespace PalmierPro.Core.Tests;

public class UndoTests
{
    [Fact]
    public void TransactionProducesSingleUndoEntry()
    {
        var manager = new UndoManager();
        var undo = new EditorUndo();
        undo.Attach(manager);

        var value = 0;

        void Set(int next)
        {
            var old = value;
            value = next;
            undo.Register("Edit", () => Set(old));
        }

        undo.Perform("Edit", () =>
        {
            Set(1);
            Set(2);
        });

        Assert.True(manager.CanUndo);
        Assert.Equal("Edit", manager.UndoActionName);

        manager.Undo();
        Assert.Equal(0, value);
        Assert.False(manager.CanUndo);
        Assert.True(manager.CanRedo);

        manager.Redo();
        Assert.Equal(2, value);
        Assert.True(manager.CanUndo);
    }

    [Fact]
    public void EmptyTransactionLeavesNoUndoEntry()
    {
        var manager = new UndoManager();
        var undo = new EditorUndo();
        undo.Attach(manager);

        undo.Perform("Nothing", () => { });

        Assert.False(manager.CanUndo);
        Assert.Equal(0, manager.GroupingLevel);
    }

    [Fact]
    public void NestedTransactionsCoalesceIntoOuterAction()
    {
        var manager = new UndoManager();
        var undo = new EditorUndo();
        undo.Attach(manager);

        var log = new List<string>();
        undo.Perform("Outer", () =>
        {
            undo.Register("Outer", () => log.Add("outer"));
            undo.Perform("Inner", () => undo.Register("Inner", () => log.Add("inner")));
        });

        Assert.Equal("Outer", manager.UndoActionName);
        manager.Undo();
        // One undo restores both, inner registration last-in-first-out.
        Assert.Equal(["inner", "outer"], log);
        Assert.False(manager.CanUndo);
    }

    [Fact]
    public void RegistrationDuringUndoPopulatesRedoOnly()
    {
        var manager = new UndoManager();
        var undo = new EditorUndo();
        undo.Attach(manager);

        var value = 0;

        void Set(int next)
        {
            var old = value;
            value = next;
            undo.Register("Set", () => Set(old));
        }

        undo.Perform("Set", () => Set(5));
        manager.Undo();
        Assert.Equal(0, value);
        Assert.False(manager.CanUndo);
        Assert.True(manager.CanRedo);

        manager.Redo();
        Assert.Equal(5, value);
        Assert.True(manager.CanUndo);
        Assert.False(manager.CanRedo);
    }

    [Fact]
    public void NewEditClearsRedoStack()
    {
        var manager = new UndoManager();
        var undo = new EditorUndo();
        undo.Attach(manager);

        var value = 0;

        void Set(string action, int next)
        {
            var old = value;
            value = next;
            undo.Register(action, () => Set(action, old));
        }

        undo.Perform("A", () => Set("A", 1));
        manager.Undo();
        Assert.Equal(0, value);
        Assert.True(manager.CanRedo);

        undo.Perform("B", () => Set("B", 2));
        Assert.False(manager.CanRedo);
    }

    [Fact]
    public void WithoutRegistrationSuppressesUndoEntries()
    {
        var manager = new UndoManager();
        var undo = new EditorUndo();
        undo.Attach(manager);

        undo.WithoutRegistration(() => undo.Register("Hidden", () => { }));

        Assert.False(manager.CanUndo);
    }

    [Fact]
    public void UndoLatestReturnsActionName()
    {
        var manager = new UndoManager();
        var undo = new EditorUndo();
        undo.Attach(manager);

        Assert.Null(undo.UndoLatest());

        var value = 0;
        undo.Perform("Move Clip", () =>
        {
            undo.Register("Move Clip", () => value = 0);
            value = 1;
        });

        Assert.Equal("Move Clip", undo.UndoLatest());
        Assert.Equal(0, value);
    }

    [Fact]
    public void DetachedEditorUndoStillRunsWork()
    {
        var undo = new EditorUndo();
        var ran = false;
        undo.Perform("X", () => ran = true);
        Assert.True(ran);
    }
}
