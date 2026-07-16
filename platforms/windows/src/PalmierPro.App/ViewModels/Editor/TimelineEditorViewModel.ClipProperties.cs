using System.Text.Json;
using PalmierPro.Core.Models;
using PalmierPro.Core.Timeline;

namespace PalmierPro.App.ViewModels.Editor;

/// Continuous inspector-property edits (M5) — ports the apply/commit/revert trio from
/// `EditorViewModel+ClipMutations.swift`'s "Multi-clip atomic mutation" + "Text-style mutation
/// helpers" sections. This class's own doc comment previously called these out as deferred to M5
/// ("Inspector-level continuous property edits ... that's M5"); the Text tab is the first caller.
/// `_dragBefore` (declared on the main partial, already shared with ApplyClipSpeed/CommitClipSpeed)
/// captures the pre-gesture snapshot the first time a clip is touched mid-drag/mid-type, so a whole
/// live-editing gesture collapses into one undo entry on commit.
///
/// Live (Apply) edits to a text clip always take the debounced-rebuild path
/// (<see cref="NotifyTimelineChangedDebounced"/>), never <see cref="RefreshVisualsRequested"/>:
/// `TimelineSession.RefreshParams`'s native call replays opacity/transform/crop/blendMode/effects/
/// keyframe params against the existing decoder/media sessions — it never re-rasterizes a text
/// clip's glyphs — so only a full snapshot `Update()` (which `StructuralChangeRequested` drives, see
/// `PreviewViewModel.RebuildAsync`) actually shows a new font/size/color/content. This is a
/// deliberate Windows divergence from the Mac's `applyClipProperty`, which takes its own text-clip
/// shortcut straight to `videoEngine?.refreshVisuals()` — cheap there because a `CATextLayer` just
/// redraws in place; there is no Windows equivalent of that shortcut. Non-text clips keep the Mac's
/// original rebuild-vs-refresh choice, ready for whichever tab wires `RefreshVisualsRequested` to
/// `IVideoEngine.RefreshParams` (not yet done anywhere in this port — see this class's own
/// `RefreshVisualsRequested` doc comment).
public sealed partial class TimelineEditorViewModel
{
    /// Applies `modify` live to every resolvable clip in `clipIds`, capturing each one's
    /// pre-gesture snapshot in <see cref="_dragBefore"/> the first time it's touched (subsequent
    /// calls mid-gesture never overwrite it). No undo entry — see <see cref="CommitClipProperties"/>.
    public void ApplyClipProperties(IReadOnlyList<string> clipIds, bool rebuild, Action<Clip> modify)
    {
        var touchedText = false;
        var touchedVisual = false;
        foreach (var clipId in clipIds)
        {
            if (FindClip(clipId) is not { } loc)
            {
                continue;
            }
            var clip = Timeline.Tracks[loc.TrackIndex].Clips[loc.ClipIndex];
            _dragBefore.TryAdd(clipId, clip.Clone());
            modify(clip);
            if (clip.MediaType == ClipType.Text)
            {
                touchedText = true;
            }
            else
            {
                touchedVisual = true;
            }
        }
        if (touchedText)
        {
            NotifyTimelineChangedDebounced();
        }
        if (touchedVisual)
        {
            if (rebuild)
            {
                NotifyTimelineChangedDebounced();
            }
            else
            {
                RefreshVisualsRequested?.Invoke(this, EventArgs.Empty);
            }
        }
    }

    /// Abandons an in-flight gesture on `clipId`, restoring its <see cref="_dragBefore"/> snapshot —
    /// the font picker's "closed the menu without picking" path. A no-op if no gesture is tracked
    /// (nothing was ever applied) or the clip no longer resolves.
    public void RevertClipProperty(string clipId)
    {
        if (!_dragBefore.Remove(clipId, out var original) || FindClip(clipId) is not { } loc)
        {
            return;
        }
        Timeline.Tracks[loc.TrackIndex].Clips[loc.ClipIndex] = original;
        NotifyTimelineChanged();
    }

    /// Ends a gesture on every resolvable clip in `clipIds`, registering one undo entry (action name
    /// "Change Clip Property" — callers that want a more specific name call
    /// `Document.UndoService.SetActionName(...)` immediately after, same pattern as
    /// `applyVolume`/`commitVolume` on the Mac) covering every clip that actually changed relative
    /// to its pre-gesture <see cref="_dragBefore"/> snapshot. A clip whose net change round-trips
    /// back to its own pre-gesture value is dropped from the undo entry entirely, matching the Mac's
    /// `guard undoTarget != clip` skip.
    public void CommitClipProperties(IReadOnlyList<string> clipIds, Action<Clip> modify)
    {
        var before = new List<(string Id, Clip Clip)>();
        var after = new List<(string Id, Clip Clip)>();
        var anyEvaluated = false;
        foreach (var clipId in clipIds)
        {
            if (FindClip(clipId) is not { } loc)
            {
                continue;
            }
            var current = Timeline.Tracks[loc.TrackIndex].Clips[loc.ClipIndex];
            var beforeModify = current.Clone();
            var undoTarget = _dragBefore.Remove(clipId, out var b) ? b : beforeModify;
            modify(current);
            if (beforeModify.ValueEquals(current) && undoTarget.ValueEquals(current))
            {
                continue;
            }
            anyEvaluated = true;
            if (!undoTarget.ValueEquals(current))
            {
                before.Add((clipId, undoTarget));
                after.Add((clipId, current.Clone()));
            }
        }
        if (before.Count > 0)
        {
            RegisterClipStateSwap(before, after, "Change Clip Property");
        }
        if (anyEvaluated)
        {
            NotifyTimelineChanged();
        }
    }

    // MARK: - Text-style mutation helpers (TextStyle.swift's `TextStyle` — see Clip.TextStyle's own
    // doc comment for why the clip stores it as raw JSON rather than this typed model).

    public void ApplyTextStyles(IReadOnlyList<string> clipIds, Action<TextStyle> modify) =>
        ApplyClipProperties(clipIds, rebuild: true, clip => WriteTextStyle(clip, ModifiedTextStyle(clip, modify)));

    public void CommitTextStyles(IReadOnlyList<string> clipIds, Action<TextStyle> modify) =>
        CommitClipProperties(clipIds, clip => WriteTextStyle(clip, ModifiedTextStyle(clip, modify)));

    private static TextStyle ModifiedTextStyle(Clip clip, Action<TextStyle> modify)
    {
        var style = ReadTextStyle(clip);
        modify(style);
        return style;
    }

    private static TextStyle ReadTextStyle(Clip clip) =>
        clip.TextStyle?.Deserialize<TextStyle>() ?? new TextStyle();

    private static void WriteTextStyle(Clip clip, TextStyle style) =>
        clip.TextStyle = JsonSerializer.SerializeToElement(style);
}
