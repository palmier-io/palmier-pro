using PalmierPro.Core.Models;
using PalmierPro.Core.Transcription;

namespace PalmierPro.Agent.Tools;

/// <summary>Mac-style timeline walk: global word indices in project frames.</summary>
internal static class TimelineTranscript
{
    public sealed record ClipWords(
        string ClipId, int TrackIndex, int StartFrame, int EndFrame,
        IReadOnlyList<TranscriptWord> Words);

    public sealed record BuildResult(
        TranscriptDocument Document,
        IReadOnlyList<ClipWords> Clips,
        string TranscriptionSource,
        IReadOnlyList<object> Skipped);

    public static BuildResult? Build(
        IAgentEditorHost host, string? language, string? clipIdFilter)
    {
        var timeline = host.ActiveTimeline;
        if (timeline is null) return null;
        var fps = Math.Max(1, timeline.Fps);
        var fragments = new List<(Clip Clip, int TrackIndex, string Path)>();
        for (var t = 0; t < timeline.Tracks.Count; t++)
        {
            foreach (var clip in timeline.Tracks[t].Clips)
            {
                if (clip.MediaType is not (ClipType.Video or ClipType.Audio)) continue;
                if (clipIdFilter is not null
                    && clip.Id != clipIdFilter
                    && !clip.Id.StartsWith(clipIdFilter, StringComparison.OrdinalIgnoreCase))
                    continue;
                var path = ResolveMediaPath(host, clip.MediaRef);
                if (path is null) continue;
                fragments.Add((clip, t, path));
            }
        }

        if (fragments.Count == 0) return null;

        var byPath = new Dictionary<string, TranscriptDocument>(StringComparer.OrdinalIgnoreCase);
        var skipped = new List<object>();
        var words = new List<TranscriptWord>();
        var segments = new List<TranscriptSegment>();
        var clipRows = new List<ClipWords>();
        var textParts = new List<string>();
        var source = "local";

        foreach (var (clip, trackIndex, path) in fragments.OrderBy(f => f.Clip.StartFrame))
        {
            if (!byPath.TryGetValue(path, out var doc))
            {
                try
                {
                    doc = LocalStt.TranscribeFile(path, clip.MediaRef, fps, language);
                    byPath[path] = doc;
                    if (doc.Source is "whisper" or "cloud") source = doc.Source;
                }
                catch (Exception ex)
                {
                    skipped.Add(new { file = path, reason = ex.Message });
                    continue;
                }
            }

            var mapped = new List<TranscriptWord>();
            foreach (var w in doc.Words)
            {
                var startSec = w.StartSeconds ?? w.StartFrame / (double)fps;
                var endSec = w.EndSeconds ?? w.EndFrame / (double)fps;
                var projectStart = MapSourceToTimeline(startSec, clip, fps);
                var projectEnd = MapSourceToTimeline(endSec, clip, fps);
                if (projectEnd <= clip.StartFrame || projectStart >= clip.EndFrame) continue;
                projectStart = Math.Max(projectStart, clip.StartFrame);
                projectEnd = Math.Min(Math.Max(projectStart + 1, projectEnd), clip.EndFrame);
                var tw = new TranscriptWord
                {
                    Text = w.Text,
                    StartFrame = projectStart,
                    EndFrame = projectEnd,
                    StartSeconds = projectStart / (double)fps,
                    EndSeconds = projectEnd / (double)fps,
                    Index = words.Count,
                    Speaker = w.Speaker,
                    ClipId = clip.Id,
                    TrackIndex = trackIndex,
                };
                words.Add(tw);
                mapped.Add(tw);
            }

            if (mapped.Count == 0) continue;
            textParts.Add(string.Join(" ", mapped.Select(m => m.Text)));
            segments.Add(new TranscriptSegment
            {
                Text = string.Join(" ", mapped.Select(m => m.Text)),
                StartFrame = mapped[0].StartFrame,
                EndFrame = mapped[^1].EndFrame,
            });
            clipRows.Add(new ClipWords(clip.Id, trackIndex, clip.StartFrame, clip.EndFrame, mapped));
        }

        var document = new TranscriptDocument
        {
            MediaRef = "timeline",
            Source = source,
            Language = language,
            Text = string.Join(" ", textParts),
            Words = words,
            Segments = segments,
        };
        return new BuildResult(document, clipRows, source, skipped);
    }

