import SwiftUI

struct StoryboardView: View {
    @Environment(EditorViewModel.self) private var editor
    @Environment(\.dismiss) private var dismiss
    @State private var planId = ""
    @State private var sceneId: String?
    @State private var report: StoryboardReport?
    @State private var error: String?
    @State private var comment = ""
    @State private var operation: Task<Void, Never>?
    @State private var operationGeneration = UUID()
    @State private var preview = StoryboardPreviewController()

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack {
                Text(L10n.string("Storyboard"))
                    .font(.system(size: AppTheme.FontSize.lg, weight: AppTheme.FontWeight.semibold))
                Picker(L10n.string("Plan"), selection: $planId) {
                    Text(L10n.string("Select a Plan")).tag("")
                    ForEach(editor.editPlans.filter { $0.timelineId == editor.activeTimelineId }) { plan in
                        Text(verbatim: plan.name).tag(plan.id)
                    }
                }
                Spacer()
                Button(L10n.string("Close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let error { Text(verbatim: error).foregroundStyle(AppTheme.Status.errorColor).textSelection(.enabled) }
            if let report {
                narratorIntent(report.narrationIntent)
                StoryboardPreviewView(controller: preview) { preview.prepare(editor: editor, planId: planId) }
                HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
                    List(selection: $sceneId) {
                        ForEach(report.cards, id: \.shot.id) { card in
                            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                                Text(verbatim: card.shot.title)
                                Text(card.resolvedRange.map { L10n.string("Measured: \($0.count) frames") }
                                     ?? L10n.string("Estimated: \(card.shot.endFrame - card.shot.startFrame) frames"))
                                    .font(.system(size: AppTheme.FontSize.xs))
                                    .foregroundStyle(AppTheme.Text.secondaryColor)
                            }.tag(card.shot.id)
                        }
                    }.frame(width: AppTheme.Storyboard.sidebarWidth)
                    ScrollView {
                        if let card = report.cards.first(where: { $0.shot.id == sceneId }) {
                            StoryboardSceneView(card: card, asset: card.shot.mediaRef.flatMap { editor.mediaAssetsById[$0] },
                                visualAssets: editor.mediaAssets.filter { $0.type == .image || $0.type == .video },
                                canEdit: (editor.editPlan(id: report.planId)?.status == .proposed || editor.editPlan(id: report.planId)?.status == .approved)
                                    && report.phase != .canceled && operation == nil,
                                canReview: report.phase == .awaitingStoryboardApproval && operation == nil) { review in
                                perform { try await editor.reviewStoryboardScene(planId: report.planId, revision: report.revision, review: review) }
                            } onRevise: { edits, visual in
                                perform { try await editor.reviseStoryboardScene(planId: report.planId, revision: report.revision,
                                    sceneId: card.shot.id, beatEdits: edits, visual: visual) }
                            }.id(card.shot.id + card.selectionRevision)
                        } else { Text(L10n.string("Select a scene to review its narration and visual.")) }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                DisclosureGroup(L10n.string("Production Blockers (\(report.blockers.count))")) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                            ForEach(Array(report.blockers.enumerated()), id: \.offset) { _, blocker in
                                Text(verbatim: blocker).textSelection(.enabled)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: AppTheme.Storyboard.evidenceHeight)
                }
                productionState(report)
                TextField(L10n.string("Grouped editorial comments"), text: $comment)
                HStack {
                    Button(L10n.string("Move Scene Earlier")) { moveScene(report, offset: -1) }
                        .disabled(!canMoveScene(report, offset: -1))
                    Button(L10n.string("Move Scene Later")) { moveScene(report, offset: 1) }
                        .disabled(!canMoveScene(report, offset: 1))
                    Button(L10n.string("Prepare Storyboard")) { perform { try await editor.prepareStoryboard(planId: planId) } }
                    Button(L10n.string("Produce")) { produce(report) }
                        .disabled(report.phase != .approved && report.phase != .blocked)
                    Button(L10n.string("Cancel Production")) {
                        perform {
                            var result = try await editor.storyboardReport(planId: planId)
                            try editor.cancelProductionReview(planId: planId)
                            result.phase = .canceled
                            return result
                        }
                    }.disabled(editor.editPlan(id: planId)?.productionRun == nil)
                    Spacer()
                    Text(verbatim: report.phase.rawValue).foregroundStyle(AppTheme.Text.secondaryColor)
                    Button(L10n.string("Approve Storyboard")) {
                        perform { try await editor.approveStoryboard(planId: report.planId, revision: report.revision, comment: comment) }
                    }.disabled(!report.canApprove || report.phase != .awaitingStoryboardApproval)
                }.disabled(operation != nil)
            } else {
                ContentUnavailableView(L10n.string("No Storyboard Selected"), systemImage: "rectangle.stack",
                    description: Text(L10n.string("Create a plan with script beats and proposed visuals, then select it here.")))
            }
        }
        .padding(AppTheme.Spacing.lg)
        .frame(width: AppTheme.Storyboard.width, height: AppTheme.Storyboard.height)
        .background(AppTheme.Background.surfaceColor)
        .task(id: editor.storyboardPreviewContext(planId: planId)) {
            preview.invalidate()
            report = nil
            error = nil
            guard !planId.isEmpty else { return }
            do {
                report = try await editor.storyboardReport(planId: planId)
                comment = editor.editPlan(id: planId)?.productionRun?.comment ?? ""
                if sceneId == nil || report?.cards.contains(where: { $0.shot.id == sceneId }) != true {
                    sceneId = report?.cards.first?.shot.id
                }
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
        .onChange(of: planId) { cancelOperation() }
        .onDisappear {
            cancelOperation()
            preview.invalidate()
        }
    }

    @ViewBuilder
    private func narratorIntent(_ intent: NarrationIntent?) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
            Text(L10n.string("Narrator Intent"))
                .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
            if let intent {
                Text(L10n.string("Language: \(intent.language ?? "—") · Start: \(intent.startFrame) frames"))
                switch intent.narrator {
                case .localSpeech(let speech):
                    Text(L10n.string("Engine: \(speech.engine.rawValue) · Voice: \(speech.voiceIdentifier) · Rate: \(speech.rate) · Pitch: \(speech.pitch)"))
                    Text(L10n.string("Pinned speech generation is not available. Production remains blocked."))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                case .recording(let recording):
                    Text(L10n.string("Recording: \(recording.mediaRef)"))
                    Text(verbatim: recording.identity.inputId).textSelection(.enabled)
                case nil:
                    Text(L10n.string("Choose an exact narrator before approving this storyboard."))
                }
            } else {
                Text(L10n.string("Choose narration language, placement, and narrator before approval."))
            }
        }
        .font(.system(size: AppTheme.FontSize.xs))
    }

