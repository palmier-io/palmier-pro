import Foundation

/// Complementary-source evaluation for shot candidates: prefer provider variety, refuse repeated
/// URLs and near-duplicate subjects, and report why each candidate was skipped so an agent can
/// widen its query instead of re-rolling the same pool.
enum SourceDiversity {
    struct Candidate: Sendable, Equatable {
        var id: String
        var providerID: String
        var title: String?
        var url: String

        var subjectTokens: Set<String> {
            Set((title ?? "").lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .filter { $0.count > 2 }
                .map(String.init))
        }
    }

    struct Skip: Sendable, Equatable {
        var id: String
        var reason: String
    }

    struct Selection: Sendable, Equatable {
        var picked: [Candidate]
        var skipped: [Skip]

        var receipt: [String: Any] {
            [
                "pickedCount": picked.count,
                "providers": Set(picked.map(\.providerID)).sorted(),
                "skipped": skipped.map { ["id": $0.id, "reason": $0.reason] },
            ]
        }
    }

    static let titleOverlapLimit = 0.6
    static let maximumCandidates = 200

    /// Round-robin over providers so one source cannot fill the limit, then fill by original order.
    static func select(_ candidates: [Candidate], delivered: StockDeliveryHistory = .init(),
                       limit: Int) -> Selection {
        let limit = max(0, limit)
        guard limit > 0 else {
            return Selection(picked: [], skipped: candidates.map { Skip(id: $0.id, reason: "empty_limit") })
        }
        let deliveredTokens = Set(delivered.entries.flatMap { entry in
            entry.outputFilename.lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .filter { $0.count > 2 }
                .map(String.init)
        })

        var seenIds = Set<String>()
        var seenURLs = Set<String>()
        var acceptedTokens: [Set<String>] = []
        var seenTokens: [Set<String>] = []
        var buckets: [String: [Candidate]] = [:]
        var providerOrder: [String] = []
        var skipped: [Skip] = []

        for candidate in candidates.prefix(maximumCandidates) {
            let reason: String?
            if !seenIds.insert(candidate.id).inserted { reason = "duplicate_id" }
            else if !seenURLs.insert(candidate.url).inserted { reason = "duplicate_url" }
            else if delivered.usedSourceIds.contains(candidate.id) { reason = "already_delivered" }
            else if overlapsTooMuch(candidate.subjectTokens, acceptedTokens: seenTokens) { reason = "near_duplicate_subject" }
            else if overlapsTooMuch(candidate.subjectTokens, against: deliveredTokens) { reason = "repeated_delivered_subject" }
            else { reason = nil }

            guard reason == nil else {
                skipped.append(Skip(id: candidate.id, reason: reason!))
                continue
            }
            seenTokens.append(candidate.subjectTokens)
            if buckets[candidate.providerID] == nil {
                providerOrder.append(candidate.providerID)
                buckets[candidate.providerID] = []
            }
            buckets[candidate.providerID]?.append(candidate)
        }

        var picked: [Candidate] = []
        while picked.count < limit {
            var advanced = false
            for provider in providerOrder {
                guard picked.count < limit, var queue = buckets[provider], !queue.isEmpty else { continue }
                let next = queue.removeFirst()
                buckets[provider] = queue
                acceptedTokens.append(next.subjectTokens)
                picked.append(next)
                advanced = true
            }
            if !advanced { break }
        }
        return Selection(picked: picked, skipped: skipped)
    }

    private static func overlapsTooMuch(_ tokens: Set<String>, acceptedTokens: [Set<String>]) -> Bool {
        guard !tokens.isEmpty else { return false }
        return acceptedTokens.contains { overlapsTooMuch(tokens, against: $0) }
    }

    private static func overlapsTooMuch(_ tokens: Set<String>, against other: Set<String>) -> Bool {
        guard !tokens.isEmpty, !other.isEmpty else { return false }
        let union = tokens.union(other).count
        guard union > 0 else { return false }
        return Double(tokens.intersection(other).count) / Double(union) > titleOverlapLimit
    }
}
