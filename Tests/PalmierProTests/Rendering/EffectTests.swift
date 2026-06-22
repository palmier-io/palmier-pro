import AVFoundation
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
    @Test func masterCurveIsLumaPreservingChroma() throws {
        let curve = GradeCurve(master: [CurvePoint(x: 0, y: 0.2), CurvePoint(x: 1, y: 1)])
        let n = 17
        let cube = try #require(curve.cubeData(dimension: n))
        let f = cube.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }

        // A mid, saturated voxel that won't clip after the lift.
        let (ri, gi, bi) = (10, 6, 2)
        let idx = ((bi * n + gi) * n + ri) * 4
        let (outR, outG, outB) = (Double(f[idx]), Double(f[idx + 1]), Double(f[idx + 2]))
        let (inR, inG, inB) = (Double(ri) / 16, Double(gi) / 16, Double(bi) / 16)

        #expect(abs(outR / outG - inR / inG) < 0.02, "R:G ratio should hold (chroma preserved)")
        #expect(abs(outR / outB - inR / inB) < 0.02, "R:B ratio should hold (chroma preserved)")
        let inLuma = 0.2126 * inR + 0.7152 * inG + 0.0722 * inB
        let outLuma = 0.2126 * outR + 0.7152 * outG + 0.0722 * outB
        #expect(outLuma > inLuma + 0.05, "lifted luma curve should raise luminance")
    }

    @Test func curveCubePacksRGBAWithRedFastest() throws {
        let curve = GradeCurve(
            red: [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 0.25)],
            green: [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 0.5)],
            blue: [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 0.75)]
        )
        let n = 17
        let cube = try #require(curve.cubeData(dimension: n))
        let f = cube.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let (ri, gi, bi) = (3, 5, 7)
        let idx = ((bi * n + gi) * n + ri) * 4

        #expect(abs(Double(f[idx]) - Double(ri) / Double(n - 1) * 0.25) < 0.0001)
        #expect(abs(Double(f[idx + 1]) - Double(gi) / Double(n - 1) * 0.5) < 0.0001)
        #expect(abs(Double(f[idx + 2]) - Double(bi) / Double(n - 1) * 0.75) < 0.0001)
        #expect(f[idx + 3] == 1)
    }

    @Test func colorWheelCubePacksRGBAWithRedFastest() throws {
        let values = [
            "lift_x": 0.0, "lift_y": 0.0, "lift_m": 0.0,
            "gamma_x": 0.0, "gamma_y": 0.0, "gamma_m": 1.0,
            "gain_x": 0.0, "gain_y": 0.0, "gain_m": 0.5,
        ]
        let cube = try #require(ColorWheels.cube(for: ResolvedEffectParams(values: values, strings: [:])))
        let f = cube.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let n = cube.dimension
        let (ri, gi, bi) = (3, 5, 7)
        let idx = ((bi * n + gi) * n + ri) * 4

        #expect(abs(Double(f[idx]) - Double(ri) / Double(n - 1) * 0.5) < 0.0001)
        #expect(abs(Double(f[idx + 1]) - Double(gi) / Double(n - 1) * 0.5) < 0.0001)
        #expect(abs(Double(f[idx + 2]) - Double(bi) / Double(n - 1) * 0.5) < 0.0001)
        #expect(f[idx + 3] == 1)
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
        nonisolated(unsafe) let urls = ["midtone": videoURL]

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
        nonisolated(unsafe) let urls = ["midtone": videoURL]

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
            "stylize.vignette": ["intensity": 2, "radius": 0.5],
            "stylize.glow": ["intensity": 1, "radius": 20],
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
        // color.curves carries a JSON curve, not Double params — covered by its own test.
        let base = try await frame(nil)
        for descriptor in EffectRegistry.all where descriptor.resourceKey == nil && descriptor.id != "color.curves" {
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
        nonisolated(unsafe) let urls = ["midtone": videoURL]

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
        nonisolated(unsafe) let urls = ["pattern": videoURL]

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
        nonisolated(unsafe) let urls = ["pattern": videoURL]

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
