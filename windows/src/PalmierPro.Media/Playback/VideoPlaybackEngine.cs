using System.Diagnostics;
using PalmierPro.Core.Compositing;
using PalmierPro.Core.Models;
using PalmierPro.Core.Playback;
using PalmierPro.Media.Video;

namespace PalmierPro.Media.Playback;

public enum SeekMode
{
    Exact,
    InteractiveScrub,
}

/// <summary>
/// Timeline playback engine: a dedicated decode thread routes the playhead through
/// TimelineFrameRouter, streams frames from bounded per-asset source readers, and
/// presents them through an IFramePresenter. Mirrors the Mac VideoEngine behavior:
/// ~30 Hz playhead notifications, coalesced interactive seeks, no looping (playback
/// stops at the end; the next play wraps to frame 0).
/// </summary>
public sealed class VideoPlaybackEngine : IDisposable
{
    private const int MaxOpenReaders = 4;
    private static readonly TimeSpan InteractiveSeekInterval = TimeSpan.FromSeconds(1.0 / 30.0);

    private readonly IFramePresenter _presenter;
    private readonly TimelineAudioPlayer _audio = new();
    private readonly Thread _thread;
    private readonly object _lock = new();
    private readonly ManualResetEventSlim _wake = new(false);
    private bool _disposed;

    // Engine-thread state.
    private Timeline? _timeline;
    private Dictionary<string, string> _mediaPaths = [];
    private Dictionary<string, Timeline> _sequences = [];
    private readonly Dictionary<string, VideoFrameExtractor> _readers = [];
    private readonly LinkedList<string> _readerUse = [];
    private int _lastPresentedFrame = -1;

    // Shared command state (guarded by _lock).
    private (Timeline Timeline, Dictionary<string, string> Paths, Dictionary<string, Timeline> Sequences)? _pendingRebuild;
    private int? _pendingSeekFrame;
    private SeekMode _pendingSeekMode;
    private DateTime _lastInteractiveFlush = DateTime.MinValue;
    private bool _playRequested;
    private double _rate = 1.0;

    // Play anchor (engine thread).
    private readonly Stopwatch _clock = new();
    private int _anchorFrame;

    public event Action<int>? PlayheadChanged;
    public event Action? PlaybackEnded;

    public int CurrentFrame { get; private set; }
    public bool IsPlaying { get; private set; }

    public double PlaybackRate
    {
        get { lock (_lock) return _rate; }
        set
        {
            lock (_lock)
            {
                _rate = Math.Clamp(value, 0.25, 10);
                if (_playRequested) _pendingSeekFrame ??= CurrentFrame;
            }
            _wake.Set();
        }
    }

    public VideoPlaybackEngine(IFramePresenter presenter)
    {
        _presenter = presenter;
        _thread = new Thread(RunLoop) { IsBackground = true, Name = "PalmierPlayback" };
        _thread.Start();
    }

    /// <summary>Replaces the playable timeline snapshot; keeps the playhead position.</summary>
    public void Rebuild(
        Timeline timeline, IReadOnlyDictionary<string, string> mediaPaths,
        IReadOnlyDictionary<string, Timeline>? sequences = null)
    {
        lock (_lock)
        {
            _pendingRebuild = (
                timeline,
                new Dictionary<string, string>(mediaPaths),
                sequences is null ? [] : new Dictionary<string, Timeline>(sequences));
        }
        _wake.Set();
    }

    public void Play()
    {
        lock (_lock)
        {
            _playRequested = true;
            _pendingSeekFrame ??= CurrentFrame;
            _pendingSeekMode = SeekMode.Exact;
        }
        _wake.Set();
    }

    public void Pause()
    {
        lock (_lock) _playRequested = false;
        _audio.Stop();
        _wake.Set();
    }

    public void SeekToFrame(int frame, SeekMode mode = SeekMode.Exact)
    {
        lock (_lock)
        {
            if (mode == SeekMode.InteractiveScrub)
            {
                // Coalesce: keep only the latest request, flush at most ~30 Hz.
                _pendingSeekFrame = frame;
                _pendingSeekMode = mode;
                if (DateTime.UtcNow - _lastInteractiveFlush < InteractiveSeekInterval) return;
                _lastInteractiveFlush = DateTime.UtcNow;
            }
            else
            {
                _pendingSeekFrame = frame;
                _pendingSeekMode = mode;
            }
        }
        _wake.Set();
    }

