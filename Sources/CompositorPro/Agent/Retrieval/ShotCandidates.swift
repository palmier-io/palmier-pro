import Foundation

enum ShotCandidateSource: String, Codable, Sendable, CaseIterable {
    case library
    case stock
}

enum ShotCandidateEvidence: String, Codable, Sendable, CaseIterable {
    case visual
    case spoken
    case catalog
}

struct LibraryShotAsset: Sendable, Equatable {
    enum Readiness: Sendable, Equatable {
        case ready
        case pending(String)
        case failed(String)
        case unavailable(String)
    }

    var id: String
    var name: String
    var type: ClipType
    var durationSeconds: Double
    var readiness: Readiness
    var width: Int? = nil
    var height: Int? = nil
    var inputId: String? = nil
    var inputIdentityState: String = "unresolved"
    var origin: MediaImportOrigin? = nil
}

struct ShotCandidate: Sendable, Equatable, Identifiable {
    var id: String
    var source: ShotCandidateSource
    var providerID: String?
    var mediaRef: String?
    var url: String?
    var name: String?
    var title: String?
    var kind: StockMediaKind
    var creator: String?
    var license: String?
    var licenseURL: String?
    var attribution: String?
    var durationSeconds: Double?
    var sourceStartSeconds: Double?
    var sourceEndSeconds: Double?
    var score: Double?
    var evidence: [ShotCandidateEvidence]
    var rank: Int?
    var usable: Bool
    var blockers: [String]
    var width: Int? = nil
    var height: Int? = nil
    var thumbnailURL: String? = nil
    var landingPageURL: String? = nil
    var inputId: String? = nil
    var inputIdentityState: String = "unresolved"
    var origin: MediaImportOrigin? = nil
    /// Rank the provider gave this row, kept apart from the merged shortlist rank.
    var providerRank: Int? = nil
    /// Editorial decision against the shot requirement this candidate was retrieved for.
    var acceptance: ShotAcceptance = .unverified("not_inspected")
    /// Measurements taken from the candidate's own decoded frames.
    var inspection: ShotInspection? = nil

    func receipt() -> [String: Any] {
        var out: [String: Any] = [
            "candidateId": id,
            "source": source.rawValue,
            "kind": kind.rawValue,
            "usable": usable,
            "evidence": evidence.map(\.rawValue),
        ]
        if let providerID { out["provider"] = providerID }
        if let mediaRef { out["mediaRef"] = mediaRef }
        if let url { out["url"] = url }
        if let name { out["name"] = name }
        if let title { out["title"] = title }
        if let creator { out["creator"] = creator }
        if let license { out["license"] = license }
        if let licenseURL { out["licenseUrl"] = licenseURL }
        if let attribution { out["attribution"] = attribution }
        if let durationSeconds { out["durationSeconds"] = durationSeconds }
        if let sourceStartSeconds { out["sourceStartSeconds"] = sourceStartSeconds }
        if let sourceEndSeconds { out["sourceEndSeconds"] = sourceEndSeconds }
        if let score { out["score"] = score }
        if let rank { out["rank"] = rank }
        if let providerRank { out["providerRank"] = providerRank }
        if !blockers.isEmpty { out["blockers"] = blockers }
        if let width { out["width"] = width }
        if let height { out["height"] = height }
        if let thumbnailURL { out["thumbnailUrl"] = thumbnailURL }
        if let landingPageURL { out["landingPageUrl"] = landingPageURL }
        if let inputId { out["inputId"] = inputId }
        out["inputIdentityState"] = inputIdentityState
        if let origin { out["origin"] = origin.receipt }
        out["acceptance"] = acceptance.receipt
        if let inspection { out["inspection"] = inspection.receipt }
        return out
    }
}

struct ShotCandidateSkipped: Sendable, Equatable {
    var id: String
    var source: ShotCandidateSource
    var reason: String

    func receipt() -> [String: Any] {
        ["candidateId": id, "source": source.rawValue, "reason": reason]
    }
}

