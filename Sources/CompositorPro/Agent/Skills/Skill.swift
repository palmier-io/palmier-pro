import Foundation

/// A skill is a folder under `~/.palmier/skills/<id>/` with a `SKILL.md` file
struct Skill: Identifiable, Sendable {
    enum Limits {
        static let maximumNameLength = 120
        static let maximumDescriptionLength = 500
        static let maximumInstructionsLength = 50_000
    }

    let id: String  // folder name
    let name: String
    let description: String
    let path: URL  // the SKILL.md file
}

enum SkillFrontmatter {
    static func contents(name: String, description: String, instructions: String) -> String {
        """
        ---
        name: \(name)
        description: \(description)
        ---

        \(instructions)
        """
    }

    /// Splits a SKILL.md into its frontmatter fields and body
    static func parse(_ text: String) -> (fields: [String: String], body: String) {
        var fields: [String: String] = [:]
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return (fields, text)
        }
        var i = 1
        while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces) != "---" {
            let line = lines[i]
            if let colon = line.firstIndex(of: ":") {
                let key = line[..<colon].trimmingCharacters(in: .whitespaces)
                var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                    value = String(value.dropFirst().dropLast())
                }
                if !key.isEmpty { fields[key] = value }
            }
            i += 1
        }
        let body = i + 1 < lines.count
            ? lines[(i + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        return (fields, body)
    }

    static func requiredFields(_ text: String) -> (name: String, description: String, body: String)? {
        let parsed = parse(text)
        guard let name = parsed.fields["name"], !name.trimmingCharacters(in: .whitespaces).isEmpty,
              let description = parsed.fields["description"],
              !description.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return (name, description, parsed.body)
    }

    static func replacingFields(
        _ text: String,
        name: String? = nil,
        description: String? = nil,
        instructions: String? = nil
    ) -> String {
        var lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              var closingIndex = lines.indices.dropFirst().first(where: {
                  lines[$0].trimmingCharacters(in: .whitespaces) == "---"
              }) else {
            let parsed = parse(text)
            return contents(
                name: name ?? parsed.fields["name"] ?? "New skill",
                description: description ?? parsed.fields["description"] ?? "Describe when to use this skill.",
                instructions: instructions ?? parsed.body
            )
        }

        func replace(_ key: String, with value: String) {
            if let index = (1..<closingIndex).first(where: { index in
                guard let colon = lines[index].firstIndex(of: ":") else { return false }
                return lines[index][..<colon].trimmingCharacters(in: .whitespaces) == key
            }) {
                lines[index] = "\(key): \(value)"
            } else {
                lines.insert("\(key): \(value)", at: closingIndex)
                closingIndex += 1
            }
        }

        if let name { replace("name", with: name) }
        if let description { replace("description", with: description) }
        guard let instructions else { return lines.joined(separator: "\n") }
        return lines[...closingIndex].joined(separator: "\n") + "\n\n" + instructions
    }
}
