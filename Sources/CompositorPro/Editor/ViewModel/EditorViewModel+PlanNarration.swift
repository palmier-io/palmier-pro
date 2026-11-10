import AVFoundation
import Foundation

@MainActor
struct PlanNarrationChangeValidation {
    private struct Source {
        let asset: MediaAsset
        let context: MediaAsset.PreparationContext
        let identity: MediaInputIdentity?
        let type: ClipType
        let duration: Double
    }

    private let candidate: EditPlan
    private let previous: EditPlan?
    private let revision: VisualReviewRevision
    private let timeline: Timeline
    private let selectedClipIds: Set<String>
    private let selectedMediaAssetIds: Set<String>
    private var sources: [Source] = []

    fileprivate init(plan: EditPlan, editor: EditorViewModel) {
        candidate = plan
        previous = editor.editPlan(id: plan.id)
        revision = editor.visualReviewRevision
        timeline = editor.timeline
        selectedClipIds = editor.selectedClipIds
        selectedMediaAssetIds = editor.selectedMediaAssetIds
    }

    fileprivate mutating func observe(_ asset: MediaAsset) {
        sources.append(Source(asset: asset, context: asset.preparationContext, identity: asset.inputIdentity,
                              type: asset.type, duration: asset.duration))
    }

    fileprivate func validateContext(in editor: EditorViewModel) throws {
        try Task.checkCancellation()
        guard editor.editPlan(id: candidate.id) == previous, editor.visualReviewRevision == revision,
              editor.timeline == timeline, editor.selectedClipIds == selectedClipIds,
              editor.selectedMediaAssetIds == selectedMediaAssetIds,
              sources.allSatisfy({ source in
                   editor.mediaAssetsById[source.asset.id] === source.asset && source.asset.preparationContext == source.context
                       && source.asset.inputIdentity == source.identity
                      && source.asset.type == source.type && source.asset.duration == source.duration
                      && !editor.missingMediaRefs.contains(source.asset.id)
                      && !editor.unprocessableMediaRefs.contains(source.asset.id)
              }) else {
            throw EditPlanValidationError.invalidReference("Plan, recording, selection, project, or timeline changed while validating narration; retry current state.")
        }
    }

    func validate(plan: EditPlan, previous: EditPlan?, in editor: EditorViewModel) throws {
        guard candidate == plan, self.previous == previous else {
            throw EditPlanValidationError.invalidReference("Narration validation does not match this plan change.")
        }
        try validateContext(in: editor)
    }
}

struct PreparedPlanNarrationChange {
    var plan: EditPlan
    var validation: PlanNarrationChangeValidation
}

@MainActor
struct PlanNarrationSession {
    var plan: EditPlan
    var timeline: Timeline
    var projectURL: URL?
    var sourceURL: URL
    private var sourceAsset: MediaAsset
    private var sourceContext: MediaAsset.PreparationContext
    private var sourceIdentity: MediaInputIdentity?
    private var sourceDuration: Double
    private var revision: VisualReviewRevision
    private var selectedClipIds: Set<String>
    private var selectedMediaAssetIds: Set<String>

    @MainActor
    init(editor: EditorViewModel, planId: String) throws {
        guard let plan = editor.editPlan(id: planId), let source = plan.narration,
               let asset = editor.mediaAssetsById[source.mediaRef], asset.type == .audio,
               asset.generationStatus == .none, asset.duration.isFinite, asset.duration > 0,
              !editor.missingMediaRefs.contains(asset.id), !editor.unprocessableMediaRefs.contains(asset.id),
              plan.timelineId == editor.activeTimelineId,
              plan.fps == editor.timeline.fps, plan.width == editor.timeline.width, plan.height == editor.timeline.height else {
            throw EditPlanValidationError.invalidReference("Narration timing requires the plan's matching active timeline and a ready audio asset.")
        }
        self.plan = plan
        timeline = editor.timeline
        projectURL = editor.projectURL
        sourceURL = asset.url
        sourceAsset = asset
        sourceContext = asset.preparationContext
        sourceIdentity = asset.inputIdentity
        sourceDuration = asset.duration
        revision = editor.visualReviewRevision
        selectedClipIds = editor.selectedClipIds
        selectedMediaAssetIds = editor.selectedMediaAssetIds
    }

