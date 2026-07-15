using CommunityToolkit.Mvvm.ComponentModel;
using PalmierPro.Core;
using PalmierPro.Core.Json;
using PalmierPro.Core.Models;
using PalmierPro.Core.Timeline;
using PalmierPro.Services.Engine;
using PalmierPro.Services.Project;

namespace PalmierPro.App.ViewModels.Editor;

/// Timeline editing core (M3, Stage C) — ports the mutation surface of
/// `Editor/ViewModel/EditorViewModel+*.swift` (ClipMutations, Ripple, Tracks, Timelines,
/// Selection, Linking) against a live `ProjectDocument`. Deliberately WinUI-free so
/// `PalmierPro.App.Tests` can drive it under plain `dotnet test`; the rest of the file split
/// mirrors the Mac extension split, one partial-class file per area.
///
/// Reference-type note: Swift's `Timeline`/`Track`/`Clip` are `Equatable` value-type structs, so
/// `EditorViewModel`'s `timeline` computed property does real copy-on-write and every undo swap
/// captures an independent snapshot just by assigning to a `let`. This port's `Timeline`/`Track`/
/// `Clip` are reference types (Track.Clips is a live `List&lt;Clip&gt;`, matching how
/// `ProjectDocument`/`TimelineSnapshotBuilder` already treat them) — which is what lets most
/// mutations below index straight into `Timeline.Tracks[i].Clips[j]` instead of Swift's
/// find-mutate-writeback dance, but it also means an undo/redo snapshot MUST be an explicit deep
/// clone (`TimelineSnapshot.Clone()`) and "did anything change" MUST be an explicit structural
/// comparison (`TimelineSnapshot.ValueEquals()`) rather than reference equality. See
/// `PalmierPro.Core.Timeline.TimelineSnapshot`.
///
/// Not ported (out of scope for this stage — see AGENTS.md plan's Phase-1 exclusions and the M5/
/// Stage D milestones): Multicam guard rails (`multicamMoveViolation`/`multicamManualRippleViolation`/
/// `multicamAtomicityViolation` and friends) — Multicam editing is a named Phase-2 feature and no
/// `MulticamEngine` exists on Windows yet, so `clip.MulticamGroupId` is always null in practice.
/// Inspector-level continuous property edits (`applyClipProperty`/`commitClipProperty`/text-style
/// helpers/keyframe stamping) — that's M5. Per-timeline `TimelineViewState` (zoom/scroll) stash —
/// no zoom/scroll UI exists yet; timeline-switch only clamps the playhead into the new timeline's
/// bounds. AI-assisted ripple-insert (`rippleInsertClips(specs:)`) and ghost-preview planning
/// (`planRippleInsertPreview`) — UI-drag/agent concerns, not core mutations.
public sealed partial class TimelineEditorViewModel : ObservableObject
{
    public ProjectDocument Document { get; }

    /// Null until Stage D wires a real engine; every call site below is a no-op-safe
    /// null-conditional call, matching the Mac's `videoEngine: VideoEngine?` being nil until
    /// `EditorWindowController` wires it up.
    public IVideoEngine? Engine { get; }

    /// Per-clip snapshot at drag start, keyed by clip id so multiple clips can be edited in
    /// tandem (`applyClipSpeed`/`commitClipSpeed`).
    private readonly Dictionary<string, Clip> _dragBefore = [];

    /// Whole-timeline snapshot at drag start, for mutations whose per-clip undos can't compose
    /// cleanly (`commitClipSpeed`) and for reverting an in-flight drag on a timeline-tab switch.
    private Timeline? _preDragTimeline;

    public TimelineEditorViewModel(ProjectDocument document, IVideoEngine? engine = null)
    {
        Document = document;
        Engine = engine;

        var pf = Document.ProjectFile;
        if (pf.Timelines.Count == 0)
        {
            pf.Timelines.Add(new Timeline());
        }
        if (pf.ActiveTimelineId is not { } activeId || pf.Timelines.All(t => t.Id != activeId))
        {
            pf.ActiveTimelineId = pf.Timelines[0].Id;
        }
        pf.OpenTimelineIds ??= [];
        if (!pf.OpenTimelineIds.Contains(pf.ActiveTimelineId))
        {
            pf.OpenTimelineIds.Add(pf.ActiveTimelineId);
        }
    }

