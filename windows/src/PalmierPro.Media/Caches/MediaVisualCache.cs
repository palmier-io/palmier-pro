using System.Drawing;
using System.Text.Json;
using PalmierPro.Media.Audio;
using PalmierPro.Media.Images;
using PalmierPro.Media.Video;

namespace PalmierPro.Media.Caches;

/// <summary>A generated timeline filmstrip: one tile per sampled time.</summary>
public sealed record Filmstrip(IReadOnlyList<double> Times, IReadOnlyList<Bitmap> Tiles, int TileWidth, int TileHeight);

/// <summary>
/// Timeline visual cache keyed by asset id, mirroring the Mac MediaVisualCache: video
/// filmstrips (120×68 tiles, 1–2 s spacing), timeline image stills (120 px), and audio
/// peak envelopes, with sprite + sidecar + waveform2 disk persistence.
/// </summary>
public sealed class MediaVisualCache
{
    public const int TileMaxWidth = 120;
    public const int TileMaxHeight = 68;
    public const int ImageStillMaxPixelSize = 120;
    public const int SpriteMaxColumns = 50;
    public const double SpriteJpegQuality = 0.75;
    private const int ProgressivePublishInterval = 50;

    private readonly SemaphoreSlim _videoThumbnailGate = new(2);
    private readonly SemaphoreSlim _imageThumbnailGate = new(4);
    private readonly SemaphoreSlim _waveformGate = new(2);

    private readonly DiskCache _disk = new("MediaVisualCache");

    private readonly object _lock = new();
    private readonly Dictionary<string, Filmstrip> _filmstrips = [];
    private readonly Dictionary<string, Bitmap> _imageStills = [];
    private readonly Dictionary<string, float[]> _waveforms = [];
    private readonly HashSet<string> _inFlight = [];

    /// <summary>Raised (on a worker thread) when visuals for an asset id changed.</summary>
    public event Action<string>? VisualsUpdated;

    public Filmstrip? FilmstripFor(string assetId)
    {
        lock (_lock) return _filmstrips.GetValueOrDefault(assetId);
    }

    public Bitmap? ImageStillFor(string assetId)
    {
        lock (_lock) return _imageStills.GetValueOrDefault(assetId);
    }

    public float[]? WaveformFor(string assetId)
    {
        lock (_lock) return _waveforms.GetValueOrDefault(assetId);
    }

    public void Invalidate(string assetId)
    {
        lock (_lock)
        {
            _filmstrips.Remove(assetId);
            _imageStills.Remove(assetId);
            _waveforms.Remove(assetId);
        }
    }

    public void ResetSessionState()
    {
        lock (_lock)
        {
            _filmstrips.Clear();
            _imageStills.Clear();
            _waveforms.Clear();
        }
        _disk.Clear();
    }

    public async Task GenerateVideoThumbnailsAsync(string assetId, string url, CancellationToken ct = default)
    {
        var jobKey = "film:" + assetId;
        if (!BeginJob(jobKey) || FilmstripFor(assetId) is not null) { EndJob(jobKey); return; }
        try
        {
            await _videoThumbnailGate.WaitAsync(ct).ConfigureAwait(false);
            try
            {
                if (FilmstripFor(assetId) is not null) return;
                await Task.Run(() => GenerateFilmstrip(assetId, url, ct), ct).ConfigureAwait(false);
            }
            finally
            {
                _videoThumbnailGate.Release();
            }
        }
        catch (OperationCanceledException) { }
        finally
        {
            EndJob(jobKey);
        }
    }

