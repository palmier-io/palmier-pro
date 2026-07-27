import Testing
import CoreGraphics
@testable import PalmierPro

// Regression guard for the Step 1 render-contract abstraction: Mat3 (portable,
// in PalmierCore) must be bit-for-bit equivalent to CGAffineTransform at both
// `concatenating` and `inverted`, because the macOS FrameRenderer bridge
// replaces `t1.concatenating(t2)` with `bridge(t1).concatenating(bridge(t2))`.
// Any drift here silently corrupts every macOS render once the bridge lands.
@Suite("Mat3 ↔ CGAffineTransform parity")
struct Mat3CGAffineTransformParityTests {

    private func cg(_ m: Mat3) -> CGAffineTransform {
        CGAffineTransform(a: m.a, b: m.b, c: m.c, d: m.d, tx: m.tx, ty: m.ty)
    }

    private func approx(_ m1: Mat3, _ m2: CGAffineTransform) -> Bool {
        abs(m1.a - m2.a) < 1e-9 &&
        abs(m1.b - m2.b) < 1e-9 &&
        abs(m1.c - m2.c) < 1e-9 &&
        abs(m1.d - m2.d) < 1e-9 &&
        abs(m1.tx - m2.tx) < 1e-9 &&
        abs(m1.ty - m2.ty) < 1e-9
    }

    private func sampleTransforms() -> [Mat3] {
        [
            .identity,
            Mat3(a: 2, b: 0, c: 0, d: 2, tx: 10, ty: -5),              // uniform scale + translate
            Mat3(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 1080),             // flipY (used by FrameRenderer)
            Mat3(a: 0.5, b: 0.866, c: -0.866, d: 0.5, tx: 100, ty: 50), // 60° rotation + translate
            Mat3(a: 1, b: 0, c: 0, d: 1, tx: -320, ty: 240),            // pure translate
            Mat3(a: 0, b: 1, c: -1, d: 0, tx: 1920, ty: 0),             // 90° rotation
            Mat3(a: 1.5, b: 0.2, c: -0.3, d: 0.75, tx: -50, ty: 33),    // skew + scale
        ]
    }

    @Test func concatenatingMatchesCGAffineTransform() {
        let ts = sampleTransforms()
        for t1 in ts {
            for t2 in ts {
                let cgResult = cg(t1).concatenating(cg(t2))
                let matResult = t1.concatenating(t2)
                #expect(approx(matResult, cgResult),
                        "t1=\(t1) t2=\(t2): Mat3 \(matResult) != CG \(cgResult)")
            }
        }
    }

    @Test func invertedMatchesCGAffineTransform() {
        // Diagnostic: capture CGAffineTransform.inverted for the failing 90°-rotation case.
        let rot90 = Mat3(a: 0, b: 1, c: -1, d: 0, tx: 1920, ty: 0)
        let inv = cg(rot90).inverted()
        print("DIAG_I rot90.inverted: CG a:\(inv.a) b:\(inv.b) c:\(inv.c) d:\(inv.d) tx:\(inv.tx) ty:\(inv.ty)")
        let rot = Mat3(a: 0.5, b: 0.866, c: -0.866, d: 0.5, tx: 100, ty: 50)
        let inv2 = cg(rot).inverted()
        print("DIAG_J rot.inverted: CG a:\(inv2.a) b:\(inv2.b) c:\(inv2.c) d:\(inv2.d) tx:\(inv2.tx) ty:\(inv2.ty)")
        for t in sampleTransforms() where (t.a * t.d - t.b * t.c) != 0 {
            let cgResult = cg(t).inverted()
            let matResult = t.inverted()
            #expect(approx(matResult, cgResult),
                    "t=\(t): Mat3.inverted \(matResult) != CG.inverted \(cgResult)")
        }
    }

    @Test func identityConcatenatingIsNoOp() {
        for t in sampleTransforms() {
            #expect(approx(t.concatenating(.identity), cg(t)))
            #expect(approx(.identity.concatenating(t), cg(t)))
        }
    }

    // The exact transform FrameRenderer.flipY produces (FrameRenderer.swift:366).
    // This is the highest-traffic transform in the pipeline; lock its parity.
    @Test func flipYParityAtMultipleHeights() {
        for height in [0.0, 1.0, 1080.0, 2160.0, 4320.0] {
            let mat = Mat3(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: height)
            let cg = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: height)
            #expect(approx(mat, cg))
            // flipY ∘ flipY == identity
            #expect(approx(mat.concatenating(mat), CGAffineTransform.identity))
        }
    }
}
