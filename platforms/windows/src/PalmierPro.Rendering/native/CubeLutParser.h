#pragma once

#include <string>
#include <vector>

// Native port of Sources/PalmierPro/Compositing/LUTLoader.swift's `.cube` text-format
// parser (TITLE/LUT_3D_SIZE/DOMAIN_MIN/DOMAIN_MAX + N^3 "r g b" data lines, R fastest —
// the standard Adobe/Iridas .cube ordering). LUT_1D_SIZE files are rejected (nullopt),
// matching LUTLoader.swift's `return nil` on that key. Data is packed R-fastest, RGBA
// float32, exactly like LUTLoader.CubeLUT.data, so LUTTetraShader's strip-texture upload
// (GpuCompositor.cpp) can consume it identically to the Swift CIImage(bitmapData:) wrap —
// see LUTTetra.hlsl's header comment for the one deliberate divergence (no CI-bottom-up
// row flip; D3D's texture V axis is already top-down, matching this buffer's row order).
namespace CubeLutParser
{
    struct CubeLut
    {
        int dimension = 0;
        std::vector<float> rgba; // dimension^3 * 4 floats, R-fastest
    };

    // Returns false (outLut untouched) on any malformed input — mirrors LUTLoader.parse's
    // `return nil` cases exactly (LUT_1D_SIZE present, missing/invalid LUT_3D_SIZE,
    // dimension out of (1, 128], data-line count mismatch, non-numeric triplet).
    bool Parse(const std::string& text, CubeLut& outLut);
    bool ParseFile(const std::string& path, CubeLut& outLut, std::string& outError);
}