    // MARK: - Persisted state (proxies onto Document.ProjectFile — no separate copy to keep in
    // sync, unlike the Mac's parallel `timelines`/`activeTimelineId` published properties)

    public List<Timeline> Timelines => Document.ProjectFile.Timelines;

    public string ActiveTimelineId
    {
        get => Document.ProjectFile.ActiveTimelineId!;
        private set
        {
            if (Document.ProjectFile.ActiveTimelineId == value)
            {
                return;
            }
            Document.ProjectFile.ActiveTimelineId = value;
            OnPropertyChanged();
        }
    }

    public List<string> OpenTimelineIds => Document.ProjectFile.OpenTimelineIds!;

    /// Active-timeline proxy; assignment routes by id and activates so undo lands on its
    /// timeline. Mirrors `EditorViewModel.timeline`'s get/set (Swift's `_modify` in-place-mutation
    /// accessor has no C# equivalent, but is also unneeded here — see the reference-type note on
    /// this class's doc comment).
    public Timeline Timeline
    {
        get => Timelines.FirstOrDefault(t => t.Id == ActiveTimelineId) ?? Timelines[0];
        set
        {
            var idx = Timelines.FindIndex(t => t.Id == value.Id);
            if (idx >= 0)
            {
                Timelines[idx] = value;
            }
            else
            {
                idx = Timelines.FindIndex(t => t.Id == ActiveTimelineId);
                if (idx < 0)
                {
                    idx = 0;
                }
                var oldId = Timelines[idx].Id;
                Timelines[idx] = value;
                for (var i = 0; i < OpenTimelineIds.Count; i++)
                {
                    if (OpenTimelineIds[i] == oldId)
                    {
                        OpenTimelineIds[i] = value.Id;
                    }
                }
            }
            ActiveTimelineId = value.Id;
            if (!OpenTimelineIds.Contains(value.Id))
            {
                OpenTimelineIds.Add(value.Id);
            }
        }
    }

    /// Replaces the active timeline's contents with an independent clone of `snapshot`, without
    /// disturbing any other timeline. The undo-swap equivalent of Swift's `vm.timeline = undoState`
    /// (which the reference-type note above explains can't just be a bare `Timeline` setter here).
    private void ReplaceActiveTimeline(Timeline snapshot)
    {
        var clone = snapshot.Clone();
        var idx = Timelines.FindIndex(t => t.Id == ActiveTimelineId);
        if (idx < 0)
        {
            idx = Timelines.FindIndex(t => t.Id == clone.Id);
        }
        if (idx < 0)
        {
            Timelines.Add(clone);
        }
        else
        {
            var oldId = Timelines[idx].Id;
            Timelines[idx] = clone;
            for (var i = 0; i < OpenTimelineIds.Count; i++)
            {
                if (OpenTimelineIds[i] == oldId)
                {
                    OpenTimelineIds[i] = clone.Id;
                }
            }
        }
        ActiveTimelineId = clone.Id;
        if (!OpenTimelineIds.Contains(clone.Id))
        {
            OpenTimelineIds.Add(clone.Id);
        }
    }

    // MARK: - Playhead (frame position only — no playback model until Stage D/E4.5)

    [ObservableProperty]
    public partial int CurrentFrame { get; set; }

    public void SeekToFrame(int frame) => CurrentFrame = Math.Clamp(frame, 0, Math.Max(0, Timeline.TotalFrames));

    // MARK: - Selection

    private HashSet<string> _selectedClipIds = [];

    public HashSet<string> SelectedClipIds
    {
        get => _selectedClipIds;
        set => SetProperty(ref _selectedClipIds, value);
    }

    private GapSelection? _selectedGap;

    public GapSelection? SelectedGap
    {
        get => _selectedGap;
        set => SetProperty(ref _selectedGap, value);
    }

