import CoreGraphics
import Foundation
import ImageIO

/// Lifts a subject out of a still image and files the cutout in the library, as one undoable step.
///
/// The consumer side of an alpha matte already exists — an image with alpha becomes a ProRes 4444
/// still for the compositor — so this only produces the matte.
extension EditorViewModel {
    struct RemoveBackgroundRequest {
        var mediaRef: String
        var mode: BackgroundRemover.Mode = .subject
        /// Softens the cutout edge. As a percentage of the image's long edge; 0 leaves Vision's edge.
        var feather: Double = 1.5
        /// Set to flatten the cutout onto a solid colour instead of leaving it transparent.
        var fillHex: String?
        var name: String?
        var folderId: String?
    }

    struct RemoveBackgroundReceipt {
        var asset: MediaAsset
        var width: Int
        var height: Int
        /// Share of the frame the subject occupies, 0...1.
        var subjectCoverage: Double
        var mode: BackgroundRemover.Mode
        var flattenedOnto: String?
    }

    enum RemoveBackgroundError: Error, Equatable, CustomStringConvertible {
        case noProject
        case mediaNotFound(String)
        case notAnImage(String)
        case mediaUnavailable(String)
        case folderMissing
        case badFill(String)

        var description: String {
            switch self {
            case .noProject: "Save the project first — the cutout is stored in its package."
            case .mediaNotFound(let id): "No media asset '\(id)'."
            case .notAnImage(let id):
                "'\(id)' is not an image. Background removal works on stills; for keyed video use "
                    + "the chroma key effect instead."
            case .mediaUnavailable(let id): "'\(id)' is offline or still preparing."
            case .folderMissing: "The destination folder no longer exists."
            case .badFill(let hex): "'\(hex)' is not a #RRGGBB colour."
            }
        }
    }

    func removeImageBackground(
        _ request: RemoveBackgroundRequest
    ) async throws -> RemoveBackgroundReceipt {
        try await projectPackageCoordinator.withMutation { lease in
            try await self.performBackgroundRemoval(request, lease: lease)
        }
    }

    private func performBackgroundRemoval(
        _ request: RemoveBackgroundRequest, lease: ProjectPackageCoordinator.MutationLease
    ) async throws -> RemoveBackgroundReceipt {
        guard projectURL != nil else { throw RemoveBackgroundError.noProject }
        if let folderId = request.folderId, folder(id: folderId) == nil {
            throw RemoveBackgroundError.folderMissing
        }
        guard let asset = mediaAssets.first(where: { $0.id == request.mediaRef }) else {
            throw RemoveBackgroundError.mediaNotFound(request.mediaRef)
        }
        guard asset.type == .image else {
            throw RemoveBackgroundError.notAnImage(request.mediaRef)
        }

        var fill: TextStyle.RGBA?
        if let hex = request.fillHex {
            guard let parsed = TextStyle.RGBA(hex: hex) else {
                throw RemoveBackgroundError.badFill(hex)
            }
            fill = parsed
        }

        let feather = request.feather.clamped(to: 0 ... 8)
        let sourceURL = asset.url
        let result: BackgroundRemover.Result = try await Task.detached(priority: .userInitiated) {
            guard let image = Self.loadImage(at: sourceURL) else {
                throw RemoveBackgroundError.notAnImage(request.mediaRef)
            }
            return try await BackgroundRemover.removeBackground(
                from: image, mode: request.mode, feather: feather
            )
        }.value

        let resolvedFill = fill
        let output = try await projectPackageCoordinator.io.perform {
            if let resolvedFill, let flattened = Self.flatten(result.image, onto: resolvedFill) { return flattened }
            return result.image
        }

        try Task.checkCancellation()
        guard projectURL != nil else { throw RemoveBackgroundError.noProject }
        let filename = "cutout-\(UUID().uuidString).png"
        let committed = try await commitImageAsset(
            output, filename: filename, name: request.name ?? defaultCutoutName(asset, request.mode),
            folderId: request.folderId, lease: lease, validate: {
                guard self.mediaAssetsById[asset.id] === asset, asset.url == sourceURL else { throw CancellationError() }
                if let id = request.folderId, self.folder(id: id) == nil { throw RemoveBackgroundError.folderMissing }
            }
        )

        return RemoveBackgroundReceipt(
            asset: committed,
            width: output.width,
            height: output.height,
            subjectCoverage: result.subjectCoverage,
            mode: request.mode,
            flattenedOnto: request.fillHex
        )
    }

    // MARK: - Helpers

    private func defaultCutoutName(_ asset: MediaAsset, _ mode: BackgroundRemover.Mode) -> String {
        let noun = mode == .person ? "Person" : "Subject"
        return "\(noun) · \(asset.name)"
    }

    /// Writes a PNG into the project package and registers it as a library asset.
    private func commitImageAsset(
        _ image: CGImage, filename: String, name: String, folderId: String?,
        lease: ProjectPackageCoordinator.MutationLease, validate: @MainActor () throws -> Void
    ) async throws -> MediaAsset {
        guard let package = projectURL else { throw RemoveBackgroundError.noProject }
        let staged = try await projectPackageCoordinator.io.perform {
            guard let data = ImageEncoder.encodePNG(image) else { throw RemoveBackgroundError.noProject }
            return try FileIO.stageData(data, pathExtension: "png")
        }
        let asset = MediaAsset(
            url: package.appendingPathComponent("media/\(filename)"), type: .image, name: name, duration: Defaults.imageDurationSeconds
        )
        asset.installThumbnail(image, maximumPixelSize: ImageEncoder.libraryThumbnailMaxPixelSize)
        asset.folderId = folderId
        asset.sourceWidth = image.width
        asset.sourceHeight = image.height
        _ = try await commitStagedProjectMedia(staged, filename: filename, lease: lease, validate: validate) { destination in
            asset.url = destination
            self.importMediaAsset(asset)
        }
        await finalizeImportedAsset(asset)
        onProjectCheckpointRequired?()
        return asset
    }

    nonisolated static func loadImage(at url: URL) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: false,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Composites the cutout onto an opaque colour.
    nonisolated static func flatten(_ image: CGImage, onto fill: TextStyle.RGBA) -> CGImage? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.setFillColor(
            red: CGFloat(fill.r), green: CGFloat(fill.g), blue: CGFloat(fill.b), alpha: 1
        )
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        guard isFinite else { return range.lowerBound }
        return Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
