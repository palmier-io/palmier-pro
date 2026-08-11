import AVFoundation
import Testing
@testable import PalmierPro

@Suite("CompositionBuilder.smoothSubdivisions")
struct SmoothSubdivisionsTests {

    @Test func emptyWhenSpanIsZero() {
        #expect(CompositionBuilder.smoothSubdivisions(from: 10, to: 10).isEmpty)
    }

    @Test func emptyWhenSpanIsNegative() {
        // Defensive guard — caller computes b - a from arbitrary kf offsets.
        #expect(CompositionBuilder.smoothSubdivisions(from: 20, to: 10).isEmpty)
    }

    @Test func produces7InteriorPointsAtEvenSpacing() {
        // smoothSegments = 8, span = 80 → 7 interior offsets at 10, 20, ..., 70.
        let result = CompositionBuilder.smoothSubdivisions(from: 0, to: 80)
        #expect(result == [10, 20, 30, 40, 50, 60, 70])
    }

    @Test func interiorPointsAreShiftedByStart() {
        // span 80, start 100 → 110, 120, ..., 170.
        let result = CompositionBuilder.smoothSubdivisions(from: 100, to: 180)
        #expect(result == [110, 120, 130, 140, 150, 160, 170])
    }

    @Test func subdivisionCountIsAtMostSegmentsMinusOne() {
        // Tight spans collapse duplicates after dedupe — count is bounded but may be smaller.
        let result = CompositionBuilder.smoothSubdivisions(from: 0, to: 3)
        #expect(result.count <= CompositionBuilder.smoothSegments - 1)
    }

    @Test func returnsDistinctOffsetsInAscendingOrder() {
        // The function dedupes internally so callers don't have to.
        for (a, b) in [(0, 1), (0, 3), (100, 110), (0, 1000)] {
            let result = CompositionBuilder.smoothSubdivisions(from: a, to: b)
            #expect(Set(result).count == result.count, "duplicates in \(result) for span \(a)..\(b)")
            #expect(result == result.sorted(), "not ascending: \(result)")
        }
    }

    @Test func tightSpansCollapseDuplicateOffsets() {
        // span=1: 7 raw subdivisions round to {0, 1}. After dedupe → 2 distinct offsets.
        let result = CompositionBuilder.smoothSubdivisions(from: 0, to: 1)
        #expect(result == [0, 1])
    }
}

// MARK: - build() validation guard

@Suite("CompositionBuilder.build — validation")
struct CompositionBuildValidationTests {

    private let renderSize = CGSize(width: 1920, height: 1080)
    /// resolveURL should never be invoked when the guard rejects the timeline.
    private let unreachable: @Sendable (String) -> URL? = { _ in
        Issue.record("resolveURL must not be called for invalid timelines")
        return nil
    }

    @Test func zeroFpsThrowsInvalidTimelineError() async {
        var timeline = Fixtures.timeline()
        timeline.fps = 0
        await #expect(throws: CompositionBuilder.InvalidTimelineError.self) {
            _ = try await CompositionBuilder.build(
                timeline: timeline, resolveURL: unreachable, renderSize: renderSize
            )
        }
    }

    @Test func zeroWidthThrowsInvalidTimelineError() async {
        var timeline = Fixtures.timeline()
        timeline.width = 0
        await #expect(throws: CompositionBuilder.InvalidTimelineError.self) {
            _ = try await CompositionBuilder.build(
                timeline: timeline, resolveURL: unreachable, renderSize: renderSize
            )
        }
    }

    @Test func zeroHeightThrowsInvalidTimelineError() async {
        var timeline = Fixtures.timeline()
        timeline.height = 0
        await #expect(throws: CompositionBuilder.InvalidTimelineError.self) {
            _ = try await CompositionBuilder.build(
                timeline: timeline, resolveURL: unreachable, renderSize: renderSize
            )
        }
    }
}

@Suite("CompositionBuilder.buildVisuals — instructions")
struct CompositionBuildVisualInstructionTests {

