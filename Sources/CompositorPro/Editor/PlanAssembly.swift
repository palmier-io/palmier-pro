import CryptoKit
import Foundation

enum PlanAssembly {
    struct Request: Sendable, Equatable {
        let shotIds: [String]?
        let replaceManualEdits: Bool

        init(shotIds: [String]? = nil, replaceManualEdits: Bool = false) {
            self.shotIds = shotIds
            self.replaceManualEdits = replaceManualEdits
        }
    }

    struct Source: Sendable, Equatable {
        let placement: ClipPlacement.Source
        let url: URL
        let expectedIdentity: MediaInputIdentity?
        let blocker: String?
    }

    struct Input: Sendable {
        let plan: EditPlan
        let timeline: Timeline
        let timelines: [Timeline]
        let sources: [String: Source]
        let request: Request
        var approvalBlockers: [String] = []
    }

    struct Resolved: Sendable {
        let timeline: Timeline
        let state: PlanAssemblyState
        let changedClipIds: [String]
        let removedClipIds: [String]
        let preservedClipIds: [String]
        let warnings: [String]
        let complete: Bool
        let timelineChanged: Bool
        let remainingClipIds: Set<String>

        var receipt: [String: Any] {
            ["shotAssembly": state.bindings.map { binding in
                binding.receipt.merging(["shotId": binding.intent.elementId], uniquingKeysWith: { _, new in new })
             }, "addedClipIds": changedClipIds, "removedClipIds": removedClipIds,
             "preservedClipIds": preservedClipIds, "cueFrames": state.cueFrames.map(\.receipt),
              "assemblyRevision": state.revision, "warnings": warnings]
        }

        var previewReceipt: [String: Any] {
            var value = receipt
            value.removeValue(forKey: "addedClipIds")
            value.removeValue(forKey: "removedClipIds")
            value["plannedClipIds"] = changedClipIds
            value["wouldRemoveClipIds"] = removedClipIds
            value["completeAfterCommit"] = complete
            return value
        }
    }

    struct Preparation: Sendable {
        let input: Input
        let identities: [String: MediaInputIdentity]
        let resolved: Resolved?
        let blockers: [String]
    }

    typealias Identify = @Sendable (URL) async throws -> MediaInputIdentity

