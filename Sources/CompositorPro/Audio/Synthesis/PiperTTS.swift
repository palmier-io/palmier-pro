import Foundation

/// Neural speech synthesis through a locally installed Piper binary and voice models.
///
/// Piper is MIT-licensed and runs entirely on this machine: no network, no key, no credits, and
/// far more natural than the system voices. Models live in a user-owned directory the user or the
/// Agent populates; nothing here downloads anything on its own, because synthesis must never
/// silently reach the network.
///
/// Every invocation is a subprocess, so it is off the main actor, cancellable, and bounded by the
/// caller's chunking rather than by Piper's own memory use.
enum PiperTTS {
    /// Where voice models are installed. Deliberately Application Support, not Caches: a model is
    /// a real dependency the user chose, and evicting it would silently change how the app sounds.
    nonisolated static var voiceDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CompositorPro/PiperVoices", isDirectory: true)
    }

    /// Resolved `piper` executable, or nil when it is not installed.
    nonisolated static func executableURL() -> URL? {
        var candidates: [URL] = []
        if let path = ProcessInfo.processInfo.environment["COMPOSITOR_PIPER"] {
            candidates.append(URL(fileURLWithPath: path))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        candidates.append(home.appendingPathComponent(".local/bin/piper"))
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/opt/homebrew/opt/piper/bin"] {
            candidates.append(URL(fileURLWithPath: dir).appendingPathComponent("piper"))
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static var isAvailable: Bool { executableURL() != nil }

    /// An installed voice, so the Agent can choose by language instead of guessing a filename.
    struct Model: Sendable, Equatable, Identifiable {
        var id: String { fileName }
        /// File name without extension, e.g. `en_US-amy-medium`.
        var fileName: String
        var language: String
        var quality: String
        /// Path Piper is given: the `.onnx` file, with its `.json` config alongside.
        var modelURL: URL

        /// Best-effort BCP-47 tag, so it can be matched against the rest of the tool surface.
        var languageTag: String { language.replacingOccurrences(of: "_", with: "-") }
    }

    enum PiperError: Error, CustomStringConvertible, Equatable {
        case notInstalled
        case noVoicesInstalled
        case noVoiceForLanguage(String, available: [String])
        case modelMissing(String)
        case failed(status: Int32, message: String)
        case producedNoAudio
        case cancelled

        var description: String {
            switch self {
            case .notInstalled:
                "Piper is not installed. Install it with: uv tool install piper-tts"
            case .noVoicesInstalled:
                "No Piper voices are installed. Download a voice .onnx (plus its .onnx.json) into "
                    + voiceDirectory.path
            case .noVoiceForLanguage(let tag, let available):
                "No Piper voice for \(tag). Installed: \(available.isEmpty ? "none" : available.joined(separator: ", ")). "
                    + "The system voice will be used instead."
            case .modelMissing(let name): "Piper voice \(name) is not installed."
            case .failed(let status, let message):
                "Piper failed (exit \(status)): \(message.isEmpty ? "no output" : message)"
            case .producedNoAudio: "Piper produced no audio."
            case .cancelled: "Speech synthesis was cancelled."
            }
        }
    }

    // MARK: - Voices

    /// Installed voices, best quality first so callers that take the first acceptable match
    /// get the most natural voice installed rather than the smallest one. `directory` is
    /// injectable so discovery can be exercised against a fixture instead of whatever
    /// happens to be installed on the machine running the tests.
    static func installedModels(in directory: URL? = nil) -> [Model] {
        let root = directory ?? voiceDirectory
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        return names
            .filter { $0.hasSuffix(".onnx") }
            .compactMap { name in
                let modelURL = root.appendingPathComponent(name)
                guard fm.fileExists(atPath: modelURL.path) else { return nil }
                return parseModel(fileName: name, modelURL: modelURL)
            }
            .sorted { lhs, rhs in
                let left = qualityRank(lhs.quality)
                let right = qualityRank(rhs.quality)
                if left != right { return left > right }
                return lhs.fileName < rhs.fileName
            }
    }

    static func models(matchingLanguage tag: String) -> [Model] {
        let wanted = tag.lowercased()
        return installedModels().filter { $0.languageTag.lowercased() == wanted }
    }

    /// Every language that has an installed voice.
    static var installedLanguages: [String] {
        Array(Set(installedModels().map(\.languageTag))).sorted()
    }

    private static func qualityRank(_ quality: String) -> Int {
        switch quality.lowercased() {
        case "x_low": return 0
        case "low": return 1
        case "medium": return 2
        case "high": return 3
        default: return 2
        }
    }

    /// Filenames follow the published convention `<language>_<name>-<quality>`, e.g.
    /// `en_US-amy-medium`. An oddly named file still yields a usable model because its language
    /// comes from the config, so it is not silently invisible.
    private static func parseModel(fileName: String, modelURL: URL) -> Model {
        let stem = (fileName as NSString).deletingPathExtension
        let parts = stem.split(separator: "-").map(String.init)
        var quality = "medium"
        if parts.count >= 3 {
            quality = parts[parts.count - 1]
        } else if parts.count == 2, ["x_low", "low", "medium", "high"].contains(parts[1].lowercased()) {
            quality = parts[1]
        }
        // The model's own config is authoritative; the filename is only a fallback.
        let language = configuredLanguage(modelURL: modelURL) ?? parts.first ?? "und"
        return Model(fileName: stem, language: language, quality: quality, modelURL: modelURL)
    }

    private static func configuredLanguage(modelURL: URL) -> String? {
        let configURL = modelURL.appendingPathExtension("json")
        guard let data = try? Data(contentsOf: configURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        // Current Piper configs nest the locale under "code"; older ones use a bare string.
        let code: String?
        if let nested = object["language"] as? [String: Any] {
            code = nested["code"] as? String
        } else {
            code = object["language"] as? String
        }
        guard let code, !code.isEmpty else { return nil }
        // Piper writes an underscore locale.
        return code.replacingOccurrences(of: "_", with: "-")
    }

    /// Picks a voice for a BCP-47 tag: exact match first, then the base language, so `en-GB`
    /// still finds `en_US`. Returns nil rather than guessing, so the caller can fall back.
    static func model(forLanguage tag: String?) -> Model? {
        guard let tag, !tag.isEmpty else { return installedModels().first }
        if let exact = models(matchingLanguage: tag).first { return exact }
        let base = tag.split(separator: "-").first.map(String.init)?.lowercased()
        guard let base else { return nil }
        return installedModels().first { $0.languageTag.lowercased().split(separator: "-").first.map(String.init) == base }
    }

    static func model(named name: String) -> Model? {
        installedModels().first { $0.fileName.lowercased() == name.lowercased() }
            ?? installedModels().first { $0.fileName.lowercased().hasPrefix(name.lowercased()) }
    }

    // MARK: - Rendering

    /// Renders one chunk to a WAV. Blocking; callers must already be off the main actor.
    static func render(
        text: String,
        model: Model,
        lengthScale: Double,
        isCancelled: () -> Bool
    ) throws -> URL {
        guard let executable = executableURL() else { throw PiperError.notInstalled }
        guard FileManager.default.fileExists(atPath: model.modelURL.path) else {
            throw PiperError.modelMissing(model.fileName)
        }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("piper-\(UUID().uuidString).wav")
        // Cleaned up only on a failed run: the returned path is the caller's file to own.
        func cleanUpOnFailure() {
            try? FileManager.default.removeItem(at: output)
        }

        let process = Process()
        process.executableURL = executable
        // Silence keeps Piper's progress chatter out of the app's console.
        process.standardOutput = FileHandle.nullDevice
        let errorPipe = Pipe()
        process.standardError = errorPipe

        var arguments = ["-m", model.modelURL.path, "-f", output.path]
        // Piper's length scale is inverse to a speaking-rate multiplier.
        if lengthScale > 0, abs(lengthScale - 1) > 0.001 {
            arguments += ["--length-scale", String(format: "%.3f", lengthScale)]
        }
        process.arguments = arguments

        let input = Pipe()
        process.standardInput = input
        do {
            try process.run()
        } catch {
            cleanUpOnFailure()
            throw PiperError.failed(status: -1, message: error.localizedDescription)
        }
        // Piper reads the utterance from stdin and does not stream a long one reliably, so the
        // text goes in and the pipe closes before the wait.
        input.fileHandleForWriting.write(Data(text.utf8))
        try? input.fileHandleForWriting.close()

        // Bounded: a corrupt model must not hang the render forever.
        let deadline = Date().addingTimeInterval(120)
        while process.isRunning {
            if isCancelled() {
                process.terminate()
                cleanUpOnFailure()
                throw PiperError.cancelled
            }
            if Date() > deadline {
                process.terminate()
                cleanUpOnFailure()
                throw PiperError.failed(status: -1, message: "timed out after 120s")
            }
            usleep(20_000)
        }
        process.waitUntilExit()

        let status = process.terminationStatus
        guard status == 0 else {
            let message = String(
                data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            cleanUpOnFailure()
            throw PiperError.failed(status: status, message: String(message.prefix(400)))
        }
        guard !isCancelled() else {
            cleanUpOnFailure()
            throw PiperError.cancelled
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int64) ?? 0
        guard size > 44 else {
            cleanUpOnFailure()
            throw PiperError.producedNoAudio
        }
        return output
    }
}