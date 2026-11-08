import CoreGraphics
import Foundation
import Testing
@testable import CompositorPro

enum MediaInputIdentityFixtures {
    @concurrent
    static func makeFiles() async throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("media-identity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let context = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.8, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
            let image = try #require(context.makeImage())
            let data = try #require(ImageEncoder.encodePNG(image))
            try data.write(to: directory.appendingPathComponent("original.png"))
            try data.write(to: directory.appendingPathComponent("renamed.png"))
            return directory
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    @concurrent
    static func remove(_ url: URL) async throws {
        try FileManager.default.removeItem(at: url)
    }
}

@Suite("Media input identity")
struct MediaInputIdentityTests {
    @Test func persistedProvenanceDoesNotRetainSignedQueryOrCredentials() throws {
        let url = try #require(URL(string: "https://user:password@example.com/asset.mp4?token=secret#private"))
        #expect(MediaImportInput.provenanceURL(url) == "https://example.com/asset.mp4")
    }

    @Test(arguments: ["", "invalid", String(repeating: "A", count: 64), String(repeating: "a", count: 63)])
    func malformedContentDigestsRemainUnresolved(digest: String) {
        let identity = MediaInputIdentity(contentSHA256: digest, byteCount: 1)
        #expect(!identity.isValid)
        #expect(MediaInputIdentity.receipt(identity: identity, verified: true, origin: nil)["inputId"] == nil)
    }

    @Test func renamedCopiesHaveOneInputIDAndChangedBytesHaveAnother() async throws {
        let directory = try await MediaInputIdentityFixtures.makeFiles()
        let service = MediaInputIdentityService()
        do {
            let original = directory.appendingPathComponent("original.png")
            let renamed = directory.appendingPathComponent("renamed.png")
            async let first = service.identify(original)
            async let second = service.identify(renamed)
            let (a, b) = try await (first, second)
            #expect(a == b)
            #expect(a.isValid)
            #expect(a.inputId.hasPrefix("sha256:"))
            try await Task.detached { try Data("different source bytes".utf8).write(to: renamed) }.value
            let changed = try await service.identify(renamed)
            #expect(changed.inputId != a.inputId)
            #expect(try await service.identify(original, force: true) == a)
        } catch {
            try await MediaInputIdentityFixtures.remove(directory)
            throw error
        }
        try await MediaInputIdentityFixtures.remove(directory)
    }

    @Test func cancellationAndMissingFileDoNotPoisonNextIdentification() async throws {
        let directory = try await MediaInputIdentityFixtures.makeFiles()
        let service = MediaInputIdentityService()
        let url = directory.appendingPathComponent("original.png")
        do {
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await service.identify(url)
            }
            await #expect(throws: CancellationError.self) { try await task.value }
            await #expect(throws: (any Error).self) { try await service.identify(directory.appendingPathComponent("missing.png")) }
            #expect(try await service.identify(url).isValid)
        } catch {
            try await MediaInputIdentityFixtures.remove(directory)
            throw error
        }
        try await MediaInputIdentityFixtures.remove(directory)
    }

    @Test @MainActor func relinkDuringMeasurementRejectsStaleResultEvenAfterURLReturns() async throws {
        let asset = MediaAsset(url: URL(fileURLWithPath: "/identity/original.png"), type: .image, name: "Original")
        let original = asset.url
        let ready = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let identity = MediaInputIdentity(contentSHA256: String(repeating: "a", count: 64), byteCount: 1)
        let task = Task {
            try await asset.prepareInputIdentity { _ in
                ready.continuation.yield(())
                for await _ in release.stream { break }
                return identity
            }
        }
        for await _ in ready.stream { break }
        asset.url = URL(fileURLWithPath: "/identity/replacement.png")
        asset.url = original
        release.continuation.yield(())
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(asset.inputIdentity == nil)
        #expect(!asset.inputIdentityVerified)
        ready.continuation.finish()
        release.continuation.finish()
    }

    @Test @MainActor func retainedRemoteOriginIsNotPendingDownloadState() async throws {
        let directory = try await MediaInputIdentityFixtures.makeFiles()
        do {
            let editor = EditorViewModel()
            let asset = MediaAsset(url: directory.appendingPathComponent("original.png"), type: .image, name: "Stock")
            let origin = MediaImportOrigin(provider: "pexels", assetId: "pexels-photo-42", landingPageURL: "https://www.pexels.com/photo/42/")
            asset.importInput = MediaImportInput(sourceURL: "https://images.pexels.com/42.png", origin: origin)
            asset.generationStatus = .downloading
            editor.importMediaAsset(asset)
            #expect(await editor.finalizeImportedAsset(asset))
            #expect(asset.generationStatus == .none)
            #expect(!asset.isGenerating)
            #expect(asset.importInput?.origin == origin)
            let entry = try #require(editor.mediaManifest.entries.first)
            let restored = MediaAsset(entry: entry, resolvedURL: asset.url)
            #expect(restored.inputIdentity == asset.inputIdentity)
            #expect(restored.importInput == asset.importInput)
            #expect(restored.inputIdentityReceipt["inputIdentityState"] as? String == "unverified")
            #expect(restored.generationStatus == .none)
            restored.relocate(to: directory.appendingPathComponent("relocated.png"))
            #expect(restored.inputIdentity == asset.inputIdentity)
            #expect(!restored.inputIdentityVerified)
        } catch {
            try await MediaInputIdentityFixtures.remove(directory)
            throw error
        }
        try await MediaInputIdentityFixtures.remove(directory)
    }
}
