#include "GpuCompositor.h"
#include "ClipGeometry.h"
#include "ColorWheels.h"
#include "CubeLutParser.h"
#include "CurveMath.h"
#include "Half.h"

#include <d3dcompiler.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <fstream>
#include <sstream>

using Microsoft::WRL::ComPtr;

namespace
{
    // Resolves `#include "File.hlsl"` directives against the shaders directory next to
    // PalmierEngine.dll — the "existing staging mechanism" (PalmierPro.Rendering.csproj's
    // Content items) copies native/shaders/*.hlsl there. Common.hlsl is the only file that
    // gets #included today.
    class ShaderIncludeHandler : public ID3DInclude
    {
    public:
        explicit ShaderIncludeHandler(const std::string& shadersDir) : shadersDir_(shadersDir) {}

        HRESULT __stdcall Open(D3D_INCLUDE_TYPE, LPCSTR pFileName, LPCVOID, LPCVOID* ppData, UINT* pBytes) override
        {
            std::string path = shadersDir_ + pFileName;
            std::ifstream file(path, std::ios::in | std::ios::binary);
            if (!file)
            {
                return E_FAIL;
            }
            std::ostringstream ss;
            ss << file.rdbuf();
            std::string contents = ss.str();
            char* buffer = new char[contents.size()];
            std::memcpy(buffer, contents.data(), contents.size());
            *ppData = buffer;
            *pBytes = static_cast<UINT>(contents.size());
            return S_OK;
        }

        HRESULT __stdcall Close(LPCVOID pData) override
        {
            delete[] static_cast<const char*>(pData);
            return S_OK;
        }

    private:
        std::string shadersDir_;
    };

    bool ReadFile(const std::string& path, std::string& outContents)
    {
        std::ifstream file(path, std::ios::in | std::ios::binary);
        if (!file)
        {
            return false;
        }
        std::ostringstream ss;
        ss << file.rdbuf();
        outContents = ss.str();
        return true;
    }

    // Anchors shader resolution on this DLL's own module (not the process exe's), matching
    // palmier_engine.h's "deployed next to the DLL" contract regardless of which host process
    // loaded PalmierEngine.dll.
    void AnchorFunction() {}

    // ---- cbuffer layouts — must match each .hlsl file's `cbuffer` declaration exactly ----
    struct LevelsCb { float blacks, whites, pad0, pad1; };
    struct HighlightsShadowsCb { float highlights, shadows, pad0, pad1; };
    struct WheelsCb { float lift[3], pad0; float gain[3], pad1; float invGamma[3], pad2; };
    struct ChromaKeyCb { float keyHue, tolerance, softness, spill; };
    struct VignetteCb { float rect[4]; float amount, midpoint, roundness, feather; };
    struct GrainCb { float amount, size, frame, pad0; float textureSize[2]; float pad1[2]; };
    struct LutTetraCb { float n, intensity, pad0, pad1; };
    struct GlowBrightCb { float threshold, warmth, pad0, pad1; };
    struct GlowCompositeCb { float intensity, pad0, pad1, pad2; };
    struct ClarityCb { float clarity, dehaze, pad0, pad1; };
    struct CompositeCb { float invRow0[4], invRow1[4], cropRect[4], params[4]; };
    struct BlurCb { float sigma; int tapRadius; int width; int height; };

    double ResolveParam(const SnapshotEffect& effect, const EffectParamSpecNative& spec, int64_t clipRelativeFrame)
    {
        const SnapshotEffectParam* p = effect.Param(spec.key);
        double raw = p ? p->Resolve(clipRelativeFrame, spec.defaultValue) : spec.defaultValue;
        return std::min(spec.rangeMax, std::max(spec.rangeMin, raw));
    }

    std::string ParamString(const SnapshotEffect& effect, const std::string& key)
    {
        const SnapshotEffectParam* p = effect.Param(key);
        return (p && p->stringValue) ? *p->stringValue : std::string();
    }
}

int BlendModeToIndex(const std::optional<std::string>& blendMode)
{
    if (!blendMode.has_value()) return 0;
    static const std::unordered_map<std::string, int> map = {
        {"normal", 0}, {"darken", 1}, {"multiply", 2}, {"colorBurn", 3}, {"lighten", 4},
        {"screen", 5}, {"colorDodge", 6}, {"overlay", 7}, {"softLight", 8}, {"hardLight", 9},
        {"difference", 10}, {"exclusion", 11}, {"hue", 12}, {"saturation", 13}, {"color", 14},
        {"luminosity", 15},
    };
    auto it = map.find(*blendMode);
    return it == map.end() ? 0 : it->second;
}

GpuCompositor::GpuCompositor(ID3D11Device* device, ID3D11DeviceContext* context)
    : device_(device), context_(context)
{
}

GpuCompositor::~GpuCompositor() = default;

bool GpuCompositor::ResolveShadersDir(std::string& outError)
{
    if (!shadersDir_.empty())
    {
        return true;
    }
    HMODULE hModule = nullptr;
    if (!GetModuleHandleExA(
            GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
            reinterpret_cast<LPCSTR>(&AnchorFunction), &hModule))
    {
        outError = "GetModuleHandleExA failed while resolving the shaders directory";
        return false;
    }
    char path[MAX_PATH]{};
    DWORD len = GetModuleFileNameA(hModule, path, MAX_PATH);
    if (len == 0 || len == MAX_PATH)
    {
        outError = "GetModuleFileNameA failed while resolving the shaders directory";
        return false;
    }
    std::string full(path, len);
    size_t slash = full.find_last_of("\\/");
    std::string dir = slash == std::string::npos ? "" : full.substr(0, slash + 1);
    shadersDir_ = dir + "shaders\\";
    return true;
}

