import Testing
@testable import PalmierPro

@Suite("Scrubbable number field")
struct ScrubbableNumberFieldTests {
    @Test(arguments: ["nan", "NaN", "inf", "-inf"])
    func rejectsNonFiniteValues(_ text: String) {
        let value = ScrubbableNumberField.committedValue(
            from: text,
            suffix: "°",
            displayMultiplier: 1,
            range: -360...360
        )

        #expect(value == nil)
    }

    @Test func parsesSuffixDecimalCommaAndClamps() {
        let value = ScrubbableNumberField.committedValue(
            from: "125,5%",
            suffix: "%",
            displayMultiplier: 100,
            range: 0...1
        )

        #expect(value == 1)
    }
}
