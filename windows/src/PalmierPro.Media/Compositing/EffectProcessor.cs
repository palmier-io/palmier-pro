using PalmierPro.Core.Compositing;
using PalmierPro.Core.Models;
using PalmierPro.Media.Playback;

namespace PalmierPro.Media.Compositing;

/// <summary>
/// Applies a clip's enabled effect stack and edge rounding to a BGRA frame.
/// Custom Metal kernels run as CPU ports of EffectPixelKernels; blur/glow/clarity
/// use separable approximations. Shared by preview and export.
/// </summary>
public static class EffectProcessor
{
    public static VideoFrame ApplyClipPipeline(VideoFrame source, Clip clip, int timelineFrame)
    {
        var working = source;
        if (clip.Effects is { Count: > 0 } effects)
        {
            var offset = timelineFrame - clip.StartFrame;
            foreach (var effect in effects)
            {
                if (!effect.Enabled) continue;
                if (EffectRegistry.Descriptor(effect.Type) is not { } descriptor) continue;
                var resolved = descriptor.Resolve(effect, offset);
                working = Apply(working, effect.Type, resolved);
            }
        }

        if (clip.EdgeRounding > 0 || clip.EdgeSoftness > 0)
            working = ApplyEdgeRounding(working, (float)clip.EdgeRounding, (float)clip.EdgeSoftness);

        return working;
    }

    public static VideoFrame Apply(VideoFrame frame, string type, ResolvedEffectParams p)
        => type switch
        {
            "color.exposure" => MapRgb(frame, (r, g, b, _, _) =>
                EffectPixelKernels.Exposure(r, g, b, (float)p.Value("ev"))),
            "color.contrast" => MapRgb(frame, (r, g, b, _, _) =>
                EffectPixelKernels.Contrast(r, g, b, (float)p.Value("amount"))),
            "color.saturation" => MapRgb(frame, (r, g, b, _, _) =>
                EffectPixelKernels.Saturation(r, g, b, (float)p.Value("amount"))),
            "color.temperature" => MapRgb(frame, (r, g, b, _, _) =>
                EffectPixelKernels.TemperatureTint(r, g, b,
                    (float)p.Value("temperature"), (float)p.Value("tint"))),
            "color.highlightsShadows" => MapRgb(frame, (r, g, b, _, _) =>
                EffectPixelKernels.HighlightsShadows(r, g, b,
                    (float)p.Value("highlights"), (float)p.Value("shadows"))),
            "color.blacksWhites" => MapRgb(frame, (r, g, b, _, _) =>
                EffectPixelKernels.Levels(r, g, b, (float)p.Value("blacks"), (float)p.Value("whites"))),
            "color.vibrance" => MapRgb(frame, (r, g, b, _, _) =>
                EffectPixelKernels.Vibrance(r, g, b, (float)p.Value("amount"))),
            "color.wheels" when !ColorWheels.IsNeutral(p) => MapRgb(frame, (r, g, b, _, _) =>
                EffectPixelKernels.Wheels(r, g, b, ColorWheels.CoefficientsFor(p))),
            "stylize.invert" => MapRgb(frame, (r, g, b, _, _) => EffectPixelKernels.Invert(r, g, b)),
            "stylize.grain" => MapRgb(frame, (r, g, b, x, y) =>
                EffectPixelKernels.Grain(r, g, b, x, y,
                    (float)p.Value("amount"), (float)p.Value("size"), p.Frame)),
            "stylize.vignette" => MapRgb(frame, (r, g, b, x, y) =>
                EffectPixelKernels.Vignette(r, g, b, x, y, frame.Width, frame.Height,
                    (float)p.Value("amount"), (float)p.Value("midpoint"),
                    (float)p.Value("roundness"), (float)p.Value("feather"))),
            "key.chroma" => MapRgba(frame, (r, g, b, a, _, _) =>
                EffectPixelKernels.ChromaKey(r, g, b, a,
                    (float)p.Value("keyHue"), (float)p.Value("tolerance"),
                    (float)p.Value("softness"), (float)p.Value("spill"))),
            "color.lut" => ApplyLut(frame, p),
            "color.curves" => ApplyGradeCurves(frame, p),
            "color.hueCurves" => ApplyHueCurves(frame, p),
            "blur.gaussian" => BoxBlur(frame, (float)p.Value("radius")),
            "blur.noiseReduction" => ApplyNoiseReduction(frame, (float)p.Value("amount")),
            "blur.motion" => ApplyMotionBlur(frame, (float)p.Value("radius"), (float)p.Value("angle")),
            "stylize.glow" => ApplyGlow(frame, p),
            "detail.clarity" => ApplyClarity(frame, p),
            "blur.sharpen" => ApplySharpen(frame, (float)p.Value("amount")),
            _ => frame,
        };

