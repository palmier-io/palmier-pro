import Testing
@testable import PalmierPro

@Suite("Analytics session activation")
struct AnalyticsSessionActivationTests {
    @Test func capturesOnlyFirstActivation() {
        var activation = Analytics.SessionActivation()

        #expect(activation.activate())
        #expect(!activation.activate())

        #expect(activation.isActivated)
    }

    @Test func restoredActiveSessionDoesNotCaptureAgain() {
        var activation = Analytics.SessionActivation(isActivated: true)

        #expect(!activation.activate())
    }
}
