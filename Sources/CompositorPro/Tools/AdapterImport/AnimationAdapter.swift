import Foundation

enum AnimationAdapterError: LocalizedError {
    case unsupportedFormat(String)
    case parseFailed(String)
    case invalidKeyframeData(String)
    case missingRequiredField(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let f): return "Unsupported animation format: \(f)"
        case .parseFailed(let msg): return "Parse failed: \(msg)"
        case .invalidKeyframeData(let msg): return "Invalid keyframe data: \(msg)"
        case .missingRequiredField(let f): return "Missing required field: \(f)"
        }
    }
}

/// Supported input animation formats
enum AnimationFormat: String, Codable, Sendable, CaseIterable {
    case gsap = "gsap"
    case lottie = "lottie"
    case css = "css"
    case hyperframes = "hyperframes"
}

/// Target native keyframe property
enum NativeKeyframeProperty: String, Codable, Sendable, CaseIterable {
    case position = "position"
    case scale = "scale"
    case opacity = "opacity"
    case rotation = "rotation"
}

/// Result of adapting an animation to native keyframes
struct AdaptedAnimation: Codable, Sendable, Equatable {
    let property: NativeKeyframeProperty
    let keyframes: [AdaptedKeyframe]
    let durationFrames: Int
    let fps: Int
}

struct AdaptedKeyframe: Codable, Sendable, Equatable {
    let frame: Int
    let value: AdaptedValue
    let interpolation: InterpolationType
}

enum AdaptedValue: Codable, Sendable, Equatable {
    case scalar(Double)
    case point(x: Double, y: Double)
    case size(width: Double, height: Double)
    case color(r: Double, g: Double, b: Double, a: Double)
}

enum InterpolationType: String, Codable, Sendable, CaseIterable {
    case linear
    case easeIn
    case easeOut
    case easeInOut
    case smooth
    case hold
}

/// Input animation container
struct AnimationAdapterInput: Codable, Sendable, Equatable {
    let format: AnimationFormat
    let source: AnimationSource
    let targetFPS: Int
    let targetDurationFrames: Int?
    let targetProperties: [NativeKeyframeProperty]?

    init(
        format: AnimationFormat,
        source: AnimationSource,
        targetFPS: Int = 30,
        targetDurationFrames: Int? = nil,
        targetProperties: [NativeKeyframeProperty]? = nil
    ) {
        self.format = format
        self.source = source
        self.targetFPS = targetFPS
        self.targetDurationFrames = targetDurationFrames
        self.targetProperties = targetProperties
    }
}

enum AnimationSource: Codable, Sendable, Equatable {
    case jsonString(String)
    case fileURL(URL)
    case lottieComposition(LottieComposition)

    private enum CodingKeys: String, CodingKey {
        case type, jsonString, filePath, lottieComposition
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "jsonString":
            let json = try container.decode(String.self, forKey: .jsonString)
            self = .jsonString(json)
        case "fileURL":
            let path = try container.decode(String.self, forKey: .filePath)
            self = .fileURL(URL(fileURLWithPath: path))
        case "lottieComposition":
            let comp = try container.decode(LottieComposition.self, forKey: .lottieComposition)
            self = .lottieComposition(comp)
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown source type: \(type)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .jsonString(let json):
            try container.encode("jsonString", forKey: .type)
            try container.encode(json, forKey: .jsonString)
        case .fileURL(let url):
            try container.encode("fileURL", forKey: .type)
            try container.encode(url.path, forKey: .filePath)
        case .lottieComposition(let comp):
            try container.encode("lottieComposition", forKey: .type)
            try container.encode(comp, forKey: .lottieComposition)
        }
    }
}

/// Lottie composition structure (subset)
struct LottieComposition: Codable, Sendable, Equatable {
    let v: String
    let fr: Double
    let ip: Double
    let op: Double
    let w: Int
    let h: Int
    let layers: [LottieLayer]
    let assets: [LottieAsset]?
    let markers: [LottieMarker]?
}

struct LottieLayer: Codable, Sendable, Equatable {
    let ddd: Int
    let ind: Int
    let ty: Int
    let nm: String
    let sr: Double?
    let ks: LottieTransform?
    let ao: Int?
    let shapes: [LottieShape]?
    let layers: [LottieLayer]?
    let t: LottieTextDocument?
    let sw: Double?
    let sh: Double?
    let sc: String?
    let refId: String?
}

struct LottieTransform: Codable, Sendable, Equatable {
    let a: LottieAnimatedProperty?
    let p: LottieAnimatedProperty?
    let s: LottieAnimatedProperty?
    let r: LottieAnimatedProperty?
    let o: LottieAnimatedProperty?
    let sk: LottieAnimatedProperty?
    let sa: LottieAnimatedProperty?
}

