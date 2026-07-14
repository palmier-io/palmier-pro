#pragma once

#include <unknwn.h>
#include <dxgi.h>

// Native interop interface for WinUI3's Microsoft.UI.Xaml.Controls.SwapChainPanel.
// Hand-declared rather than vendoring the generated
// microsoft.ui.xaml.media.dxinterop.h (ships in the Microsoft.WindowsAppSDK.WinUI
// NuGet package's include/ dir, not available when this vcxproj builds — see
// docs/README.md's CI step ordering: native builds before `dotnet restore`).
//
// IMPORTANT: this is a *different* interface, with a *different* GUID, than
// ISwapChainPanelNative in the Windows SDK's <windows.ui.xaml.media.dxinterop.h>,
// which is for the OS-shipped UWP Windows.UI.Xaml.Controls.SwapChainPanel — do not
// mix the two up or include both (same type name, so they can't coexist in one TU).
MIDL_INTERFACE("63aad0b8-7c24-40ff-85a8-640d944cc325")
ISwapChainPanelNative : public IUnknown
{
public:
    virtual HRESULT STDMETHODCALLTYPE SetSwapChain(_In_ IDXGISwapChain* swapChain) = 0;
};
