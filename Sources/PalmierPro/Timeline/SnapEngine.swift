import AppKit
import Foundation

enum SnapEngine {

    // MARK: - Types

    struct SnapTarget {
        let frame: Int
        let kind: Kind
        enum Kind { case playhead, clipEdge, beat }
    }

    struct SnapResult {
        let frame: Int
        let probeOffset: Int // which probe snapped (0=start, duration=end)
        let x: Double // snap indicator pixel position
    }

    /// Mutable state that persists across drag events for sticky snap behavior.
    struct SnapState {
        var currentlySnappedTo: Int?
        var currentProbeOffset: Int = 0 // which probe is sticky
    }

    // MARK: - Target collection

    /// Collects all clip edges, and optionally the playhead, as snap targets.
    /// Pass `excludeClipIds` to skip clips being dragged.
    /// Pass `includePlayhead: true` when the playhead itself is NOT what's being moved.
    static func collectTargets(
        tracks: [Track],
        playheadFrame: Int = 0,
        excludeClipIds: Set<String> = [],
        includePlayhead: Bool = false,
        beatFrames: ((Clip) -> [Int])? = nil,
        includeExcludedClipBeats: Bool = false
    ) -> [SnapTarget] {
        var targets: [SnapTarget] = []
        if includePlayhead {
            targets.append(SnapTarget(frame: playheadFrame, kind: .playhead))
        }
        for track in tracks {
            for clip in track.clips {
                let excluded = excludeClipIds.contains(clip.id)
                if !excluded {
                    targets.append(SnapTarget(frame: clip.startFrame, kind: .clipEdge))
                    targets.append(SnapTarget(frame: clip.endFrame, kind: .clipEdge))
                }
                if let beatFrames, !excluded || includeExcludedClipBeats {
                    for frame in beatFrames(clip) {
                        targets.append(SnapTarget(frame: frame, kind: .beat))
                    }
                }
            }
        }
        return targets
    }

    // MARK: - Snap finding

    /// Snap position(s) to nearest target, with sticky behavior and playhead priority.
    /// Tests one or more probe positions (e.g., clip start and end) against all targets.
    static func findSnap(
        position: Int,
        probeOffsets: [Int] = [0],
        targets: [SnapTarget],
        state: inout SnapState,
        baseThreshold: Double,
        pixelsPerFrame: Double
    ) -> SnapResult? {
        let baseFrameThreshold = baseThreshold / pixelsPerFrame

        // Sticky: stay snapped until moved 2.5x threshold away
        if let snapped = state.currentlySnappedTo {
            let holdThreshold = baseFrameThreshold * Snap.stickyMultiplier
            let probePos = position + state.currentProbeOffset
            if abs(Double(probePos - snapped)) <= holdThreshold,
               targets.contains(where: { $0.frame == snapped }) {
                return SnapResult(frame: snapped, probeOffset: state.currentProbeOffset, x: Double(snapped) * pixelsPerFrame)
            }
            state.currentlySnappedTo = nil
            state.currentProbeOffset = 0
        }

        // Find closest (probe, target) pair
        var best: (probeOffset: Int, target: SnapTarget, distance: Double)?
        for probeOffset in probeOffsets {
            let probePos = position + probeOffset
            for target in targets {
                let threshold: Double = switch target.kind {
                case .playhead: baseFrameThreshold * Snap.playheadMultiplier
                case .clipEdge, .beat: baseFrameThreshold
                }
                let dist = abs(Double(probePos - target.frame))
                if dist <= threshold, dist < (best?.distance ?? .infinity) {
                    best = (probeOffset, target, dist)
                }
            }
        }

        guard let best else { return nil }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        state.currentlySnappedTo = best.target.frame
        state.currentProbeOffset = best.probeOffset
        return SnapResult(frame: best.target.frame, probeOffset: best.probeOffset, x: Double(best.target.frame) * pixelsPerFrame)
    }

}
