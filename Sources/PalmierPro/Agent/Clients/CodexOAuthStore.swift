import AppKit
import CryptoKit
import Foundation
import Security

enum CodexOAuthStore {
    private static let issuer = "https://auth.openai.com"
    private static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private static let originator = "codex_cli_rs"
    private static let refreshWindow: TimeInterval = 5 * 60
    private static let refreshInterval: TimeInterval = 8 * 24 * 60 * 60
    private static let preferredPorts: [UInt16] = [1455, 1457]

    private static var authFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("auth.json", isDirectory: false)
    }

    static func cachedAccessToken() -> String? {
        loadAuthFile()?.tokens?.accessToken
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    static func accessToken(refreshIfNeeded: Bool) async throws -> String {
        guard var file = loadAuthFile(),
              let tokens = file.tokens,
              tokens.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty != nil
        else { throw CodexOAuthError.missingSession }

        if refreshIfNeeded && shouldRefresh(file: file) {
            file = try await refreshAuthFile(file)
            NotificationCenter.default.post(name: .codexOAuthAgentSettingsChanged, object: nil)
        }

        guard let token = file.tokens?.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        else { throw CodexOAuthError.missingSession }
        return token
    }

    static func status() -> CodexOAuthStatus {
        guard let file = loadAuthFile() else {
            return CodexOAuthStatus(
                hasAccessToken: false,
                hasRefreshToken: false,
                accountID: nil,
                authMode: nil,
                lastRefresh: nil,
                expiresAt: nil,
                errorMessage: nil
            )
        }

        let accessToken = file.tokens?.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let refreshToken = file.tokens?.refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        return CodexOAuthStatus(
            hasAccessToken: accessToken != nil,
            hasRefreshToken: refreshToken != nil,
            accountID: file.tokens?.accountID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            authMode: file.authMode?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            lastRefresh: file.lastRefresh?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            expiresAt: accessToken.flatMap(jwtExpirationDate),
            errorMessage: nil
        )
    }

    static func signIn() async throws -> CodexOAuthStatus {
        let pkce = try makePKCE()
        let state = try randomBase64URL(byteCount: 32)
        let server = try CodexOAuthLoopbackServer(preferredPorts: preferredPorts)
        let redirectURI = "http://localhost:\(server.port)/auth/callback"
        let url = try authorizeURL(redirectURI: redirectURI, pkce: pkce, state: state)
        defer { server.close() }

        _ = await MainActor.run {
            NSWorkspace.shared.open(url)
        }

        let callback = try await server.waitForCallback()
        guard callback.state == state else { throw CodexOAuthError.stateMismatch }
        if let error = callback.error {
            throw CodexOAuthError.authorizationFailed(error)
        }
        guard let code = callback.code?.trimmingCharacters(in: .whitespacesAndNewlines), !code.isEmpty
        else { throw CodexOAuthError.missingAuthorizationCode }

        let file = try await exchangeCode(code, redirectURI: redirectURI, codeVerifier: pkce.verifier)
        try saveAuthFile(file)
        NotificationCenter.default.post(name: .codexOAuthAgentSettingsChanged, object: nil)
        return status()
    }

    static func refreshStoredToken() async throws -> CodexOAuthStatus {
        guard let file = loadAuthFile() else { throw CodexOAuthError.missingSession }
        _ = try await refreshAuthFile(file)
        NotificationCenter.default.post(name: .codexOAuthAgentSettingsChanged, object: nil)
        return status()
    }

    static func signOut() throws {
        if let existing = loadAuthFile(),
           let apiKey = existing.openAIAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            try saveAuthFile(CodexAuthFile(authMode: nil, openAIAPIKey: apiKey, tokens: nil, lastRefresh: nil))
        } else if FileManager.default.fileExists(atPath: authFileURL.path) {
            try FileManager.default.removeItem(at: authFileURL)
        }
        NotificationCenter.default.post(name: .codexOAuthAgentSettingsChanged, object: nil)
    }

    static func authorizeURL(redirectURI: String, pkce: PKCECodes, state: String) throws -> URL {
        var components = URLComponents(string: "\(issuer)/oauth/authorize")
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: "openid profile email offline_access api.connectors.read api.connectors.invoke"),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "originator", value: originator),
        ]
        guard let url = components?.url else { throw CodexOAuthError.invalidAuthorizeURL }
        return url
    }

    static func shouldRefresh(file: CodexAuthFile, now: Date = Date()) -> Bool {
        if let accessToken = file.tokens?.accessToken,
           let expiresAt = jwtExpirationDate(accessToken) {
            return expiresAt <= now.addingTimeInterval(refreshWindow)
        }
        guard let lastRefresh = file.lastRefresh.flatMap(isoDate(from:)) else { return false }
        return lastRefresh < now.addingTimeInterval(-refreshInterval)
    }

    static func jwtExpirationDate(_ token: String) -> Date? {
        jwtClaims(token)["exp"].flatMap { value in
            if let double = value as? Double { return Date(timeIntervalSince1970: double) }
            if let int = value as? Int { return Date(timeIntervalSince1970: TimeInterval(int)) }
            return nil
        }
    }

    private static func refreshAuthFile(_ file: CodexAuthFile) async throws -> CodexAuthFile {
        guard let refreshToken = file.tokens?.refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        else { throw CodexOAuthError.missingRefreshToken }

        var request = URLRequest(url: URL(string: "\(issuer)/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        applyCodexHeaders(to: &request)
        request.httpBody = try JSONSerialization.data(
            withJSONObject: [
                "client_id": clientID,
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
            ],
            options: [.sortedKeys]
        )

        let response = try await tokenResponse(for: request)
        guard response.accessToken != nil || response.idToken != nil || response.refreshToken != nil
        else { throw CodexOAuthError.emptyTokenResponse }

        let existingTokens = file.tokens
        let idToken = response.idToken ?? existingTokens?.idToken
        let accessToken = response.accessToken ?? existingTokens?.accessToken
        let updatedRefreshToken = response.refreshToken ?? existingTokens?.refreshToken
        guard let accessToken, let updatedRefreshToken else { throw CodexOAuthError.emptyTokenResponse }

        let updated = CodexAuthFile(
            authMode: "chatgpt",
            openAIAPIKey: file.openAIAPIKey,
            tokens: CodexOAuthTokens(
                idToken: idToken,
                accessToken: accessToken,
                refreshToken: updatedRefreshToken,
                accountID: accountID(idToken: idToken, accessToken: accessToken) ?? existingTokens?.accountID
            ),
            lastRefresh: isoDateString(Date())
        )
        try saveAuthFile(updated)
        return updated
    }

    private static func exchangeCode(_ code: String, redirectURI: String, codeVerifier: String) async throws -> CodexAuthFile {
        var request = URLRequest(url: URL(string: "\(issuer)/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")
        applyCodexHeaders(to: &request)
        request.httpBody = formBody([
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", redirectURI),
            ("client_id", clientID),
            ("code_verifier", codeVerifier),
        ])

        let response = try await tokenResponse(for: request)
        guard let idToken = response.idToken,
              let accessToken = response.accessToken,
              let refreshToken = response.refreshToken
        else { throw CodexOAuthError.emptyTokenResponse }

        let existing = loadAuthFile()
        return CodexAuthFile(
            authMode: "chatgpt",
            openAIAPIKey: existing?.openAIAPIKey,
            tokens: CodexOAuthTokens(
                idToken: idToken,
                accessToken: accessToken,
                refreshToken: refreshToken,
                accountID: accountID(idToken: idToken, accessToken: accessToken)
            ),
            lastRefresh: isoDateString(Date())
        )
    }

    private static func tokenResponse(for request: URLRequest) async throws -> TokenEndpointResponse {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CodexOAuthError.invalidHTTPResponse }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw CodexOAuthError.httpStatus(http.statusCode, body)
        }
        return try JSONDecoder().decode(TokenEndpointResponse.self, from: data)
    }

    private static func saveAuthFile(_ file: CodexAuthFile) throws {
        let directory = authFileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(file)
        try data.write(to: authFileURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authFileURL.path)
    }

    private static func loadAuthFile() -> CodexAuthFile? {
        guard let data = try? Data(contentsOf: authFileURL) else { return nil }
        return try? JSONDecoder().decode(CodexAuthFile.self, from: data)
    }

    private static func accountID(idToken: String?, accessToken: String) -> String? {
        if let idToken,
           let accountID = authClaims(idToken)["chatgpt_account_id"] as? String {
            return accountID
        }
        return authClaims(accessToken)["chatgpt_account_id"] as? String
    }

    private static func authClaims(_ jwt: String) -> [String: Any] {
        if let auth = jwtClaims(jwt)["https://api.openai.com/auth"] as? [String: Any] {
            return auth
        }
        return jwtClaims(jwt)
    }

    private static func jwtClaims(_ token: String) -> [String: Any] {
        let parts = token.split(separator: ".")
        guard parts.count >= 2,
              let data = Data(base64URLEncoded: String(parts[1])),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    private static func makePKCE() throws -> PKCECodes {
        let verifier = try randomBase64URL(byteCount: 64)
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return PKCECodes(verifier: verifier, challenge: Data(digest).base64URLEncodedString)
    }

    private static func randomBase64URL(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        guard status == errSecSuccess else { throw CodexOAuthError.randomFailed }
        return Data(bytes).base64URLEncodedString
    }

    private static func applyCodexHeaders(to request: inout URLRequest) {
        request.setValue(originator, forHTTPHeaderField: "originator")
        request.setValue(codexUserAgent, forHTTPHeaderField: "user-agent")
    }

    private static var codexUserAgent: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        let os = "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
        return "\(originator)/\(version) (Mac OS \(os); arm64) PalmierPro"
    }

    private static func formBody(_ fields: [(String, String)]) -> Data {
        fields
            .map { "\(formEscape($0.0))=\(formEscape($0.1))" }
            .joined(separator: "&")
            .data(using: .utf8) ?? Data()
    }

    private static func formEscape(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ":#[]@!$&'()*+,;=")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func isoDate(from string: String) -> Date? {
        makeISODateFormatter().date(from: string)
    }

    private static func isoDateString(_ date: Date) -> String {
        makeISODateFormatter().string(from: date)
    }

    private static func makeISODateFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}

