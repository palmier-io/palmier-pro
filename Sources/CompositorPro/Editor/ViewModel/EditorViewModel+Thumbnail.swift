import AVFoundation
import CoreGraphics
import Foundation

extension EditorViewModel {
    struct ThumbnailReceipt: Sendable, Equatable {
        var url: URL
        var preset: ThumbnailPreset
        var frame: Int
        var width: Int
        var height: Int
        var bytes: Int
        /// True when the frame was chosen by legibility scoring rather than requested.
        var frameWasChosen: Bool
        /// Frames considered, when the frame was chosen.
        var framesConsidered: Int
        var hasTitle: Bool
    }

    /// Renders a poster frame for the timeline and writes it as its own file.
    ///
    /// This never touches the timeline and never becomes a media asset: a thumbnail is a separate
    /// deliverable the user uploads, not part of the cut. Passing `frame: nil` picks the most
    /// legible frame by contrast and clipping, and says so in the receipt rather than pretending
    /// it knows which frame is best.
    func generateThumbnail(
        spec: ThumbnailSpec,
        frame: Int?,
        directory: URL?,
        fileName: String?
    ) async throws -> ThumbnailReceipt {
        let fps = max(1, timeline.fps)
        let total = max(1, timeline.totalFrames)
        guard frame == nil || (frame! >= 0 && frame! < total) else {
            throw ThumbnailError.frameOutOfRange(frame: frame!, totalFrames: total)
        }
        let urls = mediaResolver.expectedURLMap()
        let candidates: [Int]
        if let frame {
            candidates = [frame]
        } else {
            candidates = legibilityFrames(total: total)
        }
        guard !candidates.isEmpty else { throw ThumbnailError.noFrames }

        var best: (frame: Int, score: Double, image: CGImage)?
        for candidate in candidates {
            try Task.checkCancellation()
            let rendered = try await renderTimelineFrame(candidate, urls: urls)
            let cropped = ThumbnailRenderer.coverCrop(rendered, to: spec.preset.size)
            let score = ThumbnailRenderer.score(cropped)
            if best == nil || score > best!.score {
                best = (candidate, score, cropped)
            }
            // An explicit frame is not a search: stop after the first one rendered.
            if frame != nil { break }
        }
        guard let chosen = best else { throw ThumbnailError.noFrames }

        guard let finished = ThumbnailRenderer.applyText(to: chosen.image, spec: spec) else {
            throw ThumbnailError.renderFailed("the headline could not be drawn")
        }
        let data = try ThumbnailRenderer.encode(finished, preset: spec.preset)

        let outputDirectory = directory ?? defaultThumbnailDirectory()
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let url = outputDirectory.appendingPathComponent(Self.thumbnailFileName(fileName))
        // Atomic, so a failed write never leaves a half-file at the path the receipt reports.
        try data.write(to: url, options: .atomic)
        return ThumbnailReceipt(
            url: url,
            preset: spec.preset,
            frame: chosen.frame,
            width: Int(spec.preset.size.width),
            height: Int(spec.preset.size.height),
            bytes: data.count,
            frameWasChosen: frame == nil,
            framesConsidered: candidates.count,
            hasTitle: !spec.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
    }

    /// Samples across the whole timeline and keeps the frames worth scoring. Spread out rather
    /// than clustered so the winner is not three consecutive frames of the same shot.
    private func legibilityFrames(total: Int) -> [Int] {
        let sampleCount = min(9, max(1, total))
        guard sampleCount > 1 else { return [0] }
        let urls = mediaResolver.expectedURLMap()
        var frames: [Int] = []
        for index in 0 ..< sampleCount {
            let frame = Int((Double(total) * Double(index) / Double(sampleCount)).rounded())
            frames.append(min(max(frame, 0), total - 1))
        }
        // The candidates are the frame numbers; scoring happens in generateThumbnail so the
        // expensive compositing build is shared with the explicit-frame path.
        return Array(Set(frames)).sorted()
    }

    private func renderTimelineFrame(_ frame: Int, urls: [String: URL]) async throws -> CGImage {
        let rendered = try await FrameCaptureRenderer.timeline(
            timeline,
            frame: frame,
            mediaURLs: urls,
            resolveTimeline: timelineResolver(),
            missingMediaRefs: missingMediaRefs
        )
        defer { try? FileManager.default.removeItem(at: rendered.stagedURL) }
        guard let image = rendered.thumbnail else {
            throw ThumbnailError.renderFailed("the frame came back empty")
        }
        return image
    }

    /// Thumbnails live beside the project package so they are found with the project but are not
    /// project state — deleting one never touches the edit.
    private func defaultThumbnailDirectory() -> URL {
        guard let projectURL else {
            return FileManager.default.temporaryDirectory
        }
        return projectURL.appendingPathComponent("thumbnails", isDirectory: true)
    }

    nonisolated static func thumbnailFileName(_ requested: String?) -> String {
        let base = (requested ?? "thumbnail")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
        let safe = base.isEmpty ? "thumbnail" : String(base.prefix(80))
        return safe.hasSuffix(".jpg") || safe.hasSuffix(".jpeg") ? safe : "\(safe).jpg"
    }
}

enum ThumbnailError: LocalizedError, Equatable {
    case frameOutOfRange(frame: Int, totalFrames: Int)
    case noFrames
    case renderFailed(String)
    case unknownPreset(String)

    var description: String {
        switch self {
        case .frameOutOfRange(let frame, let total):
            "Frame \(frame) is outside the timeline's 0…\(total - 1) range."
        case .noFrames: "The timeline has no picture to make a thumbnail from."
        case .renderFailed(let reason): "Could not render the thumbnail: \(reason)"
        case .unknownPreset(let name):
            "Unknown thumbnail preset '\(name)'. One of: "
                + ThumbnailPreset.allCases.map(\.rawValue).joined(separator: ", ") + "."
        }
    }

    /// Without this the tool surfaces "The operation couldn't be completed" instead of the
    /// reason, which is useless when the Agent has to report it back.
    var errorDescription: String? { description }
}