bool GpuCompositor::EnsureCommonResources(std::string& outError)
{
    if (!ResolveShadersDir(outError))
    {
        return false;
    }

    if (!fullscreenVs_)
    {
        std::string source;
        std::string path = shadersDir_ + "Fullscreen.hlsl";
        if (!ReadFile(path, source))
        {
            outError = "cannot read shader: " + path;
            return false;
        }
        ShaderIncludeHandler includeHandler(shadersDir_);
        ComPtr<ID3DBlob> blob, errorBlob;
        HRESULT hr = D3DCompile(source.data(), source.size(), path.c_str(), nullptr, &includeHandler,
            "VSMain", "vs_5_0", 0, 0, &blob, &errorBlob);
        if (FAILED(hr))
        {
            outError = "D3DCompile(Fullscreen.hlsl:VSMain) failed";
            if (errorBlob) outError += ": " + std::string(static_cast<const char*>(errorBlob->GetBufferPointer()), errorBlob->GetBufferSize());
            return false;
        }
        hr = device_->CreateVertexShader(blob->GetBufferPointer(), blob->GetBufferSize(), nullptr, &fullscreenVs_);
        if (FAILED(hr))
        {
            outError = "CreateVertexShader(Fullscreen.hlsl) failed";
            return false;
        }
    }

    if (!pointClampSampler_)
    {
        D3D11_SAMPLER_DESC sd{};
        sd.Filter = D3D11_FILTER_MIN_MAG_MIP_POINT;
        sd.AddressU = sd.AddressV = sd.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
        sd.ComparisonFunc = D3D11_COMPARISON_NEVER;
        sd.MaxLOD = D3D11_FLOAT32_MAX;
        if (FAILED(device_->CreateSamplerState(&sd, &pointClampSampler_)))
        {
            outError = "CreateSamplerState(point-clamp) failed";
            return false;
        }
    }
    if (!linearClampSampler_)
    {
        D3D11_SAMPLER_DESC sd{};
        sd.Filter = D3D11_FILTER_MIN_MAG_MIP_LINEAR;
        sd.AddressU = sd.AddressV = sd.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
        sd.ComparisonFunc = D3D11_COMPARISON_NEVER;
        sd.MaxLOD = D3D11_FLOAT32_MAX;
        if (FAILED(device_->CreateSamplerState(&sd, &linearClampSampler_)))
        {
            outError = "CreateSamplerState(linear-clamp) failed";
            return false;
        }
    }
    if (!linearWrapSampler_)
    {
        D3D11_SAMPLER_DESC sd{};
        sd.Filter = D3D11_FILTER_MIN_MAG_MIP_LINEAR;
        sd.AddressU = sd.AddressV = sd.AddressW = D3D11_TEXTURE_ADDRESS_WRAP;
        sd.ComparisonFunc = D3D11_COMPARISON_NEVER;
        sd.MaxLOD = D3D11_FLOAT32_MAX;
        if (FAILED(device_->CreateSamplerState(&sd, &linearWrapSampler_)))
        {
            outError = "CreateSamplerState(linear-wrap) failed";
            return false;
        }
    }
    if (!constantBuffer_)
    {
        D3D11_BUFFER_DESC bd{};
        bd.ByteWidth = 256;
        bd.Usage = D3D11_USAGE_DEFAULT;
        bd.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
        if (FAILED(device_->CreateBuffer(&bd, nullptr, &constantBuffer_)))
        {
            outError = "CreateBuffer(constant buffer) failed";
            return false;
        }
    }
    return true;
}

bool GpuCompositor::GetOrCompilePS(const std::string& file, const std::string& entry, ID3D11PixelShader** outPs, std::string& outError)
{
    std::string key = file + ":" + entry;
    auto it = psCache_.find(key);
    if (it != psCache_.end())
    {
        *outPs = it->second.Get();
        return true;
    }
    if (!ResolveShadersDir(outError))
    {
        return false;
    }
    std::string source;
    std::string path = shadersDir_ + file;
    if (!ReadFile(path, source))
    {
        outError = "cannot read shader: " + path;
        return false;
    }
    ShaderIncludeHandler includeHandler(shadersDir_);
    ComPtr<ID3DBlob> blob, errorBlob;
    HRESULT hr = D3DCompile(source.data(), source.size(), path.c_str(), nullptr, &includeHandler,
        entry.c_str(), "ps_5_0", 0, 0, &blob, &errorBlob);
    if (FAILED(hr))
    {
        outError = "D3DCompile(" + key + ") failed";
        if (errorBlob) outError += ": " + std::string(static_cast<const char*>(errorBlob->GetBufferPointer()), errorBlob->GetBufferSize());
        return false;
    }
    ComPtr<ID3D11PixelShader> ps;
    hr = device_->CreatePixelShader(blob->GetBufferPointer(), blob->GetBufferSize(), nullptr, &ps);
    if (FAILED(hr))
    {
        outError = "CreatePixelShader(" + key + ") failed";
        return false;
    }
    *outPs = ps.Get();
    psCache_.emplace(key, std::move(ps));
    return true;
}

bool GpuCompositor::GetOrCompileCS(const std::string& file, const std::string& entry, ID3D11ComputeShader** outCs, std::string& outError)
{
    std::string key = file + ":" + entry;
    auto it = csCache_.find(key);
    if (it != csCache_.end())
    {
        *outCs = it->second.Get();
        return true;
    }
    if (!ResolveShadersDir(outError))
    {
        return false;
    }
    std::string source;
    std::string path = shadersDir_ + file;
    if (!ReadFile(path, source))
    {
        outError = "cannot read shader: " + path;
        return false;
    }
    ShaderIncludeHandler includeHandler(shadersDir_);
    ComPtr<ID3DBlob> blob, errorBlob;
    HRESULT hr = D3DCompile(source.data(), source.size(), path.c_str(), nullptr, &includeHandler,
        entry.c_str(), "cs_5_0", 0, 0, &blob, &errorBlob);
    if (FAILED(hr))
    {
        outError = "D3DCompile(" + key + ") failed";
        if (errorBlob) outError += ": " + std::string(static_cast<const char*>(errorBlob->GetBufferPointer()), errorBlob->GetBufferSize());
        return false;
    }
    ComPtr<ID3D11ComputeShader> cs;
    hr = device_->CreateComputeShader(blob->GetBufferPointer(), blob->GetBufferSize(), nullptr, &cs);
    if (FAILED(hr))
    {
        outError = "CreateComputeShader(" + key + ") failed";
        return false;
    }
    *outCs = cs.Get();
    csCache_.emplace(key, std::move(cs));
    return true;
}

bool GpuCompositor::CreateWorkingTexture(int32_t width, int32_t height, bool needsUav, GpuTex& out, std::string& outError)
{
    D3D11_TEXTURE2D_DESC td{};
    td.Width = static_cast<UINT>(width);
    td.Height = static_cast<UINT>(height);
    td.MipLevels = 1;
    td.ArraySize = 1;
    td.Format = DXGI_FORMAT_R16G16B16A16_FLOAT;
    td.SampleDesc.Count = 1;
    td.Usage = D3D11_USAGE_DEFAULT;
    td.BindFlags = D3D11_BIND_SHADER_RESOURCE | D3D11_BIND_RENDER_TARGET | (needsUav ? D3D11_BIND_UNORDERED_ACCESS : 0);

    out = GpuTex{};
    if (FAILED(device_->CreateTexture2D(&td, nullptr, &out.tex)))
    {
        outError = "CreateTexture2D(working texture) failed";
        return false;
    }
    if (FAILED(device_->CreateShaderResourceView(out.tex.Get(), nullptr, &out.srv)))
    {
        outError = "CreateShaderResourceView(working texture) failed";
        return false;
    }
    if (FAILED(device_->CreateRenderTargetView(out.tex.Get(), nullptr, &out.rtv)))
    {
        outError = "CreateRenderTargetView(working texture) failed";
        return false;
    }
    if (needsUav && FAILED(device_->CreateUnorderedAccessView(out.tex.Get(), nullptr, &out.uav)))
    {
        outError = "CreateUnorderedAccessView(working texture) failed";
        return false;
    }
    out.width = width;
    out.height = height;
    return true;
}

