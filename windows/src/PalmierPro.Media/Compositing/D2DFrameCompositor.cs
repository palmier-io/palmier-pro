using System.Numerics;
using PalmierPro.Core.Compositing;
using PalmierPro.Core.Models;
using PalmierPro.Media.Playback;
using SharpGen.Runtime;
using Vortice.Direct2D1;
using Vortice.Direct3D11;
using Vortice.DXGI;
using Vortice.Mathematics;

namespace PalmierPro.Media.Compositing;

/// <summary>
/// Offscreen Direct2D compositor: stacks planned frame layers bottom → top with
/// crop → transform → opacity per layer (the Mac FrameRenderer pipeline; effects
/// and blend modes land with the HLSL kernel ports). Not thread-safe; owned by
/// the playback engine's decode thread and by export workers separately.
/// </summary>
public sealed class D2DFrameCompositor : IDisposable
{
    private readonly ID3D11Device _device;
    private readonly ID2D1Factory1 _factory;
    private readonly ID2D1Device _d2dDevice;
    private readonly ID2D1DeviceContext _context;

    private ID2D1Bitmap1? _target;
    private ID2D1Bitmap1? _readback;
    private int _targetWidth;
    private int _targetHeight;
    private bool _disposed;

    public D2DFrameCompositor()
    {
        _device = D3D11.D3D11CreateDevice(
            Vortice.Direct3D.DriverType.Hardware,
            DeviceCreationFlags.BgraSupport);
        _factory = D2D1.D2D1CreateFactory<ID2D1Factory1>();
        using var dxgi = _device.QueryInterface<IDXGIDevice>();
        _d2dDevice = _factory.CreateDevice(dxgi);
        _context = _d2dDevice.CreateDeviceContext(DeviceContextOptions.None);
    }

    /// <summary>
    /// Composites the layer stack into a BGRA frame. <paramref name="decode"/> supplies
    /// each media layer's source frame; unavailable sources are skipped.
    /// </summary>
    public VideoFrame? Compose(
        int width, int height,
        IReadOnlyList<FrameLayer> layers,
        Func<Clip, double, VideoFrame?> decode)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (width <= 0 || height <= 0) return null;
        EnsureTargets(width, height);

        _context.Target = _target;
        _context.BeginDraw();
        _context.Clear(new Color4(0f, 0f, 0f, 1f));
        DrawLayers(layers, width, height, decode, gateByClipRange: false);
        _context.EndDraw();
        _context.Target = null;

