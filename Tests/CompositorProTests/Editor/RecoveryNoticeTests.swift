import Foundation
import Testing
@testable import CompositorPro

@Suite("Recovery notices")
struct RecoveryNoticeTests {
    @Test func missingMediaProducesARelinkNotice() {
        let notices = RecoveryNoticeBuilder.notices(missingMediaCount: 3, plansUnreadable: false, projectFolderMissing: false,
            )
        #expect(notices.count == 1)
        #expect(notices.first?.kind == .missingMedia)
        #expect(notices.first?.message.contains("3 clips") == true)
    }

    @Test func singularWordingForOneClip() {
        let notices = RecoveryNoticeBuilder.notices(missingMediaCount: 1, plansUnreadable: false, projectFolderMissing: false,
            )
        #expect(notices.first?.message.contains("1 clip is missing") == true)
    }

    @Test func folderAndPlansProblemsStack() {
        let notices = RecoveryNoticeBuilder.notices(missingMediaCount: 1, plansUnreadable: true, projectFolderMissing: true,
            )
        #expect(notices.map(\.kind) == [.projectFolderMissing, .missingMedia, .unreadablePlans])
    }

    @Test func healthyProjectHasNoNotices() {
        #expect(RecoveryNoticeBuilder.notices(missingMediaCount: 0, plansUnreadable: false, projectFolderMissing: false,
            ).isEmpty)
    }

    @Test func folderProbeDetectsMissingPackages() async throws {
        let present = FileManager.default.temporaryDirectory
        #expect(await RecoveryNoticeBuilder.folderMissing(present) == false)
        #expect(await RecoveryNoticeBuilder.folderMissing(present.appendingPathComponent("nope-\(UUID().uuidString)")) == true)
        #expect(await RecoveryNoticeBuilder.folderMissing(nil) == false)
    }
}
