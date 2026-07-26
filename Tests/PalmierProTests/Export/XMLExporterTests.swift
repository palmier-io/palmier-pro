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

    /// Build a video manifest entry whose source path is an empty file in the given dir.
    private func videoManifestEntry(id: String, in dir: String) -> MediaManifestEntry {
        let path = (dir as NSString).appendingPathComponent("\(id).mp4")
        return MediaManifestEntry(
            id: id, name: id, type: .video,
            source: .external(absolutePath: path), duration: 1
        )
    }

    /// Build an audio manifest entry whose source path is an empty file in the given dir.
    private func audioManifestEntry(id: String, in dir: String) -> MediaManifestEntry {
        let path = (dir as NSString).appendingPathComponent("\(id).m4a")
        return MediaManifestEntry(
            id: id, name: id, type: .audio,
            source: .external(absolutePath: path), duration: 1
        )
    }

    // MARK: - Header / sequence shell

    @Test func headerHasXmemlVersionAndSequenceShell() async throws {
        // No clips → output is just the sequence shell. Tests the boilerplate around content.
        let timeline = Fixtures.timeline()
        let (resolver, tmpDir) = try makeResolver(entries: [])
        let outURL = tmpDir.appendingPathComponent("out.xml")

        try await XMLExporter.export(timeline: timeline, resolver: resolver, outputURL: outURL)

        let xml = try readXML(at: outURL)
        #expect(xml.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"))
        #expect(xml.contains("<xmeml version=\"4\">"))
        #expect(xml.contains("<sequence id=\"sequence-1\">"))
        #expect(xml.contains("<timebase>30</timebase>"))
        #expect(xml.contains("<width>1920</width>"))
        #expect(xml.contains("<height>1080</height>"))
        #expect(xml.contains("</xmeml>"))
    }

    @Test func exportThrowsWhenDestinationIsUnwritable() async throws {
        // A path inside a directory that does not exist can't be written.
        // The exporter must surface that failure instead of silently "succeeding".
        let timeline = Fixtures.timeline()
        let (resolver, tmpDir) = try makeResolver(entries: [])
        let unwritable = tmpDir
            .appendingPathComponent("does-not-exist", isDirectory: true)
            .appendingPathComponent("out.xml")

        await #expect(throws: (any Error).self) {
            try await XMLExporter.export(timeline: timeline, resolver: resolver, outputURL: unwritable)
        }
        #expect(!FileManager.default.fileExists(atPath: unwritable.path))
    }

    @Test func headerReportsTimelineFpsAndCanvasDimensions() async throws {
        var timeline = Fixtures.timeline(fps: 24)
        timeline.width = 1280
        timeline.height = 720
        let (resolver, tmpDir) = try makeResolver(entries: [])
        let outURL = tmpDir.appendingPathComponent("out.xml")

        try await XMLExporter.export(timeline: timeline, resolver: resolver, outputURL: outURL)

        let xml = try readXML(at: outURL)
        #expect(xml.contains("<timebase>24</timebase>"))
        #expect(xml.contains("<width>1280</width>"))
        #expect(xml.contains("<height>720</height>"))
    }

    @Test func emptyTimelineProducesZeroDuration() async throws {
        let timeline = Fixtures.timeline()
        let (resolver, tmpDir) = try makeResolver(entries: [])
        let outURL = tmpDir.appendingPathComponent("out.xml")

        try await XMLExporter.export(timeline: timeline, resolver: resolver, outputURL: outURL)

        let xml = try readXML(at: outURL)
        #expect(xml.contains("<duration>0</duration>"))
    }

    // MARK: - Clip emission

    @Test func videoClipEmitsClipitemWithStartAndEnd() async throws {
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
        try await XMLExporter.export(timeline: timeline, resolver: resolver, outputURL: outURL)

        let xml = try readXML(at: outURL)
        #expect(xml.contains("<clipitem id=\"clipitem-clip-1\">"))
        #expect(xml.contains("<name>MyVideo</name>"))
        #expect(xml.contains("<start>30</start>"))
        #expect(xml.contains("<end>90</end>")) // 30 + 60
    }

    @Test func clipsReferencingUnresolvableMediaAreSkipped() async throws {
        // No manifest entry for the clip's mediaRef → resolveURL returns nil → sortEmittable
        // drops the clip → no clipitem element in the output. Pins this fail-soft behavior
        // so a future change to "fail loudly" forces a deliberate test update.
        let (resolver, tmpDir) = try makeResolver(entries: [])
        let clip = Fixtures.clip(id: "ghost-clip", mediaRef: "missing-media", start: 0, duration: 30)
        let track = Fixtures.videoTrack(clips: [clip])
        let timeline = Fixtures.timeline(tracks: [track])

        let outURL = tmpDir.appendingPathComponent("out.xml")
        try await XMLExporter.export(timeline: timeline, resolver: resolver, outputURL: outURL)

        let xml = try readXML(at: outURL)
        #expect(!xml.contains("ghost-clip"))
        #expect(!xml.contains("clipitem"))
    }

    @Test func repeatedMediaRefEmitsFileOnceThenReferences() async throws {
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
        try await XMLExporter.export(timeline: timeline, resolver: resolver, outputURL: outURL)

        let xml = try readXML(at: outURL)
        // The full <file> element appears exactly once; the second reference is a self-closing tag.
        let fileOpenCount = xml.components(separatedBy: "<file id=\"file-shared-media-video\">").count - 1
        let fileSelfCloseCount = xml.components(separatedBy: "<file id=\"file-shared-media-video\"/>").count - 1
        #expect(fileOpenCount == 1, "expected exactly one full <file> element, got \(fileOpenCount)")
        #expect(fileSelfCloseCount == 1, "expected exactly one collapsed <file/> reference, got \(fileSelfCloseCount)")
    }

    // MARK: - Track ordering

    // MARK: - Audio clips

    @Test func audioClipAppearsInAudioSectionOnly() async throws {
        let (resolver, tmpDir) = try makeResolver(entries: [audioManifestEntry(id: "media-a", in: NSTemporaryDirectory())])
        let clip = Fixtures.clip(id: "audio-clip", mediaRef: "media-a", mediaType: .audio, start: 0, duration: 30)
        let timeline = Fixtures.timeline(tracks: [Fixtures.audioTrack(clips: [clip])])

        let outURL = tmpDir.appendingPathComponent("out.xml")
        try await XMLExporter.export(timeline: timeline, resolver: resolver, outputURL: outURL)

        let xml = try readXML(at: outURL)
        guard let audioSec = xml.range(of: "<audio>"), let videoSec = xml.range(of: "<video>") else {
            Issue.record("XML missing audio or video section")
            return
        }
        let clipitemRange = xml.range(of: "audio-clip")
        #expect(clipitemRange != nil)
        if let r = clipitemRange {
            // The audio-clip clipitem must appear AFTER <audio>, not in the <video> section.
            #expect(r.lowerBound > audioSec.lowerBound)
            #expect(r.lowerBound > videoSec.upperBound, "audio clipitem leaked into the video section")
        }
    }

    // MARK: - Links

    @Test func linkedClipsEmitCrossReferences() async throws {
        // Video + audio sharing a linkGroupId emit <link> entries pointing at each other.
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("XMLExporterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        let videoFile = tmpDir.appendingPathComponent("v.mp4")
        let audioFile = tmpDir.appendingPathComponent("a.m4a")
        FileManager.default.createFile(atPath: videoFile.path, contents: Data())
        FileManager.default.createFile(atPath: audioFile.path, contents: Data())

        var manifest = MediaManifest()
        manifest.entries = [
            MediaManifestEntry(id: "media-v", name: "v", type: .video, source: .external(absolutePath: videoFile.path), duration: 1),
            MediaManifestEntry(id: "media-a", name: "a", type: .audio, source: .external(absolutePath: audioFile.path), duration: 1),
        ]
        let resolver = MediaResolver(manifest: { manifest }, projectURL: { nil })

        var videoClip = Fixtures.clip(id: "vc", mediaRef: "media-v", mediaType: .video, start: 0, duration: 30)
        videoClip.linkGroupId = "group-1"
        var audioClip = Fixtures.clip(id: "ac", mediaRef: "media-a", mediaType: .audio, start: 0, duration: 30)
        audioClip.linkGroupId = "group-1"

        let timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [videoClip]),
            Fixtures.audioTrack(clips: [audioClip]),
        ])

        let outURL = tmpDir.appendingPathComponent("out.xml")
        try await XMLExporter.export(timeline: timeline, resolver: resolver, outputURL: outURL)

        let xml = try readXML(at: outURL)
        #expect(xml.contains("<linkclipref>clipitem-vc</linkclipref>"))
        #expect(xml.contains("<linkclipref>clipitem-ac</linkclipref>"))
        // Each link block has a mediatype declaration.
        #expect(xml.contains("<mediatype>video</mediatype>"))
        #expect(xml.contains("<mediatype>audio</mediatype>"))
    }

    @Test func unlinkedClipsEmitNoLinkBlocks() async throws {
        let (resolver, tmpDir) = try makeResolver(entries: [videoManifestEntry(id: "media-v", in: NSTemporaryDirectory())])
        let clip = Fixtures.clip(id: "lone", mediaRef: "media-v", start: 0, duration: 30)
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])

        let outURL = tmpDir.appendingPathComponent("out.xml")
        try await XMLExporter.export(timeline: timeline, resolver: resolver, outputURL: outURL)

        let xml = try readXML(at: outURL)
        #expect(!xml.contains("<link>"))
        #expect(!xml.contains("<linkclipref>"))
    }

    // MARK: - Filters

    @Test func speedNotOneEmitsTimeRemapFilter() async throws {
        let (resolver, tmpDir) = try makeResolver(entries: [videoManifestEntry(id: "media-v", in: NSTemporaryDirectory())])
        let clip = Fixtures.clip(id: "c1", mediaRef: "media-v", start: 0, duration: 60, speed: 2.0)
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])

        let outURL = tmpDir.appendingPathComponent("out.xml")
        try await XMLExporter.export(timeline: timeline, resolver: resolver, outputURL: outURL)

        let xml = try readXML(at: outURL)
        #expect(xml.contains("<effectid>timeremap</effectid>"))
        // speed=2.0 → value=200.0 (percentage), 4 decimal places.
        #expect(xml.contains("<value>200.0000</value>"))
    }

    @Test func speedOneEmitsNoTimeRemapFilter() async throws {
        let (resolver, tmpDir) = try makeResolver(entries: [videoManifestEntry(id: "media-v", in: NSTemporaryDirectory())])
        let clip = Fixtures.clip(id: "c1", mediaRef: "media-v", start: 0, duration: 60, speed: 1.0)
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])

        let outURL = tmpDir.appendingPathComponent("out.xml")
        try await XMLExporter.export(timeline: timeline, resolver: resolver, outputURL: outURL)

        let xml = try readXML(at: outURL)
        #expect(!xml.contains("timeremap"))
    }

    @Test func volumeNotOneEmitsAudioLevelsFilter() async throws {
        let (resolver, tmpDir) = try makeResolver(entries: [audioManifestEntry(id: "media-a", in: NSTemporaryDirectory())])
        let clip = Fixtures.clip(id: "c1", mediaRef: "media-a", mediaType: .audio, start: 0, duration: 60, volume: 0.5)
        let timeline = Fixtures.timeline(tracks: [Fixtures.audioTrack(clips: [clip])])

        let outURL = tmpDir.appendingPathComponent("out.xml")
        try await XMLExporter.export(timeline: timeline, resolver: resolver, outputURL: outURL)

        let xml = try readXML(at: outURL)
        #expect(xml.contains("<effectid>audiolevels</effectid>"))
        #expect(xml.contains("<value>0.5000</value>"))
    }

    @Test func volumeAtUnityEmitsNoAudioLevelsFilter() async throws {
        let (resolver, tmpDir) = try makeResolver(entries: [audioManifestEntry(id: "media-a", in: NSTemporaryDirectory())])
        let clip = Fixtures.clip(id: "c1", mediaRef: "media-a", mediaType: .audio, start: 0, duration: 60, volume: 1.0)
        let timeline = Fixtures.timeline(tracks: [Fixtures.audioTrack(clips: [clip])])

        let outURL = tmpDir.appendingPathComponent("out.xml")
        try await XMLExporter.export(timeline: timeline, resolver: resolver, outputURL: outURL)

        let xml = try readXML(at: outURL)
        #expect(!xml.contains("audiolevels"))
    }

    @Test func opacityNotOneEmitsDedicatedOpacityEffect() async throws {
        let (resolver, tmpDir) = try makeResolver(entries: [videoManifestEntry(id: "media-v", in: NSTemporaryDirectory())])
        var clip = Fixtures.clip(id: "c1", mediaRef: "media-v", start: 0, duration: 30)
        clip.opacity = 0.5
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])

        let outURL = tmpDir.appendingPathComponent("out.xml")
        try await XMLExporter.export(timeline: timeline, resolver: resolver, outputURL: outURL)

        let xml = try readXML(at: outURL)
        // FCP7 keeps opacity in its own Opacity effect, not inside Basic Motion.
        #expect(xml.contains("<effectid>opacity</effectid>"))
        #expect(xml.contains("<parameterid>opacity</parameterid>"))
        // opacity 0.5 → 50.0%
        #expect(xml.contains("<value>50.0</value>"))
    }

    @Test func nonDefaultTransformEmitsMotionFilterWithMatchingParams() async throws {
        let (resolver, tmpDir) = try makeResolver(entries: [videoManifestEntry(id: "media-v", in: NSTemporaryDirectory())])
        var clip = Fixtures.clip(id: "c1", mediaRef: "media-v", start: 0, duration: 30)
        // Centered at (0.5, 0.5) is the default; shift to (0.6, 0.6) — non-zero center offset.
        clip.transform = Transform(centerX: 0.6, centerY: 0.4, width: 0.5, height: 0.5, rotation: 45)
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])

        let outURL = tmpDir.appendingPathComponent("out.xml")
        try await XMLExporter.export(timeline: timeline, resolver: resolver, outputURL: outURL)

        let xml = try readXML(at: outURL)
        #expect(xml.contains("<effectid>basic</effectid>"))
        #expect(xml.contains("<parameterid>scale</parameterid>"))
        #expect(xml.contains("<parameterid>rotation</parameterid>"))
        #expect(xml.contains("<parameterid>center</parameterid>"))
        // FCP rotation is counter-clockwise positive; we negate ours when emitting.
        #expect(xml.contains("<value>-45.00</value>"))
        // Scale is t.width * 100 when sourceWidth is unset → 0.5 * 100 = 50.
        #expect(xml.contains("<value>50.00</value>"))
    }

    @Test func defaultClipEmitsNoMotionFilter() async throws {
        let (resolver, tmpDir) = try makeResolver(entries: [videoManifestEntry(id: "media-v", in: NSTemporaryDirectory())])
        let clip = Fixtures.clip(id: "c1", mediaRef: "media-v", start: 0, duration: 30)
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])

        let outURL = tmpDir.appendingPathComponent("out.xml")
        try await XMLExporter.export(timeline: timeline, resolver: resolver, outputURL: outURL)

        let xml = try readXML(at: outURL)
        // Defaults (centerX/Y=0.5, width=height=1, rotation=0, opacity=1) → no filter at all.
        #expect(!xml.contains("<effectid>basic</effectid>"))
    }

    // MARK: - Text clips

    @Test func textClipsAreNotEmitted() async throws {
        // Text clips have no manifest entry (CATextLayer renders them at preview/export time
        // via the AVVideoComposition path, not as composition tracks). XML must skip them too.
        let (resolver, tmpDir) = try makeResolver(entries: [videoManifestEntry(id: "media-v", in: NSTemporaryDirectory())])
        let videoClip = Fixtures.clip(id: "vc", mediaRef: "media-v", start: 0, duration: 30)
        let textClip = Fixtures.clip(id: "tc", mediaRef: "text-no-manifest", mediaType: .text, start: 0, duration: 30)
        let timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [videoClip, textClip]),
        ])

        let outURL = tmpDir.appendingPathComponent("out.xml")
        try await XMLExporter.export(timeline: timeline, resolver: resolver, outputURL: outURL)

        let xml = try readXML(at: outURL)
        #expect(!xml.contains("clipitem-tc"))
        #expect(xml.contains("clipitem-vc"))
    }

    // MARK: - Track enabled state

    @Test func mutedAudioTrackEmitsEnabledFalse() async throws {
        let (resolver, tmpDir) = try makeResolver(entries: [audioManifestEntry(id: "media-a", in: NSTemporaryDirectory())])
        var track = Fixtures.audioTrack(clips: [
            Fixtures.clip(id: "ac", mediaRef: "media-a", mediaType: .audio, start: 0, duration: 30),
        ])
        track.muted = true
        let timeline = Fixtures.timeline(tracks: [track])

        let outURL = tmpDir.appendingPathComponent("out.xml")
        try await XMLExporter.export(timeline: timeline, resolver: resolver, outputURL: outURL)

        let xml = try readXML(at: outURL)
        // Find the <track> block in the <audio> section and verify its enabled flag.
        guard let audioStart = xml.range(of: "<audio>") else { Issue.record("no <audio>"); return }
        let audioSec = xml[audioStart.lowerBound...]
        #expect(audioSec.contains("<enabled>FALSE</enabled>"),
                "muted audio track should produce <enabled>FALSE</enabled>")
    }

    @Test func hiddenVideoTrackEmitsEnabledFalse() async throws {
        let (resolver, tmpDir) = try makeResolver(entries: [videoManifestEntry(id: "media-v", in: NSTemporaryDirectory())])
        var track = Fixtures.videoTrack(clips: [
            Fixtures.clip(id: "vc", mediaRef: "media-v", start: 0, duration: 30),
        ])
        track.hidden = true
        let timeline = Fixtures.timeline(tracks: [track])

        let outURL = tmpDir.appendingPathComponent("out.xml")
        try await XMLExporter.export(timeline: timeline, resolver: resolver, outputURL: outURL)

        let xml = try readXML(at: outURL)
        guard let videoStart = xml.range(of: "<video>") else { Issue.record("no <video>"); return }
        guard let videoEnd = xml.range(of: "</video>") else { Issue.record("no </video>"); return }
        let videoSec = xml[videoStart.lowerBound..<videoEnd.upperBound]
        #expect(videoSec.contains("<enabled>FALSE</enabled>"))
    }

    // MARK: - Escaping

    @Test func specialCharsInClipNameAreXMLEscaped() async throws {
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("XMLExporterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let videoFile = tmpDir.appendingPathComponent("v.mp4")
        FileManager.default.createFile(atPath: videoFile.path, contents: Data())

        let entry = MediaManifestEntry(
            id: "media-v",
            name: "A & B < C > \"D\" 'E'",
            type: .video,
            source: .external(absolutePath: videoFile.path),
            duration: 1
        )
        var manifest = MediaManifest()
        manifest.entries = [entry]
        let resolver = MediaResolver(manifest: { manifest }, projectURL: { nil })

        let clip = Fixtures.clip(id: "c1", mediaRef: "media-v", start: 0, duration: 30)
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])

        let outURL = tmpDir.appendingPathComponent("out.xml")
        try await XMLExporter.export(timeline: timeline, resolver: resolver, outputURL: outURL)

        let xml = try readXML(at: outURL)
        #expect(xml.contains("A &amp; B &lt; C &gt; &quot;D&quot; &apos;E&apos;"))
        // The raw chars must NOT appear in the escaped section.
        #expect(!xml.contains("A & B"))
    }

    // MARK: - Trim handling

    @Test func trimStartIsReflectedInInOutPoints() async throws {
        let (resolver, tmpDir) = try makeResolver(entries: [videoManifestEntry(id: "media-v", in: NSTemporaryDirectory())])
        let clip = Fixtures.clip(id: "c1", mediaRef: "media-v", start: 0, duration: 60, trimStart: 10)
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])

        let outURL = tmpDir.appendingPathComponent("out.xml")
        try await XMLExporter.export(timeline: timeline, resolver: resolver, outputURL: outURL)

        let xml = try readXML(at: outURL)
        // in = trimStart, out = trimStart + sourceFramesConsumed (= durationFrames * speed = 60 at speed=1).
        #expect(xml.contains("<in>10</in>"))
        #expect(xml.contains("<out>70</out>"))
    }

    // MARK: - Timeline duration

    @Test func sequenceDurationEqualsTimelineTotalFrames() async throws {
        let (resolver, tmpDir) = try makeResolver(entries: [videoManifestEntry(id: "media-v", in: NSTemporaryDirectory())])
        let clipA = Fixtures.clip(id: "a", mediaRef: "media-v", start: 0, duration: 50)
        let clipB = Fixtures.clip(id: "b", mediaRef: "media-v", start: 100, duration: 80) // ends at 180
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clipA, clipB])])

        let outURL = tmpDir.appendingPathComponent("out.xml")
        try await XMLExporter.export(timeline: timeline, resolver: resolver, outputURL: outURL)

        let xml = try readXML(at: outURL)
        // Sequence <duration> appears before the first <media> block; clip <duration> entries
        // come later. We assert both: sequence shows 180, clipA shows source duration (its 1s
        // duration in frames → secondsToFrame(1, fps=30) = 30 — but only if sourceDurationFrames
        // is not present in the entry). For the sequence, 180 is the only timeline-totalFrames-sized
        // value we expect.
        #expect(xml.contains("<duration>180</duration>"))
    }

    @Test func multipleClipsOnSameTrackAreSortedByStartFrame() async throws {
        let (resolver, tmpDir) = try makeResolver(entries: [videoManifestEntry(id: "media-v", in: NSTemporaryDirectory())])
        // Insert in reverse order; exporter must sort by startFrame.
        let later = Fixtures.clip(id: "later", mediaRef: "media-v", start: 100, duration: 30)
        let earlier = Fixtures.clip(id: "earlier", mediaRef: "media-v", start: 0, duration: 30)
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [later, earlier])])

        let outURL = tmpDir.appendingPathComponent("out.xml")
        try await XMLExporter.export(timeline: timeline, resolver: resolver, outputURL: outURL)

        let xml = try readXML(at: outURL)
        guard let earlyRange = xml.range(of: "earlier"), let laterRange = xml.range(of: "later") else {
            Issue.record("expected both clip ids in output")
            return
        }
        #expect(earlyRange.lowerBound < laterRange.lowerBound, "earlier-starting clip must appear first in the XML")
    }

    @Test func xmlExportThroughExportServiceWritesFileWithoutError() async throws {
        // Drive XML export through the public ExportService API rather than calling
        // XMLExporter directly. Catches misrouting in ExportService.export's switch.
        let (resolver, tmpDir) = try makeResolver(entries: [videoManifestEntry(id: "media-v", in: NSTemporaryDirectory())])
        let clip = Fixtures.clip(id: "c1", mediaRef: "media-v", start: 0, duration: 30)
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])
        let outURL = tmpDir.appendingPathComponent("svc.xml")

        let svc = await ExportService()
        await svc.export(
            timeline: timeline, resolver: resolver,
            format: .xml, resolution: .r1080p, outputURL: outURL
        )
        await #expect(svc.error == nil)
        await #expect(svc.progress == 1.0)
        #expect(FileManager.default.fileExists(atPath: outURL.path))
    }

    @Test func videoTracksAreReversedForFCPConvention() async throws {
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
            Fixtures.videoTrack(clips: [topClip]),
            Fixtures.videoTrack(clips: [bottomClip]),
        ])

        let outURL = tmpDir.appendingPathComponent("out.xml")
        try await XMLExporter.export(timeline: timeline, resolver: resolver, outputURL: outURL)

        let xml = try readXML(at: outURL)
        let bottomRange = xml.range(of: "bottom-clip")
        let topRange = xml.range(of: "top-clip")
        #expect(bottomRange != nil && topRange != nil)
        if let b = bottomRange, let t = topRange {
            #expect(b.lowerBound < t.lowerBound, "bottom track should appear before top track in FCP XML")
        }
    }

    // MARK: - Keyframes, crop, transitions, NTSC

    /// Resolver backed by a real temp file so `resolveURL` (which checks `fileExists`) keeps
    /// the clip; `sourceFPS` drives the file-rate NTSC flag.
    private func fixture(width: Int = 3840, height: Int = 2160, sourceFPS: Double? = nil) throws -> (MediaResolver, URL) {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("kf-\(UUID().uuidString).mov")
        try Data().write(to: file)
        var entry = MediaManifestEntry(
            id: "media-1", name: "Clip", type: .video,
            source: .external(absolutePath: file.path), duration: 5,
            sourceWidth: width, sourceHeight: height
        )
        entry.sourceFPS = sourceFPS
        var manifest = MediaManifest()
        manifest.entries = [entry]
        return (MediaResolver(manifest: { manifest }, projectURL: { nil }), file)
    }

    private func export(_ clip: Clip, resolver: MediaResolver) async -> String {
        let track = clip.mediaType == .audio
            ? Fixtures.audioTrack(clips: [clip])
            : Fixtures.videoTrack(clips: [clip])
        let timeline = Fixtures.timeline(tracks: [track])
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-\(UUID().uuidString).xml")
        try? await XMLExporter.export(timeline: timeline, resolver: resolver, outputURL: out)
        return (try? String(contentsOf: out, encoding: .utf8)) ?? ""
    }

    @Test func positionKeyframesEmitVaryingCenter() async throws {
        let (resolver, file) = try fixture()
        defer { try? FileManager.default.removeItem(at: file) }

        // topLeft (0,0) → center (0.5,0.5) → export (0,0); topLeft (0.5,0.5) → center (1,1) → (1920,-1080).
        var clip = Fixtures.clip(start: 0, duration: 200)
        clip.positionTrack = KeyframeTrack(keyframes: [
            Keyframe(frame: 0, value: AnimPair(a: 0.0, b: 0.0)),
            Keyframe(frame: 100, value: AnimPair(a: 0.5, b: 0.5)),
        ])
        let xml = await export(clip, resolver: resolver)

        #expect(xml.contains("<parameterid>center</parameterid>"))
        // Center is normalized (0 = frame center), not pixels, positive toward bottom-right.
        // topLeft (0.5,0.5) + size 1 → center (1,1) → horiz 0.5, vert 0.5.
        #expect(xml.contains("<horiz>0.50000</horiz>"))
        #expect(xml.contains("<vert>0.50000</vert>"))
    }

    @Test func opacityKeyframesEmittedWithClipRelativeWhen() async throws {
        let (resolver, file) = try fixture()
        defer { try? FileManager.default.removeItem(at: file) }

        // Clip starts at frame 100; keyframes are stored clip-relative.
        var clip = Fixtures.clip(start: 100, duration: 200)
        clip.opacityTrack = KeyframeTrack(keyframes: [
            Keyframe(frame: 30, value: 1.0),
            Keyframe(frame: 150, value: 0.5),
        ])
        let xml = await export(clip, resolver: resolver)

        // Own Opacity effect, not folded into Basic Motion.
        #expect(xml.contains("<effectid>opacity</effectid>"))
        // <when> is clip-relative (the stored offset), and values scale to 0–100.
        #expect(xml.contains("<when>30</when>"))
        #expect(xml.contains("<value>100.0</value>"))
        #expect(xml.contains("<when>150</when>"))
        #expect(xml.contains("<value>50.0</value>"))
    }

    @Test func volumeKeyframesEmittedOnAudioClip() async throws {
        let (resolver, file) = try fixture()
        defer { try? FileManager.default.removeItem(at: file) }

        var clip = Fixtures.clip(mediaType: .audio, start: 0, duration: 100)
        clip.volumeTrack = KeyframeTrack(keyframes: [
            Keyframe(frame: 0, value: 0),    // 0 dB → linear 1
            Keyframe(frame: 50, value: -6),  // attenuated
        ])
        let xml = await export(clip, resolver: resolver)

        #expect(xml.contains("<effectid>audiolevels</effectid>"))
        #expect(xml.contains("<when>0</when>"))
        #expect(xml.contains("<when>50</when>"))
        // A keyframe block lives inside the Level parameter.
        #expect(xml.contains("<keyframe>"))
    }

    @Test func fadesEmitSingleSidedCrossDissolveTransitions() async throws {
        let (resolver, file) = try fixture()
        defer { try? FileManager.default.removeItem(at: file) }

        var clip = Fixtures.clip(start: 100, duration: 200)
        clip.fadeInFrames = 30
        clip.fadeOutFrames = 20
        let xml = await export(clip, resolver: resolver)

        #expect(xml.contains("<effectid>Cross Dissolve</effectid>"))
        // Fade-in: start-black spanning [start, start+fadeIn).
        #expect(xml.contains("<alignment>start-black</alignment>"))
        #expect(xml.contains("<start>100</start>"))
        #expect(xml.contains("<end>130</end>"))
        // Fade-out: end-black spanning [end-fadeOut, end).
        #expect(xml.contains("<alignment>end-black</alignment>"))
        #expect(xml.contains("<start>280</start>"))
        #expect(xml.contains("<end>300</end>"))
        // The transition precedes its clipitem in document order.
        let tIdx = try #require(xml.range(of: "start-black"))
        let cIdx = try #require(xml.range(of: "<clipitem"))
        #expect(tIdx.lowerBound < cIdx.lowerBound)
    }

    @Test func audioClipFadesEmitCrossFadeTransitions() async throws {
        let (resolver, file) = try fixture()
        defer { try? FileManager.default.removeItem(at: file) }

        var clip = Fixtures.clip(mediaType: .audio, start: 0, duration: 100)
        clip.fadeInFrames = 10
        clip.fadeOutFrames = 15
        let xml = await export(clip, resolver: resolver)

        // Audio uses Cross Fade, not the video Cross Dissolve, and carries no wipe tags.
        #expect(xml.contains("<effectid>KGAudioTransCrossFade0dB</effectid>"))
        #expect(xml.contains("<mediatype>audio</mediatype>"))
        #expect(!xml.contains("Cross Dissolve"))
        #expect(!xml.contains("<wipecode>"))
        // Fade-in [0,10) and fade-out [85,100).
        #expect(xml.contains("<start>0</start>"))
        #expect(xml.contains("<end>10</end>"))
        #expect(xml.contains("<start>85</start>"))
        #expect(xml.contains("<end>100</end>"))
    }

    @Test func noFadeEmitsNoTransition() async throws {
        let (resolver, file) = try fixture()
        defer { try? FileManager.default.removeItem(at: file) }

        let clip = Fixtures.clip(start: 0, duration: 100)
        let xml = await export(clip, resolver: resolver)

        #expect(!xml.contains("<transitionitem>"))
    }

    @Test func staticCropEmitsCropFilterAsPercentages() async throws {
        let (resolver, file) = try fixture()
        defer { try? FileManager.default.removeItem(at: file) }

        var clip = Fixtures.clip(start: 0, duration: 100)
        clip.crop = Crop(left: 0.1, top: 0.25, right: 0.2, bottom: 0.05)
        let xml = await export(clip, resolver: resolver)

        #expect(xml.contains("<effectid>crop</effectid>"))
        #expect(xml.contains("<parameterid>left</parameterid>"))
        // 0.1 → 10%, 0.25 → 25%.
        #expect(xml.contains("<value>10.00</value>"))
        #expect(xml.contains("<value>25.00</value>"))
        #expect(!xml.contains("<keyframe>"))
    }

    @Test func cropKeyframesEmitClipRelativeWhen() async throws {
        let (resolver, file) = try fixture()
        defer { try? FileManager.default.removeItem(at: file) }

        var clip = Fixtures.clip(start: 40, duration: 200)
        clip.cropTrack = KeyframeTrack(keyframes: [
            Keyframe(frame: 0, value: Crop()),
            Keyframe(frame: 60, value: Crop(left: 0.5, top: 0, right: 0, bottom: 0)),
        ])
        let xml = await export(clip, resolver: resolver)

        #expect(xml.contains("<effectid>crop</effectid>"))
        #expect(xml.contains("<when>0</when>"))
        #expect(xml.contains("<when>60</when>"))
        #expect(xml.contains("<value>50.00</value>"))
    }

    @Test func identityCropEmitsNoFilter() async throws {
        let (resolver, file) = try fixture()
        defer { try? FileManager.default.removeItem(at: file) }

        let clip = Fixtures.clip(start: 0, duration: 100)
        let xml = await export(clip, resolver: resolver)

        #expect(!xml.contains("<effectid>crop</effectid>"))
    }

    @Test func ntscSourceMarksFileRateTrue() async throws {
        // 29.97 footage → the <file> rate carries ntsc TRUE, while the sequence stays FALSE.
        let (resolver, file) = try fixture(sourceFPS: 30000.0 / 1001.0)
        defer { try? FileManager.default.removeItem(at: file) }

        let xml = await export(Fixtures.clip(start: 0, duration: 100), resolver: resolver)
        #expect(xml.contains("<ntsc>TRUE</ntsc>"))   // the source file
        #expect(xml.contains("<ntsc>FALSE</ntsc>"))  // the sequence
    }

    @Test func cleanFpsSourceStaysNtscFalse() async throws {
        let (resolver, file) = try fixture(sourceFPS: 30.0)
        defer { try? FileManager.default.removeItem(at: file) }

        let xml = await export(Fixtures.clip(start: 0, duration: 100), resolver: resolver)
        #expect(!xml.contains("<ntsc>TRUE</ntsc>"))
    }

    @Test func noKeyframesStillEmitsStaticValueOnly() async throws {
        let (resolver, file) = try fixture()
        defer { try? FileManager.default.removeItem(at: file) }

        var clip = Fixtures.clip(start: 0, duration: 100)
        clip.opacity = 0.5
        let xml = await export(clip, resolver: resolver)

        #expect(xml.contains("<effectid>opacity</effectid>"))
        #expect(!xml.contains("<keyframe>"))
    }
}

