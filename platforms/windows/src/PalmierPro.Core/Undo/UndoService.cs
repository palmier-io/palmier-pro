namespace PalmierPro.Core.Undo;

/// Per-instance port of NSUndoManager, sized to how the Mac app actually drives it (see
/// EditorViewModel+ClipMutations.swift's swap pattern): a handler registered via RegisterUndo
/// re-registers its own inverse when it runs, so Undo/Redo alternate forever without the
/// caller tracking direction. One instance per document — never shared/static.
///
/// STAGE C HANDOFF: several Mac flows register multiple *separate* top-level undos for one
/// logical user action and rely on NSUndoManager's default groupsByEvent to coalesce them into a
/// single Cmd-Z — e.g. splitAtPlayhead (EditorViewModel+ClipMutations.swift:656) loops calling
/// splitClip per selected clip, and trimStartToPlayhead/trimEndToPlayhead (lines 662-682) loop
/// per-clip trims — where each iteration opens/closes its own undo group. A literal line-by-line
/// port of those loops will push N separate groups here instead of one, so undoing takes N
/// presses. Either wrap each such loop in an explicit BeginGrouping()/EndGrouping() pair (the
/// nested-grouping path already collapses inner groups correctly — see
/// UndoServiceTests.NestedGroupsCollapseToOneUndoStep), or opt into <see cref="GroupsByEvent"/>
/// and call <see cref="FlushEventGrouping"/> once per processed UI event.
public sealed class UndoService
{
    private sealed class UndoGroup
    {
        private string? _defaultName;
        private string? _explicitName;

        public List<Action> Handlers { get; } = [];

        public string ActionName => _explicitName ?? _defaultName ?? string.Empty;

        public void RegisterDefaultName(string name) => _defaultName ??= name;

        public void SetExplicitName(string name) => _explicitName = name;

        /// Absorbs another group's handlers (in order) and name, without letting an already-set
        /// default/explicit name here be clobbered by an absent one on `other`. Used to coalesce
        /// several independently-pushed top-level groups into one event-level group.
        public void MergeFrom(UndoGroup other)
        {
            Handlers.AddRange(other.Handlers);
            if (other._defaultName is not null)
            {
                RegisterDefaultName(other._defaultName);
            }
            if (other._explicitName is not null)
            {
                SetExplicitName(other._explicitName);
            }
        }
    }

    private readonly Stack<UndoGroup> _undoStack = new();
    private readonly Stack<UndoGroup> _redoStack = new();

    /// Nested BeginGrouping/EndGrouping calls all accumulate into this single group — only the
    /// outermost EndGrouping pushes it, so nesting collapses to one undo/redo step.
    private UndoGroup? _openGroup;
    private int _groupingLevel;
    private int _disableCount;
    private bool _isUndoing;
    private bool _isRedoing;

    /// Ambient group accumulating top-level pushes while <see cref="GroupsByEvent"/> is on;
    /// committed to the undo stack by <see cref="FlushEventGrouping"/>.
    private UndoGroup? _eventGroup;
    private bool _groupsByEvent;

    /// Fires on any mutation to CanUndo/CanRedo/UndoActionName/RedoActionName — i.e. a stack
    /// push/pop or a rename of the group currently on top of a stack. Bind menu items/dirty
    /// tracking to this.
    public event EventHandler? Changed;

    public bool IsRegistrationEnabled => _disableCount == 0;
    public bool IsUndoing => _isUndoing;
    public bool IsRedoing => _isRedoing;
    public int GroupingLevel => _groupingLevel;

    /// Port of NSUndoManager.groupsByEvent, which the Mac app reads and toggles (see
    /// ToolExecutor.swift:330-339). Real NSUndoManager defaults this to true and auto-closes the
    /// ambient group via a run-loop observer at the end of each processed UI event; this port has
    /// no run loop to observe, so it defaults to **false** (every top-level push commits
    /// immediately, matching every RegisterUndo call site that predates this property) and a host
    /// that opts in by setting this true MUST call <see cref="FlushEventGrouping"/> once per
    /// processed event/dispatch to get the same coalescing. Turning it off flushes whatever is
    /// still pending so no registration is silently lost.
    public bool GroupsByEvent
    {
        get => _groupsByEvent;
        set
        {
            if (_groupsByEvent == value)
            {
                return;
            }
            _groupsByEvent = value;
            if (!value)
            {
                FlushEventGrouping();
            }
        }
    }

    public bool CanUndo => _undoStack.Count > 0;
    public bool CanRedo => _redoStack.Count > 0;
    public string? UndoActionName => _undoStack.Count > 0 ? _undoStack.Peek().ActionName : null;
    public string? RedoActionName => _redoStack.Count > 0 ? _redoStack.Peek().ActionName : null;

