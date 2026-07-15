using PalmierPro.Core;
using PalmierPro.Core.Json;
using PalmierPro.Core.Models;
using PalmierPro.Core.Timeline;

namespace PalmierPro.App.ViewModels.Editor;

/// Clip-level mutations: add/move, split, remove, speed, and overwrite-style region clearing.
/// Ports `EditorViewModel+ClipMutations.swift`. Playhead-relative shortcuts (split/trim/delete)
/// live here too, matching the Mac file's own "Playhead-relative operations" section.
public sealed partial class TimelineEditorViewModel
{
    // MARK: - Add / move

    public void AddClips(
        IReadOnlyList<MediaAsset> assets,
        int trackIndex,
        int startFrame,
        int? linkedAudioTrackIndex = null,
        IReadOnlyDictionary<string, (double Lower, double Upper)>? segments = null)
    {
        if (trackIndex < 0 || trackIndex >= Timeline.Tracks.Count)
        {
            return;
        }
        segments ??= new Dictionary<string, (double, double)>();
        // Pin by id: ClearRegion's PruneEmptyTracks can shift indices.
        var visualTrackId = Timeline.Tracks[trackIndex].Id;
        var audioTrackId = linkedAudioTrackIndex is { } idx && idx >= 0 && idx < Timeline.Tracks.Count
            ? Timeline.Tracks[idx].Id
            : null;

        WithTimelineSwap("Add Clips", true, () =>
        {
            var totalDur = assets.Sum(a => ClipDurationFrames(a, segments.TryGetValue(a.Id, out var s) ? s : null));
            ClearRegion(trackIndex, startFrame, startFrame + totalDur, prune: false);
            if (audioTrackId is not null)
            {
                var audioIdx = Timeline.Tracks.FindIndex(t => t.Id == audioTrackId);
                if (audioIdx >= 0)
                {
                    ClearRegion(audioIdx, startFrame, startFrame + totalDur, prune: false);
                }
            }

            var resolvedTrackIndex = Timeline.Tracks.FindIndex(t => t.Id == visualTrackId);
            if (resolvedTrackIndex < 0)
            {
                PruneEmptyTracks();
                return;
            }
            var resolvedAudioIndex = audioTrackId is not null ? Timeline.Tracks.FindIndex(t => t.Id == audioTrackId) : -1;

            CreateClips(
                assets, resolvedTrackIndex, startFrame,
                linkedAudioTrackIndex: resolvedAudioIndex >= 0 ? resolvedAudioIndex : null, segments: segments);
            SortClips(resolvedTrackIndex);
            PruneEmptyTracks();
        });
    }

    /// Moved clips share a single delta from the drag, so they don't collide with each other.
    public void MoveClips(IReadOnlyList<(string ClipId, int ToTrack, int ToFrame)> moves)
    {
        if (moves.Count == 0)
        {
            return;
        }

        // Collect current state + validate track-type compatibility.
        var clipInfos = new List<(Clip Clip, int FromTrack, int ToTrack, int ToFrame)>();
        foreach (var m in moves)
        {
            if (FindClip(m.ClipId) is not { } loc || m.ToTrack < 0 || m.ToTrack >= Timeline.Tracks.Count)
            {
                continue;
            }
            var clip = Timeline.Tracks[loc.TrackIndex].Clips[loc.ClipIndex];
            var destType = Timeline.Tracks[m.ToTrack].Type;
            var srcType = Timeline.Tracks[loc.TrackIndex].Type;
            if (!destType.IsCompatible(srcType))
            {
                continue;
            }
            clipInfos.Add((clip, loc.TrackIndex, m.ToTrack, Math.Max(0, m.ToFrame)));
        }
        if (clipInfos.Count == 0)
        {
            return;
        }

        var actionName = moves.Count == 1 ? "Move Clip" : "Move Clips";
        WithTimelineSwap(actionName, true, () =>
        {
            // Pull moved clips off their source tracks first, so ClearRegion on the destinations
            // never touches them.
            foreach (var info in clipInfos)
            {
                if (FindClip(info.Clip.Id) is { } loc)
                {
                    Timeline.Tracks[loc.TrackIndex].Clips.RemoveAt(loc.ClipIndex);
                }
            }

            // Trim / remove any non-moved clips blocking each destination range.
            // Pin by id: ClearRegion's PruneEmptyTracks can shift indices.
            var toTrackIds = clipInfos.Select(i => Timeline.Tracks[i.ToTrack].Id).ToList();
            for (var i = 0; i < clipInfos.Count; i++)
            {
                var idx = Timeline.Tracks.FindIndex(t => t.Id == toTrackIds[i]);
                if (idx < 0)
                {
                    continue;
                }
                ClearRegion(idx, clipInfos[i].ToFrame, clipInfos[i].ToFrame + clipInfos[i].Clip.DurationFrames, prune: false);
            }

            // Drop each clip at its exact target frame. Each clip was already removed from its
            // source track above, so re-adding the same (now orphaned) reference is safe.
            for (var i = 0; i < clipInfos.Count; i++)
            {
                var idx = Timeline.Tracks.FindIndex(t => t.Id == toTrackIds[i]);
                if (idx < 0)
                {
                    continue;
                }
                var clip = clipInfos[i].Clip;
                clip.StartFrame = clipInfos[i].ToFrame;
                Timeline.Tracks[idx].Clips.Add(clip);
            }
            for (var i = 0; i < Timeline.Tracks.Count; i++)
            {
                SortClips(i);
            }
            PruneEmptyTracks();
        });
    }

