import Foundation

actor MCPPreviewStore {
    static let shared = MCPPreviewStore()

    enum Kind: String, Sendable {
        case video
        case image
        case audio
    }

    struct AssetHandle: Sendable {
        var mediaRef: String
        var fileURL: URL?
        var mimeType: String
        var kind: Kind
        var width: Int?
        var height: Int?
        var durationSeconds: Double?
        var status: String?
        var failure: String?
    }

    struct Blob: Sendable {
        let data: Data
        let mimeType: String
    }

    private var assets: [String: AssetHandle] = [:]
    private var tokenByMediaRef: [String: String] = [:]
    private var assetOrder: [String] = []
    private var blobs: [String: Blob] = [:]
    private var blobOrder: [String] = []
    private var waiters: [String: [UUID: AsyncStream<AssetHandle>.Continuation]] = [:]
    private let capacity = 64

    @discardableResult
    func upsert(_ handle: AssetHandle) -> String {
        let token = tokenByMediaRef[handle.mediaRef] ?? UUID().uuidString
        tokenByMediaRef[handle.mediaRef] = token
        assets[token] = handle
        if let index = assetOrder.firstIndex(of: token) {
            assetOrder.remove(at: index)
        }
        assetOrder.append(token)
        trimAssets()
        notify(token, handle)
        return token
    }

    func publish(_ handle: AssetHandle) {
        _ = upsert(handle)
    }

    func asset(forToken token: String) -> AssetHandle? {
        assets[token]
    }

    func events(forToken token: String) -> AsyncStream<AssetHandle> {
        AsyncStream { continuation in
            let waiterID = UUID()
            waiters[token, default: [:]][waiterID] = continuation
            if let handle = assets[token] {
                continuation.yield(handle)
            }
            continuation.onTermination = { _ in
                Task { await self.removeWaiter(token, waiterID) }
            }
        }
    }

    func registerBlob(_ data: Data, mimeType: String) -> String {
        let token = UUID().uuidString
        blobs[token] = Blob(data: data, mimeType: mimeType)
        blobOrder.append(token)
        trim(&blobs, order: &blobOrder)
        return token
    }

    func blob(for token: String) -> Blob? {
        blobs[token]
    }

    private func notify(_ token: String, _ handle: AssetHandle) {
        guard let subs = waiters[token] else { return }
        for continuation in subs.values {
            continuation.yield(handle)
        }
    }

    private func removeWaiter(_ token: String, _ waiterID: UUID) {
        waiters[token]?[waiterID] = nil
        if waiters[token]?.isEmpty == true {
            waiters.removeValue(forKey: token)
        }
    }

    private func trimAssets() {
        while assetOrder.count > capacity {
            let evicted = assetOrder.removeFirst()
            if let mediaRef = assets[evicted]?.mediaRef {
                tokenByMediaRef.removeValue(forKey: mediaRef)
            }
            assets.removeValue(forKey: evicted)
            waiters.removeValue(forKey: evicted)
        }
    }

    private func trim<Value>(_ items: inout [String: Value], order: inout [String]) {
        while order.count > capacity {
            let evicted = order.removeFirst()
            items.removeValue(forKey: evicted)
        }
    }
}

extension MCPPreviewStore.Kind {
    var urlKey: String {
        switch self {
        case .video: "videoUrl"
        case .image: "imageUrl"
        case .audio: "audioUrl"
        }
    }

    static func from(_ type: ClipType) -> MCPPreviewStore.Kind? {
        switch type {
        case .video: .video
        case .image: .image
        case .audio: .audio
        default: nil
        }
    }
}
