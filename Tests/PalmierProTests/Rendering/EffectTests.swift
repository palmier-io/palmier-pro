import AVFoundation
import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PalmierPro

@Suite("Effects — model")
struct EffectModelTests {

    @Test func clipEffectsRoundTripThroughCodable() throws {
        var clip = Fixtures.clip(id: "c1", mediaRef: "m", start: 0, duration: 30)
        clip.effects = [Effect.make("color.exposure", ["ev": 1.5])]

        let data = try JSONEncoder().encode(clip)
        let decoded = try JSONDecoder().decode(Clip.self, from: data)

        #expect(decoded.effects?.count == 1)
        #expect(decoded.effects?.first?.type == "color.exposure")
        #expect(decoded.effects?.first?.params["ev"]?.value == 1.5)
        #expect(decoded.effects?.first?.enabled == true)
    }

    /// The master curve is a true luma curve: lifting it raises luminance while keeping
    /// the R:G:B ratio (chroma) of a non-clipping voxel constant.
    @Test func masterCurveIsLumaPreservingChroma() {
        let ctx = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        let curve = GradeCurve(master: [CurvePoint(x: 0, y: 0.2), CurvePoint(x: 1, y: 1)])
        let (inR, inG, inB) = (0.6, 0.45, 0.3)
        let img = CIImage(color: CIColor(red: inR, green: inG, blue: inB)).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
        var px = [Float](repeating: 0, count: 4)
        ctx.render(GradeCurveKernel.apply(img, curve: curve), toBitmap: &px, rowBytes: 16,
                   bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        let (outR, outG, outB) = (Double(px[0]), Double(px[1]), Double(px[2]))

        #expect(abs(outR / outG - inR / inG) < 0.02, "R:G ratio should hold (chroma preserved)")
        #expect(abs(outR / outB - inR / inB) < 0.02, "R:B ratio should hold (chroma preserved)")
        let inLuma = 0.2126 * inR + 0.7152 * inG + 0.0722 * inB
        let outLuma = 0.2126 * outR + 0.7152 * outG + 0.0722 * outB
        #expect(outLuma > inLuma + 0.05, "lifted luma curve should raise luminance")
    }

    @Test func colorWheelGainMasterScalesAllChannels() {
        let ctx = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        let p = ResolvedEffectParams(values: [
            "lift_x": 0, "lift_y": 0, "lift_m": 0,
            "gamma_x": 0, "gamma_y": 0, "gamma_m": 1,
            "gain_x": 0, "gain_y": 0, "gain_m": 0.5,
        ], strings: [:])
        let img = CIImage(color: CIColor(red: 0.8, green: 0.6, blue: 0.4)).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
        var px = [Float](repeating: 0, count: 4)
        ctx.render(WheelsKernel.apply(img, params: p), toBitmap: &px, rowBytes: 16,
                   bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        // gain_m 0.5, gamma 1, lift 0 → exact half (no cube quantization).
        #expect(abs(Double(px[0]) - 0.4) < 1e-3 && abs(Double(px[1]) - 0.3) < 1e-3 && abs(Double(px[2]) - 0.2) < 1e-3,
                "got \(px[0]) \(px[1]) \(px[2])")
    }

    @Test func clipWithoutEffectsOmitsKey() throws {
        let clip = Fixtures.clip(id: "c1", mediaRef: "m", start: 0, duration: 30)
        let data = try JSONEncoder().encode(clip)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("\"effects\""))
    }

    /// Effects from a newer build survive decode + re-encode even when the
    /// descriptor is unknown to this build.
    @Test func unknownEffectTypeIsPreserved() throws {
        var clip = Fixtures.clip(id: "c1", mediaRef: "m", start: 0, duration: 30)
        clip.effects = [Effect.make("future.hologram", ["wobble": 0.7])]

        let data = try JSONEncoder().encode(clip)
        let decoded = try JSONDecoder().decode(Clip.self, from: data)
        let reencoded = try JSONEncoder().encode(decoded)
        let final = try JSONDecoder().decode(Clip.self, from: reencoded)

        #expect(final.effects?.first?.type == "future.hologram")
        #expect(final.effects?.first?.params["wobble"]?.value == 0.7)
        #expect(EffectRegistry.descriptor(id: "future.hologram") == nil)
    }

