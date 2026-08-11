import Foundation
import Testing
@testable import PalmierPro

@Suite("Export timeline analytics snapshot")
struct ExportTimelineAnalyticsSnapshotTests {
    @Test func stripsPrivateContentAndGroupsCaptions() throws {
        var generated = generationInput()
        generated.prompt = "SECRET_PROMPT"
        generated.resultURLs = ["https://example.com/private"]
        var manifest = MediaManifest()
        manifest.entries = [
            entry("SECRET_MEDIA", "/Users/private/Movies/interview.mov", generation: generated),
        ]

        let media = Fixtures.clip(id: "SECRET_CLIP", mediaRef: "SECRET_MEDIA", start: 0, duration: 30)
        var title = Fixtures.clip(mediaRef: "title", mediaType: .text, start: 0, duration: 30)
        title.textContent = "SECRET_TITLE"
        var firstCaption = Fixtures.clip(mediaRef: "c1", mediaType: .text, start: 5, duration: 5)
        firstCaption.captionGroupId = "SECRET_GROUP"
        firstCaption.textContent = "SECRET_CAPTION_1"
        var secondCaption = Fixtures.clip(mediaRef: "c2", mediaType: .text, start: 15, duration: 10)
        secondCaption.captionGroupId = "SECRET_GROUP"
        var timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [media, title, firstCaption, secondCaption]),
        ])
        timeline.id = "SECRET_TIMELINE"

        let input = makeInput(.exportedTimeline(root: timeline, resolveTimeline: { _ in nil }), manifest)
        let snapshot = try object(input)
        let json = String(decoding: try JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys]),
                          as: UTF8.self)
        let track = try tracks(snapshot)[0]
        let captions = try array(track, "caption_groups")

        #expect(json.contains("\"filename\":\"interview.mov\""))
        #expect((try array(track, "clips")).count == 2)
        #expect(captions.count == 1)
        #expect(captions[0]["caption_count"] as? Int == 2)
        for secret in ["/Users", "private", "SECRET_", "example.com"] {
            #expect(!json.contains(secret))
        }
    }

    @Test func reportsRatiosAndDeduplicatesNestedTimelines() throws {
        var manifest = MediaManifest()
        manifest.entries = [
            entry("generated", "generated.mp4", generation: generationInput()),
            entry("imported", "imported.mov"),
            entry("upscaled", "upscaled.mp4", generation: generationInput(upscale: UpscaleSettings())),
        ]
        var child = Fixtures.timeline()
        child.id = "child"
        var firstNest = Fixtures.clip(mediaRef: child.id, mediaType: .video, start: 120, duration: 10)
        firstNest.sourceClipType = .sequence
        var secondNest = firstNest
        secondNest.startFrame = 130
        var root = Fixtures.timeline(fps: 30, tracks: [Fixtures.videoTrack(clips: [
            Fixtures.clip(mediaRef: "generated", start: 0, duration: 60),
            Fixtures.clip(mediaRef: "imported", start: 60, duration: 30),
            Fixtures.clip(mediaRef: "upscaled", start: 90, duration: 30),
            firstNest, secondNest,
        ])])
        root.id = "root"
        let frozenChild = child
        let childId = child.id

        let input = makeInput(
            .exportedTimeline(root: root, resolveTimeline: { $0 == childId ? frozenChild : nil }), manifest
        )
        let properties = ExportTimelineAnalyticsSnapshot.analyticsProperties(from: input)
        let snapshot = try object(input)
        let rootClips = try array(try tracks(snapshot)[0], "clips")

        #expect((try array(snapshot, "timelines")).count == 2)
        #expect(rootClips.suffix(2).compactMap { $0["nested_timeline_id"] as? String }
            == ["timeline_1", "timeline_1"])
        #expect(properties["generated_visual_clip_count"] as? Int == 1)
        #expect(properties["imported_visual_clip_count"] as? Int == 1)
        #expect(properties["upscaled_visual_clip_count"] as? Int == 1)
        #expect(abs((properties["generated_visual_clip_ratio"] as? Double ?? 0) - 1.0 / 3.0) < 0.000_001)
        #expect(properties["generated_visual_duration_ratio"] as? Double == 0.5)
        let project = try object(makeInput(.project(timelines: [root, child], rootTimelineId: child.id), manifest))
        #expect(project["scope"] as? String == "project")
        #expect(project["root_timeline_id"] as? String == "timeline_1")
        #expect((try array(project, "timelines")).count == 2)
    }

    @Test func analyticsCleaningPreservesZeroAndOneAsNumbers() throws {
        let numbers = [0 as Any, 1 as Any, 0.0 as Any, 1.0 as Any]
            .compactMap { Analytics.clean($0) as? NSNumber }
        #expect(numbers.count == 4)
        #expect(numbers.allSatisfy { CFGetTypeID($0) != CFBooleanGetTypeID() })
        let boolean = try #require(Analytics.clean(true) as? NSNumber)
        #expect(CFGetTypeID(boolean) == CFBooleanGetTypeID())
    }

    private func makeInput(_ scope: ExportTimelineAnalyticsInput.Scope,
                           _ manifest: MediaManifest = .init()) -> ExportTimelineAnalyticsInput {
        ExportTimelineAnalyticsInput(scope: scope, manifest: manifest, exportFilename: "/private/export.mp4")
    }

    private func object(_ input: ExportTimelineAnalyticsInput) throws -> Analytics.Payload {
        try #require(ExportTimelineAnalyticsSnapshot.analyticsProperties(from: input)["timeline_snapshot"]
            as? Analytics.Payload)
    }

    private func array(_ object: Analytics.Payload, _ key: String) throws -> [Analytics.Payload] {
        try #require(object[key] as? [Analytics.Payload])
    }

    private func tracks(_ snapshot: Analytics.Payload) throws -> [Analytics.Payload] {
        let timeline = try #require(array(snapshot, "timelines").first)
        return try array(timeline, "tracks")
    }

    private func entry(_ id: String, _ filename: String, generation: GenerationInput? = nil) -> MediaManifestEntry {
        MediaManifestEntry(
            id: id, name: "PRIVATE_NAME", type: .video,
            source: .external(absolutePath: filename), duration: 10, generationInput: generation
        )
    }

    private func generationInput(upscale: UpscaleSettings? = nil) -> GenerationInput {
        GenerationInput(
            prompt: "generated", model: "model", duration: 5,
            aspectRatio: "16:9", resolution: nil, upscaleSettings: upscale
        )
    }
}
