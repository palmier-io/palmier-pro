using System.ComponentModel;
using CommunityToolkit.Mvvm.ComponentModel;
using PalmierPro.App.ViewModels.Editor;
using PalmierPro.App.Views.Inspector;
using PalmierPro.Core.Effects;
using PalmierPro.Core.Models;
using PalmierPro.Core.Timeline;

namespace PalmierPro.App.ViewModels.Inspector;

/// One generated param row: a registry spec plus the value/keyframe state resolved for the
/// current selection at the current playhead. Plain data — EffectsTabView rebuilds its child
/// controls from a fresh `EffectsViewModel.Stack` on every real change, so these don't need their
/// own change notification (see that class's remarks on why a live slider drag never touches
/// `Stack`).
public sealed class EffectParamRow
{
    public required EffectParamSpec Spec { get; init; }

    /// Null = mixed values across a multi-clip selection (falls back to Spec.DefaultValue for
    /// display, matching the Mac's `sharedClipValue(clips) { ... } ?? spec.defaultValue`).
    public required double? Value { get; init; }

    public required bool IsAnimated { get; init; }
    public required bool HasKeyframeAtPlayhead { get; init; }

    /// Keyframe toggle is only meaningful for a single-clip selection with the playhead inside
    /// that clip — mirrors the Mac's `animatableRow`/`keyframeControls` `inRange` gate.
    public required bool CanToggleKeyframe { get; init; }
}

public sealed class EffectStackItem
{
    public required string EffectId { get; init; }
    public required EffectDescriptor Descriptor { get; init; }
    public required bool Enabled { get; init; }
    public required IReadOnlyList<EffectParamRow> Params { get; init; }
}

/// Backs the Effects tab (M5): a per-clip, explicitly ordered effect stack — add from
/// <see cref="Catalog"/>, then reorder/toggle/remove/edit params — over
/// <see cref="EffectRegistry"/>'s catalog. This is a v1 Windows-native "effect stack" UI rather
/// than a literal port of the Mac's AdjustTab.swift (fixed always-on sections with a Curves/Color-
/// Wheels/Hue-Curves custom-drawn editor for each of `color.curves`/`color.wheels`/
/// `color.hueCurves` — none of which have a Windows control yet); every registry entry still
/// renders here as generated slider/scrub rows, so no effect is unreachable, but curve/wheel-shaped
/// params show as their raw numeric components until a dedicated control exists.
///
/// Reads/writes route through <see cref="TimelineEditorViewModel"/>'s existing public mutation
/// surface only — <see cref="TimelineEditorViewModel.WithTimelineSwap"/> for one-shot commands
/// (add/remove/toggle/reorder/keyframe-stamp) and a local before/after diff (this class's own
/// <see cref="_dragBeforeTimeline"/>, mirroring TimelineEditorViewModel.ClipMutations.cs's private
/// `_dragBefore`/`_preDragTimeline` pattern for `ApplyClipSpeed`/`CommitClipSpeed`, which this class
/// can't reach directly since those fields are private to that class) for slider-drag apply/commit.
/// A live "Apply" mutates the clip(s) directly and does not touch <see cref="Stack"/> or call
/// <see cref="TimelineEditorViewModel.NotifyTimelineChanged"/> — same as `ApplyClipSpeed` today —
/// so a drag never rebuilds the child controls out from under an in-progress pointer-capture
/// gesture; the (rare) fully wired live-preview refresh promised by the RefreshParams/
/// IVideoEngine.RefreshParams pipeline isn't connected to anything yet on Windows (`ApplyClipSpeed`
/// has the same gap) — out of this tab's scope to fix.
public sealed class EffectsViewModel : ObservableObject
{
    private readonly TimelineEditorViewModel _timeline;
    private readonly IReadOnlyList<string> _clipIds;
    private Timeline? _dragBeforeTimeline;

    private IReadOnlyList<EffectStackItem> _stack = [];
    public IReadOnlyList<EffectStackItem> Stack
    {
        get => _stack;
        private set => SetProperty(ref _stack, value);
    }

    /// Grouped catalog for the add-effect flyout — every registered effect type, regardless of
    /// whether native Windows rendering exists for it yet (see EffectRegistry's class doc).
    public IReadOnlyList<(string Category, IReadOnlyList<EffectDescriptor> Effects)> Catalog => EffectRegistry.ByCategory;

    public EffectsViewModel(InspectorTabContext context)
    {
        _timeline = context.Timeline;
        _clipIds = [.. context.SelectedClips
            .Where(c => c.MediaType.IsVisual() && c.MediaType != ClipType.Text)
            .Select(c => c.Id)];
        _timeline.PropertyChanged += OnTimelinePropertyChanged;
        _timeline.StructuralChangeRequested += OnStructuralChangeRequested;
        Rebuild();
    }

    /// EffectsTabView calls this from its own `Unloaded` handler — InspectorView builds a fresh
    /// instance per tab/selection change and never explicitly disposes the old one, so an unhooked
    /// subscription here would keep this instance (and the closed-over TimelineEditorViewModel
    /// reference chain) alive for the document's lifetime.
    public void Detach()
    {
        _timeline.PropertyChanged -= OnTimelinePropertyChanged;
        _timeline.StructuralChangeRequested -= OnStructuralChangeRequested;
    }

