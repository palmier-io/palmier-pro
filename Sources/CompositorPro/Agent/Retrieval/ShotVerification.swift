import CoreGraphics
import Foundation

/// Editorial decision about a retrieved candidate for one shot requirement.
/// Availability, retrieval rank, inspection evidence, and this decision stay separate:
/// a candidate can be available and well ranked and still fail the requirement.
enum ShotAcceptance: Sendable, Equatable {
    case accepted
    case rejected(reason: ShotRejection.Reason, evidence: String)
    case unverified(String)

    var isAccepted: Bool {
        if case .accepted = self { return true }
        return false
    }

    var rejectionReason: ShotRejection.Reason? {
        if case .rejected(let reason, _) = self { return reason }
        return nil
    }

    var receipt: [String: Any] {
        switch self {
        case .accepted:
            return ["state": "accepted"]
        case .rejected(let reason, let evidence):
            return ["state": "rejected", "reason": reason.rawValue, "evidence": evidence]
        case .unverified(let reason):
            return ["state": "unverified", "reason": reason]
        }
    }
}

/// Evidence gathered by decoding frames from the candidate's own source.
/// Every value here was measured from the media, never inferred from its title.
struct ShotInspection: Sendable, Equatable {
    enum Motion: String, Sendable, Equatable {
        case still
        case moving
        case unknown
    }

    var sampledSourceSeconds: [Double] = []
    var pixelWidth: Int? = nil
    var pixelHeight: Int? = nil
    /// Span that survived cut detection. Index hits are coarse samples, not edit boundaries.
    var refinedStartSeconds: Double? = nil
    var refinedEndSeconds: Double? = nil
    var subjectScore: Double? = nil
    var actionScore: Double? = nil
    var locationScore: Double? = nil
    /// Concept similarity per excluded phrase. High means the excluded concept is present.
    var exclusionScores: [String: Double] = [:]
    var motion: Motion = .unknown
    var notes: [String] = []

    var usableSpanSeconds: Double? {
        guard let start = refinedStartSeconds, let end = refinedEndSeconds else { return nil }
        return max(0, end - start)
    }

    var receipt: [String: Any] {
        var out: [String: Any] = ["sampledSourceSeconds": sampledSourceSeconds]
        if let pixelWidth { out["pixelWidth"] = pixelWidth }
        if let pixelHeight { out["pixelHeight"] = pixelHeight }
        if let refinedStartSeconds { out["refinedStartSeconds"] = refinedStartSeconds }
        if let refinedEndSeconds { out["refinedEndSeconds"] = refinedEndSeconds }
        if let usableSpanSeconds { out["usableSpanSeconds"] = usableSpanSeconds }
        if let subjectScore { out["subjectScore"] = subjectScore }
        if let actionScore { out["actionScore"] = actionScore }
        if let locationScore { out["locationScore"] = locationScore }
        if !exclusionScores.isEmpty { out["exclusionScores"] = exclusionScores }
        out["motion"] = motion.rawValue
        if !notes.isEmpty { out["notes"] = notes }
        return out
    }
}

/// Verifies retrieved candidates against the shot requirement they were retrieved for.
enum ShotVerifier {
    /// Similarity below this does not depict the named criterion at all.
    static let similarityFloor = 0.15
    /// How far below the best verified candidate a candidate may sit and still be accepted.
    static let similarityMargin = 0.06
    /// Mean luminance change between adjacent samples that reads as a scene cut.
    static let cutThreshold = 0.22
    /// Mean luminance change between adjacent samples that reads as motion.
    static let motionThreshold = 0.04
    /// Candidates inspected per retrieval call. Verification cost is bounded, not per asset.
    static let maximumInspections = 6
    static let maximumFrameSamples = 5

    enum Criterion: String, Sendable, CaseIterable {
        case subject
        case action
        case location

        var rejectionReason: ShotRejection.Reason {
            switch self {
            case .subject: .wrongSubject
            case .action: .wrongAction
            case .location: .wrongLocation
            }
        }
    }

    /// Best verified score per criterion, used to reject clear losers without inventing a winner.
    struct BestScores: Sendable, Equatable {
        var subject: Double? = nil
        var action: Double? = nil
        var location: Double? = nil

        func score(for criterion: Criterion) -> Double? {
            switch criterion {
            case .subject: subject
            case .action: action
            case .location: location
            }
        }

        mutating func record(_ score: Double?, for criterion: Criterion) {
            guard let score else { return }
            switch criterion {
            case .subject: subject = max(subject ?? score, score)
            case .action: action = max(action ?? score, score)
            case .location: location = max(location ?? score, score)
            }
        }
    }

    // MARK: - Inspection

