#pragma once

#include <cstdint>
#include <string>
#include <vector>

// Decodes a static image file (PNG/JPEG/etc., whatever WIC's installed codecs cover) to
// straight-alpha BGRA8 once. Used for "image"-type clips — Compositor caches the result
// per mediaPath so a still image is decoded exactly once regardless of how many frames
// reference it (mirrors the "decode once, cache as static texture" requirement).
namespace WicImageReader
{
    bool ReadToBgra(const std::string& utf8Path, std::vector<uint8_t>& outBgra,
        int32_t& outWidth, int32_t& outHeight, std::string& outError);
}
