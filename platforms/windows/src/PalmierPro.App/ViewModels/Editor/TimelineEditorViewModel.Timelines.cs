using PalmierPro.Core;
using PalmierPro.Core.Json;
using PalmierPro.Core.Models;
using PalmierPro.Core.Timeline;

namespace PalmierPro.App.ViewModels.Editor;

/// Multiple timelines per project: switching, tab management, and CRUD. Ports
/// `EditorViewModel+Timelines.swift`. Per-timeline `TimelineViewState` (zoom/scroll) stash is not
/// ported — no zoom/scroll UI state exists on this VM yet (Stage D); timeline switch only clamps
/// the playhead into the newly active timeline's bounds instead of restoring a stashed one.
public sealed partial class TimelineEditorViewModel
{
    public Timeline? TimelineFor(string id) => Timelines.FirstOrDefault(t => t.Id == id);

    public void ActivateTimeline(string id)
    {
        if (id == ActiveTimelineId || Timelines.All(t => t.Id != id))
        {
            return;
        }
        RevertInFlightDrag();
        ClearTimelineScopedState();
        ActiveTimelineId = id;
        if (!OpenTimelineIds.Contains(id))
        {
            OpenTimelineIds.Add(id);
        }
        CurrentFrame = Math.Clamp(CurrentFrame, 0, Math.Max(0, Timeline.TotalFrames));
        // RefreshVisuals would apply the new timeline to the old track mappings — rebuild alone
        // is correct.
        NotifyTimelineChanged(refreshVisuals: false);
    }

    /// A switch mid-gesture would orphan live mutations with no undo — put the clips back first.
    private void RevertInFlightDrag()
    {
        if (_preDragTimeline is { } preDrag)
        {
            Timeline = preDrag;
        }
        else
        {
            foreach (var (id, before) in _dragBefore)
            {
                if (FindClip(id) is { } loc)
                {
                    Timeline.Tracks[loc.TrackIndex].Clips[loc.ClipIndex] = before.Clone();
                }
            }
        }
    }

    private void ClearTimelineScopedState()
    {
        SelectedClipIds = [];
        SelectedGap = null;
        _dragBefore.Clear();
        _preDragTimeline = null;
    }

    /// Registers an undo that re-activates the owning timeline before applying — the mutation
    /// partials (`ClipMutations`/`Ripple`/`Tracks`) all route through this since they index into
    /// `Timeline` (the active-timeline proxy). CRUD in this file operates on `Timelines` directly
    /// by id and registers straight through `Document.UndoService.RegisterUndo`, matching which
    /// registration path the Mac source actually uses per call site.
    public void RegisterTimelineUndo(string actionName, Action handler)
    {
        var tid = ActiveTimelineId;
        Document.UndoService.RegisterUndo(actionName, () =>
        {
            if (ActiveTimelineId != tid && Timelines.Any(t => t.Id == tid))
            {
                ActivateTimeline(tid);
            }
            handler();
        });
    }

    // MARK: - Project settings (fps/resolution) — ports EditorViewModel+ProjectSettings.swift's
    // `applyTimelineSettings`. Only the mutation itself: the settings-mismatch dialog
    // (`checkProjectSettings`/`addClipsWithSettingsCheck`) that surfaces on importing a clip whose
    // fps/resolution differs from an already-configured timeline is not ported — nothing calls
    // this yet except the empty-inspector Resolution/Frame Rate/Aspect Ratio menus (InspectorView),
    // which always pass an explicit user pick, never an import-driven auto-detect.

