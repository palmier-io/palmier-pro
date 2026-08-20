import CoreGraphics
import Foundation

struct MaskPointMarker {
    let maskId: String
    let clipId: String
    let frame: Int
    let canvasPoint: CGPoint
}

enum MaskTrackingStatus: Equatable {
    case running
    case failed(String)
}

extension EditorViewModel {
    enum ObjectMaskError: LocalizedError {
        case unavailable
        case emptyPrompt
        case invalidPoint

        var errorDescription: String? {
            switch self {
            case .unavailable: "The selected video or project is unavailable."
            case .emptyPrompt: "Enter what to mask, like “person” or “the red car”."
            case .invalidPoint: "Select a point inside the visible clip."
            }
        }
    }

    func beginMaskPointSelection(clipId: String) {
        if maskPointSelectionClipId == clipId {
            cancelMaskPointSelection()
            return
        }
        guard activePreviewTab == .timeline,
              let clip = clipFor(id: clipId),
              clip.mediaType == .video,
              clip.masks?.isEmpty != false
        else { return }
        cancelChromaKeySampling()
        cropEditingActive = false
        pause()
        maskPointMarker = nil
        maskPointSelectionClipId = clipId
    }

    func cancelMaskPointSelection() {
        maskPointSelectionClipId = nil
        maskPointMarker = nil
    }

    func commitMaskPointSelection(
        clipId: String,
        sourcePoint: CGPoint,
        canvasPoint: CGPoint
    ) throws {
        guard maskPointSelectionClipId == clipId,
              sourcePoint.x.isFinite, sourcePoint.y.isFinite,
              (0...1).contains(sourcePoint.x), (0...1).contains(sourcePoint.y),
              canvasPoint.x.isFinite, canvasPoint.y.isFinite,
              (0...1).contains(canvasPoint.x), (0...1).contains(canvasPoint.y),
              let clip = clipFor(id: clipId)
        else { throw ObjectMaskError.invalidPoint }
        let frame = activeFrame
        let sourceTime = try MaskPointMapper.sourceTime(
            clip: clip,
            timelineFrame: frame,
            timelineFPS: timeline.fps
        )
        let mask = ObjectMask(seed: .point(MaskPointSeed(
            x: sourcePoint.x,
            y: sourcePoint.y,
            sourceTime: sourceTime
        )))
        maskPointSelectionClipId = nil
        insertObjectMask(mask, clipId: clipId)
        maskPointMarker = MaskPointMarker(
            maskId: mask.id,
            clipId: clipId,
            frame: frame,
            canvasPoint: canvasPoint
        )
        startTracking(clipId: clipId, maskId: mask.id)
    }

