import Foundation

extension ToolExecutor {
    private static let detectSilenceAllowedKeys: Set<String> = [
        "mediaRef", "silenceThresholdDb", "minSilenceDuration", "paddingSeconds",
    ]

    /// Detects silent (speech-free, low-level) segments in a media asset's audio, on-device.
    ///
    /// Returns the silent segments in source-media seconds. Complements `remove_silence`
    /// (which cuts dead air on the timeline): `detect_silence` only reports where dead air
    /// sits, so an agent or editor can decide whether to cut it. No transcript needed;
    /// runs locally on the asset's first audio track. File I/O and audio decoding happen
    /// off the main actor. Results are cached per asset + settings.
    func detectSilence(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.detectSilenceAllowedKeys, path: "detect_silence")
        let mediaRef = try args.requireString("mediaRef")
        let asset = try asset(mediaRef, editor: editor)
        guard asset.type == .audio || (asset.type == .video && asset.hasAudio) else {
            throw ToolError("detect_silence needs audio: \(mediaRef) is \(asset.type.rawValue)"
                + (asset.type == .video ? " with no audio track" : "") + ".")
        }
        guard FileManager.default.fileExists(atPath: asset.url.path) else {
            throw ToolError("Media file not on disk: \(asset.url.lastPathComponent)")
        }

        let thresholdDb = try Self.doubleArg(args, key: "silenceThresholdDb", defaultValue: -35.0)
        let minSilenceDuration = try Self.doubleArg(args, key: "minSilenceDuration", defaultValue: 0.5)
        let paddingSeconds = try Self.doubleArg(args, key: "paddingSeconds", defaultValue: 0.08)

        guard let settings = SilenceDetectionSettings(
            thresholdDb: thresholdDb, minSilenceDuration: minSilenceDuration,
            paddingSeconds: paddingSeconds
        ) else {
            throw ToolError("detect_silence: invalid silence-detection settings.")
        }

        let silenceStore = editor.mediaVisualCache.silenceStore
        let cacheKey = silenceCacheKey(
            mediaRef: mediaRef, thresholdDb: settings.thresholdDb,
            minSilenceDuration: settings.minSilenceDuration,
            paddingSeconds: settings.paddingSeconds
        )

        // Return cached segments for identical settings without re-decoding.
        if let cached = silenceStore.segments(for: cacheKey) {
            return try Self.detectSilenceResult(
                mediaRef: mediaRef, segments: cached, settings: settings
            )
        }

        // Decode and analyze off the main actor; file I/O must not run here.
        let url = asset.url
        let segments = try await Task.detached(priority: .utility) {
            try await SilenceDetector.detectSilentSegments(
                in: url,
                thresholdDb: settings.thresholdDb,
                minSilenceDuration: settings.minSilenceDuration,
                paddingSeconds: settings.paddingSeconds
            )
        }.value

        silenceStore.install(segments, for: cacheKey)
        return try Self.detectSilenceResult(
            mediaRef: mediaRef, segments: segments, settings: settings
        )
    }

    private static func detectSilenceResult(
        mediaRef: String, segments: [SilenceDetector.Segment], settings: SilenceDetectionSettings
    ) throws -> ToolResult {
        if segments.isEmpty {
            return .ok(
                #"{"mediaRef":"\#(mediaRef)","units":"source seconds","segments":[],"count":0,"totalSilentSeconds":0,"note":"No silent segments found above the threshold."}"#
            )
        }
        let total = segments.reduce(0) { $0 + $1.durationSeconds }
        let out: [String: Any] = [
            "mediaRef": mediaRef,
            "units": "source seconds — multiply by fps for frame values",
            "segments": segments.map {
                [
                    "startSeconds": NSDecimalNumber(string: String(format: "%.3f", $0.startSeconds)),
                    "endSeconds": NSDecimalNumber(string: String(format: "%.3f", $0.endSeconds)),
                    "durationSeconds": NSDecimalNumber(string: String(format: "%.3f", $0.durationSeconds)),
                ]
            },
            "count": segments.count,
            "totalSilentSeconds": NSDecimalNumber(string: String(format: "%.3f", total)),
            "silenceThresholdDb": settings.thresholdDb,
            "minSilenceDuration": settings.minSilenceDuration,
            "paddingSeconds": settings.paddingSeconds,
        ]
        guard let json = Self.jsonString(out) else { throw ToolError("Failed to encode result.") }
        return .ok(json)
    }
}

/// Validated silence-detection parameters.
struct SilenceDetectionSettings: Equatable, Sendable {
    static let thresholdDbRange = (-80.0)...(-20.0)
    static let minSilenceDurationRange = 0.1...30.0
    static let paddingSecondsRange = 0.0...2.0

    let thresholdDb: Double
    let minSilenceDuration: Double
    let paddingSeconds: Double

    init?(thresholdDb: Double, minSilenceDuration: Double, paddingSeconds: Double) {
        guard thresholdDb.isFinite, Self.thresholdDbRange.contains(thresholdDb),
              minSilenceDuration.isFinite, Self.minSilenceDurationRange.contains(minSilenceDuration),
              paddingSeconds.isFinite, Self.paddingSecondsRange.contains(paddingSeconds)
        else { return nil }
        self.thresholdDb = thresholdDb
        self.minSilenceDuration = minSilenceDuration
        self.paddingSeconds = paddingSeconds
    }
}

extension ToolExecutor {
    private static func doubleArg(
        _ args: [String: Any], key: String, defaultValue: Double
    ) throws -> Double {
        guard args[key] != nil else { return defaultValue }
        guard let value = args.double(key), value.isFinite else {
            throw ToolError("detect_silence: \(key) must be a finite number.")
        }
        return value
    }
}
