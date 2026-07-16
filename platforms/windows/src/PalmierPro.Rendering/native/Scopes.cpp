#include "Scopes.h"

#include <d3dcompiler.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <fstream>
#include <sstream>

using Microsoft::WRL::ComPtr;

namespace
{
    // Packed histogram buffer layout (doc §3): [0,256)=Y [256,512)=R [512,768)=G [768,1024)=B
    // [1024,1120)=hue (fixed-point).
    constexpr int32_t kHistogramLength = 4 * PE_COLOR_SCOPES_RGB_BINS + PE_COLOR_SCOPES_HUE_BINS;
    constexpr float kHueFixedPointScale = 32768.0f; // doc §3: 2^15, ~2.3x headroom under UINT32_MAX

    // Mirrors GpuCompositor.cpp's ID3DInclude handler — duplicated rather than shared so this
    // class has no dependency on GpuCompositor's private members (it only ever touches
    // GpuCompositor through the SRV/dimensions Compute() is handed).
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

    void AnchorFunction() {}

    struct DownsampleCb { uint32_t sourceWidth, sourceHeight, gridWidth, gridHeight; };
    struct HistogramCb { uint32_t gridWidth, gridHeight, pad0, pad1; };
}

Scopes::Scopes(ID3D11Device* device, ID3D11DeviceContext* context)
    : device_(device), context_(context)
{
}

Scopes::~Scopes() = default;

bool Scopes::ResolveShadersDir(std::string& outError)
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

bool Scopes::GetOrCompileCS(const std::string& file, const std::string& entry, ID3D11ComputeShader** outCs, std::string& outError)
{
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
        outError = "D3DCompile(" + file + ":" + entry + ") failed";
        if (errorBlob) outError += ": " + std::string(static_cast<const char*>(errorBlob->GetBufferPointer()), errorBlob->GetBufferSize());
        return false;
    }
    ComPtr<ID3D11ComputeShader> cs;
    hr = device_->CreateComputeShader(blob->GetBufferPointer(), blob->GetBufferSize(), nullptr, &cs);
    if (FAILED(hr))
    {
        outError = "CreateComputeShader(" + file + ":" + entry + ") failed";
        return false;
    }
    *outCs = cs.Get();
    if (file == "ScopesDownsample.hlsl") downsampleCs_ = cs; else histogramCs_ = cs;
    return true;
}

bool Scopes::EnsureDeviceResources(std::string& outError)
{
    if (!constantBuffer_)
    {
        D3D11_BUFFER_DESC bd{};
        bd.ByteWidth = 16;
        bd.Usage = D3D11_USAGE_DEFAULT;
        bd.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
        if (FAILED(device_->CreateBuffer(&bd, nullptr, &constantBuffer_)))
        {
            outError = "CreateBuffer(scopes constant buffer) failed";
            return false;
        }
    }
    if (!histogramBuffer_)
    {
        D3D11_BUFFER_DESC bd{};
        bd.ByteWidth = static_cast<UINT>(kHistogramLength) * sizeof(uint32_t);
        bd.Usage = D3D11_USAGE_DEFAULT;
        bd.BindFlags = D3D11_BIND_UNORDERED_ACCESS;
        bd.MiscFlags = D3D11_RESOURCE_MISC_BUFFER_STRUCTURED;
        bd.StructureByteStride = sizeof(uint32_t);
        if (FAILED(device_->CreateBuffer(&bd, nullptr, &histogramBuffer_)))
        {
            outError = "CreateBuffer(scopes histogram buffer) failed";
            return false;
        }
        D3D11_UNORDERED_ACCESS_VIEW_DESC uavDesc{};
        uavDesc.Format = DXGI_FORMAT_UNKNOWN;
        uavDesc.ViewDimension = D3D11_UAV_DIMENSION_BUFFER;
        uavDesc.Buffer.FirstElement = 0;
        uavDesc.Buffer.NumElements = static_cast<UINT>(kHistogramLength);
        if (FAILED(device_->CreateUnorderedAccessView(histogramBuffer_.Get(), &uavDesc, &histogramUav_)))
        {
            outError = "CreateUnorderedAccessView(scopes histogram buffer) failed";
            return false;
        }
        D3D11_BUFFER_DESC sbd{};
        sbd.ByteWidth = bd.ByteWidth;
        sbd.Usage = D3D11_USAGE_STAGING;
        sbd.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
        if (FAILED(device_->CreateBuffer(&sbd, nullptr, &histogramStaging_)))
        {
            outError = "CreateBuffer(scopes histogram staging) failed";
            return false;
        }
    }
    return true;
}

