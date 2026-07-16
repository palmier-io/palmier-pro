import AVFoundation
import CoreImage
import Foundation

extension ToolExecutor {
    struct HueTargetInput: Decodable {
        let targetHue: Double
        let hueShift: Double?
        let satScale: Double?
        let lumShift: Double?
    }
    struct HueCurvesInput: Decodable { let targets: [HueTargetInput]? }
    struct LutInput: Decodable { let path: String?; let strength: Double? }

    fileprivate struct ApplyColorInput: DecodableToolArgs {
        let clipIds: [String]
        let reset: Bool?
        let exposure: Double?
        let contrast: Double?
        let saturation: Double?
        let vibrance: Double?
        let temperature: Double?
        let tint: Double?
        let highlights: Double?
        let shadows: Double?
        let blacks: Double?
        let whites: Double?
        let shadowsHue: Double?; let shadowsAmount: Double?; let shadowsLum: Double?
        let midsHue: Double?; let midsAmount: Double?; let midsGamma: Double?
        let highsHue: Double?; let highsAmount: Double?; let highsGain: Double?
        let masterCurve: [[Double]]?
        let redCurve: [[Double]]?
        let greenCurve: [[Double]]?
        let blueCurve: [[Double]]?
        let hueCurves: HueCurvesInput?
        let lut: LutInput?
        static let allowedKeys: Set<String> = [
            "clipIds", "reset", "exposure", "contrast", "saturation", "vibrance", "temperature", "tint",
            "highlights", "shadows", "blacks", "whites",
            "shadowsHue", "shadowsAmount", "shadowsLum",
            "midsHue", "midsAmount", "midsGamma",
            "highsHue", "highsAmount", "highsGain",
            "masterCurve", "redCurve", "greenCurve", "blueCurve",
            "hueCurves", "lut",
        ]
        var hasAnyParam: Bool {
            [exposure, contrast, saturation, vibrance, temperature, tint, highlights, shadows, blacks, whites,
             shadowsHue, shadowsAmount, shadowsLum, midsHue, midsAmount, midsGamma, highsHue, highsAmount, highsGain]
                .contains { $0 != nil }
                || [masterCurve, redCurve, greenCurve, blueCurve].contains { $0 != nil }
                || (hueCurves?.targets?.isEmpty == false)
                || lut != nil
        }
    }

    static let colorObjectAllowedKeys: Set<String> = ApplyColorInput.allowedKeys
        .subtracting(["clipIds", "reset", "hueCurves"])
        .union(["hueCurvesRaw"])

    /// The clip's grade in apply_color vocabulary; nil when ungraded. Round-trips via
    /// apply_color's `color` parameter (hue curves come back raw — they compile one-way).
    static func colorObject(from effects: [Effect]?) -> [String: Any]? {
        guard let effects, effects.contains(where: { $0.type.hasPrefix("color.") }) else { return nil }
        let s = GradeState(effects: effects)
        var out: [String: Any] = [:]
        let knobs: [(String, Double?)] = [
            ("exposure", s.exposure), ("contrast", s.contrast), ("saturation", s.saturation),
            ("vibrance", s.vibrance), ("temperature", s.temperature), ("tint", s.tint),
            ("highlights", s.highlights), ("shadows", s.shadows), ("blacks", s.blacks), ("whites", s.whites),
            ("shadowsHue", s.shadowsHue), ("shadowsAmount", s.shadowsAmount), ("shadowsLum", s.shadowsLum),
            ("midsHue", s.midsHue), ("midsAmount", s.midsAmount), ("midsGamma", s.midsGamma),
            ("highsHue", s.highsHue), ("highsAmount", s.highsAmount), ("highsGain", s.highsGain),
        ]
        // Wheels store every zone; neutral values aren't part of the grade's meaning.
        let neutral: [String: Double] = ["shadowsLum": 0, "midsGamma": 1, "highsGain": 1, "shadowsAmount": 0, "midsAmount": 0, "highsAmount": 0]
        for (k, v) in knobs {
            guard let v, v != neutral[k] else { continue }
            out[k] = v
        }
        for zone in ["shadows", "mids", "highs"] where out["\(zone)Amount"] == nil {
            out.removeValue(forKey: "\(zone)Hue")
        }
        func pts(_ p: [CurvePoint]) -> [[Double]]? { p.isEmpty ? nil : p.map { [$0.x, $0.y] } }
        if let c = s.curve {
            if let v = pts(c.master) { out["masterCurve"] = v }
            if let v = pts(c.red) { out["redCurve"] = v }
            if let v = pts(c.green) { out["greenCurve"] = v }
            if let v = pts(c.blue) { out["blueCurve"] = v }
        }
        if let hc = s.hueCurves {
            var raw: [String: Any] = [:]
            if let v = pts(hc.hueVsHue) { raw["hueVsHue"] = v }
            if let v = pts(hc.hueVsSat) { raw["hueVsSat"] = v }
            if let v = pts(hc.hueVsLum) { raw["hueVsLum"] = v }
            if !raw.isEmpty { out["hueCurvesRaw"] = raw }
        }
        if let path = s.lutPath {
            out["lut"] = ["path": path, "strength": s.lutIntensity ?? 1] as [String: Any]
        }
        return out.isEmpty ? nil : out
    }

