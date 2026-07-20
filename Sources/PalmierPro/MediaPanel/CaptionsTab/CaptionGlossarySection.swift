// Glossary review list for the caption tab: merged terms (canonical + variants + scope/confidence),
// per-term remove/promote, and an inline add row — all routed through EditorViewModel's shared
// glossary helpers so behavior matches the glossary_* tools. refs feature/glossary

import SwiftUI

struct CaptionGlossarySection: View {
    @Environment(EditorViewModel.self) private var editor

    // Loaded on first expand and after mutations — never per render. The store is file-backed, so
    // external MCP writes since the last load stay invisible until the manual Refresh re-reads.
    @State private var terms: [MergedGlossaryTerm] = []
    @State private var loaded = false
    @State private var expanded = false
    @State private var showAddRow = false
    @State private var newCanonical = ""
    @State private var newVariants = ""
    @State private var errorMessage: String?
    @State private var warningMessage: String?

    var body: some View {
        EditorPanelGroup("Glossary", isExpanded: $expanded, headerAccessory: countAccessory) {
            controlsRow
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Status.errorColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let warningMessage {
                Text(warningMessage)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Status.warningColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if showAddRow { addRow }
            ForEach(terms, id: \.term.canonical) { merged in
                termRow(merged)
            }
        }
        .onChange(of: expanded) { _, isExpanded in
            if isExpanded && !loaded { reload() }
        }
    }

    @ViewBuilder
    private func countAccessory() -> some View {
        if loaded {
            Text(terms.count == 1 ? "1 term" : "\(terms.count) terms")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.mutedColor)
        }
    }

    private var controlsRow: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Button("Add term") { showAddRow.toggle() }
                .buttonStyle(.capsule())
                .focusable(false)
                .help("Add a canonical spelling and its mis-heard variants to this project's glossary.")
            Spacer(minLength: AppTheme.Spacing.sm)
            Button {
                reload()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("Reload terms. Picks up glossary edits made outside the app.")
        }
    }

    private var addRow: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            TextField("Canonical spelling", text: $newCanonical)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .font(.system(size: AppTheme.FontSize.sm))
            HStack(spacing: AppTheme.Spacing.sm) {
                TextField("Variants (comma-separated)", text: $newVariants)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .font(.system(size: AppTheme.FontSize.sm))
                Button("Add") { addTerm() }
                    .buttonStyle(.capsule(.prominent))
                    .focusable(false)
                    .disabled(newCanonical.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.vertical, AppTheme.Spacing.xxs)
    }

    private func termRow(_ merged: MergedGlossaryTerm) -> some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text(merged.term.canonical)
                    .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .lineLimit(1)
                if !merged.term.variants.isEmpty {
                    Text("← " + merged.term.variants.joined(separator: ", "))
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("\(merged.scope.rawValue) · \(merged.term.confidence.rawValue)")
                    .font(.system(size: AppTheme.FontSize.xxs))
                    .foregroundStyle(merged.term.confidence == .inferred
                        ? AppTheme.Status.warningColor : AppTheme.Text.mutedColor)
            }
            Spacer(minLength: AppTheme.Spacing.sm)
            if merged.term.confidence == .inferred {
                Button("Confirm") { confirm(merged) }
                    .buttonStyle(.capsule(.prominent))
                    .focusable(false)
                    .help("Mark this suggestion correct. It starts applying to transcripts and captions immediately.")
            }
            if isPromotable(merged) {
                Button("Promote") { promote(merged) }
                    .buttonStyle(.capsule())
                    .focusable(false)
                    .help("Move this term up to \(promotionTarget(merged.scope)?.rawValue ?? "") so other projects reuse it.")
            }
            Button {
                remove(merged)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("Remove this term. Captions revert on next resync.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Actions

    private func reload() {
        terms = GlossaryStore.load(projectURL: editor.projectURL).merged()
        loaded = true
    }

    private func addTerm() {
        let canonical = newCanonical.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !canonical.isEmpty else { return }
        let variants = newVariants
            .split(whereSeparator: { $0 == "," || $0 == "，" || $0 == "、" || $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }
        let term = GlossaryTerm(canonical: canonical, variants: variants, provenance: "user", confidence: .declared)
        do {
            let result = try editor.glossaryAddTerm(term, scope: .project)
            newCanonical = ""
            newVariants = ""
            showAddRow = false
            errorMessage = nil
            warningMessage = result.warnings.isEmpty ? nil : result.warnings.joined(separator: " ")
            reload()
        } catch let error {
            errorMessage = error.localizedDescription
        }
    }

    private func remove(_ merged: MergedGlossaryTerm) {
        do {
            _ = try editor.glossaryRemoveTerm(canonical: merged.term.canonical, scope: merged.scope)
            errorMessage = nil
            reload()
        } catch let error {
            errorMessage = error.localizedDescription
        }
    }

    private func confirm(_ merged: MergedGlossaryTerm) {
        var term = merged.term
        term.confidence = .declared
        term.provenance = "user"
        do {
            let result = try editor.glossaryAddTerm(term, scope: merged.scope)
            errorMessage = nil
            warningMessage = result.warnings.isEmpty ? nil : result.warnings.joined(separator: " ")
            reload()
        } catch let error {
            errorMessage = error.localizedDescription
        }
    }

    private func promote(_ merged: MergedGlossaryTerm) {
        guard let to = promotionTarget(merged.scope) else { return }
        do {
            _ = try editor.glossaryPromoteTerms(canonical: merged.term.canonical, from: merged.scope, to: to)
            errorMessage = nil
            reload()
        } catch let error {
            errorMessage = error.localizedDescription
        }
    }

    /// The next scope up the sharing hierarchy, or nil at the top (global).
    private func promotionTarget(_ scope: GlossaryScope) -> GlossaryScope? {
        switch scope {
        case .project: .library
        case .library: .global
        case .global: nil
        }
    }

    /// Any term below the top scope can be promoted upward (matches glossary_promote's default plan).
    private func isPromotable(_ merged: MergedGlossaryTerm) -> Bool {
        promotionTarget(merged.scope) != nil
    }
}