bool GpuCompositor::CreateUploadTexture(int32_t width, int32_t height, GpuTex& out, std::string& outError)
{
    D3D11_TEXTURE2D_DESC td{};
    td.Width = static_cast<UINT>(width);
    td.Height = static_cast<UINT>(height);
    td.MipLevels = 1;
    td.ArraySize = 1;
    td.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    td.SampleDesc.Count = 1;
    td.Usage = D3D11_USAGE_DYNAMIC;
    td.BindFlags = D3D11_BIND_SHADER_RESOURCE;
    td.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;

    out = GpuTex{};
    if (FAILED(device_->CreateTexture2D(&td, nullptr, &out.tex)))
    {
        outError = "CreateTexture2D(upload texture) failed";
        return false;
    }
    if (FAILED(device_->CreateShaderResourceView(out.tex.Get(), nullptr, &out.srv)))
    {
        outError = "CreateShaderResourceView(upload texture) failed";
        return false;
    }
    out.width = width;
    out.height = height;
    return true;
}

bool GpuCompositor::UploadBgra(GpuTex& uploadTex, const DecodedSourceFrame& decoded, std::string& outError)
{
    D3D11_MAPPED_SUBRESOURCE mapped{};
    HRESULT hr = context_->Map(uploadTex.tex.Get(), 0, D3D11_MAP_WRITE_DISCARD, 0, &mapped);
    if (FAILED(hr))
    {
        outError = "Map(upload texture) failed";
        return false;
    }
    const size_t rowBytes = static_cast<size_t>(decoded.width) * 4;
    auto* dst = static_cast<uint8_t*>(mapped.pData);
    for (int32_t row = 0; row < decoded.height; ++row)
    {
        std::memcpy(dst + static_cast<size_t>(row) * mapped.RowPitch,
            decoded.bgra + static_cast<size_t>(row) * decoded.strideBytes, rowBytes);
    }
    context_->Unmap(uploadTex.tex.Get(), 0);
    return true;
}

void GpuCompositor::UpdateConstantBuffer(const void* data, size_t bytes)
{
    uint8_t buffer[256]{};
    std::memcpy(buffer, data, std::min(bytes, sizeof(buffer)));
    context_->UpdateSubresource(constantBuffer_.Get(), 0, nullptr, buffer, 0, 0);
}

void GpuCompositor::RunFullscreenPass(
    ID3D11PixelShader* ps,
    ID3D11ShaderResourceView* const* srvs, int srvCount,
    ID3D11SamplerState* const* samplers, int samplerCount,
    const void* cbData, size_t cbBytes,
    ID3D11RenderTargetView* rtv, int32_t width, int32_t height)
{
    // Unbind any leftover SRVs before rebinding the render target — a texture from the
    // previous pass may still be bound as an input at these slots (ping-pong).
    ID3D11ShaderResourceView* nullSrvs[4] = {nullptr, nullptr, nullptr, nullptr};
    context_->PSSetShaderResources(0, 4, nullSrvs);
    ID3D11RenderTargetView* nullRtv[1] = {nullptr};
    context_->OMSetRenderTargets(1, nullRtv, nullptr);

    if (cbData && cbBytes > 0)
    {
        UpdateConstantBuffer(cbData, cbBytes);
    }

    context_->IASetInputLayout(nullptr);
    context_->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    context_->VSSetShader(fullscreenVs_.Get(), nullptr, 0);
    context_->PSSetShader(ps, nullptr, 0);

    ID3D11Buffer* cbs[] = {constantBuffer_.Get()};
    context_->PSSetConstantBuffers(0, 1, cbs);

    if (srvCount > 0)
    {
        context_->PSSetShaderResources(0, srvCount, srvs);
    }
    if (samplerCount > 0)
    {
        context_->PSSetSamplers(0, samplerCount, samplers);
    }

    ID3D11RenderTargetView* rtvs[] = {rtv};
    context_->OMSetRenderTargets(1, rtvs, nullptr);

    D3D11_VIEWPORT vp{};
    vp.Width = static_cast<float>(width);
    vp.Height = static_cast<float>(height);
    vp.MinDepth = 0.0f;
    vp.MaxDepth = 1.0f;
    context_->RSSetViewports(1, &vp);

    context_->Draw(3, 0);

    context_->PSSetShaderResources(0, 4, nullSrvs);
    context_->OMSetRenderTargets(1, nullRtv, nullptr);
}

bool GpuCompositor::RunGaussianBlur(GpuTex& source, GpuTex& scratch, GpuTex& out, int32_t width, int32_t height, double radius, std::string& outError)
{
    ID3D11ComputeShader* csH = nullptr;
    ID3D11ComputeShader* csV = nullptr;
    if (!GetOrCompileCS("Blur.hlsl", "BlurHorizontalCS", &csH, outError)) return false;
    if (!GetOrCompileCS("Blur.hlsl", "BlurVerticalCS", &csV, outError)) return false;

    double sigma = std::max(radius, 0.0001) / 3.0;
    int tapRadius = std::min(64, std::max(1, static_cast<int>(std::ceil(sigma * 3.0))));
    BlurCb cb{static_cast<float>(sigma), tapRadius, width, height};

    UINT groupsX = (static_cast<UINT>(width) + 7) / 8;
    UINT groupsY = (static_cast<UINT>(height) + 7) / 8;

    ID3D11ShaderResourceView* nullSrv[1] = {nullptr};
    ID3D11UnorderedAccessView* nullUav[1] = {nullptr};

    // Horizontal: source -> scratch
    UpdateConstantBuffer(&cb, sizeof(cb));
    ID3D11Buffer* cbs[] = {constantBuffer_.Get()};
    context_->CSSetConstantBuffers(0, 1, cbs);
    context_->CSSetShader(csH, nullptr, 0);
    ID3D11ShaderResourceView* srvs[] = {source.srv.Get()};
    context_->CSSetShaderResources(0, 1, srvs);
    ID3D11UnorderedAccessView* uavs[] = {scratch.uav.Get()};
    context_->CSSetUnorderedAccessViews(0, 1, uavs, nullptr);
    context_->Dispatch(groupsX, groupsY, 1);
    context_->CSSetUnorderedAccessViews(0, 1, nullUav, nullptr);
    context_->CSSetShaderResources(0, 1, nullSrv);

    // Vertical: scratch -> out
    context_->CSSetShader(csV, nullptr, 0);
    ID3D11ShaderResourceView* srvs2[] = {scratch.srv.Get()};
    context_->CSSetShaderResources(0, 1, srvs2);
    ID3D11UnorderedAccessView* uavs2[] = {out.uav.Get()};
    context_->CSSetUnorderedAccessViews(0, 1, uavs2, nullptr);
    context_->Dispatch(groupsX, groupsY, 1);
    context_->CSSetUnorderedAccessViews(0, 1, nullUav, nullptr);
    context_->CSSetShaderResources(0, 1, nullSrv);
    context_->CSSetShader(nullptr, nullptr, 0);

    return true;
}

