using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;

namespace PalmierPro.Rendering;

/// Wraps a native PE_TimelineHandle (Stage B / E2's timeline ABI) — the render-graph +
/// scrub-machinery counterpart to <see cref="MediaSource"/>'s single-asset decode. Owned
/// by whichever <see cref="EngineSession"/> opened it; a handle from one session is never
/// valid on another (same rule <see cref="EngineSession.OpenMedia"/> documents for
/// PE_MediaHandle). Accepts/produces raw UTF-8 snapshot JSON bytes rather than the
/// PalmierPro.Services timeline-snapshot model types — this assembly sits below
/// PalmierPro.Services in the dependency graph, so serialization happens on the caller's
/// side (see PalmierPro.Services.Engine.VideoEngine).
public sealed class TimelineSession : IDisposable
{
    private readonly EngineSession _session;
    private nint _handle;
    private GCHandle _callbackContext;
    private bool _disposed;

    /// Fired from a native render-thread callback whenever a frame is actually composed
    /// (and presented, if a swap chain is attached) in response to <see cref="Seek"/> —
    /// NOT fired by <see cref="RenderFrameToFile"/> (synchronous; the caller already
    /// knows when that completes). Raised on whatever thread the native render worker
    /// runs on — marshal to the UI thread in the subscriber.
    public event Action<long>? PlayheadChanged;

    private TimelineSession(EngineSession session, nint handle)
    {
        _session = session;
        _handle = handle;
        // Normal (non-weak) GCHandle: native holds a raw pointer to it as the playhead
        // callback's userCtx for as long as this timeline is open, so this object must
        // stay alive (and non-relocatable) until Dispose() explicitly frees the handle.
        _callbackContext = GCHandle.Alloc(this);
        unsafe
        {
            NativeMethods.PE_TimelineSetPlayheadCallback(_handle, &PlayheadTrampoline, GCHandle.ToIntPtr(_callbackContext));
        }
    }

    public static TimelineSession Open(EngineSession session, ReadOnlySpan<byte> snapshotJsonUtf8)
    {
        ArgumentNullException.ThrowIfNull(session);
        string json = Encoding.UTF8.GetString(snapshotJsonUtf8);
        int status = NativeMethods.PE_OpenTimeline(session.Handle, json, out nint handle);
        if (status != 0)
        {
            throw new EngineException(status, session.GetLastErrorMessage());
        }
        return new TimelineSession(session, handle);
    }

    /// Structural or param change: re-parses and atomically swaps the snapshot in. Any
    /// render already in flight for this timeline finishes on the OLD snapshot — this
    /// call never blocks on or interrupts it.
    public void Update(ReadOnlySpan<byte> snapshotJsonUtf8)
    {
        ThrowIfDisposed();
        string json = Encoding.UTF8.GetString(snapshotJsonUtf8);
        int status = NativeMethods.PE_UpdateTimeline(_handle, json);
        if (status != 0)
        {
            throw new EngineException(status, _session.GetLastErrorMessage());
        }
    }

    /// E3's Rebuild-vs-RefreshParams split: reuses the existing decoder/media sessions
    /// unconditionally (native asserts the media set is unchanged and refuses the swap
    /// otherwise — see palmier_engine.h's PE_TimelineRefreshParams). Callers use this for
    /// opacity/transform/crop/blendMode/effects/keyframe param edits that don't touch which
    /// media a clip points at; a structural change still goes through <see cref="Update"/>.
    public void RefreshParams(ReadOnlySpan<byte> snapshotJsonUtf8)
    {
        ThrowIfDisposed();
        string json = Encoding.UTF8.GetString(snapshotJsonUtf8);
        int status = NativeMethods.PE_TimelineRefreshParams(_handle, json);
        if (status != 0)
        {
            throw new EngineException(status, _session.GetLastErrorMessage());
        }
    }

    /// Enqueues (InteractiveScrub) or dispatches (Exact/other) a seek; never blocks on
    /// the native render thread. mode is a <c>PE_SeekMode</c> raw value — see
    /// PalmierPro.Services.Engine.PreviewSeekMode for the caller-facing enum.
    public void Seek(long frame, int mode)
    {
        ThrowIfDisposed();
        int status = NativeMethods.PE_TimelineSeek(_handle, frame, mode);
        if (status != 0)
        {
            throw new EngineException(status, _session.GetLastErrorMessage());
        }
    }

    public void AttachSwapChain(object swapChainPanel, int width, int height)
    {
        ThrowIfDisposed();
        nint panelUnknown = SwapChainPanelInterop.GetNativeUnknown(swapChainPanel);
        int status = NativeMethods.PE_TimelineAttachSwapChain(_handle, panelUnknown, width, height);
        if (status != 0)
        {
            throw new EngineException(status, _session.GetLastErrorMessage());
        }
    }

    public void ResizeSwapChain(int width, int height)
    {
        ThrowIfDisposed();
        int status = NativeMethods.PE_TimelineResizeSwapChain(_handle, width, height);
        if (status != 0)
        {
            throw new EngineException(status, _session.GetLastErrorMessage());
        }
    }

    public void DetachSwapChain()
    {
        ThrowIfDisposed();
        int status = NativeMethods.PE_TimelineDetachSwapChain(_handle);
        if (status != 0)
        {
            throw new EngineException(status, _session.GetLastErrorMessage());
        }
    }

    /// Headless CI-facing golden hook: decodes+composites+PNG-encodes synchronously,
    /// bypassing the render thread/mailbox/scrub-tolerance machinery entirely — immune
    /// to any concurrent <see cref="Seek"/> calls on the same timeline.
    public void RenderFrameToFile(long frame, string pngPath)
    {
        ThrowIfDisposed();
        ArgumentException.ThrowIfNullOrEmpty(pngPath);
        int status = NativeMethods.PE_TimelineRenderFrameToFile(_handle, frame, pngPath);
        if (status != 0)
        {
            throw new EngineException(status, _session.GetLastErrorMessage());
        }
    }

    /// Media paths the engine itself failed to decode while composing — distinct from
    /// the builder-side OfflineMediaRefs (see docs/timeline-snapshot-v1.md §8).
    public IReadOnlySet<string> GetUnprocessableMediaRefs()
    {
        ThrowIfDisposed();
        nint ptr = NativeMethods.PE_TimelineGetUnprocessableMediaRefsJson(_handle);
        string json = ptr == 0 ? "[]" : (Marshal.PtrToStringUTF8(ptr) ?? "[]");
        string[] paths = JsonSerializer.Deserialize<string[]>(json) ?? [];
        return new HashSet<string>(paths);
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static void PlayheadTrampoline(nint userCtx, long frame)
    {
        if (userCtx == 0)
        {
            return;
        }
        GCHandle handle = GCHandle.FromIntPtr(userCtx);
        if (handle.Target is TimelineSession self)
        {
            self.PlayheadChanged?.Invoke(frame);
        }
    }

    private void ThrowIfDisposed() => ObjectDisposedException.ThrowIf(_handle == 0, this);

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }
        _disposed = true;
        if (_handle != 0)
        {
            unsafe
            {
                NativeMethods.PE_TimelineSetPlayheadCallback(_handle, null, 0);
            }
            if (!_session.IsDisposed)
            {
                NativeMethods.PE_CloseTimeline(_session.Handle, _handle);
            }
        }
        _handle = 0;
        if (_callbackContext.IsAllocated)
        {
            _callbackContext.Free();
        }
    }
}
