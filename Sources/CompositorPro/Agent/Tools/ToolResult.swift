import Foundation
import MCP

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

extension ToolResult.Block: Codable {
    private enum Kind: String, Codable { case text, image }
    private enum CodingKeys: String, CodingKey { case kind, text, base64, mediaType }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .text:
            self = .text(try c.decode(String.self, forKey: .text))
        case .image:
            self = .image(
                base64: try c.decode(String.self, forKey: .base64),
                mediaType: try c.decode(String.self, forKey: .mediaType)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let s):
            try c.encode(Kind.text, forKey: .kind)
            try c.encode(s, forKey: .text)
        case .image(let base64, let mediaType):
            try c.encode(Kind.image, forKey: .kind)
            try c.encode(base64, forKey: .base64)
            try c.encode(mediaType, forKey: .mediaType)
        }
    }
}
