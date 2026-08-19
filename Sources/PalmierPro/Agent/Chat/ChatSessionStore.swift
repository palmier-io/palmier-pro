import Foundation

struct ChatSession: Codable, Identifiable {
    let id: UUID
    var title: String
    var updatedAt: Date
    var messages: [AgentMessage]
    var isOpen: Bool

    init(id: UUID = UUID(), title: String = "New chat", messages: [AgentMessage] = [], isOpen: Bool = true) {
        self.id = id
        self.title = title
        self.updatedAt = Date()
        self.messages = messages
        self.isOpen = isOpen
    }

    private enum CodingKeys: String, CodingKey { case id, title, updatedAt, messages, isOpen }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.title = try c.decode(String.self, forKey: .title)
        self.updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        self.messages = try c.decode([AgentMessage].self, forKey: .messages)
        self.isOpen = try c.decodeIfPresent(Bool.self, forKey: .isOpen) ?? true
    }
}

enum ChatSessionStore {
    static let dirName = "chat"

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static func load(from projectURL: URL?) -> [ChatSession] {
        guard let dir = projectURL?.appendingPathComponent(dirName, isDirectory: true),
              let urls = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return [] }
        return urls.compactMap { url in
            guard url.pathExtension == "json",
                  let data = try? Data(contentsOf: url)
            else { return nil }
            return try? decoder.decode(ChatSession.self, from: data)
        }
    }

    static func encodeSession(_ session: ChatSession) -> Data? {
        try? encoder.encode(session)
    }
}
