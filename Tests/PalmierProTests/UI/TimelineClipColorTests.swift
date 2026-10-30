import AppKit
import Foundation
import Observation
import SwiftUI
import Testing
@testable import PalmierPro

@Suite("Timeline clip colors")
@MainActor
struct TimelineClipColorTests {
    @Test func missingOrInvalidPreferenceUsesDefaultColor() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        expectSameColor(TimelineClipColor.video.storedColor(in: defaults), TimelineClipColor.video.defaultColor)

        defaults.set([2, -1, 0.5], forKey: TimelineClipColor.video.defaultsKey)
        expectSameColor(TimelineClipColor.video.storedColor(in: defaults), TimelineClipColor.video.defaultColor)
    }

    @Test func customColorPersistsAndResetRestoresDefaults() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let palette = TimelineClipColorPalette(defaults: defaults)
        let custom = NSColor(srgbRed: 0.12, green: 0.34, blue: 0.56, alpha: 1)

        palette.set(custom, for: .audio)

        expectSameColor(palette.color(for: .audio), custom)
        expectSameColor(TimelineClipColor.audio.storedColor(in: defaults), custom)
        #expect(palette.hasOverrides)

        palette.resetAll()

        expectSameColor(palette.color(for: .audio), TimelineClipColor.audio.defaultColor)
        #expect(defaults.object(forKey: TimelineClipColor.audio.defaultsKey) == nil)
        #expect(!palette.hasOverrides)
    }

    @Test func storeNotifiesTimelineAfterChanges() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = TimelineClipColorStore(palette: TimelineClipColorPalette(defaults: defaults))

        await confirmation("Timeline redraw is requested", expectedCount: 2) { notified in
            let observer = NotificationCenter.default.addObserver(
                forName: .timelineClipColorsDidChange,
                object: nil,
                queue: nil
            ) { _ in
                notified()
            }
            defer { NotificationCenter.default.removeObserver(observer) }

            store.set(Color(red: 0.8, green: 0.7, blue: 0.6), for: .text)
            store.resetAll()
        }
    }

    @Test func colorAccessTracksPaletteChanges() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = TimelineClipColorStore(palette: TimelineClipColorPalette(defaults: defaults))

        await confirmation("Color access is invalidated") { invalidated in
            withObservationTracking {
                _ = store.color(for: .text)
            } onChange: {
                invalidated()
            }

            store.set(Color(red: 0.8, green: 0.7, blue: 0.6), for: .text)
        }
    }

    @Test func foregroundChoosesTheHigherContrastColor() {
        let onDark = AppTheme.TrackColor.readableForeground(on: .black)
        let onLight = AppTheme.TrackColor.readableForeground(on: .white)

        expectSameColor(onDark, .white)
        expectSameColor(onLight, .black)
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "TimelineClipColorTests-\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suiteName)), suiteName)
    }

    private func expectSameColor(_ lhs: NSColor, _ rhs: NSColor, sourceLocation: SourceLocation = #_sourceLocation) {
        let lhs = lhs.usingColorSpace(.sRGB) ?? lhs
        let rhs = rhs.usingColorSpace(.sRGB) ?? rhs
        #expect(abs(lhs.redComponent - rhs.redComponent) < 0.001, sourceLocation: sourceLocation)
        #expect(abs(lhs.greenComponent - rhs.greenComponent) < 0.001, sourceLocation: sourceLocation)
        #expect(abs(lhs.blueComponent - rhs.blueComponent) < 0.001, sourceLocation: sourceLocation)
    }
}
