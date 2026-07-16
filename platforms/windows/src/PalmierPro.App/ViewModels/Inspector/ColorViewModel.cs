using PalmierPro.App.ViewModels.Editor;
using PalmierPro.App.Views.Inspector;
using PalmierPro.Core.Effects;
using PalmierPro.Core.Models;
using PalmierPro.Core.Timeline;
using PalmierPro.Rendering;
using PalmierPro.Services.Engine;

namespace PalmierPro.App.ViewModels.Inspector;

/// Grade-curve channel — a UI-only grouping with no Mac model equivalent (GradeCurve.swift has no
/// `Channel`; the picker lives in CurveEditorView.swift itself), mirrored here for the same reason.
public enum ColorCurveChannel { Master, Red, Green, Blue }

/// Backs ColorTabView (M5, InspectorTab.Color) — Lift/Gamma/Gain color wheels (`color.wheels`),
/// the master grade curve (`color.curves`), and hue curves (`color.hueCurves`) for the current
/// clip selection. Ports the color-specific slice of Inspector/Tabs/AdjustTab.swift (wheelsContent/
/// curvesContent/hueCurvesContent + their apply/commit helpers), reading param specs/insert order
/// from the already-ported <see cref="EffectRegistry"/> rather than re-declaring them.
///
/// Continuous-drag apply/commit follows the same shape as EffectsViewModel.ApplyParamValue/
/// CommitParamValue (this port's established pattern, itself mirroring
/// TimelineEditorViewModel.ClipMutations.cs's private ApplyClipSpeed/CommitClipSpeed): a live
/// "Apply" mutates the clip(s) directly with undo registration suppressed, capturing one
/// pre-drag <see cref="Core.Models.Timeline"/> clone; "Commit" registers a single
/// <see cref="TimelineEditorViewModel.RegisterTimelineSwap"/> undo spanning the whole gesture.
/// Wheels additionally push straight to <see cref="IVideoEngine.RefreshParams"/> on every apply —
/// numeric-only params (color.wheels) fit that fast param-patch ABI; curves/hue curves are a
/// string-encoded param RefreshParams's <see cref="EffectParamPatch"/> can't carry, so those rely
/// on <see cref="TimelineEditorViewModel.NotifyTimelineChangedDebounced"/> for live feedback
/// instead — the "notify split" AGENTS.md's ownership note calls out.
///
/// WinUI-free (plain class, no ObservableObject) — ColorTabView rebuilds its child controls'
/// values directly from this on every relevant refresh, the same convention EffectsViewModel's
/// `EffectParamRow`s use ("these don't need their own change notification").
public sealed class ColorViewModel
{
    private const string WheelsEffectType = "color.wheels";
    private const string CurvesEffectType = "color.curves";

    private readonly TimelineEditorViewModel _timeline;
    private readonly IReadOnlyList<Clip> _clips;
    private Core.Models.Timeline? _dragBefore;

    public ColorViewModel(InspectorTabContext context)
    {
        _timeline = context.Timeline;
        _clips = [.. context.SelectedClips.Where(c => c.MediaType.IsVisual() && c.MediaType != ClipType.Text)];
    }

    public bool HasSelection => _clips.Count > 0;

    /// Shared read-back for a per-clip drawing surface (Timeline canvas, PreviewViewModel's engine
    /// session) — never for the currently-dragging control, which tracks its own live value.
    public TimelineEditorViewModel Timeline => _timeline;

    // MARK: - Shared-value read helper (mirrors AdjustTab.swift's sharedClipValue)

    private static double? SharedValue(IReadOnlyList<Clip> clips, Func<Clip, double> get)
    {
        if (clips.Count == 0)
        {
            return null;
        }
        var first = get(clips[0]);
        for (var i = 1; i < clips.Count; i++)
        {
            if (get(clips[i]) != first)
            {
                return null;
            }
        }
        return first;
    }

    // MARK: - Wheels

    public readonly record struct WheelReading(double X, double Y, double Master, double MasterDefault, double MasterMin, double MasterMax);

    private static EffectParamSpec WheelSpec(string key) =>
        EffectRegistry.Descriptor(WheelsEffectType)!.Params.First(p => p.Key == key);

    private static double WheelParam(Clip clip, string key, double def) =>
        (clip.Effects ?? []).FirstOrDefault(e => e.Type == WheelsEffectType)?.Params.GetValueOrDefault(key)?.Resolved(0, def) ?? def;

    public WheelReading ReadWheel(string prefix)
    {
        var xSpec = WheelSpec($"{prefix}_x");
        var ySpec = WheelSpec($"{prefix}_y");
        var mSpec = WheelSpec($"{prefix}_m");
        var x = SharedValue(_clips, c => WheelParam(c, $"{prefix}_x", xSpec.DefaultValue)) ?? xSpec.DefaultValue;
        var y = SharedValue(_clips, c => WheelParam(c, $"{prefix}_y", ySpec.DefaultValue)) ?? ySpec.DefaultValue;
        var m = SharedValue(_clips, c => WheelParam(c, $"{prefix}_m", mSpec.DefaultValue)) ?? mSpec.DefaultValue;
        return new WheelReading(x, y, m, mSpec.DefaultValue, mSpec.RangeMin, mSpec.RangeMax);
    }

