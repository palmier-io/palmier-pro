import Foundation
import Testing
@testable import PalmierPro

@Suite("SourceDragPayload")
struct SourceDragPayloadTests {
    private func card() -> AssetCard {
        AssetCard(id: "x", providerId: "jianying", type: .music, name: "My Song",
                  ref: "music/a b.mp3", thumbnailRef: nil, description: nil,
                  durationMs: 90000, aspect: nil, isLocal: true)
    }

    @Test func roundTripsThroughEncodedString() {
        let encoded = SourceDragPayload(card: card()).encoded()
        #expect(encoded.hasPrefix(SourceDragPayload.scheme))
        #expect(SourceDragPayload.isSourcePayload(encoded))
        let decoded = SourceDragPayload.decodeAll(encoded)
        #expect(decoded.count == 1)
        #expect(decoded[0].providerId == "jianying")
        #expect(decoded[0].ref == "music/a b.mp3")   // spaces / slashes survive base64
        #expect(decoded[0].assetType == .music)
        #expect(decoded[0].durationSeconds == 90)
    }

    @Test func ignoresNonSourceLines() {
        #expect(SourceDragPayload.decodeAll("palmier-asset://abc\npalmier-asset://def").isEmpty)
        #expect(!SourceDragPayload.isSourcePayload("palmier-asset://abc"))
    }

    @Test func missingDurationIsZero() {
        let c = AssetCard(id: "i", providerId: "photos", type: .image, name: "p", ref: "/image/u",
                          thumbnailRef: nil, description: nil, durationMs: nil, aspect: nil, isLocal: true)
        #expect(SourceDragPayload(card: c).durationSeconds == 0)
    }
}
