import Foundation

struct ClipMediaSwapPlan {
    let clipId, oldMediaRef, newMediaRef: String
    let affectedClipIds: [String]
    var changed: Bool { oldMediaRef != newMediaRef }
}

struct ClipMediaSwapError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// Armed swap session: pick a replacement source from the media panel for a clip, preserving its state.
extension EditorViewModel {
    var pendingSwapClip: Clip? {
        pendingSwapClipId.flatMap { clipFor(id: $0) }
    }

    var pendingSwapClipName: String? {
        pendingSwapClip.flatMap { clip in mediaAssets.first { $0.id == clip.mediaRef }?.name }
    }

    func beginMediaSwap(clipId: String) {
        guard let ids = try? mediaSwapTargetClipIds(for: clipId) else { return }
        pendingSwapTargetClipIds = ids
        pendingSwapClipId = clipId
        showMediaPanelMediaTab()
    }

    func cancelMediaSwap() {
        pendingSwapClipId = nil
        pendingSwapTargetClipIds = []
    }

    func isAssetCompatibleWithPendingSwap(_ asset: MediaAsset) -> Bool {
        guard let clipId = pendingSwapClipId else { return false }
        return (try? swapClipMedia(
            clipId: clipId,
            replacement: asset,
            targetClipIds: pendingSwapTargetClipIds,
            commit: false
        )) != nil
    }

    func completeMediaSwap(with asset: MediaAsset) {
        guard let clip = pendingSwapClip else {
            cancelMediaSwap()
            return
        }
        do {
            try swapClipMedia(clipId: clip.id, replacement: asset)
        } catch {
            mediaPanelToast = MediaPanelToast(message: L10n.string("This source can’t replace the clip."))
            return
        }
        cancelMediaSwap()
    }

    @discardableResult
    func swapClipMedia(
        clipId: String,
        replacement: MediaAsset,
        targetClipIds: [String]? = nil,
        commit: Bool = true
    ) throws -> ClipMediaSwapPlan {
        guard let anchor = clipFor(id: clipId) else { throw ClipMediaSwapError(message: "Clip not found: \(clipId)") }
        let ids = try targetClipIds ?? mediaSwapTargetClipIds(for: clipId)
        let targets = ids.compactMap { clipFor(id: $0) }
        guard targets.count == ids.count else { throw ClipMediaSwapError(message: "Linked clip not found.") }
        guard targets.allSatisfy({ $0.sourceClipType == replacement.type }) else { throw ClipMediaSwapError(message: "Replacement must match the clip's source type.") }

        let plan = ClipMediaSwapPlan(
            clipId: clipId, oldMediaRef: anchor.mediaRef, newMediaRef: replacement.id,
            affectedClipIds: ids
        )
        guard plan.changed else { return plan }
        if replacement.type == .video, !replacement.hasAudio,
           targets.contains(where: { $0.mediaType == .audio }) {
            throw ClipMediaSwapError(message: "Replacement video has no audio for the linked clip.")
        }

        var trimEndFrames: [String: Int] = [:]
        if replacement.type != .image {
            let rawAvailable = (replacement.resolvedDuration * Double(timeline.fps)).rounded(.down)
            guard let available = Int(exactly: rawAvailable), available > 0 else {
                throw ClipMediaSwapError(message: "Replacement media has no valid duration.")
            }
            for clip in targets {
                let rawConsumed = (Double(clip.durationFrames) * clip.speed).rounded()
                guard let consumed = Int(exactly: rawConsumed), consumed >= 0 else {
                    throw ClipMediaSwapError(message: "Clip has invalid source timing.")
                }
                let (required, overflow) = clip.trimStartFrame.addingReportingOverflow(consumed)
                guard !overflow, required >= 0, required <= available else {
                    throw ClipMediaSwapError(message: "Replacement media is too short for the clip's source range.")
                }
                trimEndFrames[clip.id] = available - required
            }
        }

        if commit {
            replaceClipMediaRef(
                clipId: plan.clipId,
                newAssetId: plan.newMediaRef,
                trimEndFrames: trimEndFrames
            )
        }
        return plan
    }

    private func mediaSwapTargetClipIds(for clipId: String) throws -> [String] {
        guard let clip = clipFor(id: clipId) else { throw ClipMediaSwapError(message: "Clip not found: \(clipId)") }
        guard clip.mediaType != .text,
              clip.sourceClipType != .text,
              clip.sourceClipType != .sequence else {
            throw ClipMediaSwapError(message: "This clip does not support media source swapping.")
        }
        let ids = linkedClipIdsSharingMedia(anchor: clipId).sorted()
        guard !ids.contains(where: { clipFor(id: $0)?.multicamGroupId != nil }) else { throw ClipMediaSwapError(message: "Use change_cam for multicam clips.") }
        return ids
    }
}