    @Test func paramResolvesKeyframeTrackWhenPresent() {
        var param = EffectParam(value: 1.0)
        #expect(param.resolved(at: 10, default: 0) == 1.0)
        param.track = KeyframeTrack(keyframes: [
            Keyframe(frame: 0, value: 0.0, interpolationOut: .linear),
            Keyframe(frame: 20, value: 2.0, interpolationOut: .linear),
        ])
        #expect(abs(param.resolved(at: 10, default: 0) - 1.0) < 0.001)
        #expect(abs(param.resolved(at: 20, default: 0) - 2.0) < 0.001)
    }

    @Test func registryDescriptorsHaveUniqueIdsAndValidDefaults() {
        var seen = Set<String>()
        for descriptor in EffectRegistry.all {
            #expect(seen.insert(descriptor.id).inserted, "duplicate id \(descriptor.id)")
            for spec in descriptor.params {
                #expect(spec.range.contains(spec.defaultValue),
                        "\(descriptor.id).\(spec.key) default outside range")
            }
        }
    }
}

@Suite("Effects — rendering")
@MainActor
struct EffectRenderingTests {

    /// Exposure through the real compositor must measurably brighten/darken frames.
    @Test func exposureChangesRenderedBrightness() async throws {
        let renderSize = CompositorFixtures.renderSize
        let videoURL = try await CompositorFixtures.midtoneVideoURL()
        let urls = ["midtone": videoURL]

        func meanLuma(ev: Double?) async throws -> Double {
            var clip = CompositorFixtures.midtoneClip()
            if let ev { clip.effects = [Effect.make("color.exposure", ["ev": ev])] }
            let tl = CompositorFixtures.timeline([Fixtures.videoTrack(clips: [clip])])
            let result = try await CompositionBuilder.build(
                timeline: tl, resolveURL: { urls[$0] }, renderSize: renderSize
            )
            let generator = AVAssetImageGenerator(asset: result.composition)
            generator.videoComposition = result.videoComposition
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let cg = try await generator.image(at: CMTime(value: 15, timescale: 30)).image
            let bytes = ColorProbeHelpers.srgbBytes(cg, size: renderSize)
            var total = 0.0
            for i in stride(from: 0, to: bytes.count, by: 4) {
                total += Double(bytes[i]) + Double(bytes[i + 1]) + Double(bytes[i + 2])
            }
            return total / Double(bytes.count / 4 * 3)
        }

        let base = try await meanLuma(ev: nil)
        let darker = try await meanLuma(ev: -2)
        let brighter = try await meanLuma(ev: 1)
        #expect(darker < base - 20, "ev -2 should darken: base \(base), got \(darker)")
        #expect(brighter > base + 20, "ev +1 should brighten: base \(base), got \(brighter)")
    }

