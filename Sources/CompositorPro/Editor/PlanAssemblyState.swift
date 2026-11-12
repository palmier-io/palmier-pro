import Foundation

enum PlanSourceAudio: String, Codable, Sendable {
    case linked, omit
}

struct PlanAssemblyState: Codable, Sendable, Equatable {
    struct Intent: Codable, Sendable, Equatable {
        let elementId: String
        let source: ClipPlacement.Source
        let sourceRevision: String
        let requestedTrackId: String?
        let startFrame: Int
        let durationFrames: Int
        let trimStartFrame: Int
        let trimEndFrame: Int
        let sourceAudio: PlanSourceAudio
    }

    struct PlacedClip: Codable, Sendable, Equatable {
        let trackId: String
        let clip: Clip

        func matchesPlacement(_ current: Clip) -> Bool {
            clip.id == current.id && clip.mediaRef == current.mediaRef
                && clip.mediaType == current.mediaType && clip.sourceClipType == current.sourceClipType
                && clip.startFrame == current.startFrame && clip.durationFrames == current.durationFrames
                && clip.trimStartFrame == current.trimStartFrame && clip.trimEndFrame == current.trimEndFrame
                && clip.speed == current.speed && clip.speedTrack == current.speedTrack
                && clip.freezeFrames == current.freezeFrames && clip.linkGroupId == current.linkGroupId
        }
    }

    struct Binding: Codable, Sendable, Equatable {
        let intent: Intent
        let clips: [PlacedClip]

        var receipt: [String: Any] {
            ["elementId": intent.elementId, "clipIds": clips.map { $0.clip.id },
             "trackIds": clips.map(\.trackId), "sourceAudio": intent.sourceAudio.rawValue,
             "startFrame": intent.startFrame, "endFrame": intent.startFrame + intent.durationFrames,
             "sourceStartFrame": intent.trimStartFrame, "sourceRevision": intent.sourceRevision]
        }
    }

    struct CueFrame: Codable, Sendable, Equatable {
        let cueId: String
        let frame: Int?
        let blocker: String?

        var receipt: [String: Any] {
            var value: [String: Any] = ["cueId": cueId]
            if let frame { value["frame"] = frame }
            if let blocker { value["blocker"] = blocker }
            return value
        }
    }

    var revision: String
    var bindings: [Binding]
    var createdTrackIds: [String]
    var cueFrames: [CueFrame]

    func validate() throws {
        guard ProductionRun.validRevision(revision), bindings.count <= EditPlanLimits.maximumShots + 1,
              Set(bindings.map { $0.intent.elementId }).count == bindings.count,
              Set(createdTrackIds).count == createdTrackIds.count else {
            throw EditPlanValidationError.invalidReference("Invalid plan assembly ownership.")
        }
        var clipIds = Set<String>()
        for binding in bindings {
            let intent = binding.intent
            _ = try EditPlan.validatedID(intent.elementId, field: "assembly elementId")
            guard ProductionRun.validRevision(intent.sourceRevision), (1...2).contains(binding.clips.count),
                  intent.durationFrames > 0, intent.durationFrames <= maxFrameArg,
                  intent.startFrame >= 0, intent.startFrame <= maxFrameArg - intent.durationFrames,
                  (0...maxFrameArg).contains(intent.trimStartFrame),
                  (0...maxFrameArg).contains(intent.trimEndFrame) else {
                throw EditPlanValidationError.invalidReference("Invalid assembled source or frame range.")
            }
            for placement in binding.clips {
                _ = try EditPlan.validatedID(placement.trackId, field: "assembly trackId")
                guard clipIds.insert(placement.clip.id).inserted else {
                    throw EditPlanValidationError.duplicateId(placement.clip.id)
                }
            }
        }
    }

    var receipt: [String: Any] {
        ["revision": revision, "bindings": bindings.map(\.receipt),
         "createdTrackIds": createdTrackIds, "cueFrames": cueFrames.map(\.receipt)]
    }
}
