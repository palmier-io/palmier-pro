namespace PalmierPro.Rendering;

/// Mirrors native PE_ColorScopesResult (native/include/palmier_engine.h) — the small readback
/// buffer behind the Inspector Adjust tab's Curves/Hue Curves scope views. Ports
/// Preview/VideoEngine.swift's histogramYRGB(frame:count:256)/hueHistogram(frame:count:96), NOT
/// Compositing/ColorScopes.swift's `Scopes` struct (Agent-tool-only, Phase 2). See
/// docs/color-scopes-v1.md for bin-count/normalization details and the exact contract.
///
/// Backed by <see cref="PalmierPro.Rendering.TimelineSession.ComputeColorScopes"/> ->
/// PE_TimelineComputeColorScopes (docs/color-scopes-v1.md §6/§8). `IReadOnlyList&lt;float&gt;`
/// (not `float[]`) because a `PE_ColorScopesResult`'s arrays are embedded inline in a struct
/// returned by value across P/Invoke, not an engine-owned buffer valid-until-next-call — copying
/// out is the only option, so this is purely about not overpromising array identity to callers.
public sealed record ColorScopesResult(
    long Frame,
    IReadOnlyList<float> YHistogram,
    IReadOnlyList<float> RHistogram,
    IReadOnlyList<float> GHistogram,
    IReadOnlyList<float> BHistogram,
    IReadOnlyList<float> HueHistogram)
{
    public const int RgbBinCount = 256;
    public const int HueBinCount = 96;

    internal static unsafe ColorScopesResult FromNative(in PE_ColorScopesResult native)
    {
        var y = new float[RgbBinCount];
        var r = new float[RgbBinCount];
        var g = new float[RgbBinCount];
        var b = new float[RgbBinCount];
        var hue = new float[HueBinCount];
        fixed (float* yp = native.YHistogram, rp = native.RHistogram, gp = native.GHistogram, bp = native.BHistogram, huep = native.HueHistogram)
        {
            new ReadOnlySpan<float>(yp, RgbBinCount).CopyTo(y);
            new ReadOnlySpan<float>(rp, RgbBinCount).CopyTo(r);
            new ReadOnlySpan<float>(gp, RgbBinCount).CopyTo(g);
            new ReadOnlySpan<float>(bp, RgbBinCount).CopyTo(b);
            new ReadOnlySpan<float>(huep, HueBinCount).CopyTo(hue);
        }
        return new ColorScopesResult(native.Frame, y, r, g, b, hue);
    }
}
