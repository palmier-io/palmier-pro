using System.Text.Json;
using PalmierPro.Core.Analysis;
using PalmierPro.Core.Editing;
using PalmierPro.Core.Models;
using PalmierPro.Core.Search;
using PalmierPro.Core.Transcription;

namespace PalmierPro.Agent.Tools;

public sealed partial class ToolExecutor
{
    private static ToolResult DetectBeats(IAgentEditorHost host, JsonElement args)
    {
        var mediaRef = ToolArgs.String(args, "mediaRef");
        if (mediaRef is null) return ToolResult.Error("mediaRef is required");
        var path = ResolveMediaPath(host, mediaRef);
        if (path is null) return ToolResult.Error($"Media file not on disk: {mediaRef}");

        float[] mono;
        try { mono = AudioPcmDecoder.DecodeMono(path, (int)BeatPostprocess.SampleRate); }
        catch (Exception ex) { return ToolResult.Error($"Could not decode audio: {ex.Message}"); }

        var analysis = OnsetBeatDetector.Detect(mono);
        var start = ToolArgs.Number(args, "startSeconds");
        var end = ToolArgs.Number(args, "endSeconds");
        IReadOnlyList<double> beats = analysis.Beats;
        IReadOnlyList<double> downbeats = analysis.Downbeats;
        if (start is not null || end is not null)
        {
            var s = Math.Max(0, start ?? 0);
            var e = end ?? double.MaxValue;
            beats = beats.Where(t => t >= s && t <= e).ToList();
            downbeats = downbeats.Where(t => t >= s && t <= e).ToList();
        }

        if (beats.Count == 0 && downbeats.Count == 0)
            return ToolResult.OkJson(new { beats = Array.Empty<double>(), note = "No beats found — the audio may lack rhythmic content." });

        var bpm = BeatPostprocess.EstimateBpm(beats) ?? analysis.Bpm;
        return ToolResult.OkJson(new
        {
            mediaRef,
            units = "source seconds — multiply by fps for frame values",
            beats = beats.Select(t => Math.Round(t, 2)).ToList(),
            downbeats = downbeats.Count == 0 ? null : downbeats.Select(t => Math.Round(t, 2)).ToList(),
            bpm = bpm > 0 ? Math.Round(bpm, 1) : (double?)null,
        });
    }

    private static ToolResult RemoveSilence(IAgentEditorHost host, JsonElement args)
    {
        var ops = host.EditOperations;
        var timeline = host.ActiveTimeline;
        if (ops is null || timeline is null) return ToolResult.Error("No active timeline.");

        var minPause = ToolArgs.Number(args, "minimumPauseSeconds") ?? SilenceRemovalSettings.Default.MinimumPauseSeconds;
        var padding = ToolArgs.Number(args, "speechPaddingSeconds") ?? SilenceRemovalSettings.Default.SpeechPaddingSeconds;
        var settings = SilenceRemovalSettings.Create(minPause, padding);
        if (settings is null)
            return ToolResult.Error("remove_silence: invalid silence-removal settings.");

        var clipIds = ToolArgs.StringArray(args, "clipIds");
        var targets = new List<(int Track, Clip Clip)>();
        if (clipIds.Count > 0)
        {
            foreach (var id in clipIds)
            {
                if (ops.FindClip(id) is not { } found)
                    return ToolResult.Error($"Clip not found: {id}");
                targets.Add(found);
            }
        }
        else
        {
            for (var t = 0; t < timeline.Tracks.Count; t++)
            {
                foreach (var clip in timeline.Tracks[t].Clips)
                {
                    if (clip.MediaType is ClipType.Audio or ClipType.Video)
                        targets.Add((t, clip));
                }
            }
        }

        var sections = 0;
        var removedFrames = 0;
        var fps = Math.Max(1, timeline.Fps);

        foreach (var (track, clip) in targets)
        {
            var path = ResolveMediaPath(host, clip.MediaRef);
            if (path is null) continue;
            float[] mono;
            try { mono = AudioPcmDecoder.DecodeMono(path, EnergyVad.SampleRate); }
            catch { continue; }

            var ranges = DeadAirAnalyzer.RemovableTimelineRanges(clip, fps, mono, settings);
            if (ranges.Count == 0) continue;
            if (!ops.RippleDeleteRangesOnTrack(track, ranges)) continue;
            sections += ranges.Count;
            removedFrames += ranges.Sum(r => r.End - r.Start);
        }

        if (sections == 0)
            return ToolResult.Error("No dead air on the timeline. The audio may have no quiet non-speech sections.");

        host.NotifyTimelineChanged();
        return ToolResult.OkJson(new
        {
            sectionsRemoved = sections,
            removedFrames,
            minimumPauseSeconds = settings.MinimumPauseSeconds,
            speechPaddingSeconds = settings.SpeechPaddingSeconds,
        });
    }

