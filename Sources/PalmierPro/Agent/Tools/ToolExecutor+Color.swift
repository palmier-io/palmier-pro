import Foundation

extension ToolExecutor {

    /// Set a visual clip's blend mode (how it composites over the layers below).
    func setBlendMode(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let clipId = try args.requireString("clipId")
        let clip = try visualClip(editor, clipId, feature: "Blend mode")
        _ = clip
        let raw = try args.requireString("mode")
        guard let mode = BlendMode(rawValue: raw) else {
            throw ToolError("Unknown blend mode '\(raw)'. Options: \(BlendMode.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        editor.setBlendMode(clipId: clipId, mode)
        return .ok("Blend mode of clip \(clipId) set to \(mode.displayName).")
    }

    /// Set the colour grade on a visual clip (per-clip) or an adjustment layer.
    func setColorGrade(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let clipId = try args.requireString("clipId")
        guard let loc = editor.findClip(id: clipId) else { throw ToolError("Clip not found: \(clipId)") }
        let clip = editor.timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
        guard clip.mediaType.isVisual || clip.mediaType == .adjustment else {
            throw ToolError("Color grade applies to visual clips or adjustment layers (clip \(clipId) is \(clip.mediaType.rawValue)).")
        }

        if args.bool("reset") == true {
            editor.setColorGrade(clipId: clipId, nil)
            return .ok("Color grade cleared on clip \(clipId).")
        }

        var g = clip.colorGrade ?? ColorGrade()
        if let v = args.double("temperature") { g.temperature = clampGrade(v) }
        if let v = args.double("tint") { g.tint = clampGrade(v) }
        if let v = args.double("exposure") { g.exposure = clampGrade(v) }
        if let v = args.double("contrast") { g.contrast = clampGrade(v) }
        if let v = args.double("saturation") { g.saturation = clampGrade(v) }
        if let b = args.bool("basicEnabled") { g.basicEnabled = b }
        if let b = args.bool("creativeEnabled") { g.creativeEnabled = b }

        if args.bool("removeLut") == true {
            g.lutRef = nil
        } else if let path = args.string("lutPath") {
            guard FileManager.default.fileExists(atPath: path) else {
                throw ToolError("LUT file not found: \(path)")
            }
            do {
                _ = try CubeLUT.parse(contentsOf: URL(fileURLWithPath: path))
            } catch {
                throw ToolError("Invalid .cube LUT: \(error.localizedDescription)")
            }
            g.lutRef = path
            g.creativeEnabled = true
        }
        if let i = args.double("lutIntensity") { g.lutIntensity = min(1, max(0, i)) }

        editor.setColorGrade(clipId: clipId, g)
        let lut = g.lutRef.map { ($0 as NSString).lastPathComponent } ?? "none"
        return .ok("""
            Color grade on clip \(clipId): temp \(Int(g.temperature)), tint \(Int(g.tint)), \
            exposure \(Int(g.exposure)), contrast \(Int(g.contrast)), saturation \(Int(g.saturation)), \
            LUT \(lut) @ \(Int(g.lutIntensity * 100))%.
            """)
    }

    private func visualClip(_ editor: EditorViewModel, _ clipId: String, feature: String) throws -> Clip {
        guard let loc = editor.findClip(id: clipId) else { throw ToolError("Clip not found: \(clipId)") }
        let clip = editor.timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
        guard clip.mediaType.isVisual else {
            throw ToolError("\(feature) only applies to visual clips (clip \(clipId) is \(clip.mediaType.rawValue)).")
        }
        return clip
    }

    private func clampGrade(_ v: Double) -> Double { min(100, max(-100, v)) }
}