    public void StepForward() => SeekToFrame(CurrentFrame + 1);
    public void StepBackward() => SeekToFrame(Math.Max(0, CurrentFrame - 1));

    private void RunLoop()
    {
        while (!_disposed)
        {
            (Timeline, Dictionary<string, string>, Dictionary<string, Timeline>)? rebuild;
            int? seek;
            bool playRequested;
            double rate;
            lock (_lock)
            {
                rebuild = _pendingRebuild;
                _pendingRebuild = null;
                seek = _pendingSeekFrame;
                _pendingSeekFrame = null;
                playRequested = _playRequested;
                rate = _rate;
            }

            if (rebuild is { } r)
            {
                _timeline = r.Item1;
                _mediaPaths = r.Item2;
                _sequences = r.Item3;
                CloseAllReaders();
                _lastPresentedFrame = -1;
                _audio.Rebuild(r.Item1, r.Item2, r.Item3);
                // Live mixer holds the old clip set — restart so deletes/edits take effect immediately.
                if (IsPlaying || playRequested)
                {
                    _audio.Stop();
                    IsPlaying = false;
                    _clock.Stop();
                }
            }

            if (_timeline is null)
            {
                _wake.Wait();
                _wake.Reset();
                continue;
            }

            var duration = TimelineFrameRouter.DurationFrames(_timeline);

            if (seek is { } target)
            {
                var clamped = Math.Clamp(target, 0, Math.Max(0, duration));
                CurrentFrame = clamped;
                RenderFrame(clamped);
                PlayheadChanged?.Invoke(clamped);
                if (playRequested) StartPlaying(clamped, duration, rate);
            }

            if (playRequested && !IsPlaying)
            {
                StartPlaying(CurrentFrame, duration, rate);
            }
            else if (!playRequested && IsPlaying)
            {
                IsPlaying = false;
                _clock.Stop();
                _audio.Stop();
            }

            if (IsPlaying)
            {
                var fps = Math.Max(1, _timeline.Fps);
                var frame = _anchorFrame + (int)(_clock.Elapsed.TotalSeconds * rate * fps);
                if (frame >= duration)
                {
                    CurrentFrame = Math.Max(0, duration);
                    IsPlaying = false;
                    _clock.Stop();
                    lock (_lock) _playRequested = false;
                    _audio.Stop();
                    RenderFrame(CurrentFrame);
                    PlayheadChanged?.Invoke(CurrentFrame);
                    PlaybackEnded?.Invoke();
                    continue;
                }
                if (frame != CurrentFrame)
                {
                    CurrentFrame = frame;
                    RenderFrame(frame);
                    PlayheadChanged?.Invoke(frame);
                }
                // Pace to the next frame boundary.
                var nextFrameAt = (frame + 1 - _anchorFrame) / (rate * fps);
                var wait = nextFrameAt - _clock.Elapsed.TotalSeconds;
                if (wait > 0.001) _wake.Wait(TimeSpan.FromSeconds(Math.Min(wait, 0.033)));
                _wake.Reset();
            }
            else
            {
                _wake.Wait();
                _wake.Reset();
            }
        }
        CloseAllReaders();
        _compositor?.Dispose();
        _compositor = null;
    }

    private void StartPlaying(int fromFrame, int duration, double rate)
    {
        // At the end, the next play wraps to the start (no looping mid-playback).
        var start = fromFrame >= duration ? 0 : fromFrame;
        _anchorFrame = start;
        CurrentFrame = start;
        IsPlaying = true;
        _clock.Restart();
        if (_timeline is not null)
            _audio.Start(_timeline, start, rate);
    }

    private Compositing.D2DFrameCompositor? _compositor;

