import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PalmierPro

@Suite("Gateway images — routing")
struct GatewayImageRoutingTests {
    @Test func referenceCountPicksTheOp() {
        #expect(GatewayImageRouting.op(forReferenceCount: 0) == .generate)
        #expect(GatewayImageRouting.op(forReferenceCount: 1) == .edit)
        #expect(GatewayImageRouting.op(forReferenceCount: 2) == .compose)
        #expect(GatewayImageRouting.op(forReferenceCount: 3) == .compose)
        #expect(GatewayImageRouting.op(forReferenceCount: 4) == nil)
    }
}

@Suite("Gateway images — multipart encoding")
struct GatewayMultipartTests {
    @Test func fieldsAndPartsEncodeInOrder() {
        let body = OpenAICompatGenerationClient.multipartBody(
            boundary: "B",
            fields: ["model": "m", "prompt": "p"],
            parts: [.init(name: "image", filename: "image.png", contentType: "image/png", data: Data([0xFF, 0x00]))]
        )
        let text = String(decoding: body, as: UTF8.self)
        #expect(text.hasPrefix("--B\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nm\r\n"))
        #expect(text.contains("Content-Disposition: form-data; name=\"prompt\"\r\n\r\np\r\n"))
        #expect(text.contains("Content-Disposition: form-data; name=\"image\"; filename=\"image.png\"\r\nContent-Type: image/png\r\n\r\n"))
        #expect(text.hasSuffix("--B--\r\n"))
        #expect(body.range(of: Data([0xFF, 0x00])) != nil)
    }

    @Test func fieldsAreSortedForDeterminism() {
        let a = OpenAICompatGenerationClient.multipartBody(boundary: "B", fields: ["z": "1", "a": "2"], parts: [])
        let text = String(decoding: a, as: UTF8.self)
        let aIndex = text.range(of: "name=\"a\"")!.lowerBound
        let zIndex = text.range(of: "name=\"z\"")!.lowerBound
        #expect(aIndex < zIndex)
    }
}

@Suite("Gateway images — chat compose parsing")
struct GatewayChatComposeTests {
    private let pixel = Data([0x89, 0x50, 0x4E, 0x47])   // arbitrary bytes round-tripped via base64

    @Test func extractsMarkdownEmbeddedDataURL() {
        let b64 = pixel.base64EncodedString()
        let content = "Here you go: ![compose](data:image/png;base64,\(b64)) — enjoy"
        #expect(OpenAICompatGenerationClient.extractDataURLImage(from: content) == pixel)
    }

    @Test func extractsFromFullChatCompletion() throws {
        let b64 = pixel.base64EncodedString()
        let payload: [String: Any] = [
            "choices": [["message": ["role": "assistant", "content": "![x](data:image/png;base64,\(b64))"]]]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        #expect(OpenAICompatGenerationClient.extractChatImage(from: data) == pixel)
    }

    @Test func missingImageReturnsNil() {
        #expect(OpenAICompatGenerationClient.extractDataURLImage(from: "no image here") == nil)
        let data = try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": "sorry"]]]])
        #expect(OpenAICompatGenerationClient.extractChatImage(from: data) == nil)
    }
}

@Suite("Gateway images — reference downscale")
struct GatewayDownscaleTests {
    private func pngData(width: Int, height: Int) -> Data {
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        // Noise defeats PNG compression so the fixture is actually oversized.
        for _ in 0..<2000 {
            ctx.setFillColor(CGColor(red: .random(in: 0...1), green: .random(in: 0...1), blue: .random(in: 0...1), alpha: 1))
            ctx.fill(CGRect(x: .random(in: 0...CGFloat(width)), y: .random(in: 0...CGFloat(height)), width: 40, height: 40))
        }
        let image = ctx.makeImage()!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    @Test func smallImagePassesThroughUntouched() throws {
        let small = pngData(width: 64, height: 64)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("gw-small-\(UUID().uuidString).png")
        try small.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        #expect(try GatewayGenerationRunner.preparedImageData(from: tmp) == small)
    }

    @Test func oversizedImageLandsUnderTheLimit() throws {
        let limit = 100_000
        let big = pngData(width: 2200, height: 2200)
        try #require(big.count > limit)
        let shrunk = try GatewayGenerationRunner.downscaled(big, limit: limit)
        #expect(shrunk.count <= limit)
        let source = CGImageSourceCreateWithData(shrunk as CFData, nil)
        #expect(source != nil && CGImageSourceGetCount(source!) == 1)
    }
}
