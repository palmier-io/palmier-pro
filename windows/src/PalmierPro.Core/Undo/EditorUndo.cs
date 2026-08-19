namespace PalmierPro.Core.Undo;

/// <summary>
/// Editor-facing undo facade mirroring the macOS EditorUndo: one user intent produces
/// one undoable action; nested registrations coalesce into the outer transaction;
/// failed or empty transactions leave no undo entry.
/// </summary>
public sealed class EditorUndo
{
    private UndoManager? _manager;
    private bool _transactionActive;
    private bool _transactionGroupOpened;

    public void Attach(UndoManager? manager) => _manager = manager;

    public UndoManager? Manager => _manager;

    public T Perform<T>(string actionName, Func<T> work)
    {
        var manager = _manager;
        if (manager is null || manager.IsUndoing || manager.IsRedoing)
        {
            return work();
        }
        if (_transactionActive) return work();

        var initialGroupingLevel = manager.GroupingLevel;
        _transactionActive = true;
        _transactionGroupOpened = false;
        try
        {
            return work();
        }
        finally
        {
            var groupOpened = _transactionGroupOpened;
            _transactionActive = false;
            _transactionGroupOpened = false;
            if (groupOpened)
            {
                manager.SetActionName(actionName);
                manager.EndUndoGrouping();
            }
            System.Diagnostics.Debug.Assert(manager.GroupingLevel == initialGroupingLevel);
        }
    }

    public void Perform(string actionName, Action work)
        => Perform<object?>(actionName, () =>
        {
            work();
            return null;
        });

    public void Register(string actionName, Action handler)
    {
        var manager = _manager;
        if (manager is null || !manager.IsUndoRegistrationEnabled) return;
        if (!_transactionActive && !manager.IsUndoing && !manager.IsRedoing)
        {
            Perform(actionName, () => Register(actionName, handler));
            return;
        }
        if (_transactionActive && !_transactionGroupOpened)
        {
            manager.BeginUndoGrouping();
            _transactionGroupOpened = true;
        }
        manager.RegisterUndo(handler);
    }

    public T WithoutRegistration<T>(Func<T> work)
    {
        var manager = _manager;
        if (manager is null || !manager.IsUndoRegistrationEnabled)
        {
            return work();
        }
        manager.DisableUndoRegistration();
        try
        {
            return work();
        }
        finally
        {
            manager.EnableUndoRegistration();
        }
    }

    public void WithoutRegistration(Action work)
        => WithoutRegistration<object?>(() =>
        {
            work();
            return null;
        });

    public bool IsRegistrationEnabled => _manager?.IsUndoRegistrationEnabled ?? true;

    public string? UndoLatest()
    {
        var manager = _manager;
        if (manager is null || !manager.CanUndo) return null;
        var actionName = manager.UndoActionName;
        manager.Undo();
        return actionName;
    }
}
