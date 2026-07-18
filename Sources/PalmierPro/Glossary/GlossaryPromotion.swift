// GlossaryPromotion — pure planner for glossary_promote: selects terms from the source scope, applies
// the higher-scope-wins collision rule, and returns the rewritten source/destination documents so the
// tool only reads/writes files around it. refs feature/glossary

import Foundation

enum GlossaryPromotion {
    struct Row: Equatable {
        let canonical: String
        let collision: Collision?
    }

    enum Collision: String, Equatable {
        case overwrote  // promoted term won and replaced the destination entry
        case kept       // destination entry won and was kept; the source copy is still removed
    }

    struct Plan {
        var from: GlossaryDocument   // source with promoted terms removed
        var to: GlossaryDocument     // destination with promoted terms merged in
        var rows: [Row]
    }

    /// Move terms matching `canonical` (nil/"all" = every term) and `confidence` from `from` into `to`.
    /// On collision the promoted term wins when `fromWinsCollision` (source is the higher-precedence
    /// scope); otherwise the destination entry is kept. The source copy is always removed.
    static func plan(
        from: GlossaryDocument,
        to: GlossaryDocument,
        fromWinsCollision: Bool,
        canonical: String?,
        confidence: GlossaryConfidence?
    ) -> Plan {
        let promoteAll = canonical == nil || canonical?.lowercased() == "all"
        var newFrom = from
        var newTo = to
        var rows: [Row] = []
        let selected = from.terms.filter {
            (promoteAll || $0.canonical == canonical) && (confidence == nil || $0.confidence == confidence)
        }
        for term in selected {
            let collided = newTo.terms.contains { $0.canonical == term.canonical }
            newFrom.terms.removeAll { $0.canonical == term.canonical }
            if collided && !fromWinsCollision {
                rows.append(Row(canonical: term.canonical, collision: .kept))
                continue
            }
            newTo.terms.removeAll { $0.canonical == term.canonical }
            newTo.terms.append(term)
            rows.append(Row(canonical: term.canonical, collision: collided ? .overwrote : nil))
        }
        return Plan(from: newFrom, to: newTo, rows: rows)
    }
}
