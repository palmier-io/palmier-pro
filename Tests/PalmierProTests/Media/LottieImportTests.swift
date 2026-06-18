import AppKit
import Testing
@testable import PalmierPro

@Suite("LottieImport")
struct LottieImportTests {

    @Test func classifiesExtensions() {
        #expect(ClipType(fileExtension: "json") == .lottie)
        #expect(ClipType(fileExtension: "lottie") == .lottie)
        #expect(ClipType(fileExtension: "webp") == .image)
        #expect(ClipType.lottie.isVisual)
        #expect(ClipType.lottie.isCompatible(with: .video))
        #expect(ClipType.lottie.isCompatible(with: .image))
        #expect(!ClipType.lottie.isCompatible(with: .audio))
    }

    @Test func sniffAcceptsLottieRejectsPlainJSON() throws {
        let lottie = try LottieVideoGeneratorTests.writeSample()
        defer { try? FileManager.default.removeItem(at: lottie) }
        #expect(LottieVideoGenerator.isLottie(at: lottie))

        let plain = FileManager.default.temporaryDirectory
            .appendingPathComponent("plain-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: plain) }
        try #"{"hello":"world","count":3}"#.write(to: plain, atomically: true, encoding: .utf8)
        #expect(!LottieVideoGenerator.isLottie(at: plain))
    }

    @Test @MainActor func loadsMetadataAndThumbnail() async throws {
        let url = try LottieVideoGeneratorTests.writeSample()
        defer { try? FileManager.default.removeItem(at: url) }

        let asset = MediaAsset(url: url, type: .lottie, name: "probe")
        await asset.loadMetadata()

        #expect(abs(asset.duration - 1.0) < 0.01)   // 30 frames @ 30fps
        #expect(asset.sourceWidth == 100)
        #expect(asset.sourceHeight == 100)
        #expect(asset.sourceFPS == 30)
        #expect(asset.thumbnail != nil)
    }
}
