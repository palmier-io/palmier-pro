using System.Runtime.InteropServices;
using PalmierPro.Core.Compositing;
using PalmierPro.Core.Export;
using PalmierPro.Core.Models;
using PalmierPro.Core.Playback;
using PalmierPro.Media.Compositing;
using PalmierPro.Media.Playback;
using PalmierPro.Media.Video;
using Vortice.MediaFoundation;

namespace PalmierPro.Media.Export;

/// <summary>
/// Frame-loop H.264/H.265 export via Media Foundation Sink Writer. Reuses
/// FrameLayerPlanner + D2DFrameCompositor (same stack as preview). Writes to a
/// staging path then atomically replaces the destination.
/// </summary>
public sealed class VideoExporter : IDisposable
{
    private readonly Dictionary<string, VideoFrameExtractor> _readers = [];
    private D2DFrameCompositor? _compositor;
    private bool _disposed;

    static VideoExporter() => MediaFoundationSession.EnsureStarted();

    public ExportRunReport Export(
        Timeline timeline,
        IReadOnlyDictionary<string, string> mediaPaths,
        IReadOnlyDictionary<string, Timeline>? sequences,
        ExportJob job,
        CancellationToken ct,
        IProgress<double>? progress = null)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (!job.Format.IsVideo())
            throw new ArgumentException($"Not a video format: {job.Format}");

        var (width, height) = ExportResolutionMath.RenderSize(
            job.Resolution, timeline.Width, timeline.Height);
        var fps = Math.Max(1, timeline.Fps);
        var durationFrames = TimelineFrameRouter.DurationFrames(timeline);
        if (durationFrames <= 0)
            throw new InvalidOperationException("Timeline has no content to export.");

        var staging = StagingPath(job.OutputPath);
        try
        {
            WriteVideo(timeline, mediaPaths, sequences, job.Format, width, height, fps,
                durationFrames, staging, ct, progress);
            Directory.CreateDirectory(Path.GetDirectoryName(job.OutputPath)!);
            File.Move(staging, job.OutputPath, overwrite: true);
        }
        catch
        {
            TryDelete(staging);
            throw;
        }

