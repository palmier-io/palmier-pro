import Testing
@testable import PalmierPro

@Suite("Cost estimator localization")
@MainActor
struct CostEstimatorLocalizationTests {
    @Test func singularCreditCopyUsesSingularNoun() {
        #expect(CostEstimator.localizedEstimate(1) == "1 credit estimated. Actual billing may differ.")
        #expect(CostEstimator.localizedInsufficientCredits(1, remaining: 0) == "1 credit needed. Only 0 remaining.")
        #expect(CostEstimator.localizedRemainingCredits(1, remaining: 4) == "1 credit. 4 remaining after this generation.")
        #expect(CostEstimator.localizedGenerateLabel(1) == "Generate · 1 credit")
    }

    @Test(arguments: [-2, 0])
    func nonpositiveUsedCreditsDisplayAsZero(credits: Int) {
        #expect(CostEstimator.localizedUsedCredits(credits) == "0 credits used")
    }

    @Test func usedCreditsHandleSingularAndPlural() {
        #expect(CostEstimator.localizedUsedCredits(1) == "1 credit used")
        #expect(CostEstimator.localizedUsedCredits(2) == "2 credits used")
    }
}
