import Foundation

/// Append-only record of every AI generation in the project. Persisted as `generation-log.json`
struct GenerationLog: Codable, Sendable, Equatable {
    var version: Int = 1
    var entries: [GenerationLogEntry] = []
}

/// One row in the Project Activity log.
struct GenerationLogEntry: Codable, Sendable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    let model: String
    let cost: Double?
    let createdAt: Date?
}

@MainActor
extension GenerationLogEntry {
    var modelDisplayName: String {
        ModelRegistry.displayName(for: model)
    }

    var sfSymbolName: String {
        switch ModelRegistry.byId[model] {
        case .video?:   "video.fill"
        case .image?:   "photo.fill"
        case .audio?:   "music.note"
        case .upscale?: "arrow.up.right.square.fill"
        case nil:       "sparkles"
        }
    }
}

extension EditorViewModel {

    var generationLogEntries: [GenerationLogEntry] {
        generationLog.entries.sorted { lhs, rhs in
            switch (lhs.createdAt, rhs.createdAt) {
            case let (l?, r?): return l > r
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return lhs.id < rhs.id
            }
        }
    }

    var totalGenerationCost: Double {
        generationLog.entries.reduce(0.0) { $0 + ($1.cost ?? 0) }
    }

    func appendGenerationLog(for asset: MediaAsset) {
        guard let gen = asset.generationInput else { return }
        generationLog.entries.append(GenerationLogEntry(
            model: gen.model,
            cost: gen.estimatedCost ?? CostEstimator.cost(for: gen),
            createdAt: gen.createdAt
        ))
    }

    /// For old projects saved before the persistent log existed:
    func seedGenerationLogFromAssets() {
        guard generationLog.entries.isEmpty else { return }
        generationLog.entries = mediaAssets.compactMap { asset in
            guard let gen = asset.generationInput else { return nil }
            return GenerationLogEntry(
                model: gen.model,
                cost: gen.estimatedCost ?? CostEstimator.cost(for: gen),
                createdAt: gen.createdAt
            )
        }
    }
}