    /// No-op while IsRegistrationEnabled is false. Invoked DURING Undo() this lands on the redo
    /// stack instead of the undo stack, and vice versa during Redo() — that's what lets a handler
    /// re-register its own inverse and have it end up in the right place.
    public void RegisterUndo(string actionName, Action handler)
    {
        ArgumentNullException.ThrowIfNull(actionName);
        ArgumentNullException.ThrowIfNull(handler);
        if (!IsRegistrationEnabled)
        {
            return;
        }

        if (_groupingLevel > 0)
        {
            _openGroup!.Handlers.Add(handler);
            _openGroup.RegisterDefaultName(actionName);
            return;
        }

        var group = new UndoGroup();
        group.Handlers.Add(handler);
        group.RegisterDefaultName(actionName);
        PushGroup(group);
    }

    public void BeginGrouping()
    {
        _groupingLevel++;
        _openGroup ??= new UndoGroup();
    }

    public void EndGrouping()
    {
        if (_groupingLevel == 0)
        {
            throw new InvalidOperationException("EndGrouping() called without a matching BeginGrouping().");
        }
        _groupingLevel--;
        if (_groupingLevel == 0)
        {
            var group = _openGroup!;
            _openGroup = null;
            // NSUndoManager silently drops a group that ended up empty (e.g. a guarded mutation
            // that turned out to be a no-op) rather than pushing a dead undo step.
            if (group.Handlers.Count > 0)
            {
                PushGroup(group);
            }
        }
    }

    /// Sets the display name of whichever group is currently forming: the open explicit/implicit
    /// group if one is open, otherwise the group most recently pushed (mirrors the Mac call sites
    /// that call this right after registerUndo/endUndoGrouping, still targeting that same step).
    /// An explicit call always wins over the name a RegisterUndo call defaulted in.
    public void SetActionName(string actionName)
    {
        ArgumentNullException.ThrowIfNull(actionName);
        if (_groupingLevel > 0)
        {
            _openGroup!.SetExplicitName(actionName);
            return;
        }
        if (_eventGroup is not null)
        {
            _eventGroup.SetExplicitName(actionName);
            return;
        }
        var stack = _isUndoing ? _redoStack : _undoStack;
        if (stack.Count == 0)
        {
            return;
        }
        stack.Peek().SetExplicitName(actionName);
        RaiseChanged();
    }

    public void DisableRegistration() => _disableCount++;

    public void EnableRegistration()
    {
        if (_disableCount > 0)
        {
            _disableCount--;
        }
    }

    public void Undo()
    {
        if (_groupingLevel > 0)
        {
            throw new InvalidOperationException("Undo() called while an undo group is still open.");
        }
        if (_undoStack.Count == 0)
        {
            return;
        }

        var group = _undoStack.Pop();
        RaiseChanged();

        _isUndoing = true;
        BeginGrouping();
        try
        {
            // Reverse of registration order: the most recently registered sub-action must be
            // unwound first (see splitClips's multi-split groups for why this matters structurally).
            for (var i = group.Handlers.Count - 1; i >= 0; i--)
            {
                group.Handlers[i]();
            }
        }
        finally
        {
            EndGrouping();
            _isUndoing = false;
        }
    }

    public void Redo()
    {
        if (_groupingLevel > 0)
        {
            throw new InvalidOperationException("Redo() called while an undo group is still open.");
        }
        if (_redoStack.Count == 0)
        {
            return;
        }

        var group = _redoStack.Pop();
        RaiseChanged();

        _isRedoing = true;
        BeginGrouping();
        try
        {
            for (var i = group.Handlers.Count - 1; i >= 0; i--)
            {
                group.Handlers[i]();
            }
        }
        finally
        {
            EndGrouping();
            _isRedoing = false;
        }
    }

    private void PushGroup(UndoGroup group)
    {
        // Registrations made *during* Undo()/Redo() are the swap pattern re-registering the
        // inverse; they must land immediately on the stack they're not currently draining from,
        // bypassing event-grouping (that coalescing only applies to genuinely new user actions).
        if (_isUndoing || _isRedoing)
        {
            (_isUndoing ? _redoStack : _undoStack).Push(group);
            RaiseChanged();
            return;
        }

        // A fresh registration outside of Undo()/Redo() processing invalidates redo history.
        _redoStack.Clear();

        if (_groupsByEvent)
        {
            if (_eventGroup is null)
            {
                _eventGroup = group;
            }
            else
            {
                _eventGroup.MergeFrom(group);
            }
            RaiseChanged();
            return;
        }

        _undoStack.Push(group);
        RaiseChanged();
    }

    /// Commits the ambient event-level group accumulated while <see cref="GroupsByEvent"/> is on
    /// as a single undo step — the explicit substitute for NSUndoManager's run-loop-driven
    /// auto-coalescing. Call once per processed UI event/dispatch (e.g. after a command handler
    /// returns). No-op if nothing has accumulated.
    public void FlushEventGrouping()
    {
        if (_eventGroup is null)
        {
            return;
        }
        var group = _eventGroup;
        _eventGroup = null;
        _undoStack.Push(group);
        RaiseChanged();
    }

    private void RaiseChanged() => Changed?.Invoke(this, EventArgs.Empty);
}
