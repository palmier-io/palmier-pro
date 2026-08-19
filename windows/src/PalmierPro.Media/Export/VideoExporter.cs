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
        if (ExportPlatformSupport.RefusalMessage(job.Format) is { } refusal)
            throw new NotSupportedException(refusal);

        var (width, height) = ExportResolutionMath.RenderSize(
            job.Resolution, timeline.Width, timeline.Height);
        var fps = Math.Max(1, timeline.Fps);
        var durationFrames = TimelineFrameRouter.DurationFrames(timeline);
        if (durationFrames <= 0)
            throw new InvalidOperationException("Timeline has no content to export.");

        var warnings = new List<string>();
        var staging = StagingPath(job.OutputPath);
        try
        {
            WriteVideo(timeline, mediaPaths, sequences, job.Format, job.Quality, width, height, fps,
                durationFrames, staging, ct, progress, warnings);
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
        warnings.AddRange(offline.Select(id => $"Offline media: {id}"));
        var info = new FileInfo(job.OutputPath);
        return new ExportRunReport
        {
            OutputBytes = info.Exists ? info.Length : 0,
            OfflineMediaRefs = offline,
            Warnings = warnings,
        };
    }

    private void WriteVideo(
        Timeline timeline,
        IReadOnlyDictionary<string, string> mediaPaths,
        IReadOnlyDictionary<string, Timeline>? sequences,
        ExportFormat format,
        string? quality,
        int width, int height, int fps, int durationFrames,
        string stagingPath,
        CancellationToken ct,
        IProgress<double>? progress,
        List<string> warnings)
    {
        _compositor ??= new D2DFrameCompositor();
        using var writer = MediaFactory.MFCreateSinkWriterFromURL(stagingPath, null, null);

        var hdr = format == ExportFormat.HevcHdr;
        var subtype = format is ExportFormat.H265 or ExportFormat.HevcHdr
            ? VideoFormatGuids.Hevc
            : VideoFormatGuids.H264;
        var mezzanine = IsMezzanineQuality(quality);
        if (mezzanine)
            warnings.Add(ExportPlatformSupport.MezzanineGuidance);

        int videoStream;
        using (var outType = MediaFactory.MFCreateMediaType())
        {
            outType.Set(MediaTypeAttributeKeys.MajorType, MediaTypeGuids.Video);
            outType.Set(MediaTypeAttributeKeys.Subtype, subtype);
            outType.Set(MediaTypeAttributeKeys.AvgBitrate, BitrateFor(width, height, fps, hdr, mezzanine));
            outType.Set(MediaTypeAttributeKeys.InterlaceMode, (int)VideoInterlaceMode.Progressive);
            outType.Set(MediaTypeAttributeKeys.FrameSize, PackSize(width, height));
            outType.Set(MediaTypeAttributeKeys.FrameRate, PackRatio(fps, 1));
            outType.Set(MediaTypeAttributeKeys.PixelAspectRatio, PackRatio(1, 1));
            if (hdr) ApplyHdrColorAttributes(outType);
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
            if (hdr) ApplyHdrColorAttributes(inType);
            try
            {
                writer.SetInputMediaType(videoStream, inType, null);
            }
            catch when (hdr)
            {
                // Some MF HEVC encoders reject HDR tags on RGB32 input — encode HEVC without tags.
                inType.DeleteItem(MediaTypeAttributeKeys.VideoPrimaries);
                inType.DeleteItem(MediaTypeAttributeKeys.TransferFunction);
                inType.DeleteItem(MediaTypeAttributeKeys.YuvMatrix);
                writer.SetInputMediaType(videoStream, inType, null);
                warnings.Add(
                    "HEVC HDR color tags were not accepted by the encoder; output is HEVC without HDR metadata.");
            }
        }

        var audioStream = AddAacStream(writer);

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

            WriteVideoSample(writer, videoStream, composed, frame * frameDuration, frameDuration);
            // Video is most of the work; leave 10% for the audio pass.
            progress?.Report((frame + 1) / (double)durationFrames * 0.9);
        }

        WriteMixedAudio(writer, audioStream, timeline, mediaPaths, sequences, durationFrames, fps, ct);
        progress?.Report(1);
        writer.Finalize();
    }

    private static int AddAacStream(IMFSinkWriter writer)
    {
        const int sampleRate = TimelineAudioPlayer.SampleRate;
        const int channels = TimelineAudioPlayer.Channels;
        int audioStream;
        using (var outType = MediaFactory.MFCreateMediaType())
        {
            outType.Set(MediaTypeAttributeKeys.MajorType, MediaTypeGuids.Audio);
            outType.Set(MediaTypeAttributeKeys.Subtype, AudioFormatGuids.Aac);
            outType.Set(MediaTypeAttributeKeys.AudioNumChannels, channels);
            outType.Set(MediaTypeAttributeKeys.AudioSamplesPerSecond, sampleRate);
            outType.Set(MediaTypeAttributeKeys.AudioBitsPerSample, 16);
            outType.Set(MediaTypeAttributeKeys.AvgBitrate, 192_000);
            audioStream = writer.AddStream(outType);
        }

        using (var inType = MediaFactory.MFCreateMediaType())
        {
            inType.Set(MediaTypeAttributeKeys.MajorType, MediaTypeGuids.Audio);
            inType.Set(MediaTypeAttributeKeys.Subtype, AudioFormatGuids.Pcm);
            inType.Set(MediaTypeAttributeKeys.AudioNumChannels, channels);
            inType.Set(MediaTypeAttributeKeys.AudioSamplesPerSecond, sampleRate);
            inType.Set(MediaTypeAttributeKeys.AudioBitsPerSample, 16);
            inType.Set(MediaTypeAttributeKeys.AudioBlockAlignment, channels * 2);
            inType.Set(MediaTypeAttributeKeys.AudioAvgBytesPerSecond, sampleRate * channels * 2);
            writer.SetInputMediaType(audioStream, inType, null);
        }
        return audioStream;
    }

    /// <summary>
    /// Offline PCM mix via the same TimelineMixerProvider as playback, converted to
    /// 16-bit interleaved samples for the AAC encoder. Matches Mac's 48 kHz stereo path.
    /// </summary>
    private static void WriteMixedAudio(
        IMFSinkWriter writer, int audioStream,
        Timeline timeline,
        IReadOnlyDictionary<string, string> mediaPaths,
        IReadOnlyDictionary<string, Timeline>? sequences,
        int durationFrames, int fps, CancellationToken ct)
    {
        const int sampleRate = TimelineAudioPlayer.SampleRate;
        const int channels = TimelineAudioPlayer.Channels;
        var pathMap = new Dictionary<string, string>(mediaPaths);
        var sequenceMap = sequences is null
            ? new Dictionary<string, Timeline>()
            : new Dictionary<string, Timeline>(sequences);

        using var mixer = new TimelineMixerProvider(timeline, pathMap, sequenceMap, fromFrame: 0, rate: 1.0);
        var totalSamples = (long)durationFrames * sampleRate / Math.Max(1, fps);
        var chunkFrames = sampleRate / 10; // 100 ms chunks
        var floatBuf = new float[chunkFrames * channels];
        var pcmBuf = new byte[chunkFrames * channels * 2];
        long written = 0;
        long time = 0;

        while (written < totalSamples)
        {
            ct.ThrowIfCancellationRequested();
            var frames = (int)Math.Min(chunkFrames, totalSamples - written);
            var floatsNeeded = frames * channels;
            var read = mixer.Read(floatBuf, 0, floatsNeeded);
            if (read <= 0) break;
            var frameCount = read / channels;
            FloatToPcm16(floatBuf, pcmBuf, read);

            var byteCount = frameCount * channels * 2;
            var duration = frameCount * 10_000_000L / sampleRate;
            WriteAudioSample(writer, audioStream, pcmBuf, byteCount, time, duration);
            time += duration;
            written += frameCount;
        }
    }

    private static void FloatToPcm16(float[] source, byte[] destination, int count)
    {
        for (var i = 0; i < count; i++)
        {
            var sample = (short)Math.Clamp((int)Math.Round(source[i] * 32767f), short.MinValue, short.MaxValue);
            destination[i * 2] = (byte)(sample & 0xFF);
            destination[i * 2 + 1] = (byte)((sample >> 8) & 0xFF);
        }
    }

    private static void WriteAudioSample(
        IMFSinkWriter writer, int stream, byte[] pcm, int byteCount, long time, long duration)
    {
        using var sample = MediaFactory.MFCreateSample();
        using var buffer = MediaFactory.MFCreateMemoryBuffer(byteCount);
        buffer.Lock(out var pointer, out _, out _);
        try { Marshal.Copy(pcm, 0, pointer, byteCount); }
        finally { buffer.Unlock(); }
        buffer.CurrentLength = byteCount;
        sample.AddBuffer(buffer);
        sample.SampleTime = time;
        sample.SampleDuration = duration;
        writer.WriteSample(stream, sample);
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

    private static void WriteVideoSample(
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

    /// <summary>Mac hevcHDR tags: BT.2020 + HLG (+ BT.2020 matrix).</summary>
    private static void ApplyHdrColorAttributes(IMFMediaType type)
    {
        type.Set(MediaTypeAttributeKeys.VideoPrimaries, (int)VideoPrimaries.Bt2020);
        type.Set(MediaTypeAttributeKeys.TransferFunction, (int)VideoTransferFunction.FuncHlg);
        type.Set(MediaTypeAttributeKeys.YuvMatrix, (int)VideoTransferMatrix.Bt202010);
    }

    private static bool IsMezzanineQuality(string? quality)
    {
        var q = (quality ?? "").Trim().ToLowerInvariant();
        return q is "mezzanine" or "high" or "intermediate" or "master";
    }

    private static uint BitrateFor(int width, int height, int fps, bool hdr = false, bool mezzanine = false)
    {
        // Rough H.264 target: ~0.1 bit per pixel per frame; HDR / mezzanine raise the ceiling.
        var denom = mezzanine ? (hdr ? 4 : 5) : (hdr ? 8 : 10);
        var bits = (long)width * height * fps / denom;
        var max = mezzanine
            ? (hdr ? 120_000_000 : 80_000_000)
            : (hdr ? 80_000_000 : 50_000_000);
        return (uint)Math.Clamp(bits, 1_000_000, max);
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
