#include "D3D11Presenter.h"

#include <d3dcompiler.h>

#include <algorithm>
#include <cstring>

using Microsoft::WRL::ComPtr;

namespace
{
    // Full-screen triangle from SV_VertexID — no vertex/index buffer needed.
    constexpr char kVertexShaderSource[] = R"(
struct VSOut { float4 pos : SV_POSITION; float2 uv : TEXCOORD0; };
VSOut VSMain(uint id : SV_VertexID)
{
    VSOut o;
    float2 uv = float2((id << 1) & 2, id & 2);
    o.uv = uv;
    o.pos = float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, 0.0, 1.0);
    return o;
}
)";

    constexpr char kPixelShaderSource[] = R"(
Texture2D frameTex : register(t0);
SamplerState frameSampler : register(s0);
float4 PSMain(float4 pos : SV_POSITION, float2 uv : TEXCOORD0) : SV_TARGET
{
    return frameTex.Sample(frameSampler, uv);
}
)";

    bool CompileShader(const char* source, size_t length, const char* entryPoint, const char* target,
        ID3DBlob** outBlob, std::string& outError)
    {
        ComPtr<ID3DBlob> errorBlob;
        HRESULT hr = D3DCompile(source, length, nullptr, nullptr, nullptr, entryPoint, target, 0, 0, outBlob, &errorBlob);
        if (FAILED(hr))
        {
            outError = "D3DCompile failed for ";
            outError += entryPoint;
            if (errorBlob)
            {
                outError += ": ";
                outError.append(static_cast<const char*>(errorBlob->GetBufferPointer()), errorBlob->GetBufferSize());
            }
            return false;
        }
        return true;
    }
}

bool D3D11Presenter::EnsureShaders(std::string& outError)
{
    if (vs_ && ps_ && sampler_)
    {
        return true;
    }

    ComPtr<ID3DBlob> vsBlob;
    if (!CompileShader(kVertexShaderSource, sizeof(kVertexShaderSource) - 1, "VSMain", "vs_5_0", &vsBlob, outError))
    {
        return false;
    }
    HRESULT hr = device_->CreateVertexShader(vsBlob->GetBufferPointer(), vsBlob->GetBufferSize(), nullptr, &vs_);
    if (FAILED(hr))
    {
        outError = "CreateVertexShader failed";
        return false;
    }

    ComPtr<ID3DBlob> psBlob;
    if (!CompileShader(kPixelShaderSource, sizeof(kPixelShaderSource) - 1, "PSMain", "ps_5_0", &psBlob, outError))
    {
        return false;
    }
    hr = device_->CreatePixelShader(psBlob->GetBufferPointer(), psBlob->GetBufferSize(), nullptr, &ps_);
    if (FAILED(hr))
    {
        outError = "CreatePixelShader failed";
        return false;
    }

    D3D11_SAMPLER_DESC sd{};
    sd.Filter = D3D11_FILTER_MIN_MAG_MIP_LINEAR;
    sd.AddressU = D3D11_TEXTURE_ADDRESS_CLAMP;
    sd.AddressV = D3D11_TEXTURE_ADDRESS_CLAMP;
    sd.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
    sd.ComparisonFunc = D3D11_COMPARISON_NEVER;
    sd.MaxLOD = D3D11_FLOAT32_MAX;
    hr = device_->CreateSamplerState(&sd, &sampler_);
    if (FAILED(hr))
    {
        outError = "CreateSamplerState failed";
        return false;
    }

    return true;
}

bool D3D11Presenter::EnsureFrameTexture(int32_t width, int32_t height, std::string& outError)
{
    if (frameTex_ && frameSrv_ && frameTexWidth_ == width && frameTexHeight_ == height)
    {
        return true;
    }

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

    frameSrv_.Reset();
    frameTex_.Reset();

    HRESULT hr = device_->CreateTexture2D(&td, nullptr, &frameTex_);
    if (FAILED(hr))
    {
        outError = "CreateTexture2D (frame upload texture) failed";
        return false;
    }
    hr = device_->CreateShaderResourceView(frameTex_.Get(), nullptr, &frameSrv_);
    if (FAILED(hr))
    {
        outError = "CreateShaderResourceView (frame upload texture) failed";
        return false;
    }

    frameTexWidth_ = width;
    frameTexHeight_ = height;
    return true;
}

bool D3D11Presenter::CreateRtv(std::string& outError)
{
    ComPtr<ID3D11Texture2D> backBuffer;
    HRESULT hr = swapChain_->GetBuffer(0, IID_PPV_ARGS(&backBuffer));
    if (FAILED(hr))
    {
        outError = "IDXGISwapChain1::GetBuffer failed";
        return false;
    }
    hr = device_->CreateRenderTargetView(backBuffer.Get(), nullptr, &rtv_);
    if (FAILED(hr))
    {
        outError = "CreateRenderTargetView failed";
        return false;
    }
    return true;
}

