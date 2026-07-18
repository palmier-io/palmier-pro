import Foundation

enum FrameCaptureSource: Sendable, Equatable {
    case timeline(frame: Int)
    case media(mediaRef: String, sourceSeconds: Double)
}

struct FrameCaptureReceipt {
    let asset: MediaAsset
    let width: Int
    let height: Int
    let source: FrameCaptureSource
    let timelineId: String?
    let actualSourceSeconds: Double?
    let warning: String?
}

extension EditorViewModel {
    enum FrameCaptureError: LocalizedError {
        case noProject
        case timelineEmpty
        case timelineFrameOutOfRange(frame: Int, totalFrames: Int)
        case mediaNotFound(String)
        case mediaNotVideo(String)
        case mediaUnavailable(String)
        case destinationFolderMissing

        var errorDescription: String? {
            switch self {
            case .noProject:
                "No project is open."
            case .timelineEmpty:
                "The timeline is empty."
            case .timelineFrameOutOfRange(let frame, let totalFrames):
                "Timeline frame \(frame) is outside 0..<\(totalFrames)."
            case .mediaNotFound(let mediaRef):
                "Media asset not found: \(mediaRef)"
            case .mediaNotVideo(let mediaRef):
                "Media asset \(mediaRef) is not a video."
            case .mediaUnavailable(let reason):
                reason
            case .destinationFolderMissing:
                "The destination media folder no longer exists."
            }
        }
    }

    @discardableResult
    func captureFrameToMedia(
        source: FrameCaptureSource,
        name requestedName: String? = nil,
        folderId: String? = nil
    ) async throws -> FrameCaptureReceipt {
        guard projectURL != nil else { throw FrameCaptureError.noProject }
        if let folderId, folder(id: folderId) == nil {
            throw FrameCaptureError.destinationFolderMissing
        }

        let defaultName: String
        let capturedTimelineId: String?
        let render: @Sendable () async throws -> RenderedFrame
        switch source {
        case .timeline(let frame):
            let timeline = timeline
            guard timeline.totalFrames > 0 else { throw FrameCaptureError.timelineEmpty }
            guard frame >= 0, frame < timeline.totalFrames else {
                throw FrameCaptureError.timelineFrameOutOfRange(frame: frame, totalFrames: timeline.totalFrames)
            }
            let mediaURLs = mediaResolver.expectedURLMap()
            let resolveTimeline = timelineResolver()
            let missingMediaRefs = missingMediaRefs
            defaultName = "Frame \(frame)"
            capturedTimelineId = timeline.id
            render = {
                try await FrameCaptureRenderer.timeline(
                    timeline,
                    frame: frame,
                    mediaURLs: mediaURLs,
                    resolveTimeline: resolveTimeline,
                    missingMediaRefs: missingMediaRefs
                )
            }

        case .media(let mediaRef, let sourceSeconds):
            guard let media = mediaAssetsById[mediaRef] else {
                throw FrameCaptureError.mediaNotFound(mediaRef)
            }
            guard media.type == .video else { throw FrameCaptureError.mediaNotVideo(mediaRef) }
            if media.isGenerating {
                throw FrameCaptureError.mediaUnavailable("Media asset \(mediaRef) is still preparing.")
            }
            if case .failed(let reason) = media.generationStatus {
                throw FrameCaptureError.mediaUnavailable("Media asset \(mediaRef) failed: \(reason)")
            }
            let url = media.url
            defaultName = "\(media.name) frame"
            capturedTimelineId = nil
            render = { try await FrameCaptureRenderer.media(url: url, sourceSeconds: sourceSeconds) }
        }

        let rendered = try await render()
        do {
            try Task.checkCancellation()
            guard projectURL != nil else { throw FrameCaptureError.noProject }
            if let folderId, folder(id: folderId) == nil {
                throw FrameCaptureError.destinationFolderMissing
            }
            try projectPackageCoordinator.beginMutation()
        } catch {
            await FrameCaptureRenderer.discardStagedFile(at: rendered.stagedURL)
            throw error
        }
        defer { projectPackageCoordinator.endMutation() }

        let filename = "frame-\(UUID().uuidString.prefix(8)).png"
        let committedURL = try await commitStagedProjectMedia(
            rendered.stagedURL,
            filename: filename,
            workAlreadyAdmitted: true
        )

        let destinationFolderStillExists = folderId.map { folder(id: $0) != nil } ?? true

        let name = requestedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = name.flatMap { $0.isEmpty ? nil : $0 } ?? defaultName
        let asset = MediaAsset(
            url: committedURL,
            type: .image,
            name: displayName,
            duration: Defaults.imageDurationSeconds
        )
        asset.folderId = destinationFolderStillExists ? folderId : nil
        asset.sourceWidth = rendered.width
        asset.sourceHeight = rendered.height

        undo.perform("Capture Frame") {
            addCapturedFrameAsset(asset)
        }

        return FrameCaptureReceipt(
            asset: asset,
            width: rendered.width,
            height: rendered.height,
            source: source,
            timelineId: capturedTimelineId,
            actualSourceSeconds: rendered.actualSourceSeconds,
            warning: destinationFolderStillExists
                ? nil
                : "The destination folder was removed, so the frame was saved at the top level of Media."
        )
    }

    private func addCapturedFrameAsset(_ asset: MediaAsset) {
        guard !mediaAssets.contains(where: { $0.id == asset.id }) else { return }
        importMediaAsset(asset)
        undo.register("Capture Frame", withTarget: self) { editor in
            editor.removeCapturedFrameAsset(asset)
        }
        searchIndex.schedule(asset)
        prepareMediaVisuals(for: asset)
        onProjectCheckpointRequired?()
    }

    private func removeCapturedFrameAsset(_ asset: MediaAsset) {
        guard mediaAssets.contains(where: { $0.id == asset.id }) else { return }
        mediaAssets.removeAll { $0.id == asset.id }
        mediaManifest.entries.removeAll { $0.id == asset.id }
        selectedMediaAssetIds.remove(asset.id)
        closePreviewTab(id: PreviewTab.mediaAssetTabId(for: asset.id))
        missingMediaRefs.remove(asset.id)
        offlineMediaRefs.remove(asset.id)
        unprocessableMediaRefs.remove(asset.id)
        undo.register("Capture Frame", withTarget: self) { editor in
            editor.addCapturedFrameAsset(asset)
        }
        onProjectCheckpointRequired?()
    }

    func captureCurrentFrameToMedia() {
        guard frameCaptureTask == nil else { return }

        let source: FrameCaptureSource
        switch activePreviewTab {
        case .timeline:
            source = .timeline(frame: currentFrame)
        case .mediaAsset(let id, _, let type):
            guard type == .video else { return }
            source = .media(
                mediaRef: id,
                sourceSeconds: Double(sourcePlayheadFrame) / Double(max(1, timeline.fps))
            )
        }
        let folderId = mediaPanelCurrentFolderId

        frameCaptureTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { frameCaptureTask = nil }
            do {
                let receipt = try await captureFrameToMedia(source: source, folderId: folderId)
                mediaPanelToast = MediaPanelToast(
                    message: receipt.warning.map { "Captured \(receipt.asset.name). \($0)" }
                        ?? "Captured \(receipt.asset.name).",
                    kind: receipt.warning == nil ? .success : .warning
                )
            } catch is CancellationError {
                return
            } catch {
                Log.project.error("capture frame failed: \(error.localizedDescription)")
                mediaPanelToast = MediaPanelToast(message: error.localizedDescription)
            }
        }
    }
}
