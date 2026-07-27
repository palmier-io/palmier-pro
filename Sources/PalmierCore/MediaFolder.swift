import Foundation

public struct MediaFolder: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var name: String
    public var parentFolderId: String?

    public init(id: String = UUID().uuidString, name: String, parentFolderId: String? = nil) {
        self.id = id
        self.name = name
        self.parentFolderId = parentFolderId
    }
}