struct LottieAnimatedProperty: Codable, Sendable, Equatable {
    let k: LottieKeyframeValue
    let x: String?
}

enum LottieKeyframeValue: Codable, Sendable, Equatable {
    case staticValue([Double])
    case keyframes([LottieKeyframe])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let arr = try? container.decode([[String: AnyCodable]].self) {
            self = .keyframes(arr.map { LottieKeyframe(from: $0) })
        } else if let val = try? container.decode([Double].self) {
            self = .staticValue(val)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected keyframe array or static value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .staticValue(let val): try container.encode(val)
        case .keyframes(let kfs): try container.encode(kfs)
        }
    }
}

struct LottieKeyframe: Codable, Sendable, Equatable {
    let t: Double
    let s: [Double]?
    let e: [Double]?
    let i: LottieEasing?
    let o: LottieEasing?
    let h: Int?
    let to: [Double]?
    let ti: LottieEasing?
    let n: String?

    init(from dict: [String: AnyCodable]) {
        self.t = dict["t"]?.value as? Double ?? 0
        self.s = dict["s"]?.value as? [Double]
        self.e = dict["e"]?.value as? [Double]
        self.i = (dict["i"]?.value as? [String: AnyCodable]).map { LottieEasing(from: $0) }
        self.o = (dict["o"]?.value as? [String: AnyCodable]).map { LottieEasing(from: $0) }
        self.h = dict["h"]?.value as? Int
        self.to = dict["to"]?.value as? [Double]
        self.ti = (dict["ti"]?.value as? [String: AnyCodable]).map { LottieEasing(from: $0) }
        self.n = dict["n"]?.value as? String
    }
}

struct LottieEasing: Codable, Sendable, Equatable {
    let x: [Double]
    let y: [Double]

    init(from dict: [String: AnyCodable]? = nil) {
        self.x = dict?["x"]?.value as? [Double] ?? [0.333, 0.667]
        self.y = dict?["y"]?.value as? [Double] ?? [0, 1]
    }
}

struct LottieShape: Codable, Sendable, Equatable {
    let ty: String
    let nm: String
    let ks: LottieTransform?
}

struct LottieAsset: Codable, Sendable, Equatable {
    let id: String
    let w: Int
    let h: Int
    let u: String?
    let p: String
    let e: Int
}

struct LottieMarker: Codable, Sendable, Equatable {
    let cm: String
    let tm: Double
    let dr: Double
}

struct LottieTextDocument: Codable, Sendable, Equatable {
    let t: String?
    let f: String?
    let s: Double?
    let fc: [Double]?
}

/// GSAP animation representation
struct GSAPAnimation: Codable, Sendable, Equatable {
    let targets: String?
    let vars: GSAPVars
    let duration: Double?
    let ease: String?
    let delay: Double?
    let `repeat`: Int?
    let yoyo: Bool?
    let stagger: GSAPStagger?
}

struct GSAPVars: Codable, Sendable, Equatable {
    let x: GSAPValue?
    let y: GSAPValue?
    let scale: GSAPValue?
    let scaleX: GSAPValue?
    let scaleY: GSAPValue?
    let opacity: GSAPValue?
    let rotation: GSAPValue?
    let transformOrigin: String?
    let ease: String?
}

enum GSAPValue: Codable, Sendable, Equatable {
    case number(Double)
    case string(String)
    case array([Double])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let n = try? container.decode(Double.self) { self = .number(n) }
        else if let s = try? container.decode(String.self) { self = .string(s) }
        else if let a = try? container.decode([Double].self) { self = .array(a) }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected number, string, or array") }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let n): try container.encode(n)
        case .string(let s): try container.encode(s)
        case .array(let a): try container.encode(a)
        }
    }
}

struct GSAPStagger: Codable, Sendable, Equatable {
    let amount: Double?
    let from: String?
    let grid: [Int]?
    let axis: String?
    let ease: String?
}

/// Main adapter class
final class AnimationAdapter: Sendable {
    static let shared = AnimationAdapter()

    private init() {}

    /// Adapts an animation from a web format to native keyframe tracks
    func adapt(_ input: AnimationAdapterInput) async throws -> [AdaptedAnimation] {
        let sourceData = try await loadSource(input.source)
        switch input.format {
        case .lottie:
            return try adaptLottie(sourceData, input: input)
        case .gsap:
            return try adaptGSAP(sourceData, input: input)
        case .css:
            return try adaptCSS(sourceData, input: input)
        case .hyperframes:
            return try adaptHyperframes(sourceData, input: input)
        }
    }