    public async Task GenerateImageThumbnailAsync(string assetId, string url, CancellationToken ct = default)
    {
        var jobKey = "img:" + assetId;
        if (!BeginJob(jobKey) || ImageStillFor(assetId) is not null) { EndJob(jobKey); return; }
        try
        {
            await _imageThumbnailGate.WaitAsync(ct).ConfigureAwait(false);
            try
            {
                if (ImageStillFor(assetId) is not null) return;
                var still = await Task.Run(
                    () => ImageThumbnailer.Thumbnail(url, ImageStillMaxPixelSize), ct).ConfigureAwait(false);
                if (still is null) return;
                lock (_lock) _imageStills[assetId] = still;
                VisualsUpdated?.Invoke(assetId);
            }
            finally
            {
                _imageThumbnailGate.Release();
            }
        }
        catch (OperationCanceledException) { }
        finally
        {
            EndJob(jobKey);
        }
    }

    public async Task GenerateWaveformAsync(string assetId, string url, CancellationToken ct = default)
    {
        var jobKey = "wave:" + assetId;
        if (!BeginJob(jobKey) || WaveformFor(assetId) is not null) { EndJob(jobKey); return; }
        try
        {
            await _waveformGate.WaitAsync(ct).ConfigureAwait(false);
            try
            {
                if (WaveformFor(assetId) is not null) return;
                var key = DiskCache.KeyFor(url);
                var cached = key is null ? null : await ReadWaveformFileAsync(key, ct).ConfigureAwait(false);
                var samples = cached ?? await WaveformExtractor.PeakEnvelopeAsync(url, null, ct).ConfigureAwait(false);
                if (samples.Length == 0) return;
                lock (_lock) _waveforms[assetId] = samples;
                VisualsUpdated?.Invoke(assetId);
                if (cached is null && key is not null)
                    await WriteWaveformFileAsync(key, samples, ct).ConfigureAwait(false);
            }
            finally
            {
                _waveformGate.Release();
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception)
        {
            // Missing or undecodable media stores nothing; the timeline draws without a waveform.
        }
        finally
        {
            EndJob(jobKey);
        }
    }

    private bool BeginJob(string jobKey)
    {
        lock (_lock) return _inFlight.Add(jobKey);
    }

    private void EndJob(string jobKey)
    {
        lock (_lock) _inFlight.Remove(jobKey);
    }

    // MARK: - Filmstrip

    private sealed record SpriteSidecar(int TileWidth, int TileHeight, int Columns, double[] Times);

    private void GenerateFilmstrip(string assetId, string url, CancellationToken ct)
    {
        var key = DiskCache.KeyFor(url);
        if (key is not null && TryLoadFilmstripFromDisk(assetId, key)) return;

        VideoFrameExtractor extractor;
        try
        {
            using var decodeLease = VideoDecodeGate.EnterAsync(ct).GetAwaiter().GetResult();
            extractor = new VideoFrameExtractor(url);
        }
        catch (Exception)
        {
            return; // Missing/unreadable media: store nothing.
        }

        using (extractor)
        {
            var duration = extractor.DurationSeconds;
            if (!double.IsFinite(duration) || duration <= 0) return;
            var interval = duration < 10 ? 1.0 : 2.0;

            var times = new List<double>();
            var tiles = new List<Bitmap>();
            for (var time = 0.0; time < duration; time += interval)
            {
                ct.ThrowIfCancellationRequested();
                var tile = extractor.FrameAt(time, TileMaxWidth, TileMaxHeight, ct);
                if (tile is null) break;
                times.Add(time);
                tiles.Add(tile);
                if (tiles.Count % ProgressivePublishInterval == 0)
                    PublishFilmstrip(assetId, times, tiles);
            }
            if (tiles.Count == 0) return;
            PublishFilmstrip(assetId, times, tiles);
            if (key is not null) WriteFilmstripToDisk(key, times, tiles);
        }
    }

    private void PublishFilmstrip(string assetId, List<double> times, List<Bitmap> tiles)
    {
        var strip = new Filmstrip([.. times], [.. tiles], tiles[0].Width, tiles[0].Height);
        lock (_lock) _filmstrips[assetId] = strip;
        VisualsUpdated?.Invoke(assetId);
    }

    private bool TryLoadFilmstripFromDisk(string assetId, string key)
    {
        var jsonPath = _disk.PathFor(key + ".thumbs.json");
        var spritePath = _disk.PathFor(key + ".thumbs.jpg");
        if (!File.Exists(jsonPath) || !File.Exists(spritePath)) return false;
        try
        {
            var sidecar = JsonSerializer.Deserialize<SpriteSidecar>(
                File.ReadAllBytes(jsonPath),
                new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
            if (sidecar is null || sidecar.Times.Length == 0 || sidecar.Columns <= 0) return false;

            using var sprite = new Bitmap(spritePath);
            var tiles = new List<Bitmap>(sidecar.Times.Length);
            for (var i = 0; i < sidecar.Times.Length; i++)
            {
                var column = i % sidecar.Columns;
                var row = i / sidecar.Columns;
                var rect = new Rectangle(
                    column * sidecar.TileWidth, row * sidecar.TileHeight,
                    sidecar.TileWidth, sidecar.TileHeight);
                tiles.Add(sprite.Clone(rect, sprite.PixelFormat));
            }
            var strip = new Filmstrip(sidecar.Times, tiles, sidecar.TileWidth, sidecar.TileHeight);
            lock (_lock) _filmstrips[assetId] = strip;
            VisualsUpdated?.Invoke(assetId);
            return true;
        }
        catch (Exception)
        {
            return false; // Corrupt cache entry: regenerate.
        }
    }

    private void WriteFilmstripToDisk(string key, List<double> times, List<Bitmap> tiles)
    {
        try
        {
            var tileWidth = tiles[0].Width;
            var tileHeight = tiles[0].Height;
            var columns = Math.Min(SpriteMaxColumns, tiles.Count);
            var rows = (tiles.Count + columns - 1) / columns;

            using var sprite = new Bitmap(columns * tileWidth, rows * tileHeight);
            using (var graphics = Graphics.FromImage(sprite))
            {
                for (var i = 0; i < tiles.Count; i++)
                    graphics.DrawImage(tiles[i], (i % columns) * tileWidth, (i / columns) * tileHeight,
                        tileWidth, tileHeight);
            }

            var jpeg = ImageThumbnailer.EncodeJpeg(sprite, SpriteJpegQuality);
            File.WriteAllBytes(_disk.PathFor(key + ".thumbs.jpg"), jpeg);
            var sidecar = new SpriteSidecar(tileWidth, tileHeight, columns, [.. times]);
            // Sidecar written last acts as the completeness marker.
            File.WriteAllBytes(
                _disk.PathFor(key + ".thumbs.json"),
                JsonSerializer.SerializeToUtf8Bytes(sidecar, new JsonSerializerOptions
                {
                    PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
                }));
        }
        catch (Exception)
        {
            // Best-effort cache write; memory copy already published.
        }
    }

    // MARK: - Waveform disk format (raw little-endian floats)

    private async Task<float[]?> ReadWaveformFileAsync(string key, CancellationToken ct)
    {
        var path = _disk.PathFor(key + ".waveform2");
        if (!File.Exists(path)) return null;
        try
        {
            var bytes = await File.ReadAllBytesAsync(path, ct).ConfigureAwait(false);
            if (bytes.Length == 0 || bytes.Length % 4 != 0) return null;
            var samples = new float[bytes.Length / 4];
            Buffer.BlockCopy(bytes, 0, samples, 0, bytes.Length);
            return samples;
        }
        catch (IOException)
        {
            return null;
        }
    }

    private async Task WriteWaveformFileAsync(string key, float[] samples, CancellationToken ct)
    {
        try
        {
            var bytes = new byte[samples.Length * 4];
            Buffer.BlockCopy(samples, 0, bytes, 0, bytes.Length);
            await File.WriteAllBytesAsync(_disk.PathFor(key + ".waveform2"), bytes, ct).ConfigureAwait(false);
        }
        catch (IOException)
        {
            // Best-effort cache write.
        }
    }
}
