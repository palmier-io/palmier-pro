import Foundation

enum MotionEnergy: String, Codable, Sendable {
    case still
    case gentle
    case dynamic
    case whip

    var label: String {
        switch self {
        case .still: L10n.key("Still")
        case .gentle: L10n.key("Gentle")
        case .dynamic: L10n.key("Dynamic")
        case .whip: L10n.key("Whip")
        }
    }
}

struct TemplateSlot: Codable, Sendable, Equatable {
    var index: Int
    var motionEnergy: MotionEnergy
    var suggestedSpeed: Double?
}

extension Clip {
    static let templateSlotMediaRef = "template.slot"

    var isUnfilledTemplateSlot: Bool {
        templateSlot != nil && mediaRef == Self.templateSlotMediaRef
    }

    func templateSlotSummary(fps: Int) -> String {
        guard let slot = templateSlot else { return "" }
        let seconds = fps > 0 ? Double(durationFrames) / Double(fps) : 0
        return "Slot \(slot.index)  ·  \(String(format: "%.1fs", seconds))  ·  \(slot.motionEnergy.label)"
    }

    func templateSlateText(fps: Int) -> String {
        guard let slot = templateSlot else { return "" }
        var lines = [templateSlotSummary(fps: fps)]
        if let speed = slot.suggestedSpeed {
            lines.append("Suggested speed \(String(format: "%.1fx", speed))")
        }
        return lines.joined(separator: "\n")
    }
}