    private static ToolResult DenoiseAudio(IAgentEditorHost host, JsonElement args)
    {
        var ops = host.EditOperations;
        if (ops is null) return ToolResult.Error("No active timeline.");
        var clipIds = ToolArgs.StringArray(args, "clipIds");
        if (clipIds.Count == 0) return ToolResult.Error("clipIds is empty.");
        var strength = ToolArgs.Number(args, "strength");
        if (strength is { } s && (s < 0 || s > 1))
            return ToolResult.Error("strength must be 0–1");
        var enabled = ToolArgs.Bool(args, "enabled") ?? true;

        foreach (var id in clipIds)
        {
            if (ops.FindClip(id) is not { } found)
                return ToolResult.Error($"Clip not found: {id}");
            if (found.Clip.MediaType != ClipType.Audio)
                return ToolResult.Error($"Clip {id} is a {found.Clip.MediaType} clip; denoise_audio needs an audio clip.");
        }

        if (!ops.SetDenoise(clipIds, enabled, strength))
            return ToolResult.Error("No audio clips updated.");
        host.NotifyTimelineChanged();

        var notes = new List<string>();
        var amount = strength ?? Clip.DefaultDenoiseAmount;
        if (enabled)
        {
            foreach (var id in clipIds)
            {
                if (ops.FindClip(id) is not { } found) continue;
                var path = ResolveMediaPath(host, found.Clip.MediaRef);
                if (path is null)
                {
                    notes.Add($"No source file for {found.Clip.MediaRef}; effect stamped only.");
                    continue;
                }
                if (TryBakeDenoise(path, found.Clip.MediaRef, amount, out var bakeNote))
                    notes.Add(bakeNote!);
                else
                    notes.Add(bakeNote ?? "Bake failed; playback uses dry mix attenuation only.");
            }
        }

        return ToolResult.OkJson(new
        {
            clipIds,
            enabled,
            strength = amount,
            notes,
        });
    }

    private static bool TryBakeDenoise(string path, string mediaRef, double amount, out string? note)
    {
        // Soft reflection keeps Agent free of a hard Media project reference cycle in tests.
        var type = Type.GetType("PalmierPro.Media.Audio.AudioEnhancer, PalmierPro.Media");
        if (type is null)
        {
            note = "Denoise effect stamped; bake runs when Media AudioEnhancer is loaded.";
            return false;
        }
        var method = type.GetMethod("TryBake");
        if (method is null)
        {
            note = "Denoise effect stamped; bake API missing.";
            return false;
        }
        var args = new object?[] { path, mediaRef, amount, null, null };
        var ok = (bool)method.Invoke(null, args)!;
        note = args[4] as string;
        return ok;
    }

