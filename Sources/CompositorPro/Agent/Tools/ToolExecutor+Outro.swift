import Foundation

extension ToolExecutor {
    private struct AddOutroInput: DecodableToolArgs {
        struct Credit: Decodable {
            let name: String?
            let role: String?
        }
        struct Subscribe: Decodable {
            let channel: String?
            let handle: String?
            let kind: String?
        }

        let credits: [Credit]?
        let subscribe: Subscribe?
        let durationFrames: Int?
        let background: String?
        let platform: String?
        static let allowedKeys: Set<String> = [
            "credits", "subscribe", "durationFrames", "platform",
        ]
    }

    /// Builds the end sequence in one undo step.
    func addOutro(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let input: AddOutroInput = try decodeToolArgs(args, path: "add_outro")

        var credits: OutroPlan.Credits?
        if let raw = input.credits, !raw.isEmpty {
            let lines = raw.compactMap { item -> OutroPlan.Credits.Line? in
                guard let name = item.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !name.isEmpty
                else { return nil }
                let role = item.role?.trimmingCharacters(in: .whitespacesAndNewlines)
                return .init(name: name, role: (role?.isEmpty ?? true) ? nil : role)
            }
            if lines.isEmpty {
                throw ToolError(
                    "add_outro received credits entries with no usable text. Each entry needs a "
                        + "name, for example {\"name\": \"A. Editor\", \"role\": \"Editor\"}."
                )
            }
            credits = OutroPlan.Credits(lines: lines)
        }

        var card: OutroPlan.Subscribe?
        if let raw = input.subscribe {
            guard let channel = raw.channel?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !channel.isEmpty
            else {
                throw ToolError("add_outro's subscribe object needs a channel name.")
            }
            let kind: OutroPlan.Subscribe.Kind
            switch raw.kind {
            case "thanks": kind = .thanks
            case "subscribe", nil: kind = .subscribe
            case let other?: throw ToolError(
                "add_outro's subscribe kind must be 'subscribe' or 'thanks'; got '\(other)'."
            )
            }
            let handle = raw.handle?.trimmingCharacters(in: .whitespacesAndNewlines)
            card = OutroPlan.Subscribe(
                channel: channel, handle: (handle?.isEmpty ?? true) ? nil : handle, kind: kind
            )
        }

        guard credits != nil || card != nil else {
            throw ToolError(
                "add_outro needs credits, a subscribe card, or both. With neither there is nothing "
                    + "to add, so nothing was changed."
            )
        }

        let platform: OutroPlan.Platform
        switch input.platform {
        case "youtube": platform = .youtube
        case "generic", nil: platform = .generic
        case let other?: throw ToolError(
            "add_outro's platform must be 'generic' or 'youtube'; got '\(other)'."
        )
        }

        let receipt: EditorViewModel.OutroReceipt
        do {
            receipt = try editor.addOutro(
                durationFrames: input.durationFrames ?? 300,
                credits: credits,
                subscribe: card,
                platform: platform
            )
        } catch let error as OutroPlan.PlanError {
            throw ToolError(error.description)
        }

        var notes = [
            "The outro occupies frames \(receipt.startFrame)-\(receipt.endFrame) and did not "
                + "extend past the existing edit.",
        ]
        if receipt.hasSubscribeCard {
            notes.append(
                "This draws the subscribe card only. Clickable subscribe and video elements are "
                    + "attached at upload in YouTube Studio."
            )
        }
        return .ok(Self.jsonString([
            "startFrame": receipt.startFrame,
            "endFrame": receipt.endFrame,
            "durationFrames": receipt.durationFrames,
            "platform": platform.rawValue,
            "creditLineCount": receipt.creditLineCount,
            "hasSubscribeCard": receipt.hasSubscribeCard,
            "trackIds": receipt.trackIds,
            "changed": true,
            "undoSteps": 1,
            "notes": notes,
        ]) ?? "{}")
    }
}