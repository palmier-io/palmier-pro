import Foundation

struct StoryboardPreviewContext: Equatable {
    struct Source: Equatable {
        let url: URL
        let type: ClipType
        let transform: Transform
    }

    let plan: EditPlan?
    let revision: VisualReviewRevision
    let unavailable: Set<String>
    let sources: [String: Source]
}

extension EditorViewModel {
    func storyboardPreviewContext(planId: String) -> StoryboardPreviewContext {
        let plan = editPlan(id: planId)
        var unavailable = plan.map(storyboardUnavailableMediaRefs) ?? []
        if plan?.narrationTiming != nil, let ref = plan?.narration?.mediaRef,
           missingMediaRefs.contains(ref) || unprocessableMediaRefs.contains(ref)
            || (mediaAssetsById[ref].map { $0.generationStatus != .none } ?? true) { unavailable.insert(ref) }
        var sources: [String: StoryboardPreviewContext.Source] = [:]
        if let plan {
            var refs = Set(plan.shots.compactMap(\.mediaRef))
            if plan.narrationTiming != nil, let ref = plan.narration?.mediaRef { refs.insert(ref) }
            for ref in refs {
                guard let asset = mediaAssetsById[ref] else { continue }
                sources[ref] = .init(url: asset.url, type: asset.type,
                    transform: fitTransform(for: asset, canvasWidth: plan.width, canvasHeight: plan.height))
            }
        }
        return .init(plan: plan, revision: visualReviewRevision, unavailable: unavailable, sources: sources)
    }

    func storyboardPreviewSnapshot(planId: String) async throws -> StoryboardPreviewSnapshot {
        let context = storyboardPreviewContext(planId: planId)
        guard let plan = context.plan, plan.timelineId == activeTimelineId,
              plan.fps == timeline.fps, plan.width == timeline.width, plan.height == timeline.height else {
            throw StoryboardPreviewError.stale
        }
        let manifest = mediaManifest
        let projectURL = projectURL
        let snapshot = try await StoryboardPreviewSnapshot.make(plan: plan, manifest: manifest,
            projectURL: projectURL, transforms: context.sources.mapValues(\.transform), unavailable: context.unavailable)
        try Task.checkCancellation()
        guard storyboardPreviewContext(planId: planId) == context else { throw StoryboardPreviewError.stale }
        for source in snapshot.sources {
            guard let selected = context.sources[source.mediaRef], selected.url == source.url,
                  selected.type == source.type else { throw StoryboardPreviewError.stale }
        }
        return snapshot
    }
}