@Suite("XMLExporter — nested timelines")
struct XMEMLNestExportTests {

    private func makeResolver(entries: [MediaManifestEntry]) throws -> MediaResolver {
        for entry in entries {
            if case let .external(absolutePath) = entry.source {
                FileManager.default.createFile(atPath: absolutePath, contents: Data())
            }
        }
        var manifest = MediaManifest()
        manifest.entries = entries
        return MediaResolver(manifest: { manifest }, projectURL: { nil })
    }

    private func videoEntry(id: String) -> MediaManifestEntry {
        MediaManifestEntry(
            id: id, name: id, type: .video,
            source: .external(absolutePath: (NSTemporaryDirectory() as NSString).appendingPathComponent("\(id)-\(UUID().uuidString).mp4")),
            duration: 5
        )
    }

    private func carrier(for child: Timeline, start: Int, duration: Int? = nil, trimStart: Int = 0) -> Clip {
        var c = Clip(mediaRef: child.id, mediaType: .sequence, sourceClipType: .sequence,
                     startFrame: start, durationFrames: duration ?? child.totalFrames)
        c.trimStartFrame = trimStart
        return c
    }

    private func render(_ parent: Timeline, timelines: [Timeline], resolver: MediaResolver) -> String {
        let byId = Dictionary(uniqueKeysWithValues: timelines.map { ($0.id, $0) })
        return XMLExporter.render(timeline: parent, resolver: resolver, resolveTimeline: { byId[$0] })
    }

