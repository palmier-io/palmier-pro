import Foundation

extension ToolExecutor {
    fileprivate struct ApplyEffectInput: DecodableToolArgs {
        struct Entry: Decodable {
            let type: String
            let params: [String: Double]?
            let enabled: Bool?
        }
        let clipIds: [String]
        let effects: [Entry]?
        let remove: [String]?
        static let allowedKeys: Set<String> = ["clipIds", "effects", "remove"]
    }

    /// Generic, registry-driven effect stack editing for non-color effects (apply_color owns color.*).
    func applyEffect(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let input: ApplyEffectInput = try decodeToolArgs(args, path: "apply_effect")
        guard !input.clipIds.isEmpty else { throw ToolError("clipIds is empty.") }
        let adds = input.effects ?? []
        let removes = input.remove ?? []
        guard !adds.isEmpty || !removes.isEmpty else {
            throw ToolError("Provide effects to add/update or remove types to delete.")
        }

        for e in adds {
            guard let d = EffectRegistry.descriptor(id: e.type) else {
                throw ToolError("Unknown effect '\(e.type)'. See the apply_effect description for available types.")
            }
            guard !e.type.hasPrefix("color.") else {
                throw ToolError("'\(e.type)' is a color grade — use apply_color, not apply_effect.")
            }
            if let params = e.params {
                let allowed = Set(d.params.map(\.key))
                let unknown = Set(params.keys).subtracting(allowed)
                guard unknown.isEmpty else {
                    throw ToolError("\(e.type): unknown param(s) '\(unknown.sorted().joined(separator: "', '"))'. Allowed: \(allowed.sorted().joined(separator: ", ")).")
                }
            }
        }
        for id in input.clipIds {
            guard let clip = editor.clipFor(id: id) else { throw ToolError("Clip not found: \(id)") }
            guard clip.mediaType == .video || clip.mediaType == .image else {
                throw ToolError("Clip \(id) is a \(clip.mediaType.rawValue) clip; apply_effect needs a video or image clip.")
            }
        }

        let snapshot = timelineSnapshot(editor)
        let actionName = input.clipIds.count == 1 ? "Apply Effect (Agent)" : "Apply Effect ×\(input.clipIds.count) (Agent)"
        try withUndoGroup(editor, actionName: actionName) {
            editor.mutateClips(ids: Set(input.clipIds), actionName: actionName) { clip in
                var stack = clip.effects ?? []
                for type in removes { stack.removeAll { $0.type == type } }
                for e in adds {
                    guard let d = EffectRegistry.descriptor(id: e.type) else { continue }
                    var effect = stack.first { $0.type == e.type } ?? d.makeEffect()
                    if let enabled = e.enabled { effect.enabled = enabled }
                    if let params = e.params {
                        for spec in d.params where params[spec.key] != nil {
                            let v = min(spec.range.upperBound, max(spec.range.lowerBound, params[spec.key]!))
                            effect.params[spec.key] = EffectParam(value: (v * 1000).rounded() / 1000)
                        }
                    }
                    stack.removeAll { $0.type == e.type }
                    stack.insert(effect, at: EffectRegistry.insertIndex(stack, for: e.type))
                }
                clip.effects = stack.isEmpty ? nil : stack
            }
        }
        return mutationResult(editor, since: snapshot, touched: input.clipIds)
    }
}
