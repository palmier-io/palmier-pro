import Foundation
import Testing
@testable import CompositorPro

struct VisualSourceAliasesTests {
    private func entry(_ id: String, digest: String, origin: MediaImportOrigin? = nil) -> MediaManifestEntry {
        var entry = MediaManifestEntry(id: id, name: id, type: .video,
            source: .external(absolutePath: "/fixture/\(id)"), duration: 10)
        entry.inputIdentity = .init(contentSHA256: String(repeating: digest, count: 64), byteCount: 100)
        entry.importInput = origin.map { MediaImportInput(origin: $0) }
        return entry
    }

    @Test func unselectedBridgeConnectsCopiesAndStockRenditionsInBothDirections() throws {
        let origin = MediaImportOrigin(provider: "pexels", assetId: "pexels-video-42", landingPageURL: nil)
        var manifest = MediaManifest()
        manifest.entries = [entry("selected", digest: "a"), entry("copy", digest: "a"),
            entry("bridge", digest: "a", origin: origin), entry("rendition", digest: "b", origin: origin),
            entry("distinct", digest: "c")]
        let aliases = VisualSourceAliases(manifest: manifest)
        let expected = Set(["media:selected", "media:copy", "media:bridge", "media:rendition",
            "sha256:\(String(repeating: "a", count: 64))", "sha256:\(String(repeating: "b", count: 64))", origin.sourceId])
        #expect(aliases.expanded(["media:selected"]) == expected)
        #expect(aliases.expanded([origin.sourceId]) == expected)
        #expect(!expected.contains("media:distinct"))
        let local = try ShotCandidateExclusions(aliases: aliases, explicitSourceIds: [], selectedMediaRefs: ["selected"])
        #expect(local.stockSourceIds == [origin.sourceId])
        let stock = try ShotCandidateExclusions(aliases: aliases, explicitSourceIds: [origin.sourceId])
        #expect(stock.excludes(mediaRef: "copy"))
        #expect(stock.excludes(mediaRef: "rendition"))
    }

    @Test func auditStillRejectsTwoTrimsAndCopiedSourcesThroughUnselectedBridge() async throws {
        let origin = MediaImportOrigin(provider: "pixabay", assetId: "pixabay-video-42", landingPageURL: nil)
        var manifest = MediaManifest()
        manifest.entries = [entry("source", digest: "a"), entry("bridge", digest: "a", origin: origin),
            entry("copy", digest: "b", origin: origin)]
        let occurrences = [
            VisualOccurrence(mediaRef: "source", clipIds: ["trim-one"], lane: ["board"], startFrame: 0,
                endFrame: 30, sourceStart: 0, sourceEnd: 30, isImage: false),
            VisualOccurrence(mediaRef: "source", clipIds: ["trim-two"], lane: ["board"], startFrame: 30,
                endFrame: 60, sourceStart: 90, sourceEnd: 120, isImage: false),
            VisualOccurrence(mediaRef: "copy", clipIds: ["copy-use"], lane: ["board"], startFrame: 60,
                endFrame: 90, sourceStart: 0, sourceEnd: 30, isImage: false),
        ]
        let report = try await VisualUniqueness.audit(occurrences: occurrences, manifest: manifest)
        #expect(report.conflicts.count == 1)
        #expect(report.conflicts.first?.occurrences == occurrences)
        #expect(report.conflicts.first?.sourceIds.contains(origin.sourceId) == true)
        #expect(!report.knownIdentityReuseFree)
        #expect(report.receipt["deliveryVerified"] as? Bool == false)
    }

    @Test func invalidRetainedHashNeverConnectsUnknownSources() async throws {
        var first = entry("one", digest: "a")
        first.inputIdentity = .init(contentSHA256: String(repeating: "a", count: 64), byteCount: 0)
        let second = MediaManifestEntry(id: "two", name: "two", type: .video,
            source: .external(absolutePath: "/fixture/two"), duration: 10, inputIdentity: first.inputIdentity)
        var manifest = MediaManifest()
        manifest.entries = [first, second]
        let aliases = VisualSourceAliases(manifest: manifest)
        #expect(aliases.expanded(["media:one"]) == ["media:one"])
        let occurrences = ["one", "two"].enumerated().map {
            VisualOccurrence(mediaRef: $0.element, clipIds: [$0.element], lane: ["board"],
                startFrame: $0.offset * 30, endFrame: ($0.offset + 1) * 30,
                sourceStart: 0, sourceEnd: 30, isImage: false)
        }
        let report = try await VisualUniqueness.audit(occurrences: occurrences, manifest: manifest)
        #expect(report.conflicts.isEmpty)
        #expect(report.unresolved.map(\.reason) == ["missing_content_identity", "missing_content_identity"])
        #expect(!report.knownIdentityReuseFree)
    }

    @Test(arguments: ["", "media:", "media:has space", "media:one:two", "sha256:abc",
        "sha256:\(String(repeating: "A", count: 64))", "stock:pexels:", "stock:Pexels:42",
        "stock:pexels:42:extra", "https://example.test/video.mp4", "library:one:visual:0-1"])
    func malformedCanonicalIdsAreRejected(id: String) {
        #expect(!VisualSourceAliases.isCanonicalSourceId(id))
    }
}
