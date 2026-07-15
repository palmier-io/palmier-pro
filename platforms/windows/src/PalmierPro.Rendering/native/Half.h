#pragma once

#include <cstdint>
#include <cstring>

// Minimal IEEE-754 binary16 <-> float32 conversion (round-to-nearest-even). Used for
// the compositor's internal working buffer — see Compositor.h's header comment for why
// fp16 is the canonical working precision (plan's "Color pipeline" section: gamma-encoded,
// premultiplied, fp16 for headroom — not a linear-light pipeline).
using Half = uint16_t;

inline float HalfToFloat(Half h)
{
    uint32_t sign = static_cast<uint32_t>(h & 0x8000u) << 16;
    uint32_t exp = (h >> 10) & 0x1Fu;
    uint32_t mant = h & 0x3FFu;
    uint32_t bits;

    if (exp == 0)
    {
        if (mant == 0)
        {
            bits = sign;
        }
        else
        {
            int shift = 0;
            while ((mant & 0x400u) == 0)
            {
                mant <<= 1;
                ++shift;
            }
            mant &= 0x3FFu;
            uint32_t fexp = static_cast<uint32_t>(127 - 15 - shift);
            bits = sign | (fexp << 23) | (mant << 13);
        }
    }
    else if (exp == 0x1Fu)
    {
        bits = sign | 0x7F800000u | (mant << 13);
    }
    else
    {
        uint32_t fexp = exp - 15u + 127u;
        bits = sign | (fexp << 23) | (mant << 13);
    }

    float f;
    std::memcpy(&f, &bits, sizeof(f));
    return f;
}

inline Half FloatToHalf(float f)
{
    uint32_t bits;
    std::memcpy(&bits, &f, sizeof(bits));
    uint32_t sign = (bits >> 16) & 0x8000u;
    uint32_t rawExp = (bits >> 23) & 0xFFu;
    uint32_t mant = bits & 0x7FFFFFu;

    if (rawExp == 0xFFu)
    {
        // inf / nan
        return static_cast<Half>(sign | 0x7C00u | (mant ? 0x200u : 0u));
    }

    int32_t exp = static_cast<int32_t>(rawExp) - 127 + 15;

    if (exp >= 0x1F)
    {
        return static_cast<Half>(sign | 0x7C00u); // overflow -> inf
    }

    if (exp <= 0)
    {
        if (exp < -10)
        {
            return static_cast<Half>(sign); // too small -> signed zero
        }
        mant |= 0x800000u;
        int shift = 14 - exp;
        uint32_t halfMant = mant >> shift;
        uint32_t remainder = mant & ((1u << shift) - 1u);
        uint32_t halfway = 1u << (shift - 1);
        if (remainder > halfway || (remainder == halfway && (halfMant & 1u)))
        {
            ++halfMant;
        }
        return static_cast<Half>(sign | halfMant);
    }

    uint32_t halfMant = mant >> 13;
    uint32_t remainder = mant & 0x1FFFu;
    if (remainder > 0x1000u || (remainder == 0x1000u && (halfMant & 1u)))
    {
        ++halfMant;
        if (halfMant == 0x400u)
        {
            halfMant = 0;
            ++exp;
            if (exp >= 0x1F)
            {
                return static_cast<Half>(sign | 0x7C00u);
            }
        }
    }
    return static_cast<Half>(sign | (static_cast<uint32_t>(exp) << 10) | halfMant);
}

// Shared by Compositor.cpp (CPU path) and GpuCompositor.cpp (GPU readback) so the final
// fp16 -> 8-bit narrowing is bit-identical on both paths — same round-to-nearest convention.
inline uint8_t HalfChannelTo8Bit(Half h)
{
    float f = HalfToFloat(h) * 255.0f;
    if (f < 0.0f) f = 0.0f;
    if (f > 255.0f) f = 255.0f;
    return static_cast<uint8_t>(f + 0.5f);
}
