import Foundation

/// Parser and serializer for video design specifications (`frame.md` / `design.md`).
/// Parses YAML frontmatter and Markdown sections into a structured `DesignSpec`.
enum DesignSpecParser {

    private enum Section {
        case root
        case colors
        case typography
        case canvas
        case pacing
        case grade
        case caption
    }

    /// Parses a `frame.md` or `design.md` document into a `DesignSpec`.
    static func parse(markdown: String) throws -> DesignSpec {
        var spec = DesignSpec()
        spec.rawMarkdown = markdown

        let lines = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        var inFrontmatter = false
        var frontmatterChecked = false
        var activeSection: Section = .root

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line == "---" {
                if !frontmatterChecked && !inFrontmatter {
                    inFrontmatter = true
                    frontmatterChecked = true
                    continue
                } else if inFrontmatter {
                    inFrontmatter = false
                    activeSection = .root
                    continue
                }
            }

            if !inFrontmatter && line.hasPrefix("#") {
                let heading = line.lowercased()
                if heading.contains("palette") || heading.contains("color") {
                    activeSection = .colors
                } else if heading.contains("typograph") || heading.contains("font") {
                    activeSection = .typography
                } else if heading.contains("canvas") || heading.contains("aspect") || heading.contains("resolution") {
                    activeSection = .canvas
                } else if heading.contains("pacing") {
                    activeSection = .pacing
                } else if heading.contains("grade") || heading.contains("look") || heading.contains("style") {
                    activeSection = .grade
                } else if heading.contains("caption") {
                    activeSection = .caption
                } else {
                    activeSection = .root
                }
                continue
            }

            // Detect section headers in YAML frontmatter
            if inFrontmatter && !rawLine.hasPrefix(" ") && !rawLine.hasPrefix("\t") && line.hasSuffix(":") {
                let secKey = String(line.dropLast()).trimmingCharacters(in: .whitespaces).lowercased()
                switch secKey {
                case "colors", "palette": activeSection = .colors
                case "typography", "fonts": activeSection = .typography
                case "canvas", "geometry", "dimensions": activeSection = .canvas
                case "pacing": activeSection = .pacing
                case "grade", "colorgrade", "color": activeSection = .grade
                case "caption", "captions": activeSection = .caption
                default: activeSection = .root
                }
                continue
            }

            // Parse key-value tokens
            guard let (rawKey, rawValue) = extractKeyValuePair(line) else { continue }
            let key = normalizeKey(rawKey)
            let val = cleanValue(rawValue)
            guard !val.isEmpty else { continue }

            applyToken(key: key, value: val, section: activeSection, spec: &spec)
        }

