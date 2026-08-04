using System.Drawing;
using System.Drawing.Imaging;

namespace PalmierPro.Media.Images;

/// <summary>
/// Still-image decode and JPEG encode utilities, the Windows counterpart of the Mac
/// ImageEncoder (ImageIO). Applies EXIF orientation before scaling.
/// </summary>
public static class ImageThumbnailer
{
    /// <summary>Library grid thumbnail bound, matching ImageEncoder.libraryThumbnailMaxPixelSize.</summary>
    public const int LibraryThumbnailMaxPixelSize = 320;

    public static Bitmap? Thumbnail(string path, int maxPixelSize)
    {
        Bitmap source;
        try
        {
            source = new Bitmap(path);
        }
        catch (Exception e) when (e is ArgumentException or OutOfMemoryException or IOException)
        {
            return null;
        }
        using (source)
        {
            ApplyExifOrientation(source);
            var scale = Math.Min(1.0, maxPixelSize / (double)Math.Max(source.Width, source.Height));
            var width = Math.Max(1, (int)Math.Round(source.Width * scale));
            var height = Math.Max(1, (int)Math.Round(source.Height * scale));
            return new Bitmap(source, width, height);
        }
    }

    public static byte[] EncodeJpeg(Bitmap bitmap, double quality)
    {
        var encoder = ImageCodecInfo.GetImageEncoders()
            .First(codec => codec.FormatID == ImageFormat.Jpeg.Guid);
        using var parameters = new EncoderParameters(1);
        parameters.Param[0] = new EncoderParameter(
            System.Drawing.Imaging.Encoder.Quality, (long)Math.Round(quality * 100));
        using var stream = new MemoryStream();
        bitmap.Save(stream, encoder, parameters);
        return stream.ToArray();
    }

    private const int OrientationPropertyId = 0x0112;

    private static void ApplyExifOrientation(Bitmap bitmap)
    {
        if (Array.IndexOf(bitmap.PropertyIdList, OrientationPropertyId) < 0) return;
        var value = bitmap.GetPropertyItem(OrientationPropertyId)?.Value;
        if (value is null || value.Length == 0) return;
        var flip = value[0] switch
        {
            2 => RotateFlipType.RotateNoneFlipX,
            3 => RotateFlipType.Rotate180FlipNone,
            4 => RotateFlipType.Rotate180FlipX,
            5 => RotateFlipType.Rotate90FlipX,
            6 => RotateFlipType.Rotate90FlipNone,
            7 => RotateFlipType.Rotate270FlipX,
            8 => RotateFlipType.Rotate270FlipNone,
            _ => RotateFlipType.RotateNoneFlipNone,
        };
        if (flip != RotateFlipType.RotateNoneFlipNone)
        {
            bitmap.RotateFlip(flip);
            bitmap.RemovePropertyItem(OrientationPropertyId);
        }
    }
}
