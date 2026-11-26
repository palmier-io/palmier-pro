import Foundation

extension ToolExecutor {
    func manageSkills(_ args: [String: Any]) async throws -> ToolResult {
        guard let action = args.string("action") else {
            throw ToolError("manage_skills.action: expected one of: create, update, remove")
        }
        switch action {
        case "create":
            return try await createSkill(args)
        case "update":
            return try await updateSkill(args)
        case "remove":
            return try await removeSkill(args)
        default:
            throw ToolError("Unknown skill action '\(action)'. Expected one of: create, update, remove.")
        }
    }

    private func createSkill(_ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(
            args,
            allowed: ["action", "name", "description", "instructions"],
            path: "manage_skills"
        )
        let name = try requiredSkillText(
            args,
            key: "name",
            path: "manage_skills",
            maximumLength: Skill.Limits.maximumNameLength,
            singleLine: true
        )
        let description = try requiredSkillText(
            args,
            key: "description",
            path: "manage_skills",
            maximumLength: Skill.Limits.maximumDescriptionLength,
            singleLine: true
        )
        let instructions = try requiredSkillText(
            args,
            key: "instructions",
            path: "manage_skills",
            maximumLength: Skill.Limits.maximumInstructionsLength,
            singleLine: false
        )
        let id = SkillStore.suggestedID(for: name)

        if let existing = skillStore.skills.first(where: { $0.id == id }) {
            guard existing.name == name,
                  existing.description == description,
                  skillStore.body(for: id) == instructions else {
                throw ToolError("A skill with id '\(id)' already exists. Use manage_skills with action='update'.")
            }
            return skillReceipt(status: "unchanged", skill: existing)
        }

        let raw = SkillFrontmatter.contents(
            name: name,
            description: description,
            instructions: instructions
        )
        guard let createdID = await skillStore.createSkill(raw: raw, preferredID: id),
              let skill = skillStore.skills.first(where: { $0.id == createdID }) else {
            throw ToolError("Could not create skill '\(name)'.")
        }
        return skillReceipt(status: "created", skill: skill)
    }

    private func updateSkill(_ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(
            args,
            allowed: ["action", "id", "name", "description", "instructions"],
            path: "manage_skills"
        )
        guard let id = args.string("id") else {
            throw ToolError("manage_skills.id: expected non-empty string for update")
        }
        let name = try optionalSkillText(
            args,
            key: "name",
            path: "manage_skills",
            maximumLength: Skill.Limits.maximumNameLength,
            singleLine: true
        )
        let description = try optionalSkillText(
            args,
            key: "description",
            path: "manage_skills",
            maximumLength: Skill.Limits.maximumDescriptionLength,
            singleLine: true
        )
        let instructions = try optionalSkillText(
            args,
            key: "instructions",
            path: "manage_skills",
            maximumLength: Skill.Limits.maximumInstructionsLength,
            singleLine: false
        )
        guard name != nil || description != nil || instructions != nil else {
            throw ToolError("manage_skills update requires at least one of: name, description, instructions.")
        }
        guard let skill = skillStore.skills.first(where: { $0.id == id }) else {
            throw ToolError("Unknown skill: \(id)")
        }

        var changed: [String] = []
        if let name, name != skill.name { changed.append("name") }
        if let description, description != skill.description { changed.append("description") }
        if let instructions, instructions != skillStore.body(for: id) { changed.append("instructions") }
        guard !changed.isEmpty else {
            return skillReceipt(status: "unchanged", skill: skill)
        }

        switch await skillStore.update(
            skill,
            name: name,
            description: description,
            instructions: instructions
        ) {
        case .updated(let saved):
            return skillReceipt(status: "updated", skill: saved, changed: changed)
        case .unchanged(let saved):
            return skillReceipt(status: "unchanged", skill: saved)
        case .failed:
            throw ToolError("Could not update skill '\(id)'.")
        }
    }

    private func removeSkill(_ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: ["action", "id"], path: "manage_skills")
        guard let id = args.string("id") else {
            throw ToolError("manage_skills.id: expected non-empty string for remove")
        }
        guard let skill = skillStore.skills.first(where: { $0.id == id }) else {
            throw ToolError("Unknown skill: \(id)")
        }
        guard await skillStore.delete(skill) else {
            throw ToolError("Could not remove skill '\(id)'.")
        }
        return .ok(Self.jsonString([
            "status": "removed",
            "id": skill.id,
            "name": skill.name,
        ]) ?? "{}")
    }

    private func requiredSkillText(
        _ args: [String: Any],
        key: String,
        path: String,
        maximumLength: Int,
        singleLine: Bool
    ) throws -> String {
        guard let value = try optionalSkillText(
            args,
            key: key,
            path: path,
            maximumLength: maximumLength,
            singleLine: singleLine
        ) else {
            throw ToolError("\(path).\(key): expected non-empty string")
        }
        return value
    }

    private func optionalSkillText(
        _ args: [String: Any],
        key: String,
        path: String,
        maximumLength: Int,
        singleLine: Bool
    ) throws -> String? {
        guard args.keys.contains(key) else { return nil }
        guard let raw = args[key] as? String else {
            throw ToolError("\(path).\(key): expected string")
        }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw ToolError("\(path).\(key): expected non-empty string")
        }
        guard value.count <= maximumLength else {
            throw ToolError("\(path).\(key): maximum length is \(maximumLength) characters")
        }
        guard !singleLine || value.rangeOfCharacter(from: .newlines) == nil else {
            throw ToolError("\(path).\(key): expected one line")
        }
        return value
    }

    private func skillReceipt(
        status: String,
        skill: Skill,
        changed: [String]? = nil
    ) -> ToolResult {
        var payload: [String: Any] = [
            "status": status,
            "skill": [
                "id": skill.id,
                "name": skill.name,
                "description": skill.description,
            ],
        ]
        if let changed { payload["changed"] = changed }
        return .ok(Self.jsonString(payload) ?? "{}")
    }
}