    private static VideoFrame ApplyHueCurves(VideoFrame frame, ResolvedEffectParams p)
    {
        if (p.String("curves") is not { Length: > 0 } json) return frame;
        if (HueCurves.FromJson(json) is not { } curves || curves.IsIdentity) return frame;
        return MapRgb(frame, (r, g, b, _, _) =>
        {
            var (h, s, v) = RgbToHsv(r, g, b);
            var hueShift = (float)(HueCurves.Eval(curves.HueVsHue, h) - HueCurves.NeutralY);
            var satShift = (float)(HueCurves.Eval(curves.HueVsSat, h) - HueCurves.NeutralY);
            var lumShift = (float)(HueCurves.Eval(curves.HueVsLum, h) - HueCurves.NeutralY);
            h = EffectPixelKernels.Saturate(h + hueShift);
            s = EffectPixelKernels.Saturate(s + satShift);
            v = EffectPixelKernels.Saturate(v + lumShift);
            return HsvToRgb(h, s, v);
        });
    }

    private static VideoFrame ApplyNoiseReduction(VideoFrame frame, float amount)
    {
        if (amount <= 0) return frame;
        // Mild bilateral-ish approx: light box blur mixed with original.
        var blurred = BoxBlur(frame, Math.Clamp(amount * 4f, 0.5f, 6f));
        var mix = Math.Clamp(amount, 0, 1);
        return MapRgb(frame, (r, g, b, x, y) =>
        {
            var i = Math.Clamp(((int)y) * blurred.Stride + ((int)x) * 4, 0, blurred.Bgra.Length - 4);
            var br = blurred.Bgra[i + 2] / 255f;
            var bg = blurred.Bgra[i + 1] / 255f;
            var bb = blurred.Bgra[i] / 255f;
            return (
                r + (br - r) * mix,
                g + (bg - g) * mix,
                b + (bb - b) * mix);
        });
    }

    private static VideoFrame ApplyMotionBlur(VideoFrame frame, float radius, float angleDeg)
    {
        if (radius <= 0) return frame;
        var steps = Math.Clamp((int)Math.Round(radius), 1, 24);
        var rad = angleDeg * MathF.PI / 180f;
        var dx = MathF.Cos(rad);
        var dy = MathF.Sin(rad);
        var output = new byte[frame.Bgra.Length];
        var stride = frame.Stride;
        for (var y = 0; y < frame.Height; y++)
        for (var x = 0; x < frame.Width; x++)
        {
            float r = 0, g = 0, b = 0, a = 0;
            for (var s = -steps; s <= steps; s++)
            {
                var sx = (int)Math.Round(x + dx * s);
                var sy = (int)Math.Round(y + dy * s);
                sx = Math.Clamp(sx, 0, frame.Width - 1);
                sy = Math.Clamp(sy, 0, frame.Height - 1);
                var i = sy * stride + sx * 4;
                b += frame.Bgra[i];
                g += frame.Bgra[i + 1];
                r += frame.Bgra[i + 2];
                a += frame.Bgra[i + 3];
            }
            var n = steps * 2 + 1;
            var o = y * stride + x * 4;
            output[o] = (byte)(b / n);
            output[o + 1] = (byte)(g / n);
            output[o + 2] = (byte)(r / n);
            output[o + 3] = (byte)(a / n);
        }
        return new VideoFrame(output, frame.Width, frame.Height, stride);
    }

