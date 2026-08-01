using System.Numerics;
using PalmierPro.Core.Compositing;
using PalmierPro.Core.Models;
using PalmierPro.Media.Playback;
using Vortice.Direct2D1;
using Vortice.Direct3D11;
using Vortice.DXGI;
using Vortice.Mathematics;
using ClipBlendMode = PalmierPro.Core.Models.BlendMode;

namespace PalmierPro.Media.Compositing;

/// <summary>
/// Offscreen Direct2D compositor: crop → effects → edge rounding → transform → opacity,
/// stacked bottom → top. Non-Normal blend modes dissolve the blend result over the
/// background (Premiere/Photoshop semantics), matching Mac FrameRenderer.
/// </summary>
public sealed class D2DFrameCompositor : IDisposable
{
    private readonly ID3D11Device _device;
    private readonly ID2D1Factory1 _factory;
    private readonly ID2D1Device _d2dDevice;
    private readonly ID2D1DeviceContext _context;

    private ID2D1Bitmap1? _target;
    private ID2D1Bitmap1? _readback;
    private ID2D1Bitmap1? _layerTarget;
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

        return ReadBack(_target!, width, height);
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

            VideoFrame? source = layer.Kind switch
            {
                FrameLayerKind.Media => decode(layer.Clip, layer.SourceSeconds),
                FrameLayerKind.Text => TextFrameRenderer.Render(layer.Clip, canvasWidth, canvasHeight),
                FrameLayerKind.Group => ComposeGroup(layer, decode),
                _ => null,
            };
            if (source is null) continue;

            // Effects + edge rounding run in source space before placement.
            if (layer.Kind != FrameLayerKind.Text)
                source = EffectProcessor.ApplyClipPipeline(source, layer.Clip, layer.Frame);
            else if (layer.Clip.Effects is { Count: > 0 } || layer.Clip.EdgeRounding > 0 || layer.Clip.EdgeSoftness > 0)
                source = EffectProcessor.ApplyClipPipeline(source, layer.Clip, layer.Frame);

