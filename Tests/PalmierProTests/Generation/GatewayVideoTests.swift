import Foundation
import Testing
@testable import PalmierPro

/// URLProtocol stub scripting the bridge's three video URLs.
final class VideoBridgeStub: URLProtocol {
    struct Call: Sendable { let method: String; let path: String; let contentType: String? }
    nonisolated(unsafe) static var calls: [Call] = []
    nonisolated(unsafe) static var statusScript: [String] = []   // consumed per GET /videos/{id}
    nonisolated(unsafe) static var videoBytes = Data("MP4BYTES".utf8)
    private static let lock = NSLock()

    static func reset(script: [String]) {
        lock.lock(); defer { lock.unlock() }
        calls = []
        statusScript = script
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "stub.test"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let path = request.url?.path ?? ""
        Self.calls.append(.init(
            method: request.httpMethod ?? "?", path: path,
            contentType: request.value(forHTTPHeaderField: "content-type")
        ))
        let (status, body): (Int, Data)
        if request.httpMethod == "POST", path.hasSuffix("/videos") {
            // Real bridge returns 201 with the full public job shape (bridge.py:_public).
            (status, body) = (201, Data(#"{"id":"vid_123","object":"video","model":"protolabs/ltx2-distilled","status":"queued","progress":0,"created_at":1}"#.utf8))
        } else if path.hasSuffix("/content") {
            (status, body) = (200, Self.videoBytes)
        } else if path.contains("/videos/") {
            let next = Self.statusScript.isEmpty ? "completed" : Self.statusScript.removeFirst()
            if next == "failed" {
                (status, body) = (200, Data(#"{"id":"vid_123","status":"failed","error":{"message":"LTX exploded"}}"#.utf8))
            } else {
                (status, body) = (200, Data(#"{"id":"vid_123","status":"\#(next)","progress":42}"#.utf8))
            }
        } else {
            (status, body) = (404, Data())
        }
        Self.lock.unlock()
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("Gateway video — stubbed bridge", .serialized)
struct GatewayVideoTests {
    private static let stubClient: OpenAICompatGenerationClient = {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [VideoBridgeStub.self]
        OpenAICompatGenerationClient.session = URLSession(configuration: config)
        GatewayGenerationRunner.videoPollInterval = .milliseconds(5)
        return OpenAICompatGenerationClient(baseURL: URL(string: "https://stub.test/v1")!, apiKey: "k")
    }()

    @Test func parseVideoJobShapes() {
        let queued = OpenAICompatGenerationClient.parseVideoJob(Data(#"{"id":"v1","status":"queued"}"#.utf8))
        #expect(queued == .init(id: "v1", status: "queued", progress: nil, errorMessage: nil))
        let failed = OpenAICompatGenerationClient.parseVideoJob(
            Data(#"{"id":"v1","status":"failed","error":{"message":"boom"}}"#.utf8))
        #expect(failed?.errorMessage == "boom")
        #expect(failed?.isTerminal == true)
        #expect(OpenAICompatGenerationClient.parseVideoJob(Data("{}".utf8)) == nil)
    }

    @Test func createPollDownloadRoundTrip() async throws {
        VideoBridgeStub.reset(script: ["queued", "in_progress", "completed"])
        let job = GatewayVideoJob(model: "protolabs/ltx2-video", prompt: "a drone shot", seconds: 8, size: "1216x704")
        var createdId: String?
        let url = try await GatewayGenerationRunner.executeVideo(job, client: Self.stubClient) { id in
            createdId = id
        }
        #expect(createdId == "vid_123")
        #expect(try Data(contentsOf: url) == VideoBridgeStub.videoBytes)
        try? FileManager.default.removeItem(at: url)
        let create = try #require(VideoBridgeStub.calls.first)
        #expect(create.method == "POST" && create.path.hasSuffix("/videos"))
        // Bridge sends application/json → it reads the full JSON body (size/seconds/
        // extra_body). A non-JSON content-type would drop those (bridge.py POST handler).
        #expect(create.contentType == "application/json", "no reference → JSON create")
        // create + 4 status GETs (3 scripted + terminal) is the ceiling; content GET last
        #expect(VideoBridgeStub.calls.last?.path.hasSuffix("/content") == true)
    }

    @Test func inputReferenceMakesCreateMultipart() async throws {
        VideoBridgeStub.reset(script: ["completed"])
        let ref = FileManager.default.temporaryDirectory.appendingPathComponent("ref-\(UUID().uuidString).png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: ref)
        defer { try? FileManager.default.removeItem(at: ref) }
        var job = GatewayVideoJob(model: "protolabs/ltx2-video", prompt: "animate this", seconds: 4)
        job.inputReferenceURL = ref
        let url = try await GatewayGenerationRunner.executeVideo(job, client: Self.stubClient) { _ in }
        try? FileManager.default.removeItem(at: url)
        let create = try #require(VideoBridgeStub.calls.first)
        #expect(create.contentType?.hasPrefix("multipart/form-data") == true)
    }

    @Test func failedJobSurfacesTheBridgeMessage() async throws {
        VideoBridgeStub.reset(script: ["in_progress", "failed"])
        await #expect(throws: OpenAICompatGenerationError.self) {
            _ = try await GatewayGenerationRunner.pollVideo(id: "vid_123", client: Self.stubClient)
        }
    }

    @Test func resumePollsAnExistingId() async throws {
        VideoBridgeStub.reset(script: ["completed"])
        let url = try await GatewayGenerationRunner.pollVideo(id: "vid_123", client: Self.stubClient)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try Data(contentsOf: url) == VideoBridgeStub.videoBytes)
        #expect(VideoBridgeStub.calls.allSatisfy { $0.method == "GET" }, "resume never re-creates")
    }

    @Test func unmappableHostedParamsAreNamed() {
        let source = VideoGenerationParams(
            prompt: "p", duration: 5, aspectRatio: "16:9", resolution: nil, sourceVideoURL: "file:///v.mp4")
        #expect(GenerationService.gatewayVideoUnmappable(source)?.contains("Video-edit") == true)
        let endFrame = VideoGenerationParams(
            prompt: "p", duration: 5, aspectRatio: "16:9", resolution: nil, endFrameURL: "file:///f.png")
        #expect(GenerationService.gatewayVideoUnmappable(endFrame)?.contains("End-frame") == true)
        let refs = VideoGenerationParams(
            prompt: "p", duration: 5, aspectRatio: "16:9", resolution: nil, referenceImageURLs: ["file:///r.png"])
        #expect(GenerationService.gatewayVideoUnmappable(refs)?.contains("Reference media") == true)
        let clean = VideoGenerationParams(
            prompt: "p", duration: 5, aspectRatio: "16:9", resolution: nil, startFrameURL: "file:///s.png")
        #expect(GenerationService.gatewayVideoUnmappable(clean) == nil)
    }

    @Test func videoSizeMapping() {
        #expect(GatewayGenerationRunner.videoSize(resolution: "1216x704", aspectRatio: nil) == "1216x704")
        #expect(GatewayGenerationRunner.videoSize(resolution: nil, aspectRatio: "9:16") == "704x1216")
        #expect(GatewayGenerationRunner.videoSize(resolution: nil, aspectRatio: "2:1") == nil)
    }
}
