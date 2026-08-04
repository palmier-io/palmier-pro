using System.Runtime.InteropServices;
using Microsoft.UI.Xaml.Controls;
using PalmierPro.Media;
using Vortice.DXGI;
using Vortice.Direct2D1;
using Vortice.Direct3D;
using Vortice.Direct3D11;
using Vortice.Mathematics;
using WinRT;

namespace PalmierPro.App.Editor;

/// <summary>
/// D3D11 + D2D presenter for a WinUI SwapChainPanel: decoded BGRA frames are uploaded
/// to a D2D bitmap and drawn aspect-fit into a flip-model composition swap chain.
/// Present may be called from the decode thread; all device access is serialized.
/// </summary>
public sealed class SwapChainPresenter : IFramePresenter, IDisposable
{
    [ComImport]
    [Guid("63aad0b8-7c24-40ff-85a8-640d944cc325")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface ISwapChainPanelNative
    {
        void SetSwapChain(IntPtr swapChain);
    }

    private readonly object _lock = new();
    private readonly ID3D11Device _device;
    private readonly IDXGISwapChain1 _swapChain;
    private readonly ID2D1DeviceContext _d2dContext;
    private ID2D1Bitmap1? _frameBitmap;
    private int _frameWidth;
    private int _frameHeight;
    private int _panelWidth;
    private int _panelHeight;
    private bool _disposed;

    public SwapChainPresenter(SwapChainPanel panel, int initialWidth, int initialHeight)
    {
        _panelWidth = Math.Max(8, initialWidth);
        _panelHeight = Math.Max(8, initialHeight);

        D3D11.D3D11CreateDevice(
            null, DriverType.Hardware, DeviceCreationFlags.BgraSupport,
            [Vortice.Direct3D.FeatureLevel.Level_11_1, Vortice.Direct3D.FeatureLevel.Level_11_0],
            out _device!).CheckError();

        using var dxgiDevice = _device.QueryInterface<IDXGIDevice>();
        using var adapter = dxgiDevice.GetAdapter();
        using var factory = adapter.GetParent<IDXGIFactory2>();

        var description = new SwapChainDescription1
        {
            Width = (uint)_panelWidth,
            Height = (uint)_panelHeight,
            Format = Format.B8G8R8A8_UNorm,
            BufferCount = 2,
            BufferUsage = Usage.RenderTargetOutput,
            SampleDescription = new SampleDescription(1, 0),
            SwapEffect = SwapEffect.FlipSequential,
            Scaling = Scaling.Stretch,
            AlphaMode = Vortice.DXGI.AlphaMode.Ignore,
        };
        _swapChain = factory.CreateSwapChainForComposition(_device, description);

        using var d2dDevice = D2D1.D2D1CreateDevice(dxgiDevice, new CreationProperties
        {
            ThreadingMode = ThreadingMode.MultiThreaded,
        });
        _d2dContext = d2dDevice.CreateDeviceContext(DeviceContextOptions.None);

        panel.As<ISwapChainPanelNative>().SetSwapChain(_swapChain.NativePointer);
    }

    /// <summary>Call from the UI thread when the hosting panel resizes.</summary>
    public void Resize(int width, int height)
    {
        lock (_lock)
        {
            if (_disposed || width < 8 || height < 8) return;
            if (width == _panelWidth && height == _panelHeight) return;
            _panelWidth = width;
            _panelHeight = height;
            _d2dContext.Target = null;
            _swapChain.ResizeBuffers(2, (uint)width, (uint)height, Format.B8G8R8A8_UNorm, SwapChainFlags.None);
        }
    }

    public void Present(VideoFrame frame)
    {
        lock (_lock)
        {
            if (_disposed) return;
            EnsureFrameBitmap(frame.Width, frame.Height);
            var handle = GCHandle.Alloc(frame.Bgra, GCHandleType.Pinned);
            try
            {
                _frameBitmap!.CopyFromMemory(handle.AddrOfPinnedObject(), (uint)frame.Stride);
            }
            finally
            {
                handle.Free();
            }
            Draw(drawFrame: true);
        }
    }

    public void Clear()
    {
        lock (_lock)
        {
            if (_disposed) return;
            Draw(drawFrame: false);
        }
    }

    private void EnsureFrameBitmap(int width, int height)
    {
        if (_frameBitmap is not null && width == _frameWidth && height == _frameHeight) return;
        _frameBitmap?.Dispose();
        _frameBitmap = _d2dContext.CreateBitmap(
            new SizeI(width, height),
            IntPtr.Zero, 0,
            new BitmapProperties1(
                new Vortice.DCommon.PixelFormat(Format.B8G8R8A8_UNorm, Vortice.DCommon.AlphaMode.Ignore)));
        _frameWidth = width;
        _frameHeight = height;
    }

    private void Draw(bool drawFrame)
    {
        using var surface = _swapChain.GetBuffer<IDXGISurface>(0);
        using var target = _d2dContext.CreateBitmapFromDxgiSurface(surface, new BitmapProperties1(
            new Vortice.DCommon.PixelFormat(Format.B8G8R8A8_UNorm, Vortice.DCommon.AlphaMode.Ignore),
            96, 96, BitmapOptions.Target | BitmapOptions.CannotDraw));

        _d2dContext.Target = target;
        _d2dContext.BeginDraw();
        _d2dContext.Clear(new Color4(0f, 0f, 0f, 1f));
        if (drawFrame && _frameBitmap is not null)
        {
            var destination = AspectFit(_frameWidth, _frameHeight, _panelWidth, _panelHeight);
            _d2dContext.DrawBitmap(
                _frameBitmap, destination, 1f, BitmapInterpolationMode.Linear, null);
        }
        _d2dContext.EndDraw();
        _d2dContext.Target = null;
        _swapChain.Present(1, PresentFlags.None);
    }

    private static Rect AspectFit(int sourceWidth, int sourceHeight, int panelWidth, int panelHeight)
    {
        var scale = Math.Min(panelWidth / (double)sourceWidth, panelHeight / (double)sourceHeight);
        var width = (float)(sourceWidth * scale);
        var height = (float)(sourceHeight * scale);
        var x = (panelWidth - width) / 2f;
        var y = (panelHeight - height) / 2f;
        return new Rect(x, y, width, height);
    }

    public void Dispose()
    {
        lock (_lock)
        {
            if (_disposed) return;
            _disposed = true;
            _frameBitmap?.Dispose();
            _d2dContext.Dispose();
            _swapChain.Dispose();
            _device.Dispose();
        }
    }
}
