import Foundation
import Testing
@testable import PalmierPro

struct ProjectActivityTests {
    @Test func decodesSignedActivityEntries() throws {
        let json = """
        [
          { "id": "failed-1", "kind": "failed", "model": "test", "credits": 27, "createdAt": 1700000000000 },
          { "id": "refund-1", "kind": "refund", "model": "test", "credits": 27, "createdAt": 1700000001000 }
        ]
        """

        let entries = try JSONDecoder().decode(
            [BackendProjectActivityEntry].self,
            from: Data(json.utf8)
        )

        #expect(entries.map(\.kind) == [.failed, .refund])
        #expect(entries.map(\.creditImpact) == [27, -27])
        #expect(entries.first?.createdDate == Date(timeIntervalSince1970: 1_700_000_000))
    }
}