    public bool IsInStack(string effectId) => Stack.Any(s => s.EffectId == effectId);

    private void OnTimelinePropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(TimelineEditorViewModel.CurrentFrame))
        {
            Rebuild();
        }
    }

    private void OnStructuralChangeRequested(object? sender, EventArgs e) => Rebuild();

    private IReadOnlyList<Clip> ResolveClips() => [.. _clipIds.Select(_timeline.ClipFor).OfType<Clip>()];

    private void Rebuild()
    {
        var clips = ResolveClips();
        var first = clips.FirstOrDefault();
        if (first is null)
        {
            Stack = [];
            return;
        }
        var single = clips.Count == 1 ? first : null;
        var frame = _timeline.CurrentFrame;

        var items = new List<EffectStackItem>();
        foreach (var effect in first.Effects ?? [])
        {
            if (EffectRegistry.Descriptor(effect.Type) is not { } descriptor)
            {
                continue; // unregistered/legacy effect type — no generated row surface for it
            }
            var canToggleKeyframe = single is not null && single.Contains(frame);
            var offset = single is not null ? frame - single.StartFrame : 0;
            var rows = descriptor.Params.Select(spec =>
            {
                var param = single?.Effects?.FirstOrDefault(e => e.Type == effect.Type)?.Params.GetValueOrDefault(spec.Key);
                var track = param?.Track;
                return new EffectParamRow
                {
                    Spec = spec,
                    Value = SharedParamValue(clips, effect.Type, spec.Key, spec.DefaultValue, offset),
                    IsAnimated = track?.IsActive ?? false,
                    HasKeyframeAtPlayhead = canToggleKeyframe && (track?.Keyframes.Any(k => k.Frame == offset) ?? false),
                    CanToggleKeyframe = canToggleKeyframe,
                };
            }).ToList();
            items.Add(new EffectStackItem
            {
                EffectId = effect.Type,
                Descriptor = descriptor,
                Enabled = effect.Enabled,
                Params = rows,
            });
        }
        Stack = items;
    }

    private static double? SharedParamValue(IReadOnlyList<Clip> clips, string effectType, string key, double def, int offset)
    {
        double? shared = null;
        foreach (var clip in clips)
        {
            var value = clip.Effects?.FirstOrDefault(e => e.Type == effectType)?.Params.GetValueOrDefault(key)?.Resolved(offset, def) ?? def;
            if (shared is null)
            {
                shared = value;
            }
            else if (Math.Abs(shared.Value - value) > 1e-9)
            {
                return null;
            }
        }
        return shared;
    }

    // MARK: - Stack commands (one-shot, undoable)

    public void AddEffect(EffectDescriptor descriptor)
    {
        if (IsInStack(descriptor.Id))
        {
            return;
        }
        _timeline.WithTimelineSwap($"Add {descriptor.DisplayName}", () =>
        {
            foreach (var clip in ResolveClips())
            {
                clip.Effects ??= [];
                if (clip.Effects.Any(e => e.Type == descriptor.Id))
                {
                    continue;
                }
                clip.Effects.Insert(EffectRegistry.InsertIndex(clip.Effects, descriptor.Id), descriptor.MakeEffect());
            }
        });
        Rebuild();
    }

    public void RemoveEffect(string effectId)
    {
        var name = EffectRegistry.Descriptor(effectId)?.DisplayName ?? effectId;
        _timeline.WithTimelineSwap($"Remove {name}", () =>
        {
            foreach (var clip in ResolveClips())
            {
                clip.Effects?.RemoveAll(e => e.Type == effectId);
                if (clip.Effects?.Count == 0)
                {
                    clip.Effects = null;
                }
            }
        });
        Rebuild();
    }

    public void ToggleEnabled(string effectId)
    {
        var wasEnabled = Stack.FirstOrDefault(s => s.EffectId == effectId)?.Enabled ?? true;
        var name = EffectRegistry.Descriptor(effectId)?.DisplayName ?? effectId;
        _timeline.WithTimelineSwap(wasEnabled ? $"Disable {name}" : $"Enable {name}", () =>
        {
            foreach (var clip in ResolveClips())
            {
                var effect = clip.Effects?.FirstOrDefault(e => e.Type == effectId);
                if (effect is not null)
                {
                    effect.Enabled = !wasEnabled;
                }
            }
        });
        Rebuild();
    }

    /// Reorders by effect *type*: the reference (first selected) clip's own stack order is what
    /// moves, then every other selected clip's stack is re-sorted to match that same type order —
    /// each clip keeps its own Effect instances, only their relative position changes, so a
    /// multi-clip selection stays in lockstep even though each clip's effects are separate objects.
    public void MoveEffect(string effectId, int direction)
    {
        var name = EffectRegistry.Descriptor(effectId)?.DisplayName ?? effectId;
        _timeline.WithTimelineSwap($"Reorder {name}", () =>
        {
            var clips = ResolveClips();
            var reference = clips.FirstOrDefault()?.Effects;
            if (reference is null)
            {
                return;
            }
            var index = reference.FindIndex(e => e.Type == effectId);
            var newIndex = index + direction;
            if (index < 0 || newIndex < 0 || newIndex >= reference.Count)
            {
                return;
            }
            (reference[index], reference[newIndex]) = (reference[newIndex], reference[index]);
            var order = reference.Select(e => e.Type).ToList();
            foreach (var clip in clips.Skip(1))
            {
                ReorderToMatch(clip, order);
            }
        });
        Rebuild();
    }

    private static void ReorderToMatch(Clip clip, List<string> order)
    {
        if (clip.Effects is not { } effects)
        {
            return;
        }
        clip.Effects =
        [
            .. effects
                .Select((e, i) => (Effect: e, Rank: order.IndexOf(e.Type) is var r && r >= 0 ? r : int.MaxValue, Original: i))
                .OrderBy(t => t.Rank).ThenBy(t => t.Original)
                .Select(t => t.Effect),
        ];
    }

    /// Stamps (or, if one already sits at the playhead, removes) a keyframe on this param for the
    /// single selected clip — single-clip only, matching the Mac's `animatableRow` gate; a
    /// multi-clip selection has no single playhead-relative value to key.
    public void ToggleKeyframe(string effectId, string paramKey)
    {
        if (ResolveClips() is not [var clip] || !clip.Contains(_timeline.CurrentFrame))
        {
            return;
        }
        var spec = EffectRegistry.Descriptor(effectId)?.Params.FirstOrDefault(p => p.Key == paramKey);
        if (spec is null)
        {
            return;
        }
        var offset = _timeline.CurrentFrame - clip.StartFrame;
        _timeline.WithTimelineSwap($"Keyframe {spec.Label}", () =>
        {
            var effect = clip.Effects?.FirstOrDefault(e => e.Type == effectId);
            if (effect is null)
            {
                return;
            }
            var param = effect.Params.GetValueOrDefault(paramKey) ?? new EffectParam(spec.DefaultValue);
            var track = param.Track ?? new KeyframeTrack<double>();
            if (track.Keyframes.Any(k => k.Frame == offset))
            {
                track.Remove(offset);
                param.Track = track.Keyframes.Count == 0 ? null : track;
            }
            else
            {
                track.Upsert(new Keyframe<double>(offset, param.Resolved(offset, spec.DefaultValue)));
                param.Track = track;
            }
            effect.Params[paramKey] = param;
        });
        Rebuild();
    }

    // MARK: - Param value (continuous drag apply/commit)

    /// Live edit — no undo entry, no `Stack` reassignment (see class doc). Call on every drag tick.
    public void ApplyParamValue(string effectId, string paramKey, double value)
    {
        _dragBeforeTimeline ??= _timeline.Timeline.Clone();
        SetParamValue(effectId, paramKey, value);
    }

    /// One undo entry for the whole gesture. Call once on drag end (pointer release / capture
    /// loss / double-tap reset).
    public void CommitParamValue(string effectId, string paramKey, double value)
    {
        var before = _dragBeforeTimeline ?? _timeline.Timeline.Clone();
        SetParamValue(effectId, paramKey, value);
        _dragBeforeTimeline = null;
        if (!before.ValueEquals(_timeline.Timeline))
        {
            var label = EffectRegistry.Descriptor(effectId)?.Params.FirstOrDefault(p => p.Key == paramKey)?.Label ?? paramKey;
            _timeline.RegisterTimelineSwap(before, _timeline.Timeline, $"Change {label}");
            _timeline.NotifyTimelineChanged();
        }
        Rebuild();
    }

    /// While the param is animated (single-clip selection with an active keyframe Track), a drag
    /// stamps/updates the keyframe at the playhead-relative offset instead of the static value —
    /// `Resolved` ignores `Value` whenever `Track.IsActive`, so writing only `Value` there would
    /// silently do nothing. Gated on the Track being active, not on the playhead sitting inside the
    /// clip's [start,end) range: mirrors the Transform tab's writeX helpers (TransformViewModel's
    /// WritePosition/WriteScale/etc.), which upsert to an active track unconditionally. Scrubbing the
    /// playhead off a still-selected clip and nudging the slider must not fall through to the `else`
    /// branch — that replaces the whole EffectParam and silently discards every keyframe on the track.
    private void SetParamValue(string effectId, string paramKey, double value)
    {
        var clips = ResolveClips();
        var single = clips.Count == 1 ? clips[0] : null;
        var offset = single is not null ? _timeline.CurrentFrame - single.StartFrame : 0;

        foreach (var clip in clips)
        {
            var effect = clip.Effects?.FirstOrDefault(e => e.Type == effectId);
            if (effect is null)
            {
                continue;
            }
            if (clip == single && effect.Params.GetValueOrDefault(paramKey)?.Track is { IsActive: true } track)
            {
                track.Upsert(new Keyframe<double>(offset, value));
            }
            else
            {
                effect.Params[paramKey] = new EffectParam(value);
            }
        }
    }
}
