import Foundation

actor MCPPreviewStore {
    static let shared = MCPPreviewStore()

    struct Item: Sendable {
        enum Kind: String, Sendable {
            case video
            case image
            case audio
        }

        let url: URL
        let mimeType: String
        let kind: Kind
    }

    private var items: [String: Item] = [:]
    private var order: [String] = []
    private let capacity = 64

    func register(_ item: Item) -> String {
        let token = UUID().uuidString
        items[token] = item
        order.append(token)
        while order.count > capacity {
            items.removeValue(forKey: order.removeFirst())
        }
        return token
    }

    func item(for token: String) -> Item? {
        items[token]
    }
}
