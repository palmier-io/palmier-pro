import AVFoundation
import Foundation

actor ProjectThumbnailFrameRenderer {
    typealias Completion = @Sendable (Result<CGImage, Error>) async -> Void

    struct Operations: Sendable {
        let prepare: @Sendable (isolated ProjectThumbnailFrameRenderer) async throws -> Void
        let generate: @Sendable (isolated ProjectThumbnailFrameRenderer, @escaping Completion) -> Void
        let cancel: @Sendable (isolated ProjectThumbnailFrameRenderer) -> Void

        static let native = Operations(
            prepare: { renderer in try await renderer.prepareNativeGenerator() },
            generate: { renderer, completion in renderer.generateNativeFrame(completion: completion) },
            cancel: { renderer in renderer.cancelNativeRequests() }
        )
    }

    enum RenderError: Error, Equatable {
        case invalidRequest
        case alreadyStarted
        case noVideoTrack
        case imageUnavailable
    }

    private enum Phase {
        case idle, preparing, generating, finished
    }

    private let url: URL
    private let time: CMTime
    private let maxPixelSize: Int
    private let operations: Operations
    private var phase = Phase.idle
    private var cancellationRequested = false
    private var asset: AVURLAsset?
    private var generator: AVAssetImageGenerator?
    private var continuation: CheckedContinuation<CGImage, Error>?

    init(url: URL, time: CMTime, maxPixelSize: Int, operations: Operations = .native) {
        self.url = url
        self.time = time
        self.maxPixelSize = maxPixelSize
        self.operations = operations
    }

    func render() async throws -> CGImage {
        guard phase == .idle else { throw RenderError.alreadyStarted }
        phase = .preparing
        do {
            guard url.isFileURL, time.isNumeric, time.timescale > 0, time >= .zero,
                  maxPixelSize > 0, maxPixelSize <= Int(Int32.max) else { throw RenderError.invalidRequest }
            try Task.checkCancellation()
            let image = try await withTaskCancellationHandler {
                try await operations.prepare(self)
                try Task.checkCancellation()
                guard !cancellationRequested else { throw CancellationError() }
                return try await withCheckedThrowingContinuation { continuation in
                    self.continuation = continuation
                    phase = .generating
                    operations.generate(self) { [self] result in
                        await finish(result)
                    }
                }
            } onCancel: {
                Task { await self.cancel() }
            }
            try Task.checkCancellation()
            return image
        } catch {
            phase = .finished
            generator = nil
            asset = nil
            throw error
        }
    }

    private func prepareNativeGenerator() async throws {
        let asset = AVURLAsset(url: url)
        self.asset = asset
        let tracks = try await asset.loadTracks(withMediaType: .video)
        try Task.checkCancellation()
        guard !cancellationRequested else { throw CancellationError() }
        guard !tracks.isEmpty else { throw RenderError.noVideoTrack }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        generator.appliesPreferredTrackTransform = true
        self.generator = generator
    }

    private func generateNativeFrame(completion: @escaping Completion) {
        guard let generator else {
            Task { await completion(.failure(RenderError.imageUnavailable)) }
            return
        }
        generator.generateCGImageAsynchronously(for: time) { image, _, error in
            let result: Result<CGImage, Error>
            if let error { result = .failure(error) }
            else if let image { result = .success(image) }
            else { result = .failure(RenderError.imageUnavailable) }
            Task { await completion(result) }
        }
    }

    private func cancel() {
        guard phase == .preparing || phase == .generating else { return }
        cancellationRequested = true
        operations.cancel(self)
    }

    private func cancelNativeRequests() {
        asset?.cancelLoading()
        generator?.cancelAllCGImageGeneration()
    }

    private func finish(_ result: Result<CGImage, Error>) {
        guard phase == .generating, let continuation else { return }
        self.continuation = nil
        phase = .finished
        generator = nil
        asset = nil
        if cancellationRequested { continuation.resume(throwing: CancellationError()) }
        else { continuation.resume(with: result) }
    }
}
