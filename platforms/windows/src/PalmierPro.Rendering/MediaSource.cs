using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Threading.Channels;

namespace PalmierPro.Rendering;

// Wraps a native PE_MediaHandle. Not thread-safe on a single instance — the native
// side serializes decode state per media (seek position, reusable buffers), so
// concurrent calls on the same MediaSource must be serialized by the caller too.
public sealed class MediaSource : IDisposable
{
    private readonly EngineSession _session;
    private nint _handle;
    private byte[] _decodeBuffer = [];

    internal MediaSource(EngineSession session, nint handle)
    {
        _session = session;
        _handle = handle;

        int status = NativeMethods.PE_GetMediaInfo(_session.Handle, _handle, out PE_MediaInfo info);
        if (status != 0)
        {
            throw new EngineException(status, _session.GetLastErrorMessage());
        }
        Info = MediaInfo.FromNative(info);
    }

    public MediaInfo Info { get; }

    internal nint Handle => _handle;

    /// See <see cref="DecodedFrame"/>'s doc comment: the returned frame's buffer is reused by the
    /// next call on this same instance.
    public DecodedFrame DecodeFrameAt(double timelineSeconds)
    {
        ThrowIfDisposed();
        int status = NativeMethods.PE_DecodeFrameAt(_session.Handle, _handle, timelineSeconds, out PE_FrameBuffer frame);
        if (status != 0)
        {
            throw new EngineException(status, _session.GetLastErrorMessage());
        }

        int size = frame.StrideBytes * frame.Height;
        if (_decodeBuffer.Length < size)
        {
            _decodeBuffer = new byte[size];
        }
        unsafe
        {
            new ReadOnlySpan<byte>((void*)frame.Data, size).CopyTo(_decodeBuffer);
        }
        return new DecodedFrame(_decodeBuffer.AsMemory(0, size), frame.Width, frame.Height, frame.StrideBytes);
    }

    // Progressive delivery: yields each thumbnail as the native callback fires rather
    // than waiting for the whole batch. Cancelling the token sets the native cancel
    // flag, which the engine polls between thumbnails.
    public async IAsyncEnumerable<ThumbnailResult> ExtractThumbnailsAsync(
        IReadOnlyList<double> times,
        int width,
        int height,
        [EnumeratorCancellation] CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        var channel = Channel.CreateUnbounded<ThumbnailResult>(new UnboundedChannelOptions
        {
            SingleReader = true,
            SingleWriter = true,
        });

        Task producer = Task.Run(() =>
        {
            Exception? failure = null;
            try
            {
                RunExtractThumbnails(times, width, height, channel.Writer, cancellationToken);
            }
            catch (Exception ex)
            {
                failure = ex;
            }
            finally
            {
                channel.Writer.TryComplete(failure);
            }
        }, CancellationToken.None);

        await foreach (ThumbnailResult thumbnail in channel.Reader.ReadAllAsync(cancellationToken).ConfigureAwait(false))
        {
            yield return thumbnail;
        }

        await producer.ConfigureAwait(false);
    }

    private unsafe void RunExtractThumbnails(
        IReadOnlyList<double> times,
        int width,
        int height,
        ChannelWriter<ThumbnailResult> writer,
        CancellationToken cancellationToken)
    {
        double[] timesArray = times as double[] ?? [.. times];
        if (timesArray.Length == 0)
        {
            return;
        }

        int[] cancelArray = new int[1];
        GCHandle cancelPin = GCHandle.Alloc(cancelArray, GCHandleType.Pinned);
        GCHandle writerHandle = GCHandle.Alloc(writer);
        using CancellationTokenRegistration registration =
            cancellationToken.Register(() => Volatile.Write(ref cancelArray[0], 1));

        try
        {
            int status;
            fixed (double* timesPtr = timesArray)
            {
                int* cancelPtr = (int*)cancelPin.AddrOfPinnedObject();
                status = NativeMethods.PE_ExtractThumbnails(
                    _session.Handle,
                    _handle,
                    timesPtr,
                    timesArray.Length,
                    width,
                    height,
                    &ThumbnailTrampoline,
                    GCHandle.ToIntPtr(writerHandle),
                    cancelPtr);
            }

            if (status == (int)PE_Status.ErrorCancelled ||
                (status != 0 && cancellationToken.IsCancellationRequested))
            {
                throw new OperationCanceledException(cancellationToken);
            }
            if (status != 0)
            {
                throw new EngineException(status, _session.GetLastErrorMessage());
            }
        }
        finally
        {
            writerHandle.Free();
            cancelPin.Free();
        }
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static unsafe void ThumbnailTrampoline(
        nint userCtx, int index, double requestedTimeSeconds, byte* bgraData, int width, int height, int strideBytes)
    {
        GCHandle handle = GCHandle.FromIntPtr(userCtx);
        if (handle.Target is ChannelWriter<ThumbnailResult> writer)
        {
            int size = strideBytes * height;
            var copy = new byte[size];
            new ReadOnlySpan<byte>(bgraData, size).CopyTo(copy);
            writer.TryWrite(new ThumbnailResult(index, requestedTimeSeconds, copy, width, height, strideBytes));
        }
    }

    // Rate/cap resolution mirrors WaveformExtractor.swift; the returned values are
    // already dB-normalized (0 = loud, 1 = silent) via WaveformContract.Normalize.
    public float[] ExtractPeakEnvelope(double startSeconds, double durationSeconds)
    {
        ThrowIfDisposed();
        if (durationSeconds <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(durationSeconds));
        }

        double rate = durationSeconds > 0
            ? Math.Min(WaveformContract.SamplesPerSecond, WaveformContract.MaxSamples / durationSeconds)
            : WaveformContract.SamplesPerSecond;
        int cap = Math.Min(WaveformContract.MaxSamples, (int)Math.Ceiling(durationSeconds * rate) + 1);
        float[] raw = new float[cap];

        int count;
        unsafe
        {
            fixed (float* buf = raw)
            {
                int status = NativeMethods.PE_ExtractPeakEnvelope(
                    _session.Handle, _handle, startSeconds, durationSeconds, rate, buf, cap, out count);
                if (status != 0)
                {
                    throw new EngineException(status, _session.GetLastErrorMessage());
                }
            }
        }

        var result = new float[count];
        for (int i = 0; i < count; i++)
        {
            result[i] = WaveformContract.Normalize(raw[i]);
        }
        return result;
    }

    // Headless CI-facing golden hook: decode + PNG-encode with no D3D device or swap
    // chain involved (see PE_RenderFrameToFile in palmier_engine.h).
    public void RenderFrameToFile(double timelineSeconds, string pngPath)
    {
        ThrowIfDisposed();
        ArgumentException.ThrowIfNullOrEmpty(pngPath);
        int status = NativeMethods.PE_RenderFrameToFile(_session.Handle, _handle, timelineSeconds, pngPath);
        if (status != 0)
        {
            throw new EngineException(status, _session.GetLastErrorMessage());
        }
    }

    private void ThrowIfDisposed()
    {
        if (_handle == 0)
        {
            throw new ObjectDisposedException(nameof(MediaSource));
        }
    }

    public void Dispose()
    {
        if (_handle == 0)
        {
            return;
        }
        if (!_session.IsDisposed)
        {
            NativeMethods.PE_CloseMedia(_session.Handle, _handle);
        }
        _handle = 0;
    }
}
