import Foundation

enum SnapEngine {

    // MARK: - Types

    struct SnapTarget {
        let frame: Int
        let kind: Kind
        enum Kind { case playhead, clipEdge }
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

    /// Collects all clip edges and the playhead as snap targets.
    /// Optionally excludes specific clip IDs (e.g., the clip being dragged).
    static func collectTargets(
        tracks: [Track],
        playheadFrame: Int,
        excludeClipIds: Set<String> = []
    ) -> [SnapTarget] {
        var targets = [SnapTarget(frame: playheadFrame, kind: .playhead)]
        for track in tracks {
            for clip in track.clips where !excludeClipIds.contains(clip.id) {
                targets.append(SnapTarget(frame: clip.startFrame, kind: .clipEdge))
                targets.append(SnapTarget(frame: clip.endFrame, kind: .clipEdge))
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
                case .clipEdge: baseFrameThreshold
                }
                let dist = abs(Double(probePos - target.frame))
                if dist <= threshold, dist < (best?.distance ?? .infinity) {
                    best = (probeOffset, target, dist)
                }
            }
        }

        guard let best else { return nil }
        state.currentlySnappedTo = best.target.frame
        state.currentProbeOffset = best.probeOffset
        return SnapResult(frame: best.target.frame, probeOffset: best.probeOffset, x: Double(best.target.frame) * pixelsPerFrame)
    }

}
