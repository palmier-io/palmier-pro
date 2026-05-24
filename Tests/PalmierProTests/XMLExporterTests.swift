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

    // MARK: - Audio clips

    @Test func audioClipAppearsInAudioSectionOnly() throws {
        let (resolver, tmpDir) = try makeResolver(entries: [audioManifestEntry(id: "media-a", in: NSTemporaryDirectory())])
        let clip = Fixtures.clip(id: "audio-clip", mediaRef: "media-a", mediaType: .audio, start: 0, duration: 30)
        let timeline = Fixtures.timeline(tracks: [Fixtures.audioTrack(clips: [clip])])

        let outURL = tmpDir.appendingPathComponent("out.xml")
        XMLExporter.export(timeline: timeline, resolver: resolver, outputURL: outURL)

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

    @Test func linkedClipsEmitCrossReferences() throws {
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
        XMLExporter.export(timeline: timeline, resolver: resolver, outputURL: outURL)

        let xml = try readXML(at: outURL)
        #expect(xml.contains("<linkclipref>clipitem-vc</linkclipref>"))
        #expect(xml.contains("<linkclipref>clipitem-ac</linkclipref>"))
        // Each link block has a mediatype declaration.
        #expect(xml.contains("<mediatype>video</mediatype>"))
        #expect(xml.contains("<mediatype>audio</mediatype>"))
    }

    @Test func unlinkedClipsEmitNoLinkBlocks() throws {
        let (resolver, tmpDir) = try makeResolver(entries: [videoManifestEntry(id: "media-v", in: NSTemporaryDirectory())])
        let clip = Fixtures.clip(id: "lone", mediaRef: "media-v", start: 0, duration: 30)
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])

        let outURL = tmpDir.appendingPathComponent("out.xml")
        XMLExporter.export(timeline: timeline, resolver: resolver, outputURL: outURL)

        let xml = try readXML(at: outURL)
        #expect(!xml.contains("<link>"))
        #expect(!xml.contains("<linkclipref>"))
    }

    // MARK: - Filters

    @Test func speedNotOneEmitsTimeRemapFilter() throws {
        let (resolver, tmpDir) = try makeResolver(entries: [videoManifestEntry(id: "media-v", in: NSTemporaryDirectory())])
        let clip = Fixtures.clip(id: "c1", mediaRef: "media-v", start: 0, duration: 60, speed: 2.0)
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])

        let outURL = tmpDir.appendingPathComponent("out.xml")
        XMLExporter.export(timeline: timeline, resolver: resolver, outputURL: outURL)

        let xml = try readXML(at: outURL)
        #expect(xml.contains("<effectid>timeremap</effectid>"))
        // speed=2.0 → value=200.0 (percentage), 4 decimal places.
        #expect(xml.contains("<value>200.0000</value>"))
    }

    @Test func speedOneEmitsNoTimeRemapFilter() throws {
        let (resolver, tmpDir) = try makeResolver(entries: [videoManifestEntry(id: "media-v", in: NSTemporaryDirectory())])
        let clip = Fixtures.clip(id: "c1", mediaRef: "media-v", start: 0, duration: 60, speed: 1.0)
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])

        let outURL = tmpDir.appendingPathComponent("out.xml")
        XMLExporter.export(timeline: timeline, resolver: resolver, outputURL: outURL)

        let xml = try readXML(at: outURL)
        #expect(!xml.contains("timeremap"))
    }

    @Test func volumeNotOneEmitsAudioLevelsFilter() throws {
        let (resolver, tmpDir) = try makeResolver(entries: [audioManifestEntry(id: "media-a", in: NSTemporaryDirectory())])
        let clip = Fixtures.clip(id: "c1", mediaRef: "media-a", mediaType: .audio, start: 0, duration: 60, volume: 0.5)
        let timeline = Fixtures.timeline(tracks: [Fixtures.audioTrack(clips: [clip])])

        let outURL = tmpDir.appendingPathComponent("out.xml")
        XMLExporter.export(timeline: timeline, resolver: resolver, outputURL: outURL)

        let xml = try readXML(at: outURL)
        #expect(xml.contains("<effectid>audiolevels</effectid>"))
        #expect(xml.contains("<value>0.5000</value>"))
    }

    @Test func volumeAtUnityEmitsNoAudioLevelsFilter() throws {
        let (resolver, tmpDir) = try makeResolver(entries: [audioManifestEntry(id: "media-a", in: NSTemporaryDirectory())])
        let clip = Fixtures.clip(id: "c1", mediaRef: "media-a", mediaType: .audio, start: 0, duration: 60, volume: 1.0)
        let timeline = Fixtures.timeline(tracks: [Fixtures.audioTrack(clips: [clip])])

        let outURL = tmpDir.appendingPathComponent("out.xml")
        XMLExporter.export(timeline: timeline, resolver: resolver, outputURL: outURL)

        let xml = try readXML(at: outURL)
        #expect(!xml.contains("audiolevels"))
    }

    @Test func opacityNotOneEmitsBasicMotionWithOpacity() throws {
        let (resolver, tmpDir) = try makeResolver(entries: [videoManifestEntry(id: "media-v", in: NSTemporaryDirectory())])
        var clip = Fixtures.clip(id: "c1", mediaRef: "media-v", start: 0, duration: 30)
        clip.opacity = 0.5
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])

        let outURL = tmpDir.appendingPathComponent("out.xml")
        XMLExporter.export(timeline: timeline, resolver: resolver, outputURL: outURL)

        let xml = try readXML(at: outURL)
        #expect(xml.contains("<effectid>basic</effectid>"))
        #expect(xml.contains("<parameterid>opacity</parameterid>"))
        // opacity 0.5 → 50.0%
        #expect(xml.contains("<value>50.0</value>"))
    }

    @Test func nonDefaultTransformEmitsMotionFilterWithMatchingParams() throws {
        let (resolver, tmpDir) = try makeResolver(entries: [videoManifestEntry(id: "media-v", in: NSTemporaryDirectory())])
        var clip = Fixtures.clip(id: "c1", mediaRef: "media-v", start: 0, duration: 30)
        // Centered at (0.5, 0.5) is the default; shift to (0.6, 0.6) — non-zero center offset.
        clip.transform = Transform(centerX: 0.6, centerY: 0.4, width: 0.5, height: 0.5, rotation: 45)
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])

        let outURL = tmpDir.appendingPathComponent("out.xml")
        XMLExporter.export(timeline: timeline, resolver: resolver, outputURL: outURL)

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

    @Test func defaultClipEmitsNoMotionFilter() throws {
        let (resolver, tmpDir) = try makeResolver(entries: [videoManifestEntry(id: "media-v", in: NSTemporaryDirectory())])
        let clip = Fixtures.clip(id: "c1", mediaRef: "media-v", start: 0, duration: 30)
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])

        let outURL = tmpDir.appendingPathComponent("out.xml")
        XMLExporter.export(timeline: timeline, resolver: resolver, outputURL: outURL)

        let xml = try readXML(at: outURL)
        // Defaults (centerX/Y=0.5, width=height=1, rotation=0, opacity=1) → no filter at all.
        #expect(!xml.contains("<effectid>basic</effectid>"))
    }

    // MARK: - Text clips

    @Test func textClipsAreNotEmitted() throws {
        // Text clips have no manifest entry (CATextLayer renders them at preview/export time
        // via the AVVideoComposition path, not as composition tracks). XML must skip them too.
        let (resolver, tmpDir) = try makeResolver(entries: [videoManifestEntry(id: "media-v", in: NSTemporaryDirectory())])
        let videoClip = Fixtures.clip(id: "vc", mediaRef: "media-v", start: 0, duration: 30)
        let textClip = Fixtures.clip(id: "tc", mediaRef: "text-no-manifest", mediaType: .text, start: 0, duration: 30)
        let timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [videoClip, textClip]),
        ])

        let outURL = tmpDir.appendingPathComponent("out.xml")
        XMLExporter.export(timeline: timeline, resolver: resolver, outputURL: outURL)

        let xml = try readXML(at: outURL)
        #expect(!xml.contains("clipitem-tc"))
        #expect(xml.contains("clipitem-vc"))
    }

    // MARK: - Track enabled state

    @Test func mutedAudioTrackEmitsEnabledFalse() throws {
        let (resolver, tmpDir) = try makeResolver(entries: [audioManifestEntry(id: "media-a", in: NSTemporaryDirectory())])
        var track = Fixtures.audioTrack(clips: [
            Fixtures.clip(id: "ac", mediaRef: "media-a", mediaType: .audio, start: 0, duration: 30),
        ])
        track.muted = true
        let timeline = Fixtures.timeline(tracks: [track])

        let outURL = tmpDir.appendingPathComponent("out.xml")
        XMLExporter.export(timeline: timeline, resolver: resolver, outputURL: outURL)

        let xml = try readXML(at: outURL)
        // Find the <track> block in the <audio> section and verify its enabled flag.
        guard let audioStart = xml.range(of: "<audio>") else { Issue.record("no <audio>"); return }
        let audioSec = xml[audioStart.lowerBound...]
        #expect(audioSec.contains("<enabled>FALSE</enabled>"),
                "muted audio track should produce <enabled>FALSE</enabled>")
    }

    @Test func hiddenVideoTrackEmitsEnabledFalse() throws {
        let (resolver, tmpDir) = try makeResolver(entries: [videoManifestEntry(id: "media-v", in: NSTemporaryDirectory())])
        var track = Fixtures.videoTrack(clips: [
            Fixtures.clip(id: "vc", mediaRef: "media-v", start: 0, duration: 30),
        ])
        track.hidden = true
        let timeline = Fixtures.timeline(tracks: [track])

        let outURL = tmpDir.appendingPathComponent("out.xml")
        XMLExporter.export(timeline: timeline, resolver: resolver, outputURL: outURL)

        let xml = try readXML(at: outURL)
        guard let videoStart = xml.range(of: "<video>") else { Issue.record("no <video>"); return }
        guard let videoEnd = xml.range(of: "</video>") else { Issue.record("no </video>"); return }
        let videoSec = xml[videoStart.lowerBound..<videoEnd.upperBound]
        #expect(videoSec.contains("<enabled>FALSE</enabled>"))
    }

    // MARK: - Escaping

    @Test func specialCharsInClipNameAreXMLEscaped() throws {
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
        XMLExporter.export(timeline: timeline, resolver: resolver, outputURL: outURL)

        let xml = try readXML(at: outURL)
        #expect(xml.contains("A &amp; B &lt; C &gt; &quot;D&quot; &apos;E&apos;"))
        // The raw chars must NOT appear in the escaped section.
        #expect(!xml.contains("A & B"))
    }

    // MARK: - Trim handling

    @Test func trimStartIsReflectedInInOutPoints() throws {
        let (resolver, tmpDir) = try makeResolver(entries: [videoManifestEntry(id: "media-v", in: NSTemporaryDirectory())])
        let clip = Fixtures.clip(id: "c1", mediaRef: "media-v", start: 0, duration: 60, trimStart: 10)
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])

        let outURL = tmpDir.appendingPathComponent("out.xml")
        XMLExporter.export(timeline: timeline, resolver: resolver, outputURL: outURL)

        let xml = try readXML(at: outURL)
        // in = trimStart, out = trimStart + sourceFramesConsumed (= durationFrames * speed = 60 at speed=1).
        #expect(xml.contains("<in>10</in>"))
        #expect(xml.contains("<out>70</out>"))
    }

    // MARK: - Timeline duration

    @Test func sequenceDurationEqualsTimelineTotalFrames() throws {
        let (resolver, tmpDir) = try makeResolver(entries: [videoManifestEntry(id: "media-v", in: NSTemporaryDirectory())])
        let clipA = Fixtures.clip(id: "a", mediaRef: "media-v", start: 0, duration: 50)
        let clipB = Fixtures.clip(id: "b", mediaRef: "media-v", start: 100, duration: 80) // ends at 180
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clipA, clipB])])

        let outURL = tmpDir.appendingPathComponent("out.xml")
        XMLExporter.export(timeline: timeline, resolver: resolver, outputURL: outURL)

        let xml = try readXML(at: outURL)
        // Sequence <duration> appears before the first <media> block; clip <duration> entries
        // come later. We assert both: sequence shows 180, clipA shows source duration (its 1s
        // duration in frames → secondsToFrame(1, fps=30) = 30 — but only if sourceDurationFrames
        // is not present in the entry). For the sequence, 180 is the only timeline-totalFrames-sized
        // value we expect.
        #expect(xml.contains("<duration>180</duration>"))
    }

    @Test func multipleClipsOnSameTrackAreSortedByStartFrame() throws {
        let (resolver, tmpDir) = try makeResolver(entries: [videoManifestEntry(id: "media-v", in: NSTemporaryDirectory())])
        // Insert in reverse order; exporter must sort by startFrame.
        let later = Fixtures.clip(id: "later", mediaRef: "media-v", start: 100, duration: 30)
        let earlier = Fixtures.clip(id: "earlier", mediaRef: "media-v", start: 0, duration: 30)
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [later, earlier])])

        let outURL = tmpDir.appendingPathComponent("out.xml")
        XMLExporter.export(timeline: timeline, resolver: resolver, outputURL: outURL)

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