    @Test func videoCompositionDoesNotOverrideSourceColorimetry() {
        let timeline = Fixtures.timeline(fps: 30, tracks: [])

        let (_, videoComposition) = CompositionBuilder.buildVisuals(
            timeline: timeline,
            trackMappings: [],
            compositionDuration: .zero,
            renderSize: CGSize(width: 320, height: 180)
        )

        #expect(videoComposition.colorPrimaries == nil)
        #expect(videoComposition.colorTransferFunction == nil)
        #expect(videoComposition.colorYCbCrMatrix == nil)
    }

    @Test func textInstructionsPreserveLayerOrderAcrossCaptionBoundaries() {
        let topA = textClip(id: "top-a", start: 0, duration: 10)
        let topB = textClip(id: "top-b", start: 10, duration: 10)
        let bottom = textClip(id: "bottom", start: 0, duration: 20)
        let timeline = Fixtures.timeline(fps: 10, tracks: [
            Fixtures.videoTrack(clips: [topA, topB]),
            Fixtures.videoTrack(clips: [bottom]),
        ])

        let (_, videoComposition) = CompositionBuilder.buildVisuals(
            timeline: timeline,
            trackMappings: [],
            compositionDuration: CMTime(value: 20, timescale: 10),
            renderSize: CGSize(width: 320, height: 180)
        )
        let instructions = videoComposition.instructions.compactMap { $0 as? CompositorInstruction }

        #expect(instructions.count == 2)
        #expect(instructions.map { $0.timeRange.start } == [
            CMTime(value: 0, timescale: 10),
            CMTime(value: 10, timescale: 10),
        ])
        #expect(instructions.map { $0.layers.map(\.clip.id) } == [
            ["bottom", "top-a"],
            ["bottom", "top-b"],
        ])
    }

    private func textClip(id: String, start: Int, duration: Int) -> Clip {
        var clip = Fixtures.clip(id: id, mediaRef: "text-\(id)", mediaType: .text, start: start, duration: duration)
        clip.textContent = id
        return clip
    }
}

@Suite("FrameRenderer — color tags")
struct FrameRendererColorTagTests {

    @Test func propagatesSourceTransferAndGammaTags() throws {
        let source = try pixelBuffer()
        let output = try pixelBuffer()
        CVBufferSetAttachment(source, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(source, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_UseGamma, .shouldPropagate)
        CVBufferSetAttachment(source, kCVImageBufferGammaLevelKey, NSNumber(value: 2.4), .shouldPropagate)
        CVBufferSetAttachment(source, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)

        let clip = Fixtures.clip(id: "clip", mediaRef: "src", start: 0, duration: 1)
        let layer = LayerPlan(source: .track(7), clip: clip, natSize: CGSize(width: 2, height: 2), preferredTransform: .identity)
        let instruction = CompositorInstruction(
            timeRange: CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 30)),
            layers: [layer],
            renderSize: CGSize(width: 2, height: 2),
            fps: 30
        )

        FrameRenderer.render(
            instruction: instruction,
            sourceFrame: { $0 == 7 ? source : nil },
            compositionTime: .zero,
            into: output,
            context: CustomVideoCompositor.ciContext
        )

        #expect(CVBufferCopyAttachment(output, kCVImageBufferColorPrimariesKey, nil) as? String == kCVImageBufferColorPrimaries_ITU_R_709_2 as String)
        #expect(CVBufferCopyAttachment(output, kCVImageBufferCGColorSpaceKey, nil) != nil)
        #expect(CVBufferCopyAttachment(output, kCVImageBufferTransferFunctionKey, nil) as? String == kCVImageBufferTransferFunction_UseGamma as String)
        #expect((CVBufferCopyAttachment(output, kCVImageBufferGammaLevelKey, nil) as? NSNumber)?.doubleValue == 2.4)
        #expect(CVBufferCopyAttachment(output, kCVImageBufferYCbCrMatrixKey, nil) as? String == kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String)
    }

    private func pixelBuffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            nil,
            2,
            2,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferCGImageCompatibilityKey as String: true] as CFDictionary,
            &buffer
        )
        let pixelBuffer = try #require(buffer)
        #expect(status == kCVReturnSuccess)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            memset(base, 255, CVPixelBufferGetDataSize(pixelBuffer))
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        return pixelBuffer
    }
}

