import Foundation
import MCP
import Testing
@testable import CompositorPro

struct RuntimeCapabilityTests {
    struct HostedCase: Sendable {
        var enabled = true
        var configured = true
        var signedIn = true
        var hasCredits = true
        var catalogLoaded = true
        var reason: RuntimeCapability.Reason?
    }

    @Test(arguments: [
        HostedCase(enabled: false, configured: false, signedIn: false, hasCredits: false, catalogLoaded: false, reason: .hostedBuildExcluded),
        HostedCase(enabled: false, reason: .hostedBuildExcluded),
        HostedCase(configured: false, reason: .backendUnconfigured),
        HostedCase(signedIn: false, reason: .authenticationRequired),
        HostedCase(hasCredits: false, reason: .creditsRequired),
        HostedCase(catalogLoaded: false, reason: .catalogUnavailable),
        HostedCase(),
    ])
    func hostedPrerequisitesHaveDistinctReasons(_ input: HostedCase) {
        let state = RuntimeCapabilities.hostedGeneration(
            enabled: input.enabled, configured: input.configured, signedIn: input.signedIn,
            hasCredits: input.hasCredits, catalogLoaded: input.catalogLoaded
        )
        #expect(state.reason == input.reason)
        #expect(state.canStart == (input.reason == nil))
    }

