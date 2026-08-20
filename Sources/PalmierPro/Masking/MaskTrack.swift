import Foundation

struct MaskTrack: Codable, Sendable, Equatable {
    var id: String
    var mediaRef: String
    var fps: Double
    var firstSourceFrame: Int
    var frameCount: Int
}

struct MaskTrackPayload: Decodable, Sendable {
    var rle: [String]
}

/// Each frame is encoded as space-separated `(start, length)` pixel runs in row-major order.
enum MaskRLE {
    struct Run: Equatable, Sendable {
        var start: Int
        var length: Int
    }

    enum DecodeError: Error, Equatable {
        case malformedToken
        case oddPairCount
        case nonPositiveLength
        case outOfBounds
        case overlappingRuns
    }

    static func runs(from string: String, width: Int, height: Int) throws(DecodeError) -> [Run] {
        let area = width * height
        var values: [Int] = []
        for token in string.split(separator: " ") {
            guard let value = Int(token), value >= 0 else { throw .malformedToken }
            values.append(value)
        }
        guard values.count.isMultiple(of: 2) else { throw .oddPairCount }

        var runs: [Run] = []
        runs.reserveCapacity(values.count / 2)
        var previousEnd = -1
        for i in stride(from: 0, to: values.count, by: 2) {
            var run = Run(start: values[i], length: values[i + 1])
            guard run.length > 0 else { throw .nonPositiveLength }
            guard run.start > previousEnd else { throw .overlappingRuns }
            let overrun = run.start + run.length - area
            if overrun > 0 {
                guard overrun <= width, run.start < area else { throw .outOfBounds }
                run.length -= overrun
            }
            previousEnd = run.start + run.length - 1
            runs.append(run)
        }
        return runs
    }
}
