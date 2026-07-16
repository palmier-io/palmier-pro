#pragma once

#include "include/palmier_engine.h"

#include <cstdint>
#include <memory>

// docs/lottie-bake-v1.md §16 "vendor" slice — the ThorVG-facing rasterization primitive the
// future "bake" slice's native/LottieBaker.cpp composes with AlphaVideoEncoder to implement
// PE_BakeLottieVideo/PE_ProbeLottieMetadata (both still declaration-only in palmier_engine.h).
// This class owns exactly one thing: turning a plain-JSON Lottie composition into premultiplied
// BGRA32 frames. Per doc §12, native only ever opens a plain .json path — a .lottie (dotLottie
// zip) source is unzipped C#-side before this is ever reached.
class LottieRasterizer
{
public:
    LottieRasterizer();
    ~LottieRasterizer();

    LottieRasterizer(const LottieRasterizer&) = delete;
    LottieRasterizer& operator=(const LottieRasterizer&) = delete;

    // Opens a plain-JSON Lottie composition (.json path — ThorVG's own extension sniff also
    // accepts .lot). Returns false if the path doesn't exist or ThorVG can't parse it as Lottie.
    bool Open(const char* utf8Path);
    void Close();
    bool IsOpen() const;

    // Native composition size (the authored "w"/"h", before any target-size rescale).
    int32_t NativeWidth() const;
    int32_t NativeHeight() const;

    // Frame count is always >= 1; frame rate is totalFrame() / duration(), 0 if duration is 0
    // (mirrors LottieVideoGenerator.metadata(for:), LottieVideoGenerator.swift:52-58).
    int32_t FrameCount() const;
    double FrameRate() const;
    double DurationSeconds() const;

    // Rasterizes frame `frameIndex` (clamped to [0, FrameCount()-1]) into `bgra`, a caller-owned
    // buffer of at least `strideBytes` * height bytes. The composition is aspect-fit into
    // width x height (ThorVG's own Picture::size() box-fit — an anisotropic stretch-to-fill
    // matching the Mac's .scaleToFill is a bake-level concern, not reproduced here). Output is
    // premultiplied BGRA32 on this little-endian target (tvg::ColorSpace::ARGB8888 — doc §7).
    // `strideBytes` must be a multiple of 4 (ThorVG's target() stride is pixel-granular).
    bool RasterizeFrame(int32_t frameIndex, int32_t width, int32_t height, uint8_t* bgra, int32_t strideBytes);

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

// Test-only smoke hook (native/LottieRasterizer.cpp), not part of the docs/lottie-bake-v1.md
// contract ABI — mirrors PE_AudioEngineSmokeTest/PE_RetimeStretcher's own precedent of exercising
// an infra-slice class directly, ahead of the orchestration entry point (PE_BakeLottieVideo) that
// composes it with AlphaVideoEncoder. Rasterizes frame 0 and the last frame of utf8LottiePath at
// width x height into caller-allocated outFrame0Bgra/outLastFrameBgra (each width * height * 4
// bytes, tightly packed). Returns 0 on success.
PALMIER_API int32_t PE_LottieRasterizerSmokeTest(
    const char* utf8LottiePath,
    int32_t width,
    int32_t height,
    uint8_t* outFrame0Bgra,
    uint8_t* outLastFrameBgra,
    int32_t* outFrameCount,
    double* outFrameRate,
    double* outDurationSeconds);
