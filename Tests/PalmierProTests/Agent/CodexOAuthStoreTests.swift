import Foundation
import Testing
@testable import PalmierPro

@Suite("Codex OAuth store")
struct CodexOAuthStoreTests {
    @Test func authorizeURLUsesOfficialCodexPKCEFlow() throws {
        let url = try CodexOAuthStore.authorizeURL(
            redirectURI: "http://localhost:1455/auth/callback",
            pkce: PKCECodes(verifier: "verifier", challenge: "challenge"),
            state: "state-123"
        )
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        #expect(components.scheme == "https")
        #expect(components.host == "auth.openai.com")
        #expect(components.path == "/oauth/authorize")
        #expect(items["response_type"] == "code")
        #expect(items["client_id"] == "app_EMoamEEZ73f0CkXaXp7hrann")
        #expect(items["redirect_uri"] == "http://localhost:1455/auth/callback")
        #expect(items["code_challenge"] == "challenge")
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["state"] == "state-123")
        #expect(items["originator"] == "codex_cli_rs")
        #expect(items["scope"]?.contains("offline_access") == true)
        #expect(items["codex_cli_simplified_flow"] == "true")
    }

    @Test func refreshWindowUsesAccessTokenExpiration() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let fresh = authFile(accessExp: now.addingTimeInterval(10 * 60))
        let expiring = authFile(accessExp: now.addingTimeInterval(4 * 60))

        #expect(CodexOAuthStore.shouldRefresh(file: fresh, now: now) == false)
        #expect(CodexOAuthStore.shouldRefresh(file: expiring, now: now) == true)
    }

    @Test func refreshFallsBackToLastRefreshWhenTokenHasNoExp() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let recent = authFile(accessToken: jwt(payload: ["sub": "user"]), lastRefresh: now.addingTimeInterval(-60))
        let stale = authFile(accessToken: jwt(payload: ["sub": "user"]), lastRefresh: now.addingTimeInterval(-9 * 24 * 60 * 60))

        #expect(CodexOAuthStore.shouldRefresh(file: recent, now: now) == false)
        #expect(CodexOAuthStore.shouldRefresh(file: stale, now: now) == true)
    }

    @Test func authFileEncodingOmitsMissingFields() throws {
        let file = CodexAuthFile(authMode: nil, openAIAPIKey: "sk-test", tokens: nil, lastRefresh: nil)
        let json = String(data: try JSONEncoder().encode(file), encoding: .utf8) ?? ""

        #expect(json.contains("OPENAI_API_KEY"))
        #expect(!json.contains("tokens"))
        #expect(!json.contains("auth_mode"))
        #expect(!json.contains("last_refresh"))
    }

    private func authFile(accessExp: Date) -> CodexAuthFile {
        authFile(accessToken: jwt(payload: ["exp": Int(accessExp.timeIntervalSince1970)]), lastRefresh: Date(timeIntervalSince1970: 1_700_000_000))
    }

    private func authFile(accessToken: String, lastRefresh: Date) -> CodexAuthFile {
        CodexAuthFile(
            authMode: "chatgpt",
            openAIAPIKey: nil,
            tokens: CodexOAuthTokens(
                idToken: nil,
                accessToken: accessToken,
                refreshToken: "refresh",
                accountID: "acct"
            ),
            lastRefresh: iso(lastRefresh)
        )
    }

    private func jwt(payload: [String: Any]) -> String {
        let header = encodedJSON(["alg": "none"])
        let body = encodedJSON(payload)
        return "\(header).\(body).signature"
    }

    private func encodedJSON(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
