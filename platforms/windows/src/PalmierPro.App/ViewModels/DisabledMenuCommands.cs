using CommunityToolkit.Mvvm.Input;

namespace PalmierPro.App.ViewModels;

/// Menu items ported 1:1 from MainMenuBuilder that have no Windows implementation yet — either
/// editor-specific (no EditorViewModel exists before Stage C/D) or infra-specific (no
/// Settings/About/Help window exists before a later stage). Present in the menu, permanently
/// disabled, so the two menu trees stay structurally identical; each is wired to a real handler
/// when its owning feature lands.
public static class DisabledMenuCommands
{
    private static IRelayCommand NoOp() => new RelayCommand(() => { }, () => false);

    public static IRelayCommand About { get; } = NoOp();
    public static IRelayCommand CheckForUpdates { get; } = NoOp();
    public static IRelayCommand Settings { get; } = NoOp();
    public static IRelayCommand ImportMedia { get; } = NoOp();
    public static IRelayCommand Export { get; } = NoOp();
    public static IRelayCommand Cut { get; } = NoOp();
    public static IRelayCommand Copy { get; } = NoOp();
    public static IRelayCommand Paste { get; } = NoOp();
    public static IRelayCommand SelectAll { get; } = NoOp();
    public static IRelayCommand SelectForwardOnTrack { get; } = NoOp();
    public static IRelayCommand SelectForwardOnAllTracks { get; } = NoOp();
    public static IRelayCommand SplitAtPlayhead { get; } = NoOp();
    public static IRelayCommand TrimStartToPlayhead { get; } = NoOp();
    public static IRelayCommand TrimEndToPlayhead { get; } = NoOp();
    public static IRelayCommand DeleteSelectedClips { get; } = NoOp();
    public static IRelayCommand RippleDelete { get; } = NoOp();
    public static IRelayCommand ToggleMediaPanel { get; } = NoOp();
    public static IRelayCommand ToggleInspector { get; } = NoOp();
    public static IRelayCommand ToggleAgentPanel { get; } = NoOp();
    public static IRelayCommand ToggleMaximizePanel { get; } = NoOp();
    public static IRelayCommand SetLayoutDefault { get; } = NoOp();
    public static IRelayCommand SetLayoutMedia { get; } = NoOp();
    public static IRelayCommand SetLayoutVertical { get; } = NoOp();
    public static IRelayCommand Tutorial { get; } = NoOp();
    public static IRelayCommand KeyboardShortcuts { get; } = NoOp();
    public static IRelayCommand MCPInstructions { get; } = NoOp();
    public static IRelayCommand SendFeedback { get; } = NoOp();
}