struct PKCECodes: Equatable, Sendable {
    let verifier: String
    let challenge: String
}

struct CodexAuthFile: Codable, Equatable, Sendable {
    var authMode: String?
    var openAIAPIKey: String?
    var tokens: CodexOAuthTokens?
    var lastRefresh: String?

    enum CodingKeys: String, CodingKey {
        case authMode = "auth_mode"
        case openAIAPIKey = "OPENAI_API_KEY"
        case tokens
        case lastRefresh = "last_refresh"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(authMode, forKey: .authMode)
        try container.encodeIfPresent(openAIAPIKey, forKey: .openAIAPIKey)
        try container.encodeIfPresent(tokens, forKey: .tokens)
        try container.encodeIfPresent(lastRefresh, forKey: .lastRefresh)
    }
}

struct CodexOAuthTokens: Codable, Equatable, Sendable {
    var idToken: String?
    var accessToken: String
    var refreshToken: String
    var accountID: String?

    enum CodingKeys: String, CodingKey {
        case idToken = "id_token"
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case accountID = "account_id"
    }
}

private struct TokenEndpointResponse: Decodable {
    var idToken: String?
    var accessToken: String?
    var refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case idToken = "id_token"
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
    }
}

private struct CodexOAuthCallback {
    var code: String?
    var state: String?
    var error: String?
}

