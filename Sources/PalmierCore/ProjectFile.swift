import Foundation

/// Root of project.json. Legacy projects stored a bare Timeline; decode falls back and wraps.
public struct ProjectFile: Codable, Sendable {
    public var timelines: [Timeline]
    public var activeTimelineId: String?
    public var openTimelineIds: [String]?
    public var viewStates: [String: TimelineViewState]?
    public var speakers: [SpeakerRegistryEntry]?
    public var multicamGroups: [MulticamSource]?

    public init(
        timelines: [Timeline],
        activeTimelineId: String? = nil,
        openTimelineIds: [String]? = nil,
        viewStates: [String: TimelineViewState]? = nil,
        speakers: [SpeakerRegistryEntry]? = nil,
        multicamGroups: [MulticamSource]? = nil
    ) {
        self.timelines = timelines
        self.activeTimelineId = activeTimelineId
        self.openTimelineIds = openTimelineIds
        self.viewStates = viewStates
        self.speakers = speakers
        self.multicamGroups = multicamGroups
    }

    public static func decode(_ data: Data) throws -> ProjectFile {
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
