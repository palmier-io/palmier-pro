#pragma once

#include "include/palmier_engine.h" // PE_ColorScopesResult, PE_COLOR_SCOPES_* constants

#include <d3d11.h>
#include <wrl/client.h>

#include <cstdint>
#include <string>

// GPU downsample + groupshared/InterlockedAdd histogram compute behind PE_TimelineComputeColorScopes
// (docs/color-scopes-v1.md). Lazily owned by GpuCompositor (GpuCompositor::ComputeColorScopes),
// mirroring TextRenderer's lazy-create-on-first-use pattern — reads GpuCompositor's already-
// composited accumulator texture directly; this class never composites or decodes anything itself,
// so it has no dependency on TimelineSnapshot/ClipFrameProvider at all.
class Scopes
{
public:
    // `device`/`context` are the same D3D11 device/context GpuCompositor already holds (not
    // owned here — GpuCompositor outlives every Scopes instance it creates).
    Scopes(ID3D11Device* device, ID3D11DeviceContext* context);
    ~Scopes();

    Scopes(const Scopes&) = delete;
    Scopes& operator=(const Scopes&) = delete;

    // `source` is the compositor's canvas-sized accumulator SRV (R16G16B16A16_FLOAT,
    // gamma-encoded; the accumulator is always opaque, so premultiplied-by-1.0 already equals
    // straight color — doc §3, no unpremultiply pass needed). Downsamples to <=320x180 (doc
    // §2.1/§3), runs the combined Y/R/G/B + hue histogram pass, reads back the packed buffer,
    // and applies both normalization schemes (doc §2: joint-max for Y/R/G/B, max-then-sqrt for
    // hue). Leaves outResult.frame untouched — the caller stamps it.
    bool Compute(ID3D11ShaderResourceView* source, int32_t width, int32_t height,
        PE_ColorScopesResult& outResult, std::string& outError);

private:
    ID3D11Device* device_;         // not owned — shared with GpuCompositor
    ID3D11DeviceContext* context_; // not owned

    std::string shadersDir_;
    Microsoft::WRL::ComPtr<ID3D11ComputeShader> downsampleCs_;
    Microsoft::WRL::ComPtr<ID3D11ComputeShader> histogramCs_;

    // <=320x180 scope grid (doc §3) — R16G16B16A16_FLOAT so the box-filter average keeps the
    // source's precision; reallocated only when the requested grid size actually changes.
    Microsoft::WRL::ComPtr<ID3D11Texture2D> gridTex_;
    Microsoft::WRL::ComPtr<ID3D11ShaderResourceView> gridSrv_;
    Microsoft::WRL::ComPtr<ID3D11UnorderedAccessView> gridUav_;
    int32_t gridCapacityW_ = 0;
    int32_t gridCapacityH_ = 0;

    // Packed RWStructuredBuffer<uint> of length 4*256+96=1120 (doc §3's "one packed buffer") +
    // its CPU-readback staging twin.
    Microsoft::WRL::ComPtr<ID3D11Buffer> histogramBuffer_;
    Microsoft::WRL::ComPtr<ID3D11UnorderedAccessView> histogramUav_;
    Microsoft::WRL::ComPtr<ID3D11Buffer> histogramStaging_;

    Microsoft::WRL::ComPtr<ID3D11Buffer> constantBuffer_; // 16 bytes, reused across both passes

    bool ResolveShadersDir(std::string& outError);
    bool GetOrCompileCS(const std::string& file, const std::string& entry, ID3D11ComputeShader** outCs, std::string& outError);
    bool EnsureDeviceResources(std::string& outError);
    bool EnsureGrid(int32_t gridW, int32_t gridH, std::string& outError);
    void UpdateConstantBuffer(const void* data, size_t bytes);
};
