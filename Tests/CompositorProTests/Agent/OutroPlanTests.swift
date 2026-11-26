import Foundation
import Testing

@testable import CompositorPro

@Suite("Outro plan")
struct OutroPlanTests {
    private func credits(_ names: [String]) -> OutroPlan.Credits {
        OutroPlan.Credits(lines: names.map { .init(name: $0, role: nil) })
    }

    private func plan(
        total: Int = 900,
        duration: Int = 300,
        credits: OutroPlan.Credits? = nil,
        subscribe: OutroPlan.Subscribe? = nil,
        platform: OutroPlan.Platform = .generic
    ) throws -> OutroPlan {
        try OutroPlan.plan(
            timelineTotalFrames: total, outroDurationFrames: duration,
            credits: credits, subscribe: subscribe,
            platform: platform
        )
    }

    @Test("Outro occupies the tail of the existing edit rather than extending past it")
    func occupiesTail() throws {
        let result = try plan(total: 900, duration: 300, credits: credits(["A"]))
        #expect(result.startFrame == 600)
        #expect(result.endFrame == 900)
        #expect(result.durationFrames == 300)
    }

    @Test("A timeline shorter than the requested duration is not extended")
    func doesNotExtendShortTimeline() throws {
        let result = try plan(total: 120, duration: 300, credits: credits(["A"]))
        #expect(result.startFrame == 0)
        #expect(result.endFrame == 120)
        #expect(result.durationFrames == 120)
    }

    @Test("A roll starts fully below the frame and exits fully above it")
    func rollTravelsOffFrame() throws {
        let result = try plan(duration: 300, credits: credits(["A"]))
        let roll = try #require(result.roll)
        #expect(roll.startY > 1.0, "must begin clear of the bottom edge")
        #expect(roll.endY < 0.0, "must finish clear of the top edge")
        #expect(roll.x == 0.5)
    }

    @Test("Roll opacity fades in and out, and never rises above full or drops below zero")
    func rollFadeEnvelope() throws {
        let result = try plan(duration: 300, credits: credits(["A"]))
        let roll = try #require(result.roll)
        let values = roll.opacityRows.map(\.value)
        #expect(values.first == 0.0)
        #expect(values.last == 0.0)
        #expect(values.contains(1.0))
        #expect(values.allSatisfy { $0 >= 0 && $0 <= 1 })
        let frames = roll.opacityRows.map(\.frame)
        #expect(frames == frames.sorted(), "envelope must advance monotonically")
    }

    @Test("Fade never consumes more than a third of a short outro")
    func fadeClampsToShortOutro() throws {
        let result = try plan(duration: 12, credits: credits(["A"]))
        let roll = try #require(result.roll)
        #expect(roll.opacityRows.count == 4)
        #expect(roll.opacityRows.allSatisfy { $0.frame < 12 })
    }

    @Test("Each credit becomes its own line, and a role adds a second line")
    func creditLinesRender() throws {
        let result = try plan(
            credits: OutroPlan.Credits(lines: [
                .init(name: "Directed by", role: "A. Editor"),
                .init(name: "Music by", role: nil),
            ])
        )
        let roll = try #require(result.roll)
        #expect(roll.text == "Directed by\nA. Editor\nMusic by")
    }

    @Test("Subscribe card is held in the opening part of the outro")
    func subscribeCardPlacement() throws {
        let result = try plan(
            duration: 300,
            subscribe: .init(channel: "Compositor Pro", handle: "@cpro", kind: .subscribe)
        )
        let card = try #require(result.subscribe)
        #expect(card.startFrame == result.startFrame)
        #expect(card.endFrame > card.startFrame)
        #expect(card.endFrame <= result.endFrame)
        #expect(card.text == "SUBSCRIBE\nCompositor Pro \u{00b7} @cpro")
    }

    @Test("A thanks card is worded for an existing subscriber")
    func thanksCardWording() throws {
        let thanks = OutroPlan.Subscribe(channel: "C", handle: nil, kind: .thanks)
        #expect(thanks.rendered == "THANKS FOR SUBSCRIBING\nC", "the heading must survive")
        let asking = OutroPlan.Subscribe(channel: "C", handle: nil, kind: .subscribe)
        #expect(asking.rendered == "SUBSCRIBE\nC")
    }

    @Test(
        "YouTube rejects durations outside its 5-20 second end-screen window",
        arguments: [(30, false), (149, false), (150, true), (600, true), (601, false)]
    )
    func youtubeWindow(duration: Int, accepted: Bool) {
        let result = Result {
            try plan(
                duration: duration, subscribe: .init(channel: "C"),
                platform: .youtube
            )
        }
        if accepted {
            #expect(throws: Never.self) { try result.get() }
        } else {
            #expect(throws: OutroPlan.PlanError.self) { try result.get() }
        }
    }

    @Test("Credits and a subscribe card together need 180 frames")
    func bothNeedRunway() {
        #expect(throws: OutroPlan.PlanError.tooShortForBoth(frames: 179)) {
            try plan(duration: 179, credits: credits(["A"]), subscribe: .init(channel: "C"))
        }
        #expect(throws: Never.self) {
            try plan(duration: 180, credits: credits(["A"]), subscribe: .init(channel: "C"))
        }
    }

    @Test("Neither credits nor a card is refused rather than silently doing nothing")
    func refusesNoOp() {
        #expect(throws: OutroPlan.PlanError.nothingToDraw) {
            try plan(duration: 300)
        }
    }

    @Test("Empty credit text is refused instead of drawing an invisible roll")
    func refusesEmptyCredits() {
        #expect(throws: OutroPlan.PlanError.emptyCredits) {
            try plan(credits: .init(lines: [.init(name: "   ", role: nil)]))
        }
    }

    @Test("Zero and negative durations are refused")
    func refusesNonPositiveDuration() {
        #expect(throws: OutroPlan.PlanError.nonPositiveDuration) {
            try plan(duration: 0, credits: credits(["A"]))
        }
        #expect(throws: OutroPlan.PlanError.nonPositiveDuration) {
            try plan(duration: -30, credits: credits(["A"]))
        }
    }

    @Test("Generic platform imposes no YouTube window")
    func genericIsPermissive() throws {
        #expect(throws: Never.self) { try plan(duration: 45, subscribe: .init(channel: "C")) }
    }
}