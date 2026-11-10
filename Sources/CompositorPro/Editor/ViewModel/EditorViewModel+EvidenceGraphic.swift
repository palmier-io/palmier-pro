import Foundation

extension EditorViewModel {
    struct GraphicSceneReceipt {
        var asset: MediaAsset
        var clipId: String?
        var spec: EvidenceGraphicSpec
        var digest: String
        var warnings: [String]
    }

    enum GraphicSceneBuildError: LocalizedError {
        case noProject

        var errorDescription: String? {
            "Save the project first — evidence graphics are stored in its package."
        }
    }

    func prepareGraphicScene(
        _ spec: EvidenceGraphicSpec,
        name: String?,
        addToTimeline: Bool = false,
        startFrame: Int = 0,
        planId: String? = nil,
        narrationText: String? = nil
    ) async throws -> GraphicSceneReceipt {
        // If plan is provided, validate against its ledger and script beats
        if let planId, let plan = editPlan(id: planId) {
            if let ledger = plan.sourceLedger {
                let knownClaims = Set(ledger.claims.map(\.claimId))
                for claimId in spec.claimIds {
                    guard knownClaims.contains(claimId) else {
                        throw EvidenceGraphicError.fabricatedAttribution("Claim '\(claimId)' is not registered in plan '\(planId)' sourceLedger.")
                    }
                }
                let narrationToValidate = narrationText ?? (plan.scriptBeats?.map(\.text).joined(separator: " ") ?? "")
                if !narrationToValidate.isEmpty {
                    try EvidenceGraphicNarrationValidator.validate(spec: spec, narration: narrationToValidate, claims: ledger.claims)
                }
            }
        } else if let narrationText, !narrationText.isEmpty {
            try EvidenceGraphicNarrationValidator.validate(spec: spec, narration: narrationText)
        }

        return try await projectPackageCoordinator.withMutation { lease in
            try await self.performGraphicScene(
                spec, lease: lease, name: name,
                addToTimeline: addToTimeline, startFrame: startFrame,
                planId: planId
            )
        }
    }

    private func performGraphicScene(
        _ spec: EvidenceGraphicSpec,
        lease: ProjectPackageCoordinator.MutationLease,
        name: String?,
        addToTimeline: Bool,
        startFrame: Int,
        planId: String?
    ) async throws -> GraphicSceneReceipt {
        guard let package = projectURL else { throw GraphicSceneBuildError.noProject }
        try Task.checkCancellation()

        let data = try EvidenceGraphicLottie.data(for: spec)
        let tempJSON = try await projectPackageCoordinator.io.perform {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("graphic-\(spec.digest)-\(UUID().uuidString).json")
            try data.write(to: url, options: [.atomic])
            return url
        }
        defer { try? FileManager.default.removeItem(at: tempJSON) }

        guard LottieVideoGenerator.isLottie(at: tempJSON) else {
            throw EvidenceGraphicError.malformedData("Generated evidence graphic failed the Lottie signature check.")
        }

        let size = CGSize(width: spec.width, height: spec.height)
        let baked = try await LottieVideoGenerator.lottieVideo(for: tempJSON, mediaRef: "graphic-\(spec.digest)", size: size)
        try Task.checkCancellation()
        try projectPackageCoordinator.validate(lease)

        let filename = "graphic-\(spec.digest).mov"
        let defaultName: String
        switch spec.kind {
        case .numericComparison: defaultName = "Comparison: \(spec.title)"
        case .sourceCard: defaultName = "Source: \(spec.title)"
        case .comparisonChart: defaultName = "Chart: \(spec.title)"
        case .policyTimeline: defaultName = "Timeline: \(spec.title)"
        }

        let finalName = name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? name! : defaultName
        let asset = MediaAsset(
            url: package.appendingPathComponent("media/\(filename)"),
            type: .video,
            name: finalName,
            duration: Double(spec.durationFrames) / Double(EvidenceGraphicLottie.fps)
        )
        asset.sourceWidth = spec.width
        asset.sourceHeight = spec.height
        asset.sourceFPS = Double(EvidenceGraphicLottie.fps)

        var placedClipId: String?
        var warnings: [String] = []

        _ = try await commitStagedProjectMedia(baked, filename: filename, lease: lease) { destination in
            asset.url = destination
            self.importMediaAsset(asset)
            self.searchIndex.schedule(asset)
            self.prepareMediaVisuals(for: asset)

            if addToTimeline {
                self.withTimelineSwap(actionName: "Add Graphic Clip") {
                    let trackIndex = self.timeline.tracks.firstIndex(where: { $0.type == .video })
                        ?? self.insertTrack(at: 0, type: .video)
                    placedClipId = self.placeClip(
                        asset: asset,
                        trackIndex: trackIndex,
                        startFrame: max(0, startFrame),
                        durationFrames: spec.durationFrames,
                        addLinkedAudio: false
                    ).first
                }
                if placedClipId == nil {
                    warnings.append("The graphic scene was created but could not be placed on the timeline.")
                }
            }

            // If an active EditPlan was specified, check if any shot links this graphic's claim
            if let planId, var plan = self.editPlan(id: planId) {
                var modified = false
                for i in 0..<plan.shots.count {
                    let shotClaims = Set(plan.shots[i].claimIds ?? [])
                    if !shotClaims.isDisjoint(with: Set(spec.claimIds)) && plan.shots[i].mediaRef == nil {
                        plan.shots[i].mediaRef = asset.id
                        plan.shots[i].license = "Sourced Graphic"
                        plan.shots[i].attribution = spec.title
                        modified = true
                    }
                }
                if modified {
                    _ = try? self.changeEditPlans(updates: [plan], actionName: "Attach Graphic (Agent)")
                }
            }

            self.onProjectCheckpointRequired?()
        }

        return GraphicSceneReceipt(
            asset: asset,
            clipId: placedClipId,
            spec: spec,
            digest: spec.digest,
            warnings: warnings
        )
    }
}
