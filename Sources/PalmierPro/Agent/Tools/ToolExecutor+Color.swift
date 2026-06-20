import Foundation

extension ToolExecutor {
    func listColorGrades() -> ToolResult {
        .ok(Self.jsonString(["looks": ColorGradeCatalog.catalogJSON]) ?? "{}")
    }

    func applyColorGrade(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let look = (args["look"] as? String)?.trimmingCharacters(in: .whitespaces)
        let lutPath = (args["lutPath"] as? String)?.trimmingCharacters(in: .whitespaces)
        let intensityRaw = (args["intensity"] as? NSNumber)?.doubleValue ?? 1.0
        let intensity = min(1.0, max(0.0, intensityRaw))

        let ref: LUTRef
        switch (look?.isEmpty == false ? look : nil, lutPath?.isEmpty == false ? lutPath : nil) {
        case let (lookID?, nil):
            guard ColorGradeCatalog.look(id: lookID) != nil else {
                let ids = ColorGradeCatalog.all.map(\.id).joined(separator: ", ")
                throw ToolError("Unknown look '\(lookID)'. Available: \(ids). Call list_color_grades.")
            }
            ref = .look(lookID, intensity: intensity)
        case let (nil, path?):
            let url = URL(fileURLWithPath: path)
            guard url.pathExtension.lowercased() == "cube" else {
                throw ToolError("lutPath must point at a .cube file (got '\(url.lastPathComponent)').")
            }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                throw ToolError("Could not read .cube file at \(path)")
            }
            let cube: CubeLUT
            do { cube = try CubeLUTParser.parse(text) }
            catch { throw ToolError("Invalid .cube: \(error.localizedDescription)") }
            ref = .cube(cube, name: url.deletingPathExtension().lastPathComponent, intensity: intensity)
        default:
            throw ToolError("Provide exactly one of 'look' or 'lutPath'.")
        }

        editor.setColorGrade(ref)
        var out = ref.summary
        out["appliesAt"] = "export"
        return .ok(Self.jsonString(out) ?? "{}")
    }

    func clearColorGrade(_ editor: EditorViewModel) throws -> ToolResult {
        editor.setColorGrade(nil)
        return .ok(Self.jsonString(["cleared": true]) ?? "{}")
    }

    func adjustColor(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        var p = editor.timeline.primaries ?? PrimaryGrade()
        let reset = (args["reset"] as? Bool) == true || (args["reset"] as? NSNumber)?.boolValue == true
        if reset {
            let curve = p.curve
            p = PrimaryGrade()
            p.curve = curve
        } else {
            func clamp(_ v: Double) -> Double { min(100, max(-100, v)) }
            func num(_ key: String) -> Double? { (args[key] as? NSNumber)?.doubleValue }
            if let v = num("temperature") { p.temperature = clamp(v) }
            if let v = num("tint") { p.tint = clamp(v) }
            if let v = num("exposure") { p.exposure = clamp(v) }
            if let v = num("contrast") { p.contrast = clamp(v) }
            if let v = num("saturation") { p.saturation = clamp(v) }
            if let v = num("vibrance") { p.vibrance = clamp(v) }
            if let v = num("highlights") { p.highlights = clamp(v) }
            if let v = num("shadows") { p.shadows = clamp(v) }
        }
        editor.setColorPrimaries(p)
        let out: [String: Any] = [
            "temperature": p.temperature, "tint": p.tint, "exposure": p.exposure,
            "contrast": p.contrast, "saturation": p.saturation, "vibrance": p.vibrance,
            "highlights": p.highlights, "shadows": p.shadows,
        ]
        return .ok(Self.jsonString(out) ?? "{}")
    }

    func setColorCurve(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        guard let channel = args["channel"] as? String else { throw ToolError("Missing 'channel'") }
        guard ["master", "red", "green", "blue"].contains(channel) else {
            throw ToolError("channel must be master, red, green, or blue")
        }
        guard let rawPoints = args["points"] as? [Any] else { throw ToolError("Missing 'points' array") }

        var points: [CurvePoint] = []
        for entry in rawPoints {
            guard let pair = entry as? [Any], pair.count == 2,
                  let x = (pair[0] as? NSNumber)?.doubleValue,
                  let y = (pair[1] as? NSNumber)?.doubleValue else {
                throw ToolError("Each point must be an [x, y] pair of numbers in 0…1")
            }
            points.append(CurvePoint(x: min(1, max(0, x)), y: min(1, max(0, y))))
        }
        points.sort { $0.x < $1.x }

        var p = editor.timeline.primaries ?? PrimaryGrade()
        var curve = p.curve ?? GradeCurve()
        let value = (points == GradeCurve.identityPoints) ? [] : points
        switch channel {
        case "master": curve.master = value
        case "red": curve.red = value
        case "green": curve.green = value
        default: curve.blue = value
        }
        p.curve = curve.isIdentity ? nil : curve
        editor.setColorPrimaries(p)
        return .ok(Self.jsonString(["channel": channel, "points": points.map { [$0.x, $0.y] }]) ?? "{}")
    }
}
