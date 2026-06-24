import AVFoundation
import CoreGraphics
import Foundation

extension ToolExecutor {
    private static let analyzeFootageQualityAllowedKeys: Set<String> = [
        "mediaRef", "clipId", "startSeconds", "endSeconds", "sampleFPS", "windowSeconds"
    ]

    func analyzeFootageQuality(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.analyzeFootageQualityAllowedKeys, path: "analyze_footage_quality")
        let mediaRef = try args.requireString("mediaRef")
        let asset = try asset(mediaRef, editor: editor)
        guard asset.type == .video else {
            throw ToolError("analyze_footage_quality: \(asset.name) is not a video asset.")
        }
        guard asset.duration > 0 else {
            throw ToolError("analyze_footage_quality: \(asset.name) has zero duration.")
        }

        let start = max(0, args.double("startSeconds") ?? 0)
        let end = min(asset.duration, args.double("endSeconds") ?? asset.duration)
        guard end > start else {
            throw ToolError("analyze_footage_quality: endSeconds must be greater than startSeconds.")
        }
        let sampleFPS = min(max(args.double("sampleFPS") ?? 4, 1), 8)
        let windowSeconds = min(max(args.double("windowSeconds") ?? 2, 0.75), 6)

        let mapping = try clipMapping(editor: editor, mediaRef: asset.id, clipId: args.string("clipId"))
        let analysis = try await FootageQualityAnalyzer.analyze(
            url: asset.url,
            start: start,
            end: end,
            sampleFPS: sampleFPS,
            windowSeconds: windowSeconds,
            fps: editor.timeline.fps,
            clip: mapping
        )

        var payload = analysis
        payload["mediaRef"] = asset.id
        payload["name"] = asset.name
        payload["durationSeconds"] = asset.duration
        payload["sampleFPS"] = sampleFPS
        payload["windowSeconds"] = windowSeconds
        if let mapping {
            payload["timelineMapping"] = Self.timelineMappingMeta(clip: mapping, fps: editor.timeline.fps)
        }

        guard let json = Self.jsonString(roundJSONFloatingPointNumbers(payload, toPlaces: 3)) else {
            throw ToolError("analyze_footage_quality: failed to encode result.")
        }
        return .ok(json)
    }

    private func clipMapping(editor: EditorViewModel, mediaRef: String, clipId: String?) throws -> Clip? {
        guard let clipId else { return nil }
        guard let loc = editor.findClip(id: clipId) else {
            throw ToolError("analyze_footage_quality: clipId not found: \(clipId)")
        }
        let clip = editor.timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
        guard clip.mediaRef == mediaRef else {
            throw ToolError("analyze_footage_quality: clip \(clipId) does not reference mediaRef \(mediaRef).")
        }
        return clip
    }
}

private enum FootageQualityAnalyzer {
    private struct SharpnessThresholds {
        let blurry: Double
        let clear: Double
    }

    private struct FrameMetric {
        let time: Double
        let sharpness: Double
        let luma: [Float]
        let motion: Motion?
    }

    private struct Motion {
        let dx: Int
        let dy: Int
        let magnitude: Double
        let residual: Double
        let visualChange: Double
    }

    static func analyze(
        url: URL,
        start: Double,
        end: Double,
        sampleFPS: Double,
        windowSeconds: Double,
        fps: Int,
        clip: Clip?
    ) async throws -> [String: Any] {
        let frames = try await sampleFrames(url: url, start: start, end: end, sampleFPS: sampleFPS)
        guard frames.count >= 2 else {
            throw ToolError("analyze_footage_quality: not enough frames decoded for analysis.")
        }

        let thresholds = sharpnessThresholds(frames)
        let windows = makeWindows(frames: frames, windowSeconds: windowSeconds, fps: fps, clip: clip, thresholds: thresholds)
        let best = windows
            .filter {
                (($0["isUsable"] as? Bool) ?? false)
                    && (($0["qualityScore"] as? Double) ?? 0) >= 0.65
                    && (($0["durationSeconds"] as? Double) ?? 0) >= 0.5
            }
            .prefix(8)
            .map { window -> [String: Any] in
                var out: [String: Any] = [
                    "startSeconds": window["startSeconds"] ?? 0,
                    "endSeconds": window["endSeconds"] ?? 0,
                    "qualityScore": window["qualityScore"] ?? 0,
                    "stability": window["stability"] ?? "unknown",
                    "clarity": window["clarity"] ?? "unknown",
                ]
                if let a = window["projectStartFrame"] { out["projectStartFrame"] = a }
                if let b = window["projectEndFrame"] { out["projectEndFrame"] = b }
                return out
            }

        return [
            "timeRange": [start, end],
            "frameCount": frames.count,
            "metricNotes": [
                "sharpness: normalized edge detail; low values usually mean blur or missed focus",
                "clarity: clear windows are eligible for bestRanges; blurry and soft windows are excluded",
                "motion: estimated global frame-to-frame translation",
                "jitter: erratic motion after translation matching; high values usually mean shaky handheld footage",
                "visualChange: residual luma change; high values can mean subject motion, lighting change, or a cut",
            ],
            "sharpnessThresholds": [
                "blurryBelow": thresholds.blurry,
                "clearAtOrAbove": thresholds.clear,
            ],
            "bestRanges": Array(best),
            "windows": windows,
        ]
    }

