import CoreGraphics
import CoreImage
import Foundation
import Testing
@testable import CompositorPro

@Suite("Masks")
struct MaskTests {
    @Test func everyShapeRoundTrips() throws {
        for shape in Mask.Shape.allCases {
            let mask = try Mask(shape: shape, centerX: 0.4, centerY: 0.6, width: 0.5, height: 0.3,
                                rotationDegrees: 45, feather: 0.05, stroke: 0.01, invert: true)
            let decoded = try JSONDecoder().decode(Mask.self, from: JSONEncoder().encode(mask))
            #expect(decoded == mask)
        }
    }

    @Test func invalidParametersAreRejectedAtDecode() {
        func decode(_ json: String) throws -> Mask {
            try JSONDecoder().decode(Mask.self, from: Data(json.utf8))
        }
        #expect(throws: MaskValidationError.self) {
            try decode(#"{"shape":"rectangle","feather":-0.1}"#)
        }
        #expect(throws: MaskValidationError.self) {
            try decode(#"{"shape":"ellipse","width":0}"#)
        }
        #expect(throws: MaskValidationError.self) {
            try decode(#"{"shape":"diamond","stroke":2}"#)
        }
        #expect(throws: MaskValidationError.self) {
            try decode(#"{"shape":"star","centerX":99}"#)
        }
    }

    @Test func defaultsFillMissingFields() throws {
        let decoded = try JSONDecoder().decode(Mask.self, from: Data(#"{"shape":"ellipse"}"#.utf8))
        #expect(decoded.centerX == 0.5 && decoded.width == 1 && !decoded.invert)
    }

    @Test func rectangleMaskHidesPixelsOutsideTheShape() throws {
        let canvas = CGRect(x: 0, y: 0, width: 64, height: 64)
        let source = CIImage(color: .white).cropped(to: canvas)
        let mask = try Mask(shape: .rectangle, width: 0.5, height: 0.5)
        let masked = MaskRenderer.applied(source, mask: mask, canvas: canvas)

        let context = CIContext(options: [.workingColorSpace: NSNull()])
        func alpha(at point: CGPoint) -> UInt8 {
            var pixel = [UInt8](repeating: 0, count: 4)
            context.render(masked, toBitmap: &pixel, rowBytes: 4,
                           bounds: CGRect(x: point.x, y: point.y, width: 1, height: 1),
                           format: .RGBA8, colorSpace: nil)
            return pixel[3]
        }
        #expect(alpha(at: CGPoint(x: 32, y: 32)) > 200)
        #expect(alpha(at: CGPoint(x: 2, y: 2)) < 50)
    }
}
