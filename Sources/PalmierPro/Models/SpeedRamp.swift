import Foundation

struct SpeedRampPoint: Codable, Sendable, Equatable {
    var position: Double
    var speed: Double
    var interpolationOut: Interpolation = .smooth

    private enum CodingKeys: String, CodingKey {
        case position, speed, interpolationOut
    }

    init(position: Double, speed: Double, interpolationOut: Interpolation = .smooth) {
        self.position = position
        self.speed = speed
        self.interpolationOut = interpolationOut
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        position = try container.decode(Double.self, forKey: .position)
        speed = try container.decode(Double.self, forKey: .speed)
        interpolationOut = try container.decodeIfPresent(
            Interpolation.self,
            forKey: .interpolationOut
        ) ?? .smooth
    }
}

struct SpeedRamp: Codable, Sendable, Equatable {
    static let minimumSpeed = 0.25
    static let maximumSpeed = 4.0
    static let renderSubdivisions = 16

    var points: [SpeedRampPoint]

    init(points: [SpeedRampPoint]) {
        self.points = Self.normalized(points)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let decoded = try container.decode([SpeedRampPoint].self)
        guard Self.isValid(decoded) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Speed ramp points must be finite, ordered, in range, and include 0 and 1."
            )
        }
        points = decoded
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(points)
    }

    var averageSpeed: Double {
        integral(through: 1)
    }

    func speed(at position: Double) -> Double {
        let position = min(1, max(0, position))
        if let point = points.first(where: { abs($0.position - position) < 0.000_000_001 }) {
            return point.speed
        }
        guard let segment = segment(containing: position) else {
            return points.first?.speed ?? 1
        }
        let span = segment.end.position - segment.start.position
        guard span > 0 else { return segment.end.speed }
        let progress = (position - segment.start.position) / span
        switch segment.start.interpolationOut {
        case .hold:
            return segment.start.speed
        case .linear:
            return segment.start.speed + (segment.end.speed - segment.start.speed) * progress
        case .smooth:
            return segment.start.speed + (segment.end.speed - segment.start.speed) * smoothstep(progress)
        }
    }

    func sourceOffset(atTimelineOffset offset: Double, duration: Int) -> Double {
        guard duration > 0 else { return 0 }
        let position = min(1, max(0, offset / Double(duration)))
        return Double(duration) * integral(through: position)
    }

    func timelineOffset(atSourceOffset offset: Double, duration: Int) -> Double? {
        guard duration > 0, offset.isFinite, offset >= 0 else { return nil }
        let total = sourceOffset(atTimelineOffset: Double(duration), duration: duration)
        guard offset <= total + 0.000_001 else { return nil }
        var low = 0.0
        var high = Double(duration)
        for _ in 0..<48 {
            let middle = (low + high) / 2
            if sourceOffset(atTimelineOffset: middle, duration: duration) < offset {
                low = middle
            } else {
                high = middle
            }
        }
        return (low + high) / 2
    }

    func windowed(startOffset: Int, duration newDuration: Int, oldDuration: Int) -> SpeedRamp {
        guard newDuration > 0, oldDuration > 0 else { return self }
        let oldStart = Double(startOffset)
        let oldEnd = oldStart + Double(newDuration)
        let oldStartPosition = oldStart / Double(oldDuration)
        let oldEndPosition = oldEnd / Double(oldDuration)
        let clipsSmoothSegment = zip(points, points.dropFirst()).contains { start, end in
            start.interpolationOut == .smooth
                && oldStartPosition < end.position
                && oldEndPosition > start.position
        }
        if clipsSmoothSegment {
            let sampleCount = 32
            let sampled = (0...sampleCount).map { index in
                let localPosition = Double(index) / Double(sampleCount)
                let oldPosition = oldStartPosition
                    + (oldEndPosition - oldStartPosition) * localPosition
                return SpeedRampPoint(
                    position: localPosition,
                    speed: extendedSpeed(at: oldPosition),
                    interpolationOut: .linear
                )
            }
            return SpeedRamp(points: sampled)
        }
        var result = [
            SpeedRampPoint(
                position: 0,
                speed: extendedSpeed(at: oldStartPosition),
                interpolationOut: interpolation(at: oldStartPosition)
            )
        ]
        for point in points {
            let oldFrame = point.position * Double(oldDuration)
            guard oldFrame > oldStart, oldFrame < oldEnd else { continue }
            result.append(SpeedRampPoint(
                position: (oldFrame - oldStart) / Double(newDuration),
                speed: point.speed,
                interpolationOut: point.interpolationOut
            ))
        }
        result.append(SpeedRampPoint(
            position: 1,
            speed: extendedSpeed(at: oldEndPosition),
            interpolationOut: .smooth
        ))
        return SpeedRamp(points: result)
    }

    func timelineOffsetsForRendering(duration: Int) -> [Int] {
        guard duration > 0 else { return [0] }
        var offsets: Set<Int> = [0, duration]
        for (start, end) in zip(points, points.dropFirst()) {
            let startFrame = Int((start.position * Double(duration)).rounded())
            let endFrame = Int((end.position * Double(duration)).rounded())
            offsets.insert(startFrame)
            offsets.insert(endFrame)
            guard endFrame - startFrame > 1, start.speed != end.speed, start.interpolationOut != .hold else {
                continue
            }
            let divisions = min(Self.renderSubdivisions, endFrame - startFrame)
            for index in 1..<divisions {
                offsets.insert(startFrame + Int((Double(endFrame - startFrame) * Double(index) / Double(divisions)).rounded()))
            }
        }
        return offsets.filter { $0 >= 0 && $0 <= duration }.sorted()
    }

    private func integral(through position: Double) -> Double {
        let position = min(1, max(0, position))
        var result = 0.0
        for (start, end) in zip(points, points.dropFirst()) {
            guard position > start.position else { break }
            let span = end.position - start.position
            guard span > 0 else { continue }
            let progress = min(1, (position - start.position) / span)
            let delta = end.speed - start.speed
            let area: Double
            switch start.interpolationOut {
            case .hold:
                area = start.speed * progress
            case .linear:
                area = start.speed * progress + delta * progress * progress / 2
            case .smooth:
                area = start.speed * progress + delta * (pow(progress, 3) - pow(progress, 4) / 2)
            }
            result += span * area
            if position <= end.position { break }
        }
        return result
    }

    private func segment(containing position: Double) -> (start: SpeedRampPoint, end: SpeedRampPoint)? {
        for (start, end) in zip(points, points.dropFirst()) where position < end.position {
            return (start, end)
        }
        return nil
    }

    private func interpolation(at position: Double) -> Interpolation {
        let position = min(1, max(0, position))
        if let point = points.first(where: { abs($0.position - position) < 0.000_000_001 }) {
            return point.interpolationOut
        }
        return segment(containing: position)?.start.interpolationOut ?? .smooth
    }

    private func extendedSpeed(at position: Double) -> Double {
        if position <= 0 { return points[0].speed }
        if position >= 1 { return points[points.count - 1].speed }
        return speed(at: position)
    }

    private static func normalized(_ points: [SpeedRampPoint]) -> [SpeedRampPoint] {
        var keyed: [Double: SpeedRampPoint] = [:]
        for point in points where point.position.isFinite && point.speed.isFinite {
            let position = min(1, max(0, point.position))
            keyed[position] = SpeedRampPoint(
                position: position,
                speed: min(maximumSpeed, max(minimumSpeed, point.speed)),
                interpolationOut: point.interpolationOut
            )
        }
        var result = keyed.values.sorted { $0.position < $1.position }
        if result.isEmpty {
            result = [
                SpeedRampPoint(position: 0, speed: 1),
                SpeedRampPoint(position: 1, speed: 1),
            ]
        } else {
            if result[0].position > 0 {
                result.insert(SpeedRampPoint(position: 0, speed: result[0].speed, interpolationOut: result[0].interpolationOut), at: 0)
            }
            if result[result.count - 1].position < 1 {
                result.append(SpeedRampPoint(position: 1, speed: result[result.count - 1].speed))
            }
            if result.count == 1 {
                result.append(SpeedRampPoint(position: 1, speed: result[0].speed))
            }
        }
        return result
    }

    private static func isValid(_ points: [SpeedRampPoint]) -> Bool {
        guard points.count >= 2,
              points.first?.position == 0,
              points.last?.position == 1 else { return false }
        var previous = -Double.infinity
        for point in points {
            guard point.position.isFinite,
                  point.speed.isFinite,
                  point.position > previous,
                  (0...1).contains(point.position),
                  (minimumSpeed...maximumSpeed).contains(point.speed) else { return false }
            previous = point.position
        }
        return true
    }
}