// MARK: - build() unreadable-asset resilience

@Suite("CompositionBuilder.build — unreadable assets")
struct CompositionBuildUnreadableAssetTests {

    private let renderSize = CGSize(width: 1920, height: 1080)

    /// Write non-media bytes to a temp .mov so AVFoundation throws "Cannot Open" on loadTracks.
    private func garbageVideoURL() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("garbage-\(UUID().uuidString).mov")
        try Data("not a real movie".utf8).write(to: url)
        return url
    }

    @Test func unreadableClipIsSkippedInsteadOfAbortingRebuild() async throws {
        // Regression: a single clip whose backing file can't be opened must not
        // throw out of build() and blank the whole preview — it should be skipped.
        let badURL = try garbageVideoURL()
        defer { try? FileManager.default.removeItem(at: badURL) }

        let clip = Fixtures.clip(mediaRef: "bad", start: 0, duration: 30)
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])

        // Should NOT throw — the bad clip is skipped and a composition returns.
        let result = try await CompositionBuilder.build(
            timeline: timeline,
            resolveURL: { $0 == "bad" ? badURL : nil },
            renderSize: renderSize
        )
        #expect(result.composition.duration.isValid)
    }
}

@Suite("CompositionBuilder.build — video source timing")
struct CompositionBuildVideoSourceTimingTests {

    @Test func videoClipUsesSourceNaturalTimescaleForInsertedRange() async throws {
        let videoURL = try await FixtureVideo.write(
            scenes: [FixtureVideo.Scene(rgb: (255, 0, 0), seconds: 2)],
            fps: 60,
            size: 64
        )
        defer { try? FileManager.default.removeItem(at: videoURL) }

        let sourceAsset = AVURLAsset(url: videoURL)
        let sourceTrack = try #require(try await sourceAsset.loadTracks(withMediaType: .video).first)
        let sourceTimescale = try await sourceTrack.load(.naturalTimeScale)
        let clip = Fixtures.clip(
            id: "deep-video",
            mediaRef: "video",
            start: 0,
            duration: 30,
            trimStart: 15
        )
        let timeline = Fixtures.timeline(fps: 30, tracks: [
            Fixtures.videoTrack(clips: [clip]),
        ])

        let result = try await CompositionBuilder.build(
            timeline: timeline,
            resolveURL: { $0 == "video" ? videoURL : nil },
            renderSize: CGSize(width: 320, height: 180)
        )

        let videoMapping = try #require(result.trackMappings.first { mapping in
            guard mapping.isVideo, case .timeline(_, let clipIds) = mapping.kind else { return false }
            return clipIds?.contains("deep-video") == true
        })
        let mediaSegment = try #require(videoMapping.compositionTrack.segments.first { !$0.isEmpty })
        #expect(mediaSegment.timeMapping.source.start.timescale == sourceTimescale)
        #expect(mediaSegment.timeMapping.source.duration.timescale == sourceTimescale)
    }
}

// MARK: - audio composition tracks

@Suite("CompositionBuilder.build — audio tracks")
struct CompositionBuildAudioTrackTests {

    @Test func normalAudioClipsShareCompositionTrack() async throws {
        let audioURL = try makeSilentWav(durationSeconds: 3)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let first = Fixtures.clip(id: "a1", mediaRef: "audio", mediaType: .audio, start: 0, duration: 24)
        let second = Fixtures.clip(id: "a2", mediaRef: "audio", mediaType: .audio, start: 24, duration: 24)
        let timeline = Fixtures.timeline(fps: 24, tracks: [
            Fixtures.audioTrack(clips: [first, second]),
        ])

        let result = try await CompositionBuilder.build(
            timeline: timeline,
            resolveURL: { _ in audioURL },
            renderSize: CGSize(width: 320, height: 180)
        )

        let audioMappings = result.trackMappings.filter { !$0.isVideo }
        #expect(audioMappings.count == 1)
        #expect(audioMappings.first.flatMap(clipIds) == ["a1", "a2"])
    }