    /// Decodes frames from the candidate's own source and measures what the requirement names.
    /// Returns nil when the source cannot be decoded on this machine.
    @concurrent
    static func inspect(
        candidate: ShotCandidate,
        requirement: ShotRequirement,
        mediaURL: URL,
        mediaType: ClipType,
        embedder: VisualEmbedder?
    ) async -> ShotInspection? {
        try? await Task.checkCancellation()
        let samples = sampleTimes(candidate: candidate, mediaType: mediaType)
        guard !samples.isEmpty else { return nil }

        var inspection = ShotInspection()
        var grids: [[Double]] = []
        var frameVectors: [[Float]] = []
        for seconds in samples {
            do {
                try await Task.checkCancellation()
                let image = try await StoryboardThumbnailService.load(url: mediaURL, type: mediaType, sourceSeconds: seconds)
                inspection.sampledSourceSeconds.append(seconds)
                if inspection.pixelWidth == nil {
                    inspection.pixelWidth = image.width
                    inspection.pixelHeight = image.height
                }
                if let grid = luminanceGrid(image) { grids.append(grid) }
                if let embedder, let vector = try? embedder.encode(image: image) { frameVectors.append(vector) }
            } catch is CancellationError {
                return nil
            } catch {
                continue
            }
        }
        guard !inspection.sampledSourceSeconds.isEmpty else { return nil }

        refineSpan(&inspection, grids: grids)
        inspection.motion = motionObservation(grids: grids)

        if let embedder, !frameVectors.isEmpty {
            let mean = meanVector(frameVectors)
            if let subject = requirement.subject, let vector = try? embedder.encode(text: subject) {
                inspection.subjectScore = cosine(mean, vector)
            }
            if let action = requirement.action, let vector = try? embedder.encode(text: action) {
                inspection.actionScore = cosine(mean, vector)
            }
            if let location = requirement.location, let vector = try? embedder.encode(text: location) {
                inspection.locationScore = cosine(mean, vector)
            }
            for exclusion in requirement.exclusions ?? [] {
                guard let vector = try? embedder.encode(text: exclusion) else { continue }
                inspection.exclusionScores[exclusion] = cosine(mean, vector)
            }
        } else {
            inspection.notes.append("Visual model unavailable; content was decoded but not compared to the requirement.")
        }
        return inspection
    }

    static func sampleTimes(candidate: ShotCandidate, mediaType: ClipType) -> [Double] {
        if mediaType == .image { return [0] }
        guard mediaType == .video else { return [] }
        let start = candidate.sourceStartSeconds ?? 0
        let end = candidate.sourceEndSeconds ?? start
        guard end > start else { return [start] }
        let span = end - start
        let count = max(2, min(maximumFrameSamples, Int(span / 1.5) + 2))
        return (0..<count).map { index in
            start + span * (Double(index) + 0.5) / Double(count)
        }
    }

    /// Trims the coarse index span to the first stable region by looking for scene cuts.
    static func refineSpan(_ inspection: inout ShotInspection, grids: [[Double]]) {
        let times = inspection.sampledSourceSeconds
        guard let first = times.first else { return }
        var start = first
        var end = times.last ?? first
        for index in 1..<min(times.count, grids.count) {
            let difference = meanAbsoluteDifference(grids[index - 1], grids[index])
            if difference >= cutThreshold {
                end = times[index]
                break
            }
        }
        inspection.refinedStartSeconds = start
        inspection.refinedEndSeconds = end
        if let span = candidateSpanSeconds(inspection.sampledSourceSeconds), end - start < span {
            inspection.notes.append("Refined the indexed span to \(Int((end - start) * 1000))ms after detecting a cut.")
        }
    }

    static func motionObservation(grids: [[Double]]) -> ShotInspection.Motion {
        guard grids.count >= 2 else { return .unknown }
        var maximum = 0.0
        for index in 1..<grids.count {
            maximum = max(maximum, meanAbsoluteDifference(grids[index - 1], grids[index]))
        }
        return maximum >= motionThreshold ? .moving : .still
    }

    static func candidateSpanSeconds(_ times: [Double]) -> Double? {
        guard let first = times.first, let last = times.last, last > first else { return nil }
        return last - first
    }

    // MARK: - Acceptance

    /// Decides whether an inspected candidate satisfies the requirement.
    /// Pure: the same inspection and best scores always produce the same decision.
    static func acceptance(
        candidate: ShotCandidate,
        requirement: ShotRequirement,
        inspection: ShotInspection?,
        best: BestScores
    ) -> ShotAcceptance {
        if let reason = sourceTypeMismatch(candidate: candidate, requirement: requirement) {
            return .rejected(reason: reason, evidence: "Source type does not match the shot requirement.")
        }
        if let rejection = durationRejection(candidate: candidate, requirement: requirement, inspection: inspection) {
            return rejection
        }
        guard let inspection else {
            return .unverified("The source was not inspected; content cannot be certified.")
        }
        for criterion in Criterion.allCases {
            guard let score = score(for: criterion, in: inspection), requirementText(criterion, in: requirement) != nil else {
                continue
            }
            let bestScore = best.score(for: criterion)
            if score < similarityFloor {
                return .rejected(
                    reason: criterion.rejectionReason,
                    evidence: "\(criterion.rawValue) similarity \(format(score)) is below the \(format(similarityFloor)) floor."
                )
            }
            if let bestScore, bestScore - score > similarityMargin {
                return .rejected(
                    reason: criterion.rejectionReason,
                    evidence: "\(criterion.rawValue) similarity \(format(score)) trails the best candidate \(format(bestScore)) by more than \(format(similarityMargin))."
                )
            }
        }
        return .accepted
    }