    func addObjectMask(clipId: String, prompt: String) throws {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ObjectMaskError.emptyPrompt }
        guard let clip = clipFor(id: clipId), clip.mediaType == .video else {
            throw ObjectMaskError.unavailable
        }
        let mask = ObjectMask(seed: .text(trimmed))
        insertObjectMask(mask, clipId: clipId)
        startTracking(clipId: clipId, maskId: mask.id)
    }

    func removeObjectMask(clipId: String, maskId: String) {
        cancelMaskWork(maskId: maskId)
        commitClipProperty(clipId: clipId, actionName: L10n.string("Remove Mask")) { clip in
            clip.masks?.removeAll { $0.id == maskId }
            if clip.masks?.isEmpty == true { clip.masks = nil }
        }
    }

    func retryMaskTracking(clipId: String, maskId: String) {
        startTracking(clipId: clipId, maskId: maskId)
    }

    func startTracking(clipId: String, maskId: String) {
        guard maskTrackingTasks[maskId] == nil else { return }
        guard let clip = clipFor(id: clipId),
              let mask = clip.masks?.first(where: { $0.id == maskId }),
              clip.speed.isFinite, clip.speed > 0,
              let sourceURL = mediaResolver.expectedURL(for: clip.mediaRef),
              let targetProjectURL = projectURL
        else {
            maskTrackingStatus[maskId] = .failed(ObjectMaskError.unavailable.localizedDescription)
            return
        }

        let request = MaskingService.Request(
            maskId: maskId,
            mediaRef: clip.mediaRef,
            seed: mask.seed,
            trim: TrimmedSource(
                sourceURL: sourceURL,
                trimStartFrame: clip.trimStartFrame,
                trimEndFrame: clip.trimEndFrame,
                sourceFramesConsumed: clip.sourceFramesConsumed,
                fps: timeline.fps
            ),
            projectId: projectId
        )
        maskTrackingStatus[maskId] = .running
        maskTrackingTasks[maskId] = Task { [weak self] in
            do {
                let staged = try await MaskingService.shared.track(request)
                try Task.checkCancellation()
                guard let self else { return }
                try await self.installMaskTrack(staged, projectURL: targetProjectURL)
                self.attachMaskTrack(clipId: clipId, maskId: maskId, track: staged.track)
            } catch is CancellationError {
                self?.maskTrackingStatus[maskId] = nil
                self?.maskTrackingTasks[maskId] = nil
            } catch {
                Log.masking.error("mask tracking failed mask=\(maskId): \(Log.detail(error))")
                self?.maskTrackingStatus[maskId] = .failed(error.localizedDescription)
                self?.maskTrackingTasks[maskId] = nil
            }
        }
    }

    func setMaskEnabled(clipId: String, maskId: String, enabled: Bool) {
        commitClipProperty(clipId: clipId, actionName: L10n.string(enabled ? "Enable Mask" : "Disable Mask")) { clip in
            clip.mutateMask(id: maskId) { $0.enabled = enabled }
        }
    }

    func setMaskInverted(clipId: String, maskId: String, inverted: Bool) {
        commitClipProperty(clipId: clipId, actionName: L10n.string("Invert Mask")) { clip in
            clip.mutateMask(id: maskId) { $0.inverted = inverted }
        }
    }

    func setMaskRemovesBackground(clipId: String, maskId: String, enabled: Bool) {
        commitClipProperty(clipId: clipId, actionName: L10n.string("Remove Background")) { clip in
            clip.mutateMask(id: maskId) { $0.removesBackground = enabled }
        }
    }

    func previewMaskAdjustment(clipId: String, maskId: String, _ modify: @escaping (inout ObjectMask) -> Void) {
        applyClipProperty(clipId: clipId) { clip in
            clip.mutateMask(id: maskId, modify)
        }
    }

    func commitMaskAdjustment(clipId: String, maskId: String, _ modify: @escaping (inout ObjectMask) -> Void) {
        commitClipProperty(clipId: clipId, actionName: L10n.string("Adjust Mask")) { clip in
            clip.mutateMask(id: maskId, modify)
        }
    }

    // MARK: - Internals

    private func installMaskTrack(_ staged: MaskingService.StagedTrack, projectURL: URL) async throws {
        let stagedURL = staged.matteURL
        defer {
            Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: stagedURL) }
        }
        let preparedURL = try await Task.detached(priority: .userInitiated) {
            try FileIO.prepareStagedFile(from: stagedURL, nextTo: projectURL)
        }.value
        try Task.checkCancellation()
        try projectPackageCoordinator.beginMutation()
        defer { projectPackageCoordinator.endMutation() }
        let installed = try await projectPackageCoordinator.performMutation { [weak self] () -> Bool in
            guard let self,
                  self.projectURL?.standardizedFileURL == projectURL.standardizedFileURL,
                  let destination = MediaResolver.expectedMatteURL(
                      forTrackId: staged.track.id, projectURL: projectURL
                  )
            else {
                try? FileManager.default.removeItem(at: preparedURL)
                return false
            }
            try FileIO.installPreparedFile(from: preparedURL, to: destination)
            return true
        }
        guard installed else { throw CancellationError() }
    }

    private func insertObjectMask(_ mask: ObjectMask, clipId: String) {
        guard let loc = findClip(id: clipId) else { return }
        let before = timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
        var after = before
        after.masks = [mask]
        timeline.tracks[loc.trackIndex].clips[loc.clipIndex] = after
        registerMaskSwap(
            clipId: clipId,
            maskId: mask.id,
            undoTarget: before,
            redoTarget: after
        )
        notifyTimelineChanged()
    }

    private func registerMaskSwap(
        clipId: String,
        maskId: String,
        undoTarget: Clip,
        redoTarget: Clip
    ) {
        registerTimelineUndo(L10n.string("Add Mask")) { vm in
            guard let loc = vm.findClip(id: clipId) else { return }
            vm.timeline.tracks[loc.trackIndex].clips[loc.clipIndex] = undoTarget
            if undoTarget.masks?.contains(where: { $0.id == maskId }) != true {
                vm.cancelMaskWork(maskId: maskId)
            }
            vm.registerMaskSwap(
                clipId: clipId,
                maskId: maskId,
                undoTarget: redoTarget,
                redoTarget: undoTarget
            )
            vm.notifyTimelineChanged()
        }
    }

    private func cancelMaskWork(maskId: String) {
        maskTrackingTasks.removeValue(forKey: maskId)?.cancel()
        maskTrackingStatus[maskId] = nil
        if maskPointMarker?.maskId == maskId {
            maskPointMarker = nil
        }
    }

    private func attachMaskTrack(clipId: String, maskId: String, track: MaskTrack) {
        maskTrackingTasks[maskId] = nil
        guard let loc = findClip(id: clipId),
              var masks = timeline.tracks[loc.trackIndex].clips[loc.clipIndex].masks,
              let index = masks.firstIndex(where: { $0.id == maskId })
        else {
            maskTrackingStatus[maskId] = nil
            return
        }
        masks[index].track = track
        timeline.tracks[loc.trackIndex].clips[loc.clipIndex].masks = masks
        if maskPointMarker?.maskId == maskId {
            maskPointMarker = nil
        }
        maskTrackingStatus[maskId] = nil
        notifyTimelineChanged()
    }

}

extension Clip {
    mutating func mutateMask(id: String, _ modify: (inout ObjectMask) -> Void) {
        guard var masks, let index = masks.firstIndex(where: { $0.id == id }) else { return }
        modify(&masks[index])
        self.masks = masks
    }
}
