import Foundation
import MCP
import Testing
@testable import CompositorPro

enum SourceClaimLedgerFixtures {
    static func ledger() -> SourceClaimLedger {
        SourceClaimLedger(
            sources: [.init(sourceId: "report", title: "Example report", url: "https://example.invalid/report",
                            author: "Example institute", publicationDate: "2026-01-01", accessedDate: "2026-11-08")],
            claims: [.init(claimId: "share", kind: .quantity, statement: "Example share is 40 percent.", value: 40, unit: "percent",
                           evidence: [.init(sourceId: "report", passage: "The measured share is 40 percent.")], status: .reviewed)]
        )
    }
}

struct SourceClaimLedgerTests {
    @Test func missingEvidenceCanBeRecordedButNotReviewed() throws {
        var ledger = SourceClaimLedgerFixtures.ledger()
        ledger.claims[0].evidence = []
        ledger.claims[0].status = .unresolved
        #expect(try ledger.validated().claims[0].evidence.isEmpty)
        ledger.claims[0].status = .reviewed
        #expect(throws: EditPlanValidationError.self) { try ledger.validated() }
    }

    @Test(arguments: ["duplicate source", "duplicate claim", "unknown source", "duplicate evidence", "empty passage", "missing unit", "non-finite", "non-quantity value", "invalid date", "ambiguous source"])
    func invalidLedgersAreRejected(caseName: String) {
        var ledger = SourceClaimLedgerFixtures.ledger()
        switch caseName {
        case "duplicate source": ledger.sources.append(ledger.sources[0])
        case "duplicate claim": ledger.claims.append(ledger.claims[0])
        case "unknown source": ledger.claims[0].evidence[0].sourceId = "missing"
        case "duplicate evidence": ledger.claims[0].evidence.append(ledger.claims[0].evidence[0])
        case "empty passage": ledger.claims[0].evidence[0].passage = " "
        case "missing unit": ledger.claims[0].unit = nil
        case "non-finite": ledger.claims[0].value = .nan
        case "non-quantity value": ledger.claims[0].kind = .location
        case "invalid date": ledger.sources[0].accessedDate = "2026-02-30"
        default: ledger.sources[0].documentReference = "document"
        }
        #expect(throws: EditPlanValidationError.self) { try ledger.validated() }
    }

    @Test(arguments: ["2024-02-29", "2000-02-29", "2026-11-08"])
    func validCalendarDatesAreAccepted(date: String) throws {
        var ledger = SourceClaimLedgerFixtures.ledger()
        ledger.sources[0].accessedDate = date
        #expect(try ledger.validated().sources[0].accessedDate == date)
    }

    @Test(arguments: ["source", "passage", "value", "unit", "statement"])
    func changedSupportingContentInvalidatesReviewedClaim(change: String) throws {
        let original = SourceClaimLedgerFixtures.ledger()
        var changed = original
        switch change {
        case "source": changed.sources[0].url = "https://example.invalid/revised"
        case "passage": changed.claims[0].evidence[0].passage = "Revised passage."
        case "value": changed.claims[0].value = 41
        case "unit": changed.claims[0].unit = "fraction"
        default: changed.claims[0].statement = "Revised statement."
        }
        #expect(try changed.validated(previous: original).claims[0].status == .unresolved)
        #expect(try original.validated(previous: original).claims[0].status == .reviewed)
    }

    @Test func malformedPersistedLedgerIsRefusedWithoutArithmeticTrap() async throws {
        var ledger = SourceClaimLedgerFixtures.ledger()
        ledger.sources.append(ledger.sources[0])
        #expect(throws: EditPlanValidationError.self) { try SourceClaimLedgerFixtures.ledger().validated(previous: ledger) }
        let plan = EditPlan(name: "Malformed ledger", timelineId: "timeline", fps: 30, width: 1920, height: 1080, sourceLedger: ledger)
        let result = try await Task.detached {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-malformed-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            try EditPlanStore.writePackageFile(try EditPlanStore.encode([plan]), to: directory, sourceURL: nil)
            return try EditPlanStore.readPackageFile(at: directory)
        }.value
        #expect(result.unreadable)
        #expect(result.plans.isEmpty)
    }
}