    private void RenderFrame(int frame)
    {
        if (_timeline is null) return;
        if (frame == _lastPresentedFrame) return;

        try
        {
            // Preview uses the topmost visual source directly (pre-compositor path).
            // Multi-layer D2D compose remains for export; it has been blanking preview
            // when alpha / DrawBitmap fails on some GPUs.
            var source = TimelineFrameRouter.VideoSourceAt(
                _timeline, frame, id => _sequences.GetValueOrDefault(id));
            if (source is null || !_mediaPaths.TryGetValue(source.Clip.MediaRef, out var path))
            {
                _presenter.Clear();
                _lastPresentedFrame = frame;
                return;
            }

            VideoFrame? decoded = null;
            if (source.Clip.MediaType == ClipType.Image)
                decoded = StillFor(source.Clip.MediaRef, path);
            else
            {
                var reader = ReaderFor(source.Clip.MediaRef, path);
                decoded = reader?.RawFrameAt(source.SourceSeconds);
            }

            if (decoded is not null)
            {
                _presenter.Present(decoded);
                _lastPresentedFrame = frame;
            }
            else
            {
                _presenter.Clear();
                // Leave _lastPresentedFrame unset so the next seek/play retries decode.
            }
        }
        catch (Exception)
        {
            _compositor?.Dispose();
            _compositor = null;
            _presenter.Clear();
        }
    }

    private VideoFrame? DecodeLayerFrame(Clip clip, double sourceSeconds)
    {
        if (!_mediaPaths.TryGetValue(clip.MediaRef, out var path)) return null;
        try
        {
            if (clip.MediaType == ClipType.Image) return StillFor(clip.MediaRef, path);
            var reader = ReaderFor(clip.MediaRef, path);
            return reader?.RawFrameAt(sourceSeconds);
        }
        catch (Exception)
        {
            return null;
        }
    }

    private VideoFrameExtractor? ReaderFor(string mediaRef, string path)
    {
        if (_readers.TryGetValue(mediaRef, out var existing))
        {
            _readerUse.Remove(mediaRef);
            _readerUse.AddFirst(mediaRef);
            return existing;
        }
        VideoFrameExtractor created;
        try
        {
            using var decodeLease = VideoDecodeGate.EnterAsync().GetAwaiter().GetResult();
            created = new VideoFrameExtractor(path);
        }
        catch (Exception)
        {
            return null;
        }
        _readers[mediaRef] = created;
        _readerUse.AddFirst(mediaRef);
        while (_readers.Count > MaxOpenReaders)
        {
            var evict = _readerUse.Last!.Value;
            _readerUse.RemoveLast();
            _readers.Remove(evict, out var reader);
            reader?.Dispose();
        }
        return created;
    }

    private readonly Dictionary<string, VideoFrame?> _stills = [];

    /// <summary>Image clips have one frame for their whole duration; decode and cache it.</summary>
    private VideoFrame? StillFor(string mediaRef, string path)
    {
        if (_stills.TryGetValue(mediaRef, out var cached)) return cached;
        VideoFrame? frame = null;
        using (var bitmap = Images.ImageThumbnailer.Thumbnail(path, 2160))
        {
            if (bitmap is not null) frame = BitmapToFrame(bitmap);
        }
        if (_stills.Count > 8) _stills.Clear();
        _stills[mediaRef] = frame;
        return frame;
    }

    private static VideoFrame BitmapToFrame(System.Drawing.Bitmap bitmap)
    {
        var rect = new System.Drawing.Rectangle(0, 0, bitmap.Width, bitmap.Height);
        var data = bitmap.LockBits(rect, System.Drawing.Imaging.ImageLockMode.ReadOnly,
            System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        try
        {
            var bytes = new byte[data.Stride * data.Height];
            System.Runtime.InteropServices.Marshal.Copy(data.Scan0, bytes, 0, bytes.Length);
            return new VideoFrame(bytes, bitmap.Width, bitmap.Height, data.Stride);
        }
        finally
        {
            bitmap.UnlockBits(data);
        }
    }

    private void CloseAllReaders()
    {
        foreach (var reader in _readers.Values) reader.Dispose();
        _readers.Clear();
        _readerUse.Clear();
        _stills.Clear();
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _wake.Set();
        _audio.Dispose();
        if (!_thread.Join(TimeSpan.FromSeconds(2))) { /* background thread; process exit reclaims it */ }
        _wake.Dispose();
    }
}
