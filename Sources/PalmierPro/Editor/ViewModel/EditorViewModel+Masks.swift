import Foundation

enum MaskTrackingStatus: Equatable {
    case running
    case failed(String)
}

extension EditorViewModel {
    enum ObjectMaskError: LocalizedError {
        case unavailable
        case emptyPrompt

        var errorDescription: String? {
            switch self {
            case .unavailable: "The selected video or project is unavailable."
            case .emptyPrompt: "Enter what to mask, like “person” or “the red car”."
            }
        }
    }

    func addObjectMask(clipId: String, prompt: String) throws {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ObjectMaskError.emptyPrompt }
        guard let clip = clipFor(id: clipId), clip.mediaType == .video else {
            throw ObjectMaskError.unavailable
        }
        let mask = ObjectMask(seed: .text(trimmed))
        commitClipProperty(clipId: clipId, actionName: L10n.string("Add Mask")) { clip in
            clip.masks = (clip.masks ?? []) + [mask]
        }
        startTracking(clipId: clipId, maskId: mask.id)
    }

    func removeObjectMask(clipId: String, maskId: String) {
        maskTrackingTasks.removeValue(forKey: maskId)?.cancel()
        maskTrackingStatus[maskId] = nil
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
