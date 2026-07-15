using CommunityToolkit.Mvvm.Input;

namespace PalmierPro.App.ViewModels;

/// Menu items ported 1:1 from MainMenuBuilder that have no Windows implementation yet — either
/// editor-specific (no preview/inspector UI exists before Stage D/E) or infra-specific (no
/// Settings/About/Help window exists before a later stage). Present in the menu, permanently
/// disabled, so the two menu trees stay structurally identical; each is wired to a real handler
/// when its owning feature lands.
///
/// Stage C (M3) moved SelectForwardOnTrack/SelectForwardOnAllTracks/SplitAtPlayhead/
/// TrimStartToPlayhead/TrimEndToPlayhead/DeleteSelectedClips/RippleDelete out of this class and
/// onto `ShellViewModel` (backed by `TimelineEditorViewModel`) — they're real commands now, not
/// placeholders; see `PalmierMenuBar.xaml`'s Edit-menu section.
///
/// Stage C also landed the FCPXML/XMEML exporters (`PalmierPro.Services.Export`) and their
/// `Services.ExportServices` registration point, but `Export` stays a NoOp here — the Export
/// dialog (destination/format picker) is Stage F.
public static class DisabledMenuCommands
{
    private static IRelayCommand NoOp() => new RelayCommand(() => { }, () => false);

    public static IRelayCommand About { get; } = NoOp();
    public static IRelayCommand CheckForUpdates { get; } = NoOp();
    public static IRelayCommand Settings { get; } = NoOp();
    public static IRelayCommand Export { get; } = NoOp();
    public static IRelayCommand Cut { get; } = NoOp();
    public static IRelayCommand Copy { get; } = NoOp();
    public static IRelayCommand Paste { get; } = NoOp();
    public static IRelayCommand SelectAll { get; } = NoOp();
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
