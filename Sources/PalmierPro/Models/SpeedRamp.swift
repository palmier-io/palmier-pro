import Foundation

struct SpeedRampPoint: Codable, Sendable, Equatable {
    var position: Double
    var speed: Double
    var interpolationOut: Interpolation = .smooth
    var tangent: Double?

    private enum CodingKeys: String, CodingKey {
        case position, speed, interpolationOut, tangent
    }

    init(
        position: Double,
        speed: Double,
        interpolationOut: Interpolation = .smooth,
        tangent: Double? = nil
    ) {
        self.position = position
        self.speed = speed
        self.interpolationOut = interpolationOut
        self.tangent = tangent
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        position = try container.decode(Double.self, forKey: .position)
        speed = try container.decode(Double.self, forKey: .speed)
        interpolationOut = try container.decodeIfPresent(
            Interpolation.self,
            forKey: .interpolationOut
        ) ?? .smooth
        tangent = try container.decodeIfPresent(Double.self, forKey: .tangent)
    }
}

struct SpeedRamp: Codable, Sendable, Equatable {
    static let minimumSpeed = 0.25
    static let maximumSpeed = 4.0
    static let maximumRenderSegments = 2_048
    static let maximumFramesPerSegment = 12
    static let maximumSpeedDeltaPerSegment = 0.05
    static let maximumAuthoredPointCount = 128
    static let maximumPointCount = maximumAuthoredPointCount + 2

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