    @Test func unityAudioClipResetsVolumeAfterMutedClipOnSharedCompositionTrack() async throws {
        let audioURL = try makeSilentWav(durationSeconds: 3)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let muted = Fixtures.clip(
            id: "a1",
            mediaRef: "audio",
            mediaType: .audio,
            start: 0,
            duration: 24,
            volume: 0
        )
        let next = Fixtures.clip(id: "a2", mediaRef: "audio", mediaType: .audio, start: 24, duration: 24)
        let timeline = Fixtures.timeline(fps: 24, tracks: [
            Fixtures.audioTrack(clips: [muted, next]),
        ])

        let result = try await CompositionBuilder.build(
            timeline: timeline,
            resolveURL: { _ in audioURL },
            renderSize: CGSize(width: 320, height: 180)
        )

        let params = try #require(result.audioMix.inputParameters.first)
        let mutedRamp = try #require(volumeRamp(params, atFrame: muted.startFrame, fps: timeline.fps))
        #expect(mutedRamp.start == 0)
        #expect(mutedRamp.end == 0)
        #expect(
            mutedRamp.range == CMTimeRange(
                start: CMTime(value: CMTimeValue(muted.startFrame), timescale: CMTimeScale(timeline.fps)),
                end: CMTime(value: CMTimeValue(muted.endFrame), timescale: CMTimeScale(timeline.fps))
            )
        )

