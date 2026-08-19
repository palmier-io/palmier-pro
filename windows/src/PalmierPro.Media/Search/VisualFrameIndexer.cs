using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using PalmierPro.Core.Models;
using PalmierPro.Core.Search;
using PalmierPro.Media.Ml;
using PalmierPro.Media.Video;

namespace PalmierPro.Media.Search;

/// <summary>
/// Builds visual embeddings by decoding actual frames (not bag-of-file-bytes).
/// Samples several timestamps per video for better search coverage.
/// </summary>
public static class VisualFrameIndexer
{
    public static EmbeddingStore Build(
        string packagePath,
        MediaManifest manifest,
        string storePath,
        int samplesPerVideo = 4)
    {
        var store = new EmbeddingStore();
        var resolver = new MediaResolver(() => manifest, () => packagePath);
        foreach (var entry in manifest.Entries)
        {
            if (entry.Type is not (ClipType.Video or ClipType.Image)) continue;
            var path = resolver.ResolvePath(entry.Id);
            if (path is null) continue;
            try
            {
                foreach (var (seconds, embedding) in EmbedAsset(path, entry.Type, entry.Duration, samplesPerVideo))
                    store.Add(entry.Id, seconds, embedding);
            }
            catch { /* skip */ }
        }
        try { store.Save(storePath); } catch { /* best-effort */ }
        return store;
    }

    public static IEnumerable<(double Seconds, float[] Embedding)> EmbedAsset(
        string path, ClipType type, double duration, int samplesPerVideo = 4)
    {
        if (type == ClipType.Image)
        {
            using var bmp = new Bitmap(path);
            var emb = EmbedBitmap(bmp);
            if (emb is not null) yield return (0, emb);
            yield break;
        }

        using var extractor = new VideoFrameExtractor(path);
        var dur = duration > 0.05 ? duration : Math.Max(0.1, extractor.DurationSeconds);
        var n = Math.Clamp(samplesPerVideo, 1, 12);
        for (var i = 0; i < n; i++)
        {
            var t = (i + 0.5) * dur / n;
            using var bmp = extractor.FrameAt(t, 256, 256);
            if (bmp is null) continue;
            var emb = EmbedBitmap(bmp);
            if (emb is not null) yield return (t, emb);
        }
    }

    private static float[]? EmbedBitmap(Bitmap bmp)
    {
        var rect = new Rectangle(0, 0, bmp.Width, bmp.Height);
        var data = bmp.LockBits(rect, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        try
        {
            var bytes = new byte[Math.Abs(data.Stride) * data.Height];
            Marshal.Copy(data.Scan0, bytes, 0, bytes.Length);
            return SiglipEmbedder.TryEmbed(bytes, bmp.Width, bmp.Height, data.Stride)
                   ?? EmbeddingMath.FrameFeatureEmbed(bytes, bmp.Width, bmp.Height, data.Stride);
        }
        finally { bmp.UnlockBits(data); }
    }
}
