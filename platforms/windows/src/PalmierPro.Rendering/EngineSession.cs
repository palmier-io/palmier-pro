using System.Runtime.CompilerServices;
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

    // Metadata-only probe (docs/lottie-bake-v1.md §8/§11) — no rasterization, no encode, no disk
    // cache. `lottiePath` must already be a plain-JSON path — a .lottie zip is unzipped C#-side
    // first (§12; see DotLottieExtractor).
    public LottieInfo ProbeLottieMetadata(string lottiePath)
    {
        ArgumentException.ThrowIfNullOrEmpty(lottiePath);
        int status = NativeMethods.PE_ProbeLottieMetadata(Handle, lottiePath, out PE_LottieInfo info);
        if (status != 0)
        {
            throw new EngineException(status, GetLastErrorMessage());
        }
        return new LottieInfo(info.DurationSeconds, info.Width, info.Height, info.FrameRate);
    }

    /// One-call bake orchestration (docs/lottie-bake-v1.md §8) — synchronous; callers invoke from a
    /// background Task (mirrors <see cref="ILottieBakeService"/>'s own async surface, which is the
    /// only real caller). `lottiePath` must already be a plain-JSON path (§12). `onProgress` fires
    /// once per rasterized animation frame (not for the hold-tail sample); cancelling `ct` polls the
    /// same way <see cref="MediaSource.ExtractThumbnailsAsync"/>'s cancellation does.
    public unsafe void BakeLottieVideo(
        string lottiePath,
        int targetWidth,
        int targetHeight,
        double holdTailSeconds,
        string outputPath,
        Action<int, int>? onProgress = null,
        CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrEmpty(lottiePath);
        ArgumentException.ThrowIfNullOrEmpty(outputPath);

        int[] cancelArray = new int[1];
        GCHandle cancelPin = GCHandle.Alloc(cancelArray, GCHandleType.Pinned);
        GCHandle progressHandle = onProgress is null ? default : GCHandle.Alloc(onProgress);
        using CancellationTokenRegistration registration = ct.Register(() => Volatile.Write(ref cancelArray[0], 1));
        try
        {
            int status;
            int* cancelPtr = (int*)cancelPin.AddrOfPinnedObject();
            status = NativeMethods.PE_BakeLottieVideo(
                Handle,
                lottiePath,
                targetWidth,
                targetHeight,
                holdTailSeconds,
                outputPath,
                onProgress is null ? null : &ProgressTrampoline,
                onProgress is null ? 0 : GCHandle.ToIntPtr(progressHandle),
                cancelPtr);

            if (status == (int)PE_Status.ErrorCancelled || (status != 0 && ct.IsCancellationRequested))
            {
                throw new OperationCanceledException(ct);
            }
            if (status != 0)
            {
                throw new EngineException(status, GetLastErrorMessage());
            }
        }
        finally
        {
            cancelPin.Free();
            if (progressHandle.IsAllocated)
            {
                progressHandle.Free();
            }
        }
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static void ProgressTrampoline(nint userCtx, int framesDone, int framesTotal)
    {
        if (userCtx == 0)
        {
            return;
        }
        GCHandle handle = GCHandle.FromIntPtr(userCtx);
        if (handle.Target is Action<int, int> callback)
        {
            callback(framesDone, framesTotal);
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
