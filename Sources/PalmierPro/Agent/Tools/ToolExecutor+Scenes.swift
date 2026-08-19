import Foundation

extension ToolExecutor {
    private static let detectScenesAllowedKeys: Set<String> = ["mediaRef", "startSeconds", "endSeconds"]

    func detectScenes(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.detectScenesAllowedKeys, path: "detect_scenes")
        let mediaRef = try args.requireString("mediaRef")
        let asset = try asset(mediaRef, editor: editor)
        guard asset.type == .video else {
            throw ToolError("detect_scenes needs video: \(mediaRef) is \(asset.type.rawValue).")
        }
        guard FileManager.default.fileExists(atPath: asset.url.path) else {
            throw ToolError("Media file not on disk: \(asset.url.lastPathComponent)")
        }

        let analysis = try await editor.mediaVisualCache.scenes.detect(for: asset).value

        guard !analysis.cuts.isEmpty else {
            return .ok(#"{"cuts":[],"scenes":[],"note":"No scene changes found — the video may be a single continuous shot."}"#)
        }
        let range = try Self.scenesRange(args, duration: analysis.duration)
        let cuts = Self.window(analysis.cuts, range)
        if range != nil, cuts.isEmpty {
            return .ok(#"{"cuts":[],"scenes":[],"note":"No cuts in the requested window; the video has cuts elsewhere — widen or drop startSeconds/endSeconds."}"#)
        }

        let sceneStart = range?.lowerBound ?? 0
        let sceneEnd = range?.upperBound ?? analysis.duration
        let scenes = analysis.scenes.filter { $0.end > sceneStart && $0.start < sceneEnd }.map { scene in
            [
                "start": Self.r2(max(scene.start, sceneStart)),
                "end": Self.r2(min(scene.end, sceneEnd)),
            ]
        }

        var out: [String: Any] = [
            "mediaRef": mediaRef,
            "units": "source seconds — multiply by fps for frame values",
            "cuts": cuts.map(Self.r2),
            "scenes": scenes,
        ]
        if analysis.duration > 0 { out["duration"] = Self.r2(analysis.duration) }
        guard let json = Self.jsonString(out) else { throw ToolError("Failed to encode result.") }
        return .ok(json)
    }

    private static func r2(_ t: Double) -> NSDecimalNumber { NSDecimalNumber(string: String(format: "%.2f", t)) }

    private static func window(_ times: [Double], _ range: ClosedRange<Double>?) -> [Double] {
        guard let range else { return times }
        return times.filter { range.contains($0) }
    }

    private static func scenesRange(_ args: [String: Any], duration: Double) throws -> ClosedRange<Double>? {
        let start = args.double("startSeconds")
        let end = args.double("endSeconds")
        guard start != nil || end != nil else { return nil }
        let s = max(start ?? 0, 0)
        let e = min(end ?? duration, duration)
        guard s < e else {
            throw ToolError("Invalid time range [\(s), \(e)] for media of duration \(duration)s")
        }
        return s...e
    }
}
