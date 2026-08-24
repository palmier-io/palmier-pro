namespace PalmierPro.Core.Export;

/// <summary>
/// Serial export queue (one active job). Mirrors Mac ExportQueue: destination reservation,
/// status transitions, cancellation before/during render, and completion callbacks.
/// The actual encoder is injected so Core stays free of Media Foundation.
/// </summary>
public sealed class ExportQueue
{
    private readonly object _lock = new();
    private readonly List<ExportJob> _jobs = [];
    private readonly Queue<ExportJob> _pending = new();
    private readonly HashSet<string> _reservedDestinations = new(StringComparer.OrdinalIgnoreCase);
    private ExportJob? _active;
    private CancellationTokenSource? _activeCts;
    private readonly Func<ExportJob, CancellationToken, IProgress<double>, Task<ExportRunReport>> _runner;

    public event Action? Changed;

    public ExportQueue(Func<ExportJob, CancellationToken, IProgress<double>, Task<ExportRunReport>> runner)
    {
        _runner = runner;
    }

    public IReadOnlyList<ExportJob> Jobs
    {
        get { lock (_lock) return _jobs.ToList(); }
    }

    public ExportJob Enqueue(ExportRequest request)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(request.OutputPath);
        var job = new ExportJob
        {
            ProjectId = request.ProjectId,
            Filename = request.Filename,
            OutputPath = Path.GetFullPath(request.OutputPath),
            Format = request.Format,
            Resolution = request.Resolution,
            Source = request.Source,
            TimelineId = request.TimelineId,
            Quality = request.Quality,
        };

        lock (_lock)
        {
            var exists = File.Exists(job.OutputPath) || Directory.Exists(job.OutputPath);
            if (!request.Overwrite && exists)
                throw new IOException($"Destination already exists: {job.OutputPath}");
            if (!_reservedDestinations.Add(job.OutputPath))
                throw new IOException($"Another export already targets {job.OutputPath}");
            _jobs.Insert(0, job);
            _pending.Enqueue(job);
        }
        Changed?.Invoke();
        _ = DrainAsync();
        return job;
    }

    public bool Cancel(string jobId)
    {
        lock (_lock)
        {
            var job = _jobs.FirstOrDefault(j => j.Id == jobId);
            if (job is null) return false;
            if (job.Status is ExportJobStatus.Completed or ExportJobStatus.Failed or ExportJobStatus.Canceled)
                return false;

            if (_active?.Id == jobId)
            {
                job.Status = ExportJobStatus.Canceling;
                _activeCts?.Cancel();
                Changed?.Invoke();
                return true;
            }

            // Still queued — drop without starting.
            job.Status = ExportJobStatus.Canceled;
            job.CompletedAt = DateTimeOffset.UtcNow;
            _reservedDestinations.Remove(job.OutputPath);
            // Rebuild pending without this job.
            var remaining = _pending.Where(j => j.Id != jobId).ToList();
            _pending.Clear();
            foreach (var j in remaining) _pending.Enqueue(j);
            Changed?.Invoke();
            return true;
        }
    }

    private async Task DrainAsync()
    {
        while (true)
        {
            ExportJob job;
            CancellationTokenSource cts;
            lock (_lock)
            {
                if (_active is not null || _pending.Count == 0) return;
                job = _pending.Dequeue();
                _active = job;
                cts = new CancellationTokenSource();
                _activeCts = cts;
                job.Status = ExportJobStatus.Preparing;
            }
            Changed?.Invoke();

            try
            {
                var progress = new Progress<double>(p =>
                {
                    lock (_lock)
                    {
                        if (_active?.Id != job.Id) return;
                        job.Status = ExportJobStatus.Rendering;
                        job.Progress = Math.Clamp(p, 0, 1);
                    }
                    Changed?.Invoke();
                });

                var report = await _runner(job, cts.Token, progress).ConfigureAwait(false);
                lock (_lock)
                {
                    job.Warnings.AddRange(report.Warnings);
                    job.Status = ExportJobStatus.Completed;
                    job.Progress = 1;
                    job.CompletedAt = DateTimeOffset.UtcNow;
                }
            }
            catch (OperationCanceledException)
            {
                lock (_lock)
                {
                    job.Status = ExportJobStatus.Canceled;
                    job.CompletedAt = DateTimeOffset.UtcNow;
                }
                TryDelete(job.OutputPath);
            }
            catch (Exception ex)
            {
                lock (_lock)
                {
                    job.Status = ExportJobStatus.Failed;
                    job.Error = ex.Message;
                    job.CompletedAt = DateTimeOffset.UtcNow;
                }
                TryDelete(job.OutputPath);
            }
            finally
            {
                lock (_lock)
                {
                    _reservedDestinations.Remove(job.OutputPath);
                    if (_active?.Id == job.Id) _active = null;
                    _activeCts?.Dispose();
                    _activeCts = null;
                }
                Changed?.Invoke();
            }
        }
    }

    private static void TryDelete(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); } catch { /* best-effort cleanup */ }
    }
}
