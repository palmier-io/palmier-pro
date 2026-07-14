#pragma once

#include <d3d11.h>
#include <dxgi1_2.h>
#include <wrl/client.h>
#include "WinUISwapChainInterop.h"

#include <cstdint>
#include <string>

// Owns one session's swap chain, attached to a WinUI SwapChainPanel via
// ISwapChainPanelNative. Callers (EngineSession) own the threading contract
// documented in palmier_engine.h; this class assumes single-caller-at-a-time
// (EngineSession serializes it behind d3dMutex_).
class D3D11Presenter
{
public:
    bool Attach(ID3D11Device* device, ID3D11DeviceContext* context, void* swapChainPanelUnknown,
        int32_t width, int32_t height, std::string& outError);
    bool Resize(int32_t width, int32_t height, std::string& outError);
    void Detach();
    bool PresentBgra(const uint8_t* bgra, int32_t width, int32_t height, int32_t strideBytes, std::string& outError);

    bool IsAttached() const { return swapChain_ != nullptr; }

private:
    Microsoft::WRL::ComPtr<ID3D11Device> device_;
    Microsoft::WRL::ComPtr<ID3D11DeviceContext> context_;
    Microsoft::WRL::ComPtr<ISwapChainPanelNative> panelNative_;
    Microsoft::WRL::ComPtr<IDXGISwapChain1> swapChain_;
    Microsoft::WRL::ComPtr<ID3D11RenderTargetView> rtv_;

    // Device-scoped (not swap-chain-scoped) — survive Detach/Resize, only recreated
    // if a later Attach hands us a different device.
    Microsoft::WRL::ComPtr<ID3D11VertexShader> vs_;
    Microsoft::WRL::ComPtr<ID3D11PixelShader> ps_;
    Microsoft::WRL::ComPtr<ID3D11SamplerState> sampler_;

    Microsoft::WRL::ComPtr<ID3D11Texture2D> frameTex_;
    Microsoft::WRL::ComPtr<ID3D11ShaderResourceView> frameSrv_;
    int32_t frameTexWidth_ = 0;
    int32_t frameTexHeight_ = 0;

    int32_t width_ = 0;
    int32_t height_ = 0;

    bool EnsureShaders(std::string& outError);
    bool EnsureFrameTexture(int32_t width, int32_t height, std::string& outError);
    bool CreateRtv(std::string& outError);
};
