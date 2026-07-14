import Foundation
import Combine
@preconcurrency import ConvexMobile

/// HTTP client for the localhost palmier-gateway. Mirrors the exact return types
/// of the Convex-backed seams (ModelCatalog / GenerationBackend / TranscriptionBackend
/// / BackendStorage) so each seam can branch to it under `BackendMode.local` without
/// changing decoded types. The reactive `convex.subscribe` seam is emulated by a
/// periodic polling publisher — the consumers cancel it when a job reaches a
/// terminal state, so it never needs to complete on its own.
enum LocalBackend {
    private static let base = LocalGateway.baseURL

    // MARK: Catalog

    static func models() async throws -> [CatalogEntry] {
        struct Response: Decodable { let models: [CatalogEntry] }
        return try await getJSON("api/models", as: Response.self).models
    }

    // MARK: Generation

    static func submitGeneration(
        model: String,
        params: BackendGenerationParams,
        projectId: String?
    ) async throws -> String {
        struct Body: Encodable {
            let model: String
            let params: BackendGenerationParams
            let projectId: String?
        }
        struct Response: Decodable { let jobId: String }
        let body = Body(model: model, params: params, projectId: projectId)
        return try await postJSON("api/generate", body: body, as: Response.self).jobId
    }

    static func generationPublisher(jobId: String) -> AnyPublisher<BackendGenerationJob?, ClientError> {
        poll("api/jobs/\(jobId)")
    }

    static func uploadReference(fileURL: URL, contentType: String) async throws -> String {
        let storageId = try await uploadStaged(fileURL: fileURL, contentType: contentType)
        return base.appendingPathComponent("files/staging/\(storageId)").absoluteString
    }

    // MARK: Transcription

    static func submitTranscription(
        storageId: String,
        durationSeconds: Double,
        language: String?
    ) async throws -> BackendTranscriptionSubmit {
        struct Body: Encodable {
            let storageId: String
            let durationSeconds: Double
            let languageMode: String
            let language: String?
        }
        let body = Body(
            storageId: storageId,
            durationSeconds: durationSeconds,
            languageMode: language == nil ? "auto" : "specific",
            language: language
        )
        return try await postJSON("api/transcribe", body: body, as: BackendTranscriptionSubmit.self)
    }

    static func transcriptionPublisher(jobId: String) -> AnyPublisher<BackendTranscriptionJob?, ClientError> {
        poll("api/transcriptions/\(jobId)")
    }

    static func transcriptionResultURL(jobId: String) async throws -> String {
        struct Response: Decodable { let resultUrl: String }
        return try await getJSON("api/transcriptions/\(jobId)/result", as: Response.self).resultUrl
    }

    // MARK: Storage

    static func uploadStaged(fileURL: URL, contentType: String) async throws -> String {
        struct Response: Decodable { let storageId: String }
        var request = URLRequest(url: base.appendingPathComponent("api/uploads/stage"))
        request.httpMethod = "POST"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: fileURL)
        try assertOK(response, data)
        return try JSONDecoder().decode(Response.self, from: data).storageId
    }

    // MARK: - Polling publisher

    private static func poll<T: Decodable>(
        _ path: String,
        every interval: TimeInterval = 0.8
    ) -> AnyPublisher<T?, ClientError> {
        Timer.publish(every: interval, on: .main, in: .common)
            .autoconnect()
            .map { _ in () }
            .prepend(())
            .flatMap { _ in fetchOptional(path) as AnyPublisher<T?, Never> }
            .setFailureType(to: ClientError.self)
            .eraseToAnyPublisher()
    }

    private static func fetchOptional<T: Decodable>(_ path: String) -> AnyPublisher<T?, Never> {
        URLSession.shared
            .dataTaskPublisher(for: base.appendingPathComponent(path))
            .map { try? JSONDecoder().decode(T.self, from: $0.data) }
            .replaceError(with: nil)
            .eraseToAnyPublisher()
    }

    // MARK: - Request helpers

    private static func getJSON<T: Decodable>(_ path: String, as: T.Type) async throws -> T {
        let (data, response) = try await URLSession.shared.data(from: base.appendingPathComponent(path))
        try assertOK(response, data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func postJSON<B: Encodable, T: Decodable>(_ path: String, body: B, as: T.Type) async throws -> T {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try assertOK(response, data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func assertOK(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw BackendError.transport("Non-HTTP response from gateway")
        }
        if (200..<300).contains(http.statusCode) { return }
        let detail = String(data: data, encoding: .utf8) ?? ""
        throw BackendError.transport("gateway HTTP \(http.statusCode): \(detail)")
    }
}
