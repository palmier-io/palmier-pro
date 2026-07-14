#pragma once

#include <cmath>

// 2D affine transform in the CGAffineTransform (a,b,c,d,tx,ty) layout:
//   x' = a*x + c*y + tx
//   y' = b*x + d*y + ty
// Concatenate(other) matches CGAffineTransform.concatenating(_:) — "self first, then
// other" — so a transform built the same way as CompositionBuilder.affineTransform
// (scale -> translate [-> rotate about center]) composes identically here.
struct Affine2D
{
    double a = 1, b = 0, c = 0, d = 1, tx = 0, ty = 0;

    static Affine2D Identity() { return Affine2D{}; }

    static Affine2D Scale(double sx, double sy) { return Affine2D{sx, 0, 0, sy, 0, 0}; }

    static Affine2D Translation(double x, double y) { return Affine2D{1, 0, 0, 1, x, y}; }

    // Standard 2D rotation matrix applied directly to our top-left-origin, y-down pixel
    // space. In a y-down space this formula rotates clockwise for positive degrees, which
    // is exactly Transform.rotation's documented convention ("positive = clockwise") —
    // see Sources/PalmierPro/Models/Timeline.swift:491. No extra axis flip needed (unlike
    // FrameRenderer.swift's CoreImage round-trip, which flips into/out of a bottom-left
    // origin purely as an artifact of CoreImage's coordinate convention and nets out to
    // the same transform applied directly here — see the header comment in Compositor.h).
    static Affine2D RotationDegrees(double degrees)
    {
        double radians = degrees * 3.14159265358979323846 / 180.0;
        double cs = std::cos(radians);
        double sn = std::sin(radians);
        return Affine2D{cs, sn, -sn, cs, 0, 0};
    }

    Affine2D Concatenate(const Affine2D& t2) const
    {
        return Affine2D{
            a * t2.a + b * t2.c,
            a * t2.b + b * t2.d,
            c * t2.a + d * t2.c,
            c * t2.b + d * t2.d,
            tx * t2.a + ty * t2.c + t2.tx,
            tx * t2.b + ty * t2.d + t2.ty,
        };
    }

    void Apply(double x, double y, double& outX, double& outY) const
    {
        outX = a * x + c * y + tx;
        outY = b * x + d * y + ty;
    }

    // Returns the identity transform if this matrix is singular (degenerate scale) —
    // callers should treat that as "nothing to sample" (zero-size destination).
    Affine2D Inverted() const
    {
        double det = a * d - b * c;
        if (det == 0.0)
        {
            return Affine2D{0, 0, 0, 0, 0, 0};
        }
        double invDet = 1.0 / det;
        double ia = d * invDet;
        double ib = -b * invDet;
        double ic = -c * invDet;
        double id = a * invDet;
        double itx = -(tx * ia + ty * ic);
        double ity = -(tx * ib + ty * id);
        return Affine2D{ia, ib, ic, id, itx, ity};
    }
};
