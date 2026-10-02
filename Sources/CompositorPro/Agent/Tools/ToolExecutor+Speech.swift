import Foundation

extension ToolExecutor {
    fileprivate struct ListSpeechVoicesInput: DecodableToolArgs {
        let language: String?
        let limit: Int?
        static let allowedKeys: Set<String> = ["language", "limit"]
    }

    /// The speech voices this Mac actually has. Which voices exist varies per machine, so a
    /// caller cannot be handed a fixed list in a tool description and be right.
    func listSpeechVoices(_ args: [String: Any]) throws -> ToolResult {
        let input: ListSpeechVoicesInput = try decodeToolArgs(args, path: "list_speech_voices")
        if let limit = input.limit, !(1...200).contains(limit) {
            throw ToolError("limit must be 1–200 (got \(limit))")
        }
        if let language = input.language, !SpeechSynthesizer.voices(matchingLanguage: language).isEmpty == false {
            throw ToolError("""
                No installed voice speaks '\(language)'. Installed languages: \
                \(SpeechSynthesizer.installedLanguages().joined(separator: ", "))
                """)
        }

        let matching = SpeechSynthesizer.voices(matchingLanguage: input.language)
        let limit = input.limit ?? 50
        return .ok(Self.jsonString([
            "count": matching.count,
            "returned": min(limit, matching.count),
            "voices": matching.prefix(limit).map { voice in
                [
                    "name": voice.name,
                    "identifier": voice.identifier,
                    "language": voice.language,
                    "gender": voice.gender,
                    "enhanced": voice.isEnhanced,
                ] as [String: Any]
            },
            "installedLanguages": SpeechSynthesizer.installedLanguages(),
            "piper": [
                "available": PiperTTS.isAvailable,
                "voiceDirectory": PiperTTS.voiceDirectory.path,
                "voices": PiperTTS.installedModels().map { model in
                    [
                        "name": model.fileName,
                        "language": model.languageTag,
                        "quality": model.quality,
                    ] as [String: Any]
                },
                "languages": PiperTTS.installedLanguages,
            ],
            "notes": [
                "System voices are the `voices` list and work everywhere macOS has one.",
                "Piper voices are a separate, higher-quality local engine; pass one as `voice` "
                    + "with `engine: 'piper'`, or let generate_speech choose it automatically.",
                "Only voices listed here can be passed to generate_speech. Omit `voice` to use the best voice for the language.",
            ],
        ]) ?? "{}")
    }

    fileprivate struct GenerateSpeechInput: DecodableToolArgs {
        let text: String?
        let clipId: String?
        let trackIndex: Int?
        let startFrame: Int?
        let endFrame: Int?
        let voice: String?
        let language: String?
        let rate: Double?
        let pitch: Double?
        let engine: String?
        let placeAtFrame: Int?
        let trackName: String?
        static let allowedKeys: Set<String> = [
            "text", "clipId", "trackIndex", "startFrame", "endFrame",
            "voice", "language", "rate", "pitch", "engine", "placeAtFrame", "trackName",
        ]
    }

