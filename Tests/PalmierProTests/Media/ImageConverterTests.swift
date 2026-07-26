import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PalmierPro

@Suite("Generation reference image conversion")
struct ImageConverterTests {
    @Test func recognizesHEICAndHEIFExtensions() {
        #expect(ImageConverter.requiresConversion(URL(fileURLWithPath: "/tmp/ref.HEIC")))
        #expect(ImageConverter.requiresConversion(URL(fileURLWithPath: "/tmp/ref.heif")))
        #expect(!ImageConverter.requiresConversion(URL(fileURLWithPath: "/tmp/ref.jpg")))
        #expect(!ImageConverter.requiresConversion(URL(fileURLWithPath: "/tmp/ref.png")))
    }

    @Test func convertsOrientedHEICToJPEG() async throws {
        let receipt = try await Self.convertOrientedHEIC()
        #expect(receipt.type == UTType.jpeg.identifier)
        #expect(receipt.width == 8)
        #expect(receipt.height == 12)
    }

    private struct Receipt: Sendable {
        let type: String?
        let width: Int?
        let height: Int?
    }

    @concurrent
    private static func convertOrientedHEIC() async throws -> Receipt {
        let sourceURL = FileIO.temporaryFileURL(pathExtension: "heic")
        let outputURL: URL
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let context = try #require(CGContext(
            data: nil,
            width: 12,
            height: 8,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 12, height: 8))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(
            sourceURL as CFURL,
            UTType.heic.identifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImagePropertyOrientation: 6] as CFDictionary
        )
        #expect(CGImageDestinationFinalize(destination))

        outputURL = try await ImageConverter.convertToJPEG(sourceURL)
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let output = try #require(CGImageSourceCreateWithURL(outputURL as CFURL, nil))
        let properties = try #require(
            CGImageSourceCopyPropertiesAtIndex(output, 0, nil) as? [CFString: Any]
        )
        return Receipt(
            type: CGImageSourceGetType(output) as String?,
            width: properties[kCGImagePropertyPixelWidth] as? Int,
            height: properties[kCGImagePropertyPixelHeight] as? Int
        )
    }
}
