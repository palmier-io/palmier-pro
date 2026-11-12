import Foundation
import Testing
@testable import CompositorPro

struct ShotCandidateExclusionTests {
    private func asset(_ id: String, digest: String? = nil, origin: MediaImportOrigin? = nil) -> LibraryShotAsset {
        LibraryShotAsset(id: id, name: id, type: .video, durationSeconds: 10, readiness: .ready,
            inputId: digest.map { "sha256:\(String(repeating: $0, count: 64))" }, origin: origin)
    }

    private func hit(_ id: String) -> StockMediaHit {
        StockMediaHit(id: id, kind: .video, title: id, url: "https://example.test/\(id).mp4",
            thumbnailURL: nil, creator: "Creator", creatorURL: nil, license: "CC0", licenseURL: nil,
            providerID: "pexels", landingPageURL: nil, width: 1920, height: 1080, durationSeconds: 10,
            fileSizeBytes: nil, attributionText: "Creator, CC0")
    }

    @Test func sourceDedupePrecedesRankAndLimitAcrossTrimsCopiesAndRemoteOrigins() throws {
        let origin = hit("used").origin
        let library = [asset("one", digest: "a", origin: origin), asset("copy", digest: "a"),
            asset("two", digest: "b"), asset("three", digest: "c")]
        let assets = Dictionary(uniqueKeysWithValues: library.map { ($0.id, $0) })
        let bundle = ShotCandidateBuilder.build(kind: .video, visual: [
            .init(assetID: "one", startSeconds: 0, endSeconds: 1, score: 0.99),
            .init(assetID: "one", startSeconds: 3, endSeconds: 4, score: 0.98),
            .init(assetID: "copy", startSeconds: 0, endSeconds: 1, score: 0.97),
            .init(assetID: "two", startSeconds: 0, endSeconds: 1, score: 0.8),
            .init(assetID: "three", startSeconds: 0, endSeconds: 1, score: 0.7),
        ], spoken: [.init(assetID: "one", startSeconds: 5, endSeconds: 6, text: "words")],
            remote: [hit("used"), hit("new")], assets: assets, limit: 4)
        #expect(bundle.candidates.map(\.mediaRef) == ["one", "two", "three", nil])
        #expect(bundle.candidates.last?.id == "stock:pexels:new")
        #expect(bundle.candidates.map(\.rank) == [1, 2, 3, 4])
        #expect(bundle.droppedUsable == 0)
        #expect(bundle.skipped.filter { $0.reason == "Duplicate source identity." }.count == 4)
    }

    @Test func usedTopHitsAreExcludedBeforeFetchAndDistinctAlternativesFillLimit() async throws {
        let library = [asset("used", digest: "a"), asset("used-copy", digest: "a"),
            asset("next", digest: "b"), asset("next-copy", digest: "b"), asset("last", digest: "c")]
        let aliases = VisualSourceAliases(sources: library.map { .init(mediaRef: $0.id, inputId: $0.inputId, origin: $0.origin) })
        let exclusions = try ShotCandidateExclusions(aliases: aliases, explicitSourceIds: ["media:used"])
        let assets = Dictionary(uniqueKeysWithValues: library.map { ($0.id, $0) })
        let eligible = exclusions.eligibleAssets(assets, kind: .video)
        let hits: [ShotCandidateBuilder.VisualInput] = [
            .init(assetID: "used", startSeconds: 0, endSeconds: 1, score: 1),
            .init(assetID: "used-copy", startSeconds: 0, endSeconds: 1, score: 0.99),
            .init(assetID: "next", startSeconds: 0, endSeconds: 1, score: 0.9),
            .init(assetID: "next", startSeconds: 2, endSeconds: 3, score: 0.89),
            .init(assetID: "next-copy", startSeconds: 0, endSeconds: 1, score: 0.88),
            .init(assetID: "last", startSeconds: 0, endSeconds: 1, score: 0.8),
        ]
        let selected = try await ShotCandidateRetrieval.visual(eligible: eligible, exclusions: exclusions, limit: 2) { count, refs in
            #expect(!refs.contains("used"))
            #expect(!refs.contains("used-copy"))
            return Array(hits.filter { refs.contains($0.assetID) }.prefix(count))
        }
        #expect(selected.map(\.assetID) == ["next", "last"])
        let bundle = ShotCandidateBuilder.build(kind: .video, visual: selected, spoken: [], remote: [],
            assets: assets, limit: 2, aliases: aliases, excludedSourceIds: exclusions.sourceIds)
        #expect(bundle.candidates.map(\.mediaRef) == ["next", "last"])
    }

