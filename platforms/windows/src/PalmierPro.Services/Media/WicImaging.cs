using System.Runtime.InteropServices;
using PalmierPro.Core.Models;
using Windows.Foundation;
using Windows.Graphics.Imaging;
using Windows.Storage;
using Windows.Storage.Streams;
using WinRT;

namespace PalmierPro.Services.Media;

/// Managed still-image imaging backed by WIC (via the `Windows.Graphics.Imaging` projection the
/// `net10.0-windows10.0.19041.0` TFM ships automatically — no CsWinRT/System.Drawing package
/// reference needed). Deliberately never routes an image through PalmierEngine: stills are a
/// decode-and-scale problem the OS codec stack already solves, and keeping it off the engine keeps
/// image-only workflows (probing, thumbnailing) usable before/without a native session.
public static class WicImaging
{
    public static async Task<ImageProbeResult?> ProbeImageAsync(string path)
    {
        try
        {
            StorageFile file = await StorageFile.GetFileFromPathAsync(path).AsTask().ConfigureAwait(false);
            using IRandomAccessStream stream = await file.OpenAsync(FileAccessMode.Read).AsTask().ConfigureAwait(false);
            BitmapDecoder decoder = await BitmapDecoder.CreateAsync(stream).AsTask().ConfigureAwait(false);
            return new ImageProbeResult { Width = (int)decoder.PixelWidth, Height = (int)decoder.PixelHeight };
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            return null;
        }
    }

