using System.Text.Json;
using System.Text.Json.Serialization;
using PalmierPro.Rendering;

namespace PalmierPro.Services.Media;

/// One filmstrip tile — BGRA8, top-down, matching `PE_ThumbnailCallback`'s layout.
public readonly record struct CachedThumbnail(double TimeSeconds, byte[] Bgra, int Width, int Height, int StrideBytes);

public sealed class ThumbnailsUpdatedEventArgs(string mediaRef, IReadOnlyList<CachedThumbnail> thumbnails, bool isComplete) : EventArgs
{
    public string MediaRef { get; } = mediaRef;
    public IReadOnlyList<CachedThumbnail> Thumbnails { get; } = thumbnails;
    /// False on a progressive partial (mirrors the Mac's every-50-frames publish); true on the
    /// final publish for this generation run, whether it came from live extraction or disk cache.
    public bool IsComplete { get; } = isComplete;
}

public sealed class WaveformReadyEventArgs(string mediaRef, float[] samples) : EventArgs
{
    public string MediaRef { get; } = mediaRef;
    public float[] Samples { get; } = samples;
}

/// Ports the filmstrip/waveform half of `Timeline/MediaVisualCache.swift` (speech/beat masks are
/// Mac-only AI features, out of scope for this port). Differences from the Mac version, all
/// deliberate:
/// - Generation goes through PalmierEngine (<see cref="EngineSession"/>/<see cref="MediaSource"/>)
///   instead of AVFoundation; the dB normalization math itself already lives in
///   <see cref="WaveformContract"/>, ported verbatim from `WaveformExtractor.swift` and applied by
///   `MediaSource.ExtractPeakEnvelope` before it ever reaches this class.
/// - `PE_ExtractThumbnails` scales to the exact requested size it's given — unlike
///   AVAssetImageGenerator's `maximumSize`, it has no aspect-fit box of its own — so
///   <see cref="FitThumbnailSize"/> computes an aspect-preserving, never-upscaled request size
///   from the source's own dimensions before calling it (mirrors `maximumSize` = <see
///   cref="ThumbnailWidth"/>x<see cref="ThumbnailHeight"/> as a bounding box, not a forced
///   stretch). Every tile for a given source still shares one size (all requested at once, off
///   one `media.Info`), so sprite packing keys off `thumbs[0].Width/Height` exactly as before —
///   just not the same literal constant for every source anymore.
/// - Memory is capped by an LRU (the Mac's dictionaries never evict); disk cache is the same
///   (path, size, mtime)-keyed sprite-sheet-JPEG-plus-JSON-sidecar shape.
public sealed class MediaVisualCache : IDisposable
{
    public const int ThumbnailWidth = 120;
    public const int ThumbnailHeight = 68;
    private const int SpriteColumns = 50; // mirrors MediaVisualCache.swift's `min(50, thumbs.count)`
    private const int ProgressivePublishInterval = 50; // mirrors Mac's `results.count % 50 == 0`
    private const double JpegQuality = 0.75;

    private readonly Func<string, MediaSource> _openMedia;
    private readonly Func<string, int, int, byte[]> _renderLottieThumbnail;
    private readonly DiskCache _diskCache;
    private readonly Lock _gate = new();
    private readonly LruCache<string, IReadOnlyList<CachedThumbnail>> _thumbnailMemory;
    private readonly LruCache<string, float[]> _waveformMemory;
    private readonly HashSet<string> _thumbnailInFlight = [];
    private readonly HashSet<string> _waveformInFlight = [];

    public event EventHandler<ThumbnailsUpdatedEventArgs>? ThumbnailsUpdated;
    public event EventHandler<WaveformReadyEventArgs>? WaveformReady;

    public MediaVisualCache(EngineSession session, DiskCache? diskCache = null, int thumbnailMemoryCapacity = 64, int waveformMemoryCapacity = 128)
        : this(session.OpenMedia, LottieThumbnail.Render, diskCache, thumbnailMemoryCapacity, waveformMemoryCapacity)
    {
    }

    /// Seam used by tests to count/observe every native `OpenMedia` call (e.g. to prove a second
    /// request is served from disk without re-extracting) without needing a native session at all
    /// for pure-math tests.
    public MediaVisualCache(
        Func<string, MediaSource> openMedia,
        DiskCache? diskCache = null,
        int thumbnailMemoryCapacity = 64,
        int waveformMemoryCapacity = 128)
        : this(openMedia, LottieThumbnail.Render, diskCache, thumbnailMemoryCapacity, waveformMemoryCapacity)
    {
    }

