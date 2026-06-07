import CoreGraphics
import Foundation

extension EditorViewModel {
    struct CaptionRequest {
        var sourceClipIds: [String] = []
        var style: TextStyle = TextStyle()
        var center: CGPoint = AppTheme.Caption.defaultCenter
        var textCase: CaptionCase = .auto
        var censorProfanity: Bool = false
        var locale: Locale? = nil
    }

    enum CaptionCase: String, CaseIterable, Sendable {
        case auto, upper, lower

        var label: String {
            switch self {
            case .auto: "Auto"
            case .upper: "UPPERCASE"
            case .lower: "lowercase"
            }
        }

        func apply(_ s: String) -> String {
            switch self {
            case .auto: s
            case .upper: s.uppercased()
            case .lower: s.lowercased()
            }
        }
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

    func captionCanTranscribe(_ clip: Clip) -> Bool {
        guard clip.mediaType == .video || clip.mediaType == .audio else { return false }
        guard let asset = mediaAssets.first(where: { $0.id == clip.mediaRef }) else { return true }
        return asset.type == .audio || (asset.type == .video && asset.hasAudio)
    }

    func captionUsesVideoAudioExtraction(for clip: Clip) -> Bool {
        let assetType = mediaAssets.first(where: { $0.id == clip.mediaRef })?.type
        return assetType == .video || (assetType == nil && clip.mediaType == .video)
    }

    func captionTargets(ids: [String]) -> [Clip] {
        let pool: [Clip] = ids.isEmpty
            ? timeline.tracks.flatMap(\.clips)
            : ids.compactMap { findClip(id: $0).map { timeline.tracks[$0.trackIndex].clips[$0.clipIndex] } }
        return captionTargets(in: pool)
    }

    func captionTargets(trackIds: Set<String>) -> [Clip] {
        guard !trackIds.isEmpty else { return [] }
        let audioGroups = Set(timeline.tracks.flatMap(\.clips).filter { $0.mediaType == .audio }.compactMap(\.linkGroupId))
        let pool = timeline.tracks
            .filter { trackIds.contains($0.id) }
            .flatMap(\.clips)
            .filter { !($0.mediaType == .video && $0.linkGroupId.map(audioGroups.contains) == true) }
        return captionTargets(in: pool)
    }

    private func captionTargets(in pool: [Clip]) -> [Clip] {
        let linkGroupsWithAudio = Set(pool.filter { $0.mediaType == .audio }.compactMap(\.linkGroupId))
        return pool
            .filter { clip in
                guard captionCanTranscribe(clip) else { return false }
                guard clip.mediaType == .video, let groupId = clip.linkGroupId else { return true }
                return !linkGroupsWithAudio.contains(groupId)
            }
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
                    result = captionUsesVideoAudioExtraction(for: clip)
                        ? try await Transcription.transcribeVideoAudio(videoURL: url, censorProfanity: request.censorProfanity, preferredLocale: request.locale)
                        : try await Transcription.transcribe(fileURL: url, censorProfanity: request.censorProfanity, preferredLocale: request.locale)
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
            let cased = phrases.map {
                CaptionBuilder.Phrase(text: request.textCase.apply($0.text), start: $0.start, end: $0.end)
            }
            specs += CaptionBuilder.specs(
                for: cased, sourceClip: liveClip, trackIndex: 0, fps: fps,
                style: request.style, captionGroupId: groupId, transformFor: transformFor
            )
        }
        guard !specs.isEmpty else { return [] }

        undoManager?.beginUndoGrouping()
        defer { undoManager?.endUndoGrouping() }
        let before = timeline
        undoManager?.disableUndoRegistration()
        timeline.tracks.insert(Track(type: .video, label: "Captions"), at: 0)
        let ids = placeTextClips(specs)
        undoManager?.enableUndoRegistration()
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
