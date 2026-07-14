using WinRT;

namespace PalmierPro.Rendering;

// Extracts the native IUnknown* backing a WinRT-projected control (WinUI3's
// Microsoft.UI.Xaml.Controls.SwapChainPanel) so it can cross the P/Invoke boundary as
// a plain pointer — native does its own QueryInterface for ISwapChainPanelNative
// (windows.ui.xaml.media.dxinterop.h), so this assembly never needs a WindowsAppSDK/
// WinUI package reference just to attach a swap chain.
internal static class SwapChainPanelInterop
{
    internal static nint GetNativeUnknown(object swapChainPanel)
    {
        if (swapChainPanel is not IWinRTObject winrtObject)
        {
            throw new ArgumentException("Expected a WinRT-projected control (e.g. SwapChainPanel).", nameof(swapChainPanel));
        }
        return winrtObject.NativeObject.ThisPtr;
    }
}
