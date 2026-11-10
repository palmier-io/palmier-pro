import Foundation
import Testing
@testable import CompositorPro

@Suite("Shot candidate verification")
struct ShotVerificationTests {
    private func requirement(
        subject: String? = "Container harbor",
        action: String? = "Cranes loading",
        location: String? = "Penang",
        sourceTypes: [ShotRequirement.SourceType]? = nil,
        targetDurationSeconds: Double? = nil,
        handleSeconds: Double? = nil
    ) -> ShotRequirement {
        ShotRequirement(
            narrativePurpose: "Establish the location before the claim.",
            subject: subject, action: action, location: location,
            sourceTypes: sourceTypes,
            targetDurationSeconds: targetDurationSeconds, handleSeconds: handleSeconds)
    }

    private func candidate(
        id: String = "library:asset-1:visual:0.0-3.0",
        source: ShotCandidateSource = .library,
        kind: StockMediaKind = .video,
        mediaRef: String? = "asset-1",
        origin: MediaImportOrigin? = nil,
        start: Double? = 0, end: Double? = 3,
        duration: Double? = 8
    ) -> ShotCandidate {
        ShotCandidate(
            id: id, source: source, providerID: source == .stock ? "pexels" : nil,
            mediaRef: mediaRef, url: nil, name: "Harbor.mov", title: nil, kind: kind,
            creator: nil, license: nil, licenseURL: nil, attribution: nil,
            durationSeconds: duration, sourceStartSeconds: start, sourceEndSeconds: end,
            score: nil, evidence: [.visual], rank: 1, usable: true, blockers: [],
            origin: origin)
    }

    private func inspection(
        subject: Double? = nil,
        action: Double? = nil,
        location: Double? = nil,
        usableSpan: Double? = nil
    ) -> ShotInspection {
        var result = ShotInspection()
        result.sampledSourceSeconds = [0.5, 1.5, 2.5]
        result.pixelWidth = 1920
        result.pixelHeight = 1080
        result.refinedStartSeconds = 0
        result.refinedEndSeconds = usableSpan
        result.subjectScore = subject
        result.actionScore = action
        result.locationScore = location
        return result
    }

    @Test func candidateBelowTheSimilarityFloorIsRejected() {
        let acceptance = ShotVerifier.acceptance(
            candidate: candidate(),
            requirement: requirement(),
            inspection: inspection(subject: 0.09, action: 0.30, location: 0.30),
            best: .init(subject: 0.30, action: 0.30, location: 0.30))
        #expect(acceptance.rejectionReason == .wrongSubject)
    }

    @Test func candidateTrailingTheBestByTooMuchIsRejected() {
        let acceptance = ShotVerifier.acceptance(
            candidate: candidate(),
            requirement: requirement(),
            inspection: inspection(subject: 0.20, action: 0.30, location: 0.30),
            best: .init(subject: 0.34, action: 0.30, location: 0.30))
        #expect(acceptance.rejectionReason == .wrongSubject)
    }

    @Test func candidateWithinTheMarginOfTheBestIsAccepted() {
        let acceptance = ShotVerifier.acceptance(
            candidate: candidate(),
            requirement: requirement(),
            inspection: inspection(subject: 0.30, action: 0.28, location: 0.26),
            best: .init(subject: 0.34, action: 0.30, location: 0.30))
        #expect(acceptance == .accepted)
    }

    @Test func unscoredCriterionDoesNotReject() {
        let acceptance = ShotVerifier.acceptance(
            candidate: candidate(),
            requirement: requirement(subject: nil, action: nil, location: nil),
            inspection: inspection(),
            best: .init())
        #expect(acceptance == .accepted)
    }

    @Test func wrongSourceTypeIsRejected() {
        let acceptance = ShotVerifier.acceptance(
            candidate: candidate(source: .stock, kind: .video, mediaRef: nil),
            requirement: requirement(sourceTypes: [.library]),
            inspection: inspection(subject: 0.30, action: 0.30, location: 0.30),
            best: .init(subject: 0.30, action: 0.30, location: 0.30))
        #expect(acceptance.rejectionReason == .notUsable)
    }

    @Test func stockVideoSatisfiesAStockVideoRequirement() {
        let acceptance = ShotVerifier.acceptance(
            candidate: candidate(source: .stock, kind: .video, mediaRef: nil),
            requirement: requirement(sourceTypes: [.stockVideo]),
            inspection: inspection(subject: 0.30, action: 0.30, location: 0.30),
            best: .init(subject: 0.30, action: 0.30, location: 0.30))
        #expect(acceptance == .accepted)
    }

    @Test func unverifiableSourceTypesDoNotRejectEverything() {
        let acceptance = ShotVerifier.acceptance(
            candidate: candidate(),
            requirement: requirement(sourceTypes: [.screenRecording]),
            inspection: inspection(subject: 0.30, action: 0.30, location: 0.30),
            best: .init(subject: 0.30, action: 0.30, location: 0.30))
        #expect(acceptance == .accepted)
    }