bool Scopes::EnsureGrid(int32_t gridW, int32_t gridH, std::string& outError)
{
    if (gridTex_ && gridCapacityW_ == gridW && gridCapacityH_ == gridH)
    {
        return true;
    }
    D3D11_TEXTURE2D_DESC td{};
    td.Width = static_cast<UINT>(gridW);
    td.Height = static_cast<UINT>(gridH);
    td.MipLevels = 1;
    td.ArraySize = 1;
    td.Format = DXGI_FORMAT_R16G16B16A16_FLOAT;
    td.SampleDesc.Count = 1;
    td.Usage = D3D11_USAGE_DEFAULT;
    td.BindFlags = D3D11_BIND_SHADER_RESOURCE | D3D11_BIND_UNORDERED_ACCESS;

    gridTex_.Reset();
    gridSrv_.Reset();
    gridUav_.Reset();
    if (FAILED(device_->CreateTexture2D(&td, nullptr, &gridTex_)))
    {
        outError = "CreateTexture2D(scopes grid) failed";
        return false;
    }
    if (FAILED(device_->CreateShaderResourceView(gridTex_.Get(), nullptr, &gridSrv_)))
    {
        outError = "CreateShaderResourceView(scopes grid) failed";
        return false;
    }
    if (FAILED(device_->CreateUnorderedAccessView(gridTex_.Get(), nullptr, &gridUav_)))
    {
        outError = "CreateUnorderedAccessView(scopes grid) failed";
        return false;
    }
    gridCapacityW_ = gridW;
    gridCapacityH_ = gridH;
    return true;
}

void Scopes::UpdateConstantBuffer(const void* data, size_t bytes)
{
    uint8_t buffer[16]{};
    std::memcpy(buffer, data, std::min(bytes, sizeof(buffer)));
    context_->UpdateSubresource(constantBuffer_.Get(), 0, nullptr, buffer, 0, 0);
}