struct ShotCandidateBundle: Sendable, Equatable {
    var candidates: [ShotCandidate]
    var skipped: [ShotCandidateSkipped]
    var droppedUsable: Int
}

struct ShotCandidateExclusions: Sendable, Equatable {
    static let maximumExplicitSourceIds = 256

    let aliases: VisualSourceAliases
    let sourceIds: Set<String>
    let selectedMediaRefs: Set<String>
    let unresolved: [VisualUniquenessIssue]

    init(aliases: VisualSourceAliases, explicitSourceIds: [String], selectedMediaRefs: Set<String> = [],
         unresolved: [VisualUniquenessIssue] = []) throws {
        guard explicitSourceIds.count <= Self.maximumExplicitSourceIds else {
            throw ToolError("excludedSourceIds accepts at most \(Self.maximumExplicitSourceIds) canonical IDs.")
        }
        guard explicitSourceIds.allSatisfy(VisualSourceAliases.isCanonicalSourceId) else {
            throw ToolError("excludedSourceIds must contain canonical media:<mediaRef>, sha256:<64 lowercase hex digits>, or stock:<provider>:<assetId> IDs.")
        }
        guard Set(explicitSourceIds).count == explicitSourceIds.count else {
            throw ToolError("excludedSourceIds must not contain duplicate IDs.")
        }
        self.aliases = aliases
        self.selectedMediaRefs = selectedMediaRefs
        self.unresolved = unresolved
        self.sourceIds = aliases.expanded(Set(explicitSourceIds).union(selectedMediaRefs.map { "media:\($0)" }))
    }

    var stockSourceIds: [String] { sourceIds.filter { $0.hasPrefix("stock:") }.sorted() }

    func excludes(mediaRef: String) -> Bool { sourceIds.contains("media:\(mediaRef)") }

    func root(mediaRef: String) -> String { aliases.root("media:\(mediaRef)") }

    func eligibleAssets(_ assets: [String: LibraryShotAsset], kind: StockMediaKind,
                        restrict: Set<String>? = nil) -> Set<String> {
        Set(assets.values.compactMap { asset in
            guard asset.readiness == .ready, asset.type.rawValue == kind.rawValue,
                  restrict?.contains(asset.id) ?? true, !excludes(mediaRef: asset.id) else { return nil }
            return asset.id
        })
    }

    @concurrent
    static func snapshot(manifest: MediaManifest, assets: [LibraryShotAsset], explicitSourceIds: [String],
                         selectedMediaRefs: Set<String>, kind: StockMediaKind, restrict: Set<String>?) async throws
        -> (assets: [String: LibraryShotAsset], exclusions: Self, eligible: Set<String>) {
        try Task.checkCancellation()
        _ = try Self(aliases: .init(), explicitSourceIds: explicitSourceIds)
        var byId: [String: LibraryShotAsset] = [:]
        for asset in assets {
            guard byId.updateValue(asset, forKey: asset.id) == nil else { throw ToolError("Duplicate library mediaRef '\(asset.id)'.") }
        }
        var seenManifestRefs = Set<String>()
        var manifestById: [String: MediaManifestEntry] = [:]
        var sources: [VisualSourceAliases.Source] = []
        for entry in manifest.entries {
            try Task.checkCancellation()
            guard seenManifestRefs.insert(entry.id).inserted else { throw ToolError("Duplicate manifest mediaRef '\(entry.id)'.") }
            manifestById[entry.id] = entry
            if let asset = byId[entry.id] {
                sources.append(.init(mediaRef: entry.id, inputId: asset.inputId, origin: asset.origin))
            } else {
                sources.append(.init(mediaRef: entry.id, inputId: entry.inputIdentity.flatMap { $0.isValid ? $0.inputId : nil },
                                     origin: entry.importInput?.origin))
            }
        }
        for asset in assets where !seenManifestRefs.contains(asset.id) {
            sources.append(.init(mediaRef: asset.id, inputId: asset.inputId, origin: asset.origin))
        }
        let aliases = VisualSourceAliases(sources: sources)
        var unresolved: [VisualUniquenessIssue] = []
        for ref in selectedMediaRefs.sorted() {
            let entry = manifestById[ref]
            let inputId: String?
            if let asset = byId[ref] { inputId = asset.inputId }
            else { inputId = entry?.inputIdentity.flatMap { $0.isValid ? $0.inputId : nil } }
            if byId[ref] == nil, entry == nil {
                unresolved.append(.init(reason: "missing_media", clipId: nil, mediaRef: ref))
            } else if !VisualSourceAliases.isValidInputId(inputId ?? "") {
                unresolved.append(.init(reason: "missing_content_identity", clipId: nil, mediaRef: ref))
            }
            if entry?.generationInput != nil || entry?.type == .lottie {
                unresolved.append(.init(reason: "unresolved_derivative_lineage", clipId: nil, mediaRef: ref))
            }
        }
        let exclusions = try Self(aliases: aliases, explicitSourceIds: explicitSourceIds,
                                  selectedMediaRefs: selectedMediaRefs, unresolved: unresolved)
        let eligible = exclusions.eligibleAssets(byId, kind: kind, restrict: restrict)
        try Task.checkCancellation()
        return (byId, exclusions, eligible)
    }
}

