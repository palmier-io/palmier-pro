import Testing
@testable import PalmierPro

@Suite("RGBA hex parsing")
struct RGBAHexTests {

    // MARK: - 3-digit form (expands each char to a byte)

    @Test func threeDigitExpandsEachChannel() {
        // "F0A" → r=FF/255=1, g=00/255=0, b=AA/255=170/255.
        let c = TextStyle.RGBA(hex: "F0A")
        #expect(c?.r == 1.0)
        #expect(c?.g == 0)
        #expect(abs((c?.b ?? -1) - 170.0/255.0) < 1e-9)
        #expect(c?.a == 1)
    }

    @Test func threeDigitWhiteIsAllOnes() {
        let c = TextStyle.RGBA(hex: "fff")
        #expect(c?.r == 1)
        #expect(c?.g == 1)
        #expect(c?.b == 1)
        #expect(c?.a == 1)
    }

    // MARK: - 6-digit form

    @Test func sixDigitParsesEachChannelAsByte() {
        let c = TextStyle.RGBA(hex: "FF8800")
        #expect(c?.r == 1)
        #expect(abs((c?.g ?? -1) - 136.0/255.0) < 1e-9)
        #expect(c?.b == 0)
        #expect(c?.a == 1) // alpha defaults to 1 in 6-digit form
    }

    // MARK: - 8-digit form (includes alpha)

    @Test func eightDigitIncludesAlphaChannel() {
        // 0x80 / 255 = 0.502...
        let c = TextStyle.RGBA(hex: "FF880080")
        #expect(c?.r == 1)
        #expect(abs((c?.a ?? -1) - 128.0/255.0) < 1e-9)
    }

    @Test func eightDigitFullAlphaMatchesSixDigit() {
        let six = TextStyle.RGBA(hex: "112233")
        let eight = TextStyle.RGBA(hex: "112233FF")
        #expect(six?.r == eight?.r)
        #expect(six?.g == eight?.g)
        #expect(six?.b == eight?.b)
        #expect(eight?.a == 1)
    }

    // MARK: - Formatting tolerance

    @Test func leadingHashIsOptional() {
        let withHash = TextStyle.RGBA(hex: "#FF0000")
        let without = TextStyle.RGBA(hex: "FF0000")
        #expect(withHash?.r == without?.r)
        #expect(withHash?.g == without?.g)
        #expect(withHash?.b == without?.b)
    }

    @Test func surroundingWhitespaceIsTrimmed() {
        let c = TextStyle.RGBA(hex: "   #00FF00  ")
        #expect(c?.r == 0)
        #expect(c?.g == 1)
        #expect(c?.b == 0)
    }

    // MARK: - Invalid inputs

    @Test func emptyStringReturnsNil() {
        #expect(TextStyle.RGBA(hex: "") == nil)
        #expect(TextStyle.RGBA(hex: "#") == nil)
    }

    @Test func wrongLengthReturnsNil() {
        // Only 3, 6, and 8 hex chars are accepted.
        #expect(TextStyle.RGBA(hex: "FF") == nil)
        #expect(TextStyle.RGBA(hex: "FFFF") == nil)
        #expect(TextStyle.RGBA(hex: "FFFFF") == nil)
        #expect(TextStyle.RGBA(hex: "FFFFFFF") == nil)
        #expect(TextStyle.RGBA(hex: "FFFFFFFFF") == nil)
    }

    @Test func nonHexCharactersReturnNil() {
        #expect(TextStyle.RGBA(hex: "GG0000") == nil)
        #expect(TextStyle.RGBA(hex: "ZZZ") == nil)
        #expect(TextStyle.RGBA(hex: "QWERTYUI") == nil)
    }
}

// MARK: - Adversarial

@Suite("RGBA hex — adversarial")
struct RGBAHexAdversarialTests {

    @Test func acceptsLowercaseAndMixedCase() {
        let upper = TextStyle.RGBA(hex: "FF8800")
        let lower = TextStyle.RGBA(hex: "ff8800")
        let mixed = TextStyle.RGBA(hex: "Ff8800")
        #expect(upper?.r == lower?.r && lower?.r == mixed?.r)
        #expect(upper?.g == lower?.g && lower?.g == mixed?.g)
    }

    @Test func rejectsZeroXPrefix() {
        // "0xFF8800" is 8 chars → 8-digit path. "0x" is not valid hex → nil.
        #expect(TextStyle.RGBA(hex: "0xFF8800") == nil)
    }

    @Test func rejectsEmbeddedWhitespace() {
        // Only leading/trailing whitespace is trimmed; internal whitespace breaks parsing.
        #expect(TextStyle.RGBA(hex: "FF 00 00") == nil)
    }
}
