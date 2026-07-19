// Offline zh-en punctuation restoration for the Qwen3-ASR path — the sherpa qwen3 port emits an
// unpunctuated character stream, so a small ct-transformer model re-inserts the sentence/clause
// marks that natural segmentation and karaoke timing key off. Downloaded on demand; when absent or
// the model can't load, restoration is a no-op passthrough and transcription proceeds unpunctuated.
import CSherpaOnnx
import Foundation

/// Text in → punctuated text out. The seam lets tests inject a fake; real inference isn't unit-tested.
protocol PunctuationRestoring: Sendable {
    func restore(_ text: String) async -> String
}

/// Loads the sherpa offline punctuation model on demand and restores punctuation. Any failure —
/// offline download, missing files, model init — latches to passthrough so it's tried once, then
/// stays out of the way. Punctuation is best-effort and must never fail a transcription.
actor SherpaPunctuationRestorer: PunctuationRestoring {
    static let shared = SherpaPunctuationRestorer()

    enum RestorerError: Error {
        case downloadFailed(String)
    }

    private static let modelArchiveName = "sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12"
    private static let modelArchiveURL = URL(string:
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/punctuation-models/\(modelArchiveName).tar.bz2")!
    private static let installDir = ModelDownloader.modelsDir
        .appendingPathComponent(modelArchiveName, isDirectory: true)

    private static var modelPath: String? {
        let path = installDir.appendingPathComponent("model.onnx").path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    private var punct: OpaquePointer?
    private var loadFailed = false

    func restore(_ text: String) async -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let punct = await loaded() else { return text }
        guard let out = SherpaOfflinePunctuationAddPunct(punct, trimmed) else { return text }
        defer { SherpaOfflinePunctuationFreeText(out) }
        let restored = String(cString: out).trimmingCharacters(in: .whitespacesAndNewlines)
        return restored.isEmpty ? text : restored
    }

    private func loaded() async -> OpaquePointer? {
        if let punct { return punct }
        if loadFailed { return nil }
        do {
            try await Self.ensureModel()
        } catch {
            Log.transcription.warning(
                "punct model unavailable, captions stay unpunctuated: \(error.localizedDescription)")
            loadFailed = true
            return nil
        }
        guard let modelPath = Self.modelPath else { loadFailed = true; return nil }

        var config = SherpaOnnxOfflinePunctuationConfig()
        let created: OpaquePointer? = modelPath.withCString { modelPtr in
            "cpu".withCString { providerPtr in
                config.model.ct_transformer = modelPtr
                config.model.num_threads = 1
                config.model.provider = providerPtr
                return SherpaOnnxCreateOfflinePunctuation(&config)
            }
        }
        guard let created else { loadFailed = true; return nil }
        punct = created
        return created
    }

    private static func ensureModel() async throws {
        if modelPath != nil { return }
        Log.transcription.notice("punct model download start", telemetry: "Punctuation model download started")
        let (temp, response) = try await URLSession.shared.download(from: modelArchiveURL)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            try? FileManager.default.removeItem(at: temp)
            throw RestorerError.downloadFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("punct-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: staging)
            try? FileManager.default.removeItem(at: temp)
        }
        let untar = Process()
        untar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        untar.arguments = ["-xjf", temp.path, "-C", staging.path]
        try untar.run()
        untar.waitUntilExit()
        guard untar.terminationStatus == 0 else { throw RestorerError.downloadFailed("archive extraction failed") }

        let extracted = staging.appendingPathComponent(modelArchiveName, isDirectory: true)
        try FileManager.default.createDirectory(
            at: installDir.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: installDir)
        try FileManager.default.moveItem(at: extracted, to: installDir)
        guard modelPath != nil else { throw RestorerError.downloadFailed("archive missing model.onnx") }
        Log.transcription.notice("punct model installed", telemetry: "Punctuation model installed")
    }
}
