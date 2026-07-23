import Testing
@testable import PalmierPro

@Suite("CostEstimator")
struct CostEstimatorTests {

    @Test func agentFormatStaysEnglishAndPluralizes() {
        #expect(CostEstimator.agentFormat(0) == "0 credits")
        #expect(CostEstimator.agentFormat(1) == "1 credit")
        #expect(CostEstimator.agentFormat(2) == "2 credits")
    }
}