    func applyColor(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let colorDict = args["color"] as? [String: Any]
        var knobArgs = args
        knobArgs.removeValue(forKey: "color")
        let input: ApplyColorInput = try decodeToolArgs(knobArgs, path: "apply_color")
        guard !input.clipIds.isEmpty else { throw ToolError("clipIds is empty.") }
        if let colorDict {
            guard !input.hasAnyParam, input.reset != true else {
                throw ToolError("'color' pastes a complete grade — don't combine it with individual knobs or reset.")
            }
            try validateUnknownKeys(colorDict, allowed: Self.colorObjectAllowedKeys, path: "apply_color.color")
        } else {
            guard input.hasAnyParam || (input.reset ?? false) else { throw ToolError("No grade parameters provided.") }
        }
        for id in input.clipIds {
            guard let clip = editor.clipFor(id: id) else { throw ToolError("Clip not found: \(id)") }
            guard clip.mediaType == .video || clip.mediaType == .image else {
                throw ToolError("Clip \(id) is a \(clip.mediaType.rawValue) clip; apply_color needs a video or image clip.")
            }
        }
        // LUT file I/O up front so it can throw before mutating.
        func storeLUT(_ path: String) throws -> String {
            do { return try LUTLoader.store(path: path, projectId: editor.projectId) }
            catch let e as LUTStoreError { throw ToolError(e.errorDescription ?? "Invalid LUT.") }
        }
        var lutDestPath: String?
        if let path = input.lut?.path, !path.isEmpty {
            lutDestPath = try storeLUT(path)
        }
        var pastedStack: [Effect]?
        if let colorDict {
            var pasted = GradeState(colorDict: colorDict)
            if let path = pasted.lutPath, !path.isEmpty { pasted.lutPath = try storeLUT(path) }
            pasted.lutIntensity = pasted.lutIntensity.map { min(1, max(0, $0)) }
            pastedStack = pasted.buildStack()
        }
        let reset = input.reset ?? false
        let snapshot = timelineSnapshot(editor)
        let actionName = input.clipIds.count == 1 ? "Color Grade (Agent)" : "Color Grade ×\(input.clipIds.count) (Agent)"
        editor.undo.perform(actionName) {
            editor.mutateClips(ids: Set(input.clipIds), actionName: actionName) { clip in
                let nonColor = (clip.effects ?? []).filter { !$0.type.hasPrefix("color.") }
                if let pastedStack {
                    clip.effects = nonColor + pastedStack
                    return
                }
                let disabledColor = reset ? []
                    : Set((clip.effects ?? []).filter { $0.type.hasPrefix("color.") && !$0.enabled }.map(\.type))
                var state = GradeState(effects: reset ? nil : clip.effects)
                state.apply(input, lutDestPath: lutDestPath)
                var color = state.buildStack()
                for i in color.indices where disabledColor.contains(color[i].type) { color[i].enabled = false }
                clip.effects = nonColor + color
            }
        }
        return mutationResult(editor, since: snapshot, touched: input.clipIds)
    }

    fileprivate struct InspectColorInput: DecodableToolArgs {
        let clipId: String?
        let mediaRef: String?
        let atFrame: Int?
        let reference: String?
        static let allowedKeys: Set<String> = ["clipId", "mediaRef", "atFrame", "reference"]
    }