enum ShotCandidateRetrieval {
    @concurrent
    static func visual(eligible: Set<String>, exclusions: ShotCandidateExclusions, limit: Int,
                       initial: [ShotCandidateBuilder.VisualInput]? = nil,
                       fetch: @Sendable (Int, Set<String>) async throws -> [ShotCandidateBuilder.VisualInput]) async throws -> [ShotCandidateBuilder.VisualInput] {
        var remaining = eligible
        var results: [ShotCandidateBuilder.VisualInput] = []
        var seen = Set<String>()
        var first = initial
        while results.count < limit, !remaining.isEmpty {
            try Task.checkCancellation()
            let hits: [ShotCandidateBuilder.VisualInput]
            if let initial = first {
                hits = initial
                first = nil
            } else {
                hits = try await fetch(limit - results.count, remaining)
            }
            try Task.checkCancellation()
            guard !hits.isEmpty else { break }
            let oldCount = remaining.count
            let ordered = hits.sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                if $0.assetID != $1.assetID { return $0.assetID < $1.assetID }
                return $0.startSeconds < $1.startSeconds
            }
            for hit in ordered where remaining.contains(hit.assetID) {
                if seen.insert(exclusions.root(mediaRef: hit.assetID)).inserted { results.append(hit) }
            }
            remaining = remaining.filter { !seen.contains(exclusions.root(mediaRef: $0)) }
            guard remaining.count < oldCount else { break }
        }
        return results
    }

    @concurrent
    static func spoken(query: String, assets: [(id: String, url: URL)], exclusions: ShotCandidateExclusions,
                       representedMediaRefs: [String] = [], limit: Int) async throws -> [ShotCandidateBuilder.SpokenInput] {
        let represented = Set(representedMediaRefs.map { exclusions.root(mediaRef: $0) })
        var remaining = assets.filter { !represented.contains(exclusions.root(mediaRef: $0.id)) }.sorted { $0.id < $1.id }
        var results: [ShotCandidateBuilder.SpokenInput] = []
        var seen = Set<String>()
        while results.count < limit, !remaining.isEmpty {
            try Task.checkCancellation()
            let hits = TranscriptSearch.search(query: query, assets: remaining, limit: limit - results.count)
            guard !hits.isEmpty else { break }
            for hit in hits {
                if seen.insert(exclusions.root(mediaRef: hit.assetID)).inserted {
                    results.append(.init(assetID: hit.assetID, startSeconds: hit.start, endSeconds: hit.end, text: hit.text))
                }
            }
            remaining.removeAll { seen.contains(exclusions.root(mediaRef: $0.id)) }
        }
        try Task.checkCancellation()
        return results
    }
}

