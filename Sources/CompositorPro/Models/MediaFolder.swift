import Foundation

struct MediaFolder: Codable, Sendable, Equatable, Identifiable {
    let id: String
    var name: String
    var parentFolderId: String?

    init(id: String = UUID().uuidString, name: String, parentFolderId: String? = nil) {
        self.id = id
        self.name = name
        self.parentFolderId = parentFolderId
    }
}