    // MARK: - Engine notification seam

    /// Mirrors `EditorViewModel.notifyTimelineChanged`/`notifyTimelineChangedDebounced`'s
    /// rebuild-vs-refresh split (`Preview/VideoEngine.swift`'s `rebuild()` vs `refreshVisuals()`).
    /// Structural edits fire `StructuralChangeRequested`; Stage D wires it to
    /// `IVideoEngine.UpdateTimelineAsync` (after building a fresh snapshot) the same way it wires
    /// `RefreshVisualsRequested` to a param-only `IVideoEngine.RefreshParams` call. Kept as plain
    /// events (not a hard `IVideoEngine` dependency) so this class stays engine-agnostic and
    /// testable without a snapshot-build pipeline.
    public event EventHandler? StructuralChangeRequested;

    public event EventHandler? RefreshVisualsRequested;

    /// Non-fatal ripple/edit refusal (blocked sync-locked shift, "can't delete every timeline",
    /// etc.) — the seam for a future toast/beep service. Mirrors the Mac's `mediaPanelToast` +
    /// `NSSound.beep()` side effects, minus the AppKit beep (no Windows equivalent at this layer).
    public event EventHandler<string>? EditRefused;

    private CancellationTokenSource? _pendingRebuildCts;

    public void NotifyTimelineChanged(bool refreshVisuals = true)
    {
        if (!Document.UndoService.IsRegistrationEnabled)
        {
            return;
        }
        _pendingRebuildCts?.Cancel();
        _pendingRebuildCts = null;
        if (refreshVisuals)
        {
            RefreshVisualsRequested?.Invoke(this, EventArgs.Empty);
        }
        StructuralChangeRequested?.Invoke(this, EventArgs.Empty);
    }

    /// Coalesces rapid rebuilds (~120ms, matching the Mac's default). An immediate
    /// `NotifyTimelineChanged` cancels any pending debounced one.
    public void NotifyTimelineChangedDebounced(TimeSpan? debounce = null)
    {
        _pendingRebuildCts?.Cancel();
        var cts = new CancellationTokenSource();
        _pendingRebuildCts = cts;
        _ = DebounceStructuralChangeAsync(debounce ?? TimeSpan.FromMilliseconds(120), cts);
    }

    private async Task DebounceStructuralChangeAsync(TimeSpan delay, CancellationTokenSource cts)
    {
        try
        {
            // No ConfigureAwait(false): resuming on the captured context matches the immediate
            // path (which fires synchronously on the caller's thread) and the Mac's @MainActor
            // Task. A WinUI window installs a DispatcherQueueSynchronizationContext on its UI
            // thread, so a Stage D handler that calls this from the UI thread gets its
            // StructuralChangeRequested continuation back on that same thread automatically; under
            // `dotnet test` there is no captured context, so it just resumes on the thread pool.
            await Task.Delay(delay, cts.Token);
        }
        catch (TaskCanceledException)
        {
            return;
        }
        if (cts.IsCancellationRequested)
        {
            return;
        }
        _pendingRebuildCts = null;
        StructuralChangeRequested?.Invoke(this, EventArgs.Empty);
    }

    private void RaiseEditRefused(string reason) => EditRefused?.Invoke(this, reason);

    // MARK: - Undo swap pattern (ports `registerTimelineSwap`/`withTimelineSwap`)

    /// Registers an undo that swaps the active timeline to `undoState`, then re-registers the
    /// inverse swap so redo reapplies `redoState` — the pattern every structural mutation below
    /// uses. Both arguments are cloned internally, so callers may pass live (still-mutable)
    /// `Timeline` references safely.
    public void RegisterTimelineSwap(Timeline undoState, Timeline redoState, string actionName)
    {
        var undoSnapshot = undoState.Clone();
        var redoSnapshot = redoState.Clone();
        RegisterTimelineUndo(actionName, () =>
        {
            ReplaceActiveTimeline(undoSnapshot);
            NotifyTimelineChanged();
            RegisterTimelineSwap(redoSnapshot, undoSnapshot, actionName);
        });
        Document.UndoService.SetActionName(actionName);
    }

