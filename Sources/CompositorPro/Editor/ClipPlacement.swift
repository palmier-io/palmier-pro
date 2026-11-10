import Foundation

enum ClipPlacement {
    struct Source: Codable, Sendable, Equatable {
        let mediaRef: String
        let type: ClipType
        let durationSeconds: Double
        let hasAudio: Bool
        let width: Int?
        let height: Int?

        @MainActor
        init(asset: MediaAsset) {
            mediaRef = asset.id
            type = asset.type
            durationSeconds = asset.resolvedDuration
            hasAudio = asset.hasAudio
            width = asset.sourceWidth
            height = asset.sourceHeight
        }

        init(mediaRef: String, type: ClipType, durationSeconds: Double, hasAudio: Bool, width: Int?, height: Int?) {
            self.mediaRef = mediaRef
            self.type = type
            self.durationSeconds = durationSeconds
            self.hasAudio = hasAudio
            self.width = width
            self.height = height
        }
    }

    struct Clips: Sendable {
        let primary: Clip
        let linkedAudio: Clip?
        var ids: [String] { [primary.id] + (linkedAudio.map { [$0.id] } ?? []) }
    }

    enum Failure: Error, LocalizedError, Sendable {
        case invalidRange
        case incompatibleTrack

        var errorDescription: String? {
            switch self {
            case .invalidRange: "Clip placement requires finite source time and a nonempty, bounded frame range."
            case .incompatibleTrack: "The source is incompatible with its destination track."
            }
        }
    }

    static func frames(seconds: Double, fps: Int) throws -> Int {
        guard (1...120).contains(fps), seconds.isFinite, seconds >= 0 else { throw Failure.invalidRange }
        let value = seconds * Double(fps)
        guard value.isFinite, value <= Double(maxFrameArg) else { throw Failure.invalidRange }
        return Int(value)
    }

    static func make(
        source: Source, trackType: ClipType, fps: Int, canvasWidth: Int, canvasHeight: Int,
        startFrame: Int, durationFrames: Int, trimStartFrame: Int = 0, trimEndFrame: Int? = nil,
        addLinkedAudio: Bool = true, primaryId: String = UUID().uuidString,
        audioId: String = UUID().uuidString, linkGroupId: String = UUID().uuidString
    ) throws -> Clips {
        guard source.type.isCompatible(with: trackType) else { throw Failure.incompatibleTrack }
        guard startFrame >= 0, durationFrames > 0, durationFrames <= maxFrameArg,
              startFrame <= maxFrameArg - durationFrames, trimStartFrame >= 0, trimStartFrame <= maxFrameArg,
              trimEndFrame.map({ (0...maxFrameArg).contains($0) }) ?? true else { throw Failure.invalidRange }
        let total = try frames(seconds: source.durationSeconds, fps: fps)
        if source.type != .image {
            guard total > 0, trimStartFrame < total, durationFrames <= total - trimStartFrame else {
                throw Failure.invalidRange
            }
        }
        let tail = total > 0 ? min(trimEndFrame ?? max(0, total - trimStartFrame - durationFrames),
                                  max(0, total - trimStartFrame - durationFrames)) : (trimEndFrame ?? 0)
        let linked = addLinkedAudio && trackType == .video && source.hasAudio
            && (source.type == .video || source.type == .sequence)
        let transform = fitTransform(sourceWidth: source.width, sourceHeight: source.height,
                                     canvasWidth: canvasWidth, canvasHeight: canvasHeight)
        var primary = Clip(id: primaryId, mediaRef: source.mediaRef, mediaType: source.type,
                           sourceClipType: source.type, startFrame: startFrame, durationFrames: durationFrames,
                           trimStartFrame: trimStartFrame, trimEndFrame: tail, transform: transform)
        primary.linkGroupId = linked ? linkGroupId : nil
        var audio: Clip?
        if linked {
            var value = Clip(id: audioId, mediaRef: source.mediaRef, mediaType: .audio,
                             sourceClipType: source.type, startFrame: startFrame, durationFrames: durationFrames,
                             trimStartFrame: trimStartFrame, trimEndFrame: tail)
            value.linkGroupId = linkGroupId
            audio = value
        }
        return Clips(primary: primary, linkedAudio: audio)
    }

    static func fitTransform(sourceWidth: Int?, sourceHeight: Int?, canvasWidth: Int, canvasHeight: Int) -> Transform {
        guard let sourceWidth, let sourceHeight, sourceWidth > 0, sourceHeight > 0,
              canvasWidth > 0, canvasHeight > 0 else { return Transform() }
        let canvasAspect = Double(canvasWidth) / Double(canvasHeight)
        let sourceAspect = Double(sourceWidth) / Double(sourceHeight)
        guard abs(canvasAspect - sourceAspect) >= Defaults.aspectTolerance else { return Transform() }
        let relativeAspect = sourceAspect / canvasAspect
        return relativeAspect > 1 ? Transform(width: 1, height: 1 / relativeAspect)
            : Transform(width: relativeAspect, height: 1)
    }

    static func trackInsertionIndex(type: ClipType, requested: Int, tracks: [Track]) -> Int {
        let divider = tracks.firstIndex { $0.type == .audio } ?? tracks.count
        let bounded = max(0, min(requested, tracks.count))
        return type == .audio ? max(bounded, divider) : min(bounded, divider)
    }
}
