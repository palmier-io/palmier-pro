using PalmierPro.Core.Compositing;
using PalmierPro.Core.Models;

namespace PalmierPro.Core.Editing;

public sealed partial class TimelineEditOperations
{
    /// <summary>
    /// Add/update/remove non-color effect stack entries. Color grades use ApplyColorKnobs.
    /// </summary>
    public bool ApplyEffects(
        IReadOnlyCollection<string> clipIds,
        IReadOnlyList<(string Type, IReadOnlyDictionary<string, double>? Params, bool? Enabled)>? adds,
        IReadOnlyList<string>? removeTypes)
    {
        var targets = ResolveVisualClips(clipIds);
        if (targets.Count == 0) return false;
        adds ??= [];
        removeTypes ??= [];
        if (adds.Count == 0 && removeTypes.Count == 0) return false;

        foreach (var (type, _, _) in adds)
        {
            if (EffectRegistry.Descriptor(type) is null) return false;
            if (type.StartsWith("color.", StringComparison.Ordinal)) return false;
        }

        MutateWithTimelineSwap(targets.Count == 1 ? "Apply Effect" : "Apply Effects", () =>
        {
            foreach (var clip in targets)
            {
                var stack = clip.Effects?.ToList() ?? [];
                foreach (var type in removeTypes)
                    stack.RemoveAll(e => e.Type == type);
                foreach (var (type, parameters, enabled) in adds)
                {
                    var descriptor = EffectRegistry.Descriptor(type)!;
                    var effect = stack.FirstOrDefault(e => e.Type == type) ?? descriptor.MakeEffect();
                    if (enabled is { } on) effect.Enabled = on;
                    if (parameters is not null)
                    {
                        foreach (var spec in descriptor.Params)
                        {
                            if (!parameters.TryGetValue(spec.Key, out var raw)) continue;
                            var clamped = Math.Clamp(raw, spec.Min, spec.Max);
                            effect.Params[spec.Key] = new EffectParam
                            {
                                Value = Math.Round(clamped * 1000) / 1000,
                            };
                        }
                    }
                    stack.RemoveAll(e => e.Type == type);
                    stack.Insert(EffectRegistry.InsertIndex(stack, type), effect);
                }
                clip.Effects = stack.Count == 0 ? null : stack;
            }
        });
        return true;
    }

    /// <summary>Merge simple color knobs into color.* effects (apply_color subset).</summary>
    public bool ApplyColorKnobs(
        IReadOnlyCollection<string> clipIds,
        IReadOnlyDictionary<string, double> knobs,
        bool reset)
    {
        var targets = ResolveVisualClips(clipIds);
        if (targets.Count == 0) return false;
        if (!reset && knobs.Count == 0) return false;

        MutateWithTimelineSwap(targets.Count == 1 ? "Apply Color" : "Apply Color", () =>
        {
            foreach (var clip in targets)
            {
                var stack = reset
                    ? (clip.Effects?.Where(e => !e.Type.StartsWith("color.", StringComparison.Ordinal)).ToList()
                       ?? [])
                    : clip.Effects?.ToList() ?? [];

                void Set(string type, string key, double value)
                {
                    var descriptor = EffectRegistry.Descriptor(type);
                    if (descriptor is null) return;
                    var effect = stack.FirstOrDefault(e => e.Type == type) ?? descriptor.MakeEffect();
                    var spec = descriptor.Params.FirstOrDefault(p => p.Key == key);
                    if (spec is null) return;
                    effect.Params[key] = new EffectParam
                    {
                        Value = Math.Round(Math.Clamp(value, spec.Min, spec.Max) * 1000) / 1000,
                    };
                    stack.RemoveAll(e => e.Type == type);
                    stack.Insert(EffectRegistry.InsertIndex(stack, type), effect);
                }

                foreach (var (name, value) in knobs)
                {
                    switch (name)
                    {
                        case "exposure": Set("color.exposure", "ev", value); break;
                        case "contrast": Set("color.contrast", "amount", value); break;
                        case "saturation": Set("color.saturation", "amount", value); break;
                        case "vibrance": Set("color.vibrance", "amount", value); break;
                        case "temperature": Set("color.temperature", "temperature", value); break;
                        case "tint": Set("color.temperature", "tint", value); break;
                        case "highlights": Set("color.highlightsShadows", "highlights", value); break;
                        case "shadows": Set("color.highlightsShadows", "shadows", value); break;
                        case "blacks": Set("color.blacksWhites", "blacks", value); break;
                        case "whites": Set("color.blacksWhites", "whites", value); break;
                    }
                }

                clip.Effects = stack.Count == 0 ? null : stack;
            }
        });
        return true;
    }

    private List<Clip> ResolveVisualClips(IReadOnlyCollection<string> clipIds)
    {
        var list = new List<Clip>();
        foreach (var id in clipIds)
        {
            if (FindClip(id) is not { } found) continue;
            if (found.Clip.MediaType is not (ClipType.Video or ClipType.Image or ClipType.Sequence))
                continue;
            list.Add(found.Clip);
        }
        return list;
    }
}
