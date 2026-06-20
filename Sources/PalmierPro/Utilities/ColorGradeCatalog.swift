import CoreImage
import Foundation

/// Built-in color looks the agent applies by name. Each is a small Core Image
/// primary chain, so it composes with the same export pass as imported `.cube` LUTs.
enum ColorGradeCatalog {

    struct Look: Sendable, Equatable {
        let id: String
        let name: String
        let summary: String
        let steps: [Step]

        struct Step: Sendable, Equatable {
            let filter: String
            let params: [String: Double]
            let curve: [CGPoint]?
            init(_ filter: String, _ params: [String: Double] = [:], curve: [CGPoint]? = nil) {
                self.filter = filter
                self.params = params
                self.curve = curve
            }
        }
    }

    /// Maps input `floor` to black and steepens mids — dehazes hazy footage.
    private static func dehazeCurve(floor: Double, shoulder: Double = 0.97) -> [CGPoint] {
        [
            .init(x: floor, y: 0.0),
            .init(x: floor + (0.5 - floor) * 0.5, y: 0.24),
            .init(x: 0.5, y: 0.5),
            .init(x: 0.5 + (shoulder - 0.5) * 0.5, y: 0.78),
            .init(x: shoulder, y: 1.0),
        ]
    }

    static let all: [Look] = [
        Look(
            id: "warm-cinematic",
            name: "Warm Cinematic",
            summary: "Warm highlights, real contrast, dehazed blacks. A filmic default for daylight/outdoor footage.",
            steps: [
                .init("CITemperatureAndTint", ["neutralX": 7200, "neutralY": 0, "targetX": 6500, "targetY": 0]),
                .init("CIToneCurve", curve: dehazeCurve(floor: 0.08)),
                .init("CIColorControls", ["saturation": 1.12, "contrast": 1.12]),
                .init("CIVibrance", ["amount": 0.2]),
            ]
        ),
        Look(
            id: "teal-orange",
            name: "Teal & Orange",
            summary: "Warm mids against cooler shadows — the classic travel/adventure blockbuster look.",
            steps: [
                .init("CITemperatureAndTint", ["neutralX": 6500, "neutralY": 0, "targetX": 6050, "targetY": 16]),
                .init("CIToneCurve", curve: dehazeCurve(floor: 0.1)),
                .init("CIColorControls", ["saturation": 1.22, "contrast": 1.14]),
                .init("CIVibrance", ["amount": 0.35]),
            ]
        ),
        Look(
            id: "moody-forest",
            name: "Moody Forest",
            summary: "Deeper greens, cooler shadows, dehazed and contrasty. Suits hikes, jungle, overcast nature.",
            steps: [
                .init("CITemperatureAndTint", ["neutralX": 6200, "neutralY": 0, "targetX": 7000, "targetY": -10]),
                .init("CIToneCurve", curve: dehazeCurve(floor: 0.12)),
                .init("CIColorControls", ["saturation": 1.0, "contrast": 1.18, "brightness": -0.02]),
            ]
        ),
        Look(
            id: "vibrant-travel",
            name: "Vibrant Travel",
            summary: "Punchy, bright, saturated, dehazed — pops skies and landscapes for social/vlog delivery.",
            steps: [
                .init("CIToneCurve", curve: dehazeCurve(floor: 0.1)),
                .init("CIColorControls", ["saturation": 1.32, "contrast": 1.16, "brightness": 0.01]),
                .init("CIVibrance", ["amount": 0.5]),
            ]
        ),
        Look(
            id: "vintage-film",
            name: "Vintage Film",
            summary: "Faded, lifted blacks and softened highlights with a warm cast — a nostalgic Super-8 feel.",
            steps: [
                .init("CITemperatureAndTint", ["neutralX": 6500, "neutralY": 0, "targetX": 6000, "targetY": 8]),
                .init("CIColorControls", ["saturation": 0.88, "contrast": 0.96]),
                .init("CIToneCurve", curve: [.init(x: 0, y: 0.1), .init(x: 0.25, y: 0.28),
                                             .init(x: 0.5, y: 0.5), .init(x: 0.75, y: 0.72), .init(x: 1, y: 0.9)]),
            ]
        ),
        Look(
            id: "clean-neutral",
            name: "Clean Neutral",
            summary: "A light, true-to-life polish — modest dehaze, contrast and vibrance. Use when footage is already good.",
            steps: [
                .init("CIToneCurve", curve: dehazeCurve(floor: 0.05)),
                .init("CIColorControls", ["saturation": 1.08, "contrast": 1.06]),
                .init("CIVibrance", ["amount": 0.18]),
            ]
        ),
    ]

    static func look(id: String) -> Look? { all.first { $0.id == id } }

    static var catalogJSON: [[String: Any]] {
        all.map { ["id": $0.id, "name": $0.name, "summary": $0.summary] }
    }
}

extension ColorGradeCatalog.Look: ColorGradeProcessor {
    func process(_ image: CIImage, colorSpace: CGColorSpace) -> CIImage {
        var result = image
        for filter in ciFilters(intensity: 1.0) {
            filter.setValue(result, forKey: kCIInputImageKey)
            if let out = filter.outputImage { result = out }
        }
        return result
    }

    /// Configured filters (no input image) with each step interpolated toward
    /// identity by `intensity` — used for the live `CALayer.filters` preview.
    func ciFilters(intensity t: Double) -> [CIFilter] {
        steps.compactMap { makeFilter($0, intensity: t) }
    }

    private func makeFilter(_ step: Step, intensity t: Double) -> CIFilter? {
        guard let f = CIFilter(name: step.filter) else { return nil }
        switch step.filter {
        case "CITemperatureAndTint":
            let nx = step.params["neutralX"] ?? 6500, ny = step.params["neutralY"] ?? 0
            let tx = step.params["targetX"] ?? nx, ty = step.params["targetY"] ?? ny
            f.setValue(CIVector(x: nx, y: ny), forKey: "inputNeutral")
            f.setValue(CIVector(x: nx + (tx - nx) * t, y: ny + (ty - ny) * t), forKey: "inputTargetNeutral")
        case "CIColorControls":
            if let s = step.params["saturation"] { f.setValue(1 + (s - 1) * t, forKey: "inputSaturation") }
            if let c = step.params["contrast"] { f.setValue(1 + (c - 1) * t, forKey: "inputContrast") }
            if let b = step.params["brightness"] { f.setValue(b * t, forKey: "inputBrightness") }
        case "CIVibrance":
            if let a = step.params["amount"] { f.setValue(a * t, forKey: "inputAmount") }
        default:
            for (key, value) in step.params {
                f.setValue(value, forKey: "input" + key.prefix(1).uppercased() + key.dropFirst())
            }
        }
        if let curve = step.curve, curve.count == 5 {
            for (i, pt) in curve.enumerated() {
                let y = pt.x + (pt.y - pt.x) * CGFloat(t)   // lerp toward identity (y = x)
                f.setValue(CIVector(x: pt.x, y: y), forKey: "inputPoint\(i)")
            }
        }
        return f
    }
}