    /// Live pad drag — no model mutation, no undo: pushes straight to the GPU preview. Mirrors
    /// AdjustTab.swift's applyEffects for the wheels' fast numeric path.
    public void ApplyWheelColor(string prefix, double x, double y) => PushWheelPreview(prefix, x, y, ReadWheel(prefix).Master);

    /// Live master-slider drag — same fast path as <see cref="ApplyWheelColor"/>.
    public void ApplyWheelMaster(string prefix, double master)
    {
        var w = ReadWheel(prefix);
        PushWheelPreview(prefix, w.X, w.Y, master);
    }

    private void PushWheelPreview(string prefix, double x, double y, double master)
    {
        if (_timeline.Engine is not { } engine || _clips.Count == 0)
        {
            return;
        }
        var patches = _clips.Select(c => new ClipParamPatch(
            c.Id,
            Effects:
            [
                new EffectParamPatch(WheelsEffectType, $"{prefix}_x", x),
                new EffectParamPatch(WheelsEffectType, $"{prefix}_y", y),
                new EffectParamPatch(WheelsEffectType, $"{prefix}_m", master),
            ])).ToList();
        engine.RefreshParams(new TimelineParamPatch(_timeline.ActiveTimelineId, patches));
    }

    public void CommitWheelColor(string prefix, double x, double y) =>
        CommitWheel(prefix, x, y, ReadWheel(prefix).Master, $"Adjust {Capitalize(prefix)}");

    public void CommitWheelMaster(string prefix, double master)
    {
        var w = ReadWheel(prefix);
        CommitWheel(prefix, w.X, w.Y, master, $"Adjust {Capitalize(prefix)}");
    }

    private void CommitWheel(string prefix, double x, double y, double master, string actionName)
    {
        EnsureDragSnapshot();
        foreach (var clip in _clips)
        {
            var effects = clip.Effects ?? [];
            UpsertWheelValue(effects, $"{prefix}_x", x);
            UpsertWheelValue(effects, $"{prefix}_y", y);
            UpsertWheelValue(effects, $"{prefix}_m", master);
            clip.Effects = effects.Count == 0 ? null : effects;
        }
        FinishDrag(actionName);
    }

    /// Upsert one param into the singleton `color.wheels` effect, inserting in canonical order when
    /// first touched and pruning it once every param returns to default — mirrors AdjustTab.swift's
    /// `upsertControl`.
    private static void UpsertWheelValue(List<Effect> effects, string key, double value)
    {
        var descriptor = EffectRegistry.Descriptor(WheelsEffectType)!;
        var idx = effects.FindIndex(e => e.Type == WheelsEffectType);
        if (idx >= 0)
        {
            effects[idx].Params[key] = new EffectParam(value);
            var allDefault = descriptor.Params.All(spec => (effects[idx].Params.GetValueOrDefault(spec.Key)?.Value ?? spec.DefaultValue) == spec.DefaultValue);
            if (allDefault)
            {
                effects.RemoveAt(idx);
            }
            return;
        }
        var spec = descriptor.Params.First(p => p.Key == key);
        if (value == spec.DefaultValue)
        {
            return;
        }
        var effect = descriptor.MakeEffect();
        effect.Params[key] = new EffectParam(value);
        effects.Insert(EffectRegistry.InsertIndex(effects, WheelsEffectType), effect);
    }

    private static string Capitalize(string s) => s.Length == 0 ? s : char.ToUpperInvariant(s[0]) + s[1..];

    public bool HasWheelAdjustment => HasEffect(WheelsEffectType);

    public void ResetWheels() => ResetEffect(WheelsEffectType, "Reset Color Wheels");

    // MARK: - Grade curve ("color.curves" — no GradeCurve.Read/Upsert on the model, matching the
    // Mac: GradeCurve.swift has none either, this effects-list interaction lives in the tab, same
    // as AdjustTab.swift's curve(in:)/upsertCurve(_:in:))

    public GradeCurve ReadGradeCurve() => _clips.Count == 0 ? new GradeCurve() : CurveFor(_clips[0].Effects ?? []);

    /// Live curve drag — mutates the model directly (bypassing undo) since only a rebuild can show
    /// progress (the string-encoded curve param has no RefreshParams fast path), then debounces the
    /// rebuild. Mirrors AdjustTab.swift's applyEffects for curves.
    public void ApplyCurveChannel(ColorCurveChannel channel, IReadOnlyList<CurvePoint> points) => MutateCurve(channel, points, commit: false);

    public void CommitCurveChannel(ColorCurveChannel channel, IReadOnlyList<CurvePoint> points) => MutateCurve(channel, points, commit: true);