    // MARK: - Split / remove

    /// Split `clipId` at `atFrame`. Also splits linked partners. Returns the IDs of the
    /// right-half clips created by the split.
    public List<string> SplitClip(string clipId, int atFrame)
    {
        if (FindClip(clipId) is not { } loc)
        {
            return [];
        }
        var clip = Timeline.Tracks[loc.TrackIndex].Clips[loc.ClipIndex];
        if (!(atFrame > clip.StartFrame && atFrame < clip.EndFrame))
        {
            return [];
        }
        return SplitClips([(loc.TrackIndex, atFrame)]);
    }

    /// Splits at one or more project frames in a single undoable action. STAGE C HANDOFF: each
    /// point can register multiple separate top-level undos (`SplitSingleClip` per group member,
    /// plus a regroup `MutateClips` call) — wrapped in one explicit `BeginGrouping`/`EndGrouping`
    /// pair so they all collapse into a single Undo, per `UndoService`'s handoff doc comment.
    public List<string> SplitClips(IReadOnlyList<(int TrackIndex, int AtFrame)> points)
    {
        Document.UndoService.BeginGrouping();
        var rightIds = new List<string>();
        try
        {
            foreach (var p in points)
            {
                if (p.TrackIndex < 0 || p.TrackIndex >= Timeline.Tracks.Count)
                {
                    continue;
                }
                var clip = Timeline.Tracks[p.TrackIndex].Clips.FirstOrDefault(c => p.AtFrame > c.StartFrame && p.AtFrame < c.EndFrame);
                if (clip is null)
                {
                    continue;
                }
                var groupIds = clip.LinkGroupId is not null
                    ? new HashSet<string>([clip.Id, .. LinkedPartnerIds(clip.Id)])
                    : new HashSet<string> { clip.Id };
                var rights = groupIds.Select(id => SplitSingleClip(id, p.AtFrame)).Where(r => r is not null).Select(r => r!).ToList();
                // Regroup the right halves so each side is its own linked pair.
                if (groupIds.Count > 1 && rights.Count > 0)
                {
                    var newGroup = SwiftId.New();
                    MutateClips(new HashSet<string>(rights), "Split Clip", c => c.LinkGroupId = newGroup);
                }
                rightIds.AddRange(rights);
            }
        }
        finally
        {
            Document.UndoService.EndGrouping();
            Document.UndoService.SetActionName(points.Count > 1 ? "Split Clips" : "Split Clip");
        }
        return rightIds;
    }

    private string? SplitSingleClip(string clipId, int atFrame)
    {
        if (FindClip(clipId) is not { } loc)
        {
            return null;
        }
        var clip = Timeline.Tracks[loc.TrackIndex].Clips[loc.ClipIndex];
        if (SplitValues(clip, atFrame) is not { } values)
        {
            return null;
        }
        var (left, right) = values;
        var before = clip.Clone();

        Timeline.Tracks[loc.TrackIndex].Clips[loc.ClipIndex] = left;
        Timeline.Tracks[loc.TrackIndex].Clips.Add(right);
        SortClips(loc.TrackIndex);

        // Self-recursive swap (like TrimClipInternal/RegisterTimelineSwap): the undo handler
        // re-registers by calling back into SplitSingleClip, so redo re-splits instead of
        // dead-ending after one undo.
        RegisterTimelineUndo("Split Clip", () =>
        {
            RemoveClipInternal(right.Id);
            if (FindClip(left.Id) is { } newLoc)
            {
                Timeline.Tracks[newLoc.TrackIndex].Clips[newLoc.ClipIndex] = before.Clone();
            }
            NotifyTimelineChanged();
            RegisterTimelineUndo("Split Clip", () => SplitSingleClip(clipId, atFrame));
        });
        NotifyTimelineChanged();
        return right.Id;
    }

