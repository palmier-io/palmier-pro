import Foundation

/// Number-field expression evaluator: +, -, *, /, parentheses, decimals, unary sign. Deliberately
/// a hand-written recursive-descent parser — no eval, no function calls, no variables.
enum MathExpression {
    enum Failure: Error, Equatable {
        case invalidSyntax
        case divisionByZero
        case notFinite
    }

    static func evaluate(_ text: String) -> Double? {
        guard let value = try? parse(text) else { return nil }
        return value
    }

    static func parse(_ text: String) throws -> Double {
        var parser = Parser(Array(text.filter { !$0.isWhitespace }))
        let value = try parser.expression()
        guard parser.isAtEnd else { throw Failure.invalidSyntax }
        guard value.isFinite else { throw Failure.notFinite }
        return value
    }

    private struct Parser {
        private let characters: [Character]
        private var index = 0

        init(_ characters: [Character]) { self.characters = characters }

        var isAtEnd: Bool { index == characters.count }

        private var current: Character? { isAtEnd ? nil : characters[index] }
        private mutating func advance() { index += 1 }

        mutating func expression() throws -> Double {
            var value = try term()
            while let op = current, op == "+" || op == "-" {
                advance()
                let rhs = try term()
                value = op == "+" ? value + rhs : value - rhs
            }
            return value
        }

        private mutating func term() throws -> Double {
            var value = try factor()
            while let op = current, op == "*" || op == "/" {
                advance()
                let rhs = try factor()
                if op == "/" {
                    guard rhs != 0 else { throw Failure.divisionByZero }
                    value /= rhs
                } else {
                    value *= rhs
                }
            }
            return value
        }

        private mutating func factor() throws -> Double {
            if current == "-" {
                advance()
                return -(try factor())
            }
            if current == "+" {
                advance()
                return try factor()
            }
            if current == "(" {
                advance()
                let value = try expression()
                guard current == ")" else { throw Failure.invalidSyntax }
                advance()
                return value
            }
            return try number()
        }

        private mutating func number() throws -> Double {
            var digits = ""
            var sawDot = false
            while let character = current, character.isNumber || (character == "." && !sawDot) {
                if character == "." { sawDot = true }
                digits.append(character)
                advance()
            }
            guard let value = Double(digits), value.isFinite else { throw Failure.invalidSyntax }
            return value
        }
    }
}

/// Committed number-field behavior: evaluate the expression, clamp into the field's range, and
/// keep the previous value when the text is not a number.
enum MathNumberInput {
    static func commit(_ text: String, previous: Double, range: ClosedRange<Double>) -> Double {
        guard let value = MathExpression.evaluate(text) else { return previous }
        return min(range.upperBound, max(range.lowerBound, value))
    }

    static func scrubbed(_ value: Double, bySteps steps: Int, step: Double, range: ClosedRange<Double>) -> Double {
        let next = value + Double(steps) * step
        return min(range.upperBound, max(range.lowerBound, next))
    }

    static func display(_ value: Double, decimals: Int) -> String {
        guard value.isFinite else { return "0" }
        return String(format: "%.\(max(0, min(6, decimals)))f", value)
    }
}
