import AppKit
import Testing
@testable import CompositorPro

@Suite("Native window menu commands", .serialized)
@MainActor
struct MainMenuWindowCommandTests {
    @Test func closeCommandHonorsNativeCloseRefusal() throws {
        _ = NSApplication.shared
        let menu = MainMenuBuilder.buildMenu()
        let close = try #require(menu.items.compactMap(\.submenu).flatMap(\.items).first {
            $0.keyEquivalent == "w" && $0.keyEquivalentModifierMask == [.command]
        })
        #expect(close.target == nil)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let delegate = CloseDelegate()
        window.delegate = delegate
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        #expect(NSApp.sendAction(try #require(close.action), to: window, from: close))
        #expect(delegate.closeRequests == 1)
        #expect(window.isVisible)

        delegate.allowsClose = true
        #expect(NSApp.sendAction(try #require(close.action), to: window, from: close))
        #expect(delegate.closeRequests == 2)
        #expect(!window.isVisible)
    }

    @Test func windowShortcutsKeepUnmodifiedEditorTrim() throws {
        let items = MainMenuBuilder.buildMenu().items.compactMap(\.submenu).flatMap(\.items)
        let fullscreen = try #require(items.first { $0.action == #selector(NSWindow.toggleFullScreen(_:)) })
        #expect(fullscreen.keyEquivalent == "f")
        #expect(fullscreen.keyEquivalentModifierMask == [.command, .control])
        #expect(fullscreen.target == nil)
        let trim = try #require(items.first { $0.keyEquivalent == "w" && $0.keyEquivalentModifierMask.isEmpty })
        #expect(trim.action == #selector(EditorActions.trimEndToPlayhead(_:)))
    }

    private final class CloseDelegate: NSObject, NSWindowDelegate {
        var allowsClose = false
        var closeRequests = 0

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            closeRequests += 1
            return allowsClose
        }
    }
}
