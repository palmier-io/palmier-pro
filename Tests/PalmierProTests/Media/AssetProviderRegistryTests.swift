import Foundation
import Testing
@testable import PalmierPro

@Suite("AssetProviderRegistry")
struct AssetProviderRegistryTests {

    @Test func lookupResolvesKnownProviders() {
        #expect(AssetProviderRegistry.provider("downloads") != nil)
        #expect(AssetProviderRegistry.provider("projects") != nil)
        #expect(AssetProviderRegistry.provider("nope") == nil)
    }

    @Test func loopbackGuardAcceptsRegisteredHostPort() {
        // Matches the downloads provider's default host+port.
        #expect(AssetProviderRegistry.isRegisteredLoopback(URL(string: "http://127.0.0.1:4617/media/x.mp4")!))
        #expect(AssetProviderRegistry.isRegisteredLoopback(URL(string: "http://127.0.0.1:4618/media/y.mp4")!))
    }

    @Test func loopbackGuardRejectsNonLoopbackAndUnknownPort() {
        #expect(!AssetProviderRegistry.isRegisteredLoopback(URL(string: "http://evil.com:4617/x.mp4")!))
        #expect(!AssetProviderRegistry.isRegisteredLoopback(URL(string: "http://127.0.0.1:9999/x.mp4")!))
    }

    @Test func provenanceRoundTripsThroughManifestEntry() throws {
        var entry = MediaManifestEntry(id: "a", name: "x", type: .video,
                                       source: .project(relativePath: "media/x.mp4"), duration: 1)
        entry.provenance = MediaProvenance(providerId: "downloads", providerRef: "/media/x.mp4")
        let back = try JSONDecoder().decode(MediaManifestEntry.self, from: JSONEncoder().encode(entry))
        #expect(back.provenance?.providerId == "downloads")
        #expect(back.provenance?.providerRef == "/media/x.mp4")
    }
}