        return spec
    }

    /// Serializes a `DesignSpec` into standard `frame.md` format.
    static func exportMarkdown(spec: DesignSpec) -> String {
        var lines: [String] = ["---"]

        // Colors
        lines.append("colors:")
        if let bg = spec.palette.background { lines.append("  background: \"\(bg.hexString)\"") }
        if let surf = spec.palette.surface { lines.append("  surface: \"\(surf.hexString)\"") }
        if let txt = spec.palette.text { lines.append("  text: \"\(txt.hexString)\"") }
        if let prim = spec.palette.primary { lines.append("  primary: \"\(prim.hexString)\"") }
        if let acc = spec.palette.accent { lines.append("  accent: \"\(acc.hexString)\"") }
        if let brd = spec.palette.border { lines.append("  border: \"\(brd.hexString)\"") }
        for (k, v) in spec.palette.custom.sorted(by: { $0.key < $1.key }) {
            lines.append("  \(k): \"\(v.hexString)\"")
        }

        // Typography
        lines.append("typography:")
        if let disp = spec.typography.displayFont { lines.append("  display: \"\(disp)\"") }
        if let body = spec.typography.bodyFont { lines.append("  body: \"\(body)\"") }
        if let sz = spec.typography.baseSize { lines.append("  baseSize: \(sz)") }
        if let dw = spec.typography.displayWeight { lines.append("  displayWeight: \"\(dw)\"") }
        if let bw = spec.typography.bodyWeight { lines.append("  bodyWeight: \"\(bw)\"") }

        // Canvas
        lines.append("canvas:")
        if let ar = spec.canvas.aspectRatio { lines.append("  aspectRatio: \"\(ar)\"") }
        if let w = spec.canvas.width { lines.append("  width: \(w)") }
        if let h = spec.canvas.height { lines.append("  height: \(h)") }

        // Pacing
        lines.append("pacing:")
        if let tgt = spec.pacing.targetShotDurationSeconds { lines.append("  targetShotDuration: \(tgt)s") }
        if let mn = spec.pacing.minShotDurationSeconds { lines.append("  minShotDuration: \(mn)s") }
        if let mx = spec.pacing.maxShotDurationSeconds { lines.append("  maxShotDuration: \(mx)s") }

        // Grade
        lines.append("grade:")
        if let p = spec.grade.preset { lines.append("  preset: \"\(p)\"") }
        if let exp = spec.grade.exposure { lines.append("  exposure: \(exp)") }
        if let c = spec.grade.contrast { lines.append("  contrast: \(c)") }
        if let s = spec.grade.saturation { lines.append("  saturation: \(s)") }
        if let t = spec.grade.temperature { lines.append("  temperature: \(t)") }

        // Caption
        lines.append("caption:")
        if let t = spec.caption.templateId { lines.append("  template: \"\(t)\"") }
        if let f = spec.caption.format { lines.append("  format: \"\(f)\"") }
        if let h = spec.caption.highlightColor { lines.append("  highlight: \"\(h.hexString)\"") }

        lines.append("---")
        lines.append("")
        lines.append("# Design Specification")
        lines.append("")

        lines.append("## Palette")
        if let bg = spec.palette.background { lines.append("- **Background**: `\(bg.hexString)`") }
        if let surf = spec.palette.surface { lines.append("- **Surface**: `\(surf.hexString)`") }
        if let txt = spec.palette.text { lines.append("- **Text**: `\(txt.hexString)`") }
        if let prim = spec.palette.primary { lines.append("- **Primary**: `\(prim.hexString)`") }
        if let acc = spec.palette.accent { lines.append("- **Accent**: `\(acc.hexString)`") }
        if let brd = spec.palette.border { lines.append("- **Border**: `\(brd.hexString)`") }
        lines.append("")

        lines.append("## Typography")
        if let disp = spec.typography.displayFont { lines.append("- **Display Font**: \(disp)") }
        if let body = spec.typography.bodyFont { lines.append("- **Body Font**: \(body)") }
        if let sz = spec.typography.baseSize { lines.append("- **Base Size**: \(sz)") }
        lines.append("")

        lines.append("## Canvas")
        if let ar = spec.canvas.aspectRatio { lines.append("- **Aspect Ratio**: \(ar)") }
        if let (w, h) = spec.canvas.resolvedDimensions() { lines.append("- **Resolution**: \(w)x\(h)") }
        lines.append("")

        lines.append("## Pacing")
        if let tgt = spec.pacing.targetShotDurationSeconds { lines.append("- **Target Shot Duration**: \(tgt)s") }
        if let mn = spec.pacing.minShotDurationSeconds { lines.append("- **Min Shot Duration**: \(mn)s") }
        if let mx = spec.pacing.maxShotDurationSeconds { lines.append("- **Max Shot Duration**: \(mx)s") }
        lines.append("")

        if let p = spec.grade.preset {
            lines.append("## Grade")
            lines.append("- **Preset**: \(p)")
            lines.append("")
        }

        if let t = spec.caption.templateId {
            lines.append("## Caption")
            lines.append("- **Template**: \(t)")
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Private Token Extraction & Application

    private static func extractKeyValuePair(_ rawLine: String) -> (String, String)? {
        var line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("-") || line.hasPrefix("*") {
            line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        guard let colonIdx = line.firstIndex(of: ":") else { return nil }
        let keyPart = String(line[..<colonIdx]).trimmingCharacters(in: .whitespaces)
        let valPart = String(line[line.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
        return (keyPart, valPart)
    }

    private static func normalizeKey(_ raw: String) -> String {
        var k = raw.replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        if k.hasPrefix("--") { k = String(k.dropFirst(2)) }
        return k.replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
    }

    private static func cleanValue(_ raw: String) -> String {
        var v = raw.trimmingCharacters(in: .whitespaces)
        if v.hasSuffix(";") { v = String(v.dropLast()).trimmingCharacters(in: .whitespaces) }
        if (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) || (v.hasPrefix("`") && v.hasSuffix("`")) {
            v = String(v.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return v
    }

    private static func parseColor(_ val: String) -> TextStyle.RGBA? {
        var clean = val
        if clean.contains(" ") { clean = clean.components(separatedBy: " ").first ?? clean }
        return TextStyle.RGBA(hex: clean)
    }

    private static func parseDurationSeconds(_ val: String) -> Double? {
        var cleaned = val.lowercased()
        if cleaned.hasSuffix("s") { cleaned = String(cleaned.dropLast()) }
        if cleaned.hasSuffix("sec") { cleaned = String(cleaned.dropLast(3)) }
        return Double(cleaned.trimmingCharacters(in: .whitespaces))
    }

    private static func applyToken(key: String, value: String, section: Section, spec: inout DesignSpec) {
        // Color tokens
        if key == "bg" || key == "background" {
            spec.palette.background = parseColor(value)
            return
        }
        if key == "surface" {
            spec.palette.surface = parseColor(value)
            return
        }
        if key == "text" || key == "primarytext" || key == "foreground" {
            spec.palette.text = parseColor(value)
            return
        }
        if key == "primary" {
            spec.palette.primary = parseColor(value)
            return
        }
        if key == "accent" || key == "secondary" {
            spec.palette.accent = parseColor(value)
            return
        }
        if key == "border" || key == "outline" {
            spec.palette.border = parseColor(value)
            return
        }

        // Section-specific color routing
        if section == .colors {
            if let color = parseColor(value) {
                spec.palette.custom[key] = color
                return
            }
        }

        // Typography tokens
        if key == "fontdisplay" || key == "display" || key == "displayfont" {
            spec.typography.displayFont = value
            return
        }
        if key == "fontbody" || key == "body" || key == "bodyfont" {
            spec.typography.bodyFont = value
            return
        }
        if key == "fontsize" || key == "basesize" {
            var sz = value
            if sz.hasSuffix("px") || sz.hasSuffix("pt") { sz = String(sz.dropLast(2)) }
            spec.typography.baseSize = Double(sz.trimmingCharacters(in: .whitespaces))
            return
        }
        if key == "displayweight" {
            spec.typography.displayWeight = value
            return
        }
        if key == "bodyweight" {
            spec.typography.bodyWeight = value
            return
        }

        // Canvas tokens
        if key == "aspectratio" || key == "aspect" {
            spec.canvas.aspectRatio = value
            return
        }
        if key == "resolution" {
            if value.contains("x") {
                let parts = value.split(separator: "x").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                if parts.count == 2 {
                    spec.canvas.width = parts[0]
                    spec.canvas.height = parts[1]
                }
            }
            return
        }
        if key == "width" {
            spec.canvas.width = Int(value)
            return
        }
        if key == "height" {
            spec.canvas.height = Int(value)
            return
        }

        // Pacing tokens
        if key == "targetshotduration" || key == "pacingtarget" || key == "targetduration" || key == "duration" {
            spec.pacing.targetShotDurationSeconds = parseDurationSeconds(value)
            return
        }
        if key == "minshotduration" || key == "minduration" || key == "min" {
            spec.pacing.minShotDurationSeconds = parseDurationSeconds(value)
            return
        }
        if key == "maxshotduration" || key == "maxduration" || key == "max" {
            spec.pacing.maxShotDurationSeconds = parseDurationSeconds(value)
            return
        }

        // Grade tokens
        if key == "preset" || key == "gradepreset" || key == "look" {
            spec.grade.preset = value
            return
        }
        if key == "exposure" { spec.grade.exposure = Double(value); return }
        if key == "contrast" { spec.grade.contrast = Double(value); return }
        if key == "saturation" { spec.grade.saturation = Double(value); return }
        if key == "temperature" { spec.grade.temperature = Double(value); return }
        if key == "tint" { spec.grade.tint = Double(value); return }

        // Caption tokens
        if key == "template" || key == "templateid" || key == "captionstyle" {
            spec.caption.templateId = value
            return
        }
        if key == "format" {
            spec.caption.format = value
            return
        }
        if key == "highlight" || key == "highlightcolor" {
            spec.caption.highlightColor = parseColor(value)
            return
        }
    }
}