    /// Decodes `path`, scales to fit within `maxPixelSize` on the long edge (aspect-preserved,
    /// never upscaled — mirrors `kCGImageSourceThumbnailMaxPixelSize`), and JPEG-encodes the
    /// result. WIC's decoder applies EXIF orientation automatically when present, matching
    /// ImageIO's `kCGImageSourceCreateThumbnailWithTransform` — no manual orientation handling.
    public static async Task<byte[]?> CreateThumbnailJpegAsync(string path, int maxPixelSize, double quality = 0.75)
    {
        try
        {
            StorageFile file = await StorageFile.GetFileFromPathAsync(path).AsTask().ConfigureAwait(false);
            using IRandomAccessStream input = await file.OpenAsync(FileAccessMode.Read).AsTask().ConfigureAwait(false);
            BitmapDecoder decoder = await BitmapDecoder.CreateAsync(input).AsTask().ConfigureAwait(false);
            SoftwareBitmap bitmap = await decoder.GetSoftwareBitmapAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Ignore).AsTask().ConfigureAwait(false);

            double scale = Math.Min(1.0, maxPixelSize / (double)Math.Max(decoder.PixelWidth, decoder.PixelHeight));
            uint targetWidth = (uint)Math.Max(1, Math.Round(decoder.PixelWidth * scale));
            uint targetHeight = (uint)Math.Max(1, Math.Round(decoder.PixelHeight * scale));

            using var output = new InMemoryRandomAccessStream();
            BitmapEncoder encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.JpegEncoderId, output).AsTask().ConfigureAwait(false);
            encoder.SetSoftwareBitmap(bitmap);
            encoder.BitmapTransform.ScaledWidth = targetWidth;
            encoder.BitmapTransform.ScaledHeight = targetHeight;
            encoder.BitmapTransform.InterpolationMode = BitmapInterpolationMode.Fant;
            await SetJpegQualityAsync(encoder, quality).ConfigureAwait(false);
            await encoder.FlushAsync().AsTask().ConfigureAwait(false);
            return await ReadAllBytesAsync(output).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            return null;
        }
    }

    /// Wraps a raw top-down BGRA8 buffer (e.g. PalmierEngine's `PE_ExtractThumbnails` output) and
    /// JPEG-encodes it directly — no decode step. Used for <see cref="MediaVisualCache"/>'s
    /// filmstrip sprite sheet.
    public static async Task<byte[]?> EncodeBgraAsJpegAsync(byte[] bgra, int width, int height, int strideBytes, double quality = 0.75)
    {
        try
        {
            var bitmap = new SoftwareBitmap(BitmapPixelFormat.Bgra8, width, height, BitmapAlphaMode.Ignore);
            CopyIntoBitmap(bgra, strideBytes, height, bitmap);

            using var output = new InMemoryRandomAccessStream();
            BitmapEncoder encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.JpegEncoderId, output).AsTask().ConfigureAwait(false);
            encoder.SetSoftwareBitmap(bitmap);
            await SetJpegQualityAsync(encoder, quality).ConfigureAwait(false);
            await encoder.FlushAsync().AsTask().ConfigureAwait(false);
            return await ReadAllBytesAsync(output).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            return null;
        }
    }

    /// Decodes any WIC-readable image (used to read <see cref="MediaVisualCache"/>'s sprite sheet
    /// back off disk) into a raw top-down BGRA8 buffer.
    public static async Task<(byte[] Bgra, int Width, int Height)?> DecodeToBgraAsync(string path)
    {
        try
        {
            StorageFile file = await StorageFile.GetFileFromPathAsync(path).AsTask().ConfigureAwait(false);
            using IRandomAccessStream stream = await file.OpenAsync(FileAccessMode.Read).AsTask().ConfigureAwait(false);
            BitmapDecoder decoder = await BitmapDecoder.CreateAsync(stream).AsTask().ConfigureAwait(false);
            SoftwareBitmap bitmap = await decoder.GetSoftwareBitmapAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Ignore).AsTask().ConfigureAwait(false);
            int width = bitmap.PixelWidth;
            int height = bitmap.PixelHeight;
            int stride = width * 4;
            var bytes = new byte[stride * height];
            CopyOutOfBitmap(bytes, stride, height, bitmap);
            return (bytes, width, height);
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            return null;
        }
    }

    private static void CopyOutOfBitmap(byte[] dest, int strideBytes, int height, SoftwareBitmap bitmap)
    {
        using BitmapBuffer buffer = bitmap.LockBuffer(BitmapBufferAccessMode.Read);
        using IMemoryBufferReference reference = buffer.CreateReference();
        // CsWinRT-projected objects don't support a plain C# cast to an arbitrary [ComImport]
        // interface (that legacy behavior was TlbImp-era COM interop) — `.As<T>()` does the
        // actual QueryInterface. Mirrors SwapChainPanelInterop's IWinRTObject/NativeObject use.
        IMemoryBufferByteAccess access = reference.As<IMemoryBufferByteAccess>();
        access.GetBuffer(out nint src, out uint _);
        BitmapPlaneDescription plane = buffer.GetPlaneDescription(0);
        int rowBytes = Math.Min(strideBytes, plane.Stride);
        for (int y = 0; y < height; y++)
        {
            Marshal.Copy(src + plane.StartIndex + y * plane.Stride, dest, y * strideBytes, rowBytes);
        }
    }

    private static void CopyIntoBitmap(byte[] bgra, int strideBytes, int height, SoftwareBitmap bitmap)
    {
        using BitmapBuffer buffer = bitmap.LockBuffer(BitmapBufferAccessMode.Write);
        using IMemoryBufferReference reference = buffer.CreateReference();
        IMemoryBufferByteAccess access = reference.As<IMemoryBufferByteAccess>();
        access.GetBuffer(out nint dst, out uint _);
        BitmapPlaneDescription plane = buffer.GetPlaneDescription(0);
        int rowBytes = Math.Min(strideBytes, plane.Stride);
        for (int y = 0; y < height; y++)
        {
            Marshal.Copy(bgra, y * strideBytes, dst + plane.StartIndex + y * plane.Stride, rowBytes);
        }
    }

    private static async Task SetJpegQualityAsync(BitmapEncoder encoder, double quality)
    {
        var properties = new BitmapPropertySet
        {
            ["ImageQuality"] = new BitmapTypedValue(quality, PropertyType.Single),
        };
        await encoder.BitmapProperties.SetPropertiesAsync(properties).AsTask().ConfigureAwait(false);
    }

    private static async Task<byte[]> ReadAllBytesAsync(InMemoryRandomAccessStream stream)
    {
        stream.Seek(0);
        using var reader = new DataReader(stream);
        await reader.LoadAsync((uint)stream.Size).AsTask().ConfigureAwait(false);
        var bytes = new byte[stream.Size];
        reader.ReadBytes(bytes);
        return bytes;
    }

    // Standard COM interop shim for pixel access into a SoftwareBitmap's locked buffer —
    // IMemoryBufferByteAccess has no WinRT projection of its own (it's a raw COM interface WIC
    // buffer references implement), so it must be declared by hand.
    [ComImport]
    [Guid("5B0D3235-4DBA-4D44-865E-8F1D0E4FD04D")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMemoryBufferByteAccess
    {
        void GetBuffer(out nint buffer, out uint capacity);
    }
}
