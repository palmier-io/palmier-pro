import Foundation

/// One row in the Project Activity log.
struct GenerationLogEntry: Equatable, Identifiable {
    enum Category: String {
        case video, image, audio, upscale

        var sfSymbolName: String {
            switch self {
            case .video:   "video.fill"
            case .image:   "photo.fill"
            case .audio:   "music.note"
            case .upscale: "arrow.up.right.square.fill"
            }
        }
    }

    let id: String
    let category: Category
    let modelDisplayName: String
    let cost: Double?
    let createdAt: Date?
}

extension EditorViewModel {

    /// All AI-generated assets in the project, newest first.
    var generationLog: [GenerationLogEntry] {
        let rows: [GenerationLogEntry] = mediaAssets.compactMap { asset in
            guard let gen = asset.generationInput else { return nil }
            let model = ModelRegistry.byId[gen.model]
            let category: GenerationLogEntry.Category
            if case .upscale = model {
                category = .upscale
            } else {
                switch asset.type {
                case .video: category = .video
                case .image: category = .image
                case .audio: category = .audio
                }
            }
            return GenerationLogEntry(
                id: asset.id,
                category: category,
                modelDisplayName: model?.displayName ?? gen.model,
                cost: gen.estimatedCost ?? CostEstimator.cost(for: gen),
                createdAt: gen.createdAt
            )
        }
        return rows.sorted { lhs, rhs in
            switch (lhs.createdAt, rhs.createdAt) {
            case let (l?, r?): return l > r
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return lhs.id < rhs.id
            }
        }
    }

    /// Sum of all known per-entry estimates.
    var totalGenerationCost: Double {
        mediaAssets.reduce(0.0) { acc, asset in
            guard let gen = asset.generationInput else { return acc }
            return acc + (gen.estimatedCost ?? CostEstimator.cost(for: gen) ?? 0)
        }
    }
}
