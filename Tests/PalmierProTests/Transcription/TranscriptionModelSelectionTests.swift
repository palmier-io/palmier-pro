import Foundation
import Testing
@testable import PalmierPro

@Suite("Transcription model selection")
@MainActor
struct TranscriptionModelSelectionTests {

    private func resolve(
        _ pref: TranscriptionPreference, signedIn: Bool, credits: Int, cost: Int
    ) throws -> (provider: TranscriptionProvider, fellBackToLocal: Bool) {
        try ToolExecutor.resolveTranscriptionProvider(
            preference: pref, isSignedIn: signedIn, remainingCredits: credits, estimatedCost: cost, path: "test"
        )
    }

    // MARK: - Deliverable 4: model identifiers per engine

    @Test func engineModelIds() {
        #expect(LocalSpeechEngine.qwen3.modelId == "qwen3-asr-0.6B-int8")
        #expect(LocalSpeechEngine.whisper.modelId == "whisper-large-v3_turbo")
        #expect(LocalSpeechEngine.apple.modelId == "apple-speech")
    }

    /// The `transcript.model ?? LocalSpeechEngine.current.modelId` fallback for nil-model cached
    /// entries is only honest while each engine re-transcribes into its own cache slot — i.e. every
    /// non-nil cacheTag is distinct and at most one engine (apple) opts out with a nil tag. If a future
    /// edit collides tags or drops the salt, a cached entry from one engine could be reported under
    /// another's model. Pin the invariant so that regression can't slip through unnoticed.
    @Test func engineCacheTagsAreDistinct() {
        let tags = LocalSpeechEngine.allCases.map(\.cacheTag)
        let nonNil = tags.compactMap { $0 }
        #expect(Set(nonNil).count == nonNil.count) // non-nil tags are unique
        #expect(tags.filter { $0 == nil }.count <= 1) // at most one engine (apple) is untagged
    }

    // MARK: - Deliverable 2: preference resolution matrix

    @Test func autoRoutesCloudWhenAffordable() throws {
        let r = try resolve(.auto, signedIn: true, credits: 10, cost: 5)
        #expect(r.provider == .cloud)
        #expect(!r.fellBackToLocal)
    }

    @Test func autoFallsBackToLocalWhenNotSignedIn() throws {
        let r = try resolve(.auto, signedIn: false, credits: 0, cost: 5)
        #expect(r.provider == .local)
        #expect(r.fellBackToLocal)
    }

    @Test func autoFallsBackToLocalWhenCreditsShort() throws {
        let r = try resolve(.auto, signedIn: true, credits: 3, cost: 5)
        #expect(r.provider == .local)
        #expect(r.fellBackToLocal)
    }

    @Test func autoUsesCloudForCachedFreeRequestEvenWithZeroCredits() throws {
        let r = try resolve(.auto, signedIn: true, credits: 0, cost: 0)
        #expect(r.provider == .cloud)
        #expect(!r.fellBackToLocal)
    }

    @Test func localAlwaysLocalNeverFallback() throws {
        for signedIn in [true, false] {
            let r = try resolve(.local, signedIn: signedIn, credits: 0, cost: 100)
            #expect(r.provider == .local)
            #expect(!r.fellBackToLocal) // deliberate local is never a "fallback"
        }
    }

    @Test func cloudRoutesCloudWhenAffordable() throws {
        let r = try resolve(.cloud, signedIn: true, credits: 10, cost: 5)
        #expect(r.provider == .cloud)
        #expect(!r.fellBackToLocal)
    }

    // MARK: - Deliverable 2 / test #2: cloud preference must error, not silently degrade

