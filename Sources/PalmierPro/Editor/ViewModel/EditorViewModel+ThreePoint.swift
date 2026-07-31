import AppKit

/// Three-point editing: source in/out marks and the insert/append/overwrite edit commands.
extension EditorViewModel {

    // MARK: - Edit sources

    /// The asset a mark command targets: the active media preview tab's asset.
    var activeSourceMarkAsset: MediaAsset? {
        guard case .mediaAsset(let id, _, _) = activePreviewTab else { return nil }
        return mediaAssets.first { $0.id == id }
    }

    /// Assets the edit commands read: the active media tab's asset, else the panel selection in order.
    var threePointSourceAssets: [MediaAsset] {
        if let asset = activeSourceMarkAsset { return [asset] }
        return selectedMediaAssetsInOrder
    }

    var canClearSourceMarks: Bool {
        threePointSourceAssets.contains { $0.sourceMarks != nil }
    }

    // MARK: - Marking (not undoable, like timeline range marks)

    func markSourceIn() {
        setSourceMark { marks, seconds in
            marks.inSeconds = seconds
            if let out = marks.outSeconds, out <= seconds { marks.outSeconds = nil }
        }
    }

    func markSourceOut() {
        setSourceMark { marks, seconds in
            marks.outSeconds = seconds
            if let inPoint = marks.inSeconds, inPoint >= seconds { marks.inSeconds = nil }
        }
    }

    func clearSourceMarks() {
        let marked = threePointSourceAssets.filter { $0.sourceMarks != nil }
        guard !marked.isEmpty else { return }
        for asset in marked { asset.sourceMarks = nil }
        updateManifestMetadata(for: marked)
    }

    private func setSourceMark(_ apply: (inout SourceMarks, Double) -> Void) {
        guard let asset = activeSourceMarkAsset, asset.type != .image, asset.duration > 0 else {
            NSSound.beep()
            return
        }
        let seconds = min(max(0, Double(sourcePlayheadFrame) / Double(timeline.fps)), asset.duration)
        var marks = asset.sourceMarks ?? SourceMarks()
        apply(&marks, seconds)
        asset.sourceMarks = marks
        updateManifestMetadata(for: [asset])
    }

    // MARK: - Edit commands

    /// Insert the marked ranges (or whole assets) at the timeline playhead, splitting any
    /// straddling clip and rippling downstream content right.
    func insertSourceAtPlayhead() {
        performThreePointEdit(actionName: "Insert at Playhead", atFrame: activeFrame, ripple: true, movesPlayhead: true)
    }

    /// Place the marked ranges (or whole assets) after the last clip on the timeline.
    func appendSourceToEnd() {
        performThreePointEdit(actionName: "Append to End", atFrame: timeline.totalFrames, ripple: false, movesPlayhead: false)
    }

    /// Place the marked ranges (or whole assets) at the timeline playhead, replacing
    /// whatever occupies that range. No ripple.
    func overwriteSourceAtPlayhead() {
        performThreePointEdit(actionName: "Overwrite at Playhead", atFrame: activeFrame, ripple: false, movesPlayhead: true)
    }

    private func performThreePointEdit(actionName: String, atFrame: Int, ripple: Bool, movesPlayhead: Bool) {
        let assets = threePointSourceAssets
        guard !assets.isEmpty else {
            refuseWithToast("Open a clip or select media to edit.")
            return
        }
        if let blocked = assets.first(where: { $0.isGenerating }) {
            refuseWithToast("\"\(blocked.name)\" is still generating.")
            return
        }
        if let blocked = assets.first(where: { isMediaOffline($0.id) }) {
            refuseWithToast("\"\(blocked.name)\" is offline.")
            return
        }
        if let blocked = assets.first(where: { $0.duration <= 0 && $0.type != .image }) {
            refuseWithToast("\"\(blocked.name)\" has no duration yet.")
            return
        }

        let segments = Dictionary(uniqueKeysWithValues: assets.compactMap { asset in
            asset.markedSegment.map { (asset.id, $0) }
        })
        let totalDur = assets.reduce(0) { $0 + clipDurationFrames(for: $1, segment: segments[$1.id]) }
        let cursor: TrackDropTarget = timeline.tracks.isEmpty ? .newTrackAt(0) : .existingTrack(0)

        if ripple {
            let plan = resolveDropPlan(cursor: cursor, assets: assets, atFrame: atFrame, segments: segments)
            for case .existingTrack(let idx)? in [plan.visualTarget, audioTargetAfterVisualInsertion(plan: plan)] {
                if let reason = rippleInsertRefusalReason(trackIndex: idx, atFrame: atFrame) {
                    refuseWithToast(reason)
                    return
                }
            }
        }

        let created = undo.perform(actionName) {
            placeDroppedAssets(assets, cursor: cursor, atFrame: atFrame, segments: segments, splitStraddlers: ripple, ripple: ripple)
        }
        guard movesPlayhead, !created.isEmpty else { return }
        seekToFrame(atFrame + totalDur)
    }
}
