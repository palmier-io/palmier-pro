using PalmierPro.Rendering;

namespace PalmierPro.Services.Media;

/// Concrete <see cref="ILottieBakeService"/> (docs/lottie-bake-v1.md §16 "service" slice): bakes a
/// Lottie/dotLottie source to a disk-cached ProRes 4444 .mov via <see cref="EngineSession.BakeLottieVideo"/>
/// (native ThorVG + `PE_EncodeAlphaVideo*`, §7/§8), keyed by §5's `{contentHash}_{width}x{height}_v{BakeVersion}`.
///
/// Two independent key spaces, deliberately: the disk cache / native-call dedup key (§5) is content
/// hash + size + version — two <see cref="MediaRef"/>s that happen to point at byte-identical source
/// files at the same size share one underlying bake. The public status surface
/// (<see cref="StatusFor"/>/<see cref="StatusChanged"/>) is keyed by (MediaRef, Width, Height) instead,
/// per <see cref="ILottieBakeService"/>'s own signature — it has no source path to hash. Every
/// (MediaRef, Width, Height) currently mapped to a given disk key is notified when that disk key's
/// bake completes/fails, even if only one of them triggered the actual native call.
public sealed class LottieBakeService : ILottieBakeService
{
    /// Bumped whenever a change could alter previously-cached bytes for an unchanged input (a ThorVG
    /// version bump, an encoder-settings change, a bake-logic bug fix) — doc §5.
    public const int BakeVersion = 1;

    private const double HoldTailSeconds = 1800.0; // doc §2/§6 — matches the Mac's constant verbatim.
    private const double MaxEncoderDimension = 4096.0; // doc §6 — mirrored from native's own clamp for key purposes.

    private readonly DiskCache _diskCache;
    private readonly LottieBakeNativeCall _bakeNative;

    private readonly Lock _gate = new();
    private readonly HashSet<string> _diskKeysInFlight = [];
    private readonly Dictionary<(string MediaRef, int Width, int Height), StatusEntry> _status = [];
    private readonly Dictionary<(string MediaRef, int Width, int Height), string> _diskKeyOf = [];

    public event EventHandler<LottieBakeStatusChangedEventArgs>? StatusChanged;

    public LottieBakeService(EngineSession session, DiskCache? diskCache = null)
        : this(
            (lottiePath, width, height, holdTailSeconds, outputPath, ct) =>
                session.BakeLottieVideo(lottiePath, width, height, holdTailSeconds, outputPath, ct: ct),
            diskCache)
    {
    }

    /// Seam used by tests to fake the native call entirely (mirrors <see cref="MediaVisualCache"/>'s
    /// own `openMedia` constructor-overload seam, doc §14) — a fake need only write SOME file to
    /// `outputPath` to simulate success, or throw to simulate failure/cancellation.
    public LottieBakeService(LottieBakeNativeCall bakeNative, DiskCache? diskCache = null)
    {
        _bakeNative = bakeNative;
        _diskCache = diskCache ?? new DiskCache("LottieVideos");
        SweepStaleTempFiles();
    }

    public string? TryGetCachedPath(LottieBakeRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (ComputeDiskKey(request) is not { } diskKey)
        {
            return null;
        }
        string path = _diskCache.PathFor(diskKey, ".mov");
        return File.Exists(path) ? path : null;
    }

