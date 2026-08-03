import Foundation
import Testing
@testable import PalmierPro

@Suite struct IEEE754Binary16Tests {
    @Test(arguments: [
        (UInt16(0x0000), Float(0)),
        (UInt16(0x8000), -Float(0)),
        (UInt16(0x3c00), Float(1)),
        (UInt16(0xc000), Float(-2)),
        (UInt16(0x7bff), Float(65_504)),
        (UInt16(0x0001), Float(bitPattern: 0x3380_0000)),
    ])
    func decodesKnownValues(bits: UInt16, expected: Float) {
        #expect(IEEE754Binary16.float(fromBits: bits).bitPattern == expected.bitPattern)
    }

    @Test(arguments: [Float(0), -Float(0), 1, -2, 0.5, 65_504, 0.000_061_035_156_25])
    func roundTripsRepresentableValues(value: Float) {
        let bits = IEEE754Binary16.bits(from: value)
        #expect(IEEE754Binary16.float(fromBits: bits).bitPattern == value.bitPattern)
    }

    @Test func preservesInfinityAndNaN() {
        #expect(IEEE754Binary16.bits(from: .infinity) == 0x7c00)
        #expect(IEEE754Binary16.bits(from: -.infinity) == 0xfc00)
        #expect(IEEE754Binary16.float(fromBits: 0x7e00).isNaN)
    }

    @Test(arguments: [
        (Float(1.000_488_281_25), UInt16(0x3c00)),
        (Float(1.001_464_843_75), UInt16(0x3c02)),
        (Float(bitPattern: 0x3300_0000), UInt16(0x0000)),
        (Float(bitPattern: 0x33c0_0000), UInt16(0x0002)),
    ])
    func roundsMidpointsToEven(value: Float, expected: UInt16) {
        #expect(IEEE754Binary16.bits(from: value) == expected)
    }
}
