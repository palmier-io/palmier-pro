import AVFoundation
import Foundation

/// Cancellation flag shared with `AVAssetExportSession`'s callback, which is not actor-isolated.
final class ProxyCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var isCancelled: Bool { lock.withLock { flag } }
    func cancel() { lock.withLock { flag = true } }
}

/// Preview-only transcoded stand-ins for large source media.
///
/// A proxy exists to make scrubbing and playback cheap, not to be an edit decision. Two rules
/// keep that honest: export never resolves through this store, and a proxy is only used when it
/// is newer than the source it stands for. Deleting a proxy is always safe — the original is
/// still the source of truth.
actor ProxyStore {
    struct Settings: Sendable, Equatable {
        /// Longest-edge preset target. AVFoundation only offers fixed export presets, so this
        /// snaps to the nearest one; it is a request, not an exact size.
        var longEdge: Int = 960
        /// Source files at or above this size are worth proxying.
        var minimumSourceBytes: Int64 = 64 * 1024 * 1024

        /// Part of the cache filename, so changing a knob cannot reuse a stale proxy.
        var fingerprint: String { "\(longEdge)" }

        var exportPreset: String {
            switch longEdge {
            case 480: AVAssetExportPreset640x480
            case 720: AVAssetExportPreset1280x720
            case 1080: AVAssetExportPreset1920x1080
            default: AVAssetExportPreset960x540
            }
        }
    }

    struct Entry: Sendable, Equatable {
        var mediaRef: String
        var sourceURL: URL
        var proxyURL: URL
        var settings: Settings
        var sourceByteCount: Int64
        var sourceModifiedAt: Date
    }

    enum ProxyError: Error, CustomStringConvertible {
        case sourceUnreadable(String)
        case tooSmall(bytes: Int64, minimum: Int64)
        case exportFailed(String)
        case notAVMedia(String)
        case noExportSession(String)

        var description: String {
            switch self {
            case .sourceUnreadable(let path): "Can't read the source at \(path)."
            case .tooSmall(let bytes, let minimum):
                "Source is \(bytes / 1_048_576) MB, under the \(minimum / 1_048_576) MB proxy threshold."
            case .exportFailed(let reason): "Proxy transcode failed: \(reason)"
            case .notAVMedia(let ref): "\(ref) is not an audio or video asset."
            case .noExportSession(let ref): "No export preset available for \(ref)."
            }
        }
    }

    private let root: URL
    private var entries: [String: Entry] = [:]
    private var inFlight: Set<String> = []
    private var tokens: [String: ProxyCancellationToken] = [:]

    /// Proxies are a cache, not project state: they live in the app's caches directory so
    /// closing a project can never orphan them inside a `.compositorpro` package.
    static let diskCache = DiskCache(named: "Proxies")

    init(root: URL = ProxyStore.diskCache.directory) {
        self.root = root
    }

    func totalBytes() -> Int64 { DiskCache.bytes(at: root) }

    // MARK: - Lookup

    /// The proxy to decode, or nil when the original is the right choice.
    ///
    /// Returns nil unless the cached file still exists and the source has not changed since the
    /// proxy was made, so a replaced or re-linked asset can never decode from a stale stand-in.
    func url(for mediaRef: String, sourceURL: URL) -> URL? {
        guard let entry = entries[mediaRef], entry.settings.fingerprint == Settings().fingerprint else {
            return nil
        }
        guard FileManager.default.fileExists(atPath: entry.proxyURL.path) else {
            entries.removeValue(forKey: mediaRef)
            return nil
        }
        guard let values = try? sourceURL.resourceValues(
            forKeys: [.fileSizeKey, .contentModificationDateKey]
        ) else { return nil }
        let size = Int64(values.fileSize ?? -1)
        let modified = values.contentModificationDate
        guard size == entry.sourceByteCount, modified == entry.sourceModifiedAt else { return nil }
        return entry.proxyURL
    }

    func list() -> [Entry] { entries.values.sorted { $0.mediaRef < $1.mediaRef } }

    func isGenerating(_ mediaRef: String) -> Bool { inFlight.contains(mediaRef) }

    // MARK: - Lifecycle

    func cancel(_ mediaRef: String) { tokens[mediaRef]?.cancel() }

    func forget(_ mediaRef: String) {
        tokens.removeValue(forKey: mediaRef)?.cancel()
        guard let entry = entries.removeValue(forKey: mediaRef) else { return }
        try? FileManager.default.removeItem(at: entry.proxyURL)
    }

    /// Drops proxies for sources that are gone, plus any staged file left by an interrupted run.
    func prune(validMediaRefs: Set<String>) {
        for ref in entries.keys where !validMediaRefs.contains(ref) {
            forget(ref)
        }
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return }
        let known = Set(entries.values.map(\.proxyURL.lastPathComponent))
        for name in names where !known.contains(name) {
            try? fm.removeItem(at: root.appendingPathComponent(name))
        }
    }

    // MARK: - Generation

    /// Transcodes one asset. Never leaves a partial file where a proxy is expected: the export
    /// writes to a staging name and is moved into place only after it completes.
    func generate(
        mediaRef: String,
        sourceURL: URL,
        settings: Settings = Settings(),
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Entry {
        if let existing = entries[mediaRef] {
            if url(for: mediaRef, sourceURL: sourceURL) != nil { return existing }
            forget(mediaRef)
        }
        let values = try sourceURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let byteCount = Int64(values.fileSize ?? 0)
        guard byteCount >= settings.minimumSourceBytes else {
            throw ProxyError.tooSmall(bytes: byteCount, minimum: settings.minimumSourceBytes)
        }
        let asset = AVURLAsset(url: sourceURL)
        let hasAV = !asset.tracks(withMediaType: .video).isEmpty
            || !asset.tracks(withMediaType: .audio).isEmpty
        guard hasAV else { throw ProxyError.notAVMedia(mediaRef) }
        guard let session = AVAssetExportSession(asset: asset, presetName: settings.exportPreset) else {
            throw ProxyError.noExportSession(mediaRef)
        }

        let token = ProxyCancellationToken()
        inFlight.insert(mediaRef)
        tokens[mediaRef] = token
        defer {
            inFlight.remove(mediaRef)
            tokens.removeValue(forKey: mediaRef)
        }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let stem = "\(Self.safeName(mediaRef))-\(settings.fingerprint)"
        let finalURL = root.appendingPathComponent("\(stem).mov")
        let stagingURL = root.appendingPathComponent("\(stem).\(UUID().uuidString).staging")
        defer { try? FileManager.default.removeItem(at: stagingURL) }

        session.outputURL = stagingURL
        session.outputFileType = .mov
        session.shouldOptimizeForNetworkUse = true
        session.timeRange = CMTimeRange(start: .zero, duration: asset.duration)
        try await ExportRunner(session: session, token: token, onProgress: onProgress).run()
        try Task.checkCancellation()
        guard !token.isCancelled else { throw CancellationError() }

        if FileManager.default.fileExists(atPath: finalURL.path) {
            try FileManager.default.removeItem(at: finalURL)
        }
        try FileManager.default.moveItem(at: stagingURL, to: finalURL)

        let entry = Entry(
            mediaRef: mediaRef, sourceURL: sourceURL, proxyURL: finalURL, settings: settings,
            sourceByteCount: byteCount, sourceModifiedAt: values.contentModificationDate ?? .distantPast
        )
        entries[mediaRef] = entry
        return entry
    }

    private static func safeName(_ ref: String) -> String {
        String(ref.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" })
    }
}

/// Bridges `AVAssetExportSession`'s callback API into async and makes it cancellable.
private final class ExportRunner: @unchecked Sendable {
    private let session: AVAssetExportSession
    private let token: ProxyCancellationToken
    private let onProgress: (@Sendable (Double) -> Void)?
    private var continuation: CheckedContinuation<Void, Error>?
    private var reportedProgress = false
    private var settled = false

    init(session: AVAssetExportSession, token: ProxyCancellationToken, onProgress: (@Sendable (Double) -> Void)?) {
        self.session = session
        self.token = token
        self.onProgress = onProgress
    }

    func run() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.continuation = continuation
                let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                    self?.poll()
                }
                session.exportAsynchronously { [weak self] in
                    timer.invalidate()
                    self?.finish()
                }
            }
        } onCancel: {
            session.cancelExport()
            token.cancel()
        }
    }

    private func poll() {
        guard !settled, !reportedProgress else { return }
        guard session.progress > 0 else { return }
        reportedProgress = true
        onProgress?(Double(session.progress))
    }

    private func finish() {
        guard !settled else { return }
        settled = true
        switch session.status {
        case .completed:
            onProgress?(1)
            continuation?.resume()
        case .cancelled:
            continuation?.resume(throwing: CancellationError())
        default:
            continuation?.resume(throwing: session.error ?? CancellationError())
        }
    }
}
