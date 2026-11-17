import Foundation
import Testing
@testable import CompositorPro

@Suite("Claim display audit")
struct ClaimDisplayAuditTests {
    private func makePlan(
        claimIds: [String],
        sceneClaimIds: [String],
        status: SourceClaimLedger.Claim.Status = .reviewed
    ) -> EditPlan {
        var plan = EditPlan(name: "Evidence plan", timelineId: "timeline-1", fps: 30, width: 1920, height: 1080)
        plan.shots = [
            EditPlanShot(title: "Evidence beat", startFrame: 0, endFrame: 90, claimIds: claimIds),
        ]
        plan.sourceLedger = SourceClaimLedger(
            sources: [
                SourceClaimLedger.Source(
                    sourceId: "source-1", title: "Report", url: "https://example.com/report",
                    author: "Desk", accessedDate: "2026-01-01"
                ),
            ],
            claims: claimIds.map {
                SourceClaimLedger.Claim(
                    claimId: $0, kind: .statement, statement: "Statement \($0)",
                    evidence: [.init(sourceId: "source-1", passage: "Passage \($0)")], status: status
                )
            }
        )
        plan.graphicScenes = [
            PlanGraphicScene(
                id: "scene-1", kind: "chart", title: "Revenue", digest: "digest-1",
                rendererVersion: "1", mediaRef: "media-graphic", clipId: "clip-graphic",
                spec: ["title": "Revenue", "items": [["label": "Q1", "claimIds": sceneClaimIds]]]
            ),
        ]
        return plan
    }

    private func makeTimeline(clipStart: Int = 0) -> Timeline {
        Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [
                Fixtures.clip(id: "clip-graphic", mediaRef: "media-graphic", start: clipStart, duration: 90),
            ]),
        ])
    }

    @Test func citedClaimShownByItsSceneIsAgreement() {
        let audit = ClaimDisplayAudit.make(
            plan: makePlan(claimIds: ["claim-1"], sceneClaimIds: ["claim-1"]),
            timeline: makeTimeline(), startFrame: 0, endFrame: 90
        )

        #expect(audit.status == .agreement)
        #expect(audit.disagreed.isEmpty)
        #expect(audit.intervals.first?.displayedClaimIds == ["claim-1"])
        #expect(audit.intervals.first?.clipIds == ["clip-graphic"])
        #expect(audit.unreviewedClaimIds.isEmpty)
    }

    @Test func sceneShowingDifferentClaimIsDisagreement() {
        let audit = ClaimDisplayAudit.make(
            plan: makePlan(claimIds: ["claim-1"], sceneClaimIds: ["claim-2"]),
            timeline: makeTimeline(), startFrame: 0, endFrame: 90
        )

        #expect(audit.status == .disagreement)
        let mismatch = try? #require(audit.disagreed.first)
        #expect(mismatch?.plannedClaimIds == ["claim-1"])
        #expect(mismatch?.displayedClaimIds == ["claim-2"])
        #expect(mismatch?.clipIds == ["clip-graphic"])
        #expect(audit.receipt["disagreedIntervals"] as? Int == 1)
    }

    @Test func citedClaimWithNoPlacedSceneIsDisagreement() {
        let audit = ClaimDisplayAudit.make(
            plan: makePlan(claimIds: ["claim-1"], sceneClaimIds: ["claim-1"]),
            timeline: makeTimeline(clipStart: 600), startFrame: 0, endFrame: 90
        )

        #expect(audit.status == .disagreement)
        #expect(audit.disagreed.first?.clipIds == [])
    }

    @Test func unresolvedClaimIsReportedSeparately() {
        let audit = ClaimDisplayAudit.make(
            plan: makePlan(claimIds: ["claim-1"], sceneClaimIds: ["claim-1"], status: .unresolved),
            timeline: makeTimeline(), startFrame: 0, endFrame: 90
        )

        #expect(audit.status == .agreement)
        #expect(audit.unreviewedClaimIds == ["claim-1"])
    }

    @Test func claimsOutsideTheReviewedRangeAreIgnored() {
        let plan = makePlan(claimIds: ["claim-1"], sceneClaimIds: ["claim-1"])
        var shifted = plan
        shifted.shots = [EditPlanShot(title: "Later", startFrame: 300, endFrame: 360, claimIds: ["claim-1"])]

        let audit = ClaimDisplayAudit.make(plan: shifted, timeline: makeTimeline(), startFrame: 0, endFrame: 90)

        #expect(audit.status == .noClaimsPlanned)
        #expect(audit.intervals.isEmpty)
        #expect(audit.receipt["checkedIntervals"] as? Int == 0)
    }

    @Test func missingPlanHasNothingToAudit() {
        let audit = ClaimDisplayAudit.make(plan: nil, timeline: makeTimeline(), startFrame: 0, endFrame: 90)
        #expect(audit.status == .noClaimsPlanned)
        #expect(audit.receipt["status"] as? String == "no_claims_planned")
    }
}
