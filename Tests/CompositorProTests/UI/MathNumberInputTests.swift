import Foundation
import Testing
@testable import CompositorPro

@Suite("Math number input")
struct MathNumberInputTests {
    @Test func evaluatesArithmeticWithPrecedence() {
        #expect(MathExpression.evaluate("1920/2") == 960)
        #expect(MathExpression.evaluate("2 + 3 * 4") == 14)
        #expect(MathExpression.evaluate("(2 + 3) * 4") == 20)
        #expect(MathExpression.evaluate("-2 * (3 - 5)") == 4)
        #expect(MathExpression.evaluate("1.5 * 2") == 3)
        #expect(MathExpression.evaluate("10 / 4") == 2.5)
    }

    @Test func rejectsInvalidOrUnsafeInput() {
        #expect(MathExpression.evaluate("") == nil)
        #expect(MathExpression.evaluate("1920/") == nil)
        #expect(MathExpression.evaluate("(1 + 2") == nil)
        #expect(MathExpression.evaluate("1 + 2)") == nil)
        #expect(MathExpression.evaluate("1/0") == nil)
        #expect(MathExpression.evaluate("2 pie") == nil)
        #expect(MathExpression.evaluate("alert(1)") == nil)
    }

    @Test func commitKeepsPreviousValueAndClampsToRange() {
        let range = 0.0...100.0
        #expect(MathNumberInput.commit("50/2", previous: 7, range: range) == 25)
        #expect(MathNumberInput.commit("500", previous: 7, range: range) == 100)
        #expect(MathNumberInput.commit("-5", previous: 7, range: range) == 0)
        #expect(MathNumberInput.commit("nonsense", previous: 7, range: range) == 7)
    }

    @Test func scrubbingClampsAndSteps() {
        let range = 0.0...10.0
        #expect(MathNumberInput.scrubbed(5, bySteps: 2, step: 0.5, range: range) == 6)
        #expect(MathNumberInput.scrubbed(9.5, bySteps: 5, step: 0.5, range: range) == 10)
        #expect(MathNumberInput.scrubbed(0.5, bySteps: -5, step: 0.5, range: range) == 0)
    }

    @Test func displayRespectsDecimalPrecision() {
        #expect(MathNumberInput.display(960, decimals: 0) == "960")
        #expect(MathNumberInput.display(1.23456, decimals: 2) == "1.23")
        #expect(MathNumberInput.display(.nan, decimals: 2) == "0")
    }
}
