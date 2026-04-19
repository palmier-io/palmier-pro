import Foundation
import MCP

/// `content` ordering is preserved end-to-end (`read_media` emits
/// `[.image, .text]` and the adapter must pass both through in that order).
struct ToolResult: Sendable {
    enum Block: Sendable {
        case text(String)
        case image(base64: String, mediaType: String)
    }

    let content: [Block]
    let isError: Bool

    static func ok(_ text: String) -> ToolResult {
        ToolResult(content: [.text(text)], isError: false)
    }

    static func error(_ message: String) -> ToolResult {
        ToolResult(content: [.text(message)], isError: true)
    }
}

extension ToolResult {
    func toMCPResult() -> CallTool.Result {
        let mapped: [Tool.Content] = content.map { block in
            switch block {
            case .text(let s):
                return .text(text: s, annotations: nil, _meta: nil)
            case .image(let base64, let mime):
                return .image(data: base64, mimeType: mime, annotations: nil, _meta: nil)
            }
        }
        return .init(content: mapped, isError: isError ? true : nil)
    }
}
