import Foundation

/// Structural claim-vs-display agreement for a reviewed timeline range.
///
/// A plan element that cites claims must be displayed by a graphic scene built for those same
/// claims inside its planned interval. This compares authored structure (plan element → retained
/// scene spec → placed clip) and never interprets rendered pixels.
struct ClaimDisplayAudit: Sendable, Equatable {
    struct Interval: Sendable, Equatable {
        let elementId: String
        let startFrame: Int
        let endFrame: Int
        let plannedClaimIds: [String]
        let displayedClaimIds: [String]
        let clipIds: [String]

        var isAgreement: Bool {
            !plannedClaimIds.isEmpty && Set(plannedClaimIds).isSubset(of: Set(displayedClaimIds))
        }
    }

    enum Status: String, Sendable {
        /// No plan element in the reviewed range cites a claim.
        case noClaimsPlanned = "no_claims_planned"
        case agreement
        case disagreement
    }

    static let maximumReportedIntervals = 32

    let intervals: [Interval]
    /// Planned claims that the source ledger has not marked reviewed.
    let unreviewedClaimIds: [String]

    var disagreed: [Interval] { intervals.filter { !$0.isAgreement } }

    var status: Status {
        guard !intervals.isEmpty else { return .noClaimsPlanned }
        return disagreed.isEmpty ? .agreement : .disagreement
    }

    var receipt: [String: Any] {
        let reported = Array((disagreed + intervals.filter(\.isAgreement)).prefix(Self.maximumReportedIntervals))
        return [
            "status": status.rawValue,
            "checkedIntervals": intervals.count,
            "disagreedIntervals": disagreed.count,
            "checkedClaimIds": Set(intervals.flatMap(\.plannedClaimIds)).sorted(),
            "unreviewedClaimIds": unreviewedClaimIds,
            "intervals": reported.map { interval in
                [
                    "elementId": interval.elementId,
                    "startFrame": interval.startFrame,
                    "endFrame": interval.endFrame,
                    "plannedClaimIds": interval.plannedClaimIds,
                    "displayedClaimIds": interval.displayedClaimIds,
                    "clipIds": interval.clipIds,
                    "agreement": interval.isAgreement,
                ] as [String: Any]
            },
        ]
    }

    /// Audits the plan for `timeline` against the range `[startFrame, endFrame)`.
    static func make(plan: EditPlan?, timeline: Timeline, startFrame: Int, endFrame: Int) -> ClaimDisplayAudit {
        guard let plan else { return ClaimDisplayAudit(intervals: [], unreviewedClaimIds: []) }
        let elements: [(id: String, start: Int, end: Int, claimIds: [String])] = plan.shots.isEmpty
            ? plan.sections.compactMap { section in
                guard let ids = section.claimIds, !ids.isEmpty else { return nil }
                return (section.id, section.startFrame, section.endFrame, ids)
            }
            : plan.shots.compactMap { shot in
                guard let ids = shot.claimIds, !ids.isEmpty else { return nil }
                return (shot.id, shot.startFrame, shot.endFrame, ids)
            }
        let inRange = elements.filter { $0.start < endFrame && $0.end > startFrame }
        guard !inRange.isEmpty else { return ClaimDisplayAudit(intervals: [], unreviewedClaimIds: []) }

        let scenesById = Dictionary(uniqueKeysWithValues: plan.graphicScenes.map { ($0.id, $0) })
        let scenesByClip = Dictionary(
            plan.graphicScenes.compactMap { scene in scene.clipId.map { ($0, scene) } },
            uniquingKeysWith: { first, _ in first }
        )
        let scenesByMedia = Dictionary(
            plan.graphicScenes.compactMap { scene in scene.mediaRef.map { ($0, scene) } },
            uniquingKeysWith: { first, _ in first }
        )
        let clips = timeline.tracks.flatMap(\.clips)

        let intervals = inRange.map { element -> Interval in
            let placed = clips.filter { clip in
                clip.startFrame < element.end && clip.endFrame > element.start
                    && (scenesByClip[clip.id] != nil || scenesByMedia[clip.mediaRef] != nil)
            }
            var displayed: [String] = []
            var clipIds: [String] = []
            for clip in placed {
                guard let scene = scenesByClip[clip.id] ?? scenesByMedia[clip.mediaRef],
                      scenesById[scene.id] != nil else { continue }
                clipIds.append(clip.id)
                displayed.append(contentsOf: claimIDs(in: scene.specObject))
            }
            return Interval(
                elementId: element.id,
                startFrame: element.start,
                endFrame: element.end,
                plannedClaimIds: element.claimIds,
                displayedClaimIds: orderedUnique(displayed),
                clipIds: clipIds
            )
        }

        let reviewed = Set((plan.sourceLedger?.claims ?? []).filter { $0.status == .reviewed }.map(\.claimId))
        let planned = Set(intervals.flatMap(\.plannedClaimIds))
        return ClaimDisplayAudit(
            intervals: intervals,
            unreviewedClaimIds: planned.subtracting(reviewed).sorted()
        )
    }

    /// Collects every `claimIds` array anywhere inside a retained scene spec.
    private static func claimIDs(in value: Any) -> [String] {
        switch value {
        case let dictionary as [String: Any]:
            return dictionary
                .sorted { $0.key < $1.key }
                .flatMap { key, child in
                    key == "claimIds" ? stringIDs(child) : claimIDs(in: child)
                }
        case let array as [Any]:
            return array.flatMap(claimIDs(in:))
        default:
            return []
        }
    }

    private static func stringIDs(_ value: Any) -> [String] {
        (value as? [Any])?.compactMap { $0 as? String } ?? (value as? String).map { [$0] } ?? []
    }

    private static func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
