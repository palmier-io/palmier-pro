import Foundation
import MCP
import Network

/// HTTP server for MCP. Each TCP connection gets its own `Server` + `Transport` pair.
actor MCPHTTPServer {

    nonisolated static let loopbackHost = "127.0.0.1"

    private nonisolated let port: UInt16
    private nonisolated let bindHost: String
    private nonisolated let bearerToken: String
    private let makeServer: @Sendable () async -> Server
    private nonisolated(unsafe) var listener: NWListener?

    init(
        port: UInt16,
        bindHost: String = MCPHTTPServer.loopbackHost,
        bearerToken: String = "",
        makeServer: @escaping @Sendable () async -> Server
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
            Task { await self.handleConnection(connection) }
        }

        listener?.start(queue: .global(qos: .userInitiated))
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection

    private func handleConnection(_ connection: NWConnection) async {
        let pipeline = Self.validationPipeline(port: port, bindHost: bindHost, bearerToken: bearerToken)
        let transport = StatelessHTTPServerTransport(validationPipeline: pipeline)
        let server = await makeServer()
        try? await server.start(transport: transport)
        receive(on: connection, transport: transport)
    }

    private func receive(on connection: NWConnection, transport: StatelessHTTPServerTransport) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, _, error in
            guard let self, let data, !data.isEmpty, error == nil else {
                connection.cancel(); return
            }
            Task { await self.handle(data: data, connection: connection, transport: transport) }
        }
    }

    private func handle(data: Data, connection: NWConnection, transport: StatelessHTTPServerTransport) async {
        guard let request = parseHTTPRequest(data) else {
            sendRaw("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n", on: connection, keepAlive: false)
            return
        }

        if request.path == "/.well-known/oauth-protected-resource" {
            if let rejection = accessRejection(for: request) {
                writeResponse(rejection, on: connection, transport: transport, keepAlive: false)
                return
            }

            let body = "{\"resource\":\"http://\(Self.advertisedHost(forBindHost: bindHost)):\(port)\"}"
            sendRaw("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)", on: connection, keepAlive: true)
            receive(on: connection, transport: transport)
            return
        }

        guard request.path == "/mcp" || request.path == "/" else {
            sendRaw("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n", on: connection, keepAlive: false)
            return
        }

        if let rejection = accessRejection(for: request) {
            writeResponse(rejection, on: connection, transport: transport, keepAlive: false)
            return
        }

        if request.method.uppercased() == "GET" {
            sendRaw("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n: connected\n\n", on: connection, keepAlive: true)
            return
        }

        let mcpResponse = await transport.handleRequest(request)
        writeResponse(mcpResponse, on: connection, transport: transport)
    }

    private func writeResponse(_ response: HTTPResponse, on connection: NWConnection, transport: StatelessHTTPServerTransport, keepAlive: Bool = true) {
        var head = "HTTP/1.1 \(response.statusCode) \(statusText(response.statusCode))\r\n"
        for (k, v) in response.headers { head += "\(k): \(v)\r\n" }
        head += "Content-Length: \(response.bodyData?.count ?? 0)\r\nConnection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n"

        var responseData = head.data(using: .utf8)!
        if let bodyData = response.bodyData { responseData.append(bodyData) }

        connection.send(content: responseData, completion: .contentProcessed { _ in
            if !keepAlive { connection.cancel() }
        })
        if keepAlive { receive(on: connection, transport: transport) }
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
        case 405: "Method Not Allowed"; case 406: "Not Acceptable"
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
        return StandardValidationPipeline(validators: validators)
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
