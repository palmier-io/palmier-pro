import Foundation

struct TemplateGenerationState: Equatable, Sendable {
    var assetId: String
    var assetName: String
    var progress: ReelAnalysisProgress
}

struct TemplateGenerationReceipt: Sendable {
    var timelineId: String
    var slotClipIds: [String]
    var warnings: [TemplateWarning]
}

extension EditorViewModel {
    enum TemplateStudioError: LocalizedError {
        case assetNotFound
        case notAVideo
        case notATemplateSlot
        case generationInProgress

        var errorDescription: String? {
            switch self {
            case .assetNotFound: "The media asset could not be found."
            case .notAVideo: "Templates can only be created from video media."
            case .notATemplateSlot: "The clip is not a template slot."
            case .generationInProgress: "A template is already being generated. Wait for it to finish."
            }
        }
    }

    /// Analyzes a reel asset and appends the generated template as a new timeline.
    @discardableResult
    func createTemplateFromReel(
        assetId: String,
        mode: TemplateMode = .placeholders
    ) async throws -> TemplateGenerationReceipt {
        guard templateGeneration == nil else { throw TemplateStudioError.generationInProgress }
        guard let asset = mediaAssetsById[assetId] else { throw TemplateStudioError.assetNotFound }
        guard asset.type == .video else { throw TemplateStudioError.notAVideo }

        let sourceURL = asset.url
        templateGeneration = TemplateGenerationState(
            assetId: assetId,
            assetName: asset.name,
            progress: ReelAnalysisProgress(stage: .scenes, fraction: 0)
        )
        defer { templateGeneration = nil }

        let analysis = try await analyzeReel(at: sourceURL, assetId: assetId)
        try Task.checkCancellation()

        guard let current = mediaAssetsById[assetId], current.url == sourceURL else {
            throw TemplateStudioError.assetNotFound
        }

        let result = TemplateGenerator.makeTimeline(
            from: analysis,
            sourceMediaRef: assetId,
            options: TemplateOptions(name: templateName(for: current.name), mode: mode)
        )

        timelines.append(result.timeline)
        registerRemoveUndo(for: result.timeline.id, actionName: "Create Template")
        activateTimeline(result.timeline.id)

        if let warning = result.warnings.first {
            mediaPanelToast = MediaPanelToast(message: warning.message)
        }
        return TemplateGenerationReceipt(
            timelineId: result.timeline.id,
            slotClipIds: result.slotClipIds,
            warnings: result.warnings
        )
    }

    func cancelTemplateGeneration() {
        templateGenerationTask?.cancel()
        templateGenerationTask = nil
        templateGeneration = nil
    }

    /// Fills an unfilled template slot with a media asset, preserving the slot's timing.
    /// The slot's suggested speed applies only when the source is long enough at that speed.
    func fillTemplateSlot(clipId: String, assetId: String) throws {
        guard let location = findClip(id: clipId) else { throw TemplateStudioError.notATemplateSlot }
        let slotClip = timeline.tracks[location.trackIndex].clips[location.clipIndex]
        guard let slot = slotClip.templateSlot else { throw TemplateStudioError.notATemplateSlot }
        guard let asset = mediaAssetsById[assetId] else { throw TemplateStudioError.assetNotFound }
        guard asset.type == .video else { throw TemplateStudioError.notAVideo }

        prepareMediaVisuals(for: asset)

        var filled = slotClip
        filled.mediaRef = assetId
        filled.mediaType = asset.type
        filled.sourceClipType = asset.type
        filled.trimStartFrame = 0
        filled.trimEndFrame = 0
        if let speed = slot.suggestedSpeed,
           asset.duration * Double(timeline.fps) >= Double(slotClip.durationFrames) * speed {
            filled.speed = speed
        }
        timeline.tracks[location.trackIndex].clips[location.clipIndex] = filled

        registerTimelineUndo("Replace Template Slot") { editor in
            guard let location = editor.findClip(id: clipId) else { return }
            editor.timeline.tracks[location.trackIndex].clips[location.clipIndex] = slotClip
            editor.notifyTimelineChanged()
        }
        notifyTimelineChanged()
    }

    private func analyzeReel(at sourceURL: URL, assetId: String) async throws -> ReelAnalysis {
        do {
            return try await ReelAnalyzer.analysis(for: sourceURL, mediaRef: assetId) { progress in
                Task { @MainActor [weak self] in
                    guard let self, templateGeneration?.assetId == assetId else { return }
                    templateGeneration?.progress = progress
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ReelAnalyzer.AnalyzeError {
            throw error
        } catch {
            throw ReelAnalyzer.AnalyzeError.failed(error.localizedDescription)
        }
    }

    private func templateName(for assetName: String) -> String {
        let base = L10n.string("\(assetName) Template")
        var name = base
        var suffix = 2
        while timelines.contains(where: { $0.name == name }) {
            name = "\(base) \(suffix)"
            suffix += 1
        }
        return name
    }
}