    private static ToolResult RemoveWords(IAgentEditorHost host, JsonElement args)
    {
        var ops = host.EditOperations;
        var timeline = host.ActiveTimeline;
        if (ops is null || timeline is null) return ToolResult.Error("No active timeline.");

        var cacheKey = host.PackagePath;
        var doc = TranscriptCache.Shared.Get(cacheKey);
        if (doc is null || doc.Words.Count == 0)
        {
            var rebuilt = TimelineTranscript.Build(host, ToolArgs.String(args, "language"), null);
            if (rebuilt is null || rebuilt.Document.Words.Count == 0)
                return ToolResult.Error("No transcript cached. Call get_transcript first.");
            doc = rebuilt.Document;
            TranscriptCache.Shared.Store(cacheKey, doc);
        }

        var aggressiveness = (ToolArgs.String(args, "cutAggressiveness") ?? "balanced").ToLowerInvariant() switch
        {
            "tight" => CutAggressiveness.Tight,
            "loose" => CutAggressiveness.Loose,
            _ => CutAggressiveness.Balanced,
        };
        var keepGapFrames = (int)Math.Round(aggressiveness.KeptGapMs() / 1000.0 * Math.Max(1, timeline.Fps));
        var maxIndex = doc.Words.Count == 0 ? -1 : doc.Words.Max(w => w.Index);
        var ignored = new List<int>();

        var selected = new HashSet<int>();
        if (args.TryGetProperty("words", out var wordsEl) && wordsEl.ValueKind == JsonValueKind.Array)
        {
            foreach (var item in wordsEl.EnumerateArray())
            {
                if (item.ValueKind == JsonValueKind.Number && item.TryGetInt32(out var idx))
                {
                    if (idx < 0 || idx > maxIndex) ignored.Add(idx);
                    else selected.Add(idx);
                }
                else if (item.ValueKind == JsonValueKind.Array && item.GetArrayLength() == 2)
                {
                    var a = item[0].GetInt32();
                    var b = item[1].GetInt32();
                    for (var i = Math.Min(a, b); i <= Math.Max(a, b); i++)
                    {
                        if (i < 0 || i > maxIndex) ignored.Add(i);
                        else selected.Add(i);
                    }
                }
            }
        }
        else if (args.TryGetProperty("matches", out var matchesEl) && matchesEl.ValueKind == JsonValueKind.Array)
        {
            var tokens = matchesEl.EnumerateArray()
                .Where(x => x.ValueKind == JsonValueKind.String)
                .Select(x => NormalizeToken(x.GetString()!))
                .ToHashSet(StringComparer.OrdinalIgnoreCase);
            foreach (var w in doc.Words)
            {
                if (tokens.Contains(NormalizeToken(w.Text))) selected.Add(w.Index);
            }
        }
        else
        {
            return ToolResult.Error("Missing 'words' or 'matches'.");
        }

        if (selected.Count == 0)
            return ToolResult.Error("No transcript words matched. Re-read get_transcript.");

        var selectedWords = doc.Words.Where(w => selected.Contains(w.Index)).ToList();
        var clipIds = selectedWords.Select(w => w.ClipId).Where(id => id is not null).Distinct().ToList();
        var linkGroups = clipIds
            .Select(id => ops.FindClip(id!)?.Clip.LinkGroupId)
            .Distinct()
            .ToList();
        if (clipIds.Count > 1 && (linkGroups.Count != 1 || linkGroups[0] is null))
            return ToolResult.Error(
                "Selected words span multiple unlinked clips. Restrict to one clip or a linked A/V pair.");

        // Cut on primary (first) track only — ripple carries linked partners via sync-lock.
        var primaryTrack = selectedWords
            .Select(w => w.TrackIndex ?? ops.FindClip(w.ClipId ?? "")?.TrackIndex)
            .Where(t => t is not null)
            .Select(t => t!.Value)
            .DefaultIfEmpty(0)
            .Min();

        var plan = selectedWords
            .Concat(doc.Words.Where(w =>
                (w.TrackIndex ?? primaryTrack) == primaryTrack && !selected.Contains(w.Index)))
            .GroupBy(w => w.Index)
            .Select(g => g.First())
            .OrderBy(w => w.StartFrame)
            .Select(w => new WordCutPlanner.Word(w.StartFrame, w.EndFrame, selected.Contains(w.Index)))
            .ToList();
        if (plan.Count == 0)
            return ToolResult.Error("The selected words resolved to no removable frames.");

        var clipStart = plan.Min(w => w.StartFrame);
        var clipEnd = plan.Max(w => w.EndFrame);
        var ranges = WordCutPlanner.CutRanges(plan, clipStart, clipEnd, keepGapFrames);
        if (ranges.Count == 0)
            return ToolResult.Error("The selected words resolved to no removable frames.");

        var snapshot = MutationDelta.Snapshot(timeline);
        ops.RippleDeleteRangesOnTrack(primaryTrack, ranges);
        host.NotifyTimelineChanged();
        TranscriptCache.Shared.Clear(cacheKey);

        var removedText = string.Join(" ", selectedWords.Select(w => w.Text));
        var extra = new Dictionary<string, object?>
        {
            ["removedWords"] = selected.Count,
            ["removedFrames"] = ranges.Sum(r => r.End - r.Start),
            ["removedRanges"] = ranges.Select(r => new { start = r.Start, end = r.End }).ToList(),
            ["cutAggressiveness"] = aggressiveness.ToString().ToLowerInvariant(),
            ["transcriptionSource"] = doc.Source,
            ["removedText"] = removedText.Length > 200 ? removedText[..200] + "…" : removedText,
        };
        if (ignored.Count > 0) extra["indicesIgnored"] = ignored.Distinct().OrderBy(i => i).ToList();
        return MutationDelta.Result(host, snapshot, null, extra,
            ["Word indices shifted — re-read get_transcript before another remove_words."]);
    }

