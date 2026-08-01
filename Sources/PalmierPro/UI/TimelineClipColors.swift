import AppKit
import Foundation
import Observation
import SwiftUI

enum TimelineClipColor: String, CaseIterable, Identifiable, Sendable {
    case video
    case audio
    case image
    case text
    case animation
    case sequence

    var id: String { rawValue }

    var label: String {
        switch self {
        case .video: L10n.key("Video")
        case .audio: L10n.key("Audio")
        case .image: L10n.key("Image")
        case .text: L10n.key("Text")
        case .animation: L10n.key("Animation")
        case .sequence: L10n.key("Sequence")
        }
    }

    var defaultColor: NSColor {
        switch self {
        case .video: NSColor(red: 0x1D/255.0, green: 0x58/255.0, blue: 0x78/255.0, alpha: 1)
        case .audio: NSColor(red: 0x2E/255.0, green: 0x77/255.0, blue: 0x65/255.0, alpha: 1)
        case .image: NSColor(red: 0x71/255.0, green: 0x54/255.0, blue: 0x86/255.0, alpha: 1)
        case .text: NSColor(red: 0x71/255.0, green: 0x54/255.0, blue: 0x86/255.0, alpha: 1)
        case .animation: NSColor(red: 0xA0/255.0, green: 0x78/255.0, blue: 0x22/255.0, alpha: 1)
        case .sequence: NSColor(red: 0xB9/255.0, green: 0xB2/255.0, blue: 0x9A/255.0, alpha: 1)
        }
    }

    var defaultsKey: String { "timelineClipColor.\(rawValue)" }

    func storedColor(in defaults: UserDefaults) -> NSColor {
        guard let components = defaults.array(forKey: defaultsKey) as? [NSNumber],
              components.count == 3 else { return defaultColor }
        let values = components.map(\.doubleValue)
        guard values.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return defaultColor }
        return NSColor(
            srgbRed: CGFloat(values[0]),
            green: CGFloat(values[1]),
            blue: CGFloat(values[2]),
            alpha: 1
        )
    }
}

final class TimelineClipColorPalette: @unchecked Sendable {
    static let shared = TimelineClipColorPalette()

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var colors: [TimelineClipColor: NSColor]
    private var overrides: Set<TimelineClipColor>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        colors = Dictionary(uniqueKeysWithValues: TimelineClipColor.allCases.map {
            ($0, $0.storedColor(in: defaults))
        })
        overrides = Set(TimelineClipColor.allCases.filter {
            defaults.array(forKey: $0.defaultsKey) != nil
        })
    }

    func color(for kind: TimelineClipColor) -> NSColor {
        lock.lock()
        defer { lock.unlock() }
        return colors[kind] ?? kind.defaultColor
    }

    func set(_ color: NSColor, for kind: TimelineClipColor) {
        guard let color = color.usingColorSpace(.sRGB) else { return }
        let components = [
            Double(color.redComponent),
            Double(color.greenComponent),
            Double(color.blueComponent),
        ]

        lock.lock()
        colors[kind] = NSColor(
            srgbRed: CGFloat(components[0]),
            green: CGFloat(components[1]),
            blue: CGFloat(components[2]),
            alpha: 1
        )
        overrides.insert(kind)
        lock.unlock()

        defaults.set(components, forKey: kind.defaultsKey)
    }

    func resetAll() {
        lock.lock()
        colors = Dictionary(uniqueKeysWithValues: TimelineClipColor.allCases.map {
            ($0, $0.defaultColor)
        })
        overrides.removeAll()
        lock.unlock()

        for kind in TimelineClipColor.allCases {
            defaults.removeObject(forKey: kind.defaultsKey)
        }
    }

    var hasOverrides: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !overrides.isEmpty
    }
}

@MainActor @Observable
final class TimelineClipColorStore {
    static let shared = TimelineClipColorStore()

    private(set) var revision = 0
    private let palette: TimelineClipColorPalette

    init(palette: TimelineClipColorPalette = .shared) {
        self.palette = palette
    }

    func color(for kind: TimelineClipColor) -> Color {
        _ = revision
        return Color(palette.color(for: kind))
    }

    func hex(for kind: TimelineClipColor) -> String {
        _ = revision
        guard let color = palette.color(for: kind).usingColorSpace(.sRGB) else { return "" }
        return String(
            format: "#%02X%02X%02X",
            Int(round(color.redComponent * 255)),
            Int(round(color.greenComponent * 255)),
            Int(round(color.blueComponent * 255))
        )
    }

    func set(_ color: Color, for kind: TimelineClipColor) {
        palette.set(NSColor(color), for: kind)
        didChange()
    }

    func resetAll() {
        palette.resetAll()
        didChange()
    }

    var hasOverrides: Bool {
        _ = revision
        return palette.hasOverrides
    }

    private func didChange() {
        revision &+= 1
        NotificationCenter.default.post(name: .timelineClipColorsDidChange, object: nil)
    }
}

extension Notification.Name {
    static let timelineClipColorsDidChange = Notification.Name("timelineClipColorsDidChange")
}
