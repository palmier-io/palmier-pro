import CoreGraphics
import Foundation
import Testing
@testable import CompositorPro

@Suite("Canvas settings and preview zoom")
struct CanvasSettingsTests {
    @Test func customSizesClampInsteadOfFailing() {
        #expect(CanvasSettings(width: 10, height: 10).width == CanvasSettings.minimumWidth)
        #expect(CanvasSettings(width: 10, height: 10).height == CanvasSettings.minimumHeight)
        #expect(CanvasSettings(width: 100_000, height: 100_000).width == CanvasSettings.maximumWidth)
        #expect(CanvasSettings(width: 1_080, height: 1_920).width == 1_080)
    }

    @Test func backgroundsRoundTripAndClampBlur() throws {
        let settings = CanvasSettings(width: 1_080, height: 1_920, background: .gradient(start: .init(r: 0, g: 0, b: 0, a: 1), end: .init(r: 1, g: 1, b: 1, a: 1)))
        let decoded = try JSONDecoder().decode(CanvasSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)

        let blur = CanvasSettings(width: 640, height: 360, background: .blur(radius: 900))
        let decodedBlur = try JSONDecoder().decode(CanvasSettings.self, from: JSONEncoder().encode(blur))
        if case .blur(let radius) = decodedBlur.background { #expect(radius == 100) } else { Issue.record("expected blur") }
    }

    @Test func missingBackgroundDecodesAsNone() throws {
        let legacy = Data(#"{"width":1920,"height":1080}"#.utf8)
        let decoded = try JSONDecoder().decode(CanvasSettings.self, from: legacy)
        #expect(decoded.background == .none)
    }

    @Test func zoomClampsAndPanNeverLosesTheContent() {
        var zoom = PreviewZoom()
        zoom.setScale(9)
        #expect(zoom.scale == PreviewZoom.maximumScale)
        zoom.setScale(0.01)
        #expect(zoom.scale == PreviewZoom.minimumScale)
        zoom.setScale(.nan)
        #expect(zoom.scale == 1)

        zoom.setScale(1)
        zoom.setPan(x: 5_000, y: -5_000, viewport: CGSize(width: 800, height: 600))
        #expect(zoom.panX == 0 && zoom.panY == 0)

        zoom.setScale(2)
        zoom.setPan(x: 5_000, y: 5_000, viewport: CGSize(width: 800, height: 600))
        #expect(zoom.panX == 400 && zoom.panY == 300)
    }
}
