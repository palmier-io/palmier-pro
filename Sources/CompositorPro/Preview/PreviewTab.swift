import Foundation
import SwiftUI

enum PreviewTab: Identifiable, Equatable {
    case timeline
    case mediaAsset(id: String, name: String, type: ClipType)
    case hyperframesBlock(id: String, name: String, html: String, durationFrames: Int)

    var id: String {
        switch self {
        case .timeline: "__timeline__"
        case .mediaAsset(let id, _, _): Self.mediaAssetTabId(for: id)
        case .hyperframesBlock(let id, _, _, _): Self.hyperframesBlockTabId(for: id)
        }
    }

    static func mediaAssetTabId(for assetId: String) -> String {
        "media_\(assetId)"
    }

    static func hyperframesBlockTabId(for blockId: String) -> String {
        "hyperframes_\(blockId)"
    }

    var displayName: String {
        switch self {
        case .timeline: "Timeline"
        case .mediaAsset(_, let name, _): name
        case .hyperframesBlock(_, let name, _, _): name
        }
    }

    var isCloseable: Bool { self != .timeline }

    var clipType: ClipType? {
        switch self {
        case .timeline: nil
        case .mediaAsset(_, _, let type): type
        case .hyperframesBlock: .video
        }
    }

    var underlineColor: Color {
        switch self {
        case .timeline: AppTheme.Accent.primary
        case .mediaAsset(_, _, let type): Color(type.themeColor)
        case .hyperframesBlock: AppTheme.Accent.spotlight
        }
    }

    var isHyperframes: Bool {
        if case .hyperframesBlock = self { return true }
        return false
    }

    var hyperframesHTML: String? {
        guard case let .hyperframesBlock(_, _, html, _) = self else { return nil }
        return html
    }

    var hyperframesBlockId: String? {
        guard case let .hyperframesBlock(id, _, _, _) = self else { return nil }
        return id
    }
}
