#pragma once

#include <cstdint>
#include <string>

// Direct CPU-buffer -> PNG encode via WIC. Deliberately D3D-free: PE_RenderFrameToFile
// (the CI-facing golden hook) must work on any runner regardless of GPU/WARP
// availability, so this never touches the D3D11 presenter.
namespace WicPngWriter
{
    bool WriteBgraToPng(const uint8_t* bgra, int32_t width, int32_t height, int32_t strideBytes,
        const std::string& utf8Path, std::string& outError);
}
