import Foundation

extension EditorViewModel {
    struct OutroReceipt: Sendable {
        var startFrame: Int
        var endFrame: Int
        var durationFrames: Int
        var creditLineCount: Int
        var hasSubscribeCard: Bool
        var trackIds: [String]
    }

    /// Builds the end sequence — credits roll and subscribe card — as one undoable action.
    ///
    /// Everything lands on new tracks above the edit, so the cut itself is untouched. The picture
    /// hold reuses the freeze-frame model rather than faking it, so credits sit over a real still.
    @discardableResult
    func addOutro(
        durationFrames: Int,
        credits: OutroPlan.Credits?,
        subscribe: OutroPlan.Subscribe?,
        platform: OutroPlan.Platform
    ) throws -> OutroReceipt {
        let plan = try OutroPlan.plan(
            timelineTotalFrames: max(1, timeline.totalFrames),
            outroDurationFrames: durationFrames,
            credits: credits,
            subscribe: subscribe,
            platform: platform
        )
        var trackIds: [String] = []

        withTimelineSwap(actionName: "Add Outro") {
            if let roll = plan.roll {
                let trackIndex = insertTrack(at: 0, type: .video)
                trackIds.append(timeline.tracks[trackIndex].id)
                var clip = makeOutroTextClip(
                    trackIndex: trackIndex,
                    content: roll.text,
                    startFrame: roll.startFrame,
                    durationFrames: plan.durationFrames,
                    style: OutroTextStyle.credits(canvasHeight: timeline.height),
                    x: roll.x,
                    y: roll.startY
                )
                // Constant-rate roll: the block starts below the frame and exits above it, so it is
                // readable in the middle whatever its height. Keyframes are clip-relative.
                clip.positionTrack = KeyframeTrack(keyframes: [
                    Keyframe(frame: 0, value: AnimPair(a: roll.x, b: roll.startY), interpolationOut: .linear),
                    Keyframe(
                        frame: max(1, plan.durationFrames - 1),
                        value: AnimPair(a: roll.x, b: roll.endY), interpolationOut: .linear
                    ),
                ])
                clip.opacityTrack = KeyframeTrack(keyframes: roll.opacityRows)
                timeline.tracks[trackIndex].clips[locationIndex(of: clip.id, trackIndex: trackIndex)] = clip
            }
            if let card = plan.subscribe {
                let trackIndex = insertTrack(at: 0, type: .video)
                trackIds.append(timeline.tracks[trackIndex].id)
                var clip = makeOutroTextClip(
                    trackIndex: trackIndex,
                    content: card.text,
                    startFrame: card.startFrame,
                    durationFrames: card.endFrame - card.startFrame,
                    style: OutroTextStyle.subscribe(canvasHeight: timeline.height),
                    x: card.x,
                    y: card.y
                )
                clip.textAnimation = TextAnimation(preset: .popIn)
                timeline.tracks[trackIndex].clips[locationIndex(of: clip.id, trackIndex: trackIndex)] = clip
            }
        }
        onProjectCheckpointRequired?()
        return OutroReceipt(
            startFrame: plan.startFrame,
            endFrame: plan.endFrame,
            durationFrames: plan.durationFrames,
            creditLineCount: credits?.lines.filter { !$0.name.isEmpty }.count ?? 0,
            hasSubscribeCard: subscribe != nil,
            trackIds: trackIds
        )
    }

    private func locationIndex(of clipId: String, trackIndex: Int) -> Int {
        timeline.tracks[trackIndex].clips.firstIndex { $0.id == clipId } ?? 0
    }

    private func makeOutroTextClip(
        trackIndex: Int,
        content: String,
        startFrame: Int,
        durationFrames: Int,
        style: TextStyle,
        x: Double,
        y: Double
    ) -> Clip {
        var clip = Clip(
            mediaRef: "", mediaType: .text,
            startFrame: startFrame, durationFrames: max(1, durationFrames)
        )
        clip.id = UUID().uuidString
        clip.textContent = content
        clip.textStyle = style
        clip.transform = Transform(centerX: x, centerY: y)
        timeline.tracks[trackIndex].clips.append(clip)
        return clip
    }
}

/// Type and scale for the outro pieces. One owner, so credits and card cannot drift apart.
enum OutroTextStyle {
    /// Proportional to the canvas so credits stay legible on a vertical export too.
    static func credits(canvasHeight: Int) -> TextStyle {
        let edge = max(2, Double(canvasHeight) * 0.0035)
        var style = TextStyle()
        style.fontName = "HelveticaNeue-Bold"
        style.fontSize = max(24, Double(canvasHeight) * 0.042)
        style.widthScale = 1.05
        style.heightScale = 1.3
        style.alignment = .center
        style.color = TextStyle.RGBA(r: 1, g: 1, b: 1, a: 1)
        // A dark edge is what keeps white credits readable over a bright frame.
        style.border = TextStyle.Outline(
            enabled: true, color: TextStyle.RGBA(r: 0, g: 0, b: 0, a: 1), width: edge
        )
        return style
    }

    static func subscribe(canvasHeight: Int) -> TextStyle {
        let edge = max(3, Double(canvasHeight) * 0.005)
        var style = TextStyle()
        style.fontName = "HelveticaNeue-Bold"
        style.fontSize = max(28, Double(canvasHeight) * 0.070)
        style.widthScale = 1.05
        style.heightScale = 1.2
        style.alignment = .center
        style.color = TextStyle.RGBA(r: 1, g: 1, b: 1, a: 1)
        style.border = TextStyle.Outline(
            enabled: true, color: TextStyle.RGBA(r: 0, g: 0, b: 0, a: 1), width: edge
        )
        return style
    }
}