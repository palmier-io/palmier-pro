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
