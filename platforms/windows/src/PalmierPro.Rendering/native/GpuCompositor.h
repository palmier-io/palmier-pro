#pragma once

#include "Compositor.h" // ComposeResult, ClipFrameProvider, DecodedSourceFrame
#include "EffectRegistry.h"
#include "TextRenderer.h"
#include "TimelineSnapshot.h"

#include <d3d11.h>
#include <wrl/client.h>

#include <atomic>
#include <memory>
#include <optional>
#include <string>
#include <unordered_map>
#include <vector>

// GPU (D3D11) per-frame compositor — the plan's "MOVE COMPOSITING TO D3D11" deliverable. This
// is the DEFAULT render path (see TimelineSession.cpp); Compositor::Compose (CPU) remains
// compiled and reachable only as an explicit fallback (PALMIERENGINE_FORCE_CPU_COMPOSITOR=1),
// mirroring the existing PALMIERENGINE_FORCE_WARP pattern (EngineSession.cpp) rather than
// running two live paths silently.
//
// Working format: R16G16B16A16_FLOAT, gamma-encoded, PREMULTIPLIED alpha (the plan's "Color
// pipeline" — non-color-managed, no global linearization). Per-clip pipeline: upload (CPU BGRA8
// decode buffer -> GPU texture) -> Ingest.hlsl (straight->premultiplied, natural resolution) ->
// ordered enabled-effect chain (one HLSL pass per Metal-kernel port, EffectRegistry.h) ->
// Composite.hlsl (transform+crop+blend into the canvas-sized accumulator, ping-ponged across
// two render targets since a pass can't read+write the same bound target). See Composite.hlsl's
// header comment for exactly which CPU math (Compositor.cpp) this bit-exactly mirrors for the
// Normal blend mode, and where the GPU path's one documented, deliberate divergence is.
//
// `EffectDescriptorNative::linearizes` (EffectRegistry.h) is carried for forward-compatibility
// with EffectRegistry.swift's `linearizes` flag but is NOT consulted by ApplyOneEffect/
// ApplyEffectChain today — every one of the 11 ported kernels has it `false` (see
// EffectRegistry.h's header comment), so there is currently nothing to wrap. A future
// linearizes:true kernel port must add the LinearizeSrgb/DelinearizeSrgb (Common.hlsl) wrap
// around its pass at that point, not assume it already happens here.
class GpuCompositor
{
public:
    GpuCompositor(ID3D11Device* device, ID3D11DeviceContext* context);
    ~GpuCompositor();

    GpuCompositor(const GpuCompositor&) = delete;
    GpuCompositor& operator=(const GpuCompositor&) = delete;

    bool Compose(
        const TimelineSnapshot& snapshot,
        int64_t frame,
        const ClipFrameProvider& provider,
        const std::atomic<int32_t>* cancelFlag,
        ComposeResult& outResult,
        std::string& outError);

private:
    struct GpuTex
    {
        Microsoft::WRL::ComPtr<ID3D11Texture2D> tex;
        Microsoft::WRL::ComPtr<ID3D11ShaderResourceView> srv;
        Microsoft::WRL::ComPtr<ID3D11RenderTargetView> rtv;
        Microsoft::WRL::ComPtr<ID3D11UnorderedAccessView> uav;
        int32_t width = 0;
        int32_t height = 0;
    };

    Microsoft::WRL::ComPtr<ID3D11Device> device_;
    Microsoft::WRL::ComPtr<ID3D11DeviceContext> context_;

    std::string shadersDir_;

    Microsoft::WRL::ComPtr<ID3D11VertexShader> fullscreenVs_;
    std::unordered_map<std::string, Microsoft::WRL::ComPtr<ID3D11PixelShader>> psCache_;
    std::unordered_map<std::string, Microsoft::WRL::ComPtr<ID3D11ComputeShader>> csCache_;

    Microsoft::WRL::ComPtr<ID3D11SamplerState> pointClampSampler_;
    Microsoft::WRL::ComPtr<ID3D11SamplerState> linearClampSampler_;
    Microsoft::WRL::ComPtr<ID3D11SamplerState> linearWrapSampler_;

