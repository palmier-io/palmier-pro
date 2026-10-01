import Foundation
import MCP
import Testing
@testable import CompositorPro

@Suite("set_clip_speed_ramp")
@MainActor
struct SpeedRampToolTests {
    /// `mediaSeconds` is deliberately longer than `clipSeconds` so a speed-up ramp has real
    /// source to consume; a ramp cannot invent media.
    private func rampFixture(
        mediaSeconds: Double = 60, clipSeconds: Double = 10
    ) async throws -> (ToolHarness, Clip) {
        let harness = ToolHarness()
        let asset = harness.addAsset(type: .video, duration: mediaSeconds)
        _ = try await harness.runOK("add_clips", args: ["entries": [
            ["mediaRef": asset.id, "startFrame": 0, "source": [0.0, clipSeconds]],
        ]])
        let clip = try #require(harness.editor.timeline.tracks.flatMap(\.clips).first)
        return (harness, clip)
    }

    @Test func rampKeepsTimelineLengthAndReportsConsumedSource() async throws {
        let (harness, clip) = try await rampFixture()
        let lengthBefore = clip.durationFrames
        // A ramp's last row lands on the final samplable frame, not one past it.
        let lastSamplable = lengthBefore - 1

        let receipt = try await harness.runOK("set_clip_speed_ramp", args: [
            "clipId": clip.id,
            "points": [["frame": 0, "speed": 1.0], ["frame": lastSamplable, "speed": 3.0]],
        ]) as? [String: Any]
        #expect(receipt?["changed"] as? Bool == true)
        #expect(receipt?["previousSpeed"] as? Double == 1.0)
        #expect((receipt?["sourceFramesConsumed"] as? Int ?? 0) > clip.durationFrames)

        let after = try #require(harness.editor.timeline.tracks.flatMap(\.clips).first { $0.id == clip.id })
        #expect(after.durationFrames == lengthBefore)
        #expect(after.startFrame == clip.startFrame)
        #expect(after.speedTrack?.keyframes.count == 2)
        #expect(after.sourceFramesConsumed == receipt?["sourceFramesConsumed"] as? Int)
    }

    @Test func rampIsOneUndoStep() async throws {
        let (harness, clip) = try await rampFixture()
        let undoManager = UndoManager()
        harness.editor.undo.attach(undoManager)
        _ = try await harness.runOK("set_clip_speed_ramp", args: [
            "clipId": clip.id,
            "points": [["frame": 0, "speed": 1.0], ["frame": 100, "speed": 2.0]],
        ])
        undoManager.undo()
        let after = try #require(harness.editor.timeline.tracks.flatMap(\.clips).first { $0.id == clip.id })
        #expect(after.speedTrack == nil)
        #expect(after.sourceFramesConsumed == 300)
    }

    @Test func clearReturnsToOneConstantSpeed() async throws {
        let (harness, clip) = try await rampFixture()
        let rampedReceipt = try await harness.runOK("set_clip_speed_ramp", args: [
            "clipId": clip.id,
            "points": [["frame": 0, "speed": 1.0], ["frame": 299, "speed": 2.0]],
        ]) as? [String: Any]
        let consumedWhileRamped = try #require(rampedReceipt?["sourceFramesConsumed"] as? Int)
        let receipt = try await harness.runOK("set_clip_speed_ramp", args: [
            "clipId": clip.id, "clear": true,
        ]) as? [String: Any]
        #expect(receipt?["cleared"] as? Bool == true)
        let after = try #require(harness.editor.timeline.tracks.flatMap(\.clips).first { $0.id == clip.id })
        #expect(after.speedTrack == nil)
        #expect(after.speed == 1.0)
        // Clearing must not lose or invent source: the clip still reads the same frames, now
        // over a length that matches them at one constant rate.
        #expect(after.sourceFramesConsumed == consumedWhileRamped)
        #expect(after.durationFrames == consumedWhileRamped)
    }

