import Foundation
import MCP
import Network

/// HTTP server for MCP. Each TCP connection gets its own `Server` + `Transport` pair.
actor MCPHTTPServer {

    private let port: UInt16
    private let makeServer: @Sendable () async -> Server
    private nonisolated(unsafe) var listener: NWListener?

    init(port: UInt16, makeServer: @escaping @Sendable () async -> Server) {
        self.port = port
        self.makeServer = makeServer
    }

    func start() throws {
        Log.mcp.info("listener start port=\(self.port)")
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            Log.mcp.fault("invalid port \(self.port)")
            throw NSError(domain: "MCPHTTPServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "invalid port \(port)"])
        }
        listener = try NWListener(using: params, on: endpointPort)

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
        let pipeline = StandardValidationPipeline(validators: [
            OriginValidator.disabled,
            ContentTypeValidator(),
            ProtocolVersionValidator(),
        ])
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
            let body = "{\"resource\":\"http://127.0.0.1:\(port)\"}"
            sendRaw("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)", on: connection, keepAlive: true)
            receive(on: connection, transport: transport)
            return
        }

        guard request.path == "/mcp" || request.path == "/" else {
            sendRaw("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n", on: connection, keepAlive: false)
            return
        }

        if request.method.uppercased() == "GET" {
            sendRaw("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n: connected\n\n", on: connection, keepAlive: true)
            return
        }

        let mcpResponse = await transport.handleRequest(request)
        writeResponse(mcpResponse, on: connection, transport: transport)
    }

    private func writeResponse(_ response: HTTPResponse, on connection: NWConnection, transport: StatelessHTTPServerTransport) {
        var head = "HTTP/1.1 \(response.statusCode) \(statusText(response.statusCode))\r\n"
        for (k, v) in response.headers { head += "\(k): \(v)\r\n" }
        head += "Content-Length: \(response.bodyData?.count ?? 0)\r\nConnection: keep-alive\r\n\r\n"

        var responseData = head.data(using: .utf8)!
        if let bodyData = response.bodyData { responseData.append(bodyData) }

        connection.send(content: responseData, completion: .contentProcessed { _ in })
        receive(on: connection, transport: transport)
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
        case 404: "Not Found"; case 405: "Method Not Allowed"; case 500: "Internal Server Error"
        default: "Unknown"
        }
    }
}
