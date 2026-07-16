using CommunityToolkit.Mvvm.ComponentModel;
using PalmierPro.App.ViewModels.Editor;
using PalmierPro.Core.Models;

namespace PalmierPro.App.ViewModels.Inspector;

/// The clip properties a Phase-1 tab hosts. No Multicam/AI (Phase 2 — see AGENTS.md's Windows
/// port plan); no Audio (no Windows tab content owns it yet either). Order here is tab-rail order.
public enum InspectorTab
{
    Video,
    Keyframes,
    Effects,
    Color,
    Text,
}

public static class InspectorTabExtensions
{
    /// Mirrors the Mac ClipTab rawValue strings (InspectorView.swift) where one exists, for the
    /// closest achievable label parity. Mac has no standalone "Color" tab — Lift/Gamma/Gain wheels,
    /// the grade curve, and hue curves are collapsible sections inside its single Adjust tab
    /// (Inspector/Tabs/AdjustTab.swift) — but EffectsTabView's generic effect-stack editor has no
    /// seam for a custom-drawn wheel/curve control (see EffectsViewModel's class doc), so this port
    /// gives color grading its own tab rather than leaving it unreachable.
    public static string DisplayName(this InspectorTab tab) => tab switch
    {
        InspectorTab.Video => "Video",
        InspectorTab.Keyframes => "Keyframes",
        InspectorTab.Effects => "Adjust",
        InspectorTab.Color => "Color",
        InspectorTab.Text => "Content",
        _ => throw new ArgumentOutOfRangeException(nameof(tab)),
    };
}

public enum InspectorSelectionState
{
    None,
    Single,
    Multi,
}

/// Ports the selection-driven half of Inspector/InspectorView.swift — which clip(s) are selected,
/// which tabs that implies, and which tab is active — for the five in-scope tabs (Video: transform/
/// crop/opacity/speed, Keyframes, Effects, Color, Text). No tab *content* lives here: each tab's actual
/// view is supplied through InspectorTabRegistry (Views/Inspector/InspectorTabRegistry.cs) so this
/// class, like TimelineEditorViewModel, stays WinUI-free and testable under plain `dotnet test`.
public sealed partial class InspectorViewModel : ObservableObject
{
    private TimelineEditorViewModel? _timeline;
    private InspectorTab _preferredTab = InspectorTab.Video;

    [ObservableProperty]
    public partial InspectorSelectionState SelectionState { get; set; } = InspectorSelectionState.None;

    [ObservableProperty]
    public partial IReadOnlyList<Clip> SelectedClips { get; set; } = [];

    [ObservableProperty]
    public partial IReadOnlyList<InspectorTab> AvailableTabs { get; set; } = [];

    /// Null when the selection resolves to no in-scope tab (e.g. an audio-only clip — no Windows
    /// tab content owns that yet) or when nothing is selected; the view renders nothing for either,
    /// same as it does for Multicam/AI on the Mac.
    [ObservableProperty]
    public partial InspectorTab? ActiveTab { get; set; }

    // MARK: - Empty-state (no selection) timeline metadata — ports `projectMetadataContent`.

    public string TimelineName => _timeline?.Timeline.Name ?? "";

    /// Ports the Mac's "Path" project row (projectMetadataContent's `url.path`) — omitted from the
    /// initial Windows port alongside menu-backed Settings rows.
    public string ProjectPath => _timeline?.Document.PackagePath ?? "";

    public int TimelineWidth => _timeline?.Timeline.Width ?? 0;

    public int TimelineHeight => _timeline?.Timeline.Height ?? 0;

    public int TimelineFps => _timeline?.Timeline.Fps ?? 0;

    public string TimelineDurationText => _timeline is { } t ? FormatDuration(t.Timeline.TotalFrames, t.Timeline.Fps) : "";

    public string TimelineAspectRatioText => _timeline is { } t ? FormatAspectRatio(t.Timeline.Width, t.Timeline.Height) : "";

    /// Wires (or unwires, passing null) the active document's timeline editor — called whenever
    /// EditorPlaceholderView.SetDocument swaps documents, mirroring how it also rewires
    /// MediaTabViewModel/PreviewViewModel there.
    public void SetTimeline(TimelineEditorViewModel? timeline)
    {
        if (_timeline is not null)
        {
            _timeline.PropertyChanged -= OnTimelinePropertyChanged;
            _timeline.StructuralChangeRequested -= OnStructuralChange;
        }
        _timeline = timeline;
        if (_timeline is not null)
        {
            _timeline.PropertyChanged += OnTimelinePropertyChanged;
            _timeline.StructuralChangeRequested += OnStructuralChange;
        }
        Recompute(resetPreferredTab: true);
        RaiseTimelineMetadataChanged();
    }

    /// Explicit tab pick from the tab rail — a no-op for a tab not currently offered (stale click
    /// racing a selection change), mirroring the Mac's `preferredTab` write in `tabBar`.
    public void SelectTab(InspectorTab tab)
    {
        if (!AvailableTabs.Contains(tab))
        {
            return;
        }
        _preferredTab = tab;
        ActiveTab = tab;
    }

