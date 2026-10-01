import Foundation

enum EditPlanStatus: String, Codable, Sendable, CaseIterable {
    case proposed
    case approved
    case ready
    case applied
    case superseded
}

enum EditPlanLimits {
    static let maximumNameLength = 120
    static let maximumTextLength = 4_000
    static let maximumLicenseLength = 500
    static let maximumAttributionLength = 2_000
    static let maximumURLLength = 2_048
    static let maximumIDLength = 200
    static let maximumSections = 64
    static let maximumShots = 256
    static let maximumPlans = 100
}

struct EditPlanSection: Codable, Sendable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    var title: String
    var summary: String = ""
    var startFrame: Int
    var endFrame: Int
}

struct EditPlanShot: Codable, Sendable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    var title: String
    var startFrame: Int
    var endFrame: Int
    var trackId: String?
    var mediaRef: String?
    var candidateURL: String?
    var license: String?
    var attribution: String?
    var sourceStartSeconds: Double?
    var sourceEndSeconds: Double?
    var notes: String = ""
}

struct EditPlan: Codable, Sendable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    var name: String
    var goal: String = ""
    var timelineId: String
    var fps: Int
    var width: Int
    var height: Int
    var status: EditPlanStatus = .proposed
    var sections: [EditPlanSection] = []
    var shots: [EditPlanShot] = []
    var notes: String = ""
    var createdAt = Date()
    var updatedAt = Date()

    private enum CodingKeys: String, CodingKey {
        case id, name, goal, timelineId, fps, width, height, status
        case sections, shots, notes, createdAt, updatedAt
    }

    init(
        id: String = UUID().uuidString,
        name: String,
        goal: String = "",
        timelineId: String,
        fps: Int,
        width: Int,
        height: Int,
        status: EditPlanStatus = .proposed,
        sections: [EditPlanSection] = [],
        shots: [EditPlanShot] = [],
        notes: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.goal = goal
        self.timelineId = timelineId
        self.fps = fps
        self.width = width
        self.height = height
        self.status = status
        self.sections = sections
        self.shots = shots
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try container.decode(String.self, forKey: .name)
        goal = try container.decodeIfPresent(String.self, forKey: .goal) ?? ""
        timelineId = try container.decode(String.self, forKey: .timelineId)
        fps = try container.decode(Int.self, forKey: .fps)
        width = try container.decode(Int.self, forKey: .width)
        height = try container.decode(Int.self, forKey: .height)
        status = try container.decodeIfPresent(EditPlanStatus.self, forKey: .status) ?? .proposed
        sections = try container.decodeIfPresent([EditPlanSection].self, forKey: .sections) ?? []
        shots = try container.decodeIfPresent([EditPlanShot].self, forKey: .shots) ?? []
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }
}

enum EditPlanValidationError: Error, Equatable {
    case invalidName
    case invalidText(field: String)
    case invalidRange
    case invalidReference(String)
    case invalidLicense
    case invalidStatusTransition(from: EditPlanStatus, to: EditPlanStatus)
    case duplicateId(String)
    case unreadablePlans
    case tooManyPlans(maximum: Int)
}

extension EditPlanValidationError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidName:
            "Plan names must be a non-empty single line of at most \(EditPlanLimits.maximumNameLength) characters."
        case .invalidText(let field):
            "\(field) must be at most \(EditPlanLimits.maximumTextLength) characters and contain no control characters."
        case .invalidRange:
            "Plan frames must satisfy 0 <= startFrame < endFrame."
        case .invalidReference(let detail):
            detail
        case .invalidLicense:
            "A web candidate must have an HTTPS URL, a license, and an attribution line."
        case .invalidStatusTransition(let from, let to):
            "Plan status cannot move from \(from.rawValue) to \(to.rawValue)."
        case .duplicateId(let id):
            "Duplicate plan element id '\(id)'. Stable ids must be unique within one plan."
        case .unreadablePlans:
            "The project's saved plans could not be read. Repair or remove plans.json before changing plans."
        case .tooManyPlans(let maximum):
            "A project stores at most \(maximum) plans. Supersede or delete an old plan first."
        }
    }
}

extension EditPlan {
    static func validatedID(_ value: String?, field: String, assign: Bool = false) throws -> String {
        if let value, !value.isEmpty {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= EditPlanLimits.maximumIDLength,
                  trimmed.rangeOfCharacter(from: .controlCharacters.union(.newlines)) == nil else {
                throw EditPlanValidationError.invalidReference("\(field) must be a non-empty id.")
            }
            return trimmed
        }
        guard assign else { throw EditPlanValidationError.invalidReference("\(field) is required.") }
        return UUID().uuidString
    }

