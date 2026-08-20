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
        guard width > 0, height > 0, width <= Int.max / height else { throw .outOfBounds }
        let area = width * height
        let tokens = string.split(separator: " ")
        guard tokens.count.isMultiple(of: 2) else { throw .oddPairCount }

        var runs: [Run] = []
        runs.reserveCapacity(tokens.count / 2)
        var previousEnd = -1
        for i in stride(from: 0, to: tokens.count, by: 2) {
            guard let start = Int(tokens[i]), start >= 0,
                  let length = Int(tokens[i + 1]), length >= 0
            else { throw .malformedToken }
            var run = Run(start: start, length: length)
            guard run.length > 0 else { throw .nonPositiveLength }
            guard run.start > previousEnd else { throw .overlappingRuns }
            guard run.start < area else { throw .outOfBounds }
            let available = area - run.start
            if run.length > available {
                guard run.length - available <= width else { throw .outOfBounds }
                run.length = available
            }
            previousEnd = run.start + run.length - 1
            runs.append(run)
        }
        return runs
    }
}