    /// Changes the project's fps and/or the active timeline's canvas resolution. fps is
    /// project-wide (every timeline's frame-based values move to the new frame grid); width/height
    /// apply to the active timeline only, matching the Mac's per-`Timeline` width/height fields.
    public void ApplyTimelineSettings(int fps, int width, int height)
    {
        var prevFps = Timeline.Fps;
        var prevWidth = Timeline.Width;
        var prevHeight = Timeline.Height;

        // FPS is project-wide: rescale frame-based values in every timeline.
        if (fps != prevFps && prevFps > 0 && fps > 0)
        {
            var scale = (double)fps / prevFps;
            CurrentFrame = SwiftMath.RoundToInt(CurrentFrame * scale);
            foreach (var t in Timelines)
            {
                t.RescaleFrames(scale);
            }
        }

        // Keep visual scale proportional when the canvas aspect changes.
        if (width != prevWidth || height != prevHeight)
        {
            foreach (var track in Timeline.Tracks)
            {
                foreach (var clip in track.Clips)
                {
                    if (SourceDimensions(clip) is not { } dims || prevWidth <= 0 || prevHeight <= 0 || width <= 0 || height <= 0)
                    {
                        continue;
                    }
                    var sourceAspect = (double)dims.Width / dims.Height;
                    var oldAspect = sourceAspect / ((double)prevWidth / prevHeight);
                    var newAspect = sourceAspect / ((double)width / height);

                    var scaleAnimated = clip.ScaleTrack?.IsActive ?? false;
                    var oldFit = FitTransform(dims.Width, dims.Height, prevWidth, prevHeight);
                    if (!scaleAnimated && TransformScaleMatches(clip.Transform, oldFit))
                    {
                        var newFit = FitTransform(dims.Width, dims.Height, width, height);
                        clip.Transform.Width = newFit.Width;
                        clip.Transform.Height = newFit.Height;
                    }
                    else
                    {
                        var heightScale = oldAspect / newAspect;
                        clip.Transform.Height *= heightScale;
                        if (clip.ScaleTrack is { IsActive: true } scaleTrack)
                        {
                            foreach (var kf in scaleTrack.Keyframes)
                            {
                                kf.Value.B *= heightScale;
                            }
                        }
                    }
                }
            }
        }

        var prevConfiguredById = Timelines.Select(t => (t.Id, t.SettingsConfigured)).ToList();
        foreach (var t in Timelines)
        {
            t.Fps = fps;
            t.SettingsConfigured = true;
        }
        Timeline.Width = width;
        Timeline.Height = height;

        RegisterTimelineUndo("Change Project Settings", () =>
        {
            ApplyTimelineSettings(prevFps, prevWidth, prevHeight);
            foreach (var (id, configured) in prevConfiguredById)
            {
                if (TimelineFor(id) is { } t)
                {
                    t.SettingsConfigured = configured;
                }
            }
        });
        NotifyTimelineChanged();
    }

    private static bool TransformScaleMatches(Transform transform, Transform other) =>
        Math.Abs(transform.Width - other.Width) < 0.0001 && Math.Abs(transform.Height - other.Height) < 0.0001;

    /// Source pixel dimensions for a clip: media-manifest entry dims, or the child timeline's for
    /// nested-sequence carriers. Mirrors `EditorViewModel.sourceDimensions(for:)` — duplicated from
    /// TransformViewModel's private copy of the same helper (different class, no shared owner to
    /// hang it off yet).
    private (int Width, int Height)? SourceDimensions(Clip clip)
    {
        var entry = Document.Manifest.Entries.FirstOrDefault(e => e.Id == clip.MediaRef);
        if (entry is { SourceWidth: { } w, SourceHeight: { } h } && w > 0 && h > 0)
        {
            return (w, h);
        }
        if (clip.SourceClipType == ClipType.Sequence)
        {
            var child = Timelines.FirstOrDefault(t => t.Id == clip.MediaRef);
            if (child is { Width: > 0, Height: > 0 })
            {
                return (child.Width, child.Height);
            }
        }
        return null;
    }

    // MARK: - CRUD

    public string CreateTimeline(string? name = null, bool activate = true)
    {
        var active = Timeline;
        var t = new Timeline
        {
            Name = name ?? NextTimelineName(),
            Fps = active.Fps,
            Width = active.Width,
            Height = active.Height,
            SettingsConfigured = active.SettingsConfigured,
        };
        Timelines.Add(t);
        RegisterRemoveUndo(t.Id, "New Timeline");
        if (activate)
        {
            ActivateTimeline(t.Id);
        }
        return t.Id;
    }

    public string? DuplicateTimeline(string id, bool activate = true)
    {
        if (TimelineFor(id) is not { } original)
        {
            return null;
        }
        var copy = original.Clone();
        copy.Id = SwiftId.New();
        copy.Name = DuplicateName(copy.Name);
        RegenerateIds(copy);
        Timelines.Add(copy);
        RegisterRemoveUndo(copy.Id, "Duplicate Timeline");
        if (activate)
        {
            ActivateTimeline(copy.Id);
        }
        return copy.Id;
    }

