import Foundation
import Testing
@testable import PalmierPro

@Suite("XMLExporter")
struct XMLExporterTests {

    /// Build a tmpdir + manifest + resolver pointing at empty files on disk.
    /// XMLExporter only checks file existence; it doesn't read contents.
    private func makeResolver(entries: [MediaManifestEntry]) throws -> (MediaResolver, URL) {
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("XMLExporterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        for entry in entries {
            if case let .external(absolutePath) = entry.source {
                FileManager.default.createFile(atPath: absolutePath, contents: Data())
            }
        }
        var manifest = MediaManifest()
        manifest.entries = entries
        let resolver = MediaResolver(
            manifest: { manifest },
            projectURL: { nil }
        )
        return (resolver, tmpDir)
    }

    private func readXML(at url: URL) throws -> String {
        String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    // MARK: - Header / sequence shell

    @Test func headerHasXmemlVersionAndSequenceShell() throws {
        // No clips → output is just the sequence shell. Tests the boilerplate around content.
        let timeline = Fixtures.timeline()
        let (resolver, tmpDir) = try makeResolver(entries: [])
        let outURL = tmpDir.appendingPathComponent("out.xml")

        XMLExporter.export(timeline: timeline, resolver: resolver, outputURL: outURL)

        let xml = try readXML(at: outURL)
        #expect(xml.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"))
        #expect(xml.contains("<xmeml version=\"4\">"))
        #expect(xml.contains("<sequence id=\"sequence-1\">"))
        #expect(xml.contains("<timebase>30</timebase>"))
        #expect(xml.contains("<width>1920</width>"))
        #expect(xml.contains("<height>1080</height>"))
        #expect(xml.contains("</xmeml>"))
    }

    @Test func headerReportsTimelineFpsAndCanvasDimensions() throws {
        var timeline = Fixtures.timeline(fps: 24)
        timeline.width = 1280
        timeline.height = 720
        let (resolver, tmpDir) = try makeResolver(entries: [])
        let outURL = tmpDir.appendingPathComponent("out.xml")

        XMLExporter.export(timeline: timeline, resolver: resolver, outputURL: outURL)

        let xml = try readXML(at: outURL)
        #expect(xml.contains("<timebase>24</timebase>"))
        #expect(xml.contains("<width>1280</width>"))
        #expect(xml.contains("<height>720</height>"))
    }

    @Test func emptyTimelineProducesZeroDuration() throws {
        let timeline = Fixtures.timeline()
        let (resolver, tmpDir) = try makeResolver(entries: [])
        let outURL = tmpDir.appendingPathComponent("out.xml")

        XMLExporter.export(timeline: timeline, resolver: resolver, outputURL: outURL)

        let xml = try readXML(at: outURL)
        #expect(xml.contains("<duration>0</duration>"))
    }

    // MARK: - Clip emission

    @Test func videoClipEmitsClipitemWithStartAndEnd() throws {
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("XMLExporterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let videoFile = tmpDir.appendingPathComponent("video.mp4")
        FileManager.default.createFile(atPath: videoFile.path, contents: Data())

        let entry = MediaManifestEntry(
            id: "media-video",
            name: "MyVideo",
            type: .video,
            source: .external(absolutePath: videoFile.path),
            duration: 5.0
        )
        var manifest = MediaManifest()
        manifest.entries = [entry]
        let resolver = MediaResolver(manifest: { manifest }, projectURL: { nil })

        let clip = Fixtures.clip(id: "clip-1", mediaRef: "media-video", start: 30, duration: 60)
        let track = Fixtures.videoTrack(clips: [clip])
        let timeline = Fixtures.timeline(tracks: [track])

        let outURL = tmpDir.appendingPathComponent("out.xml")
        XMLExporter.export(timeline: timeline, resolver: resolver, outputURL: outURL)

        let xml = try readXML(at: outURL)
        #expect(xml.contains("<clipitem id=\"clipitem-clip-1\">"))
        #expect(xml.contains("<name>MyVideo</name>"))
        #expect(xml.contains("<start>30</start>"))
        #expect(xml.contains("<end>90</end>")) // 30 + 60
    }

    @Test func clipsReferencingUnresolvableMediaAreSkipped() throws {
        // No manifest entry for the clip's mediaRef → resolveURL returns nil → sortEmittable
        // drops the clip → no clipitem element in the output. Pins this fail-soft behavior
        // so a future change to "fail loudly" forces a deliberate test update.
        let (resolver, tmpDir) = try makeResolver(entries: [])
        let clip = Fixtures.clip(id: "ghost-clip", mediaRef: "missing-media", start: 0, duration: 30)
        let track = Fixtures.videoTrack(clips: [clip])
        let timeline = Fixtures.timeline(tracks: [track])

        let outURL = tmpDir.appendingPathComponent("out.xml")
        XMLExporter.export(timeline: timeline, resolver: resolver, outputURL: outURL)

        let xml = try readXML(at: outURL)
        #expect(!xml.contains("ghost-clip"))
        #expect(!xml.contains("clipitem"))
    }

    @Test func repeatedMediaRefEmitsFileOnceThenReferences() throws {
        // First clipitem gets the full <file> element; subsequent references collapse to
        // <file id="..."/> with no children. Catches the emittedFiles cache logic.
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("XMLExporterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let videoFile = tmpDir.appendingPathComponent("video.mp4")
        FileManager.default.createFile(atPath: videoFile.path, contents: Data())

        let entry = MediaManifestEntry(
            id: "shared-media",
            name: "Shared",
            type: .video,
            source: .external(absolutePath: videoFile.path),
            duration: 10.0
        )
        var manifest = MediaManifest()
        manifest.entries = [entry]
        let resolver = MediaResolver(manifest: { manifest }, projectURL: { nil })

        // Two clips referencing the same media file.
        let clip1 = Fixtures.clip(id: "c1", mediaRef: "shared-media", start: 0, duration: 30)
        let clip2 = Fixtures.clip(id: "c2", mediaRef: "shared-media", start: 60, duration: 30)
        let track = Fixtures.videoTrack(clips: [clip1, clip2])
        let timeline = Fixtures.timeline(tracks: [track])

        let outURL = tmpDir.appendingPathComponent("out.xml")
        XMLExporter.export(timeline: timeline, resolver: resolver, outputURL: outURL)

        let xml = try readXML(at: outURL)
        // The full <file> element appears exactly once; the second reference is a self-closing tag.
        let fileOpenCount = xml.components(separatedBy: "<file id=\"file-shared-media-video\">").count - 1
        let fileSelfCloseCount = xml.components(separatedBy: "<file id=\"file-shared-media-video\"/>").count - 1
        #expect(fileOpenCount == 1, "expected exactly one full <file> element, got \(fileOpenCount)")
        #expect(fileSelfCloseCount == 1, "expected exactly one collapsed <file/> reference, got \(fileSelfCloseCount)")
    }

    // MARK: - Track ordering

    @Test func videoTracksAreReversedForFCPConvention() throws {
        // Our model stores video tracks top→bottom; FCP XML wants bottom→top. So the LAST
        // video track in our model should appear FIRST in the XML.
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("XMLExporterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let videoFile = tmpDir.appendingPathComponent("v.mp4")
        FileManager.default.createFile(atPath: videoFile.path, contents: Data())

        let entry = MediaManifestEntry(
            id: "media-v", name: "v", type: .video,
            source: .external(absolutePath: videoFile.path), duration: 5.0
        )
        var manifest = MediaManifest()
        manifest.entries = [entry]
        let resolver = MediaResolver(manifest: { manifest }, projectURL: { nil })

        let topClip = Fixtures.clip(id: "top-clip", mediaRef: "media-v", start: 0, duration: 30)
        let bottomClip = Fixtures.clip(id: "bottom-clip", mediaRef: "media-v", start: 0, duration: 30)
        let timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(label: "V1 (top)", clips: [topClip]),
            Fixtures.videoTrack(label: "V2 (bottom)", clips: [bottomClip]),
        ])

        let outURL = tmpDir.appendingPathComponent("out.xml")
        XMLExporter.export(timeline: timeline, resolver: resolver, outputURL: outURL)

        let xml = try readXML(at: outURL)
        let bottomRange = xml.range(of: "bottom-clip")
        let topRange = xml.range(of: "top-clip")
        #expect(bottomRange != nil && topRange != nil)
        if let b = bottomRange, let t = topRange {
            #expect(b.lowerBound < t.lowerBound, "bottom track should appear before top track in FCP XML")
        }
    }
}
