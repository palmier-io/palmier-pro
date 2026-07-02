import CoreImage
import Foundation
import Testing
@testable import PalmierPro

@Suite("PersonMaskGeometry")
struct PersonMaskGeometryTests {

    private func mask(fgRect: CGRect, in extent: CGRect) -> CIImage {
        let bg = CIImage(color: .black).cropped(to: extent)
        let fg = CIImage(color: .red).cropped(to: fgRect)
        return fg.composited(over: bg)
    }

    private let extent = CGRect(x: 0, y: 0, width: 100, height: 100)

    @Test func boundingBoxMatchesOnRegion() {
        let m = mask(fgRect: CGRect(x: 25, y: 25, width: 50, height: 50), in: extent)
        guard let box = PersonMaskGeometry.boundingBox(of: m) else {
            Issue.record("expected a bounding box")
            return
        }
        #expect(abs(box.minX - 0.25) < 0.05, "\(box)")
        #expect(abs(box.minY - 0.25) < 0.05, "\(box)")
        #expect(abs(box.width - 0.5) < 0.05, "\(box)")
        #expect(abs(box.height - 0.5) < 0.05, "\(box)")
    }

    @Test func boundingBoxIsNilForEmptyMask() {
        let m = CIImage(color: .black).cropped(to: extent)
        #expect(PersonMaskGeometry.boundingBox(of: m) == nil)
    }

    @Test func overlapWithMatchingBoxIsHigh() {
        let m = mask(fgRect: CGRect(x: 25, y: 25, width: 50, height: 50), in: extent)
        let iou = PersonMaskGeometry.overlap(of: m, with: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        #expect(iou > 0.85, "\(iou)")
    }

    @Test func overlapWithDisjointBoxIsLow() {
        let m = mask(fgRect: CGRect(x: 0, y: 0, width: 20, height: 20), in: extent)
        let iou = PersonMaskGeometry.overlap(of: m, with: CGRect(x: 0.7, y: 0.7, width: 0.2, height: 0.2))
        #expect(iou < 0.05, "\(iou)")
    }

    @Test func maskOverlapIdenticalMasksIsHigh() {
        let m = mask(fgRect: CGRect(x: 10, y: 10, width: 40, height: 40), in: extent)
        #expect(PersonMaskGeometry.overlap(m, m) > 0.85)
    }

    @Test func maskOverlapDisjointMasksIsLow() {
        let a = mask(fgRect: CGRect(x: 0, y: 0, width: 20, height: 20), in: extent)
        let b = mask(fgRect: CGRect(x: 70, y: 70, width: 20, height: 20), in: extent)
        #expect(PersonMaskGeometry.overlap(a, b) < 0.05)
    }
}