        let nextRamp = try #require(volumeRamp(params, atFrame: next.startFrame, fps: timeline.fps))
        #expect(nextRamp.start == 1)
        #expect(nextRamp.end == 1)
        #expect(
            nextRamp.range == CMTimeRange(
                start: CMTime(value: CMTimeValue(next.startFrame), timescale: CMTimeScale(timeline.fps)),
                end: CMTime(value: CMTimeValue(next.endFrame), timescale: CMTimeScale(timeline.fps))
            )
        )
    }

    @Test func mixedSpeedAudioClipsShareOneCompositionTrack() async throws {
        // One audio queue per composition track: retimed clips must not fan out
        // into dedicated tracks. insertClip scales each clip immediately after
        // inserting it, so mixed speeds are safe on a shared track.
        let audioURL = try makeSilentWav(durationSeconds: 4)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let first = Fixtures.clip(id: "a1", mediaRef: "audio", mediaType: .audio, start: 0, duration: 24)
        let speed = Fixtures.clip(id: "speed", mediaRef: "audio", mediaType: .audio, start: 24, duration: 24, speed: 2)
        let third = Fixtures.clip(id: "a3", mediaRef: "audio", mediaType: .audio, start: 48, duration: 24)
        let timeline = Fixtures.timeline(fps: 24, tracks: [
            Fixtures.audioTrack(clips: [first, speed, third]),
        ])

        let result = try await CompositionBuilder.build(
            timeline: timeline,
            resolveURL: { _ in audioURL },
            renderSize: CGSize(width: 320, height: 180)
        )

        let audioMappings = result.trackMappings.filter { !$0.isVideo }
        #expect(audioMappings.count == 1)
        #expect(audioMappings.first.flatMap(clipIds) == ["a1", "a3", "speed"])

        // The retimed clip occupies exactly [24,48) with 48 source frames scaled in,
        // and the following clip still lands at [48,72).
        let track = try #require(audioMappings.first?.compositionTrack)
        let ts = CMTimeScale(timeline.fps)
        let mappings = track.segments.filter { !$0.isEmpty }.map(\.timeMapping)
        #expect(mappings.count == 3)
        #expect(mappings[1].target == CMTimeRange(start: CMTime(value: 24, timescale: ts), duration: CMTime(value: 24, timescale: ts)))
        #expect(mappings[1].source.duration == CMTime(value: 48, timescale: ts))
        #expect(mappings[2].target.start == CMTime(value: 48, timescale: ts))
    }

    @Test func fractionalSpeedAudioUsesTruncatedSourceFramesForCompositionInsertion() async throws {
        let audioURL = try makeSilentWav(durationSeconds: 4)
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let sourceAsset = AVURLAsset(url: audioURL)
        let sourceTrack = try #require(try await sourceAsset.loadTracks(withMediaType: .audio).first)
        let sourceTimescale = try await sourceTrack.load(.naturalTimeScale)

        let clip = Fixtures.clip(
            id: "short-speed",
            mediaRef: "audio",
            mediaType: .audio,
            start: 60,
            duration: 13,
            speed: 1.0530859375
        )
        #expect(clip.sourceFramesConsumed == 14)

        let timeline = Fixtures.timeline(fps: 24, tracks: [
            Fixtures.audioTrack(clips: [clip]),
        ])

        let result = try await CompositionBuilder.build(
            timeline: timeline,
            resolveURL: { _ in audioURL },
            renderSize: CGSize(width: 320, height: 180)
        )

        let audioMapping = try #require(result.trackMappings.first { !$0.isVideo })
        let mediaSegment = try #require(audioMapping.compositionTrack.segments.first { !$0.isEmpty })
        let expectedSourceSeconds = Double(13) / Double(timeline.fps)
        #expect(abs(mediaSegment.timeMapping.source.duration.seconds - expectedSourceSeconds) <= 1.0 / Double(sourceTimescale))
        #expect(mediaSegment.timeMapping.source.duration.timescale == sourceTimescale)
        #expect(mediaSegment.timeMapping.target.duration == CMTime(value: 13, timescale: 24))
    }

    private func clipIds(_ mapping: TrackMapping) -> Set<String>? {
        guard case .timeline(_, let ids) = mapping.kind else { return nil }
        return ids
    }

    private func volumeRamp(
        _ params: AVAudioMixInputParameters,
        atFrame frame: Int,
        fps: Int
    ) -> (start: Float, end: Float, range: CMTimeRange)? {
        var start: Float = -1
        var end: Float = -1
        var range = CMTimeRange()
        let found = params.getVolumeRamp(
            for: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)),
            startVolume: &start,
            endVolume: &end,
            timeRange: &range
        )
        return found ? (start, end, range) : nil
    }

    private func makeSilentWav(durationSeconds: Double) throws -> URL {
        let sampleRate = 44_100
        let channels = 1
        let bitsPerSample = 16
        let sampleCount = Int(durationSeconds * Double(sampleRate))
        let dataSize = sampleCount * channels * bitsPerSample / 8

        var data = Data()
        data.append(contentsOf: "RIFF".utf8)
        appendLE(UInt32(36 + dataSize), to: &data)
        data.append(contentsOf: "WAVEfmt ".utf8)
        appendLE(UInt32(16), to: &data)
        appendLE(UInt16(1), to: &data)
        appendLE(UInt16(channels), to: &data)
        appendLE(UInt32(sampleRate), to: &data)
        appendLE(UInt32(sampleRate * channels * bitsPerSample / 8), to: &data)
        appendLE(UInt16(channels * bitsPerSample / 8), to: &data)
        appendLE(UInt16(bitsPerSample), to: &data)
        data.append(contentsOf: "data".utf8)
        appendLE(UInt32(dataSize), to: &data)
        data.append(Data(repeating: 0, count: dataSize))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("silent-\(UUID().uuidString).wav")
        try data.write(to: url)
        return url
    }

    private func appendLE<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
}

// MARK: - affineTransform

@Suite("CompositionBuilder.affineTransform")
struct AffineTransformTests {

    private let render = CGSize(width: 1920, height: 1080)
    private let nat = CGSize(width: 1920, height: 1080)

    private func approxEqual(_ a: CGAffineTransform, _ b: CGAffineTransform, eps: CGFloat = 1e-9) -> Bool {
        abs(a.a - b.a) < eps && abs(a.b - b.b) < eps &&
        abs(a.c - b.c) < eps && abs(a.d - b.d) < eps &&
        abs(a.tx - b.tx) < eps && abs(a.ty - b.ty) < eps
    }

    @Test func defaultTransformWithMatchingSizesIsIdentity() {
        // Default Transform fills the canvas at native size — should produce the identity matrix.
        let result = CompositionBuilder.affineTransform(for: Transform(), natSize: nat, renderSize: render)
        #expect(approxEqual(result, .identity))
    }

