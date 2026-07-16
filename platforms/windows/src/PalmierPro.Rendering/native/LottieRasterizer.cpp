#include "LottieRasterizer.h"

#include <thorvg.h>
#include <thorvg_lottie.h>

#include <algorithm>

// Animation::Impl (third_party\thorvg\src\renderer\tvgAnimation.h) ref()s the picture it gen()s
// and unref()s it in its own dtor; Canvas::add() takes an independent ref released on remove/
// canvas dtor (thorvg.h's Canvas::add doc). Destroying the canvas before the animation is the
// order that keeps the picture alive across both releases without a double-free.
struct LottieRasterizer::Impl
{
    tvg::Animation* animation = nullptr;
    tvg::Picture* picture = nullptr;
    tvg::SwCanvas* canvas = nullptr;
    float nativeWidth = 0.0f;
    float nativeHeight = 0.0f;
    bool initialized = false;
};

LottieRasterizer::LottieRasterizer() : impl_(std::make_unique<Impl>())
{
}

LottieRasterizer::~LottieRasterizer()
{
    Close();
}

bool LottieRasterizer::Open(const char* utf8Path)
{
    Close();
    if (!utf8Path || !*utf8Path) return false;

    // Reference-counted (thorvg.h's Initializer::init doc) — safe for independent
    // LottieRasterizer instances to bracket their own Open/Close pairs. 0 worker threads: a
    // single synchronous bake at a time needs no internal thread pool (mirrors the Mac's
    // single-threaded CGContext bake path).
    if (tvg::Initializer::init(0) != tvg::Result::Success) return false;
    impl_->initialized = true;

    impl_->animation = tvg::Animation::gen();
    if (!impl_->animation)
    {
        Close();
        return false;
    }

    impl_->picture = impl_->animation->picture();
    if (!impl_->picture || impl_->picture->load(utf8Path) != tvg::Result::Success)
    {
        Close();
        return false;
    }

    float w = 0.0f, h = 0.0f;
    impl_->picture->size(&w, &h);
    impl_->nativeWidth = w;
    impl_->nativeHeight = h;

    impl_->canvas = tvg::SwCanvas::gen();
    if (!impl_->canvas || impl_->canvas->add(impl_->picture) != tvg::Result::Success)
    {
        Close();
        return false;
    }

    return true;
}

void LottieRasterizer::Close()
{
    delete impl_->canvas;
    impl_->canvas = nullptr;
    delete impl_->animation;
    impl_->animation = nullptr;
    impl_->picture = nullptr;
    impl_->nativeWidth = 0.0f;
    impl_->nativeHeight = 0.0f;
    if (impl_->initialized)
    {
        tvg::Initializer::term();
        impl_->initialized = false;
    }
}

bool LottieRasterizer::IsOpen() const
{
    return impl_->initialized && impl_->animation && impl_->picture && impl_->canvas;
}

int32_t LottieRasterizer::NativeWidth() const
{
    return IsOpen() ? static_cast<int32_t>(impl_->nativeWidth) : 0;
}

int32_t LottieRasterizer::NativeHeight() const
{
    return IsOpen() ? static_cast<int32_t>(impl_->nativeHeight) : 0;
}

int32_t LottieRasterizer::FrameCount() const
{
    if (!IsOpen()) return 0;
    // max(1, ...) mirrors LottieVideoGenerator.metadata(for:)'s own floor (LottieVideoGenerator.swift:56).
    return std::max(1, static_cast<int32_t>(impl_->animation->totalFrame() + 0.5f));
}

double LottieRasterizer::DurationSeconds() const
{
    return IsOpen() ? static_cast<double>(impl_->animation->duration()) : 0.0;
}

double LottieRasterizer::FrameRate() const
{
    if (!IsOpen()) return 0.0;
    double duration = static_cast<double>(impl_->animation->duration());
    if (duration <= 0.0) return 0.0;
    return static_cast<double>(impl_->animation->totalFrame()) / duration;
}

bool LottieRasterizer::RasterizeFrame(int32_t frameIndex, int32_t width, int32_t height, uint8_t* bgra, int32_t strideBytes)
{
    if (!IsOpen() || !bgra || width <= 0 || height <= 0) return false;
    if (strideBytes < width * 4 || strideBytes % 4 != 0) return false;

    frameIndex = std::clamp(frameIndex, 0, FrameCount() - 1);

    // Aspect-fit box (ThorVG's own Picture::size semantics); frame() legitimately reports
    // InsufficientCondition when frameIndex equals the already-current frame (thorvg.h's
    // Animation::frame doc) — that's a no-op, not a failure, so its result isn't gated on here.
    impl_->picture->size(static_cast<float>(width), static_cast<float>(height));
    impl_->animation->frame(static_cast<float>(frameIndex));

    auto* pixels = reinterpret_cast<uint32_t*>(bgra);
    auto stridePixels = static_cast<uint32_t>(strideBytes / 4);
    if (impl_->canvas->target(pixels, stridePixels, static_cast<uint32_t>(width), static_cast<uint32_t>(height), tvg::ColorSpace::ARGB8888) != tvg::Result::Success)
    {
        return false;
    }

    impl_->canvas->update();
    if (impl_->canvas->draw(true) != tvg::Result::Success) return false;
    if (impl_->canvas->sync() != tvg::Result::Success) return false;

    return true;
}

int32_t PE_LottieRasterizerSmokeTest(
    const char* utf8LottiePath,
    int32_t width,
    int32_t height,
    uint8_t* outFrame0Bgra,
    uint8_t* outLastFrameBgra,
    int32_t* outFrameCount,
    double* outFrameRate,
    double* outDurationSeconds)
{
    if (!utf8LottiePath || !*utf8LottiePath || width <= 0 || height <= 0 || !outFrame0Bgra || !outLastFrameBgra)
    {
        return PE_ERROR_INVALID_ARGUMENT;
    }

    LottieRasterizer rasterizer;
    if (!rasterizer.Open(utf8LottiePath)) return PE_ERROR_FILE_OPEN_FAILED;

    const int32_t frameCount = rasterizer.FrameCount();
    const double frameRate = rasterizer.FrameRate();
    const double duration = rasterizer.DurationSeconds();
    const int32_t strideBytes = width * 4;

    if (!rasterizer.RasterizeFrame(0, width, height, outFrame0Bgra, strideBytes)) return PE_ERROR_DECODE_FAILED;
    if (!rasterizer.RasterizeFrame(frameCount - 1, width, height, outLastFrameBgra, strideBytes)) return PE_ERROR_DECODE_FAILED;

    if (outFrameCount) *outFrameCount = frameCount;
    if (outFrameRate) *outFrameRate = frameRate;
    if (outDurationSeconds) *outDurationSeconds = duration;

    return PE_OK;
}
