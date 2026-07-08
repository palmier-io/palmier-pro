import Foundation

extension ToolExecutor {
    private static let detectBeatsAllowedKeys: Set<String> = ["mediaRef", "startSeconds", "endSeconds"]

    func detectBeats(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.detectBeatsAllowedKeys, path: "detect_beats")
        let mediaRef = try args.requireString("mediaRef")
        let asset = try asset(mediaRef, editor: editor)
        guard asset.type == .audio || (asset.type == .video && asset.hasAudio) else {
            throw ToolError("detect_beats needs audio: \(mediaRef) is \(asset.type.rawValue)\(asset.type == .video ? " with no audio track" : "").")
        }
        guard FileManager.default.fileExists(atPath: asset.url.path) else {
            throw ToolError("Media file not on disk: \(asset.url.lastPathComponent)")
        }

        // Use shared cache to prevent duplicate beat detection.
        let analysis = try await editor.mediaVisualCache.beats.detect(for: asset).value

        guard !analysis.beats.isEmpty || !analysis.downbeats.isEmpty else {
            return .ok(#"{"beats":[],"note":"No beats found — the audio may lack rhythmic content."}"#)
        }
        let range = try Self.beatsRange(args, duration: asset.duration)
        let beats = Self.window(analysis.beats, range)
        let downbeats = Self.window(analysis.downbeats, range)
        if range != nil, beats.isEmpty, downbeats.isEmpty {
            return .ok(#"{"beats":[],"note":"No beats in the requested window; the track has beats elsewhere — widen or drop startSeconds/endSeconds."}"#)
        }

        var out: [String: Any] = [
            "mediaRef": mediaRef,
            "units": "source seconds — multiply by fps for frame values",
            "beats": beats.map(Self.r2),
        ]
        if !downbeats.isEmpty { out["downbeats"] = downbeats.map(Self.r2) }
        let bpm = range == nil ? analysis.bpm : (BeatDetector.estimateBPM(beats) ?? 0)
        if bpm > 0 { out["bpm"] = NSDecimalNumber(string: String(format: "%.1f", bpm)) }
        guard let json = Self.jsonString(out) else { throw ToolError("Failed to encode result.") }
        return .ok(json)
    }

    private static func r2(_ t: Double) -> NSDecimalNumber { NSDecimalNumber(string: String(format: "%.2f", t)) }

    private static func window(_ times: [Double], _ range: ClosedRange<Double>?) -> [Double] {
        guard let range else { return times }
        return times.filter { range.contains($0) }
    }

    private static func beatsRange(_ args: [String: Any], duration: Double) throws -> ClosedRange<Double>? {
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
