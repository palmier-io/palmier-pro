#include "CurveMath.h"
#include "third_party/simdjson/simdjson.h"

#include <cmath>

using namespace simdjson;

namespace
{
    std::vector<CurvePointNative> ParsePointsArray(simdjson_result<dom::element> field)
    {
        std::vector<CurvePointNative> pts;
        dom::array arr;
        if (field.get(arr) != SUCCESS)
        {
            return pts;
        }
        for (dom::element el : arr)
        {
            CurvePointNative p;
            double x, y;
            if (el["x"].get(x) != SUCCESS) { int64_t xi; el["x"].get(xi); x = static_cast<double>(xi); }
            if (el["y"].get(y) != SUCCESS) { int64_t yi; el["y"].get(yi); y = static_cast<double>(yi); }
            p.x = x;
            p.y = y;
            pts.push_back(p);
        }
        return pts;
    }
}

double CurveMath::EvalGradeCurve(std::vector<CurvePointNative> pts, double x)
{
    if (pts.empty())
    {
        pts = {CurvePointNative{0.0, 0.0}, CurvePointNative{1.0, 1.0}};
    }
    std::sort(pts.begin(), pts.end(), [](const CurvePointNative& a, const CurvePointNative& b) { return a.x < b.x; });
    if (x <= pts.front().x) return pts.front().y;
    if (x >= pts.back().x) return pts.back().y;
    for (size_t i = 1; i < pts.size(); ++i)
    {
        if (x <= pts[i].x)
        {
            const auto& a = pts[i - 1];
            const auto& b = pts[i];
            double t = (b.x - a.x) == 0.0 ? 0.0 : (x - a.x) / (b.x - a.x);
            return a.y + (b.y - a.y) * t;
        }
    }
    return x;
}

namespace
{
    std::vector<CurvePointNative> DefaultHuePoints()
    {
        std::vector<CurvePointNative> pts;
        for (int i = 0; i < 6; ++i)
        {
            pts.push_back(CurvePointNative{static_cast<double>(i) / 6.0, 0.5});
        }
        return pts;
    }

    double LerpPoint(const CurvePointNative& a, const CurvePointNative& b, double x)
    {
        double t = (b.x - a.x) == 0.0 ? 0.0 : (x - a.x) / (b.x - a.x);
        return a.y + (b.y - a.y) * t;
    }
}

double CurveMath::EvalHueCurve(std::vector<CurvePointNative> pts, double x)
{
    if (pts.empty())
    {
        pts = DefaultHuePoints();
    }
    std::sort(pts.begin(), pts.end(), [](const CurvePointNative& a, const CurvePointNative& b) { return a.x < b.x; });
    const CurvePointNative& first = pts.front();
    const CurvePointNative& last = pts.back();
    if (x < first.x)
    {
        return LerpPoint(CurvePointNative{last.x - 1.0, last.y}, first, x);
    }
    for (size_t i = 1; i < pts.size(); ++i)
    {
        if (x <= pts[i].x)
        {
            return LerpPoint(pts[i - 1], pts[i], x);
        }
    }
    return LerpPoint(last, CurvePointNative{first.x + 1.0, first.y}, x);
}

bool CurveMath::ParseGradeCurveJson(const std::string& json, GradeCurveSet& out)
{
    try
    {
        dom::parser parser;
        padded_string padded(json);
        dom::element root;
        if (parser.parse(padded).get(root) != SUCCESS)
        {
            return false;
        }
        out.master = ParsePointsArray(root["master"]);
        out.red = ParsePointsArray(root["red"]);
        out.green = ParsePointsArray(root["green"]);
        out.blue = ParsePointsArray(root["blue"]);
        return true;
    }
    catch (...)
    {
        return false;
    }
}

