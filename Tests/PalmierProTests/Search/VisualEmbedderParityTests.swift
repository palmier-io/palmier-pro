import CoreGraphics
import CoreML
import Foundation
import ImageIO
import Testing
@testable import PalmierPro

/// Parity against Phase-0 golden vectors. Skips when models/siglip2/build artifacts are absent.
@Suite("VisualEmbedder parity", .serialized)
struct VisualEmbedderParityTests {
    static let buildDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("models/siglip2")
        .appendingPathComponent(ProcessInfo.processInfo.environment["SIGLIP2_BUILD"] ?? "build")
        .appendingPathComponent("siglip2-base-patch16-256")
    static var artifactsExist: Bool {
        FileManager.default.fileExists(atPath: buildDir.appendingPathComponent("fixtures.json").path)
    }

    struct Fixtures: Codable {
        struct ImageCase: Codable { let file: String; let embedding: [Float] }
        struct TextCase: Codable { let text: String; let tokens: [Int32]; let embedding: [Float] }
        let images: [ImageCase]
        let texts: [TextCase]
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        let dot = zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
        let na = a.reduce(0) { $0 + $1 * $1 }.squareRoot()
        let nb = b.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return dot / (na * nb)
    }

    static func loadModel() async throws -> VisualEmbedder {
        let manifest = try JSONDecoder().decode(
            VisualEmbedder.Spec.self,
            from: Data(contentsOf: buildDir.appendingPathComponent("manifest.json"))
        )
        let tokenizer = try await TextTokenizer(
            tokenizerFolder: buildDir.appendingPathComponent("tokenizer", isDirectory: true),
            contextLength: manifest.contextLength
        )
        let imageURL = try await MLModel.compileModel(at: buildDir.appendingPathComponent("ImageEncoder.mlpackage"))
        let textURL = try await MLModel.compileModel(at: buildDir.appendingPathComponent("TextEncoder.mlpackage"))
        return try VisualEmbedder(
            imageEncoderURL: imageURL, textEncoderURL: textURL,
            tokenizer: tokenizer, spec: manifest, computeUnits: .cpuOnly
        )
    }

    @Test(.enabled(if: artifactsExist)) func imageAndTextParity() async throws {
        let model = try await Self.loadModel()
        let fixtures = try JSONDecoder().decode(
            Fixtures.self,
            from: Data(contentsOf: Self.buildDir.appendingPathComponent("fixtures.json"))
        )
        let tokenizer = try await TextTokenizer(
            tokenizerFolder: Self.buildDir.appendingPathComponent("tokenizer", isDirectory: true),
            contextLength: model.spec.contextLength
        )

        for c in fixtures.images {
            let url = Self.buildDir.appendingPathComponent(c.file)
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                Issue.record("cannot load \(c.file)")
                continue
            }
            let got = try model.encode(image: image)
            #expect(Self.cosine(got, c.embedding) > 0.985, "image \(c.file)")
        }

        for c in fixtures.texts {
            #expect(tokenizer.tokenize(c.text) == c.tokens, "tokens for \(c.text)")
            let got = try model.encode(text: c.text)
            #expect(Self.cosine(got, c.embedding) > 0.99, "text \(c.text)")
        }
    }
}