    @MainActor
    func validateCurrent(in editor: EditorViewModel) throws {
        try Task.checkCancellation()
        guard editor.projectURL == projectURL, editor.timeline == timeline,
              editor.visualReviewRevision == revision, editor.selectedClipIds == selectedClipIds,
              editor.selectedMediaAssetIds == selectedMediaAssetIds,
              editor.editPlan(id: plan.id) == plan, editor.activeTimelineId == plan.timelineId,
              let asset = editor.mediaAssetsById[plan.narration?.mediaRef ?? ""], asset === sourceAsset,
               asset.preparationContext == sourceContext, asset.inputIdentity == sourceIdentity,
              asset.type == .audio, asset.duration == sourceDuration,
              asset.generationStatus == .none,
              !editor.missingMediaRefs.contains(asset.id), !editor.unprocessableMediaRefs.contains(asset.id) else {
            throw EditPlanValidationError.invalidReference("Plan, narration, project, or timeline changed during timing preparation; retry the current revision.")
        }
    }
}

extension EditorViewModel {
    func verifyPlanNarrationAttachment(session: PlanNarrationSession) async throws {
        guard session.plan.productionRun != nil else { return }
        let identity = try await MediaInputIdentityService.shared.identify(session.sourceURL, force: true)
        try session.validateCurrent(in: self)
        try session.plan.validateNarrationAttachment(identity: identity)
    }

    func preparePlanNarrationChange(
        _ candidate: EditPlan,
        intentRequest: NarrationIntentRequest? = nil,
        identify: @Sendable (URL) async throws -> MediaInputIdentity = {
            try await MediaInputIdentityService.shared.identify($0, force: true)
        }
    ) async throws -> PreparedPlanNarrationChange {
        guard candidate.timelineId == activeTimelineId, candidate.fps == timeline.fps,
              candidate.width == timeline.width, candidate.height == timeline.height else {
            throw EditPlanValidationError.invalidReference("Narration changes require the plan's matching active timeline.")
        }
        var plan = candidate
        var context = PlanNarrationChangeValidation(plan: candidate, editor: self)
        if let request = intentRequest {
            var intent = NarrationIntent(language: request.language, startFrame: request.startFrame)
            _ = try intent.validated()
            if let narrator = request.narrator {
                switch narrator.kind {
                case "recording":
                    guard let ref = narrator.mediaRef, narrator.engine == nil, narrator.voiceIdentifier == nil,
                          narrator.rate == nil, narrator.pitch == nil else {
                        throw EditPlanValidationError.invalidReference("Recording narrator requires only kind and mediaRef; speech settings and asserted identities are not allowed.")
                    }
                    let asset = try readyNarrationAsset(mediaRef: ref)
                    context.observe(asset)
                    let identity = try await identify(asset.url)
                    try context.validateContext(in: self)
                    guard identity.isValid else { throw EditPlanValidationError.invalidReference("Recording identity is unresolved.") }
                    intent.narrator = .recording(RecordingNarrator(mediaRef: asset.id, identity: identity))
                case "local_speech":
                    let speech = try await request.resolveLocalSpeech()
                    try context.validateContext(in: self)
                    intent.narrator = .localSpeech(speech)
                default:
                    throw EditPlanValidationError.invalidReference("Narrator kind must be local_speech or recording.")
                }
            }
            plan.narrationIntent = try intent.validated()
        } else if plan.narrationIntent?.narrator != editPlan(id: plan.id)?.narrationIntent?.narrator {
            if let intent = plan.narrationIntent {
                try await intent.verifyAvailableNarrator()
                try context.validateContext(in: self)
                if case .recording(let recording) = intent.narrator {
                    let asset = try readyNarrationAsset(mediaRef: recording.mediaRef)
                    context.observe(asset)
                    let measured = try await identify(asset.url)
                    try context.validateContext(in: self)
                    guard measured == recording.identity else {
                        throw EditPlanValidationError.invalidReference("Recording intent does not match the actual selected bytes.")
                    }
                }
            }
        }
        let previous = editPlan(id: plan.id)
        if plan.productionRun != nil, plan.narration != previous?.narration, let source = plan.narration {
            let asset = try readyNarrationAsset(mediaRef: source.mediaRef)
            context.observe(asset)
            let measured = try await identify(asset.url)
            try context.validateContext(in: self)
            try plan.validateNarrationAttachment(identity: measured)
        }
        try context.validateContext(in: self)
        var validation = PlanNarrationChangeValidation(plan: plan, editor: self)
        if let intent = plan.narrationIntent, case .recording(let recording) = intent.narrator {
            validation.observe(try readyNarrationAsset(mediaRef: recording.mediaRef))
        }
        if plan.productionRun != nil, let source = plan.narration, plan.narration != previous?.narration {
            validation.observe(try readyNarrationAsset(mediaRef: source.mediaRef))
        }
        return PreparedPlanNarrationChange(plan: plan, validation: validation)
    }

