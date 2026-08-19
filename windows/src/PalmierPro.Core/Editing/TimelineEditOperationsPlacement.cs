using PalmierPro.Core.Models;
using PalmierPro.Core.Serialization;

namespace PalmierPro.Core.Editing;

public readonly record struct PlaceClipRequest(
    string MediaRef,
    ClipType MediaType,
    double DurationSeconds,
    bool HasAudio,
    int TrackIndex,
    int StartFrame,
    int DurationFrames,
    int TrimStartFrame = 0,
    int TrimEndFrame = 0,
    bool AddLinkedAudio = true,
    int? LinkedAudioTrackIndex = null);

public readonly record struct RippleInsertSpec(
    string MediaRef,
    ClipType MediaType,
    double DurationSeconds,
    bool HasAudio,
    int DurationFrames,
    int TrimStartFrame = 0,
    int TrimEndFrame = 0);

public sealed partial class TimelineEditOperations
{
    /// <summary>
    /// Overwrite-places a clip (and optional linked audio) at a track/frame.
    /// Mirrors Mac EditorViewModel.placeClip for Agent and UI drop paths.
    /// </summary>
    public List<string> PlaceClip(PlaceClipRequest request)
    {
        if (!CanPlace(request)) return [];
        var ids = new List<string>();
        MutateWithTimelineSwap("Add Clip", () => ids.AddRange(PlaceClipCore(request)));
        return ids;
    }

    /// <summary>
    /// Opens a gap at <paramref name="atFrame"/> on the target, sync-locked, and linked-audio
    /// tracks, then places clips sequentially — Mac rippleInsertClips.
    /// </summary>
    public List<string> RippleInsertClips(
        IReadOnlyList<RippleInsertSpec> specs, int trackIndex, int atFrame)
    {
        if (trackIndex < 0 || trackIndex >= Timeline.Tracks.Count || specs.Count == 0 || atFrame < 0)
            return [];
        if (specs.Any(s => s.DurationFrames < 1)) return [];
        if (!specs.All(s => s.MediaType.IsCompatible(Timeline.Tracks[trackIndex].Type)))
            return [];

        var created = new List<string>();
        MutateWithTimelineSwap(
            specs.Count == 1 ? "Ripple Insert Clip" : "Ripple Insert Clips",
            () =>
            {
                var totalPush = specs.Sum(s => s.DurationFrames);
                var targetIsVideo = Timeline.Tracks[trackIndex].Type == ClipType.Video;
                var needsLinkedAudio = targetIsVideo && specs.Any(s =>
                    s.HasAudio && s.MediaType is ClipType.Video or ClipType.Sequence);

                int? linkedAudioTrackIndex = null;
                if (needsLinkedAudio)
                {
                    linkedAudioTrackIndex = Timeline.Tracks
                        .Select((t, i) => (t, i))
                        .Where(x => x.t.Type == ClipType.Audio)
                        .Select(x => (int?)x.i)
                        .FirstOrDefault();
                    linkedAudioTrackIndex ??= InsertTrackRaw(Timeline.Tracks.Count, ClipType.Audio);
                }

                var pushTracks = Timeline.Tracks.Select((_, i) => i)
                    .Where(i => i == trackIndex
                        || i == linkedAudioTrackIndex
                        || Timeline.Tracks[i].SyncLocked)
                    .ToList();

                foreach (var ti in pushTracks)
                {
                    var straddler = Timeline.Tracks[ti].Clips
                        .FirstOrDefault(c => c.StartFrame < atFrame && atFrame < c.EndFrame);
                    if (straddler is not null)
                        SplitClipCore(straddler.Id, atFrame);
                }

                foreach (var ti in pushTracks)
                {
                    var shifts = RippleEngine.ComputePushShifts(
                        Timeline.Tracks[ti].Clips, atFrame, totalPush);
                    ApplyClipShifts(ti, shifts);
                }

                var cursor = atFrame;
                foreach (var spec in specs)
                {
                    created.AddRange(PlaceClipCore(new PlaceClipRequest(
                        spec.MediaRef,
                        spec.MediaType,
                        spec.DurationSeconds,
                        spec.HasAudio,
                        trackIndex,
                        cursor,
                        spec.DurationFrames,
                        spec.TrimStartFrame,
                        spec.TrimEndFrame,
                        AddLinkedAudio: needsLinkedAudio,
                        LinkedAudioTrackIndex: linkedAudioTrackIndex)));
                    cursor += spec.DurationFrames;
                }
            });
        return created;
    }

    private bool CanPlace(PlaceClipRequest request)
    {
        if (request.TrackIndex < 0 || request.TrackIndex >= Timeline.Tracks.Count) return false;
        if (request.StartFrame < 0 || request.DurationFrames < 1) return false;
        return request.MediaType.IsCompatible(Timeline.Tracks[request.TrackIndex].Type);
    }