    private static func sampleFrames(url: URL, start: Double, end: Double, sampleFPS: Double) async throws -> [FrameMetric] {
        let asset = AVURLAsset(url: url)
        guard (try? await asset.loadTracks(withMediaType: .video).first) != nil else {
            throw ToolError("analyze_footage_quality: no video track available.")
        }

        let interval = 1 / sampleFPS
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 384, height: 384)
        let tolerance = CMTime(seconds: interval / 2, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        let times = stride(from: start, to: end, by: interval)
            .map { CMTime(seconds: $0, preferredTimescale: 600) }
        var frames: [FrameMetric] = []
        var lastLuma: [Float]?
        var lastTime = -Double.infinity

        for await result in generator.images(for: times) {
            guard case .success(_, let image, let actualTime) = result else { continue }
            let time = actualTime.seconds
            guard time > lastTime else { continue }
            lastTime = time
            guard let luma = LumaPlane.compute(image, width: 32, height: 18) else { continue }
            let sharpness = LumaPlane.sharpness(luma, width: 32, height: 18)
            let motion = lastLuma.map { estimateMotion(from: $0, to: luma, width: 32, height: 18) }
            frames.append(FrameMetric(time: time, sharpness: sharpness, luma: luma, motion: motion))
            lastLuma = luma
        }
        return frames
    }

    private static func makeWindows(
        frames: [FrameMetric],
        windowSeconds: Double,
        fps: Int,
        clip: Clip?,
        thresholds: SharpnessThresholds
    ) -> [[String: Any]] {
        let first = frames.first?.time ?? 0
        let last = frames.last?.time ?? first
        var windows: [[String: Any]] = []
        var start = first

        while start < last {
            let end = min(start + windowSeconds, last)
            let slice = frames.filter { $0.time >= start && $0.time <= end }
            if slice.count >= 2 {
                windows.append(scoreWindow(slice, start: start, end: end, fps: fps, clip: clip, thresholds: thresholds))
            }
            start = end
        }
        return windows.sorted {
            (($0["qualityScore"] as? Double) ?? 0) > (($1["qualityScore"] as? Double) ?? 0)
        }
    }

    private static func scoreWindow(
        _ frames: [FrameMetric],
        start: Double,
        end: Double,
        fps: Int,
        clip: Clip?,
        thresholds: SharpnessThresholds
    ) -> [String: Any] {
        let motions = frames.compactMap(\.motion)
        let sharpness = frames.map(\.sharpness).average
        let motion = motions.map(\.magnitude).average
        let residual = motions.map(\.residual).average
        let visualChange = motions.map(\.visualChange).average
        let jitter = motionJitter(motions)
        let stabilityScore = clamp01(1 - jitter * 1.6 - residual * 0.9)
        let staticPenalty = visualChange < 0.015 && motion < 0.05 ? 0.08 : 0
        let highMotionPenalty = motion > 0.6 ? min((motion - 0.6) * 0.25, 0.15) : 0
        let clarity = clarityLabel(sharpness: sharpness, thresholds: thresholds)
        let blurPenalty: Double = clarity == "clear" ? 0 : (clarity == "soft" ? 0.22 : 0.45)
        let quality = clamp01(
            sharpness * 0.45
                + stabilityScore * 0.45
                + min(visualChange * 3, 1) * 0.1
                - staticPenalty
                - highMotionPenalty
                - blurPenalty
        )
        let stability = stabilityLabel(stabilityScore: stabilityScore, jitter: jitter, motion: motion)

        var issues: [String] = []
        if stability == "shaky" { issues.append("shaky") }
        if clarity == "blurry" { issues.append("blurry") }
        if clarity == "soft" { issues.append("soft focus") }
        if visualChange < 0.015 && motion < 0.05 { issues.append("static") }
        if motion > 0.65 { issues.append("high motion") }
        if residual > 0.22 { issues.append("large visual change") }
        let isUsable = clarity == "clear" && stability != "shaky"

        var out: [String: Any] = [
            "startSeconds": start,
            "endSeconds": end,
            "durationSeconds": end - start,
            "qualityScore": quality,
            "stability": stability,
            "stabilityScore": stabilityScore,
            "clarity": clarity,
            "sharpness": sharpness,
            "motion": motion,
            "jitter": jitter,
            "visualChange": visualChange,
            "isUsable": isUsable,
            "issues": issues,
        ]
        if let mapped = projectFrames(start: start, end: end, fps: fps, clip: clip) {
            out["projectStartFrame"] = mapped.start
            out["projectEndFrame"] = mapped.end
        }
        return out
    }

