namespace PalmierPro.Rendering;

/// Thin managed wrapper around the native bundled-font registry's debug probe
/// (PE_DebugResolveFontFamily, native/FontRegistry.h) — test/tooling surface only. The
/// registry itself is process-wide native state with no session handle; the real
/// text/title compositor (E4) consumes FontRegistry directly from native code, nothing
/// C# needs to resolve font families for rendering.
public static class FontRegistryDebug
{
    private const int BufferCapacity = 512;

    /// Mirrors FontRegistry::ResolveFamily: maps a TextStyle.fontName value to the bundled
    /// family DirectWrite will actually render with — the exact bundled family if present,
    /// else the fixed fallback (FontRegistry::kFallbackFamily). Throws EngineException only
    /// if the bundle itself failed to load (missing fonts\ next to PalmierEngine.dll,
    /// DirectWrite factory creation failure) — never because a name didn't match.
    public static unsafe string ResolveFamily(string storedFontName)
    {
        ArgumentException.ThrowIfNullOrEmpty(storedFontName);

        Span<byte> buffer = stackalloc byte[BufferCapacity];
        int status;
        fixed (byte* ptr = buffer)
        {
            status = NativeMethods.PE_DebugResolveFontFamily(storedFontName, ptr, BufferCapacity);
        }
        if (status != 0)
        {
            throw new EngineException(status, $"PE_DebugResolveFontFamily failed for '{storedFontName}'.");
        }

        int nul = buffer.IndexOf((byte)0);
        return System.Text.Encoding.UTF8.GetString(nul >= 0 ? buffer[..nul] : buffer);
    }
}