    public void BakeAsync(LottieBakeRequest request, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(request);
        var statusKey = (request.MediaRef, request.Width, request.Height);
        if (ComputeDiskKey(request) is not { } diskKey)
        {
            return; // source unreadable — nothing to identify a bake by (matches DiskCache's "no key" discipline).
        }

        lock (_gate)
        {
            _diskKeyOf[statusKey] = diskKey;
        }

        string cachedPath = _diskCache.PathFor(diskKey, ".mov");
        if (File.Exists(cachedPath))
        {
            // "Safe to call even when TryGetCachedPath would already return non-null" (interface
            // doc) — report Completed instead of silently ignoring, so a caller that only ever
            // calls BakeAsync (never TryGetCachedPath itself) still observes the cache hit.
            SetStatus(statusKey, LottieBakeStatus.Completed, cachedPath, null);
            return;
        }

        bool startNative;
        lock (_gate)
        {
            if (_status.TryGetValue(statusKey, out StatusEntry? existing) && existing.Status == LottieBakeStatus.InProgress)
            {
                return; // already tracked in flight for this exact (mediaRef, size)
            }
            startNative = _diskKeysInFlight.Add(diskKey);
        }
        SetStatus(statusKey, LottieBakeStatus.InProgress, null, null);
        if (startNative)
        {
            _ = RunBakeAsync(diskKey, request, cachedPath, ct);
        }
        // else: an identical-content bake is already running under some (possibly different)
        // MediaRef — no second native call (doc §5/§9's dedup), but this statusKey is now
        // registered in _diskKeyOf, so PublishForDiskKey still notifies it on completion.
    }

    public LottieBakeStatus StatusFor(string mediaRef, int width, int height)
    {
        lock (_gate)
        {
            return _status.TryGetValue((mediaRef, width, height), out StatusEntry? entry) ? entry.Status : LottieBakeStatus.NotStarted;
        }
    }

    private async Task RunBakeAsync(string diskKey, LottieBakeRequest request, string cachedPath, CancellationToken ct)
    {
        string tempOutputPath = _diskCache.PathFor($".baking-{Guid.NewGuid():N}", ".mov");
        string? extractDir = null;
        try
        {
            string nativeInputPath = request.SourcePath;
            if (DotLottieExtractor.IsDotLottiePath(request.SourcePath))
            {
                extractDir = Path.Combine(_diskCache.Directory, $".extract-{Guid.NewGuid():N}");
                nativeInputPath = DotLottieExtractor.Extract(request.SourcePath, extractDir, includeAssets: true);
            }

            (int width, int height) = EvenRoundForEncoder(request.Width, request.Height);
            await Task.Run(
                () => _bakeNative(nativeInputPath, width, height, HoldTailSeconds, tempOutputPath, ct),
                ct).ConfigureAwait(false);

            // Atomicity, one level up from native's own temp-file dance (doc §5): re-check "does the
            // real cache path already exist now" right before the move — a second concurrent bake of
            // the identical key racing to completion is tolerated silently (first mover wins).
            if (!File.Exists(cachedPath))
            {
                try
                {
                    File.Move(tempOutputPath, cachedPath);
                }
                catch (IOException) when (File.Exists(cachedPath))
                {
                }
            }
            PublishForDiskKey(diskKey, LottieBakeStatus.Completed, cachedPath, null);
        }
        catch (OperationCanceledException)
        {
            PublishForDiskKey(diskKey, LottieBakeStatus.Failed, null, "cancelled");
        }
        catch (Exception ex)
        {
            // Deliberately catches everything (not just EngineException/IOException/...): leaving
            // status stuck at InProgress forever on an unexpected exception type is a worse outcome
            // than reporting Failed for one — a caller can always retry via a fresh BakeAsync.
            // ObjectDisposedException specifically covers the owning EngineSession/document being
            // torn down mid-bake (app quit, document switch) — inert per doc §13's "app-quit
            // mid-bake" story, not a crash; the next TryGetCachedPath for this key is simply a
            // cache miss.
            PublishForDiskKey(diskKey, LottieBakeStatus.Failed, null, ex.Message);
        }
        finally
        {
            DeleteQuietly(tempOutputPath);
            if (extractDir is not null)
            {
                DeleteDirectoryQuietly(extractDir);
            }
            lock (_gate)
            {
                _diskKeysInFlight.Remove(diskKey);
            }
        }
    }

