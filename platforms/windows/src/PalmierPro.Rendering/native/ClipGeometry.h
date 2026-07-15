#pragma once

#include "Affine2D.h"
#include "TimelineSnapshot.h"

// Clip placement math shared verbatim by the CPU compositor (Compositor.cpp) and the GPU
// compositor (GpuCompositor.cpp) — extracted so both paths are guaranteed to place/crop a clip
// identically; only the per-pixel sampling/blend differs (CPU: manual bilinear + fp16
// accumulate; GPU: the same matrix fed into Composite.hlsl). See Compositor.h's header comment
// for the full derivation/rationale.

struct CropRectPixels
{
    double x0, y0, x1, y1;
};

// Mirrors CompositionBuilder.affineTransform(for:natSize:renderSize:) exactly —
// Sources/PalmierPro/Preview/CompositionBuilder.swift:911-926. See Compositor.cpp's original
// header comment (preserved there) for the full y-down-coordinate-space derivation.
inline Affine2D BuildClipAffine(const SnapshotTransform& t, double natWidth, double natHeight,
    double renderWidth, double renderHeight)
{
    double tlX = t.centerX - t.width / 2.0;
    double tlY = t.centerY - t.height / 2.0;

    double sx = (renderWidth / natWidth) * t.width * (t.flipHorizontal ? -1.0 : 1.0);
    double sy = (renderHeight / natHeight) * t.height * (t.flipVertical ? -1.0 : 1.0);
    double tx = (t.flipHorizontal ? tlX + t.width : tlX) * renderWidth;
    double ty = (t.flipVertical ? tlY + t.height : tlY) * renderHeight;

    Affine2D placed = Affine2D::Scale(sx, sy).Concatenate(Affine2D::Translation(tx, ty));
    if (t.rotationDegrees == 0.0)
    {
        return placed;
    }
    double cx = t.centerX * renderWidth;
    double cy = t.centerY * renderHeight;
    return placed
        .Concatenate(Affine2D::Translation(-cx, -cy))
        .Concatenate(Affine2D::RotationDegrees(t.rotationDegrees))
        .Concatenate(Affine2D::Translation(cx, cy));
}

inline CropRectPixels ResolveCropRect(const SnapshotCrop& crop, double natWidth, double natHeight)
{
    double x0 = crop.left * natWidth;
    double y0 = crop.top * natHeight;
    double w = (crop.VisibleWidthFraction() * natWidth) < 1.0 ? 1.0 : (crop.VisibleWidthFraction() * natWidth);
    double h = (crop.VisibleHeightFraction() * natHeight) < 1.0 ? 1.0 : (crop.VisibleHeightFraction() * natHeight);
    return CropRectPixels{x0, y0, x0 + w, y0 + h};
}
