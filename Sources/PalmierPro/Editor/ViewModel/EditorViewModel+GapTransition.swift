import Foundation

extension EditorViewModel {
    func gapTransitionContext(for gap: GapSelection) -> GapTransitionContext? {
        GapTransitionPlanner.context(for: gap, in: timeline)
    }

    func beginGapTransition(_ context: GapTransitionContext) {
        cancelPendingGapTransitionSeed()
        guard gapTransitionContext(
            for: GapSelection(trackIndex: context.trackIndex, range: context.range)
        ) == context else {
            mediaPanelToast = "The gap changed. Select it again."
            return
        }

        let requestId = UUID()
        pendingGapTransitionRequestId = requestId
        mediaPanelToast = "Preparing transition frames…"
        pendingGapTransitionSeedTask = Task { @MainActor [weak self] in
            await self?.prepareGapTransition(context, requestId: requestId)
        }
    }

    func cancelPendingGapTransitionSeed() {
        pendingGapTransitionSeedTask?.cancel()
        pendingGapTransitionSeedTask = nil
        pendingGapTransitionRequestId = nil
    }

    func gapTransitionPlacementIssue(
        _ placement: PendingGapTransitionPlacement,
        generationDurationSeconds: Int
    ) -> String? {
        let context = placement.context
        guard activeTimelineId == context.timelineId else {
            return "Return to the original timeline before generating this transition."
        }
        guard timelineRenderRevision == placement.timelineRevision else {
            return "The timeline changed. Create the transition again."
        }
        guard gapTransitionContext(
            for: GapSelection(trackIndex: context.trackIndex, range: context.range)
        ) == context else {
            return "The gap changed. Create the transition again."
        }
        guard GapTransitionPlanner.playbackRate(
            generationDurationSeconds: generationDurationSeconds,
            targetFrameCount: context.range.length,
            fps: timeline.fps
        ) != nil,
        generationDurationSeconds * timeline.fps >= context.range.length else {
            return "Choose a duration that covers the gap, up to 15 seconds."
        }
        return nil
    }

    @discardableResult
    func placeGeneratingGapTransition(
        placeholderId: String,
        placement: PendingGapTransitionPlacement,
        generationDurationSeconds: Int
    ) -> String? {
        guard gapTransitionPlacementIssue(
            placement,
            generationDurationSeconds: generationDurationSeconds
        ) == nil,
        let asset = mediaAssetsById[placeholderId],
        let trackIndex = timeline.tracks.firstIndex(where: { $0.id == placement.context.trackId }),
        let speed = GapTransitionPlanner.playbackRate(
            generationDurationSeconds: generationDurationSeconds,
            targetFrameCount: placement.context.range.length,
            fps: timeline.fps
        ) else { return nil }

        let before = timeline
        let selectedGapBefore = selectedGap
        let selectedClipIdsBefore = selectedClipIds
        let ids = undo.withoutRegistration {
            placeClip(
                asset: asset,
                trackIndex: trackIndex,
                startFrame: placement.context.range.start,
                durationFrames: placement.context.range.length,
                addLinkedAudio: false
            )
        }
        guard let clipId = ids.first, let location = findClip(id: clipId) else {
            timeline = before
            return nil
        }

        timeline.tracks[location.trackIndex].clips[location.clipIndex].speed = speed
        timeline.tracks[location.trackIndex].clips[location.clipIndex].trimStartFrame = 0
        timeline.tracks[location.trackIndex].clips[location.clipIndex].trimEndFrame = 0
        selectedGap = nil
        selectedClipIds = [clipId]
        registerGapTransitionPlacementSwap(
            targetTimeline: before,
            targetGap: selectedGapBefore,
            targetClipIds: selectedClipIdsBefore,
            inverseTimeline: timeline,
            inverseGap: nil,
            inverseClipIds: [clipId]
        )
        notifyTimelineChanged()
        return clipId
    }

