namespace PalmierPro.Core.Concurrency;

/// <summary>Async concurrency gate for decoder / inference fan-out (Mac AsyncSemaphore parity).</summary>
public sealed class AsyncSemaphore : IAsyncDisposable
{
    private readonly SemaphoreSlim _slim;

    public AsyncSemaphore(int maxCount)
    {
        if (maxCount < 1) throw new ArgumentOutOfRangeException(nameof(maxCount));
        _slim = new SemaphoreSlim(maxCount, maxCount);
    }

    public async Task<IDisposable> WaitAsync(CancellationToken ct = default)
    {
        await _slim.WaitAsync(ct).ConfigureAwait(false);
        return new Releaser(_slim);
    }

    public ValueTask DisposeAsync()
    {
        _slim.Dispose();
        return ValueTask.CompletedTask;
    }

    private sealed class Releaser(SemaphoreSlim slim) : IDisposable
    {
        private int _released;
        public void Dispose()
        {
            if (Interlocked.Exchange(ref _released, 1) == 0)
                slim.Release();
        }
    }
}