    public void RenameTimeline(string id, string name)
    {
        var i = Timelines.FindIndex(t => t.Id == id);
        if (i < 0)
        {
            return;
        }
        var trimmed = name.Trim();
        if (trimmed.Length == 0 || Timelines[i].Name == trimmed)
        {
            return;
        }
        var previous = Timelines[i].Name;
        Timelines[i].Name = trimmed;
        Document.UndoService.RegisterUndo("Rename Timeline", () => RenameTimeline(id, previous));
        Document.UndoService.SetActionName("Rename Timeline");
    }

    public void DeleteTimeline(string id)
    {
        var index = Timelines.FindIndex(t => t.Id == id);
        if (index < 0)
        {
            return;
        }
        if (Timelines.Count <= 1)
        {
            RaiseEditRefused("Can't delete every timeline — the project needs at least one.");
            return;
        }
        var openIndex = OpenTimelineIds.IndexOf(id);
        var wasActive = ActiveTimelineId == id;
        if (wasActive)
        {
            var fallback = OpenTimelineIds.FirstOrDefault(t => t != id) ?? Timelines.First(t => t.Id != id).Id;
            ActivateTimeline(fallback);
        }
        var removed = Timelines[index].Clone();
        Timelines.RemoveAt(index);
        Engine?.EvictTimeline(id);
        if (openIndex >= 0)
        {
            OpenTimelineIds.RemoveAt(openIndex);
        }
        Document.UndoService.RegisterUndo("Delete Timeline", () =>
            ReinsertTimeline(removed, index, openIndex >= 0 ? openIndex : null, wasActive));
        Document.UndoService.SetActionName("Delete Timeline");
    }

    public void CloseTimelineTab(string id)
    {
        if (OpenTimelineIds.Count <= 1)
        {
            return;
        }
        var index = OpenTimelineIds.IndexOf(id);
        if (index < 0)
        {
            return;
        }
        if (ActiveTimelineId == id)
        {
            ActivateTimeline(OpenTimelineIds[index == 0 ? 1 : index - 1]);
        }
        OpenTimelineIds.RemoveAt(index);
        Engine?.EvictTimeline(id);
    }

    public void CloseOtherTimelineTabs(string keeping)
    {
        if (!OpenTimelineIds.Contains(keeping))
        {
            return;
        }
        ActivateTimeline(keeping);
        foreach (var closed in OpenTimelineIds.Where(t => t != keeping))
        {
            Engine?.EvictTimeline(closed);
        }
        OpenTimelineIds.Clear();
        OpenTimelineIds.Add(keeping);
    }

    private void ReinsertTimeline(Timeline t, int index, int? openIndex, bool reactivate)
    {
        var clone = t.Clone();
        Timelines.Insert(Math.Min(index, Timelines.Count), clone);
        if (openIndex is { } oi)
        {
            OpenTimelineIds.Insert(Math.Min(oi, OpenTimelineIds.Count), clone.Id);
        }
        if (reactivate)
        {
            ActivateTimeline(clone.Id);
        }
        Document.UndoService.RegisterUndo("Delete Timeline", () => DeleteTimeline(clone.Id));
    }

    private void RegisterRemoveUndo(string id, string actionName)
    {
        Document.UndoService.RegisterUndo(actionName, () => DeleteTimeline(id));
        Document.UndoService.SetActionName(actionName);
    }

    /// Fresh track/clip/group ids for a duplicated timeline so ids stay unique project-wide.
    private static void RegenerateIds(Timeline t)
    {
        var groups = new Dictionary<string, string>();
        foreach (var track in t.Tracks)
        {
            track.Id = SwiftId.New();
            foreach (var clip in track.Clips)
            {
                clip.FreshenIds(groups);
            }
        }
    }

    // MARK: - Naming

    public string NextTimelineName() => UniqueName(n => $"Timeline {n}", Timelines.Count + 1);

    private string DuplicateName(string name) => UniqueName(n => n == 1 ? $"{name} copy" : $"{name} copy {n}", 1);

    public string UniqueName(Func<int, string> candidate, int start)
    {
        var used = new HashSet<string>(Timelines.Select(t => t.Name));
        var n = start;
        while (used.Contains(candidate(n)))
        {
            n++;
        }
        return candidate(n);
    }
}