    private func prepareGapTransition(
        _ context: GapTransitionContext,
        requestId: UUID
    ) async {
        defer {
            if pendingGapTransitionRequestId == requestId {
                pendingGapTransitionSeedTask = nil
                pendingGapTransitionRequestId = nil
            }
        }

        guard let model = gapTransitionModel() else {
            mediaPanelToast = "Seedance 2.0 with first and last frames at 720p is unavailable."
            return
        }
        guard let duration = GapTransitionPlanner.generationDuration(
            gapFrameCount: context.range.length,
            fps: timeline.fps,
            supportedDurations: model.durations
        ) else {
            mediaPanelToast = "Seedance 2.0 has no duration that fits this gap."
            return
        }
        guard let track = timeline.tracks.first(where: { $0.id == context.trackId }),
              let previous = track.clips.first(where: { $0.id == context.previousClipId }),
              let next = track.clips.first(where: { $0.id == context.nextClipId }),
              !isClipMediaOffline(previous),
              !isClipMediaOffline(next) else {
            mediaPanelToast = "Relink the clips around this gap before generating a transition."
            return
        }

        let timelineSnapshot = timeline
        let timelineRevision = timelineRenderRevision
        let mediaURLs = mediaResolver.expectedURLMap()
        let sourceSizes = Dictionary(uniqueKeysWithValues: mediaAssets.compactMap { asset in
            guard let width = asset.sourceWidth, let height = asset.sourceHeight else { return nil }
            return (asset.id, CGSize(width: width, height: height))
        })
        let resolveTimeline = timelineResolver()
        let missingMediaRefs = missingMediaRefs

        do {
            let frames = try await GapTransitionFrameRenderer.renderBoundaryFrames(
                timeline: timelineSnapshot,
                context: context,
                mediaURLs: mediaURLs,
                sourceSizes: sourceSizes,
                resolveTimeline: resolveTimeline,
                missingMediaRefs: missingMediaRefs
            )
            try Task.checkCancellation()
            guard pendingGapTransitionRequestId == requestId,
                  timelineRenderRevision == timelineRevision,
                  activeTimelineId == context.timelineId,
                  gapTransitionContext(
                    for: GapSelection(trackIndex: context.trackIndex, range: context.range)
                  ) == context,
                  frames.count == 2 else { return }

            guard let firstFrame = await importPastedImageData(frames[0]) else {
                mediaPanelToast = "The transition frames could not be saved."
                return
            }
            firstFrame.name = "Transition First Frame"
            updateManifestMetadata(for: [firstFrame])
            try Task.checkCancellation()
            guard pendingGapTransitionRequestId == requestId,
                  timelineRenderRevision == timelineRevision,
                  activeTimelineId == context.timelineId,
                  gapTransitionContext(
                    for: GapSelection(trackIndex: context.trackIndex, range: context.range)
                  ) == context else { return }

            guard let lastFrame = await importPastedImageData(frames[1]) else {
                mediaPanelToast = "The last transition frame could not be saved."
                return
            }
            lastFrame.name = "Transition Last Frame"
            updateManifestMetadata(for: [lastFrame])
            try Task.checkCancellation()
            guard pendingGapTransitionRequestId == requestId,
                  timelineRenderRevision == timelineRevision,
                  activeTimelineId == context.timelineId,
                  gapTransitionContext(
                    for: GapSelection(trackIndex: context.trackIndex, range: context.range)
                  ) == context else { return }

            var stored = GenerationInput(
                prompt: GapTransitionPlanner.prompt,
                model: model.id,
                duration: duration,
                aspectRatio: GapTransitionPlanner.closestAspectRatio(
                    width: timeline.width,
                    height: timeline.height,
                    supportedAspectRatios: model.aspectRatios
                ) ?? "",
                resolution: "720p"
            )
            stored.imageURLAssetIds = [firstFrame.id, lastFrame.id]
            seedGenerationPanel(
                asset: firstFrame,
                stored: stored,
                gapTransitionPlacement: PendingGapTransitionPlacement(
                    context: context,
                    timelineRevision: timelineRevision,
                    firstFrameAssetId: firstFrame.id,
                    lastFrameAssetId: lastFrame.id
                )
            )
            mediaPanelToast = nil
        } catch is CancellationError {
            return
        } catch {
            mediaPanelToast = MediaPanelToast(message: error.localizedDescription)
        }
    }

    private func gapTransitionModel() -> VideoModelConfig? {
        let capable = VideoModelConfig.allModels.filter {
            !$0.requiresSourceVideo
                && $0.supportsFirstFrame
                && $0.supportsLastFrame
                && ($0.resolutions?.contains("720p") ?? false)
        }
        if let exact = capable.first(where: {
            $0.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare("Seedance 2.0") == .orderedSame
        }) {
            return exact
        }
        return capable.first {
            $0.displayName.localizedCaseInsensitiveContains("Seedance 2.0")
                && !$0.displayName.localizedCaseInsensitiveContains("Fast")
        }
    }

    private func registerGapTransitionPlacementSwap(
        targetTimeline: Timeline,
        targetGap: GapSelection?,
        targetClipIds: Set<String>,
        inverseTimeline: Timeline,
        inverseGap: GapSelection?,
        inverseClipIds: Set<String>
    ) {
        registerTimelineUndo("Add Generated Transition") { vm in
            vm.timeline = targetTimeline
            vm.selectedGap = targetGap
            vm.selectedClipIds = targetClipIds
            vm.notifyTimelineChanged()
            vm.registerGapTransitionPlacementSwap(
                targetTimeline: inverseTimeline,
                targetGap: inverseGap,
                targetClipIds: inverseClipIds,
                inverseTimeline: targetTimeline,
                inverseGap: targetGap,
                inverseClipIds: targetClipIds
            )
        }
    }
}
