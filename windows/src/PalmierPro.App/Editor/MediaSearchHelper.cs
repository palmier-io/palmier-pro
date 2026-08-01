using PalmierPro.Core.Models;
using PalmierPro.Core.Search;
using PalmierPro.Core.Transcription;
using PalmierPro.Media.Search;

namespace PalmierPro.App.Editor;

/// <summary>
/// Shared media search used by the media panel and Agent search_media tool.
/// </summary>
public static class MediaSearchHelper
{
    public sealed record SearchHit(
        string MediaRef,
        string Scope,
        int? StartFrame,
        int? EndFrame,
        string? Text,
        double? Seconds,
        double Score);

    public static IReadOnlyList<SearchHit> Search(
        string packagePath,
        MediaManifest manifest,
        string query,
        string scope = "both",
        int limit = 10,
        string? mediaRefFilter = null)
    {
        if (string.IsNullOrWhiteSpace(query)) return [];
        scope = scope.ToLowerInvariant();
        var hits = new List<SearchHit>();

        if (scope is "spoken" or "both")
        {
            var doc = TranscriptCache.Shared.Get(packagePath);
            if (doc is not null)
            {
                var q = query.Trim();
                foreach (var seg in doc.Segments)
                {
                    if (mediaRefFilter is not null && doc.MediaRef != mediaRefFilter) break;
                    if (seg.Text.Contains(q, StringComparison.OrdinalIgnoreCase))
                    {
                        hits.Add(new SearchHit(
                            doc.MediaRef, "spoken", seg.StartFrame, seg.EndFrame, seg.Text, null, 1.0));
                    }
                }
            }
        }

        if (scope is "visual" or "both")
        {
            var storePath = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "PalmierPro", "search", SanitizePathKey(packagePath) + ".emb");
            EmbeddingStore store;
            if (File.Exists(storePath))
            {
                try { store = EmbeddingStore.Load(storePath); }
                catch { store = VisualFrameIndexer.Build(packagePath, manifest, storePath); }
            }
            else
            {
                store = VisualFrameIndexer.Build(packagePath, manifest, storePath);
            }

            var qv = EmbeddingMath.TextEmbed(query);
            foreach (var hit in store.Search(qv, limit, mediaRefFilter))
            {
                hits.Add(new SearchHit(
                    hit.MediaRef, "visual", null, null, null, hit.Seconds, hit.Score));
            }
        }

        return hits.Take(limit).ToList();
    }

    private static string SanitizePathKey(string s)
    {
        foreach (var c in Path.GetInvalidFileNameChars())
            s = s.Replace(c, '_');
        return s.Length > 80 ? s[..80] : s;
    }
}