enum ShotCandidateBuilder {
    struct VisualInput: Sendable, Equatable {
        var assetID: String
        var startSeconds: Double
        var endSeconds: Double
        var score: Float
    }

    struct SpokenInput: Sendable, Equatable {
        var assetID: String
        var startSeconds: Double
        var endSeconds: Double
        var text: String
    }

    /// Normalizes already-fetched local and remote evidence without fetching, downloading,
    /// importing, or placing anything. Ready library matches sort before remote catalog rows
    /// because they need no download; source-provided relevance is never invented across modes.
    static func build(
        kind: StockMediaKind,
        visual: [VisualInput],
        spoken: [SpokenInput],
        remote: [StockMediaHit],
        assets: [String: LibraryShotAsset],
        limit: Int,
        aliases: VisualSourceAliases? = nil,
        excludedSourceIds: Set<String> = [],
        usedSourceIds: Set<String> = []
    ) -> ShotCandidateBundle {
        let aliases = aliases ?? VisualSourceAliases(sources: assets.values.map {
            .init(mediaRef: $0.id, inputId: $0.inputId, origin: $0.origin)
        })
        let excludedSourceIds = aliases.expanded(excludedSourceIds)
        var visualCandidates: [ShotCandidate] = []
        var spokenCandidates: [ShotCandidate] = []
        var remoteCandidates: [ShotCandidate] = []
        var skipped: [ShotCandidateSkipped] = []
        var seenIDs = Set<String>()

        func append(_ candidate: inout ShotCandidate, to group: inout [ShotCandidate]) {
            if let mediaRef = candidate.mediaRef, let asset = assets[mediaRef] {
                candidate.inputId = asset.inputId
                candidate.inputIdentityState = asset.inputIdentityState
                candidate.origin = asset.origin
                if !VisualSourceAliases.isValidInputId(asset.inputId ?? "") {
                    candidate.blockers.append("missing_content_identity")
                }
            }
            let sourceIds = VisualSourceAliases.sourceIds(mediaRef: candidate.mediaRef, inputId: candidate.inputId,
                                                         origin: candidate.origin)
            guard !sourceIds.contains(where: excludedSourceIds.contains) else {
                skipped.append(.init(id: candidate.id, source: candidate.source, reason: "Excluded source identity."))
                return
            }
            guard seenIDs.insert(candidate.id).inserted else {
                skipped.append(ShotCandidateSkipped(id: candidate.id, source: candidate.source, reason: "Duplicate candidate."))
                return
            }
            group.append(candidate)
        }

        func addSkipped(id: String, source: ShotCandidateSource, reason: String) {
            guard seenIDs.insert("skipped:\(id)").inserted else { return }
            skipped.append(ShotCandidateSkipped(id: id, source: source, reason: reason))
        }

        for input in visual {
            guard let asset = assets[input.assetID] else {
                addSkipped(id: "library:\(input.assetID):visual", source: .library, reason: "No current asset for this visual hit. It may have been removed after indexing.")
                continue
            }
            guard let candidateKind = shotKind(for: asset.type), candidateKind == kind else {
                addSkipped(id: "library:\(asset.id):visual", source: .library, reason: "Asset '\(asset.id)' is \(asset.type.rawValue); shot retrieval needs \(kind.rawValue) media.")
                continue
            }
            let start = roundMilliseconds(input.startSeconds)
            let end = roundMilliseconds(input.endSeconds)
            let id = "library:\(asset.id):visual:\(start)-\(end)"
            // A still has no range to speak of: the indexer records one embedding with a
            // zero-length span, so demanding a non-empty span discarded every image in the library.
            guard end > start || candidateKind == .image else {
                addSkipped(id: id, source: .library, reason: "Visual hit has an empty source span.")
                continue
            }
            switch asset.readiness {
            case .ready:
                var candidate = ShotCandidate(
                    id: id,
                    source: .library,
                    providerID: nil,
                    mediaRef: asset.id,
                    url: nil,
                    name: asset.name,
                    title: nil,
                    kind: candidateKind,
                    creator: nil,
                    license: nil,
                    licenseURL: nil,
                    attribution: nil,
                    durationSeconds: positive(asset.durationSeconds),
                    sourceStartSeconds: candidateKind == .image ? nil : start,
                    sourceEndSeconds: candidateKind == .image ? nil : end,
                    score: roundedScore(Double(input.score)),
                    evidence: [.visual],
                    rank: nil,
                    usable: true,
                    blockers: [],
                    width: positiveDimension(asset.width),
                    height: positiveDimension(asset.height)
                )
                append(&candidate, to: &visualCandidates)
            case .pending(let status):
                addSkipped(id: id, source: .library, reason: "Asset '\(asset.id)' is still \(status).")
            case .failed(let message):
                addSkipped(id: id, source: .library, reason: "Asset '\(asset.id)' failed: \(message)")
            case .unavailable(let reason):
                addSkipped(id: id, source: .library, reason: reason)
            }
        }

        for input in spoken {
            guard let asset = assets[input.assetID] else {
                addSkipped(id: "library:\(input.assetID):spoken", source: .library, reason: "No current asset for this transcript hit.")
                continue
            }
            guard let candidateKind = shotKind(for: asset.type), candidateKind == kind else {
                addSkipped(id: "library:\(asset.id):spoken", source: .library, reason: "Asset '\(asset.id)' is \(asset.type.rawValue); shot retrieval needs \(kind.rawValue) media.")
                continue
            }
            let start = roundMilliseconds(input.startSeconds)
            let end = roundMilliseconds(input.endSeconds)
            let id = "library:\(asset.id):spoken:\(start)-\(end)"
            guard end > start else {
                addSkipped(id: id, source: .library, reason: "Transcript hit has an empty source span.")
                continue
            }
            switch asset.readiness {
            case .ready:
                var candidate = ShotCandidate(
                    id: id,
                    source: .library,
                    providerID: nil,
                    mediaRef: asset.id,
                    url: nil,
                    name: asset.name,
                    title: input.text,
                    kind: candidateKind,
                    creator: nil,
                    license: nil,
                    licenseURL: nil,
                    attribution: nil,
                    durationSeconds: positive(asset.durationSeconds),
                    sourceStartSeconds: start,
                    sourceEndSeconds: end,
                    score: nil,
                    evidence: [.spoken],
                    rank: nil,
                    usable: true,
                    blockers: [],
                    width: positiveDimension(asset.width),
                    height: positiveDimension(asset.height)
                )
                append(&candidate, to: &spokenCandidates)
            case .pending(let status):
                addSkipped(id: id, source: .library, reason: "Asset '\(asset.id)' is still \(status).")
            case .failed(let message):
                addSkipped(id: id, source: .library, reason: "Asset '\(asset.id)' failed: \(message)")
            case .unavailable(let reason):
                addSkipped(id: id, source: .library, reason: reason)
            }
        }

        var providerRanks: [String: Int] = [:]
        for hit in remote {
            let id = "stock:\(hit.providerID):\(hit.id)"
            let providerRank = (providerRanks[hit.providerID] ?? 0) + 1
            providerRanks[hit.providerID] = providerRank
            guard hit.kind == kind else {
                addSkipped(id: id, source: .stock, reason: "Remote hit is \(hit.kind.rawValue); shot retrieval needs \(kind.rawValue) media.")
                continue
            }
            guard let url = httpsURL(hit.url) else {
                addSkipped(id: id, source: .stock, reason: "Remote candidate is not downloadable over HTTPS.")
                continue
            }
            let license = hit.license.trimmingCharacters(in: .whitespacesAndNewlines)
            let attribution = hit.attribution.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !license.isEmpty, !attribution.isEmpty else {
                addSkipped(id: id, source: .stock, reason: "Remote candidate is missing license or attribution.")
                continue
            }
            let duration = hit.durationSeconds.map(Double.init).flatMap(positive)
            var candidate = ShotCandidate(
                id: id,
                source: .stock,
                providerID: hit.providerID,
                mediaRef: nil,
                url: url,
                name: nil,
                title: hit.title,
                kind: hit.kind,
                creator: hit.creator,
                license: license,
                licenseURL: hit.licenseURL,
                attribution: attribution,
                durationSeconds: duration,
                sourceStartSeconds: hit.kind == .image ? nil : duration.map { _ in 0 },
                sourceEndSeconds: hit.kind == .image ? nil : duration,
                score: nil,
                evidence: [.catalog],
                rank: nil,
                usable: true,
                blockers: [],
                width: positiveDimension(hit.width),
                height: positiveDimension(hit.height),
                thumbnailURL: hit.thumbnailURL.flatMap(httpsURL),
                landingPageURL: hit.landingPageURL.flatMap(httpsURL),
                origin: hit.origin,
                providerRank: providerRank
            )
            append(&candidate, to: &remoteCandidates)
        }

        let orderedVisual = visualCandidates.sorted {
            if $0.score != $1.score { return ($0.score ?? -.infinity) > ($1.score ?? -.infinity) }
            return $0.id < $1.id
        }
        let orderedSpoken = spokenCandidates.sorted {
            if $0.sourceStartSeconds != $1.sourceStartSeconds {
                return ($0.sourceStartSeconds ?? 0) < ($1.sourceStartSeconds ?? 0)
            }
            return $0.id < $1.id
        }
        // Remote catalog rows that already appear in the recent delivery history are ranked after
        // sources not yet used, so repeated clips do not silently win every new brief.
        let orderedRemote = remoteCandidates.sorted { a, b in
            let aIds = VisualSourceAliases.sourceIds(mediaRef: a.mediaRef, inputId: a.inputId, origin: a.origin)
            let bIds = VisualSourceAliases.sourceIds(mediaRef: b.mediaRef, inputId: b.inputId, origin: b.origin)
            let aUsed = !usedSourceIds.isDisjoint(with: aIds)
            let bUsed = !usedSourceIds.isDisjoint(with: bIds)
            if aUsed != bUsed { return !aUsed }
            guard a.providerID != b.providerID else { return a.id < b.id }
            return a.providerID ?? "" < b.providerID ?? ""
        }
        // A provider with many rows must not fill the whole shortlist. Each provider contributes
        // its best row before any provider contributes a second one, so the limit still compares
        // providers rather than counting one of them.
        let diversifiedRemote = interleaveByProvider(orderedRemote)
        // Ready library rows need no download, so they precede remote catalog rows. Within each
        // evidence group, only source-provided ordering is used; no cross-mode score is invented.
        var seenSources = Set<String>()
        let usable = (orderedVisual + orderedSpoken + diversifiedRemote).filter { candidate in
            let ids = VisualSourceAliases.sourceIds(mediaRef: candidate.mediaRef, inputId: candidate.inputId, origin: candidate.origin)
            let root = aliases.root(ids.first ?? candidate.id)
            guard seenSources.insert(root).inserted else {
                skipped.append(.init(id: candidate.id, source: candidate.source, reason: "Duplicate source identity."))
                return false
            }
            return true
        }
        let ranked = usable.enumerated().map { index, candidate in
            var candidate = candidate
            candidate.rank = index + 1
            return candidate
        }
        let limited = Array(ranked.prefix(max(1, limit)))
        return ShotCandidateBundle(
            candidates: limited,
            skipped: skipped,
            droppedUsable: max(0, ranked.count - limited.count)
        )
    }

