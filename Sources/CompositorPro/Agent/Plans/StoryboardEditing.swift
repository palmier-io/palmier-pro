import Foundation

struct StoryboardBeatEdit: Decodable, Sendable, Equatable {
    var beatId: String
    var text: String
    var spokenText: String?
}

struct StoryboardVisualEdit: Decodable, Sendable {
    var mediaRef: String
    var license: String
    var attribution: String
    var sourceStartSeconds: Double?
    var sourceEndSeconds: Double?
}

enum StoryboardEditing {
    static func revise(plan: EditPlan, sceneId: String, beatEdits: [StoryboardBeatEdit],
                       visual: StoryboardVisualEdit?) throws -> EditPlan {
        guard let sceneIndex = plan.shots.firstIndex(where: { $0.id == sceneId }),
              !beatEdits.isEmpty || visual != nil else {
            throw EditPlanValidationError.invalidReference("Select an existing scene and provide narration or a replacement visual.")
        }
        var next = plan
        if !beatEdits.isEmpty {
            guard let link = plan.shots[sceneIndex].narrationLink, let beats = plan.scriptBeats,
                  let first = beats.firstIndex(where: { $0.beatId == link.firstBeatId }),
                  let last = beats.firstIndex(where: { $0.beatId == link.lastBeatId }), first <= last,
                  Set(beatEdits.map(\.beatId)).count == beatEdits.count else {
                throw EditPlanValidationError.invalidReference("Narration edits require unique beat IDs belonging to the selected scene.")
            }
            let sceneBeats = Set(beats[first...last].map(\.beatId))
            var revisedBeats = beats
            for edit in beatEdits {
                guard sceneBeats.contains(edit.beatId), let index = beats.firstIndex(where: { $0.beatId == edit.beatId }) else {
                    throw EditPlanValidationError.invalidReference("Beat '\(edit.beatId)' does not belong to scene '\(sceneId)'.")
                }
                revisedBeats[index].text = edit.text
                revisedBeats[index].spokenText = edit.spokenText
                revisedBeats[index] = try revisedBeats[index].validated()
            }
            next.scriptBeats = revisedBeats
        }
        if let visual {
            next.shots[sceneIndex].mediaRef = visual.mediaRef
            next.shots[sceneIndex].candidateURL = nil
            next.shots[sceneIndex].license = visual.license
            next.shots[sceneIndex].attribution = visual.attribution
            next.shots[sceneIndex].sourceStartSeconds = visual.sourceStartSeconds
            next.shots[sceneIndex].sourceEndSeconds = visual.sourceEndSeconds
            next.shots[sceneIndex] = try EditPlan.validatedShot(next.shots[sceneIndex])
        }
        return next
    }

    static func reorder(plan: EditPlan, sceneIds: [String]) throws -> EditPlan {
        guard sceneIds.count == plan.shots.count, Set(sceneIds).count == sceneIds.count,
              Set(sceneIds) == Set(plan.shots.map(\.id)) else {
            throw EditPlanValidationError.invalidReference("Scene order must contain every current scene ID exactly once.")
        }
        guard sceneIds != plan.shots.map(\.id) else { return plan }
        let beats = plan.scriptBeats ?? []
        var blocks: [String: [ScriptBeat]] = [:]
        var used = Set<String>()
        for shot in plan.shots {
            try EditPlan.validatedFrames(start: shot.startFrame, end: shot.endFrame)
            guard let link = shot.narrationLink,
                  let first = beats.firstIndex(where: { $0.beatId == link.firstBeatId }),
                  let last = beats.firstIndex(where: { $0.beatId == link.lastBeatId }), first <= last else {
                throw EditPlanValidationError.invalidReference("Reordering requires each scene to own an ordered narration block.")
            }
            let block = Array(beats[first...last])
            guard block.allSatisfy({ used.insert($0.beatId).inserted }) else {
                throw EditPlanValidationError.invalidReference("Scenes share narration beats; resolve ownership before reordering.")
            }
            blocks[shot.id] = block
        }
        guard used == Set(beats.map(\.beatId)) else {
            throw EditPlanValidationError.invalidReference("Reordering requires every narration beat to belong to one scene.")
        }
        let chronological = plan.shots.sorted { $0.startFrame < $1.startFrame }
        guard zip(chronological, chronological.dropFirst()).allSatisfy({ $0.endFrame == $1.startFrame }) else {
            throw EditPlanValidationError.invalidReference("Reordering requires a contiguous sequence without overlaps or gaps.")
        }
        var next = plan
        var cursor = chronological.first?.startFrame ?? 0
        next.shots = try sceneIds.map { id in
            guard var shot = plan.shots.first(where: { $0.id == id }) else {
                throw EditPlanValidationError.invalidReference("Unknown scene '\(id)'.")
            }
            let duration = shot.endFrame - shot.startFrame
            guard cursor <= maxFrameArg - duration else { throw EditPlanValidationError.invalidRange }
            shot.startFrame = cursor
            cursor += duration
            shot.endFrame = cursor
            return shot
        }
        next.scriptBeats = sceneIds.flatMap { blocks[$0] ?? [] }
        next.sections = try plan.sections.map { original in
            let members = Set(plan.shots.filter { $0.startFrame >= original.startFrame && $0.endFrame <= original.endFrame }.map(\.id))
            let selected = next.shots.filter { members.contains($0.id) }
            guard !selected.isEmpty, let first = selected.first, let last = selected.last,
                  zip(selected, selected.dropFirst()).allSatisfy({ $0.endFrame == $1.startFrame }),
                  original.startFrame == plan.shots.filter({ members.contains($0.id) }).map(\.startFrame).min(),
                  original.endFrame == plan.shots.filter({ members.contains($0.id) }).map(\.endFrame).max() else {
                throw EditPlanValidationError.invalidReference("Reordering would split or partially move section '\(original.id)'. Move its scenes as a contiguous group.")
            }
            var section = original
            section.startFrame = first.startFrame
            section.endFrame = last.endFrame
            if section.narrationLink != nil {
                guard let firstLink = first.narrationLink, let lastLink = last.narrationLink else {
                    throw EditPlanValidationError.invalidReference("Reordered section is missing narration links.")
                }
                section.narrationLink?.firstBeatId = firstLink.firstBeatId
                section.narrationLink?.lastBeatId = lastLink.lastBeatId
            }
            return section
        }.sorted { $0.startFrame < $1.startFrame }
        return next
    }
}