    @concurrent
    static func requiredMediaRefs(plan: EditPlan, timelines: [Timeline]) async throws -> Set<String> {
        try Task.checkCancellation()
        var refs = Set(plan.shots.compactMap(\.mediaRef))
        if let narration = plan.narration { refs.insert(narration.mediaRef) }
        for cue in plan.soundCues ?? [] {
            if let ref = cue.mediaRef { refs.insert(ref) }
        }
        let children = Dictionary(timelines.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var pending = Array(refs)
        while let ref = pending.popLast() {
            try Task.checkCancellation()
            guard let child = children[ref] else { continue }
            for clip in child.tracks.flatMap(\.clips) where clip.sourceClipType != .text
                && refs.insert(clip.mediaRef).inserted {
                pending.append(clip.mediaRef)
            }
        }
        return refs.subtracting(children.keys)
    }

    @concurrent
    static func prepare(
        _ input: Input,
        identify: @escaping Identify = { try await MediaInputIdentityService.shared.identify($0, force: true) }
    ) async throws -> Preparation {
        try Task.checkCancellation()
        var blockers = try validationBlockers(input)
        var identities: [String: MediaInputIdentity] = [:]
        if blockers.isEmpty {
            for (ref, source) in input.sources.sorted(by: { $0.key < $1.key }) {
                try Task.checkCancellation()
                do {
                    let identity = try await identify(source.url)
                    guard identity.isValid, source.expectedIdentity.map({ $0 == identity }) ?? true else {
                        blockers.append("Media '\(ref)' changed since inspection; reimport and review its current bytes.")
                        continue
                    }
                    identities[ref] = identity
                } catch is CancellationError { throw CancellationError() }
                catch { blockers.append("Media '\(ref)' is unreadable; relink or import_media before assembly.") }
            }
        }
        var resolved: Resolved?
        if blockers.isEmpty {
            if let source = input.plan.narration, let timing = input.plan.narrationTiming {
                guard let identity = identities[source.mediaRef], identity.contentSHA256 == timing.sourceFingerprint else {
                    return Preparation(input: input, identities: identities, resolved: nil,
                        blockers: ["Narration bytes changed since measurement; measure the current narration before assembly."])
                }
                try input.plan.validateNarrationAttachment(identity: identity)
            }
            do { resolved = try resolve(input, identities: identities) }
            catch is CancellationError { throw CancellationError() }
            catch { blockers.append(error.localizedDescription) }
        }
        try Task.checkCancellation()
        return Preparation(input: input, identities: identities, resolved: resolved, blockers: blockers)
    }

    @concurrent
    static func verifySources(_ preparation: Preparation) async throws {
        for (ref, source) in preparation.input.sources.sorted(by: { $0.key < $1.key }) {
            try Task.checkCancellation()
            let identity: MediaInputIdentity
            do { identity = try await MediaInputIdentityService.shared.identify(source.url, force: true) }
            catch is CancellationError { throw CancellationError() }
            catch {
                throw EditPlanValidationError.invalidReference("Media '\(ref)' is missing or unreadable; relink and prepare its current source.")
            }
            guard identity.isValid, identity == preparation.identities[ref] else {
                throw EditPlanValidationError.invalidReference("Media '\(ref)' changed after preparation; inspect and prepare its current source.")
            }
        }
        try Task.checkCancellation()
    }

    private static func validationBlockers(_ input: Input) throws -> [String] {
        let plan = input.plan
        try EditPlan.validatedGeometry(fps: plan.fps, width: plan.width, height: plan.height)
        guard plan.shots.count <= EditPlanLimits.maximumShots else {
            throw EditPlanValidationError.invalidReference("A plan has at most \(EditPlanLimits.maximumShots) shots.")
        }
        try EditPlan.ensureUniqueIDs(plan)
        try plan.assembly?.validate()
        for shot in plan.shots { _ = try EditPlan.validatedShot(shot) }
        guard plan.timelineId == input.timeline.id, plan.fps == input.timeline.fps,
              plan.width == input.timeline.width, plan.height == input.timeline.height else {
            throw EditPlanValidationError.invalidReference("Plan geometry or timeline identity changed; revise the plan before assembly.")
        }
        guard !plan.shots.isEmpty else { return ["The plan has no shots to validate."] }
        guard Set(input.timelines.map(\.id)).count == input.timelines.count else {
            throw EditPlanValidationError.invalidReference("Timeline IDs must be unique before assembly.")
        }
        try validateTimeline(input.timeline)
        if let ids = input.request.shotIds {
            guard !ids.isEmpty, Set(ids).count == ids.count, Set(ids).isSubset(of: Set(plan.shots.map(\.id))) else {
                throw EditPlanValidationError.invalidReference("shotIds must name a nonempty, unique subset of this plan's shots.")
            }
            guard plan.assembly != nil else {
                throw EditPlanValidationError.invalidReference("Assemble the complete plan before revising a subset of shots.")
            }
        }
        var blockers = input.approvalBlockers
            + plan.unresolvedClaimIDs.map { "Claim '\($0)' is unresolved; review its evidence before assembly." }
        if plan.scriptBeats != nil, plan.narrationTiming == nil || plan.narrationTiming?.unresolvedBeatIds.isEmpty == false {
            blockers.append("Narration alignment is unresolved; measure the current script and audio before assembly.")
        }
        if let timing = plan.narrationTiming {
            try timing.validated(beats: plan.scriptBeats ?? [], revision: plan.narrationRevision)
        }
        for section in plan.sections {
            if let link = section.narrationLink, plan.narrationTiming != nil { _ = try plan.resolvedNarrationRange(link) }
        }
        let children = Dictionary(input.timelines.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for shot in plan.shots {
            try Task.checkCancellation()
            if let id = shot.trackId, !input.timeline.tracks.contains(where: { $0.id == id }) {
                blockers.append("Shot '\(shot.id)' names unknown trackId '\(id)'.")
            }
            guard let ref = shot.mediaRef else {
                blockers.append("Shot '\(shot.id)' has no ready mediaRef; import_media and attach the selected source.")
                continue
            }
            if let child = children[ref] {
                let involved = [child] + child.reachableTimelines(resolve: { children[$0] })
                for nested in involved { try validateTimeline(nested) }
                if child.id == input.timeline.id || child.reachableTimelines(resolve: { children[$0] }).contains(where: { $0.id == input.timeline.id }) {
                    blockers.append("Shot '\(shot.id)' would create a nested timeline cycle.")
                }
                if child.totalFrames == 0 || child.fps != plan.fps {
                    blockers.append("Shot '\(shot.id)' requires a nonempty nested timeline at the plan's frame rate.")
                }
                for nested in involved {
                    for clip in nested.tracks.flatMap(\.clips) where clip.sourceClipType != .text
                        && children[clip.mediaRef] == nil && input.sources[clip.mediaRef] == nil {
                        blockers.append("Nested shot '\(shot.id)' names unknown mediaRef '\(clip.mediaRef)'.")
                    }
                }
            } else if input.sources[ref] == nil {
                blockers.append("Shot '\(shot.id)' names unknown mediaRef '\(ref)'.")
            }
        }
        for (ref, source) in input.sources {
            if let blocker = source.blocker { blockers.append("Media '\(ref)': \(blocker)") }
        }
        return blockers
    }

    private static func validateTimeline(_ timeline: Timeline) throws {
        try EditPlan.validatedGeometry(fps: timeline.fps, width: timeline.width, height: timeline.height)
        let clips = timeline.tracks.flatMap(\.clips)
        guard Set(timeline.tracks.map(\.id)).count == timeline.tracks.count,
              Set(clips.map(\.id)).count == clips.count,
              clips.allSatisfy({ $0.startFrame >= 0 && $0.durationFrames > 0 && $0.durationFrames <= maxFrameArg
                  && $0.startFrame <= maxFrameArg - $0.durationFrames }) else {
            throw EditPlanValidationError.invalidReference("Timeline contains invalid or duplicate clip ranges; repair it before assembly.")
        }
    }

    private static func resolve(_ input: Input, identities: [String: MediaInputIdentity]) throws -> Resolved {
        let plan = input.plan
        let selected = Set(input.request.shotIds ?? plan.shots.map(\.id))
        var shots = try plan.resolvedShots()
        let cueFrames = try plan.resolvedSoundCueFrames()
        if let narration = plan.narration, let intent = plan.narrationIntent,
           let timing = plan.narrationTiming {
            let duration = try timing.duration.frame(fps: plan.fps, rounding: .roundTowardZero)
            guard duration > 0, intent.startFrame <= maxFrameArg - duration else { throw EditPlanValidationError.invalidRange }
            shots.append(EditPlanShot(id: "narration:\(plan.id)", title: "Narration", startFrame: intent.startFrame,
                                      endFrame: intent.startFrame + duration, mediaRef: narration.mediaRef))
        }
        for cue in plan.soundCues ?? [] {
            guard let mediaRef = cue.mediaRef else { continue }
            let cueAnchor = cueFrames.first(where: { $0.cueId == cue.cueId })
            guard let anchorFrame = cueAnchor?.frame, cueAnchor?.blocker == nil else { continue }
            let durationFrames: Int
            if let durationSecs = cue.durationSeconds {
                durationFrames = max(1, Int((durationSecs * Double(plan.fps)).rounded()))
            } else if let source = input.sources[mediaRef] {
                durationFrames = max(1, Int((source.placement.durationSeconds * Double(plan.fps)).rounded()))
            } else {
                durationFrames = max(1, plan.fps)
            }
            guard anchorFrame >= 0, anchorFrame <= maxFrameArg - durationFrames else { continue }
            shots.append(EditPlanShot(
                id: "cue:\(cue.cueId)",
                title: cue.purpose,
                startFrame: anchorFrame,
                endFrame: anchorFrame + durationFrames,
                trackId: cue.trackId,
                mediaRef: mediaRef
            ))
        }
        let children = Dictionary(input.timelines.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let allIntents = try shots.map { shot -> PlanAssemblyState.Intent in
            guard let ref = shot.mediaRef else { throw EditPlanValidationError.invalidReference("Shot has no selected source.") }
            let source: ClipPlacement.Source
            let revision: String
            if let child = children[ref] {
                source = .init(mediaRef: ref, type: .sequence, durationSeconds: Double(child.totalFrames) / Double(child.fps),
                               hasAudio: child.hasAudioClips, width: child.width, height: child.height)
                let involved = [child] + child.reachableTimelines(resolve: { children[$0] }).sorted { $0.id < $1.id }
                revision = try digest(NestedSource(timelines: involved, identities: identities))
            } else {
                guard let value = input.sources[ref], let identity = identities[ref] else {
                    throw EditPlanValidationError.invalidReference("Source '\(ref)' is not available.")
                }
                source = value.placement
                revision = identity.contentSHA256
            }
            let span = try PlanSourceRange.playback(shot: shot, fps: plan.fps, type: source.type, duration: source.durationSeconds)
            let total = try ClipPlacement.frames(seconds: source.durationSeconds, fps: plan.fps)
            let audio = shot.sourceAudio ?? (plan.narration == nil ? .linked : .omit)
            return .init(elementId: shot.id, source: source, sourceRevision: revision, requestedTrackId: shot.trackId,
                         startFrame: shot.startFrame, durationFrames: shot.endFrame - shot.startFrame,
                         trimStartFrame: span.lowerBound, trimEndFrame: max(0, total - span.upperBound), sourceAudio: audio)
        }
        let intents = allIntents.filter { input.request.shotIds == nil || selected.contains($0.elementId) }
        var timeline = input.timeline
        var bindings = plan.assembly?.bindings ?? []
        var createdTracks = plan.assembly?.createdTrackIds ?? []
        let locations = Dictionary(uniqueKeysWithValues: timeline.tracks.flatMap { track in
            track.clips.map { ($0.id, PlanAssemblyState.PlacedClip(trackId: track.id, clip: $0)) }
        })
        let previous = Dictionary(uniqueKeysWithValues: bindings.map { ($0.intent.elementId, $0) })
        let replacingElements = Set(intents.map(\.elementId))
        var replacements: [PlanAssemblyState.Intent] = []
        var preserved: [String] = []
        var warnings: [String] = []
        var removed: Set<String> = []
        for intent in intents {
            let old = previous[intent.elementId]
            if let old, old.intent == intent, old.clips.allSatisfy({ placement in
                guard let actual = locations[placement.clip.id] else { return false }
                return actual.trackId == placement.trackId && placement.matchesPlacement(actual.clip)
            }) {
                preserved.append(contentsOf: old.clips.map { $0.clip.id })
                if old.clips.contains(where: { locations[$0.clip.id]?.clip != $0.clip }) {
                    warnings.append("Shot '\(intent.elementId)' retains its existing finishing and manual styling.")
                }
                continue
            }
            if let old {
                guard input.request.replaceManualEdits || old.clips.allSatisfy({ locations[$0.clip.id] == $0 }) else {
                    throw EditPlanValidationError.invalidReference("Shot '\(intent.elementId)' was manually edited or removed. Preserve it, or explicitly set replaceManualEdits for the selected shots.")
                }
                let owned = Set(old.clips.map { $0.clip.id })
                let groups = Set(old.clips.compactMap { $0.clip.linkGroupId })
                    .union(old.clips.compactMap { locations[$0.clip.id]?.clip.linkGroupId })
                guard locations.values.allSatisfy({ actual in
                    guard let group = actual.clip.linkGroupId, groups.contains(group) else { return true }
                    return owned.contains(actual.clip.id)
                }) else {
                    throw EditPlanValidationError.invalidReference("Shot '\(intent.elementId)' is linked to an unrelated edit; unlink it before replacement.")
                }
                guard !timeline.transitions.contains(where: { owned.contains($0.outgoingClipId) || owned.contains($0.incomingClipId) }) else {
                    throw EditPlanValidationError.invalidReference("Shot '\(intent.elementId)' owns a transition; remove or revise that transition before replacement.")
                }
                guard old.clips.allSatisfy({ locations[$0.clip.id]?.clip.multicamGroupId == nil }) else {
                    throw EditPlanValidationError.invalidReference("Shot '\(intent.elementId)' belongs to a multicam group; remove that membership before replacement.")
                }
                removed.formUnion(owned)
            }
            replacements.append(intent)
        }
        if input.request.shotIds == nil {
            for binding in bindings where !replacingElements.contains(binding.intent.elementId) {
                guard binding.clips.allSatisfy({ locations[$0.clip.id] == nil }) else {
                    throw EditPlanValidationError.invalidReference("Assembled shot '\(binding.intent.elementId)' was removed from the plan. Remove its timeline edit explicitly before changing ownership.")
                }
            }
            bindings.removeAll { !replacingElements.contains($0.intent.elementId) }
        }
        for index in timeline.tracks.indices { timeline.tracks[index].clips.removeAll { removed.contains($0.id) } }
        let replacedIds = Set(replacements.map(\.elementId))
        bindings.removeAll { replacedIds.contains($0.intent.elementId) }
        var autoTracks: [String: String] = [:]
        func newTrack(type: ClipType, lane: String) -> String {
            if let id = autoTracks[lane] { return id }
            let track = Track(type: type)
            let index = ClipPlacement.trackInsertionIndex(type: type, requested: type == .audio ? timeline.tracks.count : 0, tracks: timeline.tracks)
            timeline.tracks.insert(track, at: index)
            autoTracks[lane] = track.id
            createdTracks.append(track.id)
            return track.id
        }
        var changed: [String] = []
        for intent in replacements {
            try Task.checkCancellation()
            let old = previous[intent.elementId]
            let isAudio = intent.source.type == .audio
            let lane: String
            if intent.elementId.hasPrefix("cue:") {
                lane = "cue"
            } else if intent.elementId.hasPrefix("narration") {
                lane = "narration"
            } else {
                lane = isAudio ? "audio" : "visual"
            }
            let trackId = intent.requestedTrackId ?? old?.clips.first?.trackId
                ?? newTrack(type: isAudio ? .audio : .video, lane: lane)
            guard let index = timeline.tracks.firstIndex(where: { $0.id == trackId }),
                  intent.source.type.isCompatible(with: timeline.tracks[index].type),
                  isAudio ? !timeline.tracks[index].muted : !timeline.tracks[index].hidden else {
                throw EditPlanValidationError.invalidReference("Shot '\(intent.elementId)' requires an available, visible/audible compatible track '\(trackId)'.")
            }
            let clips = try ClipPlacement.make(source: intent.source, trackType: timeline.tracks[index].type,
                fps: plan.fps, canvasWidth: plan.width, canvasHeight: plan.height,
                startFrame: intent.startFrame, durationFrames: intent.durationFrames,
                trimStartFrame: intent.trimStartFrame, trimEndFrame: intent.trimEndFrame,
                addLinkedAudio: intent.sourceAudio == .linked,
                primaryId: old?.clips.first?.clip.id ?? UUID().uuidString,
                audioId: old?.clips.dropFirst().first?.clip.id ?? UUID().uuidString,
                linkGroupId: old?.clips.first?.clip.linkGroupId ?? UUID().uuidString)
            try append(clips.primary, to: index, timeline: &timeline, elementId: intent.elementId)
            var placements = [PlanAssemblyState.PlacedClip(trackId: trackId, clip: clips.primary)]
            if let audio = clips.linkedAudio {
                let audioTrackId = old?.clips.dropFirst().first?.trackId ?? newTrack(type: .audio, lane: "linked")
                guard let audioIndex = timeline.tracks.firstIndex(where: { $0.id == audioTrackId }),
                      timeline.tracks[audioIndex].type == .audio, !timeline.tracks[audioIndex].muted else {
                    throw EditPlanValidationError.invalidReference("Linked audio requires its unmuted audio track.")
                }
                try append(audio, to: audioIndex, timeline: &timeline, elementId: intent.elementId)
                placements.append(.init(trackId: audioTrackId, clip: audio))
            }
            changed.append(contentsOf: clips.ids)
            bindings.append(.init(intent: intent, clips: placements))
        }
        if !replacements.isEmpty { timeline.audioMix = nil }
        bindings.sort { $0.intent.elementId < $1.intent.elementId }
        let revision = try digest(Ownership(bindings: bindings, fps: plan.fps, width: plan.width, height: plan.height, cueFrames: cueFrames))
        let state = PlanAssemblyState(revision: revision, bindings: bindings, createdTrackIds: createdTracks, cueFrames: cueFrames)
        try state.validate()
        let byElement = Dictionary(uniqueKeysWithValues: bindings.map { ($0.intent.elementId, $0) })
        let resultingClips = Dictionary(uniqueKeysWithValues: timeline.tracks.flatMap { track in
            track.clips.map { ($0.id, PlanAssemblyState.PlacedClip(trackId: track.id, clip: $0)) }
        })
        let complete = allIntents.allSatisfy { intent in
            guard let binding = byElement[intent.elementId], binding.intent == intent else { return false }
            return binding.clips.allSatisfy { placement in
                guard let actual = resultingClips[placement.clip.id] else { return false }
                return actual.trackId == placement.trackId && placement.matchesPlacement(actual.clip)
            }
        }
        if !complete { warnings.append("Untargeted shots differ from the current plan; this subset does not complete the full assembly.") }
        return Resolved(timeline: timeline, state: state, changedClipIds: changed.sorted(),
                        removedClipIds: removed.subtracting(changed).sorted(), preservedClipIds: preserved.sorted(),
                        warnings: warnings, complete: complete, timelineChanged: timeline != input.timeline,
                        remainingClipIds: Set(resultingClips.keys))
    }

    private static func append(_ clip: Clip, to index: Int, timeline: inout Timeline, elementId: String) throws {
        guard !timeline.tracks[index].clips.contains(where: { $0.startFrame < clip.endFrame && $0.endFrame > clip.startFrame }) else {
            throw EditPlanValidationError.invalidReference("Shot '\(elementId)' overlaps another edit on track '\(timeline.tracks[index].id)'; choose a free track or revise its timing.")
        }
        timeline.tracks[index].clips.append(clip)
        timeline.tracks[index].clips.sort { ($0.startFrame, $0.id) < ($1.startFrame, $1.id) }
    }

    private struct NestedSource: Encodable {
        let timelines: [Timeline]
        let identities: [String: MediaInputIdentity]
    }

    private struct Ownership: Encodable {
        let bindings: [PlanAssemblyState.Binding]
        let fps: Int
        let width: Int
        let height: Int
        let cueFrames: [PlanAssemblyState.CueFrame]
    }

    private static func digest(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
    }
}

extension EditPlan {
    func resolvedSoundCueFrames() throws -> [PlanAssemblyState.CueFrame] {
        try (soundCues ?? []).map { cue in
            if cue.mediaRef == nil {
                return .init(cueId: cue.cueId, frame: cue.anchorFrame, blocker: "missing_cue_audio")
            }
            if let frame = cue.anchorFrame { return .init(cueId: cue.cueId, frame: frame, blocker: nil) }
            guard let beatId = cue.anchorBeatId, let timing = narrationTiming, let intent = narrationIntent,
                  let anchor = timing.anchors.first(where: { $0.beatId == beatId }) else {
                return .init(cueId: cue.cueId, frame: nil, blocker: "unresolved_sound_cue_anchor")
            }
            let offset = try anchor.speechStart.frame(fps: fps)
            guard offset >= 0, intent.startFrame <= maxFrameArg - offset else { throw EditPlanValidationError.invalidRange }
            return .init(cueId: cue.cueId, frame: intent.startFrame + offset, blocker: nil)
        }
    }
}