    private func loadSource(_ source: AnimationSource) async throws -> Data {
        switch source {
        case .jsonString(let str):
            return Data(str.utf8)
        case .fileURL(let url):
            return try Data(contentsOf: url)
        case .lottieComposition(let comp):
            return try JSONEncoder().encode(comp)
        }
    }

    // MARK: - Lottie Adapter

    private func adaptLottie(_ data: Data, input: AnimationAdapterInput) throws -> [AdaptedAnimation] {
        let composition = try JSONDecoder().decode(LottieComposition.self, from: data)
        let sourceFPS = composition.fr
        let sourceDurationFrames = Int((composition.op - composition.ip) * sourceFPS / composition.fr)
        let targetDurationFrames = input.targetDurationFrames ?? sourceDurationFrames
        let frameScale = Double(targetDurationFrames) / Double(sourceDurationFrames)

        var results: [AdaptedAnimation] = []

        for layer in composition.layers {
            let layerResults = try adaptLottieLayer(layer, composition: composition, frameScale: frameScale, targetFPS: input.targetFPS, targetDurationFrames: targetDurationFrames, targetProperties: input.targetProperties)
            results.append(contentsOf: layerResults)
        }

        return results
    }

    private func adaptLottieLayer(
        _ layer: LottieLayer,
        composition: LottieComposition,
        frameScale: Double,
        targetFPS: Int,
        targetDurationFrames: Int,
        targetProperties: [NativeKeyframeProperty]?
    ) throws -> [AdaptedAnimation] {
        guard let transform = layer.ks else { return [] }

        var results: [AdaptedAnimation] = []
        let props = targetProperties ?? [.position, .scale, .opacity, .rotation]

        if props.contains(.position), let posProp = transform.p {
            let keyframes = try convertLottieProperty(posProp, frameScale: frameScale, targetFPS: targetFPS, targetDurationFrames: targetDurationFrames, valueMapper: { vals in
                guard vals.count >= 2 else { throw AnimationAdapterError.invalidKeyframeData("Position needs 2 values") }
                return .point(x: vals[0], y: vals[1])
            })
            results.append(AdaptedAnimation(property: .position, keyframes: keyframes, durationFrames: targetDurationFrames, fps: targetFPS))
        }

        if props.contains(.scale), let scaleProp = transform.s {
            let keyframes = try convertLottieProperty(scaleProp, frameScale: frameScale, targetFPS: targetFPS, targetDurationFrames: targetDurationFrames, valueMapper: { vals in
                guard vals.count >= 2 else { throw AnimationAdapterError.invalidKeyframeData("Scale needs 2 values") }
                return .size(width: vals[0] / 100.0, height: vals[1] / 100.0)
            })
            results.append(AdaptedAnimation(property: .scale, keyframes: keyframes, durationFrames: targetDurationFrames, fps: targetFPS))
        }

        if props.contains(.opacity), let opacityProp = transform.o {
            let keyframes = try convertLottieProperty(opacityProp, frameScale: frameScale, targetFPS: targetFPS, targetDurationFrames: targetDurationFrames, valueMapper: { vals in
                guard let v = vals.first else { throw AnimationAdapterError.invalidKeyframeData("Opacity needs 1 value") }
                return .scalar(v / 100.0)
            })
            results.append(AdaptedAnimation(property: .opacity, keyframes: keyframes, durationFrames: targetDurationFrames, fps: targetFPS))
        }

        if props.contains(.rotation), let rotProp = transform.r {
            let keyframes = try convertLottieProperty(rotProp, frameScale: frameScale, targetFPS: targetFPS, targetDurationFrames: targetDurationFrames, valueMapper: { vals in
                guard let v = vals.first else { throw AnimationAdapterError.invalidKeyframeData("Rotation needs 1 value") }
                return .scalar(v * .pi / 180.0)
            })
            results.append(AdaptedAnimation(property: .rotation, keyframes: keyframes, durationFrames: targetDurationFrames, fps: targetFPS))
        }

        // Recursively adapt child layers
        if let childLayers = layer.layers {
            for child in childLayers {
                let childResults = try adaptLottieLayer(child, composition: composition, frameScale: frameScale, targetFPS: targetFPS, targetDurationFrames: targetDurationFrames, targetProperties: targetProperties)
                results.append(contentsOf: childResults)
            }
        }

        return results
    }