    /// Pure split math — the keyframe/word-timing redistribution deliverable. Static and public so
    /// tests can exercise it directly, mirroring the Swift `nonisolated static` original.
    public static (Clip Left, Clip Right)? SplitValues(Clip clip, int atFrame)
    {
        if (!(atFrame > clip.StartFrame && atFrame < clip.EndFrame))
        {
            return null;
        }
        var splitOffset = atFrame - clip.StartFrame;
        var leftSource = SwiftMath.RoundToInt(splitOffset * clip.Speed);
        var rightSource = SwiftMath.RoundToInt((clip.DurationFrames - splitOffset) * clip.Speed);

        var left = clip.Clone();
        left.DurationFrames = splitOffset;
        left.TrimEndFrame = clip.TrimEndFrame + rightSource;
        left.FadeOutFrames = 0;

        var right = clip.Clone();
        right.Id = SwiftId.New();
        right.StartFrame = atFrame;
        right.DurationFrames = clip.DurationFrames - splitOffset;
        right.TrimStartFrame = clip.TrimStartFrame + leftSource;
        right.FadeInFrames = 0;

        (left.OpacityTrack, right.OpacityTrack) = SplitKeyframeTrack(clip.OpacityTrack, splitOffset, clip.Opacity, KeyframeInterpolation.Double);
        (left.VolumeTrack, right.VolumeTrack) = SplitKeyframeTrack(clip.VolumeTrack, splitOffset, clip.Volume, KeyframeInterpolation.Double);
        (left.PositionTrack, right.PositionTrack) = SplitKeyframeTrack(clip.PositionTrack, splitOffset, new AnimPair(0, 0), KeyframeInterpolation.AnimPair);
        (left.ScaleTrack, right.ScaleTrack) = SplitKeyframeTrack(clip.ScaleTrack, splitOffset, new AnimPair(1, 1), KeyframeInterpolation.AnimPair);
        (left.RotationTrack, right.RotationTrack) = SplitKeyframeTrack(clip.RotationTrack, splitOffset, 0.0, KeyframeInterpolation.Double);
        (left.CropTrack, right.CropTrack) = SplitKeyframeTrack(clip.CropTrack, splitOffset, clip.Crop, KeyframeInterpolation.Crop);
        left.ClampFadesToDuration();
        right.ClampFadesToDuration();
        return (left, right);
    }

    /// Splits a keyframe track at `splitOffset`, keeping both sides continuous. Returns
    /// `(track, track)` if the source track is null or empty.
    public static (KeyframeTrack<T>? Left, KeyframeTrack<T>? Right) SplitKeyframeTrack<T>(
        KeyframeTrack<T>? track, int splitOffset, T fallback, Func<T, T, double, T> interpolate)
    {
        if (track is not { IsActive: true })
        {
            return (track, track);
        }
        var boundary = track.Sample(splitOffset, fallback, interpolate);

        var leftKfs = track.Keyframes.Where(k => k.Frame <= splitOffset).ToList();
        if (leftKfs.Count == 0 || leftKfs[^1].Frame != splitOffset)
        {
            leftKfs.Add(new Keyframe<T>(splitOffset, boundary));
        }
        var left = leftKfs.Count == 0 ? null : new KeyframeTrack<T>(leftKfs);
        var right = track.Rebased(splitOffset, fallback, interpolate);
        return (left, right);
    }

    public void RemoveClips(ISet<string> ids, bool prune = true)
    {
        var hasMatches = Timeline.Tracks.Any(t => t.Clips.Any(c => ids.Contains(c.Id)));
        if (!hasMatches)
        {
            return;
        }
        var count = Timeline.Tracks.Sum(t => t.Clips.Count(c => ids.Contains(c.Id)));
        SelectedClipIds = new HashSet<string>(SelectedClipIds.Where(id => !ids.Contains(id)));
        WithTimelineSwap($"Remove Clip{(count == 1 ? "" : "s")}", true, () =>
        {
            foreach (var track in Timeline.Tracks)
            {
                track.Clips.RemoveAll(c => ids.Contains(c.Id));
            }
            if (prune)
            {
                PruneEmptyTracks();
            }
        });
    }

    // MARK: - Speed

