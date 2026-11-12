import AppKit
import Foundation

extension EditorViewModel {
    typealias LUTStoring = @Sendable (String, String?) async throws -> String

    struct LUTEditContext {
        let projectId: String?
        let timelineId: String
        let clips: [Clip]
        let trackIds: [String]

        @MainActor
        init(editor: EditorViewModel, clipIds: [String]) throws {
            projectId = editor.projectId
            timelineId = editor.activeTimelineId
            var clips: [Clip] = []
            var trackIds: [String] = []
            for id in Set(clipIds).sorted() {
                guard let location = editor.findClip(id: id), let clip = editor.clipFor(id: id),
                      clip.mediaType == .video || clip.mediaType == .image else {
                    throw ToolError("LUT target is missing or not visual: \(id)")
                }
                clips.append(clip)
                trackIds.append(editor.timeline.tracks[location.trackIndex].id)
            }
            guard !clips.isEmpty else { throw ToolError("No LUT targets.") }
            self.clips = clips
            self.trackIds = trackIds
        }

        @MainActor
        func validate(in editor: EditorViewModel) throws {
            try Task.checkCancellation()
            guard !editor.projectPackageCoordinator.isClosed,
                  projectId == editor.projectId, timelineId == editor.activeTimelineId else {
                throw ToolError("Project or timeline changed during LUT preparation. Retry with current targets.")
            }
            for (clip, trackId) in zip(clips, trackIds) {
                guard editor.clipFor(id: clip.id) == clip,
                      let location = editor.findClip(id: clip.id),
                      editor.timeline.tracks[location.trackIndex].id == trackId else {
                    throw ToolError("Clip changed during LUT preparation: \(clip.id). Retry with current targets.")
                }
            }
        }
    }

    func prepareLUT(
        path: String, context: LUTEditContext,
        store: LUTStoring = { try await LUTLoader.store(path: $0, projectId: $1) }
    ) async throws -> String {
        try await projectPackageCoordinator.withIntent { lease in
            try context.validate(in: self)
            let stored = try await store(path, context.projectId)
            try projectPackageCoordinator.validate(lease)
            try context.validate(in: self)
            return stored
        }
    }

    func startApplyingLUT(path: String, clips: [Clip]) {
        projectPackageCoordinator.startIntent(operation: { _ in
            let context = try LUTEditContext(editor: self, clipIds: clips.map(\.id))
            guard context.clips == clips.sorted(by: { $0.id < $1.id }) else { throw CocoaError(.userCancelled) }
            let stored = try await self.prepareLUT(path: path, context: context)
            try context.validate(in: self)
            self.undo.perform("Apply LUT") {
                self.commitClipProperties(clipIds: context.clips.map(\.id), actionName: "Apply LUT") { clip in
                    var effects = clip.effects ?? []
                    if let index = effects.firstIndex(where: { $0.type == "color.lut" }) {
                        effects[index].params["path"] = EffectParam(string: stored)
                    } else {
                        var effect = Effect(type: "color.lut")
                        effect.params["path"] = EffectParam(string: stored)
                        effects.insert(effect, at: EffectRegistry.insertIndex(effects, for: "color.lut"))
                    }
                    clip.effects = effects
                }
            }
        }, onFailure: { error in
            if let failure = error as? ToolError {
                NSApp.presentError(NSError(domain: "CompositorPro.LUT", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: failure.message]))
            } else {
                NSApp.presentError(error)
            }
        })
    }
}
