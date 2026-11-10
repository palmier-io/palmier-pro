import Foundation

/// Filmmaking brief recorded on the plan: intended audience, format, tone,
/// realism requirements, language, and delivery constraints. Every field is
/// optional and editable; inferred choices are recorded so the model's guesses
/// stay visible and revisable.
struct PlanBrief: Codable, Sendable, Equatable {
    enum Realism: String, Codable, Sendable, CaseIterable {
        case realFootageOnly
        case realOrGenerated
        case generatedAllowed
        case illustrative
    }

    var audience: String?
    var durationSeconds: Double?
    var aspectFormat: String?
    var tone: String?
    var language: String?
    var realism: Realism?
    var deliveryConstraints: String?
    var inferredChoices: [String: String]?

    static let maxComboboxLength = 200

    func validated() throws -> Self {
        var brief = self
        if let audience { brief.audience = try Self.validatedField(audience, field: "brief.audience") }
        if let aspectFormat { brief.aspectFormat = try Self.validatedField(aspectFormat, field: "brief.aspectFormat") }
        if let tone { brief.tone = try Self.validatedField(tone, field: "brief.tone") }
        if let language { brief.language = try Self.validatedField(language, field: "brief.language") }
        if let deliveryConstraints {
            brief.deliveryConstraints = try EditPlan.validatedText(deliveryConstraints, field: "brief.deliveryConstraints")
        }
        if let durationSeconds {
            guard durationSeconds.isFinite, durationSeconds > 0, durationSeconds <= 14_400 else {
                throw EditPlanValidationError.invalidReference("brief.durationSeconds must be 0–4 hours.")
            }
        }
        if let inferredChoices {
            guard inferredChoices.count <= 32 else {
                throw EditPlanValidationError.invalidReference("brief.inferredChoices holds at most 32 entries.")
            }
            var cleaned: [String: String] = [:]
            for (key, value) in inferredChoices {
                let key = try EditPlan.validatedID(key, field: "brief choice key")
                cleaned[key] = try Self.validatedField(value, field: "brief choice '\(key)'")
            }
            brief.inferredChoices = cleaned
        }
        return brief
    }

    var receipt: [String: Any] {
        var row: [String: Any] = [:]
        if let audience { row["audience"] = audience }
        if let durationSeconds { row["durationSeconds"] = durationSeconds }
        if let aspectFormat { row["aspectFormat"] = aspectFormat }
        if let tone { row["tone"] = tone }
        if let language { row["language"] = language }
        if let realism { row["realism"] = realism.rawValue }
        if let deliveryConstraints { row["deliveryConstraints"] = deliveryConstraints }
        if let inferredChoices { row["inferredChoices"] = inferredChoices }
        return row
    }

    private static func validatedField(_ value: String, field: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxComboboxLength,
              trimmed.rangeOfCharacter(from: .controlCharacters.union(.newlines)) == nil else {
            throw EditPlanValidationError.invalidText(field: field)
        }
        return trimmed
    }
}

/// Per-shot editorial requirements: why the shot exists, what it must show,
/// how it should be framed, and which source kinds are acceptable. Rejections
/// and unresolved requirements are recorded during retrieval against the shot.
struct ShotRequirement: Codable, Sendable, Equatable {
    enum ShotSize: String, Codable, Sendable, CaseIterable {
        case extremeWide = "extreme_wide"
        case wide
        case medium
        case mediumClose = "medium_close"
        case closeUp = "close_up"
        case extremeCloseUp = "extreme_close_up"
        case insert
    }

    enum Motion: String, Codable, Sendable, CaseIterable {
        case static_  // swiftlint:disable:this identifier_name
        case pan
        case tilt
        case push
        case handheld
        case aerial
        case follow
    }

    enum SourceType: String, Codable, Sendable, CaseIterable {
        case stockVideo = "stock_video"
        case stockImage = "stock_image"
        case library
        case generated
        case screenRecording = "screen_recording"
        case archival
    }

    var narrativePurpose: String
    var subject: String?
    var action: String?
    var location: String?
    var shotSize: ShotSize?
    var motion: Motion?
    var sourceTypes: [SourceType]?
    var exclusions: [String]?
    var targetDurationSeconds: Double?
    var handleSeconds: Double?

