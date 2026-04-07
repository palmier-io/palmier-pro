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
        let x: Double // pixel position for drawing the snap indicator
    }

    /// Mutable state that persists across drag events for sticky snap behavior.
    struct SnapState {
        var currentlySnappedTo: Int?
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

    /// Enhanced snap with sticky behavior and playhead priority.
    ///
    /// 1. If currently snapped to a target, require 2.5x threshold to break free (sticky).
    /// 2. Playhead gets 1.5x threshold (easier to snap to).
    /// 3. Closest target within its respective threshold wins.
    static func findSnap(
        position: Int,
        targets: [SnapTarget],
        state: inout SnapState,
        baseThreshold: Double,
        pixelsPerFrame: Double
    ) -> SnapResult? {
        let baseFrameThreshold = baseThreshold / pixelsPerFrame

        // Sticky: if already snapped, hold until moved far enough
        if let snapped = state.currentlySnappedTo {
            let holdThreshold = baseFrameThreshold * Snap.stickyMultiplier
            if abs(Double(position - snapped)) <= holdThreshold {
                // Check target still exists
                if targets.contains(where: { $0.frame == snapped }) {
                    return SnapResult(frame: snapped, x: Double(snapped) * pixelsPerFrame)
                }
            }
            // Broke free
            state.currentlySnappedTo = nil
        }

        // Find closest target with type-specific thresholds
        var best: (target: SnapTarget, distance: Double)?
        for target in targets {
            let threshold: Double = switch target.kind {
            case .playhead: baseFrameThreshold * Snap.playheadMultiplier
            case .clipEdge: baseFrameThreshold
            }

            let dist = abs(Double(position - target.frame))
            if dist <= threshold, dist < (best?.distance ?? .infinity) {
                best = (target, dist)
            }
        }

        guard let best else { return nil }
        state.currentlySnappedTo = best.target.frame
        return SnapResult(frame: best.target.frame, x: Double(best.target.frame) * pixelsPerFrame)
    }

}
