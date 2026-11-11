import Foundation

extension EditorViewModel {

    /// Inserts a hybrid HTML/HyperFrames composition clip directly onto the timeline.
    @discardableResult
    func insertHybridCompositionClip(
        html: String,
        blockId: String? = nil,
        parameters: [String: String]? = nil,
        trackIndex: Int? = nil,
        startFrame: Int? = nil,
        durationFrames: Int? = nil,
        compositeLayer: CompositeLayer = .overlay
    ) throws -> String {
        let resolvedStart = max(0, startFrame ?? currentFrame)
        let resolvedDuration = max(1, durationFrames ?? 90)

        let targetTrack: Int
        if let req = trackIndex {
            guard timeline.tracks.indices.contains(req) else {
                throw ToolError("Invalid track index: \(req). Timeline has \(timeline.tracks.count) tracks.")
            }
            guard timeline.tracks[req].type != .audio else {
                throw ToolError("Track \(req) is an audio track and cannot hold visual composition blocks.")
            }
            targetTrack = req
        } else {
            let neededRange = resolvedStart..<(resolvedStart + resolvedDuration)
            let freeTrack = timeline.tracks.enumerated().first { idx, track in
                track.type == .video && !track.clips.contains { clip in
                    let clipRange = clip.startFrame..<clip.endFrame
                    return clipRange.overlaps(neededRange)
                }
            }
            if let freeTrack {
                targetTrack = freeTrack.offset
            } else {
                let insertionIdx = ClipPlacement.trackInsertionIndex(type: .video, requested: 0, tracks: timeline.tracks)
                timeline.tracks.insert(Track(type: .video, name: "HTML Overlay"), at: insertionIdx)
                targetTrack = insertionIdx
            }
        }

        var clip = Clip(
            mediaRef: blockId ?? "hybrid-\(UUID().uuidString.prefix(8))",
            startFrame: resolvedStart,
            durationFrames: resolvedDuration
        )
        clip.mediaType = .html
        clip.sourceClipType = .html
        clip.compositeLayer = compositeLayer
        clip.htmlContent = html
        clip.hyperframesBlockId = blockId
        clip.hyperframesParameters = parameters

        withTimelineSwap(actionName: "Insert Hybrid Composition") {
            self.timeline.tracks[targetTrack].clips.append(clip)
        }
        return clip.id
    }

    /// Updates parameters or HTML content of an existing hybrid composition clip.
    func updateHybridCompositionClip(
        clipId: String,
        parameters: [String: String]? = nil,
        html: String? = nil
    ) throws {
        var foundTrackIndex: Int?
        var foundClipIndex: Int?

        for (ti, track) in timeline.tracks.enumerated() {
            if let ci = track.clips.firstIndex(where: { $0.id == clipId }) {
                foundTrackIndex = ti
                foundClipIndex = ci
                break
            }
        }

        guard let ti = foundTrackIndex, let ci = foundClipIndex else {
            throw ToolError("Clip \(clipId) not found on timeline.")
        }

        withTimelineSwap(actionName: "Update Hybrid Composition") {
            if let params = parameters {
                self.timeline.tracks[ti].clips[ci].hyperframesParameters = params
            }
            if let updatedHTML = html {
                self.timeline.tracks[ti].clips[ci].htmlContent = updatedHTML
            }
        }
    }
}