    @Test(arguments: [false, true], [false, true])
    func denoisingRequiresBothFeatureAndRuntime(bundled: Bool, runtime: Bool) {
        let state = RuntimeCapabilities.denoising(bundledSpeech: bundled, runtimeAvailable: runtime)
        #expect(state.canStart == (bundled && runtime))
        #expect(state.reason == (!bundled ? .speechBuildExcluded : !runtime ? .runtimeUnavailable : .onDemandModel))
        if bundled && runtime { #expect(state.status == .needsPreparation) }
    }

    @Test func chatImageSupportDoesNotEnableMediaGeneration() {
        #expect(RuntimeCapabilities.imageInput(supported: true).canStart)
        let hosted = RuntimeCapabilities.hostedGeneration(
            enabled: false, configured: true, signedIn: true, hasCredits: true, catalogLoaded: true
        )
        #expect(!hosted.canStart)
        #expect(hosted.reason == .hostedBuildExcluded)
        #expect(RuntimeCapabilities.imageInput(supported: nil).status == .unknown)
        #expect(RuntimeCapabilities.imageInput(supported: false).reason == .unsupportedModality)
    }

    @Test(arguments: [false, true], [false, true])
    func eitherConfiguredVideoProviderIsEnough(pexels: Bool, pixabay: Bool) {
        let input = RuntimeCapabilities.LocalInputs(pexelsConfigured: pexels, pixabayConfigured: pixabay)
        #expect(RuntimeCapabilities.stockVideo(input).canStart == (pexels || pixabay))
    }

    @Test func localSpeechNeedsAVoiceAndItsEngine() {
        #expect(!RuntimeCapabilities.speech(.init()).canStart)
        #expect(!RuntimeCapabilities.speech(.init(piperLanguages: ["en-US"])).canStart)
        #expect(!RuntimeCapabilities.speech(.init(piperInstalled: true)).canStart)
        #expect(RuntimeCapabilities.speech(.init(piperInstalled: true, piperLanguages: ["en-US"])).canStart)
        #expect(RuntimeCapabilities.speech(.init(systemSpeechLanguages: ["en-US"])).canStart)
    }

    @Test func blockerKindDistinguishesAllCategories() {
        #expect(RuntimeCapability.Reason.hostedBuildExcluded.blockerKind == .buildExclusion)
        #expect(RuntimeCapability.Reason.speechBuildExcluded.blockerKind == .buildExclusion)
        #expect(RuntimeCapability.Reason.runtimeUnavailable.blockerKind == .buildExclusion)

        #expect(RuntimeCapability.Reason.modelNotInstalled.blockerKind == .missingModelDownload)
        #expect(RuntimeCapability.Reason.modelPreparing.blockerKind == .missingModelDownload)
        #expect(RuntimeCapability.Reason.modelNotChecked.blockerKind == .missingModelDownload)
        #expect(RuntimeCapability.Reason.onDemandModel.blockerKind == .missingModelDownload)
        #expect(RuntimeCapability.Reason.voiceUnavailable.blockerKind == .missingModelDownload)

        #expect(RuntimeCapability.Reason.backendUnconfigured.blockerKind == .missingProviderCredential)
        #expect(RuntimeCapability.Reason.authenticationRequired.blockerKind == .missingProviderCredential)
        #expect(RuntimeCapability.Reason.creditsRequired.blockerKind == .missingProviderCredential)
        #expect(RuntimeCapability.Reason.credentialMissing.blockerKind == .missingProviderCredential)

        #expect(RuntimeCapability.Reason.unsupportedModality.blockerKind == .unsupportedModality)
        #expect(RuntimeCapability.Reason.clientDependent.blockerKind == .unsupportedModality)
        #expect(RuntimeCapability.Reason.disabled.blockerKind == .unsupportedModality)

        #expect(RuntimeCapability.Reason.modelFailed.blockerKind == .temporaryProviderFailure)
        #expect(RuntimeCapability.Reason.temporaryProviderFailure.blockerKind == .temporaryProviderFailure)
        #expect(RuntimeCapability.Reason.catalogUnavailable.blockerKind == .temporaryProviderFailure)
    }

    @Test func visualInspectionAvailabilityReflectsImageSupport() {
        let available = RuntimeCapabilities.visualInspection(imageInputSupported: true)
        #expect(available.canStart)
        #expect(available.status == .available)

        let unavailable = RuntimeCapabilities.visualInspection(imageInputSupported: false)
        #expect(!unavailable.canStart)
        #expect(unavailable.status == .unavailable)
        #expect(unavailable.reason == .unsupportedModality)
        #expect(unavailable.reason?.blockerKind == .unsupportedModality)

        let unknown = RuntimeCapabilities.visualInspection(imageInputSupported: nil)
        #expect(unknown.status == .unknown)
        #expect(unknown.reason == .clientDependent)
        #expect(unknown.reason?.blockerKind == .unsupportedModality)
    }
}

@MainActor
struct CapabilityToolTests {
    @Test func discoveryAndInspectionWorkWithoutAnOpenProject() async throws {
        let executor = ToolExecutor(projectProvider: { nil }, capabilityInputLoader: {
            .init(pixabayConfigured: true, systemSpeechLanguages: ["en-US"])
        })
        try await withClient(executor) { client in
            let (tools, _) = try await client.listTools()
            let tool = try #require(tools.first { $0.name == "get_capabilities" })
            #expect(tool.inputSchema.objectValue?["type"]?.stringValue == "object")
            #expect(tool.inputSchema.objectValue?["additionalProperties"] == .bool(false))
            let response = try await client.callTool(name: "get_capabilities", arguments: [:])
            #expect(response.isError != true)
            let body = try decode(response)
            let operations = try #require(body["operations"] as? [String: [String: Any]])
            #expect(operations["generate_video"]?["reason"] as? String == "hosted_build_excluded")
            #expect(operations["stock_video_search"]?["canStart"] as? Bool == true)
            #expect(operations["generate_speech"]?["canStart"] as? Bool == true)
            #expect((body["agentImageInput"] as? [String: Any])?["status"] as? String == "unknown")
            let invalid = try await client.callTool(name: "get_capabilities", arguments: ["prompt": .string("unused")])
            #expect(invalid.isError == true)
        }
    }