    /// Measures color scopes of a clip's current graded look (clipId) or a raw media asset
    /// (mediaRef), with the rendered frame. With `reference`, also measures that asset (raw)
    /// and returns the subject−reference gap.
    func inspectColor(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        let input: InspectColorInput = try decodeToolArgs(args, path: "inspect_color")

        let image: CIImage, scopes: Scopes, subjectKey: String
        if let clipId = input.clipId {
            (image, scopes) = try await gradedClip(clipId, atFrame: input.atFrame, editor: editor)
            subjectKey = "clip"
        } else if let mediaRef = input.mediaRef {
            (image, scopes) = try await rawAsset(mediaRef, editor: editor, label: "Media")
            subjectKey = "media"
        } else {
            throw ToolError("Provide either clipId (measures the graded clip) or mediaRef (measures the raw asset).")
        }

        var blocks: [ToolResult.Block] = []
        if let jpeg = Self.encodeJPEG(image) {
            blocks.append(.image(base64: jpeg.base64EncodedString(), mediaType: "image/jpeg"))
        }
        var payload: [String: Any] = [subjectKey: Self.readout(scopes)]

        if let reference = input.reference {
            let (refImage, refScopes) = try await rawAsset(reference, editor: editor, label: "Reference")
            if let jpeg = Self.encodeJPEG(refImage) {
                blocks.append(.image(base64: jpeg.base64EncodedString(), mediaType: "image/jpeg"))
            }
            payload["reference"] = Self.readout(refScopes)
            payload["gap"] = Self.gap(current: scopes, reference: refScopes)
        }

        guard let json = Self.jsonString(payload) else { throw ToolError("Failed to encode scopes.") }
        blocks.append(.text(json))
        return ToolResult(content: blocks, isError: false)
    }

    /// The clip's graded look (existing effects applied) at a representative frame.
    private func gradedClip(_ clipId: String, atFrame: Int?, editor: EditorViewModel) async throws -> (CIImage, Scopes) {
        guard let clip = editor.clipFor(id: clipId) else { throw ToolError("Clip not found: \(clipId)") }
        guard clip.mediaType == .video || clip.mediaType == .image else {
            throw ToolError("Clip \(clipId) is a \(clip.mediaType.rawValue) clip; inspect_color needs a video or image clip.")
        }
        _ = try asset(clip.mediaRef, editor: editor, label: "Clip source")   // validates the asset exists
        guard let srcURL = editor.mediaResolver.resolveURL(for: clip.mediaRef) else {
            throw ToolError("Could not resolve a source URL for clip \(clipId).")
        }
        // trim/duration are timeline-fps frame counts (CompositionBuilder uses timeline.fps as the
        // source timescale), so convert to source seconds with timeline.fps, not the media's own fps.
        let fps = Double(editor.timeline.fps)
        let sourceFrame: Double
        let offset: Int   // clip-relative frame (0…durationFrames-1), drives keyframed/animated effects
        if let f = atFrame {
            offset = max(0, min(clip.durationFrames - 1, f - clip.startFrame))
            sourceFrame = Double(clip.trimStartFrame) + Double(offset) * clip.speed
        } else {
            offset = clip.durationFrames / 2
            sourceFrame = Double(clip.trimStartFrame) + Double(clip.sourceFramesConsumed) / 2
        }
        guard let frame = await Self.frameImage(url: srcURL, type: clip.mediaType, atSeconds: sourceFrame / max(1, fps)) else {
            throw ToolError("Could not decode a frame for clip \(clipId).")
        }
        // Match the render path: crop to the visible region before grading (FrameRenderer crops first).
        let cropped = Self.cropping(frame, crop: clip.cropAt(frame: clip.startFrame + offset))
        let graded = Self.applyingEffects(cropped, clip: clip, atOffset: offset)
        guard let scopes = ColorScopes.measure(graded) else { throw ToolError("Could not measure the clip frame.") }
        return (graded, scopes)
    }

    /// A raw media asset's frame (no effects), at its midpoint.
    private func rawAsset(_ mediaRef: String, editor: EditorViewModel, label: String) async throws -> (CIImage, Scopes) {
        let media = try asset(mediaRef, editor: editor, label: label)
        guard media.type == .video || media.type == .image else {
            throw ToolError("\(label) \(mediaRef) is a \(media.type.rawValue) asset; inspect_color needs a video or image asset.")
        }
        guard let url = editor.mediaResolver.resolveURL(for: mediaRef) else {
            throw ToolError("Could not resolve a URL for \(mediaRef).")
        }
        guard let image = await Self.frameImage(url: url, type: media.type, atSeconds: media.duration / 2),
              let scopes = ColorScopes.measure(image) else {
            throw ToolError("Could not measure \(mediaRef).")
        }
        return (image, scopes)
    }