    @Test func spanShorterThanTheRequiredDurationIsRejected() {
        let acceptance = ShotVerifier.acceptance(
            candidate: candidate(start: 0, end: 1),
            requirement: requirement(targetDurationSeconds: 3),
            inspection: inspection(subject: 0.30, action: 0.30, location: 0.30, usableSpan: 1),
            best: .init(subject: 0.30, action: 0.30, location: 0.30))
        #expect(acceptance.rejectionReason == .insufficientDuration)
    }

    @Test func handlesAreCountedAgainstTheRequiredDuration() {
        let acceptance = ShotVerifier.acceptance(
            candidate: candidate(start: 0, end: 3),
            requirement: requirement(targetDurationSeconds: 3, handleSeconds: 1),
            inspection: inspection(subject: 0.30, action: 0.30, location: 0.30, usableSpan: 3),
            best: .init(subject: 0.30, action: 0.30, location: 0.30))
        #expect(acceptance.rejectionReason == .insufficientDuration)
    }

    @Test func missingInspectionLeavesTheCandidateUnverified() {
        let acceptance = ShotVerifier.acceptance(
            candidate: candidate(),
            requirement: requirement(),
            inspection: nil,
            best: .init())
        if case .unverified = acceptance {
            #expect(Bool(true))
        } else {
            #expect(Bool(false))
        }
    }

    @Test func bestScoresKeepTheStrongestCandidatePerCriterion() {
        var best = ShotVerifier.BestScores()
        best.record(0.21, for: .subject)
        best.record(0.33, for: .subject)
        best.record(nil, for: .action)
        #expect(best.score(for: .subject) == 0.33)
        #expect(best.score(for: .action) == nil)
    }

    @Test func providersContributeOneRowBeforeAnyProviderContributesTwo() {
        var first = candidate(id: "stock:pexels:1", source: .stock, mediaRef: nil)
        first.providerID = "pexels"
        var second = candidate(id: "stock:pexels:2", source: .stock, mediaRef: nil)
        second.providerID = "pexels"
        var third = candidate(id: "stock:pixabay:1", source: .stock, mediaRef: nil)
        third.providerID = "pixabay"
        let ordered = ShotCandidateBuilder.interleaveByProvider([first, second, third])
        #expect(ordered.map(\.id) == ["stock:pexels:1", "stock:pixabay:1", "stock:pexels:2"])
    }

    @Test func providerRankIsRetainedPerProvider() {
        let bundle = ShotCandidateBuilder.build(
            kind: .video,
            visual: [],
            spoken: [],
            remote: [
                StockMediaHit(id: "1", kind: .video, title: "A", url: "https://example.com/a.mp4", thumbnailURL: nil,
                              creator: "C", creatorURL: nil, license: "CC0", licenseURL: nil, providerID: "pexels",
                              landingPageURL: nil, width: 1920, height: 1080, durationSeconds: 5, fileSizeBytes: nil,
                              attributionText: nil),
                StockMediaHit(id: "2", kind: .video, title: "B", url: "https://example.com/b.mp4", thumbnailURL: nil,
                              creator: "C", creatorURL: nil, license: "CC0", licenseURL: nil, providerID: "pexels",
                              landingPageURL: nil, width: 1920, height: 1080, durationSeconds: 5, fileSizeBytes: nil,
                              attributionText: nil),
                StockMediaHit(id: "3", kind: .video, title: "D", url: "https://example.com/d.mp4", thumbnailURL: nil,
                              creator: "C", creatorURL: nil, license: "CC0", licenseURL: nil, providerID: "pixabay",
                              landingPageURL: nil, width: 1920, height: 1080, durationSeconds: 5, fileSizeBytes: nil,
                              attributionText: nil),
            ],
            assets: [:],
            limit: 10)
        let ranks = Dictionary(uniqueKeysWithValues: bundle.candidates.map { ($0.id, $0.providerRank) })
        #expect(ranks["stock:pexels:1"] == 1)
        #expect(ranks["stock:pexels:2"] == 2)
        #expect(ranks["stock:pixabay:3"] == 1)
    }

    @Test func storedRejectionMatchesByMediaRefAndStockOrigin() {
        let rejection = ShotRejection(candidateRef: "asset-1", reason: .wrongSubject, evidence: "A dog.")
        #expect(ShotVerifier.priorRejection(matching: candidate(), in: [rejection]) != nil)
        #expect(ShotVerifier.priorRejection(matching: candidate(mediaRef: "asset-2"), in: [rejection]) == nil)

        let stock = candidate(id: "stock:pexels:9", source: .stock, mediaRef: nil,
                              origin: MediaImportOrigin(provider: "pexels", assetId: "9"))
        let stockRejection = ShotRejection(candidateRef: "stock:pexels:9", reason: .wrongAction, evidence: "A dog.")
        #expect(ShotVerifier.priorRejection(matching: stock, in: [stockRejection]) != nil)
    }
}