    static func validatedName(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= EditPlanLimits.maximumNameLength,
              trimmed.rangeOfCharacter(from: .controlCharacters.union(.newlines)) == nil else {
            throw EditPlanValidationError.invalidName
        }
        return trimmed
    }

    static func validatedText(_ value: String, field: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= EditPlanLimits.maximumTextLength,
              trimmed.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw EditPlanValidationError.invalidText(field: field)
        }
        return trimmed
    }

    static func validatedFrames(start: Int, end: Int) throws {
        guard start >= 0, end > start, end <= maxFrameArg else {
            throw EditPlanValidationError.invalidRange
        }
    }

    static func validatedGeometry(fps: Int, width: Int, height: Int) throws {
        guard (1...120).contains(fps), width > 0, height > 0, width <= 8_192, height <= 8_192 else {
            throw EditPlanValidationError.invalidReference("Plan geometry must match supported project settings.")
        }
    }

    static func validatedURL(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= EditPlanLimits.maximumURLLength,
              let url = URL(string: trimmed), url.scheme == "https",
              url.host?.isEmpty == false else {
            throw EditPlanValidationError.invalidLicense
        }
        return trimmed
    }

    static func validatedShot(_ shot: EditPlanShot) throws -> EditPlanShot {
        var shot = shot
        shot.id = try validatedID(shot.id, field: "shotId", assign: true)
        shot.title = try validatedName(shot.title)
        shot.notes = try validatedText(shot.notes, field: "shot notes")
        try validatedFrames(start: shot.startFrame, end: shot.endFrame)

        if let trackId = shot.trackId {
            shot.trackId = try validatedID(trackId, field: "trackId")
        }
        if let mediaRef = shot.mediaRef {
            shot.mediaRef = try validatedID(mediaRef, field: "mediaRef")
        }
        let hasURL = (shot.candidateURL?.isEmpty == false)
        if shot.mediaRef != nil, hasURL {
            throw EditPlanValidationError.invalidReference("Set either mediaRef or candidateURL, not both.")
        }
        if let url = shot.candidateURL {
            shot.candidateURL = try validatedURL(url)
            guard let license = shot.license?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !license.isEmpty, license.count <= EditPlanLimits.maximumLicenseLength,
                  let attribution = shot.attribution?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !attribution.isEmpty, attribution.count <= EditPlanLimits.maximumAttributionLength else {
                throw EditPlanValidationError.invalidLicense
            }
            shot.license = license
            shot.attribution = attribution
        } else {
            shot.license = nil
            shot.attribution = nil
        }
        switch (shot.sourceStartSeconds, shot.sourceEndSeconds) {
        case (.none, .none):
            break
        case let (.some(start), .some(end)):
            guard start.isFinite, end.isFinite, start >= 0, end > start else {
                throw EditPlanValidationError.invalidRange
            }
        default:
            throw EditPlanValidationError.invalidReference("A source span needs both sourceStartSeconds and sourceEndSeconds.")
        }
        return shot
    }

    static func validatedSection(_ section: EditPlanSection) throws -> EditPlanSection {
        var section = section
        section.id = try validatedID(section.id, field: "sectionId", assign: true)
        section.title = try validatedName(section.title)
        section.summary = try validatedText(section.summary, field: "section summary")
        try validatedFrames(start: section.startFrame, end: section.endFrame)
        return section
    }

    static func validatedStatusTransition(from: EditPlanStatus, to: EditPlanStatus, permitReserved: Bool = false) throws {
        if to == .ready || to == .applied, !permitReserved {
            throw EditPlanValidationError.invalidStatusTransition(from: from, to: to)
        }
        switch (from, to) {
        case (_, _) where from == to:
            return
        case (.proposed, .approved), (.approved, .proposed),
            (.ready, .approved),
            (.proposed, .superseded), (.approved, .superseded),
            (.ready, .superseded), (.applied, .superseded),
            (.approved, .ready):
            return
        default:
            throw EditPlanValidationError.invalidStatusTransition(from: from, to: to)
        }
    }

    static func validatedNew(
        _ plan: EditPlan,
        timelineId: String,
        fps: Int,
        width: Int,
        height: Int,
        existingCount: Int
    ) throws -> EditPlan {
        var plan = plan
        guard existingCount < EditPlanLimits.maximumPlans else {
            throw EditPlanValidationError.tooManyPlans(maximum: EditPlanLimits.maximumPlans)
        }
        plan.id = try validatedID(plan.id, field: "planId", assign: true)
        plan.name = try validatedName(plan.name)
        plan.goal = try validatedText(plan.goal, field: "goal")
        plan.notes = try validatedText(plan.notes, field: "notes")
        guard plan.timelineId == timelineId else {
            throw EditPlanValidationError.invalidReference("Plan timeline '\(plan.timelineId)' is not the active timeline.")
        }
        guard plan.fps == fps, plan.width == width, plan.height == height else {
            throw EditPlanValidationError.invalidReference("Plan geometry does not match the timeline.")
        }
        try validatedGeometry(fps: plan.fps, width: plan.width, height: plan.height)
        guard plan.status == .proposed else {
            throw EditPlanValidationError.invalidReference("New plans always start as proposed.")
        }
        guard plan.sections.count <= EditPlanLimits.maximumSections else {
            throw EditPlanValidationError.invalidReference("A plan has at most \(EditPlanLimits.maximumSections) sections.")
        }
        guard plan.shots.count <= EditPlanLimits.maximumShots else {
            throw EditPlanValidationError.invalidReference("A plan has at most \(EditPlanLimits.maximumShots) shots.")
        }
        plan.sections = try plan.sections.map(validatedSection)
        plan.shots = try plan.shots.map(validatedShot)
        try ensureUniqueIDs(plan)
        plan.createdAt = Date()
        plan.updatedAt = plan.createdAt
        return plan
    }

    static func ensureUniqueIDs(_ plan: EditPlan) throws {
        var seen = Set<String>()
        for id in [plan.id] + plan.sections.map(\.id) + plan.shots.map(\.id) {
            guard seen.insert(id).inserted else { throw EditPlanValidationError.duplicateId(id) }
        }
    }

    func receipt(includeDetails: Bool) -> [String: Any] {
        var out: [String: Any] = [
            "planId": id,
            "name": name,
            "status": status.rawValue,
            "timelineId": timelineId,
            "fps": fps,
            "width": width,
            "height": height,
            "updatedAt": EditPlanStore.iso8601String(updatedAt),
            "sectionCount": sections.count,
            "shotCount": shots.count,
        ]
        if !goal.isEmpty { out["goal"] = goal }
        if includeDetails {
            out["createdAt"] = EditPlanStore.iso8601String(createdAt)
            out["sections"] = sections.map {
                [
                    "sectionId": $0.id,
                    "title": $0.title,
                    "summary": $0.summary,
                    "startFrame": $0.startFrame,
                    "endFrame": $0.endFrame,
                ] as [String: Any]
            }
            out["shots"] = shots.map { shot in
                var row: [String: Any] = [
                    "shotId": shot.id,
                    "title": shot.title,
                    "startFrame": shot.startFrame,
                    "endFrame": shot.endFrame,
                ]
                if let trackId = shot.trackId { row["trackId"] = trackId }
                if let mediaRef = shot.mediaRef { row["mediaRef"] = mediaRef }
                if let candidateURL = shot.candidateURL { row["candidateURL"] = candidateURL }
                if let license = shot.license { row["license"] = license }
                if let attribution = shot.attribution { row["attribution"] = attribution }
                if let start = shot.sourceStartSeconds { row["sourceStartSeconds"] = start }
                if let end = shot.sourceEndSeconds { row["sourceEndSeconds"] = end }
                if !shot.notes.isEmpty { row["notes"] = shot.notes }
                return row
            }
            if !notes.isEmpty { out["notes"] = notes }
        }
        return out
    }
}