    public void ApplyClipSpeed(string clipId, double newSpeed)
    {
        if (FindClip(clipId) is not { } loc || !Timeline.Tracks[loc.TrackIndex].Clips[loc.ClipIndex].SupportsRetiming)
        {
            return;
        }
        _preDragTimeline ??= Timeline.Clone();
        if (!_dragBefore.ContainsKey(clipId))
        {
            _dragBefore[clipId] = Timeline.Tracks[loc.TrackIndex].Clips[loc.ClipIndex].Clone();
        }
        SetClipSpeed(loc, newSpeed);
    }

    public void CommitClipSpeed(IReadOnlyList<string> ids, double newSpeed)
    {
        var before = _preDragTimeline ?? Timeline.Clone();
        foreach (var id in ids)
        {
            if (FindClip(id) is not { } loc || !Timeline.Tracks[loc.TrackIndex].Clips[loc.ClipIndex].SupportsRetiming)
            {
                continue;
            }
            if (Timeline.Tracks[loc.TrackIndex].Clips[loc.ClipIndex].Speed != newSpeed)
            {
                SetClipSpeed(loc, newSpeed);
            }
        }
        _preDragTimeline = null;
        foreach (var id in ids)
        {
            _dragBefore.Remove(id);
        }
        if (before.ValueEquals(Timeline))
        {
            return;
        }
        RegisterTimelineSwap(before, Timeline, "Change Speed");
    }

    private void SetClipSpeed(ClipLocation loc, double newSpeed)
    {
        var ti = loc.TrackIndex;
        var clip = Timeline.Tracks[ti].Clips[loc.ClipIndex];
        var basis = _dragBefore.TryGetValue(clip.Id, out var b) ? b : clip;
        var sourceFrames = basis.DurationFrames * basis.Speed;
        var newDuration = Math.Max(1, SwiftMath.RoundToInt(sourceFrames / newSpeed));
        var oldDuration = clip.DurationFrames;
        var oldEnd = clip.EndFrame;

        clip.Speed = newSpeed;
        clip.DurationFrames = newDuration;
        // Keyframe offsets are clip-relative, so retime them before the clamp drops them.
        clip.RescaleWordTimings(oldDuration);
        clip.RescaleKeyframes((double)newDuration / oldDuration);
        clip.ClampKeyframesToDuration();
        clip.ClampFadesToDuration();

        var rippleDelta = clip.StartFrame + newDuration - oldEnd;
        if (rippleDelta != 0)
        {
            var chainIds = Timeline.Tracks[ti].ContiguousClipIds(oldEnd, clip.Id);
            foreach (var c in Timeline.Tracks[ti].Clips)
            {
                if (chainIds.Contains(c.Id))
                {
                    c.StartFrame += rippleDelta;
                }
            }
        }
        SortClips(ti);
        NotifyTimelineChanged();
    }

    // MARK: - Multi-clip atomic mutation

    /// Applies `modify` to every clip whose id is in `ids`. Captures a full-clip before snapshot
    /// for each and registers a bidirectional undo/redo swap.
    public void MutateClips(ISet<string> ids, string actionName, Action<Clip> modify)
    {
        var before = new List<(string Id, Clip Clip)>();
        foreach (var track in Timeline.Tracks)
        {
            foreach (var clip in track.Clips)
            {
                if (!ids.Contains(clip.Id))
                {
                    continue;
                }
                before.Add((clip.Id, clip.Clone()));
                modify(clip);
            }
        }
        if (before.Count == 0)
        {
            return;
        }
        var after = new List<(string Id, Clip Clip)>();
        foreach (var entry in before)
        {
            if (FindClip(entry.Id) is { } loc)
            {
                after.Add((entry.Id, Timeline.Tracks[loc.TrackIndex].Clips[loc.ClipIndex].Clone()));
            }
        }
        RegisterClipStateSwap(before, after, actionName);
        NotifyTimelineChanged();
    }

    /// Registers an undo that rewrites the clips to `undoTarget`, then re-registers the inverse
    /// swap so redo reapplies `redoTarget`.
    private void RegisterClipStateSwap(List<(string Id, Clip Clip)> undoTarget, List<(string Id, Clip Clip)> redoTarget, string actionName)
    {
        RegisterTimelineUndo(actionName, () =>
        {
            foreach (var entry in undoTarget)
            {
                if (FindClip(entry.Id) is { } loc)
                {
                    Timeline.Tracks[loc.TrackIndex].Clips[loc.ClipIndex] = entry.Clip.Clone();
                }
            }
            RegisterClipStateSwap(redoTarget, undoTarget, actionName);
            NotifyTimelineChanged();
        });
        Document.UndoService.SetActionName(actionName);
    }

