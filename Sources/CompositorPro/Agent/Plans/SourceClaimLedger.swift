import Foundation

struct SourceClaimLedger: Codable, Sendable, Equatable {
    struct Source: Codable, Sendable, Equatable {
        var sourceId: String
        var title: String
        var url: String?
        var documentReference: String?
        var author: String
        var publicationDate: String?
        var accessedDate: String
    }

    struct Evidence: Codable, Sendable, Equatable {
        var sourceId: String
        var passage: String
    }

    struct Claim: Codable, Sendable, Equatable {
        enum Kind: String, Codable, Sendable, CaseIterable {
            case statement, quantity, location
        }

        enum Status: String, Codable, Sendable, CaseIterable {
            case unresolved, reviewed
        }

        var claimId: String
        var kind: Kind
        var statement: String
        var value: Double?
        var unit: String?
        var evidence: [Evidence]
        var status: Status
    }

    static let maximumSources = 128
    static let maximumClaims = 256
    var sources: [Source]
    var claims: [Claim]

    func validated(previous: Self? = nil, reviewingClaimIds: Set<String> = []) throws -> Self {
        let previous = try previous?.validated()
        guard sources.count <= Self.maximumSources, claims.count <= Self.maximumClaims else {
            throw EditPlanValidationError.invalidReference("A ledger stores at most \(Self.maximumSources) sources and \(Self.maximumClaims) claims.")
        }
        var ledger = self
        var ids = Set<String>()
        ledger.sources = try sources.map { original in
            var source = original
            source.sourceId = try EditPlan.validatedID(source.sourceId, field: "sourceId")
            guard ids.insert(source.sourceId).inserted else { throw EditPlanValidationError.duplicateId(source.sourceId) }
            source.title = try EditPlan.validatedName(source.title)
            source.author = try requiredText(source.author, field: "source author")
            guard (source.url != nil) != (source.documentReference != nil) else {
                throw EditPlanValidationError.invalidReference("Sources require exactly one url or documentReference.")
            }
            if let url = source.url { source.url = try EditPlan.validatedURL(url) }
            if let reference = source.documentReference {
                source.documentReference = try requiredText(reference, field: "documentReference")
            }
            try validateDate(source.accessedDate)
            if let date = source.publicationDate { try validateDate(date) }
            return source
        }
        let known = Set(ledger.sources.map(\.sourceId))
        let currentSources = Dictionary(uniqueKeysWithValues: ledger.sources.map { ($0.sourceId, $0) })
        let previousSources = Dictionary(uniqueKeysWithValues: (previous?.sources ?? []).map { ($0.sourceId, $0) })
        let previousClaims = Dictionary(uniqueKeysWithValues: (previous?.claims ?? []).map { ($0.claimId, $0) })
        ids = []
        ledger.claims = try claims.map { original in
            var claim = original
            claim.claimId = try EditPlan.validatedID(claim.claimId, field: "claimId")
            guard ids.insert(claim.claimId).inserted else { throw EditPlanValidationError.duplicateId(claim.claimId) }
            claim.statement = try requiredText(claim.statement, field: "claim statement")
            guard claim.evidence.count <= 16, claim.status == .unresolved || !claim.evidence.isEmpty else {
                throw EditPlanValidationError.invalidReference("Reviewed claims require 1–16 exact supporting passages; unresolved claims may record missing evidence.")
            }
            var cited = Set<String>()
            claim.evidence = try claim.evidence.map { original in
                var evidence = original
                evidence.sourceId = try EditPlan.validatedID(evidence.sourceId, field: "evidence.sourceId")
                guard known.contains(evidence.sourceId), cited.insert(evidence.sourceId).inserted else {
                    throw EditPlanValidationError.invalidReference("Claim '\(claim.claimId)' cites duplicate or unknown sources.")
                }
                evidence.passage = try requiredText(evidence.passage, field: "supporting passage")
                return evidence
            }
            if claim.kind == .quantity {
                guard let value = claim.value, value.isFinite, let unit = claim.unit else {
                    throw EditPlanValidationError.invalidReference("Quantitative claims require a finite value and explicit unit.")
                }
                claim.unit = try EditPlan.validatedName(unit)
            } else if claim.value != nil || claim.unit != nil {
                throw EditPlanValidationError.invalidReference("Only quantity claims may have a value or unit.")
            }
            if var old = previousClaims[claim.claimId], old.status == .reviewed {
                old.status = claim.status
                let changedSource = claim.evidence.contains { currentSources[$0.sourceId] != previousSources[$0.sourceId] }
                if old != claim || changedSource { claim.status = .unresolved }
            } else if previousClaims[claim.claimId]?.status == .unresolved,
                      claim.status == .reviewed, !reviewingClaimIds.contains(claim.claimId) {
                claim.status = .unresolved
            }
            return claim
        }
        return ledger
    }

