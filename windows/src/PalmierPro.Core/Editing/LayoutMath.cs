using PalmierPro.Core.Models;

namespace PalmierPro.Core.Editing;

/// <summary>Slot placement for apply_layout — fill/fit into a normalized LayoutRect.</summary>
public static class LayoutMath
{
    public static (Transform Transform, Crop Crop) Placement(
        LayoutRect rect,
        LayoutFit fit,
        double? mediaCanvasAspect,
        double canvasAspect,
        double anchorX = 0.5,
        double anchorY = 0.5)
    {
        anchorX = Math.Clamp(anchorX, 0, 1);
        anchorY = Math.Clamp(anchorY, 0, 1);
        var slotPixelAspect = rect.H > 0 ? rect.W / rect.H * canvasAspect : canvasAspect;

        if (fit == LayoutFit.Fit && mediaCanvasAspect is { } rel and > 0)
        {
            double drawW = rect.W, drawH = rect.H;
            if (rel * rect.H <= rect.W)
            {
                drawH = rect.H;
                drawW = rel * rect.H;
            }
            else
            {
                drawW = rect.W;
                drawH = rect.W / rel;
            }
            var x = rect.X + (rect.W - drawW) * anchorX;
            var y = rect.Y + (rect.H - drawH) * anchorY;
            return (Transform.FromTopLeft(x, y, drawW, drawH), new Crop());
        }

        // Fill (or fit without aspect): cover the slot.
        if (mediaCanvasAspect is { } mediaRel and > 0 && slotPixelAspect > 0)
        {
            var crop = CropFittingAspect(mediaRel, slotPixelAspect, anchorX, anchorY);
            var vw = crop.VisibleWidthFraction;
            var vh = crop.VisibleHeightFraction;
            if (vw > 0 && vh > 0)
            {
                var w = rect.W / vw;
                var h = rect.H / vh;
                var x = rect.X - crop.Left * w;
                var y = rect.Y - crop.Top * h;
                return (Transform.FromTopLeft(x, y, w, h), crop);
            }
        }

        return (Transform.FromTopLeft(rect.X, rect.Y, rect.W, rect.H), new Crop());
    }

    private static Crop CropFittingAspect(
        double mediaAspect, double targetPixelAspect, double anchorX, double anchorY)
    {
        // mediaAspect is width/height in canvas-normalized units relative to square pixels.
        if (mediaAspect >= targetPixelAspect)
        {
            // Too wide — crop left/right.
            var visible = targetPixelAspect / mediaAspect;
            var left = (1 - visible) * anchorX;
            return new Crop { Left = left, Right = 1 - visible - left };
        }
        else
        {
            var visible = mediaAspect / targetPixelAspect;
            var top = (1 - visible) * anchorY;
            return new Crop { Top = top, Bottom = 1 - visible - top };
        }
    }
}