    // MARK: - Color helpers

    fileprivate static func frameImage(url: URL, type: ClipType, atSeconds: Double) async -> CIImage? {
        if type == .image { return CIImage(contentsOf: url, options: [.colorSpace: NSNull()]) }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        let tolerance = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        let time = CMTime(seconds: max(0, atSeconds), preferredTimescale: 600)
        guard let cg = try? await generator.image(at: time).image else { return nil }
        return CIImage(cgImage: cg, options: [.colorSpace: NSNull()])
    }

    /// Crops a display-oriented frame to its visible region (insets are display-space, CI origin is bottom-left).
    fileprivate static func cropping(_ image: CIImage, crop: Crop) -> CIImage {
        guard !crop.isIdentity else { return image }
        let e = image.extent
        guard e.width > 0, e.height > 0, e.width.isFinite, e.height.isFinite else { return image }
        return image.cropped(to: CGRect(
            x: e.origin.x + crop.left * e.width,
            y: e.origin.y + crop.bottom * e.height,
            width: max(1, crop.visibleWidthFraction * e.width),
            height: max(1, crop.visibleHeightFraction * e.height)))
    }

    fileprivate static func applyingEffects(_ image: CIImage, clip: Clip, atOffset offset: Int) -> CIImage {
        guard let effects = clip.effects else { return image }
        var out = image
        for effect in effects where effect.enabled {
            guard let descriptor = EffectRegistry.descriptor(id: effect.type) else { continue }
            out = descriptor.render(out, effect: effect, atOffset: offset)
        }
        return out
    }

    fileprivate static func encodeJPEG(_ image: CIImage) -> Data? {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0,
              let cg = ColorScopes.context.createCGImage(
                image, from: extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { return nil }
        return ImageEncoder.encodeJPEG(cg, quality: 0.8)
    }

    // NSDecimalNumber so JSONSerialization renders clean 3-decimal values, not float noise.
    private static func r3(_ v: Float) -> NSDecimalNumber { NSDecimalNumber(string: String(format: "%.3f", Double(v))) }
    private static func rgb(_ v: SIMD3<Float>) -> [NSDecimalNumber] { [r3(v.x), r3(v.y), r3(v.z)] }

    private static func readout(_ s: Scopes) -> [String: Any] {
        [
            "luma": [
                "black": r3(s.lumaBlack), "white": r3(s.lumaWhite), "mean": r3(s.lumaMean),
                "clipLowPct": r3(s.clipLow * 100), "clipHighPct": r3(s.clipHigh * 100),
                "histogram16": s.lumaHistogram.map { r3($0) },
            ],
            "meanRGB": rgb(s.meanRGB),
            "blackRGB": rgb(s.blackRGB), "whiteRGB": rgb(s.whiteRGB),
            "zones": ["shadows": rgb(s.shadowRGB), "mids": rgb(s.midRGB), "highs": rgb(s.highRGB)],
            "saturation": r3(s.saturationMean),
            "balance": ["warmCool": r3(s.warmCoolBias), "greenMagenta": r3(s.greenMagentaBias)],
            "hueHistogram12": s.hueHistogram.map { r3($0) },
            "colorfulPct": r3(s.colorfulPct * 100),
        ]
    }

    /// current − reference for the key metrics, plus knob-mapped hints.
    private static func gap(current c: Scopes, reference r: Scopes) -> [String: Any] {
        var hints: [String] = []
        let db = c.lumaBlack - r.lumaBlack
        if abs(db) > 0.03 { hints.append(db > 0 ? "blacks higher than ref → lower 'blacks' / deepen shadows" : "blacks lower than ref → raise 'blacks'") }
        let dw = c.warmCoolBias - r.warmCoolBias
        if abs(dw) > 0.03 { hints.append(dw > 0 ? "warmer than ref → cooler 'temperature'" : "cooler than ref → warmer 'temperature'") }
        let dg = c.greenMagentaBias - r.greenMagentaBias
        if abs(dg) > 0.02 { hints.append(dg > 0 ? "greener than ref → 'tint' toward magenta" : "more magenta than ref → 'tint' toward green") }
        let dsat = c.saturationMean - r.saturationMean
        if abs(dsat) > 0.03 { hints.append(dsat > 0 ? "more saturated than ref → lower 'saturation'" : "less saturated than ref → raise 'saturation'") }
        return [
            "lumaBlack": r3(db), "lumaWhite": r3(c.lumaWhite - r.lumaWhite), "lumaMean": r3(c.lumaMean - r.lumaMean),
            "warmCool": r3(dw), "greenMagenta": r3(dg), "saturation": r3(dsat),
            "shadowsRGB": rgb(c.shadowRGB - r.shadowRGB),
            "midsRGB": rgb(c.midRGB - r.midRGB),
            "highsRGB": rgb(c.highRGB - r.highRGB),
            "hints": hints,
        ]
    }
}

private func clamp3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }

