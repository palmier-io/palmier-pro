import Foundation
import SwiftUI

enum PreviewTab: Identifiable, Equatable {
    case timeline
    case mediaAsset(id: String, name: String, type: ClipType)

    var id: String {
        switch self {
        case .timeline: "__timeline__"
        case .mediaAsset(let id, _, _): Self.mediaAssetTabId(for: id)
        }
    }

    static func mediaAssetTabId(for assetId: String) -> String {
        "media_\(assetId)"
    }

    var displayName: String {
        switch self {
        case .timeline: "Timeline"
        case .mediaAsset(_, let name, _): name
        }
    }

    var isCloseable: Bool { self != .timeline }

    var clipType: ClipType? {
        switch self {
        case .timeline: nil
        case .mediaAsset(_, _, let type): type
        }
    }

    var tintColor: Color {
        switch self {
        case .timeline: Color.accentColor.opacity(0.15)
        case .mediaAsset(_, _, let type): Color(type.themeColor).opacity(0.25)
        }
    }

    var underlineColor: Color {
        switch self {
        case .timeline: Color.accentColor
        case .mediaAsset(_, _, let type): Color(type.themeColor)
        }
    }
}
