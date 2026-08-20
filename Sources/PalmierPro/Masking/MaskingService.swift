import AVFoundation
import Foundation

actor MaskingService {
    static let shared = MaskingService()
    static let maxSegmentLongSide = 1920

    struct Request: Sendable {
        let maskId: String
        let mediaRef: String
        let seed: MaskSeed
        let trim: TrimmedSource
        let projectId: String?
    }

    struct StagedTrack: Sendable {
        let track: MaskTrack
        let matteURL: URL
    }

    enum ServiceError: LocalizedError {
        case emptyRange
        case invalidPayload

        var errorDescription: String? {
            switch self {
            case .emptyRange: "The clip has no visible frames to track."
            case .invalidPayload: "The mask result was invalid."
            }
        }
    }

    func track(_ request: Request) async throws -> StagedTrack {
        guard request.trim.sourceFramesConsumed > 0 else { throw ServiceError.emptyRange }

        let segmentURL = try await VideoTrimExtractor.extract(
            request.trim,
            maxLongSide: Self.maxSegmentLongSide,
            includeAudio: false
        )
        defer { try? FileManager.default.removeItem(at: segmentURL) }
        let segment = try await probeSegment(at: segmentURL)

        let videoStorageId = try await BackendStorage.uploadStaged(
            fileURL: segmentURL,
            contentType: "video/mp4"
        )
        let seed: BackendMaskSeed
        switch request.seed {
        case .text(let prompt):
            seed = .text(prompt: prompt)
        case .point(let point):
            let mapped = try MaskPointMapper.map(
                point,
                trim: request.trim,
                segmentWidth: segment.width,
                segmentHeight: segment.height,
                segmentFPS: segment.fps,
                segmentFrameCount: segment.frameCount
            )
            seed = .point(x: mapped.x, y: mapped.y, frameIndex: mapped.frameIndex)
        }
        let submit = try await MaskTrackingBackend.submit(
            videoStorageId: videoStorageId,
            frameCount: segment.frameCount,
            seed: seed,
            projectId: request.projectId
        )
        Log.masking.notice(
            "mask-track submitted job=\(submit.jobId) mask=\(request.maskId) frames=\(segment.frameCount)"
        )

        try await MaskTrackingBackend.waitForCompletion(jobId: submit.jobId)
        try Task.checkCancellation()

        let payloadData = try await MaskTrackingBackend.resultPayload(jobId: submit.jobId)
        guard let payload = try? JSONDecoder().decode(MaskTrackPayload.self, from: payloadData) else {
            throw ServiceError.invalidPayload
        }
        let track = MaskTrack(
            id: UUID().uuidString,
            mediaRef: request.mediaRef,
            fps: segment.fps,
            firstSourceFrame: request.trim.trimStartFrame,
            frameCount: payload.rle.count
        )
        let matteURL = FileIO.temporaryFileURL(pathExtension: "mov")
        do {
            try await MatteVideoRenderer.render(
                payload: payload,
                width: segment.width,
                height: segment.height,
                fps: segment.fps,
                to: matteURL
            )
        } catch {
            try? FileManager.default.removeItem(at: matteURL)
            throw error
        }
        Log.masking.notice(
            "mask-track staged job=\(submit.jobId) track=\(track.id) frames=\(track.frameCount)"
        )
        return StagedTrack(track: track, matteURL: matteURL)
    }

    private func probeSegment(
        at url: URL
    ) async throws -> (width: Int, height: Int, fps: Double, frameCount: Int) {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ServiceError.invalidPayload
        }
        let (size, nominalFrameRate, timeRange) = try await track.load(
            .naturalSize,
            .nominalFrameRate,
            .timeRange
        )
        let frameCountValue = timeRange.duration.seconds * Double(nominalFrameRate)
        guard size.width > 0, size.height > 0,
              nominalFrameRate > 0,
              frameCountValue.isFinite,
              frameCountValue >= 1,
              frameCountValue <= Double(Int.max)
        else {
            throw ServiceError.invalidPayload
        }
        return (
            Int(size.width.rounded()),
            Int(size.height.rounded()),
            Double(nominalFrameRate),
            Int(frameCountValue.rounded())
        )
    }
}
