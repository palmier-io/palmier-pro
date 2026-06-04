import CoreGraphics
import Foundation

extension EditorViewModel {
    struct CaptionRequest {
        var sourceClipIds: [String] = []
        var style: TextStyle = TextStyle()
        var center: CGPoint = AppTheme.Caption.defaultCenter
    }

    func captionLineFits(_ line: String, style: TextStyle) -> Bool {
        let size = TextLayout.naturalSize(
            content: line, style: style, maxWidth: .greatestFiniteMagnitude, canvasHeight: CGFloat(timeline.height)
        )
        return size.width <= CGFloat(timeline.width) * AppTheme.ComponentSize.captionPreviewMaxTextWidthRatio
    }

    enum CaptionError: LocalizedError {
        case noSource

        var errorDescription: String? {
            switch self {
            case .noSource: "No audio clips to caption."
            }
        }
    }

    func captionTargets(ids: [String]) -> [Clip] {
        let pool: [Clip] = ids.isEmpty
            ? timeline.tracks.flatMap(\.clips)
            : ids.compactMap { findClip(id: $0).map { timeline.tracks[$0.trackIndex].clips[$0.clipIndex] } }
        return pool
            .filter { $0.mediaType == .video || $0.mediaType == .audio }
            .sorted { $0.startFrame < $1.startFrame }
    }

    @discardableResult
    func generateCaptions(for request: CaptionRequest) async throws -> [String] {
        let targetIds = captionTargets(ids: request.sourceClipIds).map(\.id)
        guard !targetIds.isEmpty else { throw CaptionError.noSource }

        var phrasesByClipId: [String: [CaptionBuilder.Phrase]] = [:]
        var resultByMediaRef: [String: TranscriptionResult] = [:]
        var firstError: Error?
        for clipId in targetIds {
            guard let loc = findClip(id: clipId) else { continue }
            let clip = timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
            do {
                let result: TranscriptionResult
                if let cached = resultByMediaRef[clip.mediaRef] {
                    result = cached
                } else {
                    guard let url = mediaResolver.resolveURL(for: clip.mediaRef) else { continue }
                    result = clip.mediaType == .audio
                        ? try await Transcription.transcribe(fileURL: url)
                        : try await Transcription.transcribeVideoAudio(videoURL: url)
                    resultByMediaRef[clip.mediaRef] = result
                }
                phrasesByClipId[clipId] = CaptionBuilder.group(result.words) {
                    captionLineFits($0, style: request.style)
                }
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if phrasesByClipId.isEmpty, let firstError { throw firstError }

        let groupId = UUID().uuidString
        let fps = timeline.fps

        let canvasW = Double(timeline.width), canvasH = Double(timeline.height)
        let center = request.center
        let transformFor: (String) -> Transform? = { text in
            let natural = TextLayout.naturalSize(
                content: text, style: request.style, maxWidth: CGFloat(canvasW) * AppTheme.ComponentSize.captionPreviewMaxTextWidthRatio, canvasHeight: CGFloat(canvasH)
            )
            return Transform(
                center: (Double(center.x), Double(center.y)),
                width: Double(natural.width) / canvasW,
                height: Double(natural.height) / canvasH
            )
        }

        var specs: [TextClipSpec] = []
        for clipId in targetIds {
            guard let phrases = phrasesByClipId[clipId], let loc = findClip(id: clipId) else { continue }
            let liveClip = timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
            specs += CaptionBuilder.specs(
                for: phrases, sourceClip: liveClip, trackIndex: 0, fps: fps,
                style: request.style, captionGroupId: groupId, transformFor: transformFor
            )
        }
        guard !specs.isEmpty else { return [] }

        let before = timeline
        timeline.tracks.insert(Track(type: .video, label: "Captions"), at: 0)
        let ids = placeTextClips(specs)
        guard !ids.isEmpty else {
            timeline = before
            videoEngine?.syncTextLayers()
            return []
        }

        registerTimelineSwap(undoState: before, redoState: timeline, actionName: "Generate Captions")
        notifyTimelineChanged()
        return ids
    }
}