    /// Runs `work` as a single atomic mutation, registering one timeline-swap undo.
    public void WithTimelineSwap(string actionName, bool refreshVisuals, Action work)
    {
        var before = Timeline.Clone();
        Document.UndoService.DisableRegistration();
        work();
        Document.UndoService.EnableRegistration();
        if (before.ValueEquals(Timeline))
        {
            return;
        }
        // Skip when nested: an outer WithTimelineSwap is still suppressing registrations and will
        // capture our diff in its own swap.
        if (!Document.UndoService.IsRegistrationEnabled)
        {
            return;
        }
        RegisterTimelineSwap(before, Timeline, actionName);
        NotifyTimelineChanged(refreshVisuals);
    }

    public void WithTimelineSwap(string actionName, Action work) => WithTimelineSwap(actionName, true, work);

    // MARK: - Clip lookup / bookkeeping shared across every mutation partial

    public ClipLocation? FindClip(string id)
    {
        for (var ti = 0; ti < Timeline.Tracks.Count; ti++)
        {
            var ci = Timeline.Tracks[ti].Clips.FindIndex(c => c.Id == id);
            if (ci >= 0)
            {
                return new ClipLocation(ti, ci);
            }
        }
        return null;
    }

    public Clip? ClipFor(string id) => FindClip(id) is { } loc ? Timeline.Tracks[loc.TrackIndex].Clips[loc.ClipIndex] : null;

    /// Stable sort (LINQ `OrderBy`, not `List.Sort`) — mirrors Swift's guaranteed-stable
    /// `sort(by:)` so clips sharing a `startFrame` keep their relative order.
    public void SortClips(int trackIndex) =>
        Timeline.Tracks[trackIndex].Clips = [.. Timeline.Tracks[trackIndex].Clips.OrderBy(c => c.StartFrame)];

    public void RemoveClipInternal(string id)
    {
        foreach (var track in Timeline.Tracks)
        {
            track.Clips.RemoveAll(c => c.Id == id);
        }
    }

    // MARK: - Placement (ports `placeClip`/`createClips`/`clipDurationFrames`/`fitTransform`)

    public int ClipDurationFrames(MediaAsset asset, (double Lower, double Upper)? segment)
    {
        var seconds = segment is { } s ? s.Upper - s.Lower : asset.Duration;
        return Math.Max(1, SwiftMath.SecondsToFrame(seconds, Timeline.Fps));
    }

    public Transform FitTransform(MediaAsset asset) =>
        FitTransform(asset.SourceWidth, asset.SourceHeight, Timeline.Width, Timeline.Height);

    public static Transform FitTransform(int? sourceWidth, int? sourceHeight, int canvasWidth, int canvasHeight)
    {
        if (sourceWidth is not { } sw || sourceHeight is not { } sh)
        {
            return new Transform();
        }
        if (sw <= 0 || sh <= 0 || canvasWidth <= 0 || canvasHeight <= 0)
        {
            return new Transform();
        }
        var canvasAspect = (double)canvasWidth / canvasHeight;
        var relativeAspect = ((double)sw / sh) / canvasAspect;
        var sourceAspect = relativeAspect * canvasAspect;
        if (Math.Abs(canvasAspect - sourceAspect) < Defaults.AspectTolerance)
        {
            return new Transform();
        }
        return relativeAspect > 1
            ? new Transform { Width = 1.0, Height = 1.0 / relativeAspect }
            : new Transform { Width = relativeAspect, Height = 1.0 };
    }