    func validated() throws -> Self {
        var requirement = self
        requirement.narrativePurpose = try EditPlan.validatedText(narrativePurpose, field: "shot narrativePurpose")
        guard !requirement.narrativePurpose.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw EditPlanValidationError.invalidReference("Shot narrativePurpose cannot be empty.")
        }
        if let subject { requirement.subject = try Self.validatedField(subject, field: "shot.subject") }
        if let action { requirement.action = try Self.validatedField(action, field: "shot.action") }
        if let location { requirement.location = try Self.validatedField(location, field: "shot.location") }
        if let exclusions {
            var cleaned: [String] = []
            for exclusion in exclusions {
                cleaned.append(try Self.validatedField(exclusion, field: "shot.exclusions"))
            }
            requirement.exclusions = cleaned.isEmpty ? nil : cleaned
        }
        if let sourceTypes {
            var seen = Set<SourceType>()
            for type in sourceTypes {
                guard seen.insert(type).inserted else {
                    continue
                }
            }
            requirement.sourceTypes = seen.isEmpty ? nil : Array(seen)
        }
        if let targetDurationSeconds {
            guard targetDurationSeconds.isFinite, targetDurationSeconds > 0, targetDurationSeconds <= 600 else {
                throw EditPlanValidationError.invalidReference("shot.targetDurationSeconds must be within 0–600 seconds.")
            }
        }
        if let handleSeconds {
            guard handleSeconds.isFinite, handleSeconds >= 0, handleSeconds <= 30 else {
                throw EditPlanValidationError.invalidReference("shot.handleSeconds must be within 0–30 seconds.")
            }
        }
        return requirement
    }

    var receipt: [String: Any] {
        var row: [String: Any] = ["narrativePurpose": narrativePurpose]
        if let subject { row["subject"] = subject }
        if let action { row["action"] = action }
        if let location { row["location"] = location }
        if let shotSize { row["shotSize"] = shotSize.rawValue }
        if let motion { row["motion"] = motion.rawValue }
        if let sourceTypes { row["sourceTypes"] = sourceTypes.map(\.rawValue) }
        if let exclusions { row["exclusions"] = exclusions }
        if let targetDurationSeconds { row["targetDurationSeconds"] = targetDurationSeconds }
        if let handleSeconds { row["handleSeconds"] = handleSeconds }
        return row
    }

    private static func validatedField(_ value: String, field: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= PlanBrief.maxComboboxLength,
              trimmed.rangeOfCharacter(from: .controlCharacters.union(.newlines)) == nil else {
            throw EditPlanValidationError.invalidText(field: field)
        }
        return trimmed
    }
}

/// One motivated sound cue on the plan: role, purpose, and a single timing
/// anchor — either a narrative beat or a timeline frame, never both.
struct PlanSoundCue: Codable, Sendable, Equatable {
    enum Role: String, Codable, Sendable, CaseIterable {
        case voice
        case music
        case ambience
        case sfx
    }

    var cueId: String
    var role: Role
    var purpose: String
    var anchorBeatId: String?
    var anchorFrame: Int?
    var durationSeconds: Double?
    var notes: String?

    func validated() throws -> Self {
        var cue = self
        cue.cueId = try EditPlan.validatedID(cueId, field: "cueId")
        cue.purpose = try EditPlan.validatedText(purpose, field: "sound cue purpose")
        guard !cue.purpose.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw EditPlanValidationError.invalidReference("Sound cue purpose cannot be empty.")
        }
        if let anchorBeatId { cue.anchorBeatId = try EditPlan.validatedID(anchorBeatId, field: "cue.anchorBeatId") }
        if let durationSeconds {
            guard durationSeconds.isFinite, durationSeconds > 0, durationSeconds <= 600 else {
                throw EditPlanValidationError.invalidReference("sound cue durationSeconds must be within 0–600 seconds.")
            }
        }
        if let notes {
            let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            cue.notes = trimmed.isEmpty ? nil : try EditPlan.validatedText(trimmed, field: "sound cue notes")
        }
        if cue.anchorBeatId != nil, cue.anchorFrame != nil {
            throw EditPlanValidationError.invalidReference(
                "Sound cue '\(cue.cueId)' has one timing anchor: anchorBeatId or anchorFrame, not both.")
        }
        return cue
    }

    var receipt: [String: Any] {
        var row: [String: Any] = ["cueId": cueId, "role": role.rawValue, "purpose": purpose]
        if let anchorBeatId { row["anchorBeatId"] = anchorBeatId }
        if let anchorFrame { row["anchorFrame"] = anchorFrame }
        if let durationSeconds { row["durationSeconds"] = durationSeconds }
        if let notes { row["notes"] = notes }
        return row
    }
}
