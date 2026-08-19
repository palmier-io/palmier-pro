import Foundation
import Testing
@testable import PalmierPro

@Suite("ToolExecutor — trim_clips")
@MainActor
struct TrimClipsToolTests {

    private func clipFrames(_ h: ToolHarness, _ id: String) -> [Int]? {
        guard let loc = h.editor.findClip(id: id) else { return nil }
        let c = h.editor.timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
        return [c.startFrame, c.endFrame]
    }

    @Test func toolIsExposedToAgentAndMCP() {
        #expect(ToolDefinitions.mcpServer.contains { $0.name == .trimClips })
        #expect(ToolDefinitions.inAppAgent.contains { $0.name == .trimClips })
    }

    @Test func trimsBothEdgesWithoutMovingNeighbors() async throws {
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [
                Fixtures.clip(id: "a", start: 100, duration: 100, trimStart: 30, trimEnd: 30),
                Fixtures.clip(id: "b", start: 250, duration: 50),
            ])
        ]))
        let json = try await h.runOK("trim_clips", args: [
            "edits": [["clipId": "a", "startFrame": 120, "endFrame": 180]]
        ]) as? [String: Any]

        #expect(clipFrames(h, "a") == [120, 180])
        #expect(clipFrames(h, "b") == [250, 300])
        let clip = h.editor.timeline.tracks[0].clips.first { $0.id == "a" }
        #expect(clip?.trimStartFrame == 50 && clip?.trimEndFrame == 50)
        #expect(json?["notes"] == nil)
    }

    @Test func extendBeyondSourceHeadroomClampsAndReports() async throws {
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [
                Fixtures.clip(id: "a", start: 100, duration: 60, trimStart: 10)
            ])
        ]))
        let json = try await h.runOK("trim_clips", args: [
            "edits": [["clipId": "a", "startFrame": 80]]
        ]) as? [String: Any]

        #expect(clipFrames(h, "a") == [90, 160])
        let notes = json?["notes"] as? [String]
        #expect(notes?.contains { $0.contains("landed at frame 90") } == true)
    }

    @Test func rejectsFramesNearIntMaxWithoutTrapping() async throws {
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "a", start: 0, duration: 60)])
        ]))
        let result = await h.runRaw("trim_clips", args: [
            "edits": [["clipId": "a", "endFrame": 9_223_372_036_854_775_000]]
        ])
        #expect(result.isError)
        #expect(clipFrames(h, "a") == [0, 60])
    }

    @Test func rippleTrimsWholeMulticamCohortFromOneEdit() async throws {
        var camA = Fixtures.clip(id: "camA", start: 0, duration: 100)
        var camB = Fixtures.clip(id: "camB", start: 0, duration: 100)
        camA.multicamGroupId = "mc1"
        camB.multicamGroupId = "mc1"
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [camA]),
            Fixtures.videoTrack(clips: [camB]),
        ]))

        _ = try await h.runOK("trim_clips", args: [
            "edits": [["clipId": "camA", "endFrame": 80]],
            "ripple": true,
        ])
        #expect(clipFrames(h, "camA") == [0, 80])
        #expect(clipFrames(h, "camB") == [0, 80])
    }

    @Test func rejectsTwoRippleEditsSharingAMulticamCohort() async throws {
        var camA = Fixtures.clip(id: "camA", start: 0, duration: 100)
        var camB = Fixtures.clip(id: "camB", start: 0, duration: 100)
        camA.multicamGroupId = "mc1"
        camB.multicamGroupId = "mc1"
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [camA]),
            Fixtures.videoTrack(clips: [camB]),
        ]))

        let result = await h.runRaw("trim_clips", args: [
            "edits": [
                ["clipId": "camA", "endFrame": 80],
                ["clipId": "camB", "endFrame": 90],
            ],
            "ripple": true,
        ])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("multicam"))
        #expect(clipFrames(h, "camA") == [0, 100])
        #expect(clipFrames(h, "camB") == [0, 100])
    }

    @Test func extendOverwritingLaterTargetReportsSkippedTrim() async throws {
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [
                Fixtures.clip(id: "a", start: 0, duration: 100, trimEnd: 50),
                Fixtures.clip(id: "b", start: 100, duration: 30),
            ])
        ]))
        let json = try await h.runOK("trim_clips", args: [
            "edits": [
                ["clipId": "a", "endFrame": 140],
                ["clipId": "b", "endFrame": 120],
            ]
        ]) as? [String: Any]

        #expect(clipFrames(h, "a") == [0, 140])
        #expect(h.editor.findClip(id: "b") == nil)
        let notes = json?["notes"] as? [String]
        #expect(notes?.contains { $0.contains("removed when an earlier edit extended over it") } == true)
        let removed = json?["removedClipIds"] as? [String]
        #expect(removed?.contains { "b".hasPrefix($0) || $0 == "b" } == true)
    }

    @Test func rippleTrimShiftsDownstreamClips() async throws {
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [
                Fixtures.clip(id: "a", start: 0, duration: 100),
                Fixtures.clip(id: "b", start: 100, duration: 100),
            ])
        ]))
        let json = try await h.runOK("trim_clips", args: [
            "edits": [["clipId": "a", "endFrame": 60]],
            "ripple": true,
        ]) as? [String: Any]

        #expect(clipFrames(h, "a") == [0, 60])
        #expect(clipFrames(h, "b") == [60, 160])
        #expect(json?["notes"] == nil)
    }

    @Test func rippleExtendPushesDownstreamClips() async throws {
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [
                Fixtures.clip(id: "a", start: 0, duration: 100, trimEnd: 30),
                Fixtures.clip(id: "b", start: 100, duration: 100),
            ])
        ]))
        _ = try await h.runOK("trim_clips", args: [
            "edits": [["clipId": "a", "endFrame": 120]],
            "ripple": true,
        ])

        #expect(clipFrames(h, "a") == [0, 120])
        #expect(clipFrames(h, "b") == [120, 220])
    }

    @Test func rippleExtendWithoutHeadroomSkipsWithNote() async throws {
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [
                Fixtures.clip(id: "a", start: 0, duration: 100),
                Fixtures.clip(id: "b", start: 100, duration: 100),
            ])
        ]))
        let undoManager = UndoManager()
        h.editor.undo.attach(undoManager)

        let json = try await h.runOK("trim_clips", args: [
            "edits": [["clipId": "a", "endFrame": 120]],
            "ripple": true,
        ]) as? [String: Any]

        #expect(clipFrames(h, "a") == [0, 100])
        #expect(clipFrames(h, "b") == [100, 200])
        let notes = json?["notes"] as? [String]
        #expect(notes?.contains { $0.contains("no headroom") } == true)
        #expect(!undoManager.canUndo)
    }

    @Test func multipleClipsUndoAsOneAction() async throws {
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [
                Fixtures.clip(id: "a", start: 0, duration: 60),
                Fixtures.clip(id: "b", start: 100, duration: 60),
            ])
        ]))
        let undoManager = UndoManager()
        h.editor.undo.attach(undoManager)

        _ = try await h.runOK("trim_clips", args: [
            "edits": [
                ["clipId": "a", "endFrame": 40],
                ["clipId": "b", "endFrame": 120],
            ]
        ])
        #expect(clipFrames(h, "a") == [0, 40])
        #expect(clipFrames(h, "b") == [100, 120])

        undoManager.undo()
        #expect(clipFrames(h, "a") == [0, 60])
        #expect(clipFrames(h, "b") == [100, 160])
        #expect(!undoManager.canUndo)
    }

    @Test func linkedPartnerTrimsAlong() async throws {
        var video = Fixtures.clip(id: "v", start: 0, duration: 100)
        var audio = Fixtures.clip(id: "au", mediaType: .audio, start: 0, duration: 100)
        video.linkGroupId = "g1"
        audio.linkGroupId = "g1"
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [video]),
            Fixtures.audioTrack(clips: [audio]),
        ]))

        _ = try await h.runOK("trim_clips", args: [
            "edits": [["clipId": "v", "endFrame": 80]]
        ])
        #expect(clipFrames(h, "v") == [0, 80])
        #expect(clipFrames(h, "au") == [0, 80])
    }

    @Test func retimedPartnerQuantizationDriftIsReported() async throws {
        var video = Fixtures.clip(id: "v", start: 0, duration: 100)
        var audio = Fixtures.clip(id: "au", mediaType: .audio, start: 0, duration: 100, speed: 0.5)
        video.linkGroupId = "g1"
        audio.linkGroupId = "g1"
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [video]),
            Fixtures.audioTrack(clips: [audio]),
        ]))

        // A 25-frame trim maps to 12.5 source frames at 0.5x; rounding moves the audio 26.
        let json = try await h.runOK("trim_clips", args: [
            "edits": [["clipId": "v", "endFrame": 75]]
        ]) as? [String: Any]

        #expect(clipFrames(h, "v") == [0, 75])
        #expect(clipFrames(h, "au") == [0, 74])
        let notes = json?["notes"] as? [String]
        #expect(notes?.contains { $0.contains("linked partner au") && $0.contains("26") && $0.contains("25") } == true)
    }

    @Test func sameSpeedPartnersTrimWithoutDriftNote() async throws {
        var video = Fixtures.clip(id: "v", start: 0, duration: 100)
        var audio = Fixtures.clip(id: "au", mediaType: .audio, start: 0, duration: 100)
        video.linkGroupId = "g1"
        audio.linkGroupId = "g1"
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [video]),
            Fixtures.audioTrack(clips: [audio]),
        ]))

        let json = try await h.runOK("trim_clips", args: [
            "edits": [["clipId": "v", "endFrame": 75]]
        ]) as? [String: Any]

        #expect(clipFrames(h, "v") == [0, 75])
        #expect(clipFrames(h, "au") == [0, 75])
        #expect(json?["notes"] == nil)
    }

    @Test func rejectsClipOrLinkedPartnerListedTwice() async throws {
        var video = Fixtures.clip(id: "v", start: 0, duration: 100)
        var audio = Fixtures.clip(id: "au", mediaType: .audio, start: 0, duration: 100)
        video.linkGroupId = "g1"
        audio.linkGroupId = "g1"
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [video]),
            Fixtures.audioTrack(clips: [audio]),
        ]))

        let duplicate = await h.runRaw("trim_clips", args: [
            "edits": [["clipId": "v", "endFrame": 80], ["clipId": "v", "startFrame": 10]]
        ])
        #expect(duplicate.isError)

        let partner = await h.runRaw("trim_clips", args: [
            "edits": [["clipId": "v", "endFrame": 80], ["clipId": "au", "endFrame": 90]]
        ])
        #expect(partner.isError)
        #expect(ToolHarness.textOf(partner).contains("linked partner"))
    }

    @Test func noOpRequestCreatesNoUndoEntry() async throws {
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "a", start: 0, duration: 60)])
        ]))
        let undoManager = UndoManager()
        h.editor.undo.attach(undoManager)

        let json = try await h.runOK("trim_clips", args: [
            "edits": [["clipId": "a", "startFrame": 0, "endFrame": 60]]
        ]) as? [String: Any]

        let notes = json?["notes"] as? [String]
        #expect(notes?.contains { $0.contains("No change") } == true)
        #expect(!undoManager.canUndo)
    }

    @Test func validationRejectsBadEdits() async throws {
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "a", start: 0, duration: 60)])
        ]))

        #expect((await h.runRaw("trim_clips", args: ["edits": []])).isError)
        #expect((await h.runRaw("trim_clips", args: ["edits": [["clipId": "a"]]])).isError)
        #expect((await h.runRaw("trim_clips", args: ["edits": [["clipId": "missing", "endFrame": 30]]])).isError)
        #expect((await h.runRaw("trim_clips", args: [
            "edits": [["clipId": "a", "startFrame": 50, "endFrame": 50]]
        ])).isError)
        #expect((await h.runRaw("trim_clips", args: [
            "edits": [["clipId": "a", "startFrame": -5]]
        ])).isError)
        #expect((await h.runRaw("trim_clips", args: [
            "edits": [["clipId": "a", "endFrame": 30, "bogus": 1]]
        ])).isError)
        // Nothing mutated by any rejected call.
        #expect(clipFrames(h, "a") == [0, 60])
    }
}
