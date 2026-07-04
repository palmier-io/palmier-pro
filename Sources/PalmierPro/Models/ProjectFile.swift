import Foundation

/// Root of project.json. Legacy projects stored a bare Timeline; decode falls back and wraps.
struct ProjectFile: Codable, Sendable {
    var timelines: [Timeline]
    var activeTimelineId: String?
    var openTimelineIds: [String]?
    var viewStates: [String: TimelineViewState]?

    static func decode(_ data: Data) throws -> ProjectFile {
        let decoder = JSONDecoder()
        do {
            let file = try decoder.decode(ProjectFile.self, from: data)
            guard !file.timelines.isEmpty else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "project has no timelines"))
            }
            return file
        } catch {
            // Legacy files are a bare Timeline; anything else rethrows the real error.
            guard let legacy = try? decoder.decode(Timeline.self, from: data) else { throw error }
            return ProjectFile(timelines: [legacy], activeTimelineId: legacy.id, openTimelineIds: [legacy.id])
        }
    }
}