bool GpuCompositor::CreateLutTexture1D(const std::vector<float>& rgba256, GpuTex& out, std::string& outError)
{
    D3D11_TEXTURE2D_DESC td{};
    td.Width = static_cast<UINT>(rgba256.size() / 4);
    td.Height = 1;
    td.MipLevels = 1;
    td.ArraySize = 1;
    td.Format = DXGI_FORMAT_R32G32B32A32_FLOAT;
    td.SampleDesc.Count = 1;
    td.Usage = D3D11_USAGE_IMMUTABLE;
    td.BindFlags = D3D11_BIND_SHADER_RESOURCE;

    D3D11_SUBRESOURCE_DATA sd{};
    sd.pSysMem = rgba256.data();
    sd.SysMemPitch = static_cast<UINT>(td.Width * 4 * sizeof(float));

    out = GpuTex{};
    if (FAILED(device_->CreateTexture2D(&td, &sd, &out.tex)))
    {
        outError = "CreateTexture2D(1D LUT) failed";
        return false;
    }
    if (FAILED(device_->CreateShaderResourceView(out.tex.Get(), nullptr, &out.srv)))
    {
        outError = "CreateShaderResourceView(1D LUT) failed";
        return false;
    }
    out.width = static_cast<int32_t>(td.Width);
    out.height = 1;
    return true;
}

bool GpuCompositor::CreateLutTextureStrip(const std::vector<float>& rgba, int32_t width, int32_t height, GpuTex& out, std::string& outError)
{
    D3D11_TEXTURE2D_DESC td{};
    td.Width = static_cast<UINT>(width);
    td.Height = static_cast<UINT>(height);
    td.MipLevels = 1;
    td.ArraySize = 1;
    td.Format = DXGI_FORMAT_R32G32B32A32_FLOAT;
    td.SampleDesc.Count = 1;
    td.Usage = D3D11_USAGE_IMMUTABLE;
    td.BindFlags = D3D11_BIND_SHADER_RESOURCE;

    D3D11_SUBRESOURCE_DATA sd{};
    sd.pSysMem = rgba.data();
    sd.SysMemPitch = static_cast<UINT>(width * 4 * sizeof(float));

    out = GpuTex{};
    if (FAILED(device_->CreateTexture2D(&td, &sd, &out.tex)))
    {
        outError = "CreateTexture2D(LUT strip) failed";
        return false;
    }
    if (FAILED(device_->CreateShaderResourceView(out.tex.Get(), nullptr, &out.srv)))
    {
        outError = "CreateShaderResourceView(LUT strip) failed";
        return false;
    }
    out.width = width;
    out.height = height;
    return true;
}