    /// Seam variant that additionally fakes <see cref="LottieThumbnail.Render"/> — used by
    /// <see cref="GenerateLottieThumbnail"/>'s own tests (docs/lottie-bake-v1.md §11's follow-up:
    /// no disk-cached bake involved, just a single rasterized frame via the vendored ThorVG
    /// rasterizer).
    public MediaVisualCache(
        Func<string, MediaSource> openMedia,
        Func<string, int, int, byte[]> renderLottieThumbnail,
        DiskCache? diskCache = null,
        int thumbnailMemoryCapacity = 64,
        int waveformMemoryCapacity = 128)
    {
        _openMedia = openMedia;
        _renderLottieThumbnail = renderLottieThumbnail;
        _diskCache = diskCache ?? new DiskCache("MediaVisualCache");
        _thumbnailMemory = new LruCache<string, IReadOnlyList<CachedThumbnail>>(thumbnailMemoryCapacity);
        _waveformMemory = new LruCache<string, float[]>(waveformMemoryCapacity);
    }

    // ===== Sync lookups (memory only — safe to call from a draw/layout pass) =====

    public IReadOnlyList<CachedThumbnail>? Thumbnails(string mediaRef)
    {
        lock (_gate)
        {
            return _thumbnailMemory.TryGet(mediaRef, out var value) ? value : null;
        }
    }

    public float[]? Waveform(string mediaRef)
    {
        lock (_gate)
        {
            return _waveformMemory.TryGet(mediaRef, out var value) ? value : null;
        }
    }

    /// Clears cached visuals for `mediaRef` (memory only — the disk cache stays, since it's keyed
    /// on the source file's own identity and self-invalidates on edit) so relinked media
    /// regenerates. Mirrors `invalidate(_:)`.
    public void Invalidate(string mediaRef)
    {
        lock (_gate)
        {
            _thumbnailMemory.Remove(mediaRef);
            _waveformMemory.Remove(mediaRef);
        }
    }

    public void ResetSessionState()
    {
        lock (_gate)
        {
            _thumbnailMemory.Clear();
            _waveformMemory.Clear();
        }
    }

    // ===== Async generation =====

    /// Fire-and-forget, like the Mac's `generateVideoThumbnails(for:)` — progress and completion
    /// surface via <see cref="ThumbnailsUpdated"/>, not the call's own (unawaited) `Task`.
    public void GenerateVideoThumbnails(string mediaRef, string path, CancellationToken ct = default)
    {
        lock (_gate)
        {
            if (_thumbnailMemory.TryGet(mediaRef, out _) || !_thumbnailInFlight.Add(mediaRef))
            {
                return;
            }
        }
        _ = RunGenerateVideoThumbnailsAsync(mediaRef, path, ct);
    }

    public void GenerateWaveform(string mediaRef, string path, CancellationToken ct = default)
    {
        lock (_gate)
        {
            if (_waveformMemory.TryGet(mediaRef, out _) || !_waveformInFlight.Add(mediaRef))
            {
                return;
            }
        }
        _ = RunGenerateWaveformAsync(mediaRef, path, ct);
    }

    /// Media-panel filmstrip tile for a `ClipType.Lottie` asset, via the same vendored ThorVG
    /// rasterizer the bake pipeline uses (native `PE_RenderLottieThumbnail`) — a single frame-0
    /// tile, not a disk-cached bake (docs/lottie-bake-v1.md §11 names this a scoped-out follow-up
    /// of that document; implemented here as a small, additive addition). Memory-cached only
    /// (unlike <see cref="GenerateVideoThumbnails"/>'s sprite-sheet disk cache) — alpha must
    /// survive for a correctly-composited tile, and this assembly has no alpha-preserving disk
    /// image codec yet (<see cref="WicImaging"/> only writes JPEG); regenerating once per session
    /// is a minor perf cost, not a correctness one. Shares <see cref="_thumbnailInFlight"/>'s dedup
    /// set with the video path — a given MediaRef is only ever one ClipType, so no collision risk.
    public void GenerateLottieThumbnail(string mediaRef, string path, CancellationToken ct = default)
    {
        lock (_gate)
        {
            if (_thumbnailMemory.TryGet(mediaRef, out _) || !_thumbnailInFlight.Add(mediaRef))
            {
                return;
            }
        }
        _ = RunGenerateLottieThumbnailAsync(mediaRef, path, ct);
    }

