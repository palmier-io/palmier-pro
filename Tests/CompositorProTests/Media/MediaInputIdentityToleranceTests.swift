import Foundation
import Testing
@testable import CompositorPro

@Suite("MediaInputIdentity — attribute tolerance")
struct MediaInputIdentityToleranceTests {
    @Test func attributesWithoutOptionalFieldsStillIdentify() throws {
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        let attributes: [FileAttributeKey: Any] = [
            .type: FileAttributeType.typeRegular,
            .size: 1024,
            .modificationDate: modified,
        ]
        let first = try MediaInputIdentityService.revision(attributes: attributes)
        let second = try MediaInputIdentityService.revision(attributes: attributes)
        #expect(first == second)

        var changed = attributes
        changed[.size] = 2048
        let third = try MediaInputIdentityService.revision(attributes: changed)
        #expect(third != first)

        let nonRegular: [FileAttributeKey: Any] = [.type: FileAttributeType.typeDirectory, .size: 1024, .modificationDate: modified]
        #expect(throws: CocoaError.self) { try MediaInputIdentityService.revision(attributes: nonRegular) }
    }
}