    @Test func cloudPreferenceThrowsWhenCreditsShort() throws {
        #expect(throws: ToolError.self) {
            _ = try resolve(.cloud, signedIn: true, credits: 3, cost: 5)
        }
        do {
            _ = try resolve(.cloud, signedIn: true, credits: 3, cost: 5)
            Issue.record("expected a throw")
        } catch let error as ToolError {
            #expect(error.message.contains("transcriptionPreference is 'cloud'"))
            #expect(error.message.contains("can't cover"))
        }
    }

    @Test func cloudPreferenceThrowsWhenNotSignedIn() throws {
        do {
            _ = try resolve(.cloud, signedIn: false, credits: 100, cost: 5)
            Issue.record("expected a throw")
        } catch let error as ToolError {
            #expect(error.message.contains("no account is signed in"))
        }
    }

    // MARK: - Deliverable 4 / test #3: resolved model threads to the response for each local engine

    @Test func resolvedModelLabelReportsSingleModel() {
        #expect(ToolExecutor.resolvedModelLabel(models: ["qwen3-asr-0.6B-int8"], provider: .local) == "qwen3-asr-0.6B-int8")
    }

    @Test func resolvedModelLabelDefaultsByProviderWhenEmpty() {
        #expect(ToolExecutor.resolvedModelLabel(models: [], provider: .cloud) == "cloud")
        #expect(ToolExecutor.resolvedModelLabel(models: [], provider: .local) == LocalSpeechEngine.current.modelId)
    }

    @Test func resolvedModelLabelJoinsMixedModels() {
        let label = ToolExecutor.resolvedModelLabel(models: ["apple-speech", "qwen3-asr-0.6B-int8"], provider: .local)
        #expect(label.contains("apple-speech"))
        #expect(label.contains("qwen3-asr-0.6B-int8"))
    }

    @Test func inspectMediaMetaSurfacesModelAndSourceForEachEngine() {
        for engine in LocalSpeechEngine.allCases {
            let result = TranscriptionResult(text: "hi", language: "en", words: [], segments: [], model: engine.modelId)
            let meta = ToolExecutor.transcriptionMeta(from: result)
            #expect(meta["transcriptionModel"] as? String == engine.modelId)
            #expect(meta["transcriptionSource"] as? String == "local") // inspect_media never routes to cloud
        }
    }

    @Test func getTranscriptResponseReportsResolvedModel() {
        let context = TranscriptionToolContext(provider: .local, preferredLocale: nil, preference: .local)
        let transcript = TimelineTranscript(context: context, words: [], skipped: [], resolvedModel: "whisper-large-v3_turbo")
        let payload = transcript.responsePayload(fps: 30, clipId: nil, startFrame: nil, endFrame: nil, maxWords: 100)
        #expect(payload["transcriptionModel"] as? String == "whisper-large-v3_turbo")
        #expect(payload["transcriptionSource"] as? String == "local")
    }

    // MARK: - model survives every result transform so the tag reaches the response

    @Test func modelStampAndSurvivesTransforms() {
        let base = TranscriptionResult(text: "a", language: nil, words: [], segments: [])
        #expect(base.model == nil)
        #expect(base.withModel("apple-speech").model == "apple-speech")

        let timed = TranscriptionResult(
            text: "a", language: "en",
            words: [TranscriptionWord(text: "a", start: 1, end: 2)],
            segments: [TranscriptionSegment(text: "a", start: 1, end: 2)],
            model: "cloud"
        )
        #expect(timed.offsetting(by: 5).model == "cloud")
        #expect(TranscriptCache.filter(timed, to: 0...10).model == "cloud")
    }

    // MARK: - Deliverable 5 / test #4: fallback notice appears only in the auto+fallback case

    @Test func lowAccuracyNoticeOnlyWhenAutoFellBack() {
        func note(fellBack: Bool, preference: TranscriptionPreference) -> String? {
            let context = TranscriptionToolContext(
                provider: .local, preferredLocale: nil, preference: preference, fellBackToLocal: fellBack
            )
            let transcript = TimelineTranscript(context: context, words: [], skipped: [], resolvedModel: "qwen3-asr-0.6B-int8")
            return transcript.responsePayload(fps: 30, clipId: nil, startFrame: nil, endFrame: nil, maxWords: 100)["transcriptionNote"] as? String
        }
        #expect(note(fellBack: true, preference: .auto) != nil)   // auto degraded to local → notice
        #expect(note(fellBack: false, preference: .local) == nil) // deliberate local → no notice
        #expect(note(fellBack: false, preference: .auto) == nil)  // auto reached cloud → no notice
    }

    // MARK: - Deliverable 2 / test #5: ProjectFile round-trip and legacy decode

    @Test func projectFileRoundTripsTranscriptionPreference() throws {
        let file = ProjectFile(timelines: [Fixtures.timeline()], transcriptionPreference: .cloud)
        let data = try JSONEncoder().encode(file)
        let decoded = try ProjectFile.decode(data)
        #expect(decoded.transcriptionPreference == .cloud)
    }

    @Test func legacyProjectFileDecodesWithoutPreference() throws {
        // A project.json written before this field: the key is absent; decode must yield nil, not fail.
        let legacy = ProjectFile(timelines: [Fixtures.timeline()]) // nil preference
        let data = try JSONEncoder().encode(legacy)
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains("transcriptionPreference")) // nil optional is omitted from the encoding
        #expect(try ProjectFile.decode(data).transcriptionPreference == nil)
    }

    @MainActor
    @Test func editorAppliesAndSnapshotsPreference() {
        let editor = EditorViewModel()
        editor.applyProjectFile(ProjectFile(timelines: [Fixtures.timeline()], transcriptionPreference: .local))
        #expect(editor.transcriptionPreference == .local)
        #expect(editor.projectFileSnapshot().transcriptionPreference == .local)

        // Default preference is omitted from the snapshot so untouched projects stay byte-identical.
        editor.transcriptionPreference = .auto
        #expect(editor.projectFileSnapshot().transcriptionPreference == nil)
    }

    // MARK: - set_project_settings surface

    @MainActor
    @Test func setProjectSettingsUpdatesPreference() async throws {
        let harness = ToolHarness()
        let json = try await harness.runOK("set_project_settings", args: ["transcriptionPreference": "cloud"]) as? [String: Any]
        #expect(json?["transcriptionPreference"] as? String == "cloud")
        #expect((json?["changed"] as? [String])?.contains("transcriptionPreference") == true)
        #expect(harness.editor.transcriptionPreference == .cloud)
    }

    @MainActor
    @Test func setProjectSettingsRejectsUnknownPreference() async {
        let harness = ToolHarness()
        let result = await harness.runRaw("set_project_settings", args: ["transcriptionPreference": "gpu"])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("transcriptionPreference"))
    }

    @MainActor
    @Test func setProjectSettingsSchemaExposesPreference() throws {
        let tool = try #require(ToolDefinitions.all.first { $0.name == .setProjectSettings })
        let properties = try #require(tool.inputSchema["properties"] as? [String: [String: Any]])
        let pref = try #require(properties["transcriptionPreference"])
        #expect(pref["enum"] as? [String] == ["auto", "cloud", "local"])
    }
}
