import Foundation

func roundJSONFloatingPointNumbers(_ value: Any, toPlaces places: Int) -> Any {
    if let dict = value as? [String: Any] {
        return dict.mapValues { roundJSONFloatingPointNumbers($0, toPlaces: places) }
    }
    if let array = value as? [Any] {
        return array.map { roundJSONFloatingPointNumbers($0, toPlaces: places) }
    }
    if let number = value as? NSNumber, !isBooleanNumber(number) {
        let type = String(cString: number.objCType)
        guard type == "d" || type == "f" else { return number }
        let double = number.doubleValue
        return double.isFinite ? double.jsonRounded(toPlaces: places) : NSNull()
    }
    return value
}

private func isBooleanNumber(_ number: NSNumber) -> Bool {
    CFGetTypeID(number) == CFBooleanGetTypeID()
}

extension Double {
    func jsonRounded(toPlaces places: Int) -> NSDecimalNumber {
        NSDecimalNumber(value: self).rounding(accordingToBehavior:
            NSDecimalNumberHandler(roundingMode: .plain, scale: Int16(places),
                raiseOnExactness: false, raiseOnOverflow: false,
                raiseOnUnderflow: false, raiseOnDivideByZero: false))
    }
}