bool GpuCompositor::ApplyOneEffect(
    const EffectDescriptorNative& desc, const SnapshotEffect& effect,
    int64_t clipRelativeFrame, int32_t natW, int32_t natH,
    GpuTex& src, GpuTex& dst, std::string& outError)
{
    ID3D11ShaderResourceView* srcSrv = src.srv.Get();
    ID3D11SamplerState* linear = linearClampSampler_.Get();
    ID3D11SamplerState* point = pointClampSampler_.Get();

    switch (desc.kernel)
    {
        case EffectKernel::Levels:
        {
            ID3D11PixelShader* ps = nullptr;
            if (!GetOrCompilePS("Levels.hlsl", "PSMain", &ps, outError)) return false;
            LevelsCb cb{
                static_cast<float>(ResolveParam(effect, desc.params[0], clipRelativeFrame)),
                static_cast<float>(ResolveParam(effect, desc.params[1], clipRelativeFrame)), 0, 0};
            ID3D11ShaderResourceView* srvs[] = {srcSrv};
            ID3D11SamplerState* samplers[] = {linear};
            RunFullscreenPass(ps, srvs, 1, samplers, 1, &cb, sizeof(cb), dst.rtv.Get(), natW, natH);
            return true;
        }
        case EffectKernel::HighlightsShadows:
        {
            ID3D11PixelShader* ps = nullptr;
            if (!GetOrCompilePS("HighlightsShadows.hlsl", "PSMain", &ps, outError)) return false;
            HighlightsShadowsCb cb{
                static_cast<float>(ResolveParam(effect, desc.params[0], clipRelativeFrame)),
                static_cast<float>(ResolveParam(effect, desc.params[1], clipRelativeFrame)), 0, 0};
            ID3D11ShaderResourceView* srvs[] = {srcSrv};
            ID3D11SamplerState* samplers[] = {linear};
            RunFullscreenPass(ps, srvs, 1, samplers, 1, &cb, sizeof(cb), dst.rtv.Get(), natW, natH);
            return true;
        }
        case EffectKernel::Wheels:
        {
            ID3D11PixelShader* ps = nullptr;
            if (!GetOrCompilePS("Wheels.hlsl", "PSMain", &ps, outError)) return false;
            double liftX = ResolveParam(effect, desc.params[0], clipRelativeFrame);
            double liftY = ResolveParam(effect, desc.params[1], clipRelativeFrame);
            double liftM = ResolveParam(effect, desc.params[2], clipRelativeFrame);
            double gammaX = ResolveParam(effect, desc.params[3], clipRelativeFrame);
            double gammaY = ResolveParam(effect, desc.params[4], clipRelativeFrame);
            double gammaM = ResolveParam(effect, desc.params[5], clipRelativeFrame);
            double gainX = ResolveParam(effect, desc.params[6], clipRelativeFrame);
            double gainY = ResolveParam(effect, desc.params[7], clipRelativeFrame);
            double gainM = ResolveParam(effect, desc.params[8], clipRelativeFrame);
            ColorWheels::Coefficients c = ColorWheels::Compute(liftX, liftY, liftM, gammaX, gammaY, gammaM, gainX, gainY, gainM);
            WheelsCb cb{};
            cb.lift[0] = c.liftR; cb.lift[1] = c.liftG; cb.lift[2] = c.liftB; cb.pad0 = 0;
            cb.gain[0] = c.gainR; cb.gain[1] = c.gainG; cb.gain[2] = c.gainB; cb.pad1 = 0;
            cb.invGamma[0] = c.invGammaR; cb.invGamma[1] = c.invGammaG; cb.invGamma[2] = c.invGammaB; cb.pad2 = 0;
            ID3D11ShaderResourceView* srvs[] = {srcSrv};
            ID3D11SamplerState* samplers[] = {linear};
            RunFullscreenPass(ps, srvs, 1, samplers, 1, &cb, sizeof(cb), dst.rtv.Get(), natW, natH);
            return true;
        }
        case EffectKernel::ChromaKey:
        {
            double tolerance = ResolveParam(effect, desc.params[1], clipRelativeFrame);
            if (tolerance <= 0.0)
            {
                return false; // signals "no-op — dst not written"; caller keeps `src` current
            }
            ID3D11PixelShader* ps = nullptr;
            if (!GetOrCompilePS("ChromaKey.hlsl", "PSMain", &ps, outError)) return false;
            ChromaKeyCb cb{
                static_cast<float>(ResolveParam(effect, desc.params[0], clipRelativeFrame)),
                static_cast<float>(tolerance),
                static_cast<float>(ResolveParam(effect, desc.params[2], clipRelativeFrame)),
                static_cast<float>(ResolveParam(effect, desc.params[3], clipRelativeFrame))};
            ID3D11ShaderResourceView* srvs[] = {srcSrv};
            ID3D11SamplerState* samplers[] = {linear};
            RunFullscreenPass(ps, srvs, 1, samplers, 1, &cb, sizeof(cb), dst.rtv.Get(), natW, natH);
            return true;
        }
        case EffectKernel::Vignette:
        {
            double amount = ResolveParam(effect, desc.params[0], clipRelativeFrame);
            if (amount == 0.0)
            {
                return false;
            }
            ID3D11PixelShader* ps = nullptr;
            if (!GetOrCompilePS("Vignette.hlsl", "PSMain", &ps, outError)) return false;
            VignetteCb cb{};
            cb.rect[0] = 0; cb.rect[1] = 0; cb.rect[2] = static_cast<float>(natW); cb.rect[3] = static_cast<float>(natH);
            cb.amount = static_cast<float>(amount);
            cb.midpoint = static_cast<float>(ResolveParam(effect, desc.params[1], clipRelativeFrame));
            cb.roundness = static_cast<float>(ResolveParam(effect, desc.params[2], clipRelativeFrame));
            cb.feather = static_cast<float>(ResolveParam(effect, desc.params[3], clipRelativeFrame));
            ID3D11ShaderResourceView* srvs[] = {srcSrv};
            ID3D11SamplerState* samplers[] = {point};
            RunFullscreenPass(ps, srvs, 1, samplers, 1, &cb, sizeof(cb), dst.rtv.Get(), natW, natH);
            return true;
        }
        case EffectKernel::Grain:
        {
            double amount = ResolveParam(effect, desc.params[0], clipRelativeFrame);
            if (amount <= 0.0)
            {
                return false;
            }
            ID3D11PixelShader* ps = nullptr;
            if (!GetOrCompilePS("Grain.hlsl", "PSMain", &ps, outError)) return false;
            GrainCb cb{};
            cb.amount = static_cast<float>(amount);
            cb.size = static_cast<float>(ResolveParam(effect, desc.params[1], clipRelativeFrame));
            cb.frame = static_cast<float>(clipRelativeFrame);
            cb.pad0 = 0;
            cb.textureSize[0] = static_cast<float>(natW);
            cb.textureSize[1] = static_cast<float>(natH);
            cb.pad1[0] = cb.pad1[1] = 0;
            ID3D11ShaderResourceView* srvs[] = {srcSrv};
            ID3D11SamplerState* samplers[] = {point};
            RunFullscreenPass(ps, srvs, 1, samplers, 1, &cb, sizeof(cb), dst.rtv.Get(), natW, natH);
            return true;
        }
        case EffectKernel::GradeCurves:
        {
            std::string json = ParamString(effect, "curve");
            CurveMath::GradeCurveSet curve;
            if (json.empty() || !CurveMath::ParseGradeCurveJson(json, curve) || CurveMath::IsGradeCurveIdentity(curve))
            {
                return false;
            }
            ID3D11PixelShader* ps = nullptr;
            if (!GetOrCompilePS("GradeCurves.hlsl", "PSMain", &ps, outError)) return false;
            std::vector<float> channels, master;
            CurveMath::BuildGradeCurveLuts(curve, channels, master);
            GpuTex chTex, msTex;
            if (!CreateLutTexture1D(channels, chTex, outError)) return false;
            if (!CreateLutTexture1D(master, msTex, outError)) return false;
            ID3D11ShaderResourceView* srvs[] = {srcSrv, chTex.srv.Get(), msTex.srv.Get()};
            ID3D11SamplerState* samplers[] = {point, linear};
            RunFullscreenPass(ps, srvs, 3, samplers, 2, nullptr, 0, dst.rtv.Get(), natW, natH);
            return true;
        }
        case EffectKernel::HueCurves:
        {
            std::string json = ParamString(effect, "curves");
            CurveMath::HueCurveSet curves;
            if (json.empty() || !CurveMath::ParseHueCurvesJson(json, curves) || CurveMath::IsHueCurveIdentity(curves))
            {
                return false;
            }
            ID3D11PixelShader* ps = nullptr;
            if (!GetOrCompilePS("HueCurves.hlsl", "PSMain", &ps, outError)) return false;
            std::vector<float> lut;
            CurveMath::BuildHueCurveLut(curves, lut);
            GpuTex lutTex;
            if (!CreateLutTexture1D(lut, lutTex, outError)) return false;
            ID3D11ShaderResourceView* srvs[] = {srcSrv, lutTex.srv.Get()};
            ID3D11SamplerState* samplers[] = {point, linearWrapSampler_.Get()};
            RunFullscreenPass(ps, srvs, 2, samplers, 2, nullptr, 0, dst.rtv.Get(), natW, natH);
            return true;
        }
        case EffectKernel::LutTetra:
        {
            std::string path = ParamString(effect, "path");
            if (path.empty())
            {
                return false;
            }
            CubeLutParser::CubeLut cube;
            std::string parseError;
            if (!CubeLutParser::ParseFile(path, cube, parseError))
            {
                return false; // unreadable/invalid LUT file — skip, mirrors LUTTetraKernel's `guard let cube`
            }
            ID3D11PixelShader* ps = nullptr;
            if (!GetOrCompilePS("LUTTetra.hlsl", "PSMain", &ps, outError)) return false;
            GpuTex lutTex;
            if (!CreateLutTextureStrip(cube.rgba, cube.dimension, cube.dimension * cube.dimension, lutTex, outError)) return false;
            LutTetraCb cb{static_cast<float>(cube.dimension),
                static_cast<float>(ResolveParam(effect, desc.params[0], clipRelativeFrame)), 0, 0};
            ID3D11ShaderResourceView* srvs[] = {srcSrv, lutTex.srv.Get()};
            ID3D11SamplerState* samplers[] = {point, point};
            RunFullscreenPass(ps, srvs, 2, samplers, 2, &cb, sizeof(cb), dst.rtv.Get(), natW, natH);
            return true;
        }
        case EffectKernel::Clarity:
        {
            double clarity = ResolveParam(effect, desc.params[0], clipRelativeFrame);
            double dehaze = ResolveParam(effect, desc.params[1], clipRelativeFrame);
            if (clarity == 0.0 && dehaze == 0.0)
            {
                return false;
            }
            GpuTex blurScratch, blurred;
            if (!CreateWorkingTexture(natW, natH, true, blurScratch, outError)) return false;
            if (!CreateWorkingTexture(natW, natH, true, blurred, outError)) return false;
            double radius = std::max(natW, natH) / 40.0;
            if (!RunGaussianBlur(src, blurScratch, blurred, natW, natH, radius, outError)) return false;

            ID3D11PixelShader* ps = nullptr;
            if (!GetOrCompilePS("Clarity.hlsl", "PSMain", &ps, outError)) return false;
            ClarityCb cb{static_cast<float>(clarity), static_cast<float>(dehaze), 0, 0};
            ID3D11ShaderResourceView* srvs[] = {srcSrv, blurred.srv.Get()};
            ID3D11SamplerState* samplers[] = {point};
            RunFullscreenPass(ps, srvs, 2, samplers, 1, &cb, sizeof(cb), dst.rtv.Get(), natW, natH);
            return true;
        }
        case EffectKernel::Glow:
        {
            double intensity = ResolveParam(effect, desc.params[0], clipRelativeFrame);
            if (intensity <= 0.0)
            {
                return false;
            }
            double radius = ResolveParam(effect, desc.params[1], clipRelativeFrame);
            double threshold = ResolveParam(effect, desc.params[2], clipRelativeFrame);
            double warmth = ResolveParam(effect, desc.params[3], clipRelativeFrame);

            GpuTex bright;
            if (!CreateWorkingTexture(natW, natH, false, bright, outError)) return false;
            ID3D11PixelShader* brightPs = nullptr;
            if (!GetOrCompilePS("GlowBright.hlsl", "PSMain", &brightPs, outError)) return false;
            GlowBrightCb brightCb{static_cast<float>(threshold), static_cast<float>(warmth), 0, 0};
            ID3D11ShaderResourceView* brightSrvs[] = {srcSrv};
            ID3D11SamplerState* brightSamplers[] = {linear};
            RunFullscreenPass(brightPs, brightSrvs, 1, brightSamplers, 1, &brightCb, sizeof(brightCb), bright.rtv.Get(), natW, natH);

            GpuTex blurScratch, blurred;
            if (!CreateWorkingTexture(natW, natH, true, blurScratch, outError)) return false;
            if (!CreateWorkingTexture(natW, natH, true, blurred, outError)) return false;
            if (!RunGaussianBlur(bright, blurScratch, blurred, natW, natH, radius, outError)) return false;

            ID3D11PixelShader* compositePs = nullptr;
            if (!GetOrCompilePS("GlowComposite.hlsl", "PSMain", &compositePs, outError)) return false;
            GlowCompositeCb compositeCb{static_cast<float>(intensity), 0, 0, 0};
            ID3D11ShaderResourceView* compositeSrvs[] = {srcSrv, blurred.srv.Get()};
            ID3D11SamplerState* compositeSamplers[] = {point};
            RunFullscreenPass(compositePs, compositeSrvs, 2, compositeSamplers, 1, &compositeCb, sizeof(compositeCb), dst.rtv.Get(), natW, natH);
            return true;
        }
    }
    outError = "unreachable EffectKernel";
    return false;
}

