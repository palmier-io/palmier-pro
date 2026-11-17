import Foundation

enum PluginManifestError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message): "Invalid plugin manifest: \(message)"
        }
    }
}

/// Declared capability of a plugin tool. Only read-only tools are dispatchable today; mutating
/// plugins are refused until the host exposes project mutations to third parties.
enum PluginPermissionScope: String, Codable, Sendable, CaseIterable {
    case readOnly = "read-only"
    case mutatingTools = "mutating-tools"
}

enum PluginTrustLevel: String, Codable, Sendable, CaseIterable {
    case trusted
    case untrusted
    case blocked
}

/// A plugin bundle's `plugin.json`: identity, one executable tool, JSON input schema, and the
/// optional signature that decides trust. The tool runs as a separate process, never in-process.
struct PluginManifest: @unchecked Sendable {
    static let fileName = "plugin.json"
    static let maximumEntryPointLength = 240

    let id: String
    let name: String
    let version: String
    let toolName: String
    let toolDescription: String
    let inputSchema: [String: Any]
    let entryPoint: String
    let permissionScope: PluginPermissionScope
    let signature: String?

    static func load(from directory: URL) throws -> PluginManifest {
        let url = directory.appendingPathComponent(fileName, isDirectory: false)
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PluginManifestError.invalid("\(fileName) is missing or is not a JSON object")
        }
        return try parse(object)
    }

    static func parse(_ object: [String: Any]) throws -> PluginManifest {
        let id = try slug(object["id"], field: "id")
        let name = try text(object["name"], field: "name")
        let version = try text(object["version"], field: "version")
        guard let tool = object["tool"] as? [String: Any] else {
            throw PluginManifestError.invalid("tool must be an object")
        }
        let toolName = try slug(tool["name"], field: "tool.name")
        let description = try text(tool["description"] ?? object["description"], field: "tool.description")
        guard let schema = tool["inputSchema"] as? [String: Any] else {
            throw PluginManifestError.invalid("tool.inputSchema must be a JSON object")
        }
        try validateSchema(schema)
        let entryPoint = try text(object["entryPoint"], field: "entryPoint")
        guard entryPoint.count <= maximumEntryPointLength,
              !entryPoint.hasPrefix("/"), !entryPoint.contains(".."),
              !entryPoint.contains("\\") else {
            throw PluginManifestError.invalid("entryPoint must be a relative path inside the plugin bundle")
        }
        let scope = (object["permissionScope"] as? String).flatMap(PluginPermissionScope.init(rawValue:))
            ?? .readOnly
        let signature = object["signature"] as? String
        return PluginManifest(
            id: id, name: name, version: version,
            toolName: toolName, toolDescription: description, inputSchema: schema,
            entryPoint: entryPoint, permissionScope: scope, signature: signature
        )
    }

    /// The schema must describe an object so agent arguments can be validated before dispatch.
    private static func validateSchema(_ schema: [String: Any]) throws {
        guard schema["type"] as? String == "object" else {
            throw PluginManifestError.invalid("tool.inputSchema.type must be \"object\"")
        }
        if let properties = schema["properties"], !(properties is [String: Any]) {
            throw PluginManifestError.invalid("tool.inputSchema.properties must be an object")
        }
        if let required = schema["required"] {
            guard let values = required as? [Any], values.allSatisfy({ $0 is String }) else {
                throw PluginManifestError.invalid("tool.inputSchema.required must be an array of strings")
            }
        }
    }

    private static func text(_ value: Any?, field: String) throws -> String {
        guard let string = value as? String else { throw PluginManifestError.invalid("\(field) must be a string") }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 400 else {
            throw PluginManifestError.invalid("\(field) must be 1-400 characters")
        }
        return trimmed
    }

    private static func slug(_ value: Any?, field: String) throws -> String {
        let value = try text(value, field: field)
        guard value.count <= 64,
              let first = value.first, first.isLetter || first.isNumber,
              value.allSatisfy({ $0.isLowercase || $0.isNumber || "-_.".contains($0) }) else {
            throw PluginManifestError.invalid("\(field) must be a lowercase slug (letters, digits, - _ .)")
        }
        return value
    }
}

/// Argument checks against a plugin's declared JSON schema. Deliberately narrow: object schemas
/// with primitive/array/object values, so malformed calls fail before a process starts.
enum PluginInputSchema {
    static func validate(args: [String: Any], schema: [String: Any]) throws {
        let properties = schema["properties"] as? [String: Any] ?? [:]
        if let required = schema["required"] as? [String] {
            for key in required where args[key] == nil {
                throw PluginManifestError.invalid("argument '\(key)' is required")
            }
        }
        if schema["additionalProperties"] as? Bool == false {
            let unknown = args.keys.filter { properties[$0] == nil }
            guard unknown.isEmpty else {
                throw PluginManifestError.invalid("unknown argument(s): \(unknown.sorted().joined(separator: ", "))")
            }
        }
        for (key, value) in args {
            guard let spec = properties[key] as? [String: Any], let type = spec["type"] as? String else { continue }
            guard matches(value, type: type) else {
                throw PluginManifestError.invalid("argument '\(key)' must be \(type)")
            }
        }
    }

    private static func matches(_ value: Any, type: String) -> Bool {
        switch type {
        case "string": value is String
        case "integer": value is Int
        case "number": value is Int || value is Double
        case "boolean": value is Bool
        case "object": value is [String: Any]
        case "array": value is [Any]
        default: true
        }
    }
}
