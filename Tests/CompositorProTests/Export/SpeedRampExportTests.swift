import Foundation
import Testing
@testable import CompositorPro

/// A speed ramp changes the clip's timeline↔source mapping, so the emitted interchange has to
/// describe the whole curve — not a single average rate.
@Suite("Speed ramp export")
struct SpeedRampExportTests {
    private func makeResolver() throws -> (MediaResolver, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ramp-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // The emitters drop clips whose media they cannot resolve, so register a real entry.
        let path = dir.appendingPathComponent("media-v.mov")
        FileManager.default.createFile(atPath: path.path, contents: Data())
        var manifest = MediaManifest()
        manifest.entries = [MediaManifestEntry(
            id: "media-v", name: "media-v", type: .video,
            source: .external(absolutePath: path.path), duration: 20
        )]
        return (MediaResolver(manifest: { manifest }, projectURL: { nil }), dir)
    }

    private func rampedClip(
        id: String = "ramp", duration: Int = 300, start: Int = 0, endSpeed: Double
    ) -> Clip {
        var clip = Fixtures.clip(id: id, mediaRef: "media-v", start: start, duration: duration)
        clip.speed = 1
        clip.speedTrack = KeyframeTrack(keyframes: [
            Keyframe(frame: 0, value: 1, interpolationOut: .linear),
            Keyframe(frame: duration - 1, value: endSpeed, interpolationOut: .linear),
        ])
        return clip
    }

    private func exportFCPXML(_ timeline: Timeline) async throws -> String {
        let (resolver, dir) = try makeResolver()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("out.fcpxml")
        try await FCPXMLExporter.export(timeline: timeline, resolver: resolver, outputURL: out)
        return try String(contentsOf: out, encoding: .utf8)
    }

    private func exportXML(_ timeline: Timeline) throws -> String {
        let (resolver, dir) = try makeResolver()
        defer { try? FileManager.default.removeItem(at: dir) }
        return XMLExporter.render(timeline: timeline, resolver: resolver)
    }

    // MARK: - FCPXML

    @Test func rampEmitsOneTimeptPerSegmentBoundary() async throws {
        let (resolver, dir) = try makeResolver()
        defer { try? FileManager.default.removeItem(at: dir) }
        var clip = rampedClip(endSpeed: 3)
        clip.speedTrack = KeyframeTrack(keyframes: [
            Keyframe(frame: 0, value: 1, interpolationOut: .linear),
            Keyframe(frame: 150, value: 3, interpolationOut: .linear),
        ])
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])
        let xml = try await exportFCPXML(timeline)

        // Two segments (0–150, 150–299) plus the head point and the full-asset tail.
        #expect(xml.contains("<timeMap"))
        let timepts = xml.components(separatedBy: "<timept ").count - 1
        #expect(timepts == 4)
    }

    @Test func constantSpeedStillEmitsExactlyTwoTimepts() async throws {
        let clip = Fixtures.clip(id: "flat", mediaRef: "media-v", start: 0, duration: 300, speed: 2.0)
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])
        let xml = try await exportFCPXML(timeline)
        let timepts = xml.components(separatedBy: "<timept ").count - 1
        #expect(timepts == 2)
    }

    @Test func unrampedClipEmitsNoTimeMapAtAll() async throws {
        let clip = Fixtures.clip(id: "unity", mediaRef: "media-v", start: 0, duration: 300)
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])
        let xml = try await exportFCPXML(timeline)
        #expect(!xml.contains("<timeMap"))
    }

    // MARK: - Premiere XML

    @Test func rampFlipsVariablespeedAndKeyframesTheSpeedParameter() async throws {
        let clip = rampedClip(endSpeed: 3)
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])
        let xml = try exportXML(timeline)
        #expect(xml.contains("<name>variablespeed</name>"))
        #expect(xml.contains("<value>1</value>"))
        #expect(xml.contains("keyframesequence"))
        #expect(xml.contains("<name>speed</name>"))
    }

    @Test func constantSpeedKeepsVariablespeedOff() async throws {
        let clip = Fixtures.clip(id: "flat", mediaRef: "media-v", start: 0, duration: 300, speed: 2.0)
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])
        let xml = try exportXML(timeline)
        #expect(xml.contains("Time Remap"))
        // variablespeed 1 means the keyframed form, which a constant rate must not use.
        #expect(!xml.contains("keyframesequence"))
    }

    @Test func unitySpeedEmitsNoTimeRemap() async throws {
        let clip = Fixtures.clip(id: "unity", mediaRef: "media-v", start: 0, duration: 300)
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])
        let xml = try exportXML(timeline)
        #expect(!xml.contains("Time Remap"))
    }
}
