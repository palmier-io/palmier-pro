using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using PalmierPro.App.ViewModels.Preview;
using Windows.System;

namespace PalmierPro.App.Services;

/// Guards raw (unmodified or shift-only) key accelerators from firing while a text-input control
/// has focus. Ports the `isTextInputFocused` early-return in
/// EditorWindowController.handleKeyDown — but where AppKit's local key monitor only intercepts
/// the raw key events it explicitly re-dispatches, WinUI's KeyboardAccelerator fires from a
/// global per-XamlRoot table regardless of focus, so every raw-key menu accelerator (Select
/// Forward on Track, Trim Start/End, Delete, Ripple Delete, Maximize Focused Panel) must check
/// this before acting.
///
/// STAGE C HANDOFF: M1 wires this into PalmierMenuBar's raw-key accelerators, which are all
/// present-but-disabled placeholders — there's no EditorViewModel yet. Space/arrow-key playback
/// (M4, Stage D) is wired below via <see cref="HandleTransportKey"/>. Arrow-key media selection,
/// razor/pointer tool, etc. still have no Windows home; route them through this same service
/// rather than a second ad hoc focus check.
public static class KeyRouter
{
    public static bool IsTextInputFocused(XamlRoot? xamlRoot)
    {
        if (xamlRoot is null)
        {
            return false;
        }
        return FocusManager.GetFocusedElement(xamlRoot) is TextBox or PasswordBox or RichEditBox or AutoSuggestBox;
    }

    public static bool ShouldHandleRawKeyAccelerator(XamlRoot? xamlRoot) => !IsTextInputFocused(xamlRoot);

    /// Ports the Space/arrow-key half of `EditorWindowController.handleKeyDown` (M4, Stage D) —
    /// the STAGE C HANDOFF note above flagged this as having "no Windows home yet"; this is that
    /// home. Space toggles play/pause; Left/Right step one frame; Shift+Left/Right skip 5 frames
    /// (Mac's `skipForward(frames:)`/`skipBackward(frames:)` default) — same text-input-focus guard
    /// as every other raw accelerator.
    ///
    /// Callers wire this to a bubbling (not tunneling) `KeyDown` on the editor's root, so a control
    /// that already handled the same key itself — `TimelineCanvasControl`'s own Left/Right/Home/End,
    /// `MediaGridView`'s built-in arrow-key item navigation, both of which mark their `KeyDown`
    /// `Handled` — never reaches here, mirroring the Mac's `focusedPanel == .media` arrow carve-out
    /// without needing to duplicate that focus check on this platform (routed-event bubbling already
    /// does it). Returns whether the key was handled; the caller sets `e.Handled` accordingly.
    public static bool HandleTransportKey(TransportViewModel transport, XamlRoot? xamlRoot, VirtualKey key, VirtualKeyModifiers modifiers)
    {
        if (!ShouldHandleRawKeyAccelerator(xamlRoot))
        {
            return false;
        }
        // Never steal a Ctrl/Alt/Win combo (e.g. Alt+Space's system menu) — only bare or Shift-only
        // presses are transport shortcuts, matching every raw accelerator already registered.
        var extraModifiers = modifiers & ~VirtualKeyModifiers.Shift;
        if (extraModifiers != VirtualKeyModifiers.None)
        {
            return false;
        }
        var shift = modifiers.HasFlag(VirtualKeyModifiers.Shift);
        switch (key)
        {
            case VirtualKey.Space when !shift:
                transport.TogglePlayback();
                return true;
            case VirtualKey.Left:
                if (shift) transport.SkipBackward(); else transport.StepBackward();
                return true;
            case VirtualKey.Right:
                if (shift) transport.SkipForward(); else transport.StepForward();
                return true;
            default:
                return false;
        }
    }
}
