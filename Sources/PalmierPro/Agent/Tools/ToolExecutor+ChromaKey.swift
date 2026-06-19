import Foundation

extension ToolExecutor {

    /// Apply or remove an Ultra Key chroma key on a visual clip.
    func setChromaKey(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let clipId = try args.requireString("clipId")
        guard let loc = editor.findClip(id: clipId) else {
            throw ToolError("Clip not found: \(clipId)")
        }
        let clip = editor.timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
        guard clip.mediaType.isVisual else {
            throw ToolError("Chroma key only applies to visual clips (clip \(clipId) is \(clip.mediaType.rawValue)).")
        }

        if args.bool("enabled") == false {
            editor.setChromaKey(clipId: clipId, nil)
            return .ok("Chroma key removed from clip \(clipId).")
        }

        var key = clip.chromaKey ?? ChromaKey()
        key.enabled = true
        if let hex = args.string("keyColorHex"), let rgba = try parseColorHex(hex, path: "set_chroma_key") {
            key.keyColor = rgba
        }
        if let t = args.double("tolerance") { key.tolerance = clampPercent(t) }
        if let s = args.double("softness") { key.softness = clampPercent(s) }
        if let sp = args.double("spill") { key.spill = clampPercent(sp) }
        if let ef = args.double("edgeFeather") { key.edgeFeather = max(0, ef) }
        editor.setChromaKey(clipId: clipId, key)

        let hex = String(format: "#%02X%02X%02X",
                         Int((key.keyColor.r * 255).rounded()),
                         Int((key.keyColor.g * 255).rounded()),
                         Int((key.keyColor.b * 255).rounded()))
        return .ok("""
            Chroma key enabled on clip \(clipId): key \(hex), tolerance \(Int(key.tolerance)), \
            softness \(Int(key.softness)), spill \(Int(key.spill)), feather \(Int(key.edgeFeather)).
            """)
    }

    private func clampPercent(_ v: Double) -> Double { min(100, max(0, v)) }
}
