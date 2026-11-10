import Foundation

extension EditorViewModel {
    typealias AudioMixFinishing = @Sendable (AudioMixFinisher.Input, AudioMixRequest, Bool) async throws -> AudioMixFinisher.Result

    struct AudioMixOperation {
        let id: UUID
        let revision: VisualReviewRevision
        let request: AudioMixRequest
        let replaceAutomation: Bool
        let task: Task<AudioMixReceipt, Error>
    }

    func mixAudio(
        request rawRequest: AudioMixRequest, replaceAutomation: Bool = false,
        finish: @escaping AudioMixFinishing = { try await AudioMixFinisher.finish($0, request: $1, replaceAutomation: $2) }
    ) async throws -> AudioMixReceipt {
        try Task.checkCancellation()
        let request = try rawRequest.validated()
        let revision = visualReviewRevision
        if let operation = audioMixOperation {
            guard operation.request == request, operation.replaceAutomation == replaceAutomation,
                  operation.revision == revision else {
                throw AudioFinishingError(reason: "Another mix is being prepared; wait for it or cancel it before changing the request.")
            }
            var receipt = try await awaitMix(operation.task)
            receipt.changed = false
            receipt.changedClipIds = []
            return receipt
        }
        let input = AudioMixFinisher.Input(timeline: timeline, timelines: timelines, urls: mediaResolver.expectedURLMap())
        let assets = mediaAssetsById
        let lease = try projectPackageCoordinator.admitIntent()
        let id = UUID()
        let task = Task { @MainActor in
            try await projectPackageCoordinator.withIntent(lease) { _ in
                let result = try await finish(input, request, replaceAutomation)
                try Task.checkCancellation()
                guard !projectPackageCoordinator.isClosing, visualReviewRevision == revision,
                      activeTimelineId == input.timeline.id else { throw AudioMixError.staleState }
                for ref in result.receipt.state.sourceVersions.keys {
                    guard let asset = mediaAssetsById[ref], asset === assets[ref],
                          asset.url == input.urls[ref], mediaResolver.expectedURL(for: ref) == input.urls[ref],
                          asset.generationStatus == .none, !missingMediaRefs.contains(ref),
                          !unprocessableMediaRefs.contains(ref) else { throw AudioMixError.staleState }
                }
                let refs = Set(result.receipt.state.sourceVersions.keys)
                guard enhancementJobs.values.allSatisfy({ job in
                    (job.status != .queued && job.status != .running) || job.mediaRefs.isDisjoint(with: refs)
                }) else {
                    throw AudioFinishingError(reason: "Audio enhancement is unfinished; wait for its terminal result before committing a measured mix.")
                }
                if result.receipt.changed {
                    withTimelineSwap(actionName: L10n.string("Mix Audio"), refreshVisuals: false) {
                        timeline = result.timeline
                    }
                    onProjectCheckpointRequired?()
                }
                return result.receipt
            }
        }
        audioMixOperation = AudioMixOperation(id: id, revision: revision, request: request,
                                             replaceAutomation: replaceAutomation, task: task)
        defer { if audioMixOperation?.id == id { audioMixOperation = nil } }
        return try await awaitMix(task)
    }

    func cancelAudioMix() {
        audioMixOperation?.task.cancel()
    }

    private func awaitMix(_ task: Task<AudioMixReceipt, Error>) async throws -> AudioMixReceipt {
        try await withTaskCancellationHandler {
            let receipt = try await task.value
            try Task.checkCancellation()
            return receipt
        } onCancel: {
            task.cancel()
        }
    }
}