    @discardableResult
    func setPlanNarrationIntent(planId: String, request: NarrationIntentRequest) async throws -> EditPlanChangeReceipt {
        guard let plan = editPlan(id: planId) else { throw EditPlanValidationError.invalidReference("Unknown planId '\(planId)'.") }
        let prepared = try await preparePlanNarrationChange(plan, intentRequest: request)
        return try changeEditPlans(updates: [prepared.plan], actionName: L10n.string("Change Narration Intent"),
                                   narrationValidation: prepared.validation)
    }

    @discardableResult
    func attachPlanNarration(planId: String, mediaRef: String) async throws -> EditPlanChangeReceipt {
        guard var plan = editPlan(id: planId) else { throw EditPlanValidationError.invalidReference("Unknown planId '\(planId)'.") }
        plan.narration = try NarrationSource(mediaRef: mediaRef).validated()
        let prepared = try await preparePlanNarrationChange(plan)
        return try changeEditPlans(updates: [prepared.plan], actionName: L10n.string("Attach Narration"),
                                   narrationValidation: prepared.validation)
    }

    func readyNarrationAsset(mediaRef: String) throws -> MediaAsset {
        guard let asset = mediaAssetsById[mediaRef], asset.type == .audio, asset.generationStatus == .none,
              asset.duration.isFinite, asset.duration > 0,
              !missingMediaRefs.contains(mediaRef), !unprocessableMediaRefs.contains(mediaRef) else {
            throw EditPlanValidationError.invalidReference("Narration requires an exact ready library audio asset.")
        }
        return asset
    }

    func verifyRecordingNarrator(plan: EditPlan) async throws -> PlanNarrationChangeValidation? {
        guard let intent = plan.narrationIntent, case .recording(let recording) = intent.narrator else { return nil }
        var observed = PlanNarrationChangeValidation(plan: plan, editor: self)
        let asset = try readyNarrationAsset(mediaRef: recording.mediaRef)
        observed.observe(asset)
        let measured = try await MediaInputIdentityService.shared.identify(asset.url, force: true)
        try observed.validateContext(in: self)
        guard measured == recording.identity else {
            throw EditPlanValidationError.invalidReference("Chosen recording bytes changed; choose and approve the current narrator.")
        }
        return observed
    }

    enum PlanNarrationPreparationResult: Sendable {
        case noOp(EditPlanChangeReceipt)
        case prepared(EditPlanChangeReceipt)
        case unresolved(EditPlanChangeReceipt, reason: String)
    }

