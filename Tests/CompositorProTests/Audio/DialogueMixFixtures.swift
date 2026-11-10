import Foundation
@testable import CompositorPro

enum DialogueMixFixtures {
    static var request: AudioMixRequest {
        .init(roles: [.init(clipId: "voice", role: .voice), .init(clipId: "music", role: .music), .init(clipId: "room", role: .ambience)],
              target: .init(integratedLUFS: -16, truePeakDBTP: -1), ducking: .default, bedFadeFrames: 6)
    }

    @MainActor
    static func editor(source: URL) -> EditorViewModel {
        let editor = EditorViewModel()
        let voice = Fixtures.clip(id: "voice", mediaRef: "voice-source", mediaType: .audio, start: 15, duration: 60)
        let music = Fixtures.clip(id: "music", mediaRef: "music-source", mediaType: .audio, start: 0, duration: 90)
        let room = Fixtures.clip(id: "room", mediaRef: "room-source", mediaType: .audio, start: 0, duration: 90)
        var timeline = Fixtures.timeline(tracks: [Fixtures.audioTrack(id: "voice-track", clips: [voice]),
                                                  Fixtures.audioTrack(id: "music-track", clips: [music]),
                                                  Fixtures.audioTrack(id: "room-track", clips: [room])])
        timeline.id = "mix-timeline"
        editor.timeline = timeline
        for clip in [voice, music, room] { addAsset(id: clip.mediaRef, name: clip.id, source: source, to: editor) }
        return editor
    }

    @MainActor
    static func addAsset(id: String, name: String, source: URL, to editor: EditorViewModel) {
        editor.mediaAssets.append(MediaAsset(id: id, url: source, type: .audio, name: name, duration: 3))
        editor.mediaManifest.entries.append(.init(id: id, name: name, type: .audio,
                                                  source: .external(absolutePath: source.path), duration: 3))
    }

    @concurrent
    static func speech(_ sources: [AudioSpeechTiming.Source], _ fps: Int) async throws -> AudioSpeechTiming.Result {
        .init(timings: sources.map { source in
            .init(clipId: source.clip.id, ranges: [source.clip.startFrame + 6..<source.clip.endFrame - 6], method: .transcript)
        }, sourceVersions: try await LoudnessAnalyzer.sourceVersions(for: sources.map(\.url)))
    }

    @concurrent
    static func finish(_ input: AudioMixFinisher.Input, _ request: AudioMixRequest, _ replace: Bool) async throws -> AudioMixFinisher.Result {
        try await AudioMixFinisher.finish(input, request: request, replaceAutomation: replace, speech: speech)
    }

    @concurrent
    static func persisted(_ timeline: Timeline, directory: URL) async throws -> Timeline {
        let url = directory.appendingPathComponent("timeline.json")
        try JSONEncoder().encode(timeline).write(to: url)
        return try JSONDecoder().decode(Timeline.self, from: Data(contentsOf: url))
    }
}
