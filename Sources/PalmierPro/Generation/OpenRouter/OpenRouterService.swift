import Foundation

extension Notification.Name {
    static let openRouterSettingsChanged = Notification.Name("openRouterSettingsChanged")
}

enum OpenRouterModelId {
    static let prefix = "openrouter:"

    static func stored(_ id: String) -> String { prefix + id }

    static func raw(_ id: String) -> String? {
        guard id.hasPrefix(prefix) else { return nil }
        return String(id.dropFirst(prefix.count))
    }

    static func isStored(_ id: String) -> Bool {
        id.hasPrefix(prefix)
    }
}

enum OpenRouterKeychain {
    private static let account = "openrouter-api-key"

    static func save(_ key: String) {
        KeychainStore.save(key, account: account)
        NotificationCenter.default.post(name: .openRouterSettingsChanged, object: nil)
    }

    static func load() -> String? {
        #if DEBUG
        if let env = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !env.isEmpty {
            return env
        }
        #endif
        return KeychainStore.load(account: account)
    }

    static func delete() {
        KeychainStore.delete(account: account)
        NotificationCenter.default.post(name: .openRouterSettingsChanged, object: nil)
    }
}

enum OpenRouterError: LocalizedError {
    case missingAPIKey
    case transport(String)
    case api(status: Int, message: String)
    case emptyResponse
    case timedOut

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: "Set an OpenRouter API key before generating."
        case .transport(let message): message
        case .api(_, let message): message
        case .emptyResponse: "OpenRouter returned no media."
        case .timedOut: "OpenRouter generation timed out."
        }
    }
}

struct OpenRouterImageModelConfig: Identifiable, Sendable, Equatable {
    let id: String
    let displayName: String
    let description: String
    let aspectRatios: [String]
    let resolutions: [String]?
    let qualities: [String]?
    let supportsImageReference: Bool
    let maxImages: Int
    let maxReferences: Int

    fileprivate init(entry: OpenRouterImageModelListItem) {
        id = entry.id
        displayName = entry.name
        description = entry.description
        aspectRatios = entry.supportedParameters["aspect_ratio"]?.valuesIfEnum ?? ["1:1", "16:9", "9:16"]
        resolutions = entry.supportedParameters["resolution"]?.valuesIfEnum
        qualities = entry.supportedParameters["quality"]?.valuesIfEnum
        let refMax = entry.supportedParameters["input_references"]?.max ?? 0
        supportsImageReference = entry.architecture.inputModalities.contains("image") && refMax > 0
        maxReferences = max(0, refMax)
        maxImages = max(1, min(4, entry.supportedParameters["n"]?.max ?? 1))
    }

    func validate(aspectRatio: String, resolution: String?, quality: String?, imageRefCount: Int, numImages: Int) -> String? {
        if !aspectRatios.isEmpty, !aspectRatio.isEmpty, !aspectRatios.contains(aspectRatio) {
            return unsupportedValue(model: displayName, field: "aspect ratio", value: aspectRatio, allowed: aspectRatios)
        }
        if let allowed = resolutions, let r = resolution, !r.isEmpty, !allowed.contains(r) {
            return unsupportedValue(model: displayName, field: "resolution", value: r, allowed: allowed)
        }
        if let allowed = qualities, let q = quality, !q.isEmpty, !allowed.contains(q) {
            return unsupportedValue(model: displayName, field: "quality", value: q, allowed: allowed)
        }
        if imageRefCount > 0, !supportsImageReference {
            return "\(displayName) does not accept reference images."
        }
        if imageRefCount > maxReferences {
            return "\(displayName) accepts at most \(maxReferences) reference image\(maxReferences == 1 ? "" : "s")."
        }
        if numImages < 1 || numImages > maxImages {
            return "\(displayName) supports 1…\(maxImages) image\(maxImages == 1 ? "" : "s") per request (got \(numImages))."
        }
        return nil
    }
}

struct OpenRouterVideoModelConfig: Identifiable, Sendable, Equatable {
    let id: String
    let displayName: String
    let description: String
    let durations: [Int]
    let resolutions: [String]?
    let aspectRatios: [String]
    let supportsFirstFrame: Bool
    let supportsLastFrame: Bool
    let canGenerateAudio: Bool

    fileprivate init(entry: OpenRouterVideoModelListItem) {
        id = entry.id
        displayName = entry.name
        description = entry.description ?? ""
        durations = entry.supportedDurations ?? [5]
        resolutions = entry.supportedResolutions
        aspectRatios = entry.supportedAspectRatios ?? ["16:9", "9:16", "1:1"]
        let frames = Set(entry.supportedFrameImages ?? [])
        supportsFirstFrame = frames.contains("first_frame")
        supportsLastFrame = frames.contains("last_frame")
        canGenerateAudio = entry.generateAudio ?? false
    }