    private void OnTimelinePropertyChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(TimelineEditorViewModel.SelectedClipIds))
        {
            Recompute(resetPreferredTab: false);
        }
        else if (e.PropertyName is null or nameof(TimelineEditorViewModel.ActiveTimelineId))
        {
            Recompute(resetPreferredTab: true);
            RaiseTimelineMetadataChanged();
        }
    }

    /// Structural edits (delete/split/undo/...) can change which clips the current selection ids
    /// resolve to without SelectedClipIds itself changing reference — mirrors the Mac's `.onChange`
    /// firing on every relevant editor mutation, not just a fresh selection gesture.
    private void OnStructuralChange(object? sender, EventArgs e)
    {
        Recompute(resetPreferredTab: false);
        RaiseTimelineMetadataChanged();
    }

    private void Recompute(bool resetPreferredTab)
    {
        var clips = _timeline is null ? [] : ResolveSelectedClips(_timeline);
        SelectedClips = clips;
        SelectionState = clips.Count switch
        {
            0 => InspectorSelectionState.None,
            1 => InspectorSelectionState.Single,
            _ => InspectorSelectionState.Multi,
        };

        var tabs = ComputeAvailableTabs(clips, SelectionState);
        AvailableTabs = tabs;

        if (resetPreferredTab && tabs.Count > 0)
        {
            _preferredTab = tabs[0];
        }
        var resolved = tabs.Count == 0 ? (InspectorTab?)null : (tabs.Contains(_preferredTab) ? _preferredTab : tabs[0]);
        if (resolved is { } t)
        {
            _preferredTab = t;
        }
        ActiveTab = resolved;
    }

    private void RaiseTimelineMetadataChanged()
    {
        OnPropertyChanged(nameof(TimelineName));
        OnPropertyChanged(nameof(ProjectPath));
        OnPropertyChanged(nameof(TimelineWidth));
        OnPropertyChanged(nameof(TimelineHeight));
        OnPropertyChanged(nameof(TimelineFps));
        OnPropertyChanged(nameof(TimelineDurationText));
        OnPropertyChanged(nameof(TimelineAspectRatioText));
    }

    /// Track-order clip lookup, matching the Mac's `for track in editor.timeline.tracks` loop.
    private static List<Clip> ResolveSelectedClips(TimelineEditorViewModel timeline)
    {
        if (timeline.SelectedClipIds.Count == 0)
        {
            return [];
        }
        var result = new List<Clip>();
        foreach (var track in timeline.Timeline.Tracks)
        {
            foreach (var clip in track.Clips)
            {
                if (timeline.SelectedClipIds.Contains(clip.Id))
                {
                    result.Add(clip);
                }
            }
        }
        return result;
    }

    /// Ports `availableTabs`, trimmed to the five tabs a Windows tab view can exist for. A text-only
    /// selection gets just Content; a selection with any non-text visual clip gets Video (+
    /// Keyframes when exactly one clip is selected, matching the Mac's `single != nil` gate) +
    /// Adjust + Color (a Windows-only split of the Mac's single Adjust tab — see
    /// InspectorTabExtensions.DisplayName). An audio-only selection resolves to no tabs — Phase 1
    /// has no Audio tab content.
    private static List<InspectorTab> ComputeAvailableTabs(IReadOnlyList<Clip> clips, InspectorSelectionState state)
    {
        if (state == InspectorSelectionState.None)
        {
            return [];
        }

        if (clips.All(c => c.MediaType == ClipType.Text))
        {
            return [InspectorTab.Text];
        }

        var hasNonTextVisual = clips.Any(c => c.MediaType.IsVisual() && c.MediaType != ClipType.Text);
        if (!hasNonTextVisual)
        {
            return [];
        }

        var tabs = new List<InspectorTab> { InspectorTab.Video };
        if (state == InspectorSelectionState.Single)
        {
            tabs.Add(InspectorTab.Keyframes);
        }
        tabs.Add(InspectorTab.Effects);
        tabs.Add(InspectorTab.Color);
        return tabs;
    }

    private static string FormatAspectRatio(int width, int height)
    {
        var divisor = Gcd(Math.Max(1, width), Math.Max(1, height));
        return $"{width / divisor}:{height / divisor}";
    }

    private static int Gcd(int a, int b)
    {
        while (b != 0)
        {
            (a, b) = (b, a % b);
        }
        return a == 0 ? 1 : a;
    }

    private static string FormatDuration(int totalFrames, int fps)
    {
        var totalSeconds = fps > 0 ? (int)Math.Round((double)totalFrames / fps) : 0;
        var hours = totalSeconds / 3600;
        var minutes = totalSeconds % 3600 / 60;
        var seconds = totalSeconds % 60;
        return hours > 0
            ? $"{hours}:{minutes:D2}:{seconds:D2}"
            : $"{minutes}:{seconds:D2}";
    }
}
