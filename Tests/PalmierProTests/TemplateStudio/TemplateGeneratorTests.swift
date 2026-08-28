import Foundation
import Testing
@testable import PalmierPro

@Suite("Template generator")
@MainActor
struct TemplateGeneratorTests {
    private static func analysis(
        shots: [DetectedShot],
        audioSegments: [AudioSegment] = [],
        durationSeconds: Double,
        hasAudio: Bool = false
    ) -> ReelAnalysis {
        ReelAnalysis(
            shots: shots,
            audioSegments: audioSegments,
            beats: [],
            durationSeconds: durationSeconds,
            sourceWidth: 1080,
            sourceHeight: 1920,
            sourceFPS: 30,
            hasAudio: hasAudio
        )
    }

    @Test func shotsBecomeGaplessSlotsCoveringTheReel() {
        let result = TemplateGenerator.makeTimeline(
            from: Self.analysis(
                shots: [
                    DetectedShot(startSeconds: 0, durationSeconds: 1.1, motionScore: 0.01),
                    DetectedShot(startSeconds: 1.1, durationSeconds: 0.9, motionScore: 0.08),
                    DetectedShot(startSeconds: 2.0, durationSeconds: 1.0, motionScore: 0.3),
                ],
                durationSeconds: 3.0
            ),
            sourceMediaRef: "reel",
            options: TemplateOptions(name: "Reel Template")
        )

        let slots = result.timeline.tracks[0].clips
        #expect(slots.map(\.startFrame) == [0, 33, 60])
        #expect(slots.map(\.durationFrames) == [33, 27, 30])
        #expect(slots.map { $0.templateSlot?.index } == [1, 2, 3])
        #expect(slots.map { $0.templateSlot?.motionEnergy } == [.still, .dynamic, .whip])
        #expect(slots.allSatisfy { $0.mediaRef == Clip.templateSlotMediaRef })
        #expect(slots.allSatisfy { $0.isUnfilledTemplateSlot })
        #expect(result.slotClipIds == slots.map(\.id))
        #expect(result.timeline.totalFrames == 90)
    }

    @Test func originalCutsTrimTheSourceInsteadOfPlaceholders() {
        let result = TemplateGenerator.makeTimeline(
            from: Self.analysis(
                shots: [
                    DetectedShot(startSeconds: 0, durationSeconds: 1.0, motionScore: 0.03),
                    DetectedShot(startSeconds: 1.0, durationSeconds: 1.0, motionScore: 0.03),
                ],
                durationSeconds: 2.0
            ),
            sourceMediaRef: "reel",
            options: TemplateOptions(name: "Reel Template", mode: .originalCuts)
        )

        let slots = result.timeline.tracks[0].clips
        #expect(slots.allSatisfy { $0.mediaRef == "reel" })
        #expect(slots.allSatisfy { !$0.isUnfilledTemplateSlot })
        #expect(slots.map(\.trimStartFrame) == [0, 30])
        #expect(slots.map(\.trimEndFrame) == [30, 0])
    }

    @Test func musicAndSpeechSegmentsBecomeSeparateNamedLanes() {
        let result = TemplateGenerator.makeTimeline(
            from: Self.analysis(
                shots: [DetectedShot(startSeconds: 0, durationSeconds: 4.0, motionScore: 0.03)],
                audioSegments: [
                    AudioSegment(kind: .music, startSeconds: 0, durationSeconds: 4.0, confidence: 0.9),
                    AudioSegment(kind: .speech, startSeconds: 1.0, durationSeconds: 2.0, confidence: 0.8),
                ],
                durationSeconds: 4.0,
                hasAudio: true
            ),
            sourceMediaRef: "reel",
            options: TemplateOptions(name: "Reel Template")
        )

        #expect(result.timeline.tracks.map(\.type) == [.video, .audio, .audio])
        #expect(result.timeline.tracks[1].name == AudioSegmentKind.music.trackName)
        #expect(result.timeline.tracks[2].name == AudioSegmentKind.speech.trackName)
        #expect(result.timeline.tracks[2].clips.map(\.startFrame) == [30])
        #expect(result.timeline.tracks[2].clips.map(\.durationFrames) == [60])
        #expect(result.timeline.tracks[1].clips.allSatisfy { $0.mediaType == .audio })
    }

    @Test func singleShotReelWarnsAndStillProducesOneSlot() {
        let result = TemplateGenerator.makeTimeline(
            from: Self.analysis(
                shots: [DetectedShot(startSeconds: 0, durationSeconds: 5.0, motionScore: 0.03)],
                durationSeconds: 5.0
            ),
            sourceMediaRef: "reel",
            options: TemplateOptions(name: "Reel Template")
        )

        #expect(result.slotClipIds.count == 1)
        #expect(result.warnings == [.noCutsDetected, .noAudioTrack])
        #expect(result.timeline.tracks.count == 1)
    }

    @Test func zeroLengthShotsAreDroppedWithoutGapsInSlotNumbering() {
        let result = TemplateGenerator.makeTimeline(
            from: Self.analysis(
                shots: [
                    DetectedShot(startSeconds: 0, durationSeconds: 1.0, motionScore: 0.03),
                    DetectedShot(startSeconds: 1.0, durationSeconds: 0.001, motionScore: 0.03),
                    DetectedShot(startSeconds: 1.0, durationSeconds: 1.0, motionScore: 0.03),
                ],
                durationSeconds: 2.0
            ),
            sourceMediaRef: "reel",
            options: TemplateOptions(name: "Reel Template")
        )

        let slots = result.timeline.tracks[0].clips
        #expect(slots.map { $0.templateSlot?.index } == [1, 2])
        #expect(slots.map(\.startFrame) == [0, 30])
    }

    @Test(arguments: [
        (MotionEnergy.whip, 0.5, 2.0 as Double?),
        (MotionEnergy.whip, 2.0, nil),
        (MotionEnergy.still, 5.0, 0.5),
        (MotionEnergy.still, 2.0, nil),
        (MotionEnergy.gentle, 5.0, nil),
    ])
    func suggestedSpeedFollowsMotionEnergyAndLength(
        energy: MotionEnergy,
        durationSeconds: Double,
        expected: Double?
    ) {
        let score: Double = switch energy {
        case .still: 0.01
        case .gentle: 0.04
        case .dynamic: 0.1
        case .whip: 0.3
        }
        let shot = DetectedShot(startSeconds: 0, durationSeconds: durationSeconds, motionScore: score)
        #expect(shot.motionEnergy == energy)
        #expect(MotionEnergyEstimator.suggestedSpeed(for: shot) == expected)
    }

    @Test func slotsSurviveProjectRoundTrip() throws {
        let result = TemplateGenerator.makeTimeline(
            from: Self.analysis(
                shots: [DetectedShot(startSeconds: 0, durationSeconds: 0.5, motionScore: 0.3)],
                durationSeconds: 0.5
            ),
            sourceMediaRef: "reel",
            options: TemplateOptions(name: "Reel Template")
        )
        let file = ProjectFile(timelines: [result.timeline])
        let decoded = try JSONDecoder().decode(ProjectFile.self, from: JSONEncoder().encode(file))
        #expect(decoded.timelines[0].tracks[0].clips[0].templateSlot
            == result.timeline.tracks[0].clips[0].templateSlot)
    }
}
