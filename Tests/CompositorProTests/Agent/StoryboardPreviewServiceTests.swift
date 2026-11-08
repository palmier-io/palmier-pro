import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import CompositorPro

@Suite("Storyboard preview rendering")
struct StoryboardPreviewServiceTests {
    @Test func imageScenesRenderInOrderAtBoundedResolutionWithoutAudio() async throws {
        try await Self.withDirectory { directory in
            let red = try await Self.image(in: directory, name: "red.png", red: 1, blue: 0)
            let blue = try await Self.image(in: directory, name: "blue.png", red: 0, blue: 1)
            let snapshot = try await Self.snapshot(urls: [red, blue], type: .image)
            try await Self.withResult(snapshot) { result in
                #expect(result.key == snapshot.key)
                #expect(result.frameCount == 20)
                #expect(result.fps == 10)
                #expect(result.width == 1_024)
                #expect(result.height == 576)
                let first = try await Self.pixel(result.url, seconds: 0.5)
                let second = try await Self.pixel(result.url, seconds: 1.5)
                #expect(first.red > 0.8 && first.blue < 0.2)
                #expect(second.blue > 0.8 && second.red < 0.2)
                try await Self.verifyOutput(result, audio: false)
            }
        }
    }

    @Test func replacingImageAtSameURLDoesNotReuseOldStillVideo() async throws {
        try await Self.withDirectory { directory in
            let url = try await Self.image(in: directory, name: "source.png", red: 1, blue: 0)
            let first = try await Self.snapshot(urls: [url], type: .image)
            try await Self.withResult(first) { result in
                let pixel = try await Self.pixel(result.url, seconds: 0.5)
                #expect(pixel.red > 0.8)
            }
            _ = try await Self.image(in: directory, name: "source.png", red: 0, blue: 1)
            let second = try await Self.snapshot(urls: [url], type: .image)
            #expect(first.key != second.key)
            try await Self.withResult(second) { result in
                let pixel = try await Self.pixel(result.url, seconds: 0.5)
                #expect(pixel.blue > 0.8)
            }
        }
    }

