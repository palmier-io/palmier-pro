import Testing
@testable import PalmierPro

@Suite("Analytics session activation")
struct AnalyticsSessionActivationTests {
    @Test func capturesOnlyFirstActivation() {
        var activation = Analytics.SessionActivation()

        let firstActivation = activation.activate()
        let secondActivation = activation.activate()

        #expect(firstActivation)
        #expect(!secondActivation)
        #expect(activation.isActivated)
    }

    @Test func restoredActiveSessionDoesNotCaptureAgain() {
        var activation = Analytics.SessionActivation(isActivated: true)

        let repeatedActivation = activation.activate()

        #expect(!repeatedActivation)
    }
}
