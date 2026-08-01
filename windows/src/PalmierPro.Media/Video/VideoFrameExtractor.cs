using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using Vortice.MediaFoundation;

namespace PalmierPro.Media.Video;

/// <summary>
/// Decodes individual video frames through a Media Foundation source reader configured
/// for RGB32 output. This is the Windows counterpart of AVAssetImageGenerator: callers
/// request a frame at a time and receive a GDI bitmap scaled to fit a maximum size.
/// </summary>
public sealed class VideoFrameExtractor : IDisposable
{
    private readonly IMFSourceReader _reader;
    private bool _disposed;

    public int NativeWidth { get; }
    public int NativeHeight { get; }
    public double DurationSeconds { get; }

    static VideoFrameExtractor() => MediaFoundationSession.EnsureStarted();

    public VideoFrameExtractor(string path)
    {
        using var attributes = MediaFactory.MFCreateAttributes(1);
        // Enables the processor that handles YUV → RGB conversion and rotation metadata.
        attributes.Set(SourceReaderAttributeKeys.EnableAdvancedVideoProcessing, true);
        _reader = MediaFactory.MFCreateSourceReaderFromURL(ToMfUrl(path), attributes);

        _reader.SetStreamSelection(SourceReaderIndex.AllStreams, false);
        _reader.SetStreamSelection(SourceReaderIndex.FirstVideoStream, true);

        // Prefer RGB32; if the decoder rejects it, keep the native type and convert later.
        try
        {
            using var rgbType = MediaFactory.MFCreateMediaType();
            rgbType.Set(MediaTypeAttributeKeys.MajorType, MediaTypeGuids.Video);
            rgbType.Set(MediaTypeAttributeKeys.Subtype, VideoFormatGuids.Rgb32);
            _reader.SetCurrentMediaType(SourceReaderIndex.FirstVideoStream, rgbType);
        }
        catch
        {
            // Some containers only expose NV12/YUY2 until the first ReadSample; size still readable.
        }

        using (var current = _reader.GetCurrentMediaType(SourceReaderIndex.FirstVideoStream))
        {
            var packedSize = current.GetUInt64(MediaTypeAttributeKeys.FrameSize);
            NativeWidth = Math.Max(1, (int)(packedSize >> 32));
            NativeHeight = Math.Max(1, (int)(packedSize & 0xFFFFFFFF));
        }

        // Duration is optional — missing/unreadable attributes must not kill the reader.
        try
        {
            var duration = _reader.GetPresentationAttribute(
                SourceReaderIndex.MediaSource, PresentationDescriptionAttributeKeys.Duration);
            var seconds = Convert.ToInt64(duration.Value) / 10_000_000.0;
            DurationSeconds = double.IsFinite(seconds) && seconds > 0 ? seconds : 0;
        }
        catch
        {
            DurationSeconds = 0;
        }
    }

    /// <summary>MF source readers expect a URL; bare Win32 paths fail for some files.</summary>
    internal static string ToMfUrl(string path)
    {
        if (path.StartsWith("file:", StringComparison.OrdinalIgnoreCase)) return path;
        try { return new Uri(Path.GetFullPath(path)).AbsoluteUri; }
        catch { return path; }
    }

    /// <summary>
    /// Reads the first frame at or after <paramref name="seconds"/> and returns it scaled
    /// to fit within maxWidth × maxHeight (aspect preserved). Returns null when the
    /// stream ends before the requested time.
    /// </summary>
    public Bitmap? FrameAt(double seconds, int maxWidth, int maxHeight, CancellationToken ct = default)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        var position = (long)(Math.Max(0, seconds) * 10_000_000.0);
        _reader.SetCurrentPosition(position);