enum CodexOAuthError: LocalizedError, Equatable {
    case authorizationFailed(String)
    case emptyTokenResponse
    case httpStatus(Int, String)
    case invalidAuthorizeURL
    case invalidCallback
    case invalidHTTPResponse
    case missingAuthorizationCode
    case missingRefreshToken
    case missingSession
    case randomFailed
    case stateMismatch
    case timeout

    var errorDescription: String? {
        switch self {
        case .authorizationFailed(let message): "Authorization failed: \(message)"
        case .emptyTokenResponse: "Codex OAuth did not return usable tokens."
        case .httpStatus(let status, let body): "Codex OAuth returned \(status): \(body.prefix(500))"
        case .invalidAuthorizeURL: "Codex OAuth authorize URL could not be built."
        case .invalidCallback: "Codex OAuth callback was invalid."
        case .invalidHTTPResponse: "Codex OAuth returned an invalid HTTP response."
        case .missingAuthorizationCode: "Codex OAuth callback did not include an authorization code."
        case .missingRefreshToken: "Codex OAuth refresh token is missing."
        case .missingSession: "Codex OAuth session is missing."
        case .randomFailed: "Codex OAuth could not generate secure random data."
        case .stateMismatch: "Codex OAuth callback state did not match."
        case .timeout: "Codex OAuth sign-in timed out."
        }
    }
}

