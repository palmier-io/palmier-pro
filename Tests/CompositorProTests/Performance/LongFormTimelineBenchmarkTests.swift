import Foundation
import Testing
@testable import CompositorPro

/// 18-minute long-form shape: 40 tracks × 60 clips at 30 fps. Guards that lookup, windowing, and
/// marker queries stay flat as the timeline grows, and records wall-clock numbers for the record.
@Suite("Long-form timeline benchmark")
@MainActor
struct LongFormTimelineBenchmarkTests {
    private let fps = 30
    private let trackCount = 40
    private let clipsPerTrack = 60

    private func longTimeline() -> Timeline {
        let clipLength = 540 // 18 s; 60 clips × 18 s ≈ 18 min per track
        var tracks: [Track] = []
        for trackIndex in 0..<trackCount {
            var clips: [Clip] = []
            for clipIndex in 0..<clipsPerTrack {
                clips.append(Fixtures.clip(id: "t\(trackIndex)-c\(clipIndex)",
                                           mediaRef: "media-\(trackIndex)-\(clipIndex)",
                                           start: clipIndex * clipLength,
                                           duration: clipLength))
            }
            tracks.append(Track(type: .video, clips: clips))
        }
        var timeline = Timeline(name: "Long form", fps: fps, width: 1920, height: 1080, tracks: tracks)
        timeline.markers = (0..<200).map { index in
            TimelineMarker(name: "Marker \(index)", startFrame: index * 150, durationFrames: index % 2 == 0 ? 0 : 30)
        }
        return timeline
    }

    private func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    @Test func eighteenMinuteShapeLookupsStayFast() {
        let harness = ToolHarness()
        harness.editor.timeline = longTimeline()
        let timeline = harness.editor.timeline
        #expect(timeline.tracks.count == trackCount)
        #expect(timeline.tracks.flatMap(\.clips).count == trackCount * clipsPerTrack)

        let lookupStart = ContinuousClock.now
        for index in 0..<2_000 {
            let id = "t\(index % trackCount)-c\(index % clipsPerTrack)"
            #expect(harness.editor.findClip(id: id) != nil)
        }
        let lookups = seconds(ContinuousClock.now - lookupStart)

        let windowStart = ContinuousClock.now
        let window = timeline.tracks.flatMap(\.clips).filter { $0.startFrame < 15_900 && $0.endFrame > 15_000 }
        let windowSeconds = seconds(ContinuousClock.now - windowStart)

        let markerStart = ContinuousClock.now
        let markers = timeline.markers.filter { $0.intersects(15_000..<15_900) }
        let markerSeconds = seconds(ContinuousClock.now - markerStart)
        #expect(!markers.isEmpty)

        let report: [String: Any] = [
            "timelineFrames": timeline.totalFrames,
            "minutes": Double(timeline.totalFrames) / Double(fps * 60),
            "tracks": timeline.tracks.count,
            "clips": timeline.tracks.flatMap(\.clips).count,
            "lookup2000Seconds": lookups,
            "windowClips": window.count,
            "windowSeconds": windowSeconds,
            "markerQuerySeconds": markerSeconds,
        ]
        let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try? data?.write(to: URL(fileURLWithPath: "/tmp/compositor-longform-baseline.json"))

        #expect(timeline.totalFrames == clipsPerTrack * 540)
        // Generous ceilings: these catch accidental quadratic work, not machine speed.
        #expect(lookups < 5)
        #expect(windowSeconds < 1)
        #expect(markerSeconds < 1)
    }
}