    @Test(.enabled(if: !AudioEnhancer.availability.canStart), arguments: ["denoise_audio", "enhance_voice"])
    func unavailableEnhancementRefusesBeforeMutationThroughMCP(tool: String) async throws {
        let h = ToolHarness()
        let asset = h.addAsset(type: .audio)
        h.editor.timeline = Fixtures.timeline(tracks: [Fixtures.audioTrack(clips: [
            Fixtures.clip(id: "voice-clip", mediaRef: asset.id, mediaType: .audio, start: 0, duration: 60),
        ])])
        let undo = UndoManager()
        h.editor.undo.attach(undo)
        let before = h.editor.timeline
        let executor = ToolExecutor(editor: h.editor, capabilityInputLoader: { .init() })
        try await withClient(executor) { client in
            let response = try await client.callTool(name: tool, arguments: ["clipIds": .array([.string("voice-clip")])])
            #expect(response.isError == true)
            let error = try decode(response)
            #expect(error["reason"] as? String == AudioEnhancer.availability.reason?.rawValue)
            let readback = try await client.callTool(name: "get_timeline", arguments: [:])
            #expect(readback.isError != true)
            #expect(h.editor.timeline == before)
            #expect(h.editor.loudnessInFlight.isEmpty)
            #expect(h.editor.denoiseInFlight.isEmpty)
            #expect(!undo.canUndo)
        }
    }

    @Test func hostedRefusalAndModelDiscoveryUseTheSameReason() async throws {
        let h = ToolHarness()
        let executor = ToolExecutor(editor: h.editor, capabilityInputLoader: { .init() })
        let before = h.editor.timeline
        let assetsBefore = h.editor.mediaAssets.count
        try await withClient(executor) { client in
            let capabilities = try decode(await client.callTool(name: "get_capabilities", arguments: [:]))
            let models = try decode(await client.callTool(name: "list_models", arguments: ["type": .string("video")]))
            let response = try await client.callTool(name: "generate_video", arguments: ["prompt": .string("A lake at dawn")])
            let refusal = try decode(response)
            let operations = try #require(capabilities["operations"] as? [String: [String: Any]])
            let availability = try #require(models["availability"] as? [String: Any])
            #expect(response.isError == true)
            #expect(operations["generate_video"]?["reason"] as? String == availability["reason"] as? String)
            #expect(refusal["reason"] as? String == availability["reason"] as? String)
            #expect(h.editor.timeline == before)
            #expect(h.editor.mediaAssets.count == assetsBefore)
        }
    }

    @Test func disablingAnExistingEnhancementDoesNotRequireItsRuntime() throws {
        let editor = EditorViewModel()
        var clip = Fixtures.clip(id: "voice", mediaType: .audio, start: 0, duration: 60)
        clip.effects = [Effect(type: Clip.enhanceEffectType, enabled: true, params: [:])]
        editor.timeline = Fixtures.timeline(tracks: [Fixtures.audioTrack(clips: [clip])])
        try editor.setEnhance(clipIds: [clip.id], enabled: false, actionName: "Disable Enhance Voice")
        #expect(editor.timeline.tracks.first?.clips.first?.hasEnhanceEnabled == false)
        #expect(editor.loudnessInFlight.isEmpty)
    }

    @Test func visualReadinessIsRecomputedWithoutStartingModelWork() async throws {
        let model = CapabilityVisualModel()
        let executor = ToolExecutor(projectProvider: { nil }, visualSearchModel: model, capabilityInputLoader: { .init() })
        try await withClient(executor) { client in
            for (state, reason) in [
                (VisualModelLoader.State.notInstalled, "model_not_installed"),
                (.downloading(0.5), "model_preparing"),
                (.failed("Offline"), "model_failed"),
            ] {
                model.state = state
                let body = try decode(await client.callTool(name: "get_capabilities", arguments: [:]))
                let operations = try #require(body["operations"] as? [String: [String: Any]])
                #expect(operations["visual_search"]?["reason"] as? String == reason)
            }
            #expect(!model.wasStarted)
        }
    }

    @Test func cancelledInspectionDoesNotReturnAvailabilityAsSuccess() async {
        let (started, startSignal) = AsyncStream<Void>.makeStream()
        let (release, releaseSignal) = AsyncStream<Void>.makeStream()
        let executor = ToolExecutor(projectProvider: { nil }, capabilityInputLoader: {
            startSignal.yield(())
            var iterator = release.makeAsyncIterator()
            _ = await iterator.next()
            return .init()
        })
        let task = Task { await executor.execute(name: "get_capabilities", args: [:]) }
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()
        task.cancel()
        releaseSignal.finish()
        let result = await task.value
        #expect(result.isError)
        startSignal.finish()
    }