    /// Places one clip, optionally with linked audio.
    public List<string> PlaceClip(
        MediaAsset asset,
        int trackIndex,
        int startFrame,
        int durationFrames,
        bool addLinkedAudio = true,
        int? linkedAudioTrackIndex = null,
        (double Lower, double Upper)? sourceSegment = null,
        int? trimStartFrame = null,
        int? trimEndFrame = null)
    {
        if (trackIndex < 0 || trackIndex >= Timeline.Tracks.Count)
        {
            return [];
        }
        var targetIsVideo = Timeline.Tracks[trackIndex].Type == ClipType.Video;
        var shouldLink = addLinkedAudio && targetIsVideo && asset.HasAudio
            && (asset.Type == ClipType.Video || asset.Type == ClipType.Sequence);
        var linkGroupId = shouldLink ? SwiftId.New() : null;
        var trimStart = sourceSegment is { } seg ? SwiftMath.SecondsToFrame(seg.Lower, Timeline.Fps) : 0;
        var totalSourceFrames = SwiftMath.SecondsToFrame(asset.Duration, Timeline.Fps);

        // sourceSegment (source seconds) and explicit trim frames are mutually exclusive; callers
        // pass one.
        void ApplyTrim(Clip clip)
        {
            if (sourceSegment is not null)
            {
                // Tail trim is what's left after head trim and visible span.
                var consumed = SwiftMath.RoundToInt(durationFrames * clip.Speed);
                clip.TrimStartFrame = trimStart;
                clip.TrimEndFrame = Math.Max(0, totalSourceFrames - trimStart - consumed);
            }
            else
            {
                var start = Math.Max(0, trimStartFrame ?? 0);
                clip.TrimStartFrame = start;
                if (totalSourceFrames > 0)
                {
                    // Use actual remaining source for tail trim if not set; clamp to available.
                    var consumed = SwiftMath.RoundToInt(durationFrames * clip.Speed);
                    var remainingTail = Math.Max(0, totalSourceFrames - start - consumed);
                    clip.TrimEndFrame = Math.Min(trimEndFrame ?? remainingTail, remainingTail);
                }
                else if (trimEndFrame is { } t)
                {
                    clip.TrimEndFrame = t;
                }
            }
        }

        var clip = new Clip(asset.Id, startFrame, durationFrames)
        {
            MediaType = asset.Type,
            SourceClipType = asset.Type,
            Transform = FitTransform(asset),
            LinkGroupId = linkGroupId,
        };
        ApplyTrim(clip);
        Timeline.Tracks[trackIndex].Clips.Add(clip);
        SortClips(trackIndex);
        var ids = new List<string> { clip.Id };

        if (linkGroupId is not null)
        {
            var audioTrackIdx = linkedAudioTrackIndex is { } idx && idx >= 0 && idx < Timeline.Tracks.Count
                ? idx
                : ResolveOrCreateAudioTrack(startFrame, durationFrames);
            if (audioTrackIdx < 0 || audioTrackIdx >= Timeline.Tracks.Count)
            {
                return ids;
            }
            var audioClip = new Clip(asset.Id, startFrame, durationFrames)
            {
                MediaType = ClipType.Audio,
                SourceClipType = asset.Type,
                LinkGroupId = linkGroupId,
            };
            ApplyTrim(audioClip);
            Timeline.Tracks[audioTrackIdx].Clips.Add(audioClip);
            SortClips(audioTrackIdx);
            ids.Add(audioClip.Id);
        }
        return ids;
    }

    /// Creates clips sequentially; callers clear the target range first.
    public List<string> CreateClips(
        IReadOnlyList<MediaAsset> assets,
        int trackIndex,
        int startFrame,
        bool addLinkedAudio = true,
        int? linkedAudioTrackIndex = null,
        IReadOnlyDictionary<string, (double Lower, double Upper)>? segments = null)
    {
        segments ??= new Dictionary<string, (double, double)>();
        var cursor = startFrame;
        var clipIds = new List<string>();
        foreach (var asset in assets)
        {
            var segment = segments.TryGetValue(asset.Id, out var s) ? s : ((double, double)?)null;
            var durationFrames = ClipDurationFrames(asset, segment);
            clipIds.AddRange(PlaceClip(
                asset, trackIndex, cursor, durationFrames,
                addLinkedAudio: addLinkedAudio, linkedAudioTrackIndex: linkedAudioTrackIndex, sourceSegment: segment));
            cursor += durationFrames;
        }
        return clipIds;
    }
}