    @ViewBuilder
    private func productionState(_ report: StoryboardReport) -> some View {
        let status = editor.productionStatus(planId: report.planId)
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
            Text(L10n.string("Production Run"))
                .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
            Text(verbatim: status.phase.rawValue)
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            if let reason = status.blockedReason {
                Text(verbatim: reason)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Status.errorColor)
                    .textSelection(.enabled)
            }
            ForEach(status.steps, id: \.key) { step in
                Text(verbatim: "\(step.kind.rawValue): \(step.state.rawValue)")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
            }
            if let receipt = status.terminalReceipt {
                Text(L10n.string("Delivered: \(receipt.deliveryVerified ? "yes" : "no")"))
                    .font(.system(size: AppTheme.FontSize.xs))
                if let path = receipt.exportPath {
                    Text(verbatim: path).font(.system(size: AppTheme.FontSize.xs)).textSelection(.enabled)
                }
                ForEach(receipt.errors, id: \.self) { message in
                    Text(verbatim: message)
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Status.errorColor)
                }
            }
        }
        .font(.system(size: AppTheme.FontSize.xs))
    }

    private func produce(_ report: StoryboardReport) {
        operation?.cancel()
        let generation = UUID()
        operationGeneration = generation
        error = nil
        operation = Task {
            defer { if operationGeneration == generation { operation = nil } }
            do {
                _ = try await editor.productionCoordinator.produce(planId: report.planId)
                if operationGeneration == generation { self.report = try await editor.storyboardReport(planId: report.planId) }
            } catch is CancellationError {} catch {
                if operationGeneration == generation { self.error = error.localizedDescription }
            }
        }
    }

    private func perform(_ action: @escaping @MainActor () async throws -> StoryboardReport) {
        operation?.cancel()
        let generation = UUID()
        operationGeneration = generation
        error = nil
        operation = Task {
            defer { if operationGeneration == generation { operation = nil } }
            do {
                let result = try await action()
                if operationGeneration == generation { report = result }
            } catch is CancellationError {} catch {
                if operationGeneration == generation { self.error = error.localizedDescription }
            }
        }
    }

    private func cancelOperation() {
        operationGeneration = UUID()
        operation?.cancel()
        operation = nil
    }

    private func canMoveScene(_ report: StoryboardReport, offset: Int) -> Bool {
        guard report.phase != .canceled, let plan = editor.editPlan(id: report.planId),
              plan.status == .proposed || plan.status == .approved,
              let index = report.cards.firstIndex(where: { $0.shot.id == sceneId }) else { return false }
        return report.cards.indices.contains(index + offset)
    }

    private func moveScene(_ report: StoryboardReport, offset: Int) {
        guard canMoveScene(report, offset: offset), let index = report.cards.firstIndex(where: { $0.shot.id == sceneId }) else { return }
        var ids = report.cards.map(\.shot.id)
        ids.swapAt(index, index + offset)
        perform { try await editor.reorderStoryboard(planId: report.planId, revision: report.revision, sceneIds: ids) }
    }
}

