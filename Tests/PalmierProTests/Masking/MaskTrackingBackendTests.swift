import Foundation
import Testing
@testable import PalmierPro

@Suite("Mask tracking backend")
struct MaskTrackingBackendTests {
    @Test func encodesTextSeed() throws {
        let value = try encodedObject(BackendMaskSeed.text(prompt: "dog"))
        #expect(value["type"] as? String == "text")
        #expect(value["prompt"] as? String == "dog")
    }

    @Test func encodesPointSeedUsingConvexNumbers() throws {
        let value = try encodedObject(BackendMaskSeed.point(x: 320, y: 180, frameIndex: 12))
        #expect(value["type"] as? String == "point")
        #expect((value["x"] as? NSNumber)?.doubleValue == 320)
        #expect((value["y"] as? NSNumber)?.doubleValue == 180)
        #expect((value["frameIndex"] as? NSNumber)?.doubleValue == 12)
    }

    private func encodedObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
