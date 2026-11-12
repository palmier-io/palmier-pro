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
        VStack(alignment: .leading, spacing: AppTheme.Spacing.mdLg) {
            header
            if let error {
                statusBanner(text: error, tint: AppTheme.Status.errorColor, icon: "exclamationmark.triangle.fill")
            }
            if let report {
                boardContent(report)
            } else if planId.isEmpty {
                VStack {
                    ContentUnavailableView(L10n.string("No Storyboard Selected"), systemImage: "rectangle.stack",
                        description: Text(L10n.string("Create or select a plan with scenes, then prepare it for storyboard review.")))
                    .frame(maxWidth: .infinity)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.top, AppTheme.Spacing.xl)
            } else {
                VStack {
                    VStack(spacing: AppTheme.Spacing.sm) {
                        ProgressView()
                        Text(L10n.string("Loading storyboard…"))
                            .font(.system(size: AppTheme.FontSize.sm))
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                    }
                    .frame(maxWidth: .infinity)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, AppTheme.Spacing.xl)
            }
        }
        .padding(AppTheme.Spacing.lg)
        .frame(width: AppTheme.Storyboard.width, height: AppTheme.Storyboard.height)
        .background(AppTheme.Background.baseColor)
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

    private var header: some View {
        HStack(alignment: .center, spacing: AppTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text(L10n.string("Storyboard"))
                    .font(.system(size: AppTheme.FontSize.xl, weight: AppTheme.FontWeight.semibold))
                Text(L10n.string("Review scenes, sources, and approvals before production."))
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
            }
            Picker(L10n.string("Plan"), selection: $planId) {
                Text(L10n.string("Select a Plan")).tag("")
                ForEach(editor.editPlans.filter { $0.timelineId == editor.activeTimelineId }) { plan in
                    Text(verbatim: plan.name).tag(plan.id)
                }
            }
            .frame(maxWidth: 320)
            Spacer(minLength: AppTheme.Spacing.md)
            if let report {
                phaseBadge(report.phase)
                if operation != nil { ProgressView().controlSize(.small) }
            }
            Button(L10n.string("Close")) { dismiss() }.keyboardShortcut(.cancelAction)
        }
    }

    @ViewBuilder
    private func boardContent(_ report: StoryboardReport) -> some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.mdLg) {
            sidebar(report)
                .frame(width: AppTheme.Storyboard.sidebarWidth)
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                    overviewCards(report)
                    if report.cards.isEmpty {
                        emptyBoardState
                    } else if let card = report.cards.first(where: { $0.shot.id == sceneId }) {
                        StoryboardSceneView(card: card, asset: card.shot.mediaRef.flatMap { editor.mediaAssetsById[$0] },
                            visualAssets: editor.mediaAssets.filter { $0.type == .image || $0.type == .video },
                            canEdit: (editor.editPlan(id: report.planId)?.status == .proposed || editor.editPlan(id: report.planId)?.status == .approved)
                                && report.phase != .canceled && operation == nil,
                            canReview: report.phase == .awaitingStoryboardApproval && operation == nil) { review in
                            perform { try await editor.reviewStoryboardScene(planId: report.planId, revision: report.revision, review: review) }
                        } onRevise: { edits, visual in
                            perform { try await editor.reviseStoryboardScene(planId: report.planId, revision: report.revision,
                                sceneId: card.shot.id, beatEdits: edits, visual: visual) }
                        }.id(card.shot.id + card.selectionRevision + card.narration)
                    } else {
                        sectionCard {
                            ContentUnavailableView(L10n.string("Select a Scene"),
                                systemImage: "film.stack",
                                description: Text(L10n.string("Choose a scene from the list to review narration, visuals, and inspection.")))
                            .frame(maxWidth: .infinity, minHeight: 180)
                        }
                    }
                    blockersSection(report)
                    productionState(report)
                    commentsSection(report)
                }
                .padding(.bottom, AppTheme.Spacing.xs)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        actionBar(report)
    }

    private func sidebar(_ report: StoryboardReport) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack {
                Text(L10n.string("Scenes"))
                    .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                Spacer()
                Text(verbatim: "\(report.cards.count)")
                    .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
            }
            if report.cards.isEmpty {
                sectionCard {
                    Text(L10n.string("No scenes yet. Add shots to the plan, then prepare the storyboard."))
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                List(selection: $sceneId) {
                    ForEach(Array(report.cards.enumerated()), id: \.element.shot.id) { index, card in
                        sceneRow(index: index, card: card)
                            .tag(card.shot.id)
                            .listRowInsets(EdgeInsets(top: AppTheme.Spacing.xxs, leading: AppTheme.Spacing.xs, bottom: AppTheme.Spacing.xxs, trailing: AppTheme.Spacing.xs))
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .background(AppTheme.Background.clearColor)
            }
        }
    }

    private func sceneRow(index: Int, card: StoryboardCard) -> some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
            Text(verbatim: String(format: "%02d", index + 1))
                .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold, design: .monospaced))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .frame(width: 20, alignment: .leading)
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text(verbatim: card.shot.title)
                    .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                    .lineLimit(2)
                Text(verbatim: sceneTimingLabel(card))
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .lineLimit(1)
                HStack(spacing: AppTheme.Spacing.xxs) {
                    if card.review != nil {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(AppTheme.Status.successColor)
                            .font(.system(size: AppTheme.FontSize.xs))
                    }
                    if !card.blockers.isEmpty {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(AppTheme.Status.warningColor)
                            .font(.system(size: AppTheme.FontSize.xs))
                    }
                    if card.shot.mediaRef == nil {
                        Image(systemName: "photo")
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                            .font(.system(size: AppTheme.FontSize.xs))
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, AppTheme.Spacing.xxs)
    }

    @ViewBuilder
    private func overviewCards(_ report: StoryboardReport) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            narratorIntent(report.narrationIntent)
            StoryboardPreviewView(controller: preview) { preview.prepare(editor: editor, planId: planId) }
                .padding(AppTheme.Spacing.smMd)
                .background(AppTheme.Background.raisedColor)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                        .stroke(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.hairline)
                )
            if needsPreparation(report) {
                HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
                    Image(systemName: "sparkles.rectangle.stack")
                        .foregroundStyle(AppTheme.Accent.primary)
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                        Text(L10n.string("Storyboard needs preparation"))
                            .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                        Text(L10n.string("Prepare this storyboard to refresh the review run for the current plan revision."))
                            .font(.system(size: AppTheme.FontSize.xs))
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                    }
                    Spacer()
                    Button(L10n.string("Prepare")) { perform { try await editor.prepareStoryboard(planId: planId) } }
                        .buttonStyle(.borderedProminent)
                        .disabled(operation != nil)
                }
                .padding(AppTheme.Spacing.smMd)
                .background(AppTheme.Accent.primary.opacity(AppTheme.Opacity.subtle))
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous))
            }
        }
    }

    private var emptyBoardState: some View {
        sectionCard {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                Label(L10n.string("Storyboard not complete"), systemImage: "rectangle.stack.badge.plus")
                    .font(.system(size: AppTheme.FontSize.mdLg, weight: AppTheme.FontWeight.semibold))
                Text(L10n.string("This plan has no scenes yet. Add script beats and proposed shots, then prepare the storyboard so each scene can be reviewed."))
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                Text(L10n.string("Typical flow: create or update plan → prepare storyboard → review scenes → approve."))
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func blockersSection(_ report: StoryboardReport) -> some View {
        if !report.blockers.isEmpty || !report.approvalBlockers.isEmpty {
            sectionCard {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                    HStack {
                        Label(L10n.string("Blockers"), systemImage: "exclamationmark.triangle")
                            .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                        Spacer()
                        Text(verbatim: "\(report.blockers.count)")
                            .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                    }
                    if !report.approvalBlockers.isEmpty {
                        Text(L10n.string("Approval blockers"))
                            .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold))
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                        blockerList(report.approvalBlockers)
                    }
                    if !report.blockers.isEmpty {
                        Text(L10n.string("Production blockers"))
                            .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold))
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                        blockerList(report.blockers)
                    }
                }
            }
        }
    }

    private func blockerList(_ blockers: [String]) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            ForEach(Array(blockers.enumerated()), id: \.offset) { _, blocker in
                HStack(alignment: .top, spacing: AppTheme.Spacing.xs) {
                    Circle()
                        .fill(AppTheme.Status.warningColor)
                        .frame(width: 6, height: 6)
                        .padding(.top, 6)
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                        Text(verbatim: Self.blockerLabel(blocker))
                            .font(.system(size: AppTheme.FontSize.sm))
                            .foregroundStyle(AppTheme.Text.primaryColor)
                        if Self.blockerLabel(blocker) != blocker {
                            Text(verbatim: blocker)
                                .font(.system(size: AppTheme.FontSize.xxs, design: .monospaced))
                                .foregroundStyle(AppTheme.Text.tertiaryColor)
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder
    private func productionState(_ report: StoryboardReport) -> some View {
        let status = editor.productionStatus(planId: report.planId)
        sectionCard {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                HStack {
                    Text(L10n.string("Production"))
                        .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                    Spacer()
                    phaseBadge(status.phase)
                }
                if let reason = status.blockedReason, !reason.isEmpty {
                    statusBanner(text: reason, tint: AppTheme.Status.errorColor, icon: "xmark.octagon.fill")
                }
                if !status.steps.isEmpty {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                        ForEach(status.steps, id: \.key) { step in
                            HStack(spacing: AppTheme.Spacing.sm) {
                                Text(verbatim: Self.humanizeToken(step.kind.rawValue))
                                    .font(.system(size: AppTheme.FontSize.xs))
                                Spacer()
                                Text(verbatim: Self.humanizeToken(step.state.rawValue))
                                    .font(.system(size: AppTheme.FontSize.xs))
                                    .foregroundStyle(AppTheme.Text.secondaryColor)
                            }
                        }
                    }
                }
                if let receipt = status.terminalReceipt {
                    Divider()
                    Text(L10n.string("Delivered: \(receipt.deliveryVerified ? "yes" : "no")"))
                        .font(.system(size: AppTheme.FontSize.xs))
                    if let path = receipt.exportPath {
                        Text(verbatim: path).font(.system(size: AppTheme.FontSize.xs, design: .monospaced)).textSelection(.enabled)
                    }
                    ForEach(receipt.errors, id: \.self) { message in
                        Text(verbatim: message)
                            .font(.system(size: AppTheme.FontSize.xs))
                            .foregroundStyle(AppTheme.Status.errorColor)
                            .textSelection(.enabled)
                    }
                } else if status.steps.isEmpty && status.blockedReason == nil {
                    Text(L10n.string("No production steps yet. Prepare, inspect, and approve the storyboard, then produce."))
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                }
            }
        }
    }

    @ViewBuilder
    private func commentsSection(_ report: StoryboardReport) -> some View {
        sectionCard {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                Text(L10n.string("Approval comment"))
                    .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                Text(L10n.string("Included with storyboard approval for this revision."))
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                TextField(L10n.string("Grouped editorial comments"), text: $comment)
                    .textFieldStyle(.roundedBorder)
                    .disabled(operation != nil)
            }
        }
    }

    @ViewBuilder
    private func actionBar(_ report: StoryboardReport) -> some View {
        VStack(spacing: AppTheme.Spacing.sm) {
            Divider()
            VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
                HStack(alignment: .center, spacing: AppTheme.Spacing.md) {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                        Text(L10n.string("Storyboard actions"))
                            .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                        HStack(spacing: AppTheme.Spacing.xs) {
                            phaseBadge(report.phase)
                            if !report.canApprove, report.phase == .awaitingStoryboardApproval {
                                Text(L10n.string("Resolve approval blockers to approve"))
                                    .font(.system(size: AppTheme.FontSize.xs))
                                    .foregroundStyle(AppTheme.Text.secondaryColor)
                            }
                        }
                    }
                    Spacer()
                }

                HStack(alignment: .center, spacing: AppTheme.Spacing.smMd) {
                    GroupBox {
                        HStack(spacing: AppTheme.Spacing.xs) {
                            Button {
                                moveScene(report, offset: -1)
                            } label: {
                                Label(L10n.string("Move Earlier"), systemImage: "arrow.up")
                                    .labelStyle(.titleAndIcon)
                            }
                            .disabled(!canMoveScene(report, offset: -1) || operation != nil)

                            Button {
                                moveScene(report, offset: 1)
                            } label: {
                                Label(L10n.string("Move Later"), systemImage: "arrow.down")
                                    .labelStyle(.titleAndIcon)
                            }
                            .disabled(!canMoveScene(report, offset: 1) || operation != nil)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        Text(L10n.string("Scene order"))
                    }
                    .frame(maxWidth: .infinity)

                    GroupBox {
                        HStack(spacing: AppTheme.Spacing.xs) {
                            Button(L10n.string("Prepare")) { perform { try await editor.prepareStoryboard(planId: planId) } }
                                .disabled(operation != nil)
                            Button(L10n.string("Produce")) { produce(report) }
                                .disabled(report.phase != .approved && report.phase != .blocked || operation != nil)
                            Button(L10n.string("Cancel Production")) {
                                perform {
                                    var result = try await editor.storyboardReport(planId: planId)
                                    try editor.cancelProductionReview(planId: planId)
                                    result.phase = .canceled
                                    return result
                                }
                            }
                            .disabled(editor.editPlan(id: planId)?.productionRun == nil || operation != nil)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        Text(L10n.string("Production"))
                    }
                    .frame(maxWidth: .infinity)

                    GroupBox {
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                            Button {
                                perform { try await editor.approveStoryboard(planId: report.planId, revision: report.revision, comment: comment) }
                            } label: {
                                Label(L10n.string("Approve Storyboard"), systemImage: "checkmark.seal.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!report.canApprove || report.phase != .awaitingStoryboardApproval || operation != nil)

                            Text(Self.approvalHint(for: report))
                                .font(.system(size: AppTheme.FontSize.xs))
                                .foregroundStyle(AppTheme.Text.secondaryColor)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        Text(L10n.string("Approval"))
                    }
                    .frame(width: 280)
                }
            }
        }
    }

    @ViewBuilder
    private func narratorIntent(_ intent: NarrationIntent?) -> some View {
        sectionCard {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                Label(L10n.string("Narrator"), systemImage: "waveform")
                    .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                if let intent {
                    infoGrid(rows: narratorRows(intent))
                } else {
                    Text(L10n.string("No narration intent set. Choose language, placement, and an exact narrator before approval."))
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                }
            }
        }
    }

    private func narratorRows(_ intent: NarrationIntent) -> [(String, String)] {
        var rows: [(String, String)] = [
            (L10n.string("Language"), intent.language ?? "—"),
            (L10n.string("Start"), L10n.string("\(intent.startFrame) frames")),
        ]
        switch intent.narrator {
        case .localSpeech(let speech):
            rows.append((L10n.string("Narrator"), L10n.string("Local speech")))
            rows.append((L10n.string("Engine"), speech.engine.rawValue))
            rows.append((L10n.string("Voice"), speech.voiceIdentifier))
            rows.append((L10n.string("Rate / Pitch"), "\(speech.rate) / \(speech.pitch)"))
        case .recording(let recording):
            rows.append((L10n.string("Narrator"), L10n.string("Recording")))
            rows.append((L10n.string("Media"), recording.mediaRef))
            rows.append((L10n.string("Input"), recording.identity.inputId))
        case nil:
            rows.append((L10n.string("Narrator"), L10n.string("Not selected")))
        }
        return rows
    }

    private func infoGrid(rows: [(String, String)]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: AppTheme.Spacing.md, verticalSpacing: AppTheme.Spacing.xs) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow(alignment: .firstTextBaseline) {
                    Text(verbatim: row.0)
                        .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                        .frame(width: 96, alignment: .leading)
                    Text(verbatim: row.1)
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func sectionCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(AppTheme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.Background.surfaceColor)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg, style: .continuous)
                    .stroke(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.hairline)
            )
    }

    private func statusBanner(text: String, tint: Color, icon: String) -> some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            Text(verbatim: text)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.primaryColor)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(AppTheme.Spacing.smMd)
        .background(tint.opacity(AppTheme.Opacity.subtle))
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous))
    }

    private func phaseBadge(_ phase: ProductionRun.Phase) -> some View {
        Text(verbatim: Self.phaseLabel(phase))
            .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
            .padding(.horizontal, AppTheme.Spacing.smMd)
            .padding(.vertical, AppTheme.Spacing.xs)
            .background(Self.phaseColor(phase).opacity(AppTheme.Opacity.muted))
            .foregroundStyle(Self.phaseColor(phase))
            .clipShape(Capsule())
    }

    private func needsPreparation(_ report: StoryboardReport) -> Bool {
        guard let plan = editor.editPlan(id: report.planId) else { return true }
        guard let run = plan.productionRun else { return !report.cards.isEmpty }
        return run.storyboardRevision != report.revision || run.phase == .stale
    }

    private func sceneTimingLabel(_ card: StoryboardCard) -> String {
        if let range = card.resolvedRange {
            return L10n.string("Measured · \(range.count)f")
        }
        let frames = max(0, card.shot.endFrame - card.shot.startFrame)
        return L10n.string("Estimated · \(frames)f")
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

    fileprivate static func phaseLabel(_ phase: ProductionRun.Phase) -> String {
        switch phase {
        case .awaitingStoryboardApproval: L10n.string("Awaiting approval")
        case .approved: L10n.string("Approved")
        case .assembling: L10n.string("Assembling")
        case .finishing: L10n.string("Finishing")
        case .reviewing: L10n.string("Reviewing")
        case .exporting: L10n.string("Exporting")
        case .completed: L10n.string("Completed")
        case .blocked: L10n.string("Blocked")
        case .stale: L10n.string("Stale")
        case .canceled: L10n.string("Canceled")
        }
    }

    fileprivate static func phaseColor(_ phase: ProductionRun.Phase) -> Color {
        switch phase {
        case .awaitingStoryboardApproval: AppTheme.Accent.primary
        case .approved, .assembling, .finishing, .reviewing, .exporting, .completed: AppTheme.Status.successColor
        case .blocked, .stale: AppTheme.Status.warningColor
        case .canceled: AppTheme.Text.secondaryColor
        }
    }

    fileprivate static func humanizeToken(_ raw: String) -> String {
        raw.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: ":", with: " · ").capitalized
    }

    fileprivate static func blockerLabel(_ blocker: String) -> String {
        let parts = blocker.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let prefix = parts.count == 2 ? String(parts[0]) : ""
        let code = parts.count == 2 ? String(parts[1]) : blocker
        let label: String
        switch code {
        case "missing_selected_media": label = L10n.string("Missing selected visual")
        case "media_not_ready": label = L10n.string("Visual is not ready")
        case "unresolved_input_identity": label = L10n.string("Visual identity unresolved")
        case "unsupported_storyboard_visual": label = L10n.string("Unsupported visual type")
        case "unresolved_derivative_lineage": label = L10n.string("Derivative lineage unresolved")
        case "unresolved_rights": label = L10n.string("License or attribution missing")
        case "unpermitted_generated_footage": label = L10n.string("Generated footage not permitted")
        case "generation_unavailable": label = L10n.string("Generation unavailable")
        case "narration_timing_unresolved": label = L10n.string("Narration timing unresolved")
        case "missing_scene_narration_link": label = L10n.string("Scene not linked to narration")
        case "revealed_faces": label = L10n.string("Faces revealed in review")
        case "unresolved_rights_review": label = L10n.string("Rights not confirmed")
        case "suspected_duplicate": label = L10n.string("Suspected duplicate visual")
        case "incomplete_visual_inspection": label = L10n.string("Inspection incomplete")
        case "unresolved_face_and_similarity_inspection": label = L10n.string("Visual inspection required")
        case "repeated_visual_sources": label = L10n.string("Repeated visual sources")
        case "unresolved_visual_identity": label = L10n.string("Unresolved visual identity")
        case "empty_storyboard": label = L10n.string("Storyboard has no scenes")
        case "missing_script": label = L10n.string("Script beats missing")
        case "missing_narration_intent": label = L10n.string("Narration intent missing")
        case "unavailable_narrator_intent": label = L10n.string("Narrator unavailable")
        case "unavailable_recording_narrator": label = L10n.string("Recording narrator unavailable")
        default:
            if code.hasPrefix("unresolved_claim:") {
                label = L10n.string("Unresolved claim: \(code.dropFirst("unresolved_claim:".count))")
            } else {
                label = Self.humanizeToken(code)
            }
        }
        if !prefix.isEmpty, !code.hasPrefix("unresolved_claim:"), code != "empty_storyboard", code != "missing_script",
           code != "repeated_visual_sources", code != "unresolved_visual_identity", code != "missing_narration_intent",
           code != "unavailable_narrator_intent" {
            return "\(prefix): \(label)"
        }
        return label
    }

    fileprivate static func approvalHint(for report: StoryboardReport) -> String {
        if report.phase == .approved { return L10n.string("This storyboard revision is approved.") }
        if report.phase != .awaitingStoryboardApproval { return L10n.string("Prepare the storyboard to review and approve the current revision.") }
        if report.canApprove { return L10n.string("Approval records this exact storyboard revision.") }
        if report.approvalBlockers.isEmpty { return L10n.string("Review scenes and confirm inspections before approval.") }
        return L10n.string("Resolve \(report.approvalBlockers.count) approval blocker(s), then approve.")
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
            sceneHeader
            storyboardCard {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                    visualPreview
                    sceneMetaGrid
                    if let review = card.review {
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                            Label(L10n.string("Reviewed by \(review.reviewer)"), systemImage: "checkmark.seal")
                                .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                            Text(verbatim: review.evidence)
                                .font(.system(size: AppTheme.FontSize.sm))
                                .foregroundStyle(AppTheme.Text.secondaryColor)
                                .textSelection(.enabled)
                        }
                    }
                    if !card.blockers.isEmpty {
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                            Text(L10n.string("Scene blockers"))
                                .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                            ForEach(Array(card.blockers.enumerated()), id: \.offset) { _, blocker in
                                Text(verbatim: StoryboardView.blockerLabel(blocker))
                                    .font(.system(size: AppTheme.FontSize.sm))
                                    .foregroundStyle(AppTheme.Status.warningColor)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            storyboardCard {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                    Text(L10n.string("Narration"))
                        .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                    if card.narration.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(L10n.string("No narration linked to this scene."))
                            .font(.system(size: AppTheme.FontSize.sm))
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                    } else {
                        Text(verbatim: card.narration)
                            .font(.system(size: AppTheme.FontSize.sm))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !card.purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Divider()
                        Text(L10n.string("Purpose"))
                            .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                        Text(verbatim: card.purpose)
                            .font(.system(size: AppTheme.FontSize.sm))
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                            .textSelection(.enabled)
                    }
                }
            }
            StoryboardSceneEditor(card: card, visualAssets: visualAssets, canEdit: canEdit, onRevise: onRevise)
                .id(card.selectionRevision + card.narration)
            storyboardCard {
                DisclosureGroup(L10n.string("Record Visual Inspection")) {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                        Toggle(L10n.string("I inspected the complete selected source and intended framing."), isOn: $inspected)
                        Toggle(L10n.string("No person's face is revealed."), isOn: $faceless)
                        Toggle(L10n.string("License and attribution obligations are confirmed."), isOn: $rights)
                        Toggle(L10n.string("No unresolved suspected duplicate remains."), isOn: $distinct)
                        TextField(L10n.string("Reviewer"), text: $reviewer)
                            .textFieldStyle(.roundedBorder)
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                            Text(L10n.string("Evidence"))
                                .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                                .foregroundStyle(AppTheme.Text.secondaryColor)
                            TextEditor(text: $evidence).frame(height: AppTheme.Storyboard.evidenceHeight)
                                .accessibilityLabel(L10n.string("Inspection and rights evidence"))
                        }
                        Button(L10n.string("Record Inspection")) {
                            onReview(.init(sceneId: card.shot.id, selectionRevision: card.selectionRevision,
                                coverage: card.mediaType == .image ? .fullStill : .fullSpan, reviewer: reviewer,
                                evidence: evidence, facesRevealed: !faceless, rightsConfirmed: rights, suspectedDuplicate: !distinct))
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canReview || !inspected || reviewer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                   || evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(.top, AppTheme.Spacing.sm)
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

    private var sceneHeader: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
            Text(verbatim: card.shot.title)
                .font(.system(size: AppTheme.FontSize.title1, weight: AppTheme.FontWeight.semibold))
            HStack(spacing: AppTheme.Spacing.sm) {
                Label(timingSummary, systemImage: card.resolvedRange == nil ? "clock" : "waveform.path.ecg")
                if let span = sourceSpanSummary {
                    Label(span, systemImage: "scissors")
                }
                if let type = card.mediaType {
                    Label {
                        Text(verbatim: type.rawValue.capitalized)
                    } icon: {
                        Image(systemName: type == .video ? "video" : "photo")
                    }
                }
            }
            .font(.system(size: AppTheme.FontSize.xs))
            .foregroundStyle(AppTheme.Text.secondaryColor)
        }
    }

    private var visualPreview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                .fill(AppTheme.Background.raisedColor)
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .padding(AppTheme.Spacing.xs)
            } else {
                VStack(spacing: AppTheme.Spacing.sm) {
                    Image(systemName: card.shot.mediaRef == nil ? "photo.badge.plus" : "photo")
                        .font(.system(size: AppTheme.FontSize.title2))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                    Text(card.shot.mediaRef == nil ? L10n.string("No visual selected") : L10n.string("Preview unavailable"))
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: AppTheme.Storyboard.previewHeight)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                .stroke(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.hairline)
        )
        .overlay(alignment: .bottomLeading) {
            if let previewError {
                Text(verbatim: previewError)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .padding(AppTheme.Spacing.xs)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.xsSm, style: .continuous))
                    .padding(AppTheme.Spacing.sm)
            }
        }
    }

    private var sceneMetaGrid: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text(L10n.string("Source thumbnail only. Inspect the full still or continuously play the selected video span before recording review."))
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            Grid(alignment: .leading, horizontalSpacing: AppTheme.Spacing.md, verticalSpacing: AppTheme.Spacing.xs) {
                metaRow(L10n.string("Scene ID"), card.shot.id)
                if let mediaRef = card.shot.mediaRef { metaRow(L10n.string("Media"), mediaRef) }
                if let inputId = card.inputId { metaRow(L10n.string("Input ID"), inputId) }
                if let license = card.shot.license, !license.isEmpty { metaRow(L10n.string("License"), license) }
                if let attribution = card.shot.attribution, !attribution.isEmpty { metaRow(L10n.string("Attribution"), attribution) }
                if !card.claimIds.isEmpty { metaRow(L10n.string("Claims"), card.claimIds.joined(separator: ", ")) }
            }
        }
    }

    @ViewBuilder
    private func metaRow(_ label: String, _ value: String) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(verbatim: label)
                .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .frame(width: 90, alignment: .leading)
            Text(verbatim: value)
                .font(.system(size: AppTheme.FontSize.sm))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var timingSummary: String {
        if let range = card.resolvedRange {
            return L10n.string("Measured: \(range.count) frames")
        }
        return L10n.string("Estimated: \(max(0, card.shot.endFrame - card.shot.startFrame)) frames")
    }

    private var sourceSpanSummary: String? {
        guard let start = card.shot.sourceStartSeconds, let end = card.shot.sourceEndSeconds else { return nil }
        return String(format: "%.2f–%.2fs", start, end)
    }

    private func storyboardCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(AppTheme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.Background.surfaceColor)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg, style: .continuous)
                    .stroke(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.hairline)
            )
    }
}
