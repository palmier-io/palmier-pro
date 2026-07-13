import Foundation
import Testing
@testable import PalmierPro

/// URLProtocol stub scripting the bridge's three video URLs.
final class VideoBridgeStub: URLProtocol {
    struct Call: Sendable { let method: String; let path: String; let contentType: String?; let body: String }
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

    /// URLSession hands a custom URLProtocol the body as a stream, not httpBody —
    /// drain it so multipart parts are assertable. Binary parts decode lossily,
    /// which is fine for substring checks on the ASCII headers.
    static func bodyString(_ request: URLRequest) -> String {
        if let b = request.httpBody { return String(decoding: b, as: UTF8.self) }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open(); defer { stream.close() }
        var data = Data(); var buf = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buf, maxLength: buf.count)
            if n <= 0 { break }
            data.append(buf, count: n)
        }
        return String(decoding: data, as: UTF8.self)
    }

    override func startLoading() {
        Self.lock.lock()
        let path = request.url?.path ?? ""
        Self.calls.append(.init(
            method: request.httpMethod ?? "?", path: path,
            contentType: request.value(forHTTPHeaderField: "content-type"),
            body: Self.bodyString(request)
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
        // Register every stub host — the gateway client shares one global session,
        // so parallel suites must not clobber each other's protocol (host-filtered).
        config.protocolClasses = [VideoBridgeStub.self, AudioAdapterStub.self]
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
        // extend (source video alone) and first-last-frame (start + end) are now mappable.
        let extend = VideoGenerationParams(
            prompt: "p", duration: 5, aspectRatio: "16:9", resolution: nil, sourceVideoURL: "file:///v.mp4")
        #expect(GenerationService.gatewayVideoUnmappable(extend) == nil)
        let flf = VideoGenerationParams(
            prompt: "p", duration: 5, aspectRatio: "16:9", resolution: nil,
            startFrameURL: "file:///s.png", endFrameURL: "file:///e.png")
        #expect(GenerationService.gatewayVideoUnmappable(flf) == nil)
        // Still rejected: source video mixed with frames, a lone last frame, extra refs.
        let both = VideoGenerationParams(
            prompt: "p", duration: 5, aspectRatio: "16:9", resolution: nil,
            sourceVideoURL: "file:///v.mp4", startFrameURL: "file:///s.png")
        #expect(GenerationService.gatewayVideoUnmappable(both)?.contains("Pick one") == true)
        let loneEnd = VideoGenerationParams(
            prompt: "p", duration: 5, aspectRatio: "16:9", resolution: nil, endFrameURL: "file:///f.png")
        #expect(GenerationService.gatewayVideoUnmappable(loneEnd)?.contains("first-last-frame") == true)
        let refs = VideoGenerationParams(
            prompt: "p", duration: 5, aspectRatio: "16:9", resolution: nil, referenceImageURLs: ["file:///r.png"])
        #expect(GenerationService.gatewayVideoUnmappable(refs)?.contains("reference media") == true)
        let i2v = VideoGenerationParams(
            prompt: "p", duration: 5, aspectRatio: "16:9", resolution: nil, startFrameURL: "file:///s.png")
        #expect(GenerationService.gatewayVideoUnmappable(i2v) == nil)
    }

    @Test func videoInputPartShapes() {
        let img = OpenAICompatGenerationClient.VideoInput.image(Data([0x89, 0x50])).part
        #expect(img.name == "input_reference" && img.filename == "reference.png" && img.contentType == "image/png")
        let vid = OpenAICompatGenerationClient.VideoInput.video(Data("ftyp".utf8)).part
        #expect(vid.name == "input_reference" && vid.filename == "reference.mp4" && vid.contentType == "video/mp4")
    }

    @Test func isVideoReferenceByExtension() {
        #expect(GatewayGenerationRunner.isVideoReference(URL(fileURLWithPath: "/a/clip.MOV")))
        #expect(GatewayGenerationRunner.isVideoReference(URL(fileURLWithPath: "/a/clip.mp4")))
        #expect(!GatewayGenerationRunner.isVideoReference(URL(fileURLWithPath: "/a/frame.png")))
    }

    @Test func extendSendsVideoGuideAsMultipart() async throws {
        VideoBridgeStub.reset(script: ["completed"])
        let clip = FileManager.default.temporaryDirectory.appendingPathComponent("src-\(UUID().uuidString).mov")
        try Data("ftypqt  moovtrak".utf8).write(to: clip)
        defer { try? FileManager.default.removeItem(at: clip) }
        var job = GatewayVideoJob(model: "protolabs/ltx2-video", prompt: "continue the shot", seconds: 6)
        job.inputReferenceURL = clip
        let url = try await GatewayGenerationRunner.executeVideo(job, client: Self.stubClient) { _ in }
        try? FileManager.default.removeItem(at: url)
        let create = try #require(VideoBridgeStub.calls.first)
        #expect(create.contentType?.hasPrefix("multipart/form-data") == true)
        #expect(create.body.contains(#"filename="reference.mp4""#), "extend must send the guide as a video part")
        #expect(create.body.contains("video/mp4"))
        #expect(!create.body.contains(#"name="last_frame""#), "extend has no last frame")
    }

    @Test func firstLastFrameSendsBothImageParts() async throws {
        VideoBridgeStub.reset(script: ["completed"])
        let dir = FileManager.default.temporaryDirectory
        let start = dir.appendingPathComponent("s-\(UUID().uuidString).png")
        let end = dir.appendingPathComponent("e-\(UUID().uuidString).png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: start)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: end)
        defer { try? FileManager.default.removeItem(at: start); try? FileManager.default.removeItem(at: end) }
        var job = GatewayVideoJob(model: "protolabs/ltx2-video", prompt: "interpolate", seconds: 4)
        job.inputReferenceURL = start
        job.lastFrameURL = end
        let url = try await GatewayGenerationRunner.executeVideo(job, client: Self.stubClient) { _ in }
        try? FileManager.default.removeItem(at: url)
        let create = try #require(VideoBridgeStub.calls.first)
        #expect(create.body.contains(#"name="input_reference""#))
        #expect(create.body.contains(#"name="last_frame""#), "first-last-frame must send both frames")
    }

    @Test func loneLastFrameIsRejected() async throws {
        VideoBridgeStub.reset(script: ["completed"])
        let end = FileManager.default.temporaryDirectory.appendingPathComponent("e-\(UUID().uuidString).png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: end)
        defer { try? FileManager.default.removeItem(at: end) }
        var job = GatewayVideoJob(model: "protolabs/ltx2-video", prompt: "x", seconds: 4)
        job.lastFrameURL = end
        await #expect(throws: OpenAICompatGenerationError.self) {
            _ = try await GatewayGenerationRunner.executeVideo(job, client: Self.stubClient) { _ in }
        }
    }

    @Test func videoSizeMapping() {
        #expect(GatewayGenerationRunner.videoSize(resolution: "1216x704", aspectRatio: nil) == "1216x704")
        #expect(GatewayGenerationRunner.videoSize(resolution: nil, aspectRatio: "9:16") == "704x1216")
        #expect(GatewayGenerationRunner.videoSize(resolution: nil, aspectRatio: "2:1") == nil)
    }
}
