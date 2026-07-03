import Foundation

extension ToolExecutor {
    func analyzeAudioBeats(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: ["mediaRef"], path: "analyze_audio_beats")
        let mediaRef = try args.requireString("mediaRef")
        let asset = try self.asset(mediaRef, editor: editor)

        guard asset.type == .audio || (asset.type == .video && asset.hasAudio) else {
            throw ToolError("Asset '\(asset.name)' has no audio track. Only audio or video-with-audio assets can be analyzed.")
        }

        Log.agent.notice(
            "beat-detect start asset=\(asset.name)",
            telemetry: "Beat detection started",
            data: ["assetId": asset.id, "assetType": asset.type.rawValue]
        )

        let analysis: BeatAnalysis
        do {
            analysis = try await BeatDetector.analyze(url: asset.url)
        } catch {
            throw ToolError("Beat analysis failed: \(error.localizedDescription)")
        }

        let fps = Double(editor.timeline.fps)

        // Convert beat/downbeat seconds to project frames
        let beatsInFrames    = analysis.beats.map { Int(($0 * fps).rounded()) }
        let downbeatsInFrames = analysis.downbeats.map { Int(($0 * fps).rounded()) }

        // Beat interval in frames — the natural cut length for one beat
        let beatIntervalFrames = beatsInFrames.count > 1
            ? beatsInFrames[1] - beatsInFrames[0]
            : Int((60.0 / analysis.bpm * fps).rounded())

        let payload: [String: Any] = [
            "bpm": analysis.bpm,
            "confidence": (analysis.confidence * 100).rounded() / 100,
            "durationSeconds": analysis.durationSeconds,
            "fps": fps,
            "beatCount": analysis.beats.count,
            "beatIntervalFrames": beatIntervalFrames,
            "downbeatCount": analysis.downbeats.count,
            "beats": analysis.beats.map { (($0 * 100).rounded() / 100) },
            "beatsInFrames": beatsInFrames,
            "downbeats": analysis.downbeats.map { (($0 * 100).rounded() / 100) },
            "downbeatsInFrames": downbeatsInFrames,
            "climaxSeconds": (analysis.climaxSec * 100).rounded() / 100,
            "climaxFrame": Int((analysis.climaxSec * fps).rounded()),
            "energy": [
                "stepSeconds": (analysis.energyStepSec * 100).rounded() / 100,
                "curve": analysis.energyCurve.map { (($0 * 100).rounded() / 100) },
                "note": "Smoothed loudness envelope, 0–1, one value per stepSeconds. climaxSeconds is its peak (chorus/drop). To open a video at the music's climax, trim the music clip so source playback starts at climaxSeconds (use trimStartFrame = climaxFrame when the music is placed at project fps).",
            ],
        ]

        Log.agent.notice(
            "beat-detect ok bpm=\(analysis.bpm) beats=\(analysis.beats.count) confidence=\(analysis.confidence)",
            telemetry: "Beat detection finished",
            data: [
                "assetId": asset.id,
                "bpm": analysis.bpm,
                "beatCount": analysis.beats.count,
                "confidence": analysis.confidence,
            ]
        )

        guard let json = Self.jsonString(payload) else {
            throw ToolError("Failed to encode beat analysis result.")
        }
        return .ok(json)
    }
}