private struct StoryboardSceneView: View {
    let card: StoryboardCard
    let asset: MediaAsset?
    let visualAssets: [MediaAsset]
    let canEdit: Bool
    let canReview: Bool
    let onReview: (ProductionRun.VisualReview) -> Void
    let onRevise: ([StoryboardBeatEdit], StoryboardVisualEdit?) -> Void
    @State private var image: CGImage?
    @State private var previewError: String?
    @State private var inspected = false
    @State private var faceless = false
    @State private var rights = false
    @State private var distinct = false
    @State private var reviewer = ""
    @State private var evidence = ""

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Text(verbatim: card.shot.title).font(.system(size: AppTheme.FontSize.lg, weight: AppTheme.FontWeight.semibold))
            ZStack {
                Rectangle().fill(AppTheme.Background.placeholderColor)
                if let image { Image(decorative: image, scale: 1).resizable().scaledToFit() }
                else { Text(L10n.string("Preview Unavailable")) }
            }.frame(height: AppTheme.Storyboard.previewHeight)
            Text(L10n.string("Source thumbnail only. Inspect the full still or continuously play the selected video span before recording review."))
                .font(.system(size: AppTheme.FontSize.xs)).foregroundStyle(AppTheme.Text.secondaryColor)
            if let previewError { Text(verbatim: previewError) }
            Text(verbatim: card.narration).textSelection(.enabled)
            Text(verbatim: card.purpose).foregroundStyle(AppTheme.Text.secondaryColor)
            if let inputId = card.inputId { Text(verbatim: inputId).textSelection(.enabled) }
            if let start = card.shot.sourceStartSeconds, let end = card.shot.sourceEndSeconds {
                Text(L10n.string("Selected source: \(start)–\(end) seconds"))
            }
            if let license = card.shot.license { Text(verbatim: license).textSelection(.enabled) }
            if let attribution = card.shot.attribution { Text(verbatim: attribution).textSelection(.enabled) }
            if !card.claimIds.isEmpty { Text(verbatim: card.claimIds.joined(separator: ", ")).textSelection(.enabled) }
            if let review = card.review {
                Text(L10n.string("Reviewed by \(review.reviewer)"))
                Text(verbatim: review.evidence).textSelection(.enabled)
            }
            StoryboardSceneEditor(card: card, visualAssets: visualAssets, canEdit: canEdit, onRevise: onRevise)
                .id(card.selectionRevision + card.narration)
            DisclosureGroup(L10n.string("Record Visual Inspection")) {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                    Toggle(L10n.string("I inspected the complete selected source and intended framing."), isOn: $inspected)
                    Toggle(L10n.string("No person's face is revealed."), isOn: $faceless)
                    Toggle(L10n.string("License and attribution obligations are confirmed."), isOn: $rights)
                    Toggle(L10n.string("No unresolved suspected duplicate remains."), isOn: $distinct)
                    TextField(L10n.string("Reviewer"), text: $reviewer)
                    TextEditor(text: $evidence).frame(height: AppTheme.Storyboard.evidenceHeight)
                        .accessibilityLabel(L10n.string("Inspection and rights evidence"))
                    Button(L10n.string("Record Inspection")) {
                        onReview(.init(sceneId: card.shot.id, selectionRevision: card.selectionRevision,
                            coverage: card.mediaType == .image ? .fullStill : .fullSpan, reviewer: reviewer,
                            evidence: evidence, facesRevealed: !faceless, rightsConfirmed: rights, suspectedDuplicate: !distinct))
                    }.disabled(!canReview || !inspected || reviewer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                               || evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .task(id: card.selectionRevision) {
            image = nil
            previewError = nil
            guard let asset else { return }
            let url = asset.url
            do {
                let loaded = try await StoryboardThumbnailService.load(url: url, type: asset.type, sourceSeconds: card.shot.sourceStartSeconds ?? 0)
                try Task.checkCancellation()
                guard asset.url == url, asset.inputIdentity?.inputId == card.inputId else { return }
                image = loaded
            }
            catch is CancellationError {} catch { previewError = error.localizedDescription }
        }
    }
}