    private static string NormalizeToken(string text)
    {
        var chars = text.Where(ch => !char.IsPunctuation(ch)).ToArray();
        return new string(chars).Trim().ToLowerInvariant();
    }

    private static ToolResult SearchMedia(IAgentEditorHost host, JsonElement args)
    {
        var query = ToolArgs.String(args, "query");
        if (string.IsNullOrWhiteSpace(query)) return ToolResult.Error("query is required");
        var scope = (ToolArgs.String(args, "scope") ?? "both").ToLowerInvariant();
        var limit = ToolArgs.Int(args, "limit") ?? 10;
        var mediaRefFilter = ToolArgs.String(args, "mediaRef");

        var hits = new List<object>();
        string? visualIndexStatus = null;
        string? spokenIndexStatus = null;

        if (scope is "spoken" or "both")
        {
            var doc = TranscriptCache.Shared.Get(host.PackagePath);
            spokenIndexStatus = doc is null ? "no_transcript" : "ready";
            if (doc is not null)
            {
                var q = query.Trim();
                foreach (var seg in doc.Segments)
                {
                    if (mediaRefFilter is not null && doc.MediaRef != mediaRefFilter) break;
                    if (seg.Text.Contains(q, StringComparison.OrdinalIgnoreCase))
                    {
                        hits.Add(new
                        {
                            mediaRef = doc.MediaRef,
                            scope = "spoken",
                            startFrame = seg.StartFrame,
                            endFrame = seg.EndFrame,
                            text = seg.Text,
                            score = 1.0,
                        });
                    }
                }
            }
        }

        if (scope is "visual" or "both")
        {
            var storePath = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "PalmierPro", "search", SanitizePathKey(host.PackagePath) + ".emb");
            var existed = File.Exists(storePath);
            EmbeddingStore store;
            if (existed)
            {
                try { store = EmbeddingStore.Load(storePath); }
                catch { store = host.BuildVisualSearchIndex(storePath); }
            }
            else
            {
                store = host.BuildVisualSearchIndex(storePath);
            }

            visualIndexStatus = File.Exists(storePath)
                ? (existed ? "ready" : "built")
                : "empty";

            var qv = EmbeddingMath.TextEmbed(query);
            foreach (var hit in store.Search(qv, limit, mediaRefFilter))
            {
                hits.Add(new
                {
                    mediaRef = hit.MediaRef,
                    scope = "visual",
                    seconds = Math.Round(hit.Seconds, 2),
                    score = Math.Round(hit.Score, 4),
                });
            }
        }

        var indexStatus = scope switch
        {
            "spoken" => spokenIndexStatus ?? "no_transcript",
            "visual" => visualIndexStatus ?? "empty",
            _ => visualIndexStatus ?? spokenIndexStatus ?? "empty",
        };

        return ToolResult.OkJson(new
        {
            query,
            indexStatus,
            hits = hits.Take(limit).ToList(),
            note = hits.Count == 0
                ? "No hits. Visual index samples decoded frames (color/spatial features)."
                : "Visual scores from decoded-frame features (SigLIP ONNX optional upgrade).",
        });
    }

    private static string? ResolveMediaPath(IAgentEditorHost host, string mediaRef)
    {
        var entry = host.ResolveMedia(mediaRef);
        if (entry is null) return null;
        return new MediaResolver(() => host.Manifest, () => host.PackagePath).ResolvePath(entry.Id);
    }

    private static string SanitizePathKey(string s)
    {
        foreach (var c in Path.GetInvalidFileNameChars())
            s = s.Replace(c, '_');
        return s.Length > 80 ? s[..80] : s;
    }
}