    private static func sourceIds(_ candidate: ShotCandidate) -> Set<String> {
        Set(VisualSourceAliases.sourceIds(mediaRef: candidate.mediaRef, inputId: candidate.inputId,
                                          origin: candidate.origin))
    }

    /// Orders rows so every provider appears once before any provider appears twice.
    /// Provider rank inside each provider is preserved.
    static func interleaveByProvider(_ candidates: [ShotCandidate]) -> [ShotCandidate] {
        var grouped: [String: [ShotCandidate]] = [:]
        var providerOrder: [String] = []
        for candidate in candidates {
            let provider = candidate.providerID ?? ""
            if grouped[provider] == nil { providerOrder.append(provider) }
            grouped[provider, default: []].append(candidate)
        }
        var result: [ShotCandidate] = []
        var index = 0
        while result.count < candidates.count {
            var added = false
            for provider in providerOrder {
                let rows = grouped[provider] ?? []
                guard index < rows.count else { continue }
                result.append(rows[index])
                added = true
            }
            guard added else { break }
            index += 1
        }
        return result
    }

    private static func shotKind(for type: ClipType) -> StockMediaKind? {
        switch type {
        case .video: .video
        case .image: .image
        case .audio: .audio
        case .text, .lottie, .sequence, .subtitle, .html: nil
        }
    }