    private func convertLottieProperty(
        _ prop: LottieAnimatedProperty,
        frameScale: Double,
        targetFPS: Int,
        targetDurationFrames: Int,
        valueMapper: ([Double]) throws -> AdaptedValue
    ) throws -> [AdaptedKeyframe] {
        switch prop.k {
        case .staticValue(let vals):
            let value = try valueMapper(vals)
            return [AdaptedKeyframe(frame: 0, value: value, interpolation: .linear)]

        case .keyframes(let kfs):
            var results: [AdaptedKeyframe] = []
            for (_, kf) in kfs.enumerated() {
                let frame = Int((kf.t * frameScale).rounded())
                let clampedFrame = min(max(frame, 0), targetDurationFrames - 1)

                let values = kf.s ?? kf.e ?? kf.to ?? []
                guard !values.isEmpty else { continue }

                let value = try valueMapper(values)
                let interpolation = mapLottieEasing(kf.o ?? kf.i)

                results.append(AdaptedKeyframe(frame: clampedFrame, value: value, interpolation: interpolation))
            }
            return results.sorted { $0.frame < $1.frame }
        }
    }

    private func mapLottieEasing(_ easing: LottieEasing?) -> InterpolationType {
        guard let easing else { return .linear }
        // Simple heuristic based on bezier control points
        let x = easing.x
        let y = easing.y
        if x.count >= 2 && y.count >= 2 {
            if x[0] > 0.5 && y[0] < 0.5 { return .easeOut }
            if x[0] < 0.5 && y[0] > 0.5 { return .easeIn }
            if x[0] < 0.5 && y[0] < 0.5 && x[1] > 0.5 && y[1] > 0.5 { return .easeInOut }
        }
        return .smooth
    }

    // MARK: - GSAP Adapter

    private func adaptGSAP(_ data: Data, input: AnimationAdapterInput) throws -> [AdaptedAnimation] {
        let gsapAnim = try JSONDecoder().decode(GSAPAnimation.self, from: data)
        let duration = gsapAnim.duration ?? 1.0
        let targetDurationFrames = input.targetDurationFrames ?? Int(duration * Double(input.targetFPS))
        let frameScale = Double(targetDurationFrames) / (duration * Double(input.targetFPS))

        var results: [AdaptedAnimation] = []
        let vars = gsapAnim.vars
        let props = input.targetProperties ?? [.position, .scale, .opacity, .rotation]

        if props.contains(.position) {
            let keyframes = try convertGSAPProperty(
                x: vars.x, y: vars.y,
                duration: duration, frameScale: frameScale, targetFPS: input.targetFPS,
                targetDurationFrames: targetDurationFrames, ease: gsapAnim.ease ?? vars.ease,
                mapper: { x, y in .point(x: x, y: y) }
            )
            if !keyframes.isEmpty {
                results.append(AdaptedAnimation(property: .position, keyframes: keyframes, durationFrames: targetDurationFrames, fps: input.targetFPS))
            }
        }

        if props.contains(.scale) {
            let keyframes = try convertGSAPProperty(
                x: vars.scaleX ?? vars.scale, y: vars.scaleY ?? vars.scale,
                duration: duration, frameScale: frameScale, targetFPS: input.targetFPS,
                targetDurationFrames: targetDurationFrames, ease: gsapAnim.ease ?? vars.ease,
                mapper: { sx, sy in .size(width: sx, height: sy) }
            )
            if !keyframes.isEmpty {
                results.append(AdaptedAnimation(property: .scale, keyframes: keyframes, durationFrames: targetDurationFrames, fps: input.targetFPS))
            }
        }

        if props.contains(.opacity), let opacity = vars.opacity {
            let keyframes = try convertGSAPProperty(
                single: opacity, duration: duration, frameScale: frameScale, targetFPS: input.targetFPS,
                targetDurationFrames: targetDurationFrames, ease: gsapAnim.ease ?? vars.ease,
                mapper: { .scalar($0) }
            )
            if !keyframes.isEmpty {
                results.append(AdaptedAnimation(property: .opacity, keyframes: keyframes, durationFrames: targetDurationFrames, fps: input.targetFPS))
            }
        }

        if props.contains(.rotation), let rotation = vars.rotation {
            let keyframes = try convertGSAPProperty(
                single: rotation, duration: duration, frameScale: frameScale, targetFPS: input.targetFPS,
                targetDurationFrames: targetDurationFrames, ease: gsapAnim.ease ?? vars.ease,
                mapper: { .scalar($0 * .pi / 180.0) }
            )
            if !keyframes.isEmpty {
                results.append(AdaptedAnimation(property: .rotation, keyframes: keyframes, durationFrames: targetDurationFrames, fps: input.targetFPS))
            }
        }

        return results
    }

