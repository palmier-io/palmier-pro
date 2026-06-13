import Foundation

/// App-level search model loader. Loads the SigLIP model on app launch.
@MainActor
@Observable
final class VisualModelLoader {
    static let shared = VisualModelLoader()

    enum State: Equatable {
        case unknown
        case notInstalled
        case downloading(Double)
        case preparing
        case ready
        case failed(String)
    }

    private(set) var state: State = .unknown
    private(set) var enabled = SearchIndexConfig.enabled
    @ObservationIgnored private(set) var embedder: VisualEmbedder?
    private let downloader = ModelDownloader()

    var isReady: Bool { state == .ready }

    private init() {}

    /// Loads an installed model if present; never downloads. Idempotent
    func prepare() async {
        guard enabled, state == .unknown else { return }
        guard let installed = ModelDownloader.installed(for: SearchIndexConfig.manifest) else {
            state = .notInstalled
            return
        }
        state = .preparing
        await load(installed)
    }

    func download() {
        switch state {
        case .downloading, .preparing, .ready: return
        default: break
        }
        state = .downloading(0)
        Task {
            do {
                let installed = try await downloader.install(
                    manifest: SearchIndexConfig.manifest, baseURL: SearchIndexConfig.baseURL
                ) { [weak self] fraction in
                    Task { @MainActor [weak self] in
                        guard let self, case .downloading = self.state else { return }
                        self.state = .downloading(fraction)
                    }
                }
                guard enabled else { state = .unknown; return }
                state = .preparing
                await load(installed)
            } catch {
                state = .failed(error.localizedDescription)
                Log.search.error("model download failed: \(error.localizedDescription)")
            }
        }
    }

    func setEnabled(_ value: Bool) {
        SearchIndexConfig.enabled = value
        enabled = value
        if value {
            Task { await prepare(); SearchIndexCoordinator.sweepAll() }
        } else {
            Task {
                await SearchIndexCoordinator.cancelAll()
                embedder = nil
                if state == .ready || state == .preparing { state = .unknown }
            }
        }
    }

    /// Deletes the installed model and resets every project's index state.
    func remove() async {
        await SearchIndexCoordinator.resetAll()
        embedder = nil
        state = .notInstalled
        try? FileManager.default.removeItem(at: ModelDownloader.modelsDir)
    }

    private func load(_ installed: ModelDownloader.InstalledModel) async {
        do {
            let loaded = try await Task.detached(priority: .userInitiated) {
                let tokenizer = try await TextTokenizer(
                    tokenizerFolder: installed.tokenizerFolder,
                    contextLength: installed.spec.contextLength
                )
                let model = try VisualEmbedder(
                    imageEncoderURL: installed.imageEncoderURL,
                    textEncoderURL: installed.textEncoderURL,
                    tokenizer: tokenizer,
                    spec: installed.spec
                )
                _ = try model.encode(text: "warm up")
                return model
            }.value
            embedder = loaded
            state = .ready
            Log.search.notice("search model ready dim=\(loaded.spec.embeddingDim)")
            SearchIndexCoordinator.sweepAll()
        } catch {
            state = .failed(error.localizedDescription)
            Log.search.error("search model load failed: \(error.localizedDescription)")
        }
    }
}