    var hasValidCurve: Bool { Self.isValid(points) }

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
            return hermite(
                from: segment.start.speed,
                to: segment.end.speed,
                startTangent: (segment.start.tangent ?? 0) * span,
                endTangent: (segment.end.tangent ?? 0) * span,
                progress: progress
            )
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
        let windowSpan = oldEndPosition - oldStartPosition
        var result = [
            SpeedRampPoint(
                position: 0,
                speed: extendedSpeed(at: oldStartPosition),
                interpolationOut: oldStartPosition < 0
                    ? .hold
                    : interpolation(at: oldStartPosition),
                tangent: derivative(at: oldStartPosition, fromLeft: false) * windowSpan
            )
        ]
        for point in points {
            let oldFrame = point.position * Double(oldDuration)
            guard oldFrame > oldStart, oldFrame < oldEnd else { continue }
            let interpolation: Interpolation = point.position == 1 && oldEndPosition > 1
                ? .hold
                : point.interpolationOut
            result.append(SpeedRampPoint(
                position: (oldFrame - oldStart) / Double(newDuration),
                speed: point.speed,
                interpolationOut: interpolation,
                tangent: (point.tangent ?? 0) * windowSpan
            ))
        }
        result.append(SpeedRampPoint(
            position: 1,
            speed: extendedSpeed(at: oldEndPosition),
            interpolationOut: .smooth,
            tangent: derivative(at: oldEndPosition, fromLeft: true) * windowSpan
        ))
        return SpeedRamp(points: simplified(result))
    }

    func timelineOffsetsForRendering(duration: Int) -> [Int] {
        guard duration > 0 else { return [0] }
        if points.count > Self.maximumPointCount {
            let segmentCount = min(duration, Self.maximumRenderSegments)
            return (0...segmentCount).map {
                Self.frame(
                    at: Double($0) / Double(segmentCount),
                    duration: duration
                )
            }
        }
        var offsets: Set<Int> = [0, duration]
        let intervalBudget = max(1, maximumRenderSegments / max(1, points.count - 1))
        for (start, end) in zip(points, points.dropFirst()) {
            let startFrame = Self.frame(at: start.position, duration: duration)
            let endFrame = Self.frame(at: end.position, duration: duration)
            offsets.insert(startFrame)
            offsets.insert(endFrame)
            let frameSpan = endFrame - startFrame
            let varies = start.speed != end.speed
                || abs(start.tangent ?? 0) > 0.000_001
                || abs(end.tangent ?? 0) > 0.000_001
            guard frameSpan > 1, start.interpolationOut != .hold, varies else {
                continue
            }
            let durationDivisions = Int(ceil(
                Double(frameSpan) / Double(Self.maximumFramesPerSegment)
            ))
            let speedDivisions = Int(ceil(
                abs(end.speed - start.speed) / Self.maximumSpeedDeltaPerSegment
            ))
            let divisions = min(
                min(intervalBudget, frameSpan),
                max(1, max(durationDivisions, speedDivisions))
            )
            for index in 1..<divisions {
                offsets.insert(startFrame + Int((Double(endFrame - startFrame) * Double(index) / Double(divisions)).rounded()))
            }
        }
        return offsets.filter { $0 >= 0 && $0 <= duration }.sorted()
    }

    private static func frame(at position: Double, duration: Int) -> Int {
        let value = (position * Double(duration)).rounded()
        guard value > 0 else { return 0 }
        guard value < Double(Int.max) else { return Int.max }
        return Int(value)
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
                area = hermiteIntegral(
                    from: start.speed,
                    to: end.speed,
                    startTangent: (start.tangent ?? 0) * span,
                    endTangent: (end.tangent ?? 0) * span,
                    progress: progress
                )
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

    private func simplified(_ points: [SpeedRampPoint]) -> [SpeedRampPoint] {
        guard points.count > 2 else { return points }
        var result: [SpeedRampPoint] = [points[0]]
        for index in 1..<(points.count - 1) {
            let previous = result[result.count - 1]
            let current = points[index]
            let next = points[index + 1]
            if Self.isConstantSegment(from: previous, to: current),
               Self.isConstantSegment(from: current, to: next) { continue }
            result.append(current)
        }
        result.append(points[points.count - 1])
        return result
    }

    private static func isConstantSegment(from start: SpeedRampPoint, to end: SpeedRampPoint) -> Bool {
        guard abs(start.speed - end.speed) < 0.000_000_001 else { return false }
        switch start.interpolationOut {
        case .hold, .linear:
            return true
        case .smooth:
            return abs(start.tangent ?? 0) < 0.000_000_001
                && abs(end.tangent ?? 0) < 0.000_000_001
        }
    }

    private func derivative(at position: Double, fromLeft: Bool) -> Double {
        guard position >= 0, position <= 1 else { return 0 }
        let pairs = Array(zip(points, points.dropFirst()))
        let segment: (start: SpeedRampPoint, end: SpeedRampPoint)?
        if fromLeft {
            segment = pairs.last(where: { position > $0.0.position && position <= $0.1.position })
        } else {
            segment = pairs.first(where: { position >= $0.0.position && position < $0.1.position })
        }
        guard let segment else { return 0 }
        let span = segment.end.position - segment.start.position
        guard span > 0 else { return 0 }
        let progress = (position - segment.start.position) / span
        switch segment.start.interpolationOut {
        case .hold:
            return 0
        case .linear:
            return (segment.end.speed - segment.start.speed) / span
        case .smooth:
            let t = progress
            let startTangent = (segment.start.tangent ?? 0) * span
            let endTangent = (segment.end.tangent ?? 0) * span
            let value = (6 * t * t - 6 * t) * segment.start.speed
                + (3 * t * t - 4 * t + 1) * startTangent
                + (-6 * t * t + 6 * t) * segment.end.speed
                + (3 * t * t - 2 * t) * endTangent
            return value / span
        }
    }

    private func hermite(
        from start: Double,
        to end: Double,
        startTangent: Double,
        endTangent: Double,
        progress: Double
    ) -> Double {
        let t2 = progress * progress
        let t3 = t2 * progress
        return (2 * t3 - 3 * t2 + 1) * start
            + (t3 - 2 * t2 + progress) * startTangent
            + (-2 * t3 + 3 * t2) * end
            + (t3 - t2) * endTangent
    }

    private func hermiteIntegral(
        from start: Double,
        to end: Double,
        startTangent: Double,
        endTangent: Double,
        progress: Double
    ) -> Double {
        let t2 = progress * progress
        let t3 = t2 * progress
        let t4 = t3 * progress
        return (t4 / 2 - t3 + progress) * start
            + (t4 / 4 - 2 * t3 / 3 + t2 / 2) * startTangent
            + (-t4 / 2 + t3) * end
            + (t4 / 4 - t3 / 3) * endTangent
    }

    private static func normalized(_ points: [SpeedRampPoint]) -> [SpeedRampPoint] {
        var keyed: [Double: SpeedRampPoint] = [:]
        for point in points
        where point.position.isFinite && point.speed.isFinite && point.tangent?.isFinite != false {
            let position = min(1, max(0, point.position))
            keyed[position] = SpeedRampPoint(
                position: position,
                speed: min(maximumSpeed, max(minimumSpeed, point.speed)),
                interpolationOut: point.interpolationOut,
                tangent: point.tangent
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
              points.count <= maximumPointCount,
              points.first?.position == 0,
              points.last?.position == 1 else { return false }
        var previous = -Double.infinity
        for point in points {
            guard point.position.isFinite,
                  point.speed.isFinite,
                  point.tangent?.isFinite != false,
                  point.position > previous,
                  (0...1).contains(point.position),
                  (minimumSpeed...maximumSpeed).contains(point.speed) else { return false }
            previous = point.position
        }
        if points.count > maximumAuthoredPointCount {
            guard isConstantSegment(from: points[0], to: points[1])
                    || isConstantSegment(
                        from: points[points.count - 2],
                        to: points[points.count - 1]
                    ) else { return false }
        }
        for (start, end) in zip(points, points.dropFirst())
        where start.interpolationOut == .smooth {
            let span = end.position - start.position
            for index in 0...128 {
                let progress = Double(index) / 128
                let value = hermiteValue(
                    from: start.speed,
                    to: end.speed,
                    startTangent: (start.tangent ?? 0) * span,
                    endTangent: (end.tangent ?? 0) * span,
                    progress: progress
                )
                guard (minimumSpeed...maximumSpeed).contains(value) else { return false }
            }
        }
        return true
    }

    private static func hermiteValue(
        from start: Double,
        to end: Double,
        startTangent: Double,
        endTangent: Double,
        progress: Double
    ) -> Double {
        let t2 = progress * progress
        let t3 = t2 * progress
        return (2 * t3 - 3 * t2 + 1) * start
            + (t3 - 2 * t2 + progress) * startTangent
            + (-2 * t3 + 3 * t2) * end
            + (t3 - t2) * endTangent
    }
}
