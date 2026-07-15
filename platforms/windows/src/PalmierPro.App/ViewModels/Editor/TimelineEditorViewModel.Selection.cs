namespace PalmierPro.App.ViewModels.Editor;

/// Ports `EditorViewModel+Selection.swift`.
public sealed partial class TimelineEditorViewModel
{
    public enum SelectForwardScope
    {
        Track,
        AllTracks,
    }

    public void SelectForwardFromCurrentSelection(SelectForwardScope scope)
    {
        if (ForwardSelectionAnchorId() is { } anchorId)
        {
            SelectForward(anchorId, scope);
        }
    }

    public void SelectForward(string clipId, SelectForwardScope scope)
    {
        if (FindClip(clipId) is not { } anchorLoc)
        {
            return;
        }
        var anchorClip = Timeline.Tracks[anchorLoc.TrackIndex].Clips[anchorLoc.ClipIndex];
        var ids = new HashSet<string>();

        for (var trackIndex = 0; trackIndex < Timeline.Tracks.Count; trackIndex++)
        {
            if (scope != SelectForwardScope.AllTracks && trackIndex != anchorLoc.TrackIndex)
            {
                continue;
            }
            foreach (var clip in Timeline.Tracks[trackIndex].Clips)
            {
                if (clip.StartFrame >= anchorClip.StartFrame)
                {
                    ids.Add(clip.Id);
                }
            }
        }

        SelectedClipIds = ExpandToLinkGroup(ids);
        SelectedGap = null;
    }

    private string? ForwardSelectionAnchorId()
    {
        var candidates = new List<(int TrackIndex, string ClipId, int StartFrame)>();
        for (var trackIndex = 0; trackIndex < Timeline.Tracks.Count; trackIndex++)
        {
            foreach (var clip in Timeline.Tracks[trackIndex].Clips)
            {
                if (SelectedClipIds.Contains(clip.Id))
                {
                    candidates.Add((trackIndex, clip.Id, clip.StartFrame));
                }
            }
        }
        if (candidates.Count == 0)
        {
            return null;
        }
        candidates.Sort((a, b) => a.StartFrame != b.StartFrame
            ? a.StartFrame.CompareTo(b.StartFrame)
            : a.TrackIndex.CompareTo(b.TrackIndex));
        return candidates[0].ClipId;
    }
}