private struct GradeState {
    var exposure, temperature, tint, contrast, highlights, shadows, blacks, whites: Double?
    var shadowsHue, shadowsAmount, shadowsLum: Double?
    var midsHue, midsAmount, midsGamma: Double?
    var highsHue, highsAmount, highsGain: Double?
    var vibrance, saturation: Double?
    var curve: GradeCurve?
    var hueCurves: HueCurves?
    var lutPath: String?
    var lutIntensity: Double?

    init(effects: [Effect]?) {
        guard let effects else { return }
        for e in effects {
            let p = e.params
            switch e.type {
            case "color.exposure": exposure = p["ev"]?.value
            case "color.temperature": temperature = p["temperature"]?.value; tint = p["tint"]?.value
            case "color.contrast": contrast = p["amount"]?.value
            case "color.highlightsShadows": highlights = p["highlights"]?.value; shadows = p["shadows"]?.value
            case "color.blacksWhites": blacks = p["blacks"]?.value; whites = p["whites"]?.value
            case "color.vibrance": vibrance = p["amount"]?.value
            case "color.saturation": saturation = p["amount"]?.value
            case "color.curves": curve = (p["curve"]?.string).flatMap { GradeCurve(json: $0) }
            case "color.hueCurves": hueCurves = (p["curves"]?.string).flatMap { HueCurves(json: $0) }
            case "color.lut": lutPath = p["path"]?.string; lutIntensity = p["intensity"]?.value
            case "color.wheels":
                (shadowsHue, shadowsAmount) = Self.hueAmount(p["lift_x"]?.value ?? 0, p["lift_y"]?.value ?? 0)
                shadowsLum = p["lift_m"]?.value
                (midsHue, midsAmount) = Self.hueAmount(p["gamma_x"]?.value ?? 0, p["gamma_y"]?.value ?? 0)
                midsGamma = p["gamma_m"]?.value
                (highsHue, highsAmount) = Self.hueAmount(p["gain_x"]?.value ?? 0, p["gain_y"]?.value ?? 0)
                highsGain = p["gain_m"]?.value
            default: break
            }
        }
    }

    /// A pasted `color` object — the shape colorObject(from:) emits.
    init(colorDict d: [String: Any]) {
        func dv(_ k: String) -> Double? { (d[k] as? NSNumber)?.doubleValue }
        exposure = dv("exposure"); contrast = dv("contrast"); saturation = dv("saturation")
        vibrance = dv("vibrance"); temperature = dv("temperature"); tint = dv("tint")
        highlights = dv("highlights"); shadows = dv("shadows"); blacks = dv("blacks"); whites = dv("whites")
        shadowsHue = dv("shadowsHue"); shadowsAmount = dv("shadowsAmount"); shadowsLum = dv("shadowsLum")
        midsHue = dv("midsHue"); midsAmount = dv("midsAmount"); midsGamma = dv("midsGamma")
        highsHue = dv("highsHue"); highsAmount = dv("highsAmount"); highsGain = dv("highsGain")

        func points(_ raw: Any?) -> [CurvePoint] {
            (raw as? [[Any]])?.compactMap { row in
                guard row.count >= 2,
                      let x = (row[0] as? NSNumber)?.doubleValue,
                      let y = (row[1] as? NSNumber)?.doubleValue else { return nil }
                return CurvePoint(x: x, y: y)
            } ?? []
        }
        let master = points(d["masterCurve"]), red = points(d["redCurve"])
        let green = points(d["greenCurve"]), blue = points(d["blueCurve"])
        if !(master.isEmpty && red.isEmpty && green.isEmpty && blue.isEmpty) {
            var c = GradeCurve()
            c.master = master; c.red = red; c.green = green; c.blue = blue
            curve = c
        }
        if let raw = d["hueCurvesRaw"] as? [String: Any] {
            var hc = HueCurves()
            hc.hueVsHue = points(raw["hueVsHue"])
            hc.hueVsSat = points(raw["hueVsSat"])
            hc.hueVsLum = points(raw["hueVsLum"])
            if !hc.isIdentity { hueCurves = hc }
        }
        if let lut = d["lut"] as? [String: Any] {
            lutPath = lut["path"] as? String
            lutIntensity = (lut["strength"] as? NSNumber)?.doubleValue
        }
    }

