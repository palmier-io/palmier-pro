import Foundation
import Testing
@testable import PalmierPro

@Suite("OpenAI-compatible image generation — response decoding")
struct OpenAICompatGenerationTests {

    private func json(_ obj: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: obj)
    }

    @Test func decodesURLResponses() throws {
        let data = json(["data": [["url": "https://cdn.example/a.png"], ["url": "https://cdn.example/b.png"]]])
        let images = try OpenAICompatGenerationClient.decodeImages(from: data)
        #expect(images == [
            .url(URL(string: "https://cdn.example/a.png")!),
            .url(URL(string: "https://cdn.example/b.png")!),
        ])
    }

    @Test func decodesBase64Responses() throws {
        let payload = Data("hello-png".utf8)
        let data = json(["data": [["b64_json": payload.base64EncodedString()]]])
        let images = try OpenAICompatGenerationClient.decodeImages(from: data)
        #expect(images == [.base64(payload)])
    }

    @Test func surfacesApiError() {
        let data = json(["error": ["message": "model not found", "type": "invalid_request_error"]])
        #expect(throws: OpenAICompatGenerationError.self) {
            try OpenAICompatGenerationClient.decodeImages(from: data)
        }
    }

    @Test func throwsOnEmptyData() {
        let data = json(["data": []])
        #expect(throws: OpenAICompatGenerationError.self) {
            try OpenAICompatGenerationClient.decodeImages(from: data)
        }
    }

    @Test func throwsOnMalformed() {
        #expect(throws: OpenAICompatGenerationError.self) {
            try OpenAICompatGenerationClient.decodeImages(from: Data("not json".utf8))
        }
    }

    // MARK: - Model discovery

    @Test func parsesModelInfoWithModality() {
        let data = json(["data": [
            ["model_name": "protolabs/reasoning", "model_info": ["mode": "chat"]],
            ["model_name": "protolabs/image", "model_info": ["mode": "image_generation"]],
            ["model_name": "no-mode"],
        ]])
        let models = OpenAICompatGenerationClient.parseModelInfo(data)
        #expect(models == [
            .init(id: "protolabs/reasoning", mode: "chat"),
            .init(id: "protolabs/image", mode: "image_generation"),
            .init(id: "no-mode", mode: nil),
        ])
    }

    @Test func parsesBasicModels() {
        let data = json(["data": [["id": "a", "object": "model"], ["id": "b", "object": "model"]]])
        let models = OpenAICompatGenerationClient.parseBasicModels(data)
        #expect(models == [.init(id: "a", mode: nil), .init(id: "b", mode: nil)])
    }

    @Test func mapsModeToType() {
        #expect(ToolExecutor.gatewayModelType("image_generation") == "image")
        #expect(ToolExecutor.gatewayModelType("chat") == "chat")
        #expect(ToolExecutor.gatewayModelType("audio_speech") == "audio")
        #expect(ToolExecutor.gatewayModelType(nil) == "unknown")
    }
}