    private static func sharpnessThresholds(_ frames: [FrameMetric]) -> SharpnessThresholds {
        let values = frames.map(\.sharpness).sorted()
        let high = percentile(values, 0.9)
        let clear = max(0.34, high * 0.68)
        let blurry = max(0.24, min(clear * 0.72, high * 0.48))
        return SharpnessThresholds(blurry: blurry, clear: clear)
    }

    private static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let index = min(max(Int((Double(values.count - 1) * p).rounded()), 0), values.count - 1)
        return values[index]
    }

    private static func clarityLabel(sharpness: Double, thresholds: SharpnessThresholds) -> String {
        if sharpness < thresholds.blurry { return "blurry" }
        if sharpness < thresholds.clear { return "soft" }
        return "clear"
    }

    private static func estimateMotion(from a: [Float], to b: [Float], width: Int, height: Int) -> Motion {
        var bestDX = 0
        var bestDY = 0
        var best = Float.greatestFiniteMagnitude
        for dy in -2...2 {
            for dx in -2...2 {
                let diff = shiftedMeanDiff(a, b, width: width, height: height, dx: dx, dy: dy)
                if diff < best {
                    best = diff
                    bestDX = dx
                    bestDY = dy
                }
            }
        }
        let raw = LumaPlane.meanDiff(a, b) / 255
        let residual = Double(best / 255)
        let magnitude = sqrt(Double(bestDX * bestDX + bestDY * bestDY)) / sqrt(8)
        return Motion(dx: bestDX, dy: bestDY, magnitude: magnitude, residual: residual, visualChange: Double(raw))
    }

    private static func shiftedMeanDiff(_ a: [Float], _ b: [Float], width: Int, height: Int, dx: Int, dy: Int) -> Float {
        var diff: Float = 0
        var count: Float = 0
        for y in 0..<height {
            let by = y + dy
            guard by >= 0 && by < height else { continue }
            for x in 0..<width {
                let bx = x + dx
                guard bx >= 0 && bx < width else { continue }
                diff += abs(a[y * width + x] - b[by * width + bx])
                count += 1
            }
        }
        return count > 0 ? diff / count : .greatestFiniteMagnitude
    }

    private static func motionJitter(_ motions: [Motion]) -> Double {
        guard motions.count >= 3 else { return motions.map(\.magnitude).average * 0.5 }
        var changes: [Double] = []
        for i in 1..<motions.count {
            let dx = Double(motions[i].dx - motions[i - 1].dx)
            let dy = Double(motions[i].dy - motions[i - 1].dy)
            changes.append(sqrt(dx * dx + dy * dy) / sqrt(32))
        }
        return changes.average
    }

    private static func stabilityLabel(stabilityScore: Double, jitter: Double, motion: Double) -> String {
        if stabilityScore < 0.45 || jitter > 0.45 { return "shaky" }
        if motion > 0.45 { return "moving" }
        if stabilityScore > 0.75 { return "stable" }
        return "usable"
    }

    private static func projectFrames(start: Double, end: Double, fps: Int, clip: Clip?) -> (start: Int, end: Int)? {
        guard let clip else { return nil }
        let sourceStart = start * Double(fps)
        let sourceEnd = end * Double(fps)
        let visibleStart = Double(clip.trimStartFrame)
        let visibleEnd = visibleStart + Double(clip.durationFrames) * max(clip.speed, 0.0001)
        let clampedStart = max(sourceStart, visibleStart)
        let clampedEnd = min(sourceEnd, visibleEnd)
        guard clampedEnd > clampedStart else { return nil }
        let timelineStart = Double(clip.startFrame) + (clampedStart - visibleStart) / max(clip.speed, 0.0001)
        let timelineEnd = Double(clip.startFrame) + (clampedEnd - visibleStart) / max(clip.speed, 0.0001)
        return (Int(timelineStart.rounded()), Int(timelineEnd.rounded()))
    }

    private static func clamp01(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

private enum LumaPlane {
    static func compute(_ image: CGImage, width: Int, height: Int) -> [Float]? {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let ctx = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (0..<width * height).map { i in
            Float(pixels[i * 4]) * 0.299 + Float(pixels[i * 4 + 1]) * 0.587 + Float(pixels[i * 4 + 2]) * 0.114
        }
    }

    static func sharpness(_ luma: [Float], width: Int, height: Int) -> Double {
        guard width > 2, height > 2 else { return 0 }
        var total: Float = 0
        var count: Float = 0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let i = y * width + x
                let gx = abs(luma[i + 1] - luma[i - 1])
                let gy = abs(luma[i + width] - luma[i - width])
                total += gx + gy
                count += 1
            }
        }
        return min(Double((total / max(count, 1)) / 55), 1)
    }

    static func meanDiff(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var diff: Float = 0
        for i in a.indices { diff += abs(a[i] - b[i]) }
        return diff / Float(a.count)
    }
}

private extension Array where Element == Double {
    var average: Double {
        isEmpty ? 0 : reduce(0, +) / Double(count)
    }
}
