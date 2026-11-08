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
        static let allowedKeys: Set<String> = [
            "query", "kind", "scope", "mediaRef", "includeLibrary", "includeRemote",
            "orientation", "maxDurationSeconds", "limit", "excludedSourceIds", "planId",
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
                maxDurationSeconds: input.maxDurationSeconds, limit: limit,
                excludedSourceIds: Set(exclusions.stockSourceIds)).normalized()
        }
        let eligible = snapshot.eligible
        var visualInputs: [ShotCandidateBuilder.VisualInput] = []
        var spokenInputs: [ShotCandidateBuilder.SpokenInput] = []
        var indexStatus: [String: Any]?
        if includeLibrary, usesVisualEvidence(kind: kind, scope: scope), !eligible.isEmpty {
            let fetch = await fetchVisualCandidates(editor, query: text, limit: limit, restrict: eligible)
            indexStatus = fetch.index
            visualInputs = try await ShotCandidateRetrieval.visual(eligible: eligible, exclusions: exclusions, limit: limit,
                initial: fetch.hits.map { .init(assetID: $0.assetID, startSeconds: $0.shotStart, endSeconds: $0.shotEnd, score: $0.score) }) { [self] count, refs in
                    await self.fetchVisualShotInputs(editor, query: text, limit: count, restrict: refs)
                }
        }
        if includeLibrary, usesSpokenEvidence(kind: kind, scope: scope) {
            let candidates = urls.filter { eligible.contains($0.id) }
            spokenInputs = try await ShotCandidateRetrieval.spoken(query: text, assets: candidates, exclusions: exclusions,
                representedMediaRefs: visualInputs.map(\.assetID), limit: limit)
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

        let bundle = await Self.buildShotCandidates(kind: kind, visual: visualInputs, spoken: spokenInputs,
            remote: remoteHits, assets: assets, exclusions: exclusions, limit: limit)
        try Task.checkCancellation()
        try requireCurrentSnapshot()

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
            "noOp": true,
            "exclusions": [
                "sourceIds": exclusions.sourceIds.sorted(),
                "selectedMediaRefs": exclusions.selectedMediaRefs.sorted(),
                "planId": input.planId.map { $0 as Any } ?? NSNull(),
                "scope": "retained_source_identity",
                "identityFreshness": "not_checked",
                "perceptualSimilarity": "not_checked",
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
        exclusions: ShotCandidateExclusions, limit: Int) async -> ShotCandidateBundle {
        ShotCandidateBuilder.build(kind: kind, visual: visual, spoken: spoken, remote: remote, assets: assets,
            limit: limit, aliases: exclusions.aliases, excludedSourceIds: exclusions.sourceIds)
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