    @Test func receiptIncludesBlockerKindAndRecommendations() async throws {
        let executor = ToolExecutor(projectProvider: { nil }, capabilityInputLoader: {
            .init(pixabayConfigured: true, systemSpeechLanguages: ["en-US"])
        })
        try await withClient(executor) { client in
            let response = try await client.callTool(name: "get_capabilities", arguments: [:])
            let body = try decode(response)
            let operations = try #require(body["operations"] as? [String: [String: Any]])
            #expect(operations["generate_video"]?["blockerKind"] as? String == "build_exclusion")
            #expect(operations["visual_inspection"] != nil)
            #expect(operations["inspect_timeline"] != nil)
            let recommendations = try #require(body["recommendations"] as? [String])
            #expect(!recommendations.isEmpty)
            #expect(recommendations.contains { $0.contains("Hosted generation is excluded") })
        }
    }

    @Test func speechExecutionRefusesWhenCapabilityUnavailable() async throws {
        let h = ToolHarness()
        let executor = ToolExecutor(editor: h.editor, capabilityInputLoader: { .init() })
        try await withClient(executor) { client in
            let response = try await client.callTool(name: "generate_speech", arguments: ["text": .string("Test line")])
            #expect(response.isError == true)
            let error = try decode(response)
            #expect(error["reason"] as? String == "voice_unavailable")
            #expect(error["blockerKind"] as? String == "missing_model_download")
        }
    }

    @Test func materialSubstitutionsResolvedFromBriefAndCapabilities() async throws {
        let harness = ToolHarness()
        let genAsset = harness.addAsset(type: .video)
        genAsset.generationInput = GenerationInput(prompt: "Sun", model: "model", duration: 5, aspectRatio: "16:9", resolution: "1080p")
        harness.editor.mediaAssets = [genAsset]
        harness.editor.mediaManifest.entries = [genAsset.toManifestEntry(projectURL: nil)]

        let shot = EditPlanShot(id: "shot1", title: "Scene 1", startFrame: 0, endFrame: 60, mediaRef: genAsset.id,
                                license: "MIT", attribution: "AI",
                                narrationLink: .init(firstBeatId: "beat1", lastBeatId: "beat1"))
        let script = [ScriptBeat(beatId: "beat1", text: "Hello", purpose: "Intro")]
        var plan = EditPlan(name: "Plan", timelineId: harness.editor.activeTimelineId, fps: 30, width: 1920, height: 1080,
                            shots: [shot], scriptBeats: script,
                            brief: PlanBrief(realism: .realFootageOnly))
        try harness.editor.changeEditPlans(creates: [plan], actionName: "Create")

        let board = try await StoryboardResolver.resolve(plan: plan, manifest: harness.editor.mediaManifest)
        #expect(board.approvalBlockers.contains("shot1:unpermitted_generated_footage"))
        let matching = board.materialSubstitutions.first { $0.sceneId == "shot1" }
        let sub = try #require(matching)
        #expect(sub.requestedKind == "real_footage")
        #expect(sub.actualKind == "generated")
    }

    private func decode(_ response: (content: [Tool.Content], isError: Bool?)) throws -> [String: Any] {
        let texts = response.content.compactMap { block -> String? in
            if case .text(let text, _, _) = block { return text }
            return nil
        }
        let text = try #require(texts.first)
        return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func withClient(_ executor: ToolExecutor, _ body: (Client) async throws -> Void) async throws {
        let server = Server(name: "capability-test", version: "1", capabilities: .init(tools: .init(listChanged: false)))
        await MCPService.registerTools(on: server, executor: executor)
        let transports = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "capability-test", version: "1")
        try await server.start(transport: transports.server)
        do {
            _ = try await client.connect(transport: transports.client)
            try await body(client)
        } catch {
            await client.disconnect()
            await server.stop()
            throw error
        }
        await client.disconnect()
        await server.stop()
    }
}

@MainActor
private final class CapabilityVisualModel: VisualSearchModelLoading {
    var enabled = true
    var state = VisualModelLoader.State.notInstalled
    var embedder: VisualEmbedder? { nil }
    var wasStarted = false
    func prepare() async { wasStarted = true }
    func download() { wasStarted = true }
}