    func prepareApprovedNarration(planId: String,
                                  render: (@Sendable (LocalSpeechNarrator, String, String, @escaping @Sendable () -> Bool) async throws -> SpeechSynthesizer.PinnedRenderEvidence)? = nil,
                                  identify: @Sendable (URL) async throws -> MediaInputIdentity = { try await MediaInputIdentityService.shared.identify($0, force: true) },
                                  transcribe: (@Sendable (URL, String?) async throws -> TranscriptionResult?)? = nil) async throws -> PlanNarrationPreparationResult {
        let plan = try await currentApprovedNarrationPlan(planId: planId)
        guard let intent = plan.narrationIntent, let language = intent.language,
              case .localSpeech(let narrator) = intent.narrator, let beats = plan.scriptBeats else {
            throw EditPlanValidationError.invalidReference("Prepare narration requires an approved plan with a complete local narrator and script beats.")
        }
        let spokenDigest = NarrationSpokenText.digest(beats: beats)
        let revision = UUID().uuidString
        let speech = beats.map(\.narrationText).joined(separator: "\n\n")
        let evidence: SpeechSynthesizer.PinnedRenderEvidence
        if let render {
            evidence = try await render(narrator, language, speech, { @Sendable in Task.isCancelled })
        } else {
            evidence = try await SpeechSynthesizer.renderPinned(narrator: narrator, language: language, text: speech,
                                                                isCancelled: { @Sendable in Task.isCancelled })
        }
        let staged = evidence.url
        defer { try? FileManager.default.removeItem(at: staged) }
        let stagedIdentity = try await identify(staged)
        try Task.checkCancellation()
        guard stagedIdentity.isValid else {
            throw EditPlanValidationError.invalidReference("Rendered narration produced unreadable audio.")
        }
        let contextPlan = try await currentApprovedNarrationPlan(planId: planId)
        if contextPlan.narrationSynthesisProof?.mediaRef == contextPlan.narration?.mediaRef,
           let existing = contextPlan.narration, let existingAsset = mediaAssetsById[existing.mediaRef],
           contextPlan.narrationSynthesisProof?.matches(narrator: narrator, language: language,
                                                        spokenTextDigest: spokenDigest,
                                                        narrationRevision: contextPlan.narrationRevision) == true,
           contextPlan.narrationTiming?.sourceFingerprint == stagedIdentity.contentSHA256,
           contextPlan.narrationTiming?.unresolvedBeatIds.isEmpty == true {
            var existingIdentity = existingAsset.inputIdentity
            if existingIdentity == nil { existingIdentity = try? await identify(existingAsset.url) }
            if existingIdentity == stagedIdentity {
                return .noOp(EditPlanChangeReceipt(created: [], updated: [contextPlan], deletedIds: []))
            }
        }

        let source = try NarrationSource(mediaRef: UUID().uuidString).validated()
        let transcript: TranscriptionResult?
        if let transcribe { transcript = try await transcribe(staged, language) }
        else { transcript = try await attemptNarrationTranscript(url: staged, language: language) }
        let aligned: NarrationTiming?
        var unresolvedReason: String?
        if let transcript {
            let duration = try await narrationDuration(staged)
            aligned = try NarrationAlignment.align(beats: beats, transcript: transcript, duration: duration,
                                                   revision: revision, fingerprint: stagedIdentity.contentSHA256)
        } else {
            aligned = nil
            unresolvedReason = "narration_timing_unresolved"
        }
        let measured = (aligned?.unresolvedBeatIds.isEmpty == true) ? aligned : nil
        if measured == nil { unresolvedReason = "narration_timing_unresolved" }

        let planNow = try await currentApprovedNarrationPlan(planId: planId)
        guard let intentNow = planNow.narrationIntent, let languageNow = intentNow.language,
              case .localSpeech(let narratorNow) = intentNow.narrator,
              narratorNow == narrator, languageNow == language,
              NarrationSpokenText.digest(beats: planNow.scriptBeats ?? []) == spokenDigest else {
            throw EditPlanValidationError.invalidReference("Approved narrator or script changed during synthesis; retry Prepare Narration.")
        }

        let request = NarrationSynthesisRequest(planId: planNow.id, timelineId: planNow.timelineId,
                                                runId: planNow.productionRun?.id,
                                                approvedRevision: planNow.productionRun?.approvedRevision ?? "",
                                                narrationRevision: revision, engine: narrator.engine,
                                                voiceIdentifier: narrator.voiceIdentifier, language: language,
                                                rate: narrator.rate, pitch: narrator.pitch, spokenTextDigest: spokenDigest)
        let proof = NarrationSynthesisProof(requestDigest: request.digest, planId: planNow.id, timelineId: planNow.timelineId,
                                            runId: planNow.productionRun?.id,
                                            approvedRevision: planNow.productionRun?.approvedRevision ?? "",
                                            narrationRevision: revision, engine: narrator.engine,
                                            voiceIdentifier: narrator.voiceIdentifier, language: language,
                                            rate: narrator.rate, pitch: narrator.pitch, spokenTextDigest: spokenDigest,
                                            modelIdentity: narrator.modelIdentity, configurationIdentity: narrator.configurationIdentity,
                                            writtenFrames: evidence.writtenFrames, insertedSilenceSeconds: evidence.insertedSilenceSeconds,
                                            mediaRef: source.mediaRef, installedIdentity: stagedIdentity)

        let asset = MediaAsset(id: source.mediaRef, url: staged, type: .audio, name: "Narration")
        let filename = "narration-\(source.mediaRef).wav"
        _ = try await projectPackageCoordinator.withMutation { lease in
            try await self.commitStagedProjectMedia(staged, filename: filename, lease: lease, validate: {
                guard let p = self.editPlan(id: planId), p.productionRun?.phase == .approved else {
                    throw EditPlanValidationError.invalidReference("Approved narration state changed before publication; retry.")
                }
            }) { destination in
                asset.url = destination
                self.importMediaAsset(asset)
                var prospective = planNow
                prospective.narration = source
                prospective.narrationRevision = revision
                prospective.narrationTiming = measured
                prospective.narrationSynthesisProof = proof
                let before = self.editPlans
                let next = before.map { $0.id == prospective.id ? prospective : $0 }
                let action = L10n.string("Prepare Narration")
                self.undo.register(action, withTarget: self) { vm in
                    vm.editPlans = before
                    vm.onProjectCheckpointRequired?()
                    vm.undo.register(action, withTarget: vm) { redo in
                        redo.editPlans = next
                        redo.onProjectCheckpointRequired?()
                        redo.undo.register(action, withTarget: redo) { vm2 in
                            vm2.editPlans = before
                            vm2.onProjectCheckpointRequired?()
                        }
                    }
                }
                self.editPlans = next
                self.onProjectCheckpointRequired?()
            }
        }
        _ = await finalizeImportedAsset(asset)

        let receipt = EditPlanChangeReceipt(created: [], updated: [editPlan(id: planId)].compactMap { $0 }, deletedIds: [])
        if let reason = unresolvedReason, measured == nil {
            return .unresolved(receipt, reason: reason)
        }
        return .prepared(receipt)
    }