    mutating func apply(_ i: ToolExecutor.ApplyColorInput, lutDestPath: String?) {
        if let v = i.exposure { exposure = v }
        if let v = i.temperature { temperature = v }
        if let v = i.tint { tint = v }
        if let v = i.contrast { contrast = v }
        if let v = i.highlights { highlights = v }
        if let v = i.shadows { shadows = v }
        if let v = i.blacks { blacks = v }
        if let v = i.whites { whites = v }
        if let v = i.shadowsHue { shadowsHue = v }
        if let v = i.shadowsAmount { shadowsAmount = v }
        if let v = i.shadowsLum { shadowsLum = v }
        if let v = i.midsHue { midsHue = v }
        if let v = i.midsAmount { midsAmount = v }
        if let v = i.midsGamma { midsGamma = v }
        if let v = i.highsHue { highsHue = v }
        if let v = i.highsAmount { highsAmount = v }
        if let v = i.highsGain { highsGain = v }
        if let v = i.vibrance { vibrance = v }
        if let v = i.saturation { saturation = v }
        func points(_ arr: [[Double]]?) -> [CurvePoint]? {
            arr?.compactMap { $0.count >= 2 ? CurvePoint(x: clamp3($0[0]), y: clamp3($0[1])) : nil }
        }
        if i.masterCurve != nil || i.redCurve != nil || i.greenCurve != nil || i.blueCurve != nil {
            var c = curve ?? GradeCurve()
            if let p = points(i.masterCurve) { c.master = p }
            if let p = points(i.redCurve) { c.red = p }
            if let p = points(i.greenCurve) { c.green = p }
            if let p = points(i.blueCurve) { c.blue = p }
            curve = c
        }
        if let targets = i.hueCurves?.targets, !targets.isEmpty { hueCurves = Self.compileHueCurves(targets) }
        if let dest = lutDestPath {
            lutPath = dest
            lutIntensity = (i.lut?.strength).map { clamp3(min(1, max(0, $0))) } ?? 1
        } else if let st = i.lut?.strength {
            lutIntensity = clamp3(min(1, max(0, st)))   // re-blend the existing LUT
        }
    }

