#include "Compositor.h"
#include "Affine2D.h"
#include "ClipGeometry.h"
#include "Half.h"

#include <algorithm>
#include <cmath>

// BuildClipAffine/ResolveCropRect/CropRectPixels moved to ClipGeometry.h (shared verbatim with
// GpuCompositor.cpp — see that header's comment) — no behavior change, same math.

namespace
{
    struct Vec4 { float b = 0, g = 0, r = 0, a = 0; };

    // Straight-alpha bilinear sample of an 8-bit BGRA source, hard-clipped to cropRect
    // (fully transparent outside it — matches CIImage.cropped(to:)'s hard edge; no
    // coverage-based edge antialiasing in this pass). Sample taps within one texel of a
    // crop edge are still clamped to the *image* bounds rather than the crop bounds, a
    // minor documented simplification (a sub-pixel sliver at a crop edge can read one
    // texel of otherwise-cropped-away source data).
    Vec4 SampleBilinearStraight(const DecodedSourceFrame& src, const CropRectPixels& cropRect, double sx, double sy)
    {
        if (sx < cropRect.x0 || sx >= cropRect.x1 || sy < cropRect.y0 || sy >= cropRect.y1)
        {
            return Vec4{};
        }
        if (sx < 0 || sy < 0 || sx >= src.width || sy >= src.height)
        {
            return Vec4{};
        }

        double fx = sx - 0.5;
        double fy = sy - 0.5;
        int x0 = static_cast<int>(std::floor(fx));
        int y0 = static_cast<int>(std::floor(fy));
        double tx = fx - x0;
        double ty = fy - y0;
        int x1 = x0 + 1;
        int y1 = y0 + 1;

        auto clampX = [&](int x) { return std::max(0, std::min(src.width - 1, x)); };
        auto clampY = [&](int y) { return std::max(0, std::min(src.height - 1, y)); };
        auto texel = [&](int x, int y) -> Vec4 {
            x = clampX(x);
            y = clampY(y);
            const uint8_t* p = src.bgra + static_cast<size_t>(y) * src.strideBytes + static_cast<size_t>(x) * 4;
            return Vec4{p[0] / 255.0f, p[1] / 255.0f, p[2] / 255.0f, p[3] / 255.0f};
        };

        Vec4 c00 = texel(x0, y0), c10 = texel(x1, y0), c01 = texel(x0, y1), c11 = texel(x1, y1);
        auto lerp = [](float a, float b, double t) { return static_cast<float>(a + (b - a) * t); };
        Vec4 top{lerp(c00.b, c10.b, tx), lerp(c00.g, c10.g, tx), lerp(c00.r, c10.r, tx), lerp(c00.a, c10.a, tx)};
        Vec4 bot{lerp(c01.b, c11.b, tx), lerp(c01.g, c11.g, tx), lerp(c01.r, c11.r, tx), lerp(c01.a, c11.a, tx)};
        return Vec4{lerp(top.b, bot.b, ty), lerp(top.g, bot.g, ty), lerp(top.r, bot.r, ty), lerp(top.a, bot.a, ty)};
    }

    struct PixelBounds { int x0, y0, x1, y1; };

    // AABB, in destination pixels, of the transformed crop rect, clamped to the canvas.
    PixelBounds DestinationBounds(const Affine2D& forward, const CropRectPixels& cropRect, int32_t canvasW, int32_t canvasH)
    {
        double xs[4], ys[4];
        forward.Apply(cropRect.x0, cropRect.y0, xs[0], ys[0]);
        forward.Apply(cropRect.x1, cropRect.y0, xs[1], ys[1]);
        forward.Apply(cropRect.x0, cropRect.y1, xs[2], ys[2]);
        forward.Apply(cropRect.x1, cropRect.y1, xs[3], ys[3]);

        double minX = xs[0], maxX = xs[0], minY = ys[0], maxY = ys[0];
        for (int i = 1; i < 4; ++i)
        {
            minX = std::min(minX, xs[i]); maxX = std::max(maxX, xs[i]);
            minY = std::min(minY, ys[i]); maxY = std::max(maxY, ys[i]);
        }

        int x0 = std::max(0, static_cast<int>(std::floor(minX)));
        int y0 = std::max(0, static_cast<int>(std::floor(minY)));
        int x1 = std::min(canvasW, static_cast<int>(std::ceil(maxX)));
        int y1 = std::min(canvasH, static_cast<int>(std::ceil(maxY)));
        return PixelBounds{x0, y0, x1, y1};
    }

    void SourceOverAccumulate(std::vector<Half>& accum, int32_t canvasW, int dx, int dy, const Vec4& straight, double clipAlpha)
    {
        // Mirrors FrameRenderer.applyClipPipeline exactly: premultiply RGB by the source's OWN
        // (straight) alpha only, then fade ONLY the alpha channel by the clip's opacity — leaving
        // premultiplied RGB at full strength. This is what CIColorMatrix(inputAVector:
        // (0,0,0,alpha)) does to an already-premultiplied CIImage on the Mac (FrameRenderer.swift
        // ~264-271); it is NOT the conventional "scale both RGB and alpha by opacity" premultiplied
        // fade. See Compositor.h's header comment.
        float srcA = static_cast<float>(straight.a * clipAlpha);
        float srcB = straight.b * straight.a;
        float srcG = straight.g * straight.a;
        float srcR = straight.r * straight.a;

        size_t idx = (static_cast<size_t>(dy) * canvasW + dx) * 4;
        float dstB = HalfToFloat(accum[idx + 0]);
        float dstG = HalfToFloat(accum[idx + 1]);
        float dstR = HalfToFloat(accum[idx + 2]);
        float dstA = HalfToFloat(accum[idx + 3]);

        float invSrcA = 1.0f - srcA;
        accum[idx + 0] = FloatToHalf(srcB + dstB * invSrcA);
        accum[idx + 1] = FloatToHalf(srcG + dstG * invSrcA);
        accum[idx + 2] = FloatToHalf(srcR + dstR * invSrcA);
        accum[idx + 3] = FloatToHalf(srcA + dstA * invSrcA);
    }
}