    func hasSameEvidence(as other: Self) -> Bool {
        guard sources == other.sources, claims.count == other.claims.count else { return false }
        return zip(claims, other.claims).allSatisfy { left, right in
            var left = left
            left.status = right.status
            return left == right
        }
    }

    func validatedClaimIDs(_ references: [String]?) throws -> [String]? {
        guard let references, !references.isEmpty else { return nil }
        guard references.count <= Self.maximumClaims else {
            throw EditPlanValidationError.invalidReference("Too many claimIds in one plan element.")
        }
        let normalized = try references.map { try EditPlan.validatedID($0, field: "claimIds") }
        let known = Set(claims.map(\.claimId))
        guard Set(normalized).count == normalized.count, normalized.allSatisfy(known.contains) else {
            throw EditPlanValidationError.invalidReference("Plan elements must cite unique claimIds from their sourceLedger.")
        }
        return normalized
    }

    func receipt() -> [String: Any] {
        [
            "sources": sources.map { source in
                var row: [String: Any] = ["sourceId": source.sourceId, "title": source.title, "author": source.author, "accessedDate": source.accessedDate]
                if let url = source.url { row["url"] = url }
                if let reference = source.documentReference { row["documentReference"] = reference }
                if let date = source.publicationDate { row["publicationDate"] = date }
                return row
            },
            "claims": claims.map { claim in
                var row: [String: Any] = [
                    "claimId": claim.claimId, "kind": claim.kind.rawValue, "statement": claim.statement,
                    "status": claim.status.rawValue,
                    "evidence": claim.evidence.map { ["sourceId": $0.sourceId, "passage": $0.passage] },
                ]
                if let value = claim.value { row["value"] = value }
                if let unit = claim.unit { row["unit"] = unit }
                return row
            },
        ]
    }

    private func requiredText(_ value: String, field: String) throws -> String {
        let value = try EditPlan.validatedText(value, field: field)
        guard !value.isEmpty else { throw EditPlanValidationError.invalidReference("\(field) must be non-empty.") }
        return value
    }

    private func validateDate(_ value: String) throws {
        let pieces = value.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 3, pieces[0].count == 4, pieces[1].count == 2, pieces[2].count == 2,
              pieces.allSatisfy({ $0.utf8.allSatisfy { (48...57).contains($0) } }),
              let year = Int(pieces[0]), (1...9999).contains(year), let month = Int(pieces[1]), let day = Int(pieces[2]) else {
            throw EditPlanValidationError.invalidReference("Source dates must use valid YYYY-MM-DD dates.")
        }
        let calendar = Calendar(identifier: .gregorian)
        let components = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: components) else {
            throw EditPlanValidationError.invalidReference("Source dates must use valid YYYY-MM-DD dates.")
        }
        let resolved = calendar.dateComponents([.year, .month, .day], from: date)
        guard resolved.year == year, resolved.month == month, resolved.day == day else {
            throw EditPlanValidationError.invalidReference("Source dates must use valid YYYY-MM-DD dates.")
        }
    }
}
