import AVFoundation
import Foundation

struct MediaAssetMetadata: Sendable {
    struct Request: Sendable {
        let url: URL
        let type: ClipType
        let thumbnailMaxPixelSize: Int?
    }

    typealias Loader = @Sendable (Request) async throws -> MediaAssetMetadata

    let isReadable: Bool
    let duration: Double?
    let width: Int?
    let height: Int?
    let framesPerSecond: Double?
    let hasAudio: Bool?
    let thumbnail: CGImage?
    let thumbnailMaxPixelSize: Int?

    init(
        isReadable: Bool, duration: Double? = nil, width: Int? = nil, height: Int? = nil,
        framesPerSecond: Double? = nil, hasAudio: Bool? = nil,
        thumbnail: CGImage? = nil, thumbnailMaxPixelSize: Int? = nil
    ) {
        self.isReadable = isReadable
        self.duration = duration
        self.width = width
        self.height = height
        self.framesPerSecond = framesPerSecond
        self.hasAudio = hasAudio
        self.thumbnail = thumbnail
        self.thumbnailMaxPixelSize = thumbnailMaxPixelSize
    }

    @concurrent
    static func load(_ request: Request) async throws -> MediaAssetMetadata {
        try Task.checkCancellation()
        switch request.type {
        case .image:
            let metadata = ImageEncoder.metadata(url: request.url, thumbnailMaxPixelSize: request.thumbnailMaxPixelSize)
            try Task.checkCancellation()
            return MediaAssetMetadata(
                isReadable: metadata.width != nil && metadata.height != nil,
                duration: Defaults.imageDurationSeconds, width: metadata.width, height: metadata.height,
                thumbnail: metadata.thumbnail, thumbnailMaxPixelSize: request.thumbnailMaxPixelSize
            )
        case .lottie:
            return try await loadLottie(request)
        case .subtitle:
            let cues = try await SubtitleFileParser.parseFile(at: request.url)
            try Task.checkCancellation()
            return MediaAssetMetadata(isReadable: true, duration: cues.map(\.endSeconds).max() ?? 0)
        case .video, .audio:
            return try await loadAudiovisual(request)
        case .text, .sequence, .html:
            return MediaAssetMetadata(isReadable: true)
        }
    }

    @concurrent
    private static func loadAudiovisual(_ request: Request) async throws -> MediaAssetMetadata {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: request.url)
        if request.type == .audio {
            let duration = try await optional { try await asset.load(.duration) }
            let tracks = try await optional { try await asset.loadTracks(withMediaType: .audio) }
            return MediaAssetMetadata(isReadable: tracks?.isEmpty == false, duration: seconds(duration))
        }

        let tracks = try await optional { try await asset.loadTracks(withMediaType: .video) }
        let track = tracks?.first
        var width: Int?
        var height: Int?
        var framesPerSecond: Double?
        var duration: Double?
        if let track {
            if let size = try await optional({ try await track.load(.naturalSize) }),
               let transform = try await optional({ try await track.load(.preferredTransform) }) {
                let corrected = size.applying(transform)
                width = dimension(abs(corrected.width))
                height = dimension(abs(corrected.height))
            }
            if let rate = try await optional({ try await track.load(.nominalFrameRate) }), rate.isFinite, rate > 0 {
                framesPerSecond = Double(rate)
            }
            let timeRange = try await optional { try await track.load(.timeRange) }
            duration = seconds(timeRange?.duration)
        }
        if duration == nil {
            duration = seconds(try await optional { try await asset.load(.duration) })
        }
        let audioTracks = try await optional { try await asset.loadTracks(withMediaType: .audio) }
        var thumbnail: CGImage?
        let thumbnailBudget = request.thumbnailMaxPixelSize.map { min($0, ImageEncoder.libraryThumbnailMaxPixelSize) }
        if track != nil, let thumbnailBudget {
            try Task.checkCancellation()
            let generator = AVAssetImageGenerator(asset: asset)
            generator.maximumSize = CGSize(width: thumbnailBudget, height: thumbnailBudget)
            generator.appliesPreferredTrackTransform = true
            thumbnail = try await optional { try await generator.image(at: .zero).image }
        }
        try Task.checkCancellation()
        return MediaAssetMetadata(
            isReadable: track != nil, duration: duration, width: width, height: height,
            framesPerSecond: framesPerSecond, hasAudio: audioTracks.map { !$0.isEmpty },
            thumbnail: thumbnail, thumbnailMaxPixelSize: thumbnailBudget
        )
    }

    @MainActor
    private static func loadLottie(_ request: Request) async throws -> MediaAssetMetadata {
        let info = try await LottieVideoGenerator.inspect(fileAt: request.url)
        try Task.checkCancellation()
        return MediaAssetMetadata(
            isReadable: true, duration: info.meta.duration,
            width: dimension(info.meta.size.width), height: dimension(info.meta.size.height),
            framesPerSecond: info.meta.framerate,
            thumbnail: request.thumbnailMaxPixelSize == nil ? nil : info.thumbnail,
            thumbnailMaxPixelSize: request.thumbnailMaxPixelSize.map { min($0, 512) }
        )
    }

    nonisolated(nonsending)
    private static func optional<Value>(_ operation: () async throws -> Value) async throws -> Value? {
        do {
            let value = try await operation()
            try Task.checkCancellation()
            return value
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return nil
        }
    }

    private static func seconds(_ time: CMTime?) -> Double? {
        guard let time, time.isNumeric, time.seconds.isFinite, time.seconds >= 0 else { return nil }
        return time.seconds
    }

    private static func dimension(_ value: CGFloat) -> Int? {
        guard value.isFinite, value >= 0, value < CGFloat(Int.max) else { return nil }
        return Int(value)
    }
}
