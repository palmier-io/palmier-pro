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
        static let allowedKeys: Set<String> = [
            "query", "kind", "scope", "mediaRef", "includeLibrary", "includeRemote",
            "orientation", "maxDurationSeconds", "limit",
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
        if let maxDuration = input.maxDurationSeconds, maxDuration < 0 {
            throw ToolError("maxDurationSeconds must be positive (got \(maxDuration))")
        }
        let limit = min(max(input.limit ?? 8, 1), 20)

        var restrict: Set<String>?
        if let mediaRef = input.mediaRef {
            restrict = [try asset(mediaRef, editor: editor).id]
        }

        var visualInputs: [VisualSearch.Hit] = []
        var spokenInputs: [TranscriptSearch.Hit] = []
        var indexStatus: [String: Any]?
        if includeLibrary, usesVisualEvidence(kind: kind, scope: scope) {
            let fetch = await fetchVisualCandidates(editor, query: text, limit: limit, restrict: restrict)
            visualInputs = fetch.hits
            indexStatus = fetch.index
        }
        if includeLibrary, usesSpokenEvidence(kind: kind, scope: scope) {
            let candidates = editor.mediaAssets
                .filter { ($0.type == .video || $0.type == .audio) && (restrict?.contains($0.id) ?? true) }
                .map { (id: $0.id, url: $0.url) }
            spokenInputs = TranscriptSearch.search(query: text, assets: candidates, limit: limit)
        }
        try Task.checkCancellation()

        var remoteHits: [StockMediaHit] = []
        var providerOutcomes: [StockProviderOutcome] = []
        if includeRemote {
            let collected = try await StockMediaSearch.collect(StockMediaQuery(
                text: text,
                kind: kind,
                orientation: input.orientation,
                maxDurationSeconds: input.maxDurationSeconds,
                limit: limit
            ))
            remoteHits = collected.hits
            providerOutcomes = collected.outcomes
        }
        try Task.checkCancellation()

        let assets = Dictionary(uniqueKeysWithValues: editor.mediaAssets.map { asset in
            let readiness: LibraryShotAsset.Readiness
            if editor.missingMediaRefs.contains(asset.id) || editor.unprocessableMediaRefs.contains(asset.id) {
                readiness = .unavailable("missing or unreadable")
            } else {
                switch asset.generationStatus {
                case .none:
                    readiness = .ready
                case .failed(let message):
                    readiness = .failed(message)
                default:
                    readiness = .pending(asset.generationStatus.serialized)
                }
            }
            return (asset.id, LibraryShotAsset(
                id: asset.id,
                name: asset.name,
                type: asset.type,
                durationSeconds: asset.resolvedDuration,
                readiness: readiness,
                width: asset.sourceWidth,
                height: asset.sourceHeight
            ))
        })
        let bundle = ShotCandidateBuilder.build(
            kind: kind,
            visual: visualInputs.map {
                ShotCandidateBuilder.VisualInput(assetID: $0.assetID, startSeconds: $0.shotStart, endSeconds: $0.shotEnd, score: $0.score)
            },
            spoken: spokenInputs.map {
                ShotCandidateBuilder.SpokenInput(assetID: $0.assetID, startSeconds: $0.start, endSeconds: $0.end, text: $0.text)
            },
            remote: remoteHits,
            assets: assets,
            limit: limit
        )

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
            "warnings": warnings,
        ] as [String: Any], toPlaces: 3)) else {
            throw ToolError("find_shot_candidates: failed to encode results")
        }
        return .ok(json)
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