    private static (float H, float S, float V) RgbToHsv(float r, float g, float b)
    {
        var mx = Math.Max(r, Math.Max(g, b));
        var mn = Math.Min(r, Math.Min(g, b));
        var d = mx - mn;
        var h = 0f;
        if (d > 1e-6f)
        {
            if (mx == r) h = (g - b) / d + (g < b ? 6f : 0f);
            else if (mx == g) h = (b - r) / d + 2f;
            else h = (r - g) / d + 4f;
            h /= 6f;
        }
        var s = mx <= 1e-6f ? 0f : d / mx;
        return (h, s, mx);
    }

    private static (float R, float G, float B) HsvToRgb(float h, float s, float v)
    {
        var i = (int)Math.Floor(h * 6f);
        var f = h * 6f - i;
        var p = v * (1f - s);
        var q = v * (1f - f * s);
        var t = v * (1f - (1f - f) * s);
        return (i % 6) switch
        {
            0 => (v, t, p),
            1 => (q, v, p),
            2 => (p, v, t),
            3 => (p, q, v),
            4 => (t, p, v),
            _ => (v, p, q),
        };
    }

    private static VideoFrame ApplyLut(VideoFrame frame, ResolvedEffectParams p)
    {
        if (p.String("path") is not { Length: > 0 } path) return frame;
        if (LutLoader.Load(path) is not { } lut) return frame;
        var intensity = (float)p.Value("intensity");
        return MapRgb(frame, (r, g, b, _, _) => LutLoader.SampleTetra(lut, r, g, b, intensity));
    }

    private static VideoFrame ApplyGradeCurves(VideoFrame frame, ResolvedEffectParams p)
    {
        if (p.String("curve") is not { Length: > 0 } json) return frame;
        if (GradeCurve.FromJson(json) is not { } curve || curve.IsIdentity) return frame;

        // Bake 256-entry LUTs once per frame, matching Metal GradeCurves sampling.
        var master = new float[256];
        var red = new float[256];
        var green = new float[256];
        var blue = new float[256];
        for (var i = 0; i < 256; i++)
        {
            var x = i / 255.0;
            master[i] = (float)GradeCurve.Eval(curve.Master, x);
            red[i] = (float)GradeCurve.Eval(curve.Red, x);
            green[i] = (float)GradeCurve.Eval(curve.Green, x);
            blue[i] = (float)GradeCurve.Eval(curve.Blue, x);
        }

        return MapRgb(frame, (r, g, b, _, _) =>
        {
            var y = EffectPixelKernels.Luma(r, g, b);
            var yp = Sample1D(master, y);
            float nr = r, ng = g, nb = b;
            if (y > 1e-4f)
            {
                var gain = Math.Min(yp / y, 8f);
                nr *= gain; ng *= gain; nb *= gain;
            }
            else
            {
                nr = ng = nb = yp;
            }
            return (Sample1D(red, nr), Sample1D(green, ng), Sample1D(blue, nb));
        });
    }

    private static float Sample1D(float[] lut, float v)
    {
        var x = Math.Clamp(v, 0, 1) * 255f;
        var i0 = (int)Math.Floor(x);
        var i1 = Math.Min(255, i0 + 1);
        var t = x - i0;
        return lut[i0] + (lut[i1] - lut[i0]) * t;
    }

    private static VideoFrame ApplyEdgeRounding(VideoFrame frame, float rounding, float softness)
    {
        var output = new byte[frame.Bgra.Length];
        var stride = frame.Stride;
        for (var y = 0; y < frame.Height; y++)
        for (var x = 0; x < frame.Width; x++)
        {
            var i = y * stride + x * 4;
            var coverage = EffectPixelKernels.EdgeRoundingCoverage(
                x + 0.5f, y + 0.5f, frame.Width, frame.Height, rounding, softness);
            output[i] = frame.Bgra[i];
            output[i + 1] = frame.Bgra[i + 1];
            output[i + 2] = frame.Bgra[i + 2];
            output[i + 3] = (byte)Math.Clamp(frame.Bgra[i + 3] * coverage, 0, 255);
        }
        return new VideoFrame(output, frame.Width, frame.Height, stride);
    }

    private delegate (float R, float G, float B) RgbMap(float r, float g, float b, float x, float y);
    private delegate (float R, float G, float B, float A) RgbaMap(
        float r, float g, float b, float a, float x, float y);

