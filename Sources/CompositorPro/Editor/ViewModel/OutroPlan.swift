import Foundation

/// Pure layout math for an end-of-video sequence: credits roll, subscribe card, and the picture
/// hold underneath them.
///
/// Separated from the mutation so the arithmetic — where an agent would otherwise have to guess at
/// off-frame positions and fade lengths — is testable without a timeline or a renderer.
struct OutroPlan: Sendable, Equatable {
    struct Credits: Sendable, Equatable {
        struct Line: Sendable, Equatable {
            var name: String
            var role: String?

            /// A roll is one text clip, so a name and its role become two lines.
            var rendered: String {
                guard let role, !role.isEmpty else { return name }
                return name + "\n" + role
            }
        }

        var lines: [Line]
    }

    struct Subscribe: Sendable, Equatable {
        enum Kind: String, Sendable, Equatable {
            case subscribe
            case thanks

            var heading: String {
                switch self {
                case .subscribe: "SUBSCRIBE"
                case .thanks: "THANKS FOR SUBSCRIBING"
                }
            }
        }

        var channel: String
        var handle: String?
        /// "subscribe" asks; "thanks" acknowledges someone who already did.
        var kind: Kind = .subscribe

        /// The heading always leads: without a handle the card would otherwise show only a
        /// channel name and lose the call to action entirely.
        var rendered: String {
            guard let handle, !handle.isEmpty else { return kind.heading + "\n" + channel }
            return kind.heading + "\n" + channel + " " + "\u{00b7}" + " " + handle
        }
    }

    enum Platform: String, Sendable, Equatable {
        case youtube
        case generic

        /// YouTube accepts end screens only in the last 5–20 seconds.
        var durationRange: ClosedRange<Int> {
            switch self {
            case .youtube: 150...600
            case .generic: 30...3600
            }
        }
    }

    // MARK: - Output

    /// Half-open frame span the outro occupies, in timeline frames.
    var startFrame: Int
    var endFrame: Int
    var durationFrames: Int { endFrame - startFrame }
    var roll: Roll?
    var subscribe: SubscribeCard?

    /// One text clip spanning the whole outro, rolled upward at a constant rate.
    struct Roll: Sendable, Equatable {
        var startFrame: Int
        var endFrame: Int
        var text: String
        /// Normalized canvas position at the start and end of the roll. Starts fully below the
        /// frame and finishes fully above it, so the block is readable in the middle whatever its
        /// height.
        var startY: Double
        var endY: Double
        var x: Double
        /// Clip-relative opacity envelope, faded in and out.
        var opacityRows: [Keyframe<Double>]
    }

    /// A held card in the first part of the outro.
    struct SubscribeCard: Sendable, Equatable {
        var startFrame: Int
        var endFrame: Int
        var text: String
        var x: Double
        var y: Double
    }

    // MARK: - Geometry

    static let rollEntryY = 1.12
    static let rollExitY = -0.12
    /// Fade length at each end of the roll, before clamping to the available duration.
    static let rollFadeFrames = 12
    /// Two elements need enough runway for each to be read before the other takes over.
    static let minBothFrames = 180
    static let rollX = 0.5

    enum PlanError: Error, Equatable, CustomStringConvertible {
        case nothingToDraw
        case nonPositiveDuration
        case emptyCredits
        case tooShortForBoth(frames: Int)
        case platformDurationOutOfRange(frames: Int, range: ClosedRange<Int>, platform: Platform)

        var description: String {
            switch self {
            case .nothingToDraw:
                "Give credits, a subscribe card, or both. With neither there is nothing to add."
            case .nonPositiveDuration:
                "Outro duration must be at least 1 frame."
            case .emptyCredits:
                "Credits were supplied but contained no text."
            case .tooShortForBoth(let frames):
                "\(frames) frames is too short for both credits and a subscribe card. "
                    + "Give at least \(minBothFrames) frames."
            case .platformDurationOutOfRange(let frames, let range, let platform):
                "\(platform.rawValue) end screens must be \(range.lowerBound)–\(range.upperBound) frames "
                    + "(\(range.lowerBound / 30)–\(range.upperBound / 30)s); \(frames) given."
            }
        }
    }

    static func plan(
        timelineTotalFrames: Int,
        outroDurationFrames: Int,
        credits: Credits?,
        subscribe: Subscribe?,
        platform: Platform,
        subscribeShareOfOutro: Double = 0.34
    ) throws -> OutroPlan {
        let creditsText = try creditsText(credits)
        guard creditsText != nil || subscribe != nil else { throw PlanError.nothingToDraw }
        guard outroDurationFrames >= 1 else { throw PlanError.nonPositiveDuration }
        if platform == .youtube, !platform.durationRange.contains(outroDurationFrames) {
            throw PlanError.platformDurationOutOfRange(
                frames: outroDurationFrames, range: platform.durationRange, platform: platform
            )
        }
        // The outro takes the tail of the existing edit rather than extending past it.
        let end = max(timelineTotalFrames, 1)
        let start = max(0, end - outroDurationFrames)
        let duration = end - start
        if creditsText != nil && subscribe != nil, duration < minBothFrames {
            throw PlanError.tooShortForBoth(frames: duration)
        }
        return OutroPlan(
            startFrame: start,
            endFrame: end,
            roll: creditsText.map { roll($0, start: start, duration: duration) },
            subscribe: subscribe.map {
                SubscribeCard(
                    startFrame: start,
                    endFrame: min(
                        end, start + max(1, Int((Double(duration) * subscribeShareOfOutro).rounded()))
                    ),
                    text: $0.rendered,
                    x: rollX,
                    y: 0.5
                )
            }
        )
    }

    private static func creditsText(_ credits: Credits?) throws -> String? {
        guard let credits else { return nil }
        let text = credits.lines.map(\.rendered).joined(separator: "\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PlanError.emptyCredits
        }
        return text
    }

    private static func roll(_ text: String, start: Int, duration: Int) -> Roll {
        let fade = min(rollFadeFrames, max(1, duration / 6))
        return Roll(
            startFrame: start,
            endFrame: start + duration,
            text: text,
            startY: rollEntryY,
            endY: rollExitY,
            x: rollX,
            opacityRows: [
                Keyframe(frame: 0, value: 0, interpolationOut: .linear),
                Keyframe(frame: fade, value: 1, interpolationOut: .linear),
                Keyframe(frame: max(fade + 1, duration - fade), value: 1, interpolationOut: .linear),
                Keyframe(frame: max(1, duration - 1), value: 0, interpolationOut: .linear),
            ]
        )
    }
}