import Foundation

enum IEEE754Binary16 {
    static func float(fromBits bits: UInt16) -> Float {
        let sign = UInt32(bits & 0x8000) << 16
        let exponent = Int((bits >> 10) & 0x1f)
        var significand = UInt32(bits & 0x03ff)

        if exponent == 0 {
            guard significand != 0 else { return Float(bitPattern: sign) }
            var unbiasedExponent = -14
            while significand & 0x0400 == 0 {
                significand <<= 1
                unbiasedExponent -= 1
            }
            significand &= 0x03ff
            return Float(bitPattern: sign | UInt32(unbiasedExponent + 127) << 23 | significand << 13)
        }

        if exponent == 0x1f {
            return Float(bitPattern: sign | 0x7f80_0000 | significand << 13)
        }

        return Float(bitPattern: sign | UInt32(exponent + 112) << 23 | significand << 13)
    }

    static func bits(from value: Float) -> UInt16 {
        let source = value.bitPattern
        let sign = UInt16((source >> 16) & 0x8000)
        let sourceExponent = Int((source >> 23) & 0xff)
        let sourceSignificand = source & 0x007f_ffff

        if sourceExponent == 0xff {
            guard sourceSignificand != 0 else { return sign | 0x7c00 }
            let payload = UInt16(sourceSignificand >> 13)
            return sign | 0x7c00 | payload | (payload == 0 ? 1 : 0)
        }

        let unbiasedExponent = sourceExponent - 127
        if unbiasedExponent < -25 { return sign }

        if unbiasedExponent < -14 {
            let significand = sourceSignificand | 0x0080_0000
            let shift = UInt32(-unbiasedExponent - 1)
            var rounded = significand >> shift
            let remainderMask = (UInt32(1) << shift) - 1
            let remainder = significand & remainderMask
            let midpoint = UInt32(1) << (shift - 1)
            if remainder > midpoint || (remainder == midpoint && rounded & 1 == 1) {
                rounded += 1
            }
            return sign | UInt16(rounded)
        }

        var exponent = unbiasedExponent + 15
        guard exponent < 0x1f else { return sign | 0x7c00 }

        var significand = sourceSignificand >> 13
        let remainder = sourceSignificand & 0x1fff
        if remainder > 0x1000 || (remainder == 0x1000 && significand & 1 == 1) {
            significand += 1
            if significand == 0x0400 {
                significand = 0
                exponent += 1
                if exponent == 0x1f { return sign | 0x7c00 }
            }
        }

        return sign | UInt16(exponent << 10) | UInt16(significand)
    }
}
