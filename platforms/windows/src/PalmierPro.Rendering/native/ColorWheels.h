#pragma once

#include <algorithm>
#include <cmath>

// Native port of Sources/PalmierPro/Compositing/ColorWheels.swift's `hueRGB`/`chromaOffset`/
// `coefficients` — the lift/gamma/gain wheel-pad-position -> per-channel lift/gain/invGamma
// math consumed by Wheels.hlsl. Ported verbatim (same constants, same formulas).
namespace ColorWheels
{
    inline constexpr double kChromaLift = 0.2;
    inline constexpr double kChromaGain = 0.35;
    inline constexpr double kChromaGamma = 0.35;

    struct Rgb { double r, g, b; };

    inline Rgb HueRgb(double h)
    {
        double hh = h - std::floor(h);
        double x = hh * 6.0;
        double f = x - std::floor(x);
        int sector = static_cast<int>(x) % 6;
        switch (sector)
        {
            case 0: return {1.0, f, 0.0};
            case 1: return {1.0 - f, 1.0, 0.0};
            case 2: return {0.0, 1.0, f};
            case 3: return {0.0, 1.0 - f, 1.0};
            case 4: return {f, 0.0, 1.0};
            default: return {1.0, 0.0, 1.0 - f};
        }
    }

    inline Rgb ChromaOffset(double x, double y)
    {
        double r = std::min(1.0, std::sqrt(x * x + y * y));
        if (r <= 1e-6)
        {
            return {0.0, 0.0, 0.0};
        }
        Rgb c = HueRgb(std::atan2(y, x) / (2.0 * 3.14159265358979323846));
        double mean = (c.r + c.g + c.b) / 3.0;
        return {(c.r - mean) * r, (c.g - mean) * r, (c.b - mean) * r};
    }

    struct Coefficients
    {
        float liftR, liftG, liftB;
        float gainR, gainG, gainB;
        float invGammaR, invGammaG, invGammaB;
    };

    // p.* mirrors ResolvedEffectParams' 9 wheel keys (lift_x/y/m, gamma_x/y/m, gain_x/y/m).
    inline Coefficients Compute(
        double liftX, double liftY, double liftM,
        double gammaX, double gammaY, double gammaM,
        double gainX, double gainY, double gainM)
    {
        Rgb lift = ChromaOffset(liftX, liftY);
        Rgb gamma = ChromaOffset(gammaX, gammaY);
        Rgb gain = ChromaOffset(gainX, gainY);

        auto l = [&](double c) { return static_cast<float>(liftM + c * kChromaLift); };
        auto g = [&](double c) { return static_cast<float>(gainM * (1.0 + c * kChromaGain)); };
        auto ig = [&](double c) { return static_cast<float>(1.0 / std::max(0.01, gammaM * (1.0 + c * kChromaGamma))); };

        Coefficients out{};
        out.liftR = l(lift.r); out.liftG = l(lift.g); out.liftB = l(lift.b);
        out.gainR = g(gain.r); out.gainG = g(gain.g); out.gainB = g(gain.b);
        out.invGammaR = ig(gamma.r); out.invGammaG = ig(gamma.g); out.invGammaB = ig(gamma.b);
        return out;
    }
}
