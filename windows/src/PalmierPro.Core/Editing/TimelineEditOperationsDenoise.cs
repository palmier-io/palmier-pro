using PalmierPro.Core.Models;

namespace PalmierPro.Core.Editing;

public sealed partial class TimelineEditOperations
{
    public bool SetDenoise(IReadOnlyCollection<string> clipIds, bool enabled, double? amount = null)
    {
        var targets = new List<Clip>();
        foreach (var id in clipIds)
        {
            if (FindClip(id) is not { } found) continue;
            if (found.Clip.MediaType != ClipType.Audio) continue;
            targets.Add(found.Clip);
        }
        if (targets.Count == 0) return false;

        var strength = Math.Clamp(amount ?? Clip.DefaultDenoiseAmount, 0, 1);
        MutateWithTimelineSwap(enabled ? "Denoise Audio" : "Disable Denoise", () =>
        {
            foreach (var clip in targets)
            {
                var stack = clip.Effects?.ToList() ?? [];
                stack.RemoveAll(e => e.Type == Clip.DenoiseEffectType);
                if (enabled)
                {
                    stack.Add(new Effect
                    {
                        Type = Clip.DenoiseEffectType,
                        Enabled = true,
                        Params = new Dictionary<string, EffectParam>
                        {
                            ["amount"] = new EffectParam { Value = Math.Round(strength * 1000) / 1000 },
                        },
                    });
                }
                clip.Effects = stack.Count == 0 ? null : stack;
            }
        });
        return true;
    }
}