@Suite("Source claim ledger MCP")
@MainActor
struct SourceClaimLedgerMCPTests {
    @Test func changedResearchReportsDependentsBlocksAssemblyAndUndoes() async throws {
        let harness = ToolHarness()
        let asset = harness.addAsset(id: "ledger-asset", duration: 8)
        let server = Server(name: "source-ledger", version: "1", capabilities: .init(tools: .init(listChanged: false)))
        await MCPService.registerTools(on: server, executor: harness.executor)
        let transports = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "source-ledger-test", version: "1")
        try await server.start(transport: transports.server)
        do {
            _ = try await client.connect(transport: transports.client)
            let (tools, _) = try await client.listTools()
            let tool = try #require(tools.first { $0.name == "plan_edit" })
            #expect(tool.inputSchema.objectValue?["properties"]?.objectValue?["plan"]?.objectValue?["properties"]?.objectValue?["sourceLedger"] != nil)
            let original = SourceClaimLedgerFixtures.ledger()
            let created = try await client.callTool(name: "plan_edit", arguments: [
                "action": .string("create"), "plan": .object([
                    "planId": .string("ledger-plan"), "name": .string("Sourced explainer"), "sourceLedger": try Value(original),
                    "sections": .array([.object([
                        "sectionId": .string("ledger-section"), "title": .string("Comparison"), "startFrame": .int(0), "endFrame": .int(120),
                        "claimIds": .array([.string("share")]),
                    ])]),
                    "shots": .array([.object([
                        "shotId": .string("ledger-shot"), "title": .string("Share chart"), "startFrame": .int(0), "endFrame": .int(120),
                        "mediaRef": .string(asset.id), "claimIds": .array([.string("share")]),
                    ])]),
                ]),
            ])
            let createdText = try text(created.content)
            #expect(created.isError != true, "\(createdText)")
            _ = try await client.callTool(name: "plan_edit", arguments: ["action": .string("status"), "planId": .string("ledger-plan"), "status": .string("approved")])
            let before = try #require(harness.editor.editPlan(id: "ledger-plan"))
            let timeline = harness.editor.timeline
            let undo = UndoManager()
            harness.editor.undo.attach(undo)
            let ready = try await client.callTool(name: "apply_plan", arguments: ["planId": .string("ledger-plan")])
            #expect(try json(ready.content)["ready"] as? Bool == true)

            var changed = original
            changed.claims[0].value = 41
            changed.claims[0].statement = "Example share is 41 percent."
            changed.claims[0].evidence[0].passage = "The revised measured share is 41 percent."
            changed.sources[0].url = "https://example.invalid/revised-report"
            let updated = try await client.callTool(name: "plan_edit", arguments: [
                "action": .string("update"), "planId": .string("ledger-plan"), "patch": .object(["sourceLedger": try Value(changed)]),
            ])
            let receipt = try json(updated.content)
            #expect(updated.isError != true)
            #expect(receipt["invalidatedClaimIds"] as? [String] == ["share"])
            #expect((receipt["claimDependents"] as? [String: [String]])?["shotIds"] == ["ledger-shot"])
            #expect((receipt["claimDependents"] as? [String: [String]])?["sectionIds"] == ["ledger-section"])
            let current = try #require(harness.editor.editPlan(id: "ledger-plan"))
            #expect(current.sourceLedger?.claims[0].value == 41)
            #expect(current.sourceLedger?.claims[0].status == .unresolved)
            #expect(current.sourceLedgerRevision != before.sourceLedgerRevision)
            let repeatedContent = try await client.callTool(name: "plan_edit", arguments: [
                "action": .string("update"), "planId": .string("ledger-plan"), "patch": .object(["sourceLedger": try Value(changed)]),
            ])
            #expect(try json(repeatedContent.content)["noOp"] as? Bool == true)
            #expect(harness.editor.editPlan(id: "ledger-plan") == current)
            let snapshot = current
            let saved = try await Task.detached { try EditPlanStore.decode(EditPlanStore.encode([snapshot])) }.value
            #expect(saved.first?.sourceLedger == current.sourceLedger)
            #expect(saved.first?.claimDependents(["share"]) == current.claimDependents(["share"]))
            let blocked = try await client.callTool(name: "apply_plan", arguments: ["planId": .string("ledger-plan"), "commit": .bool(true)])
            #expect(blocked.isError == true)
            #expect(harness.editor.timeline == timeline)

            var invalid = changed
            invalid.claims[0].evidence[0].sourceId = "missing"
            let refused = try await client.callTool(name: "plan_edit", arguments: [
                "action": .string("update"), "planId": .string("ledger-plan"), "patch": .object(["sourceLedger": try Value(invalid)]),
            ])
            #expect(refused.isError == true)
            #expect(harness.editor.editPlan(id: "ledger-plan") == current)
            let staleReview = try await client.callTool(name: "plan_edit", arguments: [
                "action": .string("review_claims"), "planId": .string("ledger-plan"),
                "claimIds": .array([.string("share")]), "ledgerRevision": .string(try #require(before.sourceLedgerRevision)),
            ])
            #expect(staleReview.isError == true)
            #expect(harness.editor.editPlan(id: "ledger-plan") == current)
            let reviewArguments: [String: Value] = [
                "action": .string("review_claims"), "planId": .string("ledger-plan"),
                "claimIds": .array([.string("share")]), "ledgerRevision": .string(try #require(current.sourceLedgerRevision)),
            ]
            let reviewed = try await client.callTool(name: "plan_edit", arguments: reviewArguments)
            #expect(reviewed.isError != true)
            #expect(harness.editor.editPlan(id: "ledger-plan")?.sourceLedger?.claims[0].status == .reviewed)
            let repeatedReview = try await client.callTool(name: "plan_edit", arguments: reviewArguments)
            #expect(try json(repeatedReview.content)["noOp"] as? Bool == true)
            _ = try await client.callTool(name: "undo")
            #expect(harness.editor.editPlan(id: "ledger-plan") == current)
            let undone = try await client.callTool(name: "undo")
            #expect(undone.isError != true)
            #expect(harness.editor.editPlan(id: "ledger-plan") == before)
            #expect(!undo.canUndo)
            #expect(harness.editor.timeline == timeline)
            for ids in [[], ["missing"], ["share", "share"]] {
                let invalidReview = try await client.callTool(name: "plan_edit", arguments: [
                    "action": .string("review_claims"), "planId": .string("ledger-plan"),
                    "claimIds": .array(ids.map(Value.string)), "ledgerRevision": .string(try #require(before.sourceLedgerRevision)),
                ])
                #expect(invalidReview.isError == true)
                #expect(harness.editor.editPlan(id: "ledger-plan") == before)
                #expect(!undo.canUndo)
            }
        } catch {
            await server.stop()
            await client.disconnect()
            throw error
        }
        await server.stop()
        await client.disconnect()
    }

    private func text(_ blocks: [Tool.Content]) throws -> String {
        for block in blocks { if case .text(let text, _, _) = block { return text } }
        throw CocoaError(.coderReadCorrupt)
    }

    private func json(_ blocks: [Tool.Content]) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(text(blocks).utf8)) as? [String: Any])
    }
}
