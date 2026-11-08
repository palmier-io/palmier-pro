import AVFoundation
import CoreGraphics
import Foundation
import ImageIO

/// Builds one image out of the project's own frames and stills, entirely locally.
///
/// This is assembly rather than synthesis: nothing is invented, the sources are the user's media.
/// It exists because the app could render a single frame with a headline (`generate_thumbnail`) but
/// had no way to put several images into one, which is what a mood board, a contact sheet or a
/// poster needs.
extension EditorViewModel {
    struct ComposeImageRequest {
        /// Explicit source assets. Images are used as-is; video contributes a frame.
        var mediaRefs: [String] = []
        /// When set, retrieve sources matching this text from the visual index.
        var query: String?
        var retrievalLimit: Int = 6
        var layout: ComposeLayout = .grid
        var preset: ThumbnailPreset = .youtube
        var headline: String = ""
        var subline: String = ""
        var placement: ThumbnailTextPlacement = .bottomLeft
        var scrim: Bool = true
        var name: String?
        var folderId: String?
        /// Place the finished image on the timeline in the same step. Off by default: a contact
        /// sheet is usually reference material rather than something that belongs in the cut.
        var addToTimeline: Bool = false
        var startFrame: Int = 0
    }

    struct ComposeImageSource {
        var mediaRef: String
        var name: String
        /// Source time for a video frame, or nil for a still.
        var sourceSeconds: Double?
        /// Only present when the source came from retrieval.
        var score: Double?
    }

    struct ComposeImageReceipt {
        var asset: MediaAsset
        var width: Int
        var height: Int
        var sources: [ComposeImageSource]
        var requestedQuery: String?
        /// Set when the image was also placed on the timeline.
        var clipId: String?
        /// Refusals worth surfacing: a source that would not decode, a mediaRef that is missing.
        var warnings: [String]
    }

    enum ComposeImageError: Error, Equatable, CustomStringConvertible {
        case noProject
        case noSources
        case mediaNotFound(String)
        case mediaNotVisual(String)
        case retrievalUnavailable
        case folderMissing

        var description: String {
            switch self {
            case .noProject: "Save the project first — composed images are stored in its package."
            case .noSources:
                "Nothing to compose. Pass mediaRefs, or a query the visual index can match."
            case .mediaNotFound(let id): "No media asset '\(id)'."
            case .mediaNotVisual(let id):
                "'\(id)' is not an image or video, so it cannot supply a picture."
            case .retrievalUnavailable:
                "Visual search is not ready. Open Settings to prepare it, or pass mediaRefs directly."
            case .folderMissing: "The destination folder no longer exists."
            }
        }
    }

    func composeImage(_ request: ComposeImageRequest) async throws -> ComposeImageReceipt {
        try await projectPackageCoordinator.withMutation { lease in
            try await self.performImageComposition(request, lease: lease)
        }
    }

    private func performImageComposition(
        _ request: ComposeImageRequest, lease: ProjectPackageCoordinator.MutationLease
    ) async throws -> ComposeImageReceipt {
        guard let package = projectURL else { throw ComposeImageError.noProject }
        if let folderId = request.folderId, folder(id: folderId) == nil {
            throw ComposeImageError.folderMissing
        }

        var warnings: [String] = []
        let resolved = try await resolveSources(request, warnings: &warnings)
        let sourceIdentities = resolved.compactMap { source in
            mediaAssetsById[source.mediaRef].map { (asset: $0, url: $0.url) }
        }

        var images: [CGImage] = []
        images.reserveCapacity(resolved.count)
        for source in resolved {
            if let image = try await image(for: source) {
                images.append(image)
            } else {
                warnings.append("Skipped '\(source.name)': the file could not be read as an image.")
            }
        }
        guard !images.isEmpty else { throw ComposeImageError.noSources }

        let spec = ImageComposer.Spec(
            layout: request.layout,
            canvas: request.preset.size,
            headline: request.headline,
            subline: request.subline,
            placement: request.placement,
            scrim: request.scrim
        )
        let inputImages = images
        let composed = try await projectPackageCoordinator.io.perform { try ImageComposer.compose(inputImages, spec: spec) }
        let staged = try await projectPackageCoordinator.io.perform { try Self.stagePNG(composed) }
        let filename = "composed-\(UUID().uuidString).png"

        let asset = MediaAsset(
            url: package.appendingPathComponent("media/\(filename)"),
            type: .image,
            name: request.name ?? defaultComposedName(request, count: images.count),
            duration: Defaults.imageDurationSeconds
        )
        asset.installThumbnail(composed, maximumPixelSize: ImageEncoder.libraryThumbnailMaxPixelSize)
        asset.folderId = request.folderId
        asset.sourceWidth = composed.width
        asset.sourceHeight = composed.height

        var placedClipId: String?
        _ = try await commitStagedProjectMedia(staged, filename: filename, lease: lease, validate: {
            guard sourceIdentities.allSatisfy({ self.mediaAssetsById[$0.asset.id] === $0.asset && $0.asset.url == $0.url }) else {
                throw CancellationError()
            }
            if let id = request.folderId, self.folder(id: id) == nil { throw ComposeImageError.folderMissing }
        }) { destination in
            asset.url = destination
            self.importMediaAsset(asset)
            self.searchIndex.schedule(asset)
            self.prepareMediaVisuals(for: asset)
            if request.addToTimeline {
                let trackIndex = self.timeline.tracks.firstIndex(where: { $0.type == .video })
                    ?? self.insertTrack(at: 0, type: .video)
                let frames = max(1, secondsToFrame(seconds: asset.duration, fps: self.timeline.fps))
                placedClipId = self.placeClip(asset: asset, trackIndex: trackIndex,
                    startFrame: max(0, request.startFrame), durationFrames: frames, addLinkedAudio: false).first
                if placedClipId == nil { warnings.append("The image was created but could not be placed on the timeline.") }
            }
            self.onProjectCheckpointRequired?()
        }

        return ComposeImageReceipt(
            asset: asset,
            width: composed.width,
            height: composed.height,
            sources: resolved,
            requestedQuery: request.query,
            clipId: placedClipId,
            warnings: warnings
        )
    }