    private async Task RunGenerateVideoThumbnailsAsync(string mediaRef, string path, CancellationToken ct)
    {
        try
        {
            string? key = DiskCache.SizeMtimeKey(path);
            List<CachedThumbnail>? cached = key is null ? null : await LoadThumbnailsFromDiskAsync(key).ConfigureAwait(false);
            if (cached is { Count: > 0 })
            {
                Publish(mediaRef, cached, isComplete: true);
                return;
            }

            List<CachedThumbnail>? results;
            // media must be fully disposed — its native handle closed — before the completion
            // Publish below fires. A caller reacting to "isComplete" (e.g. tearing down the
            // EngineSession right after) can complete synchronously/reentrantly off a
            // TaskCompletionSource-style signal, racing PE_CloseMedia against PE_DestroySession
            // if any of media's teardown were still pending past that point. Scoping the `using`
            // to end (and thus dispose) strictly before Publish is what closes that race, not
            // merely "save before publish" — disk-save has the same requirement, hence it's
            // inside this block too.
            using (MediaSource media = _openMedia(path))
            {
                if (!media.Info.HasVideo)
                {
                    return;
                }
                List<double> times = ComputeThumbnailTimes(media.Info.Duration.TotalSeconds);
                if (times.Count == 0)
                {
                    return;
                }

                (int tileWidth, int tileHeight) = FitThumbnailSize(media.Info.Width, media.Info.Height);
                var collected = new List<CachedThumbnail>(times.Count);
                await foreach (ThumbnailResult thumb in media.ExtractThumbnailsAsync(times, tileWidth, tileHeight, ct).ConfigureAwait(false))
                {
                    collected.Add(new CachedThumbnail(thumb.RequestedTimeSeconds, thumb.Bgra, thumb.Width, thumb.Height, thumb.StrideBytes));
                    if (collected.Count % ProgressivePublishInterval == 0)
                    {
                        Publish(mediaRef, [.. collected.OrderBy(t => t.TimeSeconds)], isComplete: false);
                    }
                }
                if (collected.Count == 0)
                {
                    return;
                }
                collected.Sort((a, b) => a.TimeSeconds.CompareTo(b.TimeSeconds));
                if (key is not null)
                {
                    await SaveThumbnailsToDiskAsync(key, collected).ConfigureAwait(false);
                }
                results = collected;
            }
            Publish(mediaRef, results, isComplete: true);
        }
        catch (OperationCanceledException)
        {
        }
        catch (EngineException)
        {
        }
        finally
        {
            lock (_gate)
            {
                _thumbnailInFlight.Remove(mediaRef);
            }
        }
    }

    private async Task RunGenerateWaveformAsync(string mediaRef, string path, CancellationToken ct)
    {
        try
        {
            string? key = DiskCache.SizeMtimeKey(path);
            float[]? cached = key is null ? null : LoadWaveformFromDisk(key);
            if (cached is { Length: > 0 })
            {
                Publish(mediaRef, cached);
                return;
            }

            float[] samples;
            // See the matching comment in RunGenerateVideoThumbnailsAsync — media must be fully
            // disposed before the completion Publish, not merely before the disk-save.
            using (MediaSource media = _openMedia(path))
            {
                if (!media.Info.HasAudio)
                {
                    return;
                }
                double duration = media.Info.Duration.TotalSeconds;
                if (duration <= 0)
                {
                    return;
                }

                samples = await Task.Run(() => media.ExtractPeakEnvelope(0, duration), ct).ConfigureAwait(false);
                if (samples.Length == 0)
                {
                    return;
                }
                if (key is not null)
                {
                    SaveWaveformToDisk(key, samples);
                }
            }
            Publish(mediaRef, samples);
        }
        catch (OperationCanceledException)
        {
        }
        catch (EngineException)
        {
        }
        finally
        {
            lock (_gate)
            {
                _waveformInFlight.Remove(mediaRef);
            }
        }
    }

