import Foundation
import Testing
@testable import PalmierPro

/// URLProtocol stub for the ACE-Step adapter's sync `/audio/generations`.
final class AudioAdapterStub: URLProtocol {
    struct Call: Sendable { let method: String; let path: String; let contentType: String?; let body: String }
    nonisolated(unsafe) static var calls: [Call] = []
    nonisolated(unsafe) static var clipBytes = Data("ID3\u{04}stub-audio".utf8)
    private static let lock = NSLock()

    static func reset() { lock.lock(); defer { lock.unlock() }; calls = [] }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "audio.stub" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    static func bodyString(_ request: URLRequest) -> String {
        if let b = request.httpBody { return String(decoding: b, as: UTF8.self) }
        guard let s = request.httpBodyStream else { return "" }
        s.open(); defer { s.close() }
        var d = Data(); var buf = [UInt8](repeating: 0, count: 4096)
        while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; d.append(buf, count: n) }
        return String(decoding: d, as: UTF8.self)
    }

    override func startLoading() {
        Self.lock.lock()
        Self.calls.append(.init(
            method: request.httpMethod ?? "?", path: request.url?.path ?? "",
            contentType: request.value(forHTTPHeaderField: "content-type"),
            body: Self.bodyString(request)))
        Self.lock.unlock()
        // /audio/speech is OpenAI-native: it returns raw audio bytes, not a JSON envelope.
        let isSpeech = request.url?.path.hasSuffix("/audio/speech") == true
        let body: Data
        let contentType: String
        if isSpeech {
            body = Self.clipBytes
            contentType = "audio/mpeg"
        } else {
            let b64 = Self.clipBytes.base64EncodedString()
            body = Data(#"{"data":[{"b64_json":"\#(b64)","seed":871727746,"duration_s":6.0}],"format":"mp3"}"#.utf8)
            contentType = "application/json"
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": contentType])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("Gateway audio — stubbed ACE-Step", .serialized)
struct GatewayAudioTests {
    private static let stubClient: OpenAICompatGenerationClient = {
        let config = URLSessionConfiguration.ephemeral
        // The gateway client shares one global session; register every stub host so
        // parallel suites don't clobber each other (canInit is host-filtered; real
        // hosts fall through to the network for the live smoke).
        config.protocolClasses = [AudioAdapterStub.self, VideoBridgeStub.self]
        OpenAICompatGenerationClient.session = URLSession(configuration: config)
        return OpenAICompatGenerationClient(baseURL: URL(string: "https://audio.stub/v1")!, apiKey: "k")
    }()

    @Test func generateMusicPostsJSONAndWritesClip() async throws {
        AudioAdapterStub.reset()
        let urls = try await Self.stubClient.generateMusic(
            model: "protolabs/ace-step", prompt: "warm lo-fi hip hop",
            lyrics: "[Verse] neon rain", instrumental: false, seconds: 8, format: "mp3")
        let url = try #require(urls.first)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(url.pathExtension == "mp3")
        #expect(try Data(contentsOf: url) == AudioAdapterStub.clipBytes)
        let call = try #require(AudioAdapterStub.calls.first)
        #expect(call.method == "POST" && call.path.hasSuffix("/audio/generations"))
        #expect(call.contentType == "application/json")
        #expect(call.body.contains(#""response_format":"b64_json""#))
        #expect(call.body.contains("ace-step"))
        #expect(call.body.contains("[Verse]"), "lyrics must ride the body")
    }

    @Test func executeAudioRunsTheJob() async throws {
        AudioAdapterStub.reset()
        var job = GatewayAudioJob(model: "protolabs/ace-step", prompt: "ambient pad")
        job.instrumental = true; job.seconds = 5
        let urls = try await GatewayGenerationRunner.executeAudio(job, client: Self.stubClient)
        let url = try #require(urls.first)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try Data(contentsOf: url) == AudioAdapterStub.clipBytes)
    }

    @Test func synthesizeSpeechPostsJSONAndWritesRawBytes() async throws {
        AudioAdapterStub.reset()
        let url = try await Self.stubClient.synthesizeSpeech(
            model: "fish-s2-pro", input: "Roll sound.", voice: "narrator", format: "mp3")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(url.pathExtension == "mp3")
        #expect(try Data(contentsOf: url) == AudioAdapterStub.clipBytes, "speech returns raw bytes, not a b64 envelope")
        let call = try #require(AudioAdapterStub.calls.first)
        #expect(call.method == "POST" && call.path.hasSuffix("/audio/speech"))
        #expect(call.contentType == "application/json")
        #expect(call.body.contains(#""voice":"narrator""#))
        #expect(call.body.contains("fish-s2-pro"))
        #expect(call.body.contains("Roll sound."))
    }

    @Test func executeAudioRoutesSpeechToSpeechEndpoint() async throws {
        AudioAdapterStub.reset()
        var job = GatewayAudioJob(op: .speech, model: "fish-s2-pro", prompt: "Take one.")
        job.fields = ["voice": "calm"]
        let urls = try await GatewayGenerationRunner.executeAudio(job, client: Self.stubClient)
        let url = try #require(urls.first)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try Data(contentsOf: url) == AudioAdapterStub.clipBytes)
        let call = try #require(AudioAdapterStub.calls.first)
        #expect(call.path.hasSuffix("/audio/speech"))
        #expect(call.body.contains(#""voice":"calm""#))
    }

    @Test func materializeAudioUsesFormatExtension() throws {
        let json = Data(#"{"data":[{"b64_json":"\#(Data("x".utf8).base64EncodedString())","seed":1,"duration_s":6}],"format":"flac"}"#.utf8)
        let urls = try OpenAICompatGenerationClient.materializeAudio(from: json, format: "flac")
        let url = try #require(urls.first)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(url.pathExtension == "flac")
    }

    @Test func materializeAudioSurfacesBridgeError() {
        let json = Data(#"{"error":{"message":"only b64_json is supported"}}"#.utf8)
        #expect(throws: OpenAICompatGenerationError.self) {
            _ = try OpenAICompatGenerationClient.materializeAudio(from: json, format: "mp3")
        }
    }

    @Test func editAudioPostsMultipartWithOpModelAndFields() async throws {
        AudioAdapterStub.reset()
        let src = FileManager.default.temporaryDirectory.appendingPathComponent("src-\(UUID().uuidString).mp3")
        try Data("ID3\u{04}source-clip".utf8).write(to: src)
        defer { try? FileManager.default.removeItem(at: src) }
        let urls = try await Self.stubClient.editAudio(
            model: "ace-step-repaint", audio: try Data(contentsOf: src),
            filename: src.lastPathComponent, contentType: "audio/mpeg",
            fields: ["start_s": "2", "end_s": "4", "variance": "0.6", "format": "mp3"])
        let url = try #require(urls.first)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(url.pathExtension == "mp3")
        let call = try #require(AudioAdapterStub.calls.first)
        #expect(call.method == "POST" && call.path.hasSuffix("/audio/edits"))
        #expect(call.contentType?.hasPrefix("multipart/form-data") == true)
        #expect(call.body.contains("ace-step-repaint"))
        #expect(call.body.contains(#"name="audio""#), "source clip must be a multipart part")
        #expect(call.body.contains("start_s"))
    }

    @Test func executeAudioRoutesEditOpsToEditsEndpoint() async throws {
        AudioAdapterStub.reset()
        let src = FileManager.default.temporaryDirectory.appendingPathComponent("src-\(UUID().uuidString).mp3")
        try Data("ID3\u{04}source-clip".utf8).write(to: src)
        defer { try? FileManager.default.removeItem(at: src) }
        var job = GatewayAudioJob(op: .extend, model: "ace-step-extend", prompt: "continue the groove")
        job.sourceAudioURL = src
        job.seconds = 12
        job.fields = ["direction": "append"]
        _ = try await GatewayGenerationRunner.executeAudio(job, client: Self.stubClient)
        let call = try #require(AudioAdapterStub.calls.first)
        #expect(call.path.hasSuffix("/audio/edits"))
        #expect(call.body.contains("ace-step-extend"))
        #expect(call.body.contains("direction"))
        #expect(call.body.contains("continue the groove"), "prompt rides the edit fields")
    }

    @Test func editOpWithoutSourceThrows() async {
        let job = GatewayAudioJob(op: .repaint, model: "ace-step-repaint", prompt: "x")
        await #expect(throws: OpenAICompatGenerationError.self) {
            _ = try await GatewayGenerationRunner.executeAudio(job, client: Self.stubClient)
        }
    }

    @Test func audioContentTypeByExtension() {
        #expect(GatewayGenerationRunner.audioContentType(URL(fileURLWithPath: "/a/x.mp3")) == "audio/mpeg")
        #expect(GatewayGenerationRunner.audioContentType(URL(fileURLWithPath: "/a/x.FLAC")) == "audio/flac")
        #expect(GatewayGenerationRunner.audioContentType(URL(fileURLWithPath: "/a/x.wav")) == "audio/wav")
        #expect(GatewayGenerationRunner.audioContentType(URL(fileURLWithPath: "/a/x.xyz")) == "audio/mpeg")
    }
}
