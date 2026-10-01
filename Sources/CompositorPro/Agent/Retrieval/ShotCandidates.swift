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
        if !blockers.isEmpty { out["blockers"] = blockers }
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
        limit: Int
    ) -> ShotCandidateBundle {
        var visualCandidates: [ShotCandidate] = []
        var spokenCandidates: [ShotCandidate] = []
        var remoteCandidates: [ShotCandidate] = []
        var candidates: [ShotCandidate] = []
        var skipped: [ShotCandidateSkipped] = []
        var seenIDs = Set<String>()

        func append(_ candidate: inout ShotCandidate, to group: inout [ShotCandidate]) {
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
            guard end > start else {
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
                    blockers: []
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
                    blockers: []
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

        for hit in remote {
            let id = "stock:\(hit.providerID):\(hit.id)"
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
                blockers: []
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
        // Ready library rows need no download, so they precede remote catalog rows. Within each
        // evidence group, only source-provided ordering is used; no cross-mode score is invented.
        let usable = orderedVisual + orderedSpoken + remoteCandidates
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

    private static func shotKind(for type: ClipType) -> StockMediaKind? {
        switch type {
        case .video: .video
        case .image: .image
        case .audio: .audio
        case .text, .lottie, .sequence, .subtitle: nil
        }
    }

    private static func positive(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
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
