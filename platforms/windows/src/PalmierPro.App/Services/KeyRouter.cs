using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;

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
/// present-but-disabled placeholders — there's no EditorViewModel yet. The rest of
/// EditorWindowController.handleKeyDown (space/playback, arrow-key media selection, razor/pointer
/// tool, etc.) has no Windows home yet; route it through this same service in Stage C rather than
/// a second ad hoc focus check.
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
}