    @Test func nestEmitsInlineSequenceInsideClipitem() throws {
        let resolver = try makeResolver(entries: [videoEntry(id: "v1")])
        var child = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [Fixtures.clip(mediaRef: "v1", start: 0, duration: 60)])])
        child.name = "Intro"
        let parent = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [carrier(for: child, start: 30)])])

        let xml = render(parent, timelines: [child, parent], resolver: resolver)

        #expect(xml.contains("<sequence id=\"sequence-2\">"))
        #expect(xml.contains("<name>Intro</name>"))
        // Carrier placement and trims in parent frames.
        let clipitem = xml.components(separatedBy: "<clipitem").first { $0.contains("sequence-2") } ?? ""
        #expect(clipitem.contains("<start>30</start>"))
        #expect(clipitem.contains("<end>90</end>"))
        #expect(clipitem.contains("<in>0</in>"))
        #expect(clipitem.contains("<out>60</out>"))
        // The child's own clip is inside the nested sequence definition.
        #expect(xml.contains("<pathurl>"))
    }

    @Test func secondCarrierReferencesTheSequenceById() throws {
        let resolver = try makeResolver(entries: [videoEntry(id: "v1")])
        let child = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [Fixtures.clip(mediaRef: "v1", start: 0, duration: 60)])])
        let parent = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [
            carrier(for: child, start: 0),
            carrier(for: child, start: 60),
        ])])

        let xml = render(parent, timelines: [child, parent], resolver: resolver)

        let fullDefs = xml.components(separatedBy: "<sequence id=\"sequence-2\">").count - 1
        let refs = xml.components(separatedBy: "<sequence id=\"sequence-2\"/>").count - 1
        #expect(fullDefs == 1)
        #expect(refs == 1)
    }

    @Test func twoLevelNestingEmitsBothSequences() throws {
        let resolver = try makeResolver(entries: [videoEntry(id: "v1")])
        var grandchild = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [Fixtures.clip(mediaRef: "v1", start: 0, duration: 30)])])
        grandchild.name = "Deep"
        let child = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [carrier(for: grandchild, start: 0)])])
        let parent = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [carrier(for: child, start: 0)])])

        let xml = render(parent, timelines: [grandchild, child, parent], resolver: resolver)

        #expect(xml.contains("<sequence id=\"sequence-2\">"))
        #expect(xml.contains("<sequence id=\"sequence-3\">"))
        #expect(xml.contains("<name>Deep</name>"))
    }

    @Test func frozenCarrierClampsToChildContent() throws {
        let resolver = try makeResolver(entries: [videoEntry(id: "v1")])
        let child = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [Fixtures.clip(mediaRef: "v1", start: 0, duration: 60)])])
        let parent = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [carrier(for: child, start: 0, duration: 100, trimStart: 10)])])

        let xml = render(parent, timelines: [child, parent], resolver: resolver)

        let clipitem = xml.components(separatedBy: "<clipitem").first { $0.contains("sequence-2") } ?? ""
        #expect(clipitem.contains("<in>10</in>"))
        #expect(clipitem.contains("<out>60</out>"))
        #expect(clipitem.contains("<end>50</end>"))
    }

    @Test func emptyOrMissingChildDropsCarrier() throws {
        let resolver = try makeResolver(entries: [])
        let empty = Fixtures.timeline()
        let parent = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [
            carrier(for: empty, start: 0, duration: 30),
            { var c = Fixtures.clip(mediaRef: "no-such-timeline", start: 60, duration: 30)
              c.mediaType = .sequence; c.sourceClipType = .sequence; return c }()
        ])])

        let xml = render(parent, timelines: [empty, parent], resolver: resolver)

        #expect(!xml.contains("<clipitem"))
        #expect(!xml.contains("sequence-2"))
    }

    @Test func linkedCarrierPairEmitsLinkedClipitems() throws {
        let resolver = try makeResolver(entries: [videoEntry(id: "v1")])
        let child = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(mediaRef: "v1", start: 0, duration: 60)]),
            Fixtures.audioTrack(clips: [Fixtures.clip(mediaRef: "v1", mediaType: .audio, start: 0, duration: 60)])
        ])
        var video = carrier(for: child, start: 0)
        var audio = Fixtures.clip(mediaRef: child.id, mediaType: .audio, start: 0, duration: 60)
        audio.sourceClipType = .sequence
        video.linkGroupId = "g1"
        audio.linkGroupId = "g1"
        let parent = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [video]),
            Fixtures.audioTrack(clips: [audio])
        ])

        let xml = render(parent, timelines: [child, parent], resolver: resolver)

        // Both carriers emit; one holds the definition, the other a reference; links pair them.
        let fullDefs = xml.components(separatedBy: "<sequence id=\"sequence-2\">").count - 1
        let refs = xml.components(separatedBy: "<sequence id=\"sequence-2\"/>").count - 1
        #expect(fullDefs == 1)
        #expect(refs == 1)
        #expect(xml.contains("<linkclipref>clipitem-\(video.id)</linkclipref>"))
        #expect(xml.contains("<linkclipref>clipitem-\(audio.id)</linkclipref>"))
    }
}

