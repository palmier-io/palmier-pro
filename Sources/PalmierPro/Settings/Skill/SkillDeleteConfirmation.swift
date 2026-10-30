import SwiftUI

extension Skill {
    var displayPath: String {
        path.deletingLastPathComponent().path
            .replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}

private struct SkillDeleteConfirmation: ViewModifier {
    @Binding var skill: Skill?
    let onDelete: (Skill) -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(
            title,
            isPresented: Binding(
                get: { skill != nil },
                set: { if !$0 { skill = nil } }
            ),
            titleVisibility: .visible,
            presenting: skill
        ) { skill in
            Button(L10n.string("Delete \u{201C}\(skill.name)\u{201D}"), role: .destructive) {
                onDelete(skill)
            }
            Button(L10n.string("Keep Skill"), role: .cancel) {}
        } message: { skill in
            Text(L10n.string("This permanently removes \(skill.displayPath)."))
        }
    }

    private var title: String {
        guard let skill else { return L10n.string("Delete skill?") }
        return L10n.string("Delete \u{201C}\(skill.name)\u{201D}?")
    }
}

extension View {
    func skillDeleteConfirmation(
        skill: Binding<Skill?>,
        onDelete: @escaping (Skill) -> Void
    ) -> some View {
        modifier(SkillDeleteConfirmation(skill: skill, onDelete: onDelete))
    }
}
