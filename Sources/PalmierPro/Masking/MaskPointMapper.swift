import CoreMedia
import Foundation

struct SegmentPointPrompt: Equatable, Sendable {
    let x: Int
    let y: Int
    let frameIndex: Int
}

enum MaskPointMapper {
    enum MappingError: Error, Equatable {
        case invalidCoordinates
        case invalidSegment
        case sourceTimeOutOfRange
    }

    static func sourceTime(
        clip: Clip,
        timelineFrame: Int,
        timelineFPS: Int
    ) throws -> MaskSourceTime {
        guard timelineFPS > 0,
              clip.contains(timelineFrame: timelineFrame),
              clip.speed.isFinite,
              clip.speed > 0
        else { throw MappingError.sourceTimeOutOfRange }
        let sourceFrame = Double(clip.trimStartFrame)
            + Double(timelineFrame - clip.startFrame) * clip.speed
        let seconds = sourceFrame / Double(timelineFPS)
        guard seconds.isFinite, seconds >= 0 else { throw MappingError.sourceTimeOutOfRange }
        return MaskSourceTime(CMTime(seconds: seconds, preferredTimescale: 600_000))
    }

    static func map(
        _ seed: MaskPointSeed,
        trim: TrimmedSource,
        segmentWidth: Int,
        segmentHeight: Int,
        segmentFPS: Double,
        segmentFrameCount: Int
    ) throws -> SegmentPointPrompt {
        guard seed.x.isFinite, seed.y.isFinite,
              (0...1).contains(seed.x), (0...1).contains(seed.y)
        else { throw MappingError.invalidCoordinates }
        guard segmentWidth > 0, segmentHeight > 0,
              segmentFPS.isFinite, segmentFPS > 0,
              segmentFrameCount > 0
        else { throw MappingError.invalidSegment }

        let relative = seed.sourceTime.cmTime - trim.timeRange.start
        guard relative.isNumeric,
              relative >= .zero,
              relative < trim.timeRange.duration
        else { throw MappingError.sourceTimeOutOfRange }
        let frameValue = relative.seconds * segmentFPS
        guard frameValue.isFinite, frameValue >= 0, frameValue <= Double(Int.max) else {
            throw MappingError.invalidSegment
        }

        return SegmentPointPrompt(
            x: pixelCoordinate(seed.x, count: segmentWidth),
            y: pixelCoordinate(seed.y, count: segmentHeight),
            frameIndex: min(Int(frameValue.rounded()), segmentFrameCount - 1)
        )
    }

    private static func pixelCoordinate(_ normalized: Double, count: Int) -> Int {
        min(Int((normalized * Double(count)).rounded(.down)), count - 1)
    }
}