    // MARK: - Playhead-relative operations

    public void SplitAtPlayhead()
    {
        Document.UndoService.BeginGrouping();
        try
        {
            foreach (var id in SelectedClipIds)
            {
                SplitClip(id, CurrentFrame);
            }
        }
        finally
        {
            Document.UndoService.EndGrouping();
        }
    }

    public void TrimStartToPlayhead()
    {
        Document.UndoService.BeginGrouping();
        try
        {
            foreach (var id in SelectedClipIds)
            {
                if (FindClip(id) is not { } loc)
                {
                    continue;
                }
                var clip = Timeline.Tracks[loc.TrackIndex].Clips[loc.ClipIndex];
                if (!(CurrentFrame > clip.StartFrame && CurrentFrame < clip.EndFrame))
                {
                    continue;
                }
                var delta = CurrentFrame - clip.StartFrame;
                var sourceDelta = SwiftMath.RoundToInt(delta * clip.Speed);
                TrimClips([(id, clip.TrimStartFrame + sourceDelta, clip.TrimEndFrame)]);
            }
        }
        finally
        {
            Document.UndoService.EndGrouping();
        }
    }

    public void TrimEndToPlayhead()
    {
        Document.UndoService.BeginGrouping();
        try
        {
            foreach (var id in SelectedClipIds)
            {
                if (FindClip(id) is not { } loc)
                {
                    continue;
                }
                var clip = Timeline.Tracks[loc.TrackIndex].Clips[loc.ClipIndex];
                if (!(CurrentFrame > clip.StartFrame && CurrentFrame < clip.EndFrame))
                {
                    continue;
                }
                var delta = clip.EndFrame - CurrentFrame;
                var sourceDelta = SwiftMath.RoundToInt(delta * clip.Speed);
                TrimClips([(id, clip.TrimStartFrame, clip.TrimEndFrame + sourceDelta)]);
            }
        }
        finally
        {
            Document.UndoService.EndGrouping();
        }
    }

    public void DeleteSelectedClips() => RemoveClips(SelectedClipIds);

    // MARK: - Overwrite region

    /// Clears a region on a track by removing, trimming, or splitting the clips that overlap it.
    public void ClearRegion(int trackIndex, int start, int end, bool prune = true, ISet<string>? excluding = null)
    {
        if (trackIndex < 0 || trackIndex >= Timeline.Tracks.Count)
        {
            return;
        }
        excluding ??= new HashSet<string>();
        var actions = OverwriteEngine.ComputeOverwrite(
            [.. Timeline.Tracks[trackIndex].Clips.Where(c => !excluding.Contains(c.Id))], start, end);

        foreach (var action in actions)
        {
            switch (action)
            {
                case OverwriteAction.Remove remove:
                    RemoveClips(new HashSet<string> { remove.ClipId }, prune);
                    break;

                case OverwriteAction.TrimEnd trimEnd:
                    if (FindClip(trimEnd.ClipId) is { } teLoc)
                    {
                        var clip = Timeline.Tracks[teLoc.TrackIndex].Clips[teLoc.ClipIndex];
                        var sourceDelta = SwiftMath.RoundToInt((clip.DurationFrames - trimEnd.NewDuration) * clip.Speed);
                        var newTrimEnd = clip.TrimEndFrame + sourceDelta;
                        MutateClips(new HashSet<string> { trimEnd.ClipId }, "Trim Clip", c =>
                        {
                            c.TrimEndFrame = newTrimEnd;
                            c.SetDuration(trimEnd.NewDuration);
                        });
                    }
                    break;

                case OverwriteAction.TrimStart trimStart:
                    MutateClips(new HashSet<string> { trimStart.ClipId }, "Trim Clip", c =>
                    {
                        c.StartFrame = trimStart.NewStartFrame;
                        c.TrimStartFrame = trimStart.NewTrimStart;
                        c.SetDuration(trimStart.NewDuration);
                    });
                    break;

                case OverwriteAction.Split split:
                    if (FindClip(split.ClipId) is { } sLoc)
                    {
                        SplitClip(split.ClipId, start);
                        var rightClip = Timeline.Tracks[sLoc.TrackIndex].Clips
                            .FirstOrDefault(c => c.StartFrame == start && c.Id != split.ClipId);
                        if (rightClip is not null)
                        {
                            if (rightClip.EndFrame > end)
                            {
                                SplitClip(rightClip.Id, end);
                            }
                            RemoveClips(new HashSet<string> { rightClip.Id }, prune);
                        }
                    }
                    break;
            }
        }
    }
}
