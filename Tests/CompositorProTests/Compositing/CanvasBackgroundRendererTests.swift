import CoreImage
import Foundation
import Testing
@testable import CompositorPro

@Suite("Canvas background rendering")
struct CanvasBackgroundRendererTests {
    private let canvas = CGRect(x: 0, y: 0, width: 32, height: 18)
    private let context = CIContext(options: [.workingColorSpace: NSNull()])

    private func pixel(_ image: CIImage, at point: CGPoint) -> [UInt8] {
        var value = [UInt8](repeating: 0, count: 4)
        context.render(image, toBitmap: &value, rowBytes: 4,
                       bounds: CGRect(x: point.x, y: point.y, width: 1, height: 1),
                       format: .RGBA8, colorSpace: nil)
        return value
    }

    @Test func noneProducesNoBackground() {
        #expect(CanvasBackgroundRenderer.image(for: .none, canvas: canvas) == nil)
    }

    @Test func solidFillsWithTheRequestedColor() throws {
        let image = try #require(CanvasBackgroundRenderer.image(for: .solid(.init(r: 0, g: 0, b: 1, a: 1)), canvas: canvas))
        let value = pixel(image, at: CGPoint(x: 16, y: 9))
        #expect(value[0] < 10 && value[2] > 240 && value[3] > 240)
    }

    @Test func gradientVariesVertically() throws {
        let gradient = CanvasBackground.gradient(start: .init(r: 0, g: 0, b: 0, a: 1),
                                                 end: .init(r: 1, g: 1, b: 1, a: 1))
        let image = try #require(CanvasBackgroundRenderer.image(for: gradient, canvas: canvas))
        let top = pixel(image, at: CGPoint(x: 16, y: 17))
        let bottom = pixel(image, at: CGPoint(x: 16, y: 1))
        #expect(top[0] != bottom[0])
    }

    @Test func blurUsesContentOrFallsBackToSolid() throws {
        let content = CIImage(color: .init(red: 1, green: 0, blue: 0, alpha: 1)).cropped(to: canvas)
        let blurred = try #require(CanvasBackgroundRenderer.image(for: .blur(radius: 6), canvas: canvas, content: content))
        let value = pixel(blurred, at: CGPoint(x: 16, y: 9))
        #expect(value[0] > 120)

        let fallback = try #require(CanvasBackgroundRenderer.image(for: .blur(radius: 6), canvas: canvas))
        #expect(pixel(fallback, at: CGPoint(x: 16, y: 9))[3] > 240)
    }
}
