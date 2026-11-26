import AppKit
import Testing
@testable import CompositorPro

@Suite("Native document activity scheduling", .serialized)
@MainActor
struct VideoProjectActivityTests {
    @Test(.timeLimit(.minutes(1)))
    func nativeSaveQueuesBehindPendingActivityAndPersistsWithoutBlockingTheMainActor() async throws {
        try await withPackageTestFixture { fixture in
            let document = ActivitySaveProject(registry: fixture.registry)
            document.fileURL = fixture.package
            document.fileType = VideoProject.typeIdentifier
            try await savePackageTestDocument(document)
            let entered = PackageTestSignal()
            let saved = PackageTestSignal()
            var finishActivity: (() -> Void)?
            var didSave = false
            document.performActivity(withSynchronousWaiting: false) { finish in
                finishActivity = finish
                entered.signal()
            }
            await entered.wait()
            document.editorViewModel.timeline.name = "Agent edit awaiting save"
            document.updateChangeCount(.changeDone)
            document.onSave = { error in
                #expect(error == nil)
                didSave = true
                saved.signal()
            }

            document.save(nil)
            #expect(!didSave)
            finishActivity?()
            await saved.wait()
            let persisted = try await fixture.readPackage()
            #expect(persisted.projectFile.timelines.first?.name == "Agent edit awaiting save")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func pendingActivityDoesNotBlockTheMainActorAndKeepsCallbackOrder() async {
        let document = VideoProject()
        let firstEntered = PackageTestSignal()
        let secondEntered = PackageTestSignal()
        let thirdEntered = PackageTestSignal()
        var finishFirst: (() -> Void)?
        var events: [String] = []
        document.performActivity(withSynchronousWaiting: false) { finish in
            events.append("first")
            finishFirst = finish
            firstEntered.signal()
        }
        await firstEntered.wait()

        document.performActivity(withSynchronousWaiting: true) { finish in
            events.append("second")
            finish()
            secondEntered.signal()
        }
        events.append("returned")
        #expect(events == ["first", "returned"])
        finishFirst?()
        await secondEntered.wait()

        document.performActivity(withSynchronousWaiting: true) { finish in
            events.append("third")
            finish()
            thirdEntered.signal()
        }
        await thirdEntered.wait()
        #expect(events == ["first", "returned", "second", "third"])
    }
}

private final class ActivitySaveProject: VideoProject {
    var onSave: ((Error?) -> Void)?

    override func save(to url: URL, ofType typeName: String, for operation: NSDocument.SaveOperationType,
                       completionHandler: @escaping (Error?) -> Void) {
        let onSave = onSave
        super.save(to: url, ofType: typeName, for: operation) { error in
            completionHandler(error)
            onSave?(error)
        }
    }
}
