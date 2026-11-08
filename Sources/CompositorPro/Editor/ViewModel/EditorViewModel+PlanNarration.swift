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
