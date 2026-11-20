import AVFoundation
import Foundation
import Testing
@testable import CompositorPro

enum PlanAssemblyFixtures {
    @concurrent
    static func makeDirectory() async throws -> URL {
        let directory = try await AudioFinishingFixtures.makeDirectory()
        do {
            let video = try await StoryboardTimingFixtures.video(in: directory)
            let assemblyURL = directory.appendingPathComponent("assembly.mov")
            try FileManager.default.copyItem(at: video.url, to: assemblyURL)
            return directory
        } catch {
            try await AudioFinishingFixtures.remove(directory)
            throw error
        }
    }

    @MainActor
    static func addSource(to editor: EditorViewModel, directory: URL, id: String = "assembly-source") -> MediaAsset {
        let asset = MediaAsset(id: id, url: directory.appendingPathComponent("assembly.mov"), type: .video,
                               name: "Assembly source", duration: 5)
        asset.hasAudio = true
        asset.sourceWidth = 32
        asset.sourceHeight = 32
        editor.mediaAssets.append(asset)
        editor.mediaManifest.entries.append(.init(id: id, name: asset.name, type: .video,
            source: .external(absolutePath: asset.url.path), duration: 5, sourceWidth: 32, sourceHeight: 32))
        return asset
    }

    @MainActor
    static func plan(in editor: EditorViewModel, sourceId: String = "assembly-source") throws -> EditPlan {
        let plan = EditPlan(id: "assembly-plan", name: "Cut", timelineId: editor.activeTimelineId,
            fps: editor.timeline.fps, width: editor.timeline.width, height: editor.timeline.height,
            shots: [.init(id: "opening", title: "Opening", startFrame: 0, endFrame: 30, mediaRef: sourceId,
                          sourceStartSeconds: 1, sourceEndSeconds: 2),
                    .init(id: "ending", title: "Ending", startFrame: 30, endFrame: 60, mediaRef: sourceId,
                          sourceStartSeconds: 3, sourceEndSeconds: 4)])
        try editor.changeEditPlans(creates: [plan], actionName: "Create Plan")
        try editor.changeEditPlanStatus(id: plan.id, to: .approved, actionName: "Approve Plan")
        return try #require(editor.editPlan(id: plan.id))
    }

    @concurrent
    static func persisted(plan: EditPlan, timeline: Timeline, directory: URL) async throws -> (EditPlan, Timeline) {
        let planURL = directory.appendingPathComponent("plan.json")
        let timelineURL = directory.appendingPathComponent("timeline.json")
        try JSONEncoder().encode(plan).write(to: planURL)
        try JSONEncoder().encode(timeline).write(to: timelineURL)
        return (try JSONDecoder().decode(EditPlan.self, from: Data(contentsOf: planURL)),
                try JSONDecoder().decode(Timeline.self, from: Data(contentsOf: timelineURL)))
    }
}