    static func score(for criterion: Criterion, in inspection: ShotInspection) -> Double? {
        switch criterion {
        case .subject: inspection.subjectScore
        case .action: inspection.actionScore
        case .location: inspection.locationScore
        }
    }

    static func requirementText(_ criterion: Criterion, in requirement: ShotRequirement) -> String? {
        switch criterion {
        case .subject: requirement.subject
        case .action: requirement.action
        case .location: requirement.location
        }
    }

    /// A candidate of the wrong source kind cannot serve the shot, whatever it depicts.
    /// Kinds this project cannot prove from a candidate stay unjudged instead of rejected.
    static func sourceTypeMismatch(candidate: ShotCandidate, requirement: ShotRequirement) -> ShotRejection.Reason? {
        guard let types = requirement.sourceTypes, !types.isEmpty else { return nil }
        var verifiable = false
        for type in types {
            switch type {
            case .library:
                verifiable = true
                if candidate.source == .library { return nil }
            case .stockVideo:
                verifiable = true
                if candidate.source == .stock, candidate.kind == .video { return nil }
            case .stockImage:
                verifiable = true
                if candidate.source == .stock, candidate.kind == .image { return nil }
            case .generated, .screenRecording, .archival:
                continue
            }
        }
        return verifiable ? .notUsable : nil
    }

    /// The candidate must hold the required span plus the handles the shot asks for.
    static func durationRejection(
        candidate: ShotCandidate,
        requirement: ShotRequirement,
        inspection: ShotInspection?
    ) -> ShotAcceptance? {
        guard let target = requirement.targetDurationSeconds else { return nil }
        let handles = max(0, requirement.handleSeconds ?? 0)
        let required = target + handles * 2
        let available = inspection?.usableSpanSeconds
            ?? candidate.sourceEndSeconds.flatMap { end in candidate.sourceStartSeconds.map { start in end - start } }
            ?? candidate.durationSeconds
        guard let available else { return nil }
        guard available + 0.001 < required else { return nil }
        return .rejected(
            reason: .insufficientDuration,
            evidence: "Usable span \(format(available))s is shorter than the required \(format(required))s."
        )
    }

    /// Matches a stored rejection to a candidate by candidate id, media ref, or retained stock origin.
    /// A repair must not be offered the same rejected source again.
    static func priorRejection(matching candidate: ShotCandidate, in rejections: [ShotRejection]) -> ShotRejection? {
        let stockSourceId = candidate.origin?.sourceId
        for rejection in rejections {
            if rejection.candidateRef == candidate.id { return rejection }
            if let mediaRef = candidate.mediaRef, rejection.candidateRef == mediaRef { return rejection }
            if let stockSourceId, rejection.candidateRef == stockSourceId { return rejection }
        }
        return nil
    }

    // MARK: - Numeric helpers

    static func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Double? {
        guard a.count == b.count, !a.isEmpty else { return nil }
        var dot = 0.0
        var normA = 0.0
        var normB = 0.0
        for index in a.indices {
            let left = Double(a[index])
            let right = Double(b[index])
            dot += left * right
            normA += left * left
            normB += right * right
        }
        guard normA > 0, normB > 0 else { return nil }
        return dot / (normA.squareRoot() * normB.squareRoot())
    }

    static func meanVector(_ vectors: [[Float]]) -> [Float] {
        guard let first = vectors.first else { return [] }
        var sum = first
        for vector in vectors.dropFirst() {
            guard vector.count == sum.count else { continue }
            for index in sum.indices { sum[index] += vector[index] }
        }
        let count = Float(vectors.count)
        return sum.map { $0 / count }
    }

    static func luminanceGrid(_ image: CGImage) -> [Double]? {
        let side = 8
        var pixels = [UInt8](repeating: 0, count: side * side)
        return pixels.withUnsafeMutableBytes { buffer -> [Double]? in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return nil }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            let bytes = buffer.bindMemory(to: UInt8.self)
            return (0..<(side * side)).map { Double(bytes[$0]) / 255.0 }
        }
    }

    static func meanAbsoluteDifference(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var total = 0.0
        for index in a.indices { total += abs(a[index] - b[index]) }
        return total / Double(a.count)
    }
}
