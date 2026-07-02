import Foundation

// External media catalog exposed over localhost HTTP. Mirrors the orca-vvcut
// `Provider` contract (studio/src/lib/providers/types.ts) so the two consumers stay at parity.
enum AssetType: String, Sendable, CaseIterable {
    case music, sfx, image, video

    var clipType: ClipType {
        switch self {
        case .music, .sfx: .audio
        case .image: .image
        case .video: .video
        }
    }
}

struct AssetCard: Identifiable, Sendable {
    let id: String
    let providerId: String
    let type: AssetType
    let name: String
    let ref: String            // provider-internal addressing; resolve via fetchURL
    let thumbnailRef: String?
    let description: String?
    let durationMs: Int?
    let aspect: String?        // display-only cover ratio; never fed into a clip
    let isLocal: Bool          // false → present but not draggable (e.g. iCloud-only)
}

struct ListQuery: Sendable {
    var keys: [String] = []
    var page: Int = 1
    var limit: Int = 30
}

struct ListResult: Sendable {
    let items: [AssetCard]
    let hasMore: Bool
}

protocol AssetProvider: Sendable {
    var id: String { get }
    var label: String { get }
    var baseURL: URL { get }
    var capabilities: Set<AssetType> { get }
    func list(_ type: AssetType, query: ListQuery) async throws -> ListResult
    func fetchURL(forRef ref: String) -> URL?
    func health() async -> Bool
}

enum AssetProviderError: Error, CustomStringConvertible {
    case http(String, Int)
    case badResponse(String)

    var description: String {
        switch self {
        case let .http(id, code): "\(id) provider HTTP \(code)"
        case let .badResponse(id): "\(id) provider returned an unexpected response"
        }
    }
}
