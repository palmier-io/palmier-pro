namespace PalmierPro.Core.Undo;

/// <summary>
/// NSUndoManager-equivalent: grouped undo registration with action names,
/// where registrations made during Undo() populate the redo stack and vice versa.
/// Single-threaded by contract — call only from the UI thread.
/// </summary>
public sealed class UndoManager
{
    private sealed class Group
    {
        public string? ActionName;
        public readonly List<Action> Actions = [];
        public readonly List<Group> Children = [];

        public bool IsEmpty => Actions.Count == 0 && Children.All(c => c.IsEmpty);

        public void Invoke()
        {
            // LIFO across nested registrations, matching NSUndoManager.
            var items = new List<(int Order, Action Action)>();
            var order = 0;
            foreach (var action in Actions) items.Add((order++, action));
            foreach (var child in Children) items.Add((order++, child.Invoke));
            for (var i = items.Count - 1; i >= 0; i--) items[i].Action();
        }
    }

    private readonly List<Group> _undoStack = [];
    private readonly List<Group> _redoStack = [];
    private readonly Stack<Group> _openGroups = new();
    private int _disableCount;
    private string? _pendingActionName;

    public bool IsUndoing { get; private set; }
    public bool IsRedoing { get; private set; }
    public bool GroupsByEvent { get; set; }
    public int LevelsOfUndo { get; set; } = 0;

    public int GroupingLevel => _openGroups.Count;
    public bool IsUndoRegistrationEnabled => _disableCount == 0;

    public bool CanUndo => _undoStack.Count > 0 || _openGroups.Count > 0;
    public bool CanRedo => _redoStack.Count > 0;

    public string UndoActionName => _undoStack.Count > 0 ? _undoStack[^1].ActionName ?? "" : "";
    public string RedoActionName => _redoStack.Count > 0 ? _redoStack[^1].ActionName ?? "" : "";

    public event Action? StacksChanged;

    public void BeginUndoGrouping() => _openGroups.Push(new Group());

    public void EndUndoGrouping()
    {
        if (_openGroups.Count == 0) throw new InvalidOperationException("endUndoGrouping without matching begin");
        var group = _openGroups.Pop();
        group.ActionName ??= _pendingActionName;
        _pendingActionName = null;
        if (group.IsEmpty) return;

        if (_openGroups.Count > 0)
        {
            _openGroups.Peek().Children.Add(group);
            return;
        }

        var target = IsUndoing ? _redoStack : _undoStack;
        target.Add(group);
        if (!IsUndoing && !IsRedoing)
        {
            _redoStack.Clear();
        }
        if (LevelsOfUndo > 0)
        {
            while (_undoStack.Count > LevelsOfUndo) _undoStack.RemoveAt(0);
        }
        StacksChanged?.Invoke();
    }

    public void SetActionName(string name)
    {
        if (_openGroups.Count > 0) _openGroups.Peek().ActionName = name;
        else _pendingActionName = name;
    }

    public void RegisterUndo(Action handler)
    {
        if (!IsUndoRegistrationEnabled) return;
        if (_openGroups.Count > 0)
        {
            _openGroups.Peek().Actions.Add(handler);
            return;
        }
        // Registration outside a group forms its own top-level group.
        BeginUndoGrouping();
        _openGroups.Peek().Actions.Add(handler);
        EndUndoGrouping();
    }

    public void DisableUndoRegistration() => _disableCount += 1;

    public void EnableUndoRegistration()
    {
        if (_disableCount == 0) throw new InvalidOperationException("enableUndoRegistration not paired");
        _disableCount -= 1;
    }

    public void Undo()
    {
        if (_openGroups.Count > 0) throw new InvalidOperationException("undo with open group");
        if (_undoStack.Count == 0) return;
        var group = _undoStack[^1];
        _undoStack.RemoveAt(_undoStack.Count - 1);
        IsUndoing = true;
        BeginUndoGrouping();
        SetActionName(group.ActionName ?? "");
        try
        {
            group.Invoke();
        }
        finally
        {
            EndUndoGrouping();
            IsUndoing = false;
        }
        StacksChanged?.Invoke();
    }

    public void Redo()
    {
        if (_redoStack.Count == 0) return;
        var group = _redoStack[^1];
        _redoStack.RemoveAt(_redoStack.Count - 1);
        IsRedoing = true;
        BeginUndoGrouping();
        SetActionName(group.ActionName ?? "");
        try
        {
            group.Invoke();
        }
        finally
        {
            EndUndoGrouping();
            IsRedoing = false;
        }
        StacksChanged?.Invoke();
    }

    public void RemoveAllActions()
    {
        _undoStack.Clear();
        _redoStack.Clear();
        _openGroups.Clear();
        StacksChanged?.Invoke();
    }
}
