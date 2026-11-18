import Testing
@testable import CompositorPro

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

    @Test func evaluatesArithmeticExpressionsInTheField() {
        let value = ScrubbableNumberField.committedValue(
            from: "1920/2",
            suffix: "",
            displayMultiplier: 1,
            range: 0...4096
        )
        #expect(value == 960)

        let clamped = ScrubbableNumberField.committedValue(
            from: "50 + 25",
            suffix: "",
            displayMultiplier: 1,
            range: 0...60
        )
        #expect(clamped == 60)

        #expect(ScrubbableNumberField.committedValue(
            from: "3 * ",
            suffix: "",
            displayMultiplier: 1,
            range: 0...100
        ) == nil)
    }
}
