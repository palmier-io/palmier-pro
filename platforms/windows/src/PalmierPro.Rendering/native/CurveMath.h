#pragma once

#include <algorithm>
#include <string>
#include <vector>

// Native port of Sources/PalmierPro/Models/GradeCurve.swift (`eval`) and
// Sources/PalmierPro/Models/HueCurves.swift (`eval`) — the control-point evaluators — plus
// Sources/PalmierPro/Compositing/Kernels/GradeCurveKernel.swift's `buildLUTs` and
// HueCurveKernel.swift's `buildLUT` (the 256-wide 1D LUT construction consumed by
// GradeCurves.hlsl / HueCurves.hlsl). Control points are parsed from the effect's `curve`/
// `curves` JSON string param (CurveMath.cpp, via simdjson) — same shape as GradeCurve.Codable /
// HueCurves.Codable.

struct CurvePointNative
{
    double x = 0.0;
    double y = 0.0;
};

namespace CurveMath
{
    constexpr int kLutWidth = 256;

    struct GradeCurveSet
    {
        std::vector<CurvePointNative> master, red, green, blue;
    };

    struct HueCurveSet
    {
        std::vector<CurvePointNative> hueVsHue, hueVsSat, hueVsLum;
    };

    // GradeCurve.eval: piecewise-linear, clamped flat outside the point range, sorted by x.
    // Empty `pts` -> identity ([(0,0),(1,1)]), matching GradeCurve.identityPoints.
    double EvalGradeCurve(std::vector<CurvePointNative> pts, double x);

    // HueCurves.eval: cyclic piecewise-linear (wraps across the hue seam at 0/1). Empty `pts`
    // -> 6 evenly-spaced neutral (y=0.5) points, matching HueCurves.defaultPoints.
    double EvalHueCurve(std::vector<CurvePointNative> pts, double x);

    // Parses a GradeCurve-shaped JSON string (`{"master":[...], "red":[...], ...}`). Returns
    // false (all-empty `out`, which EvalGradeCurve treats as identity) on parse failure —
    // mirrors GradeCurve(json:)'s failable-init->nil behavior collapsing to "no curve".
    bool ParseGradeCurveJson(const std::string& json, GradeCurveSet& out);

    // Parses a HueCurves-shaped JSON string (`{"hueVsHue":[...], "hueVsSat":[...],
    // "hueVsLum":[...]}`). Same failure semantics as ParseGradeCurveJson.
    bool ParseHueCurvesJson(const std::string& json, HueCurveSet& out);

    // Mirrors GradeCurveKernel.buildLUTs exactly: t_i = i/(w-1) for i in [0,w). Each output is
    // kLutWidth RGBA float32 texels (channels: R=red curve, G=green curve, B=blue curve, A=1;
    // master: RGB all = master curve, A=1).
    void BuildGradeCurveLuts(const GradeCurveSet& curve, std::vector<float>& outChannelsRgba, std::vector<float>& outMasterRgba);

    // Mirrors HueCurveKernel.buildLUT exactly: hue_i = (i+0.5)/w. Output is kLutWidth RGBA
    // float32 texels: R=dHue (±1/12 max), G=satScale (±1), B=dLum (±0.5 max), A=1.
    void BuildHueCurveLut(const HueCurveSet& curves, std::vector<float>& outRgba);

    bool IsGradeCurveIdentity(const GradeCurveSet& c);
    bool IsHueCurveIdentity(const HueCurveSet& c);
}