bool GpuCompositor::ApplyEffectChain(
    const std::vector<SnapshotEffect>& effects, int64_t clipRelativeFrame, int32_t natW, int32_t natH,
    GpuTex& natA, GpuTex& natB, GpuTex*& current, std::string& outError)
{
    bool altAllocated = false;
    for (const SnapshotEffect& effect : effects)
    {
        if (!effect.enabled)
        {
            continue;
        }
        const EffectDescriptorNative* desc = EffectRegistry::Find(effect.type);
        if (!desc)
        {
            continue; // unregistered effect type (out of E3 scope, e.g. a CIFilter-only
                      // effect like color.exposure) — skip, not fatal.
        }
        if (!altAllocated)
        {
            if (!CreateWorkingTexture(natW, natH, false, natB, outError))
            {
                return false;
            }
            altAllocated = true;
        }
        GpuTex& src = *current;
        GpuTex& dst = (current == &natA) ? natB : natA;
        std::string effectError;
        if (ApplyOneEffect(*desc, effect, clipRelativeFrame, natW, natH, src, dst, effectError))
        {
            current = &dst;
        }
        else if (!effectError.empty())
        {
            outError = effectError;
            return false; // genuine failure (shader compile/resource creation)
        }
        // else: effect was a documented no-op for these params (e.g. amount==0) — `current`
        // stays on `src`, matching every Swift kernel wrapper's own `guard ... else { return
        // image }` early-out.
    }
    return true;
}

