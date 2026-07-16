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
    // Mirrors native PE_ScrubAudioDirection (palmier_engine.h) — the two valid values for
    // <see cref="ScrubAudio"/>'s `direction` parameter.
    public const int ScrubForward = 0;
    public const int ScrubReverse = 1;

    private readonly EngineSession _session;
    private nint _handle;
    private GCHandle _callbackContext;
    private bool _disposed;

    /// Fired from a native render-thread callback whenever a frame is actually composed
    /// (and presented, if a swap chain is attached) in response to <see cref="Seek"/> OR
    /// once per frame the playback present loop presents against the A/V clock (E4.5) —
    /// NOT fired by <see cref="RenderFrameToFile"/> (synchronous; the caller already
    /// knows when that completes). Raised on whatever thread the native render worker
    /// runs on — marshal to the UI thread in the subscriber.
    public event Action<long>? PlayheadChanged;

    /// Fired whenever isPlaying actually transitions (docs/audio-playback-v1.md §4):
    /// <see cref="Play"/>/<see cref="SetRate"/>(1.0) → true, <see cref="Pause"/>/
    /// <see cref="SetRate"/>(0.0) → false, and the engine's own auto-stop when the clock
    /// reaches the timeline's duration during playback. Raised on a native background
    /// thread — marshal to the UI thread in the subscriber.
    public event Action<bool>? IsPlayingChanged;

    private TimelineSession(EngineSession session, nint handle)
    {
        _session = session;
        _handle = handle;
        // Normal (non-weak) GCHandle: native holds a raw pointer to it as both callbacks'
        // userCtx for as long as this timeline is open, so this object must stay alive (and
        // non-relocatable) until Dispose() explicitly frees the handle.
        _callbackContext = GCHandle.Alloc(this);
        unsafe
        {
            nint ctx = GCHandle.ToIntPtr(_callbackContext);
            NativeMethods.PE_TimelineSetPlayheadCallback(_handle, &PlayheadTrampoline, ctx);
            NativeMethods.PE_TimelineSetIsPlayingCallback(_handle, &IsPlayingTrampoline, ctx);
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

    /// Latest-wins windowed audio grab at `frame` (docs/audio-playback-v1.md §5) — plays once
    /// through a lightweight voice separate from the persistent playback voice. `direction` is
    /// <see cref="ScrubForward"/> or <see cref="ScrubReverse"/>; direction detection is caller
    /// policy (see <see cref="PalmierPro.Services.Engine.VideoEngine"/>). Never throws on
    /// content grounds — a valid handle always succeeds, even when the result is silence.
    public void ScrubAudio(long frame, int direction)
    {
        ThrowIfDisposed();
        int status = NativeMethods.PE_TimelineScrubAudio(_handle, frame, direction);
        if (status != 0)
        {
            throw new EngineException(status, _session.GetLastErrorMessage());
        }
    }

    /// Cuts off any still-playing scrub grain (docs/audio-playback-v1.md §5) — the Exact-settle
    /// counterpart to <see cref="ScrubAudio"/>, mirroring the Mac's stopScrubbing() on a .exact
    /// seek. Never throws on content grounds — a no-op if no grain has ever played.
    public void StopScrubAudio()
    {
        ThrowIfDisposed();
        int status = NativeMethods.PE_TimelineStopScrubAudio(_handle);
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

    /// Synchronous, headless GPU compute of `frame`'s live color scopes (docs/color-scopes-v1.md)
    /// — the Inspector Adjust tab's Curves/Hue Curves editors' data source. Same threading
    /// contract as <see cref="RenderFrameToFile"/>: bypasses the render thread/mailbox entirely,
    /// unaffected by a concurrent <see cref="Seek"/>. Callers should invoke this off the UI thread
    /// (see <see cref="PalmierPro.Services.Engine.VideoEngine.GetColorScopesAsync"/>) — the
    /// compose + GPU readback cost is not free.
    public ColorScopesResult ComputeColorScopes(long frame)
    {
        ThrowIfDisposed();
        int status = NativeMethods.PE_TimelineComputeColorScopes(_handle, frame, out PE_ColorScopesResult native);
        if (status != 0)
        {
            throw new EngineException(status, _session.GetLastErrorMessage());
        }
        return ColorScopesResult.FromNative(native);
    }

    /// Headless CI-facing golden hook for the audio mix loop (docs/audio-playback-v1.md §6):
    /// synchronously mixes the current snapshot's audio for the range at timeline <paramref
    /// name="startFrame"/>, returning <paramref name="frameCount"/> interleaved-stereo Float32
    /// samples (length <c>frameCount × 2</c>) at 48 kHz. No XAudio2 device involved — deterministic.
    public float[] RenderAudioRange(long startFrame, int frameCount)
    {
        ThrowIfDisposed();
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(frameCount);
        var buffer = new float[frameCount * 2];
        int status;
        unsafe
        {
            fixed (float* p = buffer)
            {
                status = NativeMethods.PE_TimelineRenderAudioRange(_handle, startFrame, frameCount, p);
            }
        }
        if (status != 0)
        {
            throw new EngineException(status, _session.GetLastErrorMessage());
        }
        return buffer;
    }

    /// Master meter tap (Stage E, AudioMeterView): raw linear-amplitude peak + RMS per channel
    /// from the most recently mixed audio block — fed by both <see cref="RenderAudioRange"/>
    /// (offline, deterministic) and live playback (<see cref="Play"/>). Lock-free on the native
    /// side, so this never blocks behind the audio submission thread's decode work. All zero
    /// (silence) before either producer has ever run. Values are raw amplitude, not dB — the
    /// caller (PalmierPro.Core.Audio.AudioMeterHub) owns the dB mapping/ballistics.
    public (float LeftPeak, float LeftRms, float RightPeak, float RightRms) GetAudioLevels()
    {
        ThrowIfDisposed();
        int status = NativeMethods.PE_TimelineGetAudioLevels(
            _handle, out float leftPeak, out float leftRms, out float rightPeak, out float rightRms);
        if (status != 0)
        {
            throw new EngineException(status, _session.GetLastErrorMessage());
        }
        return (leftPeak, leftRms, rightPeak, rightRms);
    }

    /// Offline golden hook for the scrub grain (docs/audio-playback-v1.md §5): synchronously
    /// computes the same edge-faded, direction-aware grain <see cref="ScrubAudio"/> would play at
    /// <paramref name="frame"/>, returning it as <c>grainFrameCount × 2</c> interleaved-stereo
    /// Float32 samples. No XAudio2 device involved — deterministic.
    public float[] RenderScrubGrain(long frame, int direction, int grainFrameCount)
    {
        ThrowIfDisposed();
        var buffer = new float[grainFrameCount * 2];
        int status;
        unsafe
        {
            fixed (float* p = buffer)
            {
                status = NativeMethods.PE_TimelineRenderScrubGrain(_handle, frame, direction, p);
            }
        }
        if (status != 0)
        {
            throw new EngineException(status, _session.GetLastErrorMessage());
        }
        return buffer;
    }

    /// Start continuous playback from the current clock position (docs/audio-playback-v1.md §3.5).
    /// Idempotent — Play while already playing succeeds as a no-op, mirroring AVPlayer.play().
    public void Play()
    {
        ThrowIfDisposed();
        int status = NativeMethods.PE_TimelinePlay(_handle);
        if (status != 0)
        {
            throw new EngineException(status, _session.GetLastErrorMessage());
        }
    }

    /// Stop playback and freeze the clock at wherever it reached (docs/audio-playback-v1.md §3.3).
    /// Idempotent, mirroring AVPlayer.pause().
    public void Pause()
    {
        ThrowIfDisposed();
        int status = NativeMethods.PE_TimelinePause(_handle);
        if (status != 0)
        {
            throw new EngineException(status, _session.GetLastErrorMessage());
        }
    }

    /// The general rate primitive under <see cref="Play"/>/<see cref="Pause"/>. v1 accepts only
    /// 0.0 (paused) or 1.0 (playing forward) — any other value throws (native returns
    /// PE_ERROR_INVALID_ARGUMENT); Phase 1 has no shuttle/variable-speed feature (doc §4).
    public void SetRate(double rate)
    {
        ThrowIfDisposed();
        int status = NativeMethods.PE_TimelineSetRate(_handle, rate);
        if (status != 0)
        {
            throw new EngineException(status, _session.GetLastErrorMessage());
        }
    }

    /// Synchronous poll of the current master-clock frame (docs/audio-playback-v1.md §3.2) — never
    /// blocks. A freshly opened timeline reads 0 (paused at frame 0).
    public long GetClockFrame()
    {
        ThrowIfDisposed();
        int status = NativeMethods.PE_TimelineGetClockFrame(_handle, out long frame);
        if (status != 0)
        {
            throw new EngineException(status, _session.GetLastErrorMessage());
        }
        return frame;
    }

    /// Test/debug-only: is the master clock on the sample-locked audio path (true) or the QPC
    /// software fallback (false)? Backs the device-gated play→pause→play handover test
    /// (docs/audio-playback-v1.md §3.4) — the handover is otherwise unobservable through the ABI.
    public bool UsingAudioClock()
    {
        ThrowIfDisposed();
        int status = NativeMethods.PE_DebugTimelineUsingAudioClock(_handle, out int usingAudioClock);
        if (status != 0)
        {
            throw new EngineException(status, _session.GetLastErrorMessage());
        }
        return usingAudioClock != 0;
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

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static void IsPlayingTrampoline(nint userCtx, int isPlaying)
    {
        if (userCtx == 0)
        {
            return;
        }
        GCHandle handle = GCHandle.FromIntPtr(userCtx);
        if (handle.Target is TimelineSession self)
        {
            self.IsPlayingChanged?.Invoke(isPlaying != 0);
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
                NativeMethods.PE_TimelineSetIsPlayingCallback(_handle, null, 0);
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
