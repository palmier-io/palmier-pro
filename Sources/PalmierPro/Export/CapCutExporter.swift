import AVFoundation
import AppKit
import Foundation

/// Exports a Timeline as a CapCut desktop draft folder (`draft_content.json` +
/// `draft_meta_info.json`). The CapCut draft format is proprietary and
/// version-specific (reverse-engineered, see pyJianYingDraft/pyCapCut), so this is
/// a best-effort mapping: video/image/audio clips, text overlays, canvas, fps,
/// timeranges, and per-clip transform/opacity. Colour grade / LUT / blend / chroma
/// are NOT mapped (CapCut uses its own effect IDs). Media is referenced by
/// absolute path. Drop the folder in CapCut's drafts directory to open it.
enum CapCutExporter {

    struct Report: Sendable {
        var videos = 0, images = 0, audios = 0, texts = 0, missing = 0
    }

    /// CapCut's macOS drafts directory, if it exists.
    static var capCutDraftsDirectory: URL? {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CapCut/User Data/Projects/com.lveditor.draft", isDirectory: true)
        return FileManager.default.fileExists(atPath: dir.path) ? dir : nil
    }

    static func export(
        timeline: Timeline,
        resolveURL: @Sendable (String) -> URL?,
        projectName: String,
        outputURL: URL
    ) async throws -> Report {
        let fm = FileManager.default
        try fm.createDirectory(at: outputURL, withIntermediateDirectories: true)

        let fps = max(1, timeline.fps)
        func us(_ frames: Int) -> Int { Int((Double(frames) / Double(fps) * 1_000_000).rounded()) }

        var report = Report()
        var videoMaterials: [[String: Any]] = []
        var audioMaterials: [[String: Any]] = []
        var textMaterials: [[String: Any]] = []
        var tracks: [[String: Any]] = []

        // CapCut track array order is bottom→top; Palmier track 0 is topmost — reverse to match.
        for track in timeline.tracks.reversed() {
            let sorted = track.clips.sorted { $0.startFrame < $1.startFrame }.filter { $0.durationFrames > 0 }
            guard !sorted.isEmpty else { continue }

            switch track.type {
            case .video, .image:
                var segments: [[String: Any]] = []
                for clip in sorted {
                    guard let url = resolveURL(clip.mediaRef) else { report.missing += 1; continue }
                    let isImage = clip.mediaType == .image
                    let size = await Self.pixelSize(url, isImage: isImage)
                        ?? CGSize(width: timeline.width, height: timeline.height)
                    let matId = UUID().uuidString
                    let sourceDur = isImage
                        ? 10_800_000_000 // photos get a long material duration; the segment clips it
                        : (await Self.durationUs(url) ?? us(clip.sourceDurationFrames))
                    videoMaterials.append([
                        "id": matId,
                        "type": isImage ? "photo" : "video",
                        "path": url.path,
                        "material_name": url.lastPathComponent,
                        "width": Int(size.width),
                        "height": Int(size.height),
                        "duration": sourceDur,
                    ])
                    isImage ? (report.images += 1) : (report.videos += 1)
                    segments.append(Self.visualSegment(clip: clip, materialId: matId, us: us))
                }
                if !segments.isEmpty { tracks.append(Self.track(type: "video", segments: segments)) }

            case .audio:
                var segments: [[String: Any]] = []
                for clip in sorted {
                    guard let url = resolveURL(clip.mediaRef) else { report.missing += 1; continue }
                    let matId = UUID().uuidString
                    audioMaterials.append([
                        "id": matId,
                        "type": "extract_music",
                        "path": url.path,
                        "name": url.lastPathComponent,
                        "duration": await Self.durationUs(url) ?? us(clip.sourceDurationFrames),
                    ])
                    report.audios += 1
                    segments.append(Self.audioSegment(clip: clip, materialId: matId, us: us))
                }
                if !segments.isEmpty { tracks.append(Self.track(type: "audio", segments: segments)) }

            case .text:
                var segments: [[String: Any]] = []
                for clip in sorted {
                    let matId = UUID().uuidString
                    textMaterials.append(Self.textMaterial(clip: clip, id: matId))
                    report.texts += 1
                    segments.append(Self.visualSegment(clip: clip, materialId: matId, us: us))
                }
                if !segments.isEmpty { tracks.append(Self.track(type: "text", segments: segments)) }

            case .adjustment, .lottie:
                continue // CapCut adjustment layers / Lottie not mapped
            }
        }

        let draftContent: [String: Any] = [
            "id": UUID().uuidString.uppercased(),
            "name": projectName,
            "duration": us(timeline.totalFrames),
            "fps": Double(fps),
            "canvas_config": ["width": timeline.width, "height": timeline.height, "ratio": "original"],
            "platform": ["app_source": "cc", "app_version": "5.9.0", "os": "mac"],
            "new_version": "110.0.0",
            "version": 360_000,
            "materials": Self.materialsObject(videos: videoMaterials, audios: audioMaterials, texts: textMaterials),
            "tracks": tracks,
        ]

        try Self.writeJSON(draftContent, to: outputURL.appendingPathComponent("draft_content.json"))
        try Self.writeJSON(Self.metaInfo(name: projectName, durationUs: us(timeline.totalFrames)),
                           to: outputURL.appendingPathComponent("draft_meta_info.json"))
        return report
    }

