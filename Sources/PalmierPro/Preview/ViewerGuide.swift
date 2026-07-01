import Foundation

enum ViewerGuide: String, CaseIterable, Identifiable {
    case actionSafe
    case titleSafe
    case center
    case scope
    case wide
    case square
    case portrait

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .actionSafe: return "Action Safe"
        case .titleSafe:  return "Title Safe"
        case .center:     return "Center"
        case .scope:      return "Scope (2.39:1)"
        case .wide:       return "Wide (1.85:1)"
        case .square:     return "Square (1:1)"
        case .portrait:   return "Portrait (9:16)"
        }
    }

    // Inset fraction per side for safe-zone guides (SMPTE ST 2046-1 / ITU-R BT.1848-1).
    // Action Safe = 93% of frame → 3.5% inset each side.
    // Title Safe  = 90% of frame → 5% inset each side.
    var safeZoneInset: CGFloat? {
        switch self {
        case .actionSafe: return 0.035
        case .titleSafe:  return 0.05
        default:          return nil
        }
    }

    var formatAspect: CGFloat? {
        switch self {
        case .scope:    return 2.39
        case .wide:     return 1.85
        case .square:   return 1.0
        case .portrait: return 9.0 / 16.0
        default:        return nil
        }
    }
}
