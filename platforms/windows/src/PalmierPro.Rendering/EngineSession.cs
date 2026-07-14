using System.Runtime.InteropServices;

namespace PalmierPro.Rendering;

// Owns the native PE_SessionHandle. Every MediaSource opened from a session is owned
// natively by that session — disposing the session invalidates them all, so dispose
// media sources first if you still need their state.
public sealed class EngineSession : IDisposable
{
    private nint _handle;

    public EngineSession()
    {
        int status = NativeMethods.PE_CreateSession(out _handle);
        if (status != 0 || _handle == 0)
        {
            throw new EngineException(status, "PE_CreateSession failed.");
        }
    }

    internal bool IsDisposed { get; private set; }

    internal nint Handle => IsDisposed ? throw new ObjectDisposedException(nameof(EngineSession)) : _handle;

    public MediaSource OpenMedia(string path)
    {
        ArgumentException.ThrowIfNullOrEmpty(path);
        int status = NativeMethods.PE_OpenMedia(Handle, path, out nint mediaHandle);
        if (status != 0)
        {
            throw new EngineException(status, GetLastErrorMessage());
        }
        try
        {
            return new MediaSource(this, mediaHandle);
        }
        catch
        {
            // MediaSource's constructor (PE_GetMediaInfo) failed, so the caller never got a
            // handle to Dispose — close the native media ourselves to avoid leaking it.
            NativeMethods.PE_CloseMedia(Handle, mediaHandle);
            throw;
        }
    }

    internal string GetLastErrorMessage()
    {
        nint ptr = NativeMethods.PE_GetLastErrorMessage(_handle);
        return ptr == 0 ? string.Empty : Marshal.PtrToStringUTF8(ptr) ?? string.Empty;
    }

    // swapChainPanel must be a WinRT-projected SwapChainPanel (e.g.
    // Microsoft.UI.Xaml.Controls.SwapChainPanel) — see SwapChainPanelInterop. UI-thread
    // call; see palmier_engine.h for the full threading contract.
    public void AttachSwapChain(object swapChainPanel, int width, int height)
    {
        nint panelUnknown = SwapChainPanelInterop.GetNativeUnknown(swapChainPanel);
        int status = NativeMethods.PE_AttachSwapChain(Handle, panelUnknown, width, height);
        if (status != 0)
        {
            throw new EngineException(status, GetLastErrorMessage());
        }
    }

    // UI-thread call; quiesces any in-flight Present before resizing (see palmier_engine.h).
    public void ResizeSwapChain(int width, int height)
    {
        int status = NativeMethods.PE_ResizeSwapChain(Handle, width, height);
        if (status != 0)
        {
            throw new EngineException(status, GetLastErrorMessage());
        }
    }

    // UI-thread call.
    public void DetachSwapChain()
    {
        int status = NativeMethods.PE_DetachSwapChain(Handle);
        if (status != 0)
        {
            throw new EngineException(status, GetLastErrorMessage());
        }
    }

    // May be called off the UI thread (a present loop). Requires a prior AttachSwapChain.
    public void PresentFrameAt(MediaSource media, double timelineSeconds)
    {
        ArgumentNullException.ThrowIfNull(media);
        int status = NativeMethods.PE_PresentFrameAt(Handle, media.Handle, timelineSeconds);
        if (status != 0)
        {
            throw new EngineException(status, GetLastErrorMessage());
        }
    }

    public void Dispose()
    {
        if (IsDisposed)
        {
            return;
        }
        IsDisposed = true;
        NativeMethods.PE_DestroySession(_handle);
        _handle = 0;
        GC.SuppressFinalize(this);
    }

    ~EngineSession()
    {
        if (!IsDisposed && _handle != 0)
        {
            NativeMethods.PE_DestroySession(_handle);
        }
    }
}
