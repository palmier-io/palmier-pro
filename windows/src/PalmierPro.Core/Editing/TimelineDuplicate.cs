using PalmierPro.Core.Models;
using PalmierPro.Core.Serialization;

namespace PalmierPro.Core.Editing;

public static class TimelineDuplicate
{
    /// <summary>Deep-copies a timeline with fresh ids for the timeline, tracks, and clips.</summary>
    public static Timeline CloneWithNewIds(Timeline source, string? name = null)
    {
        var json = PalmierJson.Encode(source);
        var clone = PalmierJson.Decode<Timeline>(json)
            ?? throw new InvalidOperationException("Timeline clone failed.");
        clone.Id = Uuid.NewString();
        clone.Name = string.IsNullOrWhiteSpace(name) ? $"{source.Name} Copy" : name.Trim();
        foreach (var track in clone.Tracks)
        {
            track.Id = Uuid.NewString();
            foreach (var clip in track.Clips)
                clip.Id = Uuid.NewString();
        }
        return clone;
    }
}
