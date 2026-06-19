import Foundation

/// Resolves the base URL used for Anthropic Messages API requests.
///
/// Defaults to the official endpoint but can be pointed at any
/// Anthropic-compatible proxy or gateway (VibeProxy, LiteLLM, one-api, …)
/// via the Agent settings field. In DEBUG builds the `ANTHROPIC_BASE_URL`
/// environment variable takes precedence, mirroring `ANTHROPIC_API_KEY`.
enum AnthropicEndpoint {
    static let defaultBaseURL = "https://api.anthropic.com"
    private static let defaultsKey = "anthropicBaseURL"
    private static let messagesPath = "/v1/messages"

    /// The user-configured base URL, or `nil` when the default is in effect.
    static func storedBaseURL() -> String? {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        else { return nil }
        return raw
    }

    /// Persists a custom base URL, or clears it (restoring the default) when blank.
    static func save(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        } else {
            UserDefaults.standard.set(trimmed, forKey: defaultsKey)
        }
    }

    /// The effective base URL: DEBUG env override, then stored value, then default.
    static func resolvedBaseURL() -> String {
        #if DEBUG
        if let env = ProcessInfo.processInfo.environment["ANTHROPIC_BASE_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !env.isEmpty {
            return env
        }
        #endif
        return storedBaseURL() ?? defaultBaseURL
    }

    /// The full Messages API URL for the effective base URL.
    static func resolvedMessagesURL() -> URL {
        messagesURL(base: resolvedBaseURL())
    }

    /// Builds the Messages API URL for a given base, appending `/v1/messages`.
    ///
    /// A blank or malformed base falls back to the official endpoint so a bad
    /// setting can never produce a nil request URL. Trailing slashes on the
    /// base are ignored, matching the `ANTHROPIC_BASE_URL` convention.
    static func messagesURL(base: String) -> URL {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        var root = trimmed.isEmpty ? defaultBaseURL : trimmed
        while root.hasSuffix("/") { root.removeLast() }
        return URL(string: root + messagesPath)
            ?? URL(string: defaultBaseURL + messagesPath)!
    }
}