extension XMLExporterTests {
    // MARK: - File-rate in/out (PAL-166 follow-up: Resolve rejected timeline-rate in/out)

    @Test func slowerSourceEmitsFileRateInOutAndDuration() throws {
        // 29.97 source on a 60fps timeline: trim 240 timeline frames = 4s ≈ 119.88 → 120 file frames.
        let dir = NSTemporaryDirectory()
        var entry = MediaManifestEntry(
            id: "rx", name: "rx", type: .video,
            source: .external(absolutePath: (dir as NSString).appendingPathComponent("rx.mp4")),
            duration: 15.2
        )
        entry.sourceFPS = 29.97
        FileManager.default.createFile(atPath: (dir as NSString).appendingPathComponent("rx.mp4"), contents: Data())
        var manifest = MediaManifest()
        manifest.entries = [entry]
        let resolver = MediaResolver(manifest: { manifest }, projectURL: { nil })

        let clip = Fixtures.clip(id: "c", mediaRef: "rx", start: 300, duration: 300, trimStart: 240)
        var timeline = Fixtures.timeline(fps: 60, tracks: [Fixtures.videoTrack(clips: [clip])])
        timeline.width = 1920
        timeline.height = 1080

        let xml = XMLExporter.render(timeline: timeline, resolver: resolver)

        // clipitem rate = file rate; in/out/duration in 29.97-frame units; start/end stay timeline frames.
        #expect(xml.contains("<in>120</in>"))
        #expect(xml.contains("<out>270</out>"))
        #expect(xml.contains("<start>300</start>"))
        #expect(xml.contains("<end>600</end>"))
        // file duration 15.2s × 29.97 ≈ 456, not 912 timeline frames.
        #expect(xml.contains("<duration>456</duration>"))
    }

    @Test func matchingRateKeepsTimelineFrameInOut() throws {
        let dir = NSTemporaryDirectory()
        let (resolver, _) = try makeResolver(entries: [videoManifestEntry(id: "same", in: dir)])
        let clip = Fixtures.clip(id: "c", mediaRef: "same", start: 0, duration: 30, trimStart: 12)
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])

        let xml = XMLExporter.render(timeline: timeline, resolver: resolver)

        #expect(xml.contains("<in>12</in>"))
        #expect(xml.contains("<out>42</out>"))
    }
}