    private func currentApprovedNarrationPlan(planId: String) async throws -> EditPlan {
        try Task.checkCancellation()
        guard let plan = editPlan(id: planId), plan.timelineId == activeTimelineId,
              plan.fps == timeline.fps, plan.width == timeline.width, plan.height == timeline.height,
              let run = plan.productionRun, run.phase == .approved, let approved = run.approvedRevision else {
            throw EditPlanValidationError.invalidReference("Prepare narration requires the plan's matching active timeline and an approved storyboard.")
        }
        let report = try await storyboardReport(planId: planId)
        try Task.checkCancellation()
        guard report.revision == approved, report.approvalBlockers.isEmpty, editPlan(id: planId) == plan else {
            throw EditPlanValidationError.invalidReference("Approved storyboard changed; approve the current revision before preparing narration.")
        }
        return plan
    }

    private func attemptNarrationTranscript(url: URL, language: String?) async throws -> TranscriptionResult? {
        let locale = language.map(Locale.init(identifier:))
        if let locale {
            let supported = await Transcription.supportedLocales()
            guard Transcription.matchLocale(candidates: [locale], supported: supported) != nil else { return nil }
        }
        do { return try await Transcription.transcribe(fileURL: url, preferredLocale: locale) }
        catch is CancellationError { throw CancellationError() }
        catch { return nil }
    }

    private func narrationDuration(_ url: URL) async throws -> NarrationTime {
        let asset = AVURLAsset(url: url)
        return try await NarrationTime(asset.load(.duration))
    }

    func commitPlanNarrationTiming(_ timing: NarrationTiming, session: PlanNarrationSession) throws -> EditPlanChangeReceipt {
        try Task.checkCancellation()
        try session.validateCurrent(in: self)
        var plan = session.plan
        try timing.validated(beats: plan.scriptBeats ?? [], revision: plan.narrationRevision)
        if plan.productionRun != nil, case .recording(let recording) = plan.narrationIntent?.narrator,
           timing.sourceFingerprint != recording.identity.contentSHA256 {
            throw EditPlanValidationError.invalidReference("Measured narration does not match the chosen recording byte identity.")
        }
        plan.narrationTiming = timing
        return try changeEditPlans(updates: [plan], actionName: L10n.string("Measure Narration"))
    }
}
