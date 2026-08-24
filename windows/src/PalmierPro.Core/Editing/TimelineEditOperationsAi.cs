using PalmierPro.Core.Models;
using PalmierPro.Core.Serialization;

namespace PalmierPro.Core.Editing;

public sealed partial class TimelineEditOperations
{
    /// <summary>
    /// Places a pending generation placeholder spanning a gap (AI transition / gap fill stub).
    /// Returns the new clip id, or null on refusal.
    /// </summary>
    public string? PlaceAiGapFill(
        string mediaRef,
        int trackIndex,
        int startFrame,
        int endFrame,
        string? note = null)
    {
        if (trackIndex < 0 || trackIndex >= Timeline.Tracks.Count) return null;
        if (endFrame <= startFrame) return null;
        if (Timeline.Tracks[trackIndex].Type != ClipType.Video) return null;

        string? created = null;
        MutateWithTimelineSwap("AI Gap Fill", () =>
        {
            ClearRegion(trackIndex, startFrame, endFrame);
            var clip = new Clip
            {
                Id = Uuid.NewString(),
                MediaRef = mediaRef,
                MediaType = ClipType.Video,
                SourceClipType = ClipType.Video,
                StartFrame = startFrame,
                DurationFrames = endFrame - startFrame,
            };
            Timeline.Tracks[trackIndex].Clips.Add(clip);
            SortAllTracks();
            created = clip.Id;
        });
        _ = note;
        return created;
    }
}
