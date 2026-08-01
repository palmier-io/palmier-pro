using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;
using System.Runtime.InteropServices;
using PalmierPro.Core.Models;
using PalmierPro.Media.Playback;

namespace PalmierPro.Media.Compositing;

/// <summary>
/// Renders a text clip into a canvas-sized BGRA frame. Ports the Mac TextFrameRenderer
/// placement (centered by default) using GDI+; DirectWrite can replace this later for
/// tighter typography parity.
/// </summary>
public static class TextFrameRenderer
{
    public static VideoFrame? Render(Clip clip, int canvasWidth, int canvasHeight)
    {
        if (canvasWidth <= 0 || canvasHeight <= 0) return null;
        var text = clip.TextContent;
        if (string.IsNullOrEmpty(text)) return null;
        var style = (clip.TextStyle ?? new TextStyle()).ScaledVisualStyle;
        text = style.DisplayText(text);

        using var bitmap = new Bitmap(canvasWidth, canvasHeight, PixelFormat.Format32bppPArgb);
        using (var g = Graphics.FromImage(bitmap))
        {
            g.Clear(Color.Transparent);
            g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
            g.SmoothingMode = SmoothingMode.AntiAlias;

            var fontStyle = FontStyle.Regular;
            if (style.IsBold) fontStyle |= FontStyle.Bold;
            if (style.IsItalic) fontStyle |= FontStyle.Italic;
            if (style.IsUnderlined) fontStyle |= FontStyle.Underline;
            if (style.IsStruckThrough) fontStyle |= FontStyle.Strikeout;

            using var font = CreateFont(style.FontName, (float)Math.Max(1, style.FontSize), fontStyle);
            using var brush = new SolidBrush(ToColor(style.Color));
            var format = new StringFormat
            {
                Alignment = style.Alignment switch
                {
                    TextAlignment.Left => StringAlignment.Near,
                    TextAlignment.Right => StringAlignment.Far,
                    _ => StringAlignment.Center,
                },
                LineAlignment = StringAlignment.Center,
            };

            var transform = clip.Transform;
            var centerX = (float)(transform.CenterX * canvasWidth);
            var centerY = (float)(transform.CenterY * canvasHeight);
            var width = (float)(Math.Max(0.05, transform.Width) * canvasWidth);
            var height = (float)(Math.Max(0.05, transform.Height) * canvasHeight);
            var rect = new RectangleF(centerX - width / 2, centerY - height / 2, width, height);

            if (style.Background.Enabled && style.Background.Color.A > 0)
            {
                using var bg = new SolidBrush(ToColor(style.Background.Color));
                g.FillRectangle(bg, rect);
            }

            if (style.Shadow.Enabled && style.Shadow.Color.A > 0)
            {
                using var shadowBrush = new SolidBrush(ToColor(style.Shadow.Color));
                var shadowRect = rect;
                shadowRect.Offset((float)style.Shadow.OffsetX, (float)style.Shadow.OffsetY);
                g.DrawString(text, font, shadowBrush, shadowRect, format);
            }

            if (style.Border.Enabled && style.Border.Width > 0 && style.Border.Color.A > 0)
            {
                using var path = new GraphicsPath();
                path.AddString(text, font.FontFamily, (int)font.Style, g.DpiY * font.Size / 72f,
                    rect, format);
                using var pen = new Pen(ToColor(style.Border.Color), (float)style.Border.Width);
                g.DrawPath(pen, path);
            }

            g.DrawString(text, font, brush, rect, format);
        }

        return ToVideoFrame(bitmap);
    }

    private static Font CreateFont(string name, float size, FontStyle style)
    {
        try { return new Font(MapFont(name), size, style, GraphicsUnit.Pixel); }
        catch { return new Font(FontFamily.GenericSansSerif, size, style, GraphicsUnit.Pixel); }
    }

    private static string MapFont(string macName) => macName switch
    {
        "Helvetica" or "Helvetica-Bold" => "Arial",
        "Helvetica Neue" => "Arial",
        "Menlo" or "SF Mono" => "Consolas",
        "Times" or "Times New Roman" => "Times New Roman",
        _ => macName.Replace("-Bold", "").Replace("-Italic", ""),
    };

    private static Color ToColor(Rgba c)
        => Color.FromArgb(
            (int)Math.Clamp(c.A * 255, 0, 255),
            (int)Math.Clamp(c.R * 255, 0, 255),
            (int)Math.Clamp(c.G * 255, 0, 255),
            (int)Math.Clamp(c.B * 255, 0, 255));

    private static VideoFrame ToVideoFrame(Bitmap bitmap)
    {
        var rect = new Rectangle(0, 0, bitmap.Width, bitmap.Height);
        var data = bitmap.LockBits(rect, ImageLockMode.ReadOnly, PixelFormat.Format32bppPArgb);
        try
        {
            var bytes = new byte[data.Stride * data.Height];
            Marshal.Copy(data.Scan0, bytes, 0, bytes.Length);
            // Convert to tightly packed BGRA if stride has padding.
            if (data.Stride == bitmap.Width * 4)
                return new VideoFrame(bytes, bitmap.Width, bitmap.Height, data.Stride);
            var packed = new byte[bitmap.Width * bitmap.Height * 4];
            for (var y = 0; y < bitmap.Height; y++)
                Buffer.BlockCopy(bytes, y * data.Stride, packed, y * bitmap.Width * 4, bitmap.Width * 4);
            return new VideoFrame(packed, bitmap.Width, bitmap.Height, bitmap.Width * 4);
        }
        finally
        {
            bitmap.UnlockBits(data);
        }
    }
}