    public static object ResponsePayload(
        BuildResult built, int fps, int? startFrame, int? endFrame,
        string granularity, string? clipIdFilter)
    {
        const int maxWords = 10_000;
        var s = startFrame ?? 0;
        var e = endFrame ?? int.MaxValue;
        var filtered = built.Document.Words
            .Where(w => w.EndFrame > s && w.StartFrame < e)
            .Where(w => clipIdFilter is null
                || w.ClipId == clipIdFilter
                || (w.ClipId?.StartsWith(clipIdFilter, StringComparison.OrdinalIgnoreCase) ?? false))
            .ToList();

        var truncated = filtered.Count > maxWords;
        if (truncated) filtered = filtered.Take(maxWords).ToList();

        var byClip = filtered.GroupBy(w => w.ClipId ?? "")
            .Select(g =>
            {
                var first = g.First();
                var row = new Dictionary<string, object?>
                {
                    ["clipId"] = first.ClipId,
                    ["trackIndex"] = first.TrackIndex,
                    ["startFrame"] = first.StartFrame,
                    ["endFrame"] = g.Max(w => w.EndFrame),
                };
                if (granularity == "segments")
                {
                    row["segmentFormat"] = new[] { "firstWordIndex", "text", "start", "end" };
                    row["segments"] = BuildSegments(g.ToList());
                }
                else
                {
                    row["wordFormat"] = new[] { "index", "text", "startFrame" };
                    row["words"] = g.Select(w => new object[] { w.Index, w.Text, w.StartFrame }).ToList();
                }
                return row;
            })
            .OrderBy(r => (int)r["trackIndex"]!)
            .ThenBy(r => (int)r["startFrame"]!)
            .ToList();

        var payload = new Dictionary<string, object?>
        {
            ["fps"] = fps,
            ["timing"] = "projectFrames",
            ["transcriptionSource"] = built.TranscriptionSource,
            ["wordFormat"] = new[] { "index", "text", "startFrame" },
            ["clips"] = byClip,
            ["text"] = built.Document.Text,
        };
        if (truncated)
        {
            payload["totalWords"] = built.Document.Words.Count;
            payload["nextStartFrame"] = filtered[^1].EndFrame;
            payload["wordsNote"] = $"First {maxWords} words — pass startFrame={filtered[^1].EndFrame} to continue.";
        }
        if (built.Skipped.Count > 0) payload["skipped"] = built.Skipped;
        return payload;
    }

    private static List<object[]> BuildSegments(List<TranscriptWord> words)
    {
        var segs = new List<object[]>();
        if (words.Count == 0) return segs;
        var buf = new List<TranscriptWord> { words[0] };
        void Flush()
        {
            if (buf.Count == 0) return;
            segs.Add([
                buf[0].Index,
                string.Join(" ", buf.Select(w => w.Text)),
                buf[0].StartFrame,
                buf[^1].EndFrame,
            ]);
            buf.Clear();
        }

        for (var i = 1; i < words.Count; i++)
        {
            var prev = words[i - 1];
            var cur = words[i];
            var gap = cur.StartFrame - prev.EndFrame;
            var punct = prev.Text.EndsWith('.') || prev.Text.EndsWith('!') || prev.Text.EndsWith('?');
            if (gap > 30 || punct || buf.Count >= 48)
            {
                Flush();
            }
            buf.Add(cur);
        }
        Flush();
        return segs;
    }

    private static int MapSourceToTimeline(double sourceSeconds, Clip clip, int fps)
    {
        var sourceFrame = sourceSeconds * fps;
        var timeline = clip.StartFrame + (sourceFrame - clip.TrimStartFrame) / Math.Max(0.0001, clip.Speed);
        return (int)Math.Round(timeline);
    }

    private static string? ResolveMediaPath(IAgentEditorHost host, string mediaRef)
    {
        var entry = host.ResolveMedia(mediaRef);
        if (entry is null) return null;
        return new MediaResolver(() => host.Manifest, () => host.PackagePath).ResolvePath(entry.Id);
    }
}
