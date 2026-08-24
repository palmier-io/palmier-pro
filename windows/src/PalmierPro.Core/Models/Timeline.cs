using System.Text.Json.Serialization;
using PalmierPro.Core.Serialization;

namespace PalmierPro.Core.Models;

/// <summary>Clip location inside track storage.</summary>
public readonly record struct ClipLocation(int TrackIndex, int ClipIndex);

/// <summary>Written on tab switch and save, not live — playhead mutates every frame.</summary>
public sealed class TimelineViewState
{
    public int PlayheadFrame { get; set; }
    public double ZoomScale { get; set; } = EditorDefaults.PixelsPerFrame;
    public double ScrollOffsetX { get; set; }
}

public sealed class Timeline
{
    public string Id { get; set; } = Uuid.NewString();
    public string Name { get; set; } = "Timeline 1";
    public int Fps { get; set; } = 30;
    public int Width { get; set; } = 1920;
    public int Height { get; set; } = 1080;
    public bool SettingsConfigured { get; set; }
    public string? FolderId { get; set; }
    public List<Track> Tracks { get; set; } = [];

    [JsonIgnore]
    public int TotalFrames
    {
        get
        {
            var maxFrame = 0;
            foreach (var track in Tracks)
            {
                maxFrame = Math.Max(maxFrame, track.EndFrame);
            }
            return maxFrame;
        }
    }

    [JsonIgnore]
    public bool HasAudioClips => Tracks.Any(t => t.Type == ClipType.Audio && t.Clips.Count > 0);

    /// <summary>Reachable nested timelines, breadth-first, deduped, excluding self and filtered by <paramref name="include"/>.</summary>
    public List<Timeline> ReachableTimelines(
        Func<string, Timeline?> resolve,
        int maxDepth = int.MaxValue,
        Func<Timeline, bool>? include = null)
    {
        include ??= _ => true;
        var found = new List<Timeline>();
        var seen = new HashSet<string> { Id };
        var queue = new List<(Timeline Timeline, int Depth)> { (this, 0) };
        var i = 0;
        while (i < queue.Count)
        {
            var (t, depth) = queue[i];
            i += 1;
            if (depth >= maxDepth) continue;
            foreach (var clip in t.Tracks.SelectMany(tr => tr.Clips).Where(c => c.SourceClipType == ClipType.Sequence))
            {
                if (!seen.Add(clip.MediaRef)) continue;
                var child = resolve(clip.MediaRef);
                if (child is null || !include(child)) continue;
                found.Add(child);
                queue.Add((child, depth + 1));
            }
        }
        return found;
    }
}

public sealed class Track : IJsonOnDeserialized
{
    public string Id { get; set; } = Uuid.NewString();
    public required ClipType Type { get; set; }
    public bool Muted { get; set; }
    public bool Hidden { get; set; }
    public bool SyncLocked { get; set; } = true;
    public List<Clip> Clips { get; set; } = [];
    public double DisplayHeight { get; set; } = 50;

    void IJsonOnDeserialized.OnDeserialized()
    {
        DisplayHeight = Math.Min(Math.Max(DisplayHeight, TrackSize.MinHeight), TrackSize.MaxHeight);
    }

    [JsonIgnore]
    public int EndFrame
    {
        get
        {
            var maxFrame = 0;
            foreach (var clip in Clips)
            {
                maxFrame = Math.Max(maxFrame, clip.EndFrame);
            }
            return maxFrame;
        }
    }

    /// <summary>Returns IDs of clips forming a contiguous chain starting at <paramref name="fromEnd"/>, excluding <paramref name="excludeId"/>.</summary>
    public HashSet<string> ContiguousClipIds(int fromEnd, string excludeId)
    {
        var ids = new HashSet<string>();
        var chainEnd = fromEnd;
        foreach (var c in Clips.OrderBy(c => c.StartFrame).Where(c => c.Id != excludeId && c.StartFrame >= fromEnd))
        {
            if (c.StartFrame != chainEnd) break;
            chainEnd = c.EndFrame;
            ids.Add(c.Id);
        }
        return ids;
    }
}