    /// Notifies every (MediaRef, Width, Height) currently mapped to `diskKey` — see the class
    /// remarks on the two key spaces.
    private void PublishForDiskKey(string diskKey, LottieBakeStatus status, string? outputPath, string? errorMessage)
    {
        List<(string MediaRef, int Width, int Height)> keys;
        lock (_gate)
        {
            keys = [.. _diskKeyOf.Where(kv => kv.Value == diskKey).Select(kv => kv.Key)];
        }
        foreach (var key in keys)
        {
            SetStatus(key, status, outputPath, errorMessage);
        }
    }

    private void SetStatus((string MediaRef, int Width, int Height) key, LottieBakeStatus status, string? outputPath, string? errorMessage)
    {
        lock (_gate)
        {
            _status[key] = new StatusEntry(status, outputPath, errorMessage);
        }
        StatusChanged?.Invoke(this, new LottieBakeStatusChangedEventArgs(key.MediaRef, key.Width, key.Height, status, outputPath, errorMessage));
    }

    private string? ComputeDiskKey(LottieBakeRequest request)
    {
        if (DiskCache.ContentHashKey(request.SourcePath) is not { } contentHash)
        {
            return null;
        }
        (int width, int height) = EvenRoundForEncoder(request.Width, request.Height);
        return $"{contentHash}_{width}x{height}_v{BakeVersion}";
    }

    /// Mirrors native's own `clampedForEncoder`/`even()` (LottieBaker.cpp, doc §6/§8) exactly, so the
    /// cache key's `{width}x{height}` fragment matches the dimensions the bake will actually produce.
    internal static (int Width, int Height) EvenRoundForEncoder(int width, int height)
    {
        double w = Math.Max(1, width);
        double h = Math.Max(1, height);
        double longest = Math.Max(w, h);
        double scale = longest > MaxEncoderDimension ? MaxEncoderDimension / longest : 1.0;
        return (EvenFloor(w * scale), EvenFloor(h * scale));
    }

    private static int EvenFloor(double value)
    {
        int pixels = (int)Math.Floor(value);
        return Math.Max(2, pixels - (pixels % 2));
    }

    /// App-quit-mid-bake hygiene (doc §13) — a `.baking-*.mov`/`.extract-*` left over from an
    /// unclean process exit is inert (never read by anything, real cache entries are only ever
    /// published via the atomic rename above), so an unconditional sweep on construction is safe.
    private void SweepStaleTempFiles()
    {
        try
        {
            foreach (string file in Directory.EnumerateFiles(_diskCache.Directory, ".baking-*.mov"))
            {
                DeleteQuietly(file);
            }
            foreach (string dir in Directory.EnumerateDirectories(_diskCache.Directory, ".extract-*"))
            {
                DeleteDirectoryQuietly(dir);
            }
        }
        catch (IOException)
        {
        }
        catch (UnauthorizedAccessException)
        {
        }
    }

    private static void DeleteQuietly(string path)
    {
        try
        {
            if (File.Exists(path))
            {
                File.Delete(path);
            }
        }
        catch (IOException)
        {
        }
        catch (UnauthorizedAccessException)
        {
        }
    }

    private static void DeleteDirectoryQuietly(string path)
    {
        try
        {
            if (Directory.Exists(path))
            {
                Directory.Delete(path, recursive: true);
            }
        }
        catch (IOException)
        {
        }
        catch (UnauthorizedAccessException)
        {
        }
    }

    private sealed record StatusEntry(LottieBakeStatus Status, string? OutputPath, string? ErrorMessage);
}

/// `(lottiePath, width, height, holdTailSeconds, outputPath, ct) -> void`, throwing on failure/
/// cancellation — the real implementation is <see cref="EngineSession.BakeLottieVideo"/>; tests
/// substitute a fake (doc §14).
public delegate void LottieBakeNativeCall(string lottiePath, int width, int height, double holdTailSeconds, string outputPath, CancellationToken ct);
