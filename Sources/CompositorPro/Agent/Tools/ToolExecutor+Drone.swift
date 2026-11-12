import Foundation

extension ToolExecutor {
    fileprivate struct GenerateDroneInput: DecodableToolArgs {
        let tonic: String
        let octave: Int?
        let scale: String?
        let pattern: String?
        let duration: Double?
        let placeUnder: String?
        let levelDB: Double?
        static let allowedKeys: Set<String> = ["tonic", "octave", "scale", "pattern", "duration", "placeUnder", "levelDB"]
    }

    /// Renders a tanpura/shruti-style tonal drone on-device (Karplus-Strong synthesis),
    /// imports it as media, and places it on its own audio track. No server, no credits.
    func generateDrone(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try await editor.projectPackageCoordinator.withMutation { lease in
            try await self.performDroneGeneration(editor, args, lease: lease)
        }
    }

    private func performDroneGeneration(
        _ editor: EditorViewModel, _ args: [String: Any], lease: ProjectPackageCoordinator.MutationLease
    ) async throws -> ToolResult {
        let input: GenerateDroneInput = try decodeToolArgs(args, path: "generate_drone")
        guard DroneSynthesizer.semitone(forTonic: input.tonic) != nil else {
            throw ToolError("tonic must be a note name C…B (optionally sharped, e.g. C#, Eb). Got '\(input.tonic)'.")
        }
        let scale: DroneSynthesizer.Scale
        if let raw = input.scale {
            guard let parsed = DroneSynthesizer.Scale(rawValue: raw) else {
                throw ToolError("Unknown scale '\(raw)'. Available: \(DroneSynthesizer.Scale.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            scale = parsed
        } else {
            scale = .rast
        }
        let pattern: DroneSynthesizer.Pattern
        if let raw = input.pattern {
            guard let parsed = DroneSynthesizer.Pattern(rawValue: raw) else {
                throw ToolError("Unknown pattern '\(raw)'. Available: \(DroneSynthesizer.Pattern.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            pattern = parsed
        } else {
            pattern = .tanpura
        }
        if let octave = input.octave, !(1...5).contains(octave) {
            throw ToolError("octave must be 1–5 (got \(octave))")
        }
        if let duration = input.duration, !(1...120).contains(duration) {
            throw ToolError("duration must be 1–120 seconds (got \(duration))")
        }
        if let levelDB = input.levelDB, !(-40...0).contains(levelDB) {
            throw ToolError("levelDB must be -40…0 (got \(levelDB))")
        }

        var duration = input.duration ?? 30
        var under: (trackIndex: Int, startFrame: Int)? = nil
        if let underId = input.placeUnder {
            guard let loc = editor.findClip(id: underId) else {
                throw ToolError("placeUnder clip not found: \(underId)")
            }
            let clip = editor.timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
            guard clip.mediaType == .audio else {
                throw ToolError("placeUnder clip \(underId) is a \(clip.mediaType.rawValue) clip; generate_drone needs an audio clip.")
            }
            if input.duration == nil {
                let fps = Double(max(1, editor.timeline.fps))
                duration = Double(clip.durationFrames) / fps
            }
            under = (loc.trackIndex, clip.startFrame)
        }

        let spec = DroneSynthesizer.Spec(
            tonic: input.tonic,
            octave: input.octave ?? 3,
            scale: scale,
            pattern: pattern,
            duration: duration
        )
        let timelineBeforeRender = editor.timeline
        let revision = editor.timelineRenderRevision
        let wavURL = try await Task.detached(priority: .utility) {
            try DroneSynthesizer.renderWAV(spec: spec)
        }.value
        let filename = "drone-\(UUID().uuidString).wav"
        let asset = MediaAsset(url: wavURL, type: .audio, name: filename)
        _ = try await editor.commitStagedProjectMedia(
            wavURL,
            filename: filename, lease: lease, validate: {
                guard editor.timeline == timelineBeforeRender, editor.timelineRenderRevision == revision else { throw CancellationError() }
            }
        ) { destination in
            asset.url = destination
            editor.importMediaAsset(asset)
        }
        let finalized = await editor.finalizeImportedAsset(asset)
        guard finalized, editor.mediaAssetsById[asset.id] === asset else {
            throw ToolError("Could not prepare rendered drone; library record retained with mediaRef '\(asset.id)'")
        }
        try Task.checkCancellation()
        guard editor.timeline == timelineBeforeRender, editor.timelineRenderRevision == revision else {
            throw ToolError("Timeline changed while preparing drone; rendered media retained with mediaRef '\(asset.id)'")
        }

        let snapshot = timelineSnapshot(editor)
        var newClipId: String?
        var newTrackId: String?
        let levelDB = input.levelDB ?? -18.0
        try editor.undo.perform("Generate Drone (Agent)") {
            let trackIndex: Int
            if let under {
                trackIndex = editor.insertTrack(at: under.trackIndex + 1, type: .audio)
            } else {
                trackIndex = editor.insertTrack(at: editor.timeline.tracks.count, type: .audio)
            }
            let startFrame = under?.startFrame ?? editor.activeFrame
            editor.addClips(assets: [asset], trackIndex: trackIndex, startFrame: startFrame)
            guard editor.timeline.tracks.indices.contains(trackIndex) else { return }
            let track = editor.timeline.tracks[trackIndex]
            newTrackId = track.id
            try? editor.setTrackName(id: track.id, to: "Drone")
            guard let clip = track.clips.first(where: { $0.mediaRef == asset.id }) else { return }
            newClipId = clip.id
            editor.mutateClips(ids: [clip.id], actionName: "Generate Drone (Agent)") { clip in
                clip.volume = pow(10, levelDB / 20)
            }
        }

        var notes = [
            "Rendered locally with Karplus-Strong plucked-string synthesis — no server, no credits.",
            "Placed on a new audio track named Drone; mute or delete the track to remove the bed.",
        ]
        if let underId = input.placeUnder {
            notes.append("Spans the full length of clip \(underId).")
        }
        notes.append("Clip volume set to \(String(format: "%.0f", levelDB)) dB — adjust with set_clip_properties if it sits wrong against the vocal.")
        return mutationResult(editor, since: snapshot, touched: newClipId.map { [$0] } ?? [], notes: notes)
    }
}