    private static VideoFrame MapRgb(VideoFrame frame, RgbMap map)
    {
        var output = new byte[frame.Bgra.Length];
        var stride = frame.Stride;
        for (var y = 0; y < frame.Height; y++)
        for (var x = 0; x < frame.Width; x++)
        {
            var i = y * stride + x * 4;
            var b = frame.Bgra[i] / 255f;
            var g = frame.Bgra[i + 1] / 255f;
            var r = frame.Bgra[i + 2] / 255f;
            var (nr, ng, nb) = map(r, g, b, x + 0.5f, y + 0.5f);
            output[i] = ToByte(nb);
            output[i + 1] = ToByte(ng);
            output[i + 2] = ToByte(nr);
            output[i + 3] = frame.Bgra[i + 3];
        }
        return new VideoFrame(output, frame.Width, frame.Height, stride);
    }

    private static VideoFrame MapRgba(VideoFrame frame, RgbaMap map)
    {
        var output = new byte[frame.Bgra.Length];
        var stride = frame.Stride;
        for (var y = 0; y < frame.Height; y++)
        for (var x = 0; x < frame.Width; x++)
        {
            var i = y * stride + x * 4;
            var b = frame.Bgra[i] / 255f;
            var g = frame.Bgra[i + 1] / 255f;
            var r = frame.Bgra[i + 2] / 255f;
            var a = frame.Bgra[i + 3] / 255f;
            var (nr, ng, nb, na) = map(r, g, b, a, x + 0.5f, y + 0.5f);
            output[i] = ToByte(nb);
            output[i + 1] = ToByte(ng);
            output[i + 2] = ToByte(nr);
            output[i + 3] = ToByte(na);
        }
        return new VideoFrame(output, frame.Width, frame.Height, stride);
    }

    private static VideoFrame BoxBlur(VideoFrame frame, float radius)
    {
        if (radius <= 0) return frame;
        var r = Math.Clamp((int)Math.Round(radius), 1, 64);
        var temp = HorizontalBox(frame, r);
        return VerticalBox(temp, r);
    }

    private static VideoFrame HorizontalBox(VideoFrame frame, int radius)
    {
        var output = new byte[frame.Bgra.Length];
        var stride = frame.Stride;
        var width = frame.Width;
        for (var y = 0; y < frame.Height; y++)
        {
            for (var c = 0; c < 4; c++)
            {
                var sum = 0;
                for (var k = -radius; k <= radius; k++)
                    sum += frame.Bgra[y * stride + Clamp(k, 0, width - 1) * 4 + c];
                var count = radius * 2 + 1;
                for (var x = 0; x < width; x++)
                {
                    output[y * stride + x * 4 + c] = (byte)(sum / count);
                    var leave = Clamp(x - radius, 0, width - 1);
                    var enter = Clamp(x + radius + 1, 0, width - 1);
                    sum += frame.Bgra[y * stride + enter * 4 + c] - frame.Bgra[y * stride + leave * 4 + c];
                }
            }
        }
        return new VideoFrame(output, frame.Width, frame.Height, stride);
    }

    private static VideoFrame VerticalBox(VideoFrame frame, int radius)
    {
        var output = new byte[frame.Bgra.Length];
        var stride = frame.Stride;
        var height = frame.Height;
        for (var x = 0; x < frame.Width; x++)
        {
            for (var c = 0; c < 4; c++)
            {
                var sum = 0;
                for (var k = -radius; k <= radius; k++)
                    sum += frame.Bgra[Clamp(k, 0, height - 1) * stride + x * 4 + c];
                var count = radius * 2 + 1;
                for (var y = 0; y < height; y++)
                {
                    output[y * stride + x * 4 + c] = (byte)(sum / count);
                    var leave = Clamp(y - radius, 0, height - 1);
                    var enter = Clamp(y + radius + 1, 0, height - 1);
                    sum += frame.Bgra[enter * stride + x * 4 + c] - frame.Bgra[leave * stride + x * 4 + c];
                }
            }
        }
        return new VideoFrame(output, frame.Width, frame.Height, stride);
    }