    /// Speaks text — or the timeline's own transcript — with a Mac system voice, imports the
    /// result as media, and optionally places it. No server, no sign-in, no credits.
    func generateSpeech(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        let input: GenerateSpeechInput = try decodeToolArgs(args, path: "generate_speech")

        if let rate = input.rate, !(0.5...2.0).contains(rate) {
            throw ToolError("rate must be 0.5–2.0 (got \(rate))")
        }
        if let pitch = input.pitch, !(0.5...2.0).contains(pitch) {
            throw ToolError("pitch must be 0.5–2.0 (got \(pitch))")
        }
        let requestedEngine: SpeechSynthesizer.Engine?
        if let raw = input.engine {
            guard let parsed = SpeechSynthesizer.Engine(rawValue: raw) else {
                throw ToolError("engine must be piper or system.")
            }
            guard parsed == .piper, PiperTTS.isAvailable else {
                throw ToolError(
                    "Piper is not installed. Install it with: uv tool install piper-tts"
                )
            }
            requestedEngine = parsed
        } else {
            requestedEngine = nil
        }
        if input.text == nil, input.clipId == nil, input.trackIndex == nil {
            throw ToolError("generate_speech: pass text to speak, or clipId/trackIndex to speak that audio's transcript.")
        }

        var source = "text"
        var words: [String] = []
        if let literal = input.text?.trimmingCharacters(in: .whitespacesAndNewlines), !literal.isEmpty {
            words = [literal]
        } else {
            source = "transcript"
            words = try await transcriptWords(editor, input)
        }

        let spoken = words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else {
            throw ToolError("There is no speech to read for that selection. Check get_transcript, or pass text directly.")
        }

        let spec = SpeechSynthesizer.Spec(
            text: spoken,
            voiceIdentifier: input.voice,
            language: input.language,
            rate: input.rate ?? 1.0,
            pitch: input.pitch ?? 1.0,
            engine: requestedEngine
        )
        let (engine, model) = SpeechSynthesizer.resolveEngine(for: spec)
        let result = try await SpeechSynthesizer.renderReportingEngine(spec: spec)
        let wavURL = result.url

        // Commit into the project package rather than pointing the asset at the temp file:
        // finalize only reads metadata in place, so a temp path would leave a dead reference
        // the moment the render directory is cleaned. This also removes the staged file.
        let committed = try await editor.commitStagedProjectMedia(
            wavURL,
            filename: "speech-\(UUID().uuidString.prefix(8)).wav"
        )

        guard let asset = editor.addMediaAsset(from: committed) else {
            throw ToolError("The rendered speech could not be imported as media.")
        }

        var notes = [
            "Rendered locally with \(engine.label) — no server, no sign-in, no credits.",
            "Voice: \(result.voiceName).",
            "Read from \(source) (\(spoken.count) characters).",
        ]
        if engine == .system {
            notes.append(
                "Install a Piper voice for this language for a more natural read: "
                    + "uv tool install piper-tts, then drop a .onnx voice into \(PiperTTS.voiceDirectory.path)."
            )
        }

        guard let placeAt = input.placeAtFrame else {
            return .ok(Self.jsonString([
                "mediaRef": asset.id,
                "status": "ready",
                "engine": engine.rawValue,
                "voice": result.voiceName,
                "language": model?.languageTag ?? input.language ?? "",
                "characters": spoken.count,
                "source": source,
                "notes": notes + ["Added to the media library only. Pass placeAtFrame to also drop it on the timeline."],
            ]) ?? "{}")
        }

        let snapshot = timelineSnapshot(editor)
        var newClipId: String?
        var newTrackId: String?
        let trackName = input.trackName ?? "Voiceover"
        try editor.undo.perform("Generate Speech (Agent)") {
            let trackIndex = editor.insertTrack(at: editor.timeline.tracks.count, type: .audio)
            guard editor.timeline.tracks.indices.contains(trackIndex) else { return }
            let track = editor.timeline.tracks[trackIndex]
            newTrackId = track.id
            try? editor.setTrackName(id: track.id, to: trackName)
            editor.addClips(assets: [asset], trackIndex: trackIndex, startFrame: placeAt)
            newClipId = editor.timeline.tracks[trackIndex].clips
                .first(where: { $0.mediaRef == asset.id })?.id
        }

        return mutationResult(editor, since: snapshot, touched: newClipId.map { [$0] } ?? [], notes: notes)
    }

    /// Reads the same transcript `get_transcript` reads, so a spoken take and the captions
    /// can never disagree about what was said.
    private func transcriptWords(_ editor: EditorViewModel, _ input: GenerateSpeechInput) async throws -> [String] {
        // Built key by key: collecting optionals into a dictionary and compacting keeps
        // `.some(nil)`, which would make an absent argument look present.
        var scopeArgs: [String: Any] = [:]
        if let clipId = input.clipId { scopeArgs["clipId"] = clipId }
        if let trackIndex = input.trackIndex { scopeArgs["trackIndex"] = trackIndex }

        let scope = try resolveTranscriptionScope(editor, scopeArgs, path: "generate_speech")
        guard !scope.targets(in: editor).isEmpty else {
            throw ToolError("No audio to transcribe for that selection.")
        }
        // Local only: reading a transcript must not spend cloud credits behind the user's back.
        let context = TranscriptionToolContext(provider: .local, preferredLocale: nil)
        let session = TranscriptSession(context: context, scope: scope, editor: editor)
        let transcript = try await timelineTranscript(editor, session: session)

        var windowArgs: [String: Any] = [:]
        if let startFrame = input.startFrame { windowArgs["startFrame"] = startFrame }
        if let endFrame = input.endFrame { windowArgs["endFrame"] = endFrame }
        let window = try Self.frameWindow(windowArgs)
        let selected = window.map { range in
            transcript.words.filter { $0.startFrame < range.upperBound && $0.endFrame > range.lowerBound }
        } ?? transcript.words
        return selected.map(\.text)
    }
}
