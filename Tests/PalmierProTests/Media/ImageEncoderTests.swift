import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PalmierPro

@Suite("Image encoder metadata")
struct ImageEncoderTests {
    @Test(arguments: [
        (1, 12, 8),
        (3, 12, 8),
        (6, 8, 12),
        (8, 8, 12),
    ])
    func metadataUsesDisplayOrientedSize(orientation: Int, expectedWidth: Int, expectedHeight: Int) async throws {
        let metadata = try await Self.metadata(width: 12, height: 8, orientation: orientation)
        #expect(metadata.width == expectedWidth)
        #expect(metadata.height == expectedHeight)
    }

    @Test func thumbnailMatchesDisplayOrientedSize() async throws {
        let metadata = try await Self.metadata(width: 12, height: 8, orientation: 6, thumbnailMaxPixelSize: 32)
        let thumbnail = try #require(metadata.thumbnail)
        #expect(metadata.width == thumbnail.width)
        #expect(metadata.height == thumbnail.height)
        #expect(thumbnail.width == 8)
        #expect(thumbnail.height == 12)
    }

    @concurrent
    private static func metadata(
        width: Int,
        height: Int,
        orientation: Int,
        thumbnailMaxPixelSize: Int? = nil
    ) async throws -> ImageEncoder.ImageMetadata {
        let url = try writeJPEG(width: width, height: height, orientation: orientation)
        defer { try? FileManager.default.removeItem(at: url) }
        return ImageEncoder.metadata(url: url, thumbnailMaxPixelSize: thumbnailMaxPixelSize)
    }

    private static func writeJPEG(width: Int, height: Int, orientation: Int) throws -> URL {
        let url = FileIO.temporaryFileURL(pathExtension: "jpg")
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImagePropertyOrientation: orientation] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return url
    }
}