double Compositor::SourceSeconds(const SnapshotClip& clip, int64_t timelineFrame, double timelineFps)
{
    double sourceFrameUnits = static_cast<double>(clip.trimStartFrame) +
        static_cast<double>(timelineFrame - clip.startFrame) * clip.speed;
    return timelineFps > 0.0 ? sourceFrameUnits / timelineFps : 0.0;
}

bool Compositor::Compose(
    const TimelineSnapshot& snapshot,
    int64_t frame,
    const ClipFrameProvider& provider,
    const std::atomic<int32_t>* cancelFlag,
    ComposeResult& outResult,
    std::string& outError)
{
    int32_t w = std::max(1, snapshot.outputWidth);
    int32_t h = std::max(1, snapshot.outputHeight);
    double timelineFps = snapshot.Fps();

    // Opaque black base — mirrors FrameRenderer.render's `CIImage(color: .black)`
    // starting accumulator exactly, so an area with no covering clip renders black, not
    // transparent.
    std::vector<Half> accum(static_cast<size_t>(w) * h * 4);
    Half zero = FloatToHalf(0.0f);
    Half one = FloatToHalf(1.0f);
    for (size_t i = 0; i < accum.size(); i += 4)
    {
        accum[i + 0] = zero;
        accum[i + 1] = zero;
        accum[i + 2] = zero;
        accum[i + 3] = one;
    }

    // tracks[] is already paint-order (index 0 = bottom, last = top) — see
    // docs/timeline-snapshot-v1.md §2. Walk forward, no reversal.
    for (const SnapshotTrack& track : snapshot.tracks)
    {
        if (track.type != SnapshotTrackType::Video)
        {
            continue; // audio tracks contribute nothing to the video compositor
        }
        if (cancelFlag && cancelFlag->load(std::memory_order_relaxed) != 0)
        {
            outError = "cancelled";
            return false;
        }

        const SnapshotClip* active = nullptr;
        for (const SnapshotClip& clip : track.clips)
        {
            if (clip.ContainsFrame(frame))
            {
                active = &clip;
                break;
            }
        }
        if (!active || active->type == SnapshotClipType::Audio)
        {
            continue;
        }

        double alpha = std::min(1.0, std::max(0.0, active->opacity));
        if (alpha <= 0.0)
        {
            continue;
        }

        // E3 dispatch seam: only "normal" (blendMode null/"normal") is implemented in
        // this pass. Any other BlendMode value still composites as normal source-over
        // rather than being dropped or crashing — see Compositor.h's header comment.
        // TODO(E3): route through the HLSL Porter-Duff/PDF set from the plan's Render
        // graph section once the render graph itself lands.
        (void)active->IsNormalBlend();

        double sourceSeconds = active->type == SnapshotClipType::Image
            ? 0.0
            : SourceSeconds(*active, frame, timelineFps);

        DecodedSourceFrame decoded{};
        if (!provider(*active, sourceSeconds, decoded) || !decoded.bgra || decoded.width <= 0 || decoded.height <= 0)
        {
            continue; // unreadable clip this frame — skip it, don't blank the composite
        }

        double natW = decoded.width;
        double natH = decoded.height;
        CropRectPixels cropRect = ResolveCropRect(active->crop, natW, natH);
        Affine2D forward = BuildClipAffine(active->transform, natW, natH, w, h);
        Affine2D inverse = forward.Inverted();

        PixelBounds bounds = DestinationBounds(forward, cropRect, w, h);
        if (bounds.x1 <= bounds.x0 || bounds.y1 <= bounds.y0)
        {
            continue;
        }

        for (int dy = bounds.y0; dy < bounds.y1; ++dy)
        {
            if (cancelFlag && cancelFlag->load(std::memory_order_relaxed) != 0)
            {
                outError = "cancelled";
                return false;
            }
            for (int dx = bounds.x0; dx < bounds.x1; ++dx)
            {
                double sx, sy;
                inverse.Apply(dx + 0.5, dy + 0.5, sx, sy);
                Vec4 sample = SampleBilinearStraight(decoded, cropRect, sx, sy);
                if (sample.a <= 0.0f)
                {
                    continue;
                }
                SourceOverAccumulate(accum, w, dx, dy, sample, alpha);
            }
        }
    }

    ComposeResult result;
    result.width = w;
    result.height = h;
    result.strideBytes = w * 4;
    result.bgra.resize(static_cast<size_t>(result.strideBytes) * h);
    for (int y = 0; y < h; ++y)
    {
        uint8_t* row = result.bgra.data() + static_cast<size_t>(y) * result.strideBytes;
        for (int x = 0; x < w; ++x)
        {
            size_t idx = (static_cast<size_t>(y) * w + x) * 4;
            row[x * 4 + 0] = HalfChannelTo8Bit(accum[idx + 0]);
            row[x * 4 + 1] = HalfChannelTo8Bit(accum[idx + 1]);
            row[x * 4 + 2] = HalfChannelTo8Bit(accum[idx + 2]);
            row[x * 4 + 3] = HalfChannelTo8Bit(accum[idx + 3]);
        }
    }

    outResult = std::move(result);
    return true;
}
