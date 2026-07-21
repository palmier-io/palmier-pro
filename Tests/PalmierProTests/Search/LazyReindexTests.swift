import Foundation
import Testing
@testable import PalmierPro

// Covers the lazy/scoped re-index + non-blocking read fixes: a cache-tag bump must not fan
// re-transcription across the whole library, reads return cached clips immediately, active-timeline
// assets index first, stale reads fall back to a prior engine tag, and interactive reads preempt
// the background indexer.

@Suite("Lazy reindex — cache tag invariants")
struct CacheTagInvariantTests {
    // A bumped cacheTag must never also appear in priorCacheTags — the current slot and the stale
    // fallback slots must stay disjoint, or a fresh read could resolve to an orphaned prior entry.
    @Test func currentTagNeverListedAsPrior() {
        for engine in LocalSpeechEngine.allCases {
            guard let tag = engine.cacheTag else { continue }
            #expect(!engine.priorCacheTags.contains(tag), "\(engine) lists its current tag \(tag) as prior")
        }
    }
}

@Suite("Lazy reindex — background transcription gate")
struct BackgroundTranscribeGateTests {
    // A stale-under-the-new-tag (or never-cached) asset still reports needsTranscript, but the
    // background indexer only acts on it when an open timeline uses it.
    @Test func onlyTranscribesOpenTimelineAssets() {
        let open: Set<String> = ["a-on-timeline"]
        #expect(SearchIndexCoordinator.shouldBackgroundTranscribe(
            needsTranscript: true, assetId: "a-on-timeline", openTimelineRefs: open) == true)
        #expect(SearchIndexCoordinator.shouldBackgroundTranscribe(
            needsTranscript: true, assetId: "idle-library-asset", openTimelineRefs: open) == false)
        // Already cached under the current tag → nothing to do regardless of timeline membership.
        #expect(SearchIndexCoordinator.shouldBackgroundTranscribe(
            needsTranscript: false, assetId: "a-on-timeline", openTimelineRefs: open) == false)
    }

    // The reported repro: 293 library assets look uncached after a tag bump, one project open.
    @Test func tagBumpDoesNotEnqueueWholeLibrary() {
        let open: Set<String> = ["film-42min", "broll-a"]
        let library = (0..<293).map { "asset-\($0)" } + ["film-42min", "broll-a"]
        let wouldTranscribe = library.filter {
            SearchIndexCoordinator.shouldBackgroundTranscribe(needsTranscript: true, assetId: $0, openTimelineRefs: open)
        }
        #expect(wouldTranscribe.count == 2) // only the open project's assets, never all 295
    }
}

@Suite("Lazy reindex — active-timeline priority ordering")
@MainActor
struct ReindexPriorityTests {
    private func asset(_ id: String) -> MediaAsset {
        MediaAsset(id: id, url: URL(fileURLWithPath: "/tmp/\(id).mov"), type: .video, name: id)
    }

    @Test func activeFirstThenOpenThenRest() {
        let assets = ["rest1", "open1", "active1", "rest2", "active2"].map(asset)
        let ordered = SearchIndexCoordinator.prioritized(
            assets, active: ["active1", "active2"], open: ["open1"])
        // Active tier first, then open, then the rest (original order preserved in tiers 1–2).
        #expect(ordered.map(\.id) == ["active1", "active2", "open1", "rest1", "rest2"])
    }

    // The reported repro: the editor works top-of-cut down, so tier 0 follows TIMELINE order even
    // when it disagrees with library order — the first clip of the cut indexes first.
    @Test func activeTierFollowsTimelineOrder() {
        let assets = ["libA", "act-late", "libB", "act-early", "act-mid"].map(asset)
        let ordered = SearchIndexCoordinator.prioritized(
            assets, active: ["act-early", "act-mid", "act-late"], open: [])
        #expect(ordered.map(\.id) == ["act-early", "act-mid", "act-late", "libA", "libB"])
    }
}

@Suite("Lazy reindex — timeline-ordered refs")
@MainActor
struct OrderedMediaRefsTests {
    @Test func ordersByTimelinePositionFirstUseWins() {
        let editor = EditorViewModel()
        var t1 = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [
                Fixtures.clip(mediaRef: "late", start: 300, duration: 30),
                Fixtures.clip(mediaRef: "early", start: 0, duration: 30),
                Fixtures.clip(mediaRef: "early", start: 600, duration: 30), // reuse: first use wins
            ]),
            Fixtures.audioTrack(clips: [
                Fixtures.clip(mediaRef: "mid", mediaType: .audio, start: 100, duration: 30),
            ]),
        ])
        t1.id = "t1"
        editor.timelines = [t1]
        editor.activeTimelineId = "t1"
        editor.openTimelineIds = ["t1"]
        #expect(editor.orderedMediaRefs(inTimeline: "t1") == ["early", "mid", "late"])
    }
}

@Suite("Lazy reindex — timeline media refs")
@MainActor
struct TimelineMediaRefsTests {
    @Test func gathersRefsFromOpenTimelines() {
        let editor = EditorViewModel()
        var t1 = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [
            Fixtures.clip(mediaRef: "m1", start: 0, duration: 30),
            Fixtures.clip(mediaRef: "m2", start: 30, duration: 30),
        ])])
        var t2 = Fixtures.timeline(tracks: [Fixtures.audioTrack(clips: [
            Fixtures.clip(mediaRef: "m3", mediaType: .audio, start: 0, duration: 30),
        ])])
        t1.id = "t1"; t2.id = "t2"
        editor.timelines = [t1, t2]
        editor.activeTimelineId = "t1"
        editor.openTimelineIds = ["t1", "t2"]

        #expect(editor.mediaRefs(inTimelines: ["t1"]) == ["m1", "m2"])
        #expect(editor.mediaRefs(inTimelines: ["t1", "t2"]) == ["m1", "m2", "m3"])
    }
}

@Suite("Lazy reindex — background transcription gate preemption")
struct GatePreemptionTests {
    @MainActor
    @Test func waitUntilIdleResumesOnlyAfterReadEnds() async {
        let gate = BackgroundTranscriptionGate()
        var order: [String] = []
        gate.beginRead()
        let background = Task { @MainActor in
            await gate.waitUntilIdle()
            order.append("background")
        }
        await Task.yield() // let the background task reach waitUntilIdle and suspend
        order.append("read")
        gate.endRead()
        await background.value
        #expect(order == ["read", "background"]) // interactive read runs ahead of resumed background
    }

    @MainActor
    @Test func idleGateDoesNotBlock() async {
        let gate = BackgroundTranscriptionGate()
        #expect(gate.hasPendingReads == false)
        await gate.waitUntilIdle() // returns immediately with no reads in flight
    }
}