    @Test func unknownIdentitiesStayDistinctButKeepIdentityBlockers() throws {
        let assets = ["one": asset("one"), "two": asset("two")]
        let aliases = VisualSourceAliases(sources: assets.values.map { .init(mediaRef: $0.id, inputId: $0.inputId, origin: $0.origin) })
        let exclusions = try ShotCandidateExclusions(aliases: aliases, explicitSourceIds: ["media:unknown"])
        let bundle = ShotCandidateBuilder.build(kind: .video, visual: [
            .init(assetID: "one", startSeconds: 0, endSeconds: 1, score: 0.9),
            .init(assetID: "two", startSeconds: 0, endSeconds: 1, score: 0.8),
        ], spoken: [], remote: [], assets: assets, limit: 2, aliases: aliases, excludedSourceIds: exclusions.sourceIds)
        #expect(bundle.candidates.count == 2)
        #expect(bundle.candidates.allSatisfy { $0.usable && $0.blockers == ["missing_content_identity"] })
        #expect(bundle.candidates.allSatisfy { $0.inputIdentityState == "unresolved" })
    }

    @Test func explicitCanonicalExclusionsRejectDuplicatesAndOversizedSets() {
        #expect(throws: ToolError.self) {
            try ShotCandidateExclusions(aliases: .init(), explicitSourceIds: ["media:one", "media:one"])
        }
        #expect(throws: ToolError.self) {
            try ShotCandidateExclusions(aliases: .init(), explicitSourceIds: (0...256).map { "media:\($0)" })
        }
        #expect(throws: Never.self) { try ShotCandidateExclusions(aliases: .init(), explicitSourceIds: []) }
    }

    @Test func currentUnknownIdentityDoesNotReuseStaleManifestAliases() async throws {
        var manifest = MediaManifest()
        let oldIdentity = MediaInputIdentity(contentSHA256: String(repeating: "a", count: 64), byteCount: 100)
        manifest.entries = [MediaManifestEntry(id: "selected", name: "selected", type: .video,
            source: .external(absolutePath: "/fixture/selected"), duration: 10, inputIdentity: oldIdentity)]
        let snapshot = try await ShotCandidateExclusions.snapshot(manifest: manifest,
            assets: [asset("selected"), asset("copy", digest: "a")], explicitSourceIds: [],
            selectedMediaRefs: ["selected"], kind: .video, restrict: nil)
        #expect(snapshot.exclusions.sourceIds == ["media:selected"])
        #expect(snapshot.eligible == ["copy"])
        #expect(snapshot.exclusions.unresolved.map(\.reason) == ["missing_content_identity"])
        #expect(manifest.entries.first?.inputIdentity == oldIdentity)
    }

    @Test func missingSelectedSourceRemainsUnresolvedWithoutExcludingOtherUnknownAssets() async throws {
        let snapshot = try await ShotCandidateExclusions.snapshot(manifest: .init(), assets: [asset("one"), asset("two")],
            explicitSourceIds: [], selectedMediaRefs: ["missing"], kind: .video, restrict: nil)
        #expect(snapshot.eligible == ["one", "two"])
        #expect(snapshot.exclusions.unresolved.map(\.reason) == ["missing_media"])
    }

    @Test func cancelledRetrievalNeverStartsFetch() async throws {
        let exclusions = try ShotCandidateExclusions(aliases: .init(), explicitSourceIds: [])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ShotCandidateRetrieval.visual(eligible: ["one"], exclusions: exclusions, limit: 1) { _, _ in
                Issue.record("Cancelled retrieval started a search")
                return []
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
