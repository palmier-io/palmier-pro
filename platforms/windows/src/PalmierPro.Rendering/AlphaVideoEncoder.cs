namespace PalmierPro.Rendering;

/// Wraps a native PE_AlphaEncoderHandle (docs/lottie-bake-v1.md §7, §8) — a streaming ProRes
/// 4444 (yuva444p10le) .mov encoder. Unlike <see cref="MediaSource"/>/<see cref="TimelineSession"/>,
/// the <see cref="EngineSession"/> that opened this does not own its lifetime (the underlying
/// PE_EncodeAlphaVideoPushFrame/Close/Abort calls take no session) — disposing the session has
/// no effect on an already-open encoder. Not thread-safe on a single instance — callers
/// serialize <see cref="PushFrame"/> calls, same discipline as every other native encode/decode
/// wrapper in this assembly.
public sealed class AlphaVideoEncoder : IDisposable
{
    private readonly EngineSession _session;
    private nint _handle;

    private AlphaVideoEncoder(EngineSession session, nint handle, int width, int height)
    {
        _session = session;
        _handle = handle;
        Width = width;
        Height = height;
    }

    public int Width { get; }
    public int Height { get; }

    /// width/height must both be positive and even (ProRes 4:4:4:4 requirement) — the native
    /// side rejects any other size with <see cref="EngineException"/>. Performs no temp-file/
    /// atomic-rename dance of its own — a caller that needs atomic "never publish a partial
    /// file" semantics opens against its own temp path and renames after <see cref="Close"/>
    /// succeeds (mirrors docs/lottie-bake-v1.md §5).
    public static AlphaVideoEncoder Open(EngineSession session, string outputPath, int width, int height)
    {
        ArgumentNullException.ThrowIfNull(session);
        ArgumentException.ThrowIfNullOrEmpty(outputPath);
        int status = NativeMethods.PE_EncodeAlphaVideoOpen(session.Handle, outputPath, width, height, out nint handle);
        if (status != 0)
        {
            throw new EngineException(status, session.GetLastErrorMessage());
        }
        return new AlphaVideoEncoder(session, handle, width, height);
    }

    /// bgraData is premultiplied BGRA32 — <see cref="Width"/> x <see cref="Height"/> pixels at
    /// <paramref name="strideBytes"/>-wide rows (byte-identical convention to
    /// <see cref="MediaSource.DecodeFrameAt"/>'s frame buffer). <paramref name="presentationSeconds"/>
    /// must be strictly greater than the previous call's value; need not be evenly spaced — a
    /// large gap encodes a hold as one extra sample rather than repeated frames (the
    /// freeze-frame tail mechanism, doc §6). Copies bgraData before returning.
    public void PushFrame(ReadOnlySpan<byte> bgraData, int strideBytes, double presentationSeconds)
    {
        ThrowIfDisposed();
        ArgumentOutOfRangeException.ThrowIfLessThan(strideBytes, Width * 4);
        long required = (long)strideBytes * Height;
        if (bgraData.Length < required)
        {
            throw new ArgumentException($"bgraData is too short ({bgraData.Length} bytes) for {Width}x{Height} at stride {strideBytes}.", nameof(bgraData));
        }

        int status;
        unsafe
        {
            fixed (byte* p = bgraData)
            {
                status = NativeMethods.PE_EncodeAlphaVideoPushFrame(_handle, p, strideBytes, presentationSeconds);
            }
        }
        if (status != 0)
        {
            throw new EngineException(status, _session.GetLastErrorMessage());
        }
    }

    /// Flushes buffered packets and finalizes the container (moov atom) — the output file is
    /// only complete/playable once this returns without throwing. Frees the native encoder
    /// regardless of outcome; the instance is unusable after this call either way (mirrors
    /// PE_EncodeAlphaVideoClose's contract).
    public void Close()
    {
        if (_handle == 0)
        {
            return;
        }
        nint handle = _handle;
        _handle = 0;
        int status = NativeMethods.PE_EncodeAlphaVideoClose(handle);
        if (status != 0)
        {
            throw new EngineException(status, _session.GetLastErrorMessage());
        }
    }

    /// Cancellation path: discards buffered/unflushed packets and frees the native encoder
    /// WITHOUT finalizing the container — the output file (if anything was ever written to it)
    /// is left incomplete/unplayable. Always succeeds; the instance is unusable after this call.
    public void Abort()
    {
        if (_handle == 0)
        {
            return;
        }
        nint handle = _handle;
        _handle = 0;
        NativeMethods.PE_EncodeAlphaVideoAbort(handle);
    }

    private void ThrowIfDisposed()
    {
        if (_handle == 0)
        {
            throw new ObjectDisposedException(nameof(AlphaVideoEncoder));
        }
    }

    /// Disposing without an explicit <see cref="Close"/> aborts (discards, does not finalize) —
    /// a caller that wants a playable file must call <see cref="Close"/> itself; Dispose is only
    /// the safety net that guarantees the native encoder is always freed. A no-op if
    /// <see cref="Close"/> or <see cref="Abort"/> already ran.
    public void Dispose()
    {
        if (_handle == 0)
        {
            return;
        }
        nint handle = _handle;
        _handle = 0;
        NativeMethods.PE_EncodeAlphaVideoAbort(handle);
    }
}