    /// Emits effects in EffectRegistry.canonicalOrder so an agent grade renders identically to the UI's.
    func buildStack() -> [Effect] {
        var stack: [Effect] = []
        if let v = exposure { stack.append(.make("color.exposure", ["ev": clamp3(v)])) }
        if let v = contrast { stack.append(.make("color.contrast", ["amount": clamp3(v)])) }
        if highlights != nil || shadows != nil {
            stack.append(.make("color.highlightsShadows", ["highlights": clamp3(highlights ?? 0), "shadows": clamp3(shadows ?? 0)]))
        }
        if blacks != nil || whites != nil {
            stack.append(.make("color.blacksWhites", ["blacks": clamp3(blacks ?? 0), "whites": clamp3(whites ?? 0)]))
        }
        if temperature != nil || tint != nil {
            stack.append(.make("color.temperature", ["temperature": clamp3(temperature ?? 6500), "tint": clamp3(tint ?? 0)]))
        }
        if let v = vibrance { stack.append(.make("color.vibrance", ["amount": clamp3(v)])) }
        if let v = saturation { stack.append(.make("color.saturation", ["amount": clamp3(v)])) }
        let wheelFields = [shadowsHue, shadowsAmount, shadowsLum, midsHue, midsAmount, midsGamma, highsHue, highsAmount, highsGain]
        if wheelFields.contains(where: { $0 != nil }) {
            let (lx, ly) = Self.xy(shadowsHue, shadowsAmount)
            let (gx, gy) = Self.xy(midsHue, midsAmount)
            let (hx, hy) = Self.xy(highsHue, highsAmount)
            stack.append(.make("color.wheels", [
                "lift_x": clamp3(lx), "lift_y": clamp3(ly), "lift_m": clamp3(shadowsLum ?? 0),
                "gamma_x": clamp3(gx), "gamma_y": clamp3(gy), "gamma_m": clamp3(midsGamma ?? 1),
                "gain_x": clamp3(hx), "gain_y": clamp3(hy), "gain_m": clamp3(highsGain ?? 1),
            ]))
        }
        if let curve, !curve.isIdentity, let json = curve.encoded() {
            var e = Effect(type: "color.curves")
            e.params["curve"] = EffectParam(string: json)
            stack.append(e)
        }
        if let hueCurves, !hueCurves.isIdentity, let json = hueCurves.encoded() {
            var e = Effect(type: "color.hueCurves")
            e.params["curves"] = EffectParam(string: json)
            stack.append(e)
        }
        if let lutPath {
            stack.append(Effect(type: "color.lut", params: [
                "path": EffectParam(string: lutPath),
                "intensity": EffectParam(value: clamp3(lutIntensity ?? 1)),
            ]))
        }
        return stack
    }

    /// Compiles semantic hue targets into the three hue curves. Each target writes a localized
    /// bump (peak at the target hue, neutral anchors ±band away) into whichever channels it touches.
    static func compileHueCurves(_ targets: [ToolExecutor.HueTargetInput]) -> HueCurves {
        let band = 0.06   // ~22° selectivity
        func wrap01(_ v: Double) -> Double { let m = v.truncatingRemainder(dividingBy: 1); return m < 0 ? m + 1 : m }
        func bump(_ pts: inout [CurvePoint], _ center: Double, _ y: Double) {
            pts.append(CurvePoint(x: wrap01(center), y: y))
            pts.append(CurvePoint(x: wrap01(center - band), y: HueCurves.neutralY))
            pts.append(CurvePoint(x: wrap01(center + band), y: HueCurves.neutralY))
        }
        func finalize(_ pts: [CurvePoint]) -> [CurvePoint] {
            guard !pts.isEmpty else { return [] }
            // Sort by x; on a collision keep the more extreme (non-neutral) point.
            var byX: [Double: CurvePoint] = [:]
            for p in pts.sorted(by: { abs($0.y - HueCurves.neutralY) < abs($1.y - HueCurves.neutralY) }) {
                byX[clamp3(p.x)] = CurvePoint(x: clamp3(p.x), y: clamp3(p.y))
            }
            return byX.values.sorted { $0.x < $1.x }
        }
        var hue: [CurvePoint] = [], sat: [CurvePoint] = [], lum: [CurvePoint] = []
        for t in targets {
            let center = wrap01(t.targetHue / 360)
            if let hs = t.hueShift, abs(hs) > 1e-6 {
                bump(&hue, center, HueCurves.neutralY + max(-30, min(30, hs)) / 60)
            }
            if let ss = t.satScale, abs(ss - 1) > 1e-6 {
                bump(&sat, center, HueCurves.neutralY + (max(0, min(2, ss)) - 1) / 2)
            }
            if let ls = t.lumShift, abs(ls) > 1e-6 {
                bump(&lum, center, HueCurves.neutralY + max(-0.5, min(0.5, ls)))
            }
        }
        var hc = HueCurves()
        hc.hueVsHue = finalize(hue); hc.hueVsSat = finalize(sat); hc.hueVsLum = finalize(lum)
        return hc
    }

    private static func hueAmount(_ x: Double, _ y: Double) -> (Double?, Double?) {
        let amt = (x * x + y * y).squareRoot()
        guard amt > 1e-6 else { return (nil, nil) }
        var deg = atan2(y, x) * 180 / .pi
        if deg < 0 { deg += 360 }
        return (deg, amt)
    }

    private static func xy(_ hue: Double?, _ amount: Double?) -> (Double, Double) {
        let a = (hue ?? 0) * .pi / 180, r = amount ?? 0
        return (r * cos(a), r * sin(a))
    }
}