        return ReadBack(width, height);
    }

    private void DrawLayers(
        IReadOnlyList<FrameLayer> layers, int canvasWidth, int canvasHeight,
        Func<Clip, double, VideoFrame?> decode, bool gateByClipRange)
    {
        foreach (var layer in layers)
        {
            if (gateByClipRange && !layer.Clip.Contains(layer.Frame)) continue;
            var opacity = Math.Clamp(layer.Clip.OpacityAt(layer.Frame), 0.0, 1.0);
            if (opacity <= 0) continue;

            switch (layer.Kind)
            {
                case FrameLayerKind.Media:
                    DrawMediaLayer(layer, canvasWidth, canvasHeight, decode, (float)opacity);
                    break;
                case FrameLayerKind.Group:
                    DrawGroupLayer(layer, canvasWidth, canvasHeight, decode, (float)opacity);
                    break;
                case FrameLayerKind.Text:
                    break; // Text rendering arrives with the DirectWrite port.
            }
        }
    }

    private void DrawMediaLayer(
        FrameLayer layer, int canvasWidth, int canvasHeight,
        Func<Clip, double, VideoFrame?> decode, float opacity)
    {
        var frame = decode(layer.Clip, layer.SourceSeconds);
        if (frame is null) return;
        using var bitmap = CreateBitmap(frame);
        if (bitmap is null) return;
        DrawWithClipPipeline(bitmap, frame.Width, frame.Height, layer, canvasWidth, canvasHeight, opacity);
    }

    /// <summary>Children composite into a child-canvas intermediate, then the nest clip's pipeline applies.</summary>
    private void DrawGroupLayer(
        FrameLayer layer, int canvasWidth, int canvasHeight,
        Func<Clip, double, VideoFrame?> decode, float opacity)
    {
        var childWidth = layer.ChildCanvasWidth;
        var childHeight = layer.ChildCanvasHeight;
        if (layer.Children is not { Count: > 0 } children || childWidth <= 0 || childHeight <= 0) return;

        using var intermediate = _context.CreateBitmap(
            new SizeI(childWidth, childHeight),
            nint.Zero, 0,
            new BitmapProperties1(
                new Vortice.DCommon.PixelFormat(Format.B8G8R8A8_UNorm, Vortice.DCommon.AlphaMode.Premultiplied),
                96, 96, BitmapOptions.Target));

        var outerTarget = _context.Target;
        var outerTransform = _context.Transform;
        _context.Target = intermediate;
        _context.Transform = Matrix3x2.Identity;
        _context.Clear(new Color4(0f, 0f, 0f, 1f));
        DrawLayers(children, childWidth, childHeight, decode, gateByClipRange: true);
        _context.Target = outerTarget;
        _context.Transform = outerTransform;

        DrawWithClipPipeline(intermediate, childWidth, childHeight, layer, canvasWidth, canvasHeight, opacity);
    }

    /// <summary>Crop in source space, place via the shared transform math, fade by opacity.</summary>
    private void DrawWithClipPipeline(
        ID2D1Bitmap bitmap, int sourceWidth, int sourceHeight,
        FrameLayer layer, int canvasWidth, int canvasHeight, float opacity)
    {
        var crop = layer.Clip.CropAt(layer.Frame);
        var sourceRect = new Rect(
            (float)(crop.Left * sourceWidth),
            (float)(crop.Top * sourceHeight),
            (float)Math.Max(1, crop.VisibleWidthFraction * sourceWidth),
            (float)Math.Max(1, crop.VisibleHeightFraction * sourceHeight));

        var transform = LayerTransform.Placement(
            layer.Clip.TransformAt(layer.Frame),
            sourceWidth, sourceHeight, canvasWidth, canvasHeight);

        var previous = _context.Transform;
        _context.Transform = transform;
        // Destination equals the source rect: crop keeps its position under the placement
        // transform instead of rescaling into the full slot (Mac CI-crop semantics).
        _context.DrawBitmap(bitmap, sourceRect, opacity,
            InterpolationMode.Linear, sourceRect, null);
        _context.Transform = previous;
    }

    private unsafe ID2D1Bitmap1? CreateBitmap(VideoFrame frame)
    {
        fixed (byte* pixels = frame.Bgra)
        {
            return _context.CreateBitmap(
                new SizeI(frame.Width, frame.Height),
                (nint)pixels, (uint)(frame.Width * 4),
                new BitmapProperties1(
                    new Vortice.DCommon.PixelFormat(Format.B8G8R8A8_UNorm, Vortice.DCommon.AlphaMode.Premultiplied),
                    96, 96, BitmapOptions.None));
        }
    }

    private void EnsureTargets(int width, int height)
    {
        if (_target is not null && width == _targetWidth && height == _targetHeight) return;
        _target?.Dispose();
        _readback?.Dispose();
        var format = new Vortice.DCommon.PixelFormat(Format.B8G8R8A8_UNorm, Vortice.DCommon.AlphaMode.Premultiplied);
        _target = _context.CreateBitmap(new SizeI(width, height), nint.Zero, 0,
            new BitmapProperties1(format, 96, 96, BitmapOptions.Target));
        _readback = _context.CreateBitmap(new SizeI(width, height), nint.Zero, 0,
            new BitmapProperties1(format, 96, 96, BitmapOptions.CpuRead | BitmapOptions.CannotDraw));
        _targetWidth = width;
        _targetHeight = height;
    }

    private VideoFrame? ReadBack(int width, int height)
    {
        if (_target is null || _readback is null) return null;
        _readback.CopyFromBitmap(_target);
        var map = _readback.Map(MapOptions.Read);
        try
        {
            var bytes = new byte[width * height * 4];
            var rowBytes = width * 4;
            unsafe
            {
                var source = (byte*)map.Bits;
                for (var row = 0; row < height; row++)
                {
                    System.Runtime.InteropServices.Marshal.Copy(
                        (nint)(source + (long)row * map.Pitch), bytes, row * rowBytes, rowBytes);
                }
            }
            return new VideoFrame(bytes, width, height, rowBytes);
        }
        finally
        {
            _readback.Unmap();
        }
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _target?.Dispose();
        _readback?.Dispose();
        _context.Dispose();
        _d2dDevice.Dispose();
        _factory.Dispose();
        _device.Dispose();
    }
}