    // MARK: - Segments

    private static func visualSegment(clip: Clip, materialId: String, us: (Int) -> Int) -> [String: Any] {
        let t = clip.transform
        return [
            "id": UUID().uuidString,
            "material_id": materialId,
            "target_timerange": ["start": us(clip.startFrame), "duration": us(clip.durationFrames)],
            "source_timerange": ["start": us(clip.trimStartFrame), "duration": us(clip.sourceFramesConsumed)],
            "speed": clip.speed,
            "volume": clip.volume,
            "visible": true,
            "render_index": 0,
            "clip": [
                "alpha": clip.opacity,
                "rotation": t.rotation,
                "flip": ["horizontal": t.flipHorizontal, "vertical": t.flipVertical],
                "scale": ["x": t.width, "y": t.height],
                // CapCut transform: 0,0 = centre; ±1 = canvas edge. Palmier centre is 0…1, y down.
                "transform": ["x": (t.centerX - 0.5) * 2, "y": (0.5 - t.centerY) * 2],
            ],
        ]
    }

    private static func audioSegment(clip: Clip, materialId: String, us: (Int) -> Int) -> [String: Any] {
        [
            "id": UUID().uuidString,
            "material_id": materialId,
            "target_timerange": ["start": us(clip.startFrame), "duration": us(clip.durationFrames)],
            "source_timerange": ["start": us(clip.trimStartFrame), "duration": us(clip.sourceFramesConsumed)],
            "speed": clip.speed,
            "volume": clip.volume,
            "visible": true,
            "render_index": 0,
        ]
    }

    private static func track(type: String, segments: [[String: Any]]) -> [String: Any] {
        ["id": UUID().uuidString, "type": type, "attribute": 0, "flag": 0, "segments": segments]
    }

    // MARK: - Text

    private static func textMaterial(clip: Clip, id: String) -> [String: Any] {
        let style = clip.textStyle ?? TextStyle()
        let text = clip.textContent ?? ""
        let color = style.color
        let inner: [String: Any] = [
            "text": text,
            "styles": [[
                "range": [0, text.utf16.count],
                "size": style.fontSize,
                "bold": false,
                "italic": false,
                "fill": ["content": ["solid": ["color": [color.r, color.g, color.b]]]],
            ]],
        ]
        let content = (try? JSONSerialization.data(withJSONObject: inner))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{\"text\":\"\"}"
        return [
            "id": id,
            "type": "text",
            "content": content,
            "font_size": style.fontSize,
            "text_color": Self.hex(color),
            "alignment": 1,
        ]
    }

    // MARK: - Materials object (all sub-arrays present; CapCut expects the keys)

    private static func materialsObject(videos: [[String: Any]], audios: [[String: Any]], texts: [[String: Any]]) -> [String: Any] {
        [
            "videos": videos, "audios": audios, "texts": texts,
            "stickers": [], "shapes": [], "effects": [], "video_effects": [],
            "transitions": [], "material_animations": [], "masks": [], "common_masks": [],
            "canvases": [], "speeds": [], "audio_fades": [], "audio_effects": [],
            "placeholder_infos": [], "sound_channel_mappings": [], "vocal_separations": [],
        ]
    }

    private static func metaInfo(name: String, durationUs: Int) -> [String: Any] {
        [
            "draft_name": name,
            "draft_fold_path": "",
            "tm_duration": durationUs,
            "draft_id": UUID().uuidString.uppercased(),
            "draft_root_path": "",
        ]
    }

    // MARK: - Helpers

    private static func writeJSON(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
    }

    private static func hex(_ c: TextStyle.RGBA) -> String {
        String(format: "#%02X%02X%02X%02X",
               Int((c.r * 255).rounded()), Int((c.g * 255).rounded()),
               Int((c.b * 255).rounded()), Int((c.a * 255).rounded()))
    }

    private static func durationUs(_ url: URL) async -> Int? {
        guard let seconds = try? await AVURLAsset(url: url).load(.duration).seconds, seconds.isFinite else { return nil }
        return Int((seconds * 1_000_000).rounded())
    }

    private static func pixelSize(_ url: URL, isImage: Bool) async -> CGSize? {
        if isImage {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                  let w = props[kCGImagePropertyPixelWidth] as? Int,
                  let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
            return CGSize(width: w, height: h)
        }
        guard let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first,
              let size = try? await track.load(.naturalSize) else { return nil }
        return CGSize(width: abs(size.width), height: abs(size.height))
    }
}
