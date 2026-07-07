import Foundation

extension ToolExecutor {
    private static let detectBeatsAllowedKeys: Set<String> = ["mediaRef", "startSeconds", "endSeconds"]

    func detectBeats(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.detectBeatsAllowedKeys, path: "detect_beats")
        let mediaRef = try args.requireString("mediaRef")
        let asset = try asset(mediaRef, editor: editor)
        guard asset.type == .video || asset.type == .audio else {
            throw ToolError("detect_beats needs audio: \(mediaRef) is \(asset.type.rawValue).")
        }
        guard FileManager.default.fileExists(atPath: asset.url.path) else {
            throw ToolError("Media file not on disk: \(asset.url.lastPathComponent)")
        }

        // Shared store: same cache and in-flight dedup as the context menu,
        // and beat ticks appear on the clip when analysis lands.
        let analysis = try await editor.mediaVisualCache.beats.detect(for: asset).value

        let range = try Self.beatsRange(args, duration: asset.duration)
        let beats = Self.window(analysis.beats, range)
        let downbeats = Self.window(analysis.downbeats, range)
        guard !beats.isEmpty else {
            return .ok(#"{"beats":[],"note":"No beats found — the audio may lack rhythmic content."}"#)
        }

        var out: [String: Any] = [
            "mediaRef": mediaRef,
            "units": "source seconds — multiply by fps for frame values",
            "beats": beats.map(Self.r2),
        ]
        if !downbeats.isEmpty { out["downbeats"] = downbeats.map(Self.r2) }
        if analysis.bpm > 0 { out["bpm"] = NSDecimalNumber(string: String(format: "%.1f", analysis.bpm)) }
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
