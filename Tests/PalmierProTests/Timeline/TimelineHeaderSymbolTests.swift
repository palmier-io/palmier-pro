import AppKit
import Testing
@testable import PalmierPro

@Suite("Timeline header symbols")
@MainActor
struct TimelineHeaderSymbolTests {
    @Test(arguments: [
        "line.3.horizontal",
        "link",
        "personalhotspot.slash",
        "speaker.wave.2.fill",
        "speaker.slash.fill",
        "eye",
        "eye.slash",
    ])
    func rendersDirectSymbolRepresentation(_ name: String) throws {
        let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        let tint = NSColor.systemBlue.withAlphaComponent(0.4)
        let image = try #require(TimelineHeaderSymbol.image(
            named: name,
            tint: tint,
            configuration: configuration
        ))
        let expectedConfiguration = configuration.applying(
            NSImage.SymbolConfiguration(paletteColors: [tint, tint, tint])
        )
        #expect(image.symbolConfiguration == expectedConfiguration)
        #expect(!image.representations.contains { $0 is NSCustomImageRep })

        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 32,
            pixelsHigh: 32,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 8, y: 8, width: 16, height: 16))
        context.flushGraphics()

        let data = try #require(bitmap.bitmapData)
        let bytes = UnsafeBufferPointer(start: data, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        #expect(bytes.contains { $0 != 0 })
    }
}