    @Test func sourceIdentityMismatchFailsBeforeExport() async throws {
        try await Self.withDirectory { directory in
            let url = try await Self.image(in: directory, name: "source.png", red: 1, blue: 0)
            let prepared = try await Self.snapshot(urls: [url], type: .image)
            _ = try await Self.image(in: directory, name: "source.png", red: 0, blue: 1)
            await #expect(throws: StoryboardPreviewError.sourceMismatch) {
                _ = try await StoryboardPreviewService.render(prepared)
            }
        }
    }

    @Test func missingSourceFailsBeforeExport() async throws {
        try await Self.withDirectory { directory in
            let url = try await Self.image(in: directory, name: "source.png", red: 1, blue: 0)
            let prepared = try await Self.snapshot(urls: [url], type: .image)
            try await Self.removeFile(url)
            await #expect(throws: StoryboardPreviewError.unavailableSource) {
                _ = try await StoryboardPreviewService.render(prepared)
            }
        }
    }

    @Test func videoUsesSelectedSourceSpanAndExactFrameDuration() async throws {
        try await Self.withDirectory { directory in
            let video = try await Self.coloredVideo(in: directory)
            let prepared = try await Self.snapshot(urls: [video.url], type: .video, duration: video.duration,
                frameCount: 20, sourceStart: 1, sourceEnd: 3)
            #expect(prepared.timeline.tracks[0].clips[0].trimStartFrame == 10)
            try await Self.withResult(prepared) { result in
                #expect(result.frameCount == 20)
                let frames = try await Self.videoFrames(result.url)
                #expect(frames.map(\.time) == (0..<20).map { CMTime(value: Int64($0), timescale: 10) })
                #expect(frames.prefix(10).allSatisfy { $0.blue > 0.8 && $0.red < 0.2 && $0.green < 0.2 })
                #expect(frames.suffix(10).allSatisfy { $0.green > 0.8 && $0.red < 0.2 && $0.blue < 0.2 })
                try await Self.verifyOutput(result, audio: false)
            }
        }
    }

    @Test func quantizedSourceTrimAndDurationPreserveOneCompleteTimelineFrame() async throws {
        try await Self.withDirectory { directory in
            let video = try await Self.coloredVideo(in: directory, sourceTimescale: 1_000)
            let asset = AVURLAsset(url: video.url)
            let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
            #expect(try await track.load(.naturalTimeScale) == 1_000)
            let prepared = try await Self.snapshot(urls: [video.url], type: .video, duration: video.duration,
                fps: 30, frameCount: 1, sourceStart: 1.0 / 30, sourceEnd: 2.0 / 30)
            let clip = try #require(prepared.timeline.tracks[0].clips.first)
            #expect(clip.trimStartFrame == 1)
            let range = CompositionSourceTiming.requestedRange(for: clip, timeMap: clip.timeMap,
                timescale: 30, sourceTimescale: 1_000)
            #expect(range == CMTimeRange(start: CMTime(value: 33, timescale: 1_000),
                duration: CMTime(value: 33, timescale: 1_000)))
            try await Self.withResult(prepared) { result in
                let frames = try await Self.videoFrames(result.url)
                #expect(frames.count == 1)
                let frame = try #require(frames.first)
                #expect(frame.time == .zero)
                #expect(frame.blue > 0.8 && frame.red < 0.2 && frame.green < 0.2)
                try await Self.verifyOutput(result, audio: false)
            }
        }
    }

    @Test func shortSourceIsNotStretchedAtUnitSpeed() async throws {
        try await Self.withDirectory { directory in
            let video = try await Self.coloredVideo(in: directory, sourceTimescale: 1_000)
            let clip = Clip(id: "short-source", mediaRef: "video", mediaType: .video, sourceClipType: .video,
                startFrame: 0, durationFrames: 2, trimStartFrame: 89)
            let timeline = Timeline(fps: 30, width: 32, height: 32, tracks: [Track(type: .video, clips: [clip])])
            let built = try await CompositionBuilder.build(timeline: timeline, resolveURL: { _ in video.url },
                renderSize: CGSize(width: 32, height: 32))
            let mapping = try #require(built.trackMappings.first {
                if case .timeline = $0.kind { return true }
                return false
            })
            let segments = try #require(mapping.compositionTrack.segments)
            let segment = try #require(segments.first(where: { !$0.isEmpty }))
            #expect(segment.timeMapping.source.start == CMTime(value: 2_966, timescale: 1_000))
            #expect(segment.timeMapping.source.duration == CMTime(value: 34, timescale: 1_000))
            #expect(segment.timeMapping.target.duration == segment.timeMapping.source.duration)
            #expect(segment.timeMapping.target.duration != CMTime(value: 2, timescale: 30))
        }
    }

    @Test(arguments: [ClipType.image, .video])
    func requestedSourceRangePreservesImageTrimClamping(type: ClipType) {
        let clip = Clip(mediaRef: "source", mediaType: type, sourceClipType: type, startFrame: 0,
            durationFrames: 1, trimStartFrame: -1)
        let range = CompositionSourceTiming.requestedRange(for: clip, timeMap: clip.timeMap,
            timescale: 30, sourceTimescale: 1_000)
        #expect(range.start == CMTime(value: type == .image ? 0 : -33, timescale: 1_000))
        #expect(range.duration == CMTime(value: 33, timescale: 1_000))
    }

    @Test func actualVideoDurationRejectsOptimisticManifestSpan() async throws {
        try await Self.withDirectory { directory in
            let video = try await StoryboardTimingFixtures.video(in: directory)
            let prepared = try await Self.snapshot(urls: [video.url], type: .video, duration: 10,
                frameCount: 20, sourceStart: 4, sourceEnd: 6)
            await #expect(throws: StoryboardPreviewError.sourceMismatch) {
                _ = try await StoryboardPreviewService.render(prepared)
            }
        }
    }

    @Test func measuredNarrationIsIncludedWithFullFrameRange() async throws {
        try await Self.withDirectory { directory in
            let url = try await Self.image(in: directory, name: "source.png", red: 1, blue: 0)
            let narration = try await Self.audio(in: directory)
            let prepared = try await Self.snapshot(urls: [url], type: .image, frameCount: 20, narration: narration)
            #expect(prepared.measured)
            try await Self.withResult(prepared) { result in
                try await Self.verifyOutput(result, audio: true)
                let audio = try await Self.audioSamples(result.url)
                #expect(audio.count == 96_000)
                #expect(audio.firstTime == .zero)
                #expect(audio.endTime == CMTime(value: 2, timescale: 1))
                #expect(audio.rms > 0.2 && audio.rms < 0.4)
                #expect(audio.positiveCrossings >= 875 && audio.positiveCrossings <= 885)
            }
        }
    }

    @Test func measuredNarrationRequiresFingerprintEvenWithoutExpectedInputID() async throws {
        try await Self.withDirectory { directory in
            let url = try await Self.image(in: directory, name: "source.png", red: 1, blue: 0)
            let narration = try await Self.audio(in: directory)
            let prepared = try await Self.snapshot(urls: [url], type: .image, frameCount: 20, narration: narration)
            var plan = prepared.plan
            plan.narrationTiming?.sourceFingerprint = String(repeating: "f", count: 64)
            let sources = prepared.sources.map {
                StoryboardPreviewSnapshot.Source(mediaRef: $0.mediaRef, url: $0.url, type: $0.type,
                    expectedInputId: $0.type == .audio ? nil : $0.expectedInputId, duration: $0.duration)
            }
            let mismatched = StoryboardPreviewSnapshot(plan: plan, report: prepared.report,
                timeline: prepared.timeline, sources: sources, key: prepared.key, measured: true)
            await #expect(throws: StoryboardPreviewError.sourceMismatch) {
                _ = try await StoryboardPreviewService.render(mismatched)
            }
        }
    }

    @Test func cancellationBeforeStartDoesNotConsumeRenderPermit() async throws {
        try await Self.withDirectory { directory in
            let url = try await Self.image(in: directory, name: "source.png", red: 1, blue: 0)
            let prepared = try await Self.snapshot(urls: [url], type: .image)
            let gate = PreviewStartGate()
            let task = Task {
                await gate.hold()
                return try await StoryboardPreviewService.render(prepared)
            }
            await gate.waitUntilHeld()
            task.cancel()
            await gate.release()
            await #expect(throws: CancellationError.self) { _ = try await task.value }
            try await Self.withResult(prepared) { result in
                try await Self.verifyOutput(result, audio: false)
            }
        }
    }

    @MainActor
    @Test func renderDoesNotMutateEditorTimelineApprovalOrUndo() async throws {
        let directory = try await Self.makeDirectory()
        do {
            let url = try await Self.image(in: directory, name: "source.png", red: 1, blue: 0)
            let prepared = try await Self.snapshot(urls: [url], type: .image)
            let harness = ToolHarness()
            var plan = prepared.plan
            plan.timelineId = harness.editor.activeTimelineId
            try harness.editor.changeEditPlans(creates: [plan], actionName: "Create")
            let undo = UndoManager()
            harness.editor.undo.attach(undo)
            let baseline = harness.editor.editPlans
            let timeline = harness.editor.timeline
            try await Self.withResult(prepared) { _ in }
            #expect(harness.editor.editPlans == baseline)
            #expect(harness.editor.editPlan(id: plan.id)?.productionRun == nil)
            #expect(harness.editor.timeline == timeline)
            #expect(!undo.canUndo)
            try await Self.removeFile(directory)
        } catch {
            try await Self.removeFile(directory)
            throw error
        }
    }

    @concurrent
    private static func snapshot(urls: [URL], type: ClipType, duration: Double = 0, fps: Int = 10, frameCount: Int = 10,
                                 sourceStart: Double? = nil, sourceEnd: Double? = nil,
                                 narration: URL? = nil) async throws -> StoryboardPreviewSnapshot {
        var manifest = MediaManifest()
        var shots: [EditPlanShot] = []
        var beats: [ScriptBeat] = []
        for (index, url) in urls.enumerated() {
            let ref = "preview:media/\(index)"
            let beat = "beat-\(index)"
            let identity = try await MediaInputIdentityService.shared.identify(url, force: true)
            manifest.entries.append(MediaManifestEntry(id: ref, name: "Visual", type: type,
                source: .external(absolutePath: url.path), duration: duration, inputIdentity: identity))
            shots.append(EditPlanShot(id: "scene-\(index)", title: "Scene", startFrame: index * frameCount,
                endFrame: (index + 1) * frameCount, mediaRef: ref, sourceStartSeconds: sourceStart,
                sourceEndSeconds: sourceEnd, narrationLink: .init(firstBeatId: beat, lastBeatId: beat)))
            beats.append(ScriptBeat(beatId: beat, text: "Narration.", purpose: "Explain"))
        }
        var plan = EditPlan(name: "Preview", timelineId: "timeline", fps: fps, width: 1_920, height: 1_080,
            shots: shots, scriptBeats: beats)
        if let narration {
            let identity = try await MediaInputIdentityService.shared.identify(narration, force: true)
            manifest.entries.append(MediaManifestEntry(id: "narration", name: "Narration", type: .audio,
                source: .external(absolutePath: narration.path), duration: 2, inputIdentity: identity))
            plan.narrationIntent = NarrationIntent(startFrame: 0)
            plan.narration = NarrationSource(mediaRef: "narration")
            plan.narrationTiming = NarrationTiming(revision: try #require(plan.narrationRevision),
                sourceFingerprint: identity.contentSHA256, duration: try NarrationTime(CMTime(value: 2, timescale: 1)),
                anchors: [.init(beatId: "beat-0", speechStart: try NarrationTime(.zero),
                    speechEnd: try NarrationTime(CMTime(value: 1, timescale: 1)))], unresolvedBeatIds: [])
        }
        return try await StoryboardPreviewSnapshot.make(plan: plan, manifest: manifest, projectURL: nil)
    }

    @concurrent
    private static func image(in directory: URL, name: String, red: CGFloat, blue: CGFloat) async throws -> URL {
        let context = try #require(CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 256,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: red, green: 0, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
        let image = try #require(context.makeImage())
        let url = directory.appendingPathComponent(name)
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        let properties = [kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGComment: UUID().uuidString]] as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return url
    }

    @concurrent
    private static func coloredVideo(in directory: URL, sourceTimescale: CMTimeScale = 30) async throws -> (url: URL, duration: Double) {
        let url = directory.appendingPathComponent("colored-source.mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 32, AVVideoHeightKey: 32,
        ])
        input.mediaTimeScale = sourceTimescale
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 32, kCVPixelBufferHeightKey as String: 32,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        do {
            let pool = try #require(adaptor.pixelBufferPool)
            for frame in 0..<90 {
                try Task.checkCancellation()
                while !input.isReadyForMoreMediaData {
                    guard writer.status == .writing else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
                    try await Task.sleep(for: .milliseconds(1))
                }
                var buffer: CVPixelBuffer?
                guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess else {
                    throw CocoaError(.fileWriteUnknown)
                }
                let pixelBuffer = try #require(buffer)
                CVPixelBufferLockBaseAddress(pixelBuffer, [])
                do {
                    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
                    let context = try #require(CGContext(data: CVPixelBufferGetBaseAddress(pixelBuffer),
                        width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
                    let blue = frame == 1 || (30..<60).contains(frame)
                    let green = frame >= 60
                    context.setFillColor(CGColor(red: blue || green ? 0 : 1, green: green ? 1 : 0, blue: blue ? 1 : 0, alpha: 1))
                    context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
                }
                guard adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else {
                    throw writer.error ?? CocoaError(.fileWriteUnknown)
                }
            }
            writer.endSession(atSourceTime: CMTime(value: 3, timescale: 1))
            input.markAsFinished()
            await writer.finishWriting()
            guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
            let duration = try await AVURLAsset(url: url).load(.duration)
            #expect(duration == CMTime(value: 3, timescale: 1))
            return (url, duration.seconds)
        } catch {
            writer.cancelWriting()
            throw error
        }
    }

    @concurrent
    private static func audio(in directory: URL) async throws -> URL {
        let url = directory.appendingPathComponent("narration.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_000))
        buffer.frameLength = 96_000
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<Int(buffer.frameLength) {
            samples[index] = 0.4 * sin(2 * .pi * 440 * Float(index) / 48_000)
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    @concurrent
    private static func pixel(_ url: URL, seconds: Double) async throws -> (red: Double, blue: Double) {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.maximumSize = CGSize(width: 32, height: 32)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 10)).image
        let context = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return (Double(bytes[0]) / 255, Double(bytes[2]) / 255)
    }

    private struct VideoFrame: Sendable {
        let time: CMTime
        let red: Double
        let green: Double
        let blue: Double
    }

    @concurrent
    private static func videoFrames(_ url: URL) async throws -> [VideoFrame] {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        let provider = reader.outputProvider(for: output)
        try reader.start()
        defer { reader.cancelReading() }
        var frames: [VideoFrame] = []
        while let payload = try await provider.next() {
            try Task.checkCancellation()
            let frame = try payload.withUnsafeSampleBuffer { sample in
                let buffer = try #require(CMSampleBufferGetImageBuffer(sample))
                CVPixelBufferLockBaseAddress(buffer, .readOnly)
                defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
                let bytes = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
                let offset = (CVPixelBufferGetHeight(buffer) / 2) * CVPixelBufferGetBytesPerRow(buffer)
                    + (CVPixelBufferGetWidth(buffer) / 2) * 4
                return VideoFrame(time: CMSampleBufferGetPresentationTimeStamp(sample),
                    red: Double(bytes[offset + 2]) / 255, green: Double(bytes[offset + 1]) / 255, blue: Double(bytes[offset]) / 255)
            }
            frames.append(frame)
        }
        #expect(reader.status == .completed)
        return frames
    }

    private struct AudioSamples: Sendable {
        let count: Int
        let firstTime: CMTime
        let endTime: CMTime
        let rms: Double
        let positiveCrossings: Int
    }

    @concurrent
    private static func audioSamples(_ url: URL) async throws -> AudioSamples {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: true,
        ])
        let provider = reader.outputProvider(for: output)
        try reader.start()
        defer { reader.cancelReading() }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        var count = 0
        var firstTime: CMTime?
        var endTime = CMTime.zero
        var sumSquares = 0.0
        var previous: Float?
        var positiveCrossings = 0
        while let payload = try await provider.next() {
            try Task.checkCancellation()
            try payload.withUnsafeSampleBuffer { sample in
                let time = CMSampleBufferGetPresentationTimeStamp(sample)
                let sampleCount = CMSampleBufferGetNumSamples(sample)
                try #require(sampleCount > 0)
                if let firstTime { #expect(time == endTime && firstTime == .zero) }
                else { firstTime = time }
                let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleCount)))
                buffer.frameLength = AVAudioFrameCount(sampleCount)
                try #require(CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(sampleCount),
                    into: buffer.mutableAudioBufferList) == noErr)
                let samples = try #require(buffer.floatChannelData?[0])
                for index in 0..<sampleCount {
                    let value = samples[index]
                    sumSquares += Double(value) * Double(value)
                    if let previous, previous <= 0, value > 0 { positiveCrossings += 1 }
                    previous = value
                }
                count += sampleCount
                endTime = time + CMTime(value: Int64(sampleCount), timescale: 48_000)
            }
        }
        #expect(reader.status == .completed)
        return AudioSamples(count: count, firstTime: try #require(firstTime), endTime: endTime,
            rms: sqrt(sumSquares / Double(max(1, count))), positiveCrossings: positiveCrossings)
    }

    @concurrent
    private static func verifyOutput(_ result: StoryboardPreviewResult, audio: Bool) async throws {
        let asset = AVURLAsset(url: result.url)
        let duration = CMTime(value: Int64(result.frameCount), timescale: Int32(result.fps))
        #expect(try await asset.load(.duration) == duration)
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        #expect(try await video.load(.timeRange) == CMTimeRange(start: .zero, duration: duration))
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        #expect(tracks.isEmpty == !audio)
        if audio {
            let track = try #require(tracks.first)
            #expect(try await track.load(.timeRange) == CMTimeRange(start: .zero, duration: duration))
        }
    }

    @concurrent
    private static func withResult(_ snapshot: StoryboardPreviewSnapshot,
                                   operation: @Sendable (StoryboardPreviewResult) async throws -> Void) async throws {
        let result = try await StoryboardPreviewService.render(snapshot)
        do {
            try await operation(result)
            try await StoryboardPreviewService.remove(result)
            #expect(!FileManager.default.fileExists(atPath: result.url.path))
            try await StoryboardPreviewService.remove(result)
        } catch {
            try await StoryboardPreviewService.remove(result)
            throw error
        }
    }

    @concurrent
    private static func withDirectory(_ operation: @Sendable (URL) async throws -> Void) async throws {
        let directory = try await makeDirectory()
        do {
            try await operation(directory)
            try FileManager.default.removeItem(at: directory)
        } catch {
            try FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    @concurrent
    private static func makeDirectory() async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("StoryboardPreviewTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @concurrent
    private static func removeFile(_ url: URL) async throws {
        try FileManager.default.removeItem(at: url)
    }
}

private actor PreviewStartGate {
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Never>?

    func hold() async {
        await withCheckedContinuation {
            continuation = $0
            held = true
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        }
    }

    func waitUntilHeld() async {
        if held { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