bool CurveMath::ParseHueCurvesJson(const std::string& json, HueCurveSet& out)
{
    try
    {
        dom::parser parser;
        padded_string padded(json);
        dom::element root;
        if (parser.parse(padded).get(root) != SUCCESS)
        {
            return false;
        }
        out.hueVsHue = ParsePointsArray(root["hueVsHue"]);
        out.hueVsSat = ParsePointsArray(root["hueVsSat"]);
        out.hueVsLum = ParsePointsArray(root["hueVsLum"]);
        return true;
    }
    catch (...)
    {
        return false;
    }
}

namespace
{
    float Clamp01(double v) { return static_cast<float>(v < 0.0 ? 0.0 : (v > 1.0 ? 1.0 : v)); }
}

void CurveMath::BuildGradeCurveLuts(const GradeCurveSet& curve, std::vector<float>& outChannelsRgba, std::vector<float>& outMasterRgba)
{
    outChannelsRgba.assign(static_cast<size_t>(kLutWidth) * 4, 0.0f);
    outMasterRgba.assign(static_cast<size_t>(kLutWidth) * 4, 0.0f);
    for (int x = 0; x < kLutWidth; ++x)
    {
        double t = static_cast<double>(x) / static_cast<double>(kLutWidth - 1);
        outChannelsRgba[x * 4 + 0] = Clamp01(EvalGradeCurve(curve.red, t));
        outChannelsRgba[x * 4 + 1] = Clamp01(EvalGradeCurve(curve.green, t));
        outChannelsRgba[x * 4 + 2] = Clamp01(EvalGradeCurve(curve.blue, t));
        outChannelsRgba[x * 4 + 3] = 1.0f;
        float m = Clamp01(EvalGradeCurve(curve.master, t));
        outMasterRgba[x * 4 + 0] = m;
        outMasterRgba[x * 4 + 1] = m;
        outMasterRgba[x * 4 + 2] = m;
        outMasterRgba[x * 4 + 3] = 1.0f;
    }
}

void CurveMath::BuildHueCurveLut(const HueCurveSet& curves, std::vector<float>& outRgba)
{
    static constexpr double kMaxHueShift = 1.0 / 12.0;
    static constexpr double kMaxLumShift = 0.5;
    outRgba.assign(static_cast<size_t>(kLutWidth) * 4, 0.0f);
    for (int i = 0; i < kLutWidth; ++i)
    {
        double hue = (static_cast<double>(i) + 0.5) / static_cast<double>(kLutWidth);
        double dHue = (EvalHueCurve(curves.hueVsHue, hue) - 0.5) * 2.0 * kMaxHueShift;
        double satScale = (EvalHueCurve(curves.hueVsSat, hue) - 0.5) * 2.0;
        double dLum = (EvalHueCurve(curves.hueVsLum, hue) - 0.5) * 2.0 * kMaxLumShift;
        outRgba[i * 4 + 0] = static_cast<float>(dHue);
        outRgba[i * 4 + 1] = static_cast<float>(satScale);
        outRgba[i * 4 + 2] = static_cast<float>(dLum);
        outRgba[i * 4 + 3] = 1.0f;
    }
}

namespace
{
    bool AllIdentity(const std::vector<CurvePointNative>& pts)
    {
        if (pts.empty()) return true;
        if (pts.size() != 2) return false;
        return pts[0].x == 0.0 && pts[0].y == 0.0 && pts[1].x == 1.0 && pts[1].y == 1.0;
    }
    bool AllNeutral(const std::vector<CurvePointNative>& pts)
    {
        for (const auto& p : pts)
        {
            if (std::abs(p.y - 0.5) >= 1e-4) return false;
        }
        return true;
    }
}

bool CurveMath::IsGradeCurveIdentity(const GradeCurveSet& c)
{
    return AllIdentity(c.master) && AllIdentity(c.red) && AllIdentity(c.green) && AllIdentity(c.blue);
}

bool CurveMath::IsHueCurveIdentity(const HueCurveSet& c)
{
    return AllNeutral(c.hueVsHue) && AllNeutral(c.hueVsSat) && AllNeutral(c.hueVsLum);
}