bool GpuCompositor::ComposeTextClip(
    const SnapshotTextClip& textClip, int64_t frame, int32_t canvasWidth, int32_t canvasHeight,
    int& current, std::string& outError)
{
    int64_t clipRelativeFrame = frame - textClip.startFrame;
    // composedTextLayer's alpha gate (FrameRenderer.swift:283-284): opacityAt <= 0 -> nothing.
    double alpha = std::min(1.0, std::max(0.0, textClip.OpacityAt(clipRelativeFrame)));
    if (alpha <= 0.0)
    {
        return true;
    }

    if (!textRenderer_)
    {
        textRenderer_ = std::make_unique<TextRenderer>();
    }
    TextRenderer::Raster raster;
    if (!textRenderer_->Render(textClip, frame, canvasWidth, canvasHeight, raster, outError))
    {
        return false;
    }
    if (raster.Empty())
    {
        return true; // empty content / faded-out entrance / all-whitespace — skip, not an error
    }

    // Upload the straight-alpha raster and ingest (straight -> premultiplied) exactly like a
    // decoded clip frame — the text raster IS a DecodedSourceFrame in every respect.
    DecodedSourceFrame decoded{raster.bgra.data(), raster.width, raster.height, raster.strideBytes};
    GpuTex uploadTex;
    if (!CreateUploadTexture(raster.width, raster.height, uploadTex, outError))
    {
        return false;
    }
    if (!UploadBgra(uploadTex, decoded, outError))
    {
        return false;
    }

    GpuTex natA;
    if (!CreateWorkingTexture(raster.width, raster.height, false, natA, outError))
    {
        return false;
    }
    ID3D11PixelShader* ingestPs = nullptr;
    if (!GetOrCompilePS("Ingest.hlsl", "PSMain", &ingestPs, outError))
    {
        return false;
    }
    ID3D11ShaderResourceView* ingestSrvs[] = {uploadTex.srv.Get()};
    ID3D11SamplerState* ingestSamplers[] = {pointClampSampler_.Get()};
    RunFullscreenPass(ingestPs, ingestSrvs, 1, ingestSamplers, 1, nullptr, 0, natA.rtv.Get(), raster.width, raster.height);

    // Effects apply AFTER rasterizing, same order as composedTextLayer (swift:288-295).
    GpuTex* natCurrent = &natA;
    GpuTex natB;
    if (!ApplyEffectChain(textClip.effects, clipRelativeFrame, raster.width, raster.height, natA, natB, natCurrent, outError))
    {
        return false;
    }

    // Identity transform/crop: the box position + wrap is already baked into the canvas-sized
    // raster (TextRenderer), and composedTextLayer composites text flat with no affine. Opacity +
    // blend mode flow through the standard composite pass, matching any other clip.
    SnapshotTransform identity;
    SnapshotCrop identityCrop;
    int blendIndex = textClip.IsNormalBlend() ? 0 : BlendModeToIndex(textClip.blendMode);
    int next = 1 - current;
    RunCompositePass(*natCurrent, accum_[current], accum_[next], identity, identityCrop, alpha, blendIndex, canvasWidth, canvasHeight);
    current = next;
    return true;
}

void GpuCompositor::RunCompositePass(
    GpuTex& source, GpuTex& backdrop, GpuTex& target,
    const SnapshotTransform& transform, const SnapshotCrop& crop,
    double opacity, int blendModeIndex,
    int32_t canvasWidth, int32_t canvasHeight)
{
    Affine2D forward = BuildClipAffine(transform, source.width, source.height, canvasWidth, canvasHeight);
    Affine2D inverse = forward.Inverted();
    CropRectPixels cropRect = ResolveCropRect(crop, source.width, source.height);

    ID3D11PixelShader* ps = nullptr;
    std::string error;
    if (!GetOrCompilePS("Composite.hlsl", "PSMain", &ps, error))
    {
        return; // caller already validated the shader compiles during a prior effect/ingest
                // pass in the vast majority of real runs; a first-ever call failing here would
                // silently pass the backdrop through unchanged rather than crash.
    }

    CompositeCb cb{};
    cb.invRow0[0] = static_cast<float>(inverse.a);
    cb.invRow0[1] = static_cast<float>(inverse.b);
    cb.invRow0[2] = static_cast<float>(inverse.c);
    cb.invRow0[3] = static_cast<float>(inverse.d);
    cb.invRow1[0] = static_cast<float>(inverse.tx);
    cb.invRow1[1] = static_cast<float>(inverse.ty);
    cb.invRow1[2] = static_cast<float>(source.width);
    cb.invRow1[3] = static_cast<float>(source.height);
    cb.cropRect[0] = static_cast<float>(cropRect.x0);
    cb.cropRect[1] = static_cast<float>(cropRect.y0);
    cb.cropRect[2] = static_cast<float>(cropRect.x1);
    cb.cropRect[3] = static_cast<float>(cropRect.y1);
    cb.params[0] = static_cast<float>(opacity);
    cb.params[1] = static_cast<float>(blendModeIndex);
    cb.params[2] = static_cast<float>(canvasWidth);
    cb.params[3] = static_cast<float>(canvasHeight);

    ID3D11ShaderResourceView* srvs[] = {source.srv.Get(), backdrop.srv.Get()};
    ID3D11SamplerState* samplers[] = {linearClampSampler_.Get()};
    RunFullscreenPass(ps, srvs, 2, samplers, 1, &cb, sizeof(cb), target.rtv.Get(), canvasWidth, canvasHeight);
}

bool GpuCompositor::EnsureAccumulators(int32_t width, int32_t height, std::string& outError)
{
    if (accum_[0].width == width && accum_[0].height == height && accum_[0].tex)
    {
        return true;
    }
    if (!CreateWorkingTexture(width, height, false, accum_[0], outError)) return false;
    if (!CreateWorkingTexture(width, height, false, accum_[1], outError)) return false;
    return true;
}