bool Scopes::Compute(ID3D11ShaderResourceView* source, int32_t width, int32_t height,
    PE_ColorScopesResult& outResult, std::string& outError)
{
    if (!source || width <= 0 || height <= 0)
    {
        outError = "Scopes::Compute: invalid source";
        return false;
    }
    if (!EnsureDeviceResources(outError))
    {
        return false;
    }

    // doc §3: scale = min(1, min(320/width, 180/height)); gridW/gridH = round(dim * scale).
    double scale = std::min(1.0, std::min(
        static_cast<double>(PE_COLOR_SCOPES_MAX_GRID_WIDTH) / width,
        static_cast<double>(PE_COLOR_SCOPES_MAX_GRID_HEIGHT) / height));
    int32_t gridW = std::max(1, static_cast<int32_t>(std::lround(width * scale)));
    int32_t gridH = std::max(1, static_cast<int32_t>(std::lround(height * scale)));

    if (!EnsureGrid(gridW, gridH, outError))
    {
        return false;
    }

    ID3D11ComputeShader* downsampleCs = downsampleCs_.Get();
    if (!downsampleCs && !GetOrCompileCS("ScopesDownsample.hlsl", "DownsampleCS", &downsampleCs, outError))
    {
        return false;
    }
    ID3D11ComputeShader* histogramCs = histogramCs_.Get();
    if (!histogramCs && !GetOrCompileCS("ScopesHistogram.hlsl", "HistogramCS", &histogramCs, outError))
    {
        return false;
    }

    UINT groupsX = (static_cast<UINT>(gridW) + 7) / 8;
    UINT groupsY = (static_cast<UINT>(gridH) + 7) / 8;

    ID3D11ShaderResourceView* nullSrv[1] = {nullptr};
    ID3D11UnorderedAccessView* nullUav[1] = {nullptr};
    ID3D11Buffer* cbs[] = {constantBuffer_.Get()};

    // Pass 1: box-filter downsample, source -> grid.
    DownsampleCb dcb{static_cast<uint32_t>(width), static_cast<uint32_t>(height),
        static_cast<uint32_t>(gridW), static_cast<uint32_t>(gridH)};
    UpdateConstantBuffer(&dcb, sizeof(dcb));
    context_->CSSetConstantBuffers(0, 1, cbs);
    context_->CSSetShader(downsampleCs, nullptr, 0);
    ID3D11ShaderResourceView* downsampleSrvs[] = {source};
    context_->CSSetShaderResources(0, 1, downsampleSrvs);
    ID3D11UnorderedAccessView* gridUavs[] = {gridUav_.Get()};
    context_->CSSetUnorderedAccessViews(0, 1, gridUavs, nullptr);
    context_->Dispatch(groupsX, groupsY, 1);
    context_->CSSetUnorderedAccessViews(0, 1, nullUav, nullptr);
    context_->CSSetShaderResources(0, 1, nullSrv);

    // Pass 2: combined Y/R/G/B + hue histogram, grid -> packed buffer.
    UINT zero[4] = {0, 0, 0, 0};
    context_->ClearUnorderedAccessViewUint(histogramUav_.Get(), zero);

    HistogramCb hcb{static_cast<uint32_t>(gridW), static_cast<uint32_t>(gridH), 0, 0};
    UpdateConstantBuffer(&hcb, sizeof(hcb));
    context_->CSSetConstantBuffers(0, 1, cbs);
    context_->CSSetShader(histogramCs, nullptr, 0);
    ID3D11ShaderResourceView* histogramSrvs[] = {gridSrv_.Get()};
    context_->CSSetShaderResources(0, 1, histogramSrvs);
    ID3D11UnorderedAccessView* histogramUavs[] = {histogramUav_.Get()};
    context_->CSSetUnorderedAccessViews(0, 1, histogramUavs, nullptr);
    context_->Dispatch(groupsX, groupsY, 1);
    context_->CSSetUnorderedAccessViews(0, 1, nullUav, nullptr);
    context_->CSSetShaderResources(0, 1, nullSrv);
    context_->CSSetShader(nullptr, nullptr, 0);

    context_->CopyResource(histogramStaging_.Get(), histogramBuffer_.Get());
    D3D11_MAPPED_SUBRESOURCE mapped{};
    HRESULT hr = context_->Map(histogramStaging_.Get(), 0, D3D11_MAP_READ, 0, &mapped);
    if (FAILED(hr))
    {
        outError = "Map(scopes histogram staging) failed";
        return false;
    }
    std::array<uint32_t, kHistogramLength> raw{};
    std::memcpy(raw.data(), mapped.pData, raw.size() * sizeof(uint32_t));
    context_->Unmap(histogramStaging_.Get(), 0);

    // doc §2.1: joint-max normalize Y/R/G/B — ONE shared scalar across all four, not four
    // independent per-channel maxes.
    float maxV = 0.0f;
    for (int32_t i = 0; i < PE_COLOR_SCOPES_RGB_BINS; ++i)
    {
        outResult.yHistogram[i] = static_cast<float>(raw[i]);
        outResult.rHistogram[i] = static_cast<float>(raw[PE_COLOR_SCOPES_RGB_BINS + i]);
        outResult.gHistogram[i] = static_cast<float>(raw[2 * PE_COLOR_SCOPES_RGB_BINS + i]);
        outResult.bHistogram[i] = static_cast<float>(raw[3 * PE_COLOR_SCOPES_RGB_BINS + i]);
        maxV = std::max({maxV, outResult.yHistogram[i], outResult.rHistogram[i], outResult.gHistogram[i], outResult.bHistogram[i]});
    }
    if (maxV > 0.0f)
    {
        for (int32_t i = 0; i < PE_COLOR_SCOPES_RGB_BINS; ++i)
        {
            outResult.yHistogram[i] /= maxV;
            outResult.rHistogram[i] /= maxV;
            outResult.gHistogram[i] /= maxV;
            outResult.bHistogram[i] /= maxV;
        }
    }

    // doc §2.2: hue — unscale from fixed-point, max-normalize, then sqrt-compress.
    float hueMax = 0.0f;
    for (int32_t i = 0; i < PE_COLOR_SCOPES_HUE_BINS; ++i)
    {
        float v = static_cast<float>(raw[4 * PE_COLOR_SCOPES_RGB_BINS + i]) / kHueFixedPointScale;
        outResult.hueHistogram[i] = v;
        hueMax = std::max(hueMax, v);
    }
    if (hueMax > 0.0f)
    {
        for (int32_t i = 0; i < PE_COLOR_SCOPES_HUE_BINS; ++i)
        {
            outResult.hueHistogram[i] = std::sqrt(outResult.hueHistogram[i] / hueMax);
        }
    }

    return true;
}