    private func convertGSAPProperty(
        x: GSAPValue?, y: GSAPValue?,
        duration: Double, frameScale: Double, targetFPS: Int, targetDurationFrames: Int, ease: String?,
        mapper: (Double, Double) -> AdaptedValue
    ) throws -> [AdaptedKeyframe] {
        // Simplified: GSAP typically defines start/end values
        let startX = extractGSAPStartValue(x) ?? 0
        let endX = extractGSAPEndValue(x) ?? startX
        let startY = extractGSAPStartValue(y) ?? 0
        let endY = extractGSAPEndValue(y) ?? startY

        let interpolation = mapGSAPEase(ease)
        return [
            AdaptedKeyframe(frame: 0, value: mapper(startX, startY), interpolation: interpolation),
            AdaptedKeyframe(frame: targetDurationFrames - 1, value: mapper(endX, endY), interpolation: interpolation)
        ]
    }

    private func convertGSAPProperty(
        single: GSAPValue,
        duration: Double, frameScale: Double, targetFPS: Int, targetDurationFrames: Int, ease: String?,
        mapper: (Double) -> AdaptedValue
    ) throws -> [AdaptedKeyframe] {
        let start = extractGSAPStartValue(single) ?? 0
        let end = extractGSAPEndValue(single) ?? start
        let interpolation = mapGSAPEase(ease)
        return [
            AdaptedKeyframe(frame: 0, value: mapper(start), interpolation: interpolation),
            AdaptedKeyframe(frame: targetDurationFrames - 1, value: .scalar(end), interpolation: interpolation)
        ]
    }

    private func extractGSAPStartValue(_ val: GSAPValue?) -> Double? {
        guard let val else { return nil }
        switch val {
        case .number(let n): return n
        case .string(let s): return Double(s)
        case .array(let arr): return arr.first
        }
    }

    private func extractGSAPEndValue(_ val: GSAPValue?) -> Double? {
        guard let val else { return nil }
        switch val {
        case .number(let n): return n
        case .string(let s): return Double(s)
        case .array(let arr): return arr.last ?? arr.first
        }
    }

    private func mapGSAPEase(_ ease: String?) -> InterpolationType {
        guard let ease = ease?.lowercased() else { return .linear }
        if ease.contains("power1.in") || ease.contains("quad.in") { return .easeIn }
        if ease.contains("power1.out") || ease.contains("quad.out") { return .easeOut }
        if ease.contains("power1.inout") || ease.contains("quad.inout") { return .easeInOut }
        if ease.contains("back") || ease.contains("elastic") || ease.contains("bounce") { return .smooth }
        return .linear
    }

    // MARK: - CSS Adapter (simplified)

    private func adaptCSS(_ data: Data, input: AnimationAdapterInput) throws -> [AdaptedAnimation] {
        // Parse CSS @keyframes and animation properties
        let css = String(data: data, encoding: .utf8) ?? ""
        return try parseCSSKeyframes(css, input: input)
    }

    private func parseCSSKeyframes(_ css: String, input: AnimationAdapterInput) throws -> [AdaptedAnimation] {
        // Simplified CSS keyframe parser
        // Full implementation would parse @keyframes rules
        throw AnimationAdapterError.unsupportedFormat("CSS parser not yet implemented")
    }

    // MARK: - HyperFrames Adapter

    private func adaptHyperframes(_ data: Data, input: AnimationAdapterInput) throws -> [AdaptedAnimation] {
        // HyperFrames blocks may include animation definitions
        // This delegates to Lottie/GSAP adapters based on requiredAdapters
        throw AnimationAdapterError.unsupportedFormat("HyperFrames adapter delegates to format-specific adapters")
    }
}

/// Helper for encoding/decoding heterogeneous values
struct AnyCodable: Codable, @unchecked Sendable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(Bool.self) { value = v }
        else if let v = try? container.decode(Int.self) { value = v }
        else if let v = try? container.decode(Double.self) { value = v }
        else if let v = try? container.decode(String.self) { value = v }
        else if let v = try? container.decode([String: AnyCodable].self) { value = v }
        else if let v = try? container.decode([AnyCodable].self) { value = v }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported value type") }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let v as Bool: try container.encode(v)
        case let v as Int: try container.encode(v)
        case let v as Double: try container.encode(v)
        case let v as String: try container.encode(v)
        case let v as [String: AnyCodable]: try container.encode(v)
        case let v as [AnyCodable]: try container.encode(v)
        default: throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: container.codingPath, debugDescription: "Unsupported value type"))
        }
    }
}