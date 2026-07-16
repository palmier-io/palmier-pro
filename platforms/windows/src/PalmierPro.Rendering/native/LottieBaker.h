#pragma once

#include "include/palmier_engine.h"

// docs/lottie-bake-v1.md §16 "bake" slice — composes LottieRasterizer (vendor slice, ThorVG) with
// AlphaVideoEncoder (encode slice, prores_ks 4444) into the one-call PE_BakeLottieVideo/
// PE_ProbeLottieMetadata orchestration entry points declared in include/palmier_engine.h. Defined
// directly here (not routed through PalmierEngine.cpp) since neither call needs a handle registry —
// PE_BakeLottieVideo is a single synchronous call, no persistent object outlives it, mirroring how
// PE_LottieRasterizerSmokeTest is exported directly from LottieRasterizer.cpp.
//
// PE_RenderLottieThumbnail is an additive, small ABI addition beyond docs/lottie-bake-v1.md's own
// frozen contract (that doc names a media-panel Lottie thumbnail an explicit, scoped-out v1 follow-up
// in its §11) — added here to back MediaVisualCache's Lottie filmstrip-tile need via the same vendored
// ThorVG rasterizer, without a disk-cached bake. Rasterizes the animation's first frame only.
PALMIER_API int32_t PE_RenderLottieThumbnail(const char* utf8LottiePath, int32_t width, int32_t height, uint8_t* outBgra, int32_t strideBytes);