    func validate(duration: Int, aspectRatio: String, resolution: String?) -> String? {
        if !durations.isEmpty, !durations.contains(duration) {
            return unsupportedValue(
                model: displayName, field: "duration",
                value: "\(duration)s", allowed: durations.map { "\($0)s" }
            )
        }
        if !aspectRatios.isEmpty, !aspectRatio.isEmpty, !aspectRatios.contains(aspectRatio) {
            return unsupportedValue(model: displayName, field: "aspect ratio", value: aspectRatio, allowed: aspectRatios)
        }
        if let allowed = resolutions, let r = resolution, !r.isEmpty, !allowed.contains(r) {
            return unsupportedValue(model: displayName, field: "resolution", value: r, allowed: allowed)
        }
        return nil
    }
}

@Observable
@MainActor
final class OpenRouterService {
    static let shared = OpenRouterService()

    private(set) var image: [OpenRouterImageModelConfig] = []
    private(set) var video: [OpenRouterVideoModelConfig] = []
    private(set) var isLoaded = false
    private(set) var isLoading = false
    private(set) var lastError: String?
    private(set) var hasAPIKey = false

    @ObservationIgnored private var apiKey: String = ""
    @ObservationIgnored private var didConfigure = false
    @ObservationIgnored private var settingsObserver: NSObjectProtocol?

    private static let baseURL = URL(string: "https://openrouter.ai/api/v1")!
    private static let appTitle = "Palmier Pro"
    private static let appReferer = "https://github.com/Gitnapp/open-palmier"

    private init() {}

