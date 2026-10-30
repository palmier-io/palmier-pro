import Foundation
import MCP
import Network

struct MCPServerInstance: Sendable {
    let server: Server
    let onInitialize: @Sendable (Client.Info) async -> Void
}

/// HTTP server for MCP. Each client session gets its own `Server` + stateful transport
actor MCPHTTPServer {

    nonisolated static let loopbackHost = "127.0.0.1"

    private nonisolated let port: UInt16
    private nonisolated let bindHost: String
    private nonisolated let bearerToken: String
    private let makeServer: @Sendable () async -> MCPServerInstance
    private nonisolated(unsafe) var listener: NWListener?

    private struct Session {
        let server: Server
        let transport: StatefulHTTPServerTransport
        var lastUsed: ContinuousClock.Instant
        var toolListAnnounced = false
    }

    private var sessions: [String: Session] = [:]
    private var fallback: (server: Server, transport: StatelessHTTPServerTransport)?
    private static let sessionIdleLimit: Duration = .seconds(3600)
    private static let sessionCountLimit = 32

    init(
        port: UInt16,
        bindHost: String = MCPHTTPServer.loopbackHost,
        bearerToken: String = "",
        makeServer: @escaping @Sendable () async -> MCPServerInstance
    ) {
        self.port = port
        self.bindHost = Self.normalizedBindHost(bindHost)
        self.bearerToken = bearerToken
        self.makeServer = makeServer
    }

    func start() throws {
        Log.mcp.info("listener start host=\(self.bindHost) port=\(self.port)")
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            Log.mcp.fault("invalid port \(self.port)")
            throw NSError(domain: "MCPHTTPServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "invalid port \(port)"])
        }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(bindHost), port: endpointPort)
        listener = try NWListener(using: params)

        listener?.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: .global(qos: .userInitiated))
            Task { await self.receive(on: connection) }
        }

        listener?.start(queue: .global(qos: .userInitiated))
    }

    func stop() {
        listener?.cancel()
        listener = nil
        let closing = sessions.values.map(\.transport)
        sessions.removeAll()
        let fallbackTransport = fallback?.transport
        fallback = nil
        Task {
            for transport in closing { await transport.disconnect() }
            await fallbackTransport?.disconnect()
        }
    }

    // MARK: - Connection

    private func receive(on connection: NWConnection, buffer: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, _, error in
            guard let self, let data, !data.isEmpty, error == nil else {
                connection.cancel(); return
            }
            var buffer = buffer
            buffer.append(data)
            Task { await self.process(buffer: buffer, connection: connection) }
        }
    }

    // A request body can span multiple TCP reads; accumulate until Content-Length is satisfied.
    private func process(buffer: Data, connection: NWConnection) async {
        switch framing(of: buffer) {
        case .needMoreData:
            receive(on: connection, buffer: buffer)
        case .invalid:
            sendRaw("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n", on: connection, keepAlive: false)
        case .complete:
            guard let request = parseHTTPRequest(buffer) else {
                sendRaw("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n", on: connection, keepAlive: false)
                return
            }
            await handle(request: request, connection: connection)
        }
    }

    private enum Framing { case needMoreData, complete, invalid }

    private nonisolated func framing(of data: Data) -> Framing {
        guard data.count <= 16_777_216 else { return .invalid }
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > 65_536 ? .invalid : .needMoreData
        }
        guard let head = String(data: data[data.startIndex..<headerEnd.lowerBound], encoding: .utf8) else {
            return .invalid
        }
        let contentLength = head.components(separatedBy: "\r\n").dropFirst().compactMap { line -> Int? in
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" else { return nil }
            return Int(parts[1].trimmingCharacters(in: .whitespaces))
        }.first ?? 0
        let bodyBytes = data.distance(from: headerEnd.upperBound, to: data.endIndex)
        return bodyBytes >= contentLength ? .complete : .needMoreData
    }

    // MARK: - Routing

    private func handle(request: HTTPRequest, connection: NWConnection) async {
        if request.path == "/.well-known/oauth-protected-resource" {
            if let rejection = accessRejection(for: request) {
                writeResponse(rejection, on: connection, keepAlive: false)
                return
            }

            let body = "{\"resource\":\"http://\(Self.advertisedHost(forBindHost: bindHost)):\(port)\"}"
            sendRaw("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)", on: connection, keepAlive: true)
            receive(on: connection)
            return
        }

        guard request.path == "/mcp" || request.path == "/" else {
            sendRaw("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n", on: connection, keepAlive: false)
            return
        }

        if let rejection = accessRejection(for: request) {
            writeResponse(rejection, on: connection, keepAlive: false)
            return
        }

        let response: HTTPResponse
        if let claimed = request.header(HTTPHeaderName.sessionID) {
            guard var session = sessions[claimed] else {
                // Unknown/expired session → 404 per spec; the client re-initializes
                // and refreshes its tool inventory.
                sendRaw("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n", on: connection, keepAlive: true)
                receive(on: connection)
                return
            }
            session.lastUsed = .now
            sessions[claimed] = session
            response = await session.transport.handleRequest(request)
            if request.method.uppercased() == "DELETE", response.statusCode == 200 {
                sessions.removeValue(forKey: claimed)
            } else if request.method.uppercased() == "GET", response.statusCode == 200 {
                announceToolList(sessionID: claimed)
            }
        } else if isInitialize(request) {
            let transport = StatefulHTTPServerTransport(
                validationPipeline: StandardValidationPipeline(validators: baseValidators() + [SessionValidator()])
            )
            let instance = await makeServer()
            try? await instance.server.start(transport: transport) { clientInfo, _ in
                await instance.onInitialize(clientInfo)
            }
            response = await transport.handleRequest(request)
            if let assigned = response.headers[HTTPHeaderName.sessionID] {
                pruneIdleSessions()
                sessions[assigned] = Session(server: instance.server, transport: transport, lastUsed: .now)
                Log.mcp.notice("session started id=\(assigned) total=\(self.sessions.count)")
            } else {
                await transport.disconnect()
            }
        } else {
            // Sessionless clients (and plain curl) get simple request/response semantics.
            response = await fallbackPair().transport.handleRequest(request)
        }
        writeResponse(response, on: connection)
    }

    private func announceToolList(sessionID: String) {
        guard var session = sessions[sessionID], !session.toolListAnnounced else { return }
        session.toolListAnnounced = true
        sessions[sessionID] = session
        let server = session.server
        Task {
            do {
                try await server.notify(ToolListChangedNotification.message())
            } catch {
                Log.mcp.warning("tool list_changed notify failed id=\(sessionID): \(error.localizedDescription)")
                await self.resetToolListAnnouncement(sessionID: sessionID)
            }
        }
    }

    // A failed announce retries on the next GET-stream attach.
    private func resetToolListAnnouncement(sessionID: String) {
        guard var session = sessions[sessionID] else { return }
        session.toolListAnnounced = false
        sessions[sessionID] = session
    }

    private nonisolated func isInitialize(_ request: HTTPRequest) -> Bool {
        guard request.method.uppercased() == "POST", let body = request.body,
              let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return false }
        return json["method"] as? String == "initialize"
    }

    private nonisolated func baseValidators() -> [any HTTPRequestValidator] {
        Self.validators(port: port, bindHost: bindHost, bearerToken: bearerToken)
    }

    private func fallbackPair() async -> (server: Server, transport: StatelessHTTPServerTransport) {
        if let fallback { return fallback }
        let pipeline = StandardValidationPipeline(validators: baseValidators())
        let instance = await makeServer()
        let pair = (server: instance.server, transport: StatelessHTTPServerTransport(validationPipeline: pipeline))
        try? await pair.server.start(transport: pair.transport) { clientInfo, _ in
            await instance.onInitialize(clientInfo)
        }
        fallback = pair
        return pair
    }

    // Evicted clients recover transparently: their next request gets 404 and they re-initialize.
    private func pruneIdleSessions() {
        let cutoff = ContinuousClock.now - Self.sessionIdleLimit
        for (id, session) in sessions where session.lastUsed < cutoff {
            evictSession(id: id)
        }
        while sessions.count >= Self.sessionCountLimit,
              let oldest = sessions.min(by: { $0.value.lastUsed < $1.value.lastUsed }) {
            evictSession(id: oldest.key)
        }
    }

    private func evictSession(id: String) {
        guard let session = sessions.removeValue(forKey: id) else { return }
        Log.mcp.notice("session evicted id=\(id)")
        Task { await session.transport.disconnect() }
    }

    // MARK: - Response writing

    private func writeResponse(_ response: HTTPResponse, on connection: NWConnection, keepAlive: Bool = true) {
        if case .stream(let stream, let headers) = response {
            // SSE has no Content-Length; close the connection to delimit the body.
            var head = "HTTP/1.1 200 OK\r\n"
            for (k, v) in headers where k.lowercased() != "connection" { head += "\(k): \(v)\r\n" }
            head += "Connection: close\r\n\r\n"
            connection.send(content: head.data(using: .utf8), completion: .contentProcessed { _ in })
            Task {
                do {
                    for try await chunk in stream {
                        connection.send(content: chunk, completion: .contentProcessed { _ in })
                    }
                } catch {}
                connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
            return
        }

        var head = "HTTP/1.1 \(response.statusCode) \(statusText(response.statusCode))\r\n"
        for (k, v) in response.headers { head += "\(k): \(v)\r\n" }
        head += "Content-Length: \(response.bodyData?.count ?? 0)\r\nConnection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n"

        var responseData = head.data(using: .utf8)!
        if let bodyData = response.bodyData { responseData.append(bodyData) }

        connection.send(content: responseData, completion: .contentProcessed { _ in
            if !keepAlive { connection.cancel() }
        })
        if keepAlive { receive(on: connection) }
    }

    private nonisolated func accessRejection(for request: HTTPRequest) -> HTTPResponse? {
        guard Self.requiresBearerToken(bindHost: bindHost) else { return nil }
        return MCPBearerTokenValidator(expectedToken: bearerToken)
            .validate(request, context: .init(httpMethod: request.method.uppercased()))
    }

    // MARK: - HTTP Parsing

    private nonisolated func parseHTTPRequest(_ data: Data) -> HTTPRequest? {
        guard let string = String(data: data, encoding: .utf8) else { return nil }
        let parts = string.components(separatedBy: "\r\n\r\n")
        guard let headerSection = parts.first else { return nil }
        let lines = headerSection.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let tokens = requestLine.split(separator: " ", maxSplits: 2)
        guard tokens.count >= 2 else { return nil }

        let method = String(tokens[0])
        let rawPath = String(tokens[1])
        let path = rawPath.split(separator: "?").first.map(String.init) ?? rawPath

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let bodyString = parts.dropFirst().joined(separator: "\r\n\r\n")
        let body = bodyString.isEmpty ? nil : bodyString.data(using: .utf8)
        return HTTPRequest(method: method, headers: headers, body: body, path: path)
    }

    private nonisolated func sendRaw(_ string: String, on connection: NWConnection, keepAlive: Bool) {
        connection.send(content: string.data(using: .utf8), completion: .contentProcessed { _ in
            if !keepAlive { connection.cancel() }
        })
    }

    private nonisolated func statusText(_ code: Int) -> String {
        switch code {
        case 200: "OK"; case 202: "Accepted"; case 400: "Bad Request"
        case 401: "Unauthorized"; case 403: "Forbidden"; case 404: "Not Found"
        case 405: "Method Not Allowed"; case 406: "Not Acceptable"; case 409: "Conflict"
        case 415: "Unsupported Media Type"; case 421: "Misdirected Request"
        case 500: "Internal Server Error"
        default: "Unknown"
        }
    }

    // MARK: - Binding and validation

    nonisolated static func normalizedBindHost(_ host: String) -> String {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return loopbackHost }
        guard trimmed == "localhost" || isValidIPv4Host(trimmed) else { return loopbackHost }
        return trimmed
    }

    nonisolated static func requiresBearerToken(bindHost: String) -> Bool {
        !isLoopbackHost(normalizedBindHost(bindHost))
    }

    nonisolated static func advertisedHost(forBindHost bindHost: String) -> String {
        let host = normalizedBindHost(bindHost)
        guard host == "0.0.0.0" else { return host }
        let hostName = ProcessInfo.processInfo.hostName
        return hostName.isEmpty ? host : hostName
    }

    nonisolated static func validationPipeline(port: UInt16, bindHost: String, bearerToken: String) -> StandardValidationPipeline {
        StandardValidationPipeline(validators: validators(port: port, bindHost: bindHost, bearerToken: bearerToken))
    }

    nonisolated static func validators(port: UInt16, bindHost: String, bearerToken: String) -> [any HTTPRequestValidator] {
        let host = normalizedBindHost(bindHost)
        var validators: [any HTTPRequestValidator] = []
        if requiresBearerToken(bindHost: host) {
            validators.append(MCPBearerTokenValidator(expectedToken: bearerToken))
            validators.append(OriginValidator.disabled)
        } else {
            validators.append(OriginValidator.localhost(port: Int(port)))
        }
        validators.append(ContentTypeValidator())
        validators.append(ProtocolVersionValidator())
        return validators
    }

    private nonisolated static func isLoopbackHost(_ host: String) -> Bool {
        host == loopbackHost || host == "localhost"
    }

    private nonisolated static func isValidIPv4Host(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard !part.isEmpty, part.allSatisfy(\.isNumber), let octet = Int(part) else { return false }
            return (0...255).contains(octet)
        }
    }
}