    // MARK: - Sources

    private func resolveSources(
        _ request: ComposeImageRequest,
        warnings: inout [String]
    ) async throws -> [ComposeImageSource] {
        var sources: [ComposeImageSource] = []
        let query = request.query?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let query, !query.isEmpty {
            let hits = await searchIndex.search(
                query: query, limit: max(1, request.retrievalLimit)
            )
            if hits.isEmpty {
                if request.mediaRefs.isEmpty { throw ComposeImageError.retrievalUnavailable }
                warnings.append("Retrieval matched nothing for '\(query)'; used the explicit mediaRefs.")
            }
            for hit in hits {
                guard let asset = mediaAssetsById[hit.assetID] else { continue }
                // A still reports a zero-length span; its absence of a time is not a failure.
                let isStill = asset.type == .image
                sources.append(ComposeImageSource(
                    mediaRef: hit.assetID,
                    name: asset.name,
                    sourceSeconds: isStill ? nil : hit.time,
                    score: Double(hit.score)
                ))
            }
        }

        for mediaRef in request.mediaRefs where !sources.contains(where: { $0.mediaRef == mediaRef }) {
            guard let asset = mediaAssetsById[mediaRef] else {
                throw ComposeImageError.mediaNotFound(mediaRef)
            }
            guard asset.type == .image || asset.type == .video else {
                throw ComposeImageError.mediaNotVisual(mediaRef)
            }
            sources.append(ComposeImageSource(
                mediaRef: mediaRef, name: asset.name, sourceSeconds: nil, score: nil
            ))
        }
        guard !sources.isEmpty else { throw ComposeImageError.noSources }
        return sources
    }

    /// Loads a still directly; for video, extracts the requested frame, defaulting to a moment a
    /// third of the way in so the opening slate is not what ends up on a mood board.
    private func image(for source: ComposeImageSource) async throws -> CGImage? {
        guard let asset = mediaAssetsById[source.mediaRef] else { return nil }
        switch asset.type {
        case .image:
            let url = asset.url
            return try await projectPackageCoordinator.io.perform { Self.decodeImage(url) }
        case .video:
            let seconds = source.sourceSeconds ?? max(0, asset.resolvedDuration / 3)
            return await Self.frameImage(from: asset.url, seconds: seconds)
        default:
            return nil
        }
    }

    private nonisolated static func decodeImage(_ url: URL) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary) else {
            return nil
        }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, nil)
    }

    @concurrent
    private static func frameImage(from url: URL, seconds: Double) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        do {
            let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
            return try await generator.image(at: time).image
        } catch {
            return nil
        }
    }

    // MARK: - Output

    private nonisolated static func stagePNG(_ image: CGImage) throws -> URL {
        guard let data = ImageEncoder.encodePNG(image) else {
            throw ComposeImageError.noSources
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("composed-\(UUID().uuidString).png")
        try data.write(to: url, options: .atomic)
        return url
    }

    private func defaultComposedName(_ request: ComposeImageRequest, count: Int) -> String {
        if let query = request.query?.trimmingCharacters(in: .whitespacesAndNewlines),
           !query.isEmpty {
            return query
        }
        return "\(count) shots"
    }
}