bool D3D11Presenter::Attach(ID3D11Device* device, ID3D11DeviceContext* context, void* swapChainPanelUnknown,
    int32_t width, int32_t height, std::string& outError)
{
    if (!device || !context || !swapChainPanelUnknown || width <= 0 || height <= 0)
    {
        outError = "invalid PE_AttachSwapChain arguments";
        return false;
    }

    ComPtr<ISwapChainPanelNative> panelNative;
    HRESULT hr = reinterpret_cast<IUnknown*>(swapChainPanelUnknown)->QueryInterface(IID_PPV_ARGS(&panelNative));
    if (FAILED(hr))
    {
        outError = "QueryInterface(ISwapChainPanelNative) failed — is this a SwapChainPanel?";
        return false;
    }

    Detach();

    device_ = device;
    context_ = context;

    ComPtr<IDXGIDevice> dxgiDevice;
    hr = device_.As(&dxgiDevice);
    if (FAILED(hr))
    {
        outError = "QueryInterface(IDXGIDevice) failed";
        return false;
    }
    ComPtr<IDXGIAdapter> adapter;
    hr = dxgiDevice->GetAdapter(&adapter);
    if (FAILED(hr))
    {
        outError = "IDXGIDevice::GetAdapter failed";
        return false;
    }
    ComPtr<IDXGIFactory2> factory;
    hr = adapter->GetParent(IID_PPV_ARGS(&factory));
    if (FAILED(hr))
    {
        outError = "IDXGIAdapter::GetParent(IDXGIFactory2) failed";
        return false;
    }

    DXGI_SWAP_CHAIN_DESC1 desc{};
    desc.Width = static_cast<UINT>(width);
    desc.Height = static_cast<UINT>(height);
    desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    desc.SampleDesc.Count = 1;
    desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    desc.BufferCount = 2;
    desc.Scaling = DXGI_SCALING_STRETCH;
    desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL;
    desc.AlphaMode = DXGI_ALPHA_MODE_IGNORE;

    ComPtr<IDXGISwapChain1> swapChain;
    hr = factory->CreateSwapChainForComposition(device_.Get(), &desc, nullptr, &swapChain);
    if (FAILED(hr))
    {
        outError = "CreateSwapChainForComposition failed";
        return false;
    }

    hr = panelNative->SetSwapChain(swapChain.Get());
    if (FAILED(hr))
    {
        outError = "ISwapChainPanelNative::SetSwapChain failed";
        return false;
    }

    if (!EnsureShaders(outError))
    {
        return false;
    }

    swapChain_ = swapChain;
    panelNative_ = panelNative;
    width_ = width;
    height_ = height;

    return CreateRtv(outError);
}

bool D3D11Presenter::Resize(int32_t width, int32_t height, std::string& outError)
{
    if (!swapChain_)
    {
        outError = "no swap chain attached";
        return false;
    }
    if (width <= 0 || height <= 0)
    {
        outError = "invalid resize dimensions";
        return false;
    }

    rtv_.Reset();
    context_->OMSetRenderTargets(0, nullptr, nullptr);

    HRESULT hr = swapChain_->ResizeBuffers(0, static_cast<UINT>(width), static_cast<UINT>(height), DXGI_FORMAT_UNKNOWN, 0);
    if (FAILED(hr))
    {
        outError = "IDXGISwapChain1::ResizeBuffers failed";
        return false;
    }

    // Re-attach per the plan's quiesce -> ResizeBuffers -> re-SetSwapChain contract.
    hr = panelNative_->SetSwapChain(swapChain_.Get());
    if (FAILED(hr))
    {
        outError = "ISwapChainPanelNative::SetSwapChain (post-resize) failed";
        return false;
    }

    width_ = width;
    height_ = height;
    return CreateRtv(outError);
}

void D3D11Presenter::Detach()
{
    rtv_.Reset();
    frameSrv_.Reset();
    frameTex_.Reset();
    frameTexWidth_ = 0;
    frameTexHeight_ = 0;

    if (panelNative_)
    {
        panelNative_->SetSwapChain(nullptr);
    }
    swapChain_.Reset();
    panelNative_.Reset();
    width_ = 0;
    height_ = 0;
}

bool D3D11Presenter::PresentBgra(const uint8_t* bgra, int32_t width, int32_t height, int32_t strideBytes, std::string& outError)
{
    if (!swapChain_)
    {
        outError = "no swap chain attached";
        return false;
    }
    if (!bgra || width <= 0 || height <= 0)
    {
        outError = "invalid frame for PresentBgra";
        return false;
    }
    if (!EnsureFrameTexture(width, height, outError))
    {
        return false;
    }

    D3D11_MAPPED_SUBRESOURCE mapped{};
    HRESULT hr = context_->Map(frameTex_.Get(), 0, D3D11_MAP_WRITE_DISCARD, 0, &mapped);
    if (FAILED(hr))
    {
        outError = "Map (frame upload texture) failed";
        return false;
    }
    const size_t rowBytes = static_cast<size_t>(width) * 4;
    auto* dst = static_cast<uint8_t*>(mapped.pData);
    for (int32_t row = 0; row < height; ++row)
    {
        std::memcpy(dst + static_cast<size_t>(row) * mapped.RowPitch,
            bgra + static_cast<size_t>(row) * strideBytes, rowBytes);
    }
    context_->Unmap(frameTex_.Get(), 0);

    if (!rtv_ && !CreateRtv(outError))
    {
        return false;
    }

    ID3D11RenderTargetView* rtvs[] = { rtv_.Get() };
    context_->OMSetRenderTargets(1, rtvs, nullptr);

    D3D11_VIEWPORT vp{};
    vp.Width = static_cast<float>(width_);
    vp.Height = static_cast<float>(height_);
    vp.MinDepth = 0.0f;
    vp.MaxDepth = 1.0f;
    context_->RSSetViewports(1, &vp);

    context_->IASetInputLayout(nullptr);
    context_->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    context_->VSSetShader(vs_.Get(), nullptr, 0);
    context_->PSSetShader(ps_.Get(), nullptr, 0);
    ID3D11ShaderResourceView* srvs[] = { frameSrv_.Get() };
    context_->PSSetShaderResources(0, 1, srvs);
    ID3D11SamplerState* samplers[] = { sampler_.Get() };
    context_->PSSetSamplers(0, 1, samplers);
    context_->Draw(3, 0);

    hr = swapChain_->Present(1, 0);
    if (FAILED(hr))
    {
        outError = "IDXGISwapChain1::Present failed";
        return false;
    }
    return true;
}