bool GpuCompositor::ReadbackToBgra8(GpuTex& source, int32_t width, int32_t height, ComposeResult& outResult, std::string& outError)
{
    if (!stagingTex_ || stagingWidth_ != width || stagingHeight_ != height)
    {
        D3D11_TEXTURE2D_DESC td{};
        td.Width = static_cast<UINT>(width);
        td.Height = static_cast<UINT>(height);
        td.MipLevels = 1;
        td.ArraySize = 1;
        td.Format = DXGI_FORMAT_R16G16B16A16_FLOAT;
        td.SampleDesc.Count = 1;
        td.Usage = D3D11_USAGE_STAGING;
        td.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
        stagingTex_.Reset();
        if (FAILED(device_->CreateTexture2D(&td, nullptr, &stagingTex_)))
        {
            outError = "CreateTexture2D(readback staging) failed";
            return false;
        }
        stagingWidth_ = width;
        stagingHeight_ = height;
    }

    context_->CopyResource(stagingTex_.Get(), source.tex.Get());

    D3D11_MAPPED_SUBRESOURCE mapped{};
    HRESULT hr = context_->Map(stagingTex_.Get(), 0, D3D11_MAP_READ, 0, &mapped);
    if (FAILED(hr))
    {
        outError = "Map(readback staging) failed";
        return false;
    }

    ComposeResult result;
    result.width = width;
    result.height = height;
    result.strideBytes = width * 4;
    result.bgra.resize(static_cast<size_t>(result.strideBytes) * height);

    const auto* src = static_cast<const uint8_t*>(mapped.pData);
    for (int32_t y = 0; y < height; ++y)
    {
        const auto* row = reinterpret_cast<const Half*>(src + static_cast<size_t>(y) * mapped.RowPitch);
        uint8_t* outRow = result.bgra.data() + static_cast<size_t>(y) * result.strideBytes;
        for (int32_t x = 0; x < width; ++x)
        {
            const Half* px = row + static_cast<size_t>(x) * 4;
            // Texture channel order is RGBA (DXGI_FORMAT_R16G16B16A16_FLOAT); ComposeResult is
            // BGRA — swap R/B here, matching Compositor.cpp's BGRA accumulator convention.
            outRow[x * 4 + 0] = HalfChannelTo8Bit(px[2]); // B
            outRow[x * 4 + 1] = HalfChannelTo8Bit(px[1]); // G
            outRow[x * 4 + 2] = HalfChannelTo8Bit(px[0]); // R
            outRow[x * 4 + 3] = HalfChannelTo8Bit(px[3]); // A
        }
    }
    context_->Unmap(stagingTex_.Get(), 0);

    outResult = std::move(result);
    return true;
}

bool GpuCompositor::Compose(
    const TimelineSnapshot& snapshot,
    int64_t frame,
    const ClipFrameProvider& provider,
    const std::atomic<int32_t>* cancelFlag,
    ComposeResult& outResult,
    std::string& outError)
{
    if (!EnsureCommonResources(outError))
    {
        return false;
    }

    int32_t w = std::max(1, snapshot.outputWidth);
    int32_t h = std::max(1, snapshot.outputHeight);
    double fps = snapshot.Fps();

    if (!EnsureAccumulators(w, h, outError))
    {
        return false;
    }

    float clearColor[4] = {0.0f, 0.0f, 0.0f, 1.0f}; // opaque black, matching Compositor.cpp
    context_->ClearRenderTargetView(accum_[0].rtv.Get(), clearColor);
    int current = 0;

    for (const SnapshotTrack& track : snapshot.tracks)
    {
        if (track.type != SnapshotTrackType::Video)
        {
            continue;
        }
        if (cancelFlag && cancelFlag->load(std::memory_order_relaxed) != 0)
        {
            outError = "cancelled";
            return false;
        }

        const SnapshotClip* active = nullptr;
        for (const SnapshotClip& clip : track.clips)
        {
            if (clip.ContainsFrame(frame))
            {
                active = &clip;
                break;
            }
        }

        // Active video clip (at most one, non-overlapping). Wrapped so a decode miss `break`s out
        // of ONLY the video path — a text-only track (clips: []) or a video clip that fails to
        // decode must still fall through to this track's text clips below (§12.2), not skip them.
        if (active && active->type != SnapshotClipType::Audio)
        {
            int64_t clipRelativeFrame = frame - active->startFrame;
            double alpha = std::min(1.0, std::max(0.0, active->OpacityAt(clipRelativeFrame)));
            if (alpha > 0.0)
            {
                do
                {
                    double sourceSeconds = active->type == SnapshotClipType::Image
                        ? 0.0
                        : Compositor::SourceSeconds(*active, frame, fps);

                    DecodedSourceFrame decoded{};
                    if (!provider(*active, sourceSeconds, decoded) || !decoded.bgra || decoded.width <= 0 || decoded.height <= 0)
                    {
                        break;
                    }

                    GpuTex uploadTex;
                    if (!CreateUploadTexture(decoded.width, decoded.height, uploadTex, outError))
                    {
                        return false;
                    }
                    if (!UploadBgra(uploadTex, decoded, outError))
                    {
                        return false;
                    }

                    GpuTex natA;
                    if (!CreateWorkingTexture(decoded.width, decoded.height, false, natA, outError))
                    {
                        return false;
                    }
                    ID3D11PixelShader* ingestPs = nullptr;
                    if (!GetOrCompilePS("Ingest.hlsl", "PSMain", &ingestPs, outError))
                    {
                        return false;
                    }
                    ID3D11ShaderResourceView* ingestSrvs[] = {uploadTex.srv.Get()};
                    ID3D11SamplerState* ingestSamplers[] = {pointClampSampler_.Get()};
                    RunFullscreenPass(ingestPs, ingestSrvs, 1, ingestSamplers, 1, nullptr, 0, natA.rtv.Get(), decoded.width, decoded.height);

                    GpuTex* natCurrent = &natA;
                    GpuTex natB;
                    if (!ApplyEffectChain(active->effects, clipRelativeFrame, decoded.width, decoded.height, natA, natB, natCurrent, outError))
                    {
                        return false;
                    }

                    SnapshotTransform transform = active->TransformAt(clipRelativeFrame);
                    SnapshotCrop crop = active->CropAt(clipRelativeFrame);
                    int blendIndex = active->IsNormalBlend() ? 0 : BlendModeToIndex(active->blendMode);

                    int next = 1 - current;
                    RunCompositePass(*natCurrent, accum_[current], accum_[next], transform, crop, alpha, blendIndex, w, h);
                    current = next;
                } while (false);
            }
        }

        // Text clips paint OVER this track's video, in startFrame order (the builder emits textClips
        // startFrame-ordered — §12.2). Within-track video-vs-text interleave by startFrame is not
        // reproduced (video always painted first here); real captions live on dedicated text-only
        // tracks, and cross-track z-order — the order that actually matters — is preserved exactly by
        // walking snapshot.tracks in paint order (§2). Documented deviation.
        for (const SnapshotTextClip& textClip : track.textClips)
        {
            if (!textClip.ContainsFrame(frame))
            {
                continue;
            }
            if (cancelFlag && cancelFlag->load(std::memory_order_relaxed) != 0)
            {
                outError = "cancelled";
                return false;
            }
            if (!ComposeTextClip(textClip, frame, w, h, current, outError))
            {
                return false;
            }
        }
    }

    return ReadbackToBgra8(accum_[current], w, h, outResult, outError);
}