    @Test func validationRefusesEveryBadRequest() async throws {
        let (harness, clip) = try await rampFixture()
        let cases: [(String, [String: Any], String)] = [
            ("unknown clip", ["clipId": "nope", "points": [["frame": 0, "speed": 1.0], ["frame": 100, "speed": 2.0]]], "Clip not found"),
            ("one point", ["clipId": clip.id, "points": [["frame": 0, "speed": 1.0]]], "at least 2 points"),
            ("descending", ["clipId": clip.id, "points": [["frame": 100, "speed": 1.0], ["frame": 0, "speed": 2.0]]], "must increase"),
            ("past end", ["clipId": clip.id, "points": [["frame": 0, "speed": 1.0], ["frame": 5000, "speed": 2.0]]], "outside the clip"),
            ("last frame", ["clipId": clip.id, "points": [["frame": 0, "speed": 1.0], ["frame": 300, "speed": 2.0]]], "outside the clip"),
            ("zero speed", ["clipId": clip.id, "points": [["frame": 0, "speed": 0.0], ["frame": 100, "speed": 2.0]]], "outside 0.01"),
            ("too fast", ["clipId": clip.id, "points": [["frame": 0, "speed": 1.0], ["frame": 100, "speed": 5000.0]]], "outside 0.01"),
        ]
        for (index, testCase) in cases.enumerated() {
            let result = await harness.runRaw("set_clip_speed_ramp", args: testCase.1)
            let message = ToolHarness.textOf(result)
            #expect(result.isError, "case \(index) \(testCase.0): \(message)")
            #expect(message.contains(testCase.2), "case \(index) \(testCase.0): \(message)")
        }
        #expect(harness.editor.timeline.tracks.flatMap(\.clips).allSatisfy { $0.speedTrack == nil })
    }

    @Test func aRampThatOutrunsTheSourceIsRefused() async throws {
        // 10s of media at 30fps is 300 source frames; a 10x ramp over a 10s clip needs 3000.
        let (harness, clip) = try await rampFixture(mediaSeconds: 10, clipSeconds: 10)
        let result = await harness.runRaw("set_clip_speed_ramp", args: [
            "clipId": clip.id,
            "points": [["frame": 0, "speed": 10.0], ["frame": 299, "speed": 10.0]],
        ])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("needs 3000 source frames"))
        #expect(ToolHarness.textOf(result).contains("only 300 are available"))
    }

    @Test func aFlatFastRateMultipliesTheConsumedSource() async throws {
        let (harness, clip) = try await rampFixture()
        let receipt = try await harness.runOK("set_clip_speed_ramp", args: [
            "clipId": clip.id,
            "points": [["frame": 0, "speed": 4.0], ["frame": 299, "speed": 4.0]],
        ]) as? [String: Any]
        #expect(receipt?["sourceFramesConsumed"] as? Int == 1200)
    }

    @Test func getTimelineReportsTheRamp() async throws {
        let (harness, clip) = try await rampFixture()
        _ = try await harness.runOK("set_clip_speed_ramp", args: [
            "clipId": clip.id,
            "points": [["frame": 0, "speed": 1.0], ["frame": 299, "speed": 2.0]],
        ])
        let timeline = try await harness.runOK("get_timeline") as? [String: Any]
        #expect(ToolExecutor.jsonString(timeline ?? [:])?.contains("speedRamp") == true)
    }

    @Test func endToEndOverMCPWithUndo() async throws {
        let (harness, clip) = try await rampFixture()
        let undoManager = UndoManager()
        harness.editor.undo.attach(undoManager)
        let server = Server(name: "speed-ramp-test", version: "1.0.0", capabilities: .init(tools: .init(listChanged: false)))
        await MCPService.registerTools(on: server, executor: harness.executor)
        let transports = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "speed-ramp-test", version: "1.0.0")
        try await server.start(transport: transports.server)
        do {
            _ = try await client.connect(transport: transports.client)
            let (tools, _) = try await client.listTools()
            #expect(tools.contains { $0.name == "set_clip_speed_ramp" })

            let applied = try await client.callTool(name: "set_clip_speed_ramp", arguments: [
                "clipId": .string(clip.id),
                "points": .array([
                    .object(["frame": .int(0), "speed": .double(1)]),
                    .object(["frame": .int(299), "speed": .double(4)]),
                ]),
            ])
            #expect(applied.isError != true)
            #expect(harness.editor.clipFor(id: clip.id)?.speedTrack?.keyframes.count == 2)

            let undone = try await client.callTool(name: "undo", arguments: [:])
            #expect(undone.isError != true)
            #expect(harness.editor.clipFor(id: clip.id)?.speedTrack == nil)
        } catch {
            await server.stop()
            await client.disconnect()
            throw error
        }
        await server.stop()
        await client.disconnect()
    }
}
