import Foundation
@testable import PalmierPro

enum Fixtures {
    static func clip(
        id: String = UUID().uuidString,
        mediaRef: String = "media-1",
        mediaType: ClipType = .video,
        start: Int,
        duration: Int,
        trimStart: Int = 0,
        trimEnd: Int = 0,
        speed: Double = 1.0,
        volume: Double = 1.0
    ) -> Clip {
        var c = Clip(mediaRef: mediaRef, startFrame: start, durationFrames: duration)
        c.id = id
        c.mediaType = mediaType
        c.sourceClipType = mediaType
        c.trimStartFrame = trimStart
        c.trimEndFrame = trimEnd
        c.speed = speed
        c.volume = volume
        return c
    }

    static func videoTrack(id: String = UUID().uuidString, label: String = "V1", clips: [Clip] = []) -> Track {
        var t = Track(type: .video, label: label, clips: clips)
        t.id = id
        return t
    }

    static func audioTrack(id: String = UUID().uuidString, label: String = "A1", clips: [Clip] = []) -> Track {
        var t = Track(type: .audio, label: label, clips: clips)
        t.id = id
        return t
    }

    static func timeline(fps: Int = 30, tracks: [Track] = []) -> Timeline {
        var t = Timeline()
        t.fps = fps
        t.tracks = tracks
        return t
    }
}