    private async Task RunGenerateLottieThumbnailAsync(string mediaRef, string path, CancellationToken ct)
    {
        try
        {
            byte[] bgra = await Task.Run(() => _renderLottieThumbnail(path, ThumbnailWidth, ThumbnailHeight), ct).ConfigureAwait(false);
            var thumb = new CachedThumbnail(0, bgra, ThumbnailWidth, ThumbnailHeight, ThumbnailWidth * 4);
            Publish(mediaRef, [thumb], isComplete: true);
        }
        catch (OperationCanceledException)
        {
        }
        catch (EngineException)
        {
        }
        finally
        {
            lock (_gate)
            {
                _thumbnailInFlight.Remove(mediaRef);
            }
        }
    }

    private void Publish(string mediaRef, IReadOnlyList<CachedThumbnail> thumbnails, bool isComplete)
    {
        lock (_gate)
        {
            _thumbnailMemory.Set(mediaRef, thumbnails);
        }
        ThumbnailsUpdated?.Invoke(this, new ThumbnailsUpdatedEventArgs(mediaRef, thumbnails, isComplete));
    }

    private void Publish(string mediaRef, float[] samples)
    {
        lock (_gate)
        {
            _waveformMemory.Set(mediaRef, samples);
        }
        WaveformReady?.Invoke(this, new WaveformReadyEventArgs(mediaRef, samples));
    }

    /// Mirrors `videoThumbnailTimes(duration:)` exactly: 1s hops under 10s, 2s hops at/above.
    public static List<double> ComputeThumbnailTimes(double durationSeconds)
    {
        if (!double.IsFinite(durationSeconds) || durationSeconds <= 0)
        {
            return [];
        }
        double interval = durationSeconds < 10 ? 1.0 : 2.0;
        var times = new List<double>();
        for (double t = 0; t < durationSeconds; t += interval)
        {
            times.Add(t);
        }
        return times;
    }

    /// Aspect-fit `sourceWidth`x`sourceHeight` inside <see cref="ThumbnailWidth"/>x
    /// <see cref="ThumbnailHeight"/>, never upscaling — mirrors AVAssetImageGenerator's
    /// `maximumSize` bounding-box semantics (the Mac never stretches a non-16:9 source to fill a
    /// fixed tile; it letterboxes-by-shrinking instead). Falls back to the bounding box itself for
    /// a degenerate (zero/negative) source size.
    public static (int Width, int Height) FitThumbnailSize(int sourceWidth, int sourceHeight)
    {
        if (sourceWidth <= 0 || sourceHeight <= 0)
        {
            return (ThumbnailWidth, ThumbnailHeight);
        }
        double scale = Math.Min(1.0, Math.Min((double)ThumbnailWidth / sourceWidth, (double)ThumbnailHeight / sourceHeight));
        int width = Math.Max(1, (int)Math.Round(sourceWidth * scale, MidpointRounding.AwayFromZero));
        int height = Math.Max(1, (int)Math.Round(sourceHeight * scale, MidpointRounding.AwayFromZero));
        return (width, height);
    }

    // ===== Disk cache =====

    private sealed class SpriteMeta
    {
        [JsonPropertyName("tileWidth")]
        public int TileWidth { get; set; }

        [JsonPropertyName("tileHeight")]
        public int TileHeight { get; set; }

        [JsonPropertyName("columns")]
        public int Columns { get; set; }

        [JsonPropertyName("times")]
        public List<double> Times { get; set; } = [];
    }