        var offline = mediaPaths
            .Where(kv => !File.Exists(kv.Value))
            .Select(kv => kv.Key)
            .ToList();
        var info = new FileInfo(job.OutputPath);
        return new ExportRunReport
        {
            OutputBytes = info.Exists ? info.Length : 0,
            OfflineMediaRefs = offline,
            Warnings = offline.Select(id => $"Offline media: {id}").ToList(),
        };
    }

    private void WriteVideo(
        Timeline timeline,
        IReadOnlyDictionary<string, string> mediaPaths,
        IReadOnlyDictionary<string, Timeline>? sequences,
        ExportFormat format,
        int width, int height, int fps, int durationFrames,
        string stagingPath,
        CancellationToken ct,
        IProgress<double>? progress)
    {
        _compositor ??= new D2DFrameCompositor();
        using var writer = MediaFactory.MFCreateSinkWriterFromURL(stagingPath, null, null);

        var subtype = format == ExportFormat.H265
            ? VideoFormatGuids.Hevc
            : VideoFormatGuids.H264;

        int videoStream;
        using (var outType = MediaFactory.MFCreateMediaType())
        {
            outType.Set(MediaTypeAttributeKeys.MajorType, MediaTypeGuids.Video);
            outType.Set(MediaTypeAttributeKeys.Subtype, subtype);
            outType.Set(MediaTypeAttributeKeys.AvgBitrate, BitrateFor(width, height, fps));
            outType.Set(MediaTypeAttributeKeys.InterlaceMode, (int)VideoInterlaceMode.Progressive);
            outType.Set(MediaTypeAttributeKeys.FrameSize, PackSize(width, height));
            outType.Set(MediaTypeAttributeKeys.FrameRate, PackRatio(fps, 1));
            outType.Set(MediaTypeAttributeKeys.PixelAspectRatio, PackRatio(1, 1));
            videoStream = writer.AddStream(outType);
        }

        using (var inType = MediaFactory.MFCreateMediaType())
        {
            inType.Set(MediaTypeAttributeKeys.MajorType, MediaTypeGuids.Video);
            inType.Set(MediaTypeAttributeKeys.Subtype, VideoFormatGuids.Rgb32);
            inType.Set(MediaTypeAttributeKeys.InterlaceMode, (int)VideoInterlaceMode.Progressive);
            inType.Set(MediaTypeAttributeKeys.FrameSize, PackSize(width, height));
            inType.Set(MediaTypeAttributeKeys.FrameRate, PackRatio(fps, 1));
            inType.Set(MediaTypeAttributeKeys.PixelAspectRatio, PackRatio(1, 1));
            writer.SetInputMediaType(videoStream, inType, null);
        }

        writer.BeginWriting();
        var frameDuration = 10_000_000L / fps;
        Timeline? Resolve(string id) => sequences?.GetValueOrDefault(id);

        for (var frame = 0; frame < durationFrames; frame++)
        {
            ct.ThrowIfCancellationRequested();
            var layers = FrameLayerPlanner.LayersAt(timeline, frame, Resolve);
            var composed = _compositor.Compose(width, height, layers,
                (clip, seconds) => Decode(clip, seconds, mediaPaths));
            if (composed is null)
                composed = BlackFrame(width, height);

            WriteSample(writer, videoStream, composed, frame * frameDuration, frameDuration);
            progress?.Report((frame + 1) / (double)durationFrames);
        }

        writer.Finalize();
    }

    private VideoFrame? Decode(Clip clip, double sourceSeconds, IReadOnlyDictionary<string, string> mediaPaths)
    {
        if (!mediaPaths.TryGetValue(clip.MediaRef, out var path) || !File.Exists(path))
            return null;
        try
        {
            if (clip.MediaType == ClipType.Image)
            {
                using var bitmap = new System.Drawing.Bitmap(path);
                return BitmapToFrame(bitmap);
            }
            if (!_readers.TryGetValue(clip.MediaRef, out var reader))
            {
                reader = new VideoFrameExtractor(path);
                _readers[clip.MediaRef] = reader;
            }
            return reader.RawFrameAt(sourceSeconds);
        }
        catch
        {
            return null;
        }
    }

    private static VideoFrame BitmapToFrame(System.Drawing.Bitmap bitmap)
    {
        var rect = new System.Drawing.Rectangle(0, 0, bitmap.Width, bitmap.Height);
        var data = bitmap.LockBits(rect, System.Drawing.Imaging.ImageLockMode.ReadOnly,
            System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        try
        {
            var bytes = new byte[data.Stride * data.Height];
            Marshal.Copy(data.Scan0, bytes, 0, bytes.Length);
            if (data.Stride == bitmap.Width * 4)
                return new VideoFrame(bytes, bitmap.Width, bitmap.Height, data.Stride);
            var packed = new byte[bitmap.Width * bitmap.Height * 4];
            for (var y = 0; y < bitmap.Height; y++)
                Buffer.BlockCopy(bytes, y * data.Stride, packed, y * bitmap.Width * 4, bitmap.Width * 4);
            return new VideoFrame(packed, bitmap.Width, bitmap.Height, bitmap.Width * 4);
        }
        finally { bitmap.UnlockBits(data); }
    }

    private static void WriteSample(
        IMFSinkWriter writer, int stream, VideoFrame frame, long time, long duration)
    {
        var bufferSize = frame.Width * frame.Height * 4;
        using var sample = MediaFactory.MFCreateSample();
        using var buffer = MediaFactory.MFCreateMemoryBuffer(bufferSize);
        buffer.Lock(out var pointer, out _, out _);
        try
        {
            // Top-down BGRA; Sink Writer color converter handles encoder input.
            Marshal.Copy(frame.Bgra, 0, pointer, bufferSize);
        }
        finally
        {
            buffer.Unlock();
        }
        buffer.CurrentLength = bufferSize;
        sample.AddBuffer(buffer);
        sample.SampleTime = time;
        sample.SampleDuration = duration;
        writer.WriteSample(stream, sample);
    }

    private static VideoFrame BlackFrame(int width, int height)
    {
        var data = new byte[width * height * 4];
        for (var i = 0; i < data.Length; i += 4) data[i + 3] = 255;
        return new VideoFrame(data, width, height, width * 4);
    }

    private static ulong PackSize(int width, int height)
        => ((ulong)(uint)width << 32) | (uint)height;

    private static ulong PackRatio(int numerator, int denominator)
        => ((ulong)(uint)numerator << 32) | (uint)denominator;

    private static uint BitrateFor(int width, int height, int fps)
    {
        // Rough H.264 target: ~0.1 bit per pixel per frame.
        var bits = (long)width * height * fps / 10;
        return (uint)Math.Clamp(bits, 1_000_000, 50_000_000);
    }

    private static string StagingPath(string destination)
    {
        var dir = Path.GetDirectoryName(destination) ?? ".";
        var stem = Path.GetFileNameWithoutExtension(destination);
        var ext = Path.GetExtension(destination);
        return Path.Combine(dir, $".{stem}-{Guid.NewGuid():N}.partial{ext}");
    }

    private static void TryDelete(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); } catch { }
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        foreach (var reader in _readers.Values) reader.Dispose();
        _readers.Clear();
        _compositor?.Dispose();
    }
}
