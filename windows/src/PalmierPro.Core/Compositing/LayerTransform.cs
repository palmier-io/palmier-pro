using System.Numerics;
using PalmierPro.Core.Models;

namespace PalmierPro.Core.Compositing;

/// <summary>
/// Clip placement math shared by preview compositing, export, and hit testing.
/// Ports the Mac CompositionBuilder affine math; matrices are row-vector
/// (System.Numerics) in top-left-origin canvas space, matching Direct2D.
/// </summary>
public static class LayerTransform
{
    /// <summary>Maps source pixels (natural size) onto the render canvas per the clip transform.</summary>
    public static Matrix3x2 Placement(
        Transform t, double natWidth, double natHeight, double renderWidth, double renderHeight)
    {
        if (natWidth <= 0 || natHeight <= 0) return Matrix3x2.Identity;
        var (topLeftX, topLeftY) = t.TopLeft;
        var scaleX = (float)(renderWidth / natWidth * t.Width * (t.FlipHorizontal ? -1 : 1));
        var scaleY = (float)(renderHeight / natHeight * t.Height * (t.FlipVertical ? -1 : 1));
        var translateX = (float)((t.FlipHorizontal ? topLeftX + t.Width : topLeftX) * renderWidth);
        var translateY = (float)((t.FlipVertical ? topLeftY + t.Height : topLeftY) * renderHeight);
        var placed = Matrix3x2.CreateScale(scaleX, scaleY)
            * Matrix3x2.CreateTranslation(translateX, translateY);
        return placed * CanvasRotation(t, renderWidth, renderHeight);
    }

    /// <summary>Rotation about the clip's center point in canvas space.</summary>
    public static Matrix3x2 CanvasRotation(Transform t, double renderWidth, double renderHeight)
    {
        if (t.Rotation == 0) return Matrix3x2.Identity;
        var centerX = (float)(t.CenterX * renderWidth);
        var centerY = (float)(t.CenterY * renderHeight);
        return Matrix3x2.CreateRotation(
            (float)(t.Rotation * Math.PI / 180.0), new Vector2(centerX, centerY));
    }
}
