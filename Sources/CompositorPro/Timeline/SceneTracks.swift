import Foundation

enum TrackError: LocalizedError, Equatable {
    case missingMainVideoTrack
    case singletonMainTrackViolation
    case wrongTrackKind(trackId: String, mediaType: ClipType)

    var errorDescription: String? {
        switch self {
        case .missingMainVideoTrack: "A scene needs exactly one main video track."
        case .singletonMainTrackViolation: "A scene has exactly one main video track; add extra video tracks as overlays."
        case .wrongTrackKind(let trackId, let mediaType):
            "Clip type '\(mediaType.rawValue)' cannot live on track '\(trackId)'."
        }
    }
}

/// Type-safe track ordering: one main video track, extra video tracks as overlays, and audio
/// tracks. Video/audio separation is enforced at insertion, so a stack cannot mix kinds.
struct SceneTracks: Sendable, Equatable {
    private(set) var main: Track
    private(set) var overlays: [Track]
    private(set) var audio: [Track]

    init(main: Track, overlays: [Track] = [], audio: [Track] = []) throws {
        guard Self.isVisualTrack(main) else { throw TrackError.missingMainVideoTrack }
        for overlay in overlays where !Self.isVisualTrack(overlay) {
            throw TrackError.wrongTrackKind(trackId: overlay.id, mediaType: overlay.type)
        }
        for track in audio where track.type != .audio {
            throw TrackError.wrongTrackKind(trackId: track.id, mediaType: track.type)
        }
        self.main = main
        self.overlays = overlays
        self.audio = audio
    }

    /// Adapter for the flat timeline model: the first visual track is main, the rest are overlays.
    init(timeline: Timeline) throws {
        let visual = timeline.tracks.filter(Self.isVisualTrack)
        let audio = timeline.tracks.filter { $0.type == .audio }
        guard let main = visual.first else { throw TrackError.missingMainVideoTrack }
        try self.init(main: main, overlays: Array(visual.dropFirst()), audio: audio)
    }

    /// Flat order matches the timeline convention: main, overlays, audio.
    var tracks: [Track] { [main] + overlays + audio }

    func track(id: String) -> Track? {
        tracks.first { $0.id == id }
    }

    /// Insertion fails when the clip's media kind does not match the destination track.
    mutating func insert(_ clip: Clip, into trackId: String) throws {
        if trackId == main.id {
            guard Self.accepts(clip.mediaType, as: main) else {
                throw TrackError.wrongTrackKind(trackId: trackId, mediaType: clip.mediaType)
            }
            main.clips.append(clip)
            return
        }
        if let index = overlays.firstIndex(where: { $0.id == trackId }) {
            guard Self.accepts(clip.mediaType, as: overlays[index]) else {
                throw TrackError.wrongTrackKind(trackId: trackId, mediaType: clip.mediaType)
            }
            overlays[index].clips.append(clip)
            return
        }
        if let index = audio.firstIndex(where: { $0.id == trackId }) {
            guard Self.accepts(clip.mediaType, as: audio[index]) else {
                throw TrackError.wrongTrackKind(trackId: trackId, mediaType: clip.mediaType)
            }
            audio[index].clips.append(clip)
            return
        }
        throw TrackError.wrongTrackKind(trackId: trackId, mediaType: clip.mediaType)
    }

    /// The main track cannot be duplicated; a second video track must be an overlay.
    mutating func addOverlay(_ track: Track) throws {
        guard Self.isVisualTrack(track) else { throw TrackError.wrongTrackKind(trackId: track.id, mediaType: track.type) }
        guard track.id != main.id, !overlays.contains(where: { $0.id == track.id }) else {
            throw TrackError.singletonMainTrackViolation
        }
        overlays.append(track)
    }

    private static func isVisualTrack(_ track: Track) -> Bool {
        [.video, .image, .lottie, .sequence].contains(track.type) && track.type != .audio
    }

    private static func accepts(_ mediaType: ClipType, as track: Track) -> Bool {
        track.type == .audio ? mediaType == .audio : mediaType != .audio
    }
}
