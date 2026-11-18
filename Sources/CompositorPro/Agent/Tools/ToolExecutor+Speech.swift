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

    /// Speaks text — or the timeline's own transcript — locally, imports the result as media,
    /// and optionally places it. Prefers the best installed Piper voice, falling back to a Mac
    /// system voice. No server, no sign-in, no credits.
    func generateSpeech(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try await editor.projectPackageCoordinator.withMutation { lease in
            try await self.performSpeechGeneration(editor, args, lease: lease)
        }
    }

    private func performSpeechGeneration(
        _ editor: EditorViewModel, _ args: [String: Any], lease: ProjectPackageCoordinator.MutationLease
    ) async throws -> ToolResult {
        let local = try await capabilityInputLoader()
        try RuntimeCapabilities.speech(local).requireAvailable()
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
            if parsed == .piper, !(await Self.piperExecutableAvailable()) {
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
        let (_, model) = try await Self.resolveSpeechEngine(spec)
        let timelineBeforeRender = editor.timeline
        let revision = editor.timelineRenderRevision
        let result = try await SpeechSynthesizer.renderReportingEngine(spec: spec)
        let engine = result.engine
        let wavURL = result.url
        let filename = "speech-\(UUID().uuidString).wav"
        let asset = MediaAsset(url: wavURL, type: .audio, name: "speech-\(UUID().uuidString)")
        let snapshot = timelineSnapshot(editor)
        var newClipId: String?
        var installerOwnsStage = false
        do {
            guard requestedEngine == nil || requestedEngine == engine else {
                throw ToolError("The requested speech engine could not render this voice; call list_speech_voices and choose an available voice.")
            }
            let metadata = try await asset.readMetadata(thumbnailMaxPixelSize: nil, validate: {
                editor.timeline == timelineBeforeRender && editor.timelineRenderRevision == revision
            })
            guard metadata.isReadable else { throw ToolError("Could not read the rendered speech audio.") }
            asset.applyMetadata(metadata)
            try await asset.prepareInputIdentity(validate: {
                editor.timeline == timelineBeforeRender && editor.timelineRenderRevision == revision
            })
            let trackName = try TrackName.normalized(input.trackName ?? "Voiceover")
            let clips = try editor.prepareSpeechPlacement(asset, at: input.placeAtFrame)
            installerOwnsStage = true
            _ = try await editor.commitStagedProjectMedia(wavURL, filename: filename, lease: lease, validate: {
                guard editor.timeline == timelineBeforeRender, editor.timelineRenderRevision == revision else { throw CancellationError() }
            }) { destination in
                asset.installPreparedContent(at: destination)
                newClipId = editor.publishSpeechAsset(asset, clips: clips, trackName: trackName)
            }
        } catch {
            if !installerOwnsStage {
                do { try await editor.projectPackageCoordinator.io.remove([wavURL]) }
                catch let cleanup { throw ProjectPackageCleanupError(operationError: error, cleanupError: cleanup) }
            }
            throw error
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

        guard input.placeAtFrame != nil else {
            return .ok(Self.jsonString([
                "mediaRef": asset.id,
                "status": "ready",
                "changed": true,
                "undoSteps": 1,
                "engine": engine.rawValue,
                "voice": result.voiceName,
                "language": model?.languageTag ?? input.language ?? "",
                "characters": spoken.count,
                "source": source,
                "notes": notes + ["Added to the media library only. Pass placeAtFrame to also drop it on the timeline."],
            ]) ?? "{}")
        }

        return mutationResult(editor, since: snapshot, touched: newClipId.map { [$0] } ?? [], notes: notes)
    }

    @concurrent private static func piperExecutableAvailable() async -> Bool {
        PiperTTS.isAvailable
    }

    @concurrent private static func resolveSpeechEngine(_ spec: SpeechSynthesizer.Spec) async throws -> (SpeechSynthesizer.Engine, PiperTTS.Model?) {
        try Task.checkCancellation()
        if spec.engine == .piper, let voice = spec.voiceIdentifier, PiperTTS.model(named: voice) == nil {
            throw SpeechSynthesizer.SpeechError.unknownVoice(voice, PiperTTS.installedModels().map(\.fileName))
        }
        let resolved = SpeechSynthesizer.resolveEngine(for: spec)
        if resolved.engine == .piper, resolved.model == nil {
            throw ToolError("No Piper voice is installed for this request. Call list_speech_voices and choose an available voice.")
        }
        return resolved
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