    private void MutateCurve(ColorCurveChannel channel, IReadOnlyList<CurvePoint> points, bool commit)
    {
        EnsureDragSnapshot();
        List<CurvePoint> list = [.. points];
        foreach (var clip in _clips)
        {
            var effects = clip.Effects ?? [];
            var curve = CurveFor(effects);
            SetChannel(curve, channel, list);
            UpsertCurve(curve, effects);
            clip.Effects = effects.Count == 0 ? null : effects;
        }
        if (commit)
        {
            FinishDrag("Edit Curves");
        }
        else
        {
            _timeline.NotifyTimelineChangedDebounced();
        }
    }

    private static GradeCurve CurveFor(List<Effect> effects)
    {
        var json = effects.FirstOrDefault(e => e.Type == CurvesEffectType)?.Params.GetValueOrDefault("curve")?.StringValue;
        return json is null ? new GradeCurve() : (GradeCurve.FromJson(json) ?? new GradeCurve());
    }

    private static void SetChannel(GradeCurve curve, ColorCurveChannel channel, List<CurvePoint> points)
    {
        switch (channel)
        {
            case ColorCurveChannel.Master: curve.Master = points; break;
            case ColorCurveChannel.Red: curve.Red = points; break;
            case ColorCurveChannel.Green: curve.Green = points; break;
            case ColorCurveChannel.Blue: curve.Blue = points; break;
            default: throw new ArgumentOutOfRangeException(nameof(channel));
        }
    }

    private static void UpsertCurve(GradeCurve curve, List<Effect> effects)
    {
        var idx = effects.FindIndex(e => e.Type == CurvesEffectType);
        if (curve.IsIdentity || curve.ToJson() is not { } json)
        {
            if (idx >= 0)
            {
                effects.RemoveAt(idx);
            }
            return;
        }
        if (idx >= 0)
        {
            effects[idx].Params["curve"] = new EffectParam(stringValue: json);
        }
        else
        {
            var effect = EffectRegistry.Descriptor(CurvesEffectType)!.MakeEffect();
            effect.Params["curve"] = new EffectParam(stringValue: json);
            effects.Insert(EffectRegistry.InsertIndex(effects, CurvesEffectType), effect);
        }
    }

    public bool HasCurveAdjustment => HasEffect(CurvesEffectType);

    public void ResetCurves() => ResetEffect(CurvesEffectType, "Reset Curves");

    // MARK: - Hue curves ("color.hueCurves" — HueCurves.Read/Upsert already exist on the model,

    public HueCurves ReadHueCurves() => _clips.Count == 0 ? new HueCurves() : HueCurves.Read(_clips[0].Effects ?? []);

    public void ApplyHueCurveChannel(HueCurvesChannel channel, IReadOnlyList<CurvePoint> points) => MutateHueCurve(channel, points, commit: false);

    public void CommitHueCurveChannel(HueCurvesChannel channel, IReadOnlyList<CurvePoint> points) => MutateHueCurve(channel, points, commit: true);

    private void MutateHueCurve(HueCurvesChannel channel, IReadOnlyList<CurvePoint> points, bool commit)
    {
        EnsureDragSnapshot();
        List<CurvePoint> list = [.. points];
        foreach (var clip in _clips)
        {
            var effects = clip.Effects ?? [];
            var curves = HueCurves.Read(effects);
            curves.Set(channel, list);
            curves.Upsert(effects);
            clip.Effects = effects.Count == 0 ? null : effects;
        }
        if (commit)
        {
            FinishDrag("Edit Hue Curves");
        }
        else
        {
            _timeline.NotifyTimelineChangedDebounced();
        }
    }

    public bool HasHueCurveAdjustment => HasEffect(HueCurves.EffectType);

    public void ResetHueCurves() => ResetEffect(HueCurves.EffectType, "Reset Hue Curves");

    // MARK: - Reset / drag bookkeeping

    private bool HasEffect(string effectType) => _clips.Any(c => (c.Effects ?? []).Any(e => e.Type == effectType));

    private void ResetEffect(string effectType, string actionName)
    {
        if (!HasEffect(effectType))
        {
            return;
        }
        EnsureDragSnapshot();
        foreach (var clip in _clips)
        {
            if (clip.Effects is not { } effects)
            {
                continue;
            }
            effects.RemoveAll(e => e.Type == effectType);
            clip.Effects = effects.Count == 0 ? null : effects;
        }
        FinishDrag(actionName);
    }

    private void EnsureDragSnapshot() => _dragBefore ??= _timeline.Timeline.Clone();

    /// Registers the single undo entry for whatever's changed since <see cref="EnsureDragSnapshot"/>
    /// last captured a clean "before" — mirrors TimelineEditorViewModel.ClipMutations.cs's
    /// CommitClipSpeed. Always forces an immediate (non-debounced) rebuild so the authoritative
    /// post-commit frame replaces any RefreshParams-only preview or debounced-but-not-yet-fired
    /// curve edit.
    private void FinishDrag(string actionName)
    {
        var before = _dragBefore;
        _dragBefore = null;
        if (before is null || before.ValueEquals(_timeline.Timeline))
        {
            _timeline.NotifyTimelineChanged();
            return;
        }
        _timeline.RegisterTimelineSwap(before, _timeline.Timeline, actionName);
        _timeline.NotifyTimelineChanged();
    }
}