    /// Every catalog effect renders without crashing and (with non-default params)
    /// actually changes pixels. Catches broken filter names/keys as the catalog grows.
    @Test func everyCatalogEffectRendersAndChangesPixels() async throws {
        let renderSize = CompositorFixtures.renderSize
        let videoURL = try await CompositorFixtures.midtoneVideoURL()
        let urls = ["midtone": videoURL]

        let nonDefault: [String: [String: Double]] = [
            "color.exposure": ["ev": -2],
            "color.contrast": ["amount": 0.5],
            "color.saturation": ["amount": 0],
            "color.temperature": ["temperature": 3000],
            "color.highlightsShadows": ["highlights": 0.3, "shadows": 0.8],
            "color.blacksWhites": ["blacks": 1, "whites": -1],
            "color.vibrance": ["amount": 1],
            "color.wheels": ["lift_x": 0.45, "lift_y": 0.2, "gain_m": 1.2],
            "blur.gaussian": ["radius": 30],
            "blur.sharpen": ["amount": 2],
            "stylize.vignette": ["amount": -1, "midpoint": 0.2],
            "stylize.grain": ["amount": 1, "size": 1.5],
            "detail.clarity": ["clarity": 1, "dehaze": 0],
            "key.chroma": ["keyHue": 0.333, "tolerance": 0.5],
            "stylize.glow": ["intensity": 1, "radius": 20, "threshold": 0],
            "blur.noiseReduction": ["amount": 1],
            "blur.motion": ["radius": 20, "angle": 0],
        ]

        func frame(_ effects: [Effect]?) async throws -> [UInt8] {
            var clip = CompositorFixtures.midtoneClip()
            clip.effects = effects
            let tl = CompositorFixtures.timeline([Fixtures.videoTrack(clips: [clip])])
            let result = try await CompositionBuilder.build(
                timeline: tl, resolveURL: { urls[$0] }, renderSize: renderSize
            )
            let generator = AVAssetImageGenerator(asset: result.composition)
            generator.videoComposition = result.videoComposition
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let cg = try await generator.image(at: CMTime(value: 15, timescale: 30)).image
            return ColorProbeHelpers.srgbBytes(cg, size: renderSize)
        }

        // Vibrance's delta is the least predictable across renderers, so render it
        // (catches a bad filter key) but don't assert a pixel change.
        let noOpOnSaturated: Set<String> = ["color.vibrance"]
        // color.curves / color.hueCurves carry JSON curves, not Double params — covered by their own tests.
        let jsonCurveEffects: Set<String> = ["color.curves", "color.hueCurves"]
        let base = try await frame(nil)
        for descriptor in EffectRegistry.all where descriptor.resourceKey == nil && !jsonCurveEffects.contains(descriptor.id) {
            let params = nonDefault[descriptor.id]
            #expect(params != nil, "add non-default params for \(descriptor.id) to this test")
            let rendered = try await frame([Effect.make(descriptor.id, params ?? [:])])
            if noOpOnSaturated.contains(descriptor.id) { continue }
            let changed = zip(base, rendered).contains { abs(Int($0) - Int($1)) > 8 }
            #expect(changed, "\(descriptor.id) produced an unchanged frame")
        }
    }

    /// A master tone curve that lifts shadows/mids measurably brightens the frame,
    /// and an identity curve is a passthrough.
    @Test func curvesEffectAppliesCompiledCube() async throws {
        let renderSize = CompositorFixtures.renderSize
        let videoURL = try await CompositorFixtures.midtoneVideoURL()
        let urls = ["midtone": videoURL]

        func meanLuma(_ curve: GradeCurve?) async throws -> Double {
            var clip = CompositorFixtures.midtoneClip()
            if let curve, let json = curve.encoded() {
                var effect = Effect(type: "color.curves")
                effect.params["curve"] = EffectParam(string: json)
                clip.effects = [effect]
            }
            let tl = CompositorFixtures.timeline([Fixtures.videoTrack(clips: [clip])])
            let result = try await CompositionBuilder.build(
                timeline: tl, resolveURL: { urls[$0] }, renderSize: renderSize
            )
            let generator = AVAssetImageGenerator(asset: result.composition)
            generator.videoComposition = result.videoComposition
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let cg = try await generator.image(at: CMTime(value: 15, timescale: 30)).image
            let bytes = ColorProbeHelpers.srgbBytes(cg, size: renderSize)
            var total = 0.0
            for i in stride(from: 0, to: bytes.count, by: 4) {
                total += Double(bytes[i]) + Double(bytes[i + 1]) + Double(bytes[i + 2])
            }
            return total / Double(bytes.count / 4 * 3)
        }

        let base = try await meanLuma(nil)
        let identity = try await meanLuma(GradeCurve())
        let lift = try await meanLuma(GradeCurve(master: [CurvePoint(x: 0, y: 0.35), CurvePoint(x: 1, y: 1)]))
        #expect(abs(identity - base) < 4, "identity curve should passthrough: base \(base), got \(identity)")
        #expect(lift > base + 15, "lifted master curve should brighten: base \(base), got \(lift)")
    }