    private List<string> PlaceClipCore(PlaceClipRequest request)
    {
        var track = Timeline.Tracks[request.TrackIndex];
        ClearRegion(request.TrackIndex, request.StartFrame,
            request.StartFrame + request.DurationFrames);

        var linkGroupId = request.AddLinkedAudio
            && track.Type == ClipType.Video
            && request.HasAudio
            && request.MediaType is ClipType.Video or ClipType.Sequence
            ? Uuid.NewString()
            : null;

        var ids = new List<string>();
        var clip = new Clip
        {
            MediaRef = request.MediaRef,
            MediaType = request.MediaType == ClipType.Sequence ? ClipType.Video : request.MediaType,
            SourceClipType = request.MediaType,
            StartFrame = request.StartFrame,
            DurationFrames = request.DurationFrames,
            TrimStartFrame = Math.Max(0, request.TrimStartFrame),
            TrimEndFrame = Math.Max(0, request.TrimEndFrame),
            LinkGroupId = linkGroupId,
        };
        track.Clips.Add(clip);
        ids.Add(clip.Id);

        if (linkGroupId is not null)
        {
            var audioIdx = request.LinkedAudioTrackIndex
                ?? ResolveOrCreateAudioTrack(request.StartFrame, request.DurationFrames);
            if (audioIdx < 0 || audioIdx >= Timeline.Tracks.Count)
                audioIdx = ResolveOrCreateAudioTrack(request.StartFrame, request.DurationFrames);
            ClearRegion(audioIdx, request.StartFrame, request.StartFrame + request.DurationFrames);
            var audio = new Clip
            {
                MediaRef = request.MediaRef,
                MediaType = ClipType.Audio,
                SourceClipType = request.MediaType,
                StartFrame = request.StartFrame,
                DurationFrames = request.DurationFrames,
                TrimStartFrame = clip.TrimStartFrame,
                TrimEndFrame = clip.TrimEndFrame,
                LinkGroupId = linkGroupId,
            };
            Timeline.Tracks[audioIdx].Clips.Add(audio);
            ids.Add(audio.Id);
        }

        SortAllTracks();
        return ids;
    }

    private void ApplyClipShifts(int trackIndex, IReadOnlyList<ClipShift> shifts)
    {
        if (shifts.Count == 0) return;
        var map = shifts.ToDictionary(s => s.ClipId, s => s.NewStartFrame);
        foreach (var clip in Timeline.Tracks[trackIndex].Clips)
        {
            if (map.TryGetValue(clip.Id, out var start))
                clip.StartFrame = start;
        }
        Timeline.Tracks[trackIndex].Clips.Sort((a, b) => a.StartFrame.CompareTo(b.StartFrame));
    }

    /// <summary>Split without opening a nested undo group (caller owns the swap).</summary>
    private void SplitClipCore(string clipId, int frame)
    {
        if (FindClip(clipId) is not { } found) return;
        var members = new List<(int TrackIndex, Clip Clip)> { found };
        if (found.Clip.LinkGroupId is not null)
        {
            members.AddRange(LinkedPartnerIds(clipId)
                .Select(id => FindClip(id))
                .Where(p => p is not null)
                .Select(p => p!.Value));
        }
        var splittable = members
            .Where(m => frame > m.Clip.StartFrame && frame < m.Clip.EndFrame)
            .ToList();
        if (splittable.Count == 0) return;

        var newGroupId = splittable.Count > 1 ? Uuid.NewString() : null;
        foreach (var (trackIndex, clip) in splittable)
        {
            var right = SplitValues(clip, frame);
            if (newGroupId is not null) right.LinkGroupId = newGroupId;
            var track = Timeline.Tracks[trackIndex];
            track.Clips.Insert(track.Clips.IndexOf(clip) + 1, right);
        }
    }

    private int ResolveOrCreateAudioTrack(int startFrame, int duration)
    {
        for (var i = 0; i < Timeline.Tracks.Count; i++)
        {
            var t = Timeline.Tracks[i];
            if (t.Type != ClipType.Audio) continue;
            var end = startFrame + duration;
            if (!t.Clips.Any(c => c.StartFrame < end && c.EndFrame > startFrame))
                return i;
        }
        return InsertTrackRaw(Timeline.Tracks.Count, ClipType.Audio);
    }

    private int InsertTrackRaw(int at, ClipType type)
    {
        var index = PartitionedInsertionIndex(at, type);
        Timeline.Tracks.Insert(index, new Track { Type = type });
        return index;
    }

    /// <summary>Seconds → frames using AwayFromZero, minimum 1 frame.</summary>
    public static int SecondsToFrames(double seconds, int fps)
        => Math.Max(1, (int)Math.Round(Math.Max(0, seconds) * Math.Max(1, fps), MidpointRounding.AwayFromZero));
}
