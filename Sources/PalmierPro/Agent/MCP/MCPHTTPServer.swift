import Foundation
import MCP
import Network

struct MCPServerInstance: Sendable {
    let server: Server
    let onInitialize: @Sendable (Client.Info) async -> Void
}

/// HTTP server for MCP. Each client session gets its own `Server` + stateful transport
actor MCPHTTPServer {

    private let port: UInt16
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
        makeServer: @escaping @Sendable () async -> MCPServerInstance
    ) {
        self.port = port
        self.makeServer = makeServer
    }

    func start() throws {
        Log.mcp.info("listener start port=\(self.port)")
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            Log.mcp.fault("invalid port \(self.port)")
            throw NSError(domain: "MCPHTTPServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "invalid port \(port)"])
        }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Bind to IPv4 loopback only so the server is never reachable from the LAN.
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: endpointPort)
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
            let body = "{\"resource\":\"http://127.0.0.1:\(port)\"}"
            sendRaw("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)", on: connection, keepAlive: true)
            receive(on: connection)
            return
        }

        if let path = request.path, path.hasPrefix("/preview/") {
            await handlePreview(request: request, path: path, connection: connection)
            return
        }

        guard request.path == "/mcp" || request.path == "/" else {
            sendRaw("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n", on: connection, keepAlive: false)
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
        [OriginValidator.localhost(port: Int(port)), ContentTypeValidator(), ProtocolVersionValidator()]
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

    private func handlePreview(request: HTTPRequest, path: String, connection: NWConnection) async {
        let cors = [
            "Access-Control-Allow-Origin: *",
            "Access-Control-Allow-Methods: GET, HEAD, OPTIONS",
            "Access-Control-Allow-Headers: Range",
            "Access-Control-Expose-Headers: Accept-Ranges, Content-Range, Content-Length, Content-Type",
        ].joined(separator: "\r\n") + "\r\n"
        let method = request.method.uppercased()
        if method == "OPTIONS" {
            sendRaw(
                "HTTP/1.1 204 No Content\r\n\(cors)Content-Length: 0\r\n\r\n",
                on: connection,
                keepAlive: true
            )
            receive(on: connection)
            return
        }
        guard method == "GET" || method == "HEAD" else {
            sendRaw(
                "HTTP/1.1 405 Method Not Allowed\r\n\(cors)Allow: GET, HEAD, OPTIONS\r\nContent-Length: 0\r\n\r\n",
                on: connection,
                keepAlive: false
            )
            return
        }

        let token = String(path.dropFirst("/preview/".count))
        guard UUID(uuidString: token) != nil, let item = await MCPPreviewStore.shared.item(for: token) else {
            sendRaw("HTTP/1.1 404 Not Found\r\n\(cors)Content-Length: 0\r\n\r\n", on: connection, keepAlive: false)
            return
        }
        let fileURL = item.url
        let mimeType = item.mimeType
        let size: UInt64
        do {
            size = try await Task.detached(priority: .utility) {
                let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard values.isRegularFile == true, let fileSize = values.fileSize, fileSize >= 0 else {
                    throw CocoaError(.fileNoSuchFile)
                }
                return UInt64(fileSize)
            }.value
        } catch {
            sendRaw("HTTP/1.1 404 Not Found\r\n\(cors)Content-Length: 0\r\n\r\n", on: connection, keepAlive: false)
            return
        }

        let byteRange: (start: UInt64, endInclusive: UInt64, status: Int, extra: String)
        if let header = request.header("Range"), let parsed = Self.parseBytesRange(header, size: size) {
            let endInclusive = parsed.upperBound - 1
            byteRange = (
                parsed.lowerBound,
                endInclusive,
                206,
                "Content-Range: bytes \(parsed.lowerBound)-\(endInclusive)/\(size)\r\n"
            )
        } else if request.header("Range") != nil, size > 0 {
            sendRaw(
                "HTTP/1.1 416 Range Not Satisfiable\r\n\(cors)Content-Range: bytes */\(size)\r\nContent-Length: 0\r\n\r\n",
                on: connection,
                keepAlive: false
            )
            return
        } else {
            byteRange = (0, size == 0 ? 0 : size - 1, 200, "")
        }
        let length: UInt64 = size == 0 ? 0 : (byteRange.endInclusive - byteRange.start + 1)
        guard length <= UInt64(Int.max) else {
            sendRaw("HTTP/1.1 500 Internal Server Error\r\n\(cors)Content-Length: 0\r\n\r\n", on: connection, keepAlive: false)
            return
        }

        var head = "HTTP/1.1 \(byteRange.status) \(statusText(byteRange.status))\r\n"
        head += cors
        head += "Content-Type: \(mimeType)\r\n"
        head += "Accept-Ranges: bytes\r\n"
        head += byteRange.extra
        head += "Content-Length: \(length)\r\n"
        head += "Cache-Control: private, max-age=60\r\n"
        head += "Connection: keep-alive\r\n\r\n"

        if method == "HEAD" || length == 0 {
            sendRaw(head, on: connection, keepAlive: true)
            receive(on: connection)
            return
        }

        let body: Data
        do {
            let start = byteRange.start
            body = try await Task.detached(priority: .utility) {
                let handle = try FileHandle(forReadingFrom: fileURL)
                defer { try? handle.close() }
                try handle.seek(toOffset: start)
                return try handle.read(upToCount: Int(length)) ?? Data()
            }.value
        } catch {
            sendRaw("HTTP/1.1 500 Internal Server Error\r\n\(cors)Content-Length: 0\r\n\r\n", on: connection, keepAlive: false)
            return
        }

        var responseData = Data(head.utf8)
        responseData.append(body)
        connection.send(content: responseData, completion: .contentProcessed { _ in })
        receive(on: connection)
    }

    private nonisolated static func parseBytesRange(_ header: String, size: UInt64) -> Range<UInt64>? {
        guard size > 0 else { return nil }
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("bytes=") else { return nil }
        let spec = String(trimmed.dropFirst(6)).split(separator: ",", maxSplits: 1)[0]
            .trimmingCharacters(in: .whitespaces)
        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        if parts[0].isEmpty {
            guard let suffix = UInt64(parts[1]), suffix > 0 else { return nil }
            let start = size > suffix ? size - suffix : 0
            return start..<size
        }
        guard let start = UInt64(parts[0]), start < size else { return nil }
        if parts[1].isEmpty {
            return start..<size
        }
        guard let end = UInt64(parts[1]), end >= start else { return nil }
        return start..<(min(end, size - 1) + 1)
    }

    private func writeResponse(_ response: HTTPResponse, on connection: NWConnection) {
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
        head += "Content-Length: \(response.bodyData?.count ?? 0)\r\nConnection: keep-alive\r\n\r\n"

        var responseData = head.data(using: .utf8)!
        if let bodyData = response.bodyData { responseData.append(bodyData) }

        connection.send(content: responseData, completion: .contentProcessed { _ in })
        receive(on: connection)
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
        case 200: "OK"; case 202: "Accepted"; case 204: "No Content"
        case 206: "Partial Content"; case 400: "Bad Request"
        case 404: "Not Found"; case 405: "Method Not Allowed"; case 409: "Conflict"
        case 416: "Range Not Satisfiable"; case 500: "Internal Server Error"
        default: "Unknown"
        }
    }
}