struct MCPBearerTokenValidator: HTTPRequestValidator {
    let expectedToken: String

    func validate(_ request: HTTPRequest, context: HTTPValidationContext) -> HTTPResponse? {
        guard let authorization = request.header("Authorization"),
              let token = bearerToken(from: authorization),
              tokenMatches(token) else {
            return unauthorizedResponse(sessionID: context.sessionID)
        }
        return nil
    }

    private func bearerToken(from header: String) -> String? {
        let parts = header.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
        guard parts.count == 2, String(parts[0]).caseInsensitiveCompare("Bearer") == .orderedSame else {
            return nil
        }
        let token = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !token.contains(where: \.isWhitespace) else { return nil }
        return token
    }

    private func tokenMatches(_ token: String) -> Bool {
        let expected = Array(expectedToken.utf8)
        let actual = Array(token.utf8)
        var difference = expected.count ^ actual.count
        for index in 0..<max(expected.count, actual.count) {
            let lhs = index < expected.count ? expected[index] : 0
            let rhs = index < actual.count ? actual[index] : 0
            difference |= Int(lhs ^ rhs)
        }
        return difference == 0
    }

    private func unauthorizedResponse(sessionID: String?) -> HTTPResponse {
        .error(
            statusCode: 401,
            .invalidRequest("Unauthorized"),
            sessionID: sessionID,
            extraHeaders: ["WWW-Authenticate": "Bearer"]
        )
    }
}