    func configure() {
        guard !didConfigure else { return }
        didConfigure = true
        reloadAPIKey()
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .openRouterSettingsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reloadAPIKey()
                await self?.refreshModels()
            }
        }
        Task { await refreshModels() }
    }

    func saveAPIKey(_ key: String) {
        OpenRouterKeychain.save(key.trimmingCharacters(in: .whitespacesAndNewlines))
        reloadAPIKey()
        Task { await refreshModels() }
    }

    func removeAPIKey() {
        OpenRouterKeychain.delete()
        reloadAPIKey()
    }

    func refreshModels() async {
        guard hasAPIKey else {
            image = []
            video = []
            isLoaded = false
            isLoading = false
            lastError = nil
            return
        }
        isLoading = true
        lastError = nil
        defer { isLoading = false }
        do {
            let key = apiKey
            async let imageEntries = Self.fetchImageModels(apiKey: key)
            async let videoEntries = Self.fetchVideoModels(apiKey: key)
            let loadedImages = try await imageEntries.map(OpenRouterImageModelConfig.init)
            let loadedVideos = try await videoEntries.map(OpenRouterVideoModelConfig.init)
            guard hasAPIKey, apiKey == key else { return }
            image = loadedImages
            video = loadedVideos
            isLoaded = true
        } catch {
            image = []
            video = []
            isLoaded = false
            lastError = error.localizedDescription
        }
    }

    func imageModel(rawId: String) -> OpenRouterImageModelConfig? {
        image.first { $0.id == rawId }
    }

    func videoModel(rawId: String) -> OpenRouterVideoModelConfig? {
        video.first { $0.id == rawId }
    }

    func modelExists(storedId: String) -> Bool {
        guard let raw = OpenRouterModelId.raw(storedId) else { return false }
        return image.contains { $0.id == raw } || video.contains { $0.id == raw }
    }

    func generateImages(
        model: OpenRouterImageModelConfig,
        prompt: String,
        aspectRatio: String,
        resolution: String?,
        quality: String?,
        numImages: Int,
        references: [MediaAsset]
    ) async throws -> [OpenRouterImageOutput] {
        guard !apiKey.isEmpty else { throw OpenRouterError.missingAPIKey }
        var refParts: [OpenRouterContentPart] = []
        refParts.reserveCapacity(references.count)
        for asset in references {
            refParts.append(try await OpenRouterContentPart.imageDataURL(from: asset))
        }
        var body: [String: Any] = [
            "model": model.id,
            "prompt": prompt,
            "aspect_ratio": aspectRatio,
            "n": numImages,
            "output_format": "png",
        ]
        if let resolution { body["resolution"] = resolution }
        if let quality { body["quality"] = quality }
        if !refParts.isEmpty { body["input_references"] = refParts.map { $0.jsonObject } }

        let response = try await Self.request(
            path: "images",
            method: "POST",
            apiKey: apiKey,
            body: body,
            response: OpenRouterImageGenerationResponse.self
        )
        let outputs = response.data.compactMap { item -> OpenRouterImageOutput? in
            guard let data = Data(base64Encoded: item.b64JSON) else { return nil }
            return OpenRouterImageOutput(data: data, mediaType: item.mediaType ?? "image/png")
        }
        guard !outputs.isEmpty else { throw OpenRouterError.emptyResponse }
        return outputs
    }

    func generateVideoFiles(
        model: OpenRouterVideoModelConfig,
        prompt: String,
        duration: Int,
        aspectRatio: String,
        resolution: String?,
        firstFrame: MediaAsset?,
        lastFrame: MediaAsset?,
        generateAudio: Bool
    ) async throws -> [URL] {
        guard !apiKey.isEmpty else { throw OpenRouterError.missingAPIKey }
        var body: [String: Any] = [
            "model": model.id,
            "prompt": prompt,
            "duration": duration,
            "aspect_ratio": aspectRatio,
            "generate_audio": generateAudio,
        ]
        if let resolution { body["resolution"] = resolution }
        var frames: [[String: Any]] = []
        if let firstFrame {
            var part = try await OpenRouterContentPart.imageDataURL(from: firstFrame).jsonObject
            part["frame_type"] = "first_frame"
            frames.append(part)
        }
        if let lastFrame {
            var part = try await OpenRouterContentPart.imageDataURL(from: lastFrame).jsonObject
            part["frame_type"] = "last_frame"
            frames.append(part)
        }
        if !frames.isEmpty { body["frame_images"] = frames }

        let submitted = try await Self.request(
            path: "videos",
            method: "POST",
            apiKey: apiKey,
            body: body,
            response: OpenRouterVideoGenerationResponse.self
        )
        let completed = try await pollVideo(jobId: submitted.id)
        if let urls = completed.unsignedURLs, !urls.isEmpty {
            return try await downloadUnsignedVideoURLs(urls)
        }
        return try await downloadVideoContent(jobId: completed.id)
    }

    private func reloadAPIKey() {
        apiKey = OpenRouterKeychain.load() ?? ""
        hasAPIKey = !apiKey.isEmpty
        if !hasAPIKey {
            image = []
            video = []
            isLoaded = false
            lastError = nil
        }
    }

    private func pollVideo(jobId: String) async throws -> OpenRouterVideoGenerationResponse {
        for _ in 0..<240 {
            let job = try await Self.request(
                path: "videos/\(jobId)",
                method: "GET",
                apiKey: apiKey,
                body: nil,
                response: OpenRouterVideoGenerationResponse.self
            )
            switch job.status {
            case "completed":
                return job
            case "failed", "cancelled", "expired":
                throw OpenRouterError.transport(job.error ?? "OpenRouter video generation \(job.status).")
            default:
                try await Task.sleep(for: .seconds(3))
            }
        }
        throw OpenRouterError.timedOut
    }

    private func downloadUnsignedVideoURLs(_ urls: [String]) async throws -> [URL] {
        try await withThrowingTaskGroup(of: (Int, URL).self) { group in
            for (index, urlString) in urls.enumerated() {
                group.addTask {
                    guard let url = URL(string: urlString) else {
                        throw OpenRouterError.transport("Invalid video URL.")
                    }
                    let (temp, _) = try await URLSession.shared.download(from: url)
                    return (index, temp)
                }
            }
            var out: [(Int, URL)] = []
            for try await item in group { out.append(item) }
            return out.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private func downloadVideoContent(jobId: String) async throws -> [URL] {
        var request = URLRequest(url: Self.baseURL.appendingPathComponent("videos/\(jobId)/content"))
        request.httpMethod = "GET"
        Self.applyHeaders(to: &request, apiKey: apiKey, includeJSON: false)
        let (temp, response) = try await URLSession.shared.download(for: request)
        try Self.assertHTTPOK(response: response, data: nil)
        return [temp]
    }

    private static func fetchImageModels(apiKey: String) async throws -> [OpenRouterImageModelListItem] {
        try await request(
            path: "images/models",
            method: "GET",
            apiKey: apiKey,
            body: nil,
            response: OpenRouterImageModelsListResponse.self
        ).data
    }

    private static func fetchVideoModels(apiKey: String) async throws -> [OpenRouterVideoModelListItem] {
        try await request(
            path: "videos/models",
            method: "GET",
            apiKey: apiKey,
            body: nil,
            response: OpenRouterVideoModelsListResponse.self
        ).data
    }

    private static func request<T: Decodable>(
        path: String,
        method: String,
        apiKey: String?,
        body: [String: Any]?,
        response: T.Type
    ) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        applyHeaders(to: &request, apiKey: apiKey, includeJSON: body != nil)
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        }
        let (data, urlResponse) = try await URLSession.shared.data(for: request)
        try assertHTTPOK(response: urlResponse, data: data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func applyHeaders(to request: inout URLRequest, apiKey: String?, includeJSON: Bool) {
        request.setValue(Self.appReferer, forHTTPHeaderField: "HTTP-Referer")
        request.setValue(Self.appTitle, forHTTPHeaderField: "X-OpenRouter-Title")
        if includeJSON {
            request.setValue("application/json", forHTTPHeaderField: "content-type")
        }
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
    }

    private static func assertHTTPOK(response: URLResponse, data: Data?) throws {
        guard let http = response as? HTTPURLResponse else {
            throw OpenRouterError.transport("Non-HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = data.flatMap(Self.errorMessage) ?? "OpenRouter HTTP \(http.statusCode)"
            throw OpenRouterError.api(status: http.statusCode, message: message)
        }
    }

    private static func errorMessage(data: Data) -> String? {
        guard let envelope = try? JSONDecoder().decode(OpenRouterErrorEnvelope.self, from: data) else {
            return String(data: data, encoding: .utf8)
        }
        return envelope.error.message
    }
}

struct OpenRouterImageOutput: Sendable {
    let data: Data
    let mediaType: String

    var fileExtension: String {
        switch mediaType {
        case "image/jpeg": "jpg"
        case "image/webp": "webp"
        default: "png"
        }
    }
}

private struct OpenRouterContentPart: Sendable {
    let url: String

    var jsonObject: [String: Any] {
        [
            "type": "image_url",
            "image_url": ["url": url],
        ]
    }

    @MainActor
    static func imageDataURL(from asset: MediaAsset) async throws -> OpenRouterContentPart {
        guard asset.type == .image else {
            throw OpenRouterError.transport("OpenRouter currently accepts image references only.")
        }
        let url = asset.url
        let output = await Task.detached(priority: .utility) {
            ImageEncoder.encode(url: url)
        }.value
        guard let output else {
            throw OpenRouterError.transport("Could not encode reference image.")
        }
        return OpenRouterContentPart(
            url: "data:\(output.mime);base64,\(output.data.base64EncodedString())"
        )
    }
}

private struct OpenRouterSupportedParameter: Decodable, Sendable, Equatable {
    let type: String?
    let values: [String]?
    let min: Int?
    let max: Int?

    var valuesIfEnum: [String]? {
        guard type == "enum" else { return nil }
        return values
    }
}

private struct OpenRouterImageModelArchitecture: Decodable, Sendable, Equatable {
    let inputModalities: [String]
    let outputModalities: [String]

    private enum CodingKeys: String, CodingKey {
        case inputModalities = "input_modalities"
        case outputModalities = "output_modalities"
    }
}

private struct OpenRouterImageModelListItem: Decodable, Sendable, Equatable {
    let id: String
    let name: String
    let description: String
    let architecture: OpenRouterImageModelArchitecture
    let supportedParameters: [String: OpenRouterSupportedParameter]

    private enum CodingKeys: String, CodingKey {
        case id, name, description, architecture
        case supportedParameters = "supported_parameters"
    }
}

private struct OpenRouterImageModelsListResponse: Decodable, Sendable {
    let data: [OpenRouterImageModelListItem]
}

private struct OpenRouterImageGenerationResponse: Decodable, Sendable {
    struct Item: Decodable, Sendable {
        let b64JSON: String
        let mediaType: String?

        private enum CodingKeys: String, CodingKey {
            case b64JSON = "b64_json"
            case mediaType = "media_type"
        }
    }

    let data: [Item]
}

private struct OpenRouterVideoModelListItem: Decodable, Sendable, Equatable {
    let id: String
    let name: String
    let description: String?
    let supportedResolutions: [String]?
    let supportedAspectRatios: [String]?
    let supportedDurations: [Int]?
    let supportedFrameImages: [String]?
    let generateAudio: Bool?

    private enum CodingKeys: String, CodingKey {
        case id, name, description
        case supportedResolutions = "supported_resolutions"
        case supportedAspectRatios = "supported_aspect_ratios"
        case supportedDurations = "supported_durations"
        case supportedFrameImages = "supported_frame_images"
        case generateAudio = "generate_audio"
    }
}

private struct OpenRouterVideoModelsListResponse: Decodable, Sendable {
    let data: [OpenRouterVideoModelListItem]
}

private struct OpenRouterVideoGenerationResponse: Decodable, Sendable {
    let id: String
    let pollingURL: String
    let status: String
    let generationId: String?
    let unsignedURLs: [String]?
    let error: String?

    private enum CodingKeys: String, CodingKey {
        case id, status, error
        case pollingURL = "polling_url"
        case generationId = "generation_id"
        case unsignedURLs = "unsigned_urls"
    }
}

private struct OpenRouterErrorEnvelope: Decodable, Sendable {
    struct Inner: Decodable, Sendable {
        let code: Int?
        let message: String
    }
    let error: Inner
}
