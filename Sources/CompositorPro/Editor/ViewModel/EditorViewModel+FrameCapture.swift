import Foundation

enum FrameCaptureSource: Sendable {
    case timeline(frame: Int)
    case media(mediaRef: String, sourceSeconds: Double)
}

struct FrameCaptureReceipt {
    let asset: MediaAsset
    let width: Int
    let height: Int
    let timelineId: String?
    let actualSourceSeconds: Double?
    let destinationFolderWasRemoved: Bool
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
        try await projectPackageCoordinator.withMutation { lease in
            try await self.performFrameCapture(source: source, name: requestedName, folderId: folderId, lease: lease)
        }
    }

    private func performFrameCapture(
        source: FrameCaptureSource, name requestedName: String?, folderId: String?,
        lease: ProjectPackageCoordinator.MutationLease
    ) async throws -> FrameCaptureReceipt {
        guard let package = projectURL else { throw FrameCaptureError.noProject }
        if let folderId, folder(id: folderId) == nil {
            throw FrameCaptureError.destinationFolderMissing
        }

        let defaultName: String
        let capturedTimelineId: String?
        let rendered: RenderedFrame
        let validateSource: @MainActor () throws -> Void
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
            let revision = timelineRenderRevision
            validateSource = {
                guard self.timeline == timeline, self.timelineRenderRevision == revision,
                      self.mediaResolver.expectedURLMap() == mediaURLs else { throw CancellationError() }
            }
            rendered = try await FrameCaptureRenderer.timeline(
                timeline,
                frame: frame,
                mediaURLs: mediaURLs,
                resolveTimeline: resolveTimeline,
                missingMediaRefs: missingMediaRefs
            )

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
            validateSource = {
                guard self.mediaAssetsById[mediaRef] === media, media.url == url else { throw CancellationError() }
            }
            rendered = try await FrameCaptureRenderer.media(url: url, sourceSeconds: sourceSeconds)
        }

        let filename = "frame-\(UUID().uuidString).png"
        var destinationFolderStillExists = true

        let asset = MediaAsset(
            url: package.appendingPathComponent("media/\(filename)"),
            type: .image,
            name: requestedName ?? defaultName,
            duration: Defaults.imageDurationSeconds
        )
        if let thumbnail = rendered.thumbnail {
            asset.installThumbnail(thumbnail, maximumPixelSize: ImageEncoder.libraryThumbnailMaxPixelSize)
        }
        asset.sourceWidth = rendered.width
        asset.sourceHeight = rendered.height

        _ = try await commitStagedProjectMedia(rendered.stagedURL, filename: filename, lease: lease, validate: validateSource) { destination in
            asset.url = destination
            destinationFolderStillExists = folderId.map { self.folder(id: $0) != nil } ?? true
            asset.folderId = destinationFolderStillExists ? folderId : nil
            self.undo.perform("Capture Frame") {
                let before = self.mediaLibraryUndoSnapshot()
                self.importMediaAsset(asset)
                self.searchIndex.schedule(asset)
                self.prepareMediaVisuals(for: asset)
                self.undo.register("Capture Frame", withTarget: self) { editor in
                    editor.restoreMediaLibraryUndoSnapshot(before, actionName: "Capture Frame")
                }
                self.onProjectCheckpointRequired?()
            }
        }

        return FrameCaptureReceipt(
            asset: asset,
            width: rendered.width,
            height: rendered.height,
            timelineId: capturedTimelineId,
            actualSourceSeconds: rendered.actualSourceSeconds,
            destinationFolderWasRemoved: !destinationFolderStillExists
        )
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
                sourceSeconds: SourceMediaTimebase.relativeSeconds(
                    relativeFrame: sourcePlayheadFrame,
                    fps: timeline.fps
                )
            )
        }
        let folderId = mediaPanelCurrentFolderId

        frameCaptureTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { frameCaptureTask = nil }
            do {
                let receipt = try await captureFrameToMedia(source: source, folderId: folderId)
                let message = receipt.destinationFolderWasRemoved
                    ? L10n.string(
                        "Captured \(receipt.asset.name). The destination folder was removed, so the frame was saved at the top level of Media."
                    )
                    : L10n.string("Captured \(receipt.asset.name).")
                mediaPanelToast = MediaPanelToast(
                    message: message,
                    kind: receipt.destinationFolderWasRemoved ? .warning : .success
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
