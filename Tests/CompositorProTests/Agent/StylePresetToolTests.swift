import Foundation
import MCP
import Testing
@testable import CompositorPro

@Suite("apply_style_preset")
@MainActor
struct StylePresetToolTests {
    /// Grade objects are `[String: Any]`, so compare them as JSON rather than as values.
    private func sameGrade(_ a: [String: Any]?, _ b: [String: Any]?) -> Bool {
        func canon(_ value: [String: Any]?) -> String {
            guard let value else { return "<nil>" }
            guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
                return "<unencodable>"
            }
            return String(decoding: data, as: UTF8.self)
        }
        return canon(a) == canon(b)
    }
    private func fixture(count: Int = 2) async throws -> (ToolHarness, [Clip]) {
        let harness = ToolHarness()
        var ids: [Clip] = []
        for index in 0 ..< count {
            let asset = harness.addAsset(type: .video, duration: 20, hasAudio: true)
            _ = try await harness.runOK("add_clips", args: ["entries": [
                ["mediaRef": asset.id, "startFrame": index * 150, "source": [0.0, 4.0]],
            ]])
            ids.append(try #require(harness.editor.timeline.tracks.flatMap(\.clips)
                .first { $0.mediaType == .video && $0.startFrame == index * 150 }))
        }
        return (harness, ids)
    }

    @Test func everyPresetIsAValidApplyColorGrade() async throws {
        let (harness, clips) = try await fixture(count: 1)
        let clip = try #require(clips.first)
        for preset in StylePresets.all {
            _ = try await harness.runOK("apply_style_preset", args: ["preset": preset.id])
            let graded = try #require(harness.editor.clipFor(id: clip.id))
            let color = try #require(ToolExecutor.colorObject(from: graded.effects))
            // Round-trips: the applied grade is a grade apply_color can paste elsewhere.
            let copy = harness.addAsset(type: .video, duration: 20)
            _ = try await harness.runOK("add_clips", args: ["entries": [
                ["mediaRef": copy.id, "startFrame": 600, "source": [0.0, 4.0]],
            ]])
            let copyClip = try #require(harness.editor.timeline.tracks.flatMap(\.clips)
                .first { $0.mediaType == .video && $0.startFrame == 600 })
            let pasted = try await harness.runRaw("apply_color", args: [
                "clipIds": [copyClip.id], "color": color,
            ])
            #expect(!pasted.isError, "\(preset.id): \(ToolHarness.textOf(pasted))")
            #expect(
                sameGrade(ToolExecutor.colorObject(from: harness.editor.clipFor(id: copyClip.id)?.effects), color),
                "preset \(preset.id) did not round-trip"
            )
        }
    }

    @Test func presetsAreDistinctFromEachOther() {
        // A user must be able to tell two presets apart without reading the numbers.
        for (index, a) in StylePresets.all.enumerated() {
            for b in StylePresets.all[(index + 1)...] {
                #expect(!sameGrade(a.color, b.color), "\(a.id) and \(b.id) are identical")
            }
        }
    }

    @Test func appliesToEveryVisualClipByDefault() async throws {
        let (harness, clips) = try await fixture(count: 2)
        let receipt = try await harness.runOK("apply_style_preset", args: ["preset": "cinematic"]) as? [String: Any]
        #expect(receipt?["preset"] as? String == "cinematic")
        #expect(receipt?["graded"] as? Int == 2)
        #expect(receipt?["undoSteps"] as? Int == 1)
        for clip in clips {
            let graded = try #require(harness.editor.clipFor(id: clip.id))
            let color = try #require(ToolExecutor.colorObject(from: graded.effects))
            #expect(abs((color["contrast"] as? Double ?? 0) - 1.12) < 1e-6)
            // Hue survives a colour-space round trip, so it is close, not exact.
            #expect(abs((color["shadowsHue"] as? Double ?? 0) - 200) < 0.5)
            #expect(abs((color["highsHue"] as? Double ?? 0) - 38) < 0.5)
            #expect((color["masterCurve"] as? [[Double]])?.count == 4)
        }
    }

    @Test func returnsEachClipsResultingGrade() async throws {
        let (harness, clips) = try await fixture(count: 1)
        let receipt = try await harness.runOK("apply_style_preset", args: ["preset": "noir"]) as? [String: Any]
        // The receipt keys each clip by the shortened id form tools accept as input.
        let graded = try #require(receipt?["graded"] as? Int)
        #expect(graded == 1)
        let reserved: Set<String> = ["preset", "graded", "skipped", "changed", "undoSteps", "notes"]
        let entries = try #require(receipt?.filter { !reserved.contains($0.key) })
        #expect(entries.count == 1)
        let color = try #require(entries.values.first as? [String: Any])
        #expect(color["saturation"] as? Double == 0.15)
    }

    @Test func oneUndoStepRevertsTheWholeLook() async throws {
        let (harness, clips) = try await fixture(count: 2)
        let undoManager = UndoManager()
        harness.editor.undo.attach(undoManager)
        _ = try await harness.runOK("apply_style_preset", args: ["preset": "warmFilm"])
        #expect(clips.allSatisfy { ToolExecutor.colorObject(from: harness.editor.clipFor(id: $0.id)?.effects) != nil })

        undoManager.undo()
        for clip in clips {
            #expect(ToolExecutor.colorObject(from: harness.editor.clipFor(id: clip.id)?.effects) == nil)
        }
    }

    @Test func targetsASubsetWhenGivenClipIds() async throws {
        let (harness, clips) = try await fixture(count: 2)
        let only = try #require(clips.first)
        _ = try await harness.runOK("apply_style_preset", args: [
            "preset": "documentary", "clipIds": [only.id],
        ])
        #expect(ToolExecutor.colorObject(from: harness.editor.clipFor(id: only.id)?.effects) != nil)
        #expect(ToolExecutor.colorObject(from: harness.editor.clipFor(id: clips[1].id)?.effects) == nil)
    }

    @Test func leavesNonColorEffectsAlone() async throws {
        let (harness, clips) = try await fixture(count: 1)
        let clip = try #require(clips.first)
        _ = try await harness.runOK("apply_effect", args: [
            "clipIds": [clip.id], "effects": [["type": "blur.gaussian", "params": ["radius": 12]]],
        ])
        let before = harness.editor.clipFor(id: clip.id)?.effects?.filter { !$0.type.hasPrefix("color.") }
        _ = try await harness.runOK("apply_style_preset", args: ["preset": "cinematic"])
        let after = harness.editor.clipFor(id: clip.id)?.effects?.filter { !$0.type.hasPrefix("color.") }
        #expect(after == before)
    }

    @Test func replacesAPreviousGradeRatherThanStacking() async throws {
        let (harness, clips) = try await fixture(count: 1)
        let clip = try #require(clips.first)
        _ = try await harness.runOK("apply_color", args: ["clipIds": [clip.id], "saturation": 1.9])
        _ = try await harness.runOK("apply_style_preset", args: ["preset": "documentary"])
        let color = try #require(ToolExecutor.colorObject(from: harness.editor.clipFor(id: clip.id)?.effects))
        #expect(color["saturation"] as? Double == 0.94)
        // One color stack, not two.
        let colorEffects = harness.editor.clipFor(id: clip.id)?.effects?
            .filter { $0.type.hasPrefix("color.") } ?? []
        #expect(Set(colorEffects.map(\.type)).count == colorEffects.count)
    }

    @Test func refusesBadRequestsWithoutMutating() async throws {
        let (harness, clips) = try await fixture(count: 1)
        let clip = try #require(clips.first)
        let cases: [(String, [String: Any], String)] = [
            ("missing preset", [:], "requires preset"),
            ("unknown preset", ["preset": "blockbuster"], "Unknown preset 'blockbuster'"),
            ("audio clip", ["preset": "noir", "clipIds": [clip.id], "unknown": 1], "unknown"),
        ]
        for (index, testCase) in cases.enumerated() {
            let result = await harness.runRaw("apply_style_preset", args: testCase.1)
            let message = ToolHarness.textOf(result)
            #expect(result.isError, "case \(index) \(testCase.0): \(message)")
            #expect(message.contains(testCase.2), "case \(index) \(testCase.0): \(message)")
        }
        #expect(ToolExecutor.colorObject(from: harness.editor.clipFor(id: clip.id)?.effects) == nil)
    }

    @Test func refusesATimelineWithNoVisualClips() async throws {
        let harness = ToolHarness()
        let audio = harness.addAsset(type: .audio, duration: 20)
        _ = try await harness.runOK("add_clips", args: ["entries": [
            ["mediaRef": audio.id, "startFrame": 0, "source": [0.0, 4.0]],
        ]])
        let result = await harness.runRaw("apply_style_preset", args: ["preset": "noir"])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("No video or image clips"))
    }

    @Test func presetNamesAreStableContractValues() {
        // These appear in the schema enum, so renaming one is a breaking tool change.
        #expect(StylePresets.ids == [
            "documentary", "cinematic", "travelVlog", "warmFilm",
            "noir", "cleanCorporate", "socialPunch",
        ])
        for preset in StylePresets.all {
            #expect(preset.intent.count > 40, "\(preset.id) has no usable intent text")
        }
    }

    @Test func endToEndOverMCPWithUndo() async throws {
        let (harness, clips) = try await fixture(count: 1)
        let clip = try #require(clips.first)
        let undoManager = UndoManager()
        harness.editor.undo.attach(undoManager)
        let server = Server(name: "style-test", version: "1.0.0", capabilities: .init(tools: .init(listChanged: false)))
        await MCPService.registerTools(on: server, executor: harness.executor)
        let transports = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "style-test", version: "1.0.0")
        try await server.start(transport: transports.server)
        do {
            _ = try await client.connect(transport: transports.client)
            let (tools, _) = try await client.listTools()
            #expect(tools.contains { $0.name == "apply_style_preset" })

            let applied = try await client.callTool(name: "apply_style_preset", arguments: [
                "preset": .string("travelVlog"),
            ])
            #expect(applied.isError != true)
            #expect(ToolExecutor.colorObject(from: harness.editor.clipFor(id: clip.id)?.effects) != nil)

            let undone = try await client.callTool(name: "undo", arguments: [:])
            #expect(undone.isError != true)
            #expect(ToolExecutor.colorObject(from: harness.editor.clipFor(id: clip.id)?.effects) == nil)
        } catch {
            await server.stop()
            await client.disconnect()
            throw error
        }
        await server.stop()
        await client.disconnect()
    }
}
