namespace PalmierPro.Rendering;

/// Wraps native `PE_RenderLottieThumbnail` — a small, additive ABI addition beyond
/// docs/lottie-bake-v1.md's own frozen contract (that doc names a media-panel Lottie thumbnail an
/// explicit v1 follow-up in its §11), backing <see cref="PalmierPro.Services.Media.MediaVisualCache"/>'s
/// Lottie filmstrip-tile need via the same vendored ThorVG rasterizer the bake pipeline uses. Takes
/// no <see cref="EngineSession"/> — mirrors <c>PE_LottieRasterizerSmokeTest</c>'s own no-session
/// convention (native/LottieRasterizer.cpp): opening a plain-JSON Lottie file needs no engine state.
public static class LottieThumbnail
{
    /// Rasterizes the animation's first frame, aspect-fit into `width` x `height` (ThorVG's own
    /// box-fit — see native/LottieRasterizer.h), as premultiplied BGRA32. `lottiePath` must already
    /// be a plain-JSON path (a `.lottie` zip is unzipped C#-side first — docs/lottie-bake-v1.md §12).
    public static unsafe byte[] Render(string lottiePath, int width, int height)
    {
        ArgumentException.ThrowIfNullOrEmpty(lottiePath);
        ArgumentOutOfRangeException.ThrowIfLessThanOrEqual(width, 0);
        ArgumentOutOfRangeException.ThrowIfLessThanOrEqual(height, 0);

        int strideBytes = width * 4;
        var buffer = new byte[strideBytes * height];
        int status;
        fixed (byte* p = buffer)
        {
            status = NativeMethods.PE_RenderLottieThumbnail(lottiePath, width, height, p, strideBytes);
        }
        if (status != 0)
        {
            throw new EngineException(status, string.Empty);
        }
        return buffer;
    }
}