        while (true)
        {
            ct.ThrowIfCancellationRequested();
            var sample = _reader.ReadSample(
                SourceReaderIndex.FirstVideoStream, SourceReaderControlFlag.None,
                out _, out var flags, out _);
            if (sample is null || flags.HasFlag(SourceReaderFlag.EndOfStream))
            {
                sample?.Dispose();
                return null;
            }
            using (sample)
            {
                // The reader seeks to the previous keyframe; skip decoded frames until
                // the requested presentation time.
                if (sample.SampleTime + sample.SampleDuration < position) continue;
                return ToScaledBitmap(sample, maxWidth, maxHeight);
            }
        }
    }

    /// <summary>
    /// Streaming decode for playback: returns the raw BGRA frame covering
    /// <paramref name="seconds"/>. Reads forward without seeking when the request is
    /// at or slightly ahead of the last decoded sample; otherwise repositions first.
    /// </summary>
    public VideoFrame? RawFrameAt(double seconds, CancellationToken ct = default)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        var position = (long)(Math.Max(0, seconds) * 10_000_000.0);
        const long forwardReadWindow = 10_000_000; // 1 s: cheaper to drain than reseek.
        if (position < _lastSampleTime || position > _lastSampleTime + forwardReadWindow)
        {
            _reader.SetCurrentPosition(position);
            _lastSampleTime = long.MinValue;
        }

        while (true)
        {
            ct.ThrowIfCancellationRequested();
            var sample = _reader.ReadSample(
                SourceReaderIndex.FirstVideoStream, SourceReaderControlFlag.None,
                out _, out var flags, out _);
            if (sample is null || flags.HasFlag(SourceReaderFlag.EndOfStream))
            {
                sample?.Dispose();
                return null;
            }
            using (sample)
            {
                _lastSampleTime = sample.SampleTime;
                if (sample.SampleTime + sample.SampleDuration < position) continue;
                return ToVideoFrame(sample);
            }
        }
    }

    private long _lastSampleTime = long.MinValue;

    private VideoFrame ToVideoFrame(IMFSample sample)
    {
        using var buffer = sample.ConvertToContiguousBuffer();
        buffer.Lock(out var pointer, out _, out var currentLength);
        try
        {
            var stride = NativeWidth * 4;
            var bytes = new byte[Math.Min(currentLength, stride * NativeHeight)];
            Marshal.Copy(pointer, bytes, 0, bytes.Length);
            // MF RGB32 leaves alpha unused (often 0). Premultiplied D2D bitmaps treat
            // A=0 as fully transparent, so force opaque before compositing.
            ForceOpaqueAlpha(bytes, stride, NativeHeight);
            return new VideoFrame(bytes, NativeWidth, NativeHeight, stride);
        }
        finally
        {
            buffer.Unlock();
        }
    }

    private static void ForceOpaqueAlpha(byte[] bgra, int stride, int height)
    {
        var rowBytes = Math.Min(stride, bgra.Length);
        for (var y = 0; y < height; y++)
        {
            var row = y * stride;
            if (row + 3 >= bgra.Length) break;
            var end = Math.Min(row + rowBytes, bgra.Length);
            for (var i = row + 3; i < end; i += 4)
                bgra[i] = 255;
        }
    }

    private Bitmap ToScaledBitmap(IMFSample sample, int maxWidth, int maxHeight)
    {
        using var buffer = sample.ConvertToContiguousBuffer();
        buffer.Lock(out var pointer, out _, out _);
        try
        {
            var stride = NativeWidth * 4;
            using var full = new Bitmap(NativeWidth, NativeHeight, stride, PixelFormat.Format32bppRgb, pointer);
            var scale = Math.Min(1.0, Math.Min(maxWidth / (double)NativeWidth, maxHeight / (double)NativeHeight));
            var width = Math.Max(1, (int)Math.Round(NativeWidth * scale));
            var height = Math.Max(1, (int)Math.Round(NativeHeight * scale));
            // RGB32 rows are bottom-up when stride is positive from MF; Bitmap over the raw
            // pointer already presents top-down for positive stride, so no flip is required.
            return new Bitmap(full, width, height);
        }
        finally
        {
            buffer.Unlock();
        }
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _reader.Dispose();
    }
}

/// <summary>Process-wide Media Foundation startup, once.</summary>
public static class MediaFoundationSession
{
    private static readonly Lazy<bool> Started = new(() =>
    {
        MediaFactory.MFStartup();
        return true;
    });

    public static void EnsureStarted() => _ = Started.Value;
}
