import Foundation

extension ToolExecutor {
    fileprivate struct FindShotCandidatesInput: DecodableToolArgs {
        let query: String
        let kind: String
        let scope: String?
        let mediaRef: String?
        let includeLibrary: Bool?
        let includeRemote: Bool?
        let orientation: String?
        let maxDurationSeconds: Int?
        let limit: Int?
        let excludedSourceIds: [String]?
        let planId: String?
        let shotId: String?
        static let allowedKeys: Set<String> = [
            "query", "kind", "scope", "mediaRef", "includeLibrary", "includeRemote",
            "orientation", "maxDurationSeconds", "limit", "excludedSourceIds", "planId", "shotId",
        ]
    }

    /// Finds footage worth cutting by combining ready local evidence with downloadable stock
    /// catalog rows. It normalizes and ranks candidates only; downloading remains `import_media`
    /// and placement remains `add_clips`.
    func findShotCandidates(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: FindShotCandidatesInput.allowedKeys, path: "find_shot_candidates")
        let input: FindShotCandidatesInput = try decodeToolArgs(args, path: "find_shot_candidates")
        let text = input.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ToolError("find_shot_candidates: query is empty") }
        guard let kind = StockMediaKind.parse(input.kind) else {
            throw ToolError("kind must be one of \(StockMediaKind.allCases.map(\.rawValue).joined(separator: ", ")) (got '\(input.kind)')")
        }

        let includeLibrary = input.includeLibrary ?? true
        let includeRemote = input.includeRemote ?? true
        guard includeLibrary || includeRemote else {
            throw ToolError("Set includeLibrary or includeRemote to true.")
        }
        if !includeLibrary, input.scope != nil || input.mediaRef != nil {
            throw ToolError("scope and mediaRef apply only when includeLibrary is true.")
        }
        if !includeRemote, input.orientation != nil || input.maxDurationSeconds != nil {
            throw ToolError("orientation and maxDurationSeconds apply only when includeRemote is true.")
        }

        let scope = input.scope ?? "both"
        guard ["visual", "spoken", "both"].contains(scope) else {
            throw ToolError("find_shot_candidates: scope must be visual, spoken, or both (got '\(scope)')")
        }
        if includeLibrary, kind == .image, scope == "spoken" {
            throw ToolError("Images have no spoken transcript evidence; use scope visual or both.")
        }
        if includeLibrary, kind == .audio, scope == "visual" {
            throw ToolError("Audio has no visual evidence; use scope spoken or both.")
        }
        if let orientation = input.orientation,
           !["landscape", "portrait", "square"].contains(orientation) {
            throw ToolError("orientation must be landscape, portrait, or square (got '\(orientation)')")
        }
        if let maxDuration = input.maxDurationSeconds, maxDuration <= 0 {
            throw ToolError("maxDurationSeconds must be positive (got \(maxDuration))")
        }
        let limit = input.limit ?? 8
        guard (1...20).contains(limit) else { throw ToolError("limit must be an integer from 1 through 20.") }
        let explicitSourceIds = input.excludedSourceIds ?? []
        _ = try ShotCandidateExclusions(aliases: .init(), explicitSourceIds: explicitSourceIds)
        var plan: EditPlan?
        if let planId = input.planId {
            guard VisualSourceAliases.isValidEntityId(planId) else { throw ToolError("planId must be a nonempty stable ID of at most 200 characters without whitespace or colons.") }
            guard let selectedPlan = editor.editPlan(id: planId) else { throw ToolError("Unknown planId '\(planId)'.") }
            plan = selectedPlan
        }
        if input.shotId != nil, plan == nil {
            throw ToolError("shotId requires planId so the shot's requirement can be read.")
        }
        var planShot: EditPlanShot?
        if let shotId = input.shotId {
            guard let plan else { throw ToolError("shotId requires planId.") }
            guard VisualSourceAliases.isValidEntityId(shotId) else { throw ToolError("shotId must be a nonempty stable ID of at most 200 characters without whitespace or colons.") }
            guard let shot = plan.shots.first(where: { $0.id == shotId }) else { throw ToolError("Unknown shotId '\(shotId)' in plan '\(plan.id)'.") }
            planShot = shot
        }
        let requirement = planShot?.requirement
        // Verification rejects candidates, so retrieval asks for a bounded superset and the
        // shortlist limit applies after the rejections are known.
        let retrievalLimit = requirement == nil ? limit : min(limit * 3, 40)

        var restrict: Set<String>?
        if let mediaRef = input.mediaRef {
            restrict = [try asset(mediaRef, editor: editor).id]
        }

        let manifest = editor.mediaManifest
        let library = shotLibraryAssets(editor)
        let urls = editor.mediaAssets.map { (id: $0.id, url: $0.url) }
        let projectId = editor.projectId
        let projectURL = editor.projectURL
        let timelineId = editor.activeTimelineId
        let snapshot = try await ShotCandidateExclusions.snapshot(manifest: manifest, assets: library,
            explicitSourceIds: explicitSourceIds, selectedMediaRefs: Set(plan?.shots.compactMap(\.mediaRef) ?? []), kind: kind, restrict: restrict)
        let exclusions = snapshot.exclusions
        let assets = snapshot.assets
        func requireCurrentSnapshot() throws {
            guard self.editor === editor, editor.projectId == projectId, editor.projectURL == projectURL, editor.activeTimelineId == timelineId,
                  editor.mediaManifest == manifest, shotLibraryAssets(editor) == library,
                  zip(editor.mediaAssets, urls).allSatisfy({ $0.0.id == $0.1.id && $0.0.url == $0.1.url }),
                  input.planId.map({ editor.editPlan(id: $0) == plan }) ?? true else {
                throw ToolError("Project, plan, or library changed during shot retrieval; retry current state.")
            }
        }
        try requireCurrentSnapshot()
        var remoteRequest: StockMediaQuery?
        if includeRemote {
            remoteRequest = try StockMediaQuery(text: text, kind: kind, orientation: input.orientation,
                maxDurationSeconds: input.maxDurationSeconds, limit: retrievalLimit,
                excludedSourceIds: Set(exclusions.stockSourceIds)).normalized()
        }
        let eligible = snapshot.eligible
        var visualInputs: [ShotCandidateBuilder.VisualInput] = []
        var spokenInputs: [ShotCandidateBuilder.SpokenInput] = []
        var indexStatus: [String: Any]?
        if includeLibrary, usesVisualEvidence(kind: kind, scope: scope), !eligible.isEmpty {
            let fetch = await fetchVisualCandidates(editor, query: text, limit: retrievalLimit, restrict: eligible)
            indexStatus = fetch.index
            visualInputs = try await ShotCandidateRetrieval.visual(eligible: eligible, exclusions: exclusions, limit: retrievalLimit,
                initial: fetch.hits.map { .init(assetID: $0.assetID, startSeconds: $0.shotStart, endSeconds: $0.shotEnd, score: $0.score) }) { [self] count, refs in
                    await self.fetchVisualShotInputs(editor, query: text, limit: count, restrict: refs)
                }
        }
        if includeLibrary, usesSpokenEvidence(kind: kind, scope: scope) {
            let candidates = urls.filter { eligible.contains($0.id) }
            spokenInputs = try await ShotCandidateRetrieval.spoken(query: text, assets: candidates, exclusions: exclusions,
                representedMediaRefs: visualInputs.map(\.assetID), limit: retrievalLimit)
        }
        try Task.checkCancellation()

        var remoteHits: [StockMediaHit] = []
        var providerOutcomes: [StockProviderOutcome] = []
        if var request = remoteRequest {
            let represented = Set((visualInputs.map(\.assetID) + spokenInputs.map(\.assetID)).map { "media:\($0)" })
            let stockExclusions = exclusions.sourceIds.union(exclusions.aliases.expanded(represented))
                .filter { $0.hasPrefix("stock:") }
            request.excludedSourceIds = stockExclusions
            let collected = try await StockMediaSearch.collect(try request.normalized(), providers: stockProviders)
            remoteHits = collected.hits
            providerOutcomes = collected.outcomes
        }
        try Task.checkCancellation()

        let history = StockDeliveryHistory.load()
        var bundle = await Self.buildShotCandidates(kind: kind, visual: visualInputs, spoken: spokenInputs,
            remote: remoteHits, assets: assets, exclusions: exclusions, limit: retrievalLimit,
            usedSourceIds: history.usedSourceIds)
        try Task.checkCancellation()
        try requireCurrentSnapshot()

        var verification: [String: Any]?
        if let requirement {
            let verified = await verifyShotCandidates(
                editor,
                bundle: bundle,
                requirement: requirement,
                shotId: input.shotId,
                priorRejections: planShot?.rejections ?? [],
                limit: limit,
                aspectFormat: plan?.brief?.aspectFormat ?? input.orientation,
                usedMediaRefs: Set(plan?.shots.filter { $0.id != input.shotId }.compactMap(\.mediaRef) ?? [])
            )
            bundle = verified.bundle
            verification = verified.verification
        }

        var warnings: [String] = []
        if !includeLibrary { warnings.append("Local library search was disabled.") }
        if !includeRemote { warnings.append("Remote stock search was disabled.") }
        if let mediaRef = input.mediaRef {
            warnings.append("Library results are restricted to '\(mediaRef)'; remote stock is unrestricted.")
        }
        if indexStatus != nil {
            warnings.append("Local visual results may be incomplete; see local.index.")
        }
        if bundle.droppedUsable > 0 {
            warnings.append("Showing the first \(limit) usable candidates; \(bundle.droppedUsable) more were omitted by the limit.")
        }
        if !bundle.skipped.isEmpty {
            warnings.append("Skipped candidates are reported separately rather than silently dropped.")
        }
        if !exclusions.unresolved.isEmpty {
            warnings.append("Known source aliases were excluded; selected sources with unresolved identities cannot certify distinct alternatives.")
        }
        if !history.usedSourceIds.isEmpty {
            warnings.append("Sources used in recent deliveries are ranked lower, not excluded; the no-repeat rule applies within one output only.")
        }
        if verification != nil {
            warnings.append("Candidates were verified against the shot requirement by decoding their own frames; unverified candidates were not measured.")
        }

        var local: [String: Any] = ["included": includeLibrary, "scope": scope]
        if let mediaRef = input.mediaRef { local["mediaRef"] = mediaRef }
        if let indexStatus { local["index"] = indexStatus }
        let remote: [String: Any] = [
            "included": includeRemote,
            "providers": providerOutcomes.map(\.receipt),
        ]
        guard let json = Self.jsonString(roundJSONFloatingPointNumbers([
            "query": text,
            "kind": kind.rawValue,
            "limit": limit,
            "count": bundle.candidates.count,
            "truncated": bundle.droppedUsable > 0,
            "candidates": bundle.candidates.map { $0.receipt() },
            "skipped": bundle.skipped.map { $0.receipt() },
            "local": local,
            "remote": remote,
            "verification": verification as Any,
            "noOp": true,
            "exclusions": [
                "sourceIds": exclusions.sourceIds.sorted(),
                "selectedMediaRefs": exclusions.selectedMediaRefs.sorted(),
                "planId": input.planId.map { $0 as Any } ?? NSNull(),
                "scope": "retained_source_identity",
                "identityFreshness": "not_checked",
                "perceptualSimilarity": verification == nil ? "not_checked" : "measured_against_shot_requirement",
                "unresolved": exclusions.unresolved.map { ["reason": $0.reason, "mediaRef": $0.mediaRef ?? ""] },
            ],
            "warnings": warnings,
        ] as [String: Any], toPlaces: 3)) else {
            throw ToolError("find_shot_candidates: failed to encode results")
        }
        return .ok(json)
    }

    private func fetchVisualShotInputs(_ editor: EditorViewModel, query: String, limit: Int,
                                      restrict: Set<String>) async -> [ShotCandidateBuilder.VisualInput] {
        let fetched = await fetchVisualCandidates(editor, query: query, limit: limit, restrict: restrict)
        return fetched.hits.map { .init(assetID: $0.assetID, startSeconds: $0.shotStart, endSeconds: $0.shotEnd, score: $0.score) }
    }

    /// Verifies the shortlist against the shot requirement by decoding the candidates' own frames.
    /// Availability and rank stay in the candidate; this pass only adds an editorial decision.
    private func verifyShotCandidates(
        _ editor: EditorViewModel,
        bundle: ShotCandidateBundle,
        requirement: ShotRequirement,
        shotId: String?,
        priorRejections: [ShotRejection],
        limit: Int,
        aspectFormat: String? = nil,
        usedMediaRefs: Set<String> = []
    ) async -> (bundle: ShotCandidateBundle, verification: [String: Any]) {
        var skipped = bundle.skipped
        var previouslyRejected: [[String: Any]] = []

        var pending = bundle.candidates
        if !priorRejections.isEmpty {
            pending = pending.filter { candidate in
                guard let rejection = ShotVerifier.priorRejection(matching: candidate, in: priorRejections) else { return true }
                previouslyRejected.append([
                    "candidateId": candidate.id,
                    "reason": rejection.reason.rawValue,
                    "evidence": rejection.evidence,
                ])
                skipped.append(.init(id: candidate.id, source: candidate.source,
                                     reason: "Rejected earlier for this shot: \(rejection.reason.rawValue)."))
                return false
            }
        }

        let embedder = visualSearchModel.embedder
        var inspectable: [(candidate: ShotCandidate, url: URL, type: ClipType, duration: Double)] = []
        for candidate in pending {
            guard let mediaRef = candidate.mediaRef, let asset = editor.mediaAssetsById[mediaRef] else { continue }
            inspectable.append((candidate, asset.url, asset.type, asset.resolvedDuration))
        }
        let inspectedTargets = Array(inspectable.prefix(ShotVerifier.maximumInspections))
        var inspections: [String: ShotInspection] = [:]
        var index = 0
        while index < inspectedTargets.count {
            let upper = min(index + 2, inspectedTargets.count)
            let chunk = Array(inspectedTargets[index..<upper])
            let results = await withTaskGroup(of: (String, ShotInspection?).self, returning: [(String, ShotInspection?)].self) { group in
                for target in chunk {
                    group.addTask {
                        let inspection = await ShotVerifier.inspect(
                            candidate: target.candidate,
                            requirement: requirement,
                            mediaURL: target.url,
                            mediaType: target.type,
                            embedder: embedder
                        )
                        return (target.candidate.id, inspection)
                    }
                }
                var collected: [(String, ShotInspection?)] = []
                for await result in group { collected.append(result) }
                return collected
            }
            for (candidateId, inspection) in results {
                if let inspection { inspections[candidateId] = inspection }
            }
            index = upper
        }

        var best = ShotVerifier.BestScores()
        for inspection in inspections.values {
            best.record(inspection.subjectScore, for: .subject)
            best.record(inspection.actionScore, for: .action)
            best.record(inspection.locationScore, for: .location)
        }

        var accepted: [ShotCandidate] = []
        var rejected: [[String: Any]] = []
        for candidate in pending {
            var verified = candidate
            let inspection = inspections[candidate.id]
            verified.inspection = inspection
            if candidate.source == .stock {
                verified.acceptance = .unverified("Remote candidate is not imported; its content cannot be inspected before download.")
            } else if let inspection {
                let assetDuration = inspectable.first { $0.candidate.id == candidate.id }?.duration
                verified.acceptance = ShotVerifier.acceptance(
                    candidate: candidate,
                    requirement: requirement,
                    inspection: inspection,
                    best: best,
                    assetDurationSeconds: assetDuration,
                    aspectFormat: aspectFormat,
                    usedMediaRefs: usedMediaRefs
                )
            } else {
                verified.acceptance = .unverified("Not inspected: the verification budget for this call was spent on higher ranked candidates.")
            }
            switch verified.acceptance {
            case .rejected(let reason, let evidence):
                rejected.append([
                    "candidateId": candidate.id,
                    "mediaRef": candidate.mediaRef as Any,
                    "reason": reason.rawValue,
                    "evidence": evidence,
                ])
                skipped.append(.init(id: candidate.id, source: candidate.source,
                                     reason: "Rejected for this shot: \(reason.rawValue). \(evidence)"))
            case .accepted, .unverified:
                accepted.append(verified)
            }
        }

        let limited = Array(accepted.prefix(max(1, limit)))
        let verification: [String: Any] = [
            "shotId": shotId as Any,
            "requirement": requirement.receipt,
            "inspectedCandidateIds": inspections.keys.sorted(),
            "inspectionBudget": ShotVerifier.maximumInspections,
            "rejected": rejected,
            "previouslyRejected": previouslyRejected,
            "similarityFloor": ShotVerifier.similarityFloor,
            "similarityMargin": ShotVerifier.similarityMargin,
        ]
        return (
            ShotCandidateBundle(candidates: limited, skipped: skipped, droppedUsable: bundle.droppedUsable + max(0, accepted.count - limited.count)),
            verification
        )
    }

    private func shotLibraryAssets(_ editor: EditorViewModel) -> [LibraryShotAsset] {
        editor.mediaAssets.map { asset in
            let readiness: LibraryShotAsset.Readiness
            if editor.missingMediaRefs.contains(asset.id) || editor.unprocessableMediaRefs.contains(asset.id) {
                readiness = .unavailable("missing or unreadable")
            } else {
                switch asset.generationStatus {
                case .none: readiness = .ready
                case .failed(let message): readiness = .failed(message)
                default: readiness = .pending(asset.generationStatus.serialized)
                }
            }
            return LibraryShotAsset(id: asset.id, name: asset.name, type: asset.type,
                durationSeconds: asset.resolvedDuration, readiness: readiness,
                width: asset.sourceWidth, height: asset.sourceHeight,
                inputId: asset.inputIdentityReceipt["inputId"] as? String,
                inputIdentityState: asset.inputIdentityReceipt["inputIdentityState"] as? String ?? "unresolved",
                origin: asset.importInput?.origin)
        }
    }

    @concurrent
    private static func buildShotCandidates(kind: StockMediaKind, visual: [ShotCandidateBuilder.VisualInput],
        spoken: [ShotCandidateBuilder.SpokenInput], remote: [StockMediaHit], assets: [String: LibraryShotAsset],
        exclusions: ShotCandidateExclusions, limit: Int, usedSourceIds: Set<String> = []) async -> ShotCandidateBundle {
        ShotCandidateBuilder.build(kind: kind, visual: visual, spoken: spoken, remote: remote, assets: assets,
            limit: limit, aliases: exclusions.aliases, excludedSourceIds: exclusions.sourceIds,
            usedSourceIds: usedSourceIds)
    }

    private func usesVisualEvidence(kind: StockMediaKind, scope: String) -> Bool {
        switch kind {
        case .image: scope != "spoken"
        case .video: scope != "spoken"
        case .audio: false
        }
    }

    private func usesSpokenEvidence(kind: StockMediaKind, scope: String) -> Bool {
        switch kind {
        case .image: false
        case .video: scope != "visual"
        case .audio: scope != "visual"
        }
    }
}