private final class CodexOAuthLoopbackServer {
    let port: UInt16
    private var fileDescriptor: Int32?

    init(preferredPorts: [UInt16]) throws {
        var lastError: Error?
        for port in preferredPorts {
            do {
                self.fileDescriptor = try Self.bind(port: port)
                self.port = port
                return
            } catch {
                lastError = error
            }
        }
        throw lastError ?? CodexOAuthError.invalidCallback
    }

    func waitForCallback() async throws -> CodexOAuthCallback {
        guard let fd = fileDescriptor else { throw CodexOAuthError.invalidCallback }
        let port = port
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try Self.receiveCallback(fileDescriptor: fd, port: port))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func close() {
        if let fd = fileDescriptor {
            Darwin.close(fd)
            fileDescriptor = nil
        }
    }

    deinit {
        close()
    }

    private static func bind(port: UInt16) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard listen(fd, 1) == 0 else {
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return fd
    }

    private static func receiveCallback(fileDescriptor fd: Int32, port: UInt16) throws -> CodexOAuthCallback {
        var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let pollResult = poll(&pollFD, 1, 5 * 60 * 1000)
        guard pollResult > 0 else { throw CodexOAuthError.timeout }

        let clientFD = accept(fd, nil, nil)
        guard clientFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(clientFD) }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.range(of: Data("\r\n\r\n".utf8)) == nil {
            let count = recv(clientFD, &buffer, buffer.count, 0)
            guard count > 0 else { break }
            data.append(buffer, count: count)
            if data.count > 64 * 1024 { break }
        }

        guard let request = String(data: data, encoding: .utf8),
              let callback = parseCallbackRequest(request, port: port)
        else {
            sendResponse("Bad Request", status: "400 Bad Request", to: clientFD)
            throw CodexOAuthError.invalidCallback
        }

        sendResponse("Codex sign-in complete. Return to Palmier Pro.", status: "200 OK", to: clientFD)
        return callback
    }

    private static func parseCallbackRequest(_ request: String, port: UInt16) -> CodexOAuthCallback? {
        guard let firstLine = request.components(separatedBy: "\r\n").first else { return nil }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let target = String(parts[1])
        guard let components = URLComponents(string: "http://localhost:\(port)\(target)"),
              components.path == "/auth/callback"
        else { return nil }
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        return CodexOAuthCallback(code: items["code"], state: items["state"], error: items["error"] ?? items["error_description"])
    }

    private static func sendResponse(_ body: String, status: String, to fd: Int32) {
        let html = "<!doctype html><html><body>\(body)</body></html>"
        let response = """
        HTTP/1.1 \(status)\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(html.utf8.count)\r
        Connection: close\r
        \r
        \(html)
        """
        var bytes = Array(response.utf8)
        bytes.withUnsafeMutableBufferPointer { pointer in
            guard var base = pointer.baseAddress else { return }
            var remaining = pointer.count
            while remaining > 0 {
                let sent = Darwin.send(fd, base, remaining, 0)
                guard sent > 0 else { return }
                base = base.advanced(by: sent)
                remaining -= sent
            }
        }
    }
}

private extension Data {
    init?(base64URLEncoded value: String) {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - base64.count % 4) % 4
        base64.append(String(repeating: "=", count: padding))
        self.init(base64Encoded: base64)
    }

    var base64URLEncodedString: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