    private static func positive(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    private static func positiveDimension(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }

    private static func roundedScore(_ value: Double) -> Double {
        (value * 1_000).rounded() / 1_000
    }

    private static func roundMilliseconds(_ value: Double) -> Double {
        (value * 1_000).rounded() / 1_000
    }

    private static func httpsURL(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              url.scheme == "https",
              url.host?.isEmpty == false else { return nil }
        return trimmed
    }
}

extension ToolExecutor {
    struct VisualCandidateFetch {
        var hits: [VisualSearch.Hit]
        var moments: [[String: Any]]
        var index: [String: Any]?
    }

    static func visualIndexStatus(
        _ coordinator: SearchIndexCoordinator,
        model: any VisualSearchModelLoading
    ) -> String {
        guard model.enabled else { return "disabled" }
        switch model.state {
        case .ready: return coordinator.indexingActive ? "indexing" : "ready"
        case .notInstalled: return "modelNotInstalled"
        case .downloading: return "downloadingModel"
        case .preparing, .unknown: return "preparing"
        case .failed: return "failed"
        }
    }

    func fetchVisualCandidates(
        _ editor: EditorViewModel,
        query: String,
        limit: Int,
        restrict: Set<String>?
    ) async -> VisualCandidateFetch {
        let coordinator = editor.searchIndex
        let indexable = editor.mediaAssets.filter {
            ($0.type == .video || $0.type == .image) && (restrict?.contains($0.id) ?? true)
        }
        if !indexable.isEmpty, visualSearchModel.enabled, visualSearchModel.state == .unknown {
            await visualSearchModel.prepare()
        }
        if !indexable.isEmpty, visualSearchModel.enabled, visualSearchModel.state == .notInstalled {
            visualSearchModel.download()
        }

        let status = Self.visualIndexStatus(coordinator, model: visualSearchModel)
        var indexed: Int?
        if let spec = visualSearchModel.embedder?.spec {
            let urls = indexable.map(\.url)
            indexed = await Task.detached {
                urls.filter { !VisualIndexer.needsIndex(url: $0, spec: spec) }.count
            }.value
        }

        var index: [String: Any]?
        if !indexable.isEmpty, status != "ready" || (indexed ?? indexable.count) < indexable.count {
            var info: [String: Any] = ["status": status, "indexableAssets": indexable.count]
            if let indexed { info["indexedAssets"] = indexed }
            if case .downloading(let progress) = visualSearchModel.state {
                info["modelDownloadProgress"] = progress
            }
            if case .failed(let reason) = visualSearchModel.state {
                info["modelDownloadError"] = reason
            }
            index = info
        }

        let hits = await coordinator.search(query: query, limit: limit, within: restrict)
        let moments = hits.map { hit -> [String: Any] in
            let asset = editor.mediaAssets.first { $0.id == hit.assetID }
            var entry: [String: Any] = [
                "mediaRef": hit.assetID,
                "name": asset?.name ?? "",
                "score": Double(hit.score),
            ]
            if asset?.type == .image {
                entry["type"] = "image"
            } else {
                entry["startSeconds"] = hit.shotStart
                entry["endSeconds"] = hit.shotEnd
            }
            return entry
        }
        return VisualCandidateFetch(hits: hits, moments: moments, index: index)
    }
}