    /// Sprite sheet is one JPEG grid + a JSON sidecar; the sidecar is written last, mirroring the
    /// Mac's convention of treating it as the marker of a complete (non-torn) entry.
    private async Task<List<CachedThumbnail>?> LoadThumbnailsFromDiskAsync(string key)
    {
        string metaPath = _diskCache.PathFor(key, ".thumbs.json");
        string imagePath = _diskCache.PathFor(key, ".thumbs.jpg");
        if (!File.Exists(metaPath) || !File.Exists(imagePath))
        {
            return null;
        }

        SpriteMeta? meta;
        try
        {
            meta = JsonSerializer.Deserialize<SpriteMeta>(File.ReadAllBytes(metaPath));
        }
        catch (JsonException)
        {
            return null;
        }
        if (meta is null || meta.TileWidth <= 0 || meta.TileHeight <= 0 || meta.Columns <= 0 || meta.Times.Count == 0)
        {
            return null;
        }

        var decoded = await WicImaging.DecodeToBgraAsync(imagePath).ConfigureAwait(false);
        if (decoded is null)
        {
            return null;
        }
        (byte[] spriteBgra, int spriteWidth, int spriteHeight) = decoded.Value;
        int rows = (meta.Times.Count + meta.Columns - 1) / meta.Columns;
        if (spriteWidth < meta.TileWidth * Math.Min(meta.Columns, meta.Times.Count) || spriteHeight < meta.TileHeight * rows)
        {
            return null;
        }

        int spriteStride = spriteWidth * 4;
        int tileStride = meta.TileWidth * 4;
        var results = new List<CachedThumbnail>(meta.Times.Count);
        for (int i = 0; i < meta.Times.Count; i++)
        {
            int col = i % meta.Columns;
            int row = i / meta.Columns;
            var tile = new byte[tileStride * meta.TileHeight];
            for (int y = 0; y < meta.TileHeight; y++)
            {
                int srcOffset = (row * meta.TileHeight + y) * spriteStride + col * tileStride;
                Buffer.BlockCopy(spriteBgra, srcOffset, tile, y * tileStride, tileStride);
            }
            results.Add(new CachedThumbnail(meta.Times[i], tile, meta.TileWidth, meta.TileHeight, tileStride));
        }
        return results;
    }

    private async Task SaveThumbnailsToDiskAsync(string key, List<CachedThumbnail> thumbs)
    {
        if (thumbs.Count == 0)
        {
            return;
        }
        int tileW = thumbs[0].Width;
        int tileH = thumbs[0].Height;
        int columns = Math.Min(SpriteColumns, thumbs.Count);
        int rows = (thumbs.Count + columns - 1) / columns;
        int spriteW = tileW * columns;
        int spriteH = tileH * rows;
        int spriteStride = spriteW * 4;
        var sprite = new byte[spriteStride * spriteH];

        for (int i = 0; i < thumbs.Count; i++)
        {
            CachedThumbnail t = thumbs[i];
            int col = i % columns;
            int row = i / columns;
            int destX = col * tileW * 4;
            int copyLen = Math.Min(tileW * 4, t.StrideBytes);
            int tileRows = Math.Min(tileH, t.Height);
            for (int y = 0; y < tileRows; y++)
            {
                int destOffset = (row * tileH + y) * spriteStride + destX;
                Buffer.BlockCopy(t.Bgra, y * t.StrideBytes, sprite, destOffset, copyLen);
            }
        }

        byte[]? jpeg = await WicImaging.EncodeBgraAsJpegAsync(sprite, spriteW, spriteH, spriteStride, JpegQuality).ConfigureAwait(false);
        if (jpeg is null)
        {
            return;
        }

        var meta = new SpriteMeta { TileWidth = tileW, TileHeight = tileH, Columns = columns, Times = [.. thumbs.Select(t => t.TimeSeconds)] };
        await File.WriteAllBytesAsync(_diskCache.PathFor(key, ".thumbs.jpg"), jpeg).ConfigureAwait(false);
        await File.WriteAllBytesAsync(_diskCache.PathFor(key, ".thumbs.json"), JsonSerializer.SerializeToUtf8Bytes(meta)).ConfigureAwait(false);
    }

    private float[]? LoadWaveformFromDisk(string key)
    {
        string path = _diskCache.PathFor(key, ".waveform");
        if (!File.Exists(path))
        {
            return null;
        }
        byte[] bytes = File.ReadAllBytes(path);
        if (bytes.Length == 0 || bytes.Length % 4 != 0)
        {
            return null;
        }
        var samples = new float[bytes.Length / 4];
        Buffer.BlockCopy(bytes, 0, samples, 0, bytes.Length);
        return samples;
    }

    private void SaveWaveformToDisk(string key, float[] samples)
    {
        var bytes = new byte[samples.Length * 4];
        Buffer.BlockCopy(samples, 0, bytes, 0, bytes.Length);
        File.WriteAllBytes(_diskCache.PathFor(key, ".waveform"), bytes);
    }

    public void Dispose()
    {
        lock (_gate)
        {
            _thumbnailMemory.Clear();
            _waveformMemory.Clear();
        }
    }
}
