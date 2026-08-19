import Foundation
import Testing
@testable import PalmierPro

struct BackendGenerationJobTests {
    @Test func decodesOptionalRefundedCredits() throws {
        let withRefund = try JSONDecoder().decode(BackendGenerationJob.self, from: Data("""
        {"_id":"j1","status":"failed","errorMessage":"err","costCredits":27,"refundedCredits":27,"completedAt":1}
        """.utf8))
        let withoutRefund = try JSONDecoder().decode(BackendGenerationJob.self, from: Data("""
        {"_id":"j2","status":"succeeded","resultUrls":["https://example.com/out.mp4"],"costCredits":10,"completedAt":1}
        """.utf8))
        #expect(withRefund.refundedCredits == 27)
        #expect(withoutRefund.refundedCredits == nil)
    }
}
