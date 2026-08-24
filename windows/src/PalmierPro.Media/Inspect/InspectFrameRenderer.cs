using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using PalmierPro.Core.Compositing;
using PalmierPro.Core.Models;
using PalmierPro.Core.Playback;
using PalmierPro.Media.Compositing;
using PalmierPro.Media.Video;

namespace PalmierPro.Media.Inspect;

/// <summary>Renders timeline/media frames to JPEG for agent inspect_* image receipts.</summary>
public static class InspectFrameRenderer
{
    public const int DefaultMaxDimension = 512;
    public const long JpegQuality = 70L;

    public static IReadOnlyList<(byte[] Jpeg, int Width, int Height, int Frame, string Label)> RenderTimeline(
        Timeline timeline,
        IReadOnlyDictionary<string, string> mediaPaths,
        IReadOnlyDictionary<string, Timeline>? sequences,
        IReadOnlyList<int> frames,
        int maxDimension = DefaultMaxDimension)
    {
        var (width, height) = Fit(timeline.Width, timeline.Height, maxDimension);
        using var compositor = new D2DFrameCompositor();
        var readers = new Dictionary<string, VideoFrameExtractor>();
        var results = new List<(byte[] Jpeg, int Width, int Height, int Frame, string Label)>();
        try
        {
            Timeline? Resolve(string id) => sequences?.GetValueOrDefault(id);
            foreach (var frame in frames)
            {
                var layers = FrameLayerPlanner.LayersAt(timeline, frame, Resolve);
                var composed = compositor.Compose(width, height, layers,
                    (clip, seconds) => Decode(clip, seconds, mediaPaths, readers));
                composed ??= BlackFrame(width, height);
                var jpeg = EncodeJpeg(composed, $"f{frame}");
                if (jpeg is null) continue;
                results.Add((jpeg, width, height, frame, $"f{frame}"));
            }
        }
        finally
        {
            foreach (var r in readers.Values) r.Dispose();
        }
        return results;
    }

    public static IReadOnlyList<(byte[] Jpeg, int Width, int Height, double Seconds, string Label)> RenderMedia(
        string path,
        ClipType type,
        IReadOnlyList<double> sourceSeconds,
        int maxDimension = DefaultMaxDimension,
        bool overview = false)
    {
        var results = new List<(byte[] Jpeg, int Width, int Height, double Seconds, string Label)>();
        if (!File.Exists(path)) return results;

        if (type == ClipType.Image)
        {
            using var bmp = new Bitmap(path);
            var (w, h) = Fit(bmp.Width, bmp.Height, maxDimension);
            using var scaled = new Bitmap(bmp, w, h);
            BurnLabel(scaled, "image");
            results.Add((EncodeBitmapJpeg(scaled)!, w, h, 0, "image"));
            return results;
        }

        using var extractor = new VideoFrameExtractor(path);
        var (rw, rh) = Fit(extractor.NativeWidth, extractor.NativeHeight, maxDimension);
        var times = overview && sourceSeconds.Count == 0
            ? OverviewTimes(extractor)
            : sourceSeconds;
        foreach (var t in times)
        {
            using var bmp = extractor.FrameAt(t, rw, rh);
            if (bmp is null) continue;
            BurnLabel(bmp, $"{t:0.0}s");
            var jpeg = EncodeBitmapJpeg(bmp);
            if (jpeg is null) continue;
            results.Add((jpeg, bmp.Width, bmp.Height, t, $"{t:0.0}s"));
        }
        return results;
    }

    private static IReadOnlyList<double> OverviewTimes(VideoFrameExtractor extractor)
    {
        var duration = Math.Max(0.1, extractor.DurationSeconds);
        const int tiles = 8;
        return Enumerable.Range(0, tiles)
            .Select(i => (i + 0.5) * duration / tiles)
            .ToList();
    }

    private static VideoFrame? Decode(
        Clip clip, double sourceSeconds,
        IReadOnlyDictionary<string, string> mediaPaths,
        Dictionary<string, VideoFrameExtractor> readers)
    {
        if (!mediaPaths.TryGetValue(clip.MediaRef, out var path) || !File.Exists(path))
            return null;
        try
        {
            if (clip.MediaType == ClipType.Image)
            {
                using var bitmap = new Bitmap(path);
                return BitmapToFrame(bitmap);
            }
            if (!readers.TryGetValue(clip.MediaRef, out var reader))
            {
                reader = new VideoFrameExtractor(path);
                readers[clip.MediaRef] = reader;
            }
            return reader.RawFrameAt(sourceSeconds);
        }
        catch { return null; }
    }

    private static VideoFrame BitmapToFrame(Bitmap bitmap)
    {
        var rect = new Rectangle(0, 0, bitmap.Width, bitmap.Height);
        var data = bitmap.LockBits(rect, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
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

    private static VideoFrame BlackFrame(int width, int height)
    {
        var data = new byte[width * height * 4];
        for (var i = 0; i < data.Length; i += 4) data[i + 3] = 255;
        return new VideoFrame(data, width, height, width * 4);
    }

    private static (int Width, int Height) Fit(int width, int height, int maxDimension)
    {
        width = Math.Max(2, width);
        height = Math.Max(2, height);
        var longest = Math.Max(width, height);
        if (longest <= maxDimension)
            return (width / 2 * 2, height / 2 * 2);
        var scale = maxDimension / (double)longest;
        return (
            Math.Max(2, (int)Math.Round(width * scale) / 2 * 2),
            Math.Max(2, (int)Math.Round(height * scale) / 2 * 2));
    }

    private static byte[]? EncodeJpeg(VideoFrame frame, string label)
    {
        using var bmp = new Bitmap(frame.Width, frame.Height, PixelFormat.Format32bppArgb);
        var rect = new Rectangle(0, 0, frame.Width, frame.Height);
        var data = bmp.LockBits(rect, ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
        try
        {
            if (frame.Stride == frame.Width * 4)
                Marshal.Copy(frame.Bgra, 0, data.Scan0, frame.Bgra.Length);
            else
            {
                for (var y = 0; y < frame.Height; y++)
                    Marshal.Copy(frame.Bgra, y * frame.Stride, data.Scan0 + y * data.Stride, frame.Width * 4);
            }
        }
        finally { bmp.UnlockBits(data); }
        BurnLabel(bmp, label);
        return EncodeBitmapJpeg(bmp);
    }

    private static void BurnLabel(Bitmap bmp, string text)
    {
        using var g = Graphics.FromImage(bmp);
        using var font = new Font("Segoe UI", 10, FontStyle.Bold);
        var size = g.MeasureString(text, font);
        using var bg = new SolidBrush(Color.FromArgb(160, 0, 0, 0));
        g.FillRectangle(bg, 4, 4, size.Width + 6, size.Height + 2);
        g.DrawString(text, font, Brushes.White, 7, 5);
    }

    private static byte[]? EncodeBitmapJpeg(Bitmap bmp)
    {
        var codec = ImageCodecInfo.GetImageEncoders()
            .FirstOrDefault(c => c.FormatID == ImageFormat.Jpeg.Guid);
        if (codec is null) return null;
        using var ms = new MemoryStream();
        using var ep = new EncoderParameters(1);
        ep.Param[0] = new EncoderParameter(Encoder.Quality, JpegQuality);
        bmp.Save(ms, codec, ep);
        return ms.ToArray();
    }
}
