namespace PalmierPro.Core.Models;

/// `NSAttributedString.boundingRect(with:options:)`'s word-wrapped bounding-box measurement is a
/// render-time text-layout concern (CoreText on Mac, DirectWrite on Windows) — this project has no
/// text-layout stack, so it's the seam `TextLayout.NaturalSize` takes rather than a hard AppKit
/// dependency. The Windows renderer supplies the implementation.
public interface ITextBoundsMeasurer
{
    /// `text` word-wrapped to `maxWidth` (unbounded height), set in `style` at `renderFontSize` pt;
    /// returns the measured (width, height), mirroring `NSAttributedString.boundingRect`.
    (double Width, double Height) MeasureBoundingRect(string text, TextStyle style, double renderFontSize, double maxWidth);
}

/// Natural bounding size of a rendered text clip, shared between the layer controller and clip
/// placement. Ported from TextLayout.swift; actual glyph measurement goes through
/// <see cref="ITextBoundsMeasurer"/> (see its doc comment) rather than a font/text-layout stack.
public static class TextLayout
{
    public const double ShadowPadding = 12;
    public const double ReferenceCanvasHeight = 1080;

    public static (double Width, double Height) NaturalSize(
        string content,
        TextStyle style,
        double maxWidth,
        double canvasHeight,
        ITextBoundsMeasurer measurer)
    {
        var measured = content.Length == 0 ? " " : content;
        var canvasScale = canvasHeight / ReferenceCanvasHeight;
        var renderSize = style.FontSize * style.FontScale * canvasScale;
        var bounding = measurer.MeasureBoundingRect(measured, style, renderSize, maxWidth);

        // +4px slack absorbs canvas -> preview scale rounding.
        const double slack = 4;
        var shadowPad = style.Shadow.Enabled ? ShadowPadding * 2 : 0;
        var borderPad = style.Border.Enabled ? TextStyle.GlyphBorderPadding(renderSize) * 2 : 0;
        return (
            Math.Max(1, Math.Ceiling(bounding.Width) + shadowPad + borderPad + slack),
            Math.Max(1, Math.Ceiling(bounding.Height) + borderPad + slack)
        );
    }
}