    private static VideoFrame ApplyGlow(VideoFrame frame, ResolvedEffectParams p)
    {
        var intensity = (float)p.Value("intensity");
        if (intensity <= 0) return frame;
        var threshold = (float)p.Value("threshold");
        var warmth = (float)p.Value("warmth");
        var radius = (float)p.Value("radius");

        var bright = MapRgb(frame, (r, g, b, _, _) =>
        {
            var y = EffectPixelKernels.Luma(r, g, b);
            var mask = EffectPixelKernels.Smoothstep(threshold, 1f, y);
            var hr = r * mask;
            var hg = g * mask;
            var hb = b * mask;
            return (
                hr + (hr * 1f - hr) * warmth,
                hg + (hg * 0.7f - hg) * warmth,
                hb + (hb * 0.45f - hb) * warmth);
        });
        var blurred = BoxBlur(bright, radius);
        return MapRgb(frame, (r, g, b, x, y) =>
        {
            var i = ((int)y) * blurred.Stride + ((int)x) * 4;
            i = Math.Clamp(i, 0, blurred.Bgra.Length - 4);
            var gr = blurred.Bgra[i + 2] / 255f * intensity;
            var gg = blurred.Bgra[i + 1] / 255f * intensity;
            var gb = blurred.Bgra[i] / 255f * intensity;
            return (
                1f - (1f - r) * (1f - Math.Clamp(gr, 0, 1)),
                1f - (1f - g) * (1f - Math.Clamp(gg, 0, 1)),
                1f - (1f - b) * (1f - Math.Clamp(gb, 0, 1)));
        });
    }

    private static VideoFrame ApplyClarity(VideoFrame frame, ResolvedEffectParams p)
    {
        var clarity = (float)p.Value("clarity");
        var dehaze = (float)p.Value("dehaze");
        if (clarity == 0 && dehaze == 0) return frame;
        var blurred = BoxBlur(frame, 8);
        return MapRgb(frame, (r, g, b, x, y) =>
        {
            var i = Math.Clamp(((int)y) * blurred.Stride + ((int)x) * 4, 0, blurred.Bgra.Length - 4);
            var br = blurred.Bgra[i + 2] / 255f;
            var bg = blurred.Bgra[i + 1] / 255f;
            var bb = blurred.Bgra[i] / 255f;
            var nr = r + (r - br) * clarity;
            var ng = g + (g - bg) * clarity;
            var nb = b + (b - bb) * clarity;
            if (dehaze != 0)
            {
                var dark = Math.Min(r, Math.Min(g, b));
                var w = dehaze * (0.5f + 0.5f * EffectPixelKernels.Smoothstep(0.05f, 0.5f, dark));
                nr += (r - br) * (w * 0.6f);
                ng += (g - bg) * (w * 0.6f);
                nb += (b - bb) * (w * 0.6f);
                nr = 0.45f + (nr - 0.45f) * (1f + w * 0.45f);
                ng = 0.45f + (ng - 0.45f) * (1f + w * 0.45f);
                nb = 0.45f + (nb - 0.45f) * (1f + w * 0.45f);
                var yL = EffectPixelKernels.Luma(nr, ng, nb);
                nr = yL + (nr - yL) * (1f + w * 0.5f);
                ng = yL + (ng - yL) * (1f + w * 0.5f);
                nb = yL + (nb - yL) * (1f + w * 0.5f);
            }
            return (
                EffectPixelKernels.Saturate(nr),
                EffectPixelKernels.Saturate(ng),
                EffectPixelKernels.Saturate(nb));
        });
    }

    private static VideoFrame ApplySharpen(VideoFrame frame, float amount)
    {
        if (amount <= 0) return frame;
        var blurred = BoxBlur(frame, 1);
        return MapRgb(frame, (r, g, b, x, y) =>
        {
            var i = Math.Clamp(((int)y) * blurred.Stride + ((int)x) * 4, 0, blurred.Bgra.Length - 4);
            var br = blurred.Bgra[i + 2] / 255f;
            var bg = blurred.Bgra[i + 1] / 255f;
            var bb = blurred.Bgra[i] / 255f;
            return (
                EffectPixelKernels.Saturate(r + (r - br) * amount),
                EffectPixelKernels.Saturate(g + (g - bg) * amount),
                EffectPixelKernels.Saturate(b + (b - bb) * amount));
        });
    }

    private static byte ToByte(float v) => (byte)Math.Clamp((int)Math.Round(v * 255f), 0, 255);
    private static int Clamp(int v, int min, int max) => v < min ? min : v > max ? max : v;
}