    @Test func halfSizeAtCenterScalesAndTranslates() {
        // width=height=0.5 centered → sx=sy=0.5; topLeft=(0.25,0.25); tx=0.25*1920=480; ty=270.
        let t = Transform(centerX: 0.5, centerY: 0.5, width: 0.5, height: 0.5)
        let result = CompositionBuilder.affineTransform(for: t, natSize: nat, renderSize: render)
        let expected = CGAffineTransform(scaleX: 0.5, y: 0.5)
            .concatenating(CGAffineTransform(translationX: 480, y: 270))
        #expect(approxEqual(result, expected))
    }

    @Test func renderUpscalesBeyondNatSize() {
        // Source 1920×1080, render 3840×2160 → sx=sy=2 for a default fill transform.
        let bigRender = CGSize(width: 3840, height: 2160)
        let result = CompositionBuilder.affineTransform(for: Transform(), natSize: nat, renderSize: bigRender)
        #expect(abs(result.a - 2) < 1e-9)
        #expect(abs(result.d - 2) < 1e-9)
        #expect(result.tx == 0)
        #expect(result.ty == 0)
    }

    @Test func flipHorizontalNegatesXScaleAndShiftsTx() {
        // flipH=true → sx = -1; tx becomes (tl.x + width) * renderW = 1 * 1920 = 1920.
        // Net effect: mirror around the vertical center of the canvas.
        var t = Transform()
        t.flipHorizontal = true
        let result = CompositionBuilder.affineTransform(for: t, natSize: nat, renderSize: render)
        #expect(abs(result.a - (-1)) < 1e-9)
        #expect(abs(result.d - 1) < 1e-9)
        #expect(abs(result.tx - 1920) < 1e-9)
        #expect(result.ty == 0)
    }

    @Test func flipVerticalNegatesYScaleAndShiftsTy() {
        var t = Transform()
        t.flipVertical = true
        let result = CompositionBuilder.affineTransform(for: t, natSize: nat, renderSize: render)
        #expect(abs(result.a - 1) < 1e-9)
        #expect(abs(result.d - (-1)) < 1e-9)
        #expect(result.tx == 0)
        #expect(abs(result.ty - 1080) < 1e-9)
    }

    @Test func rotationAt180FlipsBothScales() {
        // A 180° rotation about the canvas center is equivalent to scaling both axes by -1
        // and translating by (renderW, renderH). Verifies that the rotation block composes
        // correctly with the prior placed transform.
        var t = Transform()
        t.rotation = 180
        let result = CompositionBuilder.affineTransform(for: t, natSize: nat, renderSize: render)
        let expected = CGAffineTransform(scaleX: -1, y: -1)
            .concatenating(CGAffineTransform(translationX: 1920, y: 1080))
        #expect(approxEqual(result, expected, eps: 1e-6))
    }

    @Test func zeroRotationSkipsRotationBlockEntirely() {
        // Same input minus the rotation should give the same matrix — the `guard rotation != 0`
        // path. Pinning down that the rotation block is genuinely a no-op at 0.
        var rotated = Transform()
        rotated.rotation = 0
        let plain = Transform()
        let a = CompositionBuilder.affineTransform(for: rotated, natSize: nat, renderSize: render)
        let b = CompositionBuilder.affineTransform(for: plain, natSize: nat, renderSize: render)
        #expect(approxEqual(a, b))
    }
}

// MARK: - Adversarial

@Suite("CompositionBuilder — adversarial")
struct CompositionBuilderAdversarialTests {

    @Test func affineTransformWithZeroNatSizeProducesInfiniteOrNaNScale() {
        // natSize=0 means scale = renderSize/0 = ∞ (or NaN if renderSize is also 0).
        // Caller must validate natSize > 0; we document the math here rather than crash.
        let result = CompositionBuilder.affineTransform(
            for: Transform(),
            natSize: CGSize(width: 0, height: 0),
            renderSize: CGSize(width: 1920, height: 1080)
        )
        #expect(result.a.isInfinite || result.a.isNaN)
    }
}