    /// LUT effect: a generated invert .cube file flips the pattern's colors.
    @Test func lutEffectAppliesCubeFile() async throws {
        let cubeURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("invert-\(UUID().uuidString).cube")
        defer { try? FileManager.default.removeItem(at: cubeURL) }
        var cube = "LUT_3D_SIZE 2\n"
        for b in [0.0, 1.0] {
            for g in [0.0, 1.0] {
                for r in [0.0, 1.0] {
                    cube += "\(1 - r) \(1 - g) \(1 - b)\n"
                }
            }
        }
        try cube.write(to: cubeURL, atomically: true, encoding: .utf8)

        let parsed = try #require(LUTLoader.load(path: cubeURL.path))
        #expect(parsed.dimension == 2)

        let renderSize = CompositorFixtures.renderSize
        let videoURL = try await CompositorFixtures.patternVideoURL()
        let urls = ["pattern": videoURL]

        var effect = Effect.make("color.lut", ["intensity": 1])
        effect.params["path"] = EffectParam(string: cubeURL.path)
        var clip = CompositorFixtures.patternClip()
        clip.effects = [effect]
        let tl = CompositorFixtures.timeline([Fixtures.videoTrack(clips: [clip])])
        let result = try await CompositionBuilder.build(
            timeline: tl, resolveURL: { urls[$0] }, renderSize: renderSize
        )
        let generator = AVAssetImageGenerator(asset: result.composition)
        generator.videoComposition = result.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let cg = try await generator.image(at: CMTime(value: 15, timescale: 30)).image
        let bytes = ColorProbeHelpers.srgbBytes(cg, size: renderSize)

        // Pattern TL is red (≈233,0,2) → inverted ≈ cyan (low R, high G/B).
        let o = (45 * Int(renderSize.width) + 80) * 4
        #expect(bytes[o] < 80, "inverted red channel should be low, got \(bytes[o])")
        #expect(bytes[o + 1] > 180 && bytes[o + 2] > 180,
                "inverted G/B should be high, got \(bytes[o + 1]), \(bytes[o + 2])")
    }

    /// Disabled effects must not change the frame; unknown types must not crash.
    @Test func disabledAndUnknownEffectsArePassthrough() async throws {
        let renderSize = CompositorFixtures.renderSize
        let videoURL = try await CompositorFixtures.patternVideoURL()
        let urls = ["pattern": videoURL]

        func frame(_ effects: [Effect]?) async throws -> [UInt8] {
            var clip = CompositorFixtures.patternClip()
            clip.effects = effects
            let tl = CompositorFixtures.timeline([Fixtures.videoTrack(clips: [clip])])
            let result = try await CompositionBuilder.build(
                timeline: tl, resolveURL: { urls[$0] }, renderSize: renderSize
            )
            let generator = AVAssetImageGenerator(asset: result.composition)
            generator.videoComposition = result.videoComposition
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let cg = try await generator.image(at: CMTime(value: 15, timescale: 30)).image
            return ColorProbeHelpers.srgbBytes(cg, size: renderSize)
        }

        var disabled = Effect.make("color.exposure", ["ev": -2])
        disabled.enabled = false
        let base = try await frame(nil)
        let withDisabled = try await frame([disabled])
        let withUnknown = try await frame([Effect.make("future.hologram")])
        #expect(base == withDisabled)
        #expect(base == withUnknown)
    }
}

enum ColorProbeHelpers {
    static func srgbBytes(_ image: CGImage, size: CGSize) -> [UInt8] {
        let w = Int(size.width), h = Int(size.height)
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(
            data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return data
    }
}
