import AVFoundation
import CoreGraphics
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PalmierPro

@Suite("ImageVideoGenerator")
struct ImageVideoGeneratorTests {
    /// An opaque still (the screenshot case) must encode on the color-tagged H.264 path and tag the
    /// sRGB transfer it actually contains — tagging 709 made preview apply the wrong EOTF.
    @Test func stillVideoTagsSRGBTransfer() async throws {
        let imageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("srgb-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: imageURL) }
        try Self.writeOpaquePNG(rgb: (30, 92, 158), to: imageURL)

        let videoURL = try await ImageVideoGenerator.stillVideo(
            for: imageURL, mediaRef: "srgb-\(UUID().uuidString)", size: CGSize(width: 64, height: 64)
        )
        defer { try? FileManager.default.removeItem(at: videoURL) }

        let asset = AVURLAsset(url: videoURL)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let format = try #require(try await track.load(.formatDescriptions).first)
        let ext = try #require(CMFormatDescriptionGetExtensions(format) as? [CFString: Any])
        #expect(ext[kCMFormatDescriptionExtension_TransferFunction] as? String == AVVideoTransferFunction_IEC_sRGB)
    }

    /// End-to-end: an opaque sRGB image round-trips through the still-encode path with its color
    /// preserved (within H.264 4:2:0 chroma residual). Guards the screenshot → re-import path.
    @Test func opaqueStillRoundTripsColor() async throws {
        let src: (UInt8, UInt8, UInt8) = (30, 92, 158)
        let imageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rt-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: imageURL) }
        try Self.writeOpaquePNG(rgb: src, to: imageURL)

        let videoURL = try await ImageVideoGenerator.stillVideo(
            for: imageURL, mediaRef: "rt-\(UUID().uuidString)", size: CGSize(width: 64, height: 64)
        )
        defer { try? FileManager.default.removeItem(at: videoURL) }

        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: videoURL))
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let (r, g, b) = Self.centerPixel(of: try await gen.image(at: .zero).image)
        #expect(abs(Int(r) - Int(src.0)) <= 6)
        #expect(abs(Int(g) - Int(src.1)) <= 6)
        #expect(abs(Int(b) - Int(src.2)) <= 6)
    }

    private static func centerPixel(of cg: CGImage) -> (UInt8, UInt8, UInt8) {
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(
            data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.interpolationQuality = .none
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (px[0], px[1], px[2])
    }

    private static func solidCGImage(rgb: (UInt8, UInt8, UInt8), size: CGSize) throws -> CGImage {
        let ctx = try #require(CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        ctx.setFillColor(red: CGFloat(rgb.0)/255, green: CGFloat(rgb.1)/255, blue: CGFloat(rgb.2)/255, alpha: 1)
        ctx.fill(CGRect(origin: .zero, size: size))
        return try #require(ctx.makeImage())
    }

    private static func writeOpaquePNG(rgb: (UInt8, UInt8, UInt8), to url: URL) throws {
        let image = try solidCGImage(rgb: rgb, size: CGSize(width: 64, height: 64))
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }
}
