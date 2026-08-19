namespace PalmierPro.Core.Project;

/// <summary>
/// Gates live .palmier package media mutations against saves and close, mirroring the
/// Mac ProjectPackageCoordinator: mutations queued during a save run when the save
/// succeeds (or are cancelled when it fails), and no new mutation is admitted after
/// closing begins.
/// </summary>
public sealed class ProjectPackageCoordinator
{
    private readonly object _lock = new();
    private int _savesInProgress;
    private int _activeMutations;
    private bool _isClosing;
    private readonly List<PendingMutation> _pendingMutations = [];
    private readonly List<TaskCompletionSource> _idleWaiters = [];

    private sealed record PendingMutation(TaskCompletionSource Ready, CancellationTokenRegistration Registration);

    public void SaveStarted()
    {
        lock (_lock) _savesInProgress++;
    }

    public void SaveFinished(bool success)
    {
        List<PendingMutation> pending;
        lock (_lock)
        {
            _savesInProgress = Math.Max(0, _savesInProgress - 1);
            if (_savesInProgress > 0) return;
            pending = [.. _pendingMutations];
            _pendingMutations.Clear();
            ResumeIdleWaitersIfIdleLocked();
        }
        foreach (var mutation in pending)
        {
            mutation.Registration.Dispose();
            if (success) mutation.Ready.TrySetResult();
            else mutation.Ready.TrySetCanceled();
        }
    }

    /// <summary>Admits package work. Throws when cancelled or when closing has begun.</summary>
    public void BeginMutation(CancellationToken ct = default)
    {
        ct.ThrowIfCancellationRequested();
        lock (_lock)
        {
            if (_isClosing) throw new OperationCanceledException("Project is closing.");
            _activeMutations++;
        }
    }

    public void EndMutation()
    {
        lock (_lock)
        {
            _activeMutations = Math.Max(0, _activeMutations - 1);
            ResumeIdleWaitersIfIdleLocked();
        }
    }

    /// <summary>
    /// Runs the operation immediately when no save is in flight; otherwise defers it
    /// until the last concurrent save completes successfully. A failed save cancels
    /// all deferred operations.
    /// </summary>
    public async Task<T> PerformMutationAsync<T>(Func<T> operation, CancellationToken ct = default)
    {
        ct.ThrowIfCancellationRequested();
        Task? readyTask = null;
        lock (_lock)
        {
            if (_savesInProgress > 0)
            {
                var ready = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
                PendingMutation? pendingEntry = null;
                var registration = ct.Register(() =>
                {
                    lock (_lock)
                    {
                        if (pendingEntry is not null) _pendingMutations.Remove(pendingEntry);
                    }
                    ready.TrySetCanceled(ct);
                });
                pendingEntry = new PendingMutation(ready, registration);
                _pendingMutations.Add(pendingEntry);
                readyTask = ready.Task;
            }
        }
        if (readyTask is not null)
        {
            await readyTask.ConfigureAwait(false);
            ct.ThrowIfCancellationRequested();
        }
        return operation();
    }

    /// <summary>Marks the project as closing and waits for admitted work to finish.</summary>
    public Task BeginClosingAsync()
    {
        lock (_lock) _isClosing = true;
        return WaitUntilIdleAsync();
    }

    /// <summary>Re-opens admission after a failed close so mutations can proceed again.</summary>
    public void CancelClosing()
    {
        lock (_lock) _isClosing = false;
    }

    public Task WaitUntilIdleAsync()
    {
        lock (_lock)
        {
            if (IsIdleLocked) return Task.CompletedTask;
            var waiter = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            _idleWaiters.Add(waiter);
            return waiter.Task;
        }
    }

    private bool IsIdleLocked => _activeMutations == 0 && _savesInProgress == 0;

    private void ResumeIdleWaitersIfIdleLocked()
    {
        if (!IsIdleLocked || _idleWaiters.Count == 0) return;
        var waiters = _idleWaiters.ToArray();
        _idleWaiters.Clear();
        foreach (var waiter in waiters) waiter.TrySetResult();
    }
}
