import AppKit
import Foundation
import SwiftUI

extension ToolExecutor {
    private struct OpenDesignSpecWizardInput: DecodableToolArgs {
        let action: String
        let specMarkdown: String?
        let filePath: String?

        static let allowedKeys: Set<String> = ["action", "specMarkdown", "filePath"]
    }

    /// Opens the frame.md / design.md visual wizard for brand styling.
    /// Actions: "open", "apply", "export", "import"
    func openDesignSpecWizard(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try Task.checkCancellation()
        let input: OpenDesignSpecWizardInput = try decodeToolArgs(args, path: "open_design_spec_wizard")

        switch input.action.lowercased() {
        case "open":
            let wizard = DesignSpecWizard(editor: editor)
            await MainActor.run {
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 700, height: 800),
                    styleMask: [.titled, .closable, .miniaturizable, .resizable],
                    backing: .buffered,
                    defer: false
                )
                window.title = "Design Spec Wizard"
                window.contentView = NSHostingView(rootView: DesignSpecWizardView(wizard: wizard))
                window.center()
                window.makeKeyAndOrderFront(nil)
            }
            return .ok(Self.jsonString(["status": "ok", "message": "Design Spec Wizard opened"]) ?? "{}")

        case "apply":
            guard let markdown = input.specMarkdown else {
                throw ToolError("specMarkdown required for apply action")
            }
            let spec = try DesignSpecParser.parse(markdown: markdown)
            let receipt = try editor.applyDesignSpec(spec)
            return .ok(Self.jsonString([
                "status": "ok",
                "applied": [
                    "retypedClips": receipt.retypedClipsCount,
                    "gradedClips": receipt.gradedClipsCount,
                    "updatedPreferences": receipt.updatedPreferences
                ],
                "message": "Design spec applied"
            ]) ?? "{}")

        case "export":
            let spec = editor.exportCurrentDesignSpec()
            let markdown = DesignSpecParser.exportMarkdown(spec: spec)
            if let path = input.filePath {
                try markdown.write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
            }
            return .ok(Self.jsonString([
                "status": "ok",
                "markdown": markdown,
                "message": "Design spec exported"
            ]) ?? "{}")

        case "import":
            guard let path = input.filePath else {
                throw ToolError("filePath required for import action")
            }
            let markdown = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
            let spec = try DesignSpecParser.parse(markdown: markdown)
            let receipt = try editor.applyDesignSpec(spec)
            return .ok(Self.jsonString([
                "status": "ok",
                "message": "Design spec imported and applied"
            ]) ?? "{}")

        default:
            throw ToolError("action must be one of: open, apply, export, import")
        }
    }
}