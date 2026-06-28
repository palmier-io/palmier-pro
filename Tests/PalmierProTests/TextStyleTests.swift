import XCTest
import Foundation
@testable import PalmierPro

final class TextStyleTests: XCTestCase {
    
    func testFontWeightDefaultsAndRoundTrips() throws {
        var style = TextStyle()
        XCTAssertEqual(style.fontWeight, 400)
        
        style.fontWeight = 700
        let data = try JSONEncoder().encode(style)
        let decoded = try JSONDecoder().decode(TextStyle.self, from: data)
        XCTAssertEqual(decoded.fontWeight, 700)
    }
    
}