#include "EffectRegistry.h"

#include <unordered_map>

namespace
{
    // Param key/default/range values are copied verbatim from EffectRegistry.swift's
    // `EffectParamSpec` literals at the line references in EffectRegistry.h.
    const std::vector<EffectDescriptorNative>& AllDescriptors()
    {
        static const std::vector<EffectDescriptorNative> all = {
            EffectDescriptorNative{
                "color.highlightsShadows", EffectKernel::HighlightsShadows, EffectKernelIoConvention::ColorKernel, false,
                {
                    {"highlights", 0.0, -1.0, 1.0},
                    {"shadows", 0.0, -1.0, 1.0},
                }},
            EffectDescriptorNative{
                "color.blacksWhites", EffectKernel::Levels, EffectKernelIoConvention::ColorKernel, false,
                {
                    {"blacks", 0.0, -1.0, 1.0},
                    {"whites", 0.0, -1.0, 1.0},
                }},
            EffectDescriptorNative{
                "color.wheels", EffectKernel::Wheels, EffectKernelIoConvention::ColorKernel, false,
                {
                    {"lift_x", 0.0, -1.0, 1.0},
                    {"lift_y", 0.0, -1.0, 1.0},
                    {"lift_m", 0.0, -0.5, 0.5},
                    {"gamma_x", 0.0, -1.0, 1.0},
                    {"gamma_y", 0.0, -1.0, 1.0},
                    {"gamma_m", 1.0, 0.5, 2.0},
                    {"gain_x", 0.0, -1.0, 1.0},
                    {"gain_y", 0.0, -1.0, 1.0},
                    {"gain_m", 1.0, 0.5, 1.5},
                }},
            EffectDescriptorNative{
                "color.hueCurves", EffectKernel::HueCurves, EffectKernelIoConvention::GeneralKernel, false, {}},
            EffectDescriptorNative{
                "color.lut", EffectKernel::LutTetra, EffectKernelIoConvention::GeneralKernel, false,
                {
                    {"intensity", 1.0, 0.0, 1.0},
                }},
            EffectDescriptorNative{
                "color.curves", EffectKernel::GradeCurves, EffectKernelIoConvention::GeneralKernel, false, {}},
            EffectDescriptorNative{
                "detail.clarity", EffectKernel::Clarity, EffectKernelIoConvention::GeneralKernel, false,
                {
                    {"clarity", 0.0, -1.0, 1.0},
                    {"dehaze", 0.0, -1.0, 1.0},
                }},
            EffectDescriptorNative{
                "key.chroma", EffectKernel::ChromaKey, EffectKernelIoConvention::ColorKernel, false,
                {
                    {"keyHue", 0.333, 0.0, 1.0},
                    {"tolerance", 0.0, 0.0, 1.0},
                    {"softness", 0.1, 0.0, 1.0},
                    {"spill", 0.5, 0.0, 1.0},
                }},
            EffectDescriptorNative{
                "stylize.grain", EffectKernel::Grain, EffectKernelIoConvention::GeneralKernel, false,
                {
                    {"amount", 0.0, 0.0, 1.0},
                    {"size", 1.5, 0.5, 4.0},
                }},
            EffectDescriptorNative{
                "stylize.vignette", EffectKernel::Vignette, EffectKernelIoConvention::GeneralKernel, false,
                {
                    {"amount", 0.0, -1.0, 1.0},
                    {"midpoint", 0.5, 0.0, 1.0},
                    {"roundness", 0.0, -1.0, 1.0},
                    {"feather", 0.5, 0.0, 1.0},
                }},
            EffectDescriptorNative{
                "stylize.glow", EffectKernel::Glow, EffectKernelIoConvention::GeneralKernel, false,
                {
                    {"intensity", 0.0, 0.0, 1.0},
                    {"radius", 20.0, 0.0, 100.0},
                    {"threshold", 0.6, 0.0, 1.0},
                    {"warmth", 0.0, 0.0, 1.0},
                }},
        };
        return all;
    }

    const std::unordered_map<std::string, const EffectDescriptorNative*>& ById()
    {
        static const std::unordered_map<std::string, const EffectDescriptorNative*> map = [] {
            std::unordered_map<std::string, const EffectDescriptorNative*> m;
            for (const auto& d : AllDescriptors())
            {
                m.emplace(d.id, &d);
            }
            return m;
        }();
        return map;
    }
}

const EffectDescriptorNative* EffectRegistry::Find(const std::string& type)
{
    const auto& map = ById();
    auto it = map.find(type);
    return it == map.end() ? nullptr : it->second;
}