            var blendMode = layer.Clip.BlendMode ?? ClipBlendMode.Normal;
            if (blendMode == ClipBlendMode.Normal)
            {
                using var bitmap = CreateBitmap(source);
                if (bitmap is null) continue;
                DrawPlaced(bitmap, source.Width, source.Height, layer, canvasWidth, canvasHeight, (float)opacity);
            }
            else
            {
                BlendLayerOntoTarget(source, layer, canvasWidth, canvasHeight, blendMode, (float)opacity);
            }
        }
    }

    private VideoFrame? ComposeGroup(FrameLayer layer, Func<Clip, double, VideoFrame?> decode)
    {
        var childWidth = layer.ChildCanvasWidth;
        var childHeight = layer.ChildCanvasHeight;
        if (layer.Children is not { Count: > 0 } children || childWidth <= 0 || childHeight <= 0)
            return null;

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

        return ReadBack(intermediate, childWidth, childHeight);
    }

    private void DrawPlaced(
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

        // Destination is in source-pixel space; Placement maps it onto the canvas.
        var previous = _context.Transform;
        _context.Transform = transform;
        _context.DrawBitmap(
            bitmap, sourceRect, opacity, BitmapInterpolationMode.Linear, sourceRect);
        _context.Transform = previous;
    }

    /// <summary>
    /// Draws the layer into a canvas-sized offscreen, blends with the current target on CPU,
    /// then replaces the target. Used for non-Normal blend modes.
    /// </summary>
    private void BlendLayerOntoTarget(
        VideoFrame source, FrameLayer layer, int canvasWidth, int canvasHeight,
        ClipBlendMode mode, float opacity)
    {
        if (_target is null || _layerTarget is null) return;

        _context.Target = _layerTarget;
        _context.Clear(new Color4(0f, 0f, 0f, 0f));
        using (var bitmap = CreateBitmap(source))
        {
            if (bitmap is not null)
                DrawPlaced(bitmap, source.Width, source.Height, layer, canvasWidth, canvasHeight, 1f);
        }
        _context.Target = _target;

        var background = ReadBack(_target, canvasWidth, canvasHeight);
        var foreground = ReadBack(_layerTarget, canvasWidth, canvasHeight);
        if (background is null || foreground is null) return;

        var blended = BlendFrames(background, foreground, mode, opacity);
        using var result = CreateBitmap(blended);
        if (result is null) return;
        _context.Transform = Matrix3x2.Identity;
        _context.DrawBitmap(result, 1f, InterpolationMode.NearestNeighbor);
    }

    private static VideoFrame BlendFrames(
        VideoFrame background, VideoFrame foreground, ClipBlendMode mode, float opacity)
    {
        var output = new byte[background.Bgra.Length];
        var stride = background.Stride;
        for (var y = 0; y < background.Height; y++)
        for (var x = 0; x < background.Width; x++)
        {
            var i = y * stride + x * 4;
            var db = background.Bgra[i] / 255f;
            var dg = background.Bgra[i + 1] / 255f;
            var dr = background.Bgra[i + 2] / 255f;
            var da = background.Bgra[i + 3] / 255f;

            var sb = foreground.Bgra[i] / 255f;
            var sg = foreground.Bgra[i + 1] / 255f;
            var sr = foreground.Bgra[i + 2] / 255f;
            var sa = foreground.Bgra[i + 3] / 255f;

            if (sa <= 0)
            {
                output[i] = background.Bgra[i];
                output[i + 1] = background.Bgra[i + 1];
                output[i + 2] = background.Bgra[i + 2];
                output[i + 3] = background.Bgra[i + 3];
                continue;
            }

            var (br, bg, bb) = BlendModes.Blend(mode, sr, sg, sb, dr, dg, db);
            // Fade blend RESULT toward background by opacity (Mac dissolve semantics).
            var t = opacity * sa;
            var fr = dr + (br - dr) * t;
            var fg = dg + (bg - dg) * t;
            var fb = db + (bb - db) * t;
            var fa = Math.Clamp(da + sa * opacity * (1f - da), 0f, 1f);
            output[i] = ToByte(fb);
            output[i + 1] = ToByte(fg);
            output[i + 2] = ToByte(fr);
            output[i + 3] = ToByte(fa);
        }
        return new VideoFrame(output, background.Width, background.Height, stride);
    }

    private unsafe ID2D1Bitmap1? CreateBitmap(VideoFrame frame)
    {
        // Prefer Premultiplied (text / keyed media). If the buffer looks fully transparent
        // (typical MF RGB32 with unused A=0), treat alpha as opaque like SwapChainPresenter.
        var alphaMode = LooksFullyTransparent(frame)
            ? Vortice.DCommon.AlphaMode.Ignore
            : Vortice.DCommon.AlphaMode.Premultiplied;
        fixed (byte* pixels = frame.Bgra)
        {
            return _context.CreateBitmap(
                new SizeI(frame.Width, frame.Height),
                (nint)pixels, (uint)frame.Stride,
                new BitmapProperties1(
                    new Vortice.DCommon.PixelFormat(Format.B8G8R8A8_UNorm, alphaMode),
                    96, 96, BitmapOptions.None));
        }
    }

    private static bool LooksFullyTransparent(VideoFrame frame)
    {
        var bgra = frame.Bgra;
        var stride = frame.Stride;
        // Sample a few pixels; all-zero alpha means Ignore is required for visibility.
        for (var y = 0; y < frame.Height; y += Math.Max(1, frame.Height / 4))
        {
            var row = y * stride;
            for (var x = 0; x < frame.Width; x += Math.Max(1, frame.Width / 4))
            {
                var i = row + x * 4 + 3;
                if (i < bgra.Length && bgra[i] != 0) return false;
            }
        }
        return frame.Width > 0 && frame.Height > 0;
    }

    private void EnsureTargets(int width, int height)
    {
        if (_target is not null && width == _targetWidth && height == _targetHeight) return;
        _target?.Dispose();
        _readback?.Dispose();
        _layerTarget?.Dispose();
        var format = new Vortice.DCommon.PixelFormat(Format.B8G8R8A8_UNorm, Vortice.DCommon.AlphaMode.Premultiplied);
        _target = _context.CreateBitmap(new SizeI(width, height), nint.Zero, 0,
            new BitmapProperties1(format, 96, 96, BitmapOptions.Target));
        _layerTarget = _context.CreateBitmap(new SizeI(width, height), nint.Zero, 0,
            new BitmapProperties1(format, 96, 96, BitmapOptions.Target));
        _readback = _context.CreateBitmap(new SizeI(width, height), nint.Zero, 0,
            new BitmapProperties1(format, 96, 96, BitmapOptions.CpuRead | BitmapOptions.CannotDraw));
        _targetWidth = width;
        _targetHeight = height;
    }

    private VideoFrame? ReadBack(ID2D1Bitmap1 source, int width, int height)
    {
        if (_readback is null) return null;
        _readback.CopyFromBitmap(source);
        var map = _readback.Map(MapOptions.Read);
        try
        {
            var bytes = new byte[width * height * 4];
            var rowBytes = width * 4;
            unsafe
            {
                var src = (byte*)map.Bits;
                for (var row = 0; row < height; row++)
                {
                    System.Runtime.InteropServices.Marshal.Copy(
                        (nint)(src + (long)row * map.Pitch), bytes, row * rowBytes, rowBytes);
                }
            }
            return new VideoFrame(bytes, width, height, rowBytes);
        }
        finally
        {
            _readback.Unmap();
        }
    }

    private static byte ToByte(float v) => (byte)Math.Clamp((int)Math.Round(v * 255f), 0, 255);

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _target?.Dispose();
        _layerTarget?.Dispose();
        _readback?.Dispose();
        _context.Dispose();
        _d2dDevice.Dispose();
        _factory.Dispose();
        _device.Dispose();
    }
}