    Microsoft::WRL::ComPtr<ID3D11Buffer> constantBuffer_; // 64 bytes, reused/overwritten per pass

    GpuTex accum_[2];
    Microsoft::WRL::ComPtr<ID3D11Texture2D> stagingTex_;
    int32_t stagingWidth_ = 0, stagingHeight_ = 0;

    // Lazily created on first text clip — a WIC-software D2D/DirectWrite rasterizer (needs no D3D
    // device, so it is independent of this compositor's GPU device).
    std::unique_ptr<TextRenderer> textRenderer_;

    bool ResolveShadersDir(std::string& outError);
    bool EnsureCommonResources(std::string& outError);
    bool EnsureAccumulators(int32_t width, int32_t height, std::string& outError);

    bool GetOrCompilePS(const std::string& file, const std::string& entry, ID3D11PixelShader** outPs, std::string& outError);
    bool GetOrCompileCS(const std::string& file, const std::string& entry, ID3D11ComputeShader** outCs, std::string& outError);

    bool CreateWorkingTexture(int32_t width, int32_t height, bool needsUav, GpuTex& out, std::string& outError);
    bool CreateUploadTexture(int32_t width, int32_t height, GpuTex& out, std::string& outError);
    bool UploadBgra(GpuTex& uploadTex, const DecodedSourceFrame& decoded, std::string& outError);

    void UpdateConstantBuffer(const void* data, size_t bytes);
    // `ps` must already be compiled (GetOrCompilePS) — this method has no failure path.
    void RunFullscreenPass(
        ID3D11PixelShader* ps,
        ID3D11ShaderResourceView* const* srvs, int srvCount,
        ID3D11SamplerState* const* samplers, int samplerCount,
        const void* cbData, size_t cbBytes,
        ID3D11RenderTargetView* rtv, int32_t width, int32_t height);

    bool RunGaussianBlur(GpuTex& source, GpuTex& scratch, GpuTex& out, int32_t width, int32_t height, double radius, std::string& outError);

    bool ApplyEffectChain(
        const std::vector<SnapshotEffect>& effects, int64_t clipRelativeFrame, int32_t natW, int32_t natH,
        GpuTex& natA, GpuTex& natB, GpuTex*& current, std::string& outError);

    // E4 text pass — rasterizes `textClip` at `frame` (TextRenderer, a canvas-sized straight-alpha
    // BGRA raster), then ingests + effect-chains + composites it into the accumulator ping-pong
    // exactly like a decoded clip (identity transform: the text box position is already baked into
    // the raster by TextRenderer, mirroring composedTextLayer which composites the raster flat, no
    // affine — FrameRenderer.swift:275). Advances `current` iff anything was drawn.
    bool ComposeTextClip(
        const SnapshotTextClip& textClip, int64_t frame, int32_t canvasWidth, int32_t canvasHeight,
        int& current, std::string& outError);

    bool ApplyOneEffect(
        const EffectDescriptorNative& desc, const SnapshotEffect& effect,
        int64_t clipRelativeFrame, int32_t natW, int32_t natH,
        GpuTex& src, GpuTex& dst, std::string& outError);

    bool CreateLutTexture1D(const std::vector<float>& rgba256, GpuTex& out, std::string& outError);
    bool CreateLutTextureStrip(const std::vector<float>& rgba, int32_t width, int32_t height, GpuTex& out, std::string& outError);

    void RunCompositePass(
        GpuTex& source, GpuTex& backdrop, GpuTex& target,
        const SnapshotTransform& transform, const SnapshotCrop& crop,
        double opacity, int blendModeIndex,
        int32_t canvasWidth, int32_t canvasHeight);

    bool ReadbackToBgra8(GpuTex& source, int32_t width, int32_t height, ComposeResult& outResult, std::string& outError);
};

// Shared by TimelineSession.cpp (to decide which path a snapshot's clips need) and
// GpuCompositor.cpp/tests. Maps a BlendMode raw string to the index Composite.hlsl's
// ApplyBlend switches on (0=normal ... 15=luminosity) — matches BlendMode.swift's declared
// case order exactly (Models/BlendMode.swift:5-7). Unset/"normal"/unrecognized -> 0.
int BlendModeToIndex(const std::optional<std::string>& blendMode);