enum EditPlanStore {
    static let filename = Project.plansFilename

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func iso8601String(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    static func encode(_ plans: [EditPlan]) throws -> Data {
        try encoder.encode(plans)
    }

    static func decode(_ data: Data) throws -> [EditPlan] {
        try decoder.decode([EditPlan].self, from: data)
    }

    /// Snapshots plans for saving without destroying recoverable on-disk plans.
    static func snapshot(plans: [EditPlan], loadFailed: Bool) -> [EditPlan]? {
        if loadFailed { return nil }
        return plans
    }

    /// Reads plans without throwing for a malformed list. Filesystem failures still throw so
    /// save/close can surface them.
    nonisolated static func readPackageFile(at packageURL: URL) throws -> (plans: [EditPlan], unreadable: Bool) {
        let url = packageURL.appendingPathComponent(filename, isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else { return ([], false) }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard let plans = try? decoder.decode([EditPlan].self, from: data) else {
            Log.project.error("read plans decode failed bytes=\(data.count); keeping the file for recovery")
            return ([], true)
        }
        return (plans, false)
    }

    nonisolated static func writePackageFile(_ data: Data?, to packageURL: URL, sourceURL: URL?) throws {
        let destination = packageURL.appendingPathComponent(filename, isDirectory: false)
        if let data {
            try data.write(to: destination, options: .atomic)
            return
        }
        guard let sourceURL, sourceURL.standardizedFileURL.path != packageURL.standardizedFileURL.path else { return }
        let source = sourceURL.appendingPathComponent(filename, isDirectory: false)
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
    }
}
